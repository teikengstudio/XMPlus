import 'dart:io';

import 'package:audio_service_platform_interface/audio_service_platform_interface.dart';
import 'package:flutter/services.dart';

import 'app_log.dart';

/// Windows SMTC transport only; playback remains in the application's handler.
class WindowsAudioServicePlatform extends AudioServicePlatform {
  static const _channel = MethodChannel('xmplus/system_media');

  AudioHandlerCallbacks? _callbacks;
  PlaybackStateMessage? _state;
  MediaItemMessage? _mediaItem;
  List<MediaItemMessage> _queue = const [];

  static void registerWith() {
    AppLog.instance.trace(
      "lib/services/windows_audio_service.dart::WindowsAudioServicePlatform.registerWith",
    );

    AudioServicePlatform.instance = WindowsAudioServicePlatform();
  }

  @override
  Future<void> configure(ConfigureRequest request) {
    AppLog.instance.trace(
      "lib/services/windows_audio_service.dart::WindowsAudioServicePlatform.configure",
    );
    return _invoke('configure');
  }

  @override
  void setHandlerCallbacks(AudioHandlerCallbacks callbacks) {
    AppLog.instance.trace(
      "lib/services/windows_audio_service.dart::WindowsAudioServicePlatform.setHandlerCallbacks",
    );

    _callbacks = callbacks;
    _channel.setMethodCallHandler(_receiveMethodCall);
  }

  void _channelEvent(
    String message,
    String method, {
    Object? arguments,
    Object? result,
  }) {
    AppLog.instance.trace(
      "lib/services/windows_audio_service.dart::WindowsAudioServicePlatform._channelEvent",
    );

    if (AppLog.instance.level != AppLogLevel.debug) return;
    AppLog.instance.write(
      AppLogLevel.debug,
      'platform',
      message,
      data: {
        'channel': _channel.name,
        'method': method,
        'arguments': arguments,
        'result': result,
      },
    );
  }

  void _channelFailure(
    String method,
    Object? arguments,
    Object error,
    StackTrace stack,
  ) {
    AppLog.instance.trace(
      "lib/services/windows_audio_service.dart::WindowsAudioServicePlatform._channelFailure",
    );

    AppLog.instance.write(
      AppLogLevel.error,
      'platform',
      'MethodChannel failed',
      data: {
        'channel': _channel.name,
        'method': method,
        'arguments': arguments,
      },
      error: error,
      stackTrace: stack,
    );
  }

  Future<void> _invoke(String method, [Map<String, Object?>? arguments]) async {
    AppLog.instance.trace(
      "lib/services/windows_audio_service.dart::WindowsAudioServicePlatform._invoke",
    );

    _channelEvent('MethodChannel call', method, arguments: arguments);
    try {
      await _channel.invokeMethod<void>(method, arguments);
      _channelEvent('MethodChannel result', method, result: null);
    } catch (error, stack) {
      _channelFailure(method, arguments, error, stack);
      rethrow;
    }
  }

  Future<void> _receiveMethodCall(MethodCall call) async {
    AppLog.instance.trace(
      "lib/services/windows_audio_service.dart::WindowsAudioServicePlatform._receiveMethodCall",
    );

    _channelEvent(
      'MethodChannel incoming call',
      call.method,
      arguments: call.arguments,
    );
    try {
      await _onMethodCall(call);
      _channelEvent('MethodChannel incoming result', call.method, result: null);
    } catch (error, stack) {
      _channelFailure(call.method, call.arguments, error, stack);
      rethrow;
    }
  }

  Future<void> _onMethodCall(MethodCall call) async {
    AppLog.instance.trace(
      "lib/services/windows_audio_service.dart::WindowsAudioServicePlatform._onMethodCall",
    );

    final callbacks = _callbacks;
    if (callbacks == null) return;
    switch (call.method) {
      case 'play':
        await callbacks.play(const PlayRequest());
        break;
      case 'pause':
        await callbacks.pause(const PauseRequest());
        break;
      case 'stop':
        await callbacks.stop(const StopRequest());
        break;
      case 'skipToNext':
        await callbacks.skipToNext(const SkipToNextRequest());
        break;
      case 'skipToPrevious':
        await callbacks.skipToPrevious(const SkipToPreviousRequest());
        break;
      case 'fastForward':
        await callbacks.fastForward(const FastForwardRequest());
        break;
      case 'rewind':
        await callbacks.rewind(const RewindRequest());
        break;
      case 'seek':
        final arguments = Map<Object?, Object?>.from(call.arguments as Map);
        await callbacks.seek(
          SeekRequest(
            position: Duration(microseconds: arguments['position'] as int),
          ),
        );
        break;
      case 'setSpeed':
        final arguments = Map<Object?, Object?>.from(call.arguments as Map);
        await callbacks.setSpeed(
          SetSpeedRequest(speed: (arguments['speed'] as num).toDouble()),
        );
        break;
      default:
        throw MissingPluginException('Unknown SMTC event ${call.method}');
    }
  }

  @override
  Future<void> setState(SetStateRequest request) {
    AppLog.instance.trace(
      "lib/services/windows_audio_service.dart::WindowsAudioServicePlatform.setState",
    );

    _state = request.state;
    return _publish();
  }

  @override
  Future<void> setMediaItem(SetMediaItemRequest request) {
    AppLog.instance.trace(
      "lib/services/windows_audio_service.dart::WindowsAudioServicePlatform.setMediaItem",
    );

    _mediaItem = request.mediaItem;
    return _publish();
  }

  @override
  Future<void> setQueue(SetQueueRequest request) {
    AppLog.instance.trace(
      "lib/services/windows_audio_service.dart::WindowsAudioServicePlatform.setQueue",
    );

    // SMTC has no queue browser. Retain it for handlers publishing queueIndex
    // before their first mediaItem; never expose ids or playback URLs to Windows.
    _queue = request.queue;
    return _publish();
  }

  Future<void> _publish() {
    AppLog.instance.trace(
      "lib/services/windows_audio_service.dart::WindowsAudioServicePlatform._publish",
    );

    final state = _state;
    final index = state?.queueIndex;
    final item =
        _mediaItem ??
        (index != null && index >= 0 && index < _queue.length
            ? _queue[index]
            : null);
    final processing = state?.processingState;
    final status = switch (processing) {
      null || AudioProcessingStateMessage.idle => 'idle',
      AudioProcessingStateMessage.completed ||
      AudioProcessingStateMessage.error => 'stopped',
      AudioProcessingStateMessage.loading ||
      AudioProcessingStateMessage.buffering => 'changing',
      AudioProcessingStateMessage.ready =>
        state!.playing ? 'playing' : 'paused',
    };
    var position = state?.updatePosition.inMicroseconds ?? 0;
    final speed = state?.speed ?? 1.0;
    if (status == 'playing' && speed.isFinite && speed >= 0) {
      final elapsed = DateTime.now()
          .difference(state!.updateTime)
          .inMicroseconds;
      if (elapsed > 0) position += (elapsed * speed).round();
    }
    final actions = <MediaActionMessage>{
      ...?state?.systemActions,
      ...?state?.controls.map((control) {
        AppLog.instance.trace(
          "lib/services/windows_audio_service.dart::WindowsAudioServicePlatform._publish.closure#1",
        );
        return control.action;
      }),
    };
    return _invoke('update', <String, Object?>{
      'title': item?.displayTitle ?? item?.title ?? '',
      'artist': item?.artist ?? '',
      'album': item?.album ?? '',
      'artwork': _artwork(item),
      'duration': item?.duration?.inMicroseconds ?? 0,
      'position': position,
      'status': status,
      'speed': speed.isFinite && speed >= 0 ? speed : 1.0,
      'actions': actions.map((action) {
        AppLog.instance.trace(
          "lib/services/windows_audio_service.dart::WindowsAudioServicePlatform._publish.closure#2",
        );
        return action.name;
      }).toList(),
    });
  }

  Map<String, String>? _artwork(MediaItemMessage? item) {
    AppLog.instance.trace(
      "lib/services/windows_audio_service.dart::WindowsAudioServicePlatform._artwork",
    );

    final cachePath = item?.extras?['artCacheFile'];
    if (cachePath is String &&
        cachePath.isNotEmpty &&
        !cachePath.startsWith(r'\\') &&
        File(cachePath).isAbsolute) {
      return {'kind': 'file', 'value': cachePath};
    }
    final uri = item?.artUri;
    if (uri == null || uri.userInfo.isNotEmpty) return null;
    if ((uri.scheme == 'http' || uri.scheme == 'https') &&
        uri.host.isNotEmpty) {
      return {'kind': 'uri', 'value': uri.toString()};
    }
    if (uri.scheme == 'file' &&
        uri.host.isEmpty &&
        uri.hasAbsolutePath &&
        !uri.hasQuery &&
        !uri.hasFragment) {
      try {
        return {'kind': 'file', 'value': uri.toFilePath(windows: true)};
      } on UnsupportedError {
        return null;
      } on ArgumentError {
        return null;
      }
    }
    return null;
  }

  @override
  Future<void> stopService(StopServiceRequest request) {
    AppLog.instance.trace(
      "lib/services/windows_audio_service.dart::WindowsAudioServicePlatform.stopService",
    );

    _state = null;
    _mediaItem = null;
    _queue = const [];
    return _invoke('stopService');
  }

  /// Removes native event subscriptions before replacing this adapter.
  Future<void> dispose() async {
    AppLog.instance.trace(
      "lib/services/windows_audio_service.dart::WindowsAudioServicePlatform.dispose",
    );

    await _invoke('dispose');
    _channel.setMethodCallHandler(null);
    _callbacks = null;
    _state = null;
    _mediaItem = null;
    _queue = const [];
  }

  // These are Android-only settings/browser notifications, not SMTC features.
  // audio_service sends AndroidPlaybackInfo even on desktop during init.
  @override
  Future<void> setAndroidPlaybackInfo(
    SetAndroidPlaybackInfoRequest request,
  ) async {
    AppLog.instance.trace(
      "lib/services/windows_audio_service.dart::WindowsAudioServicePlatform.setAndroidPlaybackInfo",
    );
  }

  @override
  Future<void> androidForceEnableMediaButtons(
    AndroidForceEnableMediaButtonsRequest request,
  ) async {
    AppLog.instance.trace(
      "lib/services/windows_audio_service.dart::WindowsAudioServicePlatform.androidForceEnableMediaButtons",
    );
  }

  @override
  Future<void> notifyChildrenChanged(
    NotifyChildrenChangedRequest request,
  ) async {
    AppLog.instance.trace(
      "lib/services/windows_audio_service.dart::WindowsAudioServicePlatform.notifyChildrenChanged",
    );
  }
}
