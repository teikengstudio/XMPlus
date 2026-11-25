import 'package:flutter/material.dart';

import '../api/xmly_client.dart';
import '../api/xmly_experience.dart';
import '../common/widgets/app_header.dart';
import '../common/widgets/local_panel.dart';
import '../models/xmly_models.dart';
import '../services/app_runtime.dart';
import '../services/app_log.dart';
import '../storage/app_storage.dart';
import '../services/playback_policy.dart';
import 'playback_volume_control.dart';

// Track only this setting's writes, including same-value/ABA updates, so a late
// declined dialog cannot undo a newer choice for the global or album scope.
final _listenAndDownloadWrites = Expando<Map<String?, int>>();

/// Commit first: a failed disk write must not change the live playback policy.
Future<void> persistPlaybackSetting(
  AppRuntime runtime,
  String key,
  Object? value, {
  String? albumId,
}) async {
  AppLog.instance.trace(
    "lib/pages/playback_settings_page.dart::persistPlaybackSetting",
  );
  final revisions = key == 'listenAndDownload'
      ? (_listenAndDownloadWrites[runtime] ??= <String?, int>{})
      : null;
  final revision = revisions == null ? null : (revisions[albumId] ?? 0) + 1;
  if (revision != null) revisions![albumId] = revision;
  Object? previousValue;
  var previouslyPresent = false;

  await runtime.storage.transaction((state) {
    AppLog.instance.trace(
      "lib/pages/playback_settings_page.dart::persistPlaybackSetting.closure#1",
    );

    final settings = state['settings'] as Map;
    final global = settings.putIfAbsent('playback', () {
      AppLog.instance.trace(
        "lib/pages/playback_settings_page.dart::persistPlaybackSetting.closure#1.closure#1",
      );
      return <String, dynamic>{};
    }) as Map;
    Map target = global;
    if (albumId != null) {
      final overrides = settings.putIfAbsent('albumOverrides', () {
        AppLog.instance.trace(
          "lib/pages/playback_settings_page.dart::persistPlaybackSetting.closure#1.closure#2",
        );
        return <String, dynamic>{};
      }) as Map;
      target = overrides.putIfAbsent(albumId, () {
        AppLog.instance.trace(
          "lib/pages/playback_settings_page.dart::persistPlaybackSetting.closure#1.closure#3",
        );
        return <String, dynamic>{};
      }) as Map;
    }
    previousValue = target[key];
    previouslyPresent = target.containsKey(key);
    if (value == null) {
      target.remove(key);
    } else {
      target[key] = value;
    }
    PlaybackSettings.resolve(global, albumId == null ? const {} : target);
    if (key == 'syncHistory' && value is! bool)
      throw const FormatException('同步设置无效');
  });
  final accepted = await runtime.player.applySettings(
    updateSource: key == 'listenAndDownload',
  );
  if (!accepted && revision != null) {
    await runtime.storage.transaction((state) {
      AppLog.instance.trace(
        'lib/pages/playback_settings_page.dart::persistPlaybackSetting.closure#2',
      );
      if (revisions![albumId] != revision) return;
      final settings = state['settings'] as Map;
      final target = albumId == null
          ? settings['playback'] as Map?
          : (settings['albumOverrides'] as Map?)?[albumId] as Map?;
      if (target == null ||
          target[key] != value ||
          target.containsKey(key) != (value != null))
        return;
      if (previouslyPresent) {
        target[key] = previousValue;
      } else {
        target.remove(key);
      }
    });
    await runtime.player.applySettings(updateSource: false);
  }
  runtime.changed();
}

/// Imports both values together, rejecting an outdated preview before any write.
Future<void> persistAlbumSkipSettings(
  AppRuntime runtime,
  String albumId, {
  required int skipIntroSeconds,
  required int skipOutroSeconds,
  required XmlyClient expectedClient,
  required String expectedIdentity,
  required String expectedCacheIdentity,
  required Object? expectedSkipIntroSeconds,
  required Object? expectedSkipOutroSeconds,
  required bool Function() isCurrent,
}) async {
  AppLog.instance.trace(
    'lib/pages/playback_settings_page.dart::persistAlbumSkipSettings',
  );
  xmlyIdentifier(albumId);
  if (skipIntroSeconds < 0 ||
      skipIntroSeconds > 3600 ||
      skipOutroSeconds < 0 ||
      skipOutroSeconds > 3600) {
    throw const FormatException('片头和片尾必须为 0–3600 的整数秒');
  }
  await runtime.storage.transaction((state) {
    AppLog.instance.trace(
      'lib/pages/playback_settings_page.dart::persistAlbumSkipSettings.closure#1',
    );
    final settings = state['settings'] as Map;
    final existing =
        (settings['albumOverrides'] as Map?)?[albumId] as Map? ?? const {};
    if (!isCurrent() ||
        !identical(runtime.client, expectedClient) ||
        !expectedClient.accountAvailable ||
        expectedClient.identity != expectedIdentity ||
        expectedClient.cacheIdentity != expectedCacheIdentity ||
        existing['skipIntroSeconds'] != expectedSkipIntroSeconds ||
        existing['skipOutroSeconds'] != expectedSkipOutroSeconds) {
      throw const XmlyException('skip_recommendation_stale', '设置已变化，请重新获取建议');
    }
    final overrides = settings.putIfAbsent('albumOverrides', () {
      AppLog.instance.trace(
        'lib/pages/playback_settings_page.dart::persistAlbumSkipSettings.closure#1.closure#1',
      );
      return <String, dynamic>{};
    }) as Map;
    final target = overrides.putIfAbsent(albumId, () {
      AppLog.instance.trace(
        'lib/pages/playback_settings_page.dart::persistAlbumSkipSettings.closure#1.closure#2',
      );
      return <String, dynamic>{};
    }) as Map;
    target['skipIntroSeconds'] = skipIntroSeconds;
    target['skipOutroSeconds'] = skipOutroSeconds;
    PlaybackSettings.resolve(settings['playback'] as Map? ?? const {}, target);
  });
  await runtime.player.applySettings(updateSource: false);
  runtime.changed();
}

Future<void> showQuickPlaybackSettings(
  BuildContext context,
  AppRuntime runtime, {
  String? albumId,
  String? albumTitle,
  bool skipOnly = false,
}) async {
  AppLog.instance.trace(
    "lib/pages/playback_settings_page.dart::showQuickPlaybackSettings",
  );

  var global = albumId == null;
  var saving = false;
  var fullSettings = false;
  await showLocalPanel<void>(
    context: context,
    title: skipOnly ? '跳过片头片尾' : '播放选项',
    builder: (context) {
      AppLog.instance.trace(
        "lib/pages/playback_settings_page.dart::showQuickPlaybackSettings.closure#1",
      );
      return StatefulBuilder(
        builder: (context, setPanelState) {
          AppLog.instance.trace(
            "lib/pages/playback_settings_page.dart::showQuickPlaybackSettings.closure#1.closure#1",
          );
          return Column(
            children: [
              if (albumId != null)
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: SegmentedButton<bool>(
                    showSelectedIcon: false,
                    expandedInsets: EdgeInsets.zero,
                    segments: const [
                      ButtonSegment(value: false, label: Text('此专辑')),
                      ButtonSegment(value: true, label: Text('全局')),
                    ],
                    selected: {global},
                    onSelectionChanged: saving
                        ? null
                        : (values) {
                            AppLog.instance.trace(
                              "lib/pages/playback_settings_page.dart::showQuickPlaybackSettings.closure#1.closure#1.closure#1",
                            );
                            setPanelState(() {
                              AppLog.instance.trace(
                                "lib/pages/playback_settings_page.dart::showQuickPlaybackSettings.closure#1.closure#1.closure#1.closure#1",
                              );
                              global = values.single;
                            });
                          },
                  ),
                ),
              Expanded(
                child: PlaybackSettingsPage(
                  key: ValueKey((global, fullSettings)),
                  runtime: runtime,
                  albumId: global ? null : albumId,
                  albumTitle: global ? null : albumTitle,
                  embedded: true,
                  quick: !fullSettings,
                  skipOnly: skipOnly,
                  onSavingChanged: (value) {
                    AppLog.instance.trace(
                      "lib/pages/playback_settings_page.dart::showQuickPlaybackSettings.closure#1.closure#1.closure#2",
                    );

                    if (context.mounted)
                      setPanelState(() {
                        AppLog.instance.trace(
                          "lib/pages/playback_settings_page.dart::showQuickPlaybackSettings.closure#1.closure#1.closure#2.closure#1",
                        );
                        saving = value;
                      });
                  },
                  onOpenFullSettings: () {
                    AppLog.instance.trace(
                      "lib/pages/playback_settings_page.dart::showQuickPlaybackSettings.closure#1.closure#1.closure#3",
                    );

                    setPanelState(() {
                      AppLog.instance.trace(
                        "lib/pages/playback_settings_page.dart::showQuickPlaybackSettings.closure#1.closure#1.closure#3.closure#1",
                      );
                      fullSettings = true;
                    });
                  },
                  onOpenGlobalSettings: () {
                    AppLog.instance.trace(
                      "lib/pages/playback_settings_page.dart::showQuickPlaybackSettings.closure#1.closure#1.closure#4",
                    );
                    setPanelState(() {
                      AppLog.instance.trace(
                        "lib/pages/playback_settings_page.dart::showQuickPlaybackSettings.closure#1.closure#1.closure#4.closure#1",
                      );
                      global = true;
                    });
                  },
                ),
              ),
              if (fullSettings && !skipOnly)
                TextButton.icon(
                  onPressed: saving
                      ? null
                      : () {
                          AppLog.instance.trace(
                            "lib/pages/playback_settings_page.dart::showQuickPlaybackSettings.closure#1.closure#1.closure#5",
                          );
                          setPanelState(() {
                            AppLog.instance.trace(
                              "lib/pages/playback_settings_page.dart::showQuickPlaybackSettings.closure#1.closure#1.closure#5.closure#1",
                            );
                            fullSettings = false;
                          });
                        },
                  icon: const Icon(Icons.unfold_less_rounded),
                  label: const Text('收起高级设置'),
                ),
            ],
          );
        },
      );
    },
  );
}

class PlaybackSettingsPage extends StatefulWidget {
  const PlaybackSettingsPage({
    required this.runtime,
    this.albumId,
    this.albumTitle,
    this.embedded = false,
    this.quick = false,
    this.skipOnly = false,
    this.onSavingChanged,
    this.onOpenFullSettings,
    this.onOpenGlobalSettings,
    super.key,
  });
  final AppRuntime runtime;
  final String? albumId, albumTitle;
  final bool embedded;
  final bool quick;
  final bool skipOnly;
  final ValueChanged<bool>? onSavingChanged;
  final VoidCallback? onOpenFullSettings;
  final VoidCallback? onOpenGlobalSettings;

  @override
  State<PlaybackSettingsPage> createState() {
    AppLog.instance.trace(
      "lib/pages/playback_settings_page.dart::PlaybackSettingsPage.createState",
    );
    return _PlaybackSettingsPageState();
  }
}

class _PlaybackSettingsPageState extends State<PlaybackSettingsPage> {
  bool _busy = false;
  String? _error;
  String? _historyResult;
  final Map<String, double> _drafts = {};
  final Map<String, String> _integerDrafts = {};
  int _integerDraftRevision = 0;
  int _recommendationGeneration = 0;
  bool Function()? _recommendationCurrent;
  String? _skipResult;

  @override
  void initState() {
    AppLog.instance.trace(
      'lib/pages/playback_settings_page.dart::_PlaybackSettingsPageState.initState',
    );
    super.initState();
    widget.runtime.addListener(_invalidateRecommendation);
  }

  @override
  void didUpdateWidget(covariant PlaybackSettingsPage oldWidget) {
    AppLog.instance.trace(
      'lib/pages/playback_settings_page.dart::_PlaybackSettingsPageState.didUpdateWidget',
    );
    super.didUpdateWidget(oldWidget);
    if (oldWidget.runtime != widget.runtime) {
      oldWidget.runtime.removeListener(_invalidateRecommendation);
      widget.runtime.addListener(_invalidateRecommendation);
    }
    if (oldWidget.runtime != widget.runtime ||
        oldWidget.albumId != widget.albumId) {
      _recommendationGeneration++;
      _integerDrafts.clear();
      _drafts.clear();
      _skipResult = null;
    }
  }

  void _invalidateRecommendation() {
    AppLog.instance.trace(
      'lib/pages/playback_settings_page.dart::_PlaybackSettingsPageState._invalidateRecommendation',
    );
    if (_recommendationCurrent?.call() == false) {
      _recommendationGeneration++;
    }
  }

  @override
  void dispose() {
    AppLog.instance.trace(
      'lib/pages/playback_settings_page.dart::_PlaybackSettingsPageState.dispose',
    );
    _recommendationGeneration++;
    _recommendationCurrent = null;
    widget.runtime.removeListener(_invalidateRecommendation);
    super.dispose();
  }

  Map get _settings {
    AppLog.instance.trace(
      "lib/pages/playback_settings_page.dart::_PlaybackSettingsPageState._settings.get",
    );
    return widget.runtime.storage.state['settings'] as Map;
  }

  Map get _global {
    AppLog.instance.trace(
      "lib/pages/playback_settings_page.dart::_PlaybackSettingsPageState._global.get",
    );
    return _settings['playback'] as Map? ?? const {};
  }

  Map get _album {
    AppLog.instance.trace(
      "lib/pages/playback_settings_page.dart::_PlaybackSettingsPageState._album.get",
    );
    return (_settings['albumOverrides'] as Map?)?[widget.albumId] as Map? ??
        const {};
  }

  Future<void> _getSkipRecommendation() {
    AppLog.instance.trace(
      'lib/pages/playback_settings_page.dart::_PlaybackSettingsPageState._getSkipRecommendation',
    );
    return AppLog.instance.runWithErrorScope(() async {
      AppLog.instance.trace(
        'lib/pages/playback_settings_page.dart::_PlaybackSettingsPageState._getSkipRecommendation.closure#1',
      );
      final runtime = widget.runtime;
      final albumId = widget.albumId;
      if (_busy || albumId == null) return;
      final client = runtime.client;
      if (!client.accountAvailable) {
        setState(() {
          AppLog.instance.trace(
            'lib/pages/playback_settings_page.dart::_PlaybackSettingsPageState._getSkipRecommendation.closure#1.closure#1',
          );
          _skipResult = '登录后可获取建议';
        });
        return;
      }
      final generation = ++_recommendationGeneration;
      final identity = client.identity;
      final cacheIdentity = client.cacheIdentity;
      final originalIntro = _album['skipIntroSeconds'];
      final originalOutro = _album['skipOutroSeconds'];
      bool current() {
        AppLog.instance.trace(
          'lib/pages/playback_settings_page.dart::_PlaybackSettingsPageState._getSkipRecommendation.closure#1.current',
        );
        return mounted &&
            generation == _recommendationGeneration &&
            identical(widget.runtime, runtime) &&
            widget.albumId == albumId &&
            identical(runtime.client, client) &&
            client.accountAvailable &&
            client.identity == identity &&
            client.cacheIdentity == cacheIdentity &&
            _album['skipIntroSeconds'] == originalIntro &&
            _album['skipOutroSeconds'] == originalOutro;
      }

      _recommendationCurrent = current;
      setState(() {
        AppLog.instance.trace(
          'lib/pages/playback_settings_page.dart::_PlaybackSettingsPageState._getSkipRecommendation.closure#1.closure#2',
        );
        _busy = true;
        _error = null;
        _skipResult = null;
      });
      widget.onSavingChanged?.call(true);
      var applying = false;
      try {
        final recommendation = await XmlyExperience(client)
            .albumSkipRecommendation(albumId);
        if (!current()) return;
        if (recommendation == null) {
          setState(() {
            AppLog.instance.trace(
              'lib/pages/playback_settings_page.dart::_PlaybackSettingsPageState._getSkipRecommendation.closure#1.closure#3',
            );
            _skipResult = '暂无建议';
          });
          return;
        }
        final apply = await showDialog<bool>(
          context: context,
          builder: (context) {
            AppLog.instance.trace(
              'lib/pages/playback_settings_page.dart::_PlaybackSettingsPageState._getSkipRecommendation.closure#1.closure#4',
            );
            return AlertDialog(
              title: const Text('片头片尾建议'),
              content: SingleChildScrollView(
                child: Text(
                  '跳过片头：${recommendation.skipIntroSeconds} 秒\n'
                  '跳过片尾：${recommendation.skipOutroSeconds} 秒\n\n'
                  '应用后会替换本专辑当前的片头和片尾设置。',
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () {
                    AppLog.instance.trace(
                      'lib/pages/playback_settings_page.dart::_PlaybackSettingsPageState._getSkipRecommendation.closure#1.closure#4.closure#1',
                    );
                    Navigator.pop(context, false);
                  },
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: () {
                    AppLog.instance.trace(
                      'lib/pages/playback_settings_page.dart::_PlaybackSettingsPageState._getSkipRecommendation.closure#1.closure#4.closure#2',
                    );
                    Navigator.pop(context, true);
                  },
                  child: const Text('应用到本专辑'),
                ),
              ],
            );
          },
        );
        if (apply != true || !current()) return;
        applying = true;
        await persistAlbumSkipSettings(
          runtime,
          albumId,
          skipIntroSeconds: recommendation.skipIntroSeconds,
          skipOutroSeconds: recommendation.skipOutroSeconds,
          expectedClient: client,
          expectedIdentity: identity,
          expectedCacheIdentity: cacheIdentity,
          expectedSkipIntroSeconds: originalIntro,
          expectedSkipOutroSeconds: originalOutro,
          isCurrent: current,
        );
        if (mounted && widget.runtime == runtime && widget.albumId == albumId) {
          setState(() {
            AppLog.instance.trace(
              'lib/pages/playback_settings_page.dart::_PlaybackSettingsPageState._getSkipRecommendation.closure#1.closure#5',
            );
            _skipResult = '已应用到本专辑';
            _integerDrafts.remove('skipIntroSeconds');
            _integerDrafts.remove('skipOutroSeconds');
          });
        }
      } catch (error, stack) {
        if (!mounted || widget.runtime != runtime || widget.albumId != albumId)
          return;
        if (error is XmlyException &&
            error.code == 'skip_recommendation_stale') {
          setState(() {
            AppLog.instance.trace(
              'lib/pages/playback_settings_page.dart::_PlaybackSettingsPageState._getSkipRecommendation.closure#1.closure#6',
            );
            _skipResult = error.message;
          });
          return;
        }
        if (!applying && !current()) return;
        if (error is! XmlyException &&
            !(error is StorageException &&
                const {'too_large', 'secret_in_state'}.contains(error.code)) &&
            !AppLog.instance.errorWasRecorded(error)) {
          AppLog.instance.write(
            AppLogLevel.error,
            'settings',
            applying
                ? 'Applying skip recommendation failed'
                : 'Reading skip recommendation failed',
            error: error,
            stackTrace: stack,
            promptUser: applying,
          );
        }
        setState(() {
          AppLog.instance.trace(
            'lib/pages/playback_settings_page.dart::_PlaybackSettingsPageState._getSkipRecommendation.closure#1.closure#7',
          );
          _error = applying ? '设置保存或应用失败，请重试' : null;
          _skipResult = applying ? null : '暂时无法获取建议';
        });
      } finally {
        _recommendationCurrent = null;
        if (mounted) {
          setState(() {
            AppLog.instance.trace(
              'lib/pages/playback_settings_page.dart::_PlaybackSettingsPageState._getSkipRecommendation.closure#1.closure#8',
            );
            _busy = false;
          });
          widget.onSavingChanged?.call(false);
        }
      }
    });
  }

  String _source(String key) {
    AppLog.instance.trace(
      "lib/pages/playback_settings_page.dart::_PlaybackSettingsPageState._source",
    );
    return widget.albumId == null
        ? '全局设置'
        : _album.containsKey(key)
        ? '专辑设置'
        : '继承全局';
  }

  Future<void> _save(String key, Object? value) {
    AppLog.instance.trace(
      "lib/pages/playback_settings_page.dart::_PlaybackSettingsPageState._save",
    );
    return AppLog.instance.runWithErrorScope(() async {
      AppLog.instance.trace(
        "lib/pages/playback_settings_page.dart::_PlaybackSettingsPageState._save.closure#1",
      );

      if (_busy) return;
      setState(() {
        AppLog.instance.trace(
          "lib/pages/playback_settings_page.dart::_PlaybackSettingsPageState._save.closure#1.closure#1",
        );

        _busy = true;
        _error = null;
      });
      widget.onSavingChanged?.call(true);
      try {
        await persistPlaybackSetting(
          widget.runtime,
          key,
          value,
          albumId: widget.albumId,
        );
        _integerDrafts.remove(key);
      } on FormatException catch (error) {
        if (mounted)
          setState(() {
            AppLog.instance.trace(
              "lib/pages/playback_settings_page.dart::_PlaybackSettingsPageState._save.closure#1.closure#2",
            );
            _error = error.message;
          });
      } catch (error, stack) {
        if (!(error is StorageException &&
                const {'too_large', 'secret_in_state'}.contains(error.code)) &&
            !AppLog.instance.errorWasRecorded(error)) {
          AppLog.instance.write(
            AppLogLevel.error,
            'settings',
            'Applying playback settings failed',
            error: error,
            stackTrace: stack,
            promptUser: true,
          );
        }
        if (mounted)
          setState(() {
            AppLog.instance.trace(
              "lib/pages/playback_settings_page.dart::_PlaybackSettingsPageState._save.closure#1.closure#3",
            );
            _error = '设置保存或应用失败，请重试';
          });
      } finally {
        if (mounted) {
          setState(() {
            AppLog.instance.trace(
              "lib/pages/playback_settings_page.dart::_PlaybackSettingsPageState._save.closure#1.closure#4",
            );
            _busy = false;
          });
          widget.onSavingChanged?.call(false);
        }
      }
    });
  }

  Widget _inherit(String key) {
    AppLog.instance.trace(
      "lib/pages/playback_settings_page.dart::_PlaybackSettingsPageState._inherit",
    );
    return widget.albumId != null && _album.containsKey(key)
        ? TextButton(
            key: ValueKey('inherit:$key'),
            onPressed: _busy
                ? null
                : () {
                    AppLog.instance.trace(
                      "lib/pages/playback_settings_page.dart::_PlaybackSettingsPageState._inherit.closure#1",
                    );
                    _save(key, null);
                  },
            child: const Text('恢复继承全局'),
          )
        : const SizedBox.shrink();
  }

  Widget _section(
    String title,
    List<Widget> children, {
    bool expandable = false,
  }) {
    AppLog.instance.trace(
      "lib/pages/playback_settings_page.dart::_PlaybackSettingsPageState._section",
    );
    return widget.quick && expandable
        ? Padding(
            padding: const EdgeInsets.only(bottom: 20),
            child: Card(
              margin: EdgeInsets.zero,
              child: ExpansionTile(title: Text(title), children: children),
            ),
          )
        : _sectionBody(title, children);
  }

  Widget _sectionBody(String title, List<Widget> children) {
    AppLog.instance.trace(
      "lib/pages/playback_settings_page.dart::_PlaybackSettingsPageState._sectionBody",
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 12),
            child: Text(
              title,
              style: Theme.of(context).textTheme.titleSmall
                  ?.copyWith(color: Theme.of(context).colorScheme.primary),
            ),
          ),
          Card(
            margin: EdgeInsets.zero,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: children,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _slider(
    String key,
    String title,
    double value,
    double min,
    double max,
    int divisions,
    String Function(double) label,
  ) {
    AppLog.instance.trace(
      "lib/pages/playback_settings_page.dart::_PlaybackSettingsPageState._slider",
    );

    final current = _drafts[key] ?? value;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              const SizedBox(width: 12),
              Text(
                label(current),
                style: Theme.of(context).textTheme.titleMedium
                    ?.copyWith(color: Theme.of(context).colorScheme.primary),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            _source(key),
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          Slider(
            key: ValueKey(key),
            value: current.clamp(min, max).toDouble(),
            min: min,
            max: max,
            divisions: divisions,
            label: label(current),
            semanticFormatterCallback: label,
            onChanged: _busy
                ? null
                : (value) {
                    AppLog.instance.trace(
                      "lib/pages/playback_settings_page.dart::_PlaybackSettingsPageState._slider.closure#1",
                    );
                    setState(() {
                      AppLog.instance.trace(
                        "lib/pages/playback_settings_page.dart::_PlaybackSettingsPageState._slider.closure#1.closure#1",
                      );
                      _drafts[key] = value;
                    });
                  },
            onChangeEnd: _busy
                ? null
                : (value) async {
                    AppLog.instance.trace(
                      "lib/pages/playback_settings_page.dart::_PlaybackSettingsPageState._slider.closure#2",
                    );

                    await _save(key, double.parse(value.toStringAsFixed(2)));
                    if (mounted)
                      setState(() {
                        AppLog.instance.trace(
                          "lib/pages/playback_settings_page.dart::_PlaybackSettingsPageState._slider.closure#2.closure#1",
                        );
                        _drafts.remove(key);
                      });
                  },
          ),
          if (key == 'speed')
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final speed in [0.75, 1.0, 1.25, 1.5, 2.0])
                  ChoiceChip(
                    showCheckmark: false,
                    label: Text('${speed}×'),
                    selected: current == speed,
                    onSelected: _busy
                        ? null
                        : (_) {
                            AppLog.instance.trace(
                              "lib/pages/playback_settings_page.dart::_PlaybackSettingsPageState._slider.closure#3",
                            );
                            _save(key, speed);
                          },
                  ),
              ],
            ),
          _inherit(key),
        ],
      ),
    );
  }

  Future<void> _saveSeconds(
    String key,
    String title,
    String text,
    int min,
    int max,
  ) async {
    AppLog.instance.trace(
      "lib/pages/playback_settings_page.dart::_PlaybackSettingsPageState._saveSeconds",
    );

    final parsed = int.tryParse(text);
    if (parsed == null || parsed < min || parsed > max) {
      setState(() {
        AppLog.instance.trace(
          "lib/pages/playback_settings_page.dart::_PlaybackSettingsPageState._saveSeconds.closure#1",
        );
        _error = '$title请输入 $min–$max 秒';
      });
      return;
    }
    await _save(key, parsed);
  }

  Widget _number(String key, String title, int value, int min, int max) {
    AppLog.instance.trace(
      "lib/pages/playback_settings_page.dart::_PlaybackSettingsPageState._number",
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            '${_source(key)} · $min–$max 秒',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              IconButton(
                tooltip: '$title减少 1 秒',
                icon: const Icon(Icons.remove_rounded),
                onPressed: _busy || value <= min
                    ? null
                    : () {
                        AppLog.instance.trace(
                          "lib/pages/playback_settings_page.dart::_PlaybackSettingsPageState._number.closure#1",
                        );
                        _save(key, value - 1);
                      },
              ),
              Expanded(
                child: TextFormField(
                  key: ValueKey('$key:$value:$_busy:$_integerDraftRevision'),
                  initialValue: _integerDrafts[key] ?? '$value',
                  enabled: !_busy,
                  textAlign: TextAlign.center,
                  keyboardType: TextInputType.number,
                  textInputAction: TextInputAction.done,
                  decoration: InputDecoration(
                    labelText: title,
                    suffixText: '秒',
                    suffixIcon: IconButton(
                      key: ValueKey('saveSeconds:$key'),
                      tooltip: '保存$title',
                      onPressed: _busy
                          ? null
                          : () {
                              AppLog.instance.trace(
                                "lib/pages/playback_settings_page.dart::_PlaybackSettingsPageState._number.closure#2",
                              );

                              _saveSeconds(
                                key,
                                title,
                                _integerDrafts[key] ?? '$value',
                                min,
                                max,
                              );
                            },
                      icon: const Icon(Icons.check_rounded),
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 12,
                    ),
                  ),
                  onChanged: (text) {
                    AppLog.instance.trace(
                      "lib/pages/playback_settings_page.dart::_PlaybackSettingsPageState._number.closure#3",
                    );
                    setState(() {
                      AppLog.instance.trace(
                        'lib/pages/playback_settings_page.dart::_PlaybackSettingsPageState._number.closure#3.closure#1',
                      );
                      _integerDrafts[key] = text;
                    });
                  },
                  onFieldSubmitted: (text) {
                    AppLog.instance.trace(
                      "lib/pages/playback_settings_page.dart::_PlaybackSettingsPageState._number.closure#4",
                    );
                    _saveSeconds(key, title, text, min, max);
                  },
                ),
              ),
              IconButton(
                tooltip: '$title增加 1 秒',
                icon: const Icon(Icons.add_rounded),
                onPressed: _busy || value >= max
                    ? null
                    : () {
                        AppLog.instance.trace(
                          "lib/pages/playback_settings_page.dart::_PlaybackSettingsPageState._number.closure#5",
                        );
                        _save(key, value + 1);
                      },
              ),
            ],
          ),
          if (key == 'skipIntroSeconds' || key == 'skipOutroSeconds')
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                for (final seconds in const [0, 15, 30, 60, 90, 120])
                  ChoiceChip(
                    showCheckmark: false,
                    label: Text(seconds == 0 ? '不跳过' : '$seconds 秒'),
                    selected:
                        (int.tryParse(_integerDrafts[key] ?? '') ?? value) ==
                        seconds,
                    onSelected: _busy
                        ? null
                        : (_) {
                            AppLog.instance.trace(
                              'lib/pages/playback_settings_page.dart::_PlaybackSettingsPageState._number.closure#6',
                            );
                            setState(() {
                              AppLog.instance.trace(
                                'lib/pages/playback_settings_page.dart::_PlaybackSettingsPageState._number.closure#6.closure#1',
                              );
                              _integerDrafts[key] = '$seconds';
                              _integerDraftRevision++;
                            });
                          },
                    visualDensity: VisualDensity.compact,
                  ),
              ],
            ),
          _inherit(key),
        ],
      ),
    );
  }

  Widget _toggle(String key, String title, bool value) {
    AppLog.instance.trace(
      "lib/pages/playback_settings_page.dart::_PlaybackSettingsPageState._toggle",
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SwitchListTile(
          key: ValueKey(key),
          title: Text(title),
          subtitle: Text(_source(key)),
          value: value,
          onChanged: _busy
              ? null
              : (value) {
                  AppLog.instance.trace(
                    "lib/pages/playback_settings_page.dart::_PlaybackSettingsPageState._toggle.closure#1",
                  );
                  _save(key, value);
                },
        ),
        Padding(padding: const EdgeInsets.only(left: 16), child: _inherit(key)),
      ],
    );
  }

  Future<void> _sync(bool value) async {
    AppLog.instance.trace(
      "lib/pages/playback_settings_page.dart::_PlaybackSettingsPageState._sync",
    );

    if (value) {
      final allowed = await showDialog<bool>(
        context: context,
        builder: (context) {
          AppLog.instance.trace(
            "lib/pages/playback_settings_page.dart::_PlaybackSettingsPageState._sync.closure#1",
          );
          return AlertDialog(
            title: const Text('上传收听进度？'),
            content: const Text('开启后会向当前账号上传在线播放和本地播放进度。'),
            actions: [
              TextButton(
                onPressed: () {
                  AppLog.instance.trace(
                    "lib/pages/playback_settings_page.dart::_PlaybackSettingsPageState._sync.closure#1.closure#1",
                  );
                  Navigator.pop(context, false);
                },
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () {
                  AppLog.instance.trace(
                    "lib/pages/playback_settings_page.dart::_PlaybackSettingsPageState._sync.closure#1.closure#2",
                  );
                  Navigator.pop(context, true);
                },
                child: const Text('开启上传'),
              ),
            ],
          );
        },
      );
      if (allowed != true || !mounted) return;
    }
    await _save('syncHistory', value);
  }

  Future<void> _retryHistory() {
    AppLog.instance.trace(
      "lib/pages/playback_settings_page.dart::_PlaybackSettingsPageState._retryHistory",
    );
    return AppLog.instance.runWithErrorScope(() async {
      AppLog.instance.trace(
        "lib/pages/playback_settings_page.dart::_PlaybackSettingsPageState._retryHistory.closure#1",
      );

      if (_busy) return;
      setState(() {
        AppLog.instance.trace(
          "lib/pages/playback_settings_page.dart::_PlaybackSettingsPageState._retryHistory.closure#1.closure#1",
        );

        _busy = true;
        _error = null;
        _historyResult = null;
      });
      try {
        await widget.runtime.player.retryHistory();
        if (mounted)
          setState(() {
            AppLog.instance.trace(
              "lib/pages/playback_settings_page.dart::_PlaybackSettingsPageState._retryHistory.closure#1.closure#2",
            );
            _historyResult = '历史同步完成';
          });
      } catch (error, stack) {
        if (!(error is XmlyException &&
                const {
                  'history_unavailable',
                  'history_interrupted',
                  'history_unconfirmed',
                  'login_required',
                  'login_expired',
                  'auth_required',
                  'client_closed',
                  'request_cancelled',
                }.contains(error.code)) &&
            !AppLog.instance.errorWasRecorded(error)) {
          AppLog.instance.write(
            AppLogLevel.error,
            'settings',
            'Retrying playback history failed',
            error: error,
            stackTrace: stack,
            promptUser: true,
          );
        }
        if (mounted) {
          setState(() {
            AppLog.instance.trace(
              "lib/pages/playback_settings_page.dart::_PlaybackSettingsPageState._retryHistory.closure#1.closure#3",
            );

            final code = error is XmlyException ? error.code : null;
            if (code != 'history_unavailable' &&
                code != 'history_interrupted') {
              _error = '历史同步失败，进度已保留';
            }
            _historyResult = switch (code) {
              'history_unconfirmed' => '部分进度未获确认，请稍后手动重试',
              'history_unavailable' => '请先登录并开启历史同步',
              'history_interrupted' => '账号或同步设置已变更，请重新操作',
              _ => null,
            };
          });
        }
      } finally {
        if (mounted)
          setState(() {
            AppLog.instance.trace(
              "lib/pages/playback_settings_page.dart::_PlaybackSettingsPageState._retryHistory.closure#1.closure#4",
            );
            _busy = false;
          });
      }
    });
  }

  Future<void> _downloadOption(String key, bool value) {
    AppLog.instance.trace(
      "lib/pages/playback_settings_page.dart::_PlaybackSettingsPageState._downloadOption",
    );
    return AppLog.instance.runWithErrorScope(() async {
      AppLog.instance.trace(
        "lib/pages/playback_settings_page.dart::_PlaybackSettingsPageState._downloadOption.closure#1",
      );

      if (_busy) return;
      setState(() {
        AppLog.instance.trace(
          "lib/pages/playback_settings_page.dart::_PlaybackSettingsPageState._downloadOption.closure#1.closure#1",
        );

        _busy = true;
        _error = null;
      });
      try {
        await widget.runtime.storage.transaction((state) {
          AppLog.instance.trace(
            "lib/pages/playback_settings_page.dart::_PlaybackSettingsPageState._downloadOption.closure#1.closure#2",
          );

          final download = (state['settings'] as Map).putIfAbsent(
            'download',
            () {
              AppLog.instance.trace(
                "lib/pages/playback_settings_page.dart::_PlaybackSettingsPageState._downloadOption.closure#1.closure#2.closure#1",
              );
              return <String, dynamic>{};
            },
          ) as Map;
          download[key] = value;
        });
        widget.runtime.changed();
      } catch (error, stack) {
        if (!(error is StorageException &&
                const {'too_large', 'secret_in_state'}.contains(error.code)) &&
            !AppLog.instance.errorWasRecorded(error)) {
          AppLog.instance.write(
            AppLogLevel.error,
            'settings',
            'Saving playback download option failed',
            error: error,
            stackTrace: stack,
            promptUser: true,
          );
        }
        if (mounted)
          setState(() {
            AppLog.instance.trace(
              "lib/pages/playback_settings_page.dart::_PlaybackSettingsPageState._downloadOption.closure#1.closure#3",
            );
            _error = '设置保存失败';
          });
      } finally {
        if (mounted)
          setState(() {
            AppLog.instance.trace(
              "lib/pages/playback_settings_page.dart::_PlaybackSettingsPageState._downloadOption.closure#1.closure#4",
            );
            _busy = false;
          });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    AppLog.instance.trace(
      "lib/pages/playback_settings_page.dart::_PlaybackSettingsPageState.build",
    );

    final content = ListenableBuilder(
      listenable: widget.runtime,
      builder: (context, _) {
        AppLog.instance.trace(
          "lib/pages/playback_settings_page.dart::_PlaybackSettingsPageState.build.closure#1",
        );

        PlaybackSettings resolved;
        try {
          resolved = PlaybackSettings.resolve(
            _global,
            widget.albumId == null ? const {} : _album,
          );
        } on FormatException catch (error) {
          return Center(child: Text('播放设置无效：${error.message}'));
        }
        final download = _settings['download'] as Map? ?? const {};
        return SafeArea(
          top: false,
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 720),
              child: ListView(
                padding: EdgeInsets.all(
                  MediaQuery.sizeOf(context).width < 320 ? 8 : 16,
                ),
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(8, 0, 8, 20),
                    child: Text(
                      widget.albumId == null
                          ? '对所有专辑生效；专辑可单独设置。'
                          : '${widget.albumTitle?.isNotEmpty == true ? widget.albumTitle : '当前专辑'} · 未单独设置的项目继承全局',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ),
                  if (_busy) const LinearProgressIndicator(),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Text(
                        _error!,
                        key: const ValueKey('playbackError'),
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                  if (!widget.skipOnly)
                    _section('声音', [
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                '主音量',
                                style: Theme.of(context).textTheme.titleMedium,
                              ),
                            ),
                            PlaybackVolumeControl(runtime: widget.runtime),
                          ],
                        ),
                      ),
                      Padding(
                        padding: EdgeInsets.symmetric(horizontal: 16),
                        child: Text(
                          '所有专辑共用，专辑音量可单独调整。',
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurfaceVariant,
                              ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      _slider('speed', '播放倍速', resolved.speed, 0.5, 3, 25, (
                        value,
                      ) {
                        AppLog.instance.trace(
                          "lib/pages/playback_settings_page.dart::_PlaybackSettingsPageState.build.closure#1.closure#1",
                        );
                        return '${value.toStringAsFixed(2)}×';
                      }),
                      const SizedBox(height: 12),
                      _slider(
                        'volume',
                        widget.albumId == null ? '默认专辑音量' : '专辑音量',
                        resolved.volume,
                        0,
                        100,
                        100,
                        (value) {
                          AppLog.instance.trace(
                            "lib/pages/playback_settings_page.dart::_PlaybackSettingsPageState.build.closure#1.closure#2",
                          );
                          return '${value.round()}%';
                        },
                      ),
                    ]),
                  _section('跳过与快进', [
                    const Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      child: Text('输入秒数后点勾保存，设为 0 则不跳过。'),
                    ),
                    _number(
                      'skipIntroSeconds',
                      '跳过片头',
                      resolved.skipIntroSeconds,
                      0,
                      3600,
                    ),
                    _number(
                      'skipOutroSeconds',
                      '跳过片尾',
                      resolved.skipOutroSeconds,
                      0,
                      3600,
                    ),
                    if (widget.albumId != null) ...[
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: OutlinedButton.icon(
                            key: const ValueKey('getSkipRecommendation'),
                            onPressed: _busy ? null : _getSkipRecommendation,
                            style: OutlinedButton.styleFrom(
                              minimumSize: const Size(48, 48),
                            ),
                            icon: const Icon(Icons.auto_fix_high_outlined),
                            label: const Text('获取建议'),
                          ),
                        ),
                      ),
                      if (_skipResult != null)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                          child: Text(
                            _skipResult!,
                            key: const ValueKey('skipRecommendationResult'),
                          ),
                        ),
                    ],
                    if (!widget.quick && !widget.skipOnly) ...[
                      _number(
                        'seekBackwardSeconds',
                        '后退间隔',
                        resolved.seekBackwardSeconds,
                        1,
                        300,
                      ),
                      _number(
                        'seekForwardSeconds',
                        '前进间隔',
                        resolved.seekForwardSeconds,
                        1,
                        300,
                      ),
                    ],
                    if ((widget.albumId == null ||
                            widget.runtime.player.current?.albumId ==
                                widget.albumId) &&
                        widget.runtime.player.duration > 0 &&
                        (int.tryParse(
                                      _integerDrafts['skipIntroSeconds'] ?? '',
                                    ) ??
                                    resolved.skipIntroSeconds) +
                                (int.tryParse(
                                      _integerDrafts['skipOutroSeconds'] ?? '',
                                    ) ??
                                    resolved.skipOutroSeconds) >=
                            widget.runtime.player.duration)
                      const Padding(
                        padding: EdgeInsets.all(16),
                        child: Text('本集较短，将完整播放。'),
                      ),
                  ], expandable: !widget.skipOnly),
                  if (!widget.skipOnly)
                    _section('播放方式', [
                      _toggle('autoNext', '自动播放下一集', resolved.autoNext),
                      if (!widget.quick)
                        _toggle(
                          'listenAndDownload',
                          '默认边听边下',
                          resolved.listenAndDownload,
                        ),
                      Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '播放顺序',
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                            const SizedBox(height: 4),
                            Text(
                              _source('loopMode'),
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurfaceVariant,
                                  ),
                            ),
                            const SizedBox(height: 12),
                            _PlaybackChoices<String>(
                              key: const ValueKey('loopModeOptions'),
                              options: const [
                                ('off', '顺序播放'),
                                ('single', '单集循环'),
                                ('all', '列表循环'),
                                ('shuffle', '随机播放'),
                              ],
                              selected: resolved.loopMode,
                              onSelected: _busy
                                  ? null
                                  : (value) {
                                      AppLog.instance.trace(
                                        "lib/pages/playback_settings_page.dart::_PlaybackSettingsPageState.build.closure#1.closure#3",
                                      );
                                      _save('loopMode', value);
                                    },
                            ),
                            _inherit('loopMode'),
                          ],
                        ),
                      ),
                    ]),
                  if (!widget.skipOnly) ...[
                    if (widget.quick)
                      ListTile(
                        title: const Text('完整播放设置'),
                        subtitle: const Text('快进间隔、边听边下及其他偏好'),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: _busy ? null : widget.onOpenFullSettings,
                      )
                    else if (widget.albumId == null) ...[
                      _section('历史恢复', [
                        _toggle(
                          'disableLocalResume',
                          '禁用本地恢复',
                          resolved.disableLocalResume,
                        ),
                        _toggle(
                          'disableCloudResume',
                          '禁用云端恢复',
                          resolved.disableCloudResume,
                        ),
                      ]),
                      _section('历史同步', [
                        SwitchListTile(
                          key: const ValueKey('syncHistory'),
                          title: const Text('上传云端收听进度'),
                          subtitle: const Text('仅控制上传，不影响云端恢复'),
                          value: _global['syncHistory'] == true,
                          onChanged: _busy ? null : _sync,
                        ),
                        ListTile(
                          title: const Text('重试进度上传'),
                          subtitle: _historyResult == null
                              ? null
                              : Text(_historyResult!),
                          trailing: const Icon(Icons.sync),
                          onTap: _busy ? null : _retryHistory,
                        ),
                      ]),
                      _section('下载与定时', [
                        SwitchListTile(
                          title: const Text('暂停播放时也暂停当前下载'),
                          value: download['pauseDownloadWithPlayback'] == true,
                          onChanged: _busy
                              ? null
                              : (value) {
                                  AppLog.instance.trace(
                                    "lib/pages/playback_settings_page.dart::_PlaybackSettingsPageState.build.closure#1.closure#4",
                                  );
                                  _downloadOption(
                                    'pauseDownloadWithPlayback',
                                    value,
                                  );
                                },
                        ),
                        SwitchListTile(
                          title: const Text('定时结束后继续下载'),
                          value: download['continueDownloadAfterSleep'] == true,
                          onChanged: _busy
                              ? null
                              : (value) {
                                  AppLog.instance.trace(
                                    "lib/pages/playback_settings_page.dart::_PlaybackSettingsPageState.build.closure#1.closure#5",
                                  );
                                  _downloadOption(
                                    'continueDownloadAfterSleep',
                                    value,
                                  );
                                },
                        ),
                        ListTile(
                          title: const Text('定时关闭偏好'),
                          trailing: const Icon(Icons.timer_outlined),
                          onTap: _busy
                              ? null
                              : () {
                                  AppLog.instance.trace(
                                    "lib/pages/playback_settings_page.dart::_PlaybackSettingsPageState.build.closure#1.closure#6",
                                  );
                                  showSleepTimerDialog(
                                    context,
                                    widget.runtime,
                                    startTimer: false,
                                  );
                                },
                        ),
                      ]),
                    ] else
                      ListTile(
                        title: const Text('全局播放设置'),
                        subtitle: const Text('历史同步、下载与定时偏好'),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: _busy
                            ? null
                            : widget.onOpenGlobalSettings ??
                                  () {
                                    AppLog.instance.trace(
                                      "lib/pages/playback_settings_page.dart::_PlaybackSettingsPageState.build.closure#1.closure#7",
                                    );
                                    showQuickPlaybackSettings(
                                      context,
                                      widget.runtime,
                                    );
                                  },
                      ),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
    return widget.embedded
        ? PopScope(canPop: !_busy, child: content)
        : Scaffold(
            appBar: AppHeader(title: const Text('播放设置')),
            body: content,
          );
  }
}

class _PlaybackChoices<T> extends StatelessWidget {
  const _PlaybackChoices({
    required this.options,
    required this.selected,
    required this.onSelected,
    this.minimumWidth = 128,
    super.key,
  });

  final List<(T, String)> options;
  final T selected;
  final ValueChanged<T>? onSelected;
  final double minimumWidth;

  @override
  Widget build(BuildContext context) {
    AppLog.instance.trace(
      "lib/pages/playback_settings_page.dart::_PlaybackChoices.build",
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        AppLog.instance.trace(
          "lib/pages/playback_settings_page.dart::_PlaybackChoices.build.closure#1",
        );

        final theme = Theme.of(context);
        final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
        final columns =
            ((constraints.maxWidth + 8) / (minimumWidth * scale + 8))
                .floor()
                .clamp(1, options.length);
        final width = (constraints.maxWidth - (columns - 1) * 8) / columns;
        return Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final option in options)
              SizedBox(
                width: width,
                child: ChoiceChip(
                  key: ValueKey(option.$1),
                  showCheckmark: false,
                  labelPadding: EdgeInsets.zero,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 10,
                  ),
                  label: Center(
                    child: Text(option.$2, textAlign: TextAlign.center),
                  ),
                  selected: selected == option.$1,
                  selectedColor: theme.colorScheme.primaryContainer,
                  backgroundColor: theme.colorScheme.surfaceContainerLow,
                  labelStyle: TextStyle(
                    color: selected == option.$1
                        ? theme.colorScheme.onPrimaryContainer
                        : theme.colorScheme.onSurface,
                  ),
                  side: BorderSide(
                    color: selected == option.$1
                        ? theme.colorScheme.primary.withValues(alpha: 0.6)
                        : theme.colorScheme.outlineVariant.withValues(
                            alpha: 0.6,
                          ),
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  onSelected: onSelected == null
                      ? null
                      : (_) {
                          AppLog.instance.trace(
                            "lib/pages/playback_settings_page.dart::_PlaybackChoices.build.closure#1.closure#1",
                          );
                          onSelected!(option.$1);
                        },
                ),
              ),
          ],
        );
      },
    );
  }
}

Future<void> showSleepTimerDialog(
  BuildContext context,
  AppRuntime runtime, {
  bool startTimer = true,
}) {
  AppLog.instance.trace(
    "lib/pages/playback_settings_page.dart::showSleepTimerDialog",
  );
  return showLocalPanel<void>(
    context: context,
    title: startTimer ? '定时关闭' : '定时关闭偏好',
    height: 600,
    builder: (_) {
      AppLog.instance.trace(
        "lib/pages/playback_settings_page.dart::showSleepTimerDialog.closure#1",
      );
      return _SleepTimerPage(runtime: runtime, startTimer: startTimer);
    },
  );
}

class _SleepTimerPage extends StatefulWidget {
  const _SleepTimerPage({required this.runtime, required this.startTimer});
  final AppRuntime runtime;
  final bool startTimer;

  @override
  State<_SleepTimerPage> createState() {
    AppLog.instance.trace(
      "lib/pages/playback_settings_page.dart::_SleepTimerPage.createState",
    );
    return _SleepTimerPageState();
  }
}

class _SleepTimerPageState extends State<_SleepTimerPage> {
  final _form = GlobalKey<FormState>();
  late final TextEditingController _minutes;
  late final int _storedMinutes;
  late SleepMode _mode;
  late SleepAction _action;
  late bool _wait;
  late bool _customMinutes;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    AppLog.instance.trace(
      "lib/pages/playback_settings_page.dart::_SleepTimerPageState.initState",
    );

    super.initState();
    final stored = (widget.runtime.storage.state['settings'] as Map)['sleep'];
    SleepRequest request;
    try {
      request = SleepRequest.fromJson(stored is Map ? stored : const {});
    } on FormatException {
      request = SleepRequest();
    }
    _storedMinutes = request.minutes;
    _minutes = TextEditingController(text: '${request.minutes}');
    _mode = request.mode;
    _action = request.action;
    _wait = request.waitForEnd;
    _customMinutes = ![15, 30, 45, 60].contains(request.minutes);
  }

  @override
  void dispose() {
    AppLog.instance.trace(
      "lib/pages/playback_settings_page.dart::_SleepTimerPageState.dispose",
    );

    _minutes.dispose();
    super.dispose();
  }

  Future<void> _save() {
    AppLog.instance.trace(
      "lib/pages/playback_settings_page.dart::_SleepTimerPageState._save",
    );
    return AppLog.instance.runWithErrorScope(() async {
      AppLog.instance.trace(
        "lib/pages/playback_settings_page.dart::_SleepTimerPageState._save.closure#1",
      );

      if (_saving || !_form.currentState!.validate()) return;
      setState(() {
        AppLog.instance.trace(
          "lib/pages/playback_settings_page.dart::_SleepTimerPageState._save.closure#1.closure#1",
        );

        _saving = true;
        _error = null;
      });
      try {
        final enteredMinutes = int.tryParse(_minutes.text);
        final request = SleepRequest(
          mode: _mode,
          action: _action,
          minutes:
              enteredMinutes != null &&
                  enteredMinutes >= 1 &&
                  enteredMinutes <= 1440
              ? enteredMinutes
              : _storedMinutes,
          waitForEnd: _wait,
        );
        await widget.runtime.storage.transaction((state) {
          AppLog.instance.trace(
            "lib/pages/playback_settings_page.dart::_SleepTimerPageState._save.closure#1.closure#2",
          );
          (state['settings'] as Map)['sleep'] = request.toJson();
        });
        if (widget.startTimer) widget.runtime.player.setSleep(request);
        widget.runtime.changed();
        if (mounted) Navigator.pop(context);
      } catch (error, stack) {
        if (error is! FormatException &&
            !(error is StorageException &&
                const {'too_large', 'secret_in_state'}.contains(error.code)) &&
            !AppLog.instance.errorWasRecorded(error)) {
          AppLog.instance.write(
            AppLogLevel.error,
            'settings',
            'Saving sleep settings failed',
            error: error,
            stackTrace: stack,
            promptUser: true,
          );
        }
        if (mounted)
          setState(() {
            AppLog.instance.trace(
              "lib/pages/playback_settings_page.dart::_SleepTimerPageState._save.closure#1.closure#3",
            );

            _saving = false;
            _error = '定时设置保存失败';
          });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    AppLog.instance.trace(
      "lib/pages/playback_settings_page.dart::_SleepTimerPageState.build",
    );
    return PopScope(
      canPop: !_saving,
      child: SafeArea(
        top: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Form(
              key: _form,
              child: ListView(
                padding: EdgeInsets.all(
                  MediaQuery.sizeOf(context).width < 320 ? 8 : 24,
                ),
                children: [
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 16),
                      child: Text(
                        _error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                  Text('结束时间', style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 12),
                  _PlaybackChoices<SleepMode>(
                    key: const ValueKey('sleepModeOptions'),
                    options: const [
                      (SleepMode.afterDuration, '倒计时'),
                      (SleepMode.endOfTrack, '本集结束'),
                    ],
                    selected: _mode,
                    onSelected: _saving
                        ? null
                        : (value) {
                            AppLog.instance.trace(
                              "lib/pages/playback_settings_page.dart::_SleepTimerPageState.build.closure#1",
                            );
                            setState(() {
                              AppLog.instance.trace(
                                "lib/pages/playback_settings_page.dart::_SleepTimerPageState.build.closure#1.closure#1",
                              );
                              _mode = value;
                            });
                          },
                  ),
                  const SizedBox(height: 20),
                  AnimatedSize(
                    duration: MediaQuery.disableAnimationsOf(context)
                        ? Duration.zero
                        : const Duration(milliseconds: 220),
                    curve: Curves.easeOutCubic,
                    alignment: Alignment.topCenter,
                    child: _mode != SleepMode.afterDuration
                        ? const SizedBox(width: double.infinity)
                        : Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '时长（分钟）',
                                style: Theme.of(context).textTheme.titleMedium,
                              ),
                              const SizedBox(height: 12),
                              _PlaybackChoices<int?>(
                                key: const ValueKey('sleepDurationOptions'),
                                options: const [
                                  (15, '15'),
                                  (30, '30'),
                                  (45, '45'),
                                  (60, '60'),
                                  (null, '自定义'),
                                ],
                                selected: _customMinutes
                                    ? null
                                    : int.tryParse(_minutes.text),
                                minimumWidth: 76,
                                onSelected: _saving
                                    ? null
                                    : (value) {
                                        AppLog.instance.trace(
                                          "lib/pages/playback_settings_page.dart::_SleepTimerPageState.build.closure#2",
                                        );
                                        setState(() {
                                          AppLog.instance.trace(
                                            "lib/pages/playback_settings_page.dart::_SleepTimerPageState.build.closure#2.closure#1",
                                          );

                                          _customMinutes = value == null;
                                          if (value != null)
                                            _minutes.text = '$value';
                                        });
                                      },
                              ),
                              AnimatedSize(
                                duration:
                                    MediaQuery.disableAnimationsOf(context)
                                    ? Duration.zero
                                    : const Duration(milliseconds: 180),
                                curve: Curves.easeOutCubic,
                                alignment: Alignment.topCenter,
                                child: !_customMinutes
                                    ? const SizedBox(width: double.infinity)
                                    : Padding(
                                        padding: const EdgeInsets.only(top: 16),
                                        child: TextFormField(
                                          key: const ValueKey('sleepMinutes'),
                                          controller: _minutes,
                                          enabled: !_saving,
                                          decoration: const InputDecoration(
                                            labelText: '自定义分钟（1–1440）',
                                          ),
                                          keyboardType: TextInputType.number,
                                          validator: (text) {
                                            AppLog.instance.trace(
                                              "lib/pages/playback_settings_page.dart::_SleepTimerPageState.build.closure#3",
                                            );

                                            final n = int.tryParse(text ?? '');
                                            return n == null ||
                                                    n < 1 ||
                                                    n > 1440
                                                ? '请输入 1–1440 分钟'
                                                : null;
                                          },
                                        ),
                                      ),
                              ),
                              const SizedBox(height: 8),
                              CheckboxListTile(
                                contentPadding: EdgeInsets.zero,
                                title: const Text('到时等待本集结束'),
                                value: _wait,
                                onChanged: _saving
                                    ? null
                                    : (value) {
                                        AppLog.instance.trace(
                                          "lib/pages/playback_settings_page.dart::_SleepTimerPageState.build.closure#4",
                                        );

                                        setState(() {
                                          AppLog.instance.trace(
                                            "lib/pages/playback_settings_page.dart::_SleepTimerPageState.build.closure#4.closure#1",
                                          );
                                          _wait = value == true;
                                        });
                                      },
                              ),
                              const SizedBox(height: 20),
                            ],
                          ),
                  ),
                  Text('结束动作', style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 12),
                  _PlaybackChoices<SleepAction>(
                    key: const ValueKey('sleepActionOptions'),
                    options: const [
                      (SleepAction.pause, '暂停播放'),
                      (SleepAction.exit, '保存并退出'),
                    ],
                    selected: _action,
                    onSelected: _saving
                        ? null
                        : (value) {
                            AppLog.instance.trace(
                              "lib/pages/playback_settings_page.dart::_SleepTimerPageState.build.closure#5",
                            );
                            setState(() {
                              AppLog.instance.trace(
                                "lib/pages/playback_settings_page.dart::_SleepTimerPageState.build.closure#5.closure#1",
                              );
                              _action = value;
                            });
                          },
                  ),
                  const SizedBox(height: 28),
                  OverflowBar(
                    alignment: MainAxisAlignment.end,
                    spacing: 8,
                    overflowSpacing: 8,
                    children: [
                      TextButton(
                        onPressed: _saving
                            ? null
                            : () {
                                AppLog.instance.trace(
                                  "lib/pages/playback_settings_page.dart::_SleepTimerPageState.build.closure#6",
                                );
                                Navigator.pop(context);
                              },
                        child: const Text('取消'),
                      ),
                      FilledButton(
                        key: const ValueKey('saveSleep'),
                        onPressed: _saving ? null : _save,
                        child: Text(
                          _saving
                              ? '正在保存'
                              : widget.startTimer
                              ? '开始定时'
                              : '保存偏好',
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
