import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

import '../common/widgets/app_header.dart';
import '../app.dart';
import '../common/theme.dart';
import '../common/widgets/log_upload_prompt_host.dart';
import '../storage/app_storage.dart';
import '../storage/flutter_credential_store.dart';
import '../services/app_runtime.dart';
import '../services/account_service.dart';
import '../services/app_log.dart';

class StartupPage extends StatefulWidget {
  const StartupPage({required this.arguments, super.key});
  final List<String> arguments;

  @override
  State<StartupPage> createState() {
    AppLog.instance.trace(
      "lib/pages/startup_page.dart::StartupPage.createState",
    );
    return _StartupPageState();
  }
}

class _StartupPageState extends State<StartupPage> {
  final _navigator = GlobalKey<NavigatorState>();
  final _promptRoutes = LogUploadPromptObserver();
  final _sentryRoutes = SentryNavigatorObserver();
  AppRuntime? _runtime;
  String? _directory;
  String? _error;
  bool _opening = false;
  ThemeMode _themeMode = ThemeMode.system;
  Color _seedColor = const Color(AppAppearance.defaultSeedColor);
  double _textScale = 1;
  bool _oledBlack = false;

  @override
  void initState() {
    AppLog.instance.trace(
      "lib/pages/startup_page.dart::_StartupPageState.initState",
    );

    super.initState();
    _open();
  }

  Future<void> _open([String? selected]) {
    AppLog.instance.trace(
      "lib/pages/startup_page.dart::_StartupPageState._open",
    );
    return AppLog.instance.runWithErrorScope(() async {
      AppLog.instance.trace(
        "lib/pages/startup_page.dart::_StartupPageState._open.closure#1",
      );

      if (_opening) return;
      setState(() {
        AppLog.instance.trace(
          "lib/pages/startup_page.dart::_StartupPageState._open.closure#1.closure#1",
        );

        _opening = true;
        _error = null;
      });
      AppStorage? candidate;
      var invalidDirectoryArgument = false;
      try {
        if (selected != null) _directory = selected;
        if (_directory == null) {
          final args = widget.arguments;
          final index = args.indexOf('--data-dir');
          if (index >= 0) {
            if (index + 1 >= args.length || !p.isAbsolute(args[index + 1])) {
              invalidDirectoryArgument = true;
              throw const FormatException('资料目录必须是绝对路径');
            }
            _directory = args[index + 1];
          } else {
            _directory = (await getApplicationSupportDirectory()).path;
          }
        }
        candidate = await AppStorage.open(_directory!);
        AppRuntime.applyLogSettings(candidate.state['settings'] as Map);
        // Validate persisted presentation values before leaving recovery UI.
        final appearance = AppAppearance(candidate);
        if (mounted) {
          setState(() {
            AppLog.instance.trace(
              "lib/pages/startup_page.dart::_StartupPageState._open.closure#1.closure#2",
            );

            _themeMode = appearance.themeMode;
            _seedColor = appearance.seedColor;
            _textScale = appearance.textScale;
            _oledBlack = appearance.oledBlack;
          });
        }
        appearance.dispose();
        final runtime = AppRuntime(
          storage: candidate,
          secrets: FlutterCredentialStore(),
        );
        await runtime.load();
        if (!mounted) {
          await candidate.close();
          return;
        }
        setState(() {
          AppLog.instance.trace(
            "lib/pages/startup_page.dart::_StartupPageState._open.closure#1.closure#3",
          );

          _runtime = runtime;
        });
      } catch (error, stackTrace) {
        AppLog.instance.level = AppLogLevel.info;
        final expected =
            (error is StorageException &&
                const {'directory', 'locked'}.contains(error.code)) ||
            invalidDirectoryArgument;
        if (!expected) {
          if (!AppLog.instance.errorWasRecorded(error)) {
            AppLog.instance.write(
              AppLogLevel.error,
              'startup',
              '无法打开资料目录',
              error: error,
              stackTrace: stackTrace,
              promptUser: true,
            );
          }
          AppLog.instance.requestUploadPrompt();
        }
        try {
          await candidate?.close();
        } catch (cleanupError, cleanupStack) {
          AppLog.instance.write(
            AppLogLevel.warning,
            'startup',
            '启动失败后的资料清理未完成',
            error: cleanupError,
            stackTrace: cleanupStack,
            promptUser: false,
          );
        } finally {
          await AppLog.instance.flush();
        }
        if (mounted)
          setState(() {
            AppLog.instance.trace(
              "lib/pages/startup_page.dart::_StartupPageState._open.closure#1.closure#4",
            );

            _error =
                error is StorageException ||
                    error is FormatException ||
                    error is AccountException
                ? error.toString()
                : '无法打开资料目录，请检查目录权限后重试';
          });
      } finally {
        if (mounted)
          setState(() {
            AppLog.instance.trace(
              "lib/pages/startup_page.dart::_StartupPageState._open.closure#1.closure#5",
            );

            _opening = false;
          });
      }
    });
  }

  Future<void> _choose() {
    AppLog.instance.trace(
      "lib/pages/startup_page.dart::_StartupPageState._choose",
    );
    return AppLog.instance.runWithErrorScope(() async {
      AppLog.instance.trace(
        "lib/pages/startup_page.dart::_StartupPageState._choose.closure#1",
      );

      try {
        final value = await FilePicker.getDirectoryPath(dialogTitle: '选择资料目录');
        if (value != null && mounted) await _open(value);
      } catch (error, stack) {
        if (!AppLog.instance.errorWasRecorded(error)) {
          AppLog.instance.write(
            AppLogLevel.error,
            'startup',
            'Choosing profile directory failed',
            error: error,
            stackTrace: stack,
            promptUser: true,
          );
        }
        if (mounted)
          setState(() {
            AppLog.instance.trace(
              "lib/pages/startup_page.dart::_StartupPageState._choose.closure#1.closure#1",
            );
            _error = '无法选择资料目录，请重试';
          });
      }
    });
  }

  @override
  void dispose() {
    AppLog.instance.trace(
      "lib/pages/startup_page.dart::_StartupPageState.dispose",
    );

    _promptRoutes.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    AppLog.instance.trace(
      "lib/pages/startup_page.dart::_StartupPageState.build",
    );

    if (_runtime case final runtime?) return MyApp(runtime: runtime);
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'XMPlus',
      navigatorKey: _navigator,
      navigatorObservers: [_promptRoutes, _sentryRoutes],
      initialRoute: '/startup/recovery',
      theme: getThemeData(
        seedColor: _seedColor,
        brightness: Brightness.light,
        oledBlack: _oledBlack,
      ),
      darkTheme: getThemeData(
        seedColor: _seedColor,
        brightness: Brightness.dark,
        oledBlack: _oledBlack,
      ),
      themeMode: _themeMode,
      builder: (context, child) {
        AppLog.instance.trace(
          "lib/pages/startup_page.dart::_StartupPageState.build.closure#1",
        );
        return MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: AppTextScaler(
              MediaQuery.textScalerOf(context),
              _textScale,
            ),
          ),
          child: ListenableBuilder(
            listenable: _promptRoutes,
            builder: (context, _) {
              AppLog.instance.trace(
                "lib/pages/startup_page.dart::_StartupPageState.build.closure#1.closure#1",
              );
              return LogUploadPromptHost(
                navigatorKey: _navigator,
                canShow: () {
                  AppLog.instance.trace(
                    "lib/pages/startup_page.dart::_StartupPageState.build.closure#1.closure#1.closure#1",
                  );
                  return !_opening && _error != null && !_promptRoutes.hasPopup;
                },
                exportCurrent: true,
                child: child!,
              );
            },
          ),
        );
      },
      routes: {
        '/startup/recovery': (_) {
          AppLog.instance.trace(
            "lib/pages/startup_page.dart::_StartupPageState.build.closure#2",
          );
          return Scaffold(
            appBar: usesWindowHeader
                ? const AppHeader(title: Text('XMPlus'), showBrand: true)
                : null,
            body: SafeArea(
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 560),
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (_opening) const CircularProgressIndicator(),
                        if (_error != null) ...[
                          Text(_error!, textAlign: TextAlign.center),
                          const SizedBox(height: 16),
                          if (_directory != null) SelectableText(_directory!),
                          const SizedBox(height: 16),
                          Wrap(
                            spacing: 12,
                            runSpacing: 12,
                            alignment: WrapAlignment.center,
                            children: [
                              FilledButton(
                                onPressed: _opening
                                    ? null
                                    : () {
                                        AppLog.instance.trace(
                                          "lib/pages/startup_page.dart::_StartupPageState.build.closure#2.closure#1",
                                        );
                                        _open();
                                      },
                                child: const Text('重试'),
                              ),
                              OutlinedButton(
                                onPressed: _opening ? null : _choose,
                                child: const Text('选择其他资料目录'),
                              ),
                            ],
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      },
    );
  }
}
