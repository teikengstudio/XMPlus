import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import 'android_platform.dart';
import 'app_log.dart';

/// Exports only a session returned by the logger, never an arbitrary path.
/// A null result means the caller or the platform save dialog cancelled.
/// [canStart] gates preparation; an opened save dialog can still finish.
Future<Uri?> exportLogSession(LogSession session, {bool Function()? canStart}) {
  AppLog.instance.trace("lib/services/log_export.dart::exportLogSession");
  return AppLog.instance.runWithErrorScope(() async {
    AppLog.instance.trace(
      "lib/services/log_export.dart::exportLogSession.closure#1",
    );

    if (canStart?.call() == false) return null;
    final log = AppLog.instance;
    final sessions = await log.sessions();
    if (canStart?.call() == false) return null;
    if (!sessions.any((candidate) {
      AppLog.instance.trace(
        "lib/services/log_export.dart::exportLogSession.closure#1.closure#1",
      );
      return candidate.fileName == session.fileName &&
          candidate.path == session.path;
    })) {
      throw const FileSystemException('所选日志会话已不可用，请刷新后重试');
    }
    final name = session.fileName;
    if (p.basename(name) != name ||
        name.contains('/') ||
        name.contains(r'\') ||
        !RegExp(r'^XMPlus-\d+-\d+-[A-Za-z0-9_-]+\.log$').hasMatch(name)) {
      throw ArgumentError.value(name, 'fileName', '日志文件名无效');
    }
    final snapshot = await log.snapshot(name);
    if (canStart?.call() == false) return null;
    if (Platform.isAndroid) {
      return AndroidPlatform.exportLogSnapshot(snapshot, name);
    }
    if (!Platform.isWindows) throw UnsupportedError('当前平台不支持日志文件导出');
    final selected = await FilePicker.getDirectoryPath(
      dialogTitle: '选择日志导出文件夹',
    );
    if (selected == null) return null;
    final directory = await Directory(selected).resolveSymbolicLinks();
    final source = snapshot.sourcePath;
    final canonicalSource = source == null
        ? null
        : await File(source).resolveSymbolicLinks();
    var target = File(p.join(directory, name));
    if (canonicalSource != null && p.equals(target.path, canonicalSource)) {
      throw const FileSystemException('不能覆盖源日志，请选择其他导出目录');
    }
    while (true) {
      final type = await FileSystemEntity.type(target.path, followLinks: false);
      if (type == FileSystemEntityType.link ||
          type == FileSystemEntityType.directory) {
        throw const FileSystemException('导出目标不能是链接或目录');
      }
      if (type == FileSystemEntityType.notFound) break;
      target = File(
        p.join(
          directory,
          '${p.basenameWithoutExtension(name)}-export-${const Uuid().v4()}.log',
        ),
      );
    }
    var created = false;
    RandomAccessFile? output;
    try {
      await target.create(exclusive: true);
      created = true;
      if (await FileSystemEntity.type(target.path, followLinks: false) !=
          FileSystemEntityType.file) {
        throw const FileSystemException('导出目标已改变');
      }
      output = await target.open(mode: FileMode.writeOnlyAppend);
      await for (final chunk in snapshot.openRead()) {
        for (var offset = 0; offset < chunk.length; offset += 64 * 1024) {
          final end = offset + 64 * 1024 < chunk.length
              ? offset + 64 * 1024
              : chunk.length;
          await output.writeFrom(chunk, offset, end);
        }
      }
      await output.flush();
      await output.close();
      output = null;
      return target.uri;
    } catch (_) {
      try {
        await output?.close();
      } catch (error, stack) {
        log.write(
          AppLogLevel.warning,
          'log_export',
          'Closing failed log export output failed',
          error: error,
          stackTrace: stack,
          promptUser: false,
        );
      }
      if (created) {
        try {
          if (await FileSystemEntity.type(target.path, followLinks: false) ==
              FileSystemEntityType.file) {
            await target.delete();
          }
        } catch (error, stack) {
          log.write(
            AppLogLevel.warning,
            'log_export',
            'Removing incomplete log export failed',
            error: error,
            stackTrace: stack,
            promptUser: false,
          );
        }
      }
      rethrow;
    }
  });
}
