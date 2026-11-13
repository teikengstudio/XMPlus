import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/app_runtime.dart';
import "../../services/app_log.dart";

/// Keeps routes mounted while exit or backup recovery temporarily blocks input.
class AppShutdownOverlay extends StatelessWidget {
  const AppShutdownOverlay({
    required this.runtime,
    required this.onRetry,
    required this.child,
    this.windowError,
    super.key,
  });

  final AppRuntime runtime;
  final VoidCallback onRetry;
  final Widget child;
  final String? windowError;

  @override
  Widget build(BuildContext context) {
    AppLog.instance.trace(
      "lib/common/widgets/app_shutdown_overlay.dart::AppShutdownOverlay.build",
    );
    return ListenableBuilder(
      listenable: runtime,
      child: child,
      builder: (context, child) {
        AppLog.instance.trace(
          "lib/common/widgets/app_shutdown_overlay.dart::AppShutdownOverlay.build.closure#1",
        );

        final recovering =
            !runtime.closing &&
            (runtime.restoringBackup || runtime.restoreNeedsReload);
        final blocked = runtime.closing || recovering;
        final error = windowError ?? runtime.lifecycleError;
        final busy = recovering ? runtime.restoringBackup : error == null;
        return Stack(
          fit: StackFit.expand,
          children: [
            ExcludeFocus(
              excluding: blocked,
              child: ExcludeSemantics(
                excluding: blocked,
                child: AbsorbPointer(absorbing: blocked, child: child),
              ),
            ),
            if (blocked)
              Focus(
                autofocus: true,
                onKeyEvent: (_, event) {
                  AppLog.instance.trace(
                    "lib/common/widgets/app_shutdown_overlay.dart::AppShutdownOverlay.build.closure#1.closure#1",
                  );
                  return event.logicalKey == LogicalKeyboardKey.escape
                      ? KeyEventResult.handled
                      : KeyEventResult.ignored;
                },
                child: Material(
                  color: Theme.of(context).colorScheme.surface,
                  child: SafeArea(
                    child: Center(
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.all(24),
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 440),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                recovering
                                    ? (busy ? '正在恢复备份…' : '备份加载尚未完成')
                                    : (busy ? '正在退出…' : '退出尚未完成'),
                                style: Theme.of(context).textTheme.titleLarge,
                              ),
                              const SizedBox(height: 16),
                              if (busy)
                                const CircularProgressIndicator()
                              else ...[
                                Text(
                                  error ?? '备份已保存，请重试加载或退出后重新打开应用。',
                                  textAlign: TextAlign.center,
                                ),
                                const SizedBox(height: 16),
                                FilledButton(
                                  onPressed: recovering
                                      ? () async {
                                          AppLog.instance.trace(
                                            "lib/common/widgets/app_shutdown_overlay.dart::AppShutdownOverlay.build.closure#1.closure#2",
                                          );
                                          try {
                                            await runtime.reloadAfterRestore();
                                          } catch (_) {
                                            // Runtime retains the logged failure
                                            // and retry state after page closure.
                                          }
                                        }
                                      : onRetry,
                                  child: Text(recovering ? '重试加载' : '重试退出'),
                                ),
                                if (recovering)
                                  TextButton(
                                    onPressed: onRetry,
                                    child: const Text('退出应用'),
                                  ),
                              ],
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}
