import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../services/app_runtime.dart';
import '../services/app_log.dart';
import '../storage/app_storage.dart';

class PlaybackVolumeControl extends StatefulWidget {
  const PlaybackVolumeControl({required this.runtime, super.key});

  final AppRuntime runtime;

  @override
  State<PlaybackVolumeControl> createState() {
    AppLog.instance.trace(
      "lib/pages/playback_volume_control.dart::PlaybackVolumeControl.createState",
    );
    return _PlaybackVolumeControlState();
  }
}

class _PlaybackVolumeControlState extends State<PlaybackVolumeControl> {
  bool _saving = false;
  bool _dismissedWhileSaving = false;
  double? _draft;
  String? _error;
  double? _failedVolume;
  bool? _failedMuted;

  String _label(double value) {
    AppLog.instance.trace(
      "lib/pages/playback_volume_control.dart::_PlaybackVolumeControlState._label",
    );
    return '${value.round()}%';
  }

  Future<void> _save({double? value, bool? muted}) {
    AppLog.instance.trace(
      "lib/pages/playback_volume_control.dart::_PlaybackVolumeControlState._save",
    );
    return AppLog.instance.runWithErrorScope(() async {
      AppLog.instance.trace(
        "lib/pages/playback_volume_control.dart::_PlaybackVolumeControlState._save.closure#1",
      );

      if (!mounted || _saving) return;
      setState(() {
        AppLog.instance.trace(
          "lib/pages/playback_volume_control.dart::_PlaybackVolumeControlState._save.closure#1.closure#1",
        );

        _saving = true;
        _dismissedWhileSaving = false;
        _draft = value;
        _error = null;
        _failedVolume = null;
        _failedMuted = null;
      });
      try {
        if (muted != null) {
          await widget.runtime.player.setMasterMuted(muted);
        } else {
          await widget.runtime.player.setMasterVolume(value!);
        }
        widget.runtime.changed();
      } catch (error, stack) {
        if (error is! FormatException &&
            !(error is StorageException &&
                const {'too_large', 'secret_in_state'}.contains(error.code)) &&
            !AppLog.instance.errorWasRecorded(error)) {
          AppLog.instance.write(
            AppLogLevel.error,
            'settings',
            'Applying master volume failed',
            error: error,
            stackTrace: stack,
            promptUser: true,
          );
        }
        if (mounted) {
          setState(() {
            AppLog.instance.trace(
              "lib/pages/playback_volume_control.dart::_PlaybackVolumeControlState._save.closure#1.closure#2",
            );

            _error = '主音量保存或应用失败，请重试';
            _failedVolume = value;
            _failedMuted = muted;
          });
        }
      } finally {
        if (mounted) {
          setState(() {
            AppLog.instance.trace(
              "lib/pages/playback_volume_control.dart::_PlaybackVolumeControlState._save.closure#1.closure#3",
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
      "lib/pages/playback_volume_control.dart::_PlaybackVolumeControlState.build",
    );
    return ListenableBuilder(
      listenable: widget.runtime,
      builder: (context, _) {
        AppLog.instance.trace(
          "lib/pages/playback_volume_control.dart::_PlaybackVolumeControlState.build.closure#1",
        );

        final current =
            _draft ?? widget.runtime.player.effectiveSettings.masterVolume;
        final muted = widget.runtime.player.effectiveSettings.masterMuted;
        final theme = Theme.of(context);
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
              "lib/pages/playback_volume_control.dart::_PlaybackVolumeControlState.build.closure#1.closure#1",
            );

            if (_saving) _dismissedWhileSaving = true;
            if (mounted && !_saving && _draft != null) {
              setState(() {
                AppLog.instance.trace(
                  "lib/pages/playback_volume_control.dart::_PlaybackVolumeControlState.build.closure#1.closure#1.closure#1",
                );
                _draft = null;
              });
            }
          },
          menuChildren: [
            SizedBox(
              width: math.min(340, MediaQuery.sizeOf(context).width - 32),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            muted ? '主音量 · 已静音' : '主音量',
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
                                  semanticsLabel: '正在保存主音量',
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
                    Slider(
                      key: const ValueKey('playbackVolumeSlider'),
                      autofocus: true,
                      value: current,
                      min: 0,
                      max: 100,
                      divisions: 100,
                      label: _label(current),
                      semanticFormatterCallback: (value) {
                        AppLog.instance.trace(
                          "lib/pages/playback_volume_control.dart::_PlaybackVolumeControlState.build.closure#1.closure#2",
                        );
                        return '主音量 ${_label(value)}';
                      },
                      // Disabling a focused slider drops keyboard focus. Keep
                      // it enabled, but ignore edits while this save is pending.
                      onChanged: (value) {
                        AppLog.instance.trace(
                          "lib/pages/playback_volume_control.dart::_PlaybackVolumeControlState.build.closure#1.closure#3",
                        );

                        if (!_saving)
                          setState(() {
                            AppLog.instance.trace(
                              "lib/pages/playback_volume_control.dart::_PlaybackVolumeControlState.build.closure#1.closure#3.closure#1",
                            );
                            _draft = value;
                          });
                      },
                      onChangeEnd: (value) {
                        AppLog.instance.trace(
                          "lib/pages/playback_volume_control.dart::_PlaybackVolumeControlState.build.closure#1.closure#4",
                        );
                        _save(value: value);
                      },
                    ),
                    Text(
                      muted ? '调整音量即可恢复，切换专辑后保留。' : '所有专辑共用，专辑音量可单独调整。',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    if (_error != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _error!,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.error,
                              ),
                            ),
                            TextButton(
                              onPressed: () {
                                AppLog.instance.trace(
                                  "lib/pages/playback_volume_control.dart::_PlaybackVolumeControlState.build.closure#1.closure#5",
                                );
                                _save(
                                  value: _failedVolume,
                                  muted: _failedMuted,
                                );
                              },
                              child: const Text('重试'),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
          builder: (context, controller, _) {
            AppLog.instance.trace(
              "lib/pages/playback_volume_control.dart::_PlaybackVolumeControlState.build.closure#1.closure#6",
            );
            return Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  key: const ValueKey('playbackMuteButton'),
                  tooltip: _failedMuted != null
                      ? (_failedMuted! ? '重试静音' : '重试取消静音')
                      : (muted ? '取消静音' : '静音'),
                  isSelected: muted,
                  onPressed: () async {
                    AppLog.instance.trace(
                      "lib/pages/playback_volume_control.dart::_PlaybackVolumeControlState.build.closure#1.closure#6.closure#1",
                    );

                    if (_saving) return;
                    // A failed device command may already have saved its target.
                    // Retrying must apply that target, not toggle it back.
                    await _save(muted: _failedMuted ?? !muted);
                    if (mounted &&
                        _error != null &&
                        !_dismissedWhileSaving &&
                        !controller.isOpen) {
                      controller.open();
                    }
                  },
                  icon: Icon(
                    _failedMuted != null
                        ? Icons.error_outline_rounded
                        : muted || current == 0
                        ? Icons.volume_off_rounded
                        : Icons.volume_up_rounded,
                    size: 20,
                  ),
                ),
                Tooltip(
                  message: '调整主音量（所有专辑）',
                  child: TextButton(
                    onPressed: () {
                      AppLog.instance.trace(
                        "lib/pages/playback_volume_control.dart::_PlaybackVolumeControlState.build.closure#1.closure#6.closure#2",
                      );
                      controller.isOpen
                          ? controller.close()
                          : controller.open();
                    },
                    child: Text(_label(current)),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }
}
