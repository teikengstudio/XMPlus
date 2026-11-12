import 'package:flutter/material.dart';

import '../services/app_runtime.dart';
import '../services/app_log.dart';
import '../storage/app_storage.dart';

enum WindowCloseAction {
  ask('每次询问'),
  mini('收起到小窗'),
  exit('彻底退出');

  const WindowCloseAction(this.label);
  final String label;

  static WindowCloseAction read(AppRuntime runtime) {
    AppLog.instance.trace(
      "lib/pages/window_close_preferences.dart::WindowCloseAction.read",
    );

    final value =
        (runtime.storage.state['settings'] as Map)['windowCloseAction'];
    return values.firstWhere(
      (action) {
        AppLog.instance.trace(
          "lib/pages/window_close_preferences.dart::WindowCloseAction.read.closure#1",
        );
        return action.name == value;
      },
      orElse: () {
        AppLog.instance.trace(
          "lib/pages/window_close_preferences.dart::WindowCloseAction.read.closure#2",
        );
        return ask;
      },
    );
  }

  Future<void> save(AppRuntime runtime) async {
    AppLog.instance.trace(
      "lib/pages/window_close_preferences.dart::WindowCloseAction.save",
    );

    await runtime.storage.transaction((state) {
      AppLog.instance.trace(
        "lib/pages/window_close_preferences.dart::WindowCloseAction.save.closure#1",
      );

      (state['settings'] as Map)['windowCloseAction'] = name;
    });
    runtime.changed();
  }
}

class WindowCloseChoiceDialog extends StatefulWidget {
  const WindowCloseChoiceDialog({super.key});

  @override
  State<WindowCloseChoiceDialog> createState() {
    AppLog.instance.trace(
      "lib/pages/window_close_preferences.dart::WindowCloseChoiceDialog.createState",
    );
    return _WindowCloseChoiceDialogState();
  }
}

class _WindowCloseChoiceDialogState extends State<WindowCloseChoiceDialog> {
  bool _remember = false;

  @override
  Widget build(BuildContext context) {
    AppLog.instance.trace(
      "lib/pages/window_close_preferences.dart::_WindowCloseChoiceDialogState.build",
    );
    return AlertDialog(
      title: const Text('关闭主窗口'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('收起到小窗后仍可继续收听和控制播放。'),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('记住我的选择'),
              subtitle: const Text('可在设置的外观页更改'),
              value: _remember,
              onChanged: (value) {
                AppLog.instance.trace(
                  "lib/pages/window_close_preferences.dart::_WindowCloseChoiceDialogState.build.closure#1",
                );
                setState(() {
                  AppLog.instance.trace(
                    "lib/pages/window_close_preferences.dart::_WindowCloseChoiceDialogState.build.closure#1.closure#1",
                  );
                  _remember = value == true;
                });
              },
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () {
            AppLog.instance.trace(
              "lib/pages/window_close_preferences.dart::_WindowCloseChoiceDialogState.build.closure#2",
            );
            Navigator.pop(context);
          },
          child: const Text('取消'),
        ),
        TextButton(
          onPressed: () {
            AppLog.instance.trace(
              "lib/pages/window_close_preferences.dart::_WindowCloseChoiceDialogState.build.closure#3",
            );

            Navigator.pop(context, (WindowCloseAction.exit, _remember));
          },
          child: const Text('彻底退出'),
        ),
        FilledButton(
          onPressed: () {
            AppLog.instance.trace(
              "lib/pages/window_close_preferences.dart::_WindowCloseChoiceDialogState.build.closure#4",
            );

            Navigator.pop(context, (WindowCloseAction.mini, _remember));
          },
          child: const Text('收起到小窗'),
        ),
      ],
    );
  }
}

class WindowClosePreference extends StatefulWidget {
  const WindowClosePreference({required this.runtime, super.key});
  final AppRuntime runtime;

  @override
  State<WindowClosePreference> createState() {
    AppLog.instance.trace(
      "lib/pages/window_close_preferences.dart::WindowClosePreference.createState",
    );
    return _WindowClosePreferenceState();
  }
}

class _WindowClosePreferenceState extends State<WindowClosePreference> {
  bool _saving = false;
  String? _error;

  Future<void> _save(WindowCloseAction? action) {
    AppLog.instance.trace(
      "lib/pages/window_close_preferences.dart::_WindowClosePreferenceState._save",
    );
    return AppLog.instance.runWithErrorScope(() async {
      AppLog.instance.trace(
        "lib/pages/window_close_preferences.dart::_WindowClosePreferenceState._save.closure#1",
      );

      if (action == null || _saving) return;
      setState(() {
        AppLog.instance.trace(
          "lib/pages/window_close_preferences.dart::_WindowClosePreferenceState._save.closure#1.closure#1",
        );

        _saving = true;
        _error = null;
      });
      try {
        await action.save(widget.runtime);
      } catch (error, stack) {
        if (!(error is StorageException &&
                const {'too_large', 'secret_in_state'}.contains(error.code)) &&
            !AppLog.instance.errorWasRecorded(error)) {
          AppLog.instance.write(
            AppLogLevel.error,
            'settings',
            'Saving close preference failed',
            error: error,
            stackTrace: stack,
            promptUser: true,
          );
        }
        if (mounted)
          setState(() {
            AppLog.instance.trace(
              "lib/pages/window_close_preferences.dart::_WindowClosePreferenceState._save.closure#1.closure#2",
            );
            _error = '设置保存失败，原设置已保留';
          });
      } finally {
        if (mounted)
          setState(() {
            AppLog.instance.trace(
              "lib/pages/window_close_preferences.dart::_WindowClosePreferenceState._save.closure#1.closure#3",
            );
            _saving = false;
          });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    AppLog.instance.trace(
      "lib/pages/window_close_preferences.dart::_WindowClosePreferenceState.build",
    );
    return ListenableBuilder(
      listenable: widget.runtime,
      builder: (context, _) {
        AppLog.instance.trace(
          "lib/pages/window_close_preferences.dart::_WindowClosePreferenceState.build.closure#1",
        );
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('关闭主窗口时'),
            DropdownButton<WindowCloseAction>(
              isExpanded: true,
              value: WindowCloseAction.read(widget.runtime),
              items: WindowCloseAction.values.map((action) {
                AppLog.instance.trace(
                  "lib/pages/window_close_preferences.dart::_WindowClosePreferenceState.build.closure#1.closure#1",
                );
                return DropdownMenuItem(
                  value: action,
                  child: Text(action.label),
                );
              }).toList(),
              onChanged: _saving ? null : _save,
            ),
            const Text('小窗关闭后最小化到任务栏，播放继续。'),
            if (_error != null)
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
          ],
        );
      },
    );
  }
}
