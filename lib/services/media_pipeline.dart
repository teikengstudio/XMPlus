import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../api/xmly_client.dart';
import '../models/xmly_models.dart';
import 'account_service.dart';
import 'app_log.dart';
import 'audio_cache.dart';
import 'download_paths.dart';
import 'file_paths.dart';
import 'download_service.dart';
import 'media_processor.dart';

/// Downloads and the player retain the same cache object; neither opens a CDN
/// stream elsewhere. Billing admission remains exclusively in DownloadService.
class MediaPipeline {
  MediaPipeline({
    required this.accounts,
    required this.anonymous,
    MediaProcessor? processor,
    DownloadPaths? paths,
  }) : processor = processor ?? MediaProcessor(),
       paths = paths ?? DownloadPaths() {
    AppLog.instance.trace(
      "lib/services/media_pipeline.dart::MediaPipeline.new",
    );
  }
  final AccountService accounts;
  final XmlyClient anonymous;
  final MediaProcessor processor;
  final DownloadPaths paths;
  final Map<String, AudioCache> _caches = {};
  final Map<String, DownloadControl> _controls = {};
  final Map<String, int> _leases = {};
  final Map<String, String> _directories = {};
  final Set<String> _finished = {};

  AudioCache? taskCache(String taskId) {
    AppLog.instance.trace(
      "lib/services/media_pipeline.dart::MediaPipeline.taskCache",
    );
    return _controls.containsKey(taskId) ? _caches[taskId] : null;
  }

  void retainTask(String taskId) {
    AppLog.instance.trace(
      "lib/services/media_pipeline.dart::MediaPipeline.retainTask",
    );

    _leases[taskId] = (_leases[taskId] ?? 0) + 1;
  }

  Future<void> releaseTask(String taskId) async {
    AppLog.instance.trace(
      "lib/services/media_pipeline.dart::MediaPipeline.releaseTask",
    );

    final count = (_leases[taskId] ?? 0) - 1;
    if (count > 0) {
      _leases[taskId] = count;
      return;
    }
    _leases.remove(taskId);
    if (_finished.contains(taskId)) await _discardFinished(taskId);
  }

  Future<ResolvedAudio> _refresh(DownloadTask task, bool Function() isActive) {
    AppLog.instance.trace(
      "lib/services/media_pipeline.dart::MediaPipeline._refresh",
    );

    if (!isActive()) throw const DownloadStopped();
    final quality = (task.settings['download'] as Map?)?['quality'] as String?;
    Future<ResolvedAudio> resolve(XmlyClient client) {
      AppLog.instance.trace(
        "lib/services/media_pipeline.dart::MediaPipeline._refresh.resolve",
      );

      if (!isActive()) throw const DownloadStopped();
      return DownloadService.readRequests(client, task.settings, () {
        AppLog.instance.trace(
          "lib/services/media_pipeline.dart::MediaPipeline._refresh.resolve.closure#1",
        );
        return client.resolve(
          task.track.id,
          force: true,
          quality: quality,
          mediaAuthRetries: 0,
          isActive: isActive,
        );
      }, control: _controls[task.id]);
    }

    return task.accountIdentity == 'anonymous'
        ? resolve(anonymous)
        : accounts.runWithAccount(task.accountIdentity, resolve);
  }

  String _cacheDirectory(DownloadTask task) {
    AppLog.instance.trace(
      "lib/services/media_pipeline.dart::MediaPipeline._cacheDirectory",
    );

    if (!p.isAbsolute(task.rootDirectory))
      throw const XmlyException('invalid_root', '下载目录必须是绝对路径');
    for (final component in [
      task.id,
      task.accountIdentity,
      task.track.number,
    ]) {
      if (!RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(component)) {
        throw const XmlyException('cache_identity', '缓存任务标识无效');
      }
    }
    return p.join(
      absoluteFilePath(task.rootDirectory),
      '.xmly-cache',
      task.accountIdentity,
      task.track.number,
      task.id,
    );
  }

  Future<String> processOnly(DownloadTask task, DownloadControl control) {
    AppLog.instance.trace(
      "lib/services/media_pipeline.dart::MediaPipeline.processOnly",
    );
    return AppLog.instance.runWithErrorScope(() async {
      AppLog.instance.trace(
        "lib/services/media_pipeline.dart::MediaPipeline.processOnly.closure#1",
      );

      await control.checkpoint();
      final directory = _cacheDirectory(task);
      final source = await _verifiedSource(directory, task);
      if (source == null)
        throw const XmlyException('source_missing', '源缓存已失效，请重新获取音频');
      await control.checkpoint();
      final candidate = _caches[task.id];
      final cache =
          candidate?.complete == true &&
              candidate!.directory == directory &&
              _directories[task.id] == directory
          ? candidate
          : null;
      _directories[task.id] = directory;
      // A paused transfer already verified all source bytes. Re-publish its
      // retained cache while reprocessing, so playback need not await conversion.
      if (cache != null) _controls[task.id] = control;
      var completed = false;
      var failed = false;
      try {
        final result = await _process(task, source, control);
        completed = true;
        return result;
      } catch (_) {
        failed = true;
        rethrow;
      } finally {
        try {
          if (cache != null) {
            if (!completed ||
                control.paused ||
                control.cancelled ||
                !_leases.containsKey(task.id)) {
              await cache.pause();
            }
            if (identical(_controls[task.id], control))
              _controls.remove(task.id);
          }
          if (_finished.contains(task.id) && !_leases.containsKey(task.id)) {
            await _discardFinished(task.id);
          }
        } catch (error, stack) {
          _cleanupFailure(task.id, error, stack, primaryFailed: failed);
          if (!failed) rethrow;
        }
      }
    });
  }

  Future<String> _process(
    DownloadTask task,
    String source,
    DownloadControl control,
  ) async {
    AppLog.instance.trace(
      "lib/services/media_pipeline.dart::MediaPipeline._process",
    );

    await control.processing();
    final result = await processor.process(
      sourcePath: source,
      task: task,
      checkpoint: control.checkpoint,
    );
    if (result.warnings.isNotEmpty)
      await control.warning(result.warnings.join('；'));
    _finished.add(task.id);
    return result.path;
  }

  Future<String> transfer(
    DownloadTask task,
    ResolvedAudio audio,
    DownloadControl control,
  ) {
    AppLog.instance.trace(
      "lib/services/media_pipeline.dart::MediaPipeline.transfer",
    );
    return AppLog.instance.runWithErrorScope(() async {
      AppLog.instance.trace(
        "lib/services/media_pipeline.dart::MediaPipeline.transfer.closure#1",
      );

      final directory = _cacheDirectory(task);
      final download = task.settings['download'] as Map? ?? const {};
      await paths.checkRoot(
        task.rootDirectory,
        minimumFreeMiB: download['minimumFreeMiB'] as int? ?? 512,
      );
      await control.checkpoint();
      var cache = _caches[task.id];
      if (cache != null && _directories[task.id] != directory) {
        // Account rotation keeps the task ID, but bytes and refresh callbacks
        // belong to the old account. Stop old readers before opening its successor.
        await cache.close();
        _caches.remove(task.id);
        _directories.remove(task.id);
        _finished.remove(task.id);
        cache = null;
        await control.checkpoint();
      }
      if (cache == null) {
        cache = await AudioCache.open(
          directory: directory,
          audio: audio,
          rateLimitRetries: download['retryLimit'] as int? ?? 3,
          minimumRateLimitDelay: const Duration(minutes: 5),
          refresh: (isActive) {
            AppLog.instance.trace(
              "lib/services/media_pipeline.dart::MediaPipeline.transfer.closure#1.closure#1",
            );
            return _refresh(task, isActive);
          },
          checkpoint: () async {
            AppLog.instance.trace(
              "lib/services/media_pipeline.dart::MediaPipeline.transfer.closure#1.closure#2",
            );

            await _controls[task.id]?.checkpoint();
          },
          onProgress: (received, total, rate) {
            AppLog.instance.trace(
              "lib/services/media_pipeline.dart::MediaPipeline.transfer.closure#1.closure#3",
            );

            _controls[task.id]?.onProgress(received, total, rate);
          },
        );
        _caches[task.id] = cache;
      } else {
        await cache.pause();
        cache.updateAuthorization(audio);
      }
      _controls[task.id] = control;
      _directories[task.id] = directory;
      var completed = false;
      var failed = false;
      try {
        var source = await _verifiedSource(directory, task);
        if (source == null) {
          // Cache cooldowns and queued account refreshes may not checkpoint until
          // they finish. A stop reaches the finally block, which drains the cache.
          await Future.any<void>([
            cache.ensureComplete(),
            control.stopped.then((_) {
              AppLog.instance.trace(
                "lib/services/media_pipeline.dart::MediaPipeline.transfer.closure#1.closure#4",
              );
              return throw const DownloadStopped();
            }),
          ]);
          await control.checkpoint();
          final extension = cache.sourceFormat;
          if (!const {
            'mp3',
            'm4a',
            'flac',
            'ogg',
            'wav',
            'aac',
          }.contains(extension)) {
            throw const XmlyException('invalid_media', '无法识别源音频格式');
          }
          final temporary = p.join(
            directory,
            'assemble-${const Uuid().v4()}.$extension',
          );
          await cache.assemble(temporary);
          source = p.join(directory, 'source.$extension');
          await paths.commit(temporary, source, overwrite: true);
          final digest = (await sha256.bind(File(source).openRead()).single)
              .toString();
          final manifest = File(
            p.join(directory, 'source-${const Uuid().v4()}.json'),
          );
          await manifest.writeAsString(
            jsonEncode({
              'account': task.accountIdentity,
              'track': task.track.id,
              'task': task.id,
              'extension': extension,
              'sha256': digest,
            }),
            flush: true,
          );
          await paths.commit(
            manifest.path,
            p.join(directory, 'source.json'),
            overwrite: true,
          );
        }
        final result = await _process(task, source, control);
        completed = true;
        return result;
      } catch (_) {
        failed = true;
        rethrow;
      } finally {
        try {
          // A retained completed cache may still be draining to the player.
          if (!completed ||
              control.paused ||
              control.cancelled ||
              !cache.complete ||
              !_leases.containsKey(task.id)) {
            await cache.pause();
          }
          _controls.remove(task.id);
          if (_finished.contains(task.id) && !_leases.containsKey(task.id)) {
            await _discardFinished(task.id);
          }
        } catch (error, stack) {
          _cleanupFailure(task.id, error, stack, primaryFailed: failed);
          if (!failed) rethrow;
        }
      }
    });
  }

  Future<String?> _verifiedSource(String directory, DownloadTask task) async {
    AppLog.instance.trace(
      "lib/services/media_pipeline.dart::MediaPipeline._verifiedSource",
    );

    final manifest = File(p.join(directory, 'source.json'));
    try {
      if (!await manifest.exists() || await manifest.length() > 4096)
        return null;
      final data = jsonDecode(await manifest.readAsString()) as Map;
      final extension = data['extension'];
      if (data['account'] != task.accountIdentity ||
          data['track'] != task.track.id ||
          data['task'] != task.id ||
          !const {
            'mp3',
            'm4a',
            'flac',
            'ogg',
            'wav',
            'aac',
          }.contains(extension))
        return null;
      final source = File(p.join(directory, 'source.$extension'));
      if (!await source.exists()) return null;
      final digest = (await sha256.bind(source.openRead()).single).toString();
      return digest == data['sha256'] ? source.path : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> pauseTask(String taskId) async {
    AppLog.instance.trace(
      "lib/services/media_pipeline.dart::MediaPipeline.pauseTask",
    );

    await _caches[taskId]?.pause();
  }

  Future<void> detachTask(String id) async {
    AppLog.instance.trace(
      "lib/services/media_pipeline.dart::MediaPipeline.detachTask",
    );

    if (_controls.containsKey(id) || (_leases[id] ?? 0) > 0) {
      throw const XmlyException('cache_in_use', '请先停止引用此任务的播放和下载');
    }
    await _caches[id]?.close();
    _caches.remove(id);
    _directories.remove(id);
    _finished.remove(id);
  }

  Future<void> discardSource(DownloadTask task) async {
    AppLog.instance.trace(
      "lib/services/media_pipeline.dart::MediaPipeline.discardSource",
    );

    if (_controls.containsKey(task.id) || (_leases[task.id] ?? 0) > 0) {
      throw const XmlyException('cache_in_use', '请先停止引用此任务的播放和下载');
    }
    final directory = _cacheDirectory(task);
    final cache = _caches[task.id];
    if (cache != null) {
      await cache.deleteRegenerable();
    } else if (await Directory(directory).exists()) {
      await Directory(directory).delete(recursive: true);
    }
    _caches.remove(task.id);
    _directories.remove(task.id);
    _finished.remove(task.id);
  }

  Future<void> _discardFinished(String id) async {
    AppLog.instance.trace(
      "lib/services/media_pipeline.dart::MediaPipeline._discardFinished",
    );

    final cache = _caches.remove(id);
    final directory = _directories[id];
    try {
      if (cache != null) {
        await cache.deleteRegenerable();
      } else if (directory != null && await Directory(directory).exists()) {
        await Directory(directory).delete(recursive: true);
      }
      _finished.remove(id);
      _directories.remove(id);
    } on FileSystemException catch (error, stack) {
      _cleanupFailure(id, error, stack, primaryFailed: true);
      // Keep the cleanup target for a later release/close; never delete final output.
    }
  }

  void _cleanupFailure(
    String taskId,
    Object error,
    StackTrace stack, {
    required bool primaryFailed,
  }) {
    AppLog.instance.trace(
      "lib/services/media_pipeline.dart::MediaPipeline._cleanupFailure",
    );

    if (!primaryFailed) AppLog.instance.requestUploadPrompt();
    if (AppLog.instance.errorWasRecorded(error)) return;
    AppLog.instance.write(
      primaryFailed ? AppLogLevel.warning : AppLogLevel.error,
      'media',
      'Media cache cleanup failed',
      data: {'taskId': taskId},
      error: error,
      stackTrace: stack,
      promptUser: !primaryFailed,
    );
  }

  Future<void> close() async {
    AppLog.instance.trace(
      "lib/services/media_pipeline.dart::MediaPipeline.close",
    );

    for (final id in _finished.toList()) {
      if (!_leases.containsKey(id)) await _discardFinished(id);
    }
    for (final cache in _caches.values.toList()) {
      await cache.close();
    }
    _caches.clear();
    _controls.clear();
    _leases.clear();
  }
}
