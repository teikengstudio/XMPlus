import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../models/xmly_models.dart';
import 'app_log.dart';

/// Android platform operations that cannot use desktop command-line utilities.
class AndroidPlatform {
  static const _channel = MethodChannel('teikengstudio.xmplus/platform');
  static const _filesChannel = MethodChannel('teikengstudio.xmplus/files');

  /// SAF receives paths and a bounded preamble, never the committed log bytes.
  static Future<Uri?> exportLogSnapshot(LogSnapshot snapshot, String fileName) {
    AppLog.instance.trace(
      "lib/services/android_platform.dart::AndroidPlatform.exportLogSnapshot",
    );
    return AppLog.instance.runWithErrorScope(() async {
      AppLog.instance.trace(
        "lib/services/android_platform.dart::AndroidPlatform.exportLogSnapshot.closure#1",
      );

      if (!RegExp(r'^XMPlus-[A-Za-z0-9_-]+\.log$').hasMatch(fileName)) {
        throw const FormatException('日志文件名无效');
      }
      if (snapshot.tailLength > 1024 * 1024) {
        throw StateError('日志保留片段超过安全上限');
      }
      final header = snapshot.warningHeader;
      final warningPrefix = header.isEmpty
          ? ''
          : '${AppLog.redact(utf8.decode(header))}\n';
      if (utf8.encode(warningPrefix).length > 64 * 1024) {
        throw StateError('日志写入失败说明超过安全上限');
      }
      File? tail;
      var tailCreated = false;
      try {
        if (snapshot.totalBytes > snapshot.length + header.length) {
          final cache = await getTemporaryDirectory();
          tail = File(
            p.join(cache.path, 'xmplus-log-export-${const Uuid().v4()}.tmp'),
          );
          await tail.create(exclusive: true);
          tailCreated = true;
          final output = tail.openWrite(mode: FileMode.writeOnlyAppend);
          var suffixFailed = false;
          try {
            var count = 0;
            await for (final bytes in snapshot.openSuffix()) {
              count += bytes.length;
              if (count > 1024 * 1024 + 64 * 1024) {
                throw StateError('日志保留片段超过安全上限');
              }
              output.add(bytes);
            }
            await output.flush();
          } catch (_) {
            suffixFailed = true;
            rethrow;
          } finally {
            try {
              await output.close();
            } catch (error, stack) {
              AppLog.instance.write(
                AppLogLevel.warning,
                'log_export',
                'Closing Android log export fragment failed',
                error: error,
                stackTrace: stack,
                promptUser: false,
              );
              if (!suffixFailed) rethrow;
            }
          }
        }
        final uri = await _invoke<String>('exportLogSnapshot', {
          'sourcePath': snapshot.sourcePath,
          'length': snapshot.length,
          'tailPath': tail?.path,
          'fileName': fileName,
          'warningPrefix': warningPrefix,
        });
        if (uri == null) return null;
        final parsed = Uri.parse(uri);
        if (parsed.scheme != 'content') {
          throw const FormatException('Android 日志导出未返回完整文档 URI');
        }
        return parsed;
      } finally {
        if (tailCreated && tail != null) {
          try {
            await tail.delete();
          } catch (error, stack) {
            AppLog.instance.write(
              AppLogLevel.warning,
              'platform',
              '日志导出临时片段清理失败',
              error: error,
              stackTrace: stack,
              promptUser: false,
            );
          }
        }
      }
    });
  }

  static Future<bool> claimLogUploadPrompt() {
    AppLog.instance.trace(
      "lib/services/android_platform.dart::AndroidPlatform.claimLogUploadPrompt",
    );
    return AppLog.instance.runWithErrorScope(() async {
      AppLog.instance.trace(
        "lib/services/android_platform.dart::AndroidPlatform.claimLogUploadPrompt.closure#1",
      );
      return await _invoke<bool>('claimLogUploadPrompt') ?? false;
    });
  }

  static Future<T?> _invoke<T>(
    String method, [
    Map<String, Object?>? arguments,
    MethodChannel? channel,
  ]) {
    AppLog.instance.trace(
      "lib/services/android_platform.dart::AndroidPlatform._invoke",
    );
    return AppLog.instance.runWithErrorScope(() async {
      AppLog.instance.trace(
        "lib/services/android_platform.dart::AndroidPlatform._invoke.closure#1",
      );

      final targetChannel = channel ?? _channel;
      if (AppLog.instance.level == AppLogLevel.debug) {
        AppLog.instance.write(
          AppLogLevel.debug,
          'platform',
          'MethodChannel call',
          data: {
            'channel': targetChannel.name,
            'method': method,
            'arguments': arguments,
          },
        );
      }
      try {
        final result = await targetChannel.invokeMethod<T>(method, arguments);
        if (AppLog.instance.level == AppLogLevel.debug) {
          AppLog.instance.write(
            AppLogLevel.debug,
            'platform',
            'MethodChannel result',
            data: {
              'channel': targetChannel.name,
              'method': method,
              'result': result,
            },
          );
        }
        return result;
      } catch (error, stack) {
        AppLog.instance.write(
          AppLogLevel.error,
          'platform',
          'MethodChannel failed',
          data: {
            'channel': targetChannel.name,
            'method': method,
            'arguments': arguments,
          },
          error: error,
          stackTrace: stack,
        );
        rethrow;
      }
    });
  }

  static Future<Map<String, String>> mediaToolPaths() {
    AppLog.instance.trace(
      "lib/services/android_platform.dart::AndroidPlatform.mediaToolPaths",
    );
    return AppLog.instance.runWithErrorScope(() async {
      AppLog.instance.trace(
        "lib/services/android_platform.dart::AndroidPlatform.mediaToolPaths.closure#1",
      );

      Map<String, String>? values;
      try {
        values = (await _invoke<Map<dynamic, dynamic>>('mediaToolPaths'))
            ?.cast<String, String>();
      } on PlatformException catch (error, stack) {
        const replacement = XmlyException(
          'media_tool_missing',
          '随附 Android FFmpeg/FFprobe 缺失或不可执行，请重新安装完整安装包',
        );
        AppLog.instance.linkError(replacement, error);
        Error.throwWithStackTrace(replacement, stack);
      }
      final directory = values?['directory'];
      if (directory == null ||
          !p.isAbsolute(directory) ||
          directory.contains('\u0000') ||
          await Directory(directory).resolveSymbolicLinks() != directory) {
        throw const FormatException('Android 媒体工具安装目录无效');
      }
      final tools = <String, String>{};
      for (final name in ['ffmpeg', 'ffprobe']) {
        final path = values?[name];
        if (path == null ||
            !p.isAbsolute(path) ||
            path != p.join(directory, 'libxmplus_$name.so') ||
            await FileSystemEntity.type(path, followLinks: false) !=
                FileSystemEntityType.file ||
            await File(path).resolveSymbolicLinks() != path) {
          throw const FormatException('随附 Android 媒体工具缺失或路径无效');
        }
        tools[name] = path;
      }
      return tools;
    });
  }

  static Future<int> availableBytes(String path) {
    AppLog.instance.trace(
      "lib/services/android_platform.dart::AndroidPlatform.availableBytes",
    );
    return AppLog.instance.runWithErrorScope(() async {
      AppLog.instance.trace(
        "lib/services/android_platform.dart::AndroidPlatform.availableBytes.closure#1",
      );

      final bytes = await _invoke<int>('availableBytes', {'path': path});
      if (bytes == null || bytes < 0) throw const FormatException('无法查询可用空间');
      return bytes;
    });
  }

  /// Runs the Android FUSE no-replace fallback on a native background queue.
  static Future<void> copyNoReplace(String source, String target) {
    AppLog.instance.trace(
      "lib/services/android_platform.dart::AndroidPlatform.copyNoReplace",
    );
    return AppLog.instance.runWithErrorScope(() async {
      AppLog.instance.trace(
        "lib/services/android_platform.dart::AndroidPlatform.copyNoReplace.closure#1",
      );

      try {
        await _invoke<void>('copyNoReplace', {
          'source': source,
          'target': target,
        }, _filesChannel);
      } on PlatformException catch (error, stack) {
        final replacement = XmlyException(
          error.code,
          error.message ?? '文件安全提交失败，源缓存已保留',
        );
        AppLog.instance.linkError(replacement, error);
        Error.throwWithStackTrace(replacement, stack);
      }
    });
  }

  static Future<void> openAudioFile(String path) {
    AppLog.instance.trace(
      "lib/services/android_platform.dart::AndroidPlatform.openAudioFile",
    );
    return _invoke<void>('openAudioFile', {'path': path});
  }
}
