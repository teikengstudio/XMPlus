import 'dart:async';

import 'package:flutter/material.dart';

import '../api/xmly_anchor.dart';
import '../common/widgets/app_header.dart';
import '../models/xmly_models.dart';
import '../services/app_log.dart';
import '../services/app_runtime.dart';
import 'anchor_page.dart';
import 'catalogue_page.dart';

class AnchorFollowingPage extends StatefulWidget {
  const AnchorFollowingPage({
    required this.runtime,
    required this.uid,
    this.additionalUids = const [],
    this.onDownload,
    this.onPlayAlbum,
    super.key,
  });
  final AppRuntime runtime;
  final String uid;
  final List<String> additionalUids;
  final TrackDownload? onDownload;
  final AlbumPlayback? onPlayAlbum;

  @override
  State<AnchorFollowingPage> createState() {
    AppLog.instance.trace(
      "lib/pages/anchor_following_page.dart::AnchorFollowingPage.createState",
    );
    return _AnchorFollowingPageState();
  }
}

class _AnchorFollowingPageState extends State<AnchorFollowingPage> {
  final _scroll = ScrollController();
  Completer<void> _cancelled = Completer<void>();
  final _items = <AnchorProfile>[];
  final _accountItems = <String, List<AnchorProfile>>{};
  final _pages = <String, int>{};
  final _finished = <String>{};
  final _failures = <String, bool>{};
  int _generation = 0;
  bool _busy = false, _hasMore = true, _refreshNeeded = false;
  String? _error;

  Set<String> get _uids {
    AppLog.instance.trace(
      "lib/pages/anchor_following_page.dart::_AnchorFollowingPageState._uids.get",
    );
    return {widget.uid, ...widget.additionalUids};
  }

  @override
  void initState() {
    AppLog.instance.trace(
      "lib/pages/anchor_following_page.dart::_AnchorFollowingPageState.initState",
    );

    super.initState();
    _scroll.addListener(_nearEnd);
    unawaited(_load());
  }

  @override
  void didUpdateWidget(covariant AnchorFollowingPage oldWidget) {
    AppLog.instance.trace(
      "lib/pages/anchor_following_page.dart::_AnchorFollowingPageState.didUpdateWidget",
    );

    super.didUpdateWidget(oldWidget);
    if (oldWidget.runtime != widget.runtime ||
        oldWidget.uid != widget.uid ||
        oldWidget.additionalUids.join(',') != widget.additionalUids.join(','))
      unawaited(_refresh());
  }

  @override
  void dispose() {
    AppLog.instance.trace(
      "lib/pages/anchor_following_page.dart::_AnchorFollowingPageState.dispose",
    );

    _generation++;
    _cancelled.complete();
    _scroll.dispose();
    super.dispose();
  }

  bool _current(int generation) {
    AppLog.instance.trace(
      "lib/pages/anchor_following_page.dart::_AnchorFollowingPageState._current",
    );
    return mounted && generation == _generation;
  }

  Future<void> _refresh() async {
    AppLog.instance.trace(
      "lib/pages/anchor_following_page.dart::_AnchorFollowingPageState._refresh",
    );

    _generation++;
    _cancelled.complete();
    _cancelled = Completer<void>();
    setState(() {
      AppLog.instance.trace(
        "lib/pages/anchor_following_page.dart::_AnchorFollowingPageState._refresh.closure#1",
      );

      _items.clear();
      _accountItems.clear();
      _pages.clear();
      _finished.clear();
      _failures.clear();
      _error = null;
      _busy = false;
      _hasMore = true;
      _refreshNeeded = false;
    });
    await _load();
  }

  Future<void> _load() async {
    AppLog.instance.trace(
      "lib/pages/anchor_following_page.dart::_AnchorFollowingPageState._load",
    );

    if (_busy || !_hasMore) return;
    final generation = _generation;
    setState(() {
      AppLog.instance.trace(
        "lib/pages/anchor_following_page.dart::_AnchorFollowingPageState._load.closure#1",
      );
      _busy = true;
      _error = null;
      _refreshNeeded = false;
    });
    final pending = _uids.where((uid) {
      AppLog.instance.trace(
        "lib/pages/anchor_following_page.dart::_AnchorFollowingPageState._load.closure#2",
      );
      return !_finished.contains(uid);
    }).toList();
    final cancelled = _cancelled.future;
    Future<void> loadAccount(String uid) async {
      AppLog.instance.trace(
        "lib/pages/anchor_following_page.dart::_AnchorFollowingPageState._load.loadAccount",
      );

      try {
        final client = widget.runtime.anonymous;
        final next = await client.withReadPolicy(
          () {
            AppLog.instance.trace(
              "lib/pages/anchor_following_page.dart::_AnchorFollowingPageState._load.loadAccount.closure#1",
            );
            return XmlyAnchor(client)
                .following(uid, page: (_pages[uid] ?? 0) + 1);
          },
          rateLimitRetries: 0,
          cancelled: cancelled,
        );
        if (!_current(generation)) return;
        final previous = _accountItems[uid] ?? const <AnchorProfile>[];
        final seen = previous.map((item) {
          AppLog.instance.trace(
            "lib/pages/anchor_following_page.dart::_AnchorFollowingPageState._load.loadAccount.closure#2",
          );
          return item.uid;
        }).toSet();
        final added = next.items.where((item) {
          AppLog.instance.trace(
            "lib/pages/anchor_following_page.dart::_AnchorFollowingPageState._load.loadAccount.closure#3",
          );
          return seen.add(item.uid);
        }).toList();
        if (added.isEmpty && (next.items.isNotEmpty || next.hasMore)) {
          throw const XmlyException('repeated_page', '关注列表未更新');
        }
        _accountItems[uid] = [...previous, ...added];
        _pages[uid] = next.page;
        if (!next.hasMore) _finished.add(uid);
        _failures.remove(uid);
      } catch (error, stack) {
        if (!_current(generation)) return;
        if (!AppLog.instance.errorWasRecorded(error)) {
          AppLog.instance.write(
            AppLogLevel.warning,
            'anchor_following',
            'Loading followed anchors failed',
            error: error,
            stackTrace: stack,
          );
        }
        _failures[uid] =
            error is XmlyException && error.code == 'repeated_page';
      }
      if (!_current(generation)) return;
      setState(() {
        AppLog.instance.trace(
          "lib/pages/anchor_following_page.dart::_AnchorFollowingPageState._load.loadAccount.closure#4",
        );

        final merged = <String, AnchorProfile>{};
        for (final account in _uids) {
          for (final anchor
              in _accountItems[account] ?? const <AnchorProfile>[]) {
            merged.putIfAbsent(anchor.uid, () {
              AppLog.instance.trace(
                "lib/pages/anchor_following_page.dart::_AnchorFollowingPageState._load.loadAccount.closure#4.closure#1",
              );
              return anchor;
            });
          }
        }
        _items
          ..clear()
          ..addAll(merged.values);
        _hasMore = _uids.any((uid) {
          AppLog.instance.trace(
            "lib/pages/anchor_following_page.dart::_AnchorFollowingPageState._load.loadAccount.closure#4.closure#2",
          );
          return !_finished.contains(uid);
        });
        _refreshNeeded = _failures.values.any((repeated) {
          AppLog.instance.trace(
            "lib/pages/anchor_following_page.dart::_AnchorFollowingPageState._load.loadAccount.closure#4.closure#3",
          );
          return repeated;
        });
        _error = _failures.isEmpty
            ? null
            : _refreshNeeded
            ? '列表未更新，请刷新'
            : _accountItems.isEmpty
            ? '关注列表加载失败'
            : '部分账号加载失败';
      });
    }

    try {
      for (
        var offset = 0;
        offset < pending.length && _current(generation);
        offset += 3
      ) {
        await Future.wait(pending.skip(offset).take(3).map(loadAccount));
      }
    } finally {
      if (_current(generation))
        setState(() {
          AppLog.instance.trace(
            "lib/pages/anchor_following_page.dart::_AnchorFollowingPageState._load.closure#3",
          );
          _busy = false;
        });
    }
  }

  void _nearEnd() {
    AppLog.instance.trace(
      "lib/pages/anchor_following_page.dart::_AnchorFollowingPageState._nearEnd",
    );

    if (_scroll.hasClients &&
        _scroll.position.extentAfter < 320 &&
        _error == null)
      unawaited(_load());
  }

  void _open(AnchorProfile anchor) {
    AppLog.instance.trace(
      "lib/pages/anchor_following_page.dart::_AnchorFollowingPageState._open",
    );

    Navigator.of(context).push(
      MaterialPageRoute<void>(
        settings: const RouteSettings(name: AnchorPage.routeName),
        builder: (_) {
          AppLog.instance.trace(
            "lib/pages/anchor_following_page.dart::_AnchorFollowingPageState._open.closure#1",
          );
          return AnchorPage(
            runtime: widget.runtime,
            uid: anchor.uid,
            initialName: anchor.nickname,
            onDownload: widget.onDownload,
            onPlayAlbum: widget.onPlayAlbum,
          );
        },
      ),
    );
  }

  Widget _footer() {
    AppLog.instance.trace(
      "lib/pages/anchor_following_page.dart::_AnchorFollowingPageState._footer",
    );

    if (_busy)
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Center(child: CircularProgressIndicator()),
      );
    if (_error != null)
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            Text(_error!),
            TextButton(
              onPressed: _refreshNeeded ? _refresh : _load,
              child: Text(_refreshNeeded ? '刷新' : '重试'),
            ),
          ],
        ),
      );
    if (_items.isEmpty)
      return const Padding(
        padding: EdgeInsets.all(32),
        child: Center(child: Text('暂无关注的主播')),
      );
    if (_hasMore)
      return Center(
        child: TextButton(onPressed: _load, child: const Text('加载更多')),
      );
    return const SizedBox(height: 24);
  }

  @override
  Widget build(BuildContext context) {
    AppLog.instance.trace(
      "lib/pages/anchor_following_page.dart::_AnchorFollowingPageState.build",
    );

    return Scaffold(
      appBar: AppHeader(
        title: const Text('关注的主播'),
        actions: [
          IconButton(
            tooltip: '刷新',
            onPressed: _refresh,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 960),
            child: RefreshIndicator(
              onRefresh: _refresh,
              child: Scrollbar(
                controller: _scroll,
                child: ListView.builder(
                  controller: _scroll,
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.all(16),
                  itemCount: _items.length + 1,
                  itemBuilder: (context, index) {
                    AppLog.instance.trace(
                      "lib/pages/anchor_following_page.dart::_AnchorFollowingPageState.build.closure#1",
                    );

                    if (index == _items.length) return _footer();
                    final anchor = _items[index];
                    final details = [
                      if (anchor.albums != null) '${anchor.albums} 个专辑',
                      if (anchor.tracks != null) '${anchor.tracks} 个声音',
                    ];
                    return ListTile(
                      key: ValueKey(anchor.uid),
                      leading: ClipOval(
                        child: CoverImage(uri: anchor.avatar, size: 48),
                      ),
                      title: Text(
                        anchor.nickname,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        details.isEmpty ? anchor.intro : details.join(' · '),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: const Icon(Icons.chevron_right, size: 20),
                      onTap: () {
                        AppLog.instance.trace(
                          "lib/pages/anchor_following_page.dart::_AnchorFollowingPageState.build.closure#1.closure#1",
                        );
                        _open(anchor);
                      },
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
