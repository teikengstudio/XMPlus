import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api/xmly_client.dart';
import '../api/xmly_experience.dart';
import '../common/widgets/adaptive_text.dart';
import '../common/widgets/confirmation_dialog.dart';
import '../common/widgets/logged_network_image.dart';
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
  XmlyClient? _manuscriptClient;
  String? _manuscriptKey, _manuscriptTrackId, _manuscript, _manuscriptError;
  bool _manuscriptLoading = false;
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
    _runtime.addListener(_manuscriptContextChanged);
    if (widget.expanded) unawaited(_refreshManuscript());
    if (widget.expanded) unawaited(_refreshFavorite());
  }

  @override
  void didUpdateWidget(covariant PlayerPanel oldWidget) {
    AppLog.instance.trace(
      "lib/pages/player_panel.dart::_PlayerPanelState.didUpdateWidget",
    );

    super.didUpdateWidget(oldWidget);
    if (oldWidget.runtime != _runtime) {
      oldWidget.runtime.removeListener(_favoriteContextChanged);
      oldWidget.runtime.removeListener(_manuscriptContextChanged);
      _runtime.addListener(_manuscriptContextChanged);
      _runtime.addListener(_favoriteContextChanged);
      _dragPosition = null;
      _dragEpoch = null;
    }
    if (widget.expanded &&
        (oldWidget.runtime != _runtime || !oldWidget.expanded)) {
      unawaited(_refreshFavorite());
    }
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
    _runtime.removeListener(_manuscriptContextChanged);
    _manuscriptRequest++;
    _manuscriptCancelled?.complete();
    _manuscriptCancelled = null;
    _favoriteRequest++;
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

  Future<void> _refreshManuscript() {
    AppLog.instance.trace(
      "lib/pages/player_panel.dart::_PlayerPanelState._refreshManuscript",
    );
    return AppLog.instance.runWithErrorScope(() async {
      AppLog.instance.trace(
        "lib/pages/player_panel.dart::_PlayerPanelState._refreshManuscript.closure#1",
      );

      final client = _runtime.client, key = _runtime.client.cacheIdentity;
      final trackId = _runtime.player.current?.id;
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
        if (current())
          setState(() {
            AppLog.instance.trace(
              "lib/pages/player_panel.dart::_PlayerPanelState._refreshManuscript.closure#1.closure#3",
            );
            _manuscript = manuscript;
          });
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
    _navigator.push(
      MaterialPageRoute<void>(
        builder: (_) {
          AppLog.instance.trace(
            "lib/pages/player_panel.dart::_PlayerPanelState._openAlbum.closure#1",
          );
          return AlbumPageView(runtime: _runtime, albumId: albumId);
        },
      ),
    );
  }

  Future<void> _queue() {
    AppLog.instance.trace(
      "lib/pages/player_panel.dart::_PlayerPanelState._queue",
    );
    return showPlayerQueuePanel(_navigator.context, _runtime);
  }

  Widget _cover(String? url, double size, {bool small = false}) {
    AppLog.instance.trace(
      "lib/pages/player_panel.dart::_PlayerPanelState._cover",
    );

    final colors = Theme.of(context).colorScheme;
    final fallback = ColoredBox(
      color: colors.primaryContainer,
      child: Center(
        child: Icon(
          Icons.headphones_rounded,
          size: size * 0.34,
          color: colors.onPrimaryContainer,
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
    String tooltip,
    IconData icon,
    Future<void> Function()? command, {
    double size = 28,
  }) {
    AppLog.instance.trace(
      "lib/pages/player_panel.dart::_PlayerPanelState._button",
    );
    return IconButton(
      tooltip: tooltip,
      onPressed: _busy || _cancelling || command == null
          ? null
          : () {
              AppLog.instance.trace(
                "lib/pages/player_panel.dart::_PlayerPanelState._button.closure#1",
              );
              _act(command);
            },
      icon: Icon(icon, size: size),
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
        final favorite = _favorite == true;
        final settings = player.effectiveSettings;
        final message =
            _error ?? _favoriteError ?? player.error ?? player.warning;
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
        final compact = MediaQuery.sizeOf(context).width < 320;
        if (!widget.expanded) {
          return Material(
            color: colors.surfaceContainer,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: InkWell(
                        onTap: widget.onExpand ?? _expand,
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(16, 10, 4, 10),
                          child: Row(
                            children: [
                              if (!compact) ...[
                                _cover(coverUrl, 44, small: true),
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
                    IconButton(
                      tooltip: playLabel,
                      onPressed: play,
                      icon: Icon(
                        canPause
                            ? Icons.pause_rounded
                            : Icons.play_arrow_rounded,
                        size: 32,
                      ),
                    ),
                    if (widget.miniWindow)
                      _button(
                        '下一集',
                        Icons.skip_next_rounded,
                        track == null ? null : player.next,
                      )
                    else
                      IconButton(
                        tooltip: '播放列表',
                        onPressed: _queue,
                        icon: const Icon(Icons.queue_music_rounded),
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
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AdaptiveText(
              title,
              minimumScale: 0.8,
              style: theme.textTheme.titleLarge?.copyWith(
                fontSize: compact ? 16 : 20,
                fontWeight: FontWeight.w600,
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
                      "lib/pages/player_panel.dart::_PlayerPanelState.build.closure#1.closure#2",
                    );
                    _openAlbum(track.albumId);
                  },
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    alignment: Alignment.centerLeft,
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
            SizedBox(height: compact ? 4 : 16),
            Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                PlaybackSpeedControl(
                  key: ValueKey((_runtime, track?.id)),
                  runtime: _runtime,
                  albumId: track?.albumId.isNotEmpty == true
                      ? track!.albumId
                      : null,
                ),
                _button(
                  _favoriteLabel,
                  favorite
                      ? Icons.favorite_rounded
                      : Icons.favorite_border_rounded,
                  track == null || _favoriteBusy
                      ? null
                      : () {
                          AppLog.instance.trace(
                            "lib/pages/player_panel.dart::_PlayerPanelState.build.closure#1.closure#3",
                          );
                          return _favoriteAction(track);
                        },
                ),
                PlaybackVolumeControl(runtime: _runtime),
                _button(
                  '添加书签',
                  Icons.bookmark_add_outlined,
                  track == null
                      ? null
                      : () async {
                          AppLog.instance.trace(
                            "lib/pages/player_panel.dart::_PlayerPanelState.build.closure#1.closure#4",
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
                        },
                ),
              ],
            ),
          ],
        );
        final progress = Column(
          children: [
            SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 3,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 22),
                inactiveTrackColor: colors.onSurface.withValues(alpha: 0.12),
              ),
              child: Slider(
                key: ValueKey((player, epoch)),
                padding: const EdgeInsets.symmetric(
                  vertical: 22,
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
                          "lib/pages/player_panel.dart::_PlayerPanelState.build.closure#1.closure#5",
                        );
                        _dragEpoch = epoch;
                      },
                onChanged: track == null || max == 0 || _busy
                    ? null
                    : (value) {
                        AppLog.instance.trace(
                          "lib/pages/player_panel.dart::_PlayerPanelState.build.closure#1.closure#6",
                        );

                        if (_dragEpoch == epoch &&
                            player.playbackEpoch == epoch) {
                          setState(() {
                            AppLog.instance.trace(
                              "lib/pages/player_panel.dart::_PlayerPanelState.build.closure#1.closure#6.closure#1",
                            );
                            _dragPosition = value;
                          });
                        }
                      },
                onChangeEnd: track == null || max == 0 || _busy
                    ? null
                    : (value) async {
                        AppLog.instance.trace(
                          "lib/pages/player_panel.dart::_PlayerPanelState.build.closure#1.closure#7",
                        );

                        final selectedEpoch = _dragEpoch;
                        setState(() {
                          AppLog.instance.trace(
                            "lib/pages/player_panel.dart::_PlayerPanelState.build.closure#1.closure#7.closure#1",
                          );

                          _dragPosition = null;
                          _dragEpoch = null;
                        });
                        if (selectedEpoch != epoch ||
                            player.playbackEpoch != epoch)
                          return;
                        await _act(() {
                          AppLog.instance.trace(
                            "lib/pages/player_panel.dart::_PlayerPanelState.build.closure#1.closure#7.closure#2",
                          );
                          return player.seek(value, expectedEpoch: epoch);
                        });
                      },
              ),
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
          padding: EdgeInsets.symmetric(vertical: compact ? 8 : 20),
          child: Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (!compact)
                _button(
                  _keyHint('后退 ${settings.seekBackwardSeconds} 秒', '←'),
                  Icons.replay_rounded,
                  track == null ? null : player.seekBackward,
                  size: 24,
                ),
              _button(
                '上一集',
                Icons.skip_previous_rounded,
                track == null ? null : player.previous,
                size: 34,
              ),
              Tooltip(
                message: _keyHint(playLabel, '空格'),
                child: SizedBox.square(
                  dimension: compact ? 64 : 76,
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      padding: EdgeInsets.zero,
                      shape: const CircleBorder(),
                    ),
                    onPressed: play,
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        if (_busy ||
                            _cancelling ||
                            player.loading ||
                            player.buffering)
                          SizedBox.square(
                            dimension: compact ? 52 : 62,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: colors.onPrimary,
                            ),
                          ),
                        Icon(
                          canPause
                              ? Icons.pause_rounded
                              : Icons.play_arrow_rounded,
                          size: 42,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              _button(
                '下一集',
                Icons.skip_next_rounded,
                track == null ? null : player.next,
                size: 34,
              ),
              if (!compact)
                _button(
                  _keyHint('前进 ${settings.seekForwardSeconds} 秒', '→'),
                  Icons.forward_rounded,
                  track == null ? null : player.seekForward,
                  size: 24,
                ),
            ],
          ),
        );
        final footer = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: TextButton.icon(
                    onPressed: () {
                      AppLog.instance.trace(
                        "lib/pages/player_panel.dart::_PlayerPanelState.build.closure#1.closure#8",
                      );
                      showSleepTimerDialog(context, _runtime);
                    },
                    icon: Icon(
                      sleep == null ? Icons.timer_outlined : Icons.timer,
                    ),
                    label: Text(
                      sleepLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextButton.icon(
                    onPressed: _queue,
                    icon: const Icon(Icons.queue_music_rounded),
                    label: const Text(
                      '播放列表',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ],
            ),
            if (track != null && _manuscript == null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: _manuscriptLoading
                    ? const Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          SizedBox.square(
                            dimension: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                          SizedBox(width: 8),
                          Text('正在读取文稿…', key: ValueKey('manuscriptLoading')),
                        ],
                      )
                    : _manuscriptError != null
                    ? Column(
                        children: [
                          Text(
                            _manuscriptError!,
                            key: const ValueKey('manuscriptError'),
                            style: TextStyle(color: colors.error),
                          ),
                          TextButton.icon(
                            key: const ValueKey('manuscriptRetry'),
                            onPressed: _refreshManuscript,
                            icon: const Icon(Icons.refresh),
                            label: const Text('重试文稿'),
                          ),
                        ],
                      )
                    : Text(
                        '此声音暂无文稿',
                        key: const ValueKey('manuscriptAbsent'),
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodySmall,
                      ),
              ),
            if (sleep != null)
              TextButton(
                onPressed: () {
                  AppLog.instance.trace(
                    "lib/pages/player_panel.dart::_PlayerPanelState.build.closure#1.closure#9",
                  );

                  player.cancelSleep();
                  _runtime.changed();
                },
                child: const Text('取消定时'),
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
          appBar: AppBar(
            leading: IconButton(
              tooltip: '收起播放器',
              onPressed: () {
                AppLog.instance.trace(
                  "lib/pages/player_panel.dart::_PlayerPanelState.build.closure#1.closure#10",
                );
                Navigator.of(context).maybePop();
              },
              icon: const Icon(Icons.keyboard_arrow_down_rounded),
            ),
            title: const Text('正在收听'),
            centerTitle: true,
            actions: [
              PopupMenuButton<String>(
                tooltip: '更多播放操作',
                icon: const Icon(Icons.more_horiz),
                onSelected: (value) {
                  AppLog.instance.trace(
                    "lib/pages/player_panel.dart::_PlayerPanelState.build.closure#1.closure#11",
                  );

                  switch (value) {
                    case 'settings':
                      _settings();
                    case 'comments':
                      if (track != null)
                        showTrackComments(_navigator.context, _runtime, track);
                    case 'album':
                      if (track != null) _openAlbum(track.albumId);
                    case 'replay':
                      _act(player.replay);
                    case 'local':
                      _act(player.switchToLocal);
                    case 'backward':
                      _act(player.seekBackward);
                    case 'forward':
                      _act(player.seekForward);
                  }
                },
                itemBuilder: (_) {
                  AppLog.instance.trace(
                    "lib/pages/player_panel.dart::_PlayerPanelState.build.closure#1.closure#12",
                  );
                  return [
                    const PopupMenuItem(value: 'settings', child: Text('播放设置')),
                    if (track != null)
                      const PopupMenuItem(
                        value: 'comments',
                        child: Text('查看评论'),
                      ),
                    if (track?.albumId.isNotEmpty == true)
                      const PopupMenuItem(value: 'album', child: Text('查看专辑')),
                    PopupMenuItem(
                      value: 'replay',
                      enabled: track != null && !_busy,
                      child: const Text('从头重听'),
                    ),
                    if (compact) ...[
                      PopupMenuItem(
                        value: 'backward',
                        enabled: track != null && !_busy,
                        child: Text(
                          _keyHint('后退 ${settings.seekBackwardSeconds} 秒', '←'),
                        ),
                      ),
                      PopupMenuItem(
                        value: 'forward',
                        enabled: track != null && !_busy,
                        child: Text(
                          _keyHint('前进 ${settings.seekForwardSeconds} 秒', '→'),
                        ),
                      ),
                    ],
                    if (track != null &&
                        player.sourceKind != 'local' &&
                        _runtime.downloads.tasks.any((task) {
                          AppLog.instance.trace(
                            "lib/pages/player_panel.dart::_PlayerPanelState.build.closure#1.closure#12.closure#1",
                          );
                          return task.track.id == track.id &&
                              task.state.name == 'completed';
                        }))
                      PopupMenuItem(
                        value: 'local',
                        enabled: !_busy,
                        child: const Text('切换本地文件'),
                      ),
                  ];
                },
              ),
            ],
          ),
          body: SafeArea(
            top: false,
            child: LayoutBuilder(
              builder: (context, constraints) {
                AppLog.instance.trace(
                  "lib/pages/player_panel.dart::_PlayerPanelState.build.closure#1.closure#13",
                );

                final manuscript = _manuscript;
                final wideReader =
                    manuscript != null && constraints.maxWidth >= 900;
                final twoColumns =
                    constraints.maxWidth >= 760 && constraints.maxHeight < 700;
                // ponytail: reserve the control stack; very short/error states scroll.
                final textHeight = MediaQuery.textScalerOf(context).scale(56);
                final coverHeight =
                    constraints.maxHeight -
                    380 -
                    textHeight -
                    (sleep == null ? 0 : 48);
                final coverSize = twoColumns
                    ? math.min(360.0, constraints.maxWidth * 0.38)
                    : math.min(
                        360.0,
                        math.min(
                          constraints.maxWidth - 64,
                          math.max(120.0, coverHeight),
                        ),
                      );
                final details = Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    metadata,
                    SizedBox(height: compact ? 4 : 20),
                    progress,
                    controls,
                    footer,
                  ],
                );
                if (manuscript != null) {
                  final reader = ManuscriptReader(
                    key: ValueKey((
                      _manuscriptClient,
                      _manuscriptKey,
                      track?.id,
                    )),
                    manuscript: manuscript,
                  );
                  final left = Padding(
                    padding: EdgeInsets.all(compact ? 8 : 24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (!compact) ...[
                          _cover(
                            coverUrl,
                            math.min(coverSize, wideReader ? 240 : 300),
                          ),
                          const SizedBox(height: 20),
                        ],
                        details,
                      ],
                    ),
                  );
                  if (wideReader) {
                    return Row(
                      key: const ValueKey('manuscriptWideLayout'),
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(
                          child: SingleChildScrollView(
                            key: const ValueKey('manuscriptControlsScroll'),
                            child: left,
                          ),
                        ),
                        const VerticalDivider(width: 1),
                        Expanded(
                          child: Padding(
                            key: const ValueKey('manuscriptRightPane'),
                            padding: const EdgeInsets.all(24),
                            child: reader,
                          ),
                        ),
                      ],
                    );
                  }
                  return SingleChildScrollView(
                    key: const ValueKey('manuscriptNarrowLayout'),
                    child: Column(
                      children: [
                        left,
                        SizedBox(
                          height: math.max(
                            320,
                            math.min(560, constraints.maxHeight * .75),
                          ),
                          child: Padding(
                            padding: EdgeInsets.all(compact ? 8 : 24),
                            child: reader,
                          ),
                        ),
                      ],
                    ),
                  );
                }
                return SingleChildScrollView(
                  child: Center(
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        maxWidth: twoColumns ? 1040 : 520,
                        minHeight: constraints.maxHeight,
                      ),
                      child: Padding(
                        padding: EdgeInsets.fromLTRB(
                          compact ? 8 : 24,
                          compact ? 8 : 20,
                          compact ? 8 : 24,
                          compact ? 8 : 24,
                        ),
                        child: twoColumns
                            ? Row(
                                crossAxisAlignment: CrossAxisAlignment.center,
                                children: [
                                  _cover(coverUrl, coverSize),
                                  const SizedBox(width: 40),
                                  Expanded(child: details),
                                ],
                              )
                            : Column(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceEvenly,
                                children: [
                                  if (!compact) ...[
                                    _cover(coverUrl, coverSize),
                                    const SizedBox(height: 28),
                                  ],
                                  details,
                                ],
                              ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        );
        return _withKeyboard(page);
      },
    );
  }
}
