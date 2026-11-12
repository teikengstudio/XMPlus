import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../common/widgets/adaptive_text.dart';
import '../models/xmly_models.dart';
import '../services/app_log.dart';
import '../services/app_runtime.dart';

void _recordQueueError(
  String operation,
  Object error,
  StackTrace stack, {
  bool recoverable = false,
}) {
  AppLog.instance.trace("lib/pages/player_queue_panel.dart::_recordQueueError");

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
      }.contains(error.code);
  log.write(
    recoverable || expected ? AppLogLevel.warning : AppLogLevel.error,
    'player_queue_panel',
    operation,
    error: error,
    stackTrace: stack,
    promptUser: !recoverable && !expected,
  );
}

// Shared by the mini and expanded player; released with the player service.
final _positions = Expando<_QueuePosition>();

class _QueuePosition {
  String? trackId;
  double fraction = 0;
}

class PlayerQueuePanel extends StatefulWidget {
  const PlayerQueuePanel({required this.runtime, super.key});
  final AppRuntime runtime;

  @override
  State<PlayerQueuePanel> createState() {
    AppLog.instance.trace(
      "lib/pages/player_queue_panel.dart::PlayerQueuePanel.createState",
    );
    return _PlayerQueuePanelState();
  }
}

class _PlayerQueuePanelState extends State<PlayerQueuePanel> {
  late final _position = _positions[widget.runtime.player] ??= _QueuePosition();
  ScrollController? _scroll;
  List<Track> _tracks = const [];
  double _rowExtent = 64;
  bool _busy = false;
  bool _confirmClear = false;
  String? _error;

  @override
  void didChangeDependencies() {
    AppLog.instance.trace(
      "lib/pages/player_queue_panel.dart::_PlayerQueuePanelState.didChangeDependencies",
    );

    super.didChangeDependencies();
    final scaler = MediaQuery.textScalerOf(context);
    _rowExtent = math.max(
      64,
      scaler.scale(16) * 1.5 + scaler.scale(14) * 1.5 + 12,
    );
    if (_scroll != null) return;
    _tracks = widget.runtime.player.queue;
    final anchor = _tracks.indexWhere((track) {
      AppLog.instance.trace(
        "lib/pages/player_queue_panel.dart::_PlayerQueuePanelState.didChangeDependencies.closure#1",
      );
      return track.id == _position.trackId;
    });
    final index = anchor >= 0 ? anchor : widget.runtime.player.cursor;
    _scroll = ScrollController(
      initialScrollOffset:
          (math.max(0, index) + (anchor >= 0 ? _position.fraction : 0)) *
          _rowExtent,
      keepScrollOffset: false,
    )..addListener(_remember);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      AppLog.instance.trace(
        "lib/pages/player_queue_panel.dart::_PlayerQueuePanelState.didChangeDependencies.closure#2",
      );

      if (mounted) _remember();
    });
  }

  void _remember() {
    AppLog.instance.trace(
      "lib/pages/player_queue_panel.dart::_PlayerQueuePanelState._remember",
    );

    final scroll = _scroll;
    if (scroll == null || !scroll.hasClients || _tracks.isEmpty) return;
    final row = math.max(0, scroll.offset) / _rowExtent;
    final index = row.floor().clamp(0, _tracks.length - 1);
    _position
      ..trackId = _tracks[index].id
      ..fraction = (row - index).clamp(0, 1);
  }

  @override
  void dispose() {
    AppLog.instance.trace(
      "lib/pages/player_queue_panel.dart::_PlayerQueuePanelState.dispose",
    );

    _remember();
    _scroll?.dispose();
    super.dispose();
  }

  void _showCurrent() {
    AppLog.instance.trace(
      "lib/pages/player_queue_panel.dart::_PlayerQueuePanelState._showCurrent",
    );

    final scroll = _scroll, index = widget.runtime.player.cursor;
    if (scroll == null || !scroll.hasClients || index < 0) return;
    final target =
        index * _rowExtent -
        (scroll.position.viewportDimension - _rowExtent) / 2;
    scroll.animateTo(
      target.clamp(0, scroll.position.maxScrollExtent),
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
    );
  }

  Future<void> _run(Future<void> Function() command) {
    AppLog.instance.trace(
      "lib/pages/player_queue_panel.dart::_PlayerQueuePanelState._run",
    );
    return AppLog.instance.runWithErrorScope(() async {
      AppLog.instance.trace(
        "lib/pages/player_queue_panel.dart::_PlayerQueuePanelState._run.closure#1",
      );

      if (_busy) return;
      setState(() {
        AppLog.instance.trace(
          "lib/pages/player_queue_panel.dart::_PlayerQueuePanelState._run.closure#1.closure#1",
        );

        _busy = true;
        _error = null;
      });
      try {
        await command();
      } catch (error, stack) {
        _recordQueueError('Queue command failed', error, stack);
        if (mounted) {
          setState(() {
            AppLog.instance.trace(
              "lib/pages/player_queue_panel.dart::_PlayerQueuePanelState._run.closure#1.closure#2",
            );

            _error = error is XmlyException ? error.message : '队列操作失败，请重试';
          });
        }
      } finally {
        if (mounted)
          setState(() {
            AppLog.instance.trace(
              "lib/pages/player_queue_panel.dart::_PlayerQueuePanelState._run.closure#1.closure#3",
            );
            _busy = false;
          });
      }
    });
  }

  Future<void> _clear() async {
    AppLog.instance.trace(
      "lib/pages/player_queue_panel.dart::_PlayerQueuePanelState._clear",
    );
    setState(() {
      AppLog.instance.trace(
        "lib/pages/player_queue_panel.dart::_PlayerQueuePanelState._clear.closure#1",
      );
      _confirmClear = false;
    });
    await _run(widget.runtime.player.clearQueue);
  }

  @override
  Widget build(BuildContext context) {
    AppLog.instance.trace(
      "lib/pages/player_queue_panel.dart::_PlayerQueuePanelState.build",
    );
    return SafeArea(
      top: false,
      child: LayoutBuilder(
        builder: (context, constraints) {
          AppLog.instance.trace(
            "lib/pages/player_queue_panel.dart::_PlayerQueuePanelState.build.closure#1",
          );
          return ListenableBuilder(
            listenable: widget.runtime,
            builder: (context, _) {
              AppLog.instance.trace(
                "lib/pages/player_queue_panel.dart::_PlayerQueuePanelState.build.closure#1.closure#1",
              );

              final player = widget.runtime.player;
              _tracks = player.queue;
              return Column(
                children: [
                  ConstrainedBox(
                    constraints: BoxConstraints(
                      maxHeight: math.max(
                        0,
                        constraints.maxHeight - _rowExtent - 4,
                      ),
                    ),
                    child: SingleChildScrollView(
                      primary: false,
                      child: Column(
                        children: [
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 4),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      AdaptiveText(
                                        '${_tracks.length} 集 · ${player.queueSource == 'album' ? '专辑播放' : player.queueSourceLabel}',
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodySmall,
                                      ),
                                      if (player.queueSource == 'updates') ...[
                                        const SizedBox(height: 4),
                                        AdaptiveText(
                                          player.queueOrderLabel,
                                          style: Theme.of(context)
                                              .textTheme
                                              .bodySmall,
                                        ),
                                      ],
                                    ],
                                  ),
                                ),
                                IconButton(
                                  tooltip: '回到当前播放',
                                  onPressed: player.current == null
                                      ? null
                                      : _showCurrent,
                                  icon: const Icon(
                                    Icons.my_location_rounded,
                                    size: 20,
                                  ),
                                ),
                                TextButton(
                                  onPressed: _busy || _tracks.isEmpty
                                      ? null
                                      : () {
                                          AppLog.instance.trace(
                                            "lib/pages/player_queue_panel.dart::_PlayerQueuePanelState.build.closure#1.closure#1.closure#1",
                                          );

                                          setState(() {
                                            AppLog.instance.trace(
                                              "lib/pages/player_queue_panel.dart::_PlayerQueuePanelState.build.closure#1.closure#1.closure#1.closure#1",
                                            );
                                            _confirmClear = true;
                                          });
                                        },
                                  child: const Text('清空'),
                                ),
                              ],
                            ),
                          ),
                          if (_confirmClear)
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 8),
                              child: Wrap(
                                alignment: WrapAlignment.center,
                                crossAxisAlignment: WrapCrossAlignment.center,
                                spacing: 12,
                                children: [
                                  const Text('清空当前播放列表？'),
                                  TextButton(
                                    onPressed: () {
                                      AppLog.instance.trace(
                                        "lib/pages/player_queue_panel.dart::_PlayerQueuePanelState.build.closure#1.closure#1.closure#2",
                                      );

                                      setState(() {
                                        AppLog.instance.trace(
                                          "lib/pages/player_queue_panel.dart::_PlayerQueuePanelState.build.closure#1.closure#1.closure#2.closure#1",
                                        );
                                        _confirmClear = false;
                                      });
                                    },
                                    child: const Text('保留列表'),
                                  ),
                                  TextButton(
                                    onPressed: _busy ? null : _clear,
                                    child: const Text('确认清空'),
                                  ),
                                ],
                              ),
                            ),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            child: Wrap(
                              spacing: 8,
                              children: [
                                if (player.queueSource == 'album' &&
                                    player.sourceAlbumId.isNotEmpty)
                                  TextButton(
                                    onPressed: _busy
                                        ? null
                                        : () {
                                            AppLog.instance.trace(
                                              "lib/pages/player_queue_panel.dart::_PlayerQueuePanelState.build.closure#1.closure#1.closure#3",
                                            );
                                            _run(() {
                                              AppLog.instance.trace(
                                                "lib/pages/player_queue_panel.dart::_PlayerQueuePanelState.build.closure#1.closure#1.closure#3.closure#1",
                                              );
                                              return player.refreshAlbumTail(
                                                player.sourceAlbumId,
                                              );
                                            });
                                          },
                                    child: const Text('检查专辑更新'),
                                  ),
                              ],
                            ),
                          ),
                          if (_error != null)
                            Padding(
                              padding: const EdgeInsets.all(8),
                              child: Text(
                                _error!,
                                style: TextStyle(
                                  color: Theme.of(context).colorScheme.error,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  SizedBox(
                    height: 4,
                    child: _busy ? const LinearProgressIndicator() : null,
                  ),
                  Expanded(
                    child: _tracks.isEmpty
                        ? const Center(child: Text('队列为空'))
                        : Scrollbar(
                            controller: _scroll,
                            child: ReorderableListView.builder(
                              key: const ValueKey('playerQueueScroll'),
                              scrollController: _scroll,
                              padding: EdgeInsets.zero,
                              itemExtent: _rowExtent,
                              itemCount: _tracks.length,
                              buildDefaultDragHandles: false,
                              onReorderItem: (from, to) {
                                AppLog.instance.trace(
                                  "lib/pages/player_queue_panel.dart::_PlayerQueuePanelState.build.closure#1.closure#1.closure#4",
                                );

                                _run(() {
                                  AppLog.instance.trace(
                                    "lib/pages/player_queue_panel.dart::_PlayerQueuePanelState.build.closure#1.closure#1.closure#4.closure#1",
                                  );
                                  return player.moveQueueItem(from, to);
                                });
                              },
                              itemBuilder: (context, index) {
                                AppLog.instance.trace(
                                  "lib/pages/player_queue_panel.dart::_PlayerQueuePanelState.build.closure#1.closure#1.closure#5",
                                );

                                final track = _tracks[index];
                                return ListTile(
                                  key: ValueKey('queue:$index:${track.id}'),
                                  selected: index == player.cursor,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  selectedTileColor: Theme.of(context)
                                      .colorScheme
                                      .surfaceContainerHigh,
                                  minTileHeight: _rowExtent,
                                  contentPadding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                  ),
                                  minVerticalPadding: 4,
                                  minLeadingWidth: 48,
                                  horizontalTitleGap: 8,
                                  leading: ReorderableDragStartListener(
                                    index: index,
                                    enabled: !_busy,
                                    child: Tooltip(
                                      message: '拖动调整顺序',
                                      child: SizedBox(
                                        width: 48,
                                        height: 48,
                                        child: Icon(
                                          index == player.cursor
                                              ? Icons.graphic_eq
                                              : Icons.drag_handle,
                                        ),
                                      ),
                                    ),
                                  ),
                                  title: AdaptiveText(
                                    track.title.isEmpty
                                        ? track.id
                                        : track.title,
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodyMedium,
                                  ),
                                  subtitle: track.album.isEmpty
                                      ? null
                                      : AdaptiveText(
                                          track.album,
                                          style: Theme.of(context)
                                              .textTheme
                                              .bodySmall,
                                        ),
                                  onTap: _busy
                                      ? null
                                      : () {
                                          AppLog.instance.trace(
                                            "lib/pages/player_queue_panel.dart::_PlayerQueuePanelState.build.closure#1.closure#1.closure#5.closure#1",
                                          );
                                          _run(() {
                                            AppLog.instance.trace(
                                              "lib/pages/player_queue_panel.dart::_PlayerQueuePanelState.build.closure#1.closure#1.closure#5.closure#1.closure#1",
                                            );
                                            return player.playQueueItem(index);
                                          });
                                        },
                                  trailing: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      IconButton(
                                        tooltip: '下一集播放',
                                        icon: const Icon(Icons.playlist_play),
                                        onPressed:
                                            _busy || index == player.cursor
                                            ? null
                                            : () {
                                                AppLog.instance.trace(
                                                  "lib/pages/player_queue_panel.dart::_PlayerQueuePanelState.build.closure#1.closure#1.closure#5.closure#2",
                                                );
                                                _run(() {
                                                  AppLog.instance.trace(
                                                    "lib/pages/player_queue_panel.dart::_PlayerQueuePanelState.build.closure#1.closure#1.closure#5.closure#2.closure#1",
                                                  );
                                                  return player.playNext(track);
                                                });
                                              },
                                      ),
                                      IconButton(
                                        tooltip: '移出队列',
                                        icon: const Icon(Icons.close),
                                        onPressed: _busy
                                            ? null
                                            : () {
                                                AppLog.instance.trace(
                                                  "lib/pages/player_queue_panel.dart::_PlayerQueuePanelState.build.closure#1.closure#1.closure#5.closure#3",
                                                );
                                                _run(() {
                                                  AppLog.instance.trace(
                                                    "lib/pages/player_queue_panel.dart::_PlayerQueuePanelState.build.closure#1.closure#1.closure#5.closure#3.closure#1",
                                                  );
                                                  return player.removeQueueItem(
                                                    index,
                                                  );
                                                });
                                              },
                                      ),
                                    ],
                                  ),
                                );
                              },
                            ),
                          ),
                  ),
                ],
              );
            },
          );
        },
      ),
    );
  }
}
