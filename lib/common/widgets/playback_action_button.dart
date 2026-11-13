import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../services/app_log.dart';

class PlaybackActionButton extends StatelessWidget {
  const PlaybackActionButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onPressed,
    this.tooltip,
    this.size = 64,
    this.emphasized = false,
    this.showLabel = true,
  });

  final Widget icon;
  final String label;
  final VoidCallback? onPressed;
  final String? tooltip;
  final double size;
  final bool emphasized;
  final bool showLabel;

  @override
  Widget build(BuildContext context) {
    AppLog.instance.trace(
      'lib/common/widgets/playback_action_button.dart::PlaybackActionButton.build',
    );

    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final textStyle =
        theme.textTheme.labelMedium ?? const TextStyle(fontSize: 12);
    final fontSize = textStyle.fontSize ?? 12;
    final iconSize = 20 + (size - 48) / 4;
    final extent = math.max(
      48.0,
      showLabel
          ? size *
                math.max(
                  1.0,
                  MediaQuery.textScalerOf(context).scale(fontSize) / fontSize,
                )
          : size,
    );
    final iconWidget = IconTheme.merge(
      data: IconThemeData(size: iconSize),
      child: icon,
    );

    return Tooltip(
      message: tooltip ?? label,
      child: SizedBox.square(
        dimension: extent,
        child: TextButton(
          onPressed: onPressed,
          style: TextButton.styleFrom(
            foregroundColor: emphasized
                ? colors.onPrimaryContainer
                : colors.onSurfaceVariant,
            backgroundColor: emphasized ? colors.primaryContainer : null,
            disabledBackgroundColor: emphasized
                ? colors.onSurface.withValues(alpha: 0.12)
                : null,
            padding: const EdgeInsets.all(4),
            minimumSize: Size.zero,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            textStyle: textStyle,
            shape: showLabel
                ? RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  )
                : const CircleBorder(),
          ),
          child: showLabel
              ? Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    iconWidget,
                    const SizedBox(height: 2),
                    Flexible(
                      child: Text(
                        label,
                        textAlign: TextAlign.center,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                )
              : Semantics(label: label, child: iconWidget),
        ),
      ),
    );
  }
}
