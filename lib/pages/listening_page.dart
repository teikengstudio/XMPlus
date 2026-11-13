import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../api/xmly_experience.dart';
import '../api/xmly_history.dart';
import '../common/widgets/adaptive_text.dart';
import '../common/widgets/app_tab_button.dart';
import '../common/widgets/confirmation_dialog.dart';
import '../models/xmly_models.dart';
import '../services/app_log.dart';
import '../services/app_runtime.dart';
import 'catalogue_page.dart';
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
  List<UpdateItem> _updates = [];
  List<SubscriptionItem> _subscriptions = [];
  List<Map<String, dynamic>> _cloudHistory = [];
  List<Track> _favorites = [];
  bool _moreFavorites = false;
  int _favoritePage = 0;
  late int _libraryRevision;
  late bool _accountAvailable;
  bool _moreUpdates = false, _moreSubscriptions = false, _acting = false;
  int? _before;
  int _subscriptionPage = 0, _accountEpoch = 0;
  late String _accountKey;
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
    return _runtime.client.cacheIdentity;
  }

  bool get _signedIn {
    AppLog.instance.trace(
      "lib/pages/listening_page.dart::_ListeningPageState._signedIn.get",
    );
    return _runtime.client.accountAvailable;
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
    _accountKey = _currentKey;
    _libraryRevision = _runtime.libraryRevision;
    _accountAvailable = _signedIn;
    ++_accountEpoch;
    setState(() {
      AppLog.instance.trace(
        "lib/pages/listening_page.dart::_ListeningPageState._resetAccount.closure#1",
      );

      _updates = [];
      _subscriptions = [];
      _cloudHistory = [];
      _favorites = [];
      _favoritePage = 0;
      _moreFavorites = false;
      _before = null;
      _subscriptionPage = 0;
      _moreUpdates = false;
      _moreSubscriptions = false;
      for (var i = 0; i < _busy.length; i++) {
        _busy[i] = false;
        _errors[i] = null;
        ++_requests[i];
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
    return AppLog.instance.runWithErrorScope(() async {
      AppLog.instance.trace(
        "lib/pages/listening_page.dart::_ListeningPageState._loadUpdates.closure#1",
      );

      if (!_signedIn || (!reset && (_busy[0] || !_moreUpdates))) return;
      final client = _runtime.client,
          epoch = _accountEpoch,
          request = ++_requests[0];
      final key = client.cacheIdentity;
      final before = reset ? null : _before;
      setState(() {
        AppLog.instance.trace(
          "lib/pages/listening_page.dart::_ListeningPageState._loadUpdates.closure#1.closure#1",
        );

        _busy[0] = true;
        _errors[0] = null;
      });
      try {
        final result = await XmlyExperience(client)
            .updates(before: before, pageSize: 50);
        if (!_valid(0, request, epoch, key)) return;
        final known = reset
            ? <String>{}
            : _updates.map((item) {
                AppLog.instance.trace(
                  "lib/pages/listening_page.dart::_ListeningPageState._loadUpdates.closure#1.closure#2",
                );
                return item.track.id;
              }).toSet();
        final added = result.items.where((item) {
          AppLog.instance.trace(
            "lib/pages/listening_page.dart::_ListeningPageState._loadUpdates.closure#1.closure#3",
          );
          return known.add(item.track.id);
        }).toList();
        if ((!reset && result.hasMore && added.isEmpty) ||
            (result.hasMore &&
                (result.nextTimeline == null ||
                    result.nextTimeline == before))) {
          throw const XmlyException('repeated_page', '更新列表没有前进，请稍后重试');
        }
        if ((reset ? 0 : _updates.length) + added.length > 5000) {
          throw const XmlyException('feed_limit', '已加载 5000 条更新，请搜索或刷新列表');
        }
        setState(() {
          AppLog.instance.trace(
            "lib/pages/listening_page.dart::_ListeningPageState._loadUpdates.closure#1.closure#4",
          );

          _updates = [if (!reset) ..._updates, ...added];
          _before = result.nextTimeline;
          _moreUpdates = result.hasMore;
        });
      } catch (error, stack) {
        _recordListeningError('Updates load failed', error, stack);
        if (_valid(0, request, epoch, key))
          setState(() {
            AppLog.instance.trace(
              "lib/pages/listening_page.dart::_ListeningPageState._loadUpdates.closure#1.closure#5",
            );

            _errors[0] = error is XmlyException && error.code == 'repeated_page'
                ? '更多更新分页暂不可用，已保留当前列表'
                : _message(error);
            if (error is XmlyException && error.code == 'repeated_page')
              _moreUpdates = false;
          });
      } finally {
        if (_valid(0, request, epoch, key))
          setState(() {
            AppLog.instance.trace(
              "lib/pages/listening_page.dart::_ListeningPageState._loadUpdates.closure#1.closure#6",
            );
            _busy[0] = false;
          });
      }
    });
  }

  Future<void> _loadSubscriptions({bool reset = false}) {
    AppLog.instance.trace(
      "lib/pages/listening_page.dart::_ListeningPageState._loadSubscriptions",
    );
    return AppLog.instance.runWithErrorScope(() async {
      AppLog.instance.trace(
        "lib/pages/listening_page.dart::_ListeningPageState._loadSubscriptions.closure#1",
      );

      if (!_signedIn || (!reset && (_busy[1] || !_moreSubscriptions))) return;
      final client = _runtime.client,
          epoch = _accountEpoch,
          request = ++_requests[1];
      final key = client.cacheIdentity,
          page = reset ? 1 : _subscriptionPage + 1;
      setState(() {
        AppLog.instance.trace(
          "lib/pages/listening_page.dart::_ListeningPageState._loadSubscriptions.closure#1.closure#1",
        );

        _busy[1] = true;
        _errors[1] = null;
      });
      try {
        final result = await XmlyExperience(client).subscriptions(page: page);
        if (!_valid(1, request, epoch, key)) return;
        final known = reset
            ? <String>{}
            : _subscriptions.map((item) {
                AppLog.instance.trace(
                  "lib/pages/listening_page.dart::_ListeningPageState._loadSubscriptions.closure#1.closure#2",
                );
                return item.album.id;
              }).toSet();
        final added = result.items.where((item) {
          AppLog.instance.trace(
            "lib/pages/listening_page.dart::_ListeningPageState._loadSubscriptions.closure#1.closure#3",
          );
          return known.add(item.album.id);
        }).toList();
        if (!reset && result.hasMore && added.isEmpty) {
          throw const XmlyException('repeated_page', '订阅列表没有前进，请稍后重试');
        }
        if ((reset ? 0 : _subscriptions.length) + added.length > 5000) {
          throw const XmlyException('subscription_limit', '已加载 5000 个订阅');
        }
        setState(() {
          AppLog.instance.trace(
            "lib/pages/listening_page.dart::_ListeningPageState._loadSubscriptions.closure#1.closure#4",
          );

          _subscriptions = [if (!reset) ..._subscriptions, ...added];
          _subscriptionPage = page;
          _moreSubscriptions = result.hasMore;
        });
      } catch (error, stack) {
        _recordListeningError('Subscriptions load failed', error, stack);
        if (_valid(1, request, epoch, key))
          setState(() {
            AppLog.instance.trace(
              "lib/pages/listening_page.dart::_ListeningPageState._loadSubscriptions.closure#1.closure#5",
            );
            _errors[1] = _message(error);
          });
      } finally {
        if (_valid(1, request, epoch, key))
          setState(() {
            AppLog.instance.trace(
              "lib/pages/listening_page.dart::_ListeningPageState._loadSubscriptions.closure#1.closure#6",
            );
            _busy[1] = false;
          });
      }
    });
  }

  Future<void> _loadHistory() {
    AppLog.instance.trace(
      "lib/pages/listening_page.dart::_ListeningPageState._loadHistory",
    );
    return AppLog.instance.runWithErrorScope(() async {
      AppLog.instance.trace(
        "lib/pages/listening_page.dart::_ListeningPageState._loadHistory.closure#1",
      );

      if (!_signedIn) return;
      final client = _runtime.client,
          epoch = _accountEpoch,
          request = ++_requests[2];
      final key = client.cacheIdentity;
      setState(() {
        AppLog.instance.trace(
          "lib/pages/listening_page.dart::_ListeningPageState._loadHistory.closure#1.closure#1",
        );

        _busy[2] = true;
        _errors[2] = null;
      });
      try {
        final result = await XmlyHistory(client).records();
        if (_valid(2, request, epoch, key))
          setState(() {
            AppLog.instance.trace(
              "lib/pages/listening_page.dart::_ListeningPageState._loadHistory.closure#1.closure#2",
            );
            _cloudHistory = result;
          });
      } catch (error, stack) {
        _recordListeningError('History load failed', error, stack);
        if (_valid(2, request, epoch, key))
          setState(() {
            AppLog.instance.trace(
              "lib/pages/listening_page.dart::_ListeningPageState._loadHistory.closure#1.closure#3",
            );
            _errors[2] = _message(error);
          });
      } finally {
        if (_valid(2, request, epoch, key))
          setState(() {
            AppLog.instance.trace(
              "lib/pages/listening_page.dart::_ListeningPageState._loadHistory.closure#1.closure#4",
            );
            _busy[2] = false;
          });
      }
    });
  }

  Future<void> _loadFavorites({bool reset = false}) {
    AppLog.instance.trace(
      "lib/pages/listening_page.dart::_ListeningPageState._loadFavorites",
    );
    return AppLog.instance.runWithErrorScope(() async {
      AppLog.instance.trace(
        "lib/pages/listening_page.dart::_ListeningPageState._loadFavorites.closure#1",
      );

      if (!_signedIn || (!reset && (_busy[3] || !_moreFavorites))) return;
      final client = _runtime.client,
          epoch = _accountEpoch,
          request = ++_requests[3];
      final key = client.cacheIdentity, page = reset ? 1 : _favoritePage + 1;
      setState(() {
        AppLog.instance.trace(
          "lib/pages/listening_page.dart::_ListeningPageState._loadFavorites.closure#1.closure#1",
        );

        _busy[3] = true;
        _errors[3] = null;
      });
      try {
        final result = await XmlyExperience(client).favorites(page: page);
        if (!_valid(3, request, epoch, key)) return;
        final known = reset
            ? <String>{}
            : _favorites.map((track) {
                AppLog.instance.trace(
                  "lib/pages/listening_page.dart::_ListeningPageState._loadFavorites.closure#1.closure#2",
                );
                return track.id;
              }).toSet();
        final added = result.items.where((track) {
          AppLog.instance.trace(
            "lib/pages/listening_page.dart::_ListeningPageState._loadFavorites.closure#1.closure#3",
          );
          return known.add(track.id);
        }).toList();
        if (!reset && result.hasMore && added.isEmpty) {
          throw const XmlyException('repeated_page', '收藏列表没有前进，请稍后重试');
        }
        if ((reset ? 0 : _favorites.length) + added.length > 5000) {
          throw const XmlyException('favorite_limit', '已加载 5000 条收藏，请搜索或刷新列表');
        }
        setState(() {
          AppLog.instance.trace(
            "lib/pages/listening_page.dart::_ListeningPageState._loadFavorites.closure#1.closure#4",
          );

          _favorites = [if (!reset) ..._favorites, ...added];
          _favoritePage = page;
          _moreFavorites = result.hasMore;
        });
      } catch (error, stack) {
        _recordListeningError('Favorites load failed', error, stack);
        if (_valid(3, request, epoch, key)) {
          setState(() {
            AppLog.instance.trace(
              "lib/pages/listening_page.dart::_ListeningPageState._loadFavorites.closure#1.closure#5",
            );
            _errors[3] = _message(error);
          });
        }
      } finally {
        if (_valid(3, request, epoch, key)) {
          setState(() {
            AppLog.instance.trace(
              "lib/pages/listening_page.dart::_ListeningPageState._loadFavorites.closure#1.closure#6",
            );
            _busy[3] = false;
          });
          _scheduleFavoriteSearch();
        }
      }
    });
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
        identity == _runtime.player.libraryIdentity;
  }

  Future<void> _changeLibrary(
    Future<void> Function(XmlyExperience api) change,
  ) async {
    AppLog.instance.trace(
      "lib/pages/listening_page.dart::_ListeningPageState._changeLibrary",
    );

    if (!_signedIn) throw const XmlyException('login_required', '请先登录');
    final client = _runtime.client, epoch = _accountEpoch;
    final identity = _runtime.player.libraryIdentity;
    var attempted = false;
    try {
      await _runtime.accounts.runWithAccount(client.identity, (admitted) async {
        AppLog.instance.trace(
          "lib/pages/listening_page.dart::_ListeningPageState._changeLibrary.closure#1",
        );

        if (!_active(epoch, client.cacheIdentity, identity) ||
            !identical(admitted, client) ||
            !client.accountAvailable) {
          throw const XmlyException('account_changed', '账号已变更，请重试');
        }
        attempted = true;
        await change(XmlyExperience(client));
      });
    } catch (error) {
      if (attempted &&
          _active(epoch, client.cacheIdentity, identity) &&
          (error is! XmlyException || !error.definitive)) {
        _runtime.libraryChanged();
      }
      rethrow;
    }
    if (_active(epoch, client.cacheIdentity, identity))
      _runtime.libraryChanged();
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

  void _openAlbum(String id) {
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
      records[track.id] = _ListeningRecord(
        track,
        (raw['position'] as num).toDouble(),
        ((raw['updated_at'] as num) * 1000).toInt(),
      );
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
    String positionLabel = '已听',
    String note = '',
    VoidCallback? editNote,
  }) {
    AppLog.instance.trace(
      "lib/pages/listening_page.dart::_ListeningPageState._trackTile",
    );

    final compact = MediaQuery.sizeOf(context).width < 320;
    final epoch = _accountEpoch, key = _currentKey;
    final identity = _runtime.player.libraryIdentity;
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
                return _runtime.player.addToQueue(track);
              });
              break;
            case 'next':
              _act(() {
                AppLog.instance.trace(
                  "lib/pages/listening_page.dart::_ListeningPageState._trackTile.closure#2.closure#2",
                );
                return _runtime.player.playNext(track);
              });
              break;
            case 'download':
              _act(() {
                AppLog.instance.trace(
                  "lib/pages/listening_page.dart::_ListeningPageState._trackTile.closure#2.closure#3",
                );
                return widget.onDownload([track]);
              });
              break;
            case 'album':
              _openAlbum(track.albumId);
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
    final identity = _runtime.player.libraryIdentity;
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
          return SizedBox(
            width: 72,
            child: InkWell(
              onTap: () {
                AppLog.instance.trace(
                  "lib/pages/listening_page.dart::_ListeningPageState._subscriptionStrip.closure#2.closure#1",
                );

                if (_active(epoch, key, identity)) _openAlbum(item.album.id);
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
        return _trackTile(
          row.track,
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
      footer: _moreUpdates
          ? Padding(
              padding: const EdgeInsets.all(16),
              child: Center(
                child: OutlinedButton(
                  onPressed: _busy[0]
                      ? null
                      : () {
                          AppLog.instance.trace(
                            "lib/pages/listening_page.dart::_ListeningPageState._updatesTab.closure#6",
                          );
                          _loadUpdates();
                        },
                  child: const Text('加载更多更新'),
                ),
              ),
            )
          : null,
    );
  }

  Widget _subscriptionsTab() {
    AppLog.instance.trace(
      "lib/pages/listening_page.dart::_ListeningPageState._subscriptionsTab",
    );

    final epoch = _accountEpoch, key = _currentKey;
    final identity = _runtime.player.libraryIdentity;
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
        return ListTile(
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 12,
            vertical: 2,
          ),
          minTileHeight: 64,
          minVerticalPadding: 4,
          horizontalTitleGap: 12,
          leading: MediaQuery.sizeOf(context).width < 320
              ? null
              : CoverImage(uri: row.album.coverUrl, size: 48),
          title: _itemTitle(row.album.title),
          subtitle: Text(
            row.latestTitle,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: PopupMenuButton<String>(
            tooltip: '专辑操作',
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
                _openAlbum(row.album.id);
              } else if (value == 'unsubscribe' &&
                  await showConfirmationDialog(
                    context,
                    const Text('取消订阅此专辑？'),
                  ) &&
                  _active(epoch, key, identity)) {
                await _act(() {
                  AppLog.instance.trace(
                    "lib/pages/listening_page.dart::_ListeningPageState._subscriptionsTab.closure#3.closure#1.closure#1",
                  );
                  return _changeLibrary((api) {
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
              return const [
                PopupMenuItem(value: 'album', child: Text('查看专辑')),
                PopupMenuItem(value: 'unsubscribe', child: Text('取消订阅')),
              ];
            },
          ),
          onTap: () {
            AppLog.instance.trace(
              "lib/pages/listening_page.dart::_ListeningPageState._subscriptionsTab.closure#3.closure#3",
            );

            if (_active(epoch, key, identity)) _openAlbum(row.album.id);
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
          ? Padding(
              padding: const EdgeInsets.all(16),
              child: Center(
                child: OutlinedButton(
                  onPressed: _busy[1]
                      ? null
                      : () {
                          AppLog.instance.trace(
                            "lib/pages/listening_page.dart::_ListeningPageState._subscriptionsTab.closure#5",
                          );
                          _loadSubscriptions();
                        },
                  child: const Text('加载更多订阅'),
                ),
              ),
            )
          : null,
    );
  }

  Widget _historyTab() {
    AppLog.instance.trace(
      "lib/pages/listening_page.dart::_ListeningPageState._historyTab",
    );

    final rows = _history();
    return _dated<_ListeningRecord>(
      rows,
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
          play: () {
            AppLog.instance.trace(
              "lib/pages/listening_page.dart::_ListeningPageState._historyTab.closure#2.closure#1",
            );
            _act(() {
              AppLog.instance.trace(
                "lib/pages/listening_page.dart::_ListeningPageState._historyTab.closure#2.closure#1.closure#1",
              );
              return row.track.albumId.isEmpty
                  ? _runtime.player.playTrack(row.track)
                  : _runtime.player.playAlbum(
                      row.track.albumId,
                      row.track.id,
                      track: row.track,
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

    final epoch = _accountEpoch, key = _currentKey;
    final identity = _runtime.player.libraryIdentity;
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
          if (index == 1) {
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
          }
          if (index == items.length + 2) {
            return Padding(
              padding: const EdgeInsets.all(16),
              child: Center(
                child: OutlinedButton(
                  onPressed: _busy[3]
                      ? null
                      : () {
                          AppLog.instance.trace(
                            "lib/pages/listening_page.dart::_ListeningPageState._favoritesTab.closure#1.closure#2",
                          );
                          _loadFavorites();
                        },
                  child: const Text('加载更多收藏'),
                ),
              ),
            );
          }
          final track = items[index - 2];
          return _trackTile(
            track,
            play: () {
              AppLog.instance.trace(
                "lib/pages/listening_page.dart::_ListeningPageState._favoritesTab.closure#1.closure#3",
              );
              _act(() {
                AppLog.instance.trace(
                  "lib/pages/listening_page.dart::_ListeningPageState._favoritesTab.closure#1.closure#3.closure#1",
                );
                return track.albumId.isEmpty
                    ? _runtime.player.playTrack(track)
                    : widget.onPlayAlbum(track.albumId, track.id, track: track);
              });
            },
            removeLabel: '取消收藏',
            remove: () async {
              AppLog.instance.trace(
                "lib/pages/listening_page.dart::_ListeningPageState._favoritesTab.closure#1.closure#4",
              );

              if (await showConfirmationDialog(
                    context,
                    const Text('取消收藏此声音？'),
                  ) &&
                  _active(epoch, key, identity)) {
                await _act(() {
                  AppLog.instance.trace(
                    "lib/pages/listening_page.dart::_ListeningPageState._favoritesTab.closure#1.closure#4.closure#1",
                  );
                  return _changeLibrary((api) {
                    AppLog.instance.trace(
                      "lib/pages/listening_page.dart::_ListeningPageState._favoritesTab.closure#1.closure#4.closure#1.closure#1",
                    );
                    return api.setFavorite(track, favorite: false);
                  });
                });
              }
            },
          );
        },
      ),
    );
  }

  Widget _bookmarksTab() {
    AppLog.instance.trace(
      "lib/pages/listening_page.dart::_ListeningPageState._bookmarksTab",
    );

    final epoch = _accountEpoch, key = _currentKey;
    final identity = _runtime.player.libraryIdentity;
    final library =
        (_runtime.storage.state['library'] as Map)[identity] as Map?;
    final bookmarks = library?['bookmarks'] as List? ?? const [];
    final rows = <({int index, Map record, Track track, String note})>[];
    for (var i = 0; i < bookmarks.length; i++) {
      final record = bookmarks[i];
      if (record is! Map || record['track'] is! Map) continue;
      try {
        final track = Track.fromJson(xmlyMap(record['track']));
        final note = record['note'] is String ? record['note'] as String : '';
        if (_matches(track, extra: note)) {
          rows.add((index: i, record: record, track: track, note: note));
        }
      } on XmlyException {
        continue;
      } on FormatException {
        continue;
      }
    }
    return _dated(
      rows,
      (row) {
        AppLog.instance.trace(
          "lib/pages/listening_page.dart::_ListeningPageState._bookmarksTab.closure#1",
        );
        return row.record['createdAt'] is int
            ? row.record['createdAt'] as int
            : 0;
      },
      (row) {
        AppLog.instance.trace(
          "lib/pages/listening_page.dart::_ListeningPageState._bookmarksTab.closure#2",
        );

        final (:index, :record, :track, :note) = row;
        final saved = record['position'];
        final position = saved is num && saved.isFinite && saved >= 0
            ? saved.toDouble()
            : 0.0;
        return _trackTile(
          track,
          position: position,
          positionLabel: '书签位置',
          note: note,
          editNote: () {
            AppLog.instance.trace(
              "lib/pages/listening_page.dart::_ListeningPageState._bookmarksTab.closure#2.closure#1",
            );

            _editBookmarkNote(index, record, epoch, key, identity);
          },
          play: () {
            AppLog.instance.trace(
              "lib/pages/listening_page.dart::_ListeningPageState._bookmarksTab.closure#2.closure#2",
            );
            _act(() {
              AppLog.instance.trace(
                "lib/pages/listening_page.dart::_ListeningPageState._bookmarksTab.closure#2.closure#2.closure#1",
              );
              return _runtime.player.playTrack(
                track,
                resumePosition: position,
                manualPosition: true,
              );
            });
          },
          removeLabel: '删除书签',
          remove: () {
            AppLog.instance.trace(
              "lib/pages/listening_page.dart::_ListeningPageState._bookmarksTab.closure#2.closure#3",
            );
            _removeBookmark(index, record, epoch, key, identity);
          },
        );
      },
      emptyMessage: _query.isEmpty ? '暂无书签' : '没有匹配的书签',
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
        final title = Text(
          '我的收听',
          style: Theme.of(context).textTheme.headlineLarge?.copyWith(
            fontSize: 30,
            fontWeight: FontWeight.w600,
            height: 1.3,
          ),
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
    _tabs.removeListener(_searchTabChanged);
    _tabs.dispose();
    _runtime.removeListener(_runtimeChanged);
    _search.dispose();
    super.dispose();
  }
}

class _ListeningRecord {
  const _ListeningRecord(this.track, this.position, this.updatedAt);
  final Track track;
  final double position;
  final int updatedAt;
}
