import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../common/widgets/adaptive_text.dart';
import '../common/widgets/confirmation_dialog.dart';
import '../models/xmly_models.dart';
import '../services/account_service.dart';
import '../services/app_log.dart';
import '../services/app_runtime.dart';
import '../storage/app_storage.dart';
import '../storage/config_archive.dart';

class BackupPage extends StatefulWidget {
  const BackupPage({required this.runtime, this.onChanged, super.key});
  final AppRuntime runtime;
  final VoidCallback? onChanged;

  @override
  State<BackupPage> createState() {
    AppLog.instance.trace("lib/pages/backup_page.dart::BackupPage.createState");
    return _BackupPageState();
  }
}

class _BackupPageState extends State<BackupPage> {
  late final ConfigArchive _archive = widget.runtime.backupArchive;
  bool _includeAccount = false;
  bool _busy = false;
  bool _waitingForReload = false;
  String? _message;
  String? get _statusMessage {
    AppLog.instance.trace(
      "lib/pages/backup_page.dart::_BackupPageState._statusMessage.get",
    );
    return _waitingForReload && !widget.runtime.restoreNeedsReload
        ? '备份已恢复，未完成任务保持暂停'
        : _message;
  }

  Future<bool> _confirm(String title, Widget content, String action) {
    AppLog.instance.trace(
      "lib/pages/backup_page.dart::_BackupPageState._confirm",
    );
    return showConfirmationDialog(
      context,
      Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
      content: SingleChildScrollView(child: content),
      confirmLabel: action,
    );
  }

  Future<void> _run(Future<void> Function() action) {
    AppLog.instance.trace("lib/pages/backup_page.dart::_BackupPageState._run");
    return AppLog.instance.runWithErrorScope(() async {
      AppLog.instance.trace(
        "lib/pages/backup_page.dart::_BackupPageState._run.closure#1",
      );

      if (_busy || !mounted) return;
      setState(() {
        AppLog.instance.trace(
          "lib/pages/backup_page.dart::_BackupPageState._run.closure#1.closure#1",
        );

        _busy = true;
        _waitingForReload = false;
        _message = null;
      });
      try {
        await action();
      } catch (error, stack) {
        final expected =
            error is ConfigArchiveException ||
            error is FormatException ||
            (error is StorageException &&
                const {'too_large', 'secret_in_state'}.contains(error.code)) ||
            (error is AccountException &&
                const {
                  'credential_missing',
                  'credential_mismatch',
                  'missing',
                  'paused',
                  'closed',
                  'not_loaded',
                  'quota_invalid',
                  'unsettled',
                  'usage_uncertain',
                  'archive_invalid',
                }.contains(error.code)) ||
            (error is XmlyException &&
                const {
                  'invalid_credentials',
                  'login_required',
                  'login_expired',
                  'auth_required',
                  'confirmation_required',
                  'confirmation_changed',
                  'insufficient_quota',
                  'usage_uncertain',
                  'request_cancelled',
                  'client_closed',
                }.contains(error.code));
        if (!expected && !AppLog.instance.errorWasRecorded(error)) {
          AppLog.instance.write(
            AppLogLevel.error,
            'backup',
            'Backup action failed',
            error: error,
            stackTrace: stack,
            promptUser: true,
          );
        }
        if (!mounted) return;
        setState(() {
          AppLog.instance.trace(
            "lib/pages/backup_page.dart::_BackupPageState._run.closure#1.closure#2",
          );
          _message = switch (error) {
            ConfigArchiveException e => e.message,
            AccountException e => e.message,
            StorageException e => e.message,
            XmlyException e => e.message,
            _ => '操作失败，原资料已保留，请检查文件和保存位置',
          };
        });
      } finally {
        if (mounted)
          setState(() {
            AppLog.instance.trace(
              "lib/pages/backup_page.dart::_BackupPageState._run.closure#1.closure#3",
            );
            _busy = false;
          });
      }
    });
  }

  Future<void> _export() {
    AppLog.instance.trace(
      "lib/pages/backup_page.dart::_BackupPageState._export",
    );
    return _run(() async {
      AppLog.instance.trace(
        "lib/pages/backup_page.dart::_BackupPageState._export.closure#1",
      );

      final includeAccount = _includeAccount;
      if (includeAccount &&
          !await _confirm(
            '导出登录信息？',
            const Text('此备份未加密，包含登录凭据。拿到文件的人可能使用你的账号，请妥善保存，不要发送给他人。'),
            '仍要导出',
          ))
        return;
      if (!mounted) return;
      final bytes = await _archive.export(includeAccount: includeAccount);
      if (!mounted) return;
      final date = DateTime.now().toIso8601String().substring(0, 10);
      final saved = await FilePicker.saveFile(
        fileName: 'XMPlus-$date${includeAccount ? '-含账号' : ''}.zip',
        bytes: Uint8List.fromList(bytes),
        mimeType: 'application/zip',
        dialogTitle: '保存备份',
      );
      if (saved != null && mounted)
        setState(() {
          AppLog.instance.trace(
            "lib/pages/backup_page.dart::_BackupPageState._export.closure#1.closure#1",
          );
          _message = '备份已保存';
        });
    });
  }

  Future<void> _import() {
    AppLog.instance.trace(
      "lib/pages/backup_page.dart::_BackupPageState._import",
    );
    return _run(() async {
      AppLog.instance.trace(
        "lib/pages/backup_page.dart::_BackupPageState._import.closure#1",
      );

      final file = await FilePicker.pickFile(
        dialogTitle: '选择 XMPlus 备份',
        type: FileType.custom,
        allowedExtensions: ['zip'],
      );
      if (file == null || !mounted) return;
      final length = await file.length();
      if (length != null && length > ConfigArchive.maxBytes) {
        throw const ConfigArchiveException('备份超过 64 MiB');
      }
      // A bounded stream also handles providers which do not report file length.
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in file.readAsByteStream()) {
        if (bytes.length + chunk.length > ConfigArchive.maxBytes) {
          throw const ConfigArchiveException('备份超过 64 MiB');
        }
        bytes.add(chunk);
      }
      final draft = await _archive.inspect(bytes.takeBytes());
      if (!mounted) return;
      final replacements = <String, String>{};
      for (final oldRoot in draft.missingDirectories) {
        if (!await _confirm(
          '下载目录已失效',
          Text('原目录：$oldRoot\n请选择新的下载目录；旧音频和缓存不会自动复制。'),
          '选择目录',
        ))
          return;
        if (!mounted) return;
        final selected = await FilePicker.getDirectoryPath(
          dialogTitle: '选择新的下载目录',
        );
        if (selected == null || !mounted) return;
        replacements[oldRoot] = selected;
      }
      final accepted = await _confirm(
        '恢复备份',
        Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final line in draft.summary)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text('• $line'),
              ),
            for (final replacement in replacements.entries)
              Text('${replacement.key}\n→ ${replacement.value}\n'),
            const Text('取消不会修改现有资料。恢复后不会自动播放或开始下载。'),
          ],
        ),
        '确认恢复',
      );
      if (!accepted || !mounted) return;
      try {
        await widget.runtime.restoreBackup(draft, relocatedRoots: replacements);
      } catch (_) {
        if (!widget.runtime.restoreNeedsReload) rethrow;
        if (mounted)
          setState(() {
            AppLog.instance.trace(
              "lib/pages/backup_page.dart::_BackupPageState._import.closure#1.closure#1",
            );
            _waitingForReload = true;
            _message = '备份已保存，但加载未完成；请重试加载或退出后重新打开应用';
          });
        return;
      } finally {
        widget.onChanged?.call();
      }
      if (mounted)
        setState(() {
          AppLog.instance.trace(
            "lib/pages/backup_page.dart::_BackupPageState._import.closure#1.closure#2",
          );
          _message = '备份已恢复，未完成任务保持暂停';
        });
    });
  }

  @override
  Widget build(BuildContext context) {
    AppLog.instance.trace("lib/pages/backup_page.dart::_BackupPageState.build");
    return ListenableBuilder(
      listenable: widget.runtime,
      builder: (context, _) {
        AppLog.instance.trace(
          "lib/pages/backup_page.dart::_BackupPageState.build.closure#1",
        );
        return _content(context);
      },
    );
  }

  Widget _content(BuildContext context) {
    AppLog.instance.trace(
      "lib/pages/backup_page.dart::_BackupPageState._content",
    );
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: ListView(
          padding: EdgeInsets.all(
            MediaQuery.sizeOf(context).width < 320 ? 8 : 16,
          ),
          children: [
            AdaptiveText(
              '备份与恢复',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 20),
            Card(
              child: Column(
                children: [
                  SwitchListTile(
                    title: const Text('包含登录信息'),
                    subtitle: const Text('默认备份设置、书签和任务记录，不包含音频或云端收藏、历史'),
                    value: _includeAccount,
                    onChanged: _busy
                        ? null
                        : (value) {
                            AppLog.instance.trace(
                              "lib/pages/backup_page.dart::_BackupPageState._content.closure#1",
                            );
                            setState(() {
                              AppLog.instance.trace(
                                "lib/pages/backup_page.dart::_BackupPageState._content.closure#1.closure#1",
                              );
                              _includeAccount = value;
                            });
                          },
                  ),
                  if (_includeAccount)
                    const Padding(
                      padding: EdgeInsets.fromLTRB(16, 0, 16, 12),
                      child: Text('未加密，包含登录凭据。请勿分享此备份。'),
                    ),
                  ListTile(
                    leading: const Icon(Icons.save_alt),
                    title: const AdaptiveText('导出备份'),
                    enabled: !_busy,
                    onTap: _busy ? null : _export,
                  ),
                  ListTile(
                    leading: const Icon(Icons.settings_backup_restore),
                    title: const AdaptiveText('恢复备份'),
                    subtitle: const Text('先查看恢复内容，再确认'),
                    enabled: !_busy,
                    onTap: _busy ? null : _import,
                  ),
                ],
              ),
            ),
            if (_busy)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 16),
                child: LinearProgressIndicator(),
              ),
            if (_statusMessage != null)
              Padding(
                padding: const EdgeInsets.only(top: 16),
                child: Semantics(
                  liveRegion: true,
                  child: Text(_statusMessage!),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
