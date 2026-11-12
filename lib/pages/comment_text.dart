import 'package:flutter/material.dart';

import '../api/xmly_comment_emojis.dart';
import "../services/app_log.dart";

/// Official bracketed expressions are images; other bracketed text stays intact.
class CommentText extends StatelessWidget {
  const CommentText(this.text, {this.style, super.key});

  final String text;
  final TextStyle? style;
  static final _expression = RegExp(r'\[([^\[\]\r\n]{1,16})\]');

  @override
  Widget build(BuildContext context) {
    AppLog.instance.trace("lib/pages/comment_text.dart::CommentText.build");

    final spans = <InlineSpan>[];
    var start = 0;
    for (final match in _expression.allMatches(text)) {
      final filename = xmlyCommentEmojis[match[1]];
      if (filename == null) continue;
      if (match.start > start) {
        spans.add(TextSpan(text: text.substring(start, match.start)));
      }
      final label = match[0]!;
      spans.add(
        WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 1),
            child: Tooltip(
              message: label,
              excludeFromSemantics: true,
              child: Image.network(
                'https://s1.xmcdn.com/css/img/face/$filename',
                width: 22,
                height: 22,
                fit: BoxFit.contain,
                semanticLabel: label,
                errorBuilder: (context, error, stack) {
                  AppLog.instance.trace(
                    "lib/pages/comment_text.dart::CommentText.build.closure#1",
                  );
                  return Text(
                    label,
                    style: style,
                    textScaler: TextScaler.noScaling,
                  );
                },
              ),
            ),
          ),
        ),
      );
      start = match.end;
    }
    if (spans.isEmpty) return SelectableText(text, style: style);
    if (start < text.length) spans.add(TextSpan(text: text.substring(start)));
    return SelectionArea(
      child: Text.rich(TextSpan(children: spans), style: style),
    );
  }
}
