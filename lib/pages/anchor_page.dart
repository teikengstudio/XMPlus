import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api/xmly_anchor.dart';
import '../common/widgets/adaptive_text.dart';
import '../common/widgets/app_header.dart';
import '../common/widgets/logged_network_image.dart';
import '../models/xmly_models.dart';
import '../services/app_log.dart';
import '../services/app_runtime.dart';
import 'catalogue_page.dart';

class AnchorPage extends StatefulWidget {
  const AnchorPage({
    required this.runtime,
    this.uid,
    this.albumId,
    this.trackId,
    this.initialName = '',
    this.onDownload,
    this.onPlayAlbum,
    super.key,
  }) : assert(uid != null || albumId != null || trackId != null);

  static const routeName = '/anchor';
  final AppRuntime runtime;
  final String? uid, albumId, trackId;
  final String initialName;
  final TrackDownload? onDownload;
  final AlbumPlayback? onPlayAlbum;

  @override
  State<AnchorPage> createState() {
    AppLog.instance.trace("lib/pages/anchor_page.dart::AnchorPage.createState");

    return _AnchorPageState();
  }
}

class _AnchorListing<T> {
  List<T> items = [];
  int page = 0;
  int? total;
  bool busy = false, hasMore = true, refreshNeeded = false;
  String? error;
}

class _AnchorPageState extends State<AnchorPage>
    with SingleTickerProviderStateMixin {
  final _scroll = ScrollController();
  late final TabController _tabs;
  Completer<void> _cancelled = Completer<void>();
  int _generation = 0, _selected = 0, _playRequest = 0;
  String? _uid, _resolveError, _profileError;
  AnchorProfile? _profile;
  bool _resolving = true, _profileBusy = false;
  bool _openingFollow = false;
  _AnchorListing<AnchorAlbum> _albums = _AnchorListing();
  _AnchorListing<Track> _tracks = _AnchorListing();

  @override
  void initState() {
    AppLog.instance.trace(
      "lib/pages/anchor_page.dart::_AnchorPageState.initState",
    );

    super.initState();
    _tabs = TabController(length: 2, vsync: this)..addListener(_selectTab);
    _scroll.addListener(_nearEnd);
    _refresh();
  }

  @override
  void didUpdateWidget(covariant AnchorPage oldWidget) {
    AppLog.instance.trace(
      "lib/pages/anchor_page.dart::_AnchorPageState.didUpdateWidget",
    );

    super.didUpdateWidget(oldWidget);
    if (oldWidget.runtime != widget.runtime ||
        oldWidget.uid != widget.uid ||
        oldWidget.albumId != widget.albumId ||
        oldWidget.trackId != widget.trackId) {
      _refresh();
    }
  }

  @override
  void dispose() {
    AppLog.instance.trace(
      "lib/pages/anchor_page.dart::_AnchorPageState.dispose",
    );

    _generation++;
    _playRequest++;
    _cancelled.complete();
    _tabs.dispose();
    _scroll.dispose();
    super.dispose();
  }

  bool _current(int generation) {
    AppLog.instance.trace(
      "lib/pages/anchor_page.dart::_AnchorPageState._current",
    );

    return mounted && generation == _generation;
  }

  Future<T> _read<T>(Future<T> Function(XmlyAnchor) action) {
    AppLog.instance.trace("lib/pages/anchor_page.dart::_AnchorPageState._read");

    final client = widget.runtime.anonymous;
    return client.withReadPolicy(
      () {
        AppLog.instance.trace(
          "lib/pages/anchor_page.dart::_AnchorPageState._read.closure#1",
        );
        return action(XmlyAnchor(client));
      },
      rateLimitRetries: 0,
      cancelled: _cancelled.future,
    );
  }

  void _record(String operation, Object error, StackTrace stack) {
    AppLog.instance.trace(
      "lib/pages/anchor_page.dart::_AnchorPageState._record",
    );

    if (AppLog.instance.errorWasRecorded(error)) return;
    AppLog.instance.write(
      AppLogLevel.error,
      'anchor_page',
      operation,
      error: error,
      stackTrace: stack,
      promptUser: false,
    );
  }

  Future<void> _refresh() async {
    AppLog.instance.trace(
      "lib/pages/anchor_page.dart::_AnchorPageState._refresh",
    );

    final generation = ++_generation;
    _cancelled.complete();
    _cancelled = Completer<void>();
    setState(() {
      AppLog.instance.trace(
        "lib/pages/anchor_page.dart::_AnchorPageState._refresh.closure#1",
      );

      _uid = null;
      _profile = null;
      _resolveError = _profileError = null;
      _resolving = true;
      _profileBusy = false;
      _albums = _AnchorListing();
      _tracks = _AnchorListing();
    });
    try {
      final uid = widget.uid != null
          ? xmlyIdentifier(widget.uid!)
          : await _read((api) {
              AppLog.instance.trace(
                "lib/pages/anchor_page.dart::_AnchorPageState._refresh.closure#2",
              );

              if (widget.trackId != null)
                return api.trackAnchor(widget.trackId!);
              return api.albumAnchor(widget.albumId!);
            });
      if (!_current(generation)) return;
      setState(() {
        AppLog.instance.trace(
          "lib/pages/anchor_page.dart::_AnchorPageState._refresh.closure#3",
        );
        _uid = uid;
        _resolving = false;
      });
      await Future.wait([_loadProfile(), _loadSelected()]);
    } catch (error, stack) {
      if (!_current(generation)) return;
      _record('Resolving anchor failed', error, stack);
      setState(() {
        AppLog.instance.trace(
          "lib/pages/anchor_page.dart::_AnchorPageState._refresh.closure#4",
        );

        _resolving = _profileBusy = false;
        _resolveError = '主播资料加载失败';
      });
    }
  }

  Future<void> _loadProfile() async {
    AppLog.instance.trace(
      "lib/pages/anchor_page.dart::_AnchorPageState._loadProfile",
    );

    final generation = _generation;
    final uid = _uid;
    if (uid == null || _profileBusy) return;
    setState(() {
      AppLog.instance.trace(
        "lib/pages/anchor_page.dart::_AnchorPageState._loadProfile.closure#1",
      );
      _profileBusy = true;
      _profileError = null;
    });
    try {
      final profile = await _read((api) {
        AppLog.instance.trace(
          "lib/pages/anchor_page.dart::_AnchorPageState._loadProfile.closure#2",
        );
        return api.profile(uid);
      });
      if (!_current(generation)) return;
      setState(() {
        AppLog.instance.trace(
          "lib/pages/anchor_page.dart::_AnchorPageState._loadProfile.closure#3",
        );
        _profile = profile;
      });
    } catch (error, stack) {
      if (!_current(generation)) return;
      _record('Loading anchor profile failed', error, stack);
      setState(() {
        AppLog.instance.trace(
          "lib/pages/anchor_page.dart::_AnchorPageState._loadProfile.closure#4",
        );
        _profileError = '主播资料加载失败';
      });
    } finally {
      if (_current(generation))
        setState(() {
          AppLog.instance.trace(
            "lib/pages/anchor_page.dart::_AnchorPageState._loadProfile.closure#5",
          );
          _profileBusy = false;
        });
    }
  }

  Future<void> _loadSelected() {
    AppLog.instance.trace(
      "lib/pages/anchor_page.dart::_AnchorPageState._loadSelected",
    );

    if (_selected == 0) {
      return _load<AnchorAlbum>(
        _albums,
        (api, uid, page) {
          AppLog.instance.trace(
            "lib/pages/anchor_page.dart::_AnchorPageState._loadSelected.closure#1",
          );
          return api.albums(uid, page: page);
        },
        (album) {
          AppLog.instance.trace(
            "lib/pages/anchor_page.dart::_AnchorPageState._loadSelected.closure#2",
          );
          return album.album.id;
        },
      );
    }
    return _load<Track>(
      _tracks,
      (api, uid, page) {
        AppLog.instance.trace(
          "lib/pages/anchor_page.dart::_AnchorPageState._loadSelected.closure#3",
        );
        return api.tracks(uid, page: page);
      },
      (track) {
        AppLog.instance.trace(
          "lib/pages/anchor_page.dart::_AnchorPageState._loadSelected.closure#4",
        );
        return track.id;
      },
    );
  }

  Future<void> _load<T>(
    _AnchorListing<T> listing,
    Future<AnchorContentPage<T>> Function(XmlyAnchor, String, int) fetch,
    String Function(T) id,
  ) async {
    AppLog.instance.trace("lib/pages/anchor_page.dart::_AnchorPageState._load");

    final generation = _generation;
    final uid = _uid;
    if (uid == null || listing.busy || !listing.hasMore) return;
    setState(() {
      AppLog.instance.trace(
        "lib/pages/anchor_page.dart::_AnchorPageState._load.closure#1",
      );

      listing.busy = true;
      listing.error = null;
      listing.refreshNeeded = false;
    });
    try {
      final next = await _read((api) {
        AppLog.instance.trace(
          "lib/pages/anchor_page.dart::_AnchorPageState._load.closure#2",
        );
        return fetch(api, uid, listing.page + 1);
      });
      if (!_current(generation)) return;
      final seen = listing.items.map(id).toSet();
      final added = <T>[];
      for (final item in next.items) {
        if (seen.add(id(item))) added.add(item);
      }
      if (added.isEmpty && (next.items.isNotEmpty || next.hasMore)) {
        throw const XmlyException('repeated_page', '列表分页未前进，请刷新后重试');
      }
      setState(() {
        AppLog.instance.trace(
          "lib/pages/anchor_page.dart::_AnchorPageState._load.closure#3",
        );

        listing.items = [...listing.items, ...added];
        listing.page = next.page;
        listing.total = next.total;
        listing.hasMore = next.hasMore;
      });
    } catch (error, stack) {
      if (!_current(generation)) return;
      _record('Loading anchor content failed', error, stack);
      setState(() {
        AppLog.instance.trace(
          "lib/pages/anchor_page.dart::_AnchorPageState._load.closure#4",
        );

        listing.refreshNeeded =
            error is XmlyException && error.code == 'repeated_page';
        listing.error = listing.refreshNeeded ? '列表未更新，请刷新' : '列表加载失败';
      });
    } finally {
      if (_current(generation))
        setState(() {
          AppLog.instance.trace(
            "lib/pages/anchor_page.dart::_AnchorPageState._load.closure#5",
          );
          listing.busy = false;
        });
    }
  }

  void _selectTab() {
    AppLog.instance.trace(
      "lib/pages/anchor_page.dart::_AnchorPageState._selectTab",
    );

    if (_tabs.index == _selected) return;
    setState(() {
      AppLog.instance.trace(
        "lib/pages/anchor_page.dart::_AnchorPageState._selectTab.closure#1",
      );
      _selected = _tabs.index;
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
    final loaded = _selected == 0 ? _albums.page : _tracks.page;
    if (loaded == 0) _loadSelected();
  }

  void _nearEnd() {
    AppLog.instance.trace(
      "lib/pages/anchor_page.dart::_AnchorPageState._nearEnd",
    );

    if (!_scroll.hasClients || _scroll.position.extentAfter > 320) return;
    final error = _selected == 0 ? _albums.error : _tracks.error;
    if (error == null) _loadSelected();
  }

  void _openAlbum(Album album) {
    AppLog.instance.trace(
      "lib/pages/anchor_page.dart::_AnchorPageState._openAlbum",
    );

    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) {
          AppLog.instance.trace(
            "lib/pages/anchor_page.dart::_AnchorPageState._openAlbum.closure#1",
          );

          return AlbumPageView(
            runtime: widget.runtime,
            albumId: album.id,
            onDownload: widget.onDownload,
            onPlayAlbum: widget.onPlayAlbum,
          );
        },
      ),
    );
  }

  Future<void> _play(Track track) async {
    AppLog.instance.trace("lib/pages/anchor_page.dart::_AnchorPageState._play");

    final request = ++_playRequest;
    try {
      if (track.albumId.isEmpty) {
        await widget.runtime.player.playTrack(track);
      } else {
        await (widget.onPlayAlbum ?? widget.runtime.player.playAlbum)(
          track.albumId,
          track.id,
          track: track,
        );
      }
    } catch (error, stack) {
      _record('Playing anchor track failed', error, stack);
      if (mounted && request == _playRequest) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('暂时无法播放，请重试')));
      }
    }
  }

  String _count(int value) {
    AppLog.instance.trace(
      "lib/pages/anchor_page.dart::_AnchorPageState._count",
    );

    if (value >= 100000000) return '${(value / 100000000).toStringAsFixed(1)}亿';
    if (value >= 10000) return '${(value / 10000).toStringAsFixed(1)}万';
    return '$value';
  }

  Future<void> _openFollowPage() async {
    AppLog.instance.trace(
      "lib/pages/anchor_page.dart::_AnchorPageState._openFollowPage",
    );

    final uid = _uid;
    if (uid == null || _openingFollow) return;
    final generation = _generation;
    setState(() {
      AppLog.instance.trace(
        "lib/pages/anchor_page.dart::_AnchorPageState._openFollowPage.closure#1",
      );
      _openingFollow = true;
    });
    try {
      if (!await launchUrl(
        Uri.https('www.ximalaya.com', '/zhubo/$uid/'),
        mode: LaunchMode.externalApplication,
      )) {
        throw StateError('The official anchor page could not be opened');
      }
    } catch (error, stack) {
      _record('Opening official anchor page failed', error, stack);
      if (_current(generation))
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('网页打开失败，请重试')));
    } finally {
      if (mounted)
        setState(() {
          AppLog.instance.trace(
            "lib/pages/anchor_page.dart::_AnchorPageState._openFollowPage.closure#2",
          );
          _openingFollow = false;
        });
    }
  }

  Widget _followButton() {
    AppLog.instance.trace(
      "lib/pages/anchor_page.dart::_AnchorPageState._followButton",
    );

    return Tooltip(
      message: '在喜马拉雅关注',
      child: OutlinedButton.icon(
        onPressed: _openingFollow ? null : _openFollowPage,
        icon: _openingFollow
            ? const SizedBox.square(
                dimension: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.add, size: 18),
        label: const Text('去关注'),
      ),
    );
  }

  Widget _avatar(double size) {
    AppLog.instance.trace(
      "lib/pages/anchor_page.dart::_AnchorPageState._avatar",
    );

    final colors = Theme.of(context).colorScheme;
    final fallback = ColoredBox(
      color: colors.surfaceContainerHighest,
      child: Icon(
        Icons.person_outline,
        size: size * .45,
        color: colors.onSurfaceVariant,
      ),
    );
    final uri = _profile?.avatar;
    return SizedBox.square(
      dimension: size,
      child: ClipOval(
        child: uri == null
            ? fallback
            : Image(
                image: LoggedNetworkImage(uri.toString()),
                fit: BoxFit.cover,
                excludeFromSemantics: true,
                errorBuilder: (_, __, ___) {
                  AppLog.instance.trace(
                    "lib/pages/anchor_page.dart::_AnchorPageState._avatar.closure#1",
                  );
                  return fallback;
                },
              ),
      ),
    );
  }

  Widget _stat(int value, String label) {
    AppLog.instance.trace("lib/pages/anchor_page.dart::_AnchorPageState._stat");

    final theme = Theme.of(context);
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: _count(value),
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          TextSpan(
            text: '  $label',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Widget _statistics() {
    AppLog.instance.trace(
      "lib/pages/anchor_page.dart::_AnchorPageState._statistics",
    );

    final profile = _profile;
    return Wrap(
      spacing: 24,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (profile?.following case final count?) _stat(count, '关注'),
        if (profile?.fans case final count?) _stat(count, '粉丝'),
      ],
    );
  }

  Widget _description() {
    AppLog.instance.trace(
      "lib/pages/anchor_page.dart::_AnchorPageState._description",
    );

    final profile = _profile;
    final theme = Theme.of(context);
    final text = profile == null
        ? ''
        : profile.verified && profile.verification.isNotEmpty
        ? '认证信息：${profile.verification}'
        : profile.intro.isNotEmpty
        ? profile.intro
        : profile.location;
    if (text.isEmpty) return const SizedBox.shrink();
    return Text(
      text,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: theme.textTheme.bodyMedium?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
        height: 1.5,
      ),
    );
  }

  Widget _header() {
    AppLog.instance.trace(
      "lib/pages/anchor_page.dart::_AnchorPageState._header",
    );

    final profile = _profile;
    final theme = Theme.of(context);
    final name =
        profile?.nickname ??
        (widget.initialName.isEmpty ? '主播' : widget.initialName);
    return LayoutBuilder(
      builder: (context, constraints) {
        AppLog.instance.trace(
          "lib/pages/anchor_page.dart::_AnchorPageState._header.closure#1",
        );

        final scale = MediaQuery.textScalerOf(context).scale(16) / 16;
        final wide = constraints.maxWidth >= 640 * scale;
        final badges = <Widget>[
          if (profile?.verified == true)
            Icon(
              Icons.verified_rounded,
              size: 20,
              color: theme.brightness == Brightness.dark
                  ? const Color(0xffffca75)
                  : const Color(0xffd79832),
              semanticLabel: '已认证',
            ),
          if (profile?.level case final level?)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(
                color: theme.colorScheme.tertiaryContainer.withValues(
                  alpha: .6,
                ),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                'Lv$level',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onTertiaryContainer,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
        ];
        return Padding(
          padding: EdgeInsets.symmetric(vertical: wide ? 24 : 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _avatar(wide ? 112 : 80),
                  SizedBox(width: wide ? 28 : 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          name,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.headlineSmall?.copyWith(
                            fontSize: wide ? 28 : 22,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        if (badges.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: Wrap(
                              spacing: 8,
                              runSpacing: 6,
                              children: badges,
                            ),
                          ),
                        if (wide) ...[
                          const SizedBox(height: 12),
                          _statistics(),
                          const SizedBox(height: 12),
                          _description(),
                        ],
                        if (!wide && profile != null) ...[
                          const SizedBox(height: 8),
                          _followButton(),
                        ],
                      ],
                    ),
                  ),
                  if (wide && profile != null) ...[
                    const SizedBox(width: 24),
                    _followButton(),
                  ],
                ],
              ),
              if (!wide) ...[
                const SizedBox(height: 16),
                _statistics(),
                const SizedBox(height: 10),
                _description(),
              ],
              if (_profileBusy)
                const Padding(
                  padding: EdgeInsets.only(top: 12),
                  child: LinearProgressIndicator(minHeight: 2),
                ),
              if (_profileError != null) _retry(_profileError!, _loadProfile),
            ],
          ),
        );
      },
    );
  }

  Widget _retry(
    String message,
    Future<void> Function() action, {
    String label = '重试',
  }) {
    AppLog.instance.trace(
      "lib/pages/anchor_page.dart::_AnchorPageState._retry",
    );

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(message, textAlign: TextAlign.center),
          TextButton(onPressed: action, child: Text(label)),
        ],
      ),
    );
  }

  Widget _footer<T>(_AnchorListing<T> listing, String empty) {
    AppLog.instance.trace(
      "lib/pages/anchor_page.dart::_AnchorPageState._footer",
    );

    if (listing.busy)
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Center(child: CircularProgressIndicator()),
      );
    if (listing.error != null)
      return Center(
        child: _retry(
          listing.error!,
          listing.refreshNeeded ? _refresh : _loadSelected,
          label: listing.refreshNeeded ? '刷新' : '重试',
        ),
      );
    if (listing.page > 0 && listing.items.isEmpty)
      return Padding(
        padding: const EdgeInsets.all(32),
        child: Center(child: Text(empty)),
      );
    if (listing.hasMore)
      return Center(
        child: TextButton(onPressed: _loadSelected, child: const Text('加载更多')),
      );
    return const SizedBox(height: 24);
  }

  Widget _albumList() {
    AppLog.instance.trace(
      "lib/pages/anchor_page.dart::_AnchorPageState._albumList",
    );

    return SliverLayoutBuilder(
      builder: (context, constraints) {
        AppLog.instance.trace(
          "lib/pages/anchor_page.dart::_AnchorPageState._albumList.closure#1",
        );

        final scaler = MediaQuery.textScalerOf(context);
        final scale = math.max(1.0, scaler.scale(16) / 16);
        final width = constraints.crossAxisExtent;
        final columns = width >= 880 * scale ? 2 : 1;
        final coverSize = width >= 640 ? 112.0 : 88.0;
        final titleSize = width >= 640 ? 18.0 : 16.0;
        final textHeight =
            (scaler.scale(titleSize) * 1.4).ceilToDouble() * 2 +
            (scaler.scale(14) * 1.5).ceilToDouble() +
            (scaler.scale(12) * 1.4).ceilToDouble() +
            20;
        return SliverGrid.builder(
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            crossAxisSpacing: 28,
            mainAxisSpacing: width >= 640 ? 18 : 10,
            mainAxisExtent: math.max(coverSize, textHeight) + 16,
          ),
          itemCount: _albums.items.length,
          itemBuilder: (context, index) {
            AppLog.instance.trace(
              "lib/pages/anchor_page.dart::_AnchorPageState._albumList.closure#1.closure#1",
            );

            final item = _albums.items[index];
            return _AnchorAlbumCard(
              key: ValueKey(item.album.id),
              item: item,
              coverSize: coverSize,
              titleSize: titleSize,
              onTap: () {
                AppLog.instance.trace(
                  "lib/pages/anchor_page.dart::_AnchorPageState._albumList.closure#1.closure#1.closure#1",
                );
                _openAlbum(item.album);
              },
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    AppLog.instance.trace("lib/pages/anchor_page.dart::_AnchorPageState.build");

    final theme = Theme.of(context);
    final albumCount = _albums.total ?? _profile?.albums;
    final trackCount = _tracks.total ?? _profile?.tracks;
    final tabHeight = math.max(
      56.0,
      MediaQuery.textScalerOf(context).scale(18) * 1.4 + 20,
    );
    return Scaffold(
      backgroundColor: theme.colorScheme.surface,
      appBar: AppHeader(
        title: const Text('主播'),
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
            constraints: const BoxConstraints(maxWidth: 1440),
            child: LayoutBuilder(
              builder: (context, constraints) {
                AppLog.instance.trace(
                  "lib/pages/anchor_page.dart::_AnchorPageState.build.closure#1",
                );

                final padding = constraints.maxWidth >= 800 ? 32.0 : 16.0;
                return RefreshIndicator(
                  onRefresh: _refresh,
                  child: Scrollbar(
                    controller: _scroll,
                    child: CustomScrollView(
                      controller: _scroll,
                      physics: const AlwaysScrollableScrollPhysics(),
                      slivers: [
                        if (_resolving)
                          const SliverFillRemaining(
                            hasScrollBody: false,
                            child: Center(child: CircularProgressIndicator()),
                          )
                        else if (_resolveError != null)
                          SliverFillRemaining(
                            hasScrollBody: false,
                            child: Center(
                              child: _retry(_resolveError!, _refresh),
                            ),
                          )
                        else ...[
                          SliverPadding(
                            padding: EdgeInsets.symmetric(horizontal: padding),
                            sliver: SliverToBoxAdapter(
                              child: Column(
                                children: [
                                  _header(),
                                  Divider(
                                    height: 1,
                                    color: theme.colorScheme.outlineVariant
                                        .withValues(alpha: .6),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          SliverPadding(
                            padding: EdgeInsets.symmetric(horizontal: padding),
                            sliver: SliverPersistentHeader(
                              pinned: true,
                              delegate: _AnchorTabs(
                                color: theme.colorScheme.surface,
                                height: tabHeight,
                                tabs: TabBar(
                                  controller: _tabs,
                                  isScrollable: true,
                                  tabAlignment: TabAlignment.start,
                                  dividerColor: Colors.transparent,
                                  indicatorSize: TabBarIndicatorSize.label,
                                  labelPadding: const EdgeInsets.only(
                                    right: 28,
                                  ),
                                  labelStyle: theme.textTheme.titleMedium
                                      ?.copyWith(
                                        fontSize: 18,
                                        fontWeight: FontWeight.w700,
                                      ),
                                  unselectedLabelStyle: theme
                                      .textTheme
                                      .titleMedium
                                      ?.copyWith(
                                        fontSize: 18,
                                        fontWeight: FontWeight.w500,
                                      ),
                                  tabs: [
                                    Tab(
                                      height: tabHeight,
                                      text: albumCount == null
                                          ? '专辑'
                                          : '专辑 ($albumCount)',
                                    ),
                                    Tab(
                                      height: tabHeight,
                                      text: trackCount == null
                                          ? '声音'
                                          : '声音 ($trackCount)',
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                          if (_selected == 0) ...[
                            if (_albums.items.isNotEmpty)
                              SliverPadding(
                                padding: EdgeInsets.fromLTRB(
                                  padding - 8,
                                  12,
                                  padding - 8,
                                  0,
                                ),
                                sliver: _albumList(),
                              ),
                            SliverToBoxAdapter(
                              child: _footer(_albums, '暂无公开专辑'),
                            ),
                          ] else ...[
                            SliverPadding(
                              padding: EdgeInsets.symmetric(
                                horizontal: padding - 8,
                              ),
                              sliver: SliverList.builder(
                                itemCount: _tracks.items.length,
                                itemBuilder: (context, index) {
                                  AppLog.instance.trace(
                                    "lib/pages/anchor_page.dart::_AnchorPageState.build.closure#1.closure#1",
                                  );

                                  final track = _tracks.items[index];
                                  return ListTile(
                                    key: ValueKey(track.id),
                                    leading: CoverImage(
                                      uri: track.coverUrl,
                                      size: 48,
                                    ),
                                    title: Text(
                                      track.title,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    subtitle: track.album.isEmpty
                                        ? null
                                        : AdaptiveText(track.album),
                                    onTap: () {
                                      AppLog.instance.trace(
                                        "lib/pages/anchor_page.dart::_AnchorPageState.build.closure#1.closure#1.closure#1",
                                      );
                                      unawaited(_play(track));
                                    },
                                    trailing: IconButton(
                                      tooltip: '播放',
                                      onPressed: () {
                                        AppLog.instance.trace(
                                          "lib/pages/anchor_page.dart::_AnchorPageState.build.closure#1.closure#1.closure#2",
                                        );
                                        unawaited(_play(track));
                                      },
                                      icon: const Icon(Icons.play_arrow),
                                    ),
                                  );
                                },
                              ),
                            ),
                            SliverToBoxAdapter(
                              child: _footer(_tracks, '暂无公开声音'),
                            ),
                          ],
                        ],
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _AnchorTabs extends SliverPersistentHeaderDelegate {
  _AnchorTabs({required this.tabs, required this.color, required this.height}) {
    AppLog.instance.trace("lib/pages/anchor_page.dart::_AnchorTabs.new");
  }
  final TabBar tabs;
  final Color color;
  final double height;

  @override
  double get minExtent {
    AppLog.instance.trace(
      "lib/pages/anchor_page.dart::_AnchorTabs.minExtent.get",
    );
    return height;
  }

  @override
  double get maxExtent {
    AppLog.instance.trace(
      "lib/pages/anchor_page.dart::_AnchorTabs.maxExtent.get",
    );
    return height;
  }

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    AppLog.instance.trace("lib/pages/anchor_page.dart::_AnchorTabs.build");

    return Material(color: color, child: tabs);
  }

  @override
  bool shouldRebuild(covariant _AnchorTabs oldDelegate) {
    AppLog.instance.trace(
      "lib/pages/anchor_page.dart::_AnchorTabs.shouldRebuild",
    );

    return tabs != oldDelegate.tabs ||
        color != oldDelegate.color ||
        height != oldDelegate.height;
  }
}

class _AnchorAlbumCard extends StatelessWidget {
  const _AnchorAlbumCard({
    required this.item,
    required this.coverSize,
    required this.titleSize,
    required this.onTap,
    super.key,
  });
  final AnchorAlbum item;
  final double coverSize, titleSize;
  final VoidCallback onTap;

  Widget _metric(
    BuildContext context,
    IconData icon,
    String value,
    String label,
  ) {
    AppLog.instance.trace(
      "lib/pages/anchor_page.dart::_AnchorAlbumCard._metric",
    );

    final color = Theme.of(context).colorScheme.onSurfaceVariant;
    return Semantics(
      label: label,
      child: ExcludeSemantics(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: color.withValues(alpha: .7)),
            const SizedBox(width: 5),
            Flexible(
              child: Text(
                value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall
                    ?.copyWith(color: color, height: 1.4),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _cover(BuildContext context) {
    AppLog.instance.trace(
      "lib/pages/anchor_page.dart::_AnchorAlbumCard._cover",
    );

    final colors = Theme.of(context).colorScheme;
    return SizedBox(
      width: coverSize + 8,
      height: coverSize,
      child: Stack(
        children: [
          Positioned(
            right: 0,
            top: coverSize * .1,
            bottom: coverSize * .1,
            child: Container(
              width: coverSize * .8,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: const Color(0xff272727),
                border: Border.all(color: const Color(0xff4b4b4b), width: 2),
              ),
            ),
          ),
          DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(6),
              boxShadow: [
                BoxShadow(
                  color: colors.shadow.withValues(alpha: .06),
                  blurRadius: 10,
                  offset: const Offset(0, 3),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: CoverImage(uri: item.album.coverUrl, size: coverSize),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    AppLog.instance.trace("lib/pages/anchor_page.dart::_AnchorAlbumCard.build");

    final theme = Theme.of(context);
    final album = item.album;
    final plays = item.playCount;
    final count = plays == null
        ? null
        : plays >= 100000000
        ? '${(plays / 100000000).toStringAsFixed(2)}亿'
        : plays >= 10000
        ? '${(plays / 10000).toStringAsFixed(1)}万'
        : '$plays';
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _cover(context),
              const SizedBox(width: 18),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      album.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontSize: titleSize,
                        height: 1.4,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      album.intro,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontSize: 14,
                        height: 1.5,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const Spacer(),
                    Row(
                      children: [
                        if (count != null) ...[
                          Flexible(
                            child: _metric(
                              context,
                              Icons.play_arrow_outlined,
                              count,
                              '$plays 次播放',
                            ),
                          ),
                          const SizedBox(width: 18),
                        ],
                        Flexible(
                          child: _metric(
                            context,
                            Icons.graphic_eq_rounded,
                            '${album.total}',
                            '${album.total} 集',
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
