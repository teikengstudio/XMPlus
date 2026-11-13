import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api/xmly_client.dart';
import '../api/xmly_experience.dart';
import '../common/widgets/adaptive_text.dart';
import '../common/widgets/app_header.dart';
import '../common/widgets/app_tab_button.dart';
import '../common/widgets/confirmation_dialog.dart';
import '../common/widgets/logged_network_image.dart';
import '../common/widgets/local_panel.dart';
import '../common/widgets/playback_action_button.dart';
import '../models/xmly_models.dart';
import '../services/app_log.dart';
import '../services/app_runtime.dart';
import 'catalogue_page.dart';
import 'manuscript_reader.dart';
import 'playback_settings_page.dart';
import 'playback_speed_control.dart';
import 'player_queue_panel.dart';
import 'playback_volume_control.dart';
import 'track_comments_panel.dart';

void _recordPlayerPanelError(
  String operation,
  Object error,
  StackTrace stack, {
  bool recoverable = false,
}) {
  AppLog.instance.trace("lib/pages/player_panel.dart::_recordPlayerPanelError");

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
        'invalid_page',
      }.contains(error.code);
  log.write(
    recoverable || expected ? AppLogLevel.warning : AppLogLevel.error,
    'player_panel',
    operation,
    error: error,
    stackTrace: stack,
    promptUser: !recoverable && !expected,
  );
}

String playbackTime(double seconds) {
  AppLog.instance.trace("lib/pages/player_panel.dart::playbackTime");

  final total = seconds.isFinite && seconds > 0 ? seconds.floor() : 0;
  final hours = total ~/ 3600;
  final minutes = (total ~/ 60) % 60;
  final rest = (total % 60).toString().padLeft(2, '0');
  return hours > 0
      ? '$hours:${minutes.toString().padLeft(2, '0')}:$rest'
      : '$minutes:$rest';
}

class PlayerPanel extends StatefulWidget {
  const PlayerPanel({
    required this.runtime,
    this.expanded = false,
    this.miniWindow = false,
    this.onExpand,
    this.navigatorKey,
    super.key,
  });
  static const routeName = '/player';
  final AppRuntime runtime;
  final bool expanded;
  final bool miniWindow;
  final VoidCallback? onExpand;
  final GlobalKey<NavigatorState>? navigatorKey;

  @override
  State<PlayerPanel> createState() {
    AppLog.instance.trace(
      "lib/pages/player_panel.dart::PlayerPanel.createState",
    );
    return _PlayerPanelState();
  }
}

class _PlayerPanelState extends State<PlayerPanel> {
  PageController _pages = PageController(keepPage: false);
  final _retiredPages = <PageController>{};
  int _paneCount = 1, _secondaryPage = 1;
  (int, bool)? _pendingPaneLayout;
  bool _configuredManuscript = true;
  bool _changingPaneLayout = false;
  final _visitedPages = <int>{0};
  int _selectedPage = 0;
  final _keyboardFocus = FocusNode(
    debugLabel: 'Player shortcuts',
    skipTraversal: true,
  );
  bool _busy = false, _cancelling = false;
  double? _dragPosition;
  int? _dragEpoch;
  String? _error;
  XmlyClient? _favoriteClient;
  String? _favoriteKey, _favoriteTrackId, _favoriteError;
  bool? _favorite;
  bool _favoriteBusy = false, _favoriteMutating = false;
  int _favoriteRequest = 0, _libraryRevision = -1;
  XmlyClient? _likeClient;
  String? _likeKey, _likeTrackId, _likeError, _likeCountError;
  int? _likeCount;
  bool _likeBusy = false, _likeCountLoading = false;
  int _likeRequest = 0, _likeCountRequest = 0;
  XmlyClient? _manuscriptClient;
  String? _manuscriptKey, _manuscriptTrackId, _manuscript, _manuscriptError;
  bool _manuscriptLoading = false;
  bool _manuscriptLoaded = false;
  int _manuscriptRequest = 0;
  Completer<void>? _manuscriptCancelled;
  AppRuntime get _runtime {
    AppLog.instance.trace(
      "lib/pages/player_panel.dart::_PlayerPanelState._runtime.get",
    );
    return widget.runtime;
  }

  NavigatorState get _navigator {
    AppLog.instance.trace(
      "lib/pages/player_panel.dart::_PlayerPanelState._navigator.get",
    );
    return widget.navigatorKey?.currentState ?? Navigator.of(context);
  }

  @override
  void initState() {
    AppLog.instance.trace(
      "lib/pages/player_panel.dart::_PlayerPanelState.initState",
    );

    super.initState();
    _runtime.addListener(_favoriteContextChanged);
    _runtime.addListener(_likeContextChanged);
    _runtime.addListener(_manuscriptContextChanged);
    if (widget.expanded) {
      unawaited(_refreshFavorite());
      _refreshLikes();
      unawaited(_refreshManuscript());
    }
  }

  @override
  void didUpdateWidget(covariant PlayerPanel oldWidget) {
    AppLog.instance.trace(
      "lib/pages/player_panel.dart::_PlayerPanelState.didUpdateWidget",
    );

    super.didUpdateWidget(oldWidget);
    if (oldWidget.runtime != _runtime) {
      oldWidget.runtime.removeListener(_favoriteContextChanged);
      oldWidget.runtime.removeListener(_likeContextChanged);
      oldWidget.runtime.removeListener(_manuscriptContextChanged);
      _runtime.addListener(_manuscriptContextChanged);
      _runtime.addListener(_favoriteContextChanged);
      _runtime.addListener(_likeContextChanged);
      _dragPosition = null;
      _dragEpoch = null;
    }
    if (widget.expanded &&
        (oldWidget.runtime != _runtime || !oldWidget.expanded)) {
      unawaited(_refreshFavorite());
      _refreshLikes();
    }
    if (oldWidget.runtime != _runtime && !widget.expanded) _refreshLikes();
    if (oldWidget.runtime != _runtime ||
        oldWidget.expanded != widget.expanded) {
      unawaited(_refreshManuscript());
    }
  }

  @override
  void dispose() {
    AppLog.instance.trace(
      "lib/pages/player_panel.dart::_PlayerPanelState.dispose",
    );

    _runtime.removeListener(_favoriteContextChanged);
    _runtime.removeListener(_likeContextChanged);
    _runtime.removeListener(_manuscriptContextChanged);
    _manuscriptRequest++;
    _manuscriptCancelled?.complete();
    _manuscriptCancelled = null;
    _favoriteRequest++;
    _likeRequest++;
    _likeCountRequest++;
    _pages.dispose();
    for (final controller in _retiredPages) {
      controller.dispose();
    }
    _retiredPages.clear();
    _keyboardFocus.dispose();
    super.dispose();
  }

  bool get _desktopKeyboard {
    AppLog.instance.trace(
      "lib/pages/player_panel.dart::_PlayerPanelState._desktopKeyboard.get",
    );
    return switch (Theme.of(context).platform) {
      TargetPlatform.windows ||
      TargetPlatform.macOS ||
      TargetPlatform.linux => true,
      _ => false,
    };
  }

  String _keyHint(String label, String key) {
    AppLog.instance.trace(
      "lib/pages/player_panel.dart::_PlayerPanelState._keyHint",
    );
    return _desktopKeyboard ? '$label（$key）' : label;
  }

  KeyEventResult _onPlayerKey(FocusNode node, KeyEvent event) {
    AppLog.instance.trace(
      "lib/pages/player_panel.dart::_PlayerPanelState._onPlayerKey",
    );

    // Descendant controls keep their own activation, editing and navigation.
    // Also exclude routes above this player, including non-focusing dialogs.
    if (!node.hasPrimaryFocus || ModalRoute.of(context)?.isCurrent == false) {
      return KeyEventResult.ignored;
    }
    final keyboard = HardwareKeyboard.instance;
    if (keyboard.isControlPressed ||
        keyboard.isAltPressed ||
        keyboard.isMetaPressed ||
        keyboard.isShiftPressed) {
      return KeyEventResult.ignored;
    }
    if (widget.expanded && _paneCount == 1 && _selectedPage != 0) {
      return KeyEventResult.ignored;
    }
    final player = _runtime.player;
    if (player.current == null) return KeyEventResult.ignored;
    final command = switch (event.logicalKey) {
      LogicalKeyboardKey.space => _playPause,
      LogicalKeyboardKey.arrowLeft => player.seekBackward,
      LogicalKeyboardKey.arrowRight => player.seekForward,
      _ => null,
    };
    if (command == null) return KeyEventResult.ignored;
    // One command per press; repeats must not toggle or enqueue more seeks.
    if (event is KeyDownEvent) {
      unawaited(
        event.logicalKey == LogicalKeyboardKey.space
            ? _playPause()
            : _act(command),
      );
    }
    return KeyEventResult.handled;
  }

  Widget _withKeyboard(Widget child) {
    AppLog.instance.trace(
      "lib/pages/player_panel.dart::_PlayerPanelState._withKeyboard",
    );
    return !_desktopKeyboard
        ? child
        : Focus(
            focusNode: _keyboardFocus,
            autofocus: true,
            onKeyEvent: _onPlayerKey,
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: _keyboardFocus.requestFocus,
              child: child,
            ),
          );
  }

  void _manuscriptContextChanged() {
    AppLog.instance.trace(
      "lib/pages/player_panel.dart::_PlayerPanelState._manuscriptContextChanged",
    );

    if (!mounted || !widget.expanded) return;
    final client = _runtime.client;
    if (!identical(client, _manuscriptClient) ||
        client.cacheIdentity != _manuscriptKey ||
        _runtime.player.current?.id != _manuscriptTrackId) {
      unawaited(_refreshManuscript());
    }
  }

  Future<void> _refreshManuscript({bool force = false}) {
    AppLog.instance.trace(
      "lib/pages/player_panel.dart::_PlayerPanelState._refreshManuscript",
    );
    return AppLog.instance.runWithErrorScope(() async {
      AppLog.instance.trace(
        "lib/pages/player_panel.dart::_PlayerPanelState._refreshManuscript.closure#1",
      );

      final client = _runtime.client, key = _runtime.client.cacheIdentity;
      final trackId = _runtime.player.current?.id;
      if (!force &&
          widget.expanded &&
          identical(client, _manuscriptClient) &&
          key == _manuscriptKey &&
          trackId == _manuscriptTrackId &&
          (_manuscriptLoaded || _manuscriptLoading)) {
        return;
      }
      final request = ++_manuscriptRequest;
      _manuscriptCancelled?.complete();
      _manuscriptCancelled = null;
      _manuscriptClient = client;
      _manuscriptKey = key;
      _manuscriptTrackId = trackId;
      setState(() {
        AppLog.instance.trace(
          "lib/pages/player_panel.dart::_PlayerPanelState._refreshManuscript.closure#1.closure#1",
        );

        _manuscript = null;
        _manuscriptError = null;
        _manuscriptLoaded = false;
        _manuscriptLoading = widget.expanded && trackId != null;
      });
      if (!_manuscriptLoading) return;
      final cancelled = _manuscriptCancelled = Completer<void>();
      bool current() {
        AppLog.instance.trace(
          "lib/pages/player_panel.dart::_PlayerPanelState._refreshManuscript.closure#1.current",
        );
        return mounted &&
            widget.expanded &&
            request == _manuscriptRequest &&
            identical(client, _runtime.client) &&
            key == _runtime.client.cacheIdentity &&
            trackId == _runtime.player.current?.id;
      }

      try {
        final manuscript = await client.withReadPolicy(
          () {
            AppLog.instance.trace(
              "lib/pages/player_panel.dart::_PlayerPanelState._refreshManuscript.closure#1.closure#2",
            );
            return client.fetchManuscript(trackId!);
          },
          rateLimitRetries: 0,
          cancelled: cancelled.future,
        );
        if (current()) {
          setState(() {
            AppLog.instance.trace(
              "lib/pages/player_panel.dart::_PlayerPanelState._refreshManuscript.closure#1.closure#3",
            );

            _manuscript = manuscript;
            _manuscriptLoaded = true;
            if (manuscript == null) {
              if (_selectedPage == 1) _selectedPage = 2;
              if (_secondaryPage == 1) _secondaryPage = 2;
              if (_paneCount == 2 || _selectedPage == 2) {
                _visitedPages.add(2);
              }
            }
          });
        }
      } catch (error, stack) {
        _recordPlayerPanelError('Manuscript load failed', error, stack);
        if (current()) {
          setState(() {
            AppLog.instance.trace(
              "lib/pages/player_panel.dart::_PlayerPanelState._refreshManuscript.closure#1.closure#4",
            );
            _manuscriptError = error is XmlyException
                ? error.message
                : '文稿读取失败，请重试';
          });
        }
      } finally {
        if (current()) {
          _manuscriptCancelled = null;
          setState(() {
            AppLog.instance.trace(
              "lib/pages/player_panel.dart::_PlayerPanelState._refreshManuscript.closure#1.closure#5",
            );
            _manuscriptLoading = false;
          });
        }
      }
    });
  }

  void _selectPage(int page) {
    AppLog.instance.trace(
      'lib/pages/player_panel.dart::_PlayerPanelState._selectPage',
    );
    if (!_pageOrder.contains(page)) return;
    setState(() {
      AppLog.instance.trace(
        'lib/pages/player_panel.dart::_PlayerPanelState._selectPage.closure#1',
      );
      _selectedPage = page;
      if (page != 0) _secondaryPage = page;
      _visitedPages.add(page);
    });
    if (_paneCount == 1 && _pages.hasClients && !_changingPaneLayout) {
      unawaited(
        _pages.animateToPage(
          _pageOrder.indexOf(page),
          duration: MediaQuery.disableAnimationsOf(context)
              ? Duration.zero
              : const Duration(milliseconds: 250),
          curve: Curves.easeOutCubic,
        ),
      );
    }
  }

  bool get _hasManuscript {
    AppLog.instance.trace(
      'lib/pages/player_panel.dart::_PlayerPanelState._hasManuscript.get',
    );
    return !_manuscriptLoaded || _manuscript != null;
  }

  List<int> get _pageOrder {
    AppLog.instance.trace(
      'lib/pages/player_panel.dart::_PlayerPanelState._pageOrder.get',
    );
    if (!_hasManuscript) return const [0, 2];
    return _paneCount == 2 && _secondaryPage == 2
        ? const [0, 2, 1]
        : const [0, 1, 2];
  }

  void _configurePanes(int count) {
    AppLog.instance.trace(
      'lib/pages/player_panel.dart::_PlayerPanelState._configurePanes',
    );
    final layout = (count, _hasManuscript);
    if (count == _paneCount && _hasManuscript == _configuredManuscript) {
      _pendingPaneLayout = null;
      return;
    }
    if (layout == _pendingPaneLayout) return;
    _pendingPaneLayout = layout;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      AppLog.instance.trace(
        'lib/pages/player_panel.dart::_PlayerPanelState._configurePanes.closure#1',
      );
      if (!mounted || _pendingPaneLayout != layout) return;
      _pendingPaneLayout = null;
      final oldPages = _pages;
      _changingPaneLayout = true;
      setState(() {
        AppLog.instance.trace(
          'lib/pages/player_panel.dart::_PlayerPanelState._configurePanes.closure#1.closure#1',
        );
        _paneCount = count;
        _configuredManuscript = _hasManuscript;
        _pages = PageController(
          keepPage: false,
          viewportFraction: 1 / count,
          initialPage: count == 1 ? _pageOrder.indexOf(_selectedPage) : 0,
        );
        if (count == 2) _visitedPages.add(_secondaryPage);
      });
      final installedPages = _pages;
      _retiredPages.add(oldPages);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        AppLog.instance.trace(
          'lib/pages/player_panel.dart::_PlayerPanelState._configurePanes.closure#1.closure#2',
        );
        if (mounted && identical(_pages, installedPages)) {
          if (installedPages.hasClients) {
            installedPages.jumpToPage(
              count == 1 ? _pageOrder.indexOf(_selectedPage) : 0,
            );
          }
          _changingPaneLayout = false;
        }
        if (_retiredPages.remove(oldPages)) oldPages.dispose();
      });
    });
  }

  void _pageSwiped(int index) {
    AppLog.instance.trace(
      'lib/pages/player_panel.dart::_PlayerPanelState._pageSwiped',
    );
    if (_paneCount != 1 || _changingPaneLayout) return;
    final order = _pageOrder;
    if (index >= order.length) return;
    setState(() {
      AppLog.instance.trace(
        'lib/pages/player_panel.dart::_PlayerPanelState._pageSwiped.closure#1',
      );
      _selectedPage = order[index];
      if (_selectedPage != 0) _secondaryPage = _selectedPage;
      _visitedPages.add(_selectedPage);
    });
  }

  Widget _manuscriptPage(Track? track) {
    AppLog.instance.trace(
      'lib/pages/player_panel.dart::_PlayerPanelState._manuscriptPage',
    );
    if (track == null) return const Center(child: Text('尚未选择声音'));
    if (_manuscriptLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_manuscriptError != null) {
      return Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_manuscriptError!, textAlign: TextAlign.center),
              PlaybackActionButton(
                onPressed: () {
                  AppLog.instance.trace(
                    'lib/pages/player_panel.dart::_PlayerPanelState._manuscriptPage.closure#1',
                  );
                  unawaited(_refreshManuscript(force: true));
                },
                icon: const Icon(Icons.refresh),
                label: '重试文稿',
              ),
            ],
          ),
        ),
      );
    }
    if (_manuscript == null) {
      return const Center(child: Text('此声音暂无文稿'));
    }
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 900),
        child: ManuscriptReader(
          key: ValueKey((
            _manuscriptClient,
            _manuscriptKey,
            _manuscriptTrackId,
          )),
          manuscript: _manuscript!,
          showTitle: false,
        ),
      ),
    );
  }

  void _favoriteContextChanged() {
    AppLog.instance.trace(
      "lib/pages/player_panel.dart::_PlayerPanelState._favoriteContextChanged",
    );

    if (!widget.expanded || !mounted) return;
    final client = _runtime.client;
    final changed =
        !identical(client, _favoriteClient) ||
        client.cacheIdentity != _favoriteKey ||
        _runtime.player.current?.id != _favoriteTrackId;
    final revised = _libraryRevision != _runtime.libraryRevision;
    _libraryRevision = _runtime.libraryRevision;
    if (changed || (revised && !_favoriteMutating)) {
      unawaited(_refreshFavorite());
    }
  }

  bool _favoriteCurrent(
    XmlyClient client,
    String key,
    String trackId,
    int request,
  ) {
    AppLog.instance.trace(
      "lib/pages/player_panel.dart::_PlayerPanelState._favoriteCurrent",
    );
    return mounted &&
        request == _favoriteRequest &&
        identical(client, _runtime.client) &&
        key == _runtime.client.cacheIdentity &&
        trackId == _runtime.player.current?.id;
  }

  void _likeContextChanged() {
    AppLog.instance.trace(
      "lib/pages/player_panel.dart::_PlayerPanelState._likeContextChanged",
    );
    if (!mounted) return;
    final client = _runtime.client;
    if (!identical(client, _likeClient) ||
        client.cacheIdentity != _likeKey ||
        _runtime.player.current?.id != _likeTrackId) {
      _refreshLikes();
    }
  }

  bool _likeContextCurrent(XmlyClient client, String key, String trackId) {
    AppLog.instance.trace(
      "lib/pages/player_panel.dart::_PlayerPanelState._likeContextCurrent",
    );
    return mounted &&
        identical(client, _runtime.client) &&
        key == _runtime.client.cacheIdentity &&
        trackId == _runtime.player.current?.id;
  }

  bool _likeCurrent(
    XmlyClient client,
    String key,
    String trackId,
    int request,
  ) {
    AppLog.instance.trace(
      "lib/pages/player_panel.dart::_PlayerPanelState._likeCurrent",
    );
    return request == _likeRequest && _likeContextCurrent(client, key, trackId);
  }

  bool _likeCountCurrent(
    XmlyClient client,
    String key,
    String trackId,
    int request,
  ) {
    AppLog.instance.trace(
      "lib/pages/player_panel.dart::_PlayerPanelState._likeCountCurrent",
    );
    return request == _likeCountRequest &&
        _likeContextCurrent(client, key, trackId);
  }

  void _refreshLikes() {
    AppLog.instance.trace(
      "lib/pages/player_panel.dart::_PlayerPanelState._refreshLikes",
    );
    final client = _runtime.client, key = _runtime.client.cacheIdentity;
    final track = _runtime.player.current;
    final sameContext =
        identical(client, _likeClient) &&
        key == _likeKey &&
        track?.id == _likeTrackId;
    if (sameContext && _likeBusy) return;
    _likeRequest++;
    _likeCountRequest++;
    _likeClient = client;
    _likeKey = key;
    _likeTrackId = track?.id;
    setState(() {
      AppLog.instance.trace(
        "lib/pages/player_panel.dart::_PlayerPanelState._refreshLikes.closure#1",
      );
      _likeCount = sameContext ? _likeCount ?? track?.likes : track?.likes;
      _likeBusy = false;
      _likeCountLoading = false;
      _likeError = null;
      _likeCountError = null;
    });
    if (widget.expanded && track != null) unawaited(_refreshLikeCount(track));
  }

  Future<void> _refreshLikeCount(Track track, {bool force = false}) async {
    AppLog.instance.trace(
      "lib/pages/player_panel.dart::_PlayerPanelState._refreshLikeCount",
    );
    final client = _runtime.client, key = _runtime.client.cacheIdentity;
    if (!_likeContextCurrent(client, key, track.id)) return;
    final request = ++_likeCountRequest;
    setState(() {
      AppLog.instance.trace(
        "lib/pages/player_panel.dart::_PlayerPanelState._refreshLikeCount.closure#1",
      );
      _likeCountLoading = true;
      _likeCountError = null;
    });
    Future<Track> fetch() async {
      AppLog.instance.trace(
        "lib/pages/player_panel.dart::_PlayerPanelState._refreshLikeCount.fetch",
      );
      // Search/catalogue entries can replace full metadata in the shared cache.
      final forced = force || _likeCount == null;
      final value = await client.track(track.id, force: forced);
      if (!forced &&
          value.likes == null &&
          _likeCountCurrent(client, key, track.id, request)) {
        return client.track(track.id, force: true);
      }
      return value;
    }

    try {
      final value = client.accountAvailable
          ? await _runtime.accounts.runWithAccount(client.identity, (admitted) {
              AppLog.instance.trace(
                "lib/pages/player_panel.dart::_PlayerPanelState._refreshLikeCount.closure#2",
              );
              if (!_likeCountCurrent(client, key, track.id, request) ||
                  !identical(admitted, client)) {
                throw const XmlyException('account_changed', '账号已变更，请重试');
              }
              return fetch();
            })
          : await fetch();
      if (_likeCountCurrent(client, key, track.id, request)) {
        setState(() {
          AppLog.instance.trace(
            "lib/pages/player_panel.dart::_PlayerPanelState._refreshLikeCount.closure#3",
          );
          _likeCount = value.likes ?? _likeCount;
        });
      }
    } catch (error, stack) {
      _recordPlayerPanelError(
        'Like count failed',
        error,
        stack,
        recoverable: true,
      );
      if (_likeCountCurrent(client, key, track.id, request)) {
        setState(() {
          AppLog.instance.trace(
            "lib/pages/player_panel.dart::_PlayerPanelState._refreshLikeCount.closure#4",
          );
          _likeCountError = error is XmlyException
              ? error.message
              : '喜欢数读取失败，请重试';
        });
      }
    } finally {
      if (_likeCountCurrent(client, key, track.id, request)) {
        setState(() {
          AppLog.instance.trace(
            "lib/pages/player_panel.dart::_PlayerPanelState._refreshLikeCount.closure#5",
          );
          _likeCountLoading = false;
        });
      }
    }
  }

  Future<void> _likeAction(Track track) {
    AppLog.instance.trace(
      "lib/pages/player_panel.dart::_PlayerPanelState._likeAction",
    );
    return AppLog.instance.runWithErrorScope(() async {
      AppLog.instance.trace(
        "lib/pages/player_panel.dart::_PlayerPanelState._likeAction.closure#1",
      );
      final client = _runtime.client, key = _runtime.client.cacheIdentity;
      if (_likeBusy || !_likeContextCurrent(client, key, track.id)) return;
      if (!client.accountAvailable) {
        setState(() {
          AppLog.instance.trace(
            "lib/pages/player_panel.dart::_PlayerPanelState._likeAction.closure#1.closure#1",
          );
          _likeError = '请先登录后点赞声音';
        });
        return;
      }
      final request = ++_likeRequest;
      _likeCountRequest++;
      var attempted = false;
      setState(() {
        AppLog.instance.trace(
          "lib/pages/player_panel.dart::_PlayerPanelState._likeAction.closure#1.closure#2",
        );
        _likeBusy = true;
        _likeCountLoading = false;
        _likeError = null;
      });
      try {
        await _runtime.accounts.runWithAccount(client.identity, (
          admitted,
        ) async {
          AppLog.instance.trace(
            "lib/pages/player_panel.dart::_PlayerPanelState._likeAction.closure#1.closure#3",
          );
          if (!_likeCurrent(client, key, track.id, request) ||
              !identical(admitted, client)) {
            throw const XmlyException('account_changed', '账号已变更，请重试');
          }
          attempted = true;
          await XmlyExperience(client).likeTrack(track);
        });
        if (_likeCurrent(client, key, track.id, request)) {
          ScaffoldMessenger.of(context)
              .showSnackBar(const SnackBar(content: Text('点赞成功')));
        }
      } catch (error, stack) {
        _recordPlayerPanelError('Like change failed', error, stack);
        if (_likeCurrent(client, key, track.id, request)) {
          setState(() {
            AppLog.instance.trace(
              "lib/pages/player_panel.dart::_PlayerPanelState._likeAction.closure#1.closure#4",
            );
            _likeError = error is XmlyException ? error.message : '点赞操作未完成，请重试';
          });
        }
      } finally {
        if (_likeCurrent(client, key, track.id, request)) {
          if (attempted) await _refreshLikeCount(track, force: true);
          if (_likeCurrent(client, key, track.id, request)) {
            setState(() {
              AppLog.instance.trace(
                "lib/pages/player_panel.dart::_PlayerPanelState._likeAction.closure#1.closure#5",
              );
              _likeBusy = false;
            });
          }
        }
      }
    });
  }

  Widget _likeControl(Track? track) {
    AppLog.instance.trace(
      "lib/pages/player_panel.dart::_PlayerPanelState._likeControl",
    );
    final current =
        track != null &&
        identical(_likeClient, _runtime.client) &&
        _likeKey == _runtime.client.cacheIdentity &&
        _likeTrackId == track.id;
    final count = current ? _likeCount : null;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        PlaybackActionButton(
          tooltip:
              '${_likeBusy
                  ? '正在点赞'
                  : _runtime.client.accountAvailable
                  ? '点赞'
                  : '点赞（需登录）'} · 喜欢数：${count ?? '未知'}',
          onPressed: track == null || !current || _likeBusy
              ? null
              : () {
                  AppLog.instance.trace(
                    "lib/pages/player_panel.dart::_PlayerPanelState._likeControl.closure#1",
                  );
                  unawaited(_likeAction(track));
                },
          icon: const Icon(
            Icons.thumb_up_outlined,
            size: 20,
            semanticLabel: '点赞',
          ),
          label: count?.toString() ?? '—',
        ),
        if (current && _likeError != null)
          SizedBox(
            width: 160,
            child: Text(
              _likeError!,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        if (current && _likeCountError != null)
          PlaybackActionButton(
            tooltip: _likeCountError!,
            onPressed: _likeBusy || _likeCountLoading
                ? null
                : () {
                    AppLog.instance.trace(
                      "lib/pages/player_panel.dart::_PlayerPanelState._likeControl.closure#2",
                    );
                    unawaited(_refreshLikeCount(track, force: true));
                  },
            icon: const Icon(Icons.refresh_rounded, size: 16),
            label: '重试喜欢数',
          ),
      ],
    );
  }

  Future<void> _refreshFavorite() {
    AppLog.instance.trace(
      "lib/pages/player_panel.dart::_PlayerPanelState._refreshFavorite",
    );
    return AppLog.instance.runWithErrorScope(() async {
      AppLog.instance.trace(
        "lib/pages/player_panel.dart::_PlayerPanelState._refreshFavorite.closure#1",
      );

      final client = _runtime.client, key = _runtime.client.cacheIdentity;
      final track = _runtime.player.current;
      final request = ++_favoriteRequest;
      _favoriteClient = client;
      _favoriteKey = key;
      _favoriteTrackId = track?.id;
      _libraryRevision = _runtime.libraryRevision;
      setState(() {
        AppLog.instance.trace(
          "lib/pages/player_panel.dart::_PlayerPanelState._refreshFavorite.closure#1.closure#1",
        );

        _favorite = null;
        _favoriteError = null;
        _favoriteBusy = track != null && client.accountAvailable;
        _favoriteMutating = false;
      });
      if (track == null || !client.accountAvailable) return;
      try {
        final favorite = await XmlyExperience(client).isFavorite(track.id);
        if (_favoriteCurrent(client, key, track.id, request)) {
          setState(() {
            AppLog.instance.trace(
              "lib/pages/player_panel.dart::_PlayerPanelState._refreshFavorite.closure#1.closure#2",
            );
            _favorite = favorite;
          });
        }
      } catch (error, stack) {
        _recordPlayerPanelError('Favorite status failed', error, stack);
        if (_favoriteCurrent(client, key, track.id, request)) {
          setState(() {
            AppLog.instance.trace(
              "lib/pages/player_panel.dart::_PlayerPanelState._refreshFavorite.closure#1.closure#3",
            );
            _favoriteError = error is XmlyException
                ? error.message
                : '收藏状态读取失败，请重试';
          });
        }
      } finally {
        if (_favoriteCurrent(client, key, track.id, request)) {
          setState(() {
            AppLog.instance.trace(
              "lib/pages/player_panel.dart::_PlayerPanelState._refreshFavorite.closure#1.closure#4",
            );
            _favoriteBusy = false;
          });
        }
      }
    });
  }

  Future<void> _favoriteAction(Track track) {
    AppLog.instance.trace(
      "lib/pages/player_panel.dart::_PlayerPanelState._favoriteAction",
    );
    return AppLog.instance.runWithErrorScope(() async {
      AppLog.instance.trace(
        "lib/pages/player_panel.dart::_PlayerPanelState._favoriteAction.closure#1",
      );

      if (_favoriteBusy || track.id != _runtime.player.current?.id) return;
      final client = _runtime.client, key = _runtime.client.cacheIdentity;
      if (!client.accountAvailable) {
        setState(() {
          AppLog.instance.trace(
            "lib/pages/player_panel.dart::_PlayerPanelState._favoriteAction.closure#1.closure#1",
          );
          _favoriteError = '请先登录后收藏声音';
        });
        return;
      }
      final favorite = _favorite;
      if (favorite == null) return _refreshFavorite();
      final request = ++_favoriteRequest, desired = !favorite;
      var attempted = false;
      setState(() {
        AppLog.instance.trace(
          "lib/pages/player_panel.dart::_PlayerPanelState._favoriteAction.closure#1.closure#2",
        );

        _favoriteBusy = true;
        _favoriteMutating = true;
        _favoriteError = null;
      });
      try {
        if (favorite &&
            !await showConfirmationDialog(context, const Text('取消收藏此声音？'))) {
          return;
        }
        if (!_favoriteCurrent(client, key, track.id, request)) return;
        await _runtime.accounts.runWithAccount(client.identity, (
          admitted,
        ) async {
          AppLog.instance.trace(
            "lib/pages/player_panel.dart::_PlayerPanelState._favoriteAction.closure#1.closure#3",
          );

          if (!_favoriteCurrent(client, key, track.id, request) ||
              !identical(admitted, client)) {
            throw const XmlyException('account_changed', '账号已变更，请重试');
          }
          attempted = true;
          await XmlyExperience(client).setFavorite(track, favorite: desired);
        });
        _runtime.libraryChanged();
        if (_favoriteCurrent(client, key, track.id, request)) {
          setState(() {
            AppLog.instance.trace(
              "lib/pages/player_panel.dart::_PlayerPanelState._favoriteAction.closure#1.closure#4",
            );
            _favorite = desired;
          });
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(desired ? '已收藏声音' : '已取消收藏')));
        }
      } catch (error, stack) {
        _recordPlayerPanelError('Favorite change failed', error, stack);
        if (attempted) _runtime.libraryChanged();
        if (!_favoriteCurrent(client, key, track.id, request)) return;
        setState(() {
          AppLog.instance.trace(
            "lib/pages/player_panel.dart::_PlayerPanelState._favoriteAction.closure#1.closure#5",
          );

          _favorite = null;
          _favoriteError = error is XmlyException
              ? error.message
              : '收藏操作未完成，请重试';
        });
        if (attempted) {
          try {
            final value = await XmlyExperience(client).isFavorite(track.id);
            if (_favoriteCurrent(client, key, track.id, request)) {
              setState(() {
                AppLog.instance.trace(
                  "lib/pages/player_panel.dart::_PlayerPanelState._favoriteAction.closure#1.closure#6",
                );
                _favorite = value;
              });
            }
          } catch (error, stack) {
            _recordPlayerPanelError(
              'Favorite reconciliation failed',
              error,
              stack,
              recoverable: true,
            );
            // Do not infer an outcome or replay an uncertain mutation.
          }
        }
      } finally {
        if (_favoriteCurrent(client, key, track.id, request)) {
          setState(() {
            AppLog.instance.trace(
              "lib/pages/player_panel.dart::_PlayerPanelState._favoriteAction.closure#1.closure#7",
            );

            _favoriteBusy = false;
            _favoriteMutating = false;
          });
        }
      }
    });
  }

  String get _favoriteLabel {
    AppLog.instance.trace(
      "lib/pages/player_panel.dart::_PlayerPanelState._favoriteLabel.get",
    );
    return _favoriteBusy
        ? '正在读取收藏状态'
        : !_runtime.client.accountAvailable
        ? '收藏（需登录）'
        : _favorite == null
        ? '重试收藏状态'
        : _favorite!
        ? '取消收藏'
        : '收藏';
  }

  Widget _favoriteControl(Track? track) {
    AppLog.instance.trace(
      "lib/pages/player_panel.dart::_PlayerPanelState._favoriteControl",
    );
    if (_favoriteError == null) {
      return PlaybackActionButton(
        tooltip: _favoriteLabel,
        onPressed: track == null || _favoriteBusy
            ? null
            : () {
                AppLog.instance.trace(
                  "lib/pages/player_panel.dart::_PlayerPanelState._favoriteControl.closure#1",
                );
                _favoriteAction(track);
              },
        icon: Icon(
          _favorite == true
              ? Icons.favorite_rounded
              : Icons.favorite_border_rounded,
          size: 20,
        ),
        label: _favorite == true ? '已收藏' : '收藏',
      );
    }
    final colors = Theme.of(context).colorScheme;
    return MenuAnchor(
      consumeOutsideTap: true,
      menuChildren: [
        SizedBox(
          width: math.min(300, MediaQuery.sizeOf(context).width - 32),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('收藏状态暂不可用', style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 8),
                Text(
                  _favoriteError!,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ),
        MenuItemButton(
          onPressed: _favoriteBusy ? null : _refreshFavorite,
          leadingIcon: const Icon(Icons.refresh_rounded),
          child: const Text('重试收藏状态'),
        ),
      ],
      builder: (context, controller, _) {
        AppLog.instance.trace(
          "lib/pages/player_panel.dart::_PlayerPanelState._favoriteControl.closure#2",
        );
        return PlaybackActionButton(
          tooltip: '收藏状态暂不可用，点击查看',
          key: const ValueKey('favoriteStatusUnavailable'),
          onPressed: () {
            AppLog.instance.trace(
              "lib/pages/player_panel.dart::_PlayerPanelState._favoriteControl.closure#2.closure#1",
            );

            controller.isOpen ? controller.close() : controller.open();
          },
          icon: Badge(
            smallSize: 6,
            backgroundColor: colors.outline,
            child: const Icon(Icons.favorite_border_rounded, size: 20),
          ),
          label: '收藏',
        );
      },
    );
  }

  Future<void> _act(Future<void> Function() command) {
    AppLog.instance.trace(
      "lib/pages/player_panel.dart::_PlayerPanelState._act",
    );
    return AppLog.instance.runWithErrorScope(() async {
      AppLog.instance.trace(
        "lib/pages/player_panel.dart::_PlayerPanelState._act.closure#1",
      );

      if (_busy || _cancelling) return;
      setState(() {
        AppLog.instance.trace(
          "lib/pages/player_panel.dart::_PlayerPanelState._act.closure#1.closure#1",
        );

        _busy = true;
        _error = null;
      });
      try {
        await command();
      } on XmlyException catch (error, stack) {
        _recordPlayerPanelError('Player command failed', error, stack);
        if (mounted)
          setState(() {
            AppLog.instance.trace(
              "lib/pages/player_panel.dart::_PlayerPanelState._act.closure#1.closure#2",
            );
            _error = error.message;
          });
      } catch (error, stack) {
        _recordPlayerPanelError('Player command failed', error, stack);
        if (mounted)
          setState(() {
            AppLog.instance.trace(
              "lib/pages/player_panel.dart::_PlayerPanelState._act.closure#1.closure#3",
            );
            _error = '操作未完成，请重试';
          });
      } finally {
        if (mounted)
          setState(() {
            AppLog.instance.trace(
              "lib/pages/player_panel.dart::_PlayerPanelState._act.closure#1.closure#4",
            );
            _busy = false;
          });
      }
    });
  }

  Future<void> _playPause() {
    AppLog.instance.trace(
      "lib/pages/player_panel.dart::_PlayerPanelState._playPause",
    );
    return AppLog.instance.runWithErrorScope(() async {
      AppLog.instance.trace(
        "lib/pages/player_panel.dart::_PlayerPanelState._playPause.closure#1",
      );

      final player = _runtime.player;
      if (player.current == null || _cancelling) return;
      if (!player.loading && !(_busy && player.playing)) {
        return _act(player.playing ? player.pause : player.resume);
      }
      // Only cancellation may pass a command awaiting catalogue or audio.
      // Keep its busy gate intact until that original command has settled.
      setState(() {
        AppLog.instance.trace(
          "lib/pages/player_panel.dart::_PlayerPanelState._playPause.closure#1.closure#1",
        );

        _cancelling = true;
        _error = null;
      });
      try {
        await player.pause();
      } on XmlyException catch (error, stack) {
        _recordPlayerPanelError('Player pause failed', error, stack);
        if (mounted)
          setState(() {
            AppLog.instance.trace(
              "lib/pages/player_panel.dart::_PlayerPanelState._playPause.closure#1.closure#2",
            );
            _error = error.message;
          });
      } catch (error, stack) {
        _recordPlayerPanelError('Player pause failed', error, stack);
        if (mounted)
          setState(() {
            AppLog.instance.trace(
              "lib/pages/player_panel.dart::_PlayerPanelState._playPause.closure#1.closure#3",
            );
            _error = '操作未完成，请重试';
          });
      } finally {
        if (mounted)
          setState(() {
            AppLog.instance.trace(
              "lib/pages/player_panel.dart::_PlayerPanelState._playPause.closure#1.closure#4",
            );
            _cancelling = false;
          });
      }
    });
  }

  void _expand() {
    AppLog.instance.trace(
      "lib/pages/player_panel.dart::_PlayerPanelState._expand",
    );
    _navigator.push(
      MaterialPageRoute<void>(
        settings: const RouteSettings(name: PlayerPanel.routeName),
        builder: (_) {
          AppLog.instance.trace(
            "lib/pages/player_panel.dart::_PlayerPanelState._expand.closure#1",
          );
          return PlayerPanel(runtime: _runtime, expanded: true);
        },
      ),
    );
  }

  void _settings() {
    AppLog.instance.trace(
      "lib/pages/player_panel.dart::_PlayerPanelState._settings",
    );

    final track = _runtime.player.current;
    showQuickPlaybackSettings(
      _navigator.context,
      _runtime,
      albumId: track?.albumId.isNotEmpty == true ? track!.albumId : null,
      albumTitle: track?.album,
    );
  }

  void _openAlbum(String albumId) {
    AppLog.instance.trace(
      "lib/pages/player_panel.dart::_PlayerPanelState._openAlbum",
    );

    if (albumId.isEmpty) return;
    showLocalPanel<void>(
      context: _navigator.context,
      title: '专辑详情',
      width: 660,
      height: 760,
      showHeader: false,
      builder: (_) {
        AppLog.instance.trace(
          "lib/pages/player_panel.dart::_PlayerPanelState._openAlbum.closure#1",
        );
        return AlbumPageView(
          runtime: _runtime,
          albumId: albumId,
          inPanel: true,
        );
      },
    );
  }

  void _queue() {
    AppLog.instance.trace(
      "lib/pages/player_panel.dart::_PlayerPanelState._queue",
    );
    showLocalPanel<void>(
      context: _navigator.context,
      title: '播放列表',
      width: 560,
      height: 760,
      builder: (_) {
        AppLog.instance.trace(
          'lib/pages/player_panel.dart::_PlayerPanelState._queue.closure#1',
        );
        return PlayerQueuePanel(
          key: ValueKey(_runtime.player),
          runtime: _runtime,
        );
      },
    );
  }

  Widget _cover(String? url, double size, {bool small = false}) {
    AppLog.instance.trace(
      "lib/pages/player_panel.dart::_PlayerPanelState._cover",
    );

    final colors = Theme.of(context).colorScheme;
    final fallback = ColoredBox(
      color: colors.surfaceContainerHighest,
      child: Center(
        child: Icon(
          Icons.headphones_rounded,
          size: size * 0.34,
          color: colors.primary,
        ),
      ),
    );
    return ExcludeSemantics(
      child: ClipRRect(
        borderRadius: BorderRadius.circular(small ? 10 : 24),
        child: SizedBox.square(
          dimension: size,
          child: url == null || url.isEmpty
              ? fallback
              : Image(
                  image: LoggedNetworkImage(url),
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) {
                    AppLog.instance.trace(
                      "lib/pages/player_panel.dart::_PlayerPanelState._cover.closure#1",
                    );
                    return fallback;
                  },
                ),
        ),
      ),
    );
  }

  Widget _button(
    String label,
    IconData icon,
    Future<void> Function()? command, {
    double size = 56,
    double iconSize = 24,
    String? tooltip,
  }) {
    AppLog.instance.trace(
      "lib/pages/player_panel.dart::_PlayerPanelState._button",
    );
    return PlaybackActionButton(
      label: label,
      showLabel: false,
      tooltip: tooltip,
      size: size,
      onPressed: _busy || _cancelling || command == null
          ? null
          : () {
              AppLog.instance.trace(
                "lib/pages/player_panel.dart::_PlayerPanelState._button.closure#1",
              );
              _act(command);
            },
      icon: Icon(icon, size: iconSize),
    );
  }

  @override
  Widget build(BuildContext context) {
    AppLog.instance.trace(
      "lib/pages/player_panel.dart::_PlayerPanelState.build",
    );
    return ListenableBuilder(
      listenable: _runtime,
      builder: (context, _) {
        AppLog.instance.trace(
          "lib/pages/player_panel.dart::_PlayerPanelState.build.closure#1",
        );

        final player = _runtime.player;
        final track = player.current;
        final theme = Theme.of(context);
        final colors = theme.colorScheme;
        final title = track == null
            ? '尚未选择声音'
            : track.title.isEmpty
            ? track.id
            : track.title;
        final max = player.duration.isFinite && player.duration > 0
            ? player.duration
            : 0.0;
        final epoch = player.playbackEpoch;
        final position =
            ((_dragEpoch == epoch ? _dragPosition : null) ?? player.position)
                .clamp(0.0, max)
                .toDouble();
        final settings = player.effectiveSettings;
        final message = _error ?? player.error ?? player.warning;
        final canPause = player.playing || player.loading;
        final playLabel = player.loading
            ? '取消加载'
            : canPause
            ? '暂停'
            : '播放';
        final VoidCallback? play =
            track == null || _cancelling || (_busy && !canPause)
            ? null
            : () {
                AppLog.instance.trace(
                  "lib/pages/player_panel.dart::_PlayerPanelState.build.closure#1.closure#1",
                );
                unawaited(_playPause());
              };
        final coverUrl = track?.coverUrl?.toString();
        final compact = MediaQuery.sizeOf(context).width < 400;
        final widePlayer = MediaQuery.sizeOf(context).width >= 920;
        Widget playControl({required Key key, double size = 48}) {
          AppLog.instance.trace(
            'lib/pages/player_panel.dart::_PlayerPanelState.build.closure#1.playControl',
          );
          return PlaybackActionButton(
            key: key,
            showLabel: false,
            size: size,
            emphasized: true,
            label: playLabel,
            tooltip: _keyHint(playLabel, '空格'),
            onPressed: play,
            icon: SizedBox.square(
              dimension: 26,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  if (player.loading ||
                      player.buffering ||
                      _busy ||
                      _cancelling)
                    CircularProgressIndicator(
                      strokeWidth: 2,
                      color: colors.onPrimaryContainer,
                    ),
                  Icon(
                    canPause ? Icons.pause_rounded : Icons.play_arrow_rounded,
                    size: 24,
                  ),
                ],
              ),
            ),
          );
        }

        Widget seekSlider({bool dock = false}) {
          AppLog.instance.trace(
            "lib/pages/player_panel.dart::_PlayerPanelState.build.closure#1.seekSlider",
          );
          return SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 3,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 18),
              inactiveTrackColor: colors.onSurface.withValues(alpha: 0.12),
            ),
            child: KeyedSubtree(
              key: ValueKey((player, epoch, dock)),
              child: Slider(
                key: dock ? const ValueKey('dockSeekSlider') : null,
                padding: EdgeInsets.symmetric(
                  vertical: dock ? 12 : 22,
                  horizontal: 5,
                ),
                value: position,
                max: max > 0 ? max : 1,
                label: playbackTime(position),
                semanticFormatterCallback: playbackTime,
                onChangeStart: track == null || max == 0 || _busy
                    ? null
                    : (_) {
                        AppLog.instance.trace(
                          "lib/pages/player_panel.dart::_PlayerPanelState.build.closure#1.seekSlider.closure#1",
                        );
                        _dragEpoch = epoch;
                      },
                onChanged: track == null || max == 0 || _busy
                    ? null
                    : (value) {
                        AppLog.instance.trace(
                          "lib/pages/player_panel.dart::_PlayerPanelState.build.closure#1.seekSlider.closure#2",
                        );

                        if (_dragEpoch == epoch &&
                            player.playbackEpoch == epoch) {
                          setState(() {
                            AppLog.instance.trace(
                              "lib/pages/player_panel.dart::_PlayerPanelState.build.closure#1.seekSlider.closure#2.closure#1",
                            );
                            _dragPosition = value;
                          });
                        }
                      },
                onChangeEnd: track == null || max == 0 || _busy
                    ? null
                    : (value) async {
                        AppLog.instance.trace(
                          "lib/pages/player_panel.dart::_PlayerPanelState.build.closure#1.seekSlider.closure#3",
                        );

                        final selectedEpoch = _dragEpoch;
                        setState(() {
                          AppLog.instance.trace(
                            "lib/pages/player_panel.dart::_PlayerPanelState.build.closure#1.seekSlider.closure#3.closure#1",
                          );

                          _dragPosition = null;
                          _dragEpoch = null;
                        });
                        if (selectedEpoch != epoch ||
                            player.playbackEpoch != epoch) {
                          return;
                        }
                        await _act(() {
                          AppLog.instance.trace(
                            "lib/pages/player_panel.dart::_PlayerPanelState.build.closure#1.seekSlider.closure#3.closure#2",
                          );
                          return player.seek(value, expectedEpoch: epoch);
                        });
                      },
              ),
            ),
          );
        }

        if (!widget.expanded) {
          if (!widget.miniWindow) {
            final timeStyle = theme.textTheme.bodySmall?.copyWith(
              color: colors.onSurfaceVariant,
              fontFeatures: const [FontFeature.tabularFigures()],
            );
            return Material(
              color: colors.surfaceContainerLow,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  AppLog.instance.trace(
                    "lib/pages/player_panel.dart::_PlayerPanelState.build.closure#1.closure#2",
                  );

                  final fontSize = theme.textTheme.bodyMedium?.fontSize ?? 14;
                  final textScale = math.max(
                    1.0,
                    MediaQuery.textScalerOf(context).scale(fontSize) / fontSize,
                  );
                  final availableWidth = constraints.maxWidth / textScale;
                  final showProgress = availableWidth >= 600;
                  return Padding(
                    key: ValueKey(
                      showProgress ? 'playbackDockWide' : 'playbackDockNarrow',
                    ),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 4,
                    ),
                    child: Row(
                      children: [
                        if (showProgress)
                          _button(
                            '上一集',
                            Icons.skip_previous_rounded,
                            track == null ? null : player.previous,
                            size: 48,
                          ),
                        if (showProgress)
                          playControl(key: const ValueKey('dockPlayPause'))
                        else
                          Semantics(
                            value:
                                '${playbackTime(position)} / ${playbackTime(max)}',
                            child: Stack(
                              children: [
                                playControl(
                                  key: const ValueKey('dockPlayPause'),
                                ),
                                Positioned.fill(
                                  child: IgnorePointer(
                                    child: ExcludeSemantics(
                                      child: CircularProgressIndicator(
                                        value: max > 0 ? position / max : 0,
                                        strokeWidth: 2,
                                        strokeCap: StrokeCap.round,
                                        backgroundColor: colors.onSurface
                                            .withValues(alpha: 0.12),
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        if (showProgress)
                          _button(
                            '下一集',
                            Icons.skip_next_rounded,
                            track == null ? null : player.next,
                            size: 48,
                          ),
                        const SizedBox(width: 8),
                        if (showProgress) ...[
                          _PlayerExpandTarget(
                            onTap: widget.onExpand ?? _expand,
                            child: _cover(coverUrl, 40, small: true),
                          ),
                          const SizedBox(width: 8),
                        ],
                        Expanded(
                          flex: showProgress ? 2 : 1,
                          child: _PlayerExpandTarget(
                            onTap: widget.onExpand ?? _expand,
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.bodyMedium,
                                ),
                                if (showProgress)
                                  Text(
                                    message ?? track?.artist ?? '',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.bodySmall?.copyWith(
                                      color: message == null
                                          ? colors.onSurfaceVariant
                                          : colors.error,
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                        if (showProgress) ...[
                          const SizedBox(width: 16),
                          Expanded(
                            flex: 3,
                            child: Row(
                              children: [
                                Expanded(child: seekSlider(dock: true)),
                                const SizedBox(width: 8),
                                Text(
                                  '${playbackTime(position)} / ${playbackTime(max)}',
                                  key: const ValueKey('dockPlaybackTime'),
                                  style: timeStyle,
                                ),
                              ],
                            ),
                          ),
                        ],
                        if (availableWidth >= 760)
                          PlaybackSpeedControl(
                            runtime: _runtime,
                            size: 48,
                            albumId: track?.albumId.isNotEmpty == true
                                ? track!.albumId
                                : null,
                          ),
                        if (availableWidth >= 960)
                          PlaybackVolumeControl(
                            runtime: _runtime,
                            vertical: true,
                            size: 48,
                          ),
                        if (showProgress)
                          PlaybackActionButton(
                            size: 48,
                            tooltip: '播放列表',
                            label: '列表',
                            onPressed: _queue,
                            icon: const Icon(Icons.queue_music_rounded),
                          ),
                      ],
                    ),
                  );
                },
              ),
            );
          }
          return Material(
            color: colors.surfaceContainer,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: _PlayerExpandTarget(
                        onTap: widget.onExpand ?? _expand,
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(10, 4, 4, 4),
                          child: Row(
                            children: [
                              if (!compact) ...[
                                _cover(coverUrl, 40, small: true),
                                const SizedBox(width: 12),
                              ],
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    AdaptiveText(
                                      title,
                                      style: theme.textTheme.bodyMedium,
                                    ),
                                    AdaptiveText(
                                      message ??
                                          (track?.album.isNotEmpty == true
                                              ? track!.album
                                              : '打开播放器'),
                                      style: theme.textTheme.bodySmall
                                          ?.copyWith(
                                            color: message == null
                                                ? colors.onSurfaceVariant
                                                : colors.error,
                                          ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    playControl(key: const ValueKey('miniPlayPause')),
                    _button(
                      '下一集',
                      Icons.skip_next_rounded,
                      track == null ? null : player.next,
                      size: 48,
                    ),
                    const SizedBox(width: 4),
                  ],
                ),
                LinearProgressIndicator(
                  minHeight: 2,
                  value:
                      player.loading || player.buffering || _busy || _cancelling
                      ? null
                      : max > 0
                      ? position / max
                      : 0,
                  backgroundColor: colors.surfaceContainerHighest,
                ),
              ],
            ),
          );
        }

        final sleep = player.policy.sleepRequest;
        final remaining = player.policy.remainingDuration;
        final sleepLabel = sleep == null
            ? '定时关闭'
            : player.policy.sleepWaitingForEnd || remaining == null
            ? '本集结束后${sleep.action.name == 'exit' ? '退出' : '暂停'}'
            : playbackTime(remaining.inSeconds.toDouble());
        final metadata = Column(
          crossAxisAlignment: widePlayer
              ? CrossAxisAlignment.center
              : CrossAxisAlignment.start,
          children: [
            Text(
              title,
              textAlign: widePlayer ? TextAlign.center : TextAlign.start,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleLarge?.copyWith(
                fontSize: compact ? 18 : 24,
                height: 1.45,
                fontWeight: FontWeight.w700,
              ),
            ),
            if (track != null &&
                (track.albumId.isNotEmpty ||
                    track.album.isNotEmpty ||
                    track.artist.isNotEmpty)) ...[
              SizedBox(height: compact ? 4 : 10),
              if (track.albumId.isNotEmpty)
                TextButton(
                  key: const ValueKey('playerAlbumLink'),
                  onPressed: () {
                    AppLog.instance.trace(
                      "lib/pages/player_panel.dart::_PlayerPanelState.build.closure#1.closure#3",
                    );
                    _openAlbum(track.albumId);
                  },
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    alignment: widePlayer
                        ? Alignment.center
                        : Alignment.centerLeft,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Flexible(
                        child: AdaptiveText(
                          track.album.isEmpty ? '查看专辑' : track.album,
                          style: theme.textTheme.bodySmall,
                        ),
                      ),
                      const Icon(Icons.chevron_right, size: 18),
                    ],
                  ),
                )
              else if (track.album.isNotEmpty)
                AdaptiveText(
                  track.album,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
              if (track.artist.isNotEmpty)
                AdaptiveText(
                  track.artist,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
            ],
          ],
        );
        final quickControls = Wrap(
          alignment: WrapAlignment.center,
          spacing: 4,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            PlaybackSpeedControl(
              key: ValueKey((_runtime, track?.id)),
              runtime: _runtime,
              albumId: track?.albumId.isNotEmpty == true
                  ? track!.albumId
                  : null,
            ),
            PlaybackVolumeControl(runtime: _runtime, vertical: true),
            PlaybackActionButton(
              onPressed: () {
                AppLog.instance.trace(
                  "lib/pages/player_panel.dart::_PlayerPanelState.build.closure#1.closure#4",
                );
                showSleepTimerDialog(context, _runtime);
              },
              icon: Icon(
                sleep == null ? Icons.timer_outlined : Icons.timer,
                size: 20,
              ),
              label: '定时关闭',
              tooltip: sleepLabel,
            ),
          ],
        );
        final contentActions = Wrap(
          alignment: WrapAlignment.center,
          spacing: 4,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            _likeControl(track),
            _favoriteControl(track),
            PlaybackActionButton(
              onPressed: track == null || _busy || _cancelling
                  ? null
                  : () {
                      AppLog.instance.trace(
                        "lib/pages/player_panel.dart::_PlayerPanelState.build.closure#1.closure#5",
                      );
                      _act(() async {
                        AppLog.instance.trace(
                          "lib/pages/player_panel.dart::_PlayerPanelState.build.closure#1.closure#5.closure#1",
                        );

                        final savedPosition = player.position;
                        await player.bookmark();
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(
                                '已添加书签 · ${playbackTime(savedPosition)}',
                              ),
                            ),
                          );
                        }
                      });
                    },
              icon: const Icon(Icons.bookmark_add_outlined, size: 20),
              label: '书签',
            ),
            PlaybackActionButton(
              onPressed: _queue,
              icon: const Icon(Icons.queue_music_rounded, size: 20),
              label: '播放列表',
            ),
          ],
        );
        final progress = Column(
          children: [
            Row(
              children: [
                _button(
                  '快退',
                  Icons.replay_rounded,
                  track == null ? null : player.seekBackward,
                  tooltip: _keyHint(
                    '后退 ${settings.seekBackwardSeconds} 秒',
                    '←',
                  ),
                ),
                Expanded(child: seekSlider()),
                _button(
                  '快进',
                  Icons.forward_rounded,
                  track == null ? null : player.seekForward,
                  tooltip: _keyHint('前进 ${settings.seekForwardSeconds} 秒', '→'),
                ),
              ],
            ),
            DefaultTextStyle(
              style: (theme.textTheme.bodySmall ?? const TextStyle()).copyWith(
                color: colors.onSurfaceVariant,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(playbackTime(position)),
                  Text(playbackTime(max)),
                ],
              ),
            ),
          ],
        );
        final controls = Padding(
          padding: EdgeInsets.symmetric(
            vertical: compact
                ? 8
                : widePlayer
                ? 12
                : 20,
          ),
          child: Wrap(
            alignment: WrapAlignment.center,
            spacing: 4,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _button(
                '上一集',
                Icons.skip_previous_rounded,
                track == null ? null : player.previous,
                iconSize: 30,
              ),
              playControl(key: const ValueKey('playerPlayPause'), size: 64),
              _button(
                '下一集',
                Icons.skip_next_rounded,
                track == null ? null : player.next,
                iconSize: 30,
              ),
            ],
          ),
        );
        final footer = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (sleep != null)
              Center(
                child: PlaybackActionButton(
                  onPressed: () {
                    AppLog.instance.trace(
                      "lib/pages/player_panel.dart::_PlayerPanelState.build.closure#1.closure#6",
                    );

                    player.cancelSleep();
                    _runtime.changed();
                  },
                  icon: const Icon(Icons.timer_off_outlined, size: 20),
                  label: '取消定时',
                ),
              ),
            if (message != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  message,
                  key: const ValueKey('playerMessage'),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colors.error,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
          ],
        );
        final page = Scaffold(
          appBar: AppHeader(
            leading: IconButton(
              tooltip: '收起播放器',
              onPressed: () {
                AppLog.instance.trace(
                  "lib/pages/player_panel.dart::_PlayerPanelState.build.closure#1.closure#7",
                );
                Navigator.of(context).maybePop();
              },
              icon: const Icon(Icons.keyboard_arrow_down_rounded),
            ),
            title: const Text('正在收听'),
            centerTitle: true,
            actions: [
              IconButton(
                tooltip: '播放设置',
                onPressed: _settings,
                icon: const Icon(Icons.settings_outlined),
              ),
            ],
          ),
          body: SafeArea(
            top: false,
            child: Column(
              children: [
                AppTabStrip(
                  key: const ValueKey('playerContentTabs'),
                  children: [
                    for (final (index, label) in [
                      if (_paneCount == 1) (0, '播放'),
                      if (_hasManuscript) (1, '文稿'),
                      (2, '评论'),
                    ])
                      AppTabButton(
                        key: ValueKey(index),
                        label: label,
                        selected:
                            (_paneCount == 2
                                ? _secondaryPage
                                : _selectedPage) ==
                            index,
                        onPressed: () {
                          AppLog.instance.trace(
                            "lib/pages/player_panel.dart::_PlayerPanelState.build.closure#1.closure#8",
                          );
                          _selectPage(index);
                        },
                      ),
                  ],
                ),
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      AppLog.instance.trace(
                        "lib/pages/player_panel.dart::_PlayerPanelState.build.closure#1.closure#9",
                      );
                      final minPaneWidth = math.max(
                        460.0,
                        MediaQuery.textScalerOf(context).scale(340),
                      );
                      _configurePanes(
                        (constraints.maxWidth / minPaneWidth).floor().clamp(
                          1,
                          2,
                        ),
                      );
                      final order = _pageOrder;
                      final contents = <Widget>[
                        LayoutBuilder(
                          builder: (context, constraints) {
                            AppLog.instance.trace(
                              "lib/pages/player_panel.dart::_PlayerPanelState.build.closure#1.closure#9.closure#1",
                            );
                            final textHeight = MediaQuery.textScalerOf(context)
                                .scale(56);
                            final coverSize = math.min(
                              widePlayer ? 260.0 : 280.0,
                              math.min(
                                constraints.maxWidth - 64,
                                math.max(
                                  120.0,
                                  constraints.maxHeight -
                                      480 -
                                      textHeight -
                                      (sleep == null ? 0 : 48),
                                ),
                              ),
                            );
                            return SingleChildScrollView(
                              key: const PageStorageKey('playerPlayback'),
                              primary: false,
                              child: Center(
                                child: ConstrainedBox(
                                  constraints: BoxConstraints(
                                    maxWidth: widePlayer ? 560 : 680,
                                    minHeight: constraints.maxHeight,
                                  ),
                                  child: Padding(
                                    padding: EdgeInsets.all(compact ? 8 : 16),
                                    child: Column(
                                      mainAxisAlignment:
                                          MainAxisAlignment.spaceEvenly,
                                      children: [
                                        metadata,
                                        const SizedBox(height: 8),
                                        if (!compact) ...[
                                          _cover(coverUrl, coverSize),
                                          const SizedBox(height: 8),
                                        ],
                                        controls,
                                        progress,
                                        contentActions,
                                        quickControls,
                                        footer,
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                        !_visitedPages.contains(1)
                            ? const Center(child: CircularProgressIndicator())
                            : _manuscriptPage(track),
                        !_visitedPages.contains(2)
                            ? const Center(child: CircularProgressIndicator())
                            : track == null
                            ? const Center(child: Text('尚未选择声音'))
                            : TrackCommentsPanel(
                                key: ValueKey((_runtime, track.id)),
                                runtime: _runtime,
                                track: track,
                              ),
                      ];
                      return PrimaryScrollController.none(
                        child: ScrollConfiguration(
                          behavior: ScrollConfiguration.of(context).copyWith(
                            dragDevices: {
                              ...ScrollConfiguration.of(context).dragDevices,
                              PointerDeviceKind.mouse,
                            },
                          ),
                          child: PageView.builder(
                            controller: _pages,
                            padEnds: false,
                            physics: _paneCount == 1
                                ? null
                                : const NeverScrollableScrollPhysics(),
                            onPageChanged: _pageSwiped,
                            itemCount: order.length,
                            findChildIndexCallback: (key) {
                              AppLog.instance.trace(
                                "lib/pages/player_panel.dart::_PlayerPanelState.build.closure#1.closure#9.closure#2",
                              );
                              final index = order.indexOf(
                                (key as ValueKey<int>).value,
                              );
                              return index < 0 ? null : index;
                            },
                            itemBuilder: (context, index) {
                              AppLog.instance.trace(
                                "lib/pages/player_panel.dart::_PlayerPanelState.build.closure#1.closure#9.closure#3",
                              );
                              final page = order[index];
                              return _PlayerPage(
                                key: ValueKey(page),
                                visible: _paneCount == 2
                                    ? page == 0 || page == _secondaryPage
                                    : page == _selectedPage,
                                child: DecoratedBox(
                                  decoration: BoxDecoration(
                                    border: _paneCount == 1
                                        ? null
                                        : Border(
                                            right: BorderSide(
                                              color: colors.outlineVariant,
                                            ),
                                          ),
                                  ),
                                  child: contents[page],
                                ),
                              );
                            },
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
        return _withKeyboard(page);
      },
    );
  }
}

class _PlayerPage extends StatefulWidget {
  const _PlayerPage({required this.child, required this.visible, super.key});

  final Widget child;
  final bool visible;

  @override
  State<_PlayerPage> createState() {
    AppLog.instance.trace(
      'lib/pages/player_panel.dart::_PlayerPage.createState',
    );
    return _PlayerPageState();
  }
}

class _PlayerPageState extends State<_PlayerPage>
    with AutomaticKeepAliveClientMixin {
  Widget? _retainedChild;
  @override
  bool get wantKeepAlive {
    AppLog.instance.trace(
      'lib/pages/player_panel.dart::_PlayerPageState.wantKeepAlive.get',
    );
    return true;
  }

  @override
  Widget build(BuildContext context) {
    AppLog.instance.trace(
      'lib/pages/player_panel.dart::_PlayerPageState.build',
    );
    super.build(context);
    if (widget.visible) _retainedChild = widget.child;
    return _retainedChild ?? widget.child;
  }
}

class _PlayerExpandTarget extends StatefulWidget {
  const _PlayerExpandTarget({required this.onTap, required this.child});

  final VoidCallback onTap;
  final Widget child;

  @override
  State<_PlayerExpandTarget> createState() {
    AppLog.instance.trace(
      "lib/pages/player_panel.dart::_PlayerExpandTarget.createState",
    );
    return _PlayerExpandTargetState();
  }
}

class _PlayerExpandTargetState extends State<_PlayerExpandTarget> {
  final _states = WidgetStatesController();

  @override
  void dispose() {
    AppLog.instance.trace(
      "lib/pages/player_panel.dart::_PlayerExpandTargetState.dispose",
    );

    _states.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    AppLog.instance.trace(
      "lib/pages/player_panel.dart::_PlayerExpandTargetState.build",
    );
    return ListenableBuilder(
      listenable: _states,
      builder: (context, _) {
        AppLog.instance.trace(
          "lib/pages/player_panel.dart::_PlayerExpandTargetState.build.closure#1",
        );

        final radius = BorderRadius.circular(10);
        return InkWell(
          onTap: widget.onTap,
          statesController: _states,
          mouseCursor: SystemMouseCursors.click,
          borderRadius: radius,
          overlayColor: const WidgetStatePropertyAll(Colors.transparent),
          splashFactory: NoSplash.splashFactory,
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: radius,
              border: Border.all(
                width: 1.5,
                color: _states.value.contains(WidgetState.focused)
                    ? Theme.of(context).colorScheme.primary
                    : Colors.transparent,
              ),
            ),
            child: widget.child,
          ),
        );
      },
    );
  }
}
