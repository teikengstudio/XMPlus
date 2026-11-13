// Adapted from PiliPlus lib/main.dart::MyApp, commit
// d9e9626f1a3f89cd9ca85e18f61aaba02634e12a (GNU GPL v3).
// Source: https://github.com/bggRGjQaUbCoE/PiliPlus
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:get/get.dart';
import 'package:synchronized/synchronized.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:window_manager/window_manager.dart';

import 'common/theme.dart';
import 'common/widgets/scroll_behavior.dart';
import 'common/widgets/app_shutdown_overlay.dart';
import 'common/widgets/log_upload_prompt_host.dart';
import 'pages/shell_page.dart';
import 'pages/download_page.dart';
import 'pages/player_panel.dart';
import 'pages/mini_player_page.dart';
import 'pages/window_close_preferences.dart';
import 'services/app_runtime.dart';
import 'services/app_log.dart';
import 'services/desktop_playback_window.dart';
import 'services/desktop_tray.dart';
import 'storage/app_storage.dart';

class MyApp extends StatefulWidget {
  const MyApp({required this.runtime, super.key});

  final AppRuntime runtime;

  @override
  State<MyApp> createState() {
    AppLog.instance.trace("lib/app.dart::MyApp.createState");
    return _MyAppState();
  }
}

class _MyAppState extends State<MyApp> with WindowListener {
  late final _appearance = AppAppearance(widget.runtime.storage);
  final _navigator = GlobalKey<NavigatorState>();
  final _messenger = GlobalKey<ScaffoldMessengerState>();
  final _playerRoutes = _PlayerRouteObserver();
  final _promptRoutes = LogUploadPromptObserver();
  final _sentryRoutes = SentryNavigatorObserver();
  final _windowActions = Lock();
  final _playbackWindow = DesktopPlaybackWindow();
  late final _tray = DesktopTray(
    onRestore: () {
      AppLog.instance.trace("lib/app.dart::_MyAppState._tray.closure#1");
      return _switchWindow(restore: true);
    },
    onMini: () {
      AppLog.instance.trace("lib/app.dart::_MyAppState._tray.closure#2");
      return _switchWindow();
    },
    onPlayPause: () {
      AppLog.instance.trace("lib/app.dart::_MyAppState._tray.closure#3");
      return _trayPlayback(() {
        AppLog.instance.trace(
          "lib/app.dart::_MyAppState._tray.closure#3.closure#1",
        );

        final player = widget.runtime.player;
        return player.playing || player.loading
            ? player.pause()
            : player.resume();
      });
    },
    onNext: () {
      AppLog.instance.trace("lib/app.dart::_MyAppState._tray.closure#4");
      return _trayPlayback(widget.runtime.player.next);
    },
    onExit: () {
      AppLog.instance.trace("lib/app.dart::_MyAppState._tray.closure#5");
      return onCloseRequested(explicitExit: true);
    },
  );
  bool _trayPlaybackBusy = false;
  Route<void>? _miniRoute;
  Route<dynamic>? _closeDialog;
  Future<void>? _closeWork;
  bool _exitPending = false, _choosingCloseAction = false;
  String? _windowCloseError;

  @override
  void initState() {
    AppLog.instance.trace("lib/app.dart::_MyAppState.initState");

    super.initState();
    widget.runtime.confirmDownload = (batch) async {
      AppLog.instance.trace("lib/app.dart::_MyAppState.initState.closure#1");

      final context = _navigator.currentContext;
      return context == null ? false : confirmDownloadBatch(context, batch);
    };
    widget.runtime.requestExit = () {
      AppLog.instance.trace("lib/app.dart::_MyAppState.initState.closure#2");
      return onCloseRequested(explicitExit: true);
    };
    if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
      windowManager.addListener(this);
      unawaited(windowManager.setPreventClose(true));
    }
    if (Platform.isWindows) {
      _tray.ensureReady();
      widget.runtime.addListener(_updateTray);
      _updateTray();
    }
  }

  void _updateTray() {
    AppLog.instance.trace("lib/app.dart::_MyAppState._updateTray");
    final player = widget.runtime.player;
    _tray.update(
      title: player.current?.title ?? '',
      playing: player.playing,
      loading: player.loading,
      enabled:
          player.current != null &&
          !widget.runtime.closing &&
          !widget.runtime.restoringBackup &&
          !widget.runtime.restoreNeedsReload &&
          !_trayPlaybackBusy,
    );
  }

  Future<void> _trayPlayback(Future<void> Function() action) {
    AppLog.instance.trace("lib/app.dart::_MyAppState._trayPlayback");
    return AppLog.instance.runWithErrorScope(() async {
      AppLog.instance.trace(
        "lib/app.dart::_MyAppState._trayPlayback.closure#1",
      );

      if (_trayPlaybackBusy ||
          widget.runtime.closing ||
          widget.runtime.restoringBackup ||
          widget.runtime.restoreNeedsReload ||
          !mounted)
        return;
      _trayPlaybackBusy = true;
      _updateTray();
      try {
        await action();
      } catch (error, stack) {
        if (!AppLog.instance.errorWasRecorded(error)) {
          AppLog.instance.write(
            AppLogLevel.error,
            'window',
            'Tray playback operation failed',
            error: error,
            stackTrace: stack,
            promptUser: true,
          );
        }
        await _revealWindow();
        _showWindowError('播放操作未完成，请重试');
      } finally {
        _trayPlaybackBusy = false;
        widget.runtime.changed();
      }
    });
  }

  @override
  void onWindowClose() async {
    AppLog.instance.trace("lib/app.dart::_MyAppState.onWindowClose");

    await onCloseRequested();
  }

  @override
  void onWindowMinimize() {
    AppLog.instance.trace("lib/app.dart::_MyAppState.onWindowMinimize");
    if (Platform.isWindows && _miniRoute != null) unawaited(_sendToTray());
  }

  Future<void> onCloseRequested({bool explicitExit = false}) {
    AppLog.instance.trace("lib/app.dart::_MyAppState.onCloseRequested");

    if (!mounted) return Future.value();
    if (explicitExit ||
        widget.runtime.scheduledExit ||
        widget.runtime.exitOnly ||
        widget.runtime.restoringBackup ||
        widget.runtime.restoreNeedsReload) {
      _exitPending = true;
      // A timer can fire while a close dialog is waiting for user input.
      // Dismiss only our dialog; an explicit exit still confirms downloads.
      final dialog = _closeDialog;
      if (dialog != null &&
          dialog.isActive &&
          (_choosingCloseAction || widget.runtime.scheduledExit)) {
        _navigator.currentState?.removeRoute(dialog);
      }
    }
    return _closeWork ??= _windowActions.synchronized(_handleClose).whenComplete(
      () {
        AppLog.instance.trace(
          "lib/app.dart::_MyAppState.onCloseRequested.closure#1",
        );

        _closeWork = null;
        _exitPending = false;
        widget.runtime.scheduledExit = false;
        if (mounted)
          setState(() {
            AppLog.instance.trace(
              "lib/app.dart::_MyAppState.onCloseRequested.closure#1.closure#1",
            );
          });
      },
    );
  }

  Future<T?> _askClose<T>(Widget dialog) async {
    AppLog.instance.trace("lib/app.dart::_MyAppState._askClose");

    await _restoreMainWindow();
    final context = _navigator.currentContext;
    if (context == null) return null;
    final route = DialogRoute<T>(
      context: context,
      settings: const RouteSettings(name: '/dialog/window-close'),
      builder: (_) {
        AppLog.instance.trace("lib/app.dart::_MyAppState._askClose.closure#1");
        return dialog;
      },
    );
    _closeDialog = route;
    try {
      return await _navigator.currentState!.push(route);
    } finally {
      if (identical(_closeDialog, route)) _closeDialog = null;
    }
  }

  Future<void> _handleClose() {
    AppLog.instance.trace("lib/app.dart::_MyAppState._handleClose");
    return AppLog.instance.runWithErrorScope(() async {
      AppLog.instance.trace("lib/app.dart::_MyAppState._handleClose.closure#1");

      if (!mounted) return;
      if (_windowCloseError != null)
        setState(() {
          AppLog.instance.trace(
            "lib/app.dart::_MyAppState._handleClose.closure#1.closure#1",
          );
          _windowCloseError = null;
        });
      try {
        if (Platform.isWindows && !_exitPending) {
          if (_miniRoute != null) {
            await _hideToTray();
            if (!_exitPending) return;
          } else {
            var action = WindowCloseAction.read(widget.runtime);
            if (action == WindowCloseAction.ask) {
              _choosingCloseAction = true;
              final choice = await _askClose<(WindowCloseAction, bool)>(
                const WindowCloseChoiceDialog(),
              );
              _choosingCloseAction = false;
              if (!_exitPending) {
                if (choice == null) return;
                action = choice.$1;
                if (choice.$2) {
                  try {
                    await action.save(widget.runtime);
                  } catch (error, stack) {
                    if (!(error is StorageException &&
                            const {
                              'too_large',
                              'secret_in_state',
                            }.contains(error.code)) &&
                        !AppLog.instance.errorWasRecorded(error)) {
                      AppLog.instance.write(
                        AppLogLevel.error,
                        'window',
                        'Saving close preference failed',
                        error: error,
                        stackTrace: stack,
                        promptUser: true,
                      );
                    }
                    _showWindowError('未能记住选择，本次仍按所选方式关闭');
                  }
                }
              }
            }
            if (!_exitPending && action == WindowCloseAction.mini) {
              await _enterMini();
              if (!_exitPending) return;
            }
            if (!_exitPending && action == WindowCloseAction.tray) {
              await _hideToTray();
              if (!_exitPending) return;
            }
          }
        }
        if (!widget.runtime.exitOnly &&
            !widget.runtime.scheduledExit &&
            !widget.runtime.restoringBackup &&
            !widget.runtime.restoreNeedsReload &&
            widget.runtime.downloads.tasks.any((task) {
              AppLog.instance.trace(
                "lib/app.dart::_MyAppState._handleClose.closure#1.closure#2",
              );
              return task.active;
            })) {
          final confirmed = await _askClose<bool>(
            Builder(
              builder: (context) {
                AppLog.instance.trace(
                  "lib/app.dart::_MyAppState._handleClose.closure#1.closure#3",
                );
                return AlertDialog(
                  title: const Text('暂停下载并退出？'),
                  content: const Text('下次打开后可手动继续。'),
                  actions: [
                    TextButton(
                      onPressed: () {
                        AppLog.instance.trace(
                          "lib/app.dart::_MyAppState._handleClose.closure#1.closure#3.closure#1",
                        );
                        Navigator.pop(context, false);
                      },
                      child: const Text('取消'),
                    ),
                    FilledButton(
                      onPressed: () {
                        AppLog.instance.trace(
                          "lib/app.dart::_MyAppState._handleClose.closure#1.closure#3.closure#2",
                        );
                        Navigator.pop(context, true);
                      },
                      child: const Text('暂停并退出'),
                    ),
                  ],
                );
              },
            ),
          );
          if (confirmed != true && !widget.runtime.scheduledExit) return;
        }
        if (await widget.runtime.close()) {
          if (Platform.isWindows) _tray.dispose();
          AppLog.instance.write(AppLogLevel.info, 'lifecycle', '应用退出');
          await AppLog.instance.close();
          if (Platform.isAndroid) {
            await SystemNavigator.pop();
          } else {
            await windowManager.setPreventClose(false);
            await windowManager.close();
          }
        } else {
          await _revealWindow();
          _showWindowError(widget.runtime.lifecycleError ?? '退出未完成，请重试');
        }
      } catch (error, stack) {
        if (!AppLog.instance.errorWasRecorded(error)) {
          AppLog.instance.write(
            AppLogLevel.error,
            'window',
            'Closing window failed',
            error: error,
            stackTrace: stack,
            promptUser: true,
          );
        }
        if (mounted) {
          setState(() {
            AppLog.instance.trace(
              "lib/app.dart::_MyAppState._handleClose.closure#1.closure#4",
            );
            _windowCloseError = '窗口未能关闭，请重试退出';
          });
        }
        if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
          try {
            await windowManager.setPreventClose(true);
          } catch (cleanupError, cleanupStack) {
            AppLog.instance.write(
              AppLogLevel.warning,
              'window',
              'Restoring close prevention failed',
              error: cleanupError,
              stackTrace: cleanupStack,
              promptUser: false,
            );
          }
        }
        await _revealWindow();
        _showWindowError('窗口操作未完成，请重试');
      } finally {
        _choosingCloseAction = false;
      }
    });
  }

  Future<void> _revealWindow() async {
    AppLog.instance.trace("lib/app.dart::_MyAppState._revealWindow");

    if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
      if (await windowManager.isMinimized()) await windowManager.restore();
      await windowManager.show();
      await windowManager.focus();
    }
  }

  Future<void> _hideToTray() async {
    AppLog.instance.trace("lib/app.dart::_MyAppState._hideToTray");
    if (!_tray.ensureReady()) throw StateError('系统托盘暂不可用');
    _updateTray();
    try {
      await windowManager.hide();
    } catch (_) {
      await _revealWindow();
      rethrow;
    }
  }

  Future<void> _sendToTray() {
    AppLog.instance.trace("lib/app.dart::_MyAppState._sendToTray");
    return AppLog.instance.runWithErrorScope(() {
      AppLog.instance.trace("lib/app.dart::_MyAppState._sendToTray.closure#1");

      return _windowActions.synchronized(() async {
        AppLog.instance.trace(
          "lib/app.dart::_MyAppState._sendToTray.closure#1.closure#1",
        );

        if (!mounted || widget.runtime.closing) return;
        try {
          await _hideToTray();
        } catch (error, stack) {
          if (!AppLog.instance.errorWasRecorded(error)) {
            AppLog.instance.write(
              AppLogLevel.error,
              'window',
              'Hiding playback window to tray failed',
              error: error,
              stackTrace: stack,
              promptUser: true,
            );
          }
          await _revealWindow();
          _showWindowError('暂时无法收起到托盘，请重试');
        }
      });
    });
  }

  Future<void> _restoreMainWindow() async {
    AppLog.instance.trace("lib/app.dart::_MyAppState._restoreMainWindow");
    if (Platform.isWindows) {
      await _playbackWindow.restore();
      final route = _miniRoute;
      if (route != null) {
        _navigator.currentState?.removeRoute(route);
        if (mounted)
          setState(() {
            AppLog.instance.trace(
              "lib/app.dart::_MyAppState._restoreMainWindow.closure#1",
            );
            _miniRoute = null;
          });
      }
    }
    await _revealWindow();
  }

  void _showWindowError(String message) {
    AppLog.instance.trace("lib/app.dart::_MyAppState._showWindowError");

    _messenger.currentState?.showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _enterMini() {
    AppLog.instance.trace("lib/app.dart::_MyAppState._enterMini");
    return AppLog.instance.runWithErrorScope(() async {
      AppLog.instance.trace("lib/app.dart::_MyAppState._enterMini.closure#1");

      if (_miniRoute != null || !mounted) return;
      final route = MaterialPageRoute<void>(
        settings: const RouteSettings(name: MiniPlayerPage.routeName),
        builder: (_) {
          AppLog.instance.trace(
            "lib/app.dart::_MyAppState._enterMini.closure#1.closure#1",
          );
          return MiniPlayerPage(
            runtime: widget.runtime,
            onRestore: () {
              AppLog.instance.trace(
                "lib/app.dart::_MyAppState._enterMini.closure#1.closure#1.closure#1",
              );
              unawaited(_switchWindow(restore: true));
            },
            onExit: () {
              AppLog.instance.trace(
                "lib/app.dart::_MyAppState._enterMini.closure#1.closure#1.closure#2",
              );
              unawaited(onCloseRequested(explicitExit: true));
            },
          );
        },
      );
      setState(() {
        AppLog.instance.trace(
          "lib/app.dart::_MyAppState._enterMini.closure#1.closure#2",
        );
        _miniRoute = route;
      });
      unawaited(_navigator.currentState!.push(route));
      try {
        await _playbackWindow.enterMini();
      } catch (error, stack) {
        if (!AppLog.instance.errorWasRecorded(error)) {
          AppLog.instance.write(
            AppLogLevel.error,
            'window',
            'Entering mini window failed',
            error: error,
            stackTrace: stack,
            promptUser: true,
          );
        }
        if (!_playbackWindow.isMini) {
          _navigator.currentState?.removeRoute(route);
          if (mounted)
            setState(() {
              AppLog.instance.trace(
                "lib/app.dart::_MyAppState._enterMini.closure#1.closure#3",
              );
              _miniRoute = null;
            });
        }
        rethrow;
      }
    });
  }

  Future<void> _switchWindow({bool restore = false}) {
    AppLog.instance.trace("lib/app.dart::_MyAppState._switchWindow");
    return AppLog.instance.runWithErrorScope(() {
      AppLog.instance.trace(
        "lib/app.dart::_MyAppState._switchWindow.closure#1",
      );
      return _windowActions.synchronized(() async {
        AppLog.instance.trace(
          "lib/app.dart::_MyAppState._switchWindow.closure#1.closure#1",
        );

        if (!mounted || widget.runtime.closing) return;
        try {
          if (restore) {
            await _restoreMainWindow();
          } else {
            await _enterMini();
            await _revealWindow();
          }
        } catch (error, stack) {
          if (!AppLog.instance.errorWasRecorded(error)) {
            AppLog.instance.write(
              AppLogLevel.error,
              'window',
              'Switching playback window failed',
              error: error,
              stackTrace: stack,
              promptUser: true,
            );
          }
          await _revealWindow();
          _showWindowError('窗口切换失败，可重试或选择彻底退出');
        }
      });
    });
  }

  @override
  void dispose() {
    AppLog.instance.trace("lib/app.dart::_MyAppState.dispose");

    if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
      windowManager.removeListener(this);
    }
    widget.runtime.confirmDownload = null;
    widget.runtime.requestExit = null;
    if (Platform.isWindows) {
      widget.runtime.removeListener(_updateTray);
      _tray.dispose();
    }
    _appearance.dispose();
    _playerRoutes.dispose();
    _promptRoutes.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    AppLog.instance.trace("lib/app.dart::_MyAppState.build");

    return ListenableBuilder(
      listenable: _appearance,
      builder: (context, _) {
        AppLog.instance.trace("lib/app.dart::_MyAppState.build.closure#1");
        return GetMaterialApp(
          title: 'XMPlus',
          navigatorKey: _navigator,
          scaffoldMessengerKey: _messenger,
          navigatorObservers: [_playerRoutes, _promptRoutes, _sentryRoutes],
          initialRoute: '/',
          debugShowCheckedModeBanner: false,
          theme: getThemeData(
            seedColor: _appearance.seedColor,
            brightness: Brightness.light,
            oledBlack: _appearance.oledBlack,
          ),
          darkTheme: getThemeData(
            seedColor: _appearance.seedColor,
            brightness: Brightness.dark,
            oledBlack: _appearance.oledBlack,
          ),
          themeMode: _appearance.themeMode,
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          locale: const Locale('zh', 'CN'),
          fallbackLocale: const Locale('zh', 'CN'),
          supportedLocales: const [Locale('zh', 'CN'), Locale('en', 'US')],
          scrollBehavior: const CustomScrollBehavior(),
          builder: (context, child) {
            AppLog.instance.trace(
              "lib/app.dart::_MyAppState.build.closure#1.closure#1",
            );
            return MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: AppTextScaler(
                  MediaQuery.textScalerOf(context),
                  _appearance.textScale,
                ),
              ),
              child: ColoredBox(
                color: Theme.of(context).colorScheme.surface,
                child: AppShutdownOverlay(
                  runtime: widget.runtime,
                  windowError: _windowCloseError,
                  onRetry: () {
                    AppLog.instance.trace(
                      "lib/app.dart::_MyAppState.build.closure#1.closure#1.closure#1",
                    );
                    unawaited(onCloseRequested(explicitExit: true));
                  },
                  child: Overlay.wrap(
                    child: ListenableBuilder(
                      listenable: Listenable.merge([
                        _playerRoutes,
                        _promptRoutes,
                        widget.runtime,
                      ]),
                      child: child,
                      builder: (context, child) {
                        AppLog.instance.trace(
                          "lib/app.dart::_MyAppState.build.closure#1.closure#1.closure#2",
                        );
                        return LogUploadPromptHost(
                          navigatorKey: _navigator,
                          canShow: () {
                            AppLog.instance.trace(
                              "lib/app.dart::_MyAppState.build.closure#1.closure#1.closure#2.closure#1",
                            );
                            return !_promptRoutes.hasPopup &&
                                !widget.runtime.closing &&
                                !widget.runtime.restoringBackup &&
                                !widget.runtime.restoreNeedsReload &&
                                _closeWork == null &&
                                !_exitPending &&
                                _closeDialog == null;
                          },
                          child: Column(
                            children: [
                              Expanded(child: child!),
                              if (_miniRoute == null &&
                                  !_playerRoutes.playerExpanded)
                                SafeArea(
                                  top: false,
                                  child: ExcludeFocus(
                                    excluding:
                                        _playerRoutes.current is PopupRoute,
                                    child: ExcludeSemantics(
                                      excluding:
                                          _playerRoutes.current is PopupRoute,
                                      child: AbsorbPointer(
                                        absorbing:
                                            _playerRoutes.current is PopupRoute,
                                        child: PlayerPanel(
                                          runtime: widget.runtime,
                                          navigatorKey: _navigator,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ),
            );
          },
          home: PopScope(
            canPop: !Platform.isAndroid,
            onPopInvokedWithResult: (didPop, result) {
              AppLog.instance.trace(
                "lib/app.dart::_MyAppState.build.closure#1.closure#2",
              );

              if (!didPop && Platform.isAndroid) unawaited(onCloseRequested());
            },
            child: ShellPage(
              appearance: _appearance,
              runtime: widget.runtime,
              onMiniPlayer: Platform.isWindows
                  ? () {
                      AppLog.instance.trace(
                        "lib/app.dart::_MyAppState.build.closure#1.closure#3",
                      );
                      unawaited(_switchWindow());
                    }
                  : null,
              onTray: Platform.isWindows
                  ? () {
                      AppLog.instance.trace(
                        "lib/app.dart::_MyAppState.build.closure#1.closure#4",
                      );
                      unawaited(_sendToTray());
                    }
                  : null,
            ),
          ),
        );
      },
    );
  }
}

class _PlayerRouteObserver extends NavigatorObserver with ChangeNotifier {
  final _routes = <Route<dynamic>>[];
  Route<dynamic>? current;
  bool _disposed = false;

  bool get playerExpanded {
    AppLog.instance.trace(
      "lib/app.dart::_PlayerRouteObserver.playerExpanded.get",
    );

    for (final route in _routes.reversed) {
      if (route is PageRoute)
        return route.settings.name == PlayerPanel.routeName;
    }
    return false;
  }

  void _changed(Route<dynamic>? route) {
    AppLog.instance.trace("lib/app.dart::_PlayerRouteObserver._changed");

    current = route;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      AppLog.instance.trace(
        "lib/app.dart::_PlayerRouteObserver._changed.closure#1",
      );

      if (!_disposed) notifyListeners();
    });
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    AppLog.instance.trace("lib/app.dart::_PlayerRouteObserver.didPush");

    _routes.add(route);
    _changed(route);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    AppLog.instance.trace("lib/app.dart::_PlayerRouteObserver.didPop");

    _routes.remove(route);
    _changed(previousRoute);
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    AppLog.instance.trace("lib/app.dart::_PlayerRouteObserver.didReplace");

    final index = oldRoute == null ? -1 : _routes.indexOf(oldRoute);
    if (index >= 0) {
      if (newRoute == null) {
        _routes.removeAt(index);
      } else {
        _routes[index] = newRoute;
      }
    } else if (newRoute != null) {
      _routes.add(newRoute);
    }
    _changed(identical(current, oldRoute) ? newRoute : current);
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    AppLog.instance.trace("lib/app.dart::_PlayerRouteObserver.didRemove");

    _routes.remove(route);
    _changed(identical(current, route) ? previousRoute : current);
  }

  @override
  void dispose() {
    AppLog.instance.trace("lib/app.dart::_PlayerRouteObserver.dispose");

    _disposed = true;
    super.dispose();
  }
}
