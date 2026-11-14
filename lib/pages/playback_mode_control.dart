import 'package:flutter/material.dart';

import '../services/app_log.dart';
import '../services/app_runtime.dart';

String playbackModeLabel(String mode) {
  AppLog.instance.trace(
    "lib/pages/playback_mode_control.dart::playbackModeLabel",
  );

  return switch (mode) {
    'single' => '单集循环',
    'all' => '列表循环',
    'shuffle' => '随机播放',
    _ => '顺序播放',
  };
}

IconData playbackModeIcon(String mode) {
  AppLog.instance.trace(
    "lib/pages/playback_mode_control.dart::playbackModeIcon",
  );

  return switch (mode) {
    'single' => Icons.repeat_one_rounded,
    'all' => Icons.repeat_rounded,
    'shuffle' => Icons.shuffle_rounded,
    _ => Icons.playlist_play_rounded,
  };
}

class PlaybackModeButton extends StatefulWidget {
  const PlaybackModeButton({required this.runtime, super.key});
  final AppRuntime runtime;

  @override
  State<PlaybackModeButton> createState() {
    AppLog.instance.trace(
      "lib/pages/playback_mode_control.dart::PlaybackModeButton.createState",
    );

    return _PlaybackModeButtonState();
  }
}

class _PlaybackModeButtonState extends State<PlaybackModeButton> {
  bool _saving = false;

  Future<void> _select(String mode) async {
    AppLog.instance.trace(
      "lib/pages/playback_mode_control.dart::_PlaybackModeButtonState._select",
    );

    if (_saving) return;
    setState(() {
      AppLog.instance.trace(
        "lib/pages/playback_mode_control.dart::_PlaybackModeButtonState._select.closure#1",
      );
      _saving = true;
    });
    try {
      await widget.runtime.player.setPlaybackMode(mode);
      widget.runtime.changed();
    } catch (error, stack) {
      if (!AppLog.instance.errorWasRecorded(error)) {
        AppLog.instance.write(
          AppLogLevel.error,
          'player',
          'Saving playback mode failed',
          error: error,
          stackTrace: stack,
        );
      }
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)
            ?.showSnackBar(const SnackBar(content: Text('播放方式未保存，请重试')));
      }
    } finally {
      if (mounted)
        setState(() {
          AppLog.instance.trace(
            "lib/pages/playback_mode_control.dart::_PlaybackModeButtonState._select.closure#2",
          );
          _saving = false;
        });
    }
  }

  @override
  Widget build(BuildContext context) {
    AppLog.instance.trace(
      "lib/pages/playback_mode_control.dart::_PlaybackModeButtonState.build",
    );

    return ListenableBuilder(
      listenable: widget.runtime,
      builder: (context, _) {
        AppLog.instance.trace(
          "lib/pages/playback_mode_control.dart::_PlaybackModeButtonState.build.closure#1",
        );

        final mode = widget.runtime.player.effectiveSettings.loopMode;
        final colors = Theme.of(context).colorScheme;
        return PopupMenuButton<String>(
          key: const ValueKey('playbackModeMenu'),
          enabled: !_saving,
          tooltip: playbackModeLabel(mode),
          initialValue: mode,
          icon: Icon(
            playbackModeIcon(mode),
            color: mode == 'off' ? null : colors.primary,
          ),
          onSelected: _select,
          itemBuilder: (context) {
            AppLog.instance.trace(
              "lib/pages/playback_mode_control.dart::_PlaybackModeButtonState.build.closure#1.closure#1",
            );

            return [
              for (final value in const ['off', 'single', 'all', 'shuffle'])
                PopupMenuItem(
                  value: value,
                  child: Row(
                    children: [
                      Icon(playbackModeIcon(value), size: 20),
                      const SizedBox(width: 12),
                      Expanded(child: Text(playbackModeLabel(value))),
                      if (value == mode) ...[
                        const SizedBox(width: 16),
                        Icon(
                          Icons.check_rounded,
                          size: 18,
                          color: colors.primary,
                        ),
                      ],
                    ],
                  ),
                ),
            ];
          },
        );
      },
    );
  }
}
