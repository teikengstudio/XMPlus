import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import "../services/app_log.dart";

/// An inline draft: only Apply changes the application's saved theme.
class ThemeColorEditor extends StatefulWidget {
  const ThemeColorEditor({
    required this.initialColor,
    required this.onApply,
    required this.onCancel,
    this.oledBlack = false,
    super.key,
  });

  final Color initialColor;
  final ValueChanged<Color> onApply;
  final VoidCallback onCancel;
  final bool oledBlack;

  @override
  State<ThemeColorEditor> createState() {
    AppLog.instance.trace(
      "lib/pages/theme_color_editor.dart::ThemeColorEditor.createState",
    );
    return _ThemeColorEditorState();
  }
}

class _ThemeColorEditorState extends State<ThemeColorEditor> {
  late HSVColor _hsv;
  late final TextEditingController _hex;
  final _planeFocus = FocusNode();
  bool _validHex = true;
  bool _planeFocused = false;

  Color get _color {
    AppLog.instance.trace(
      "lib/pages/theme_color_editor.dart::_ThemeColorEditorState._color.get",
    );
    return _hsv.toColor();
  }

  String get _hexValue {
    AppLog.instance.trace(
      "lib/pages/theme_color_editor.dart::_ThemeColorEditorState._hexValue.get",
    );
    return '#${(_color.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';
  }

  @override
  void initState() {
    AppLog.instance.trace(
      "lib/pages/theme_color_editor.dart::_ThemeColorEditorState.initState",
    );

    super.initState();
    _hsv = HSVColor.fromColor(widget.initialColor.withValues(alpha: 1));
    _hex = TextEditingController(text: _hexValue);
  }

  @override
  void dispose() {
    AppLog.instance.trace(
      "lib/pages/theme_color_editor.dart::_ThemeColorEditorState.dispose",
    );

    _hex.dispose();
    _planeFocus.dispose();
    super.dispose();
  }

  void _setColor(HSVColor color) {
    AppLog.instance.trace(
      "lib/pages/theme_color_editor.dart::_ThemeColorEditorState._setColor",
    );

    setState(() {
      AppLog.instance.trace(
        "lib/pages/theme_color_editor.dart::_ThemeColorEditorState._setColor.closure#1",
      );

      _hsv = color;
      _validHex = true;
      _hex.value = TextEditingValue(
        text: _hexValue,
        selection: TextSelection.collapsed(offset: _hexValue.length),
      );
    });
  }

  void _readHex(String value) {
    AppLog.instance.trace(
      "lib/pages/theme_color_editor.dart::_ThemeColorEditorState._readHex",
    );

    final match = RegExp(r'^#?([a-fA-F0-9]{3}|[a-fA-F0-9]{6})$')
        .firstMatch(value.trim());
    setState(() {
      AppLog.instance.trace(
        "lib/pages/theme_color_editor.dart::_ThemeColorEditorState._readHex.closure#1",
      );

      _validHex = match != null;
      if (match == null) return;
      var digits = match[1]!;
      if (digits.length == 3) {
        digits = digits.split('').map((digit) {
          AppLog.instance.trace(
            "lib/pages/theme_color_editor.dart::_ThemeColorEditorState._readHex.closure#1.closure#1",
          );
          return '$digit$digit';
        }).join();
      }
      _hsv = HSVColor.fromColor(
        Color(0xFF000000 | int.parse(digits, radix: 16)),
      );
    });
  }

  KeyEventResult _onPlaneKey(FocusNode node, KeyEvent event) {
    AppLog.instance.trace(
      "lib/pages/theme_color_editor.dart::_ThemeColorEditorState._onPlaneKey",
    );

    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final adjustment = switch (event.logicalKey) {
      LogicalKeyboardKey.arrowLeft => const Offset(-0.01, 0),
      LogicalKeyboardKey.arrowRight => const Offset(0.01, 0),
      LogicalKeyboardKey.arrowUp => const Offset(0, 0.01),
      LogicalKeyboardKey.arrowDown => const Offset(0, -0.01),
      _ => null,
    };
    if (adjustment == null) return KeyEventResult.ignored;
    _setColor(
      _hsv
          .withSaturation((_hsv.saturation + adjustment.dx).clamp(0.0, 1.0))
          .withValue((_hsv.value + adjustment.dy).clamp(0.0, 1.0)),
    );
    return KeyEventResult.handled;
  }

  Widget _colorPlane() {
    AppLog.instance.trace(
      "lib/pages/theme_color_editor.dart::_ThemeColorEditorState._colorPlane",
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        AppLog.instance.trace(
          "lib/pages/theme_color_editor.dart::_ThemeColorEditorState._colorPlane.closure#1",
        );

        const height = 160.0;
        void select(Offset position) {
          AppLog.instance.trace(
            "lib/pages/theme_color_editor.dart::_ThemeColorEditorState._colorPlane.closure#1.select",
          );

          _planeFocus.requestFocus();
          _setColor(
            _hsv
                .withSaturation(
                  (position.dx / constraints.maxWidth).clamp(0.0, 1.0),
                )
                .withValue((1 - position.dy / height).clamp(0.0, 1.0)),
          );
        }

        return Semantics(
          label: '饱和度和明度',
          value:
              '${(_hsv.saturation * 100).round()}%，${(_hsv.value * 100).round()}%',
          hint: '使用左右方向键调整饱和度，上下方向键调整明度，也可输入色值',
          child: Focus(
            focusNode: _planeFocus,
            onKeyEvent: _onPlaneKey,
            onFocusChange: (value) {
              AppLog.instance.trace(
                "lib/pages/theme_color_editor.dart::_ThemeColorEditorState._colorPlane.closure#1.closure#1",
              );
              setState(() {
                AppLog.instance.trace(
                  "lib/pages/theme_color_editor.dart::_ThemeColorEditorState._colorPlane.closure#1.closure#1.closure#1",
                );
                _planeFocused = value;
              });
            },
            child: MouseRegion(
              cursor: SystemMouseCursors.precise,
              child: GestureDetector(
                key: const ValueKey('themeSaturationValue'),
                behavior: HitTestBehavior.opaque,
                onTapDown: (event) {
                  AppLog.instance.trace(
                    "lib/pages/theme_color_editor.dart::_ThemeColorEditorState._colorPlane.closure#1.closure#2",
                  );
                  select(event.localPosition);
                },
                onPanDown: (event) {
                  AppLog.instance.trace(
                    "lib/pages/theme_color_editor.dart::_ThemeColorEditorState._colorPlane.closure#1.closure#3",
                  );
                  select(event.localPosition);
                },
                onPanUpdate: (event) {
                  AppLog.instance.trace(
                    "lib/pages/theme_color_editor.dart::_ThemeColorEditorState._colorPlane.closure#1.closure#4",
                  );
                  select(event.localPosition);
                },
                child: CustomPaint(
                  size: Size(constraints.maxWidth, height),
                  painter: _ColorPlanePainter(_hsv, _planeFocused),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    AppLog.instance.trace(
      "lib/pages/theme_color_editor.dart::_ThemeColorEditorState.build",
    );

    final theme = Theme.of(context);
    final controls = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _colorPlane(),
        const SizedBox(height: 12),
        Row(
          children: [
            const Text('色相'),
            const SizedBox(width: 12),
            Expanded(
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  activeTrackColor: Colors.transparent,
                  inactiveTrackColor: Colors.transparent,
                  thumbColor: HSVColor.fromAHSV(1, _hsv.hue, 1, 1).toColor(),
                  overlayColor: _color.withValues(alpha: 0.12),
                ),
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 24),
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.all(Radius.circular(6)),
                          gradient: LinearGradient(
                            colors: [
                              Color(0xFFFF0000),
                              Color(0xFFFFFF00),
                              Color(0xFF00FF00),
                              Color(0xFF00FFFF),
                              Color(0xFF0000FF),
                              Color(0xFFFF00FF),
                              Color(0xFFFF0000),
                            ],
                          ),
                        ),
                        child: SizedBox(height: 8, width: double.infinity),
                      ),
                    ),
                    Slider(
                      key: const ValueKey('themeHueSlider'),
                      value: _hsv.hue,
                      min: 0,
                      max: 360,
                      semanticFormatterCallback: (value) {
                        AppLog.instance.trace(
                          "lib/pages/theme_color_editor.dart::_ThemeColorEditorState.build.closure#1",
                        );
                        return '色相 ${value.round()} 度';
                      },
                      onChanged: (value) {
                        AppLog.instance.trace(
                          "lib/pages/theme_color_editor.dart::_ThemeColorEditorState.build.closure#2",
                        );
                        _setColor(_hsv.withHue(value));
                      },
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        TextField(
          key: const ValueKey('themeHexInput'),
          controller: _hex,
          autocorrect: false,
          enableSuggestions: false,
          textCapitalization: TextCapitalization.characters,
          decoration: InputDecoration(
            labelText: '色值（HEX）',
            helperText: '支持 #RGB 或 #RRGGBB',
            errorText: _validHex ? null : '请输入 3 位或 6 位十六进制色值',
            errorMaxLines: 2,
            prefixIcon: Padding(
              padding: const EdgeInsets.all(14),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: _color,
                  shape: BoxShape.circle,
                  border: Border.all(color: theme.colorScheme.outlineVariant),
                ),
                child: const SizedBox(width: 20, height: 20),
              ),
            ),
          ),
          onChanged: _readHex,
        ),
      ],
    );
    final previews = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _ColorPreview(seed: _color, brightness: Brightness.light),
        const SizedBox(height: 12),
        _ColorPreview(
          seed: _color,
          brightness: Brightness.dark,
          oledBlack: widget.oledBlack,
        ),
      ],
    );
    return Column(
      key: const ValueKey('themeColorEditor'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LayoutBuilder(
          builder: (context, constraints) {
            AppLog.instance.trace(
              "lib/pages/theme_color_editor.dart::_ThemeColorEditorState.build.closure#3",
            );

            if (constraints.maxWidth >= 560) {
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(flex: 3, child: controls),
                  const SizedBox(width: 24),
                  Expanded(flex: 2, child: previews),
                ],
              );
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [controls, const SizedBox(height: 16), previews],
            );
          },
        ),
        const SizedBox(height: 16),
        Wrap(
          alignment: WrapAlignment.end,
          spacing: 8,
          runSpacing: 8,
          children: [
            TextButton(
              key: const ValueKey('themeColorCancel'),
              onPressed: widget.onCancel,
              child: const Text('取消'),
            ),
            FilledButton(
              key: const ValueKey('themeColorApply'),
              onPressed: _validHex
                  ? () {
                      AppLog.instance.trace(
                        "lib/pages/theme_color_editor.dart::_ThemeColorEditorState.build.closure#4",
                      );
                      widget.onApply(_color);
                    }
                  : null,
              child: const Text('应用主题色'),
            ),
          ],
        ),
      ],
    );
  }
}

class _ColorPlanePainter extends CustomPainter {
  const _ColorPlanePainter(this.color, this.focused);

  final HSVColor color;
  final bool focused;

  @override
  void paint(Canvas canvas, Size size) {
    AppLog.instance.trace(
      "lib/pages/theme_color_editor.dart::_ColorPlanePainter.paint",
    );

    final rect = Offset.zero & size;
    final shape = RRect.fromRectAndRadius(rect, const Radius.circular(12));
    canvas.save();
    canvas.clipRRect(shape);
    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          colors: [
            Colors.white,
            HSVColor.fromAHSV(1, color.hue, 1, 1).toColor(),
          ],
        ).createShader(rect),
    );
    canvas.drawRect(
      rect,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.transparent, Colors.black],
        ).createShader(rect),
    );
    final point = Offset(
      (color.saturation * size.width).clamp(8, size.width - 8),
      ((1 - color.value) * size.height).clamp(8, size.height - 8),
    );
    canvas.drawCircle(point, 8, Paint()..color = const Color(0x99000000));
    canvas.drawCircle(point, 6.5, Paint()..color = Colors.white);
    canvas.drawCircle(point, 4, Paint()..color = color.toColor());
    canvas.restore();
    if (focused) {
      canvas.drawRRect(
        shape.deflate(1.5),
        Paint()
          ..color = Colors.white
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
    }
  }

  @override
  bool shouldRepaint(_ColorPlanePainter oldDelegate) {
    AppLog.instance.trace(
      "lib/pages/theme_color_editor.dart::_ColorPlanePainter.shouldRepaint",
    );
    return oldDelegate.color != color || oldDelegate.focused != focused;
  }
}

class _ColorPreview extends StatelessWidget {
  const _ColorPreview({
    required this.seed,
    required this.brightness,
    this.oledBlack = false,
  });

  final Color seed;
  final Brightness brightness;
  final bool oledBlack;

  @override
  Widget build(BuildContext context) {
    AppLog.instance.trace(
      "lib/pages/theme_color_editor.dart::_ColorPreview.build",
    );

    final scheme = ColorScheme.fromSeed(
      seedColor: seed,
      brightness: brightness,
    );
    final dark = brightness == Brightness.dark;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: dark && oledBlack ? Colors.black : scheme.surface,
        border: Border.all(color: scheme.outlineVariant),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: DefaultTextStyle(
          style: Theme.of(context).textTheme.bodyMedium!
              .copyWith(color: scheme.onSurface),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                dark ? '深色效果' : '浅色效果',
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  DecoratedBox(
                    decoration: BoxDecoration(
                      color: scheme.primary,
                      shape: BoxShape.circle,
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: Icon(
                        Icons.play_arrow_rounded,
                        color: scheme.onPrimary,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  const Expanded(child: Text('听见每一种色彩')),
                ],
              ),
              const SizedBox(height: 14),
              LinearProgressIndicator(
                value: 0.4,
                minHeight: 4,
                borderRadius: BorderRadius.circular(4),
                color: scheme.primary,
                backgroundColor: scheme.surfaceContainerHighest,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
