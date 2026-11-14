import 'dart:async';

import 'package:flutter/material.dart';

import '../common/widgets/app_scrollbar.dart';
import '../api/xmly_browse.dart';
import '../api/xmly_client.dart';
import '../api/xmly_experience.dart';
import '../common/widgets/app_header.dart';
import '../common/widgets/app_tab_button.dart';
import '../models/xmly_models.dart';
import '../services/app_log.dart';
import '../services/app_runtime.dart';
import 'home_album_section.dart';

class HomeBrowsePage extends StatefulWidget {
  const HomeBrowsePage({
    required this.runtime,
    required this.onOpenAlbum,
    this.categoryId = 0,
    super.key,
  });

  final AppRuntime runtime;
  final ValueChanged<Album> onOpenAlbum;
  final int categoryId;

  @override
  State<HomeBrowsePage> createState() {
    AppLog.instance.trace(
      "lib/pages/home_browse_page.dart::HomeBrowsePage.createState",
    );
    return _HomeBrowsePageState();
  }
}

class _HomeBrowsePageState extends State<HomeBrowsePage> {
  final _scroll = ScrollController();
  late XmlyClient _client;
  Completer<void>? _cancel;
  List<BrowseCategory> _categories = const [];
  List<Album> _albums = const [];
  Map<String, HomeAlbumStats> _stats = const {};
  int _category = 0, _sort = 1, _page = 0, _generation = 0;
  bool _busy = false, _hasMore = true;
  String? _error;

  @override
  void initState() {
    AppLog.instance.trace(
      "lib/pages/home_browse_page.dart::_HomeBrowsePageState.initState",
    );

    super.initState();
    _client = widget.runtime.client;
    _category = widget.categoryId;
    widget.runtime.addListener(_accountChanged);
    _load(reset: true);
  }

  @override
  void didUpdateWidget(covariant HomeBrowsePage oldWidget) {
    AppLog.instance.trace(
      "lib/pages/home_browse_page.dart::_HomeBrowsePageState.didUpdateWidget",
    );

    super.didUpdateWidget(oldWidget);
    if (oldWidget.runtime != widget.runtime) {
      oldWidget.runtime.removeListener(_accountChanged);
      widget.runtime.addListener(_accountChanged);
      _accountChanged();
    }
  }

  void _accountChanged() {
    AppLog.instance.trace(
      "lib/pages/home_browse_page.dart::_HomeBrowsePageState._accountChanged",
    );

    final client = widget.runtime.client;
    if (identical(client, _client)) return;
    _client = client;
    _load(reset: true);
  }

  bool _active(int generation, XmlyClient client) {
    AppLog.instance.trace(
      "lib/pages/home_browse_page.dart::_HomeBrowsePageState._active",
    );
    return mounted && generation == _generation && identical(client, _client);
  }

  Future<void> _load({bool reset = false}) async {
    AppLog.instance.trace(
      "lib/pages/home_browse_page.dart::_HomeBrowsePageState._load",
    );

    if (!reset && (_busy || !_hasMore)) return;
    if (reset) {
      _cancel?.complete();
      _cancel = Completer<void>();
      _generation++;
    }
    final generation = _generation;
    final client = _client;
    final sort = _sort;
    final page = reset ? 1 : _page + 1;
    setState(() {
      AppLog.instance.trace(
        "lib/pages/home_browse_page.dart::_HomeBrowsePageState._load.closure#1",
      );

      _busy = true;
      _error = null;
      if (reset) {
        _albums = const [];
        _stats = const {};
        _page = 0;
        _hasMore = true;
      }
    });
    try {
      await client.withReadPolicy(
        () async {
          AppLog.instance.trace(
            "lib/pages/home_browse_page.dart::_HomeBrowsePageState._load.closure#2",
          );

          final api = XmlyBrowse(client);
          if (_categories.isEmpty) {
            final categories = await api.categories();
            if (!_active(generation, client)) return;
            setState(() {
              AppLog.instance.trace(
                "lib/pages/home_browse_page.dart::_HomeBrowsePageState._load.closure#2.closure#1",
              );

              _categories = categories;
              if (!_categories.any((item) {
                AppLog.instance.trace(
                  "lib/pages/home_browse_page.dart::_HomeBrowsePageState._load.closure#2.closure#1.closure#1",
                );
                return item.id == _category;
              }))
                _category = 0;
            });
          }
          final result = await api.albums(
            categoryId: _category,
            sort: sort,
            page: page,
          );
          if (!_active(generation, client)) return;
          final seen = _albums.map((album) {
            AppLog.instance.trace(
              "lib/pages/home_browse_page.dart::_HomeBrowsePageState._load.closure#2.closure#2",
            );
            return album.id;
          }).toSet();
          final additions = result.section.albums.where((album) {
            AppLog.instance.trace(
              "lib/pages/home_browse_page.dart::_HomeBrowsePageState._load.closure#2.closure#3",
            );
            return seen.add(album.id);
          }).toList();
          if (additions.isEmpty &&
              (result.hasMore || result.section.albums.isNotEmpty)) {
            throw const XmlyException('repeated_page', '列表没有更新，请刷新后重试');
          }
          setState(() {
            AppLog.instance.trace(
              "lib/pages/home_browse_page.dart::_HomeBrowsePageState._load.closure#2.closure#4",
            );

            _albums = [..._albums, ...additions];
            _stats = {..._stats, ...result.section.stats};
            _page = result.page;
            _hasMore = result.hasMore;
            _busy = false;
          });
        },
        rateLimitRetries: 0,
        cancelled: _cancel!.future,
      );
    } catch (error, stack) {
      if (!_active(generation, client)) return;
      AppLog.instance.write(
        AppLogLevel.warning,
        'home_browse',
        'Album browse failed',
        error: error,
        stackTrace: stack,
      );
      setState(() {
        AppLog.instance.trace(
          "lib/pages/home_browse_page.dart::_HomeBrowsePageState._load.closure#3",
        );

        _busy = false;
        _error = error is XmlyException ? error.message : '加载失败，请稍后重试';
      });
    }
  }

  void _select({int? category, int? sort}) {
    AppLog.instance.trace(
      "lib/pages/home_browse_page.dart::_HomeBrowsePageState._select",
    );

    final nextCategory = category ?? _category;
    final nextSort = sort ?? _sort;
    if (nextCategory == _category && nextSort == _sort) return;
    _category = nextCategory;
    _sort = nextSort;
    if (_scroll.hasClients) _scroll.jumpTo(0);
    _load(reset: true);
  }

  @override
  void dispose() {
    AppLog.instance.trace(
      "lib/pages/home_browse_page.dart::_HomeBrowsePageState.dispose",
    );

    _generation++;
    _cancel?.complete();
    widget.runtime.removeListener(_accountChanged);
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    AppLog.instance.trace(
      "lib/pages/home_browse_page.dart::_HomeBrowsePageState.build",
    );

    return Scaffold(
      appBar: AppHeader(
        title: const Text('全部专辑'),
        actions: [
          IconButton(
            tooltip: '刷新',
            onPressed: () {
              AppLog.instance.trace(
                "lib/pages/home_browse_page.dart::_HomeBrowsePageState.build.closure#1",
              );
              _load(reset: true);
            },
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: Column(
        children: [
          if (_categories.isNotEmpty)
            AppTabStrip(
              children: [
                AppTabButton(
                  key: const ValueKey('browseCategory0'),
                  label: '全部',
                  selected: _category == 0,
                  onPressed: () {
                    AppLog.instance.trace(
                      "lib/pages/home_browse_page.dart::_HomeBrowsePageState.build.closure#2",
                    );
                    return _select(category: 0);
                  },
                ),
                for (final category in _categories)
                  AppTabButton(
                    key: ValueKey('browseCategory${category.id}'),
                    label: category.title,
                    selected: _category == category.id,
                    onPressed: () {
                      AppLog.instance.trace(
                        "lib/pages/home_browse_page.dart::_HomeBrowsePageState.build.closure#3",
                      );
                      return _select(category: category.id);
                    },
                  ),
              ],
            ),
          AppTabStrip(
            children: [
              for (final sort in const {1: '综合', 2: '最近更新', 3: '最多播放'}.entries)
                AppTabButton(
                  key: ValueKey('browseSort${sort.key}'),
                  label: sort.value,
                  selected: _sort == sort.key,
                  onPressed: () {
                    AppLog.instance.trace(
                      "lib/pages/home_browse_page.dart::_HomeBrowsePageState.build.closure#4",
                    );
                    return _select(sort: sort.key);
                  },
                ),
            ],
          ),
          SizedBox(
            height: 2,
            child: _busy
                ? const LinearProgressIndicator(semanticsLabel: '正在加载专辑')
                : null,
          ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: () {
                AppLog.instance.trace(
                  "lib/pages/home_browse_page.dart::_HomeBrowsePageState.build.closure#5",
                );
                return _load(reset: true);
              },
              child: AppScrollbar(
                controller: _scroll,
                child: CustomScrollView(
                  controller: _scroll,
                  physics: const AlwaysScrollableScrollPhysics(),
                  slivers: [
                    if (_albums.isNotEmpty)
                      SliverPadding(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                        sliver: HomeAlbumSection(
                          section: HomeSection(
                            title: '专辑',
                            albums: _albums,
                            stats: _stats,
                          ),
                          showTitle: false,
                          onOpenAlbum: widget.onOpenAlbum,
                        ),
                      ),
                    if (_error != null)
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.all(20),
                          child: Column(
                            children: [
                              Text(_error!, textAlign: TextAlign.center),
                              const SizedBox(height: 8),
                              OutlinedButton(
                                key: const ValueKey('browseRetry'),
                                onPressed: () {
                                  AppLog.instance.trace(
                                    "lib/pages/home_browse_page.dart::_HomeBrowsePageState.build.closure#6",
                                  );
                                  _load(reset: _page == 0);
                                },
                                child: const Text('重试'),
                              ),
                            ],
                          ),
                        ),
                      ),
                    if (!_busy && _error == null && _albums.isEmpty)
                      const SliverFillRemaining(
                        hasScrollBody: false,
                        child: Center(child: Text('这个分类暂时没有专辑')),
                      ),
                    if (_albums.isNotEmpty && _error == null)
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                          child: Center(
                            child: _hasMore
                                ? OutlinedButton(
                                    key: const ValueKey('browseMore'),
                                    onPressed: _busy ? null : _load,
                                    child: Text(_busy ? '加载中' : '加载更多'),
                                  )
                                : Text(
                                    '已显示全部',
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodySmall,
                                  ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
