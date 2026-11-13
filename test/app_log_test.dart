import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:xmly_flutter/services/app_log.dart';

Future<List<Map<String, dynamic>>> records(LogSnapshot snapshot) async =>
    (await utf8.decoder.bind(snapshot.openRead()).join())
        .split('\n')
        .where((line) => line.isNotEmpty)
        .map((line) => jsonDecode(line) as Map<String, dynamic>)
        .toList();

void main() {
  late Directory root;
  late List<AppLog> openLogs;
  var id = 0;
  final epoch = DateTime.utc(2026, 1, 1);

  Future<AppLog> createLog({String? session, DateTime? start}) async {
    final log = AppLog(
      directory: root,
      sessionId: session ?? 'test-${id++}',
      startedAt: start ?? epoch.add(Duration(seconds: id)),
      processId: 123,
    );
    openLogs.add(log);
    await log.initialize();
    return log;
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('xmplus-app-log-');
    openLogs = [];
  });
  tearDown(() async {
    for (final log in openLogs) {
      await log.close();
    }
    await root.delete(recursive: true);
  });

  test(
    'keeps seven owned sessions, resumes sequences, repairs an incomplete tail',
    () async {
      final foreign = File(p.join(root.path, 'other.log'));
      await foreign.writeAsString('must survive');
      final directory = Directory(
        p.join(root.path, 'XMPlus-1-123-directory.log'),
      );
      await directory.create();
      final names = <String>[];
      for (var n = 0; n < 8; n++) {
        final log = await createLog(
          session: 'session-$n',
          start: epoch.add(Duration(seconds: n)),
        );
        log.write(AppLogLevel.info, 'test', 'marker-$n');
        await log.close();
        names.add(log.currentFileName!);
      }
      final latest = openLogs.last;
      final sessions = await latest.sessions();
      expect(sessions.length, 7);
      expect(
        sessions.map((entry) => entry.fileName),
        names.skip(1).toList().reversed,
      );
      for (var n = 1; n < 8; n++) {
        final lines = await records(await latest.snapshot(names[n]));
        expect(lines.single['message'], 'marker-$n');
        expect(lines.single['sessionId'], 'session-$n');
      }
      expect(await foreign.readAsString(), 'must survive');
      expect(await directory.exists(), isTrue);

      final current = File(latest.currentFilePath!);
      final original = await current.readAsString();
      await current.writeAsString('{"interrupted":', mode: FileMode.append);
      final reopened = await createLog(
        session: 'session-7',
        start: epoch.add(const Duration(seconds: 7)),
      );
      expect(reopened.currentFileName, names.last);
      reopened.write(AppLogLevel.info, 'test', 'appended');
      await reopened.flush();
      final text = await current.readAsString();
      expect(text.startsWith(original), isTrue);
      expect(text, isNot(contains('interrupted')));
      final lines = await records(await reopened.snapshot(names.last));
      expect(lines.map((line) => line['sequence']), [0, 1]);
      expect((await reopened.sessions()).length, 7);
      await expectLater(
        reopened.snapshot('../${names.last}'),
        throwsArgumentError,
      );
    },
  );

  test('never rotates or reads owned-looking symlinks', () async {
    final outside = await Directory.systemTemp.createTemp(
      'xmplus-log-outside-',
    );
    addTearDown(() => outside.delete(recursive: true));
    final target = File(p.join(outside.path, 'keep.txt'));
    await target.writeAsString('outside must survive');
    final name = 'XMPlus-1-123-linked.log';
    final link = Link(p.join(root.path, name));
    try {
      await link.create(target.path);
    } on FileSystemException {
      // Windows requires Developer Mode or symlink privilege. Other real-file
      // rotation tests still run; the parent can exercise this on enabled hosts.
      markTestSkipped('Host does not permit creating filesystem symlinks');
      return;
    }
    for (var n = 0; n < 8; n++) {
      final log = await createLog();
      log.write(AppLogLevel.info, 'test', 'session-$n');
      await log.close();
    }
    expect(await link.exists(), isTrue);
    expect(await target.readAsString(), 'outside must survive');
    expect(
      (await openLogs.last.sessions()).any((entry) => entry.fileName == name),
      isFalse,
    );
    await expectLater(
      openLogs.last.snapshot(name),
      throwsA(isA<FileSystemException>()),
    );
  });

  test('Cookie-only cleaning precedes disk, buffers, and immutable hooks', () async {
    final log = await createLog();
    final captured = <AppLogRecord>[];
    log.sink = captured.add;
    final input = <String, Object?>{
      'headers': {
        'cOoKiE': 'PRIVATE_A',
        'COOKIE2': 'PRIVATE_B',
        'SeT-CoOkIe': ['PRIVATE_C'],
        'x-tk': 'KEEP_TICKET',
      },
      'nested': [
        {'Cookie': 'PRIVATE_D', 'token': 'KEEP_TOKEN'},
      ],
      'jsonBody': '{"nested":{"Set-Cookie":"PRIVATE_E","token":"KEEP_TOKEN"}}',
      'formBody': 'Cookie=PRIVATE_F&token=KEEP_TOKEN&url=https%3A%2F%2Fexample.test%2F%3Fsign%3DKEEP_SIGN',
      'nestedForm':
          'payload=${Uri.encodeQueryComponent('{"COOKIE2":"PRIVATE_G","token":"KEEP_TOKEN"}')}',
      'headerText': 'Headers:\r\ncOoKiE: PRIVATE_H\r\nx-tk: KEEP_TICKET\r\nSet-Cookie: PRIVATE_I\r\n',
      'errorExcerpt': const FormatException(
        'fixture malformed JSON',
        '{"Cookie":"PRIVATE_EXCERPT","token":"KEEP_TOKEN","url":"?sign=KEEP_SIGN"',
        1,
      ).toString(),
      'nestedFragment': r'FormatException: {"nested":{"\u0043ookie":"PRIVATE_UNICODE","token":"KEEP_TOKEN"},"url":"?sign=KEEP_SIGN"',
      'escapedFragment': r'FormatException: {\"Cookie2\":\"PRIVATE_ESCAPED\\\"tail\",\"token\":\"KEEP_TOKEN\",\"url\":\"?sign=KEEP_SIGN\"',
      'unterminatedFragment': 'FormatException: {"token":"KEEP_TOKEN","url":"?sign=KEEP_SIGN","Set-Cookie":"PRIVATE_UNTERMINATED',
      'url': 'https://example.test/?sign=KEEP_SIGN&password=KEEP_PASSWORD',
    };
    log.write(
      AppLogLevel.error,
      'http',
      'request',
      data: input,
      error: StateError('HttpException: Cookie: PRIVATE_J\nx-tk: KEEP_TICKET'),
      stackTrace: StackTrace.fromString('test frame\nCookie2: PRIVATE_K'),
      requestId: 'request-1',
    );
    input['headers'] = {'Cookie': 'MUTATED_PRIVATE'};
    await log.flush();
    final snapshot = await log.snapshot(log.currentFileName!);
    final text = await utf8.decoder.bind(snapshot.openRead()).join();
    final persisted = await File(log.currentFilePath!).readAsString();
    final hooked = jsonEncode(captured.single.values);
    for (final output in [text, persisted, hooked]) {
      expect(output, isNot(contains('PRIVATE_')));
      expect(output, contains('KEEP_TOKEN'));
      expect(output, contains('KEEP_TICKET'));
      expect(output, contains('KEEP_SIGN'));
      expect(output, contains('KEEP_PASSWORD'));
    }
    expect(captured.single.requestId, 'request-1');
    expect(
      () => captured.single.values['message'] = 'changed',
      throwsUnsupportedError,
    );
    expect(
      () => (captured.single.values['data'] as Map)['token'] = 'changed',
      throwsUnsupportedError,
    );
    expect(AppLog.redact({'token': 'unchanged', 'Cookie': 'private'}), {
      'token': 'unchanged',
      'Cookie': AppLog.cookieReplacement,
    });
    expect(
      AppLog.redact(
        r'prefix {"Cookie":"PRIVATE_TRAILING\\","token":"KEEP_TOKEN","url":"?sign=KEEP_SIGN"} suffix',
      ),
      'prefix {"Cookie":"${AppLog.cookieReplacement}","token":"KEEP_TOKEN","url":"?sign=KEEP_SIGN"} suffix',
    );
    expect(
      AppLog.redact(
        r'prefix {\"Cookie2\":\"PRIVATE_ESCAPED\\\"tail\",\"token\":\"KEEP_TOKEN\",\"url\":\"?sign=KEEP_SIGN\"} suffix',
      ),
      r'prefix {\"Cookie2\":\"[REDACTED COOKIE]\",\"token\":\"KEEP_TOKEN\",\"url\":\"?sign=KEEP_SIGN\"} suffix',
    );
    expect(
      AppLog.redact(
        'prefix {"token":"KEEP_TOKEN","url":"?sign=KEEP_SIGN","Set-Cookie":"PRIVATE_UNTERMINATED',
      ),
      'prefix {"token":"KEEP_TOKEN","url":"?sign=KEEP_SIGN","Set-Cookie":"${AppLog.cookieReplacement}"',
    );
  });

  test(
    'ordinary thresholds filter; network failures remain ERROR even at FATAL',
    () async {
      final log = await createLog();
      for (final threshold in AppLogLevel.values) {
        log.level = threshold;
        for (final severity in AppLogLevel.values) {
          log.write(severity, threshold.name, severity.name);
        }
        log.write(
          AppLogLevel.fatal,
          threshold.name,
          'network',
          networkError: true,
        );
        log.trace('trace-${threshold.name}');
      }
      final lines = await records(await log.snapshot(log.currentFileName!));
      for (final threshold in AppLogLevel.values) {
        final category = lines
            .where((line) => line['category'] == threshold.name)
            .toList();
        expect(
          category
              .where((line) => line['message'] != 'network')
              .map((line) => line['message']),
          AppLogLevel.values
              .where((level) => level.index >= threshold.index)
              .map((level) => level.name),
        );
        expect(
          category.singleWhere((line) => line['message'] == 'network')['level'],
          'ERROR',
        );
      }
      expect(
        lines
            .where((line) => line['category'] == 'method')
            .map((line) => line['message']),
        ['trace-debug'],
      );
      expect(AppLog.parseLevel('fatal'), AppLogLevel.fatal);
      expect(AppLog.parseLevel('info'), AppLogLevel.info);
      expect(AppLog.parseLevel(null), AppLogLevel.warning);
      expect(AppLog.parseLevel('unknown'), AppLogLevel.warning);
      expect(AppLog.parseLevel(2), AppLogLevel.warning);
    },
  );

  test('nested error scopes propagate identities and link normalized errors without suppressing attempts', () async {
    final log = await createLog();
    log.level = AppLogLevel.error;
    final captured = <AppLogRecord>[];
    final original = StateError('shared failure');
    final replacement = StateError('normalized failure');
    log.sink = (record) {
      expect(log.errorWasRecorded(record.error!), isTrue);
      captured.add(record);
    };
    await log.runWithErrorScope(() async {
      log.write(AppLogLevel.error, 'scope', 'parent', error: original);
      try {
        await log.runWithErrorScope<void>(() async {
          expect(log.errorWasRecorded(original), isFalse);
          log.linkError(replacement, original);
          expect(log.errorWasRecorded(replacement), isFalse);
          for (var attempt = 0; attempt < 2; attempt++) {
            log.write(
              AppLogLevel.error,
              'scope',
              'attempt-$attempt',
              error: original,
              networkError: true,
              requestId: 'request-$attempt',
            );
          }
          log.linkError(replacement, original);
          expect(log.errorWasRecorded(replacement), isTrue);
          throw replacement;
        });
      } catch (error) {
        expect(error, same(replacement));
        expect(log.errorWasRecorded(original), isTrue);
        expect(log.errorWasRecorded(error), isTrue);
      }
      await log.runWithErrorScope(() async {
        expect(log.errorWasRecorded(original), isFalse);
        expect(log.errorWasRecorded(replacement), isFalse);
        log.write(AppLogLevel.error, 'scope', 'fresh-child', error: original);
      });
    });
    expect(log.errorWasRecorded(original), isFalse);
    expect(log.errorWasRecorded(replacement), isFalse);
    expect(
      captured.map((record) => record.error),
      everyElement(same(original)),
    );
    final scopeIds = captured.map((record) => record.errorScopeId).toList();
    expect(scopeIds, everyElement(isNotNull));
    expect(scopeIds[1], scopeIds[2]);
    expect(scopeIds.toSet(), hasLength(3));
    final lines = await records(await log.snapshot(log.currentFileName!));
    expect(lines.map((line) => line['message']), [
      'parent',
      'attempt-0',
      'attempt-1',
      'fresh-child',
    ]);
    expect(lines.where((line) => line.containsKey('errorScopeId')), isEmpty);
    expect(captured[1].requestId, 'request-0');
    expect(captured[2].requestId, 'request-1');
  });

  test('fresh root and concurrent scopes record the same error object independently', () async {
    final log = await createLog();
    final original = StateError('reused failure');
    final captured = <AppLogRecord>[];
    log.sink = captured.add;
    Future<void> invoke(String message, {Future<void>? barrier}) =>
        log.runWithErrorScope(() async {
          expect(log.errorWasRecorded(original), isFalse);
          if (barrier != null) await barrier;
          expect(log.errorWasRecorded(original), isFalse);
          log.write(AppLogLevel.error, 'scope', message, error: original);
          expect(log.errorWasRecorded(original), isTrue);
        });
    await invoke('first-root');
    await invoke('second-root');
    final barrier = Completer<void>();
    final first = invoke('concurrent-first', barrier: barrier.future);
    final second = invoke('concurrent-second', barrier: barrier.future);
    barrier.complete();
    await Future.wait([first, second]);
    expect(log.errorWasRecorded(original), isFalse);
    expect(captured.map((record) => record.errorScopeId).toSet(), hasLength(4));
    expect(
      captured.map((record) => record.errorScopeId),
      everyElement(isNotNull),
    );
    expect(
      (await records(await log.snapshot(log.currentFileName!)))
          .map((line) => line['message']),
      ['first-root', 'second-root', 'concurrent-first', 'concurrent-second'],
    );
  });

  test(
    'ended scopes fall back to active ancestors and never hide future faults',
    () async {
      final log = await createLog();
      final original = StateError('outliving failure');
      final captured = <AppLogRecord>[];
      log.sink = captured.add;
      final releaseRoot = Completer<void>();
      late Future<void> afterRoot;
      await log.runWithErrorScope(() async {
        log.write(AppLogLevel.error, 'scope', 'parent', error: original);
        final releaseChild = Completer<void>();
        late Future<void> afterChild;
        await log.runWithErrorScope(() async {
          log.write(AppLogLevel.error, 'scope', 'child', error: original);
          afterChild = releaseChild.future.then((_) {
            expect(log.errorWasRecorded(original), isTrue);
            log.write(
              AppLogLevel.error,
              'scope',
              'active-ancestor',
              error: original,
            );
          });
        });
        releaseChild.complete();
        await afterChild;
        afterRoot = releaseRoot.future.then((_) async {
          expect(log.errorWasRecorded(original), isFalse);
          log.write(
            AppLogLevel.error,
            'scope',
            'no-active-scope',
            error: original,
          );
          await log.runWithErrorScope(() async {
            expect(log.errorWasRecorded(original), isFalse);
            log.write(
              AppLogLevel.error,
              'scope',
              'future-root',
              error: original,
            );
          });
        });
      });
      releaseRoot.complete();
      await afterRoot;
      expect(captured[0].errorScopeId, isNotNull);
      expect(captured[1].errorScopeId, isNot(captured[0].errorScopeId));
      expect(captured[2].errorScopeId, captured[0].errorScopeId);
      expect(captured[3].errorScopeId, isNull);
      expect(captured[4].errorScopeId, isNotNull);
      expect(captured[4].errorScopeId, isNot(captured[0].errorScopeId));
      expect(captured[4].errorScopeId, isNot(captured[1].errorScopeId));
      expect(
        (await records(await log.snapshot(log.currentFileName!)))
            .map((line) => line['message']),
        [
          'parent',
          'child',
          'active-ancestor',
          'no-active-scope',
          'future-root',
        ],
      );
    },
  );

  test('filtered errors request one reminder without recording their identity; network errors remain accepted', () async {
    final log = await createLog();
    log.level = AppLogLevel.fatal;
    final original = StateError('filtered failure');
    final captured = <AppLogRecord>[];
    log.sink = captured.add;
    var signals = 0;
    final subscription = log.pendingErrors.listen((_) => signals++);
    addTearDown(subscription.cancel);
    await log.runWithErrorScope(() async {
      log.write(
        AppLogLevel.error,
        'scope',
        'filtered',
        error: original,
        promptUser: true,
      );
      expect(log.hasPendingErrors, isTrue);
      expect(log.errorWasRecorded(original), isFalse);
      log.write(
        AppLogLevel.fatal,
        'scope',
        'unserializable',
        error: original,
        data: {
          'invalid': Iterable<Object>.generate(
            1,
            (_) => throw StateError('serialization failed'),
          ),
        },
      );
      expect(log.errorWasRecorded(original), isFalse);
      log.requestUploadPrompt();
      log.write(
        AppLogLevel.error,
        'scope',
        'network',
        error: original,
        networkError: true,
      );
      expect(log.errorWasRecorded(original), isTrue);
    });
    final lines = await records(await log.snapshot(log.currentFileName!));
    expect(lines.map((line) => line['message']), ['network']);
    expect(lines.single['level'], 'ERROR');
    expect(captured, hasLength(1));
    expect(captured.single.errorScopeId, isNotNull);
    expect(signals, 1);
    expect(await log.claimUploadPrompt(), isTrue);
    log.requestUploadPrompt();
    expect(log.hasPendingErrors, isFalse);
    await log.close();
    log.requestUploadPrompt();
    expect(log.hasPendingErrors, isFalse);
    expect(signals, 1);
  });

  test('bootstrap retains only the main entry; applying INFO stops traces immediately', () async {
    final log = AppLog(
      directory: root,
      sessionId: 'bootstrap',
      startedAt: epoch,
    );
    openLogs.add(log);
    log.trace('main');
    log.trace('not-another-preinit-buffer');
    await log.initialize();
    log.trace('startup');
    log.level = AppLogLevel.info;
    log.trace('disabled');
    final lines = await records(await log.snapshot(log.currentFileName!));
    expect(lines.map((line) => line['message']), ['main', 'startup']);
    expect(
      lines.every((line) => (line['data'] as Map)['phase'] == 'bootstrap'),
      isTrue,
    );
  });

  test(
    'one-second and 64 KiB batches persist without explicit business flush',
    () async {
      final log = await createLog();
      log.level = AppLogLevel.info;
      log.write(AppLogLevel.info, 'test', 'timer-marker');
      final timerDone = log.status.firstWhere((_) => log.retainedBytes == 0);
      await timerDone.timeout(const Duration(seconds: 5));
      expect(
        await File(log.currentFilePath!).readAsString(),
        contains('timer-marker'),
      );
      log.write(AppLogLevel.info, 'test', 'x' * AppLog.batchBytes);
      final batchDone = log.status.firstWhere((_) => log.retainedBytes == 0);
      await batchDone.timeout(const Duration(seconds: 5));
      expect(log.retainedBytes, 0);
      log.write(AppLogLevel.error, 'test', 'error-marker');
      final errorDone = log.status.firstWhere((_) => log.retainedBytes == 0);
      await errorDone.timeout(const Duration(seconds: 5));
      expect(
        await File(log.currentFilePath!).readAsString(),
        contains('error-marker'),
      );
    },
  );

  test('concurrent flush and snapshot fix a complete JSONL cutoff before later traces', () async {
    final log = await createLog();
    log.level = AppLogLevel.debug;
    for (var n = 0; n < 100; n++) {
      log.write(AppLogLevel.info, 'test', 'before-$n');
    }
    final flushing = log.flush();
    final taking = log.snapshot(log.currentFileName!);
    for (var n = 0; n < 100; n++) {
      log.trace('later-$n');
    }
    await flushing;
    final snapshot = await taking;
    await log.flush();
    final lines = await records(snapshot);
    expect(lines.length, 100);
    expect(lines.last['message'], 'before-99');
    expect(
      snapshot.length,
      lessThan(await File(log.currentFilePath!).length()),
    );
    expect(lines.map((line) => line['sequence']), List.generate(100, (n) => n));
    expect((await records(snapshot)).length, 100);
  });

  test('streams a 128 MiB historical snapshot with bounded chunks and matching digest', () async {
    final log = await createLog();
    final file = File(p.join(root.path, 'XMPlus-1-123-large.log'));
    final emptyLength = utf8.encode('${jsonEncode({'padding': ''})}\n').length;
    final block = utf8.encode(
      '${jsonEncode({'padding': 'x' * (64 * 1024 - emptyLength)})}\n',
    );
    expect(block.length, 64 * 1024);
    final writer = await file.open(mode: FileMode.write);
    try {
      for (var n = 0; n < 2048; n++) {
        await writer.writeFrom(block);
      }
    } finally {
      await writer.close();
    }
    final snapshot = await log.snapshot(p.basename(file.path));
    expect(snapshot.length, 128 * 1024 * 1024);
    expect(snapshot.tailLength, 0);
    var count = 0, largestChunk = 0;
    final digest = await sha256
        .bind(
          snapshot.openRead().map((chunk) {
            count += chunk.length;
            if (chunk.length > largestChunk) largestChunk = chunk.length;
            return chunk;
          }),
        )
        .single;
    expect(count, snapshot.length);
    expect(largestChunk, lessThanOrEqualTo(64 * 1024));
    expect(digest, await sha256.bind(file.openRead()).single);
    await expectLater(
      snapshot.readForClipboard(android: true),
      throwsStateError,
    );
    await expectLater(
      snapshot.readForClipboard(android: false),
      throwsStateError,
    );
    expect(await file.length(), snapshot.length);
  }, timeout: const Timeout(Duration(minutes: 2)));

  test(
    'clipboard caps reject limit plus one before opening the source',
    () async {
      final log = await createLog();
      for (final android in [true, false]) {
        final cap = android
            ? LogSnapshot.androidClipboardLimit
            : LogSnapshot.windowsClipboardLimit;
        final file = File(
          p.join(root.path, 'XMPlus-${android ? 2 : 3}-123-clipboard.log'),
        );
        final handle = await file.open(mode: FileMode.write);
        await handle.truncate(cap + 1);
        await handle.setPosition(cap);
        await handle.writeByte(10);
        await handle.close();
        final snapshot = await log.snapshot(p.basename(file.path));
        expect(snapshot.totalBytes, cap + 1);
        expect(snapshot.canCopyToClipboard(android: android), isFalse);
        // Removing the source proves the policy rejects before opening/decoding it.
        await file.delete();
        await expectLater(
          snapshot.readForClipboard(android: android),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              '日志过大，无法完整复制，请导出到文件',
            ),
          ),
        );
      }
      log.write(AppLogLevel.info, 'test', 'small complete clipboard');
      final small = await log.snapshot(log.currentFileName!);
      expect(
        await small.readForClipboard(android: true),
        await File(log.currentFilePath!).readAsString(),
      );
    },
  );

  test('initial directory obstruction keeps current tail exportable and recovers the same file', () async {
    final obstruction = await File(p.join(root.path, 'logs')).create();
    final log = AppLog(
      directory: Directory(obstruction.path),
      sessionId: 'initial-failure',
      startedAt: epoch,
      processId: 123,
    );
    openLogs.add(log);
    await log.initialize();
    final name = log.currentFileName!;
    final path = log.currentFilePath!;
    expect(
      name,
      'XMPlus-${epoch.microsecondsSinceEpoch}-123-initial-failure.log',
    );
    expect(log.persistenceError, isNotNull);
    expect(await File(path).exists(), isFalse);
    log.write(AppLogLevel.info, 'test', 'x' * (AppLog.retainedBytesLimit + 1));
    log.write(
      AppLogLevel.info,
      'test',
      'initial-failure-marker',
      data: {'Cookie': 'PRIVATE_INITIAL', 'token': 'KEEP_TOKEN'},
    );
    await log.flush();
    final selected = (await log.sessions()).single;
    expect(selected.isCurrent, isTrue);
    expect(selected.fileName, name);
    expect(selected.path, path);
    expect(selected.startedAt, epoch);
    expect(selected.byteLength, log.retainedBytes);
    final failed = await log.snapshot(selected.fileName);
    expect(failed.sourcePath, isNull);
    expect(failed.length, 0);
    expect(failed.tailLength, selected.byteLength);
    expect(failed.missingRecords, 1);
    final text = await utf8.decoder.bind(failed.openRead()).join();
    expect(text, contains('initial-failure-marker'));
    expect(text, contains(AppLog.cookieReplacement));
    expect(text, isNot(contains('PRIVATE_INITIAL')));
    expect(text, contains('KEEP_TOKEN'));
    final exported = await records(failed);
    expect(exported.first['message'], '日志写入失败，当前导出仅含保留片段');
    expect(exported.last['message'], '日志记录丢失');
    expect((exported.last['data'] as Map)['missingRecords'], 1);
    await obstruction.delete();
    await log.flush();
    expect(log.persistenceError, isNull);
    expect(log.currentFileName, name);
    expect(log.currentFilePath, path);
    expect(log.retainedBytes, 0);
    expect(
      (await Directory(obstruction.path).list().toList()).single.path,
      path,
    );
    final recovered = await records(await log.snapshot(name));
    expect(recovered.map((line) => line['message']), [
      '日志写入恢复；部分记录已丢失',
      'initial-failure-marker',
    ]);
    expect((await log.sessions()).single.byteLength, await File(path).length());
  });

  test('real I/O failure retains whole Cookie-cleaned tail, counts loss, retries same file', () async {
    final log = await createLog();
    log.level = AppLogLevel.info;
    log.write(AppLogLevel.info, 'test', 'committed-before-failure');
    await log.flush();
    final originalName = log.currentFileName!;
    final current = File(log.currentFilePath!);
    final backup = await current.rename('${current.path}.held');
    final obstruction = await Directory(current.path).create();
    try {
      final allLengths = <int>[];
      log.sink = (record) {
        allLengths.add(utf8.encode('${jsonEncode(record.values)}\n').length);
      };
      log.write(
        AppLogLevel.error,
        'test',
        'failure-first',
        data: {'Cookie': 'PRIVATE_BUFFER'},
      );
      await log.flush();
      expect(log.persistenceError, isNotNull);
      for (var n = 0; n < 96; n++) {
        log.write(
          AppLogLevel.info,
          'test',
          'tail-$n-${'x' * 32768}',
          data: {'cookie2': 'PRIVATE_TAIL', 'token': 'KEEP_TOKEN'},
        );
      }
      await log.flush();
      expect(log.retainedBytes, lessThanOrEqualTo(AppLog.retainedBytesLimit));
      expect(log.lostRecords, greaterThan(0));
      final failed = await log.snapshot(originalName);
      final output = await utf8.decoder.bind(failed.openRead()).join();
      expect(output, isNot(contains('PRIVATE_')));
      expect(output, contains('KEEP_TOKEN'));
      expect(output, contains('日志写入失败'));
      expect(failed.tailLength, log.retainedBytes);
      expect(failed.missingRecords, log.lostRecords);
      expect(failed.missingBytes, log.lostBytes);
      final retained = (await records(failed))
          .where((line) => line['category'] == 'test')
          .toList();
      expect(retained.last['message'], startsWith('tail-95-'));
      expect(retained.length + failed.missingRecords, 97);
      // Every discarded item is an entire UTF-8 JSONL record, not a chopped tail.
      expect(
        failed.tailLength + failed.missingBytes,
        allLengths.fold<int>(0, (sum, size) => sum + size),
      );
      final lost = log.lostRecords;
      await obstruction.delete();
      await backup.rename(current.path);
      await log.flush();
      expect(log.persistenceError, isNull);
      expect(log.currentFileName, originalName);
      expect(log.retainedBytes, 0);
      expect(log.lostRecords, lost);
      final recovered = await records(await log.snapshot(originalName));
      expect(recovered.first['message'], 'committed-before-failure');
      expect(recovered[1]['level'], 'WARNING');
      expect(
        (recovered[1]['data'] as Map)['missingRecords'],
        failed.missingRecords,
      );
      expect(
        (recovered[1]['data'] as Map)['missingBytes'],
        failed.missingBytes,
      );
      expect(
        recovered.skip(2).map((line) => line['message']),
        retained.map((line) => line['message']),
      );
      final sequences = recovered
          .map((line) => line['sequence'] as int)
          .toList();
      expect(sequences.toSet().length, sequences.length);
      expect(sequences, orderedEquals([...sequences]..sort()));
      expect((await log.sessions()).length, 1);
    } finally {
      if (await obstruction.exists()) await obstruction.delete();
      if (await backup.exists()) await backup.rename(current.path);
    }
  });

  test(
    'a single oversized failed record is dropped whole, not retained unbounded',
    () async {
      final log = await createLog();
      final current = File(log.currentFilePath!);
      await current.delete();
      await Directory(current.path).create();
      log.write(
        AppLogLevel.error,
        'test',
        'x' * (AppLog.retainedBytesLimit + 1),
      );
      await log.flush();
      expect(log.persistenceError, isNotNull);
      expect(log.retainedBytes, 0);
      expect(log.lostRecords, 1);
      final snapshot = await log.snapshot(log.currentFileName!);
      expect(snapshot.tailLength, 0);
      expect(snapshot.missingRecords, 1);
      expect((await records(snapshot)).length, 2);
      await Directory(current.path).delete();
      await log.flush();
      expect(log.persistenceError, isNull);
      final restored = await records(await log.snapshot(log.currentFileName!));
      expect(restored.single['level'], 'WARNING');
    },
  );

  test('sink recursion and sink failures cannot break logging; prompt claimed once', () async {
    final log = await createLog();
    var calls = 0;
    log.sink = (_) {
      calls++;
      log.trace('recursive-sink');
      throw StateError('telemetry offline');
    };
    log.write(AppLogLevel.error, 'test', 'first', promptUser: true);
    expect(log.hasPendingErrors, isTrue);
    log.promptLogUpload = false;
    expect(await log.claimUploadPrompt(), isFalse);
    log.promptLogUpload = true;
    final claims = await Future.wait([
      log.claimUploadPrompt(),
      log.claimUploadPrompt(),
    ]);
    expect(claims.where((value) => value).length, 1);
    log.write(AppLogLevel.error, 'test', 'second', promptUser: true);
    expect(await log.claimUploadPrompt(), isFalse);
    expect(calls, 2);
    expect(
      (await records(await log.snapshot(log.currentFileName!)))
          .map((line) => line['message']),
      ['first', 'second'],
    );
  });
}
