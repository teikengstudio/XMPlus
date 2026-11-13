import 'dart:async';

import 'package:uuid/uuid.dart';

import '../models/xmly_models.dart';
import '../storage/app_storage.dart';
import 'app_log.dart';
import 'download_service.dart' show DownloadStopped;

/// Only explicit, local consent authorizes future downloads. The catalogue at
/// consent time is a complete baseline, never an instruction to backfill.
class AutoDownloadService {
  AutoDownloadService({
    required this.storage,
    required this.checkAccount,
    required this.loadCatalogue,
    required this.hasTask,
    required this.enqueueNew,
  }) {
    AppLog.instance.trace(
      "lib/services/auto_download_service.dart::AutoDownloadService.new",
    );
  }

  final AppStorage storage;
  final void Function(String identity) checkAccount;
  final Future<List<Track>> Function(
    String identity,
    String albumId,
    Future<void> cancelled,
    Future<void> Function() checkpoint,
  )
  loadCatalogue;
  final bool Function(String identity, String trackId) hasTask;
  final Future<void> Function(
    String identity,
    Track track,
    bool Function() allowed,
    Future<void> cancelled,
  )
  enqueueNew;
  final _changes = StreamController<void>.broadcast();
  final _flights = <String, Future<void>>{};
  final _revisions = <String, int>{};
  final _errors = <String, String>{};
  final _pendingStops = <String, Set<Completer<void>>>{};

  Completer<void> _startRead(String key) {
    AppLog.instance.trace(
      "lib/services/auto_download_service.dart::AutoDownloadService._startRead",
    );

    final stop = Completer<void>();
    _pendingStops
        .putIfAbsent(key, () {
          AppLog.instance.trace(
            "lib/services/auto_download_service.dart::AutoDownloadService._startRead.closure#1",
          );
          return {};
        })
        .add(stop);
    return stop;
  }

  void _stopReads([String? key]) {
    AppLog.instance.trace(
      "lib/services/auto_download_service.dart::AutoDownloadService._stopReads",
    );

    final keys = key == null ? _pendingStops.keys.toList() : [key];
    for (final item in keys) {
      for (final stop in _pendingStops.remove(item) ?? <Completer<void>>{}) {
        if (!stop.isCompleted) stop.complete();
      }
    }
  }

  void _finishRead(String key, Completer<void> stop) {
    AppLog.instance.trace(
      "lib/services/auto_download_service.dart::AutoDownloadService._finishRead",
    );

    _pendingStops[key]?.remove(stop);
    if (_pendingStops[key]?.isEmpty == true) _pendingStops.remove(key);
  }

  int _generation = 0;
  bool _suspended = false, _closed = false;

  Stream<void> get changes {
    AppLog.instance.trace(
      "lib/services/auto_download_service.dart::AutoDownloadService.changes.get",
    );
    return _changes.stream;
  }

  List<String> get errors {
    AppLog.instance.trace(
      "lib/services/auto_download_service.dart::AutoDownloadService.errors.get",
    );
    return List.unmodifiable(_errors.values);
  }

  String _key(String identity, String albumId) {
    AppLog.instance.trace(
      "lib/services/auto_download_service.dart::AutoDownloadService._key",
    );
    return '$identity/$albumId';
  }

  Map? _record(String identity, String albumId) {
    AppLog.instance.trace(
      "lib/services/auto_download_service.dart::AutoDownloadService._record",
    );

    final all = (storage.state['settings'] as Map)['autoDownloads'];
    final albums = all is Map ? all[identity] : null;
    final record = albums is Map ? albums[albumId] : null;
    return record is Map ? record : null;
  }

  bool enabled(String identity, String albumId) {
    AppLog.instance.trace(
      "lib/services/auto_download_service.dart::AutoDownloadService.enabled",
    );
    return _record(identity, albumId)?['enabled'] == true;
  }

  String? errorFor(String identity, String albumId) {
    AppLog.instance.trace(
      "lib/services/auto_download_service.dart::AutoDownloadService.errorFor",
    );
    return _errors[_key(identity, albumId)];
  }

  Future<void> setEnabled(
    String identity,
    String albumId, {
    required bool confirmed,
  }) {
    AppLog.instance.trace(
      "lib/services/auto_download_service.dart::AutoDownloadService.setEnabled",
    );
    return AppLog.instance.runWithErrorScope(() async {
      AppLog.instance.trace(
        "lib/services/auto_download_service.dart::AutoDownloadService.setEnabled.closure#1",
      );

      if (_closed) return;
      final key = _key(identity, albumId);
      _stopReads(key);
      final revision = (_revisions[key] ?? 0) + 1;
      _revisions[key] =
          revision; // Cancel in-flight work before the first await.
      final generation = _generation;
      bool current() {
        AppLog.instance.trace(
          "lib/services/auto_download_service.dart::AutoDownloadService.setEnabled.closure#1.current",
        );
        return !_closed &&
            !_suspended &&
            _generation == generation &&
            _revisions[key] == revision;
      }

      if (!confirmed) {
        try {
          await storage.transaction((state) {
            AppLog.instance.trace(
              "lib/services/auto_download_service.dart::AutoDownloadService.setEnabled.closure#1.closure#1",
            );

            final all = (state['settings'] as Map)['autoDownloads'];
            final albums = all is Map ? all[identity] : null;
            final record = albums is Map ? albums[albumId] : null;
            if (record is Map) record['enabled'] = false;
          });
        } catch (error, stack) {
          _recordFailure('Disabling automatic download failed', error, stack);
          rethrow;
        }
        _errors.remove(key);
        _notify();
        return;
      }
      final stop = _startRead(key);
      Future<void> checkpoint() async {
        AppLog.instance.trace(
          "lib/services/auto_download_service.dart::AutoDownloadService.setEnabled.closure#1.checkpoint",
        );

        if (!current()) throw const _StaleConsent();
        checkAccount(identity);
      }

      try {
        if (!current()) return;
        checkAccount(identity);
        final tracks = _catalogue(
          await loadCatalogue(identity, albumId, stop.future, checkpoint),
          albumId,
        );
        if (!current()) return;
        checkAccount(identity);
        await storage.transaction((state) {
          AppLog.instance.trace(
            "lib/services/auto_download_service.dart::AutoDownloadService.setEnabled.closure#1.closure#2",
          );

          if (!current()) throw const _StaleConsent();
          checkAccount(identity);
          final all = (state['settings'] as Map).putIfAbsent(
            'autoDownloads',
            () {
              AppLog.instance.trace(
                "lib/services/auto_download_service.dart::AutoDownloadService.setEnabled.closure#1.closure#2.closure#1",
              );
              return <String, dynamic>{};
            },
          ) as Map;
          final albums = all.putIfAbsent(identity, () {
            AppLog.instance.trace(
              "lib/services/auto_download_service.dart::AutoDownloadService.setEnabled.closure#1.closure#2.closure#2",
            );
            return <String, dynamic>{};
          }) as Map;
          albums[albumId] = {
            'enabled': true,
            'consentId': const Uuid().v4(),
            'seen': tracks.map((track) {
              AppLog.instance.trace(
                "lib/services/auto_download_service.dart::AutoDownloadService.setEnabled.closure#1.closure#2.closure#3",
              );
              return track.id;
            }).toList(),
            'pending': <dynamic>[],
          };
        });
        _errors.remove(key);
      } on _StaleConsent {
        // Closing, disabling and restore invalidate requests without side effects.
      } catch (error, stack) {
        if (!current()) return;
        _recordFailure('Enabling automatic download failed', error, stack);
        _errors[key] = _message(error);
        rethrow;
      } finally {
        _finishRead(key, stop);
        _notify();
      }
    });
  }

  Future<void> scanAll() async {
    AppLog.instance.trace(
      "lib/services/auto_download_service.dart::AutoDownloadService.scanAll",
    );

    final generation = _generation;
    final all = (storage.state['settings'] as Map)['autoDownloads'];
    if (all is! Map) return;
    for (final entry in all.entries) {
      if (entry.key is! String || entry.value is! Map) continue;
      for (final album in (entry.value as Map).keys) {
        if (_closed || _suspended || generation != _generation) return;
        if (album is String) await scanAlbum(entry.key as String, album);
      }
    }
  }

  Future<void> scanAlbum(String identity, String albumId) {
    AppLog.instance.trace(
      "lib/services/auto_download_service.dart::AutoDownloadService.scanAlbum",
    );

    if (_closed || _suspended || !enabled(identity, albumId))
      return Future.value();
    final key = _key(identity, albumId);
    final existing = _flights[key];
    if (existing != null) return existing;
    final future = _scan(identity, albumId).whenComplete(() {
      AppLog.instance.trace(
        "lib/services/auto_download_service.dart::AutoDownloadService.scanAlbum.closure#1",
      );

      _flights.remove(key);
    });
    _flights[key] = future;
    return future;
  }

  Future<void> _scan(String identity, String albumId) {
    AppLog.instance.trace(
      "lib/services/auto_download_service.dart::AutoDownloadService._scan",
    );
    return AppLog.instance.runWithErrorScope(() async {
      AppLog.instance.trace(
        "lib/services/auto_download_service.dart::AutoDownloadService._scan.closure#1",
      );

      final key = _key(identity, albumId);
      final stop = _startRead(key);
      final generation = _generation, revision = _revisions[key];
      final consent = _record(identity, albumId)?['consentId'];
      bool allowed() {
        AppLog.instance.trace(
          "lib/services/auto_download_service.dart::AutoDownloadService._scan.closure#1.allowed",
        );
        return !_closed &&
            !_suspended &&
            _generation == generation &&
            _revisions[key] == revision &&
            consent is String &&
            _record(identity, albumId)?['consentId'] == consent &&
            enabled(identity, albumId);
      }

      Future<void> checkpoint() async {
        AppLog.instance.trace(
          "lib/services/auto_download_service.dart::AutoDownloadService._scan.closure#1.checkpoint",
        );

        if (!allowed()) throw const _StaleConsent();
        checkAccount(identity);
      }

      Future<void> update(void Function(Map record) change) {
        AppLog.instance.trace(
          "lib/services/auto_download_service.dart::AutoDownloadService._scan.closure#1.update",
        );
        return storage.transaction((state) {
          AppLog.instance.trace(
            "lib/services/auto_download_service.dart::AutoDownloadService._scan.closure#1.update.closure#1",
          );

          if (!allowed()) throw const _StaleConsent();
          checkAccount(identity);
          final record =
              ((state['settings'] as Map)['autoDownloads']
                      as Map)[identity][albumId]
                  as Map;
          change(record);
        });
      }

      try {
        if (consent is! String || consent.isEmpty) {
          throw const XmlyException('auto_invalid', '自动下载资料无效，请关闭后重新开启');
        }
        await checkpoint();
        final tracks = _catalogue(
          await loadCatalogue(identity, albumId, stop.future, checkpoint),
          albumId,
        );
        await checkpoint();
        final record = _record(identity, albumId)!;
        final seen = _ids(record['seen']);
        final pending = _pending(record['pending'], albumId);
        for (final track in tracks) {
          if (!seen.contains(track.id)) pending[track.id] = track;
        }
        // Durably remember additions BEFORE preparing permission/quota or tasks.
        await update((value) {
          AppLog.instance.trace(
            "lib/services/auto_download_service.dart::AutoDownloadService._scan.closure#1.closure#1",
          );

          value['pending'] = pending.values.map((track) {
            AppLog.instance.trace(
              "lib/services/auto_download_service.dart::AutoDownloadService._scan.closure#1.closure#1.closure#1",
            );
            return track.toJson();
          }).toList();
        });
        for (final track in pending.values) {
          await checkpoint();
          // Every existing state wins, including cancelled/failed/restored tasks.
          if (!hasTask(identity, track.id)) {
            await enqueueNew(identity, track, allowed, stop.future);
            await checkpoint();
            if (!hasTask(identity, track.id)) {
              throw const XmlyException('auto_not_enqueued', '新声音未加入下载列表');
            }
          }
          await update((value) {
            AppLog.instance.trace(
              "lib/services/auto_download_service.dart::AutoDownloadService._scan.closure#1.closure#2",
            );

            final ids = _ids(value['seen'])..add(track.id);
            value['seen'] = ids.toList();
            value['pending'] = _pending(value['pending'], albumId).values
                .where((item) {
                  AppLog.instance.trace(
                    "lib/services/auto_download_service.dart::AutoDownloadService._scan.closure#1.closure#2.closure#1",
                  );
                  return item.id != track.id;
                })
                .map((item) {
                  AppLog.instance.trace(
                    "lib/services/auto_download_service.dart::AutoDownloadService._scan.closure#1.closure#2.closure#2",
                  );
                  return item.toJson();
                })
                .toList();
          });
        }
        _errors.remove(key);
      } on _StaleConsent {
        // Never advance a baseline or enqueue after consent has been invalidated.
      } catch (error, stack) {
        if (allowed()) {
          _recordFailure('Automatic download scan failed', error, stack);
          _errors[key] = _message(error);
        }
      } finally {
        _finishRead(key, stop);
        _notify();
      }
    });
  }

  static Set<String> _ids(Object? value) {
    AppLog.instance.trace(
      "lib/services/auto_download_service.dart::AutoDownloadService._ids",
    );

    if (value is! List ||
        value.any((id) {
          AppLog.instance.trace(
            "lib/services/auto_download_service.dart::AutoDownloadService._ids.closure#1",
          );
          return id is! String;
        })) {
      throw const XmlyException('auto_invalid', '自动下载资料无效，请关闭后重新开启');
    }
    return value.cast<String>().toSet();
  }

  static const _invalidCatalogue = XmlyException(
    'auto_catalogue',
    '专辑列表不完整，自动下载已停止',
  );

  static Map<String, Track> _pending(Object? value, String albumId) {
    AppLog.instance.trace(
      "lib/services/auto_download_service.dart::AutoDownloadService._pending",
    );

    if (value is! List)
      throw const XmlyException('auto_invalid', '自动下载资料无效，请关闭后重新开启');
    final pending = <String, Track>{};
    for (final item in value) {
      final track = Track.fromJson(Map<String, dynamic>.from(item as Map));
      if (track.albumId != albumId) throw _invalidCatalogue;
      pending[track.id] = track;
    }
    return pending;
  }

  static List<Track> _catalogue(List<Track> tracks, String albumId) {
    AppLog.instance.trace(
      "lib/services/auto_download_service.dart::AutoDownloadService._catalogue",
    );

    final ids = <String>{};
    if (tracks.length > 5000 ||
        tracks.any((track) {
          AppLog.instance.trace(
            "lib/services/auto_download_service.dart::AutoDownloadService._catalogue.closure#1",
          );
          return track.albumId != albumId || !ids.add(track.id);
        })) {
      throw _invalidCatalogue;
    }
    return tracks;
  }

  static String _message(Object error) {
    AppLog.instance.trace(
      "lib/services/auto_download_service.dart::AutoDownloadService._message",
    );
    return switch (error) {
      XmlyException(code: 'usage_uncertain') => '自动下载已停止：请先核对未确认的听时',
      XmlyException(code: 'insufficient_quota') => '自动下载已停止：听时不足',
      XmlyException(code: 'login_expired') => '自动下载已停止：请重新登录原账号',
      _ => '自动下载未完成，请检查原账号、听时和下载目录后重新检查专辑',
    };
  }

  void _recordFailure(String message, Object error, StackTrace stack) {
    AppLog.instance.trace(
      "lib/services/auto_download_service.dart::AutoDownloadService._recordFailure",
    );

    if (error is _StaleConsent || error is DownloadStopped) return;
    if (error is XmlyException &&
        const {
          'client_closed',
          'request_cancelled',
          'closed',
          'missing_account',
          'account_mismatch',
          'task_mismatch',
          'login_required',
          'login_expired',
          'auth_required',
          'confirmation_required',
          'confirmation_changed',
          'insufficient_quota',
          'usage_uncertain',
        }.contains(error.code))
      return;
    if (!AppLog.instance.errorWasRecorded(error)) {
      AppLog.instance.write(
        AppLogLevel.error,
        'auto_download',
        message,
        error: error,
        stackTrace: stack,
      );
    }
    AppLog.instance.requestUploadPrompt();
  }

  /// Cancel pending discovery/admission without removing saved subscriptions.
  void invalidatePending() {
    AppLog.instance.trace(
      "lib/services/auto_download_service.dart::AutoDownloadService.invalidatePending",
    );

    _generation++;
    _stopReads();
  }

  /// Synchronous invalidation avoids waiting on account locks during restore.
  void suspend() {
    AppLog.instance.trace(
      "lib/services/auto_download_service.dart::AutoDownloadService.suspend",
    );

    invalidatePending();
    _suspended = true;
  }

  void resume() {
    AppLog.instance.trace(
      "lib/services/auto_download_service.dart::AutoDownloadService.resume",
    );

    if (!_closed) _suspended = false;
  }

  void _notify() {
    AppLog.instance.trace(
      "lib/services/auto_download_service.dart::AutoDownloadService._notify",
    );

    if (!_changes.isClosed) _changes.add(null);
  }

  Future<void> close() async {
    AppLog.instance.trace(
      "lib/services/auto_download_service.dart::AutoDownloadService.close",
    );

    _closed = true;
    suspend();
    await Future.wait(_flights.values.toList());
    await _changes.close();
  }
}

class _StaleConsent implements Exception {
  const _StaleConsent();
}
