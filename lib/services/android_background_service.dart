import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'app_log.dart';
import 'download_service.dart';
import 'close_sequence.dart';

/// Android only: exposes existing workers to the OS, without owning a queue.
class AndroidBackgroundService with WidgetsBindingObserver {
  AndroidBackgroundService._(this._downloads) {
    AppLog.instance.trace(
      "lib/services/android_background_service.dart::AndroidBackgroundService._",
    );
  }

  static const _channel = MethodChannel(
    'teikengstudio.xmplus/download_background',
  );
  static final error = ValueNotifier<String?>(null);

  static Future<AndroidBackgroundService> start(DownloadService downloads) {
    AppLog.instance.trace(
      "lib/services/android_background_service.dart::AndroidBackgroundService.start",
    );
    return AppLog.instance.runWithErrorScope(() async {
      AppLog.instance.trace(
        "lib/services/android_background_service.dart::AndroidBackgroundService.start.closure#1",
      );

      if (!Platform.isAndroid) throw UnsupportedError('仅支持 Android 后台下载');
      final service = AndroidBackgroundService._(downloads);
      _channel.setMethodCallHandler(service._receiveNativeEvent);
      WidgetsBinding.instance.addObserver(service);
      service._subscription = downloads.changes.listen((_) {
        AppLog.instance.trace(
          "lib/services/android_background_service.dart::AndroidBackgroundService.start.closure#1.closure#1",
        );
        service._observe();
      });
      service._observe();
      await service._queue;
      return service;
    });
  }

  static Future<bool> batteryOptimizationExempt() {
    AppLog.instance.trace(
      "lib/services/android_background_service.dart::AndroidBackgroundService.batteryOptimizationExempt",
    );
    return AppLog.instance.runWithErrorScope(() async {
      AppLog.instance.trace(
        "lib/services/android_background_service.dart::AndroidBackgroundService.batteryOptimizationExempt.closure#1",
      );
      return await _invoke<bool>('batteryOptimizationExempt') ?? false;
    });
  }

  /// Only call from an explicit user action; never request during startup.
  static Future<void> requestBatteryOptimizationExemption() {
    AppLog.instance.trace(
      "lib/services/android_background_service.dart::AndroidBackgroundService.requestBatteryOptimizationExemption",
    );
    return _invoke<void>('requestBatteryOptimizationExemption');
  }

  static void _channelEvent(
    String message,
    String method, {
    Object? arguments,
    Object? result,
  }) {
    AppLog.instance.trace(
      "lib/services/android_background_service.dart::AndroidBackgroundService._channelEvent",
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

  static void _channelFailure(
    String method,
    Object? arguments,
    Object failure,
    StackTrace stack,
  ) {
    AppLog.instance.trace(
      "lib/services/android_background_service.dart::AndroidBackgroundService._channelFailure",
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
      error: failure,
      stackTrace: stack,
    );
  }

  static Future<T?> _invoke<T>(
    String method, [
    Map<String, Object?>? arguments,
  ]) {
    AppLog.instance.trace(
      "lib/services/android_background_service.dart::AndroidBackgroundService._invoke",
    );
    return AppLog.instance.runWithErrorScope(() async {
      AppLog.instance.trace(
        "lib/services/android_background_service.dart::AndroidBackgroundService._invoke.closure#1",
      );

      _channelEvent('MethodChannel call', method, arguments: arguments);
      try {
        final result = await _channel.invokeMethod<T>(method, arguments);
        _channelEvent('MethodChannel result', method, result: result);
        return result;
      } catch (failure, stack) {
        _channelFailure(method, arguments, failure, stack);
        rethrow;
      }
    });
  }

  Future<void> _receiveNativeEvent(MethodCall call) {
    AppLog.instance.trace(
      "lib/services/android_background_service.dart::AndroidBackgroundService._receiveNativeEvent",
    );
    return AppLog.instance.runWithErrorScope(() async {
      AppLog.instance.trace(
        "lib/services/android_background_service.dart::AndroidBackgroundService._receiveNativeEvent.closure#1",
      );

      _channelEvent(
        'MethodChannel incoming call',
        call.method,
        arguments: call.arguments,
      );
      try {
        await _nativeEvent(call);
        _channelEvent(
          'MethodChannel incoming result',
          call.method,
          result: null,
        );
      } catch (failure, stack) {
        if (!AppLog.instance.errorWasRecorded(failure)) {
          _channelFailure(call.method, call.arguments, failure, stack);
        }
        AppLog.instance.requestUploadPrompt();
        rethrow;
      }
    });
  }

  final DownloadService _downloads;
  final Stopwatch _clock = Stopwatch()..start();
  StreamSubscription<void>? _subscription;
  Timer? _progressTimer;
  Future<void> _queue = Future<void>.value();
  late final _closeSteps = CloseSequence([
    () async {
      AppLog.instance.trace(
        "lib/services/android_background_service.dart::AndroidBackgroundService._closeSteps.closure#1",
      );

      _closed = true;
      WidgetsBinding.instance.removeObserver(this);
      _progressTimer?.cancel();
    },
    () async {
      AppLog.instance.trace(
        "lib/services/android_background_service.dart::AndroidBackgroundService._closeSteps.closure#2",
      );

      await _subscription?.cancel();
    },
    () {
      AppLog.instance.trace(
        "lib/services/android_background_service.dart::AndroidBackgroundService._closeSteps.closure#3",
      );
      return _queue;
    },
    () async {
      AppLog.instance.trace(
        "lib/services/android_background_service.dart::AndroidBackgroundService._closeSteps.closure#4",
      );

      _channel.setMethodCallHandler(null);
    },
    _stop,
  ]);
  bool _closed = false, _queued = false, _started = false;
  bool _askedPermission = false, _permission = false;
  bool _failed = false, _timedOut = false;
  String? _stateKey, _publishedState;
  int _publishedAt = -1000;

  List<DownloadTask> get _active {
    AppLog.instance.trace(
      "lib/services/android_background_service.dart::AndroidBackgroundService._active.get",
    );
    return _downloads.tasks
        .where((task) {
          AppLog.instance.trace(
            "lib/services/android_background_service.dart::AndroidBackgroundService._active.get.closure#1",
          );
          return task.state == DownloadState.downloading ||
              task.state == DownloadState.processing;
        })
        .toList(growable: false);
  }

  void _observe() {
    AppLog.instance.trace(
      "lib/services/android_background_service.dart::AndroidBackgroundService._observe",
    );

    if (_closed) return;
    final key = _active
        .map((task) {
          AppLog.instance.trace(
            "lib/services/android_background_service.dart::AndroidBackgroundService._observe.closure#1",
          );
          return '${task.id}:${task.state.name}';
        })
        .join('|');
    if (key != _stateKey) {
      _stateKey = key;
      _progressTimer?.cancel();
      _progressTimer = null;
      _enqueue();
      return;
    }
    if (key.isEmpty || _failed || _timedOut) return;
    final remaining = 1000 - (_clock.elapsedMilliseconds - _publishedAt);
    if (remaining <= 0) {
      _enqueue();
    } else {
      _progressTimer ??= Timer(Duration(milliseconds: remaining), () {
        AppLog.instance.trace(
          "lib/services/android_background_service.dart::AndroidBackgroundService._observe.closure#2",
        );

        _progressTimer = null;
        _enqueue();
      });
    }
  }

  void _enqueue() {
    AppLog.instance.trace(
      "lib/services/android_background_service.dart::AndroidBackgroundService._enqueue",
    );

    if (_closed || _queued) return;
    _queued = true;
    // Read the latest tasks only when this operation runs. Native start, update,
    // and stop always finish in order, including a pending permission dialog.
    _queue = _queue.then((_) async {
      AppLog.instance.trace(
        "lib/services/android_background_service.dart::AndroidBackgroundService._enqueue.closure#1",
      );

      _queued = false;
      if (!_closed) await _sync();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    AppLog.instance.trace(
      "lib/services/android_background_service.dart::AndroidBackgroundService.didChangeAppLifecycleState",
    );

    if (state == AppLifecycleState.resumed && !_closed) {
      _failed = false;
      _permission = false; // Re-read permission changed in Android settings.
      _enqueue();
    }
  }

  Future<void> _sync() {
    AppLog.instance.trace(
      "lib/services/android_background_service.dart::AndroidBackgroundService._sync",
    );
    return AppLog.instance.runWithErrorScope(() async {
      AppLog.instance.trace(
        "lib/services/android_background_service.dart::AndroidBackgroundService._sync.closure#1",
      );

      try {
        var tasks = _active;
        if (tasks.isEmpty) {
          _failed = false;
          _timedOut = false;
          await _stop();
          return;
        }
        if (_failed || _timedOut) return;
        if (!_permission) {
          final foreground =
              WidgetsBinding.instance.lifecycleState ==
              AppLifecycleState.resumed;
          _permission =
              await _invoke<bool>('downloadNotificationPermission', {
                'request': foreground && !_askedPermission,
              }) ??
              false;
          if (foreground) _askedPermission = true;
          if (_closed) return;
          tasks = _active; // The user may have paused during the system dialog.
          if (tasks.isEmpty) {
            await _stop();
            return;
          }
          if (!_permission) {
            _failed = true;
            await _stop();
            await _report('下载通知未授权，后台下载保活未启用，下载可能被系统中断；前台下载不受影响。请在系统设置中允许通知。');
            return;
          }
        }
        if (_timedOut) return;
        final state = tasks
            .map((task) {
              AppLog.instance.trace(
                "lib/services/android_background_service.dart::AndroidBackgroundService._sync.closure#1.closure#1",
              );
              return '${task.id}:${task.state.name}';
            })
            .join('|');
        final remaining = 1000 - (_clock.elapsedMilliseconds - _publishedAt);
        if (_started && state == _publishedState && remaining > 0) {
          _progressTimer ??= Timer(Duration(milliseconds: remaining), () {
            AppLog.instance.trace(
              "lib/services/android_background_service.dart::AndroidBackgroundService._sync.closure#1.closure#2",
            );

            _progressTimer = null;
            _enqueue();
          });
          return;
        }
        final processing = tasks.any((task) {
          AppLog.instance.trace(
            "lib/services/android_background_service.dart::AndroidBackgroundService._sync.closure#1.closure#3",
          );
          return task.state == DownloadState.processing;
        });
        var received = 0;
        var total = 0;
        var knownTotal = true;
        var speed = 0.0;
        for (final task in tasks) {
          received += task.receivedBytes;
          speed += task.bytesPerSecond;
          if (task.totalBytes == null || task.totalBytes! <= 0) {
            knownTotal = false;
          } else {
            total += task.totalBytes!;
          }
        }
        final title = tasks.length == 1
            ? '${processing ? '正在处理' : '正在下载'} · ${tasks.first.track.title}'
            : '正在下载/处理 ${tasks.length} 个文件';
        final progress = knownTotal
            ? '${_bytes(received)} / ${_bytes(total)}'
            : _bytes(received);
        await _invoke<void>('downloadForeground', {
          'title': title,
          'text': processing
              ? '$progress · 正在处理文件'
              : '$progress · ${_bytes(speed.round())}/s',
          'receivedBytes': received,
          'totalBytes': knownTotal ? total : null,
        });
        if (_closed || _timedOut || _active.isEmpty) {
          await _stop();
          return;
        }
        _publishedState = state;
        _started = true;
        _publishedAt = _clock.elapsedMilliseconds;
        error.value = null;
      } catch (failure, stack) {
        if (!AppLog.instance.errorWasRecorded(failure)) {
          AppLog.instance.write(
            AppLogLevel.error,
            'android_background_service',
            'Synchronizing download foreground service failed',
            error: failure,
            stackTrace: stack,
          );
        }
        AppLog.instance.requestUploadPrompt();
        _failed = true;
        error.value = '下载后台服务不可用，请保持应用在前台：$failure';
        FlutterError.reportError(
          FlutterErrorDetails(
            exception: failure,
            stack: stack,
            library: 'android_background_service',
            context: ErrorDescription('同步 Android 下载前台服务失败'),
          ),
        );
        // Native startup rejection already displays a toast. Other platform errors
        // are surfaced too, rather than pretending a background service exists.
        try {
          await _stop();
          await _report(error.value!);
        } catch (reportFailure, reportStack) {
          AppLog.instance.write(
            AppLogLevel.warning,
            'android_background_service',
            'Recovering failed download foreground service failed',
            error: reportFailure,
            stackTrace: reportStack,
          );
          FlutterError.reportError(
            FlutterErrorDetails(
              exception: reportFailure,
              stack: reportStack,
              library: 'android_background_service',
            ),
          );
        }
      }
    });
  }

  static String _bytes(int value) {
    AppLog.instance.trace(
      "lib/services/android_background_service.dart::AndroidBackgroundService._bytes",
    );

    if (value < 1024) return '$value B';
    if (value < 1024 * 1024) return '${(value / 1024).toStringAsFixed(1)} KiB';
    return '${(value / (1024 * 1024)).toStringAsFixed(1)} MiB';
  }

  static Future<void> _report(String message) {
    AppLog.instance.trace(
      "lib/services/android_background_service.dart::AndroidBackgroundService._report",
    );
    return AppLog.instance.runWithErrorScope(() async {
      AppLog.instance.trace(
        "lib/services/android_background_service.dart::AndroidBackgroundService._report.closure#1",
      );

      error.value = message;
      await _invoke<void>('showDownloadBackgroundError', {'message': message});
    });
  }

  Future<void> _nativeEvent(MethodCall call) {
    AppLog.instance.trace(
      "lib/services/android_background_service.dart::AndroidBackgroundService._nativeEvent",
    );
    return AppLog.instance.runWithErrorScope(() async {
      AppLog.instance.trace(
        "lib/services/android_background_service.dart::AndroidBackgroundService._nativeEvent.closure#1",
      );

      if (_closed || call.method != 'downloadServiceTimeout') return;
      _timedOut = true;
      _started = false;
      error.value = '系统后台下载时限已到，下载已暂停；请返回应用后手动继续。电池优化豁免不能取消系统时限。';
      try {
        await _downloads.pauseAll();
      } catch (failure, stack) {
        if (!AppLog.instance.errorWasRecorded(failure)) {
          AppLog.instance.write(
            AppLogLevel.error,
            'platform',
            'Download timeout handling failed',
            data: {'channel': _channel.name, 'method': call.method},
            error: failure,
            stackTrace: stack,
          );
        }
        AppLog.instance.requestUploadPrompt();
        FlutterError.reportError(
          FlutterErrorDetails(
            exception: failure,
            stack: stack,
            library: 'android_background_service',
            context: ErrorDescription('系统下载时限到期后暂停下载失败'),
          ),
        );
        try {
          await _report('系统后台下载时限已到，但暂停下载失败，请立即返回应用手动暂停。');
        } catch (reportFailure, reportStack) {
          AppLog.instance.write(
            AppLogLevel.warning,
            'android_background_service',
            'Reporting download timeout recovery failure failed',
            error: reportFailure,
            stackTrace: reportStack,
          );
        }
      }
    });
  }

  Future<void> _stop() {
    AppLog.instance.trace(
      "lib/services/android_background_service.dart::AndroidBackgroundService._stop",
    );
    return AppLog.instance.runWithErrorScope(() async {
      AppLog.instance.trace(
        "lib/services/android_background_service.dart::AndroidBackgroundService._stop.closure#1",
      );

      // Also stop an orphaned native presenter on initial synchronization/close.
      await _invoke<void>('stopDownloadForeground');
      _started = false;
      _publishedState = null;
    });
  }

  Future<void> close() {
    AppLog.instance.trace(
      "lib/services/android_background_service.dart::AndroidBackgroundService.close",
    );
    return AppLog.instance.runWithErrorScope(_closeSteps.run);
  }
}
