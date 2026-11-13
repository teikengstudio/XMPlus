import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:xmly_flutter/api/xmly_client.dart';
import 'package:xmly_flutter/models/xmly_models.dart';
import 'package:xmly_flutter/services/account_service.dart';
import 'package:xmly_flutter/services/download_service.dart';
import 'package:xmly_flutter/services/usage_ledger.dart';
import 'package:xmly_flutter/storage/app_storage.dart';
import 'package:xmly_flutter/storage/credential_store.dart';

class _UnusedCredentials implements CredentialStore {
  @override
  Future<String?> read(String key) => throw StateError('No credential access');
  @override
  Future<void> write(String key, String value) =>
      throw StateError('No credential access');
  @override
  Future<void> delete(String key) => throw StateError('No credential access');
}

void main() {
  test('cancel drains workers, removes durable records, and keeps bulk completions', () async {
    final root = await Directory.systemTemp.createTemp('xmplus-task-removal-');
    final storage = await AppStorage.open(p.join(root.path, 'profile'));
    final output = await File(p.join(root.path, 'completed.mp3'))
        .writeAsString('keep audio');
    final lateOutput = await File(p.join(root.path, 'committed.mp3'))
        .writeAsString('committed audio');
    final accounts = AccountService(
      storage: storage,
      secrets: _UnusedCredentials(),
    );
    final client = XmlyClient();
    final ledger = UsageLedger(storage: storage, clientFor: accounts.clientFor);
    final started = Completer<void>();
    final commitStarted = Completer<void>();
    final stopped = Completer<void>();
    final release = Completer<void>();
    final service = DownloadService(
      storage: storage,
      accounts: accounts,
      ledger: ledger,
      anonymous: client,
      transfer: (_, _, _) => throw StateError('No network transfer'),
      processOnly: (task, control) async {
        if (task.id == 'remove') {
          started.complete();
          await control.stopped;
          stopped.complete();
          await release.future;
          await control.checkpoint();
          throw StateError('Stopped processing must not finish');
        }
        if (task.id != 'commit') throw StateError('Unrelated task started');
        commitStarted.complete();
        await control.stopped;
        // A verified atomic output may finish just as cancellation arrives.
        return lateOutput.path;
      },
    );
    addTearDown(() async {
      if (!release.isCompleted) release.complete();
      await service.close();
      client.close();
      await storage.close();
      await root.delete(recursive: true);
    });

    DownloadTask task(
      String id,
      int number, {
      DownloadState state = DownloadState.paused,
    }) => DownloadTask(
      id: id,
      accountIdentity: 'anonymous',
      track: Track(id: '$number', albumId: '1'),
      rootDirectory: root.path,
      settings: const {},
      createdAt: DateTime.utc(2026),
      state: state,
      processingFailed: state == DownloadState.paused,
      finalPath: state == DownloadState.completed ? output.path : null,
    );
    final initial = [
      task('remove', 1),
      task('sibling', 2),
      task('commit', 3),
      task('completed', 4, state: DownloadState.completed),
      task('legacy', 5, state: DownloadState.cancelled),
    ];
    final receipt = DownloadReceipt(
      operationId: 'confirmed-operation',
      accountIdentity: 'offline-account',
      trackId: 'xmly:1',
      taskId: 'remove',
      seconds: 60,
      balanceBefore: 120,
      balanceAfter: 60,
      createdAt: DateTime.utc(2026),
      state: DebitState.confirmed,
    );
    await storage.transaction((state) {
      state['settings'] = {
        'download': {'parallelism': 2},
        'autoDownloads': {
          'offline-account': {
            '1': {
              'enabled': true,
              'consentId': 'test-consent',
              'seen': <String>[],
              'pending': [
                initial.first.track.toJson(),
                Track(id: '6', albumId: '1').toJson(),
              ],
            },
          },
        },
      };
      state['accounts'] = {
        'offline-account': {
          'ledger': {
            'receipts': [receipt.toJson()],
          },
        },
      };
      state['downloads'] = initial.map((task) => task.toJson()).toList();
      state['downloadAlbums'] = [
        DownloadAlbumJob(
          id: 'album',
          albumId: '1',
          title: 'Album',
          accountIdentity: 'anonymous',
          rootDirectory: root.path,
          settings: const {},
          total: 200,
          page: 1,
          state: 'paused',
          taskIds: ['remove', 'sibling', 'completed'],
          seen: ['xmly:1', 'xmly:2', 'xmly:4'],
        ).toJson(),
      ];
    });
    final savedAccounts = storage.state['accounts'];
    await service.load();
    await service.resume('remove');
    await started.future;
    var removed = false;
    final cancellation = service
        .cancelMany(['remove'])
        .then((_) => removed = true);
    await stopped.future;
    expect(
      removed,
      isFalse,
      reason: 'Deletion must wait for the worker to drain',
    );
    expect(service.tasks.any((task) => task.id == 'remove'), isTrue);
    release.complete();
    await cancellation;
    expect(service.tasks.any((task) => task.id == 'remove'), isFalse);
    expect(
      (storage.state['downloads'] as List).any(
        (task) => task['id'] == 'remove',
      ),
      isFalse,
    );
    final album = service.albumJobs.single;
    expect(album.state, 'paused');
    expect(album.page, 1);
    expect(album.seen, ['xmly:1', 'xmly:2', 'xmly:4']);
    expect(album.taskIds, ['sibling', 'completed']);
    expect(service.task('sibling').state, DownloadState.paused);
    Map subscription() =>
        ((storage.state['settings'] as Map)['autoDownloads']
                as Map)['offline-account']['1']
            as Map;
    expect(subscription()['seen'], contains('xmly:1'));
    expect((subscription()['pending'] as List).map((item) => item['id']), [
      'xmly:6',
    ]);

    await service.resume('commit');
    await commitStarted.future;
    await service.cancelAll();
    expect(
      service.tasks.map((task) => task.id),
      unorderedEquals(['completed', 'commit']),
    );
    expect(
      service.tasks.every((task) => task.state == DownloadState.completed),
      isTrue,
    );
    expect(service.albumJobs, isEmpty);
    expect(storage.state['accounts'], savedAccounts);
    expect(subscription()['enabled'], isTrue);
    expect(subscription()['seen'], containsAll(['xmly:1', 'xmly:6']));
    expect(subscription()['pending'], isEmpty);
    expect(await output.readAsString(), 'keep audio');
    expect(await lateOutput.readAsString(), 'committed audio');
    await service.reload();
    expect(
      service.tasks.map((task) => task.id),
      unorderedEquals(['completed', 'commit']),
    );
    expect(service.albumJobs, isEmpty);

    // Explicit single deletion also removes the downloaded-library index only.
    await service.cancel('completed');
    await service.reload();
    expect(service.tasks.map((task) => task.id), ['commit']);
    expect(await output.readAsString(), 'keep audio');
    expect(storage.state['accounts'], savedAccounts);
  });
}
