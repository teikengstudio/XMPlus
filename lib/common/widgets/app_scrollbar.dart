import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../services/app_log.dart';

/// A quiet scrollbar with a bounded thumb and Flutter's native interactions.
class AppScrollbar extends RawScrollbar {
  const AppScrollbar({
    super.key,
    required super.child,
    super.controller,
    super.thumbVisibility,
    super.trackVisibility,
    super.thickness,
    super.radius,
    super.padding,
    super.interactive,
    super.scrollbarOrientation,
    ScrollNotificationPredicate? notificationPredicate,
    this.maxThumbLength = 80,
  }) : assert(maxThumbLength > 0 && maxThumbLength < double.infinity),
       super(
         minThumbLength: 28,
         minOverscrollLength: 18,
         mainAxisMargin: 4,
         crossAxisMargin: 3,
         pressDuration: Duration.zero,
         fadeDuration: const Duration(milliseconds: 180),
         timeToFade: const Duration(milliseconds: 700),
         notificationPredicate:
             notificationPredicate ?? defaultScrollNotificationPredicate,
       );

  final double maxThumbLength;

  @override
  RawScrollbarState<AppScrollbar> createState() {
    AppLog.instance.trace(
      "lib/common/widgets/app_scrollbar.dart::AppScrollbar.createState",
    );
    return _AppScrollbarState();
  }
}

class _AppScrollbarState extends RawScrollbarState<AppScrollbar> {
  _CappedScrollbarPainter? _cappedPainter;
  late ScrollbarThemeData _theme;
  late ColorScheme _colors;
  bool _hovered = false;
  bool _dragged = false;
  bool _highContrast = false;

  @override
  ScrollbarPainter get scrollbarPainter {
    AppLog.instance.trace(
      "lib/common/widgets/app_scrollbar.dart::_AppScrollbarState.scrollbarPainter.get",
    );
    return _cappedPainter ?? super.scrollbarPainter;
  }

  Set<WidgetState> get _states {
    AppLog.instance.trace(
      "lib/common/widgets/app_scrollbar.dart::_AppScrollbarState._states.get",
    );
    return {
      if (_hovered) WidgetState.hovered,
      if (_dragged) WidgetState.dragged,
    };
  }

  @override
  bool get showScrollbar {
    AppLog.instance.trace(
      "lib/common/widgets/app_scrollbar.dart::_AppScrollbarState.showScrollbar.get",
    );
    return widget.thumbVisibility ??
        _theme.thumbVisibility?.resolve(_states) ??
        false;
  }

  @override
  bool get enableGestures {
    AppLog.instance.trace(
      "lib/common/widgets/app_scrollbar.dart::_AppScrollbarState.enableGestures.get",
    );
    return widget.interactive ?? _theme.interactive ?? true;
  }

  @override
  void initState() {
    AppLog.instance.trace(
      "lib/common/widgets/app_scrollbar.dart::_AppScrollbarState.initState",
    );

    super.initState();
    // RawScrollbar owns the fade controller and all gestures. Replace only its
    // painter, sharing the animation and releasing the original listener.
    final original = super.scrollbarPainter;
    _cappedPainter = _CappedScrollbarPainter(
      color: original.color,
      fadeoutOpacityAnimation: original.fadeoutOpacityAnimation,
      maxThumbLength: widget.maxThumbLength,
    );
    original.dispose();
  }

  @override
  void didChangeDependencies() {
    AppLog.instance.trace(
      "lib/common/widgets/app_scrollbar.dart::_AppScrollbarState.didChangeDependencies",
    );

    _theme = ScrollbarTheme.of(context);
    _colors = Theme.of(context).colorScheme;
    _highContrast = MediaQuery.highContrastOf(context);
    super.didChangeDependencies();
  }

  @override
  void updateScrollbarPainter() {
    AppLog.instance.trace(
      "lib/common/widgets/app_scrollbar.dart::_AppScrollbarState.updateScrollbarPainter",
    );

    final states = _states;
    final active = _hovered || _dragged;
    var color =
        _theme.thumbColor?.resolve(states) ??
        _colors.onSurfaceVariant.withValues(
          alpha: _dragged ? .48 : (_hovered ? .32 : .18),
        );
    if (_highContrast) color = color.withValues(alpha: math.max(.7, color.a));
    final trackVisible =
        showScrollbar &&
        (widget.trackVisibility ??
            _theme.trackVisibility?.resolve(states) ??
            false);
    final direction = Directionality.of(context);
    final minLength = math.min(
      _theme.minThumbLength ?? widget.minThumbLength,
      widget.maxThumbLength,
    );
    scrollbarPainter
      ..color = color
      ..trackColor = trackVisible
          ? _theme.trackColor?.resolve(states) ??
                _colors.onSurface.withValues(alpha: .04)
          : Colors.transparent
      ..trackBorderColor = trackVisible
          ? _theme.trackBorderColor?.resolve(states) ?? Colors.transparent
          : Colors.transparent
      ..textDirection = direction
      ..thickness =
          widget.thickness ??
          _theme.thickness?.resolve(states) ??
          (active ? 4 : 2.5)
      ..radius = widget.radius ?? _theme.radius ?? const Radius.circular(6)
      ..padding = (widget.padding ?? MediaQuery.paddingOf(context)).resolve(
        direction,
      )
      ..scrollbarOrientation = widget.scrollbarOrientation
      ..mainAxisMargin = _theme.mainAxisMargin ?? widget.mainAxisMargin
      ..crossAxisMargin = _theme.crossAxisMargin ?? widget.crossAxisMargin
      ..minLength = minLength
      ..minOverscrollLength = math.min(18, minLength)
      ..ignorePointer = !enableGestures;
    _cappedPainter!
      ..maxThumbLength = widget.maxThumbLength
      ..refreshMetrics();
  }

  @override
  void handleThumbPressStart(Offset localPosition) {
    AppLog.instance.trace(
      "lib/common/widgets/app_scrollbar.dart::_AppScrollbarState.handleThumbPressStart",
    );

    super.handleThumbPressStart(localPosition);
    setState(() {
      AppLog.instance.trace(
        "lib/common/widgets/app_scrollbar.dart::_AppScrollbarState.handleThumbPressStart.closure#1",
      );
      _dragged = true;
    });
  }

  @override
  void handleThumbPressEnd(Offset localPosition, Velocity velocity) {
    AppLog.instance.trace(
      "lib/common/widgets/app_scrollbar.dart::_AppScrollbarState.handleThumbPressEnd",
    );

    setState(() {
      AppLog.instance.trace(
        "lib/common/widgets/app_scrollbar.dart::_AppScrollbarState.handleThumbPressEnd.closure#1",
      );
      _dragged = false;
    });
    super.handleThumbPressEnd(localPosition, velocity);
  }

  @override
  void handleHover(PointerHoverEvent event) {
    AppLog.instance.trace(
      "lib/common/widgets/app_scrollbar.dart::_AppScrollbarState.handleHover",
    );

    final hovered = isPointerOverScrollbar(
      event.position,
      event.kind,
      forHover: true,
    );
    if (hovered != _hovered)
      setState(() {
        AppLog.instance.trace(
          "lib/common/widgets/app_scrollbar.dart::_AppScrollbarState.handleHover.closure#1",
        );
        _hovered = hovered;
      });
    super.handleHover(event);
  }

  @override
  void handleHoverExit(PointerExitEvent event) {
    AppLog.instance.trace(
      "lib/common/widgets/app_scrollbar.dart::_AppScrollbarState.handleHoverExit",
    );

    if (_hovered)
      setState(() {
        AppLog.instance.trace(
          "lib/common/widgets/app_scrollbar.dart::_AppScrollbarState.handleHoverExit.closure#1",
        );
        _hovered = false;
      });
    super.handleHoverExit(event);
  }
}

class _CappedScrollbarPainter extends ScrollbarPainter {
  _CappedScrollbarPainter({
    required super.color,
    required super.fadeoutOpacityAnimation,
    required this.maxThumbLength,
  }) {
    AppLog.instance.trace(
      "lib/common/widgets/app_scrollbar.dart::_CappedScrollbarPainter.new",
    );
  }

  double maxThumbLength;
  ScrollMetrics? _metrics;
  AxisDirection? _direction;
  Size? _paintSize;
  double _extentScale = 1;

  @override
  void update(ScrollMetrics metrics, AxisDirection axisDirection) {
    AppLog.instance.trace(
      "lib/common/widgets/app_scrollbar.dart::_CappedScrollbarPainter.update",
    );

    _metrics = metrics.copyWith();
    _direction = axisDirection;
    refreshMetrics();
  }

  void refreshMetrics() {
    AppLog.instance.trace(
      "lib/common/widgets/app_scrollbar.dart::_CappedScrollbarPainter.refreshMetrics",
    );

    final metrics = _metrics;
    final direction = _direction;
    if (metrics == null || direction == null) return;
    _extentScale = 1;
    final extent = metrics.maxScrollExtent - metrics.minScrollExtent;
    final resolvedPadding = padding.resolve(textDirection);
    final mainPadding = axisDirectionToAxis(direction) == Axis.vertical
        ? resolvedPadding.vertical
        : resolvedPadding.horizontal;
    final viewport = metrics.viewportDimension - mainPadding;
    final track = viewport - 2 * mainAxisMargin;
    // Increase only the painter's content range to cap its proportional thumb.
    // Keeping min/max/pixels on the same scale preserves reverse directions,
    // centered scroll views with negative extents, and RawScrollbar drag starts.
    final cappedExtent = viewport * (track / maxThumbLength - 1);
    if (extent > 0 &&
        extent.isFinite &&
        cappedExtent.isFinite &&
        cappedExtent > extent &&
        metrics.pixels.isFinite &&
        metrics.minScrollExtent.isFinite &&
        metrics.maxScrollExtent.isFinite) {
      final scale = cappedExtent / extent;
      final minimum = metrics.minScrollExtent * scale;
      final maximum = metrics.maxScrollExtent * scale;
      final clamped = metrics.pixels.clamp(
        metrics.minScrollExtent,
        metrics.maxScrollExtent,
      );
      // Keep elastic overscroll in physical pixels instead of amplifying it.
      final pixels = clamped * scale + (metrics.pixels - clamped);
      if (scale.isFinite &&
          minimum.isFinite &&
          maximum.isFinite &&
          pixels.isFinite) {
        _extentScale = scale;
        super.update(
          metrics.copyWith(
            minScrollExtent: minimum,
            maxScrollExtent: maximum,
            pixels: pixels,
          ),
          direction,
        );
        return;
      }
    }
    super.update(metrics, direction);
  }

  @override
  double getTrackToScroll(double thumbOffsetLocal) {
    AppLog.instance.trace(
      "lib/common/widgets/app_scrollbar.dart::_CappedScrollbarPainter.getTrackToScroll",
    );
    return super.getTrackToScroll(thumbOffsetLocal) / _extentScale;
  }

  @override
  void paint(Canvas canvas, Size size) {
    AppLog.instance.trace(
      "lib/common/widgets/app_scrollbar.dart::_CappedScrollbarPainter.paint",
    );

    _paintSize = size;
    super.paint(canvas, size);
  }

  // Widen the invisible hit region across the track without changing its
  // painted size or its main-axis bounds. Flutter still decides whether the
  // projected point hits the thumb or track and preserves touch hit padding.
  Offset? _projectToTrack(Offset position, {double minWidth = 12}) {
    AppLog.instance.trace(
      "lib/common/widgets/app_scrollbar.dart::_CappedScrollbarPainter._projectToTrack",
    );

    final size = _paintSize;
    final direction = _direction;
    if (size == null || direction == null) return null;
    final vertical = axisDirectionToAxis(direction) == Axis.vertical;
    final orientation =
        scrollbarOrientation ??
        (vertical
            ? textDirection == TextDirection.rtl
                  ? ScrollbarOrientation.left
                  : ScrollbarOrientation.right
            : ScrollbarOrientation.bottom);
    final insets = padding.resolve(textDirection);
    final center = switch (orientation) {
      ScrollbarOrientation.left =>
        insets.left + crossAxisMargin + thickness / 2,
      ScrollbarOrientation.right =>
        size.width - insets.right - crossAxisMargin - thickness / 2,
      ScrollbarOrientation.top => insets.top + crossAxisMargin + thickness / 2,
      ScrollbarOrientation.bottom =>
        size.height - insets.bottom - crossAxisMargin - thickness / 2,
    };
    final crossPosition = vertical ? position.dx : position.dy;
    if ((crossPosition - center).abs() > math.max(thickness, minWidth) / 2) {
      return null;
    }
    return vertical ? Offset(center, position.dy) : Offset(position.dx, center);
  }

  @override
  bool? hitTest(Offset? position) {
    AppLog.instance.trace(
      "lib/common/widgets/app_scrollbar.dart::_CappedScrollbarPainter.hitTest",
    );

    if (position == null) return super.hitTest(position);
    return super.hitTest(_projectToTrack(position) ?? position);
  }

  @override
  bool hitTestInteractive(
    Offset position,
    PointerDeviceKind kind, {
    bool forHover = false,
  }) {
    AppLog.instance.trace(
      "lib/common/widgets/app_scrollbar.dart::_CappedScrollbarPainter.hitTestInteractive",
    );

    if (super.hitTestInteractive(position, kind, forHover: forHover))
      return true;
    final projected = _projectToTrack(position, minWidth: forHover ? 48 : 12);
    return projected != null &&
        super.hitTestInteractive(projected, kind, forHover: forHover);
  }

  @override
  bool hitTestOnlyThumbInteractive(Offset position, PointerDeviceKind kind) {
    AppLog.instance.trace(
      "lib/common/widgets/app_scrollbar.dart::_CappedScrollbarPainter.hitTestOnlyThumbInteractive",
    );

    if (super.hitTestOnlyThumbInteractive(position, kind)) return true;
    final projected = _projectToTrack(position);
    return projected != null &&
        super.hitTestOnlyThumbInteractive(projected, kind);
  }
}
