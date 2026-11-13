import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:encrypt/encrypt.dart' as aes;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:xmly_flutter/api/xmly_client.dart';
import 'package:xmly_flutter/api/xmly_crypto.dart';
import 'package:xmly_flutter/models/xmly_models.dart';
import 'package:xmly_flutter/services/usage_ledger.dart';
import 'package:xmly_flutter/storage/app_storage.dart';

// Every request terminates here; no live credentials or socket transport exist.
class _QuotaTransport implements HttpClientAdapter {
  int balance = 120, queries = 0, reports = 0;
  int? reportBalance;
  bool newDevice = false, malformedReport = false;
  bool failConfig = false, failConfigAfterReport = false;

  String _encrypted(String value) {
    final cipher = aes.Encrypter(
      aes.AES(
        aes.Key(Uint8List.fromList(XmlyCrypto.durationKey)),
        mode: aes.AESMode.ecb,
        padding: 'PKCS7',
      ),
    );
    return cipher
        .encrypt('$value|${DateTime.now().millisecondsSinceEpoch}')
        .base64;
  }

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.method != 'POST' || options.uri.host != 'mobile.ximalaya.com') {
      throw StateError('Unexpected offline request: ${options.uri}');
    }
    var malformed = false;
    switch (options.uri.path) {
      case '/lite-mobile/audi/func/v1/config':
        queries++;
        malformed = failConfig;
      case '/lite-mobile/audi/func/v1/report':
        reports++;
        balance = reportBalance ?? balance;
        malformed = malformedReport;
        if (failConfigAfterReport) failConfig = true;
      default:
        throw StateError('Unexpected offline request: ${options.uri}');
    }
    return ResponseBody.fromString(
      jsonEncode({
        'ret': 0,
        'data': malformed
            ? <String, dynamic>{}
            : {
                'availableListenDuration': _encrypted('$balance'),
                'newDevice': _encrypted('$newDevice'),
              },
      }),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  test('server quota resolves unknown reports without replay or balance inference', () async {
    final root = await Directory.systemTemp.createTemp('xmplus-auto-quota-');
    final storage = await AppStorage.open(p.join(root.path, 'profile'));
    final transport = _QuotaTransport();
    final dio = Dio()..httpClientAdapter = transport;
    final credentials = Credentials(
      token: '123&offline-fixture',
      deviceId: 'offline-device',
    );
    final identity = credentials.identity;
    final client = XmlyClient(credentials: credentials, dio: dio);
    final ledger = UsageLedger(storage: storage, clientFor: (_) => client);
    addTearDown(() async {
      client.close();
      await storage.close();
      await root.delete(recursive: true);
    });
    await storage.transaction((state) {
      (state['accounts'] as Map)[identity] = {'ledger': <String, dynamic>{}};
    });
    final audio = ResolvedAudio(
      uri: Uri.parse('https://offline.invalid/audio.m4a'),
      requiresReward: true,
      track: Track(id: '1', albumId: '1', duration: 30),
      actualQuality: 'm4a_64',
      accountIdentity: identity,
      expiresAt: null,
      cacheFinalUri: (_) => null,
      invalidateCachedUri: () {},
    );

    // A successful server response is authoritative even when rewards increase
    // the balance rather than producing the old before-minus-duration formula.
    transport.reportBalance = 170;
    final accepted = await ledger.prepay(
      identity: identity,
      taskId: 'accepted',
      audio: audio,
      userConfirmed: true,
    );
    expect(accepted!.state, DebitState.confirmed);
    expect(accepted.balanceAfter, 170);
    expect(ledger.isBlocked(identity), isFalse);
    expect(transport.reports, 1);
    expect(transport.queries, 1);
    final reused = await ledger.prepay(
      identity: identity,
      taskId: 'accepted',
      audio: audio,
      userConfirmed: false,
    );
    expect(reused!.operationId, accepted.operationId);
    expect(transport.reports, 1);
    expect(transport.queries, 1);

    // The report response is lost/malformed. An unchanged config balance ends
    // local uncertainty, without claiming it proves this individual debit.
    transport.malformedReport = true;
    final refreshed = await ledger.prepay(
      identity: identity,
      taskId: 'unknown',
      audio: audio,
      userConfirmed: true,
    );
    expect(refreshed!.state, DebitState.confirmed);
    expect(refreshed.balanceAfter, 170);
    expect(ledger.isBlocked(identity), isFalse);
    expect(transport.reports, 2);
    expect(transport.queries, 3);

    // A failed quota refresh leaves the durable journal reachable and blocked.
    transport.failConfigAfterReport = true;
    await expectLater(
      ledger.prepay(
        identity: identity,
        taskId: 'failed-refresh',
        audio: audio,
        userConfirmed: true,
      ),
      throwsA(
        isA<XmlyException>().having(
          (error) => error.code,
          'code',
          'invalid_quota',
        ),
      ),
    );
    expect(transport.reports, 3);
    expect(transport.queries, 5);
    expect(ledger.isBlocked(identity), isTrue);
    final pending = ledger.receipts(identity).last;
    expect(pending.state, DebitState.uncertain);
    await expectLater(
      ledger.prepay(
        identity: identity,
        taskId: 'failed-refresh',
        audio: audio,
        userConfirmed: true,
      ),
      throwsA(isA<XmlyException>()),
    );
    expect(ledger.receipts(identity).last.operationId, pending.operationId);
    expect(ledger.receipts(identity).last.state, DebitState.uncertain);
    expect(transport.reports, 3);
    expect(transport.queries, 6);

    transport.failConfig = false;
    final recovered = await ledger.prepay(
      identity: identity,
      taskId: 'failed-refresh',
      audio: audio,
      userConfirmed: false,
    );
    expect(recovered!.operationId, pending.operationId);
    expect(recovered.state, DebitState.confirmed);
    expect(ledger.isBlocked(identity), isFalse);
    expect(transport.reports, 3);
    expect(transport.queries, 7);

    // Restored online debt also adopts a successful zero/new-device quota; it
    // must not resend the old report just because there is no balance delta.
    await storage.transaction((state) {
      final saved =
          ((state['accounts'] as Map)[identity] as Map)['ledger'] as Map;
      saved['usage_seconds'] = 8.0;
      saved['usage_uncertain'] = true;
      saved['usage_pending'] = {
        'operationId': 'restored-online',
        'accountIdentity': identity,
        'trackId': 'xmly:1',
        'seconds': 8,
        'balanceBefore': 0,
        'balanceAfter': null,
        'createdAt': DateTime.utc(2026).millisecondsSinceEpoch,
        'state': 'submitting',
      };
    });
    transport.balance = 0;
    transport.newDevice = true;
    await ledger.load();
    await ledger.settle(identity);
    expect(ledger.debt(identity), 0);
    expect(ledger.isBlocked(identity), isFalse);
    expect(transport.reports, 3);
    expect(transport.queries, 8);
    final saved =
        ((storage.state['accounts'] as Map)[identity] as Map)['ledger'] as Map;
    expect(saved['usage_pending'], isNull);
    expect(saved['usage_uncertain'], isFalse);
  });
}
