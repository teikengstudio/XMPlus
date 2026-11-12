import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:audio_service_platform_interface/audio_service_platform_interface.dart';
import 'package:flutter/foundation.dart';

import '../models/xmly_models.dart';
import 'album_cache.dart';
import 'app_log.dart';
import 'download_service.dart' show DownloadStopped;
import 'close_sequence.dart';
import 'player_service.dart';
import 'windows_audio_service.dart';

/// A system-control view of PlayerService, never a second player or queue.
class SystemMediaService extends BaseAudioHandler {
  SystemMediaService._(this._player, this._albumCache, this._commandsAllowed) {
    AppLog.instance.trace(
      "lib/services/system_media_service.dart::SystemMediaService._",
    );
  }

  static Future<SystemMediaService> start({
    required PlayerService player,
    required AlbumCache albumCache,
    bool Function()? commandsAllowed,
  }) {
    AppLog.instance.trace(
      "lib/services/system_media_service.dart::SystemMediaService.start",
    );
    return AppLog.instance.runWithErrorScope(() async {
      AppLog.instance.trace(
        "lib/services/system_media_service.dart::SystemMediaService.start.closure#1",
      );

      if (!Platform.isAndroid && !Platform.isWindows) {
        throw UnsupportedError('系统媒体控制仅支持 Android 和 Windows');
      }
      if (Platform.isWindows) WindowsAudioServicePlatform.registerWith();
      final handler = SystemMediaService._(player, albumCache, commandsAllowed);
      await AudioService.init<SystemMediaService>(
        builder: () {
          AppLog.instance.trace(
            "lib/services/system_media_service.dart::SystemMediaService.start.closure#1.closure#1",
          );
          return handler;
        },
        config: const AudioServiceConfig(
          androidNotificationChannelId: 'teikengstudio.xmplus.playback',
          androidNotificationChannelName: '声音播放',
          androidNotificationIcon: 'drawable/ic_media_notification',
          androidNotificationOngoing: false,
          androidStopForegroundOnPause: false,
        ),
      );
      handler._playerEvents = player.changes.listen((_) {
        AppLog.instance.trace(
          "lib/services/system_media_service.dart::SystemMediaService.start.closure#1.closure#2",
        );
        handler._sync();
      });
      albumCache.addListener(handler._sync);
      handler._platformErrors = AudioService.asyncError.listen(
        (failure) {
          AppLog.instance.trace(
            "lib/services/system_media_service.dart::SystemMediaService.start.closure#1.closure#3",
          );
          unawaited(handler._platformError(failure));
        },
        onError: (Object failure, StackTrace stack) {
          AppLog.instance.trace(
            "lib/services/system_media_service.dart::SystemMediaService.start.closure#1.closure#4",
          );

          unawaited(handler._platformError(failure, stack));
        },
      );
      handler._sync();
      return handler;
    });
  }

  final PlayerService _player;
  final AlbumCache _albumCache;
  final bool Function()? _commandsAllowed;
  final Stopwatch _clock = Stopwatch()..start();
  final Set<Future<void>> _pending = {};
  StreamSubscription<void>? _playerEvents;
  StreamSubscription<Object>? _platformErrors;
  late final _closeSteps = CloseSequence([
    () async {
      AppLog.instance.trace(
        "lib/services/system_media_service.dart::SystemMediaService._closeSteps.closure#1",
      );

      _closed = true;
      _albumCache.removeListener(_sync);
    },
    () async {
      AppLog.instance.trace(
        "lib/services/system_media_service.dart::SystemMediaService._closeSteps.closure#2",
      );

      await _playerEvents?.cancel();
    },
    () async {
      AppLog.instance.trace(
        "lib/services/system_media_service.dart::SystemMediaService._closeSteps.closure#3",
      );

      await _platformErrors?.cancel();
    },
    () async {
      AppLog.instance.trace(
        "lib/services/system_media_service.dart::SystemMediaService._closeSteps.closure#4",
      );

      await Future.wait(_pending.toList());
    },
    () async {
      AppLog.instance.trace(
        "lib/services/system_media_service.dart::SystemMediaService._closeSteps.closure#5",
      );

      mediaItem.add(null);
      playbackState.add(PlaybackState());
      _clock.stop();
    },
    () async {
      AppLog.instance.trace(
        "lib/services/system_media_service.dart::SystemMediaService._closeSteps.closure#6",
      );

      await Future.wait([
        playbackState.close(),
        mediaItem.close(),
        queue.close(),
        queueTitle.close(),
        androidPlaybackInfo.close(),
        ratingStyle.close(),
        customEvent.close(),
        customState.close(),
      ]);
    },
    () {
      AppLog.instance.trace(
        "lib/services/system_media_service.dart::SystemMediaService._closeSteps.closure#7",
      );
      return AudioServicePlatform.instance.stopService(
        const StopServiceRequest(),
      );
    },
  ]);
  bool _closed = false, _dismissed = false, _everActive = false;
  Object? _metadataKey, _stateKey;
  String? _commandError, _nativeError;
  int _publishedAt = -1000;
  int _commandRecoveryRevision = 0;

  static Duration _seconds(double seconds) {
    AppLog.instance.trace(
      "lib/services/system_media_service.dart::SystemMediaService._seconds",
    );
    return Duration(
      microseconds: (seconds * Duration.microsecondsPerSecond).round(),
    );
  }

  Future<void> _platformError(Object failure, [StackTrace? sourceStack]) {
    AppLog.instance.trace(
      "lib/services/system_media_service.dart::SystemMediaService._platformError",
    );
    return AppLog.instance.runWithErrorScope(() async {
      AppLog.instance.trace(
        "lib/services/system_media_service.dart::SystemMediaService._platformError.closure#1",
      );

      if (_closed) return;
      final stack =
          sourceStack ?? (failure is Error ? failure.stackTrace : null);
      _nativeError = '系统媒体控制同步失败，请重新启动应用';
      _report(
        failure,
        stack ?? StackTrace.current,
        _nativeError!,
        observerStack: stack == null,
      );
      _sync();
    });
  }

  void _report(
    Object failure,
    StackTrace stack,
    String message, {
    bool observerStack = false,
  }) {
    AppLog.instance.trace(
      "lib/services/system_media_service.dart::SystemMediaService._report",
    );

    final expected =
        failure is DownloadStopped ||
        failure is ArgumentError ||
        failure is FormatException ||
        failure is XmlyException &&
            const {
              'cancelled',
              'download_stopped',
              'request_cancelled',
              'client_closed',
              'login_required',
              'login_expired',
              'auth_required',
              'confirmation_required',
              'confirmation_changed',
              'usage_uncertain',
              'insufficient_quota',
              'invalid_album',
              'invalid_page',
              'invalid_feed',
              'missing_track',
              'catalogue_limit',
              'duplicate_page',
              'catalogue_changed',
              'queue_full',
            }.contains(failure.code);
    if (!AppLog.instance.errorWasRecorded(failure)) {
      AppLog.instance.write(
        expected ? AppLogLevel.warning : AppLogLevel.error,
        'system_media_service',
        message,
        data: {'stackTraceSource': observerStack ? 'observer' : 'source'},
        error: failure,
        stackTrace: stack,
      );
    }
    if (!expected) AppLog.instance.requestUploadPrompt();
    if (!_closed) {
      try {
        customEvent.add({'type': 'systemMediaError', 'message': message});
      } catch (reportFailure, reportStack) {
        AppLog.instance.write(
          AppLogLevel.warning,
          'system_media_service',
          'Publishing system media failure failed',
          error: reportFailure,
          stackTrace: reportStack,
        );
      }
    }
    try {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: failure,
          stack: stack,
          library: 'system_media_service',
          context: ErrorDescription(message),
          silent: expected,
        ),
      );
    } catch (reportFailure, reportStack) {
      AppLog.instance.write(
        AppLogLevel.warning,
        'system_media_service',
        'Reporting system media failure to Flutter failed',
        error: reportFailure,
        stackTrace: reportStack,
      );
    }
  }

  void _sync() {
    AppLog.instance.trace(
      "lib/services/system_media_service.dart::SystemMediaService._sync",
    );

    if (_closed) return;
    final track = _player.current;
    final hasSource = _player.sourceKind.isNotEmpty;
    if (hasSource || _player.loading) {
      _dismissed = false;
      _everActive = true;
    }
    if (_commandError != null &&
        !_player.loading &&
        hasSource &&
        _player.error == null &&
        _player.playbackRecoveryRevision != _commandRecoveryRevision) {
      _commandError = null;
    }
    final error = _nativeError ?? _commandError ?? _player.error;
    final active =
        track != null &&
        !_dismissed &&
        (hasSource || _player.loading || (_everActive && error != null));
    final seconds = active
        ? (_player.loading || _player.duration <= 0
              ? track.duration
              : _player.duration)
        : 0.0;
    final duration = seconds.isFinite && seconds > 0 ? _seconds(seconds) : null;
    final cached = active && track.albumId.isNotEmpty
        ? _albumCache[track.albumId]
        : null;
    final metadataKey = (active ? track : null, cached, duration);
    if (_metadataKey != metadataKey) {
      _metadataKey = metadataKey;
      if (!active) {
        mediaItem.add(null);
      } else {
        Track? observed;
        for (final candidate in cached?.tracks ?? const <Track>[]) {
          if (candidate.id == track.id) {
            observed = candidate;
            break;
          }
        }
        final title = track.title.isNotEmpty
            ? track.title
            : observed?.title ?? '';
        final artist = track.artist.isNotEmpty
            ? track.artist
            : observed?.artist.isNotEmpty == true
            ? observed!.artist
            : cached?.album.artist ?? '';
        final album = track.album.isNotEmpty
            ? track.album
            : observed?.album.isNotEmpty == true
            ? observed!.album
            : cached?.album.title ?? '';
        // AlbumCache has already validated this local image. Never fetch artwork
        // or private playback URLs here; null also clears the previous cover.
        mediaItem.add(
          MediaItem(
            id: track.id,
            title: title.isEmpty ? '声音 ${track.number}' : title,
            artist: artist,
            album: album,
            duration: duration,
            artUri: cached?.coverPath == null
                ? null
                : Uri.file(cached!.coverPath!),
          ),
        );
      }
    }

    final processing = !active
        ? AudioProcessingState.idle
        : error != null
        ? AudioProcessingState.error
        : _player.loading
        ? AudioProcessingState.loading
        : _player.buffering
        ? AudioProcessingState.buffering
        : AudioProcessingState.ready;
    final playing = active && error == null && _player.playing;
    final speed = _player.rate.isFinite && _player.rate > 0
        ? _player.rate
        : 1.0;
    final stateKey = (
      processing,
      playing,
      speed,
      error,
      active ? track.id : null,
      duration,
      _player.seekRevision,
    );
    final now = _clock.elapsedMilliseconds;
    if (_stateKey == stateKey && (!playing || now - _publishedAt < 1000))
      return;
    _stateKey = stateKey;
    _publishedAt = now;
    var position = active && _player.position.isFinite
        ? _player.position.clamp(0.0, double.infinity).toDouble()
        : 0.0;
    if (duration != null) position = position.clamp(0.0, seconds).toDouble();
    playbackState.add(
      PlaybackState(
        processingState: processing,
        playing: playing,
        updatePosition: _seconds(position),
        speed: speed,
        controls: active
            ? [
                MediaControl.skipToPrevious,
                playing ? MediaControl.pause : MediaControl.play,
                MediaControl.skipToNext,
                MediaControl.rewind,
                MediaControl.fastForward,
                MediaControl.stop,
              ]
            : const [],
        androidCompactActionIndices: active ? const [0, 1, 2] : null,
        systemActions: active ? const {MediaAction.seek} : const {},
        errorCode: active && error != null ? 1 : null,
        errorMessage: active ? error : null,
      ),
    );
  }

  Future<void> _command(Future<void> Function() action) {
    AppLog.instance.trace(
      "lib/services/system_media_service.dart::SystemMediaService._command",
    );
    return AppLog.instance.runWithErrorScope(() async {
      AppLog.instance.trace(
        "lib/services/system_media_service.dart::SystemMediaService._command.closure#1",
      );

      if (!(_commandsAllowed?.call() ?? true)) return;
      if (_closed) throw StateError('系统媒体控制已关闭');
      final finished = Completer<void>();
      _pending.add(finished.future);
      _commandError = null;
      var actionFailed = false;
      try {
        await action();
      } catch (failure, stack) {
        actionFailed = true;
        if (!_closed) {
          _commandError = _player.error ?? '系统播放操作失败，请在应用内重试';
          _commandRecoveryRevision = _player.playbackRecoveryRevision;
          _report(failure, stack, _commandError!);
        }
        rethrow;
      } finally {
        _pending.remove(finished.future);
        finished.complete();
        try {
          _sync();
        } catch (failure, stack) {
          if (actionFailed) {
            AppLog.instance.write(
              AppLogLevel.warning,
              'system_media_service',
              'Synchronizing system media after command failure failed',
              error: failure,
              stackTrace: stack,
            );
          } else {
            if (!AppLog.instance.errorWasRecorded(failure)) {
              AppLog.instance.write(
                AppLogLevel.error,
                'system_media_service',
                'Synchronizing system media after command failed',
                error: failure,
                stackTrace: stack,
              );
            }
            AppLog.instance.requestUploadPrompt();
            rethrow;
          }
        }
      }
    });
  }

  @override
  Future<void> play() {
    AppLog.instance.trace(
      "lib/services/system_media_service.dart::SystemMediaService.play",
    );
    return _command(_player.resume);
  }

  @override
  Future<void> pause() {
    AppLog.instance.trace(
      "lib/services/system_media_service.dart::SystemMediaService.pause",
    );
    return _command(_player.pause);
  }

  @override
  Future<void> stop() {
    AppLog.instance.trace(
      "lib/services/system_media_service.dart::SystemMediaService.stop",
    );
    return _command(() async {
      AppLog.instance.trace(
        "lib/services/system_media_service.dart::SystemMediaService.stop.closure#1",
      );

      await _player.quiesce();
      _dismissed = true;
      _everActive = false;
    });
  }

  @override
  Future<void> skipToPrevious() {
    AppLog.instance.trace(
      "lib/services/system_media_service.dart::SystemMediaService.skipToPrevious",
    );
    return _command(_player.previous);
  }

  @override
  Future<void> skipToNext() {
    AppLog.instance.trace(
      "lib/services/system_media_service.dart::SystemMediaService.skipToNext",
    );
    return _command(_player.next);
  }

  @override
  Future<void> seek(Duration position) {
    AppLog.instance.trace(
      "lib/services/system_media_service.dart::SystemMediaService.seek",
    );
    return _command(() async {
      AppLog.instance.trace(
        "lib/services/system_media_service.dart::SystemMediaService.seek.closure#1",
      );

      final seconds = position.inMicroseconds / Duration.microsecondsPerSecond;
      if (!seconds.isFinite)
        throw ArgumentError.value(position, 'position', '播放位置无效');
      final duration = _player.duration;
      await _player.seek(
        seconds
            .clamp(
              0.0,
              duration.isFinite && duration > 0 ? duration : double.infinity,
            )
            .toDouble(),
      );
    });
  }

  @override
  Future<void> fastForward() {
    AppLog.instance.trace(
      "lib/services/system_media_service.dart::SystemMediaService.fastForward",
    );
    return _command(_player.seekForward);
  }

  @override
  Future<void> rewind() {
    AppLog.instance.trace(
      "lib/services/system_media_service.dart::SystemMediaService.rewind",
    );
    return _command(_player.seekBackward);
  }

  /// The runtime quiesces PlayerService before closing this projection.
  // Drain state streams before the native stop. If it fails, retry only that
  // stop; publishing to or closing the completed streams must not run again.
  Future<void> close() {
    AppLog.instance.trace(
      "lib/services/system_media_service.dart::SystemMediaService.close",
    );
    return AppLog.instance.runWithErrorScope(_closeSteps.run);
  }
}
