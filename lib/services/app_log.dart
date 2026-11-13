import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

enum AppLogLevel { debug, info, warning, error, fatal }

/// This file deliberately has no method traces: logging must not log itself.
class AppLog {
  AppLog({
    required Directory directory,
    required String sessionId,
    required DateTime startedAt,
    int? processId,
  }) : _root = directory,
       _sessionId = sessionId,
       _startedAt = startedAt.toUtc(),
       _processId = processId ?? pid;

  AppLog._();
  static final instance = AppLog._();
  static const retainedBytesLimit = 1024 * 1024;
  static const batchBytes = 64 * 1024;
  static const cookieReplacement = '[REDACTED COOKIE]';
  static final _ownedName = RegExp(
    r'^XMPlus-(\d+)-(\d+)-([A-Za-z0-9_-]+)\.log$',
  );
  static final _safeId = RegExp(r'^[A-Za-z0-9_-]+$');

  Directory? _root;
  String? _sessionId;
  DateTime? _startedAt;
  int? _processId;
  String? _fileName;
  File? _file;
  bool _initialized = false, _closed = false, _inside = false;
  bool _automaticFlushQueued = false, _promptClaimed = false;
  bool _bootstrap = false;
  bool _prepared = false, _urgentFlush = false;
  String? _initialTrace;
  Future<void>? _initializing;
  Future<void> _work = Future<void>.value();
  Timer? _timer;
  final _pending = ListQueue<_LogLine>();
  int _pendingBytes = 0, _sequence = 0, _committedLength = 0;
  int _missingRecords = 0, _missingBytes = 0;
  int _lostRecords = 0, _lostBytes = 0;
  String? _persistenceError;
  AppLogLevel _level = AppLogLevel.warning;
  bool _pendingError = false;
  bool promptLogUpload = true;
  final _status = StreamController<void>.broadcast();
  final _errors = StreamController<void>.broadcast();
  final _errorScopeKey = Object();
  int _nextErrorScopeId = 0;

  /// Receives immutable Cookie-cleaned values plus transient original error
  /// identity. A throwing/async-failing telemetry sink is inert.
  FutureOr<void> Function(AppLogRecord record)? sink;

  AppLogLevel get level => _level;
  set level(AppLogLevel value) {
    _bootstrap = false;
    _level = value;
    _notify();
  }

  String? get directory => _root?.path;
  String? get currentFileName => _fileName;
  String? get currentFilePath => _file?.path;
  String? get sessionId => _sessionId;
  DateTime? get startedAt => _startedAt;
  String? get persistenceError => _persistenceError;
  int get retainedBytes => _pendingBytes;
  int get lostRecords => _lostRecords;
  int get lostBytes => _lostBytes;
  bool get hasPendingErrors => _pendingError;
  Stream<void> get status => _status.stream;
  Stream<void> get pendingErrors => _errors.stream;

  static AppLogLevel parseLevel(Object? value) => AppLogLevel.values.firstWhere(
    (level) => level.name == value,
    orElse: () => AppLogLevel.warning,
  );

  /// Windows uses this synchronous process gate. Android supplies its native
  /// process-wide claim callback; it must be called only immediately before UI.
  Future<bool> claimUploadPrompt({
    Future<bool> Function()? claimProcess,
  }) async {
    if (!promptLogUpload || !_pendingError || _promptClaimed) return false;
    _promptClaimed = true;
    try {
      if (claimProcess != null && !await claimProcess()) return false;
      _pendingError = false;
      return true;
    } catch (_) {
      _promptClaimed = false;
      return false;
    }
  }

  void requestUploadPrompt() {
    if (_closed || _promptClaimed || _pendingError) return;
    _pendingError = true;
    if (!_errors.isClosed) _errors.add(null);
  }

  _ErrorScope? get _currentErrorScope {
    var scope = Zone.current[_errorScopeKey] as _ErrorScope?;
    while (scope != null && !scope.active) {
      scope = scope.parent;
    }
    return scope;
  }

  Future<T> runWithErrorScope<T>(Future<T> Function() action) {
    final scope = _ErrorScope(++_nextErrorScopeId, _currentErrorScope);
    return runZoned(() async {
      try {
        return await action();
      } finally {
        scope.active = false;
        scope.errors?.clear();
        scope.errors = null;
      }
    }, zoneValues: {_errorScopeKey: scope});
  }

  bool errorWasRecorded(Object error) =>
      _currentErrorScope?.errors?.contains(error) ?? false;

  void linkError(Object replacement, Object original) {
    final scope = _currentErrorScope;
    if (scope != null && (scope.errors?.contains(original) ?? false)) {
      scope.record(replacement);
    }
  }

  Future<void> initialize() => _initializing ??= _initialize();

  Future<void> _initialize() async {
    try {
      _root ??= Directory(
        p.join((await getApplicationSupportDirectory()).path, 'logs'),
      );
      await _readProcessSession();
    } catch (error) {
      _fail(error);
    }
    _sessionId ??= const Uuid().v4();
    _startedAt ??= DateTime.now().toUtc();
    _processId ??= pid;
    try {
      if (!_safeId.hasMatch(_sessionId!)) {
        throw const FormatException('Invalid log session ID');
      }
      _fileName =
          'XMPlus-${_startedAt!.microsecondsSinceEpoch}-$_processId-$_sessionId.log';
      final root = _root;
      if (root != null) _file = File(p.join(root.path, _fileName!));
      await _prepareFile();
    } catch (error) {
      _fail(error);
    }
    _initialized = true;
    _bootstrap = true;
    _level = AppLogLevel.debug;
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_pending.isNotEmpty || _persistenceError != null) _scheduleFlush();
    });
    final initial = _initialTrace;
    _initialTrace = null;
    if (initial != null) trace(initial);
    _notify();
  }

  Future<void> _readProcessSession() async {
    if (_sessionId != null) return;
    final file = File(p.join(_root!.path, '.process-session.json'));
    if (await FileSystemEntity.type(file.path, followLinks: false) !=
        FileSystemEntityType.file)
      return;
    // Application writes this tiny metadata file atomically, once per OS process.
    if (await file.length() > 4096)
      throw const FormatException('Invalid process session metadata');
    final value = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    final id = value['sessionId'];
    final process = value['pid'];
    final start = value['startedAt'];
    final date = start is int
        ? DateTime.fromMicrosecondsSinceEpoch(start, isUtc: true)
        : DateTime.tryParse('$start')?.toUtc();
    if (id is! String ||
        !_safeId.hasMatch(id) ||
        process is! int ||
        process <= 0 ||
        date == null) {
      throw const FormatException('Invalid process session metadata');
    }
    // A failed native AtomicFile update can leave the previous process record.
    if (process != pid) return;
    _sessionId = id;
    _processId = process;
    _startedAt = date;
  }

  Future<void> _checkRoot() async {
    final root = _root;
    if (root == null) throw const FileSystemException('日志目录尚未初始化');
    final type = await FileSystemEntity.type(root.path, followLinks: false);
    if (type == FileSystemEntityType.notFound)
      await root.create(recursive: true);
    if (await FileSystemEntity.type(root.path, followLinks: false) !=
        FileSystemEntityType.directory) {
      throw const FileSystemException('日志目录不可用或为链接');
    }
  }

  Future<void> _prepareFile() async {
    await _checkRoot();
    final file = _file;
    if (file == null) throw const FileSystemException('日志会话尚未初始化');
    final type = await FileSystemEntity.type(file.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) {
      final sessions = await _listSessions();
      // Delete only owned, ordinary files; never follow a link, including a link
      // substituted since enumeration. The current process has a single writer.
      for (final session in sessions.skip(6)) {
        final path = session.path;
        if (path != null &&
            await FileSystemEntity.type(path, followLinks: false) ==
                FileSystemEntityType.file) {
          await File(path).delete();
        }
      }
      await file.create(exclusive: true);
      _committedLength = 0;
    } else if (type == FileSystemEntityType.file) {
      final handle = await file.open(mode: FileMode.append);
      try {
        final end = await _lastNewline(handle, await handle.length());
        _committedLength = end;
        await handle.truncate(end);
        if (end > 0) {
          final start = await _lastNewline(handle, end - 1);
          await handle.setPosition(start);
          final prefix = utf8.decode(
            await handle.read((end - start).clamp(0, batchBytes)),
            allowMalformed: true,
          );
          final match = RegExp(r'"sequence":(\d+)').firstMatch(prefix);
          if (match == null)
            throw const FormatException('Last log record has no sequence');
          final offset = int.parse(match.group(1)!) + 1;
          if (_pending.isNotEmpty) {
            final rebased = _pending
                .map((line) {
                  final values = jsonDecode(
                    utf8.decode(line.bytes),
                  ) as Map<String, dynamic>;
                  values['sequence'] = line.sequence + offset;
                  values['sessionId'] = _sessionId;
                  return _LogLine(
                    line.sequence + offset,
                    Uint8List.fromList(utf8.encode('${jsonEncode(values)}\n')),
                  );
                })
                .toList(growable: false);
            _pending.clear();
            _pending.addAll(rebased);
            _pendingBytes = rebased.fold<int>(
              0,
              (sum, line) => sum + line.bytes.length,
            );
          }
          _sequence += offset;
        }
      } finally {
        await handle.close();
      }
    } else {
      throw const FileSystemException('日志文件不能是链接或目录');
    }
    _prepared = true;
  }

  void trace(String method) {
    if (_inside || _closed) return;
    if (!_initialized) {
      _initialTrace ??= method;
      return;
    }
    if (_level != AppLogLevel.debug) return;
    write(
      AppLogLevel.debug,
      'method',
      method,
      data: _bootstrap ? const {'phase': 'bootstrap'} : null,
    );
  }

  void write(
    AppLogLevel level,
    String category,
    String message, {
    Map<String, Object?>? data,
    Object? error,
    StackTrace? stackTrace,
    bool networkError = false,
    bool promptUser = false,
    String? requestId,
  }) {
    if (_inside || _closed) return;
    if (promptUser) requestUploadPrompt();
    if (networkError) level = AppLogLevel.error;
    if (!networkError && level.index < _level.index) return;
    _inside = true;
    try {
      final values = <String, Object?>{
        'timestamp': DateTime.now().toUtc().toIso8601String(),
        'sessionId': _sessionId,
        'sequence': _sequence++,
        'level': level.name.toUpperCase(),
        'category': category,
        'message': message,
        if (requestId != null) 'requestId': requestId,
        if (data != null) 'data': data,
        if (error != null) 'error': '$error',
        if (stackTrace != null) 'stackTrace': '$stackTrace',
      };
      final cleaned = redact(values) as Map<String, Object?>;
      final bytes = Uint8List.fromList(utf8.encode('${jsonEncode(cleaned)}\n'));
      _pending.add(_LogLine(values['sequence'] as int, bytes));
      _pendingBytes += bytes.length;
      if (_persistenceError != null) _boundTail();
      final scope = _currentErrorScope;
      if (error != null && level.index >= AppLogLevel.error.index) {
        scope?.record(error);
      }
      final callback = sink;
      if (callback != null && category != 'method') {
        try {
          final result = callback(
            AppLogRecord(
              level,
              cleaned,
              networkError: networkError,
              error: error,
              stackTrace: stackTrace,
              errorScopeId: scope?.id,
            ),
          );
          if (result is Future<void>)
            unawaited(result.catchError((Object _) {}));
        } catch (_) {
          // Telemetry is not allowed to break logging or trigger another error.
        }
      }
      if (level.index >= AppLogLevel.error.index) _urgentFlush = true;
      if (_urgentFlush || _pendingBytes >= batchBytes) _scheduleFlush();
    } catch (failure) {
      // Serialization failure is a logging failure, never a business exception.
      _fail(failure);
    } finally {
      _inside = false;
    }
  }

  void _scheduleFlush() {
    if (_automaticFlushQueued || !_initialized || _closed) return;
    _automaticFlushQueued = true;
    scheduleMicrotask(() async {
      _urgentFlush = false;
      try {
        if (!_closed) await flush();
      } finally {
        _automaticFlushQueued = false;
        if (_persistenceError == null &&
            (_urgentFlush || _pendingBytes >= batchBytes)) {
          _scheduleFlush();
        }
      }
    });
  }

  Future<void> flush() {
    final cutoff = _sequence - 1;
    return _serialize(() => _flushThrough(cutoff));
  }

  Future<T> _serialize<T>(Future<T> Function() action) {
    final result = _work.then((_) => action());
    _work = result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }

  Future<void> _flushThrough(int cutoff) async {
    if (!_initialized) return;
    RandomAccessFile? handle;
    List<_LogLine> batch = const [];
    var batchCommitted = false;
    try {
      if (!_prepared) {
        final before = _sequence;
        await _prepareFile();
        cutoff += _sequence - before;
      }
      await _checkRoot();
      final file = _file;
      if (file == null) throw const FileSystemException('日志会话尚未初始化');
      var type = await FileSystemEntity.type(file.path, followLinks: false);
      if (type == FileSystemEntityType.notFound && _committedLength == 0) {
        await _prepareFile();
        type = await FileSystemEntity.type(file.path, followLinks: false);
      }
      if (type != FileSystemEntityType.file) {
        throw const FileSystemException('日志文件不可用或为链接');
      }
      handle = await file.open(mode: FileMode.append);
      if (await handle.length() < _committedLength) {
        throw const FileSystemException('日志已提交内容丢失');
      }
      await handle.truncate(_committedLength);
      await handle.setPosition(_committedLength);
      batch = _pending
          .takeWhile((line) => line.sequence <= cutoff)
          .toList(growable: false);
      for (final line in batch) {
        _pending.removeFirst();
        _pendingBytes -= line.bytes.length;
      }
      final missingRecords = _missingRecords;
      final missingBytes = _missingBytes;
      var length = _committedLength;
      if (missingRecords > 0) {
        final warning = _lossLine(
          missingRecords,
          missingBytes,
          batch.isEmpty ? _sequence++ : batch.first.sequence - 1,
        );
        await handle.writeFrom(warning);
        length += warning.length;
      }
      for (final line in batch) {
        await handle.writeFrom(line.bytes);
        length += line.bytes.length;
      }
      await handle.flush();
      _committedLength = length;
      batchCommitted = true;
      _missingRecords -= missingRecords;
      _missingBytes -= missingBytes;
      _persistenceError = null;
      _notify();
    } catch (error) {
      if (!batchCommitted) {
        for (final line in batch.reversed) {
          _pending.addFirst(line);
          _pendingBytes += line.bytes.length;
        }
      }
      _fail(error);
    } finally {
      try {
        await handle?.close();
      } catch (error) {
        _fail(error);
      }
    }
  }

  Uint8List _lossLine(int records, int bytes, int sequence) =>
      Uint8List.fromList(
        utf8.encode(
          '${jsonEncode({
            'timestamp': DateTime.now().toUtc().toIso8601String(),
            'sessionId': _sessionId,
            'sequence': sequence,
            'level': 'WARNING',
            'category': 'logging',
            'message': '日志写入恢复；部分记录已丢失',
            'data': {'missingRecords': records, 'missingBytes': bytes},
          })}\n',
        ),
      );

  void _boundTail() {
    while (_pendingBytes > retainedBytesLimit && _pending.isNotEmpty) {
      final line = _pending.removeFirst();
      _pendingBytes -= line.bytes.length;
      _missingRecords++;
      _missingBytes += line.bytes.length;
      _lostRecords++;
      _lostBytes += line.bytes.length;
    }
  }

  void _fail(Object error) {
    _persistenceError = '${redact('$error')}';
    _boundTail();
    _notify();
  }

  void _notify() {
    if (!_status.isClosed) _status.add(null);
  }

  Future<List<LogSession>> sessions() => _serialize(() async {
    List<LogSession> result;
    try {
      result = (await _listSessions()).toList();
    } catch (error) {
      _fail(error);
      result = [];
    }
    final name = currentFileName;
    if (name != null) {
      var length = _committedLength;
      final file = _file;
      if (file != null) {
        try {
          length =
              await FileSystemEntity.type(file.path, followLinks: false) ==
                  FileSystemEntityType.file
              ? await file.length()
              : 0;
        } catch (error) {
          _fail(error);
        }
      }
      result = result
          .where((session) => session.fileName != name)
          .take(6)
          .toList();
      result.add(
        LogSession(
          name,
          file?.path,
          _startedAt!,
          length + _pendingBytes,
          isCurrent: true,
        ),
      );
      result.sort((a, b) {
        final time = b.startedAt.compareTo(a.startedAt);
        return time == 0 ? b.fileName.compareTo(a.fileName) : time;
      });
    }
    return List.unmodifiable(result.take(7));
  });

  Future<List<LogSession>> _listSessions() async {
    final root = _root;
    if (root == null || !await root.exists()) return [];
    if (await FileSystemEntity.type(root.path, followLinks: false) !=
        FileSystemEntityType.directory) {
      throw const FileSystemException('日志目录不能是链接');
    }
    final result = <LogSession>[];
    await for (final entity in root.list(followLinks: false)) {
      final name = p.basename(entity.path);
      final match = _ownedName.firstMatch(name);
      if (match == null ||
          await FileSystemEntity.type(entity.path, followLinks: false) !=
              FileSystemEntityType.file)
        continue;
      final micros = int.tryParse(match.group(1)!);
      if (micros == null) continue;
      final stat = await entity.stat();
      result.add(
        LogSession(
          name,
          entity.path,
          DateTime.fromMicrosecondsSinceEpoch(micros, isUtc: true),
          stat.size,
          isCurrent: entity.path == _file?.path,
        ),
      );
    }
    result.sort((a, b) {
      final time = b.startedAt.compareTo(a.startedAt);
      return time == 0 ? b.fileName.compareTo(a.fileName) : time;
    });
    return List.unmodifiable(result);
  }

  Future<LogSnapshot> snapshot(String fileName) {
    if (!_ownedName.hasMatch(fileName) || p.basename(fileName) != fileName) {
      return Future.error(
        ArgumentError.value(fileName, 'fileName', 'Not an owned log basename'),
      );
    }
    final cutoff = _sequence - 1;
    return _serialize(() async {
      final current = fileName == currentFileName;
      if (current) await _flushThrough(cutoff);
      final root = _root;
      final file = root == null ? null : File(p.join(root.path, fileName));
      String? source;
      var length = 0;
      try {
        final type = file == null
            ? FileSystemEntityType.notFound
            : await FileSystemEntity.type(file.path, followLinks: false);
        if (file != null && type == FileSystemEntityType.file) {
          if (current) {
            length = _committedLength;
            if (await file.length() < length) {
              final handle = await file.open();
              try {
                length = await _lastNewline(handle, await handle.length());
              } finally {
                await handle.close();
              }
            }
          } else {
            final handle = await file.open();
            try {
              length = await _lastNewline(handle, await handle.length());
            } finally {
              await handle.close();
            }
          }
          source = file.path;
        } else if (!current) {
          throw const FileSystemException('日志文件不可用或为链接');
        }
      } catch (error) {
        if (!current) rethrow;
        _fail(error);
        length = 0;
      }
      final tail = current
          ? _pending
                .where((line) => line.sequence <= cutoff)
                .map((line) => line.bytes)
                .toList(growable: false)
          : const <Uint8List>[];
      return LogSnapshot._(
        source,
        length,
        tail,
        persistenceError: current ? _persistenceError : null,
        missingRecords: current ? _missingRecords : 0,
        missingBytes: current ? _missingBytes : 0,
      );
    });
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _timer?.cancel();
    await flush();
    await _status.close();
    await _errors.close();
  }

  /// Cookie-only cleaning shared by local records and telemetry hooks. JSON and
  /// form text are parsed before cleaning; ordinary secret/token fields survive.
  static Object? redact(Object? value) =>
      _redact(value, HashSet<Object>.identity());

  static bool _cookieKey(String key) {
    final lower = key.toLowerCase();
    return lower == 'cookie' || lower == 'cookie2' || lower == 'set-cookie';
  }

  static Object? _redact(Object? value, Set<Object> visiting) {
    if (value == null || value is num || value is bool) return value;
    if (value is String) return _cleanText(value, visiting);
    if (value is Map || value is Iterable) {
      if (!visiting.add(value)) return '[CYCLIC VALUE]';
      try {
        if (value is Map) {
          return Map<String, Object?>.unmodifiable({
            for (final entry in value.entries)
              '${entry.key}': _cookieKey('${entry.key}')
                  ? cookieReplacement
                  : _redact(entry.value, visiting),
          });
        }
        return List<Object?>.unmodifiable(
          (value as Iterable).map((item) => _redact(item, visiting)),
        );
      } finally {
        visiting.remove(value);
      }
    }
    return _cleanText('$value', visiting);
  }

  static String _cleanText(String text, Set<Object> visiting) {
    final trimmed = text.trimLeft();
    if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
      try {
        return jsonEncode(_redact(jsonDecode(text), visiting));
      } on FormatException {
        // Not JSON: still clean header lines and embedded Cookie fields below.
      }
    }
    // A form can contain JSON or header text in an encoded field value. Do not
    // mistake a URL query for a form or alter unrelated form values.
    if (!text.contains('\n') &&
        !RegExp(r'^[A-Za-z][A-Za-z0-9+.-]*://').hasMatch(text) &&
        RegExp(r'^[^=&\s]+=').hasMatch(text)) {
      return text
          .split('&')
          .map((part) {
            final split = part.indexOf('=');
            if (split < 0) return part;
            try {
              if (_cookieKey(
                Uri.decodeQueryComponent(part.substring(0, split)),
              )) {
                return '${part.substring(0, split + 1)}${Uri.encodeQueryComponent(cookieReplacement)}';
              }
              final decoded = Uri.decodeQueryComponent(
                part.substring(split + 1),
              );
              final cleaned = _cleanText(decoded, visiting);
              if (cleaned != decoded) {
                return '${part.substring(0, split + 1)}${Uri.encodeQueryComponent(cleaned)}';
              }
            } on FormatException {
              /* Keep non-Cookie form values verbatim. */
            }
            return part;
          })
          .join('&');
    }
    // Match the remainder of a header line, including exception messages that
    // prefix the header with context (e.g. "HttpException: Cookie: ...").
    return _cleanJsonFragments(text).replaceAllMapped(
      RegExp(r'\b(cookie2?|set-cookie)\s*:\s*[^\r\n]*', caseSensitive: false),
      (match) => '${match.group(1)}: $cookieReplacement',
    );
  }

  // Error excerpts need not be valid JSON. Preserve surrounding text while
  // recognizing JSON string tokens, including strings escaped by outer JSON.
  static String _cleanJsonFragments(String text) {
    StringBuffer? output;
    var copied = 0;
    var cursor = 0;
    while (cursor < text.length) {
      final quote = text.indexOf('"', cursor);
      if (quote < 0) break;
      cursor = quote + 1;
      var start = quote;
      while (start > 0 && text.codeUnitAt(start - 1) == 92) {
        start--;
      }
      final escapes = quote - start;
      // Each enclosing JSON string turns n backslashes into 2n + 1.
      if ((escapes & (escapes + 1)) != 0) continue;
      final keyEnd = _fragmentStringEnd(text, quote + 1, escapes);
      if (keyEnd == null) continue;
      var valueStart = keyEnd;
      while (valueStart < text.length && text.codeUnitAt(valueStart) <= 32) {
        valueStart++;
      }
      if (valueStart == text.length || text.codeUnitAt(valueStart) != 58) {
        continue;
      }
      var key = text.substring(start, keyEnd);
      try {
        for (var layer = escapes; layer > 0; layer = (layer - 1) ~/ 2) {
          key = jsonDecode('"$key"') as String;
        }
        if (!_cookieKey(jsonDecode(key) as String)) continue;
      } on FormatException {
        continue;
      }
      valueStart++;
      while (valueStart < text.length && text.codeUnitAt(valueStart) <= 32) {
        valueStart++;
      }
      final delimiter = '${'\\' * escapes}"';
      var end = valueStart;
      if (text.startsWith(delimiter, valueStart)) {
        end =
            _fragmentStringEnd(text, valueStart + delimiter.length, escapes) ??
            text.length;
      } else {
        var depth = 0;
        while (end < text.length) {
          if (text.startsWith(delimiter, end)) {
            end =
                _fragmentStringEnd(text, end + delimiter.length, escapes) ??
                text.length;
            continue;
          }
          final character = text.codeUnitAt(end);
          if (depth == 0 &&
              (character == 44 || character == 125 || character == 93))
            break;
          if (character == 123 || character == 91) depth++;
          if (character == 125 || character == 93) depth--;
          end++;
        }
        while (end > valueStart && text.codeUnitAt(end - 1) <= 32) {
          end--;
        }
      }
      output ??= StringBuffer();
      output.write(text.substring(copied, valueStart));
      output.write('$delimiter$cookieReplacement$delimiter');
      copied = end;
      cursor = end;
    }
    if (output == null) return text;
    output.write(text.substring(copied));
    return output.toString();
  }

  static int? _fragmentStringEnd(String text, int start, int escapes) {
    var cursor = start;
    while (cursor < text.length) {
      final quote = text.indexOf('"', cursor);
      if (quote < 0) return null;
      var slash = quote;
      while (slash > start && text.codeUnitAt(slash - 1) == 92) {
        slash--;
      }
      final slashes = quote - slash;
      if (slashes >= escapes &&
          (slashes - escapes) % (2 * (escapes + 1)) == 0) {
        return quote + 1;
      }
      cursor = quote + 1;
    }
    return null;
  }
}

class _ErrorScope {
  _ErrorScope(this.id, this.parent);

  final int id;
  final _ErrorScope? parent;
  HashSet<Object>? errors;
  bool active = true;

  void record(Object error) {
    for (_ErrorScope? scope = this; scope != null; scope = scope.parent) {
      if (scope.active) {
        (scope.errors ??= HashSet<Object>.identity()).add(error);
      }
    }
  }
}

class AppLogRecord {
  const AppLogRecord(
    this.level,
    this.values, {
    required this.networkError,
    this.error,
    this.stackTrace,
    this.errorScopeId,
  });
  final AppLogLevel level;
  final Map<String, Object?> values;
  final bool networkError;

  /// Transient original identity for captureException. Never persisted or
  /// retained by AppLog; the reporter must apply beforeSend Cookie cleaning.
  final Object? error;
  final StackTrace? stackTrace;

  /// Transient invocation provenance; never included in persisted values.
  final int? errorScopeId;
  String? get requestId => values['requestId'] as String?;
}

class LogSession {
  const LogSession(
    this.fileName,
    this.path,
    this.startedAt,
    this.byteLength, {
    required this.isCurrent,
  });
  final String fileName;
  final String? path;
  final DateTime startedAt;
  final int byteLength;
  final bool isCurrent;
}

class _LogLine {
  const _LogLine(this.sequence, this.bytes);
  final int sequence;
  final Uint8List bytes;
}

/// An immutable byte cutoff, not a whole-file copy. The source is read only to
/// [length], even when more records are appended after this snapshot is made.
class LogSnapshot {
  LogSnapshot._(
    this.sourcePath,
    this.length,
    List<Uint8List> tail, {
    required this.persistenceError,
    required this.missingRecords,
    required this.missingBytes,
  }) : _tail = List.unmodifiable(tail) {
    _header = persistenceError == null
        ? Uint8List(0)
        : _notice('日志写入失败，当前导出仅含保留片段', {'persistenceError': persistenceError});
    _missing = missingRecords == 0
        ? Uint8List(0)
        : _notice('日志记录丢失', {
            'missingRecords': missingRecords,
            'missingBytes': missingBytes,
          });
  }
  static const androidClipboardLimit = 512 * 1024;
  static const windowsClipboardLimit = 8 * 1024 * 1024;
  final String? sourcePath;
  final int length;
  final String? persistenceError;
  final int missingRecords, missingBytes;
  final List<Uint8List> _tail;
  late final Uint8List _header, _missing;
  int get tailLength => _tail.fold<int>(0, (sum, bytes) => sum + bytes.length);
  int get totalBytes => _header.length + length + tailLength + _missing.length;
  bool canCopyToClipboard({required bool android}) =>
      totalBytes <= (android ? androidClipboardLimit : windowsClipboardLimit);

  /// Prefix notices must precede the source on both native and Dart exporters.
  /// Android can use [openSuffix] as its small cache tail and [openPrefix] as a
  /// warning preamble; neither helper reads the committed file.
  Uint8List get warningHeader => Uint8List.fromList(_header);
  Stream<List<int>> openPrefix() async* {
    if (_header.isNotEmpty) yield _header.asUnmodifiableView();
  }

  Stream<List<int>> openSuffix() async* {
    for (final bytes in _tail) yield bytes.asUnmodifiableView();
    if (_missing.isNotEmpty) yield _missing.asUnmodifiableView();
  }

  Stream<List<int>> openRead() async* {
    yield* openPrefix();
    final source = sourcePath;
    if (source != null && length > 0) {
      if (await FileSystemEntity.type(source, followLinks: false) !=
          FileSystemEntityType.file) {
        throw const FileSystemException('日志快照源不可用或为链接');
      }
      var read = 0;
      await for (final chunk in File(source).openRead(0, length)) {
        read += chunk.length;
        yield chunk;
      }
      if (read != length) throw const FileSystemException('日志快照源长度不足');
    }
    yield* openSuffix();
  }

  Future<String> readForClipboard({required bool android}) async {
    if (!canCopyToClipboard(android: android)) {
      throw StateError('日志过大，无法完整复制，请导出到文件');
    }
    return utf8.decoder.bind(openRead()).join();
  }

  static Uint8List _notice(
    String message,
    Map<String, Object?> data,
  ) => Uint8List.fromList(
    utf8.encode(
      '${jsonEncode({'level': 'WARNING', 'category': 'logging', 'message': message, 'data': data})}\n',
    ),
  );
}

/// Find an exclusive complete-line endpoint with bounded memory, even when the
/// final line is very large. A trailing interrupted write is never exported.
Future<int> _lastNewline(RandomAccessFile handle, int before) async {
  var end = before;
  while (end > 0) {
    final start = (end - AppLog.batchBytes).clamp(0, end);
    await handle.setPosition(start);
    final bytes = await handle.read(end - start);
    for (var i = bytes.length - 1; i >= 0; i--) {
      if (bytes[i] == 10) return start + i + 1;
    }
    end = start;
  }
  return 0;
}
