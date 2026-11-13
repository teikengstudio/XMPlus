import 'package:flutter/material.dart';

import "../../services/app_log.dart";

/// Fits one-line metadata without shrinking below the chosen readable scale.
class AdaptiveText extends StatelessWidget {
  const AdaptiveText(
    this.text, {
    super.key,
    this.style,
    this.minimumScale = 0.85,
  });

  final String text;
  final TextStyle? style;
  final double minimumScale;

  @override
  Widget build(BuildContext context) {
    AppLog.instance.trace(
      "lib/common/widgets/adaptive_text.dart::AdaptiveText.build",
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        AppLog.instance.trace(
          "lib/common/widgets/adaptive_text.dart::AdaptiveText.build.closure#1",
        );
        return FittedBox(
          fit: BoxFit.scaleDown,
          alignment: AlignmentDirectional.centerStart,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: constraints.maxWidth / minimumScale,
            ),
            child: Text(
              text,
              style: style,
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        );
      },
    );
  }
}
