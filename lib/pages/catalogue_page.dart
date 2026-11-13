import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';

import '../api/xmly_catalogue.dart';
import '../api/xmly_client.dart';
import '../api/xmly_experience.dart';
import '../common/widgets/adaptive_text.dart';
import '../common/widgets/logged_network_image.dart';
import '../common/widgets/app_header.dart';
import '../common/widgets/local_panel.dart';
import '../models/xmly_models.dart';
import '../services/app_log.dart';
import '../services/app_runtime.dart';
import '../services/download_service.dart';
import 'album_introduction.dart';
import 'download_page.dart'
    show
        deleteDownloadedAudio,
        requestAlbumDownloads,
        requestDownloads,
        setAlbumAutoDownload;
import 'media_settings_page.dart';
import 'playback_settings_page.dart';

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
        'batch_too_large',
        'task_busy',
        'original_account_required',
      }.contains(error.code);
  log.write(
    recoverable || expected ? AppLogLevel.warning : AppLogLevel.error,
    'catalogue_page',
    operation,
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

Future<Track> _locateAlbumTrack(
  XmlyClient client,
  String albumId,
  Track track,
) async {
  AppLog.instance.trace("lib/pages/catalogue_page.dart::_locateAlbumTrack");

  final id = track.id;
  if (_trackOrdinal(track) == null) track = await client.track(track.id);
  final ordinal = _trackOrdinal(track);
  if (track.id != id ||
      track.albumId != albumId ||
      ordinal == null ||
      ordinal > 5000) {
    throw const XmlyException('track_position_missing', '无法确定这集在专辑中的位置，请刷新后重试');
  }
  return track;
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

class _DiscoveryPageState extends State<DiscoveryPage> {
  final _query = TextEditingController();
  final _scroll = ScrollController();
  String _kind = 'album';
  SearchPage? _result;
  String? _resultQuery;
  String? _error;
  bool _loading = false;
  int _generation = 0;
  int _playRequest = 0;

  Future<void> _search({int page = 1, String? query}) {
    AppLog.instance.trace(
      "lib/pages/catalogue_page.dart::_DiscoveryPageState._search",
    );
    return AppLog.instance.runWithErrorScope(() async {
      AppLog.instance.trace(
        "lib/pages/catalogue_page.dart::_DiscoveryPageState._search.closure#1",
      );

      final submittedQuery = query ?? _query.text;
      final generation = ++_generation;
      setState(() {
        AppLog.instance.trace(
          "lib/pages/catalogue_page.dart::_DiscoveryPageState._search.closure#1.closure#1",
        );

        _loading = true;
        _error = null;
      });
      try {
        final result = await widget.runtime.client.search(
          submittedQuery,
          kind: _kind,
          page: page,
          pageSize: 30,
        );
        if (mounted && generation == _generation) {
          setState(() {
            AppLog.instance.trace(
              "lib/pages/catalogue_page.dart::_DiscoveryPageState._search.closure#1.closure#2",
            );

            _result = result;
            _resultQuery = submittedQuery;
          });
          WidgetsBinding.instance.addPostFrameCallback((_) {
            AppLog.instance.trace(
              "lib/pages/catalogue_page.dart::_DiscoveryPageState._search.closure#1.closure#3",
            );

            if (mounted && generation == _generation && _scroll.hasClients) {
              _scroll.jumpTo(_scroll.position.minScrollExtent);
            }
          });
        }
      } catch (error, stack) {
        _recordCatalogueError('Search failed', error, stack);
        if (mounted && generation == _generation)
          setState(() {
            AppLog.instance.trace(
              "lib/pages/catalogue_page.dart::_DiscoveryPageState._search.closure#1.closure#4",
            );

            _error = _safeError(error);
          });
      } finally {
        if (mounted && generation == _generation)
          setState(() {
            AppLog.instance.trace(
              "lib/pages/catalogue_page.dart::_DiscoveryPageState._search.closure#1.closure#5",
            );

            _loading = false;
          });
      }
    });
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

  @override
  void dispose() {
    AppLog.instance.trace(
      "lib/pages/catalogue_page.dart::_DiscoveryPageState.dispose",
    );

    _generation++;
    _playRequest++;
    _query.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    AppLog.instance.trace(
      "lib/pages/catalogue_page.dart::_DiscoveryPageState.build",
    );

    final result = _result;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 960),
        child: Scrollbar(
          controller: _scroll,
          child: CustomScrollView(
            controller: _scroll,
            slivers: [
              SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.all(
                    MediaQuery.sizeOf(context).width < 320 ? 8 : 16,
                  ),
                  child: Column(
                    children: [
                      TextField(
                        controller: _query,
                        maxLength: 200,
                        decoration: const InputDecoration(
                          labelText: '搜索专辑或声音',
                          counterText: '',
                          prefixIcon: Icon(Icons.search),
                        ),
                        onSubmitted: (_) {
                          AppLog.instance.trace(
                            "lib/pages/catalogue_page.dart::_DiscoveryPageState.build.closure#1",
                          );
                          _search();
                        },
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(
                            child: DropdownButton<String>(
                              value: _kind,
                              isExpanded: true,
                              items: const [
                                DropdownMenuItem(
                                  value: 'album',
                                  child: Text('专辑'),
                                ),
                                DropdownMenuItem(
                                  value: 'track',
                                  child: Text('声音'),
                                ),
                              ],
                              onChanged: _loading
                                  ? null
                                  : (value) {
                                      AppLog.instance.trace(
                                        "lib/pages/catalogue_page.dart::_DiscoveryPageState.build.closure#2",
                                      );
                                      setState(() {
                                        AppLog.instance.trace(
                                          "lib/pages/catalogue_page.dart::_DiscoveryPageState.build.closure#2.closure#1",
                                        );

                                        _kind = value!;
                                        _result = null;
                                        _resultQuery = null;
                                      });
                                    },
                            ),
                          ),
                          const SizedBox(width: 12),
                          FilledButton(
                            onPressed: _loading
                                ? null
                                : () {
                                    AppLog.instance.trace(
                                      "lib/pages/catalogue_page.dart::_DiscoveryPageState.build.closure#3",
                                    );
                                    _search();
                                  },
                            child: const Text('搜索'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              if (_loading)
                const SliverToBoxAdapter(child: LinearProgressIndicator()),
              if (_error != null)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(_error!),
                  ),
                ),
              if (result == null)
                const SliverFillRemaining(
                  hasScrollBody: false,
                  child: Center(child: Text('搜索专辑或声音')),
                )
              else if (result.kind == 'album')
                SliverList.builder(
                  itemCount: result.albums.length,
                  itemBuilder: (context, index) {
                    AppLog.instance.trace(
                      "lib/pages/catalogue_page.dart::_DiscoveryPageState.build.closure#4",
                    );

                    final album = result.albums[index];
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
                          : CoverImage(uri: album.coverUrl, size: 48),
                      title: AdaptiveText(album.title),
                      subtitle: AdaptiveText(
                        '${album.artist} · ${album.total} 集',
                      ),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () {
                        AppLog.instance.trace(
                          "lib/pages/catalogue_page.dart::_DiscoveryPageState.build.closure#4.closure#1",
                        );
                        _openAlbum(album.id);
                      },
                    );
                  },
                )
              else
                SliverList.builder(
                  itemCount: result.tracks.length,
                  itemBuilder: (context, index) {
                    AppLog.instance.trace(
                      "lib/pages/catalogue_page.dart::_DiscoveryPageState.build.closure#5",
                    );

                    final track = result.tracks[index];
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
                          : CoverImage(uri: track.coverUrl, size: 48),
                      title: AdaptiveText(track.title),
                      subtitle: AdaptiveText(
                        '${track.album} · ${_duration(track.duration)}',
                      ),
                      onTap: () {
                        AppLog.instance.trace(
                          "lib/pages/catalogue_page.dart::_DiscoveryPageState.build.closure#5.closure#1",
                        );
                        _playResult(track);
                      },
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            tooltip: '播放此集',
                            icon: const Icon(Icons.play_arrow),
                            onPressed: () {
                              AppLog.instance.trace(
                                "lib/pages/catalogue_page.dart::_DiscoveryPageState.build.closure#5.closure#2",
                              );
                              _playResult(track);
                            },
                          ),
                          PopupMenuButton<String>(
                            tooltip: '声音操作',
                            onSelected: (action) {
                              AppLog.instance.trace(
                                "lib/pages/catalogue_page.dart::_DiscoveryPageState.build.closure#5.closure#3",
                              );

                              AppLog.instance.runWithErrorScope(() async {
                                AppLog.instance.trace(
                                  "lib/pages/catalogue_page.dart::_DiscoveryPageState.build.closure#5.closure#3.closure#1",
                                );

                                if (action == 'album') {
                                  _openAlbum(track.albumId, target: track);
                                } else {
                                  try {
                                    await widget.onDownload?.call([track]);
                                  } catch (error, stack) {
                                    _recordCatalogueError(
                                      'Download request failed',
                                      error,
                                      stack,
                                    );
                                    if (context.mounted) {
                                      ScaffoldMessenger.of(context)
                                          .showSnackBar(
                                            SnackBar(
                                              content: Text(_safeError(error)),
                                            ),
                                          );
                                    }
                                  }
                                }
                              });
                            },
                            itemBuilder: (_) {
                              AppLog.instance.trace(
                                "lib/pages/catalogue_page.dart::_DiscoveryPageState.build.closure#5.closure#4",
                              );
                              return [
                                if (track.albumId.isNotEmpty)
                                  const PopupMenuItem(
                                    value: 'album',
                                    child: Text('查看专辑并定位'),
                                  ),
                                if (widget.onDownload != null)
                                  const PopupMenuItem(
                                    value: 'download',
                                    child: Text('下载'),
                                  ),
                              ];
                            },
                          ),
                        ],
                      ),
                    );
                  },
                ),
              if (result != null)
                SliverToBoxAdapter(
                  child: _Paging(
                    page: result.page,
                    total: result.total,
                    pageSize: result.pageSize,
                    busy: _loading,
                    onPage: (page) {
                      AppLog.instance.trace(
                        "lib/pages/catalogue_page.dart::_DiscoveryPageState.build.closure#6",
                      );
                      return _search(page: page, query: _resultQuery);
                    },
                  ),
                ),
            ],
          ),
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
    this.onDownload,
    this.onPlayAlbum,
    this.inPanel = false,
    super.key,
  });
  final AppRuntime runtime;
  final String albumId;
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
  final _headerKey = GlobalKey();
  String? _targetWarning;
  final _search = TextEditingController();
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
  bool _showSearch = false, _selectionMode = false, _cachedView = false;
  String? _error;
  String _filter = '';
  XmlyClient? _libraryClient;
  String? _libraryKey, _subscriptionError;
  int _libraryRevision = -1, _subscriptionRequest = 0, _accountEpoch = 0;
  bool? _subscribed;
  bool _subscriptionBusy = false, _favoriteBusy = false;
  bool _subscriptionMutating = false;
  bool _ascending = true;
  static const _pageSize = xmlyAlbumPageSize;

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
  }

  @override
  void dispose() {
    AppLog.instance.trace(
      "lib/pages/catalogue_page.dart::_AlbumPageViewState.dispose",
    );

    widget.runtime.removeListener(_runtimeChanged);
    _generation++;
    _cancelCatalogue();
    _search.dispose();
    _range.dispose();
    _albumScroll.dispose();
    super.dispose();
  }

  void _runtimeChanged() {
    AppLog.instance.trace(
      "lib/pages/catalogue_page.dart::_AlbumPageViewState._runtimeChanged",
    );

    if (!mounted) return;
    final client = widget.runtime.client;
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
        _complete = null;
        _offline = false;
        _filter = '';
        _search.clear();
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
        if (_cachedView) _showCached(_page);
      }
    });
    if (accountChanged || (libraryChanged && !_subscriptionMutating)) {
      _loadSubscription();
    }
    if (accountChanged) _loadPage(1, target: widget.initialTrack);
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
    final ordered = orderedTracks ?? _orderedForDisplay(_cachedTracks());
    final filter = _filter.toLowerCase();
    final tracks = filter.isEmpty
        ? ordered
        : ordered.where((track) {
            AppLog.instance.trace(
              "lib/pages/catalogue_page.dart::_AlbumPageViewState._showCached.closure#1",
            );
            return track.title.toLowerCase().contains(filter);
          }).toList();
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
        identical(client, widget.runtime.client) &&
        key == widget.runtime.client.cacheIdentity;
  }

  Future<void> _loadSubscription() {
    AppLog.instance.trace(
      "lib/pages/catalogue_page.dart::_AlbumPageViewState._loadSubscription",
    );
    return AppLog.instance.runWithErrorScope(() async {
      AppLog.instance.trace(
        "lib/pages/catalogue_page.dart::_AlbumPageViewState._loadSubscription.closure#1",
      );

      final client = widget.runtime.client,
          key = widget.runtime.client.cacheIdentity;
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
      final client = widget.runtime.client,
          key = widget.runtime.client.cacheIdentity;
      if (!client.accountAvailable) {
        setState(() {
          AppLog.instance.trace(
            "lib/pages/catalogue_page.dart::_AlbumPageViewState._changeSubscription.closure#1.closure#1",
          );
          _subscriptionError = '请先登录后订阅专辑';
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
          });
        }
      }
    });
  }

  String get _subscriptionLabel {
    AppLog.instance.trace(
      "lib/pages/catalogue_page.dart::_AlbumPageViewState._subscriptionLabel.get",
    );
    return _subscriptionBusy
        ? '正在读取订阅状态'
        : !widget.runtime.client.accountAvailable
        ? '订阅（需登录）'
        : _subscribed == null
        ? '重试订阅状态'
        : _subscribed!
        ? '取消订阅'
        : '订阅专辑';
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
    return (scaler.scale(16) * 1.5 + scaler.scale(14) * 1.5 + 12).clamp(
      64.0,
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
      return track.id == target.id;
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
      if (_offline) {
        final tracks = _orderedForDisplay(_cachedTracks());
        if (target != null) {
          final index = tracks.indexWhere((track) {
            AppLog.instance.trace(
              "lib/pages/catalogue_page.dart::_AlbumPageViewState._loadPage.closure#1.closure#1",
            );
            return track.id == target.id;
          });
          if (index >= 0) page = index ~/ _pageSize + 1;
        }
        setState(() {
          AppLog.instance.trace(
            "lib/pages/catalogue_page.dart::_AlbumPageViewState._loadPage.closure#1.closure#2",
          );
          _showCached(page, orderedTracks: tracks);
        });
        if (target != null) _revealTarget(target, _generation);
        return;
      }
      final client = widget.runtime.client,
          key = widget.runtime.client.cacheIdentity;
      setState(() {
        AppLog.instance.trace(
          "lib/pages/catalogue_page.dart::_AlbumPageViewState._loadPage.closure#1.closure#3",
        );

        _busy = true;
        _error = null;
      });
      try {
        int? targetOrdinal;
        if (target != null) {
          final located = await _readCatalogue(client, () {
            AppLog.instance.trace(
              "lib/pages/catalogue_page.dart::_AlbumPageViewState._loadPage.closure#1.closure#4",
            );
            return _locateAlbumTrack(client, widget.albumId, target);
          });
          if (!_sameAccount(client, key) || generation != _generation) return;
          targetOrdinal = _trackOrdinal(located)!;
          page = (targetOrdinal - 1) ~/ _pageSize + 1;
        }
        if (_filter.isNotEmpty && _complete != null) {
          final filter = _filter.toLowerCase();
          final filtered = _orderedForDisplay(_complete!).where((track) {
            AppLog.instance.trace(
              "lib/pages/catalogue_page.dart::_AlbumPageViewState._loadPage.closure#1.closure#5",
            );
            return track.title.toLowerCase().contains(filter);
          }).toList();
          if (mounted && generation == _generation) {
            setState(() {
              AppLog.instance.trace(
                "lib/pages/catalogue_page.dart::_AlbumPageViewState._loadPage.closure#1.closure#6",
              );

              _page = page;
              _total = filtered.length;
              _visible = filtered
                  .skip((page - 1) * _pageSize)
                  .take(_pageSize)
                  .toList();
            });
          }
        } else {
          var result = await _readCatalogue(client, () {
            AppLog.instance.trace(
              "lib/pages/catalogue_page.dart::_AlbumPageViewState._loadPage.closure#1.closure#7",
            );
            return client.album(
              widget.albumId,
              page: page,
              pageSize: _pageSize,
              ascending: _ascending,
            );
          });
          if (!_sameAccount(client, key) || generation != _generation) return;
          if (!_ascending &&
              targetOrdinal != null &&
              targetOrdinal <= result.total) {
            final targetPage = (result.total - targetOrdinal) ~/ _pageSize + 1;
            if (targetPage != page) {
              page = targetPage;
              result = await _readCatalogue(client, () {
                AppLog.instance.trace(
                  "lib/pages/catalogue_page.dart::_AlbumPageViewState._loadPage.closure#1.closure#8",
                );
                return client.album(
                  widget.albumId,
                  page: page,
                  pageSize: _pageSize,
                  ascending: false,
                );
              });
            }
          }
          if (_sameAccount(client, key) && generation == _generation) {
            setState(() {
              AppLog.instance.trace(
                "lib/pages/catalogue_page.dart::_AlbumPageViewState._loadPage.closure#1.closure#9",
              );

              _offline = false;
              _cachedView = false;
              _complete = null;
              _album = result.album;
              _page = page;
              _total = result.total;
              _visible = result.tracks;
            });
            if (target != null) _revealTarget(target, generation);
            unawaited(_rememberPage(result));
          }
        }
      } catch (error, stack) {
        _recordCatalogueError('Catalogue load failed', error, stack);
        if (_sameAccount(client, key) && generation == _generation) {
          setState(() {
            AppLog.instance.trace(
              "lib/pages/catalogue_page.dart::_AlbumPageViewState._loadPage.closure#1.closure#10",
            );

            _restoreCache(page: page);
            _offline = _album != null;
            _error = _offline ? null : _safeError(error);
            if (target != null) _targetWarning = '暂时无法定位这集，目标信息已保留，请重新定位。';
          });
          if (_offline && target != null) {
            final index = _orderedForDisplay(_cachedTracks())
                .indexWhere((track) {
                  AppLog.instance.trace(
                    "lib/pages/catalogue_page.dart::_AlbumPageViewState._loadPage.closure#1.closure#11",
                  );
                  return track.id == target.id;
                });
            if (index >= 0) {
              setState(() {
                AppLog.instance.trace(
                  "lib/pages/catalogue_page.dart::_AlbumPageViewState._loadPage.closure#1.closure#12",
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
              "lib/pages/catalogue_page.dart::_AlbumPageViewState._loadPage.closure#1.closure#13",
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

  List<PopupMenuEntry<String>> _orderMenu() {
    AppLog.instance.trace(
      "lib/pages/catalogue_page.dart::_AlbumPageViewState._orderMenu",
    );
    return [
      CheckedPopupMenuItem(
        value: 'ascending',
        checked: _ascending,
        enabled: !_busy,
        child: const Text('最早在前'),
      ),
      CheckedPopupMenuItem(
        value: 'descending',
        checked: !_ascending,
        enabled: !_busy,
        child: const Text('最新在前'),
      ),
    ];
  }

  Future<List<Track>> _all() async {
    AppLog.instance.trace(
      "lib/pages/catalogue_page.dart::_AlbumPageViewState._all",
    );

    if (_complete != null) return _complete!;
    if (_offline) {
      throw const XmlyException('offline_catalogue', '离线目录不完整，无法按完整专辑下载');
    }
    final generation = _generation, client = widget.runtime.client;
    final identity = client.cacheIdentity;
    final tracks = await _readCatalogue(client, () {
      AppLog.instance.trace(
        "lib/pages/catalogue_page.dart::_AlbumPageViewState._all.closure#1",
      );
      return XmlyCatalogue(client).album(widget.albumId);
    });
    if (!mounted ||
        generation != _generation ||
        !identical(client, widget.runtime.client) ||
        identity != widget.runtime.client.cacheIdentity) {
      throw const XmlyException('catalogue_changed', '专辑目录已变化，请重新操作');
    }
    _complete = tracks;
    return tracks;
  }

  Future<void> _filterAll() {
    AppLog.instance.trace(
      "lib/pages/catalogue_page.dart::_AlbumPageViewState._filterAll",
    );
    return AppLog.instance.runWithErrorScope(() async {
      AppLog.instance.trace(
        "lib/pages/catalogue_page.dart::_AlbumPageViewState._filterAll.closure#1",
      );

      if (_busy) return;
      final generation = _generation;
      final filter = _search.text.trim();
      setState(() {
        AppLog.instance.trace(
          "lib/pages/catalogue_page.dart::_AlbumPageViewState._filterAll.closure#1.closure#1",
        );

        _busy = true;
        _error = null;
      });
      try {
        if (_offline) {
          _filter = filter;
          setState(() {
            AppLog.instance.trace(
              "lib/pages/catalogue_page.dart::_AlbumPageViewState._filterAll.closure#1.closure#2",
            );
            _showCached(1);
          });
          return;
        }
        if (filter.isNotEmpty) await _all();
        if (!mounted || generation != _generation) return;
        _filter = filter;
      } catch (error, stack) {
        _recordCatalogueError('Catalogue filtering failed', error, stack);
        if (mounted && generation == _generation)
          setState(() {
            AppLog.instance.trace(
              "lib/pages/catalogue_page.dart::_AlbumPageViewState._filterAll.closure#1.closure#3",
            );
            _error = _safeError(error);
          });
        return;
      } finally {
        if (mounted && generation == _generation)
          setState(() {
            AppLog.instance.trace(
              "lib/pages/catalogue_page.dart::_AlbumPageViewState._filterAll.closure#1.closure#4",
            );
            _busy = false;
          });
      }
      if (mounted && generation == _generation) await _loadPage(1);
    });
  }

  Future<void> _download({bool all = false}) {
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
        if (all) {
          await requestAlbumDownloads(context, widget.runtime, widget.albumId);
          return;
        }
        final requested = range.isNotEmpty
            ? XmlyCatalogue.selectRange(await _all(), range)
            : selected;
        if (requested.isEmpty)
          throw const XmlyException('empty_selection', '请选择未下载的声音或填写集数范围');
        if (!mounted) return;
        // Preparation checks completed files before deduplicating their tasks.
        await requestDownloads(context, widget.runtime, requested);
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

  Future<void> _play(Track track) async {
    AppLog.instance.trace(
      "lib/pages/catalogue_page.dart::_AlbumPageViewState._play",
    );

    if (_offline) {
      final task = await _localDownload(track);
      if (!mounted) return;
      if (task == null)
        throw const XmlyException('offline_playback', '此声音本地文件不存在，请重新下载后播放');
      await widget.runtime.player.playLocal(task.id);
      return;
    }
    if (widget.onPlayAlbum != null) {
      final position = track.officialPosition;
      await widget.onPlayAlbum!(
        widget.albumId,
        track.id,
        page: position == null
            ? (_filter.isEmpty && _ascending ? _page : null)
            : (position - 1) ~/ _pageSize + 1,
        track: track,
      );
    } else {
      await widget.runtime.player.playAlbum(
        widget.albumId,
        track.id,
        track: track,
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
        await widget.runtime.player.addToQueue(track);
      case 'next':
        await widget.runtime.player.playNext(track);
      case 'download':
        final task = await _localDownload(track);
        if (mounted && task == null)
          await requestDownloads(context, widget.runtime, [track]);
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

      final client = widget.runtime.client,
          key = widget.runtime.client.cacheIdentity;
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
      case 'ascending':
        _setOrder(true);
      case 'descending':
        _setOrder(false);
      case 'subscribe':
        _changeSubscription();
      case 'refresh':
        _offline = false;
        _complete = null;
        _filter = '';
        _search.clear();
        _loadPage(1);
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

  @override
  Widget build(BuildContext context) {
    AppLog.instance.trace(
      "lib/pages/catalogue_page.dart::_AlbumPageViewState.build",
    );

    final album = _album;
    final identity = widget.runtime.accounts.primaryAccountId;
    final automatic = widget.runtime.autoDownloads;
    final compact =
        MediaQuery.sizeOf(context).width < (usesWindowHeader ? 640 : 320);
    final canDownload = !_busy && !widget.runtime.accounts.admissionPaused;
    return Scaffold(
      appBar: AppHeader(
        windowControls: !widget.inPanel,
        leading: widget.inPanel
            ? IconButton(
                tooltip: '收起专辑',
                onPressed: () {
                  AppLog.instance.trace(
                    "lib/pages/catalogue_page.dart::_AlbumPageViewState.build.closure#1",
                  );
                  Navigator.of(context).maybePop();
                },
                icon: const Icon(Icons.close_rounded),
              )
            : null,
        title: AdaptiveText(
          album?.title.isNotEmpty == true
              ? album!.title
              : '专辑 ${widget.albumId}',
        ),
        actions: [
          if (!compact && _offline)
            IconButton(
              tooltip: '刷新专辑',
              icon: const Icon(Icons.refresh),
              onPressed: _busy
                  ? null
                  : () {
                      AppLog.instance.trace(
                        "lib/pages/catalogue_page.dart::_AlbumPageViewState.build.closure#2",
                      );
                      _albumAction('refresh');
                    },
            ),
          IconButton(
            tooltip: _showSearch ? '隐藏搜索' : '搜索本专辑',
            icon: Icon(_showSearch ? Icons.search_off : Icons.search),
            onPressed: () {
              AppLog.instance.trace(
                "lib/pages/catalogue_page.dart::_AlbumPageViewState.build.closure#3",
              );
              setState(() {
                AppLog.instance.trace(
                  "lib/pages/catalogue_page.dart::_AlbumPageViewState.build.closure#3.closure#1",
                );
                _showSearch = !_showSearch;
              });
            },
          ),
          if (compact)
            PopupMenuButton<String>(
              tooltip: '更多操作',
              offset: const Offset(0, 12),
              onSelected: _albumAction,
              itemBuilder: (_) {
                AppLog.instance.trace(
                  "lib/pages/catalogue_page.dart::_AlbumPageViewState.build.closure#4",
                );
                return [
                  ..._orderMenu(),
                  const PopupMenuDivider(),
                  PopupMenuItem(
                    value: 'subscribe',
                    enabled: !_subscriptionBusy,
                    child: Text(_subscriptionLabel),
                  ),
                  if (_offline)
                    PopupMenuItem(
                      value: 'refresh',
                      enabled: !_busy,
                      child: const Text('刷新专辑'),
                    ),
                  const PopupMenuItem(value: 'tags', child: Text('专辑标签')),
                  const PopupMenuItem(value: 'settings', child: Text('播放设置')),
                ];
              },
            )
          else ...[
            PopupMenuButton<String>(
              tooltip: '目录排序：${_ascending ? "最早在前" : "最新在前"}',
              offset: const Offset(0, 12),
              icon: const Icon(Icons.sort),
              onSelected: _albumAction,
              itemBuilder: (_) {
                AppLog.instance.trace(
                  "lib/pages/catalogue_page.dart::_AlbumPageViewState.build.closure#5",
                );
                return _orderMenu();
              },
            ),
            IconButton(
              tooltip: '专辑标签',
              icon: const Icon(Icons.edit_note),
              onPressed: () {
                AppLog.instance.trace(
                  "lib/pages/catalogue_page.dart::_AlbumPageViewState.build.closure#6",
                );
                _albumAction('tags');
              },
            ),
            IconButton(
              tooltip: '播放设置',
              icon: const Icon(Icons.headphones_outlined),
              onPressed: () {
                AppLog.instance.trace(
                  "lib/pages/catalogue_page.dart::_AlbumPageViewState.build.closure#7",
                );
                _albumAction('settings');
              },
            ),
          ],
        ],
      ),
      body: SafeArea(
        top: false,
        child: LayoutBuilder(
          builder: (context, constraints) {
            AppLog.instance.trace(
              "lib/pages/catalogue_page.dart::_AlbumPageViewState.build.closure#8",
            );

            final padding = EdgeInsets.symmetric(
              horizontal: ((constraints.maxWidth - 960) / 2).clamp(
                0.0,
                double.infinity,
              ),
            );
            return Scrollbar(
              controller: _albumScroll,
              child: CustomScrollView(
                controller: _albumScroll,
                scrollBehavior: ScrollConfiguration.of(context)
                    .copyWith(scrollbars: false),
                slivers:
                    [
                      SliverToBoxAdapter(
                        child: Column(
                          key: _headerKey,
                          children: [
                            if (widget.initialTrack case final target?)
                              ListTile(
                                title: AdaptiveText('搜索目标：${target.title}'),
                                subtitle: _targetWarning == null
                                    ? null
                                    : Text(_targetWarning!),
                                trailing: TextButton(
                                  onPressed: _busy
                                      ? null
                                      : () {
                                          AppLog.instance.trace(
                                            "lib/pages/catalogue_page.dart::_AlbumPageViewState.build.closure#8.closure#1",
                                          );

                                          _filter = '';
                                          _search.clear();
                                          _loadPage(1, target: target);
                                        },
                                  child: const Text('重新定位'),
                                ),
                              ),
                            if (album != null)
                              Padding(
                                padding: EdgeInsets.all(compact ? 8 : 12),
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    if (!compact)
                                      CoverImage(
                                        uri:
                                            album.coverUrl ??
                                            (_visible.isEmpty
                                                ? null
                                                : _visible.first.coverUrl),
                                        localPath: widget
                                            .runtime
                                            .albumCache[widget.albumId]
                                            ?.coverPath,
                                        size: 72,
                                        downloaded: widget
                                            .runtime
                                            .downloads
                                            .tasks
                                            .any((task) {
                                              AppLog.instance.trace(
                                                "lib/pages/catalogue_page.dart::_AlbumPageViewState.build.closure#8.closure#2",
                                              );
                                              return task.track.albumId ==
                                                      widget.albumId &&
                                                  task.state ==
                                                      DownloadState.completed;
                                            }),
                                      ),
                                    if (!compact) const SizedBox(width: 12),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          AdaptiveText(
                                            album.title,
                                            style: Theme.of(context)
                                                .textTheme
                                                .titleLarge,
                                          ),
                                          AdaptiveText(
                                            '${album.artist} · ${album.total} 集',
                                          ),
                                          AlbumIntroduction(
                                            text: album.intro,
                                            client: widget.runtime.anonymous,
                                            albumId: album.id,
                                            onOpenAlbum: (recommended) {
                                              AppLog.instance.trace(
                                                "lib/pages/catalogue_page.dart::_AlbumPageViewState.build.closure#8.closure#3",
                                              );

                                              Navigator.of(context).push(
                                                MaterialPageRoute<void>(
                                                  builder: (_) {
                                                    AppLog.instance.trace(
                                                      "lib/pages/catalogue_page.dart::_AlbumPageViewState.build.closure#8.closure#3.closure#1",
                                                    );
                                                    return AlbumPageView(
                                                      runtime: widget.runtime,
                                                      albumId: recommended.id,
                                                      onDownload:
                                                          widget.onDownload,
                                                      onPlayAlbum:
                                                          widget.onPlayAlbum,
                                                    );
                                                  },
                                                ),
                                              );
                                            },
                                          ),
                                          if (_cachedView)
                                            const Text('离线缓存（仅显示已观察目录与已下载声音）'),
                                          OutlinedButton.icon(
                                            onPressed: _subscriptionBusy
                                                ? null
                                                : _changeSubscription,
                                            icon: Icon(
                                              _subscribed == true
                                                  ? Icons.check_circle_outline
                                                  : Icons.add_circle_outline,
                                            ),
                                            label: Text(_subscriptionLabel),
                                          ),
                                          if (_subscriptionError != null)
                                            Text(
                                              _subscriptionError!,
                                              style: TextStyle(
                                                color: Theme.of(context)
                                                    .colorScheme
                                                    .error,
                                              ),
                                            ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            SwitchListTile(
                              title: const Text('自动下载新声音'),
                              subtitle: Text(
                                identity == null
                                    ? '登录后可开启'
                                    : '仅下载开启后新增的声音，使用主账号正常扣时',
                              ),
                              value:
                                  identity != null &&
                                  automatic.enabled(identity, widget.albumId),
                              onChanged: identity == null || _autoBusy
                                  ? null
                                  : (_) {
                                      AppLog.instance.trace(
                                        "lib/pages/catalogue_page.dart::_AlbumPageViewState.build.closure#8.closure#4",
                                      );
                                      _autoDownload(identity);
                                    },
                            ),
                            if (identity != null &&
                                automatic.errorFor(identity, widget.albumId) !=
                                    null)
                              Padding(
                                padding: EdgeInsets.all(compact ? 8 : 16),
                                child: Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        automatic.errorFor(
                                          identity,
                                          widget.albumId,
                                        )!,
                                      ),
                                    ),
                                    TextButton(
                                      onPressed: _scanUpdates,
                                      child: const Text('重新检查'),
                                    ),
                                  ],
                                ),
                              ),
                            if (_showSearch)
                              Padding(
                                padding: EdgeInsets.symmetric(
                                  horizontal: compact ? 8 : 16,
                                ),
                                child: Row(
                                  children: [
                                    Expanded(
                                      child: TextField(
                                        controller: _search,
                                        decoration: InputDecoration(
                                          labelText: _offline
                                              ? '搜索已缓存声音'
                                              : '搜索本专辑全部声音',
                                        ),
                                        onSubmitted: (_) {
                                          AppLog.instance.trace(
                                            "lib/pages/catalogue_page.dart::_AlbumPageViewState.build.closure#8.closure#5",
                                          );
                                          _filterAll();
                                        },
                                      ),
                                    ),
                                    IconButton(
                                      tooltip: '搜索本专辑',
                                      onPressed: _busy ? null : _filterAll,
                                      icon: const Icon(Icons.search),
                                    ),
                                  ],
                                ),
                              ),
                            Padding(
                              padding: EdgeInsets.all(compact ? 8 : 16),
                              child: Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                children: [
                                  OutlinedButton.icon(
                                    onPressed: () {
                                      AppLog.instance.trace(
                                        "lib/pages/catalogue_page.dart::_AlbumPageViewState.build.closure#8.closure#6",
                                      );
                                      setState(() {
                                        AppLog.instance.trace(
                                          "lib/pages/catalogue_page.dart::_AlbumPageViewState.build.closure#8.closure#6.closure#1",
                                        );

                                        if (_selectionMode) {
                                          _clearSelection();
                                        } else {
                                          _selectionMode = true;
                                        }
                                      });
                                    },
                                    icon: Icon(
                                      _selectionMode
                                          ? Icons.close
                                          : Icons.checklist,
                                    ),
                                    label: Text(
                                      _selectionMode ? '退出下载模式' : '进入下载模式',
                                    ),
                                  ),
                                  OutlinedButton.icon(
                                    onPressed: canDownload
                                        ? () {
                                            AppLog.instance.trace(
                                              "lib/pages/catalogue_page.dart::_AlbumPageViewState.build.closure#8.closure#7",
                                            );
                                            _download(all: true);
                                          }
                                        : null,
                                    icon: const Icon(
                                      Icons.download_for_offline_outlined,
                                    ),
                                    label: const Text('下载整个专辑'),
                                  ),
                                  if (_selectionMode) ...[
                                    SizedBox(
                                      width:
                                          (MediaQuery.sizeOf(context).width -
                                                  (compact ? 16 : 32))
                                              .clamp(0.0, 240.0)
                                              .toDouble(),
                                      child: TextField(
                                        controller: _range,
                                        decoration: const InputDecoration(
                                          labelText: '集数范围',
                                          hintText: '1-1000 或 1,3,5-8',
                                        ),
                                      ),
                                    ),
                                    FilledButton(
                                      onPressed: canDownload
                                          ? () {
                                              AppLog.instance.trace(
                                                "lib/pages/catalogue_page.dart::_AlbumPageViewState.build.closure#8.closure#8",
                                              );
                                              _download();
                                            }
                                          : null,
                                      child: Text('下载所选 (${_selected.length})'),
                                    ),
                                    TextButton(
                                      onPressed: () {
                                        AppLog.instance.trace(
                                          "lib/pages/catalogue_page.dart::_AlbumPageViewState.build.closure#8.closure#9",
                                        );
                                        setState(() {
                                          AppLog.instance.trace(
                                            "lib/pages/catalogue_page.dart::_AlbumPageViewState.build.closure#8.closure#9.closure#1",
                                          );

                                          for (final track in _visible) {
                                            _select(track, true);
                                          }
                                        });
                                      },
                                      child: const Text('选择本页'),
                                    ),
                                    TextButton(
                                      onPressed: () {
                                        AppLog.instance.trace(
                                          "lib/pages/catalogue_page.dart::_AlbumPageViewState.build.closure#8.closure#10",
                                        );
                                        setState(_clearSelection);
                                      },
                                      child: const Text('清除选择'),
                                    ),
                                  ],
                                ],
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
                                        color: Theme.of(context)
                                            .colorScheme
                                            .error,
                                      ),
                                    ),
                                    if (_album == null) ...[
                                      const SizedBox(height: 8),
                                      TextButton.icon(
                                        onPressed: _busy
                                            ? null
                                            : () {
                                                AppLog.instance.trace(
                                                  "lib/pages/catalogue_page.dart::_AlbumPageViewState.build.closure#8.closure#11",
                                                );
                                                _loadPage(_page);
                                              },
                                        icon: const Icon(Icons.refresh_rounded),
                                        label: const Text('重新加载专辑'),
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                          ],
                        ),
                      ),
                      SliverFixedExtentList.builder(
                        itemExtent: _trackExtent,
                        itemCount: _visible.length,
                        itemBuilder: (_, index) {
                          AppLog.instance.trace(
                            "lib/pages/catalogue_page.dart::_AlbumPageViewState.build.closure#8.closure#12",
                          );

                          final track = _visible[index];
                          final downloaded = _downloaded.contains(track.id);
                          return ListTile(
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 12,
                            ),
                            minTileHeight: _trackExtent,
                            minVerticalPadding: 4,
                            horizontalTitleGap: 12,
                            selected: track.id == widget.initialTrack?.id,
                            leading: _selectionMode
                                ? Checkbox(
                                    value: _selected.containsKey(track.id),
                                    onChanged: downloaded
                                        ? null
                                        : (value) {
                                            AppLog.instance.trace(
                                              "lib/pages/catalogue_page.dart::_AlbumPageViewState.build.closure#8.closure#12.closure#1",
                                            );
                                            setState(() {
                                              AppLog.instance.trace(
                                                "lib/pages/catalogue_page.dart::_AlbumPageViewState.build.closure#8.closure#12.closure#1.closure#1",
                                              );
                                              _select(track, value == true);
                                            });
                                          },
                                  )
                                : (compact
                                      ? null
                                      : CoverImage(
                                          size: 48,
                                          uri:
                                              track.coverUrl ?? album?.coverUrl,
                                          downloaded: downloaded,
                                          localPath: widget
                                              .runtime
                                              .albumCache[widget.albumId]
                                              ?.coverPath,
                                        )),
                            title: AdaptiveText(track.title),
                            subtitle: Text(
                              '${_duration(track.duration)}${downloaded ? ' · 已下载' : ''}',
                            ),
                            trailing: _menu(track),
                            onLongPress: () {
                              AppLog.instance.trace(
                                "lib/pages/catalogue_page.dart::_AlbumPageViewState.build.closure#8.closure#12.closure#2",
                              );
                              setState(() {
                                AppLog.instance.trace(
                                  "lib/pages/catalogue_page.dart::_AlbumPageViewState.build.closure#8.closure#12.closure#2.closure#1",
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
                                            "lib/pages/catalogue_page.dart::_AlbumPageViewState.build.closure#8.closure#12.closure#3",
                                          );
                                          setState(() {
                                            AppLog.instance.trace(
                                              "lib/pages/catalogue_page.dart::_AlbumPageViewState.build.closure#8.closure#12.closure#3.closure#1",
                                            );
                                            _select(
                                              track,
                                              !_selected.containsKey(track.id),
                                            );
                                          });
                                        }
                                : () {
                                    AppLog.instance.trace(
                                      "lib/pages/catalogue_page.dart::_AlbumPageViewState.build.closure#8.closure#12.closure#4",
                                    );
                                    unawaited(
                                      AppLog.instance.runWithErrorScope(
                                        () async {
                                          AppLog.instance.trace(
                                            "lib/pages/catalogue_page.dart::_AlbumPageViewState.build.closure#8.closure#12.closure#4.closure#1",
                                          );

                                          try {
                                            await _play(track);
                                          } catch (error, stack) {
                                            _recordCatalogueError(
                                              'Playback failed',
                                              error,
                                              stack,
                                            );
                                            if (mounted)
                                              setState(() {
                                                AppLog.instance.trace(
                                                  "lib/pages/catalogue_page.dart::_AlbumPageViewState.build.closure#8.closure#12.closure#4.closure#1.closure#1",
                                                );
                                                _error = _safeError(error);
                                              });
                                          }
                                        },
                                      ),
                                    );
                                  },
                          );
                        },
                      ),
                      if (_album != null)
                        SliverToBoxAdapter(
                          child: _Paging(
                            page: _page,
                            total: _total,
                            pageSize: _pageSize,
                            busy: _busy,
                            onPage: _loadPage,
                          ),
                        ),
                    ].map((sliver) {
                      AppLog.instance.trace(
                        "lib/pages/catalogue_page.dart::_AlbumPageViewState.build.closure#8.closure#13",
                      );
                      return SliverPadding(padding: padding, sliver: sliver);
                    }).toList(),
              ),
            );
          },
        ),
      ),
    );
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

class _Paging extends StatelessWidget {
  const _Paging({
    required this.page,
    required this.total,
    required this.pageSize,
    required this.busy,
    required this.onPage,
  });
  final int page, total, pageSize;
  final bool busy;
  final Future<void> Function(int) onPage;

  Future<void> _jumpToPage(BuildContext context) async {
    AppLog.instance.trace("lib/pages/catalogue_page.dart::_Paging._jumpToPage");

    final last = (total / pageSize).ceil().clamp(1, 10000);
    final form = GlobalKey<FormState>();
    var selected = page;
    final target = await showDialog<int>(
      context: context,
      builder: (context) {
        AppLog.instance.trace(
          "lib/pages/catalogue_page.dart::_Paging._jumpToPage.closure#1",
        );

        void submit() {
          AppLog.instance.trace(
            "lib/pages/catalogue_page.dart::_Paging._jumpToPage.closure#1.submit",
          );

          if (!form.currentState!.validate()) return;
          form.currentState!.save();
          Navigator.of(context).pop(selected);
        }

        return AlertDialog(
          title: const Text('跳转页码'),
          content: Form(
            key: form,
            child: TextFormField(
              initialValue: '$page',
              autofocus: true,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                labelText: '页码',
                helperText: '请输入 1–$last 页',
              ),
              validator: (value) {
                AppLog.instance.trace(
                  "lib/pages/catalogue_page.dart::_Paging._jumpToPage.closure#1.closure#1",
                );

                if (value == null || !RegExp(r'^[0-9]+$').hasMatch(value))
                  return '请输入数字页码';
                final number = int.tryParse(value);
                if (number == null || number < 1 || number > last)
                  return '页码须在 1–$last 之间';
                return null;
              },
              onSaved: (value) {
                AppLog.instance.trace(
                  "lib/pages/catalogue_page.dart::_Paging._jumpToPage.closure#1.closure#2",
                );
                selected = int.parse(value!);
              },
              onFieldSubmitted: (_) {
                AppLog.instance.trace(
                  "lib/pages/catalogue_page.dart::_Paging._jumpToPage.closure#1.closure#3",
                );
                submit();
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                AppLog.instance.trace(
                  "lib/pages/catalogue_page.dart::_Paging._jumpToPage.closure#1.closure#4",
                );
                Navigator.of(context).pop();
              },
              child: const Text('取消'),
            ),
            FilledButton(onPressed: submit, child: const Text('跳转')),
          ],
        );
      },
    );
    if (target != null && context.mounted && !busy) await onPage(target);
  }

  @override
  Widget build(BuildContext context) {
    AppLog.instance.trace("lib/pages/catalogue_page.dart::_Paging.build");
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Row(
        children: [
          IconButton(
            tooltip: '上一页',
            onPressed: busy || page <= 1
                ? null
                : () {
                    AppLog.instance.trace(
                      "lib/pages/catalogue_page.dart::_Paging.build.closure#1",
                    );
                    onPage(page - 1);
                  },
            icon: const Icon(Icons.chevron_left),
          ),
          Expanded(
            child: TextButton(
              onPressed: busy
                  ? null
                  : () {
                      AppLog.instance.trace(
                        "lib/pages/catalogue_page.dart::_Paging.build.closure#2",
                      );
                      _jumpToPage(context);
                    },
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  AdaptiveText(
                    '第 $page / ${(total / pageSize).ceil().clamp(1, 10000)} 页',
                  ),
                  AdaptiveText(
                    '共 $total 项',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ),
          IconButton(
            tooltip: '下一页',
            onPressed: busy || page * pageSize >= total
                ? null
                : () {
                    AppLog.instance.trace(
                      "lib/pages/catalogue_page.dart::_Paging.build.closure#3",
                    );
                    onPage(page + 1);
                  },
            icon: const Icon(Icons.chevron_right),
          ),
        ],
      ),
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
