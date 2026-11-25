import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';

import '../common/widgets/app_scrollbar.dart';
import '../api/xmly_catalogue.dart';
import '../api/xmly_client.dart';
import '../api/xmly_experience.dart';
import '../api/xmly_history.dart';
import '../api/xmly_anchor.dart';
import '../api/xmly_discovery.dart';
import '../common/widgets/content_paging.dart';
import '../common/widgets/logged_network_image.dart';
import '../common/widgets/app_header.dart';
import '../common/widgets/local_panel.dart';
import '../models/xmly_models.dart';
import '../services/app_log.dart';
import '../services/app_runtime.dart';
import '../services/download_service.dart';
import 'album_introduction.dart';
import 'album_action_bar.dart';
import 'album_similar_section.dart';
import 'album_bulk_download_page.dart';
import 'anchor_page.dart';
import 'album_search_page.dart';
import 'download_page.dart'
    show deleteDownloadedAudio, requestDownloads, setAlbumAutoDownload;
import 'media_settings_page.dart';
import 'playback_settings_page.dart';
import 'album_reviews_page.dart';

void _recordCatalogueError(
  String operation,
  Object error,
  StackTrace stack, {
  bool recoverable = false,
}) {
  AppLog.instance.trace("lib/pages/catalogue_page.dart::_recordCatalogueError");

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
        'rejected',
        'permission_denied',
        'queue_full',
        'catalogue_limit',
        'invalid_id',
        'invalid_page',
        'invalid_episode',
        'invalid_range',
        'range_not_found',
        'ambiguous_episode',
        'episode_not_found',
        'empty_selection',
        'offline_catalogue',
        'offline_playback',
        'catalogue_changed',
        'track_position_missing',
        'task_busy',
        'original_account_required',
      }.contains(error.code);
  log.write(
    recoverable || expected ? AppLogLevel.warning : AppLogLevel.error,
    'catalogue_page',
    operation,
    data: error is XmlyException ? error.diagnostics : null,
    error: error,
    stackTrace: stack,
    promptUser: !recoverable && !expected,
  );
}

typedef TrackDownload = Future<void> Function(List<Track> tracks);
typedef AlbumPlayback = Future<void> Function(
  String albumId,
  String trackId, {
  int? page,
  Track? track,
});

int? _trackOrdinal(Track track) {
  AppLog.instance.trace("lib/pages/catalogue_page.dart::_trackOrdinal");
  return track.officialPosition ?? xmlyPositive(track.orderNo);
}

List<int> catalogueHintPages(
  CatalogueLocationHint hint, {
  required String albumId,
  required String trackId,
  required int total,
  int pageSize = xmlyAlbumPageSize,
}) {
  AppLog.instance.trace('lib/pages/catalogue_page.dart::catalogueHintPages');
  try {
    if (xmlyIdentifier(hint.albumId) != xmlyIdentifier(albumId) ||
        xmlyIdentifier(hint.trackId) != xmlyIdentifier(trackId))
      return const [];
  } on XmlyException {
    return const [];
  }
  if (hint.sort != 0 ||
      hint.page < 1 ||
      hint.pageSize < 1 ||
      hint.indexInList < 0 ||
      hint.indexInList >= hint.pageSize ||
      total < 1 ||
      pageSize < 1)
    return const [];
  final offset = hint.absoluteOffset;
  if (offset < 0 || offset >= total) return const [];
  return {
    offset ~/ pageSize + 1,
    (total - 1 - offset) ~/ pageSize + 1,
  }.toList();
}

bool cataloguePageContainsTarget(
  AlbumPage page,
  String albumId,
  String trackId,
) {
  AppLog.instance.trace(
    'lib/pages/catalogue_page.dart::cataloguePageContainsTarget',
  );
  return page.album.id == albumId &&
      page.tracks.any((track) {
        AppLog.instance.trace(
          'lib/pages/catalogue_page.dart::cataloguePageContainsTarget.closure#1',
        );
        return track.id == trackId && track.albumId == albumId;
      });
}

Future<AlbumPage> locateCatalogueTarget({
  required XmlyClient client,
  required String albumId,
  required Track target,
  required bool ascending,
  required bool Function() isCurrent,
}) async {
  AppLog.instance.trace('lib/pages/catalogue_page.dart::locateCatalogueTarget');
  const missing = XmlyException(
    'track_position_missing',
    '无法确定这集在专辑中的位置，请重新定位',
  );
  void check() {
    AppLog.instance.trace(
      'lib/pages/catalogue_page.dart::locateCatalogueTarget.check',
    );
    if (!isCurrent()) throw const XmlyException('request_cancelled', '请求已取消');
  }

  final pages = <int, AlbumPage>{};
  Future<AlbumPage> read(int page) async {
    AppLog.instance.trace(
      'lib/pages/catalogue_page.dart::locateCatalogueTarget.read',
    );
    check();
    final cached = pages[page];
    if (cached != null) return cached;
    final result = await client.album(
      albumId,
      page: page,
      pageSize: xmlyAlbumPageSize,
      ascending: ascending,
    );
    check();
    if (result.album.id != albumId || result.page != page) throw missing;
    pages[page] = result;
    return result;
  }

  Future<AlbumPage?> ordinalPage(Track track) async {
    AppLog.instance.trace(
      'lib/pages/catalogue_page.dart::locateCatalogueTarget.ordinalPage',
    );
    final ordinal = _trackOrdinal(track);
    if (track.id != target.id ||
        track.albumId != albumId ||
        ordinal == null ||
        ordinal > xmlyMaxPage * xmlyAlbumPageSize)
      return null;
    var result = await read((ordinal - 1) ~/ xmlyAlbumPageSize + 1);
    if (ordinal > result.total) return null;
    if (!ascending)
      result = await read((result.total - ordinal) ~/ xmlyAlbumPageSize + 1);
    return cataloguePageContainsTarget(result, albumId, target.id)
        ? result
        : null;
  }

  check();
  if (target.albumId != albumId) throw missing;
  if (_trackOrdinal(target) != null) {
    final result = await ordinalPage(target);
    if (result != null) return result;
  } else {
    try {
      final hint = await XmlyDiscovery(client)
          .locateTrack(albumId: albumId, trackId: target.id);
      check();
      final first = await read(1);
      for (final page in catalogueHintPages(
        hint,
        albumId: albumId,
        trackId: target.id,
        total: first.total,
      )) {
        final result = await read(page);
        if (cataloguePageContainsTarget(result, albumId, target.id))
          return result;
      }
    } catch (error, stack) {
      check();
      _recordCatalogueError(
        'Track location hint unavailable',
        error,
        stack,
        recoverable: true,
      );
    }
  }
  check();
  final track = await client.track(target.id);
  check();
  final result = await ordinalPage(track);
  if (result == null) throw missing;
  return result;
}

class DiscoveryPage extends StatefulWidget {
  const DiscoveryPage({
    required this.runtime,
    this.onDownload,
    this.onPlayAlbum,
    super.key,
  });
  final AppRuntime runtime;
  final TrackDownload? onDownload;
  final AlbumPlayback? onPlayAlbum;
  @override
  State<DiscoveryPage> createState() {
    AppLog.instance.trace(
      "lib/pages/catalogue_page.dart::DiscoveryPage.createState",
    );
    return _DiscoveryPageState();
  }
}

class _DiscoveryPageState extends State<DiscoveryPage>
    with SingleTickerProviderStateMixin {
  static const _kinds = ['all', 'album', 'track', 'user'];
  static const _labels = ['全部', '专辑', '声音', '主播'];
  final _query = TextEditingController();
  final _queryFocus = FocusNode();
  final _scroll = ScrollController();
  late final _tabs = TabController(length: _kinds.length, vsync: this);
  String _kind = 'all';
  SearchPage? _result;
  String? _resultQuery, _submittedQuery, _error;
  bool _loading = false;
  int _generation = 0, _playRequest = 0, _requestedPage = 1;
  Completer<void>? _searchCancelled, _hotCancelled;
  List<HotWord> _hotWords = const [];
  bool _showHotWords = true, _hotAttempted = false;
  int _hotGeneration = 0;

  @override
  void initState() {
    AppLog.instance.trace(
      'lib/pages/catalogue_page.dart::_DiscoveryPageState.initState',
    );
    super.initState();
    _showHotWords = widget.runtime.showHotWords;
    widget.runtime.addListener(_runtimeChanged);
    _query.addListener(_queryChanged);
    _loadHotWords();
  }

  @override
  void didUpdateWidget(covariant DiscoveryPage oldWidget) {
    AppLog.instance.trace(
      'lib/pages/catalogue_page.dart::_DiscoveryPageState.didUpdateWidget',
    );
    super.didUpdateWidget(oldWidget);
    if (identical(oldWidget.runtime, widget.runtime)) return;
    oldWidget.runtime.removeListener(_runtimeChanged);
    widget.runtime.addListener(_runtimeChanged);
    _generation++;
    _searchCancelled?.complete();
    _searchCancelled = null;
    _hotGeneration++;
    _hotCancelled?.complete();
    _hotCancelled = null;
    _showHotWords = widget.runtime.showHotWords;
    _hotWords = const [];
    _hotAttempted = false;
    _loading = false;
    _result = null;
    _resultQuery = null;
    _error = null;
    _loadHotWords();
  }

  void _runtimeChanged() {
    AppLog.instance.trace(
      'lib/pages/catalogue_page.dart::_DiscoveryPageState._runtimeChanged',
    );
    final enabled = widget.runtime.showHotWords;
    if (!mounted || enabled == _showHotWords) return;
    _hotGeneration++;
    _hotCancelled?.complete();
    _hotCancelled = null;
    setState(() {
      AppLog.instance.trace(
        'lib/pages/catalogue_page.dart::_DiscoveryPageState._runtimeChanged.closure#1',
      );
      _showHotWords = enabled;
      _hotWords = const [];
      _hotAttempted = false;
    });
    if (enabled) _loadHotWords();
  }

  void _queryChanged() {
    AppLog.instance.trace(
      'lib/pages/catalogue_page.dart::_DiscoveryPageState._queryChanged',
    );
    if (!mounted) return;
    if (_query.text.trim().isEmpty) {
      _generation++;
      _searchCancelled?.complete();
      _searchCancelled = null;
      setState(() {
        AppLog.instance.trace(
          'lib/pages/catalogue_page.dart::_DiscoveryPageState._queryChanged.closure#1',
        );
        _result = null;
        _resultQuery = null;
        _submittedQuery = null;
        _error = null;
        _loading = false;
      });
      _loadHotWords();
    } else {
      setState(() {
        AppLog.instance.trace(
          'lib/pages/catalogue_page.dart::_DiscoveryPageState._queryChanged.closure#2',
        );
      });
    }
  }

  Future<void> _loadHotWords() async {
    AppLog.instance.trace(
      'lib/pages/catalogue_page.dart::_DiscoveryPageState._loadHotWords',
    );
    if (!mounted ||
        !widget.runtime.showHotWords ||
        !_showHotWords ||
        _query.text.trim().isNotEmpty ||
        _hotAttempted)
      return;
    _hotAttempted = true;
    final generation = ++_hotGeneration;
    final cancelled = _hotCancelled = Completer<void>();
    final client = widget.runtime.anonymous;
    try {
      final words = await client.withReadPolicy(
        () {
          AppLog.instance.trace(
            'lib/pages/catalogue_page.dart::_DiscoveryPageState._loadHotWords.closure#1',
          );
          if (!mounted ||
              !widget.runtime.showHotWords ||
              generation != _hotGeneration) {
            throw const XmlyException('request_cancelled', '请求已取消');
          }
          return XmlyDiscovery(client).hotWords();
        },
        rateLimitRetries: 4,
        cancelled: cancelled.future,
      );
      if (!mounted ||
          generation != _hotGeneration ||
          !widget.runtime.showHotWords)
        return;
      setState(() {
        AppLog.instance.trace(
          'lib/pages/catalogue_page.dart::_DiscoveryPageState._loadHotWords.closure#2',
        );
        _hotWords = words;
      });
    } catch (error, stack) {
      if (mounted &&
          generation == _hotGeneration &&
          widget.runtime.showHotWords) {
        _recordCatalogueError(
          'Hot words unavailable',
          error,
          stack,
          recoverable: true,
        );
      }
    } finally {
      if (identical(_hotCancelled, cancelled)) _hotCancelled = null;
    }
  }

  Future<void> _search({int page = 1, String? query}) async {
    AppLog.instance.trace(
      "lib/pages/catalogue_page.dart::_DiscoveryPageState._search",
    );

    final rawQuery = query ?? _query.text;
    final submitted = rawQuery.trim();
    final generation = ++_generation;
    _searchCancelled?.complete();
    _searchCancelled = null;
    if (submitted.isEmpty || rawQuery.length > 200) {
      setState(() {
        AppLog.instance.trace(
          "lib/pages/catalogue_page.dart::_DiscoveryPageState._search.closure#1",
        );

        _loading = false;
        _error = '请输入 1～200 字的关键词';
        _result = null;
        _resultQuery = null;
        _submittedQuery = null;
        _requestedPage = 1;
      });
      _queryFocus.requestFocus();
      return;
    }
    final cancelled = _searchCancelled = Completer<void>();
    final kind = _kind;
    setState(() {
      AppLog.instance.trace(
        "lib/pages/catalogue_page.dart::_DiscoveryPageState._search.closure#2",
      );

      _loading = true;
      _error = null;
      _submittedQuery = submitted;
      _requestedPage = page;
      if (_resultQuery != submitted || _result?.kind != kind) _result = null;
    });
    try {
      final client = widget.runtime.anonymous;
      final result = await client.withReadPolicy(
        () {
          AppLog.instance.trace(
            "lib/pages/catalogue_page.dart::_DiscoveryPageState._search.closure#3",
          );
          return client.search(submitted, kind: kind, page: page, pageSize: 30);
        },
        rateLimitRetries: 0,
        cancelled: cancelled.future,
      );
      if (!mounted || generation != _generation) return;
      setState(() {
        AppLog.instance.trace(
          "lib/pages/catalogue_page.dart::_DiscoveryPageState._search.closure#4",
        );

        _result = result;
        _resultQuery = submitted;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        AppLog.instance.trace(
          "lib/pages/catalogue_page.dart::_DiscoveryPageState._search.closure#5",
        );

        if (mounted && generation == _generation && _scroll.hasClients) {
          _scroll.jumpTo(_scroll.position.minScrollExtent);
        }
      });
    } catch (error, stack) {
      if (!mounted || generation != _generation) return;
      _recordCatalogueError('Search failed', error, stack);
      setState(() {
        AppLog.instance.trace(
          "lib/pages/catalogue_page.dart::_DiscoveryPageState._search.closure#6",
        );
        _error = _safeError(error);
      });
    } finally {
      if (mounted && generation == _generation) {
        _searchCancelled = null;
        setState(() {
          AppLog.instance.trace(
            "lib/pages/catalogue_page.dart::_DiscoveryPageState._search.closure#7",
          );
          _loading = false;
        });
      }
    }
  }

  void _selectKind(int index) {
    AppLog.instance.trace(
      "lib/pages/catalogue_page.dart::_DiscoveryPageState._selectKind",
    );

    if (_kind == _kinds[index]) return;
    ++_generation;
    _searchCancelled?.complete();
    _searchCancelled = null;
    setState(() {
      AppLog.instance.trace(
        "lib/pages/catalogue_page.dart::_DiscoveryPageState._selectKind.closure#1",
      );

      _kind = _kinds[index];
      _result = null;
      _error = null;
      _loading = false;
      _tabs.animateTo(index);
    });
    final query = _submittedQuery ?? _query.text.trim();
    if (query.isNotEmpty) unawaited(_search(query: query));
  }

  void _clear() {
    AppLog.instance.trace(
      "lib/pages/catalogue_page.dart::_DiscoveryPageState._clear",
    );

    ++_generation;
    _searchCancelled?.complete();
    _searchCancelled = null;
    setState(() {
      AppLog.instance.trace(
        "lib/pages/catalogue_page.dart::_DiscoveryPageState._clear.closure#1",
      );

      _query.clear();
      _result = null;
      _resultQuery = null;
      _submittedQuery = null;
      _error = null;
      _loading = false;
    });
    _queryFocus.requestFocus();
  }

  void _openAlbum(String id, {Track? target}) {
    AppLog.instance.trace(
      "lib/pages/catalogue_page.dart::_DiscoveryPageState._openAlbum",
    );

    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) {
          AppLog.instance.trace(
            "lib/pages/catalogue_page.dart::_DiscoveryPageState._openAlbum.closure#1",
          );
          return AlbumPageView(
            runtime: widget.runtime,
            albumId: id,
            initialTrack: target,
            onDownload: widget.onDownload,
            onPlayAlbum: widget.onPlayAlbum,
          );
        },
      ),
    );
  }

  Future<void> _playResult(Track track) {
    AppLog.instance.trace(
      "lib/pages/catalogue_page.dart::_DiscoveryPageState._playResult",
    );
    return AppLog.instance.runWithErrorScope(() async {
      AppLog.instance.trace(
        "lib/pages/catalogue_page.dart::_DiscoveryPageState._playResult.closure#1",
      );

      final request = ++_playRequest;
      try {
        if (track.albumId.isEmpty) {
          await widget.runtime.player.playTrack(track);
        } else {
          final ordinal = _trackOrdinal(track);
          await (widget.onPlayAlbum ?? widget.runtime.player.playAlbum)(
            track.albumId,
            track.id,
            page: ordinal == null
                ? null
                : (ordinal - 1) ~/ xmlyAlbumPageSize + 1,
            track: track,
          );
        }
      } catch (error, stack) {
        _recordCatalogueError('Playback failed', error, stack);
        if (mounted && request == _playRequest) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text(_safeError(error))));
        }
      }
    });
  }

  void _openAnchor(AnchorSearchResult anchor) {
    AppLog.instance.trace(
      "lib/pages/catalogue_page.dart::_DiscoveryPageState._openAnchor",
    );

    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) {
          AppLog.instance.trace(
            "lib/pages/catalogue_page.dart::_DiscoveryPageState._openAnchor.closure#1",
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

  Future<void> _trackAction(String action, Track track) async {
    AppLog.instance.trace(
      "lib/pages/catalogue_page.dart::_DiscoveryPageState._trackAction",
    );

    if (action == 'album') {
      _openAlbum(track.albumId, target: track);
      return;
    }
    try {
      await widget.onDownload?.call([track]);
    } catch (error, stack) {
      _recordCatalogueError('Download request failed', error, stack);
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(_safeError(error))));
      }
    }
  }

  @override
  void dispose() {
    AppLog.instance.trace(
      "lib/pages/catalogue_page.dart::_DiscoveryPageState.dispose",
    );

    _generation++;
    widget.runtime.removeListener(_runtimeChanged);
    _query.removeListener(_queryChanged);
    _hotGeneration++;
    _hotCancelled?.complete();
    _searchCancelled?.complete();
    _playRequest++;
    _query.dispose();
    _queryFocus.dispose();
    _scroll.dispose();
    _tabs.dispose();
    super.dispose();
  }

  Widget _header(double padding) {
    AppLog.instance.trace(
      "lib/pages/catalogue_page.dart::_DiscoveryPageState._header",
    );

    final colors = Theme.of(context).colorScheme;
    final border = OutlineInputBorder(
      borderRadius: BorderRadius.circular(28),
      borderSide: BorderSide.none,
    );
    return Padding(
      padding: EdgeInsets.fromLTRB(padding, 12, padding, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 620),
            child: TextField(
              key: const ValueKey('catalogueSearchField'),
              controller: _query,
              focusNode: _queryFocus,
              autofocus: true,
              maxLength: 200,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                hintText: '搜索专辑、声音、主播',
                hintStyle: TextStyle(
                  color: colors.onSurfaceVariant,
                  fontSize: 14,
                ),
                counterText: '',
                filled: true,
                fillColor: colors.surfaceContainerHighest.withValues(alpha: .6),
                border: border,
                enabledBorder: border,
                focusedBorder: border.copyWith(
                  borderSide: BorderSide(
                    color: colors.primary.withValues(alpha: .45),
                  ),
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 14,
                ),
                prefixIcon: IconButton(
                  tooltip: '搜索',
                  onPressed: () {
                    AppLog.instance.trace(
                      "lib/pages/catalogue_page.dart::_DiscoveryPageState._header.closure#1",
                    );
                    unawaited(_search());
                  },
                  icon: const Icon(Icons.search_rounded, size: 22),
                ),
                suffixIcon: _query.text.isEmpty
                    ? null
                    : IconButton(
                        tooltip: '清空',
                        onPressed: _clear,
                        icon: const Icon(Icons.close_rounded, size: 20),
                      ),
              ),
              onChanged: (_) {
                AppLog.instance.trace(
                  "lib/pages/catalogue_page.dart::_DiscoveryPageState._header.closure#2",
                );

                setState(() {
                  AppLog.instance.trace(
                    "lib/pages/catalogue_page.dart::_DiscoveryPageState._header.closure#2.closure#1",
                  );
                });
              },
              onSubmitted: (_) {
                AppLog.instance.trace(
                  "lib/pages/catalogue_page.dart::_DiscoveryPageState._header.closure#3",
                );
                unawaited(_search());
              },
            ),
          ),
          const SizedBox(height: 20),
          TabBar(
            key: const ValueKey('searchCategoryTabs'),
            controller: _tabs,
            isScrollable: true,
            tabAlignment: TabAlignment.center,
            labelPadding: const EdgeInsets.symmetric(horizontal: 16),
            labelColor: colors.primary,
            unselectedLabelColor: colors.onSurface,
            labelStyle: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w600,
            ),
            unselectedLabelStyle: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w500,
            ),
            indicator: UnderlineTabIndicator(
              borderSide: BorderSide(color: colors.primary, width: 3),
              insets: const EdgeInsets.symmetric(horizontal: 8),
              borderRadius: BorderRadius.circular(3),
            ),
            onTap: _selectKind,
            tabs: [
              for (var i = 0; i < _labels.length; i++)
                Tab(key: ValueKey('searchTab-${_kinds[i]}'), text: _labels[i]),
            ],
          ),
        ],
      ),
    );
  }

  Widget _section(String title, String kind, int count, int visible) {
    AppLog.instance.trace(
      "lib/pages/catalogue_page.dart::_DiscoveryPageState._section",
    );

    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.only(top: 12, bottom: 16),
        child: Row(
          children: [
            Expanded(
              child: Text(
                title,
                style: Theme.of(context).textTheme.titleLarge
                    ?.copyWith(fontWeight: FontWeight.w500),
              ),
            ),
            if (_kind == 'all' && count > visible)
              TextButton(
                key: ValueKey('searchMore-$kind'),
                onPressed: () {
                  AppLog.instance.trace(
                    "lib/pages/catalogue_page.dart::_DiscoveryPageState._section.closure#1",
                  );
                  return _selectKind(_kinds.indexOf(kind));
                },
                style: TextButton.styleFrom(
                  foregroundColor: Theme.of(context)
                      .colorScheme
                      .onSurfaceVariant,
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [Text('更多'), Icon(Icons.chevron_right, size: 18)],
                ),
              ),
          ],
        ),
      ),
    );
  }

  static String _countLabel(int count) {
    AppLog.instance.trace(
      "lib/pages/catalogue_page.dart::_DiscoveryPageState._countLabel",
    );

    if (count >= 100000000) return '${(count / 100000000).toStringAsFixed(1)}亿';
    if (count >= 10000) return '${(count / 10000).toStringAsFixed(1)}万';
    return '$count';
  }

  Widget _albumCard(Album album, double width) {
    AppLog.instance.trace(
      "lib/pages/catalogue_page.dart::_DiscoveryPageState._albumCard",
    );

    final colors = Theme.of(context).colorScheme;
    final plays = xmlyPositive(album.raw['play']);
    final vip = const [1, 2].contains(album.raw['vipType']);
    final paid = album.raw['is_paid'] == true || album.raw['isPaid'] == true;
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        key: ValueKey('searchAlbum-${album.id}'),
        onTap: () {
          AppLog.instance.trace(
            "lib/pages/catalogue_page.dart::_DiscoveryPageState._albumCard.closure#1",
          );
          return _openAlbum(album.id);
        },
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Stack(
                children: [
                  CoverImage(uri: album.coverUrl, size: width - 8),
                  if (plays != null)
                    Positioned(
                      right: 8,
                      bottom: 8,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: .6),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 7,
                            vertical: 3,
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(
                                Icons.play_arrow_rounded,
                                size: 14,
                                color: Colors.white,
                              ),
                              const SizedBox(width: 2),
                              Text(
                                _countLabel(plays),
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 11,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 10),
              Text.rich(
                TextSpan(
                  children: [
                    if (vip || paid)
                      TextSpan(
                        text: vip ? 'VIP  ' : '付费  ',
                        style: TextStyle(
                          color: colors.tertiary,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    TextSpan(text: album.title),
                  ],
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: colors.onSurface,
                  fontSize: 15,
                  height: 1.4,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _trackTile(Track track) {
    AppLog.instance.trace(
      "lib/pages/catalogue_page.dart::_DiscoveryPageState._trackTile",
    );

    final narrow =
        MediaQuery.sizeOf(context).width < 420 ||
        MediaQuery.textScalerOf(context).scale(14) > 22;
    return ListTile(
      key: ValueKey('searchTrack-${track.id}'),
      contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 5),
      leading: narrow ? null : CoverImage(uri: track.coverUrl, size: 48),
      title: Text(track.title, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        '${track.album} · ${_duration(track.duration)}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      onTap: () {
        AppLog.instance.trace(
          "lib/pages/catalogue_page.dart::_DiscoveryPageState._trackTile.closure#1",
        );
        if (track.albumId.isNotEmpty) {
          _openAlbum(track.albumId, target: track);
        } else {
          unawaited(_playResult(track));
        }
      },
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!narrow)
            IconButton(
              tooltip: '播放此集',
              icon: const Icon(Icons.play_arrow_rounded),
              onPressed: () {
                AppLog.instance.trace(
                  "lib/pages/catalogue_page.dart::_DiscoveryPageState._trackTile.closure#2",
                );
                unawaited(_playResult(track));
              },
            ),
          if (track.albumId.isNotEmpty || widget.onDownload != null)
            PopupMenuButton<String>(
              tooltip: '更多',
              onSelected: (action) {
                AppLog.instance.trace(
                  "lib/pages/catalogue_page.dart::_DiscoveryPageState._trackTile.closure#3",
                );
                unawaited(_trackAction(action, track));
              },
              itemBuilder: (_) {
                AppLog.instance.trace(
                  "lib/pages/catalogue_page.dart::_DiscoveryPageState._trackTile.closure#4",
                );
                return [
                  if (track.albumId.isNotEmpty)
                    const PopupMenuItem(value: 'album', child: Text('查看专辑并定位')),
                  if (widget.onDownload != null)
                    const PopupMenuItem(value: 'download', child: Text('下载')),
                ];
              },
            ),
        ],
      ),
    );
  }

  Widget _anchorTile(AnchorSearchResult anchor) {
    AppLog.instance.trace(
      "lib/pages/catalogue_page.dart::_DiscoveryPageState._anchorTile",
    );

    final colors = Theme.of(context).colorScheme;
    final counts = [
      if (anchor.albumsCount != null) '${anchor.albumsCount} 张专辑',
      if (anchor.tracksCount != null) '${anchor.tracksCount} 声音',
      if (anchor.followersCount != null)
        '${_countLabel(anchor.followersCount!)} 粉丝',
    ];
    final subtitle = [
      if (counts.isNotEmpty) counts.join(' · '),
      if (anchor.description.isNotEmpty) anchor.description,
    ].join('\n');
    return ListTile(
      key: ValueKey('searchAnchor-${anchor.uid}'),
      contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
      leading: ClipOval(child: CoverImage(uri: anchor.avatarUrl, size: 48)),
      title: Row(
        children: [
          Flexible(
            child: Text(
              anchor.nickname,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (anchor.isVerified)
            Padding(
              padding: const EdgeInsets.only(left: 6),
              child: Icon(
                Icons.verified_rounded,
                color: colors.primary,
                size: 16,
              ),
            ),
        ],
      ),
      subtitle: subtitle.isEmpty
          ? null
          : Text(subtitle, maxLines: 2, overflow: TextOverflow.ellipsis),
      trailing: const Icon(Icons.chevron_right_rounded, size: 20),
      onTap: () {
        AppLog.instance.trace(
          "lib/pages/catalogue_page.dart::_DiscoveryPageState._anchorTile.closure#1",
        );
        return _openAnchor(anchor);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    AppLog.instance.trace(
      "lib/pages/catalogue_page.dart::_DiscoveryPageState.build",
    );

    final result = _result;
    final empty =
        result != null &&
        result.albums.isEmpty &&
        result.tracks.isEmpty &&
        result.anchors.isEmpty;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1600),
        child: LayoutBuilder(
          builder: (context, constraints) {
            AppLog.instance.trace(
              "lib/pages/catalogue_page.dart::_DiscoveryPageState.build.closure#1",
            );

            final padding = constraints.maxWidth < 600 ? 16.0 : 28.0;
            final width = constraints.maxWidth - padding * 2;
            final scale = MediaQuery.textScalerOf(context).scale(15) / 15;
            final gap = width < 600 ? 12.0 : 24.0;
            final columns = width < 600
                ? (width >= 280 && scale < 1.5 ? 2 : 1)
                : ((width + gap) / (220 * scale.clamp(1, 1.4) + gap))
                      .floor()
                      .clamp(2, 5);
            final cardWidth = (width - gap * (columns - 1)) / columns;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _header(padding),
                SizedBox(
                  height: 2,
                  child: _loading
                      ? const LinearProgressIndicator(minHeight: 2)
                      : null,
                ),
                Expanded(
                  child: AppScrollbar(
                    controller: _scroll,
                    child: CustomScrollView(
                      controller: _scroll,
                      scrollBehavior: ScrollConfiguration.of(context)
                          .copyWith(scrollbars: false),
                      keyboardDismissBehavior:
                          ScrollViewKeyboardDismissBehavior.onDrag,
                      slivers: [
                        if (_showHotWords &&
                            widget.runtime.showHotWords &&
                            _query.text.trim().isEmpty &&
                            _hotWords.isNotEmpty)
                          SliverToBoxAdapter(
                            child: Padding(
                              padding: EdgeInsets.all(padding),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    '热搜',
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleMedium,
                                  ),
                                  const SizedBox(height: 8),
                                  Wrap(
                                    spacing: 8,
                                    runSpacing: 8,
                                    children: [
                                      for (final word in _hotWords)
                                        ActionChip(
                                          label: Text(word.displayWord),
                                          onPressed: () {
                                            AppLog.instance.trace(
                                              'lib/pages/catalogue_page.dart::_DiscoveryPageState.build.closure#1.closure#1',
                                            );
                                            _query.text = word.word;
                                            unawaited(
                                              _search(query: word.word),
                                            );
                                          },
                                        ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          ),
                        if (_error != null)
                          SliverToBoxAdapter(
                            child: Padding(
                              padding: EdgeInsets.all(padding),
                              child: Wrap(
                                spacing: 8,
                                crossAxisAlignment: WrapCrossAlignment.center,
                                children: [
                                  Text(_error!),
                                  TextButton(
                                    onPressed: _loading
                                        ? null
                                        : () {
                                            AppLog.instance.trace(
                                              "lib/pages/catalogue_page.dart::_DiscoveryPageState.build.closure#1.closure#2",
                                            );
                                            unawaited(
                                              _search(
                                                page: _requestedPage,
                                                query: _submittedQuery,
                                              ),
                                            );
                                          },
                                    child: const Text('重试'),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        if (!_loading &&
                            _error == null &&
                            (result == null || empty))
                          SliverFillRemaining(
                            hasScrollBody: false,
                            child: Center(
                              child: Text(
                                result == null ? '搜索你想听的内容' : '没有找到相关内容',
                                style: TextStyle(
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onSurfaceVariant,
                                ),
                              ),
                            ),
                          ),
                        if (result != null && !empty)
                          SliverPadding(
                            padding: EdgeInsets.fromLTRB(
                              padding,
                              0,
                              padding,
                              24,
                            ),
                            sliver: SliverMainAxisGroup(
                              slivers: [
                                if (result.anchors.isNotEmpty) ...[
                                  _section(
                                    '主播',
                                    'user',
                                    result.totals['user'] ?? result.total,
                                    result.anchors.length,
                                  ),
                                  SliverList.builder(
                                    itemCount: result.anchors.length,
                                    itemBuilder: (_, index) {
                                      AppLog.instance.trace(
                                        "lib/pages/catalogue_page.dart::_DiscoveryPageState.build.closure#1.closure#3",
                                      );
                                      return _anchorTile(result.anchors[index]);
                                    },
                                  ),
                                ],
                                if (result.albums.isNotEmpty) ...[
                                  _section(
                                    '专辑',
                                    'album',
                                    result.totals['album'] ?? result.total,
                                    result.albums.length,
                                  ),
                                  SliverGrid.builder(
                                    gridDelegate:
                                        SliverGridDelegateWithFixedCrossAxisCount(
                                          crossAxisCount: columns,
                                          crossAxisSpacing: gap,
                                          mainAxisSpacing: 20,
                                          mainAxisExtent:
                                              cardWidth + 12 + 44 * scale,
                                        ),
                                    itemCount: result.albums.length,
                                    itemBuilder: (_, index) {
                                      AppLog.instance.trace(
                                        "lib/pages/catalogue_page.dart::_DiscoveryPageState.build.closure#1.closure#4",
                                      );
                                      return _albumCard(
                                        result.albums[index],
                                        cardWidth,
                                      );
                                    },
                                  ),
                                ],
                                if (result.tracks.isNotEmpty) ...[
                                  _section(
                                    '声音',
                                    'track',
                                    result.totals['track'] ?? result.total,
                                    result.tracks.length,
                                  ),
                                  SliverList.builder(
                                    itemCount: result.tracks.length,
                                    itemBuilder: (_, index) {
                                      AppLog.instance.trace(
                                        "lib/pages/catalogue_page.dart::_DiscoveryPageState.build.closure#1.closure#5",
                                      );
                                      return _trackTile(result.tracks[index]);
                                    },
                                  ),
                                ],
                                if (_kind != 'all')
                                  SliverToBoxAdapter(
                                    child: ContentPaging(
                                      page: result.page,
                                      total: result.total,
                                      pageSize: result.pageSize,
                                      busy: _loading,
                                      onPage: (page) {
                                        AppLog.instance.trace(
                                          "lib/pages/catalogue_page.dart::_DiscoveryPageState.build.closure#1.closure#6",
                                        );
                                        return _search(
                                          page: page,
                                          query: _resultQuery,
                                        );
                                      },
                                    ),
                                  ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class AlbumPageView extends StatefulWidget {
  const AlbumPageView({
    required this.runtime,
    required this.albumId,
    this.initialTrack,
    this.accountIdentity,
    this.onDownload,
    this.onPlayAlbum,
    this.inPanel = false,
    super.key,
  });
  final AppRuntime runtime;
  final String albumId;
  final String? accountIdentity;
  final Track? initialTrack;
  final TrackDownload? onDownload;
  final AlbumPlayback? onPlayAlbum;
  final bool inPanel;
  @override
  State<AlbumPageView> createState() {
    AppLog.instance.trace(
      "lib/pages/catalogue_page.dart::AlbumPageView.createState",
    );
    return _AlbumPageViewState();
  }
}

class _AlbumPageViewState extends State<AlbumPageView> {
  final _albumScroll = ScrollController();
  final _informationScroll = ScrollController();
  final _headerKey = GlobalKey();
  String? _targetWarning;
  final _range = TextEditingController();
  final _selected = <String, Track>{};
  List<DownloadTask> _observedDownloads = [];
  Set<String> _downloaded = {};
  Object? _observedCache;
  Album? _album;
  List<Track> _visible = [];
  List<Track>? _complete;
  int _page = 1, _total = 0, _generation = 0;
  Completer<void>? _catalogueCancelled;
  bool _busy = false, _autoBusy = false, _offline = false;
  bool _selectionMode = false, _cachedView = false;
  String? _error;
  XmlyClient? _libraryClient;
  String? _libraryKey, _subscriptionError;
  int _libraryRevision = -1, _subscriptionRequest = 0, _accountEpoch = 0;
  bool? _subscribed;
  bool _subscriptionBusy = false, _favoriteBusy = false;
  bool _subscriptionMutating = false;
  bool _ascending = true;
  static const _pageSize = xmlyAlbumPageSize;
  final _actionChanges = ValueNotifier<int>(0);
  StreamSubscription<void>? _playerChanges;
  Map<String, dynamic>? _overview;
  Map<String, dynamic>? _cloudProgress;
  Future<void>? _historyRead;
  int _overviewRequest = 0, _tab = 0;
  int? _rangeStart;
  bool _continueBusy = false, _followBusy = false;
  bool? _following;
  String? _unavailablePoster;

  void _actionsChanged() {
    AppLog.instance.trace(
      "lib/pages/catalogue_page.dart::_AlbumPageViewState._actionsChanged",
    );
    if (mounted) _actionChanges.value++;
  }

  XmlyClient get _client {
    AppLog.instance.trace(
      "lib/pages/catalogue_page.dart::_AlbumPageViewState._client.get",
    );

    final identity = widget.accountIdentity;
    if (identity == null) return widget.runtime.client;
    return widget.runtime.accounts.accountIds.contains(identity)
        ? widget.runtime.accounts.clientFor(identity)
        : widget.runtime.anonymous;
  }

  @override
  void initState() {
    AppLog.instance.trace(
      "lib/pages/catalogue_page.dart::_AlbumPageViewState.initState",
    );

    super.initState();
    _ascending =
        (widget.runtime.storage.state['settings']
            as Map)['catalogueAscending'] !=
        false;
    widget.runtime.addListener(_runtimeChanged);
    _downloaded = _completedTrackIds();
    _restoreCache();
    _loadPage(1, target: widget.initialTrack);
    _scanUpdates();
    _loadSubscription();
    _loadOverview();
    _playerChanges = widget.runtime.player.changes.listen((_) {
      AppLog.instance.trace(
        "lib/pages/catalogue_page.dart::_AlbumPageViewState.initState.closure#1",
      );
      if (mounted) setState(_actionsChanged);
    });
  }

  @override
  void didUpdateWidget(covariant AlbumPageView oldWidget) {
    AppLog.instance.trace(
      "lib/pages/catalogue_page.dart::_AlbumPageViewState.didUpdateWidget",
    );
    super.didUpdateWidget(oldWidget);
    if (oldWidget.runtime == widget.runtime &&
        oldWidget.albumId == widget.albumId &&
        oldWidget.accountIdentity == widget.accountIdentity)
      return;
    oldWidget.runtime.removeListener(_runtimeChanged);
    widget.runtime.addListener(_runtimeChanged);
    _playerChanges?.cancel();
    _playerChanges = widget.runtime.player.changes.listen((_) {
      AppLog.instance.trace(
        "lib/pages/catalogue_page.dart::_AlbumPageViewState.didUpdateWidget.closure#1",
      );
      if (mounted) setState(_actionsChanged);
    });
    _accountEpoch++;
    _continueBusy = false;
    _followBusy = false;
    _overviewRequest++;
    _subscriptionRequest++;
    _overview = null;
    _cloudProgress = null;
    _historyRead = null;
    _following = null;
    _rangeStart = null;
    _album = null;
    _visible = [];
    _complete = null;
    _offline = false;
    _clearSelection();
    _restoreCache();
    _loadSubscription();
    _loadOverview();
    _loadPage(1, target: widget.initialTrack);
  }

  @override
  void dispose() {
    AppLog.instance.trace(
      "lib/pages/catalogue_page.dart::_AlbumPageViewState.dispose",
    );

    widget.runtime.removeListener(_runtimeChanged);
    _generation++;
    _overviewRequest++;
    _playerChanges?.cancel();
    _actionChanges.dispose();
    _cancelCatalogue();
    _range.dispose();
    _albumScroll.dispose();
    _informationScroll.dispose();
    super.dispose();
  }

  void _runtimeChanged() {
    AppLog.instance.trace(
      "lib/pages/catalogue_page.dart::_AlbumPageViewState._runtimeChanged",
    );

    if (!mounted) return;
    final client = _client;
    final accountChanged =
        !identical(client, _libraryClient) ||
        client.cacheIdentity != _libraryKey;
    if (accountChanged) _accountEpoch++;
    final libraryChanged = widget.runtime.libraryRevision != _libraryRevision;
    _libraryRevision = widget.runtime.libraryRevision;
    final downloads = widget.runtime.downloads.tasks;
    final cached = widget.runtime.albumCache[widget.albumId];
    setState(() {
      AppLog.instance.trace(
        "lib/pages/catalogue_page.dart::_AlbumPageViewState._runtimeChanged.closure#1",
      );

      if (accountChanged) {
        _continueBusy = false;
        _followBusy = false;
        _complete = null;
        _overviewRequest++;
        _overview = null;
        _cloudProgress = null;
        _historyRead = null;
        _following = null;
        _rangeStart = null;
        _offline = false;
        _clearSelection();
      }
      if (!listEquals(downloads, _observedDownloads) ||
          !identical(cached, _observedCache)) {
        _observedDownloads = downloads;
        _observedCache = cached;
        _downloaded = _completedTrackIds();
        _selected.removeWhere((id, _) {
          AppLog.instance.trace(
            "lib/pages/catalogue_page.dart::_AlbumPageViewState._runtimeChanged.closure#1.closure#1",
          );
          return _downloaded.contains(id);
        });
        if (_cachedView && _rangeStart == null) _showCached(_page);
      }
    });
    if (accountChanged || (libraryChanged && !_subscriptionMutating)) {
      _loadSubscription();
    }
    if (accountChanged) _loadPage(1, target: widget.initialTrack);
    if (accountChanged) _loadOverview();
    _actionsChanged();
  }

  Map<String, dynamic> get _albumData {
    AppLog.instance.trace(
      "lib/pages/catalogue_page.dart::_AlbumPageViewState._albumData.get",
    );
    return xmlyMap(_overview?['albumData']);
  }

  Map<String, dynamic> get _anchorData {
    AppLog.instance.trace(
      "lib/pages/catalogue_page.dart::_AlbumPageViewState._anchorData.get",
    );
    return xmlyMap(xmlyMap(_overview?['anchor'])['baseAnchor']);
  }

  int get _catalogueTotal {
    AppLog.instance.trace(
      "lib/pages/catalogue_page.dart::_AlbumPageViewState._catalogueTotal.get",
    );
    if (!_cachedView) return _total;
    var total = _album?.total ?? 0;
    if (total > 0) return total;
    for (final track in _cachedTracks()) {
      final position = _trackOrdinal(track) ?? 0;
      if (position > total) total = position;
    }
    return total > 0 ? total : _total;
  }

  Future<void> _loadOverview() async {
    AppLog.instance.trace(
      "lib/pages/catalogue_page.dart::_AlbumPageViewState._loadOverview",
    );
    final client = _client, key = _client.cacheIdentity;
    final albumId = widget.albumId, request = ++_overviewRequest;
    if (!client.accountAvailable) return;
    bool active() {
      AppLog.instance.trace(
        "lib/pages/catalogue_page.dart::_AlbumPageViewState._loadOverview.active",
      );
      return _sameAccount(client, key) &&
          widget.albumId == albumId &&
          request == _overviewRequest;
    }

    final cloud = _historyRead = () async {
      AppLog.instance.trace(
        "lib/pages/catalogue_page.dart::_AlbumPageViewState._loadOverview.closure#1",
      );
      try {
        final progress = await XmlyHistory(client).progress(
          albumId: albumId,
          timeout: const Duration(seconds: 2),
          isActive: active,
        );
        if (active())
          setState(() {
            AppLog.instance.trace(
              "lib/pages/catalogue_page.dart::_AlbumPageViewState._loadOverview.closure#1.closure#1",
            );
            _cloudProgress = progress;
            _actionsChanged();
          });
      } catch (error, stack) {
        _recordCatalogueError(
          'Album cloud history unavailable',
          error,
          stack,
          recoverable: true,
        );
      }
    }();
    try {
      final overview = await client.albumOverview(albumId);
      if (!active()) return;
      setState(() {
        AppLog.instance.trace(
          "lib/pages/catalogue_page.dart::_AlbumPageViewState._loadOverview.closure#2",
        );
        _overview = overview;
        _unavailablePoster = null;
        final follow = _anchorData['follow'];
        _following = follow is bool
            ? follow
            : follow is num
            ? follow == 1
            : null;
        _actionsChanged();
      });
    } catch (error, stack) {
      _recordCatalogueError(
        'Album overview unavailable',
        error,
        stack,
        recoverable: true,
      );
    }
    await cloud;
  }

  Map<String, Track> get _knownAlbumTracks {
    AppLog.instance.trace(
      "lib/pages/catalogue_page.dart::_AlbumPageViewState._knownAlbumTracks.get",
    );
    return {
      for (final track in [
        ..._cachedTracks(),
        ..._visible,
        ...?_complete,
        ...widget.runtime.player.queue,
      ])
        if (track.albumId == widget.albumId) track.id: track,
    };
  }

  ({double position, int updatedAt})? _savedProgress(String trackId) {
    AppLog.instance.trace(
      "lib/pages/catalogue_page.dart::_AlbumPageViewState._savedProgress",
    );
    final library =
        (widget.runtime.storage.state['library'] as Map)[_client.identity];
    final entries = library is Map ? library['playbackProgress'] : null;
    final entry = entries is Map ? entries[trackId] : null;
    if (entry is! Map) return null;
    final position = entry['position'], updatedAt = entry['updatedAt'];
    if (position is! num ||
        !position.isFinite ||
        position < 0 ||
        position > 2147483647 ||
        updatedAt is! int ||
        updatedAt < 0)
      return null;
    return (position: position.toDouble(), updatedAt: updatedAt);
  }

  ({Track track, double position, int updatedAt, bool fromCloud})?
  get _continueRecord {
    AppLog.instance.trace(
      "lib/pages/catalogue_page.dart::_AlbumPageViewState._continueRecord.get",
    );
    final player = widget.runtime.player;
    final current = player.current;
    if (current != null &&
        current.albumId == widget.albumId &&
        player.playbackIdentity == _client.identity &&
        player.sourceKind.isNotEmpty) {
      return (
        track: current,
        position: player.position,
        updatedAt: DateTime.now().millisecondsSinceEpoch,
        fromCloud: false,
      );
    }
    final settings = player.effectiveSettings;
    ({Track track, double position, int updatedAt, bool fromCloud})? latest;
    if (!settings.disableLocalResume) {
      for (final track in _knownAlbumTracks.values) {
        final saved = _savedProgress(track.id);
        if (saved != null &&
            (latest == null || saved.updatedAt > latest.updatedAt)) {
          latest = (
            track: track,
            position: saved.position,
            updatedAt: saved.updatedAt,
            fromCloud: false,
          );
        }
      }
    }
    final cloud = settings.disableCloudResume ? null : _cloudProgress;
    if (cloud != null && cloud['album_id'] == widget.albumId) {
      final updatedAt = ((cloud['updated_at'] as num) * 1000).toInt();
      if (latest == null || updatedAt > latest.updatedAt) {
        latest = (
          track: Track.fromApi({
            'trackId': cloud['track_id'],
            'albumId': widget.albumId,
            'title': cloud['title'],
            'duration': cloud['duration'],
            'albumTitle': cloud['album_title'],
            'cover_url': cloud['cover_url'],
          }),
          position: (cloud['position'] as num).toDouble(),
          updatedAt: updatedAt,
          fromCloud: true,
        );
      }
    }
    return latest;
  }

  String? get _suggestedTrackId {
    AppLog.instance.trace(
      "lib/pages/catalogue_page.dart::_AlbumPageViewState._suggestedTrackId.get",
    );
    final tabs = _overview?['tabs'];
    if (tabs is! List || tabs.isEmpty) return null;
    final id = xmlyPositive(
      xmlyMap(xmlyMap(xmlyMap(tabs.first)['data'])['autoTrack'])['playTrackId'],
    );
    return id?.toString();
  }

  Future<void> _continuePlayback() async {
    AppLog.instance.trace(
      "lib/pages/catalogue_page.dart::_AlbumPageViewState._continuePlayback",
    );
    if (_continueBusy) return;
    final client = _client,
        key = _client.cacheIdentity,
        albumId = widget.albumId;
    final epoch = _accountEpoch;
    bool active() {
      AppLog.instance.trace(
        "lib/pages/catalogue_page.dart::_AlbumPageViewState._continuePlayback.active",
      );
      return _sameAccount(client, key) &&
          epoch == _accountEpoch &&
          widget.albumId == albumId;
    }

    setState(() {
      AppLog.instance.trace(
        "lib/pages/catalogue_page.dart::_AlbumPageViewState._continuePlayback.closure#1",
      );
      _continueBusy = true;
      _actionsChanged();
    });
    try {
      final currentPlayer = widget.runtime.player;
      if ((currentPlayer.current?.albumId != albumId ||
              currentPlayer.playbackIdentity != client.identity ||
              currentPlayer.sourceKind.isEmpty) &&
          !currentPlayer.effectiveSettings.disableCloudResume) {
        await _historyRead;
        if (!active()) return;
      }
      final record = _continueRecord;
      final player = widget.runtime.player;
      if (record != null &&
          player.current?.id == record.track.id &&
          player.playbackIdentity == client.identity &&
          player.sourceKind.isNotEmpty) {
        if (!player.playing) await player.resume();
        return;
      }
      Track? track = record?.track;
      final suggested = _suggestedTrackId;
      if (track == null && suggested != null) {
        track =
            _knownAlbumTracks['xmly:$suggested'] ??
            (_offline ? null : await client.track(suggested));
      }
      if (!active()) return;
      if (track == null) {
        if (_offline) {
          final tracks = _cachedTracks();
          if (tracks.isNotEmpty) track = tracks.first;
        } else {
          final first = await client.album(
            albumId,
            page: 1,
            pageSize: _pageSize,
            ascending: true,
          );
          if (first.tracks.isNotEmpty) track = first.tracks.first;
        }
      }
      if (!active()) return;
      if (track == null)
        throw const XmlyException('missing_track', '专辑暂无可播放的节目');
      if (_offline) {
        await _play(
          track,
          historyProgress: record == null
              ? null
              : (
                  position: record.position,
                  updatedAt: record.updatedAt,
                  fromCloud: record.fromCloud,
                ),
        );
      } else {
        await player.playAlbum(
          albumId,
          track.id,
          track: track,
          accountIdentity: client.identity,
          historyProgress: record == null
              ? null
              : (
                  position: record.position,
                  updatedAt: record.updatedAt,
                  fromCloud: record.fromCloud,
                ),
        );
      }
    } catch (error, stack) {
      _recordCatalogueError('Continue album playback failed', error, stack);
      if (active()) {
        setState(() {
          AppLog.instance.trace(
            "lib/pages/catalogue_page.dart::_AlbumPageViewState._continuePlayback.closure#2",
          );
          _error = _safeError(error);
        });
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(_safeError(error))));
      }
    } finally {
      if (mounted && epoch == _accountEpoch) {
        setState(() {
          AppLog.instance.trace(
            "lib/pages/catalogue_page.dart::_AlbumPageViewState._continuePlayback.closure#3",
          );
          _continueBusy = false;
          _actionsChanged();
        });
      }
    }
  }

  Widget _footer() {
    AppLog.instance.trace(
      "lib/pages/catalogue_page.dart::_AlbumPageViewState._footer",
    );
    return ListenableBuilder(
      listenable: _actionChanges,
      builder: (context, _) {
        AppLog.instance.trace(
          "lib/pages/catalogue_page.dart::_AlbumPageViewState._footer.closure#1",
        );
        final record = _continueRecord;
        final title = record?.track.title ?? '';
        return AlbumActionBar(
          subscribed: _subscribed,
          subscriptionBusy: _subscriptionBusy,
          subscriptionError: _subscriptionError,
          onSubscribe: _changeSubscription,
          playBusy: _continueBusy,
          playLabel: record == null
              ? _suggestedTrackId == null
                    ? '开始播放'
                    : '播放'
              : title.isEmpty
              ? '续播'
              : '续播 · $title',
          onPlay: _album == null ? null : _continuePlayback,
        );
      },
    );
  }

  void _openAlbum(String id) {
    AppLog.instance.trace(
      "lib/pages/catalogue_page.dart::_AlbumPageViewState._openAlbum",
    );
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) {
          AppLog.instance.trace(
            "lib/pages/catalogue_page.dart::_AlbumPageViewState._openAlbum.closure#1",
          );
          return AlbumPageView(
            runtime: widget.runtime,
            albumId: id,
            accountIdentity: widget.accountIdentity,
            onDownload: widget.onDownload,
            onPlayAlbum: widget.onPlayAlbum,
          );
        },
      ),
    );
  }

  void _openAnchor() {
    AppLog.instance.trace(
      "lib/pages/catalogue_page.dart::_AlbumPageViewState._openAnchor",
    );
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        settings: const RouteSettings(name: AnchorPage.routeName),
        builder: (_) {
          AppLog.instance.trace(
            "lib/pages/catalogue_page.dart::_AlbumPageViewState._openAnchor.closure#1",
          );
          return AnchorPage(
            runtime: widget.runtime,
            uid:
                xmlyPositive(_anchorData['uid'])?.toString() ??
                _album?.anchorUid,
            albumId: widget.albumId,
            initialName: '${_anchorData['nickName'] ?? _album?.artist ?? ''}',
            accountIdentity: widget.accountIdentity,
            onDownload: widget.onDownload,
            onPlayAlbum: widget.onPlayAlbum,
          );
        },
      ),
    );
  }

  Future<void> _followAnchor() async {
    AppLog.instance.trace(
      "lib/pages/catalogue_page.dart::_AlbumPageViewState._followAnchor",
    );
    final uid =
        xmlyPositive(_anchorData['uid'])?.toString() ?? _album?.anchorUid;
    if (uid == null || _followBusy) return;
    final client = _client, key = _client.cacheIdentity, epoch = _accountEpoch;
    bool active() {
      AppLog.instance.trace(
        "lib/pages/catalogue_page.dart::_AlbumPageViewState._followAnchor.active",
      );
      return _sameAccount(client, key) && epoch == _accountEpoch;
    }

    setState(() {
      AppLog.instance.trace(
        "lib/pages/catalogue_page.dart::_AlbumPageViewState._followAnchor.closure#1",
      );
      _followBusy = true;
    });
    try {
      await widget.runtime.accounts.runWithAccount(client.identity, (
        admitted,
      ) async {
        AppLog.instance.trace(
          "lib/pages/catalogue_page.dart::_AlbumPageViewState._followAnchor.closure#2",
        );
        if (!active() || !identical(client, admitted))
          throw const XmlyException('account_changed', '账号已变更，请重试');
        final api = XmlyAnchor(client);
        final previous = _following ?? await api.isFollowing(uid);
        if (!active()) return;
        await api.setFollowing(uid, following: !previous);
        if (active())
          setState(() {
            AppLog.instance.trace(
              "lib/pages/catalogue_page.dart::_AlbumPageViewState._followAnchor.closure#2.closure#1",
            );
            _following = !previous;
          });
      });
      widget.runtime.libraryChanged();
    } catch (error, stack) {
      _recordCatalogueError('Album anchor follow failed', error, stack);
      if (active())
        setState(() {
          AppLog.instance.trace(
            "lib/pages/catalogue_page.dart::_AlbumPageViewState._followAnchor.closure#3",
          );
          _error = _safeError(error);
        });
    } finally {
      if (mounted && epoch == _accountEpoch)
        setState(() {
          AppLog.instance.trace(
            "lib/pages/catalogue_page.dart::_AlbumPageViewState._followAnchor.closure#4",
          );
          _followBusy = false;
        });
    }
  }

  void _openBulkDownload() {
    AppLog.instance.trace(
      "lib/pages/catalogue_page.dart::_AlbumPageViewState._openBulkDownload",
    );
    final album = _album;
    if (album == null) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) {
          AppLog.instance.trace(
            "lib/pages/catalogue_page.dart::_AlbumPageViewState._openBulkDownload.closure#1",
          );
          return AlbumBulkDownloadPage(
            runtime: widget.runtime,
            album: album,
            accountIdentity: widget.accountIdentity,
          );
        },
      ),
    );
  }

  void _openSearch() {
    AppLog.instance.trace(
      "lib/pages/catalogue_page.dart::_AlbumPageViewState._openSearch",
    );
    final album = _album;
    if (album == null) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) {
          AppLog.instance.trace(
            "lib/pages/catalogue_page.dart::_AlbumPageViewState._openSearch.closure#1",
          );
          return AlbumSearchPage(
            runtime: widget.runtime,
            album: album,
            accountIdentity: widget.accountIdentity,
            onDownload: widget.onDownload,
          );
        },
      ),
    );
  }

  Future<void> _chooseRange() async {
    AppLog.instance.trace(
      "lib/pages/catalogue_page.dart::_AlbumPageViewState._chooseRange",
    );
    if (_catalogueTotal < 1 || _busy) return;
    final epoch = _accountEpoch, total = _catalogueTotal;
    final start = await showDialog<int>(
      context: context,
      barrierLabel: '关闭集数选择',
      builder: (context) {
        AppLog.instance.trace(
          "lib/pages/catalogue_page.dart::_AlbumPageViewState._chooseRange.closure#1",
        );
        return Dialog(
          insetPadding: const EdgeInsets.symmetric(
            horizontal: 12,
            vertical: 80,
          ),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 700),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    const SizedBox(width: 16),
                    Expanded(
                      child: Text(
                        '共$total集',
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ),
                    IconButton(
                      autofocus: true,
                      tooltip: '关闭集数选择',
                      onPressed: () {
                        AppLog.instance.trace(
                          "lib/pages/catalogue_page.dart::_AlbumPageViewState._chooseRange.closure#1.closure#1",
                        );
                        return Navigator.pop(context);
                      },
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
                Flexible(
                  child: GridView.builder(
                    shrinkWrap: true,
                    padding: const EdgeInsets.all(12),
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 3,
                      mainAxisSpacing: 12,
                      crossAxisSpacing: 10,
                      mainAxisExtent:
                          MediaQuery.textScalerOf(context).scale(16) + 30,
                    ),
                    itemCount: (total + _pageSize - 1) ~/ _pageSize,
                    itemBuilder: (context, index) {
                      AppLog.instance.trace(
                        "lib/pages/catalogue_page.dart::_AlbumPageViewState._chooseRange.closure#1.closure#2",
                      );
                      final first = index * _pageSize + 1,
                          last = ((index + 1) * _pageSize).clamp(1, total);
                      final position =
                          _rangeStart ??
                          (_visible.isEmpty
                              ? 1
                              : _trackOrdinal(_visible.first) ?? 1);
                      final selected = position >= first && position <= last;
                      return Semantics(
                        selected: selected,
                        child: TextButton(
                          style: TextButton.styleFrom(
                            foregroundColor: selected
                                ? const Color(0xffff414a)
                                : Theme.of(context).colorScheme.onSurface,
                            backgroundColor: selected
                                ? const Color(0xffffeeee)
                                : Theme.of(context)
                                      .colorScheme
                                      .surfaceContainerLow,
                            padding: const EdgeInsets.symmetric(horizontal: 4),
                          ),
                          onPressed: () {
                            AppLog.instance.trace(
                              "lib/pages/catalogue_page.dart::_AlbumPageViewState._chooseRange.closure#1.closure#2.closure#1",
                            );
                            return Navigator.pop(context, first);
                          },
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Text('$first–$last'),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
    if (start != null && mounted && epoch == _accountEpoch)
      await _loadRange(start);
  }

  Future<void> _loadRange(int start) async {
    AppLog.instance.trace(
      "lib/pages/catalogue_page.dart::_AlbumPageViewState._loadRange",
    );
    final total = _catalogueTotal,
        end = (start + _pageSize - 1).clamp(start, _catalogueTotal);
    final firstPage = (_ascending ? start - 1 : total - end) ~/ _pageSize + 1;
    final lastPage = (_ascending ? end - 1 : total - start) ~/ _pageSize + 1;
    final client = _client,
        key = _client.cacheIdentity,
        albumId = widget.albumId;
    final generation = ++_generation;
    _cancelCatalogue();
    setState(() {
      AppLog.instance.trace(
        "lib/pages/catalogue_page.dart::_AlbumPageViewState._loadRange.closure#1",
      );
      _busy = true;
      _rangeStart = start;
      _error = null;
    });
    try {
      List<Track> tracks;
      if (_offline || _cachedView) {
        tracks = _orderedForDisplay(_cachedTracks());
      } else {
        tracks = await _readCatalogue(client, () async {
          AppLog.instance.trace(
            "lib/pages/catalogue_page.dart::_AlbumPageViewState._loadRange.closure#2",
          );
          final result = <Track>[];
          for (var page = firstPage; page <= lastPage; page++) {
            if (!_sameAccount(client, key) || generation != _generation)
              throw const XmlyException('request_cancelled', '请求已取消');
            final response = await client.album(
              albumId,
              page: page,
              pageSize: _pageSize,
              ascending: _ascending,
            );
            if (response.total != total)
              throw const XmlyException('catalogue_changed', '专辑节目已更新，请刷新后选择');
            result.addAll(response.tracks);
            unawaited(_rememberPage(response));
          }
          return result;
        });
      }
      if (!_sameAccount(client, key) || generation != _generation) return;
      setState(() {
        AppLog.instance.trace(
          "lib/pages/catalogue_page.dart::_AlbumPageViewState._loadRange.closure#3",
        );
        _page = firstPage;
        _visible = tracks.where((track) {
          AppLog.instance.trace(
            "lib/pages/catalogue_page.dart::_AlbumPageViewState._loadRange.closure#3.closure#1",
          );
          final position = track.officialPosition;
          return position != null && position >= start && position <= end;
        }).toList();
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        AppLog.instance.trace(
          "lib/pages/catalogue_page.dart::_AlbumPageViewState._loadRange.closure#4",
        );
        if (!mounted || generation != _generation || !_albumScroll.hasClients)
          return;
        final header = _headerKey.currentContext?.findRenderObject();
        if (header is RenderBox && header.hasSize) {
          _albumScroll.jumpTo(
            header.size.height.clamp(
              0.0,
              _albumScroll.position.maxScrollExtent,
            ),
          );
        }
      });
    } catch (error, stack) {
      _recordCatalogueError('Album range load failed', error, stack);
      if (_sameAccount(client, key) && generation == _generation)
        setState(() {
          AppLog.instance.trace(
            "lib/pages/catalogue_page.dart::_AlbumPageViewState._loadRange.closure#5",
          );
          _error = _safeError(error);
          _rangeStart = null;
        });
    } finally {
      if (mounted && generation == _generation)
        setState(() {
          AppLog.instance.trace(
            "lib/pages/catalogue_page.dart::_AlbumPageViewState._loadRange.closure#6",
          );
          _busy = false;
        });
    }
  }

  void _cancelCatalogue() {
    AppLog.instance.trace(
      "lib/pages/catalogue_page.dart::_AlbumPageViewState._cancelCatalogue",
    );

    _catalogueCancelled?.complete();
    _catalogueCancelled = null;
  }

  Future<T> _readCatalogue<T>(
    XmlyClient client,
    Future<T> Function() read,
  ) async {
    AppLog.instance.trace(
      "lib/pages/catalogue_page.dart::_AlbumPageViewState._readCatalogue",
    );

    _cancelCatalogue();
    final cancelled = _catalogueCancelled = Completer<void>();
    try {
      return await client.withReadPolicy(
        read,
        rateLimitRetries: 4,
        cancelled: cancelled.future,
      );
    } finally {
      if (identical(_catalogueCancelled, cancelled)) {
        _catalogueCancelled = null;
      }
    }
  }

  List<Track> _cachedTracks() {
    AppLog.instance.trace(
      "lib/pages/catalogue_page.dart::_AlbumPageViewState._cachedTracks",
    );

    final cached = widget.runtime.albumCache[widget.albumId];
    final tracks = <String, Track>{
      for (final track in cached?.tracks ?? <Track>[]) track.id: track,
    };
    for (final task in widget.runtime.downloads.tasks) {
      if (task.track.albumId == widget.albumId) {
        tracks.putIfAbsent(task.track.id, () {
          AppLog.instance.trace(
            "lib/pages/catalogue_page.dart::_AlbumPageViewState._cachedTracks.closure#1",
          );
          return task.track;
        });
      }
    }
    return tracks.values.toList()..sort((a, b) {
      AppLog.instance.trace(
        "lib/pages/catalogue_page.dart::_AlbumPageViewState._cachedTracks.closure#2",
      );
      return (a.officialPosition ?? a.orderNo ?? 5001).compareTo(
        b.officialPosition ?? b.orderNo ?? 5001,
      );
    });
  }

  void _restoreCache({int page = 1}) {
    AppLog.instance.trace(
      "lib/pages/catalogue_page.dart::_AlbumPageViewState._restoreCache",
    );

    final cached = widget.runtime.albumCache[widget.albumId];
    final tracks = _cachedTracks();
    if (cached == null && tracks.isEmpty) return;
    _album =
        cached?.album ??
        Album(
          id: widget.albumId,
          title: tracks.first.album,
          artist: tracks.first.artist,
          coverUrl: tracks.first.coverUrl,
        );
    _showCached(page, orderedTracks: _orderedForDisplay(tracks));
  }

  void _showCached(int page, {List<Track>? orderedTracks}) {
    AppLog.instance.trace(
      "lib/pages/catalogue_page.dart::_AlbumPageViewState._showCached",
    );

    _cachedView = true;
    final tracks = orderedTracks ?? _orderedForDisplay(_cachedTracks());
    _total = tracks.length;
    _page = page.clamp(
      1,
      ((_total + _pageSize - 1) ~/ _pageSize).clamp(1, 10000),
    );
    _visible = tracks.skip((_page - 1) * _pageSize).take(_pageSize).toList();
  }

  Future<DownloadTask?> _localDownload(Track track) async {
    AppLog.instance.trace(
      "lib/pages/catalogue_page.dart::_AlbumPageViewState._localDownload",
    );

    final tasks = widget.runtime.downloads.tasks.where((task) {
      AppLog.instance.trace(
        "lib/pages/catalogue_page.dart::_AlbumPageViewState._localDownload.closure#1",
      );
      return task.track.id == track.id && task.state == DownloadState.completed;
    }).toList();
    tasks.sort((a, b) {
      AppLog.instance.trace(
        "lib/pages/catalogue_page.dart::_AlbumPageViewState._localDownload.closure#2",
      );
      return (b.accountIdentity == widget.runtime.player.libraryIdentity
              ? 1
              : 0)
          .compareTo(
            a.accountIdentity == widget.runtime.player.libraryIdentity ? 1 : 0,
          );
    });
    for (final task in tasks) {
      if (task.finalPath != null && await File(task.finalPath!).exists())
        return task;
    }
    return null;
  }

  Set<String> _completedTrackIds() {
    AppLog.instance.trace(
      "lib/pages/catalogue_page.dart::_AlbumPageViewState._completedTrackIds",
    );
    return {
      for (final task in widget.runtime.downloads.tasks)
        if (task.state == DownloadState.completed) task.track.id,
    };
  }

  void _select(Track track, bool selected) {
    AppLog.instance.trace(
      "lib/pages/catalogue_page.dart::_AlbumPageViewState._select",
    );

    if (selected && !_downloaded.contains(track.id)) {
      _selected[track.id] = track;
    } else {
      _selected.remove(track.id);
    }
  }

  void _clearSelection() {
    AppLog.instance.trace(
      "lib/pages/catalogue_page.dart::_AlbumPageViewState._clearSelection",
    );

    _selected.clear();
    _range.clear();
    _selectionMode = false;
  }

  bool _sameAccount(XmlyClient client, String key) {
    AppLog.instance.trace(
      "lib/pages/catalogue_page.dart::_AlbumPageViewState._sameAccount",
    );
    return mounted &&
        identical(client, _client) &&
        key == _client.cacheIdentity;
  }

  Future<void> _loadSubscription() {
    AppLog.instance.trace(
      "lib/pages/catalogue_page.dart::_AlbumPageViewState._loadSubscription",
    );
    return AppLog.instance.runWithErrorScope(() async {
      AppLog.instance.trace(
        "lib/pages/catalogue_page.dart::_AlbumPageViewState._loadSubscription.closure#1",
      );

      final client = _client, key = _client.cacheIdentity;
      final request = ++_subscriptionRequest;
      _libraryClient = client;
      _libraryKey = key;
      _libraryRevision = widget.runtime.libraryRevision;
      setState(() {
        AppLog.instance.trace(
          "lib/pages/catalogue_page.dart::_AlbumPageViewState._loadSubscription.closure#1.closure#1",
        );

        _subscribed = null;
        _subscriptionError = null;
        _subscriptionBusy = client.accountAvailable;
        _subscriptionMutating = false;
        _actionsChanged();
      });
      if (!client.accountAvailable) return;
      try {
        final subscribed = await XmlyExperience(client)
            .isSubscribed(widget.albumId);
        if (_sameAccount(client, key) && request == _subscriptionRequest) {
          setState(() {
            AppLog.instance.trace(
              "lib/pages/catalogue_page.dart::_AlbumPageViewState._loadSubscription.closure#1.closure#2",
            );
            _subscribed = subscribed;
          });
        }
      } catch (error, stack) {
        _recordCatalogueError('Subscription status failed', error, stack);
        if (_sameAccount(client, key) && request == _subscriptionRequest) {
          setState(() {
            AppLog.instance.trace(
              "lib/pages/catalogue_page.dart::_AlbumPageViewState._loadSubscription.closure#1.closure#3",
            );
            _subscriptionError = _safeError(error);
          });
        }
      } finally {
        if (_sameAccount(client, key) && request == _subscriptionRequest) {
          setState(() {
            AppLog.instance.trace(
              "lib/pages/catalogue_page.dart::_AlbumPageViewState._loadSubscription.closure#1.closure#4",
            );
            _subscriptionBusy = false;
            _actionsChanged();
          });
        }
      }
    });
  }

  Future<void> _changeSubscription() {
    AppLog.instance.trace(
      "lib/pages/catalogue_page.dart::_AlbumPageViewState._changeSubscription",
    );
    return AppLog.instance.runWithErrorScope(() async {
      AppLog.instance.trace(
        "lib/pages/catalogue_page.dart::_AlbumPageViewState._changeSubscription.closure#1",
      );

      if (_subscriptionBusy) return;
      final client = _client, key = _client.cacheIdentity;
      if (!client.accountAvailable) {
        setState(() {
          AppLog.instance.trace(
            "lib/pages/catalogue_page.dart::_AlbumPageViewState._changeSubscription.closure#1.closure#1",
          );
          _subscriptionError = '请先登录后订阅专辑';
          _actionsChanged();
        });
        return;
      }
      final subscribed = _subscribed;
      if (subscribed == null) return _loadSubscription();
      final desired = !subscribed, request = ++_subscriptionRequest;
      var attempted = false;
      setState(() {
        AppLog.instance.trace(
          "lib/pages/catalogue_page.dart::_AlbumPageViewState._changeSubscription.closure#1.closure#2",
        );

        _subscriptionBusy = true;
        _subscriptionMutating = true;
        _subscriptionError = null;
        _actionsChanged();
      });
      try {
        await widget.runtime.accounts.runWithAccount(client.identity, (
          admitted,
        ) async {
          AppLog.instance.trace(
            "lib/pages/catalogue_page.dart::_AlbumPageViewState._changeSubscription.closure#1.closure#3",
          );

          if (!_sameAccount(client, key) || !identical(admitted, client)) {
            throw const XmlyException('account_changed', '账号已变更，请重试');
          }
          attempted = true;
          await XmlyExperience(client)
              .setSubscribed(widget.albumId, subscribed: desired);
        });
        widget.runtime.libraryChanged();
        if (_sameAccount(client, key) && request == _subscriptionRequest) {
          setState(() {
            AppLog.instance.trace(
              "lib/pages/catalogue_page.dart::_AlbumPageViewState._changeSubscription.closure#1.closure#4",
            );
            _subscribed = desired;
          });
        }
      } catch (error, stack) {
        _recordCatalogueError('Subscription change failed', error, stack);
        if (attempted) widget.runtime.libraryChanged();
        if (!_sameAccount(client, key) || request != _subscriptionRequest)
          return;
        setState(() {
          AppLog.instance.trace(
            "lib/pages/catalogue_page.dart::_AlbumPageViewState._changeSubscription.closure#1.closure#5",
          );

          _subscribed = null;
          _subscriptionError = _safeError(error);
        });
        try {
          final value = await XmlyExperience(client)
              .isSubscribed(widget.albumId);
          if (_sameAccount(client, key) && request == _subscriptionRequest) {
            setState(() {
              AppLog.instance.trace(
                "lib/pages/catalogue_page.dart::_AlbumPageViewState._changeSubscription.closure#1.closure#6",
              );
              _subscribed = value;
            });
          }
        } catch (error, stack) {
          _recordCatalogueError(
            'Subscription reconciliation failed',
            error,
            stack,
            recoverable: true,
          );
          // Keep the unknown state and offer an explicit status retry.
        }
      } finally {
        if (_sameAccount(client, key) && request == _subscriptionRequest) {
          setState(() {
            AppLog.instance.trace(
              "lib/pages/catalogue_page.dart::_AlbumPageViewState._changeSubscription.closure#1.closure#7",
            );

            _subscriptionBusy = false;
            _subscriptionMutating = false;
            _actionsChanged();
          });
        }
      }
    });
  }

  void _scanUpdates() {
    AppLog.instance.trace(
      "lib/pages/catalogue_page.dart::_AlbumPageViewState._scanUpdates",
    );

    for (final identity in widget.runtime.accounts.accountIds) {
      unawaited(
        widget.runtime.autoDownloads.scanAlbum(identity, widget.albumId),
      );
    }
  }

  Future<void> _autoDownload(String identity) {
    AppLog.instance.trace(
      "lib/pages/catalogue_page.dart::_AlbumPageViewState._autoDownload",
    );
    return AppLog.instance.runWithErrorScope(() async {
      AppLog.instance.trace(
        "lib/pages/catalogue_page.dart::_AlbumPageViewState._autoDownload.closure#1",
      );

      setState(() {
        AppLog.instance.trace(
          "lib/pages/catalogue_page.dart::_AlbumPageViewState._autoDownload.closure#1.closure#1",
        );

        _autoBusy = true;
        _error = null;
      });
      try {
        await setAlbumAutoDownload(
          context,
          widget.runtime.autoDownloads,
          identity,
          widget.albumId,
          _album?.title ?? '',
        );
      } catch (error, stack) {
        _recordCatalogueError(
          'Automatic download setting failed',
          error,
          stack,
        );
        if (mounted)
          setState(() {
            AppLog.instance.trace(
              "lib/pages/catalogue_page.dart::_AlbumPageViewState._autoDownload.closure#1.closure#2",
            );
            _error = _safeError(error);
          });
      } finally {
        if (mounted)
          setState(() {
            AppLog.instance.trace(
              "lib/pages/catalogue_page.dart::_AlbumPageViewState._autoDownload.closure#1.closure#3",
            );
            _autoBusy = false;
          });
      }
    });
  }

  double get _trackExtent {
    AppLog.instance.trace(
      "lib/pages/catalogue_page.dart::_AlbumPageViewState._trackExtent.get",
    );
    final scaler = MediaQuery.textScalerOf(context);
    return (scaler.scale(16) * 1.5 + scaler.scale(12) * 1.5 + 30).clamp(
      84.0,
      double.infinity,
    );
  }

  void _revealTarget(Track target, int generation) {
    AppLog.instance.trace(
      "lib/pages/catalogue_page.dart::_AlbumPageViewState._revealTarget",
    );

    final index = _visible.indexWhere((track) {
      AppLog.instance.trace(
        "lib/pages/catalogue_page.dart::_AlbumPageViewState._revealTarget.closure#1",
      );
      return track.id == target.id && track.albumId == widget.albumId;
    });
    if (index < 0) {
      setState(() {
        AppLog.instance.trace(
          "lib/pages/catalogue_page.dart::_AlbumPageViewState._revealTarget.closure#2",
        );
        _targetWarning = '当前目录没有找到这集，目标信息已保留，可重新定位。';
      });
      return;
    }
    setState(() {
      AppLog.instance.trace(
        "lib/pages/catalogue_page.dart::_AlbumPageViewState._revealTarget.closure#3",
      );
      _targetWarning = null;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      AppLog.instance.trace(
        "lib/pages/catalogue_page.dart::_AlbumPageViewState._revealTarget.closure#4",
      );

      if (!mounted || generation != _generation || !_albumScroll.hasClients)
        return;
      final header = _headerKey.currentContext?.findRenderObject();
      if (header is! RenderBox || !header.hasSize) return;
      final offset = header.size.height + index * _trackExtent;
      _albumScroll.jumpTo(
        offset.clamp(
          _albumScroll.position.minScrollExtent,
          _albumScroll.position.maxScrollExtent,
        ),
      );
    });
  }

  Future<void> _loadPage(int page, {Track? target}) {
    AppLog.instance.trace(
      "lib/pages/catalogue_page.dart::_AlbumPageViewState._loadPage",
    );
    return AppLog.instance.runWithErrorScope(() async {
      AppLog.instance.trace(
        "lib/pages/catalogue_page.dart::_AlbumPageViewState._loadPage.closure#1",
      );

      final generation = ++_generation;
      _cancelCatalogue();
      _rangeStart = null;
      if (target != null) {
        final available = _complete != null
            ? _orderedForDisplay(_complete!)
            : (_cachedView || _offline)
            ? _orderedForDisplay(_cachedTracks())
            : null;
        if (available != null) {
          final tracks = available;
          final index = tracks.indexWhere((track) {
            AppLog.instance.trace(
              "lib/pages/catalogue_page.dart::_AlbumPageViewState._loadPage.closure#1.closure#1",
            );
            return track.id == target.id && track.albumId == widget.albumId;
          });
          if (index >= 0) {
            setState(() {
              AppLog.instance.trace(
                "lib/pages/catalogue_page.dart::_AlbumPageViewState._loadPage.closure#1.closure#2",
              );
              _page = index ~/ _pageSize + 1;
              _total = tracks.length;
              _visible = tracks
                  .skip((_page - 1) * _pageSize)
                  .take(_pageSize)
                  .toList();
              _busy = false;
              _error = null;
            });
            _revealTarget(target, generation);
            return;
          }
        }
      }
      if (_offline) {
        final tracks = _orderedForDisplay(_cachedTracks());
        if (target != null) {
          final index = tracks.indexWhere((track) {
            AppLog.instance.trace(
              "lib/pages/catalogue_page.dart::_AlbumPageViewState._loadPage.closure#1.closure#3",
            );
            return track.id == target.id && track.albumId == widget.albumId;
          });
          if (index >= 0) page = index ~/ _pageSize + 1;
        }
        setState(() {
          AppLog.instance.trace(
            "lib/pages/catalogue_page.dart::_AlbumPageViewState._loadPage.closure#1.closure#4",
          );
          _showCached(page, orderedTracks: tracks);
        });
        if (target != null) _revealTarget(target, _generation);
        return;
      }
      final client = _client, key = _client.cacheIdentity;
      setState(() {
        AppLog.instance.trace(
          "lib/pages/catalogue_page.dart::_AlbumPageViewState._loadPage.closure#1.closure#5",
        );

        _busy = true;
        _error = null;
      });
      try {
        final result = await _readCatalogue(client, () {
          AppLog.instance.trace(
            "lib/pages/catalogue_page.dart::_AlbumPageViewState._loadPage.closure#1.closure#6",
          );
          if (target != null)
            return locateCatalogueTarget(
              client: client,
              albumId: widget.albumId,
              target: target,
              ascending: _ascending,
              isCurrent: () {
                AppLog.instance.trace(
                  "lib/pages/catalogue_page.dart::_AlbumPageViewState._loadPage.closure#1.closure#6.closure#1",
                );
                return _sameAccount(client, key) && generation == _generation;
              },
            );
          return client.album(
            widget.albumId,
            page: page,
            pageSize: _pageSize,
            ascending: _ascending,
          );
        });
        if (!_sameAccount(client, key) || generation != _generation) return;
        if (_sameAccount(client, key) && generation == _generation) {
          setState(() {
            AppLog.instance.trace(
              "lib/pages/catalogue_page.dart::_AlbumPageViewState._loadPage.closure#1.closure#7",
            );

            _offline = false;
            _cachedView = false;
            _complete = null;
            _album = result.album;
            _page = result.page;
            _total = result.total;
            _visible = result.tracks;
          });
          if (target != null) _revealTarget(target, generation);
          unawaited(_rememberPage(result));
        }
      } catch (error, stack) {
        _recordCatalogueError('Catalogue load failed', error, stack);
        if (_sameAccount(client, key) && generation == _generation) {
          setState(() {
            AppLog.instance.trace(
              "lib/pages/catalogue_page.dart::_AlbumPageViewState._loadPage.closure#1.closure#8",
            );

            if (target == null || _album == null) {
              _restoreCache(page: page);
              _offline = _album != null;
            }
            _error = _album == null ? _safeError(error) : null;
            if (target != null) _targetWarning = '暂时无法定位这集，目标信息已保留，请重新定位。';
          });
          if (_offline && target != null) {
            final index = _orderedForDisplay(_cachedTracks()).indexWhere((
              track,
            ) {
              AppLog.instance.trace(
                "lib/pages/catalogue_page.dart::_AlbumPageViewState._loadPage.closure#1.closure#9",
              );
              return track.id == target.id && track.albumId == widget.albumId;
            });
            if (index >= 0) {
              setState(() {
                AppLog.instance.trace(
                  "lib/pages/catalogue_page.dart::_AlbumPageViewState._loadPage.closure#1.closure#10",
                );
                _showCached(index ~/ _pageSize + 1);
              });
              _revealTarget(target, generation);
            }
          }
        }
      } finally {
        if (mounted && generation == _generation)
          setState(() {
            AppLog.instance.trace(
              "lib/pages/catalogue_page.dart::_AlbumPageViewState._loadPage.closure#1.closure#11",
            );
            _busy = false;
          });
      }
    });
  }

  Future<void> _rememberPage(AlbumPage page) {
    AppLog.instance.trace(
      "lib/pages/catalogue_page.dart::_AlbumPageViewState._rememberPage",
    );
    return AppLog.instance.runWithErrorScope(() async {
      AppLog.instance.trace(
        "lib/pages/catalogue_page.dart::_AlbumPageViewState._rememberPage.closure#1",
      );

      try {
        await widget.runtime.albumCache.remember(page);
      } catch (error, stack) {
        _recordCatalogueError(
          'Catalogue cache failed',
          error,
          stack,
          recoverable: true,
        );
        // Optional cache failures never delay or replace the live catalogue.
      }
    });
  }

  List<Track> _orderedForDisplay(List<Track> tracks) {
    AppLog.instance.trace(
      "lib/pages/catalogue_page.dart::_AlbumPageViewState._orderedForDisplay",
    );
    return _ascending ? tracks : tracks.reversed.toList();
  }

  Future<void> _setOrder(bool ascending) {
    AppLog.instance.trace(
      "lib/pages/catalogue_page.dart::_AlbumPageViewState._setOrder",
    );
    return AppLog.instance.runWithErrorScope(() async {
      AppLog.instance.trace(
        "lib/pages/catalogue_page.dart::_AlbumPageViewState._setOrder.closure#1",
      );

      if (_busy || _ascending == ascending) return;
      final epoch = _accountEpoch;
      setState(() {
        AppLog.instance.trace(
          "lib/pages/catalogue_page.dart::_AlbumPageViewState._setOrder.closure#1.closure#1",
        );

        _busy = true;
        _error = null;
      });
      try {
        await widget.runtime.storage.transaction((state) {
          AppLog.instance.trace(
            "lib/pages/catalogue_page.dart::_AlbumPageViewState._setOrder.closure#1.closure#2",
          );

          (state['settings'] as Map)['catalogueAscending'] = ascending;
        });
        if (!mounted) return;
        setState(() {
          AppLog.instance.trace(
            "lib/pages/catalogue_page.dart::_AlbumPageViewState._setOrder.closure#1.closure#3",
          );

          _ascending = ascending;
          _selected.clear();
        });
        await _loadPage(1);
        if (mounted && _albumScroll.hasClients) {
          _albumScroll.jumpTo(_albumScroll.position.minScrollExtent);
        }
      } catch (error, stack) {
        _recordCatalogueError('Catalogue order failed', error, stack);
        if (mounted && epoch == _accountEpoch)
          setState(() {
            AppLog.instance.trace(
              "lib/pages/catalogue_page.dart::_AlbumPageViewState._setOrder.closure#1.closure#4",
            );
            _error = '目录排序保存失败，请重试';
          });
      } finally {
        if (mounted && epoch == _accountEpoch)
          setState(() {
            AppLog.instance.trace(
              "lib/pages/catalogue_page.dart::_AlbumPageViewState._setOrder.closure#1.closure#5",
            );
            _busy = false;
          });
      }
    });
  }

  Widget _orderControl() {
    AppLog.instance.trace(
      "lib/pages/catalogue_page.dart::_AlbumPageViewState._orderControl",
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                key: const ValueKey('albumOrderToggle'),
                onPressed: _busy
                    ? null
                    : () {
                        AppLog.instance.trace(
                          "lib/pages/catalogue_page.dart::_AlbumPageViewState._orderControl.closure#1",
                        );
                        _setOrder(!_ascending);
                      },
                icon: const Icon(Icons.sort_rounded, size: 20),
                label: Text(
                  _ascending ? '从旧到新' : '从新到旧',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                style: TextButton.styleFrom(
                  foregroundColor: Colors.grey,
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                ),
              ),
            ),
          ),
          IconButton(
            tooltip: '搜索本专辑',
            onPressed: _album == null ? null : _openSearch,
            icon: const Icon(Icons.search, color: Colors.grey),
          ),
          IconButton(
            tooltip: '批量下载',
            onPressed: _album == null ? null : _openBulkDownload,
            icon: const Icon(Icons.download_outlined, color: Colors.grey),
          ),
          Expanded(
            child: TextButton(
              onPressed: _busy ? null : _chooseRange,
              style: TextButton.styleFrom(
                foregroundColor: _rangeStart == null
                    ? Colors.grey
                    : const Color(0xffff414a),
                padding: const EdgeInsets.symmetric(horizontal: 4),
                alignment: Alignment.centerRight,
              ),
              child: Text(
                '共$_catalogueTotal集⌄',
                textAlign: TextAlign.right,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<List<Track>> _all() async {
    AppLog.instance.trace(
      "lib/pages/catalogue_page.dart::_AlbumPageViewState._all",
    );

    if (_complete != null) return _complete!;
    if (_offline) {
      throw const XmlyException('offline_catalogue', '离线目录不完整，无法按完整专辑下载');
    }
    final generation = _generation, client = _client;
    final identity = client.cacheIdentity;
    final tracks = await _readCatalogue(client, () {
      AppLog.instance.trace(
        "lib/pages/catalogue_page.dart::_AlbumPageViewState._all.closure#1",
      );
      return XmlyCatalogue(client).album(widget.albumId);
    });
    if (!mounted ||
        generation != _generation ||
        !identical(client, _client) ||
        identity != _client.cacheIdentity) {
      throw const XmlyException('catalogue_changed', '专辑目录已变化，请重新操作');
    }
    _complete = tracks;
    return tracks;
  }

  Future<void> _download() {
    AppLog.instance.trace(
      "lib/pages/catalogue_page.dart::_AlbumPageViewState._download",
    );
    return AppLog.instance.runWithErrorScope(() async {
      AppLog.instance.trace(
        "lib/pages/catalogue_page.dart::_AlbumPageViewState._download.closure#1",
      );

      if (_busy) return;
      final generation = _generation;
      final range = _range.text.trim();
      final selected = _selected.values.toList();
      setState(() {
        AppLog.instance.trace(
          "lib/pages/catalogue_page.dart::_AlbumPageViewState._download.closure#1.closure#1",
        );

        _busy = true;
        _error = null;
      });
      try {
        final requested = range.isNotEmpty
            ? XmlyCatalogue.selectRange(await _all(), range)
            : selected;
        if (requested.isEmpty)
          throw const XmlyException('empty_selection', '请选择未下载的声音或填写集数范围');
        if (!mounted) return;
        // Preparation checks completed files before deduplicating their tasks.
        await requestDownloads(
          context,
          widget.runtime,
          requested,
          accountIdentity: widget.accountIdentity,
        );
      } catch (error, stack) {
        _recordCatalogueError('Download request failed', error, stack);
        if (mounted && generation == _generation)
          setState(() {
            AppLog.instance.trace(
              "lib/pages/catalogue_page.dart::_AlbumPageViewState._download.closure#1.closure#2",
            );
            _error = _safeError(error);
          });
      } finally {
        if (mounted && generation == _generation)
          setState(() {
            AppLog.instance.trace(
              "lib/pages/catalogue_page.dart::_AlbumPageViewState._download.closure#1.closure#3",
            );
            _busy = false;
          });
      }
    });
  }

  Future<void> _play(
    Track track, {
    ({double position, int updatedAt, bool fromCloud})? historyProgress,
  }) async {
    AppLog.instance.trace(
      "lib/pages/catalogue_page.dart::_AlbumPageViewState._play",
    );

    final client = _client,
        key = _client.cacheIdentity,
        albumId = widget.albumId;
    if (_offline) {
      final task = await _localDownload(track);
      if (!_sameAccount(client, key) || widget.albumId != albumId) return;
      if (task == null)
        throw const XmlyException('offline_playback', '此声音本地文件不存在，请重新下载后播放');
      await widget.runtime.player.playTrack(
        track,
        accountIdentity: client.identity,
        historyProgress: historyProgress,
      );
      return;
    }
    if (widget.onPlayAlbum != null && widget.accountIdentity == null) {
      final position = track.officialPosition;
      await widget.onPlayAlbum!(
        widget.albumId,
        track.id,
        page: position == null
            ? (_ascending ? _page : null)
            : (position - 1) ~/ _pageSize + 1,
        track: track,
      );
    } else {
      await widget.runtime.player.playAlbum(
        widget.albumId,
        track.id,
        track: track,
        accountIdentity: widget.accountIdentity,
      );
    }
  }

  Future<void> _trackAction(Track track, String action) async {
    AppLog.instance.trace(
      "lib/pages/catalogue_page.dart::_AlbumPageViewState._trackAction",
    );

    switch (action) {
      case 'play':
        await _play(track);
      case 'queue':
        await widget.runtime.player.addToQueue(
          track,
          accountIdentity: widget.accountIdentity,
        );
      case 'next':
        await widget.runtime.player.playNext(
          track,
          accountIdentity: widget.accountIdentity,
        );
      case 'download':
        final task = await _localDownload(track);
        if (mounted && task == null)
          await requestDownloads(context, widget.runtime, [
            track,
          ], accountIdentity: widget.accountIdentity);
      case 'delete':
        final task = await _localDownload(track);
        if (mounted && task != null) {
          await deleteDownloadedAudio(context, widget.runtime, task);
        }
    }
    if (mounted)
      setState(() {
        AppLog.instance.trace(
          "lib/pages/catalogue_page.dart::_AlbumPageViewState._trackAction.closure#1",
        );
      });
  }

  Widget _menu(Track track) {
    AppLog.instance.trace(
      "lib/pages/catalogue_page.dart::_AlbumPageViewState._menu",
    );
    return Builder(
      builder: (menuContext) {
        AppLog.instance.trace(
          "lib/pages/catalogue_page.dart::_AlbumPageViewState._menu.closure#1",
        );
        return IconButton(
          tooltip: '声音操作',
          icon: const Icon(Icons.more_vert),
          onPressed: _busy || _favoriteBusy
              ? null
              : () {
                  AppLog.instance.trace(
                    "lib/pages/catalogue_page.dart::_AlbumPageViewState._menu.closure#1.closure#1",
                  );
                  _openTrackMenu(menuContext, track);
                },
        );
      },
    );
  }

  Future<void> _openTrackMenu(BuildContext menuContext, Track track) {
    AppLog.instance.trace(
      "lib/pages/catalogue_page.dart::_AlbumPageViewState._openTrackMenu",
    );
    return AppLog.instance.runWithErrorScope(() async {
      AppLog.instance.trace(
        "lib/pages/catalogue_page.dart::_AlbumPageViewState._openTrackMenu.closure#1",
      );

      final client = _client, key = _client.cacheIdentity;
      final epoch = _accountEpoch;
      bool current() {
        AppLog.instance.trace(
          "lib/pages/catalogue_page.dart::_AlbumPageViewState._openTrackMenu.closure#1.current",
        );
        return _sameAccount(client, key) && epoch == _accountEpoch;
      }

      final anchor = menuContext.findRenderObject()! as RenderBox;
      final overlay =
          Overlay.of(menuContext).context.findRenderObject()! as RenderBox;
      final position = RelativeRect.fromRect(
        Rect.fromPoints(
          anchor.localToGlobal(Offset.zero, ancestor: overlay),
          anchor.localToGlobal(
            anchor.size.bottomRight(Offset.zero),
            ancestor: overlay,
          ),
        ),
        Offset.zero & overlay.size,
      );
      setState(() {
        AppLog.instance.trace(
          "lib/pages/catalogue_page.dart::_AlbumPageViewState._openTrackMenu.closure#1.closure#1",
        );
        _favoriteBusy = true;
      });
      try {
        final task = await _localDownload(track);
        if (!current()) return;
        final action = await showMenu<String>(
          context: context,
          position: position,
          items: [
            const PopupMenuItem(value: 'play', child: Text('播放')),
            const PopupMenuItem(value: 'queue', child: Text('加入播放队列')),
            const PopupMenuItem(value: 'next', child: Text('下一集播放')),
            if (task != null)
              const PopupMenuItem(value: 'delete', child: Text('删除已下载文件'))
            else
              const PopupMenuItem(value: 'download', child: Text('下载')),
            if (client.accountAvailable)
              _FavoriteMenuItem(client: client, trackId: track.id)
            else
              const PopupMenuItem(value: 'favorite', child: Text('收藏（需登录）')),
          ],
        );
        if (!current() || action == null) return;
        if (action == 'retryFavorite') {
          setState(() {
            AppLog.instance.trace(
              "lib/pages/catalogue_page.dart::_AlbumPageViewState._openTrackMenu.closure#1.closure#2",
            );
            _favoriteBusy = false;
          });
          if (menuContext.mounted) await _openTrackMenu(menuContext, track);
          return;
        }
        if (action != 'favorite' && action != 'unfavorite') {
          await _trackAction(track, action);
          return;
        }
        if (!client.accountAvailable) {
          setState(() {
            AppLog.instance.trace(
              "lib/pages/catalogue_page.dart::_AlbumPageViewState._openTrackMenu.closure#1.closure#3",
            );
            _error = '请先登录后收藏声音';
          });
          return;
        }
        final desired = action == 'favorite';
        var attempted = false;
        try {
          await widget.runtime.accounts.runWithAccount(client.identity, (
            admitted,
          ) async {
            AppLog.instance.trace(
              "lib/pages/catalogue_page.dart::_AlbumPageViewState._openTrackMenu.closure#1.closure#4",
            );

            if (!current() || !identical(admitted, client)) {
              throw const XmlyException('account_changed', '账号已变更，请重试');
            }
            attempted = true;
            await XmlyExperience(client).setFavorite(track, favorite: desired);
          });
          widget.runtime.libraryChanged();
        } catch (error, stack) {
          _recordCatalogueError('Favorite change failed', error, stack);
          if (attempted) widget.runtime.libraryChanged();
          if (!current()) return;
          setState(() {
            AppLog.instance.trace(
              "lib/pages/catalogue_page.dart::_AlbumPageViewState._openTrackMenu.closure#1.closure#5",
            );
            _error = _safeError(error);
          });
          // Reconcile an uncertain write without replaying the mutation.
          if (attempted) {
            try {
              await XmlyExperience(client).isFavorite(track.id);
            } catch (error, stack) {
              _recordCatalogueError(
                'Favorite reconciliation failed',
                error,
                stack,
                recoverable: true,
              );
            }
          }
        }
      } catch (error, stack) {
        _recordCatalogueError('Track action failed', error, stack);
        if (current())
          setState(() {
            AppLog.instance.trace(
              "lib/pages/catalogue_page.dart::_AlbumPageViewState._openTrackMenu.closure#1.closure#6",
            );
            _error = _safeError(error);
          });
      } finally {
        if (mounted)
          setState(() {
            AppLog.instance.trace(
              "lib/pages/catalogue_page.dart::_AlbumPageViewState._openTrackMenu.closure#1.closure#7",
            );
            _favoriteBusy = false;
          });
      }
    });
  }

  void _albumAction(String action) {
    AppLog.instance.trace(
      "lib/pages/catalogue_page.dart::_AlbumPageViewState._albumAction",
    );

    switch (action) {
      case 'auto':
        final identity = widget.runtime.accounts.primaryAccountId;
        if (identity != null) _autoDownload(identity);
      case 'refresh':
        _offline = false;
        _complete = null;
        _loadPage(1);
        _loadOverview();
      case 'tags':
        showLocalPanel<void>(
          context: context,
          title: '专辑标签',
          builder: (_) {
            AppLog.instance.trace(
              "lib/pages/catalogue_page.dart::_AlbumPageViewState._albumAction.closure#1",
            );
            return AlbumTagsPage(
              runtime: widget.runtime,
              albumId: widget.albumId,
              albumTitle: _album?.title ?? '',
              embedded: true,
            );
          },
        );
      case 'settings':
        showQuickPlaybackSettings(
          context,
          widget.runtime,
          albumId: widget.albumId,
          albumTitle: _album?.title,
        );
    }
  }

  String _count(Object? value) {
    AppLog.instance.trace(
      "lib/pages/catalogue_page.dart::_AlbumPageViewState._count",
    );
    final number = value is num ? value : num.tryParse('$value');
    if (number == null || !number.isFinite || number < 0) return '';
    if (number >= 100000000)
      return '${(number / 100000000).toStringAsFixed(1)}亿';
    if (number >= 10000) return '${(number / 10000).toStringAsFixed(1)}万';
    return number.toInt().toString();
  }

  String _trackDate(Object? value) {
    AppLog.instance.trace(
      "lib/pages/catalogue_page.dart::_AlbumPageViewState._trackDate",
    );
    DateTime? date;
    if (value is int && value > 0 && value <= 8640000000000000) {
      date = DateTime.fromMillisecondsSinceEpoch(value);
    } else if (value is String) {
      date = DateTime.tryParse(value);
    }
    return date == null
        ? ''
        : '${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
  }

  Uri? _albumImage(Object? value) {
    AppLog.instance.trace(
      "lib/pages/catalogue_page.dart::_AlbumPageViewState._albumImage",
    );
    final uri = Uri.tryParse('$value');
    return uri != null &&
            uri.host.isNotEmpty &&
            (uri.scheme == 'http' || uri.scheme == 'https')
        ? uri.replace(scheme: 'https')
        : null;
  }

  Uri? get _posterUrl {
    AppLog.instance.trace(
      "lib/pages/catalogue_page.dart::_AlbumPageViewState._posterUrl.get",
    );
    final poster = _albumImage(
      xmlyMap(xmlyMap(_overview?['album'])['ocMap'])['coverBigPath'],
    );
    return poster?.toString() == _unavailablePoster ? null : poster;
  }

  Widget _albumHero(
    Album album, {
    required bool compact,
    bool sidePanel = false,
  }) {
    AppLog.instance.trace(
      "lib/pages/catalogue_page.dart::_AlbumPageViewState._albumHero",
    );
    final base = Theme.of(context);
    final colors = base.colorScheme;
    final publicAlbum = xmlyMap(xmlyMap(_overview?['album'])['baseAlbum']);
    final poster = _posterUrl;
    final cover = _albumImage(publicAlbum['coverLarge']) ?? album.coverUrl;
    final anchor = _anchorData;
    final score = xmlyMap(_albumData['albumRecScore']);
    final other = xmlyMap(_overview?['otherData']);
    final monthly = xmlyMap(other['monthlyTicket']);
    final platinum = xmlyMap(other['platinum']);
    final rank = xmlyMap(_albumData['rankInfo']);
    final grass = _overview?['plantGrass'];
    final introduction = grass is List
        ? grass.whereType<Map>().where((card) {
            AppLog.instance.trace(
              "lib/pages/catalogue_page.dart::_AlbumPageViewState._albumHero.closure#1",
            );
            return card['cardType'] == 'albumIntro';
          }).firstOrNull
        : null;
    final summary = xmlyMap(introduction?['footer'])['summary'];
    final intro = summary is String && summary.trim().isNotEmpty
        ? summary
        : album.intro;
    final body = introduction?['body'];
    final tags = body is List
        ? body
              .whereType<Map>()
              .map((tag) {
                AppLog.instance.trace(
                  "lib/pages/catalogue_page.dart::_AlbumPageViewState._albumHero.closure#2",
                );
                return '${tag['title'] ?? ''}';
              })
              .where((text) {
                AppLog.instance.trace(
                  "lib/pages/catalogue_page.dart::_AlbumPageViewState._albumHero.closure#3",
                );
                return text.isNotEmpty;
              })
              .toList()
        : <String>[];
    final finished = publicAlbum['isFinished'];
    final stats = <({String value, String label})>[
      if ('${score['label'] ?? ''}'.isNotEmpty)
        (
          value: '${score['label']}',
          label: score['totalNum'] == null
              ? '口碑推荐'
              : '${_count(score['totalNum'])}人点评',
        ),
      if (monthly['monthlyTicketCount'] != null)
        (value: _count(monthly['monthlyTicketCount']), label: '月票'),
      if (_albumData['playTimes'] != null || album.raw['play'] != null)
        (
          value: _count(_albumData['playTimes'] ?? album.raw['play']),
          label: '播放量',
        ),
      if (compact)
        (
          value: '${_count(_albumData['trackCount'] ?? _catalogueTotal)}集',
          label: finished == true || finished == 1
              ? '已完结'
              : finished == false || finished == 0
              ? '连载中'
              : '节目',
        )
      else if (xmlyPositive(platinum['uploadTracks']) != null)
        (value: '日更${platinum['uploadTracks']}集', label: '白金超前听'),
    ];
    final foreground = compact ? colors.onSurface : Colors.white;
    final secondary = compact ? colors.onSurfaceVariant : Colors.white70;
    final author = LayoutBuilder(
      builder: (context, constraints) {
        AppLog.instance.trace(
          "lib/pages/catalogue_page.dart::_AlbumPageViewState._albumHero.closure#4",
        );
        return Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 4,
          children: [
            ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: (constraints.maxWidth - 72).clamp(
                  64.0,
                  double.infinity,
                ),
              ),
              child: TextButton.icon(
                key: const ValueKey('albumAnchorLink'),
                onPressed: _openAnchor,
                style: TextButton.styleFrom(
                  foregroundColor: secondary,
                  padding: EdgeInsets.zero,
                  alignment: Alignment.centerLeft,
                ),
                icon: ClipOval(
                  child: CoverImage(
                    uri:
                        _albumImage(anchor['smallLogo']) ??
                        album.anchorAvatarUrl,
                    size: 24,
                  ),
                ),
                label: Text(
                  '${anchor['nickName'] ?? album.artist}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
            if (xmlyPositive(anchor['uid']) != null || album.anchorUid != null)
              TextButton(
                onPressed: _followBusy ? null : _followAnchor,
                style: TextButton.styleFrom(
                  foregroundColor: secondary,
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                ),
                child: Text(
                  _followBusy
                      ? '处理中'
                      : _following == true
                      ? '已关注'
                      : '+ 关注',
                ),
              ),
          ],
        );
      },
    );
    final title = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          album.title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: foreground,
            fontSize: compact ? 20 : 23,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(height: 6),
        author,
        if ('${anchor['ptitle'] ?? ''}'.isNotEmpty)
          Text(
            '${anchor['ptitle']}',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: secondary, fontSize: 12),
          ),
      ],
    );
    final statistics = stats.isEmpty
        ? const SizedBox.shrink()
        : LayoutBuilder(
            builder: (context, constraints) {
              AppLog.instance.trace(
                "lib/pages/catalogue_page.dart::_AlbumPageViewState._albumHero.closure#5",
              );
              final columns =
                  constraints.maxWidth >= 340 &&
                      MediaQuery.textScalerOf(context).scale(12) <= 16
                  ? 4
                  : 2;
              final cellWidth =
                  (constraints.maxWidth - 12 * (columns - 1)) / columns;
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 18),
                child: Wrap(
                  spacing: 12,
                  runSpacing: 14,
                  children: [
                    for (final stat in stats)
                      SizedBox(
                        width: cellWidth,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            FittedBox(
                              fit: BoxFit.scaleDown,
                              alignment: Alignment.centerLeft,
                              child: Text(
                                stat.value,
                                style: TextStyle(
                                  fontSize: compact ? 20 : 21,
                                  fontWeight: FontWeight.w600,
                                  color: compact
                                      ? foreground
                                      : const Color(0xffead0ae),
                                ),
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              stat.label,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: 12, color: secondary),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              );
            },
          );
    final details = Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: compact ? colors.surface : Colors.white.withValues(alpha: .05),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (tags.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  for (final tag in tags)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      color: compact
                          ? colors.surfaceContainerLow
                          : Colors.white.withValues(alpha: .05),
                      child: Text(
                        tag,
                        style: TextStyle(color: secondary, fontSize: 12),
                      ),
                    ),
                ],
              ),
            ),
          if ('${rank['rankingListName'] ?? ''}'.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                '${rank['rankingListName']}${rank['rank'] == null ? '' : ' NO.${rank['rank']}'}',
                style: TextStyle(
                  color: compact ? colors.primary : const Color(0xffa8c8f6),
                ),
              ),
            ),
          if (compact && intro.trim().isNotEmpty)
            Text(
              intro,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: secondary, fontSize: 14),
            ),
          Theme(
            data: base.copyWith(
              textTheme: base.textTheme.apply(
                bodyColor: secondary,
                displayColor: foreground,
              ),
              textButtonTheme: TextButtonThemeData(
                style: TextButton.styleFrom(foregroundColor: secondary),
              ),
            ),
            child: AlbumIntroduction(
              text: compact ? '' : intro,
              client: _client,
              albumId: album.id,
              album: album,
              onOpenAlbum: (recommended) {
                AppLog.instance.trace(
                  "lib/pages/catalogue_page.dart::_AlbumPageViewState._albumHero.closure#6",
                );
                return _openAlbum(recommended.id);
              },
            ),
          ),
        ],
      ),
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        AppLog.instance.trace(
          "lib/pages/catalogue_page.dart::_AlbumPageViewState._albumHero.closure#7",
        );
        final coverWidget = CoverImage(
          uri: cover,
          localPath: widget.runtime.albumCache[widget.albumId]?.coverPath,
          size: sidePanel
              ? 198
              : constraints.maxWidth < 360
              ? 104
              : 120,
        );
        final content = Padding(
          padding: EdgeInsets.fromLTRB(16, compact ? 16 : 0, 16, 22),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (!compact)
                SizedBox(
                  height: (constraints.maxWidth * .56).clamp(150.0, 308.0),
                ),
              if (compact && !sidePanel)
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    coverWidget,
                    const SizedBox(width: 16),
                    Expanded(child: title),
                  ],
                )
              else ...[
                if (sidePanel) ...[coverWidget, const SizedBox(height: 18)],
                title,
              ],
              statistics,
              details,
            ],
          ),
        );
        if (compact)
          return DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Color.alphaBlend(
                    colors.primaryContainer.withValues(alpha: .18),
                    colors.surface,
                  ),
                  colors.surfaceContainerLowest,
                ],
              ),
            ),
            child: content,
          );
        return Container(
          color: const Color(0xff302319),
          child: Stack(
            children: [
              if (poster != null)
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  height: (constraints.maxWidth * .85).clamp(200.0, 468.0),
                  child: Image(
                    image: LoggedNetworkImage(poster.toString()),
                    fit: BoxFit.cover,
                    alignment: Alignment.topCenter,
                    excludeFromSemantics: true,
                    errorBuilder: (_, _, _) {
                      AppLog.instance.trace(
                        "lib/pages/catalogue_page.dart::_AlbumPageViewState._albumHero.closure#7.closure#1",
                      );
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        AppLog.instance.trace(
                          "lib/pages/catalogue_page.dart::_AlbumPageViewState._albumHero.closure#7.closure#1.closure#1",
                        );
                        if (mounted && _posterUrl == poster)
                          setState(() {
                            AppLog.instance.trace(
                              "lib/pages/catalogue_page.dart::_AlbumPageViewState._albumHero.closure#7.closure#1.closure#1.closure#1",
                            );
                            _unavailablePoster = poster.toString();
                          });
                      });
                      return const SizedBox.shrink();
                    },
                  ),
                ),
              const Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Color(0x05000000),
                        Color(0xee302319),
                        Color(0xff302319),
                      ],
                      stops: [0, .56, 1],
                    ),
                  ),
                ),
              ),
              DefaultTextStyle(
                style: const TextStyle(color: Colors.white70, fontSize: 14),
                child: content,
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _albumTabs() {
    AppLog.instance.trace(
      "lib/pages/catalogue_page.dart::_AlbumPageViewState._albumTabs",
    );
    return Material(
      color: Theme.of(context).colorScheme.surface,
      child: Row(
        children: [
          for (var index = 0; index < 3; index++)
            Expanded(
              child: Semantics(
                selected: _tab == index,
                button: true,
                child: InkWell(
                  onTap: () {
                    AppLog.instance.trace(
                      "lib/pages/catalogue_page.dart::_AlbumPageViewState._albumTabs.closure#1",
                    );
                    return setState(() {
                      AppLog.instance.trace(
                        "lib/pages/catalogue_page.dart::_AlbumPageViewState._albumTabs.closure#1.closure#1",
                      );
                      _tab = index;
                    });
                  },
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(4, 16, 4, 0),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          const ['节目列表', '评价', '找相似'][index],
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 17,
                            fontWeight: _tab == index
                                ? FontWeight.w700
                                : FontWeight.w400,
                          ),
                        ),
                        const SizedBox(height: 9),
                        Container(
                          height: 3,
                          width: 22,
                          decoration: BoxDecoration(
                            color: _tab == index
                                ? const Color(0xffff414a)
                                : Colors.transparent,
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _selectionControls() {
    AppLog.instance.trace(
      "lib/pages/catalogue_page.dart::_AlbumPageViewState._selectionControls",
    );
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        children: [
          TextField(
            controller: _range,
            decoration: const InputDecoration(
              labelText: '下载集数范围',
              hintText: '1–100 或 1,3,5-8',
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              FilledButton(
                onPressed: _busy || widget.runtime.accounts.admissionPaused
                    ? null
                    : () {
                        AppLog.instance.trace(
                          "lib/pages/catalogue_page.dart::_AlbumPageViewState._selectionControls.closure#1",
                        );
                        _download();
                      },
                child: Text('下载所选 (${_selected.length})'),
              ),
              TextButton(
                onPressed: () {
                  AppLog.instance.trace(
                    "lib/pages/catalogue_page.dart::_AlbumPageViewState._selectionControls.closure#2",
                  );
                  return setState(() {
                    AppLog.instance.trace(
                      "lib/pages/catalogue_page.dart::_AlbumPageViewState._selectionControls.closure#2.closure#1",
                    );
                    for (final track in _visible) {
                      _select(track, true);
                    }
                  });
                },
                child: const Text('选择当前列表'),
              ),
              TextButton(
                onPressed: () {
                  AppLog.instance.trace(
                    "lib/pages/catalogue_page.dart::_AlbumPageViewState._selectionControls.closure#3",
                  );
                  return setState(_clearSelection);
                },
                child: const Text('退出多选'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _playSafely(Track track) async {
    AppLog.instance.trace(
      "lib/pages/catalogue_page.dart::_AlbumPageViewState._playSafely",
    );
    final epoch = _accountEpoch;
    try {
      await _play(track);
    } catch (error, stack) {
      _recordCatalogueError('Playback failed', error, stack);
      if (mounted && epoch == _accountEpoch)
        setState(() {
          AppLog.instance.trace(
            "lib/pages/catalogue_page.dart::_AlbumPageViewState._playSafely.closure#1",
          );
          _error = _safeError(error);
        });
    }
  }

  Widget _programTile(Track track) {
    AppLog.instance.trace(
      "lib/pages/catalogue_page.dart::_AlbumPageViewState._programTile",
    );
    final downloaded = _downloaded.contains(track.id);
    final player = widget.runtime.player;
    final current =
        player.current?.id == track.id &&
        player.playbackIdentity == _client.identity;
    final saved = _savedProgress(track.id);
    final cloud = _cloudProgress;
    final remotePosition = cloud?['track_id'] == track.id
        ? (cloud?['position'] as num?)
        : null;
    final remoteUpdated = cloud?['track_id'] == track.id
        ? ((cloud?['updated_at'] as num) * 1000).toInt()
        : 0;
    final progress = current
        ? player.position
        : remotePosition != null &&
              (saved == null || remoteUpdated > saved.updatedAt)
        ? remotePosition.toDouble()
        : saved?.position;
    final date = _trackDate(track.raw['date']);
    final metadata = <String>[
      if (progress != null && progress > 0)
        track.duration > 0 && progress >= track.duration - 1
            ? '已听完'
            : track.duration > progress
            ? '剩${_duration(track.duration - progress)}'
            : '已听${_duration(progress)}'
      else
        _duration(track.duration),
      if (date.isNotEmpty) date,
      if (track.raw['play'] != null) '▷ ${_count(track.raw['play'])}',
      if (downloaded) '已下载',
    ];
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16),
      minTileHeight: _trackExtent,
      horizontalTitleGap: 8,
      selected:
          current ||
          (track.id == widget.initialTrack?.id && _targetWarning == null),
      leading: _selectionMode
          ? Checkbox(
              value: _selected.containsKey(track.id),
              onChanged: downloaded
                  ? null
                  : (value) {
                      AppLog.instance.trace(
                        "lib/pages/catalogue_page.dart::_AlbumPageViewState._programTile.closure#1",
                      );
                      return setState(() {
                        AppLog.instance.trace(
                          "lib/pages/catalogue_page.dart::_AlbumPageViewState._programTile.closure#1.closure#1",
                        );
                        _select(track, value == true);
                      });
                    },
            )
          : SizedBox(
              width: 32,
              child: Center(
                child: Text(
                  '${track.officialPosition ?? '—'}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    color: current ? const Color(0xffff414a) : Colors.grey,
                  ),
                ),
              ),
            ),
      title: Text(
        track.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 15),
      ),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Text(
          metadata.join('   '),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 12, color: Colors.grey),
        ),
      ),
      trailing: _menu(track),
      onLongPress: () {
        AppLog.instance.trace(
          "lib/pages/catalogue_page.dart::_AlbumPageViewState._programTile.closure#2",
        );
        return setState(() {
          AppLog.instance.trace(
            "lib/pages/catalogue_page.dart::_AlbumPageViewState._programTile.closure#2.closure#1",
          );
          _selectionMode = true;
          _select(track, true);
        });
      },
      onTap: _selectionMode
          ? downloaded
                ? null
                : () {
                    AppLog.instance.trace(
                      "lib/pages/catalogue_page.dart::_AlbumPageViewState._programTile.closure#3",
                    );
                    return setState(() {
                      AppLog.instance.trace(
                        "lib/pages/catalogue_page.dart::_AlbumPageViewState._programTile.closure#3.closure#1",
                      );
                      _select(track, !_selected.containsKey(track.id));
                    });
                  }
          : () {
              AppLog.instance.trace(
                "lib/pages/catalogue_page.dart::_AlbumPageViewState._programTile.closure#4",
              );
              _playSafely(track);
            },
    );
  }

  Widget _overflow({bool dark = false}) {
    AppLog.instance.trace(
      "lib/pages/catalogue_page.dart::_AlbumPageViewState._overflow",
    );
    final identity = widget.runtime.accounts.primaryAccountId;
    final baseTheme = Theme.of(context);
    return Theme(
      data: baseTheme,
      child: PopupMenuButton<String>(
        tooltip: '更多操作',
        icon: Icon(
          Icons.more_horiz,
          color: dark ? Colors.white : baseTheme.colorScheme.onSurface,
        ),
        color: baseTheme.colorScheme.surface,
        onSelected: _albumAction,
        itemBuilder: (_) {
          AppLog.instance.trace(
            "lib/pages/catalogue_page.dart::_AlbumPageViewState._overflow.closure#1",
          );
          return [
            CheckedPopupMenuItem(
              value: 'auto',
              enabled: identity != null && !_autoBusy,
              checked:
                  identity != null &&
                  widget.runtime.autoDownloads.enabled(
                    identity,
                    widget.albumId,
                  ),
              child: Text(identity == null ? '自动下载新节目（需登录）' : '自动下载新节目（主账号）'),
            ),
            const PopupMenuItem(value: 'tags', child: Text('专辑标签')),
            const PopupMenuItem(value: 'settings', child: Text('播放设置')),
            PopupMenuItem(
              value: 'refresh',
              enabled: !_busy,
              child: const Text('刷新专辑'),
            ),
          ];
        },
      ),
    );
  }

  Widget _albumContent({required bool wide, required bool poster}) {
    AppLog.instance.trace(
      "lib/pages/catalogue_page.dart::_AlbumPageViewState._albumContent",
    );
    final album = _album;
    if (_tab != 0)
      return Column(
        children: [
          _albumTabs(),
          Expanded(
            child: _tab == 1
                ? AlbumReviewsPage(
                    runtime: widget.runtime,
                    albumId: widget.albumId,
                    albumTitle: album?.title ?? '',
                    accountIdentity: widget.accountIdentity,
                    onDownload: widget.onDownload,
                    onPlayAlbum: widget.onPlayAlbum,
                    embedded: true,
                  )
                : AlbumSimilarSection(
                    key: ValueKey('${widget.albumId}:${_client.cacheIdentity}'),
                    client: _client,
                    albumId: widget.albumId,
                    onOpenAlbum: _openAlbum,
                    onOpenAnchor: _openAnchor,
                  ),
          ),
        ],
      );
    final identity = widget.runtime.accounts.primaryAccountId;
    final automaticError = identity == null
        ? null
        : widget.runtime.autoDownloads.errorFor(identity, widget.albumId);
    return AppScrollbar(
      controller: _albumScroll,
      child: CustomScrollView(
        controller: _albumScroll,
        scrollBehavior: ScrollConfiguration.of(context)
            .copyWith(scrollbars: false),
        slivers: [
          SliverToBoxAdapter(
            child: Column(
              key: _headerKey,
              children: [
                if (!wide && album != null) _albumHero(album, compact: !poster),
                if (_cachedView)
                  const Padding(
                    padding: EdgeInsets.all(8),
                    child: Text('离线缓存节目'),
                  ),
                if (widget.initialTrack case final target?)
                  ListTile(
                    title: Text(
                      '定位：${target.title}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: _targetWarning == null
                        ? null
                        : Text(_targetWarning!),
                    trailing: TextButton(
                      onPressed: _busy
                          ? null
                          : () {
                              AppLog.instance.trace(
                                "lib/pages/catalogue_page.dart::_AlbumPageViewState._albumContent.closure#1",
                              );
                              _loadPage(1, target: target);
                            },
                      child: const Text('重新定位'),
                    ),
                  ),
                if (_selectionMode) _selectionControls(),
                if (_rangeStart != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        '第$_rangeStart–${(_rangeStart! + _pageSize - 1).clamp(1, _catalogueTotal)}集',
                        style: const TextStyle(color: Color(0xffff414a)),
                      ),
                    ),
                  ),
                if (automaticError != null)
                  ListTile(
                    title: Text(automaticError),
                    trailing: TextButton(
                      onPressed: _scanUpdates,
                      child: const Text('重新检查'),
                    ),
                  ),
                if (_busy) const LinearProgressIndicator(),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      children: [
                        Text(
                          _error!,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                        TextButton(
                          onPressed: _busy
                              ? null
                              : () {
                                  AppLog.instance.trace(
                                    "lib/pages/catalogue_page.dart::_AlbumPageViewState._albumContent.closure#2",
                                  );
                                  _loadPage(_page);
                                },
                          child: const Text('重新加载'),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          SliverPersistentHeader(
            pinned: true,
            delegate: _AlbumProgramHeader(
              extent: 84 + MediaQuery.textScalerOf(context).scale(17) * 1.5,
              child: Material(
                color: Theme.of(context).colorScheme.surface,
                child: Column(children: [_albumTabs(), _orderControl()]),
              ),
            ),
          ),
          SliverFixedExtentList.builder(
            itemExtent: _trackExtent,
            itemCount: _visible.length,
            itemBuilder: (_, index) {
              AppLog.instance.trace(
                "lib/pages/catalogue_page.dart::_AlbumPageViewState._albumContent.closure#3",
              );
              return _programTile(_visible[index]);
            },
          ),
          if (!_busy && _visible.isEmpty && album != null)
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Center(child: Text('暂无节目')),
              ),
            ),
          if (album != null && _rangeStart == null)
            SliverToBoxAdapter(
              child: ContentPaging(
                page: _page,
                total: _total,
                pageSize: _pageSize,
                busy: _busy,
                onPage: _loadPage,
              ),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    AppLog.instance.trace(
      "lib/pages/catalogue_page.dart::_AlbumPageViewState.build",
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        AppLog.instance.trace(
          "lib/pages/catalogue_page.dart::_AlbumPageViewState.build.closure#1",
        );
        final landscape =
            MediaQuery.orientationOf(context) == Orientation.landscape;
        final wide = constraints.maxWidth >= 720 && landscape;
        final poster = !landscape && _posterUrl != null;
        final base = Theme.of(context);
        final toolbarTheme = poster
            ? base.copyWith(
                colorScheme: base.colorScheme.copyWith(
                  surface: const Color(0xff302319),
                  onSurface: Colors.white,
                ),
                textTheme: base.textTheme.apply(
                  bodyColor: Colors.white,
                  displayColor: Colors.white,
                ),
                iconTheme: const IconThemeData(color: Colors.white),
                appBarTheme: const AppBarTheme(
                  backgroundColor: Color(0xff302319),
                  foregroundColor: Colors.white,
                  surfaceTintColor: Colors.transparent,
                ),
              )
            : base;
        final album = _album;
        return Scaffold(
          appBar: PreferredSize(
            preferredSize: const Size.fromHeight(kToolbarHeight),
            child: Theme(
              data: toolbarTheme,
              child: AppHeader(
                windowControls: !widget.inPanel,
                leading: widget.inPanel
                    ? IconButton(
                        tooltip: '收起专辑',
                        onPressed: () {
                          AppLog.instance.trace(
                            "lib/pages/catalogue_page.dart::_AlbumPageViewState.build.closure#1.closure#1",
                          );
                          Navigator.of(context).maybePop();
                        },
                        icon: const Icon(Icons.keyboard_arrow_down),
                      )
                    : null,
                title: Text(
                  album?.title ?? '专辑',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                actions: [_overflow(dark: poster)],
              ),
            ),
          ),
          bottomNavigationBar: _footer(),
          body: SafeArea(
            top: false,
            bottom: false,
            child: Center(
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: wide ? 1280 : 960),
                child: wide
                    ? Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            SizedBox(
                              width: constraints.maxWidth < 1000 ? 260 : 300,
                              child: AppScrollbar(
                                controller: _informationScroll,
                                child: SingleChildScrollView(
                                  controller: _informationScroll,
                                  child: album == null
                                      ? const SizedBox.shrink()
                                      : _albumHero(
                                          album,
                                          compact: true,
                                          sidePanel: true,
                                        ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 24),
                            Expanded(
                              child: _albumContent(wide: true, poster: false),
                            ),
                          ],
                        ),
                      )
                    : _albumContent(wide: false, poster: poster),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _AlbumProgramHeader extends SliverPersistentHeaderDelegate {
  const _AlbumProgramHeader({required this.extent, required this.child});
  final double extent;
  final Widget child;
  @override
  double get minExtent {
    AppLog.instance.trace(
      "lib/pages/catalogue_page.dart::_AlbumProgramHeader.minExtent.get",
    );
    return extent;
  }

  @override
  double get maxExtent {
    AppLog.instance.trace(
      "lib/pages/catalogue_page.dart::_AlbumProgramHeader.maxExtent.get",
    );
    return extent;
  }

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    AppLog.instance.trace(
      "lib/pages/catalogue_page.dart::_AlbumProgramHeader.build",
    );
    return child;
  }

  @override
  bool shouldRebuild(covariant _AlbumProgramHeader oldDelegate) {
    AppLog.instance.trace(
      "lib/pages/catalogue_page.dart::_AlbumProgramHeader.shouldRebuild",
    );
    return oldDelegate.extent != extent || oldDelegate.child != child;
  }
}

class _FavoriteMenuItem extends PopupMenuEntry<String> {
  const _FavoriteMenuItem({required this.client, required this.trackId});

  final XmlyClient client;
  final String trackId;

  @override
  double get height {
    AppLog.instance.trace(
      "lib/pages/catalogue_page.dart::_FavoriteMenuItem.height.get",
    );
    return kMinInteractiveDimension;
  }

  @override
  bool represents(String? value) {
    AppLog.instance.trace(
      "lib/pages/catalogue_page.dart::_FavoriteMenuItem.represents",
    );
    return const {'favorite', 'unfavorite', 'retryFavorite'}.contains(value);
  }

  @override
  State<_FavoriteMenuItem> createState() {
    AppLog.instance.trace(
      "lib/pages/catalogue_page.dart::_FavoriteMenuItem.createState",
    );
    return _FavoriteMenuItemState();
  }
}

class _FavoriteMenuItemState extends State<_FavoriteMenuItem> {
  late final Future<bool> _favorite;

  @override
  void initState() {
    AppLog.instance.trace(
      "lib/pages/catalogue_page.dart::_FavoriteMenuItemState.initState",
    );

    super.initState();
    _favorite = _loadFavorite();
  }

  Future<bool> _loadFavorite() {
    AppLog.instance.trace(
      "lib/pages/catalogue_page.dart::_FavoriteMenuItemState._loadFavorite",
    );
    return AppLog.instance.runWithErrorScope(() async {
      AppLog.instance.trace(
        "lib/pages/catalogue_page.dart::_FavoriteMenuItemState._loadFavorite.closure#1",
      );

      try {
        return await XmlyExperience(widget.client).isFavorite(widget.trackId);
      } catch (error, stack) {
        _recordCatalogueError('Favorite menu status failed', error, stack);
        rethrow;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    AppLog.instance.trace(
      "lib/pages/catalogue_page.dart::_FavoriteMenuItemState.build",
    );
    return FutureBuilder<bool>(
      future: _favorite,
      builder: (context, snapshot) {
        AppLog.instance.trace(
          "lib/pages/catalogue_page.dart::_FavoriteMenuItemState.build.closure#1",
        );

        final ready = snapshot.connectionState == ConnectionState.done;
        return PopupMenuItem<String>(
          enabled: ready,
          value: snapshot.hasError
              ? 'retryFavorite'
              : snapshot.data == true
              ? 'unfavorite'
              : 'favorite',
          child: Text(
            !ready
                ? '正在读取收藏状态…'
                : snapshot.hasError
                ? '重试收藏状态'
                : snapshot.data == true
                ? '取消收藏'
                : '收藏',
          ),
        );
      },
    );
  }
}

class CoverImage extends StatelessWidget {
  const CoverImage({
    required this.uri,
    this.localPath,
    this.size = 52,
    this.downloaded = false,
    super.key,
  });
  final String? localPath;
  final Uri? uri;
  final double size;
  final bool downloaded;
  @override
  Widget build(BuildContext context) {
    AppLog.instance.trace("lib/pages/catalogue_page.dart::CoverImage.build");

    if (MediaQuery.sizeOf(context).width < 320) return const SizedBox.shrink();
    return Stack(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: SizedBox(
            width: size,
            height: size,
            child: ColoredBox(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              child: localPath != null
                  ? Image.file(
                      File(localPath!),
                      fit: BoxFit.cover,
                      errorBuilder: (_, error, stack) {
                        AppLog.instance.trace(
                          "lib/pages/catalogue_page.dart::CoverImage.build.closure#1",
                        );

                        _recordCatalogueError(
                          'Cached cover load failed',
                          error,
                          stack ?? StackTrace.current,
                          recoverable: true,
                        );
                        return const Icon(Icons.album_outlined);
                      },
                    )
                  : uri == null
                  ? const Icon(Icons.album_outlined)
                  : Image(
                      image: LoggedNetworkImage(uri.toString()),
                      fit: BoxFit.cover,
                      frameBuilder: (_, child, frame, synchronous) {
                        AppLog.instance.trace(
                          "lib/pages/catalogue_page.dart::CoverImage.build.closure#2",
                        );
                        return frame != null || synchronous
                            ? child
                            : const Icon(Icons.album_outlined);
                      },
                      errorBuilder: (_, _, _) {
                        AppLog.instance.trace(
                          "lib/pages/catalogue_page.dart::CoverImage.build.closure#3",
                        );
                        return const Icon(Icons.album_outlined);
                      },
                    ),
            ),
          ),
        ),
        if (downloaded)
          Positioned(
            right: 2,
            bottom: 2,
            child: Tooltip(
              message: '已下载',
              child: DecoratedBox(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Theme.of(context).colorScheme.surface,
                ),
                child: Icon(
                  Icons.check_circle,
                  size: 20,
                  color: Theme.of(context).colorScheme.primary,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

String _duration(double seconds) {
  AppLog.instance.trace("lib/pages/catalogue_page.dart::_duration");
  return '${seconds ~/ 60}:${(seconds.toInt() % 60).toString().padLeft(2, '0')}';
}

String _safeError(Object error) {
  AppLog.instance.trace("lib/pages/catalogue_page.dart::_safeError");
  return error is XmlyException ? error.message : '请求未完成，请稍后重试';
}
