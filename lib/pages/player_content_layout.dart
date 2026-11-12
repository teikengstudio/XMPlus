import 'dart:math' as math;

import 'package:flutter/material.dart';

import "../services/app_log.dart";

/// Keeps the player at a constant width while its neighbouring pane opens.
class PlayerContentLayout extends StatefulWidget {
  const PlayerContentLayout({
    required this.sideOpen,
    required this.player,
    required this.side,
    super.key,
  });

  final bool sideOpen;
  final Widget player;
  final Widget side;

  @override
  State<PlayerContentLayout> createState() {
    AppLog.instance.trace(
      "lib/pages/player_content_layout.dart::PlayerContentLayout.createState",
    );
    return _PlayerContentLayoutState();
  }
}

class _PlayerContentLayoutState extends State<PlayerContentLayout>
    with SingleTickerProviderStateMixin {
  late final _motion = AnimationController(
    vsync: this,
    value: widget.sideOpen ? 1 : 0,
    duration: const Duration(milliseconds: 340),
    reverseDuration: const Duration(milliseconds: 280),
  );
  late final _position = CurvedAnimation(
    parent: _motion,
    curve: Curves.easeInOutCubic,
  );
  late final _reveal = CurvedAnimation(
    parent: _motion,
    // Make room before showing text, and hide it before the player moves back.
    curve: const Interval(0.62, 1, curve: Curves.easeOutCubic),
  );
  bool _reduceMotion = false;

  @override
  void didChangeDependencies() {
    AppLog.instance.trace(
      "lib/pages/player_content_layout.dart::_PlayerContentLayoutState.didChangeDependencies",
    );

    super.didChangeDependencies();
    _reduceMotion = MediaQuery.disableAnimationsOf(context);
    if (_reduceMotion) _motion.value = widget.sideOpen ? 1 : 0;
  }

  @override
  void didUpdateWidget(covariant PlayerContentLayout oldWidget) {
    AppLog.instance.trace(
      "lib/pages/player_content_layout.dart::_PlayerContentLayoutState.didUpdateWidget",
    );

    super.didUpdateWidget(oldWidget);
    if (oldWidget.sideOpen == widget.sideOpen) return;
    if (_reduceMotion) {
      _motion.value = widget.sideOpen ? 1 : 0;
    } else if (widget.sideOpen) {
      _motion.forward();
    } else {
      _motion.reverse();
    }
  }

  @override
  void dispose() {
    AppLog.instance.trace(
      "lib/pages/player_content_layout.dart::_PlayerContentLayoutState.dispose",
    );

    _position.dispose();
    _reveal.dispose();
    _motion.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    AppLog.instance.trace(
      "lib/pages/player_content_layout.dart::_PlayerContentLayoutState.build",
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        AppLog.instance.trace(
          "lib/pages/player_content_layout.dart::_PlayerContentLayoutState.build.closure#1",
        );

        final leftWidth = (constraints.maxWidth - 32) * 10 / 21;
        final centerOffset = (constraints.maxWidth - leftWidth) / 2;
        final side = RepaintBoundary(child: widget.side);
        final player = RepaintBoundary(child: widget.player);
        return ClipRect(
          child: AnimatedBuilder(
            animation: _motion,
            builder: (context, _) {
              AppLog.instance.trace(
                "lib/pages/player_content_layout.dart::_PlayerContentLayoutState.build.closure#1.closure#1",
              );
              return Stack(
                fit: StackFit.expand,
                children: [
                  Positioned(
                    left: 0,
                    top: 0,
                    bottom: 0,
                    width: leftWidth,
                    child: Transform.translate(
                      offset: Offset(centerOffset * (1 - _position.value), 0),
                      child: player,
                    ),
                  ),
                  Positioned(
                    left: leftWidth + 32,
                    top: 0,
                    bottom: 0,
                    right: 0,
                    child: Offstage(
                      offstage: _motion.isDismissed && !widget.sideOpen,
                      child: TickerMode(
                        enabled: !_motion.isDismissed,
                        child: ExcludeFocus(
                          excluding: !widget.sideOpen || _reveal.value == 0,
                          child: ExcludeSemantics(
                            excluding: !widget.sideOpen || _reveal.value == 0,
                            child: IgnorePointer(
                              ignoring: !widget.sideOpen || _reveal.value == 0,
                              child: FadeTransition(
                                opacity: _reveal,
                                child: Transform.translate(
                                  offset: Offset(12 * (1 - _reveal.value), 0),
                                  child: side,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        );
      },
    );
  }
}

/// Retains visited panes so tab changes do not restart loading or lose scrolling.
class PlayerSideContent extends StatefulWidget {
  const PlayerSideContent({
    required this.section,
    required this.header,
    required this.content,
    super.key,
  });

  final String? section;
  final Widget header;
  final Widget? content;

  @override
  State<PlayerSideContent> createState() {
    AppLog.instance.trace(
      "lib/pages/player_content_layout.dart::PlayerSideContent.createState",
    );
    return _PlayerSideContentState();
  }
}

class _PlayerSideContentState extends State<PlayerSideContent> {
  final _panes = <String, Widget>{};
  final _leaving = <String>{};
  String? _selected;
  late Widget _header;
  bool _reduceMotion = false;

  @override
  void initState() {
    AppLog.instance.trace(
      "lib/pages/player_content_layout.dart::_PlayerSideContentState.initState",
    );

    super.initState();
    _header = widget.header;
    _updateContent();
  }

  @override
  void didChangeDependencies() {
    AppLog.instance.trace(
      "lib/pages/player_content_layout.dart::_PlayerSideContentState.didChangeDependencies",
    );

    super.didChangeDependencies();
    _reduceMotion = MediaQuery.disableAnimationsOf(context);
    if (_reduceMotion) _leaving.clear();
  }

  void _updateContent() {
    AppLog.instance.trace(
      "lib/pages/player_content_layout.dart::_PlayerSideContentState._updateContent",
    );

    final section = widget.section, content = widget.content;
    if (section == null || content == null) return;
    if (_selected != null && _selected != section && !_reduceMotion) {
      _leaving.add(_selected!);
    }
    _leaving.remove(section);
    _selected = section;
    _panes[section] = content;
    _header = widget.header;
  }

  @override
  void didUpdateWidget(covariant PlayerSideContent oldWidget) {
    AppLog.instance.trace(
      "lib/pages/player_content_layout.dart::_PlayerSideContentState.didUpdateWidget",
    );

    super.didUpdateWidget(oldWidget);
    _updateContent();
  }

  void _finishTransition(String section) {
    AppLog.instance.trace(
      "lib/pages/player_content_layout.dart::_PlayerSideContentState._finishTransition",
    );

    if (!mounted || section == _selected || !_leaving.contains(section)) return;
    setState(() {
      AppLog.instance.trace(
        "lib/pages/player_content_layout.dart::_PlayerSideContentState._finishTransition.closure#1",
      );
      _leaving.remove(section);
    });
  }

  @override
  Widget build(BuildContext context) {
    AppLog.instance.trace(
      "lib/pages/player_content_layout.dart::_PlayerSideContentState.build",
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        AppLog.instance.trace(
          "lib/pages/player_content_layout.dart::_PlayerSideContentState.build.closure#1",
        );

        final gap = math.min(16.0, constraints.maxHeight * .05);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: math.max(
                  0,
                  constraints.maxHeight -
                      gap -
                      math.min(176, constraints.maxHeight * .6),
                ),
              ),
              child: SingleChildScrollView(primary: false, child: _header),
            ),
            SizedBox(height: gap),
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  for (final section in const [
                    'comments',
                    'manuscript',
                    'queue',
                  ])
                    Offstage(
                      key: ValueKey(section),
                      offstage:
                          section != _selected && !_leaving.contains(section),
                      child: TickerMode(
                        enabled:
                            section == _selected || _leaving.contains(section),
                        child: ExcludeFocus(
                          excluding: section != _selected,
                          child: ExcludeSemantics(
                            excluding: section != _selected,
                            child: IgnorePointer(
                              ignoring: section != _selected,
                              child: AnimatedOpacity(
                                opacity: section == _selected ? 1 : 0,
                                duration: _reduceMotion
                                    ? Duration.zero
                                    : const Duration(milliseconds: 160),
                                curve: Curves.easeOutCubic,
                                onEnd: () {
                                  AppLog.instance.trace(
                                    "lib/pages/player_content_layout.dart::_PlayerSideContentState.build.closure#1.closure#1",
                                  );
                                  _finishTransition(section);
                                },
                                child: RepaintBoundary(
                                  key: ValueKey('${section}RightPane'),
                                  child:
                                      _panes[section] ??
                                      const SizedBox.shrink(),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}
