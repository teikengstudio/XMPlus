import 'dart:async';
import 'dart:ui';

import 'package:flutter/widgets.dart' show WidgetsBinding;
import 'package:synchronized/synchronized.dart';
import 'package:window_manager/window_manager.dart';

import 'app_log.dart';

/// Changes only the presentation of the existing window, never the player.
class DesktopPlaybackWindow {
  final _changes = Lock();
  _WindowPlacement? _main;

  bool get isMini {
    AppLog.instance.trace(
      "lib/services/desktop_playback_window.dart::DesktopPlaybackWindow.isMini.get",
    );
    return _main != null;
  }

  Future<void> _normalWindow() async {
    AppLog.instance.trace(
      "lib/services/desktop_playback_window.dart::DesktopPlaybackWindow._normalWindow",
    );

    if (await windowManager.isMinimized()) await windowManager.restore();
    if (await windowManager.isFullScreen()) {
      await windowManager.setFullScreen(false);
    }
    if (await windowManager.isMaximized()) await windowManager.unmaximize();
    for (var attempt = 0; attempt < 50; attempt++) {
      if (!await windowManager.isMinimized() &&
          !await windowManager.isMaximized() &&
          !await windowManager.isFullScreen()) {
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    throw TimeoutException('窗口未能恢复普通大小');
  }

  Future<void> enterMini() {
    AppLog.instance.trace(
      "lib/services/desktop_playback_window.dart::DesktopPlaybackWindow.enterMini",
    );
    return AppLog.instance.runWithErrorScope(() async {
      AppLog.instance.trace(
        "lib/services/desktop_playback_window.dart::DesktopPlaybackWindow.enterMini.closure#1",
      );

      try {
        await _changes.synchronized(() async {
          AppLog.instance.trace(
            "lib/services/desktop_playback_window.dart::DesktopPlaybackWindow.enterMini.closure#1.closure#1",
          );

          if (_main != null) return;
          final saved = _WindowPlacement(
            bounds: await windowManager.getBounds(),
            maximized: await windowManager.isMaximized(),
            fullScreen: await windowManager.isFullScreen(),
            alwaysOnTop: await windowManager.isAlwaysOnTop(),
          );
          _main = saved;
          try {
            await _normalWindow();
            saved.bounds = await windowManager.getBounds();
            await WidgetsBinding.instance.endOfFrame;
            final view = WidgetsBinding.instance.platformDispatcher.views.first;
            // Window bounds include the native resize frame; content needs 90dp.
            final height =
                90 +
                saved.bounds.height -
                view.physicalSize.height / view.devicePixelRatio;
            await windowManager.setMinimumSize(Size(320, height));
            await windowManager.setSize(Size(420, height));
            await windowManager.setAlwaysOnTop(true);
            await windowManager.show();
          } catch (failure, stack) {
            if (!AppLog.instance.errorWasRecorded(failure)) {
              AppLog.instance.write(
                AppLogLevel.error,
                'window',
                'Entering mini playback window failed',
                error: failure,
                stackTrace: stack,
              );
            }
            AppLog.instance.requestUploadPrompt();
            try {
              await _restore(saved);
            } catch (restoreFailure, restoreStack) {
              AppLog.instance.write(
                AppLogLevel.warning,
                'window',
                'Restoring window after mini playback failure failed',
                error: restoreFailure,
                stackTrace: restoreStack,
              );
            } finally {
              _main = null;
            }
            rethrow;
          }
        });
      } catch (failure, stack) {
        if (!AppLog.instance.errorWasRecorded(failure)) {
          AppLog.instance.write(
            AppLogLevel.error,
            'window',
            'Entering mini playback window failed',
            error: failure,
            stackTrace: stack,
          );
        }
        AppLog.instance.requestUploadPrompt();
        rethrow;
      }
    });
  }

  Future<void> restore() {
    AppLog.instance.trace(
      "lib/services/desktop_playback_window.dart::DesktopPlaybackWindow.restore",
    );
    return AppLog.instance.runWithErrorScope(() async {
      AppLog.instance.trace(
        "lib/services/desktop_playback_window.dart::DesktopPlaybackWindow.restore.closure#1",
      );

      try {
        await _changes.synchronized(() async {
          AppLog.instance.trace(
            "lib/services/desktop_playback_window.dart::DesktopPlaybackWindow.restore.closure#1.closure#1",
          );

          final saved = _main;
          if (saved == null) return;
          await _restore(saved);
          _main = null;
        });
      } catch (failure, stack) {
        if (!AppLog.instance.errorWasRecorded(failure)) {
          AppLog.instance.write(
            AppLogLevel.error,
            'window',
            'Restoring playback window failed',
            error: failure,
            stackTrace: stack,
          );
        }
        AppLog.instance.requestUploadPrompt();
        rethrow;
      }
    });
  }

  Future<void> _restore(_WindowPlacement saved) async {
    AppLog.instance.trace(
      "lib/services/desktop_playback_window.dart::DesktopPlaybackWindow._restore",
    );

    await _normalWindow();
    await windowManager.setMinimumSize(const Size(320, 320));
    await windowManager.setBounds(saved.bounds);
    await windowManager.setAlwaysOnTop(saved.alwaysOnTop);
    if (saved.maximized) await windowManager.maximize();
    if (saved.fullScreen) await windowManager.setFullScreen(true);
    await windowManager.show();
    await windowManager.focus();
  }
}

class _WindowPlacement {
  _WindowPlacement({
    required this.bounds,
    required this.maximized,
    required this.fullScreen,
    required this.alwaysOnTop,
  }) {
    AppLog.instance.trace(
      "lib/services/desktop_playback_window.dart::_WindowPlacement.new",
    );
  }

  Rect bounds;
  final bool maximized, fullScreen, alwaysOnTop;
}
