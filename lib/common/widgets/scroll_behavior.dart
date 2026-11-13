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

  // Keep Material's desktop scrollbar rather than suppressing it upstream.
  @override
  Widget buildOverscrollIndicator(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) {
    AppLog.instance.trace(
      "lib/common/widgets/scroll_behavior.dart::CustomScrollBehavior.buildOverscrollIndicator",
    );

    if (getPlatform(context) == TargetPlatform.android) {
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
