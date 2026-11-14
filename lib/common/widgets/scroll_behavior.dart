// Adapted from PiliPlus lib/common/widgets/scroll_behavior.dart, commit
// d9e9626f1a3f89cd9ca85e18f61aaba02634e12a (GNU GPL v3).
// Source: https://github.com/bggRGjQaUbCoE/PiliPlus
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';

import "../../services/app_log.dart";
import 'app_scrollbar.dart';

const Set<PointerDeviceKind> desktopDragDevices = {
  PointerDeviceKind.touch,
  PointerDeviceKind.mouse,
  PointerDeviceKind.trackpad,
  PointerDeviceKind.stylus,
  PointerDeviceKind.invertedStylus,
  PointerDeviceKind.unknown,
};

class CustomScrollBehavior extends MaterialScrollBehavior {
  const CustomScrollBehavior();

  @override
  Widget buildScrollbar(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) {
    AppLog.instance.trace(
      "lib/common/widgets/scroll_behavior.dart::CustomScrollBehavior.buildScrollbar",
    );

    if (axisDirectionToAxis(details.direction) == Axis.horizontal) return child;
    final scrollbar = context.findAncestorStateOfType<RawScrollbarState>();
    // A primary ScrollView inserts PrimaryScrollController.none below itself.
    // Resolve at the explicit scrollbar, before that boundary, to avoid twins.
    final controller =
        scrollbar?.widget.controller ??
        (scrollbar == null
            ? null
            : PrimaryScrollController.maybeOf(scrollbar.context));
    if (scrollbar != null && controller == details.controller) {
      return child;
    }
    return switch (getPlatform(context)) {
      TargetPlatform.windows || TargetPlatform.linux || TargetPlatform.macOS =>
        AppScrollbar(controller: details.controller, child: child),
      TargetPlatform.android ||
      TargetPlatform.iOS ||
      TargetPlatform.fuchsia => child,
    };
  }

  @override
  Widget buildOverscrollIndicator(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) {
    AppLog.instance.trace(
      "lib/common/widgets/scroll_behavior.dart::CustomScrollBehavior.buildOverscrollIndicator",
    );

    if (getPlatform(context) == TargetPlatform.android &&
        !MediaQuery.disableAnimationsOf(context)) {
      return StretchingOverscrollIndicator(
        axisDirection: details.direction,
        clipBehavior: details.decorationClipBehavior ?? Clip.hardEdge,
        child: child,
      );
    }
    return child;
  }

  @override
  Set<PointerDeviceKind> get dragDevices {
    AppLog.instance.trace(
      "lib/common/widgets/scroll_behavior.dart::CustomScrollBehavior.dragDevices.get",
    );
    return desktopDragDevices;
  }
}
