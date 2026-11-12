import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../services/android_platform.dart';
import '../../services/app_log.dart';
import '../../services/log_export.dart';

/// Install on the navigator and rebuild the host when this observer changes.
class LogUploadPromptObserver extends NavigatorObserver with ChangeNotifier {
  int _popups = 0;
  bool _disposed = false, _notificationScheduled = false;

  bool get hasPopup {
    AppLog.instance.trace(
      "lib/common/widgets/log_upload_prompt_host.dart::LogUploadPromptObserver.hasPopup.get",
    );
    return _popups != 0;
  }

  void _changed() {
    AppLog.instance.trace(
      "lib/common/widgets/log_upload_prompt_host.dart::LogUploadPromptObserver._changed",
    );

    if (_disposed || _notificationScheduled) return;
    _notificationScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      AppLog.instance.trace(
        "lib/common/widgets/log_upload_prompt_host.dart::LogUploadPromptObserver._changed.closure#1",
      );

      _notificationScheduled = false;
      if (!_disposed) notifyListeners();
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void _added(Route<dynamic>? route) {
    AppLog.instance.trace(
      "lib/common/widgets/log_upload_prompt_host.dart::LogUploadPromptObserver._added",
    );

    if (route is PopupRoute) _popups++;
    _changed();
  }

  void _removed(Route<dynamic>? route) {
    AppLog.instance.trace(
      "lib/common/widgets/log_upload_prompt_host.dart::LogUploadPromptObserver._removed",
    );

    if (route is PopupRoute) {
      // Keep the gate closed until the outgoing dialog has left the overlay.
      unawaited(
        route.completed.then((_) {
          AppLog.instance.trace(
            "lib/common/widgets/log_upload_prompt_host.dart::LogUploadPromptObserver._removed.closure#1",
          );

          _popups--;
          _changed();
        }),
      );
    } else {
      _changed();
    }
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    AppLog.instance.trace(
      "lib/common/widgets/log_upload_prompt_host.dart::LogUploadPromptObserver.didPush",
    );

    _added(route);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    AppLog.instance.trace(
      "lib/common/widgets/log_upload_prompt_host.dart::LogUploadPromptObserver.didPop",
    );

    _removed(route);
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    AppLog.instance.trace(
      "lib/common/widgets/log_upload_prompt_host.dart::LogUploadPromptObserver.didRemove",
    );

    _removed(route);
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    AppLog.instance.trace(
      "lib/common/widgets/log_upload_prompt_host.dart::LogUploadPromptObserver.didReplace",
    );

    _removed(oldRoute);
    _added(newRoute);
  }

  @override
  void dispose() {
    AppLog.instance.trace(
      "lib/common/widgets/log_upload_prompt_host.dart::LogUploadPromptObserver.dispose",
    );

    _disposed = true;
    super.dispose();
  }
}

class LogUploadPromptHost extends StatefulWidget {
  const LogUploadPromptHost({
    required this.child,
    required this.navigatorKey,
    required this.canShow,
    this.exportCurrent = false,
    super.key,
  });

  final Widget child;
  final GlobalKey<NavigatorState> navigatorKey;
  final bool Function() canShow;
  final bool exportCurrent;

  @override
  State<LogUploadPromptHost> createState() {
    AppLog.instance.trace(
      "lib/common/widgets/log_upload_prompt_host.dart::LogUploadPromptHost.createState",
    );
    return _LogUploadPromptHostState();
  }
}

class _LogUploadPromptHostState extends State<LogUploadPromptHost>
    with WidgetsBindingObserver {
  // Retain an in-flight claim across recovery -> application navigator changes.
  // AppLog/native still own the once-per-process gate.
  static Future<bool>? _claim;
  static bool _presented = false;
  late final StreamSubscription<void> _errors;
  bool _scheduled = false, _working = false;

  bool get _ready {
    AppLog.instance.trace(
      "lib/common/widgets/log_upload_prompt_host.dart::_LogUploadPromptHostState._ready.get",
    );
    return mounted &&
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed &&
        AppLog.instance.promptLogUpload &&
        widget.canShow() &&
        widget.navigatorKey.currentState?.overlay != null;
  }

  @override
  void initState() {
    AppLog.instance.trace(
      "lib/common/widgets/log_upload_prompt_host.dart::_LogUploadPromptHostState.initState",
    );

    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _errors = AppLog.instance.pendingErrors.listen((_) {
      AppLog.instance.trace(
        "lib/common/widgets/log_upload_prompt_host.dart::_LogUploadPromptHostState.initState.closure#1",
      );
      _schedule();
    });
    _schedule();
  }

  @override
  void didUpdateWidget(covariant LogUploadPromptHost oldWidget) {
    AppLog.instance.trace(
      "lib/common/widgets/log_upload_prompt_host.dart::_LogUploadPromptHostState.didUpdateWidget",
    );

    super.didUpdateWidget(oldWidget);
    _schedule();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    AppLog.instance.trace(
      "lib/common/widgets/log_upload_prompt_host.dart::_LogUploadPromptHostState.didChangeAppLifecycleState",
    );

    if (state == AppLifecycleState.resumed) _schedule();
  }

  void _schedule() {
    AppLog.instance.trace(
      "lib/common/widgets/log_upload_prompt_host.dart::_LogUploadPromptHostState._schedule",
    );

    if (!mounted || _scheduled || _working || _presented) return;
    if (_claim == null && !AppLog.instance.hasPendingErrors) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      AppLog.instance.trace(
        "lib/common/widgets/log_upload_prompt_host.dart::_LogUploadPromptHostState._schedule.closure#1",
      );

      _scheduled = false;
      unawaited(_tryShow());
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  Future<void> _tryShow() async {
    AppLog.instance.trace(
      "lib/common/widgets/log_upload_prompt_host.dart::_LogUploadPromptHostState._tryShow",
    );

    if (_working || _presented || !_ready) return;
    final navigator = widget.navigatorKey.currentState!;
    _working = true;
    try {
      final claim = _claim ??= AppLog.instance.claimUploadPrompt(
        claimProcess: Platform.isAndroid
            ? AndroidPlatform.claimLogUploadPrompt
            : null,
      );
      if (!await claim) {
        if (identical(_claim, claim)) _claim = null;
        return;
      }
      if (_presented ||
          !_ready ||
          !identical(navigator, widget.navigatorKey.currentState))
        return;
      _presented = true;
      unawaited(
        navigator.push<void>(
          DialogRoute<void>(
            context: navigator.context,
            barrierDismissible: false,
            builder: (_) {
              AppLog.instance.trace(
                "lib/common/widgets/log_upload_prompt_host.dart::_LogUploadPromptHostState._tryShow.closure#1",
              );
              return _LogUploadDialog(exportCurrent: widget.exportCurrent);
            },
          ),
        ),
      );
    } finally {
      _working = false;
    }
  }

  @override
  void dispose() {
    AppLog.instance.trace(
      "lib/common/widgets/log_upload_prompt_host.dart::_LogUploadPromptHostState.dispose",
    );

    WidgetsBinding.instance.removeObserver(this);
    unawaited(_errors.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    AppLog.instance.trace(
      "lib/common/widgets/log_upload_prompt_host.dart::_LogUploadPromptHostState.build",
    );
    return widget.child;
  }
}

class _LogUploadDialog extends StatefulWidget {
  const _LogUploadDialog({required this.exportCurrent});
  final bool exportCurrent;

  @override
  State<_LogUploadDialog> createState() {
    AppLog.instance.trace(
      "lib/common/widgets/log_upload_prompt_host.dart::_LogUploadDialog.createState",
    );
    return _LogUploadDialogState();
  }
}

class _LogUploadDialogState extends State<_LogUploadDialog> {
  bool _busy = false;
  String? _message;

  Future<void> _export() async {
    AppLog.instance.trace(
      "lib/common/widgets/log_upload_prompt_host.dart::_LogUploadDialogState._export",
    );

    setState(() {
      AppLog.instance.trace(
        "lib/common/widgets/log_upload_prompt_host.dart::_LogUploadDialogState._export.closure#1",
      );

      _busy = true;
      _message = null;
    });
    try {
      final sessions = await AppLog.instance.sessions();
      final current = sessions.firstWhere(
        (session) {
          AppLog.instance.trace(
            "lib/common/widgets/log_upload_prompt_host.dart::_LogUploadDialogState._export.closure#2",
          );
          return session.isCurrent;
        },
        orElse: () {
          AppLog.instance.trace(
            "lib/common/widgets/log_upload_prompt_host.dart::_LogUploadDialogState._export.closure#3",
          );
          return throw StateError('本次日志不可用');
        },
      );
      if (!mounted) return;
      final destination = await exportLogSession(current);
      if (mounted)
        setState(() {
          AppLog.instance.trace(
            "lib/common/widgets/log_upload_prompt_host.dart::_LogUploadDialogState._export.closure#4",
          );

          _message = destination == null ? '已取消导出' : '日志已导出';
        });
    } catch (error, stack) {
      AppLog.instance.write(
        AppLogLevel.warning,
        'log_export',
        '日志导出失败',
        error: error,
        stackTrace: stack,
        promptUser: false,
      );
      if (mounted)
        setState(() {
          AppLog.instance.trace(
            "lib/common/widgets/log_upload_prompt_host.dart::_LogUploadDialogState._export.closure#5",
          );
          _message = '日志导出失败：$error';
        });
    } finally {
      if (mounted)
        setState(() {
          AppLog.instance.trace(
            "lib/common/widgets/log_upload_prompt_host.dart::_LogUploadDialogState._export.closure#6",
          );
          _busy = false;
        });
    }
  }

  Future<void> _openIssues() async {
    AppLog.instance.trace(
      "lib/common/widgets/log_upload_prompt_host.dart::_LogUploadDialogState._openIssues",
    );

    setState(() {
      AppLog.instance.trace(
        "lib/common/widgets/log_upload_prompt_host.dart::_LogUploadDialogState._openIssues.closure#1",
      );

      _busy = true;
      _message = null;
    });
    try {
      if (!await launchUrl(
        Uri.parse('https://github.com/teikengstudio/XMPlus/issues'),
        mode: LaunchMode.externalApplication,
      )) {
        throw StateError('无法打开浏览器');
      }
      if (mounted) Navigator.of(context).pop();
    } catch (error, stack) {
      AppLog.instance.write(
        AppLogLevel.warning,
        'log_upload_prompt',
        '无法打开 GitHub',
        error: error,
        stackTrace: stack,
        promptUser: false,
      );
      if (mounted)
        setState(() {
          AppLog.instance.trace(
            "lib/common/widgets/log_upload_prompt_host.dart::_LogUploadDialogState._openIssues.closure#2",
          );
          _message = '无法打开 GitHub，请稍后重试';
        });
    } finally {
      if (mounted)
        setState(() {
          AppLog.instance.trace(
            "lib/common/widgets/log_upload_prompt_host.dart::_LogUploadDialogState._openIssues.closure#3",
          );
          _busy = false;
        });
    }
  }

  @override
  Widget build(BuildContext context) {
    AppLog.instance.trace(
      "lib/common/widgets/log_upload_prompt_host.dart::_LogUploadDialogState.build",
    );
    return PopScope(
      canPop: !_busy,
      child: AlertDialog(
        title: const Text('运行出错'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('请到 GitHub 反馈问题，并附上日志。可在“设置 → 开发”导出。'),
            if (_message != null) ...[
              const SizedBox(height: 12),
              Text(_message!),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: _busy
                ? null
                : () {
                    AppLog.instance.trace(
                      "lib/common/widgets/log_upload_prompt_host.dart::_LogUploadDialogState.build.closure#1",
                    );
                    Navigator.of(context).pop();
                  },
            child: const Text('稍后'),
          ),
          if (widget.exportCurrent)
            TextButton(
              onPressed: _busy ? null : _export,
              child: const Text('导出日志'),
            ),
          FilledButton(
            onPressed: _busy ? null : _openIssues,
            child: const Text('前往 GitHub'),
          ),
        ],
      ),
    );
  }
}
