import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../common/widgets/playback_action_button.dart';
import '../services/app_runtime.dart';
import '../services/app_log.dart';
import '../storage/app_storage.dart';
import 'playback_settings_page.dart';

class PlaybackSpeedControl extends StatefulWidget {
  const PlaybackSpeedControl({
    required this.runtime,
    this.albumId,
    this.size = 64,
    super.key,
  });

  final AppRuntime runtime;
  final String? albumId;
  final double size;

  @override
  State<PlaybackSpeedControl> createState() {
    AppLog.instance.trace(
      "lib/pages/playback_speed_control.dart::PlaybackSpeedControl.createState",
    );
    return _PlaybackSpeedControlState();
  }
}

class _PlaybackSpeedControlState extends State<PlaybackSpeedControl> {
  bool _saving = false;
  double? _draft;
  String? _error;

  String _label(double value) {
    AppLog.instance.trace(
      "lib/pages/playback_speed_control.dart::_PlaybackSpeedControlState._label",
    );
    return '${value.toStringAsFixed(2).replaceFirst(RegExp(r'0$'), '')}×';
  }

  Future<void> _save(double value) {
    AppLog.instance.trace(
      "lib/pages/playback_speed_control.dart::_PlaybackSpeedControlState._save",
    );
    return AppLog.instance.runWithErrorScope(() async {
      AppLog.instance.trace(
        "lib/pages/playback_speed_control.dart::_PlaybackSpeedControlState._save.closure#1",
      );

      if (!mounted || _saving) return;
      setState(() {
        AppLog.instance.trace(
          "lib/pages/playback_speed_control.dart::_PlaybackSpeedControlState._save.closure#1.closure#1",
        );

        _saving = true;
        _draft = value;
        _error = null;
      });
      try {
        await persistPlaybackSetting(
          widget.runtime,
          'speed',
          double.parse(value.toStringAsFixed(2)),
          albumId: widget.albumId,
        );
      } catch (error, stack) {
        if (error is! FormatException &&
            !(error is StorageException &&
                const {'too_large', 'secret_in_state'}.contains(error.code)) &&
            !AppLog.instance.errorWasRecorded(error)) {
          AppLog.instance.write(
            AppLogLevel.error,
            'settings',
            'Applying playback speed failed',
            error: error,
            stackTrace: stack,
            promptUser: true,
          );
        }
        if (mounted)
          setState(() {
            AppLog.instance.trace(
              "lib/pages/playback_speed_control.dart::_PlaybackSpeedControlState._save.closure#1.closure#2",
            );
            _error = '倍速保存或应用失败，请重试';
          });
      } finally {
        if (mounted) {
          setState(() {
            AppLog.instance.trace(
              "lib/pages/playback_speed_control.dart::_PlaybackSpeedControlState._save.closure#1.closure#3",
            );

            _saving = false;
            _draft = null;
          });
        }
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    AppLog.instance.trace(
      "lib/pages/playback_speed_control.dart::_PlaybackSpeedControlState.build",
    );

    final current = _draft ?? widget.runtime.player.effectiveSettings.speed;
    final theme = Theme.of(context);
    final menuWidth = math.min(340.0, MediaQuery.sizeOf(context).width - 32);
    const speeds = [1.0, 1.25, 1.5, 2.0];
    final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
    final columns = ((menuWidth - 24) / (68 * scale + 8)).floor().clamp(
      1,
      speeds.length,
    );
    final presetWidth = (menuWidth - 32 - (columns - 1) * 8) / columns;
    return MenuAnchor(
      consumeOutsideTap: true,
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(theme.colorScheme.surface),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        padding: const WidgetStatePropertyAll(EdgeInsets.zero),
        elevation: const WidgetStatePropertyAll(6),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        ),
      ),
      onClose: () {
        AppLog.instance.trace(
          "lib/pages/playback_speed_control.dart::_PlaybackSpeedControlState.build.closure#1",
        );

        if (mounted && !_saving && _draft != null) {
          setState(() {
            AppLog.instance.trace(
              "lib/pages/playback_speed_control.dart::_PlaybackSpeedControlState.build.closure#1.closure#1",
            );
            _draft = null;
          });
        }
      },
      menuChildren: [
        SizedBox(
          width: menuWidth,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        widget.albumId == null ? '全局倍速' : '专辑倍速',
                        style: theme.textTheme.titleMedium,
                      ),
                    ),
                    const SizedBox(width: 12),
                    SizedBox(
                      width: 14,
                      height: 14,
                      child: _saving
                          ? const CircularProgressIndicator(
                              strokeWidth: 2,
                              semanticsLabel: '正在保存倍速',
                            )
                          : null,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      _label(current),
                      style: theme.textTheme.titleMedium?.copyWith(
                        color: theme.colorScheme.primary,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final speed in speeds)
                      SizedBox(
                        width: presetWidth,
                        child: ChoiceChip(
                          key: ValueKey('quickSpeed:$speed'),
                          showCheckmark: false,
                          labelPadding: EdgeInsets.zero,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 8,
                          ),
                          label: Center(child: Text(_label(speed))),
                          selected: current == speed,
                          onSelected: _saving
                              ? null
                              : (_) {
                                  AppLog.instance.trace(
                                    "lib/pages/playback_speed_control.dart::_PlaybackSpeedControlState.build.closure#2",
                                  );
                                  _save(speed);
                                },
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                      ),
                  ],
                ),
                Slider(
                  key: const ValueKey('playbackSpeedSlider'),
                  autofocus: true,
                  value: current,
                  min: 0.5,
                  max: 3,
                  divisions: 50,
                  label: _label(current),
                  semanticFormatterCallback: _label,
                  // Keep keyboard focus while saving without admitting a
                  // second edit until the current value has been applied.
                  onChanged: (value) {
                    AppLog.instance.trace(
                      "lib/pages/playback_speed_control.dart::_PlaybackSpeedControlState.build.closure#3",
                    );

                    if (!_saving)
                      setState(() {
                        AppLog.instance.trace(
                          "lib/pages/playback_speed_control.dart::_PlaybackSpeedControlState.build.closure#3.closure#1",
                        );
                        _draft = value;
                      });
                  },
                  onChangeEnd: _save,
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      '0.5×',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    Text(
                      '3.0×',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      _error!,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.error,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
      builder: (context, controller, _) {
        AppLog.instance.trace(
          "lib/pages/playback_speed_control.dart::_PlaybackSpeedControlState.build.closure#4",
        );
        return PlaybackActionButton(
          size: widget.size,
          tooltip: '调整播放倍速',
          icon: const Icon(Icons.speed_rounded),
          label: _label(current),
          onPressed: () {
            AppLog.instance.trace(
              "lib/pages/playback_speed_control.dart::_PlaybackSpeedControlState.build.closure#4.closure#1",
            );
            controller.isOpen ? controller.close() : controller.open();
          },
        );
      },
    );
  }
}
