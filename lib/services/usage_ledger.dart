// Ported from xmly/usage.py (AGPL-3.0-or-later); see LICENSE/NOTICE.
import 'package:synchronized/synchronized.dart';
import 'package:uuid/uuid.dart';

import '../api/xmly_client.dart';
import '../models/xmly_models.dart';
import '../storage/app_storage.dart';
import 'app_log.dart';

enum DebitState { prepared, submitting, confirmed, uncertain, rejected }

class DownloadReceipt {
  const DownloadReceipt({
    required this.operationId,
    required this.accountIdentity,
    required this.trackId,
    required this.taskId,
    required this.seconds,
    required this.balanceBefore,
    this.balanceAfter,
    required this.createdAt,
    required this.state,
    this.historical = false,
  });

  final String operationId, accountIdentity, trackId, taskId;
  final int seconds, balanceBefore;
  final int? balanceAfter;
  final DateTime createdAt;
  final DebitState state;
  final bool historical;

  factory DownloadReceipt.fromJson(Map<String, dynamic> value) {
    AppLog.instance.trace(
      "lib/services/usage_ledger.dart::DownloadReceipt.factory:fromJson",
    );

    final historical =
        value['historical'] == true || value['state'] == 'historical';
    final state = value['state'] == 'historical'
        ? DebitState.confirmed
        : DebitState.values.where((item) {
            AppLog.instance.trace(
              "lib/services/usage_ledger.dart::DownloadReceipt.factory:fromJson.closure#1",
            );
            return item.name == value['state'];
          }).firstOrNull;
    if (state == null ||
        ['operationId', 'accountIdentity', 'trackId', 'taskId'].any((key) {
          AppLog.instance.trace(
            "lib/services/usage_ledger.dart::DownloadReceipt.factory:fromJson.closure#2",
          );
          return value[key] is! String || (value[key] as String).isEmpty;
        }) ||
        value['seconds'] is! int ||
        (value['seconds'] as int) < 1 ||
        (value['seconds'] as int) > UsageLedger.maxSeconds ||
        value['balanceBefore'] is! int ||
        (value['balanceBefore'] as int) < 0 ||
        (value['balanceAfter'] != null &&
            (value['balanceAfter'] is! int ||
                (value['balanceAfter'] as int) < 0)) ||
        value['createdAt'] is! int) {
      throw const XmlyException('invalid_ledger', '扣时记录损坏，请保留资料并恢复备份');
    }
    return DownloadReceipt(
      operationId: value['operationId'] as String,
      accountIdentity: value['accountIdentity'] as String,
      trackId: 'xmly:${xmlyIdentifier(value['trackId'] as String)}',
      taskId: value['taskId'] as String,
      seconds: value['seconds'] as int,
      balanceBefore: value['balanceBefore'] as int,
      balanceAfter: value['balanceAfter'] as int?,
      createdAt: DateTime.fromMillisecondsSinceEpoch(value['createdAt'] as int),
      state: state,
      historical: historical,
    );
  }

  Map<String, dynamic> toJson() {
    AppLog.instance.trace(
      "lib/services/usage_ledger.dart::DownloadReceipt.toJson",
    );
    return {
      'operationId': operationId,
      'accountIdentity': accountIdentity,
      'trackId': trackId,
      'taskId': taskId,
      'seconds': seconds,
      'balanceBefore': balanceBefore,
      'balanceAfter': balanceAfter,
      'createdAt': createdAt.millisecondsSinceEpoch,
      'state': historical && state == DebitState.confirmed
          ? 'historical'
          : state.name,
      if (historical) ...{'historical': true, 'downloadExempt': false},
    };
  }
}

/// One account mutex covers online debt and download prepayments. A local UUID
/// identifies the journal entry only: the server has no idempotency key.
class UsageLedger {
  UsageLedger({
    required this.storage,
    required this.clientFor,
    Duration Function()? monotonic,
    DateTime Function()? clock,
  }) : _monotonic = monotonic ?? _elapsedClock(),
       _clock = clock ?? DateTime.now {
    AppLog.instance.trace("lib/services/usage_ledger.dart::UsageLedger.new");
  }

  static const maxSeconds = 2147483647;
  static const reportFactor = 1.0;
  final AppStorage storage;
  final XmlyClient Function(String identity) clientFor;
  final Duration Function() _monotonic;
  final DateTime Function() _clock;
  final Map<String, Lock> _locks = {};
  final Lock _watchChanges = Lock();
  _Listening? _watch;

  void _recordFailure(Object error, StackTrace stack, String identity) {
    AppLog.instance.trace(
      "lib/services/usage_ledger.dart::UsageLedger._recordFailure",
    );

    if (error is XmlyException &&
        const {
          'usage_uncertain',
          'insufficient_quota',
          'confirmation_required',
          'confirmation_changed',
          'login_required',
          'login_expired',
          'missing_account',
          'account_mismatch',
          'task_mismatch',
          'invalid_duration',
          'invalid_speed',
          'cancelled',
          'client_closed',
        }.contains(error.code))
      return;
    AppLog.instance.requestUploadPrompt();
    if (AppLog.instance.errorWasRecorded(error)) return;
    AppLog.instance.write(
      AppLogLevel.error,
      'usage',
      'Listening-time operation failed',
      data: {'account': identity},
      error: error,
      stackTrace: stack,
      promptUser: true,
    );
  }

  bool get needsRestart {
    AppLog.instance.trace(
      "lib/services/usage_ledger.dart::UsageLedger.needsRestart.get",
    );
    return _watch?.suspended ?? false;
  }

  static Duration Function() _elapsedClock() {
    AppLog.instance.trace(
      "lib/services/usage_ledger.dart::UsageLedger._elapsedClock",
    );

    final watch = Stopwatch()..start();
    return () {
      AppLog.instance.trace(
        "lib/services/usage_ledger.dart::UsageLedger._elapsedClock.closure#1",
      );
      return watch.elapsed;
    };
  }

  Lock _lock(String identity) {
    AppLog.instance.trace("lib/services/usage_ledger.dart::UsageLedger._lock");
    return _locks.putIfAbsent(identity, Lock.new);
  }

  Map<String, dynamic> _ledger(String identity) {
    AppLog.instance.trace(
      "lib/services/usage_ledger.dart::UsageLedger._ledger",
    );

    final account = (storage.state['accounts'] as Map)[identity];
    if (account is! Map) {
      throw const XmlyException('missing_account', '请先登录原账号');
    }
    final ledger = account['ledger'];
    if (ledger != null && ledger is! Map<String, dynamic>) {
      throw const XmlyException('invalid_ledger', '扣时资料损坏，请保留资料');
    }
    final result = ledger as Map<String, dynamic>? ?? const <String, dynamic>{};
    if ((result['usage_uncertain'] != null &&
            result['usage_uncertain'] is! bool) ||
        (result['usage_pending'] != null && result['usage_pending'] is! Map)) {
      throw const XmlyException('invalid_ledger', '待核对扣时资料无效，请保留资料');
    }
    return result;
  }

  Future<void> _write(
    String identity,
    void Function(Map<String, dynamic>) update,
  ) {
    AppLog.instance.trace("lib/services/usage_ledger.dart::UsageLedger._write");
    return storage.transaction((state) {
      AppLog.instance.trace(
        "lib/services/usage_ledger.dart::UsageLedger._write.closure#1",
      );

      final account = (state['accounts'] as Map)[identity];
      if (account is! Map) {
        throw const XmlyException('missing_account', '请先登录原账号');
      }
      final ledger = account.putIfAbsent('ledger', () {
        AppLog.instance.trace(
          "lib/services/usage_ledger.dart::UsageLedger._write.closure#1.closure#1",
        );
        return <String, dynamic>{};
      });
      if (ledger is! Map<String, dynamic>) {
        throw const XmlyException('invalid_ledger', '扣时资料损坏，请保留资料');
      }
      update(ledger);
    });
  }

  List<DownloadReceipt> receipts(String identity) {
    AppLog.instance.trace(
      "lib/services/usage_ledger.dart::UsageLedger.receipts",
    );

    final items = _ledger(identity)['receipts'] ?? const [];
    if (items is! List) {
      throw const XmlyException('invalid_ledger', '扣时记录损坏，请保留资料');
    }
    return List.unmodifiable(
      items.map((item) {
        AppLog.instance.trace(
          "lib/services/usage_ledger.dart::UsageLedger.receipts.closure#1",
        );

        if (item is! Map) {
          throw const XmlyException('invalid_ledger', '扣时记录损坏，请保留资料');
        }
        final receipt = DownloadReceipt.fromJson(
          Map<String, dynamic>.from(item),
        );
        if (receipt.accountIdentity != identity) {
          throw const XmlyException('invalid_ledger', '扣时记录与账号不符');
        }
        return receipt;
      }),
    );
  }

  bool isBlocked(String identity) {
    AppLog.instance.trace(
      "lib/services/usage_ledger.dart::UsageLedger.isBlocked",
    );

    final ledger = _ledger(identity);
    return ledger['usage_uncertain'] == true ||
        ledger['usage_pending'] != null ||
        receipts(identity).any((item) {
          AppLog.instance.trace(
            "lib/services/usage_ledger.dart::UsageLedger.isBlocked.closure#1",
          );
          return item.state == DebitState.submitting ||
              item.state == DebitState.uncertain;
        });
  }

  Future<void> _guard(String identity) async {
    AppLog.instance.trace("lib/services/usage_ledger.dart::UsageLedger._guard");

    if (clientFor(identity).identity != identity) {
      throw const XmlyException('account_mismatch', '请求账号已改变，请重新操作');
    }
    if (isBlocked(identity)) await _refreshPending(identity);
  }

  static const _uncertain = XmlyException(
    'usage_uncertain',
    '听时暂时无法确认，正在自动核对，请稍后再试',
  );

  /// Local recovery only; operation entry points refresh quota without replaying.
  Future<void> load() async {
    AppLog.instance.trace("lib/services/usage_ledger.dart::UsageLedger.load");

    for (final identity
        in (storage.state['accounts'] as Map).keys.cast<String>().toList()) {
      await _lock(identity).synchronized(() {
        AppLog.instance.trace(
          "lib/services/usage_ledger.dart::UsageLedger.load.closure#1",
        );
        return _recover(identity);
      });
    }
  }

  Future<void> _recover(String identity) async {
    AppLog.instance.trace(
      "lib/services/usage_ledger.dart::UsageLedger._recover",
    );

    final ledger = _ledger(identity);
    final entries = receipts(identity);
    final pending = ledger['usage_pending'];
    final recoverPending = pending is Map && pending['state'] == 'submitting';
    if (!recoverPending &&
        !entries.any((item) {
          AppLog.instance.trace(
            "lib/services/usage_ledger.dart::UsageLedger._recover.closure#1",
          );
          return item.state == DebitState.submitting;
        }))
      return;
    await _write(identity, (next) {
      AppLog.instance.trace(
        "lib/services/usage_ledger.dart::UsageLedger._recover.closure#2",
      );

      for (final entry in next['receipts'] as List? ?? const []) {
        if (entry is Map && entry['state'] == 'submitting')
          entry['state'] = 'uncertain';
      }
      if (recoverPending) {
        (next['usage_pending'] as Map)['state'] = 'uncertain';
        next['usage_uncertain'] = true;
      }
    });
  }

  Future<Quota> queryQuota(String identity) {
    AppLog.instance.trace(
      "lib/services/usage_ledger.dart::UsageLedger.queryQuota",
    );
    return _lock(identity).synchronized(() async {
      AppLog.instance.trace(
        "lib/services/usage_ledger.dart::UsageLedger.queryQuota.closure#1",
      );

      final client = clientFor(identity);
      if (client.identity != identity) {
        throw const XmlyException('account_mismatch', '请使用原账号核对听时');
      }
      return client.queryQuota();
    });
  }

  Future<DownloadReceipt?> prepay({
    required String identity,
    required String taskId,
    required ResolvedAudio audio,
    required bool userConfirmed,
    int? expectedSeconds,
    int? expectedBalance,
    Future<void> Function(Duration delay)? wait,
  }) {
    AppLog.instance.trace("lib/services/usage_ledger.dart::UsageLedger.prepay");
    return AppLog.instance.runWithErrorScope(() {
      AppLog.instance.trace(
        "lib/services/usage_ledger.dart::UsageLedger.prepay.closure#1",
      );
      return _lock(identity).synchronized(() async {
        AppLog.instance.trace(
          "lib/services/usage_ledger.dart::UsageLedger.prepay.closure#1.closure#1",
        );

        if (!audio.requiresReward) return null;
        if (audio.accountIdentity != identity || taskId.trim().isEmpty) {
          throw const XmlyException('account_mismatch', '声音授权与下载账号不符');
        }
        await _recover(identity);
        await _guard(identity);
        for (final receipt in receipts(identity).reversed) {
          if (receipt.taskId != taskId) continue;
          if (receipt.trackId != audio.track.id) {
            throw const XmlyException('task_mismatch', '原任务与声音不符');
          }
          if (receipt.state == DebitState.confirmed && !receipt.historical)
            return receipt;
        }
        final duration = audio.track.duration;
        if (!duration.isFinite || duration <= 0 || duration > maxSeconds) {
          throw const XmlyException('invalid_duration', '缺少有效的整首时长，不能预扣下载');
        }
        final seconds = duration.ceil();
        if (!userConfirmed) {
          throw const XmlyException(
            'confirmation_required',
            '请先确认本首扣时及不可自动退款说明',
          );
        }
        await _settleLocked(identity, pause: false);
        // Settlement takes its own balance lock. Acquire this only afterwards;
        // keep the fresh quote, durable journal, report and result atomic to claims.
        return clientFor(identity).withBalanceChange(() async {
          AppLog.instance.trace(
            "lib/services/usage_ledger.dart::UsageLedger.prepay.closure#1.closure#1.closure#1",
          );

          final quota = await clientFor(identity).queryQuota();
          if ((expectedSeconds != null && expectedSeconds != seconds) ||
              (expectedBalance != null &&
                  expectedBalance != quota.remainingSeconds)) {
            throw const XmlyException('confirmation_changed', '时长或余额已改变，请重新确认');
          }
          if (quota.remainingSeconds < seconds) throw _insufficient;
          for (var attempt = 0; ; attempt++) {
            final operation = DownloadReceipt(
              operationId: const Uuid().v4(),
              accountIdentity: identity,
              trackId: audio.track.id,
              taskId: taskId,
              seconds: seconds,
              balanceBefore: quota.remainingSeconds,
              createdAt: _clock(),
              state: DebitState.submitting,
            ).toJson();
            try {
              await _submit(identity, operation, online: false);
              return receipts(identity).singleWhere((item) {
                AppLog.instance.trace(
                  "lib/services/usage_ledger.dart::UsageLedger.prepay.closure#1.closure#1.closure#1.closure#1",
                );
                return item.operationId == operation['operationId'];
              });
            } on XmlyException catch (error) {
              final rejected = receipts(identity).any((receipt) {
                AppLog.instance.trace(
                  "lib/services/usage_ledger.dart::UsageLedger.prepay.closure#1.closure#1.closure#1.closure#2",
                );
                return receipt.operationId == operation['operationId'] &&
                    receipt.state == DebitState.rejected;
              });
              if (!rejected ||
                  !error.definitive ||
                  attempt >= 4 ||
                  const {
                    'invalid_duration',
                    'invalid_ledger',
                    'login_expired',
                    'login_required',
                    'account_mismatch',
                    'invalid_endpoint',
                    'insufficient_quota',
                    'rate_limited',
                  }.contains(error.code))
                rethrow;
              final backoff = Duration(seconds: 1 << attempt);
              final delay = (error.retryAfter ?? Duration.zero) > backoff
                  ? error.retryAfter!
                  : backoff;
              if (wait != null) {
                await wait(delay);
              } else {
                await Future<void>.delayed(delay);
              }
              await _guard(identity);
              final refreshed = await clientFor(identity).queryQuota();
              if (refreshed.remainingSeconds != quota.remainingSeconds) {
                throw const XmlyException(
                  'confirmation_changed',
                  '重试前余额已变化，请重新确认',
                );
              }
            }
          }
        });
      });
    });
  }

  static const _insufficient = XmlyException(
    'insufficient_quota',
    '听时不足，请前往官方 App 获取听时',
    definitive: true,
  );

  double debt(String identity) {
    AppLog.instance.trace("lib/services/usage_ledger.dart::UsageLedger.debt");

    final value = _ledger(identity)['usage_seconds'] ?? 0.0;
    if (value is! num || !value.isFinite || value < 0) {
      throw const XmlyException('invalid_ledger', '实际收听记录无效，请保留资料');
    }
    return value.toDouble();
  }

  /// Starts paused. Only actual playback state events may enable metering.
  Future<void> startWatch({
    required String identity,
    required String trackId,
    required bool requiresReward,
    bool prepaid = false,
    double speed = 1,
  }) {
    AppLog.instance.trace(
      "lib/services/usage_ledger.dart::UsageLedger.startWatch",
    );
    return _watchChanges.synchronized(() async {
      AppLog.instance.trace(
        "lib/services/usage_ledger.dart::UsageLedger.startWatch.closure#1",
      );

      _validSpeed(speed);
      final normalized = 'xmly:${xmlyIdentifier(trackId)}';
      await _stopWatch();
      if (!requiresReward || prepaid || identity == 'anonymous') return;
      await _lock(identity).synchronized(() async {
        AppLog.instance.trace(
          "lib/services/usage_ledger.dart::UsageLedger.startWatch.closure#1.closure#1",
        );

        await _recover(identity);
        await _guard(identity);
        final quota = await clientFor(identity).queryQuota();
        final newDevice = quota.newDevice && quota.remainingSeconds == 0;
        if (!newDevice && quota.remainingSeconds - debt(identity) <= 0) {
          throw _insufficient;
        }
        _watch = _Listening(identity, normalized, speed, _monotonic());
      });
    });
  }

  static void _validSpeed(double speed) {
    AppLog.instance.trace(
      "lib/services/usage_ledger.dart::UsageLedger._validSpeed",
    );

    if (!speed.isFinite || speed < 0.5 || speed > 3) {
      throw const XmlyException('invalid_speed', '播放倍速范围为 0.5–3.0');
    }
  }

  /// No position argument: seeking can never produce billable seconds.
  /// Record device events immediately; periodic saves use [sampleCurrentState].
  void recordPlaybackState({
    required bool playing,
    required bool buffering,
    double? speed,
  }) {
    AppLog.instance.trace(
      "lib/services/usage_ledger.dart::UsageLedger.recordPlaybackState",
    );

    if (speed != null) _validSpeed(speed);
    final watch = _watch;
    if (watch == null || watch.suspended) return;
    _captureElapsed(watch);
    watch.playing = playing && !buffering;
    if (speed != null) watch.speed = speed;
  }

  /// Save the latest device state without replacing it with queued UI state.
  Future<void> sampleCurrentState({double? speed}) {
    AppLog.instance.trace(
      "lib/services/usage_ledger.dart::UsageLedger.sampleCurrentState",
    );

    if (speed != null) {
      _validSpeed(speed);
      final watch = _watch;
      if (watch != null) {
        _captureElapsed(watch);
        watch.speed = speed;
      }
    }
    return observe(
      playing: _watch?.playing ?? false,
      buffering: false,
      stateAlreadyRecorded: true,
    );
  }

  Future<void> observe({
    required bool playing,
    required bool buffering,
    double? speed,
    bool stateAlreadyRecorded = false,
  }) {
    AppLog.instance.trace(
      "lib/services/usage_ledger.dart::UsageLedger.observe",
    );

    if (!stateAlreadyRecorded) {
      recordPlaybackState(playing: playing, buffering: buffering, speed: speed);
    }
    final observedWatch = _watch;
    return AppLog.instance.runWithErrorScope(() {
      AppLog.instance.trace(
        "lib/services/usage_ledger.dart::UsageLedger.observe.closure#1",
      );
      return _watchChanges.synchronized(() async {
        AppLog.instance.trace(
          "lib/services/usage_ledger.dart::UsageLedger.observe.closure#1.closure#1",
        );

        final watch = observedWatch;
        if (watch == null || !identical(watch, _watch)) return;
        await _lock(watch.identity).synchronized(() async {
          AppLog.instance.trace(
            "lib/services/usage_ledger.dart::UsageLedger.observe.closure#1.closure#1.closure#1",
          );

          try {
            await _sample(watch.identity);
            await _guard(watch.identity);
            if (!playing ||
                _monotonic() - watch.settledAt >=
                    const Duration(seconds: 120)) {
              // A later device event may already have updated the actual state.
              await _settleLocked(watch.identity, pause: false);
            }
          } catch (error, stack) {
            _recordFailure(error, stack, watch.identity);
            _suspend(watch);
            rethrow;
          }
        });
      });
    });
  }

  void _captureElapsed(_Listening watch) {
    AppLog.instance.trace(
      "lib/services/usage_ledger.dart::UsageLedger._captureElapsed",
    );

    final now = _monotonic();
    final elapsed = now > watch.sampledAt
        ? (now - watch.sampledAt).inMicroseconds / 1000000
        : 0.0;
    watch.unsaved += watch.playing ? elapsed * watch.speed * reportFactor : 0;
    watch.sampledAt = now;
  }

  void _suspend(_Listening watch) {
    AppLog.instance.trace(
      "lib/services/usage_ledger.dart::UsageLedger._suspend",
    );

    _captureElapsed(watch);
    watch.playing = false;
    watch.suspended = true;
  }

  Future<void> _sample(String identity) {
    AppLog.instance.trace(
      "lib/services/usage_ledger.dart::UsageLedger._sample",
    );
    return AppLog.instance.runWithErrorScope(() async {
      AppLog.instance.trace(
        "lib/services/usage_ledger.dart::UsageLedger._sample.closure#1",
      );

      final watch = _watch;
      if (watch == null || watch.identity != identity) return;
      _captureElapsed(watch);
      if (watch.unsaved == 0) return;
      final amount = watch.unsaved;
      try {
        final total = debt(identity) + amount;
        await _write(identity, (ledger) {
          AppLog.instance.trace(
            "lib/services/usage_ledger.dart::UsageLedger._sample.closure#1.closure#1",
          );
          ledger['usage_seconds'] = total;
        });
        watch.unsaved -= amount;
      } catch (error, stack) {
        _recordFailure(error, stack, identity);
        _suspend(watch);
        rethrow;
      }
    });
  }

  /// Restore pauses producers first; preserve unknown journals without sending.
  Future<void> captureForRestore() {
    AppLog.instance.trace(
      "lib/services/usage_ledger.dart::UsageLedger.captureForRestore",
    );
    return _watchChanges.synchronized(() async {
      AppLog.instance.trace(
        "lib/services/usage_ledger.dart::UsageLedger.captureForRestore.closure#1",
      );

      final watch = _watch;
      if (watch == null) return;
      await _lock(watch.identity).synchronized(() async {
        AppLog.instance.trace(
          "lib/services/usage_ledger.dart::UsageLedger.captureForRestore.closure#1.closure#1",
        );

        // Keep the watch and unsaved sample reachable if persistence fails.
        await _sample(watch.identity);
        watch.playing = false;
        _watch = null;
      });
    });
  }

  /// Previewing or prepaying a download does not pause actual playback. Keep
  /// sampling the watch across network waits, as periodic settlement does.
  Future<void> settleForDownload(String identity) {
    AppLog.instance.trace(
      "lib/services/usage_ledger.dart::UsageLedger.settleForDownload",
    );
    return _lock(identity).synchronized(() {
      AppLog.instance.trace(
        "lib/services/usage_ledger.dart::UsageLedger.settleForDownload.closure#1",
      );
      return _settleLocked(identity, pause: false);
    });
  }

  /// Callers pause the player before this account-switch/exit boundary.
  Future<void> settle([String? identity]) async {
    AppLog.instance.trace("lib/services/usage_ledger.dart::UsageLedger.settle");

    if (identity != null) {
      await _lock(identity).synchronized(() {
        AppLog.instance.trace(
          "lib/services/usage_ledger.dart::UsageLedger.settle.closure#1",
        );
        return _settleLocked(identity);
      });
      return;
    }
    await _settleAccounts();
  }

  /// Exit refreshes unknown reports without replaying them.
  Future<void> settleForExit() {
    AppLog.instance.trace(
      "lib/services/usage_ledger.dart::UsageLedger.settleForExit",
    );
    return _settleAccounts();
  }

  Future<void> _settleAccounts() {
    AppLog.instance.trace(
      "lib/services/usage_ledger.dart::UsageLedger._settleAccounts",
    );
    return AppLog.instance.runWithErrorScope(() async {
      AppLog.instance.trace(
        "lib/services/usage_ledger.dart::UsageLedger._settleAccounts.closure#1",
      );

      final identities = (storage.state['accounts'] as Map).keys
          .cast<String>()
          .toList();
      for (final id in identities) {
        await _lock(id).synchronized(() async {
          AppLog.instance.trace(
            "lib/services/usage_ledger.dart::UsageLedger._settleAccounts.closure#1.closure#1",
          );

          try {
            await _settleLocked(id);
          } on XmlyException catch (error, stack) {
            _recordFailure(error, stack, id);
            rethrow;
          }
        });
      }
    });
  }

  Future<void> _settleLocked(String identity, {bool pause = true}) async {
    AppLog.instance.trace(
      "lib/services/usage_ledger.dart::UsageLedger._settleLocked",
    );

    await _recover(identity);
    await _sample(identity);
    final watch = _watch;
    if (pause && watch?.identity == identity) watch!.playing = false;
    if (!isBlocked(identity) &&
        debt(identity) < 1 &&
        watch?.identity != identity)
      return;
    await _guard(identity);
    var seconds = debt(identity).floor();
    while (seconds > 0) {
      final amount = seconds > maxSeconds ? maxSeconds : seconds;
      await clientFor(identity).withBalanceChange(() async {
        AppLog.instance.trace(
          "lib/services/usage_ledger.dart::UsageLedger._settleLocked.closure#1",
        );

        final quota = await clientFor(identity).queryQuota();
        final newDevice = quota.newDevice && quota.remainingSeconds == 0;
        if (!newDevice && quota.remainingSeconds < amount) throw _insufficient;
        final operation = <String, dynamic>{
          'operationId': const Uuid().v4(),
          'accountIdentity': identity,
          'trackId': watch?.identity == identity ? watch!.trackId : '',
          'seconds': amount,
          'balanceBefore': quota.remainingSeconds,
          'balanceAfter': null,
          'createdAt': _clock().millisecondsSinceEpoch,
          'state': 'submitting',
        };
        await _submit(identity, operation, online: true);
      });
      seconds = debt(identity).floor();
    }
    if (watch?.identity == identity) watch!.settledAt = _monotonic();
  }

  Future<void> stopWatch() {
    AppLog.instance.trace(
      "lib/services/usage_ledger.dart::UsageLedger.stopWatch",
    );
    return _watchChanges.synchronized(_stopWatch);
  }

  Future<void> _stopWatch() async {
    AppLog.instance.trace(
      "lib/services/usage_ledger.dart::UsageLedger._stopWatch",
    );

    final watch = _watch;
    if (watch == null) return;
    await _lock(watch.identity).synchronized(() {
      AppLog.instance.trace(
        "lib/services/usage_ledger.dart::UsageLedger._stopWatch.closure#1",
      );
      return _settleLocked(watch.identity);
    });
    _watch = null;
  }

  Future<void> _submit(
    String identity,
    Map<String, dynamic> operation, {
    required bool online,
  }) {
    AppLog.instance.trace(
      "lib/services/usage_ledger.dart::UsageLedger._submit",
    );
    return AppLog.instance.runWithErrorScope(() async {
      AppLog.instance.trace(
        "lib/services/usage_ledger.dart::UsageLedger._submit.closure#1",
      );

      // A failed journal commit returns before even constructing a report request.
      await _write(identity, (ledger) {
        AppLog.instance.trace(
          "lib/services/usage_ledger.dart::UsageLedger._submit.closure#1.closure#1",
        );

        if (online) {
          ledger['usage_pending'] = operation;
          ledger['usage_uncertain'] = true;
        } else {
          (ledger.putIfAbsent('receipts', () {
            AppLog.instance.trace(
              "lib/services/usage_ledger.dart::UsageLedger._submit.closure#1.closure#1.closure#1",
            );
            return <dynamic>[];
          }) as List).add(operation);
        }
      });
      final balanceBefore = operation['balanceBefore'] as int;
      // 一天限免时余额超过 20 小时，扣时接口不可用。
      final freeDay = balanceBefore > const Duration(hours: 20).inSeconds;
      final int balanceAfter;
      try {
        balanceAfter = freeDay
            ? balanceBefore
            : (await clientFor(identity)
                      .debitSeconds(operation['seconds'] as int))
                  .remainingSeconds;
      } catch (error, stack) {
        _recordFailure(error, stack, identity);
        if (error is XmlyException && error.definitive) {
          try {
            await _finish(
              identity,
              operation,
              online: online,
              state: DebitState.rejected,
            );
          } catch (finishError, finishStack) {
            _recordFailure(finishError, finishStack, identity);
            await _markUncertain(identity, operation, online: online);
            AppLog.instance.linkError(_uncertain, finishError);
            throw _uncertain;
          }
          rethrow;
        }
        try {
          await _refreshPending(identity);
          return;
        } catch (refreshError, refreshStack) {
          _recordFailure(refreshError, refreshStack, identity);
          await _markUncertain(identity, operation, online: online);
          rethrow;
        }
      }
      operation['balanceAfter'] = balanceAfter;
      try {
        await _finish(
          identity,
          operation,
          online: online,
          state: DebitState.confirmed,
        );
      } catch (error, stack) {
        _recordFailure(error, stack, identity);
        // Durable submitting remains authoritative even when disk stays unavailable.
        await _markUncertain(identity, operation, online: online);
        AppLog.instance.linkError(_uncertain, error);
        throw _uncertain;
      }
    });
  }

  Future<void> _finish(
    String identity,
    Map<String, dynamic> operation, {
    required bool online,
    required DebitState state,
  }) {
    AppLog.instance.trace(
      "lib/services/usage_ledger.dart::UsageLedger._finish",
    );
    return _write(identity, (ledger) {
      AppLog.instance.trace(
        "lib/services/usage_ledger.dart::UsageLedger._finish.closure#1",
      );

      if (online) {
        if (state == DebitState.confirmed) {
          final current = ledger['usage_seconds'] as num;
          ledger['usage_seconds'] = (current - (operation['seconds'] as int))
              .clamp(0, double.infinity);
        }
        ledger.remove('usage_pending');
        ledger['usage_uncertain'] = false;
      } else {
        final entries = ledger['receipts'] as List;
        final index = entries.indexWhere((item) {
          AppLog.instance.trace(
            "lib/services/usage_ledger.dart::UsageLedger._finish.closure#1.closure#1",
          );
          return (item as Map)['operationId'] == operation['operationId'];
        });
        if (index < 0)
          throw const XmlyException('invalid_ledger', '扣时记录丢失，请保留资料');
        entries[index] = {...operation, 'state': state.name};
      }
    });
  }

  Future<void> _markUncertain(
    String identity,
    Map<String, dynamic> operation, {
    required bool online,
  }) {
    AppLog.instance.trace(
      "lib/services/usage_ledger.dart::UsageLedger._markUncertain",
    );
    return AppLog.instance.runWithErrorScope(() async {
      AppLog.instance.trace(
        "lib/services/usage_ledger.dart::UsageLedger._markUncertain.closure#1",
      );

      if (_watch?.identity == identity) _suspend(_watch!);
      try {
        await _write(identity, (ledger) {
          AppLog.instance.trace(
            "lib/services/usage_ledger.dart::UsageLedger._markUncertain.closure#1.closure#1",
          );

          final pending = {...operation, 'state': 'uncertain'};
          if (online) {
            ledger['usage_pending'] = pending;
            ledger['usage_uncertain'] = true;
          } else {
            final entries = ledger['receipts'] as List;
            final index = entries.indexWhere((item) {
              AppLog.instance.trace(
                "lib/services/usage_ledger.dart::UsageLedger._markUncertain.closure#1.closure#1.closure#1",
              );
              return (item as Map)['operationId'] == operation['operationId'];
            });
            if (index >= 0) entries[index] = pending;
          }
        });
      } catch (error, stack) {
        _recordFailure(error, stack, identity);
        AppLog.instance.linkError(_uncertain, error);
        // The pre-POST submitting journal is already durable and blocks replay.
      }
    });
  }

  /// Adopt the server balance, not a locally inferred per-report outcome.
  Future<void> _refreshPending(String identity) async {
    AppLog.instance.trace(
      "lib/services/usage_ledger.dart::UsageLedger._refreshPending",
    );

    final pending = _ledger(identity)['usage_pending'];
    if (pending is Map &&
        (pending['accountIdentity'] != identity ||
            pending['operationId'] is! String ||
            (pending['operationId'] as String).isEmpty ||
            !['uncertain', 'submitting'].contains(pending['state']) ||
            pending['seconds'] is! int ||
            (pending['seconds'] as int) < 1 ||
            (pending['seconds'] as int) > maxSeconds ||
            (pending['seconds'] as int) > debt(identity))) {
      throw const XmlyException('invalid_ledger', '待核对扣时记录无效，请保留资料');
    }
    final entries = receipts(identity);
    final client = clientFor(identity);
    if (client.identity != identity) {
      throw const XmlyException('account_mismatch', '请求账号已改变，请重新操作');
    }
    final quota = await client.queryQuota();
    if (!identical(client, clientFor(identity)) ||
        client.identity != identity) {
      throw const XmlyException('account_mismatch', '请求账号已改变，请重新操作');
    }
    if (pending is Map) {
      await _finish(
        identity,
        {
          ...Map<String, dynamic>.from(pending),
          'balanceAfter': quota.remainingSeconds,
        },
        online: true,
        state: DebitState.confirmed,
      );
    }
    for (final receipt in entries) {
      if (receipt.state != DebitState.submitting &&
          receipt.state != DebitState.uncertain)
        continue;
      await _finish(
        identity,
        {...receipt.toJson(), 'balanceAfter': quota.remainingSeconds},
        online: false,
        state: DebitState.confirmed,
      );
    }
    if (pending == null && _ledger(identity)['usage_uncertain'] == true) {
      await _write(identity, (ledger) {
        AppLog.instance.trace(
          "lib/services/usage_ledger.dart::UsageLedger._refreshPending.closure#1",
        );
        ledger['usage_uncertain'] = false;
      });
    }
  }
}

class _Listening {
  _Listening(this.identity, this.trackId, this.speed, this.sampledAt)
    : settledAt = sampledAt {
    AppLog.instance.trace("lib/services/usage_ledger.dart::_Listening.new");
  }
  final String identity, trackId;
  double speed;
  Duration sampledAt, settledAt;
  bool playing = false;
  bool suspended = false;
  double unsaved = 0;
}
