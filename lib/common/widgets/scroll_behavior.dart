// Adapted from PiliPlus lib/common/widgets/scroll_behavior.dart, commit
// d9e9626f1a3f89cd9ca85e18f61aaba02634e12a (GNU GPL v3).
// Source: https://github.com/bggRGjQaUbCoE/PiliPlus
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';

import "../../services/app_log.dart";

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

    final material = context.findAncestorWidgetOfExactType<Scrollbar>();
    final raw = context.findAncestorWidgetOfExactType<RawScrollbar>();
    final controller = material != null ? material.controller : raw?.controller;
    if ((material != null || raw != null) &&
        (controller == details.controller ||
            controller == null &&
                details.controller ==
                    PrimaryScrollController.maybeOf(context))) {
      return child;
    }
    return super.buildScrollbar(context, child, details);
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
