import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../api/xmly_experience.dart';
import '../api/xmly_client.dart';
import '../api/xmly_history.dart';
import '../common/widgets/adaptive_text.dart';
import '../common/widgets/app_tab_button.dart';
import '../common/widgets/confirmation_dialog.dart';
import '../models/xmly_models.dart';
import '../services/app_log.dart';
import '../services/app_runtime.dart';
import 'catalogue_page.dart';
import 'download_page.dart' show requestDownloads;
import 'anchor_following_page.dart';
import 'player_panel.dart';

void _recordListeningError(
  String operation,
  Object error,
  StackTrace stack, {
  bool recoverable = false,
}) {
  AppLog.instance.trace("lib/pages/listening_page.dart::_recordListeningError");

  final log = AppLog.instance;
  if (log.errorWasRecorded(error)) return;
  final expected =
      error is XmlyException &&
      const {
        'client_closed',
        'request_cancelled',
        'cancelled',
        'download_stopped',
        'stopped',
        'closed',
        'login_required',
        'login_expired',
        'auth_required',
        'account_changed',
        'account_mismatch',
        'missing_account',
        'confirmation_required',
        'confirmation_changed',
        'insufficient_quota',
        'usage_uncertain',
        'rate_limited',
        'queue_full',
        'catalogue_limit',
        'feed_limit',
        'subscription_limit',
        'favorite_limit',
        'stale_bookmark',
      }.contains(error.code);
  log.write(
    recoverable || expected ? AppLogLevel.warning : AppLogLevel.error,
    'listening_page',
    operation,
    error: error,
    stackTrace: stack,
    promptUser: !recoverable && !expected,
  );
}

class _BookmarkNoteDialog extends StatefulWidget {
  const _BookmarkNoteDialog({
    required this.title,
    required this.position,
    required this.note,
    required this.save,
  });
  final String title, note;
  final double position;
  final Future<void> Function(String) save;

  @override
  State<_BookmarkNoteDialog> createState() {
    AppLog.instance.trace(
      "lib/pages/listening_page.dart::_BookmarkNoteDialog.createState",
    );
    return _BookmarkNoteDialogState();
  }
}

class _BookmarkNoteDialogState extends State<_BookmarkNoteDialog> {
  late final _note = TextEditingController(text: widget.note);
  final _form = GlobalKey<FormState>();
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    AppLog.instance.trace(
      "lib/pages/listening_page.dart::_BookmarkNoteDialogState.dispose",
    );

    _note.dispose();
    super.dispose();
  }

  Future<void> _save() {
    AppLog.instance.trace(
      "lib/pages/listening_page.dart::_BookmarkNoteDialogState._save",
    );
    return AppLog.instance.runWithErrorScope(() async {
      AppLog.instance.trace(
        "lib/pages/listening_page.dart::_BookmarkNoteDialogState._save.closure#1",
      );

      if (_saving || !_form.currentState!.validate()) return;
      setState(() {
        AppLog.instance.trace(
          "lib/pages/listening_page.dart::_BookmarkNoteDialogState._save.closure#1.closure#1",
        );

        _saving = true;
        _error = null;
      });
      try {
        await widget.save(_note.text.trim());
        if (mounted) Navigator.pop(context);
      } catch (error, stack) {
        _recordListeningError('Bookmark save failed', error, stack);
        if (mounted) {
          setState(() {
            AppLog.instance.trace(
              "lib/pages/listening_page.dart::_BookmarkNoteDialogState._save.closure#1.closure#2",
            );

            _saving = false;
            _error = error is XmlyException ? error.message : '备注保存失败，请重试';
          });
        }
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    AppLog.instance.trace(
      "lib/pages/listening_page.dart::_BookmarkNoteDialogState.build",
    );
    return PopScope(
      canPop: !_saving,
      child: AlertDialog(
        title: const Text('书签备注'),
        scrollable: true,
        content: SizedBox(
          width: 440,
          child: Form(
            key: _form,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                Text('书签位置 ${playbackTime(widget.position)}'),
                const SizedBox(height: 12),
                TextFormField(
                  key: const ValueKey('bookmarkNote'),
                  controller: _note,
                  enabled: !_saving,
                  autofocus: true,
                  minLines: 2,
                  maxLines: 5,
                  maxLength: 1000,
                  decoration: const InputDecoration(
                    labelText: '备注（可选）',
                    hintText: '例如：重点概念、例题；清空可移除备注',
                  ),
                  validator: (text) {
                    AppLog.instance.trace(
                      "lib/pages/listening_page.dart::_BookmarkNoteDialogState.build.closure#1",
                    );
                    return (text ?? '').characters.length > 1000
                        ? '备注不能超过 1000 字'
                        : null;
                  },
                ),
                if (_error != null)
                  Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: _saving
                ? null
                : () {
                    AppLog.instance.trace(
                      "lib/pages/listening_page.dart::_BookmarkNoteDialogState.build.closure#2",
                    );
                    Navigator.pop(context);
                  },
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: _saving ? null : _save,
            child: Text(_saving ? '正在保存…' : '保存备注'),
          ),
        ],
      ),
    );
  }
}

class ListeningPage extends StatefulWidget {
  const ListeningPage({
    required this.runtime,
    required this.onDownload,
    required this.onPlayAlbum,
    super.key,
  });
  final AppRuntime runtime;
  final Future<void> Function(List<Track>) onDownload;
  final AlbumPlayback onPlayAlbum;

  @override
  State<ListeningPage> createState() {
    AppLog.instance.trace(
      "lib/pages/listening_page.dart::ListeningPage.createState",
    );
    return _ListeningPageState();
  }
}

class _ListeningPageState extends State<ListeningPage>
    with SingleTickerProviderStateMixin {
  final _search = TextEditingController();
  late final TabController _tabs;
  int _selectedTab = 0;
  Timer? _favoriteSearchTimer;
  bool _favoriteSearchPaused = false;
  final _busy = [false, false, false, false];
  final List<String?> _errors = [null, null, null, null];
  final _requests = [0, 0, 0, 0];
  late int _libraryRevision;
  late bool _accountAvailable;
  bool _acting = false;
  int _accountEpoch = 0;
  late String _accountKey;
  final _sources = <String, _ListeningAccount>{};
  final List<Completer<void>?> _cancelled = [null, null, null, null];

  List<T> _merge<T>(
    Iterable<T> items,
    String Function(T) id, {
    int Function(T)? timestamp,
  }) {
    AppLog.instance.trace(
      "lib/pages/listening_page.dart::_ListeningPageState._merge",
    );

    final found = <String, T>{};
    for (final item in items) {
      final previous = found[id(item)];
      if (previous == null ||
          (timestamp != null && timestamp(item) > timestamp(previous))) {
        found[id(item)] = item;
      }
    }
    final result = found.values.toList();
    if (timestamp != null)
      result.sort((a, b) {
        AppLog.instance.trace(
          "lib/pages/listening_page.dart::_ListeningPageState._merge.closure#1",
        );

        final order = timestamp(b).compareTo(timestamp(a));
        return order == 0 ? id(a).compareTo(id(b)) : order;
      });
    return result;
  }

  List<UpdateItem> get _updates {
    AppLog.instance.trace(
      "lib/pages/listening_page.dart::_ListeningPageState._updates.get",
    );

    return _merge(
      _sources.values.expand((source) {
        AppLog.instance.trace(
          "lib/pages/listening_page.dart::_ListeningPageState._updates.get.closure#1",
        );

        return source.updates;
      }),
      (item) {
        AppLog.instance.trace(
          "lib/pages/listening_page.dart::_ListeningPageState._updates.get.closure#2",
        );

        return item.track.id;
      },
      timestamp: (item) {
        AppLog.instance.trace(
          "lib/pages/listening_page.dart::_ListeningPageState._updates.get.closure#3",
        );

        return item.publishedAt;
      },
    );
  }

  List<SubscriptionItem> get _subscriptions {
    AppLog.instance.trace(
      "lib/pages/listening_page.dart::_ListeningPageState._subscriptions.get",
    );

    return _merge(
      _sources.values.expand((source) {
        AppLog.instance.trace(
          "lib/pages/listening_page.dart::_ListeningPageState._subscriptions.get.closure#1",
        );

        return source.subscriptions;
      }),
      (item) {
        AppLog.instance.trace(
          "lib/pages/listening_page.dart::_ListeningPageState._subscriptions.get.closure#2",
        );

        return item.album.id;
      },
      timestamp: (item) {
        AppLog.instance.trace(
          "lib/pages/listening_page.dart::_ListeningPageState._subscriptions.get.closure#3",
        );

        return item.updatedAt;
      },
    );
  }

  List<Track> get _favorites {
    AppLog.instance.trace(
      "lib/pages/listening_page.dart::_ListeningPageState._favorites.get",
    );

    return _merge(
      _sources.values.expand((source) {
        AppLog.instance.trace(
          "lib/pages/listening_page.dart::_ListeningPageState._favorites.get.closure#1",
        );

        return source.favorites;
      }),
      (item) {
        AppLog.instance.trace(
          "lib/pages/listening_page.dart::_ListeningPageState._favorites.get.closure#2",
        );

        return item.id;
      },
    );
  }

  List<Map<String, dynamic>> get _cloudHistory {
    AppLog.instance.trace(
      "lib/pages/listening_page.dart::_ListeningPageState._cloudHistory.get",
    );

    return [
      for (final source in _sources.values)
        for (final record in source.history)
          {...record, 'accountIdentity': source.identity},
    ];
  }

  bool get _moreUpdates {
    AppLog.instance.trace(
      "lib/pages/listening_page.dart::_ListeningPageState._moreUpdates.get",
    );

    return _sources.values.any((source) {
      AppLog.instance.trace(
        "lib/pages/listening_page.dart::_ListeningPageState._moreUpdates.get.closure#1",
      );

      return source.more[0];
    });
  }

  bool get _moreSubscriptions {
    AppLog.instance.trace(
      "lib/pages/listening_page.dart::_ListeningPageState._moreSubscriptions.get",
    );

    return _sources.values.any((source) {
      AppLog.instance.trace(
        "lib/pages/listening_page.dart::_ListeningPageState._moreSubscriptions.get.closure#1",
      );

      return source.more[1];
    });
  }

  bool get _moreFavorites {
    AppLog.instance.trace(
      "lib/pages/listening_page.dart::_ListeningPageState._moreFavorites.get",
    );

    return _sources.values.any((source) {
      AppLog.instance.trace(
        "lib/pages/listening_page.dart::_ListeningPageState._moreFavorites.get.closure#1",
      );

      return source.more[3];
    });
  }

  int get _favoritePage {
    AppLog.instance.trace(
      "lib/pages/listening_page.dart::_ListeningPageState._favoritePage.get",
    );

    return _sources.isEmpty ||
            _sources.values.any((source) {
              AppLog.instance.trace(
                "lib/pages/listening_page.dart::_ListeningPageState._favoritePage.get.closure#1",
              );

              return source.pages[3] == 0;
            })
        ? 0
        : 1;
  }

  void _syncSources() {
    AppLog.instance.trace(
      "lib/pages/listening_page.dart::_ListeningPageState._syncSources",
    );

    _sources.clear();
    final accounts = _runtime.accounts;
    final identities = accounts.accountIds.toList();
    identities.sort((a, b) {
      AppLog.instance.trace(
        "lib/pages/listening_page.dart::_ListeningPageState._syncSources.closure#1",
      );

      if (a == b) return 0;
      if (a == accounts.primaryAccountId) return -1;
      if (b == accounts.primaryAccountId) return 1;
      return a.compareTo(b);
    });
    for (final identity in identities) {
      _sources[identity] = _ListeningAccount(accounts.clientFor(identity));
    }
  }

  String _accountLabel(String identity) {
    AppLog.instance.trace(
      "lib/pages/listening_page.dart::_ListeningPageState._accountLabel",
    );

    if (identity == 'anonymous') return '本地';
    final record =
        (_runtime.storage.state['accounts'] as Map)[identity] as Map?;
    final uid = _sources[identity]?.client.credentials?.uid ?? record?['uid'];
    return uid == null ? '原账号' : '账号 $uid';
  }

  List<_ListeningAccount> _owners(int section, String id) {
    AppLog.instance.trace(
      "lib/pages/listening_page.dart::_ListeningPageState._owners",
    );

    return _sources.values.where((source) {
      AppLog.instance.trace(
        "lib/pages/listening_page.dart::_ListeningPageState._owners.closure#1",
      );

      return switch (section) {
        0 => source.updates.any((item) {
          AppLog.instance.trace(
            "lib/pages/listening_page.dart::_ListeningPageState._owners.closure#1.closure#1",
          );

          return item.track.id == id;
        }),
        1 => source.subscriptions.any((item) {
          AppLog.instance.trace(
            "lib/pages/listening_page.dart::_ListeningPageState._owners.closure#1.closure#2",
          );

          return item.album.id == id;
        }),
        3 => source.favorites.any((item) {
          AppLog.instance.trace(
            "lib/pages/listening_page.dart::_ListeningPageState._owners.closure#1.closure#3",
          );

          return item.id == id;
        }),
        _ => false,
      };
    }).toList();
  }

  String _ownerLabel(List<_ListeningAccount> owners) {
    AppLog.instance.trace(
      "lib/pages/listening_page.dart::_ListeningPageState._ownerLabel",
    );

    return _sources.length < 2
        ? ''
        : owners
              .map((source) {
                AppLog.instance.trace(
                  "lib/pages/listening_page.dart::_ListeningPageState._ownerLabel.closure#1",
                );

                return _accountLabel(source.identity);
              })
              .join(' · ');
  }

  AppRuntime get _runtime {
    AppLog.instance.trace(
      "lib/pages/listening_page.dart::_ListeningPageState._runtime.get",
    );
    return widget.runtime;
  }

  String get _currentKey {
    AppLog.instance.trace(
      "lib/pages/listening_page.dart::_ListeningPageState._currentKey.get",
    );
    final identities = _runtime.accounts.accountIds.toList()..sort();
    return identities
        .map((id) {
          AppLog.instance.trace(
            "lib/pages/listening_page.dart::_ListeningPageState._currentKey.get.closure#1",
          );

          return '$id:${_runtime.accounts.clientFor(id).cacheIdentity}';
        })
        .join('|');
  }

  bool get _signedIn {
    AppLog.instance.trace(
      "lib/pages/listening_page.dart::_ListeningPageState._signedIn.get",
    );
    return _runtime.accounts.accountIds.isNotEmpty;
  }

  String get _query {
    AppLog.instance.trace(
      "lib/pages/listening_page.dart::_ListeningPageState._query.get",
    );
    return _search.text.trim().toLowerCase();
  }

  @override
  void initState() {
    AppLog.instance.trace(
      "lib/pages/listening_page.dart::_ListeningPageState.initState",
    );

    super.initState();
    _tabs = TabController(length: 5, vsync: this)
      ..addListener(_searchTabChanged);
    _syncSources();
    _accountKey = _currentKey;
    _libraryRevision = _runtime.libraryRevision;
    _accountAvailable = _signedIn;
    _runtime.addListener(_runtimeChanged);
    _refresh();
  }

  @override
  void didUpdateWidget(covariant ListeningPage oldWidget) {
    AppLog.instance.trace(
      "lib/pages/listening_page.dart::_ListeningPageState.didUpdateWidget",
    );

    super.didUpdateWidget(oldWidget);
    if (oldWidget.runtime != widget.runtime) {
      oldWidget.runtime.removeListener(_runtimeChanged);
      _runtime.addListener(_runtimeChanged);
      _resetAccount();
    }
  }

  void _runtimeChanged() {
    AppLog.instance.trace(
      "lib/pages/listening_page.dart::_ListeningPageState._runtimeChanged",
    );

    if (_accountKey != _currentKey || _accountAvailable != _signedIn) {
      _resetAccount();
    } else if (mounted) {
      if (_libraryRevision != _runtime.libraryRevision) {
        _libraryRevision = _runtime.libraryRevision;
        _refreshLibrary();
      }
      setState(() {
        AppLog.instance.trace(
          "lib/pages/listening_page.dart::_ListeningPageState._runtimeChanged.closure#1",
        );
      });
    }
  }

  void _resetAccount() {
    AppLog.instance.trace(
      "lib/pages/listening_page.dart::_ListeningPageState._resetAccount",
    );

    _favoriteSearchTimer?.cancel();
    _favoriteSearchPaused = false;
    _syncSources();
    _accountKey = _currentKey;
    _libraryRevision = _runtime.libraryRevision;
    _accountAvailable = _signedIn;
    ++_accountEpoch;
    setState(() {
      AppLog.instance.trace(
        "lib/pages/listening_page.dart::_ListeningPageState._resetAccount.closure#1",
      );

      for (var i = 0; i < _busy.length; i++) {
        _busy[i] = false;
        _errors[i] = null;
        ++_requests[i];
        _cancelled[i]?.complete();
        _cancelled[i] = null;
      }
    });
    _refresh();
  }

  void _refreshLibrary() {
    AppLog.instance.trace(
      "lib/pages/listening_page.dart::_ListeningPageState._refreshLibrary",
    );

    if (!_signedIn) return;
    unawaited(_loadUpdates(reset: true));
    unawaited(_loadSubscriptions(reset: true));
    unawaited(_loadFavorites(reset: true));
  }

  void _refresh() {
    AppLog.instance.trace(
      "lib/pages/listening_page.dart::_ListeningPageState._refresh",
    );

    _refreshLibrary();
    unawaited(_loadHistory());
  }

  bool _valid(int section, int request, int epoch, String key) {
    AppLog.instance.trace(
      "lib/pages/listening_page.dart::_ListeningPageState._valid",
    );
    return mounted &&
        _signedIn &&
        epoch == _accountEpoch &&
        request == _requests[section] &&
        key == _currentKey;
  }

  Future<void> _loadUpdates({bool reset = false}) {
    AppLog.instance.trace(
      "lib/pages/listening_page.dart::_ListeningPageState._loadUpdates",
    );

    return _loadSection(0, reset: reset);
  }

  Future<void> _loadSubscriptions({bool reset = false}) {
    AppLog.instance.trace(
      "lib/pages/listening_page.dart::_ListeningPageState._loadSubscriptions",
    );

    return _loadSection(1, reset: reset);
  }

  Future<void> _loadHistory() {
    AppLog.instance.trace(
      "lib/pages/listening_page.dart::_ListeningPageState._loadHistory",
    );

    return _loadSection(2, reset: true);
  }

  Future<void> _loadFavorites({bool reset = false}) {
    AppLog.instance.trace(
      "lib/pages/listening_page.dart::_ListeningPageState._loadFavorites",
    );

    return _loadSection(3, reset: reset);
  }

  Future<void> _loadSection(int section, {required bool reset}) async {
    AppLog.instance.trace(
      "lib/pages/listening_page.dart::_ListeningPageState._loadSection",
    );

    if (!_signedIn || (!reset && _busy[section])) return;
    final epoch = _accountEpoch,
        request = ++_requests[section],
        key = _currentKey;
    _cancelled[section]?.complete();
    final cancelled = _cancelled[section] = Completer<void>();
    final sources = _sources.values.where((source) {
      AppLog.instance.trace(
        "lib/pages/listening_page.dart::_ListeningPageState._loadSection.closure#1",
      );

      return reset || source.more[section];
    }).toList();
    setState(() {
      AppLog.instance.trace(
        "lib/pages/listening_page.dart::_ListeningPageState._loadSection.closure#2",
      );

      _busy[section] = true;
      _errors[section] = null;
      for (final source in sources) {
        source.errors[section] = null;
      }
    });
    bool current() {
      AppLog.instance.trace(
        "lib/pages/listening_page.dart::_ListeningPageState._loadSection.current",
      );

      return _valid(section, request, epoch, key);
    }

    Future<void> load(_ListeningAccount source) async {
      AppLog.instance.trace(
        "lib/pages/listening_page.dart::_ListeningPageState._loadSection.load",
      );

      if (!current()) return;
      try {
        await source.client.withReadPolicy(
          () async {
            AppLog.instance.trace(
              "lib/pages/listening_page.dart::_ListeningPageState._loadSection.load.closure#1",
            );

            switch (section) {
              case 0:
                final before = reset ? null : source.before;
                final result = await XmlyExperience(source.client)
                    .updates(before: before, pageSize: 50);
                if (!current()) return;
                final known = {
                  if (!reset)
                    for (final item in source.updates) item.track.id,
                };
                final added = result.items.where((item) {
                  AppLog.instance.trace(
                    "lib/pages/listening_page.dart::_ListeningPageState._loadSection.load.closure#1.closure#1",
                  );

                  return known.add(item.track.id);
                }).toList();
                if (result.hasMore &&
                    ((!reset && added.isEmpty) ||
                        result.nextTimeline == null ||
                        result.nextTimeline == before)) {
                  throw const XmlyException('repeated_page', '更多更新暂不可用，请刷新重试');
                }
                if ((reset ? 0 : source.updates.length) + added.length > 5000) {
                  throw const XmlyException('feed_limit', '已加载 5000 条更新');
                }
                source.updates = [if (!reset) ...source.updates, ...added];
                source.before = result.nextTimeline;
                source.more[0] = result.hasMore;
              case 1:
                final page = reset ? 1 : source.pages[1] + 1;
                final result = await XmlyExperience(source.client)
                    .subscriptions(page: page);
                if (!current()) return;
                final known = {
                  if (!reset)
                    for (final item in source.subscriptions) item.album.id,
                };
                final added = result.items.where((item) {
                  AppLog.instance.trace(
                    "lib/pages/listening_page.dart::_ListeningPageState._loadSection.load.closure#1.closure#2",
                  );

                  return known.add(item.album.id);
                }).toList();
                if (!reset && result.hasMore && added.isEmpty) {
                  throw const XmlyException('repeated_page', '更多订阅暂不可用，请刷新重试');
                }
                if ((reset ? 0 : source.subscriptions.length) + added.length >
                    5000) {
                  throw const XmlyException(
                    'subscription_limit',
                    '已加载 5000 个订阅',
                  );
                }
                source.subscriptions = [
                  if (!reset) ...source.subscriptions,
                  ...added,
                ];
                source.pages[1] = page;
                source.more[1] = result.hasMore;
              case 2:
                final result = await XmlyHistory(source.client).records();
                if (!current()) return;
                source.history = result;
                source.more[2] = false;
              case 3:
                final page = reset ? 1 : source.pages[3] + 1;
                final result = await XmlyExperience(source.client)
                    .favorites(page: page);
                if (!current()) return;
                final known = {
                  if (!reset)
                    for (final item in source.favorites) item.id,
                };
                final added = result.items.where((item) {
                  AppLog.instance.trace(
                    "lib/pages/listening_page.dart::_ListeningPageState._loadSection.load.closure#1.closure#3",
                  );

                  return known.add(item.id);
                }).toList();
                if (!reset && result.hasMore && added.isEmpty) {
                  throw const XmlyException('repeated_page', '更多收藏暂不可用，请刷新重试');
                }
                if ((reset ? 0 : source.favorites.length) + added.length >
                    5000) {
                  throw const XmlyException('favorite_limit', '已加载 5000 条收藏');
                }
                source.favorites = [if (!reset) ...source.favorites, ...added];
                source.pages[3] = page;
                source.more[3] = result.hasMore;
            }
          },
          rateLimitRetries: 0,
          cancelled: cancelled.future,
        );
      } catch (error, stack) {
        if (!current()) return;
        _recordListeningError(
          'Account library load failed',
          error,
          stack,
          recoverable: true,
        );
        source.errors[section] = _message(error);
        if (error is XmlyException &&
            const {
              'repeated_page',
              'feed_limit',
              'subscription_limit',
              'favorite_limit',
            }.contains(error.code)) {
          source.more[section] = false;
        }
      }
      if (current())
        setState(() {
          AppLog.instance.trace(
            "lib/pages/listening_page.dart::_ListeningPageState._loadSection.load.closure#2",
          );
        });
    }

    try {
      // Bound work per section; account failures are retained independently.
      for (var offset = 0; offset < sources.length && current(); offset += 3) {
        await Future.wait(sources.skip(offset).take(3).map(load));
      }
    } finally {
      if (current()) {
        _cancelled[section] = null;
        setState(() {
          AppLog.instance.trace(
            "lib/pages/listening_page.dart::_ListeningPageState._loadSection.closure#3",
          );

          _busy[section] = false;
          final errors = [
            for (final source in _sources.values)
              if (source.errors[section] != null)
                '${_accountLabel(source.identity)}：${source.errors[section]}',
          ];
          _errors[section] = errors.isEmpty ? null : errors.join('\n');
        });
        if (section == 3) _scheduleFavoriteSearch();
      }
    }
  }

  void _searchTabChanged() {
    AppLog.instance.trace(
      "lib/pages/listening_page.dart::_ListeningPageState._searchTabChanged",
    );

    if (mounted && _selectedTab != _tabs.index) {
      setState(() {
        AppLog.instance.trace(
          "lib/pages/listening_page.dart::_ListeningPageState._searchTabChanged.closure#1",
        );
        _selectedTab = _tabs.index;
      });
    }
    _scheduleFavoriteSearch();
  }

  void _searchChanged() {
    AppLog.instance.trace(
      "lib/pages/listening_page.dart::_ListeningPageState._searchChanged",
    );

    setState(() {
      AppLog.instance.trace(
        "lib/pages/listening_page.dart::_ListeningPageState._searchChanged.closure#1",
      );
      _favoriteSearchPaused = false;
    });
    _scheduleFavoriteSearch();
  }

  void _scheduleFavoriteSearch() {
    AppLog.instance.trace(
      "lib/pages/listening_page.dart::_ListeningPageState._scheduleFavoriteSearch",
    );

    _favoriteSearchTimer?.cancel();
    if (!mounted ||
        !_signedIn ||
        _tabs.index != 3 ||
        _query.isEmpty ||
        _favoriteSearchPaused ||
        _busy[3] ||
        !_moreFavorites ||
        _errors[3] != null)
      return;
    _favoriteSearchTimer = Timer(const Duration(milliseconds: 300), () {
      AppLog.instance.trace(
        "lib/pages/listening_page.dart::_ListeningPageState._scheduleFavoriteSearch.closure#1",
      );

      if (mounted &&
          _tabs.index == 3 &&
          _query.isNotEmpty &&
          !_favoriteSearchPaused) {
        unawaited(_loadFavorites());
      }
    });
  }

  Widget _favoriteSearchStatus(int matches) {
    AppLog.instance.trace(
      "lib/pages/listening_page.dart::_ListeningPageState._favoriteSearchStatus",
    );

    final complete =
        _favoritePage > 0 && !_moreFavorites && !_busy[3] && _errors[3] == null;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 8,
        children: [
          Text(
            complete
                ? '已搜索全部 ${_favorites.length} 条收藏，匹配 $matches 条'
                : '${_favoriteSearchPaused || _errors[3] != null ? '搜索已暂停' : '正在搜索'}：已检索 ${_favorites.length} 条收藏，匹配 $matches 条，尚未检索完整列表',
          ),
          if (!complete)
            TextButton(
              onPressed: () {
                AppLog.instance.trace(
                  "lib/pages/listening_page.dart::_ListeningPageState._favoriteSearchStatus.closure#1",
                );

                final failed = _errors[3] != null;
                setState(() {
                  AppLog.instance.trace(
                    "lib/pages/listening_page.dart::_ListeningPageState._favoriteSearchStatus.closure#1.closure#1",
                  );

                  _favoriteSearchPaused =
                      !_favoriteSearchPaused && _errors[3] == null;
                  if (!_favoriteSearchPaused) _errors[3] = null;
                });
                if (!_favoriteSearchPaused && failed && !_busy[3]) {
                  unawaited(
                    _loadFavorites(
                      reset: !_moreFavorites || _favoritePage == 0,
                    ),
                  );
                } else {
                  _scheduleFavoriteSearch();
                }
              },
              child: Text(
                _favoriteSearchPaused || _errors[3] != null ? '继续搜索' : '暂停搜索',
              ),
            ),
        ],
      ),
    );
  }

  bool _active(int epoch, String key, String identity) {
    AppLog.instance.trace(
      "lib/pages/listening_page.dart::_ListeningPageState._active",
    );

    return mounted &&
        epoch == _accountEpoch &&
        key == _currentKey &&
        (identity == 'anonymous' ||
            _sources.containsKey(identity) ||
            (_runtime.storage.state['library'] as Map).containsKey(identity));
  }

  Future<void> _changeLibrary(
    String identity,
    Future<void> Function(XmlyExperience api) change,
  ) async {
    AppLog.instance.trace(
      "lib/pages/listening_page.dart::_ListeningPageState._changeLibrary",
    );

    final source = _sources[identity];
    if (source == null) throw const XmlyException('missing_account', '请先登录原账号');
    final client = source.client, epoch = _accountEpoch, key = _currentKey;
    var attempted = false;
    try {
      await _runtime.accounts.runWithAccount(identity, (admitted) async {
        AppLog.instance.trace(
          "lib/pages/listening_page.dart::_ListeningPageState._changeLibrary.closure#1",
        );

        if (!_active(epoch, key, identity) ||
            !identical(admitted, client) ||
            client.cacheIdentity != source.key ||
            !client.accountAvailable) {
          throw const XmlyException('account_changed', '原账号已变更，请刷新后重试');
        }
        attempted = true;
        await change(XmlyExperience(client));
      });
    } catch (error) {
      if (attempted &&
          _active(epoch, key, identity) &&
          (error is! XmlyException || !error.definitive))
        _runtime.libraryChanged();
      rethrow;
    }
    if (_active(epoch, key, identity)) _runtime.libraryChanged();
  }

  Future<void> _removeFavorite(
    Track track,
    List<_ListeningAccount> owners,
  ) async {
    AppLog.instance.trace(
      "lib/pages/listening_page.dart::_ListeningPageState._removeFavorite",
    );

    if (owners.isEmpty) return;
    final epoch = _accountEpoch, key = _currentKey;
    String? identity;
    if (owners.length == 1) {
      identity = owners.single.identity;
      if (!await showConfirmationDialog(
        context,
        Text('从${_accountLabel(identity)}取消收藏此声音？'),
      ))
        return;
    } else {
      identity = await showDialog<String>(
        context: context,
        builder: (context) {
          AppLog.instance.trace(
            "lib/pages/listening_page.dart::_ListeningPageState._removeFavorite.closure#1",
          );

          return SimpleDialog(
            title: const Text('从哪个账号取消收藏'),
            children: [
              for (final owner in owners)
                SimpleDialogOption(
                  onPressed: () {
                    AppLog.instance.trace(
                      "lib/pages/listening_page.dart::_ListeningPageState._removeFavorite.closure#1.closure#1",
                    );

                    Navigator.pop(context, owner.identity);
                  },
                  child: Text(_accountLabel(owner.identity)),
                ),
            ],
          );
        },
      );
    }
    if (identity == null || !_active(epoch, key, identity)) return;
    final selected = identity;
    await _act(() {
      AppLog.instance.trace(
        "lib/pages/listening_page.dart::_ListeningPageState._removeFavorite.closure#2",
      );

      return _changeLibrary(selected, (api) {
        AppLog.instance.trace(
          "lib/pages/listening_page.dart::_ListeningPageState._removeFavorite.closure#2.closure#1",
        );

        return api.setFavorite(track, favorite: false);
      });
    });
  }

  Future<void> _removeBookmark(
    int index,
    Map record,
    int epoch,
    String key,
    String identity,
  ) async {
    AppLog.instance.trace(
      "lib/pages/listening_page.dart::_ListeningPageState._removeBookmark",
    );

    if (!_active(epoch, key, identity) ||
        !await showConfirmationDialog(context, const Text('删除此书签？')) ||
        !_active(epoch, key, identity))
      return;
    await _act(() {
      AppLog.instance.trace(
        "lib/pages/listening_page.dart::_ListeningPageState._removeBookmark.closure#1",
      );
      return _runtime.storage.transaction((state) {
        AppLog.instance.trace(
          "lib/pages/listening_page.dart::_ListeningPageState._removeBookmark.closure#1.closure#1",
        );

        if (!_active(epoch, key, identity)) return;
        final library = (state['library'] as Map)[identity] as Map?;
        final bookmarks = library?['bookmarks'] as List? ?? const [];
        if (index >= bookmarks.length ||
            jsonEncode(bookmarks[index]) != jsonEncode(record)) {
          throw const XmlyException('stale_bookmark', '书签列表已变化，请重新选择');
        }
        bookmarks.removeAt(index);
      });
    });
  }

  Future<void> _editBookmarkNote(
    int index,
    Map record,
    int epoch,
    String key,
    String identity,
  ) async {
    AppLog.instance.trace(
      "lib/pages/listening_page.dart::_ListeningPageState._editBookmarkNote",
    );

    if (_acting || !_active(epoch, key, identity)) return;
    final track = Track.fromJson(xmlyMap(record['track']));
    await showDialog<void>(
      context: context,
      builder: (_) {
        AppLog.instance.trace(
          "lib/pages/listening_page.dart::_ListeningPageState._editBookmarkNote.closure#1",
        );
        return _BookmarkNoteDialog(
          title: track.title.isEmpty ? track.id : track.title,
          position: record['position'] is num
              ? (record['position'] as num).toDouble()
              : 0,
          note: record['note'] is String ? record['note'] as String : '',
          save: (note) async {
            AppLog.instance.trace(
              "lib/pages/listening_page.dart::_ListeningPageState._editBookmarkNote.closure#1.closure#1",
            );

            await _runtime.storage.transaction((state) {
              AppLog.instance.trace(
                "lib/pages/listening_page.dart::_ListeningPageState._editBookmarkNote.closure#1.closure#1.closure#1",
              );

              if (!_active(epoch, key, identity)) {
                throw const XmlyException('account_changed', '账号已变化，请重新打开书签');
              }
              final library = (state['library'] as Map)[identity] as Map?;
              final bookmarks = library?['bookmarks'] as List? ?? const [];
              if (index >= bookmarks.length ||
                  jsonEncode(bookmarks[index]) != jsonEncode(record)) {
                throw const XmlyException('stale_bookmark', '书签列表已变化，请重新选择');
              }
              final updated = Map<String, dynamic>.from(
                bookmarks[index] as Map,
              );
              if (note.isEmpty) {
                updated.remove('note');
              } else {
                updated['note'] = note;
              }
              bookmarks[index] = updated;
            });
            _runtime.changed();
          },
        );
      },
    );
  }

  static String _message(Object error) {
    AppLog.instance.trace(
      "lib/pages/listening_page.dart::_ListeningPageState._message",
    );
    return error is XmlyException ? error.message : '加载失败，请重试';
  }

  Future<void> _act(Future<void> Function() action) {
    AppLog.instance.trace(
      "lib/pages/listening_page.dart::_ListeningPageState._act",
    );
    return AppLog.instance.runWithErrorScope(() async {
      AppLog.instance.trace(
        "lib/pages/listening_page.dart::_ListeningPageState._act.closure#1",
      );

      if (_acting) return;
      final epoch = _accountEpoch;
      setState(() {
        AppLog.instance.trace(
          "lib/pages/listening_page.dart::_ListeningPageState._act.closure#1.closure#1",
        );
        _acting = true;
      });
      try {
        await action();
      } catch (error, stack) {
        _recordListeningError('Listening action failed', error, stack);
        if (mounted && epoch == _accountEpoch)
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text(_message(error))));
      } finally {
        if (mounted)
          setState(() {
            AppLog.instance.trace(
              "lib/pages/listening_page.dart::_ListeningPageState._act.closure#1.closure#2",
            );
            _acting = false;
          });
      }
    });
  }

  void _openAlbum(String id, {String? accountIdentity}) {
    AppLog.instance.trace(
      "lib/pages/listening_page.dart::_ListeningPageState._openAlbum",
    );
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) {
          AppLog.instance.trace(
            "lib/pages/listening_page.dart::_ListeningPageState._openAlbum.closure#1",
          );
          return AlbumPageView(
            runtime: _runtime,
            albumId: id,
            accountIdentity: accountIdentity,
            onDownload: widget.onDownload,
            onPlayAlbum: widget.onPlayAlbum,
          );
        },
      ),
    );
  }

  bool _matches(Track track, {String extra = ''}) {
    AppLog.instance.trace(
      "lib/pages/listening_page.dart::_ListeningPageState._matches",
    );
    return _query.isEmpty ||
        '${track.title} ${track.album} ${track.artist} ${track.id} $extra'
            .toLowerCase()
            .contains(_query);
  }

  List<_ListeningRecord> _history() {
    AppLog.instance.trace(
      "lib/pages/listening_page.dart::_ListeningPageState._history",
    );

    final records = <String, _ListeningRecord>{};
    for (final raw in _cloudHistory) {
      final track = Track.fromApi({
        'trackId': raw['track_id'],
        'albumId': raw['album_id'],
        'title': raw['title'],
        'albumTitle': raw['album_title'],
        'duration': raw['duration'],
        'cover_url': raw['cover_url'],
      });
      final record = _ListeningRecord(
        track,
        (raw['position'] as num).toDouble(),
        ((raw['updated_at'] as num) * 1000).toInt(),
        raw['accountIdentity'] as String,
      );
      if (records[track.id] == null ||
          record.updatedAt > records[track.id]!.updatedAt) {
        records[track.id] = record;
      }
    }
    return records.values.where((row) {
      AppLog.instance.trace(
        "lib/pages/listening_page.dart::_ListeningPageState._history.closure#1",
      );
      return _matches(row.track);
    }).toList()..sort((a, b) {
      AppLog.instance.trace(
        "lib/pages/listening_page.dart::_ListeningPageState._history.closure#2",
      );
      return b.updatedAt.compareTo(a.updatedAt);
    });
  }

  String _day(int timestamp) {
    AppLog.instance.trace(
      "lib/pages/listening_page.dart::_ListeningPageState._day",
    );

    if (timestamp <= 0) return '更早';
    final date = DateTime.fromMillisecondsSinceEpoch(timestamp).toLocal();
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(date.year, date.month, date.day);
    if (day == today) return '今天';
    if (day == DateTime(today.year, today.month, today.day - 1)) return '昨天';
    return '${date.year}年${date.month}月${date.day}日';
  }

  Widget _empty(String message) {
    AppLog.instance.trace(
      "lib/pages/listening_page.dart::_ListeningPageState._empty",
    );
    return Padding(
      padding: const EdgeInsets.all(28),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              _query.isEmpty
                  ? Icons.library_music_outlined
                  : Icons.search_off_rounded,
              size: 40,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 16),
            Text(
              message,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyLarge,
            ),
          ],
        ),
      ),
    );
  }

  Widget _itemTitle(String title) {
    AppLog.instance.trace(
      "lib/pages/listening_page.dart::_ListeningPageState._itemTitle",
    );
    return Text(
      title,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: Theme.of(context).textTheme.titleMedium,
    );
  }

  Widget _sectionState(int section, VoidCallback refresh) {
    AppLog.instance.trace(
      "lib/pages/listening_page.dart::_ListeningPageState._sectionState",
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_busy[section]) const LinearProgressIndicator(),
        if (_errors[section] != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_errors[section]!),
                TextButton(
                  onPressed: _busy[section] ? null : refresh,
                  child: const Text('重试'),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _trackTile(
    Track track, {
    required VoidCallback? play,
    double position = 0,
    String? removeLabel,
    VoidCallback? remove,
    String? accountIdentity,
    String accountText = '',
    String positionLabel = '已听',
    String note = '',
    VoidCallback? editNote,
  }) {
    AppLog.instance.trace(
      "lib/pages/listening_page.dart::_ListeningPageState._trackTile",
    );

    final compact = MediaQuery.sizeOf(context).width < 320;
    final epoch = _accountEpoch, key = _currentKey;
    final identity = accountIdentity ?? _runtime.player.libraryIdentity;
    final duration = track.duration;
    final progress = duration > 0
        ? (position / duration).clamp(0.0, 1.0).toDouble()
        : null;
    return ListTile(
      contentPadding: EdgeInsets.symmetric(
        horizontal: compact ? 8 : 12,
        vertical: 2,
      ),
      minTileHeight: 64,
      minVerticalPadding: 4,
      horizontalTitleGap: 12,
      leading: compact ? null : CoverImage(uri: track.coverUrl, size: 48),
      title: _itemTitle(track.title.isEmpty ? track.id : track.title),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (note.isNotEmpty)
            Text(note, maxLines: 3, overflow: TextOverflow.ellipsis),
          if (accountText.isNotEmpty) _accountCaption(accountText),
          if (track.album.isNotEmpty) AdaptiveText(track.album),
          AdaptiveText(
            position > 0
                ? '$positionLabel ${playbackTime(position)}${duration > 0 ? ' / ${playbackTime(duration)}' : ''}'
                : playbackTime(duration),
          ),
          if (position > 0 && progress != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: LinearProgressIndicator(
                value: progress,
                minHeight: 2,
                semanticsLabel: positionLabel,
              ),
            ),
        ],
      ),
      onTap: _acting || play == null
          ? null
          : () {
              AppLog.instance.trace(
                "lib/pages/listening_page.dart::_ListeningPageState._trackTile.closure#1",
              );

              if (_active(epoch, key, identity)) play();
            },
      trailing: PopupMenuButton<String>(
        tooltip: '声音操作',
        enabled: !_acting,
        onSelected: (value) {
          AppLog.instance.trace(
            "lib/pages/listening_page.dart::_ListeningPageState._trackTile.closure#2",
          );

          if (!_active(epoch, key, identity)) return;
          switch (value) {
            case 'play':
              play?.call();
              break;
            case 'queue':
              _act(() {
                AppLog.instance.trace(
                  "lib/pages/listening_page.dart::_ListeningPageState._trackTile.closure#2.closure#1",
                );
                return _runtime.player.addToQueue(
                  track,
                  accountIdentity: accountIdentity,
                );
              });
              break;
            case 'next':
              _act(() {
                AppLog.instance.trace(
                  "lib/pages/listening_page.dart::_ListeningPageState._trackTile.closure#2.closure#2",
                );
                return _runtime.player.playNext(
                  track,
                  accountIdentity: accountIdentity,
                );
              });
              break;
            case 'download':
              _act(() {
                AppLog.instance.trace(
                  "lib/pages/listening_page.dart::_ListeningPageState._trackTile.closure#2.closure#3",
                );
                return requestDownloads(context, _runtime, [
                  track,
                ], accountIdentity: accountIdentity);
              });
              break;
            case 'album':
              _openAlbum(track.albumId, accountIdentity: accountIdentity);
              break;
            case 'remove':
              remove?.call();
              break;
            case 'note':
              editNote?.call();
              break;
          }
        },
        itemBuilder: (_) {
          AppLog.instance.trace(
            "lib/pages/listening_page.dart::_ListeningPageState._trackTile.closure#3",
          );
          return [
            if (play != null)
              const PopupMenuItem(value: 'play', child: Text('播放')),
            const PopupMenuItem(value: 'queue', child: Text('加入播放队列')),
            const PopupMenuItem(value: 'next', child: Text('下一集播放')),
            const PopupMenuItem(value: 'download', child: Text('下载')),
            if (track.albumId.isNotEmpty)
              const PopupMenuItem(value: 'album', child: Text('查看专辑')),
            if (editNote != null)
              PopupMenuItem(
                value: 'note',
                child: Text(note.isEmpty ? '添加备注' : '编辑备注'),
              ),
            if (remove != null)
              PopupMenuItem(value: 'remove', child: Text(removeLabel ?? '移除')),
          ];
        },
      ),
    );
  }

  Widget _dated<T>(
    List<T> items,
    int Function(T) timestamp,
    Widget Function(T) tile, {
    Widget? footer,
    List<Widget> headers = const [],
    String emptyMessage = '暂无记录',
  }) {
    AppLog.instance.trace(
      "lib/pages/listening_page.dart::_ListeningPageState._dated",
    );

    final rows = <Object>[];
    String? previous;
    for (final item in items) {
      final day = _day(timestamp(item));
      if (day != previous) {
        rows.add(day);
        previous = day;
      }
      rows.add(item as Object);
    }
    return Scrollbar(
      child: CustomScrollView(
        slivers: [
          for (final header in headers) SliverToBoxAdapter(child: header),
          if (items.isEmpty && footer == null)
            SliverFillRemaining(
              hasScrollBody: false,
              child: _empty(emptyMessage),
            ),
          SliverList.builder(
            itemCount: rows.length + (footer == null ? 0 : 1),
            itemBuilder: (_, index) {
              AppLog.instance.trace(
                "lib/pages/listening_page.dart::_ListeningPageState._dated.closure#1",
              );

              if (index == rows.length) return footer!;
              final row = rows[index];
              return row is String
                  ? Padding(
                      padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
                      child: AdaptiveText(
                        row,
                        style: Theme.of(context).textTheme.labelLarge?.copyWith(
                          fontWeight: FontWeight.w600,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    )
                  : tile(row as T);
            },
          ),
        ],
      ),
    );
  }

  Widget _subscriptionStrip() {
    AppLog.instance.trace(
      "lib/pages/listening_page.dart::_ListeningPageState._subscriptionStrip",
    );

    final compact = MediaQuery.sizeOf(context).width < 320;
    final epoch = _accountEpoch, key = _currentKey;
    return SizedBox(
      height: compact
          ? (MediaQuery.textScalerOf(context).scale(16) * 1.5 + 8).clamp(
              48.0,
              double.infinity,
            )
          : 68 + MediaQuery.textScalerOf(context).scale(16) * 1.5,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.symmetric(
          horizontal: compact ? 8 : 12,
          vertical: compact ? 0 : 4,
        ),
        itemCount: _subscriptions.length,
        separatorBuilder: (_, _) {
          AppLog.instance.trace(
            "lib/pages/listening_page.dart::_ListeningPageState._subscriptionStrip.closure#1",
          );
          return const SizedBox(width: 8);
        },
        itemBuilder: (_, index) {
          AppLog.instance.trace(
            "lib/pages/listening_page.dart::_ListeningPageState._subscriptionStrip.closure#2",
          );

          final item = _subscriptions[index];
          final identity = _owners(1, item.album.id).first.identity;
          return SizedBox(
            width: 72,
            child: InkWell(
              onTap: () {
                AppLog.instance.trace(
                  "lib/pages/listening_page.dart::_ListeningPageState._subscriptionStrip.closure#2.closure#1",
                );

                if (_active(epoch, key, identity))
                  _openAlbum(item.album.id, accountIdentity: identity);
              },
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (!compact) CoverImage(uri: item.album.coverUrl, size: 56),
                  if (!compact) const SizedBox(height: 4),
                  AdaptiveText(item.album.title),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _updatesTab() {
    AppLog.instance.trace(
      "lib/pages/listening_page.dart::_ListeningPageState._updatesTab",
    );

    final visible = _updates.where((row) {
      AppLog.instance.trace(
        "lib/pages/listening_page.dart::_ListeningPageState._updatesTab.closure#1",
      );

      return _matches(row.track);
    }).toList();
    return _dated<UpdateItem>(
      visible,
      (row) {
        AppLog.instance.trace(
          "lib/pages/listening_page.dart::_ListeningPageState._updatesTab.closure#2",
        );

        return row.publishedAt;
      },
      (row) {
        AppLog.instance.trace(
          "lib/pages/listening_page.dart::_ListeningPageState._updatesTab.closure#3",
        );

        final owners = _owners(0, row.track.id);
        final identity = owners.firstOrNull?.identity;
        return _trackTile(
          row.track,
          accountIdentity: identity,
          accountText: _ownerLabel(owners),
          play: () {
            AppLog.instance.trace(
              "lib/pages/listening_page.dart::_ListeningPageState._updatesTab.closure#3.closure#1",
            );

            _act(() {
              AppLog.instance.trace(
                "lib/pages/listening_page.dart::_ListeningPageState._updatesTab.closure#3.closure#1.closure#1",
              );

              return _runtime.player.playUpdates(
                visible.map((item) {
                  AppLog.instance.trace(
                    "lib/pages/listening_page.dart::_ListeningPageState._updatesTab.closure#3.closure#1.closure#1.closure#1",
                  );

                  return item.track;
                }).toList(),
                row.track.id,
                accountIdentities: {
                  for (final item in visible)
                    item.track.id: _owners(0, item.track.id).first.identity,
                },
              );
            });
          },
        );
      },
      headers: [
        if (_subscriptions.isNotEmpty) _subscriptionStrip(),
        _sectionState(0, () {
          AppLog.instance.trace(
            "lib/pages/listening_page.dart::_ListeningPageState._updatesTab.closure#4",
          );

          _loadUpdates(reset: true);
        }),
        if (_subscriptions.isEmpty)
          _sectionState(1, () {
            AppLog.instance.trace(
              "lib/pages/listening_page.dart::_ListeningPageState._updatesTab.closure#5",
            );

            _loadSubscriptions(reset: true);
          }),
      ],
      emptyMessage: _signedIn ? '暂无更新' : '登录后查看订阅更新',
      footer: _moreUpdates ? _moreButton(0, '加载更多更新', _loadUpdates) : null,
    );
  }

  Widget _moreButton(int section, String label, Future<void> Function() load) {
    AppLog.instance.trace(
      "lib/pages/listening_page.dart::_ListeningPageState._moreButton",
    );

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Center(
        child: OutlinedButton(
          onPressed: _busy[section] ? null : load,
          child: Text(label),
        ),
      ),
    );
  }

  Widget _subscriptionsTab() {
    AppLog.instance.trace(
      "lib/pages/listening_page.dart::_ListeningPageState._subscriptionsTab",
    );

    final epoch = _accountEpoch, key = _currentKey;
    final items = _subscriptions.where((row) {
      AppLog.instance.trace(
        "lib/pages/listening_page.dart::_ListeningPageState._subscriptionsTab.closure#1",
      );

      return _query.isEmpty ||
          '${row.album.title} ${row.latestTitle} ${row.album.artist}'
              .toLowerCase()
              .contains(_query);
    }).toList();
    return _dated<SubscriptionItem>(
      items,
      (row) {
        AppLog.instance.trace(
          "lib/pages/listening_page.dart::_ListeningPageState._subscriptionsTab.closure#2",
        );

        return row.updatedAt;
      },
      (row) {
        AppLog.instance.trace(
          "lib/pages/listening_page.dart::_ListeningPageState._subscriptionsTab.closure#3",
        );

        final owners = _owners(1, row.album.id);
        final identity = owners.first.identity;
        final accountText = _ownerLabel(owners);
        return ListTile(
          key: ValueKey('subscription-${row.album.id}'),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 12,
            vertical: 4,
          ),
          leading: MediaQuery.sizeOf(context).width < 320
              ? null
              : CoverImage(uri: row.album.coverUrl, size: 48),
          title: _itemTitle(row.album.title),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                row.latestTitle,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              if (accountText.isNotEmpty) _accountCaption(accountText),
            ],
          ),
          trailing: PopupMenuButton<String>(
            tooltip: '更多',
            enabled: !_acting,
            icon: row.unreadCount > 0
                ? Badge(
                    label: Text('${row.unreadCount}'),
                    child: const Icon(Icons.more_vert),
                  )
                : const Icon(Icons.more_vert),
            onSelected: (value) async {
              AppLog.instance.trace(
                "lib/pages/listening_page.dart::_ListeningPageState._subscriptionsTab.closure#3.closure#1",
              );

              if (!_active(epoch, key, identity)) return;
              if (value == 'album') {
                _openAlbum(row.album.id, accountIdentity: identity);
                return;
              }
              final owner = value.substring('unsubscribe:'.length);
              if (await showConfirmationDialog(
                    context,
                    Text('从${_accountLabel(owner)}取消订阅此专辑？'),
                  ) &&
                  _active(epoch, key, owner)) {
                await _act(() {
                  AppLog.instance.trace(
                    "lib/pages/listening_page.dart::_ListeningPageState._subscriptionsTab.closure#3.closure#1.closure#1",
                  );

                  return _changeLibrary(owner, (api) {
                    AppLog.instance.trace(
                      "lib/pages/listening_page.dart::_ListeningPageState._subscriptionsTab.closure#3.closure#1.closure#1.closure#1",
                    );

                    return api.setSubscribed(row.album.id, subscribed: false);
                  });
                });
              }
            },
            itemBuilder: (_) {
              AppLog.instance.trace(
                "lib/pages/listening_page.dart::_ListeningPageState._subscriptionsTab.closure#3.closure#2",
              );

              return [
                const PopupMenuItem(value: 'album', child: Text('查看专辑')),
                for (final owner in owners)
                  PopupMenuItem(
                    value: 'unsubscribe:${owner.identity}',
                    child: Text(
                      owners.length == 1
                          ? '取消订阅'
                          : '取消订阅 · ${_accountLabel(owner.identity)}',
                    ),
                  ),
              ];
            },
          ),
          onTap: () {
            AppLog.instance.trace(
              "lib/pages/listening_page.dart::_ListeningPageState._subscriptionsTab.closure#3.closure#3",
            );

            if (_active(epoch, key, identity))
              _openAlbum(row.album.id, accountIdentity: identity);
          },
        );
      },
      headers: [
        _sectionState(1, () {
          AppLog.instance.trace(
            "lib/pages/listening_page.dart::_ListeningPageState._subscriptionsTab.closure#4",
          );

          _loadSubscriptions(reset: true);
        }),
      ],
      emptyMessage: _signedIn ? '暂无订阅' : '登录后查看订阅',
      footer: _moreSubscriptions
          ? _moreButton(1, '加载更多订阅', _loadSubscriptions)
          : null,
    );
  }

  Widget _historyTab() {
    AppLog.instance.trace(
      "lib/pages/listening_page.dart::_ListeningPageState._historyTab",
    );

    return _dated<_ListeningRecord>(
      _history(),
      (row) {
        AppLog.instance.trace(
          "lib/pages/listening_page.dart::_ListeningPageState._historyTab.closure#1",
        );

        return row.updatedAt;
      },
      (row) {
        AppLog.instance.trace(
          "lib/pages/listening_page.dart::_ListeningPageState._historyTab.closure#2",
        );

        return _trackTile(
          row.track,
          position: row.position,
          accountIdentity: row.identity,
          accountText: _sources.length > 1 ? _accountLabel(row.identity) : '',
          play: () {
            AppLog.instance.trace(
              "lib/pages/listening_page.dart::_ListeningPageState._historyTab.closure#2.closure#1",
            );

            _act(() {
              AppLog.instance.trace(
                "lib/pages/listening_page.dart::_ListeningPageState._historyTab.closure#2.closure#1.closure#1",
              );

              final historyProgress = (
                position: row.position,
                updatedAt: row.updatedAt,
              );
              return row.track.albumId.isEmpty
                  ? _runtime.player.playTrack(
                      row.track,
                      historyProgress: historyProgress,
                      accountIdentity: row.identity,
                    )
                  : _runtime.player.playAlbum(
                      row.track.albumId,
                      row.track.id,
                      track: row.track,
                      historyProgress: historyProgress,
                      accountIdentity: row.identity,
                    );
            });
          },
        );
      },
      headers: [_sectionState(2, _loadHistory)],
      emptyMessage: !_signedIn
          ? '登录后查看云历史记录'
          : _query.isEmpty
          ? '暂无云历史记录'
          : '没有匹配的历史记录',
    );
  }

  Widget _favoritesTab() {
    AppLog.instance.trace(
      "lib/pages/listening_page.dart::_ListeningPageState._favoritesTab",
    );

    final items = _favorites.where(_matches).toList();
    return Scrollbar(
      child: ListView.builder(
        itemCount: items.length + 2 + (_moreFavorites ? 1 : 0),
        itemBuilder: (_, index) {
          AppLog.instance.trace(
            "lib/pages/listening_page.dart::_ListeningPageState._favoritesTab.closure#1",
          );

          if (index == 0)
            return Column(
              children: [
                _sectionState(3, () {
                  AppLog.instance.trace(
                    "lib/pages/listening_page.dart::_ListeningPageState._favoritesTab.closure#1.closure#1",
                  );

                  _loadFavorites(reset: true);
                }),
                if (_signedIn && _query.isNotEmpty)
                  _favoriteSearchStatus(items.length),
              ],
            );
          if (index == 1)
            return items.isEmpty
                ? _empty(
                    !_signedIn
                        ? '登录后查看收藏'
                        : _query.isEmpty
                        ? '暂无收藏'
                        : _moreFavorites ||
                              _busy[3] ||
                              _errors[3] != null ||
                              _favoritePage == 0
                        ? '已加载收藏中没有匹配项'
                        : '全部收藏中没有匹配项',
                  )
                : const SizedBox.shrink();
          if (index == items.length + 2)
            return _moreButton(3, '加载更多收藏', _loadFavorites);
          final track = items[index - 2];
          final owners = _owners(3, track.id), identity = owners.first.identity;
          return _trackTile(
            track,
            accountIdentity: identity,
            accountText: _ownerLabel(owners),
            play: () {
              AppLog.instance.trace(
                "lib/pages/listening_page.dart::_ListeningPageState._favoritesTab.closure#1.closure#2",
              );

              _act(() {
                AppLog.instance.trace(
                  "lib/pages/listening_page.dart::_ListeningPageState._favoritesTab.closure#1.closure#2.closure#1",
                );

                return track.albumId.isEmpty
                    ? _runtime.player.playTrack(
                        track,
                        accountIdentity: identity,
                      )
                    : _runtime.player.playAlbum(
                        track.albumId,
                        track.id,
                        track: track,
                        accountIdentity: identity,
                      );
              });
            },
            removeLabel: '取消收藏',
            remove: () {
              AppLog.instance.trace(
                "lib/pages/listening_page.dart::_ListeningPageState._favoritesTab.closure#1.closure#3",
              );

              _removeFavorite(track, owners);
            },
          );
        },
      ),
    );
  }

  Widget _accountCaption(String text) {
    AppLog.instance.trace(
      "lib/pages/listening_page.dart::_ListeningPageState._accountCaption",
    );

    return Text(
      text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: Theme.of(context).textTheme.bodySmall
          ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
    );
  }

  Widget _bookmarksTab() {
    AppLog.instance.trace(
      "lib/pages/listening_page.dart::_ListeningPageState._bookmarksTab",
    );

    final epoch = _accountEpoch, key = _currentKey;
    final rows =
        <
          ({int index, Map record, Track track, String note, String identity})
        >[];
    final libraries = _runtime.storage.state['library'] as Map;
    for (final entry in libraries.entries) {
      if (entry.key is! String || entry.value is! Map) continue;
      final identity = entry.key as String;
      final bookmarks = (entry.value as Map)['bookmarks'] as List? ?? const [];
      for (var i = 0; i < bookmarks.length; i++) {
        final record = bookmarks[i];
        if (record is! Map || record['track'] is! Map) continue;
        try {
          final track = Track.fromJson(xmlyMap(record['track']));
          final note = record['note'] is String ? record['note'] as String : '';
          if (_matches(track, extra: note)) {
            rows.add((
              index: i,
              record: record,
              track: track,
              note: note,
              identity: identity,
            ));
          }
        } on XmlyException {
          continue;
        } on FormatException {
          continue;
        }
      }
    }
    rows.sort((a, b) {
      AppLog.instance.trace(
        "lib/pages/listening_page.dart::_ListeningPageState._bookmarksTab.closure#1",
      );

      final first = a.record['createdAt'], second = b.record['createdAt'];
      return (second is int ? second : 0).compareTo(first is int ? first : 0);
    });
    return _dated(
      rows,
      (row) {
        AppLog.instance.trace(
          "lib/pages/listening_page.dart::_ListeningPageState._bookmarksTab.closure#2",
        );
        return row.record['createdAt'] is int
            ? row.record['createdAt'] as int
            : 0;
      },
      (row) {
        AppLog.instance.trace(
          "lib/pages/listening_page.dart::_ListeningPageState._bookmarksTab.closure#3",
        );

        final (:index, :record, :track, :note, :identity) = row;
        final saved = record['position'];
        final position = saved is num && saved.isFinite && saved >= 0
            ? saved.toDouble()
            : 0.0;
        return _trackTile(
          track,
          position: position,
          positionLabel: '书签位置',
          accountIdentity: identity,
          accountText: libraries.length > 1 ? _accountLabel(identity) : '',
          note: note,
          editNote: () {
            AppLog.instance.trace(
              "lib/pages/listening_page.dart::_ListeningPageState._bookmarksTab.closure#3.closure#1",
            );

            _editBookmarkNote(index, record, epoch, key, identity);
          },
          play: () {
            AppLog.instance.trace(
              "lib/pages/listening_page.dart::_ListeningPageState._bookmarksTab.closure#3.closure#2",
            );
            _act(() {
              AppLog.instance.trace(
                "lib/pages/listening_page.dart::_ListeningPageState._bookmarksTab.closure#3.closure#2.closure#1",
              );
              return _runtime.player.playTrack(
                track,
                resumePosition: position,
                manualPosition: true,
                accountIdentity: identity,
              );
            });
          },
          removeLabel: '删除书签',
          remove: () {
            AppLog.instance.trace(
              "lib/pages/listening_page.dart::_ListeningPageState._bookmarksTab.closure#3.closure#3",
            );
            _removeBookmark(index, record, epoch, key, identity);
          },
        );
      },
      emptyMessage: _query.isEmpty ? '暂无书签' : '没有匹配的书签',
    );
  }

  void _openFollowedAnchors() {
    AppLog.instance.trace(
      "lib/pages/listening_page.dart::_ListeningPageState._openFollowedAnchors",
    );

    final uids = {
      for (final source in _sources.values)
        if (source.client.credentials?.uid case final uid?) uid,
    }.toList();
    if (uids.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('登录后查看关注的主播')));
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) {
          AppLog.instance.trace(
            "lib/pages/listening_page.dart::_ListeningPageState._openFollowedAnchors.closure#1",
          );
          return AnchorFollowingPage(
            runtime: _runtime,
            uid: uids.first,
            additionalUids: uids.skip(1).toList(),
            onDownload: widget.onDownload,
            onPlayAlbum: widget.onPlayAlbum,
          );
        },
      ),
    );
  }

  Widget _libraryHeader() {
    AppLog.instance.trace(
      "lib/pages/listening_page.dart::_ListeningPageState._libraryHeader",
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        AppLog.instance.trace(
          "lib/pages/listening_page.dart::_ListeningPageState._libraryHeader.closure#1",
        );
        final title = Wrap(
          spacing: 16,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              '我的收听',
              style: Theme.of(context).textTheme.headlineLarge?.copyWith(
                fontSize: 30,
                fontWeight: FontWeight.w600,
                height: 1.3,
              ),
            ),
            TextButton.icon(
              key: const ValueKey('followedAnchorsLink'),
              onPressed: _openFollowedAnchors,
              icon: const Icon(Icons.people_outline, size: 18),
              label: const Text('关注的主播'),
            ),
          ],
        );
        final search = Row(
          children: [
            Expanded(
              child: TextField(
                controller: _search,
                onChanged: (_) {
                  AppLog.instance.trace(
                    "lib/pages/listening_page.dart::_ListeningPageState._libraryHeader.closure#1.closure#1",
                  );
                  _searchChanged();
                },
                decoration: InputDecoration(
                  hintText: '搜索收听内容',
                  prefixIcon: const Icon(Icons.search_rounded),
                  suffixIcon: _search.text.isEmpty
                      ? null
                      : IconButton(
                          tooltip: '清空搜索',
                          onPressed: () {
                            AppLog.instance.trace(
                              "lib/pages/listening_page.dart::_ListeningPageState._libraryHeader.closure#1.closure#2",
                            );
                            _search.clear();
                            _searchChanged();
                          },
                          icon: const Icon(Icons.close_rounded),
                        ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              tooltip: '刷新收听列表',
              icon: const Icon(Icons.refresh_rounded),
              onPressed: !_signedIn
                  ? null
                  : () {
                      AppLog.instance.trace(
                        "lib/pages/listening_page.dart::_ListeningPageState._libraryHeader.closure#1.closure#3",
                      );
                      _runtime.libraryChanged();
                      unawaited(_loadHistory());
                    },
            ),
          ],
        );
        if (constraints.maxWidth <
            720 * MediaQuery.textScalerOf(context).scale(14) / 14) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [title, const SizedBox(height: 16), search],
          );
        }
        return Row(
          children: [
            Expanded(child: title),
            const SizedBox(width: 32),
            SizedBox(
              width: (constraints.maxWidth * .5).clamp(320.0, 520.0),
              child: search,
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    AppLog.instance.trace(
      "lib/pages/listening_page.dart::_ListeningPageState.build",
    );

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 960),
        child: NestedScrollView(
          headerSliverBuilder: (context, innerBoxIsScrolled) {
            AppLog.instance.trace(
              "lib/pages/listening_page.dart::_ListeningPageState.build.closure#1",
            );
            return [
              SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.fromLTRB(
                    MediaQuery.sizeOf(context).width < 320 ? 8 : 16,
                    8,
                    8,
                    8,
                  ),
                  child: _libraryHeader(),
                ),
              ),
              SliverToBoxAdapter(
                child: AppTabStrip(
                  key: const ValueKey('listeningContentTabs'),
                  children: [
                    for (final (index, label) in const [
                      (0, '听更新'),
                      (1, '订阅'),
                      (2, '历史'),
                      (3, '收藏'),
                      (4, '书签'),
                    ])
                      AppTabButton(
                        key: ValueKey(index),
                        label: label,
                        selected: _selectedTab == index,
                        onPressed: () {
                          AppLog.instance.trace(
                            "lib/pages/listening_page.dart::_ListeningPageState.build.closure#1.closure#1",
                          );
                          _tabs.animateTo(index);
                        },
                      ),
                  ],
                ),
              ),
              if (_acting)
                const SliverToBoxAdapter(child: LinearProgressIndicator()),
            ];
          },
          body: TabBarView(
            controller: _tabs,
            children: [
              _updatesTab(),
              _subscriptionsTab(),
              _historyTab(),
              _favoritesTab(),
              _bookmarksTab(),
            ],
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    AppLog.instance.trace(
      "lib/pages/listening_page.dart::_ListeningPageState.dispose",
    );

    ++_accountEpoch;
    _favoriteSearchTimer?.cancel();
    for (final cancelled in _cancelled) {
      cancelled?.complete();
    }
    _tabs.removeListener(_searchTabChanged);
    _tabs.dispose();
    _runtime.removeListener(_runtimeChanged);
    _search.dispose();
    super.dispose();
  }
}

class _ListeningRecord {
  const _ListeningRecord(
    this.track,
    this.position,
    this.updatedAt,
    this.identity,
  );
  final String identity;
  final Track track;
  final double position;
  final int updatedAt;
}

class _ListeningAccount {
  _ListeningAccount(this.client) : key = client.cacheIdentity {
    AppLog.instance.trace(
      "lib/pages/listening_page.dart::_ListeningAccount.new",
    );
  }
  final XmlyClient client;
  final String key;
  String get identity {
    AppLog.instance.trace(
      "lib/pages/listening_page.dart::_ListeningAccount.identity.get",
    );

    return client.identity;
  }

  final pages = [0, 0, 0, 0];
  final more = [true, true, false, true];
  final List<String?> errors = [null, null, null, null];
  int? before;
  List<UpdateItem> updates = [];
  List<SubscriptionItem> subscriptions = [];
  List<Map<String, dynamic>> history = [];
  List<Track> favorites = [];
}
