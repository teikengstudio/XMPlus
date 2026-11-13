import 'package:flutter/material.dart';

import "../../services/app_log.dart";

/// A quiet tab with a fixed label footprint and a short selection indicator.
class AppTabButton extends StatelessWidget {
  const AppTabButton({
    required this.label,
    required this.selected,
    required this.onPressed,
    this.icon,
    super.key,
  });

  final String label;
  final bool selected;
  final VoidCallback? onPressed;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    AppLog.instance.trace(
      "lib/common/widgets/app_tab_button.dart::AppTabButton.build",
    );

    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 180);
    return Semantics(
      selected: selected,
      inMutuallyExclusiveGroup: true,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 240),
        child: TextButton(
          onPressed: onPressed,
          style: TextButton.styleFrom(
            minimumSize: const Size(48, 48),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            foregroundColor: selected
                ? colors.primary
                : colors.onSurfaceVariant,
            textStyle: theme.textTheme.labelLarge?.copyWith(
              fontSize: 14,
              fontWeight: FontWeight.w500,
            ),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
          ).copyWith(animationDuration: duration),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (icon != null) ...[
                    Icon(icon, size: 18),
                    const SizedBox(width: 8),
                  ],
                  Flexible(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              SizedBox(
                width: 22,
                height: 3,
                child: AnimatedOpacity(
                  opacity: selected ? 1 : 0,
                  duration: duration,
                  curve: Curves.easeOutCubic,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: onPressed == null
                          ? colors.onSurface.withValues(alpha: .38)
                          : colors.primary,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Keeps category rows at one height and makes overflow visible on desktop.
class AppTabStrip extends StatefulWidget {
  const AppTabStrip({required this.children, super.key});

  final List<Widget> children;

  @override
  State<AppTabStrip> createState() {
    AppLog.instance.trace(
      "lib/common/widgets/app_tab_button.dart::AppTabStrip.createState",
    );
    return _AppTabStripState();
  }
}

class _AppTabStripState extends State<AppTabStrip> {
  final _scroll = ScrollController();

  @override
  void dispose() {
    AppLog.instance.trace(
      "lib/common/widgets/app_tab_button.dart::_AppTabStripState.dispose",
    );

    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    AppLog.instance.trace(
      "lib/common/widgets/app_tab_button.dart::_AppTabStripState.build",
    );
    return ScrollConfiguration(
      behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
      child: Scrollbar(
        controller: _scroll,
        thumbVisibility: true,
        interactive: true,
        scrollbarOrientation: ScrollbarOrientation.bottom,
        thickness: 3,
        radius: const Radius.circular(3),
        child: SingleChildScrollView(
          controller: _scroll,
          primary: false,
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.only(bottom: 8),
          child: Row(mainAxisSize: MainAxisSize.min, children: widget.children),
        ),
      ),
    );
  }
}
