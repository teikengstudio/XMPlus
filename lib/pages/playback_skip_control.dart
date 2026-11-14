import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../common/widgets/local_panel.dart';
import '../services/app_log.dart';
import '../services/app_runtime.dart';
import '../services/playback_policy.dart';

Future<void> showSkipSegmentsSettings(
  BuildContext context,
  AppRuntime runtime,
) {
  AppLog.instance.trace(
    "lib/pages/playback_skip_control.dart::showSkipSegmentsSettings",
  );

  final track = runtime.player.current;
  final duration = runtime.player.duration;
  return showLocalPanel<void>(
    context: context,
    title: '跳过片头片尾',
    width: 420,
    height: 560,
    builder: (context) {
      AppLog.instance.trace(
        "lib/pages/playback_skip_control.dart::showSkipSegmentsSettings.closure#1",
      );

      return _SkipSegmentsPanel(
        runtime: runtime,
        albumId: track?.albumId.isNotEmpty == true ? track!.albumId : null,
        albumTitle: track?.album,
        duration: duration,
      );
    },
  );
}

class PlaybackSkipButton extends StatelessWidget {
  const PlaybackSkipButton({required this.runtime, super.key});
  final AppRuntime runtime;

  @override
  Widget build(BuildContext context) {
    AppLog.instance.trace(
      "lib/pages/playback_skip_control.dart::PlaybackSkipButton.build",
    );

    return ListenableBuilder(
      listenable: runtime,
      builder: (context, _) {
        AppLog.instance.trace(
          "lib/pages/playback_skip_control.dart::PlaybackSkipButton.build.closure#1",
        );

        final settings = runtime.player.effectiveSettings;
        final enabled =
            settings.skipIntroSeconds > 0 || settings.skipOutroSeconds > 0;
        return IconButton(
          key: const ValueKey('playbackSkipSegments'),
          tooltip: enabled
              ? '片头 ${settings.skipIntroSeconds} 秒 · 片尾 ${settings.skipOutroSeconds} 秒'
              : '跳过片头片尾',
          color: enabled ? Theme.of(context).colorScheme.primary : null,
          icon: const Icon(Icons.content_cut_rounded),
          onPressed: () {
            AppLog.instance.trace(
              "lib/pages/playback_skip_control.dart::PlaybackSkipButton.build.closure#1.closure#1",
            );
            showSkipSegmentsSettings(context, runtime);
          },
        );
      },
    );
  }
}

class _SkipSegmentsPanel extends StatefulWidget {
  const _SkipSegmentsPanel({
    required this.runtime,
    required this.duration,
    this.albumId,
    this.albumTitle,
  });
  final AppRuntime runtime;
  final String? albumId, albumTitle;
  final double duration;

  @override
  State<_SkipSegmentsPanel> createState() {
    AppLog.instance.trace(
      "lib/pages/playback_skip_control.dart::_SkipSegmentsPanel.createState",
    );

    return _SkipSegmentsPanelState();
  }
}

class _SkipSegmentsPanelState extends State<_SkipSegmentsPanel> {
  final _form = GlobalKey<FormState>();
  final _intro = TextEditingController();
  final _outro = TextEditingController();
  final Map<bool, (String, String)> _drafts = {};
  late bool _global;
  bool _saving = false;
  String? _error;

  Map get _settings {
    AppLog.instance.trace(
      "lib/pages/playback_skip_control.dart::_SkipSegmentsPanelState._settings.get",
    );

    return widget.runtime.storage.state['settings'] as Map;
  }

  @override
  void initState() {
    AppLog.instance.trace(
      "lib/pages/playback_skip_control.dart::_SkipSegmentsPanelState.initState",
    );

    super.initState();
    _global = widget.albumId == null;
    _loadValues();
    _intro.addListener(_changed);
    _outro.addListener(_changed);
  }

  void _loadValues() {
    AppLog.instance.trace(
      "lib/pages/playback_skip_control.dart::_SkipSegmentsPanelState._loadValues",
    );

    final draft = _drafts[_global];
    final settings = PlaybackSettings.resolve(
      _settings['playback'] as Map? ?? const {},
      _global
          ? const {}
          : (_settings['albumOverrides'] as Map?)?[widget.albumId] as Map? ??
                const {},
    );
    _intro.text = draft?.$1 ?? '${settings.skipIntroSeconds}';
    _outro.text = draft?.$2 ?? '${settings.skipOutroSeconds}';
  }

  void _changed() {
    AppLog.instance.trace(
      "lib/pages/playback_skip_control.dart::_SkipSegmentsPanelState._changed",
    );

    if (mounted)
      setState(() {
        AppLog.instance.trace(
          "lib/pages/playback_skip_control.dart::_SkipSegmentsPanelState._changed.closure#1",
        );
      });
  }

  void _scope(Set<bool> values) {
    AppLog.instance.trace(
      "lib/pages/playback_skip_control.dart::_SkipSegmentsPanelState._scope",
    );

    _drafts[_global] = (_intro.text, _outro.text);
    setState(() {
      AppLog.instance.trace(
        "lib/pages/playback_skip_control.dart::_SkipSegmentsPanelState._scope.closure#1",
      );

      _global = values.single;
      _error = null;
      _loadValues();
    });
  }

  @override
  void dispose() {
    AppLog.instance.trace(
      "lib/pages/playback_skip_control.dart::_SkipSegmentsPanelState.dispose",
    );

    _intro.dispose();
    _outro.dispose();
    super.dispose();
  }

  Future<void> _save({bool inherit = false}) async {
    AppLog.instance.trace(
      "lib/pages/playback_skip_control.dart::_SkipSegmentsPanelState._save",
    );

    if (_saving || (!inherit && !_form.currentState!.validate())) return;
    setState(() {
      AppLog.instance.trace(
        "lib/pages/playback_skip_control.dart::_SkipSegmentsPanelState._save.closure#1",
      );
      _saving = true;
      _error = null;
    });
    try {
      await widget.runtime.player.setSkipSegments(
        introSeconds: inherit ? 0 : int.parse(_intro.text),
        outroSeconds: inherit ? 0 : int.parse(_outro.text),
        albumId: _global ? null : widget.albumId,
        inherit: inherit,
      );
      widget.runtime.changed();
      if (mounted) Navigator.pop(context);
    } catch (error, stack) {
      if (!AppLog.instance.errorWasRecorded(error)) {
        AppLog.instance.write(
          AppLogLevel.error,
          'player',
          'Saving chapter skip settings failed',
          error: error,
          stackTrace: stack,
        );
      }
      if (mounted)
        setState(() {
          AppLog.instance.trace(
            "lib/pages/playback_skip_control.dart::_SkipSegmentsPanelState._save.closure#2",
          );
          _error = '设置未保存，请重试';
        });
    } finally {
      if (mounted)
        setState(() {
          AppLog.instance.trace(
            "lib/pages/playback_skip_control.dart::_SkipSegmentsPanelState._save.closure#3",
          );
          _saving = false;
        });
    }
  }

  Widget _seconds(String label, TextEditingController controller, String key) {
    AppLog.instance.trace(
      "lib/pages/playback_skip_control.dart::_SkipSegmentsPanelState._seconds",
    );

    final seconds = int.tryParse(controller.text);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextFormField(
          key: ValueKey(key),
          controller: controller,
          enabled: !_saving,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          textInputAction: key == 'skipIntroInput'
              ? TextInputAction.next
              : TextInputAction.done,
          decoration: InputDecoration(labelText: label, suffixText: '秒'),
          validator: (text) {
            AppLog.instance.trace(
              "lib/pages/playback_skip_control.dart::_SkipSegmentsPanelState._seconds.closure#1",
            );

            final value = int.tryParse(text ?? '');
            return value == null || value < 0 || value > 3600
                ? '请输入 0–3600 秒'
                : null;
          },
          onFieldSubmitted: key == 'skipOutroInput'
              ? (_) {
                  AppLog.instance.trace(
                    "lib/pages/playback_skip_control.dart::_SkipSegmentsPanelState._seconds.closure#2",
                  );
                  _save();
                }
              : null,
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 6,
          runSpacing: 4,
          children: [
            for (final value in const [0, 15, 30, 60, 90, 120])
              ChoiceChip(
                showCheckmark: false,
                label: Text(value == 0 ? '不跳过' : '$value 秒'),
                selected: seconds == value,
                onSelected: _saving
                    ? null
                    : (_) {
                        AppLog.instance.trace(
                          "lib/pages/playback_skip_control.dart::_SkipSegmentsPanelState._seconds.closure#3",
                        );
                        controller.text = '$value';
                      },
                visualDensity: VisualDensity.compact,
              ),
          ],
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    AppLog.instance.trace(
      "lib/pages/playback_skip_control.dart::_SkipSegmentsPanelState.build",
    );

    final total =
        (int.tryParse(_intro.text) ?? 0) + (int.tryParse(_outro.text) ?? 0);
    final overrides =
        (_settings['albumOverrides'] as Map?)?[widget.albumId] as Map?;
    final overridden =
        overrides?.containsKey('skipIntroSeconds') == true ||
        overrides?.containsKey('skipOutroSeconds') == true;
    return PopScope(
      canPop: !_saving,
      child: Form(
        key: _form,
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            if (widget.albumId != null) ...[
              SegmentedButton<bool>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: false, label: Text('此专辑')),
                  ButtonSegment(value: true, label: Text('全局')),
                ],
                selected: {_global},
                onSelectionChanged: _saving ? null : _scope,
              ),
              const SizedBox(height: 12),
              if (!_global && widget.albumTitle?.isNotEmpty == true)
                Text(
                  widget.albumTitle!,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              const SizedBox(height: 12),
            ],
            _seconds('片头', _intro, 'skipIntroInput'),
            const SizedBox(height: 24),
            _seconds('片尾', _outro, 'skipOutroInput'),
            if (widget.duration > 0 && total >= widget.duration) ...[
              const SizedBox(height: 12),
              const Text('本集较短，将完整播放。'),
            ],
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            const SizedBox(height: 24),
            OverflowBar(
              alignment: MainAxisAlignment.end,
              spacing: 8,
              overflowSpacing: 8,
              children: [
                if (!_global && overridden)
                  TextButton(
                    onPressed: _saving
                        ? null
                        : () {
                            AppLog.instance.trace(
                              "lib/pages/playback_skip_control.dart::_SkipSegmentsPanelState.build.closure#1",
                            );
                            _save(inherit: true);
                          },
                    child: const Text('跟随全局'),
                  ),
                TextButton(
                  onPressed: _saving
                      ? null
                      : () {
                          AppLog.instance.trace(
                            "lib/pages/playback_skip_control.dart::_SkipSegmentsPanelState.build.closure#2",
                          );
                          Navigator.pop(context);
                        },
                  child: const Text('取消'),
                ),
                FilledButton(
                  key: const ValueKey('saveSkipSegments'),
                  onPressed: _saving
                      ? null
                      : () {
                          AppLog.instance.trace(
                            "lib/pages/playback_skip_control.dart::_SkipSegmentsPanelState.build.closure#3",
                          );
                          _save();
                        },
                  child: Text(_saving ? '保存中' : '保存'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
