import 'dart:math' as math;

import 'package:flutter/material.dart';

import "../../services/app_log.dart";

/// Keeps short player tasks over the current page on both phones and desktops.
Future<T?> showLocalPanel<T>({
  required BuildContext context,
  required String title,
  required WidgetBuilder builder,
  double width = 480,
  double height = 680,
  bool showHeader = true,
}) {
  AppLog.instance.trace("lib/common/widgets/local_panel.dart::showLocalPanel");

  Widget frame(BuildContext context) {
    AppLog.instance.trace(
      "lib/common/widgets/local_panel.dart::showLocalPanel.frame",
    );
    return Material(
      color: Theme.of(context).colorScheme.surface,
      clipBehavior: Clip.antiAlias,
      borderRadius: BorderRadius.circular(20),
      child: Column(
        children: [
          if (showHeader) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 8, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      title,
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  IconButton(
                    tooltip: '收起$title',
                    onPressed: () {
                      AppLog.instance.trace(
                        "lib/common/widgets/local_panel.dart::showLocalPanel.frame.closure#1",
                      );
                      Navigator.of(context).maybePop();
                    },
                    icon: Icon(
                      MediaQuery.sizeOf(context).width >= 700
                          ? Icons.close_rounded
                          : Icons.keyboard_arrow_down_rounded,
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
          ],
          Expanded(child: builder(context)),
        ],
      ),
    );
  }

  if (MediaQuery.sizeOf(context).width >= 700) {
    return showDialog<T>(
      context: context,
      barrierColor: Theme.of(context).colorScheme.scrim.withValues(alpha: 0.16),
      builder: (context) {
        AppLog.instance.trace(
          "lib/common/widgets/local_panel.dart::showLocalPanel.closure#1",
        );
        return Dialog(
          alignment: Alignment.centerRight,
          insetPadding: const EdgeInsets.fromLTRB(24, 64, 20, 24),
          elevation: 8,
          shadowColor: Colors.black.withValues(alpha: 0.18),
          surfaceTintColor: Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          clipBehavior: Clip.antiAlias,
          constraints: BoxConstraints(maxWidth: width),
          child: SizedBox(width: width, height: height, child: frame(context)),
        );
      },
    );
  }
  return showModalBottomSheet<T>(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    // Drag dismissal calls pop directly and bypasses forms' saving PopScopes.
    enableDrag: false,
    useSafeArea: true,
    builder: (context) {
      AppLog.instance.trace(
        "lib/common/widgets/local_panel.dart::showLocalPanel.closure#2",
      );
      return Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: LayoutBuilder(
          builder: (context, constraints) {
            AppLog.instance.trace(
              "lib/common/widgets/local_panel.dart::showLocalPanel.closure#2.closure#1",
            );
            return SizedBox(
              height: math.min(height, constraints.maxHeight * 0.9),
              child: frame(context),
            );
          },
        ),
      );
    },
  );
}
