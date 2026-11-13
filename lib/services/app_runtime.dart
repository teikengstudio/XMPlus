import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../api/xmly_client.dart';
import '../api/xmly_catalogue.dart';
import '../api/xmly_experience.dart';
import '../api/xmly_rewards.dart';
import '../storage/app_storage.dart';
import '../storage/config_archive.dart';
import '../storage/credential_store.dart';
import 'account_service.dart';
import 'close_sequence.dart';
import 'album_cache.dart';
import 'android_background_service.dart';
import 'auto_download_service.dart';
import 'usage_ledger.dart';
import '../models/xmly_models.dart';
import 'download_service.dart';
import 'media_pipeline.dart';
import 'player_service.dart';
import 'system_media_service.dart';
import 'app_log.dart';
import 'file_paths.dart';

class AppRuntime extends ChangeNotifier {
  AppRuntime({required this.storage, required this.secrets}) {
    AppLog.instance.trace("lib/services/app_runtime.dart::AppRuntime.new");

    anonymous = XmlyClient(
      urlCacheDirectory: p.join(storage.directory, 'audio-url-cache'),
    );
    albumCache = AlbumCache(p.join(storage.directory, 'album-cache'));
    accounts = AccountService(
      storage: storage,
      secrets: secrets,
      quiesce: quiesce,
      settle: settle,
      quiesceForRestore: _quiesceForRestore,
    );
    ledger = UsageLedger(storage: storage, clientFor: accounts.clientFor);
    settlementHandlers.add(() {
      AppLog.instance.trace(
        "lib/services/app_runtime.dart::AppRuntime.new.closure#1",
      );
      return closing ? ledger.captureForRestore() : ledger.stopWatch();
    });
    settlementHandlers.add(() {
      AppLog.instance.trace(
        "lib/services/app_runtime.dart::AppRuntime.new.closure#2",
      );
      return closing ? ledger.settleForExit() : ledger.settle();
    });
    pipeline = MediaPipeline(accounts: accounts, anonymous: anonymous);
    downloads = DownloadService(
      storage: storage,
      accounts: accounts,
      ledger: ledger,
      transfer: pipeline.transfer,
      processOnly: pipeline.processOnly,
      discardSource: pipeline.discardSource,
      anonymous: anonymous,
      beforeAdmission: _claimForDownload,
    );
    autoDownloads = AutoDownloadService(
      storage: storage,
      checkAccount: _checkAutomaticAccount,
      loadCatalogue: (identity, albumId, cancelled, checkpoint) {
        AppLog.instance.trace(
          "lib/services/app_runtime.dart::AppRuntime.new.closure#3",
        );

        final client = accounts.clientFor(identity);
        return DownloadService.readRequests(
          client,
          storage.state['settings'] as Map,
          () {
            AppLog.instance.trace(
              "lib/services/app_runtime.dart::AppRuntime.new.closure#3.closure#1",
            );
            return XmlyCatalogue(client).album(albumId);
          },
          cancelled: cancelled,
          checkpoint: checkpoint,
        );
      },
      hasTask: (identity, trackId) {
        AppLog.instance.trace(
          "lib/services/app_runtime.dart::AppRuntime.new.closure#4",
        );
        return downloads.tasks.any((task) {
          AppLog.instance.trace(
            "lib/services/app_runtime.dart::AppRuntime.new.closure#4.closure#1",
          );
          return task.track.id == trackId &&
              (task.accountIdentity == identity ||
                  task.state == DownloadState.completed);
        });
      },
      enqueueNew: (identity, track, allowed, cancelled) async {
        AppLog.instance.trace(
          "lib/services/app_runtime.dart::AppRuntime.new.closure#5",
        );

        _checkAutomaticAccount(identity);
        final batch = await prepareDownloads(
          [track],
          accountIdentity: identity,
          automatic: true,
          cancelled: cancelled,
          checkpoint: () async {
            AppLog.instance.trace(
              "lib/services/app_runtime.dart::AppRuntime.new.closure#5.closure#1",
            );

            if (!allowed()) throw const DownloadStopped();
            _checkAutomaticAccount(identity);
          },
        );
        if (!allowed()) return;
        _checkAutomaticAccount(identity);
        await downloads.enqueueAutomatic(
          batch,
          allowed: () {
            AppLog.instance.trace(
              "lib/services/app_runtime.dart::AppRuntime.new.closure#5.closure#2",
            );

            if (!allowed()) return false;
            try {
              _checkAutomaticAccount(identity);
              return true;
            } catch (_) {
              return false;
            }
          },
        );
      },
    );
    player = PlayerService(
      storage: storage,
      accounts: accounts,
      ledger: ledger,
      downloads: downloads,
      pipeline: pipeline,
      anonymous: anonymous,
      prepareDownload: (tracks) {
        AppLog.instance.trace(
          "lib/services/app_runtime.dart::AppRuntime.new.closure#6",
        );
        return prepareDownloads(tracks);
      },
      confirmDownload: (batch) async {
        AppLog.instance.trace(
          "lib/services/app_runtime.dart::AppRuntime.new.closure#7",
        );
        return await confirmDownload?.call(batch) ?? false;
      },
      exitApplication: () async {
        AppLog.instance.trace(
          "lib/services/app_runtime.dart::AppRuntime.new.closure#8",
        );

        scheduledExit = true;
        if (requestExit != null) {
          await requestExit!();
        } else {
          scheduledExit = false;
          lifecycleError = '当前窗口不能执行退出';
          notifyListeners();
        }
      },
    );
    pauseHandlers.add(() {
      AppLog.instance.trace(
        "lib/services/app_runtime.dart::AppRuntime.new.closure#9",
      );
      return player.quiesce();
    });
    pauseHandlers.add(downloads.pauseAll);
  }

  final AppStorage storage;
  final CredentialStore secrets;
  late final XmlyClient anonymous;
  late final AlbumCache albumCache;
  late final AccountService accounts;
  late final UsageLedger ledger;
  late final MediaPipeline pipeline;
  late final DownloadService downloads;
  late final AutoDownloadService autoDownloads;
  late final PlayerService player;
  late final ConfigArchive backupArchive = ConfigArchive(
    storage: storage,
    accounts: accounts,
    secrets: secrets,
  );
  SystemMediaService? _systemMedia;
  AndroidBackgroundService? _androidBackground;
  Future<bool> Function(DownloadBatch)? confirmDownload;
  Future<void> Function()? requestExit;
  bool scheduledExit = false, _closed = false;
  StreamSubscription<void>? _playerChanges;
  StreamSubscription<void>? _downloadChanges;
  final List<Future<void> Function()> pauseHandlers = [];
  StreamSubscription<void>? _automaticChanges;
  final List<Future<void> Function()> settlementHandlers = [];
  final Map<String, DownloadState> _cachedDownloadStates = {};
  Future<void>? _restoreWork;
  bool _restoreNeedsReload = false;
  bool get restoreNeedsReload {
    AppLog.instance.trace(
      "lib/services/app_runtime.dart::AppRuntime.restoreNeedsReload.get",
    );
    return _restoreNeedsReload;
  }

  bool get restoringBackup {
    AppLog.instance.trace(
      "lib/services/app_runtime.dart::AppRuntime.restoringBackup.get",
    );
    return _restoreWork != null;
  }

  bool closing = false;
  bool _closeRunning = false;
  CloseSequence? _release;
  bool get exitOnly {
    AppLog.instance.trace(
      "lib/services/app_runtime.dart::AppRuntime.exitOnly.get",
    );
    return _release != null;
  }

  String? lifecycleError;
  Timer? _rewardTimer;
  bool _refreshingRewards = false;
  int _rewardGeneration = 0;
  final Map<String, Quota> _rewardChecks = {};
  int libraryRevision = 0;

  static void applyLogSettings(Map settings) {
    AppLog.instance.trace(
      "lib/services/app_runtime.dart::AppRuntime.applyLogSettings",
    );

    final value = settings['development'];
    final development = value is Map ? value : const {};
    AppLog.instance.level = AppLog.parseLevel(development['logLevel']);
    final prompt = development['promptLogUpload'];
    AppLog.instance.promptLogUpload = prompt is bool ? prompt : true;
  }

  XmlyClient get client {
    AppLog.instance.trace(
      "lib/services/app_runtime.dart::AppRuntime.client.get",
    );
    return accounts.activeClient ?? anonymous;
  }

  Future<void> load() {
    AppLog.instance.trace("lib/services/app_runtime.dart::AppRuntime.load");
    return AppLog.instance.runWithErrorScope(() async {
      AppLog.instance.trace(
        "lib/services/app_runtime.dart::AppRuntime.load.closure#1",
      );

      try {
        await _loadServices();
      } catch (error, stack) {
        _recordFailure('Loading runtime failed', error, stack);
        try {
          await _abortStartup();
        } catch (cleanupError, cleanupStack) {
          _recordFailure(
            'Rolling back runtime startup failed',
            cleanupError,
            cleanupStack,
          );
        }
        rethrow;
      }
      unawaited(autoDownloads.scanAll());
      _configureRewards();
      AppLog.instance.write(AppLogLevel.info, 'runtime', 'Runtime loaded');
    });
  }

  Future<void> _loadServices() async {
    AppLog.instance.trace(
      "lib/services/app_runtime.dart::AppRuntime._loadServices",
    );

    await anonymous.flushUrlCache();
    await accounts.load();
    await ledger.load();
    await albumCache.load();
    albumCache.addListener(_albumCacheChanged);
    await downloads.load();
    if (Platform.isAndroid) {
      _androidBackground = await AndroidBackgroundService.start(downloads);
    }
    for (final task in downloads.tasks) {
      _cachedDownloadStates[task.id] = task.state;
    }
    await player.load();
    if (Platform.isAndroid || Platform.isWindows) {
      _systemMedia = await SystemMediaService.start(
        player: player,
        albumCache: albumCache,
        commandsAllowed: () {
          AppLog.instance.trace(
            "lib/services/app_runtime.dart::AppRuntime._loadServices.closure#1",
          );
          return !closing &&
              !_closed &&
              !restoringBackup &&
              !restoreNeedsReload;
        },
      );
    }
    _playerChanges = player.changes.listen((_) {
      AppLog.instance.trace(
        "lib/services/app_runtime.dart::AppRuntime._loadServices.closure#2",
      );
      notifyListeners();
    });
    _downloadChanges = downloads.changes.listen((_) {
      AppLog.instance.trace(
        "lib/services/app_runtime.dart::AppRuntime._loadServices.closure#3",
      );

      _refreshDownloadedAlbums();
      notifyListeners();
    });
    _automaticChanges = autoDownloads.changes.listen((_) {
      AppLog.instance.trace(
        "lib/services/app_runtime.dart::AppRuntime._loadServices.closure#4",
      );
      notifyListeners();
    });
  }

  Future<void> _abortStartup() async {
    AppLog.instance.trace(
      "lib/services/app_runtime.dart::AppRuntime._abortStartup",
    );

    closing = true;
    autoDownloads.suspend();
    albumCache.removeListener(_albumCacheChanged);
    // No automatic work starts until every service has loaded. Release these
    // idle resources without settling accounts or saving an unloaded queue.
    // Wait for every cleanup even if one fails, before the caller closes storage.
    try {
      Future<void> cleanup(Future<void> Function() operation) {
        AppLog.instance.trace(
          "lib/services/app_runtime.dart::AppRuntime._abortStartup.cleanup",
        );
        return AppLog.instance.runWithErrorScope(() async {
          AppLog.instance.trace(
            "lib/services/app_runtime.dart::AppRuntime._abortStartup.cleanup.closure#1",
          );

          try {
            await operation();
          } catch (error, stack) {
            _recordFailure('Releasing startup resource failed', error, stack);
            rethrow;
          }
        });
      }

      await Future.wait<void>([
        if (_systemMedia != null) cleanup(_systemMedia!.close),
        if (_androidBackground != null) cleanup(_androidBackground!.close),
        cleanup(() {
          AppLog.instance.trace(
            "lib/services/app_runtime.dart::AppRuntime._abortStartup.closure#1",
          );
          return player.close(quiesced: true);
        }),
        if (_playerChanges != null) cleanup(_playerChanges!.cancel),
        if (_downloadChanges != null) cleanup(_downloadChanges!.cancel),
        if (_automaticChanges != null) cleanup(_automaticChanges!.cancel),
        cleanup(autoDownloads.close),
        cleanup(downloads.close),
        cleanup(() {
          AppLog.instance.trace(
            "lib/services/app_runtime.dart::AppRuntime._abortStartup.closure#2",
          );
          return accounts.close(preserveState: true);
        }),
        cleanup(albumCache.close),
        cleanup(pipeline.close),
        cleanup(() async {
          AppLog.instance.trace(
            "lib/services/app_runtime.dart::AppRuntime._abortStartup.closure#3",
          );

          anonymous.close();
          await anonymous.flushUrlCache();
        }),
      ]);
    } finally {
      _closed = true;
      await AppLog.instance.flush();
    }
  }

  void _albumCacheChanged() {
    AppLog.instance.trace(
      "lib/services/app_runtime.dart::AppRuntime._albumCacheChanged",
    );
    notifyListeners();
  }

  void _refreshDownloadedAlbums() {
    AppLog.instance.trace(
      "lib/services/app_runtime.dart::AppRuntime._refreshDownloadedAlbums",
    );

    if (closing || _closed) return;
    for (final task in downloads.tasks) {
      final previous = _cachedDownloadStates[task.id];
      _cachedDownloadStates[task.id] = task.state;
      if (restoringBackup ||
          restoreNeedsReload ||
          task.track.albumId.isEmpty ||
          downloads.albumJobs.any((job) {
            AppLog.instance.trace(
              "lib/services/app_runtime.dart::AppRuntime._refreshDownloadedAlbums.closure#1",
            );
            return job.albumId == task.track.albumId;
          }) ||
          (previous != null &&
              !(task.state == DownloadState.queued && previous != task.state) &&
              !(task.state == DownloadState.completed &&
                  previous != task.state))) {
        continue;
      }
      unawaited(
        AppLog.instance.runWithErrorScope(() async {
          AppLog.instance.trace(
            "lib/services/app_runtime.dart::AppRuntime._refreshDownloadedAlbums.closure#2",
          );

          try {
            final originalClient = task.accountIdentity == 'anonymous'
                ? anonymous
                : accounts.clientFor(task.accountIdentity);
            await albumCache.refresh(task.track.albumId, originalClient);
          } catch (error, stack) {
            _recordFailure(
              'Refreshing downloaded album metadata failed',
              error,
              stack,
            );
          }
        }),
      );
    }
  }

  void changed() {
    AppLog.instance.trace("lib/services/app_runtime.dart::AppRuntime.changed");

    downloads.settingsChanged();
    _configureRewards();
    notifyListeners();
  }

  void libraryChanged() {
    AppLog.instance.trace(
      "lib/services/app_runtime.dart::AppRuntime.libraryChanged",
    );

    XmlyExperience(client).invalidateLibrary();
    libraryRevision++;
    notifyListeners();
  }

  Future<String> downloadRoot() async {
    AppLog.instance.trace(
      "lib/services/app_runtime.dart::AppRuntime.downloadRoot",
    );

    final settings = storage.state['settings'] as Map;
    final configured = (settings['download'] as Map?)?['rootDirectory'];
    if (configured is String && configured.isNotEmpty)
      return absoluteFilePath(configured);
    final parent = Platform.isAndroid
        ? await getExternalStorageDirectory() ??
              await getApplicationSupportDirectory()
        : await getDownloadsDirectory() ??
              await getApplicationDocumentsDirectory();
    final directory = await Directory(p.join(parent.path, 'XMPlus'))
        .create(recursive: true);
    await storage.transaction((state) {
      AppLog.instance.trace(
        "lib/services/app_runtime.dart::AppRuntime.downloadRoot.closure#1",
      );

      final settings = state['settings'] as Map;
      final download = settings.putIfAbsent('download', () {
        AppLog.instance.trace(
          "lib/services/app_runtime.dart::AppRuntime.downloadRoot.closure#1.closure#1",
        );
        return <String, dynamic>{};
      }) as Map;
      download['rootDirectory'] = directory.path;
    });
    return directory.path;
  }

  Future<DownloadBatch> prepareDownloads(
    List<Track> tracks, {
    String? accountIdentity,
    bool automatic = false,
    bool? polling,
    bool previewBilling = true,
    Future<void>? cancelled,
    Future<void> Function()? checkpoint,
  }) async {
    AppLog.instance.trace(
      "lib/services/app_runtime.dart::AppRuntime.prepareDownloads",
    );

    final root = await downloadRoot();
    final settings = storage.state['settings'] as Map;
    final identity =
        accountIdentity ?? accounts.primaryAccountId ?? 'anonymous';
    final selected = <Track>[];
    final pages = <String, Map<int, AlbumPage>>{};
    final pattern =
        (settings['download'] as Map?)?['filenamePattern'] as String? ??
        '{index} - {title} [{trackId}]';
    for (final track in tracks) {
      if (pattern.contains('{index}') &&
          track.orderNo == null &&
          track.officialPosition == null &&
          track.albumId.isNotEmpty) {
        final albumPages = pages.putIfAbsent(track.albumId, () {
          AppLog.instance.trace(
            "lib/services/app_runtime.dart::AppRuntime.prepareDownloads.closure#1",
          );
          return {};
        });
        final source = identity == 'anonymous'
            ? anonymous
            : accounts.clientFor(identity);
        Track? matching;
        for (var page = 1; ; page++) {
          await checkpoint?.call();
          final result = albumPages[page] ??=
              await DownloadService.readRequests(
                source,
                settings,
                () {
                  AppLog.instance.trace(
                    "lib/services/app_runtime.dart::AppRuntime.prepareDownloads.closure#2",
                  );
                  return source.album(
                    track.albumId,
                    page: page,
                    pageSize: xmlyAlbumPageSize,
                    ascending: true,
                  );
                },
                cancelled: cancelled,
                checkpoint: checkpoint,
              );
          matching = result.tracks.where((item) {
            AppLog.instance.trace(
              "lib/services/app_runtime.dart::AppRuntime.prepareDownloads.closure#3",
            );
            return item.id == track.id;
          }).firstOrNull;
          if (matching != null || page * xmlyAlbumPageSize >= result.total)
            break;
        }
        if (matching == null) {
          throw const XmlyException('missing_official_order', '专辑中没有找到此声音');
        }
        selected.add(matching);
      } else {
        selected.add(track);
      }
    }
    return downloads.prepare(
      selected,
      accountIdentity: identity,
      rootDirectory: root,
      previewBilling: previewBilling,
      cancelled: cancelled,
      checkpoint: checkpoint,
      settings: {
        'download': {
          ...(settings['download'] as Map? ?? const {}),
          // Automatic consent is bound to this account, including later retries.
          'polling':
              !automatic &&
              (polling ?? (settings['download'] as Map?)?['polling'] != false),
        },
        'media': settings['media'] ?? <String, dynamic>{},
        'tags': settings['tags'] ?? <String, dynamic>{},
        'albumTags': settings['albumTags'] ?? <String, dynamic>{},
      },
    );
  }

  Future<DownloadBatch> prepareAlbumDownloads(
    String albumId, {
    String? accountIdentity,
    bool? polling,
  }) async {
    AppLog.instance.trace(
      "lib/services/app_runtime.dart::AppRuntime.prepareAlbumDownloads",
    );

    final settings = storage.state['settings'] as Map;
    return downloads.prepareAlbum(
      albumId,
      accountIdentity:
          accountIdentity ?? accounts.primaryAccountId ?? 'anonymous',
      rootDirectory: await downloadRoot(),
      previewBilling: false,
      settings: {
        'download': {
          ...(settings['download'] as Map? ?? const {}),
          'polling':
              polling ?? (settings['download'] as Map?)?['polling'] != false,
        },
        'media': settings['media'] ?? <String, dynamic>{},
        'tags': settings['tags'] ?? <String, dynamic>{},
        'albumTags': settings['albumTags'] ?? <String, dynamic>{},
      },
    );
  }

  bool get _automaticRewardsEnabled {
    AppLog.instance.trace(
      "lib/services/app_runtime.dart::AppRuntime._automaticRewardsEnabled.get",
    );
    return !closing &&
        !_closed &&
        !restoringBackup &&
        !restoreNeedsReload &&
        (storage.state['settings'] as Map)['autoClaim'] == true;
  }

  Future<int?> _claimForDownload(String identity, XmlyClient client) async {
    AppLog.instance.trace(
      "lib/services/app_runtime.dart::AppRuntime._claimForDownload",
    );

    if (!_automaticRewardsEnabled) return null;
    final record = (storage.state['accounts'] as Map)[identity] as Map?;
    if (record == null ||
        record['rewardPaused'] == true ||
        ledger.isBlocked(identity))
      return null;
    final checked = _rewardChecks[identity];
    if (checked != null &&
        DateTime.now().difference(checked.checkedAt) <
            const Duration(minutes: 5)) {
      var remaining = checked.remainingSeconds - ledger.debt(identity).ceil();
      for (final receipt in ledger.receipts(identity)) {
        if (receipt.state == DebitState.confirmed &&
            receipt.balanceAfter != null &&
            !receipt.createdAt.isBefore(checked.checkedAt) &&
            receipt.balanceAfter! < remaining) {
          remaining = receipt.balanceAfter!;
        }
      }
      if (remaining >= 7200) return null;
    }
    return _refreshAccountRewards(identity, client);
  }

  Future<int?> _refreshAccountRewards(String identity, XmlyClient client) {
    AppLog.instance.trace(
      "lib/services/app_runtime.dart::AppRuntime._refreshAccountRewards",
    );
    return AppLog.instance.runWithErrorScope(() async {
      AppLog.instance.trace(
        "lib/services/app_runtime.dart::AppRuntime._refreshAccountRewards.closure#1",
      );

      final generation = _rewardGeneration;
      bool allowed() {
        AppLog.instance.trace(
          "lib/services/app_runtime.dart::AppRuntime._refreshAccountRewards.closure#1.allowed",
        );
        return generation == _rewardGeneration && _automaticRewardsEnabled;
      }

      if (!allowed()) return null;
      final rewards = XmlyRewards(client, automaticEnabled: true);
      var increase = 0;
      try {
        final before = await client.queryQuota();
        if (!allowed()) return null;
        final after = await rewards.refresh(shouldContinue: allowed);
        _rewardChecks[identity] = after;
        increase = after.remainingSeconds - before.remainingSeconds;
      } catch (error, stack) {
        _recordFailure('Refreshing account rewards failed', error, stack);
        // Claim availability must not prevent an otherwise authorized download.
        return null;
      }
      if (rewards.lastError.isNotEmpty) {
        await storage.transaction((state) {
          AppLog.instance.trace(
            "lib/services/app_runtime.dart::AppRuntime._refreshAccountRewards.closure#1.closure#1",
          );

          ((state['accounts'] as Map)[identity] as Map)['rewardPaused'] = true;
        });
        if (!closing && !_closed) notifyListeners();
      }
      return increase > 0 ? increase : null;
    });
  }

  void _checkAutomaticAccount(String identity) {
    AppLog.instance.trace(
      "lib/services/app_runtime.dart::AppRuntime._checkAutomaticAccount",
    );

    if (closing ||
        _closed ||
        restoringBackup ||
        restoreNeedsReload ||
        accounts.admissionPaused ||
        !accounts.accountIds.contains(identity)) {
      throw const XmlyException('missing_account', '请先登录原账号');
    }
  }

  Future<void> pauseDownload(String id) async {
    AppLog.instance.trace(
      "lib/services/app_runtime.dart::AppRuntime.pauseDownload",
    );

    if (downloads.task(id).state == DownloadState.completed) return;
    if (player.currentTaskId == id && player.sourceKind != 'local') {
      await player.pause();
    }
    await downloads.pause(id);
    await pipeline.pauseTask(id);
  }

  Future<void> cancelDownload(String id) async {
    AppLog.instance.trace(
      "lib/services/app_runtime.dart::AppRuntime.cancelDownload",
    );

    await cancelDownloads([id]);
  }

  Future<void> cancelDownloads(Iterable<String> taskIds) async {
    AppLog.instance.trace(
      'lib/services/app_runtime.dart::AppRuntime.cancelDownloads',
    );
    _requireDownloadActions();
    autoDownloads.invalidatePending();
    final ids = taskIds.toSet();
    for (final id in ids) {
      await player.stopTaskReference(id);
    }
    _requireDownloadActions();
    await downloads.cancelMany(ids);
    for (final id in ids) {
      await pipeline.pauseTask(id);
    }
  }

  Future<void> cancelAllDownloads() async {
    AppLog.instance.trace(
      'lib/services/app_runtime.dart::AppRuntime.cancelAllDownloads',
    );
    _requireDownloadActions();
    autoDownloads.invalidatePending();
    final ids = [
      for (final task in downloads.tasks)
        if (task.state != DownloadState.completed) task.id,
    ];
    for (final id in ids) {
      await player.stopTaskReference(id);
    }
    _requireDownloadActions();
    await downloads.cancelAll();
    for (final id in ids) {
      await pipeline.pauseTask(id);
    }
  }

  Future<void> cancelAlbumDownloads(String id) async {
    AppLog.instance.trace(
      'lib/services/app_runtime.dart::AppRuntime.cancelAlbumDownloads',
    );
    _requireDownloadActions();
    autoDownloads.invalidatePending();
    final job = downloads.albumJobs.firstWhere((job) {
      AppLog.instance.trace(
        'lib/services/app_runtime.dart::AppRuntime.cancelAlbumDownloads.closure#1',
      );
      return job.id == id;
    });
    final ids = [
      for (final taskId in job.taskIds)
        if (downloads.task(taskId).state != DownloadState.completed) taskId,
    ];
    for (final taskId in ids) {
      await player.stopTaskReference(taskId);
    }
    _requireDownloadActions();
    await downloads.cancelAlbum(id);
    for (final taskId in ids) {
      await pipeline.pauseTask(taskId);
    }
  }

  void _requireDownloadActions() {
    AppLog.instance.trace(
      'lib/services/app_runtime.dart::AppRuntime._requireDownloadActions',
    );
    if (closing || _closed || restoringBackup || restoreNeedsReload) {
      throw const XmlyException('task_busy', '请先完成备份恢复或重新打开应用');
    }
  }

  Future<void> pauseAllDownloads() async {
    AppLog.instance.trace(
      "lib/services/app_runtime.dart::AppRuntime.pauseAllDownloads",
    );

    // Invalidate before awaiting playback or queue locks: a late catalogue or
    // authorization result must not create new work after this pause command.
    autoDownloads.invalidatePending();
    final playingTask = player.currentTaskId;
    if (playingTask != null &&
        player.sourceKind != 'local' &&
        downloads.task(playingTask).state != DownloadState.completed) {
      await player.pause();
    }
    await downloads.pauseAll();
  }

  Future<void> reacquireDownload(String id) async {
    AppLog.instance.trace(
      "lib/services/app_runtime.dart::AppRuntime.reacquireDownload",
    );

    await player.stopTaskReference(id);
    await downloads.pause(id);
    await downloads.retry(id, reacquire: true);
  }

  Future<void> relocateDownload(String id, String directory) async {
    AppLog.instance.trace(
      "lib/services/app_runtime.dart::AppRuntime.relocateDownload",
    );

    await player.stopTaskReference(id);
    await downloads.pause(id);
    await pipeline.detachTask(id);
    await downloads.relocate(id, directory);
  }

  Future<void> restoreBackup(
    ArchiveImport draft, {
    Map<String, String> relocatedRoots = const {},
  }) {
    AppLog.instance.trace(
      "lib/services/app_runtime.dart::AppRuntime.restoreBackup",
    );
    if (closing || _closed) {
      return Future.error(StateError('应用正在退出，请重新打开后加载备份'));
    }
    if (restoringBackup || restoreNeedsReload) {
      return Future.error(StateError('请先完成当前备份的恢复'));
    }
    return _startRestore(() {
      AppLog.instance.trace(
        "lib/services/app_runtime.dart::AppRuntime.restoreBackup.closure#1",
      );
      return backupArchive.restore(draft, relocatedRoots: relocatedRoots);
    });
  }

  Future<void> reloadAfterRestore() {
    AppLog.instance.trace(
      "lib/services/app_runtime.dart::AppRuntime.reloadAfterRestore",
    );
    if (closing || _closed) {
      return Future.error(StateError('应用正在退出，请重新打开后加载备份'));
    }
    final pending = _restoreWork;
    if (pending != null) return pending;
    return _startRestore(null);
  }

  Future<void> _startRestore(Future<void> Function()? writeBackup) {
    AppLog.instance.trace(
      "lib/services/app_runtime.dart::AppRuntime._startRestore",
    );
    if (writeBackup == null) _restoreNeedsReload = true;
    lifecycleError = null;
    autoDownloads.suspend();
    _rewardChecks.clear();
    final future = _restoreBackup(writeBackup);
    _restoreWork = future;
    _configureRewards();
    notifyListeners();
    return future;
  }

  Future<void> _restoreBackup(Future<void> Function()? writeBackup) {
    AppLog.instance.trace(
      "lib/services/app_runtime.dart::AppRuntime._restoreBackup",
    );
    return AppLog.instance.runWithErrorScope(() async {
      AppLog.instance.trace(
        "lib/services/app_runtime.dart::AppRuntime._restoreBackup.closure#1",
      );
      try {
        if (writeBackup != null) {
          await writeBackup();
          _restoreNeedsReload = true;
        }
        applyLogSettings(storage.state['settings'] as Map);
        await downloads.reload();
        _cachedDownloadStates
          ..clear()
          ..addEntries(
            downloads.tasks.map((task) {
              AppLog.instance.trace(
                "lib/services/app_runtime.dart::AppRuntime._restoreBackup.closure#1.closure#1",
              );
              return MapEntry(task.id, task.state);
            }),
          );
        await ledger.load();
        await player.reload();
        _restoreNeedsReload = false;
        lifecycleError = null;
        AppLog.instance.write(
          AppLogLevel.info,
          'runtime',
          'Restored profile loaded',
        );
      } catch (error, stack) {
        _recordFailure('Loading restored profile failed', error, stack);
        if (restoreNeedsReload) {
          lifecycleError = '备份内容已保存，但加载未完成。请检查资料目录后重试加载，或退出后重新打开应用。';
        }
        rethrow;
      } finally {
        _restoreWork = null;
        if (!closing && !restoreNeedsReload) autoDownloads.resume();
        changed();
      }
    });
  }

  void _configureRewards() {
    AppLog.instance.trace(
      "lib/services/app_runtime.dart::AppRuntime._configureRewards",
    );

    final enabled = _automaticRewardsEnabled;
    if (!enabled) {
      // Re-enabling starts a new run; an in-flight old run stays cancelled.
      _rewardGeneration++;
      _rewardTimer?.cancel();
      _rewardTimer = null;
    } else {
      _rewardTimer ??= Timer.periodic(const Duration(minutes: 5), (_) {
        AppLog.instance.trace(
          "lib/services/app_runtime.dart::AppRuntime._configureRewards.closure#1",
        );
        unawaited(_refreshRewards());
      });
    }
  }

  Future<void> _refreshRewards() {
    AppLog.instance.trace(
      "lib/services/app_runtime.dart::AppRuntime._refreshRewards",
    );
    return AppLog.instance.runWithErrorScope(() async {
      AppLog.instance.trace(
        "lib/services/app_runtime.dart::AppRuntime._refreshRewards.closure#1",
      );

      if (_refreshingRewards || !_automaticRewardsEnabled) return;
      final generation = _rewardGeneration;
      bool allowed() {
        AppLog.instance.trace(
          "lib/services/app_runtime.dart::AppRuntime._refreshRewards.closure#1.allowed",
        );
        return generation == _rewardGeneration && _automaticRewardsEnabled;
      }

      _refreshingRewards = true;
      try {
        for (final identity in accounts.accountIds.toList()) {
          if (!allowed()) break;
          final record = (storage.state['accounts'] as Map)[identity] as Map;
          if (record['rewardPaused'] == true) continue;
          try {
            await accounts.runWithAccount(identity, (client) async {
              AppLog.instance.trace(
                "lib/services/app_runtime.dart::AppRuntime._refreshRewards.closure#1.closure#1",
              );

              if (!allowed()) return;
              await _refreshAccountRewards(identity, client);
            });
          } catch (error, stack) {
            _recordFailure('Refreshing account rewards failed', error, stack);
            // A failed account refresh never triggers account rotation or replay.
          }
        }
      } finally {
        _refreshingRewards = false;
      }
    });
  }

  Future<void> _quiesceForRestore() async {
    AppLog.instance.trace(
      "lib/services/app_runtime.dart::AppRuntime._quiesceForRestore",
    );

    autoDownloads.suspend();
    try {
      await player.quiesce(preserveUnknown: true);
      await downloads.pauseAll();
      await ledger.captureForRestore();
    } finally {
      // The account mutex still blocks new admissions until restore finishes.
      if (!closing && !restoringBackup && !restoreNeedsReload)
        autoDownloads.resume();
    }
  }

  Future<void> quiesce() async {
    AppLog.instance.trace("lib/services/app_runtime.dart::AppRuntime.quiesce");

    autoDownloads.suspend();
    try {
      for (final pause in List.of(pauseHandlers)) {
        await pause();
      }
    } finally {
      if (!closing && !restoringBackup && !restoreNeedsReload)
        autoDownloads.resume();
    }
  }

  Future<void> settle() async {
    AppLog.instance.trace("lib/services/app_runtime.dart::AppRuntime.settle");

    for (final settle in List.of(settlementHandlers)) {
      await settle();
    }
  }

  void _recordFailure(String message, Object error, StackTrace stack) {
    AppLog.instance.trace(
      "lib/services/app_runtime.dart::AppRuntime._recordFailure",
    );

    if (error is DownloadStopped) return;
    if (error is StorageException &&
        const {
          'directory',
          'locked',
          'too_large',
          'secret_in_state',
        }.contains(error.code))
      return;
    if (error is AccountException &&
        const {
          'credential_missing',
          'missing',
          'paused',
          'closed',
          'not_loaded',
          'credential_mismatch',
          'archive_invalid',
          'quota_invalid',
          'unsettled',
        }.contains(error.code))
      return;
    if (error is XmlyException &&
        const {
          'invalid_credentials',
          'invalid_id',
          'invalid_quality',
          'invalid_retry',
          'invalid_endpoint',
          'invalid_duration',
          'invalid_speed',
          'login_required',
          'login_expired',
          'auth_required',
          'challenge_invalid',
          'challenge_expired',
          'sms_cooldown',
          'client_closed',
          'request_cancelled',
          'missing_account',
          'account_mismatch',
          'task_mismatch',
          'confirmation_required',
          'confirmation_changed',
          'insufficient_quota',
          'usage_uncertain',
        }.contains(error.code))
      return;
    if (!AppLog.instance.errorWasRecorded(error)) {
      AppLog.instance.write(
        AppLogLevel.error,
        'runtime',
        message,
        error: error,
        stackTrace: stack,
        promptUser: true,
      );
    }
    AppLog.instance.requestUploadPrompt();
  }

  Future<bool> close() {
    AppLog.instance.trace("lib/services/app_runtime.dart::AppRuntime.close");
    return AppLog.instance.runWithErrorScope(() async {
      AppLog.instance.trace(
        "lib/services/app_runtime.dart::AppRuntime.close.closure#1",
      );

      if (_closed) return true;
      if (_closeRunning) return false;
      _closeRunning = true;
      closing = true;
      lifecycleError = null;
      _rewardGeneration++;
      autoDownloads.suspend();
      _rewardTimer?.cancel();
      _rewardTimer = null;
      notifyListeners();
      try {
        try {
          await _restoreWork;
        } catch (_) {
          // A failed reload still permits exit with the committed backup intact.
        }
        lifecycleError = null;
        if (_release == null) {
          await quiesce();
          await settle();
          // From this point, services may be irreversibly closed. Keep the UI in
          // exit-only mode and retry the failed step without repeating teardown.
          _release = CloseSequence([
            () async {
              AppLog.instance.trace(
                "lib/services/app_runtime.dart::AppRuntime.close.closure#1.closure#1",
              );

              await _systemMedia?.close();
            },
            () async {
              AppLog.instance.trace(
                "lib/services/app_runtime.dart::AppRuntime.close.closure#1.closure#2",
              );

              await _androidBackground?.close();
            },
            () async {
              AppLog.instance.trace(
                "lib/services/app_runtime.dart::AppRuntime.close.closure#1.closure#3",
              );

              await albumCache.close();
              albumCache.removeListener(_albumCacheChanged);
            },
            // Drain final history sync while the account client can still finish it.
            () {
              AppLog.instance.trace(
                "lib/services/app_runtime.dart::AppRuntime.close.closure#1.closure#4",
              );
              return player.close(quiesced: true);
            },
            // The exit boundary already settled or preserved pending usage.
            () {
              AppLog.instance.trace(
                "lib/services/app_runtime.dart::AppRuntime.close.closure#1.closure#5",
              );
              return accounts.close(preserveState: true);
            },
            () async {
              AppLog.instance.trace(
                "lib/services/app_runtime.dart::AppRuntime.close.closure#1.closure#6",
              );

              await _playerChanges?.cancel();
            },
            autoDownloads.close,
            () async {
              AppLog.instance.trace(
                "lib/services/app_runtime.dart::AppRuntime.close.closure#1.closure#7",
              );

              await _automaticChanges?.cancel();
            },
            downloads.close,
            () async {
              AppLog.instance.trace(
                "lib/services/app_runtime.dart::AppRuntime.close.closure#1.closure#8",
              );

              await _downloadChanges?.cancel();
            },
            pipeline.close,
            () async {
              AppLog.instance.trace(
                "lib/services/app_runtime.dart::AppRuntime.close.closure#1.closure#9",
              );

              anonymous.close();
              await anonymous.flushUrlCache();
            },
            storage.close,
          ]);
        }
        await _release!.run();
        _closed = true;
        AppLog.instance.write(AppLogLevel.info, 'runtime', 'Runtime closed');
        return true;
      } catch (error, stack) {
        _recordFailure('Closing runtime failed', error, stack);
        lifecycleError = exitOnly
            ? '退出未完成，部分服务已关闭，请重试退出后重新打开应用'
            : '保存或结算未完成，请稍后重试退出';
        if (!exitOnly) {
          closing = false;
          if (!restoreNeedsReload) autoDownloads.resume();
          _configureRewards();
        }
        notifyListeners();
        return false;
      } finally {
        await AppLog.instance.flush();
        _closeRunning = false;
      }
    });
  }
}
