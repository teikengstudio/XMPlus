import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../common/widgets/adaptive_text.dart';
import '../services/app_log.dart';
import '../services/app_runtime.dart';
import '../services/error_reporting.dart';
import '../services/log_export.dart';
import '../storage/app_storage.dart';

class DeveloperSettingsPage extends StatefulWidget {
  const DeveloperSettingsPage({required this.runtime, super.key});

  final AppRuntime runtime;

  @override
  State<DeveloperSettingsPage> createState() {
    AppLog.instance.trace(
      "lib/pages/developer_settings_page.dart::DeveloperSettingsPage.createState",
    );
    return _DeveloperSettingsPageState();
  }
}

class _DeveloperSettingsPageState extends State<DeveloperSettingsPage> {
  final _log = AppLog.instance;
  List<LogSession> _sessions = const [];
  String? _selected;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    AppLog.instance.trace(
      "lib/pages/developer_settings_page.dart::_DeveloperSettingsPageState.initState",
    );

    super.initState();
    _refresh();
  }

  Future<void> _refresh() {
    AppLog.instance.trace(
      "lib/pages/developer_settings_page.dart::_DeveloperSettingsPageState._refresh",
    );
    return _log.runWithErrorScope(() async {
      AppLog.instance.trace(
        "lib/pages/developer_settings_page.dart::_DeveloperSettingsPageState._refresh.closure#1",
      );

      if (_busy) return;
      setState(() {
        AppLog.instance.trace(
          "lib/pages/developer_settings_page.dart::_DeveloperSettingsPageState._refresh.closure#1.closure#1",
        );

        _busy = true;
        _error = null;
      });
      try {
        await _log.flush();
        final sessions = (await _log.sessions())
            .take(7)
            .toList(growable: false);
        if (!mounted) return;
        setState(() {
          AppLog.instance.trace(
            "lib/pages/developer_settings_page.dart::_DeveloperSettingsPageState._refresh.closure#1.closure#2",
          );

          _sessions = sessions;
          if (!sessions.any((session) {
            AppLog.instance.trace(
              "lib/pages/developer_settings_page.dart::_DeveloperSettingsPageState._refresh.closure#1.closure#2.closure#1",
            );
            return session.fileName == _selected;
          })) {
            _selected =
                sessions
                    .where((session) {
                      AppLog.instance.trace(
                        "lib/pages/developer_settings_page.dart::_DeveloperSettingsPageState._refresh.closure#1.closure#2.closure#2",
                      );
                      return session.isCurrent;
                    })
                    .firstOrNull
                    ?.fileName ??
                sessions.firstOrNull?.fileName;
          }
        });
      } catch (error, stack) {
        if (!_log.errorWasRecorded(error)) {
          _log.write(
            AppLogLevel.warning,
            'log_export',
            'Reading log sessions failed',
            error: error,
            stackTrace: stack,
            promptUser: false,
          );
        }
        if (mounted)
          setState(() {
            AppLog.instance.trace(
              "lib/pages/developer_settings_page.dart::_DeveloperSettingsPageState._refresh.closure#1.closure#3",
            );
            _error = '无法读取日志会话：$error';
          });
      } finally {
        if (mounted)
          setState(() {
            AppLog.instance.trace(
              "lib/pages/developer_settings_page.dart::_DeveloperSettingsPageState._refresh.closure#1.closure#4",
            );
            _busy = false;
          });
      }
    });
  }

  Future<void> _save(String key, Object value) {
    AppLog.instance.trace(
      "lib/pages/developer_settings_page.dart::_DeveloperSettingsPageState._save",
    );
    return _log.runWithErrorScope(() async {
      AppLog.instance.trace(
        "lib/pages/developer_settings_page.dart::_DeveloperSettingsPageState._save.closure#1",
      );

      if (_busy) return;
      setState(() {
        AppLog.instance.trace(
          "lib/pages/developer_settings_page.dart::_DeveloperSettingsPageState._save.closure#1.closure#1",
        );

        _busy = true;
        _error = null;
      });
      try {
        await widget.runtime.storage.transaction((state) {
          AppLog.instance.trace(
            "lib/pages/developer_settings_page.dart::_DeveloperSettingsPageState._save.closure#1.closure#2",
          );

          final settings = state['settings'] as Map;
          final existing = settings['development'];
          final development = existing is Map ? existing : <String, dynamic>{};
          development[key] = value;
          settings['development'] = development;
        });
        AppRuntime.applyLogSettings(
          widget.runtime.storage.state['settings'] as Map,
        );
        widget.runtime.changed();
        _log.write(
          AppLogLevel.info,
          'settings',
          '开发设置已保存',
          data: {'key': key, 'value': value},
        );
      } catch (error, stack) {
        if (!(error is StorageException &&
                const {'too_large', 'secret_in_state'}.contains(error.code)) &&
            !_log.errorWasRecorded(error)) {
          _log.write(
            AppLogLevel.error,
            'settings',
            'Saving developer settings failed',
            error: error,
            stackTrace: stack,
            promptUser: true,
          );
        }
        if (mounted) {
          setState(() {
            AppLog.instance.trace(
              "lib/pages/developer_settings_page.dart::_DeveloperSettingsPageState._save.closure#1.closure#3",
            );
            _error = '设置保存失败，原设置已保留：$error';
          });
        }
      } finally {
        if (mounted)
          setState(() {
            AppLog.instance.trace(
              "lib/pages/developer_settings_page.dart::_DeveloperSettingsPageState._save.closure#1.closure#4",
            );
            _busy = false;
          });
      }
    });
  }

  Future<void> _export({required bool clipboard}) {
    AppLog.instance.trace(
      "lib/pages/developer_settings_page.dart::_DeveloperSettingsPageState._export",
    );
    return _log.runWithErrorScope(() async {
      AppLog.instance.trace(
        "lib/pages/developer_settings_page.dart::_DeveloperSettingsPageState._export.closure#1",
      );

      if (_busy) return;
      final session = _sessions.where((session) {
        AppLog.instance.trace(
          "lib/pages/developer_settings_page.dart::_DeveloperSettingsPageState._export.closure#1.closure#1",
        );
        return session.fileName == _selected;
      }).firstOrNull;
      if (session == null) return;
      setState(() {
        AppLog.instance.trace(
          "lib/pages/developer_settings_page.dart::_DeveloperSettingsPageState._export.closure#1.closure#2",
        );

        _busy = true;
        _error = null;
      });
      try {
        if (clipboard) {
          final snapshot = await _log.snapshot(session.fileName);
          if (!snapshot.canCopyToClipboard(android: Platform.isAndroid)) {
            throw StateError('日志过大，无法完整复制，请导出到文件');
          }
          final text = await snapshot.readForClipboard(
            android: Platform.isAndroid,
          );
          await Clipboard.setData(ClipboardData(text: text));
          if (mounted) _message('日志已复制');
        } else {
          final destination = await exportLogSession(session);
          if (destination != null && mounted) _message('日志已导出');
        }
      } catch (error, stack) {
        if (!_log.errorWasRecorded(error)) {
          _log.write(
            AppLogLevel.warning,
            'log_export',
            'Exporting log failed',
            error: error,
            stackTrace: stack,
            promptUser: false,
          );
        }
        if (mounted) {
          setState(() {
            AppLog.instance.trace(
              "lib/pages/developer_settings_page.dart::_DeveloperSettingsPageState._export.closure#1.closure#3",
            );

            _error = error is StateError
                ? '${error.message}'
                : '${clipboard ? '复制' : '导出'}日志失败：$error';
          });
        }
      } finally {
        if (mounted)
          setState(() {
            AppLog.instance.trace(
              "lib/pages/developer_settings_page.dart::_DeveloperSettingsPageState._export.closure#1.closure#4",
            );
            _busy = false;
          });
      }
    });
  }

  void _message(String message) {
    AppLog.instance.trace(
      "lib/pages/developer_settings_page.dart::_DeveloperSettingsPageState._message",
    );

    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  static String _size(int bytes) {
    AppLog.instance.trace(
      "lib/pages/developer_settings_page.dart::_DeveloperSettingsPageState._size",
    );

    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KiB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MiB';
  }

  static String _sessionLabel(LogSession session) {
    AppLog.instance.trace(
      "lib/pages/developer_settings_page.dart::_DeveloperSettingsPageState._sessionLabel",
    );

    final time = session.startedAt.toLocal().toString().split('.').first;
    return '${session.isCurrent ? '本次运行 · ' : ''}$time · ${_size(session.byteLength)}';
  }

  @override
  Widget build(BuildContext context) {
    AppLog.instance.trace(
      "lib/pages/developer_settings_page.dart::_DeveloperSettingsPageState.build",
    );

    return ListenableBuilder(
      listenable: widget.runtime,
      builder: (context, _) {
        AppLog.instance.trace(
          "lib/pages/developer_settings_page.dart::_DeveloperSettingsPageState.build.closure#1",
        );
        return StreamBuilder<void>(
          stream: _log.status,
          builder: (context, _) {
            AppLog.instance.trace(
              "lib/pages/developer_settings_page.dart::_DeveloperSettingsPageState.build.closure#1.closure#1",
            );
            return ListView(
              padding: const EdgeInsets.all(20),
              children: [
                AdaptiveText(
                  '开发',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 8),
                if (_busy) const LinearProgressIndicator(),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Text(
                      _error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                const SizedBox(height: 16),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        AdaptiveText(
                          '运行日志',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 4),
                        const Text('记录运行情况，方便排查问题。'),
                        const SizedBox(height: 12),
                        InputDecorator(
                          decoration: const InputDecoration(
                            labelText: '记录详细程度',
                          ),
                          child: DropdownButtonHideUnderline(
                            child: DropdownButton<AppLogLevel>(
                              isExpanded: true,
                              value: _log.level,
                              items: [
                                for (final level in AppLogLevel.values)
                                  DropdownMenuItem(
                                    value: level,
                                    child: Text(switch (level) {
                                      AppLogLevel.debug => '详细',
                                      AppLogLevel.info => '普通',
                                      AppLogLevel.warning => '警告',
                                      AppLogLevel.error => '错误',
                                      AppLogLevel.fatal => '严重错误',
                                    }),
                                  ),
                              ],
                              onChanged: _busy
                                  ? null
                                  : (level) {
                                      AppLog.instance.trace(
                                        "lib/pages/developer_settings_page.dart::_DeveloperSettingsPageState.build.closure#1.closure#1.closure#1",
                                      );

                                      if (level != null)
                                        _save('logLevel', level.name);
                                    },
                            ),
                          ),
                        ),
                        const SizedBox(height: 16),
                        InputDecorator(
                          decoration: const InputDecoration(labelText: '日志文件'),
                          child: DropdownButtonHideUnderline(
                            child: DropdownButton<String>(
                              isExpanded: true,
                              value: _selected,
                              hint: const Text('暂无日志'),
                              items: [
                                for (final session in _sessions)
                                  DropdownMenuItem(
                                    value: session.fileName,
                                    child: Text(
                                      _sessionLabel(session),
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                              ],
                              onChanged: _busy
                                  ? null
                                  : (value) {
                                      AppLog.instance.trace(
                                        "lib/pages/developer_settings_page.dart::_DeveloperSettingsPageState.build.closure#1.closure#1.closure#2",
                                      );

                                      setState(() {
                                        AppLog.instance.trace(
                                          "lib/pages/developer_settings_page.dart::_DeveloperSettingsPageState.build.closure#1.closure#1.closure#2.closure#1",
                                        );
                                        _selected = value;
                                      });
                                    },
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            FilledButton.icon(
                              onPressed: _busy || _selected == null
                                  ? null
                                  : () {
                                      AppLog.instance.trace(
                                        "lib/pages/developer_settings_page.dart::_DeveloperSettingsPageState.build.closure#1.closure#1.closure#3",
                                      );
                                      _export(clipboard: false);
                                    },
                              icon: const Icon(Icons.save_alt),
                              label: const Text('导出到文件'),
                            ),
                            OutlinedButton.icon(
                              onPressed: _busy || _selected == null
                                  ? null
                                  : () {
                                      AppLog.instance.trace(
                                        "lib/pages/developer_settings_page.dart::_DeveloperSettingsPageState.build.closure#1.closure#1.closure#4",
                                      );
                                      _export(clipboard: true);
                                    },
                              icon: const Icon(Icons.copy_outlined),
                              label: const Text('复制到剪贴板'),
                            ),
                            TextButton.icon(
                              onPressed: _busy ? null : _refresh,
                              icon: const Icon(Icons.refresh),
                              label: const Text('刷新'),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        const Text('保存位置'),
                        SelectableText(_log.directory ?? '尚未取得日志目录'),
                        if (_log.persistenceError != null) ...[
                          const SizedBox(height: 12),
                          Text(
                            '日志写入失败，当前导出仅含保留片段。\n${_log.persistenceError}',
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.error,
                            ),
                          ),
                          Text(
                            '保留 ${_size(_log.retainedBytes)}；累计丢失 ${_log.lostRecords} 条 / ${_size(_log.lostBytes)}。',
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Card(
                  child: SwitchListTile.adaptive(
                    title: const Text('问题反馈提醒'),
                    subtitle: const Text('出现错误时提醒你反馈。'),
                    value: _log.promptLogUpload,
                    onChanged: _busy
                        ? null
                        : (value) {
                            AppLog.instance.trace(
                              "lib/pages/developer_settings_page.dart::_DeveloperSettingsPageState.build.closure#1.closure#1.closure#5",
                            );
                            _save('promptLogUpload', value);
                          },
                  ),
                ),
                const SizedBox(height: 16),
                ValueListenableBuilder<ErrorReportingStatus>(
                  valueListenable: ErrorReporting.status,
                  builder: (context, status, _) {
                    AppLog.instance.trace(
                      "lib/pages/developer_settings_page.dart::_DeveloperSettingsPageState.build.closure#1.closure#1.closure#6",
                    );
                    return Card(
                      child: ListTile(
                        leading: const Icon(Icons.bug_report_outlined),
                        title: const Text('错误报告'),
                        subtitle: const Text('自动反馈运行问题。'),
                        trailing: Text(switch (status) {
                          ErrorReportingStatus.unconfigured => '未配置',
                          ErrorReportingStatus.active => '已启用',
                          ErrorReportingStatus.initializing => '初始化中',
                          ErrorReportingStatus.failed => '未启用',
                        }),
                      ),
                    );
                  },
                ),
              ],
            );
          },
        );
      },
    );
  }
}
