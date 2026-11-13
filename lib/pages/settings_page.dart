// Wide/narrow settings layout adapted from PiliPlus
// lib/pages/setting/view.dart, commit
// d9e9626f1a3f89cd9ca85e18f61aaba02634e12a (GNU GPL v3).
// Source: https://github.com/bggRGjQaUbCoE/PiliPlus
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:path/path.dart' as p;

import '../common/theme.dart';
import '../common/widgets/adaptive_text.dart';
import '../common/widgets/app_header.dart';
import '../services/app_runtime.dart';
import '../services/app_log.dart';
import '../services/update_service.dart';
import 'account_page.dart';
import 'backup_page.dart';
import 'download_settings_page.dart';
import 'developer_settings_page.dart';
import 'media_settings_page.dart';
import 'playback_settings_page.dart';
import 'theme_color_editor.dart';
import 'window_close_preferences.dart';

enum _SettingsSection {
  account,
  download,
  media,
  playback,
  appearance,
  backup,
  developer,
  about,
}

class SettingsPage extends StatefulWidget {
  const SettingsPage({
    required this.appearance,
    required this.runtime,
    required this.updates,
    super.key,
  });

  final AppAppearance appearance;
  final AppRuntime runtime;
  final UpdateService updates;

  @override
  State<SettingsPage> createState() {
    AppLog.instance.trace(
      "lib/pages/settings_page.dart::SettingsPage.createState",
    );
    return _SettingsPageState();
  }
}

class _SettingsPageState extends State<SettingsPage> {
  _SettingsSection _section = _SettingsSection.appearance;

  static const _items = [
    (
      title: '账号',
      icon: Icons.person_outline,
      section: _SettingsSection.account,
    ),
    (
      title: '下载',
      icon: Icons.download_outlined,
      section: _SettingsSection.download,
    ),
    (title: '媒体处理', icon: Icons.tune, section: _SettingsSection.media),
    (
      title: '播放',
      icon: Icons.headphones_outlined,
      section: _SettingsSection.playback,
    ),
    (
      title: '外观',
      icon: Icons.palette_outlined,
      section: _SettingsSection.appearance,
    ),
    (
      title: '备份与恢复',
      icon: Icons.settings_backup_restore,
      section: _SettingsSection.backup,
    ),
    (
      title: '开发',
      icon: Icons.developer_mode_outlined,
      section: _SettingsSection.developer,
    ),
    (title: '关于', icon: Icons.info_outline, section: _SettingsSection.about),
  ];

  Widget _detail(_SettingsSection section) {
    AppLog.instance.trace(
      "lib/pages/settings_page.dart::_SettingsPageState._detail",
    );
    return switch (section) {
      _SettingsSection.download => DownloadSettingsPage(
        runtime: widget.runtime,
      ),
      _SettingsSection.media => MediaSettingsPage(runtime: widget.runtime),
      _SettingsSection.playback => PlaybackSettingsPage(
        runtime: widget.runtime,
        embedded: true,
      ),
      _SettingsSection.account => AccountPage(
        storage: widget.runtime.storage,
        accounts: widget.runtime.accounts,
        onChanged: widget.runtime.changed,
        updates: widget.runtime,
      ),
      _SettingsSection.backup => BackupPage(
        runtime: widget.runtime,
        onChanged: widget.appearance.reload,
      ),
      _SettingsSection.appearance => _AppearanceSettings(
        appearance: widget.appearance,
        runtime: widget.runtime,
      ),
      _SettingsSection.developer => DeveloperSettingsPage(
        runtime: widget.runtime,
      ),
      _SettingsSection.about => _AboutSettings(updates: widget.updates),
    };
  }

  void _open(_SettingsSection section, String title, bool wide) {
    AppLog.instance.trace(
      "lib/pages/settings_page.dart::_SettingsPageState._open",
    );

    if (wide) {
      setState(() {
        AppLog.instance.trace(
          "lib/pages/settings_page.dart::_SettingsPageState._open.closure#1",
        );
        _section = section;
      });
    } else {
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          settings: RouteSettings(name: '/settings/${section.name}'),
          builder: (context) {
            AppLog.instance.trace(
              "lib/pages/settings_page.dart::_SettingsPageState._open.closure#2",
            );
            return Scaffold(
              appBar: AppHeader(title: AdaptiveText(title)),
              body: SafeArea(child: _detail(section)),
            );
          },
        ),
      );
    }
  }

  Widget _list(bool wide) {
    AppLog.instance.trace(
      "lib/pages/settings_page.dart::_SettingsPageState._list",
    );

    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 12),
      children: [
        for (final item in _items)
          ListTile(
            leading: Icon(item.icon),
            title: Text(
              item.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            selected: wide && item.section == _section,
            selectedTileColor: theme.colorScheme.onInverseSurface,
            trailing: !wide ? const Icon(Icons.chevron_right) : null,
            onTap: () {
              AppLog.instance.trace(
                "lib/pages/settings_page.dart::_SettingsPageState._list.closure#1",
              );
              _open(item.section, item.title, wide);
            },
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    AppLog.instance.trace(
      "lib/pages/settings_page.dart::_SettingsPageState.build",
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        AppLog.instance.trace(
          "lib/pages/settings_page.dart::_SettingsPageState.build.closure#1",
        );

        final textScale = MediaQuery.textScalerOf(context).scale(14) / 14;
        if (constraints.maxWidth < 840 ||
            constraints.maxWidth < 240 + 560 * textScale) {
          return _list(false);
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(width: 240, child: _list(true)),
            VerticalDivider(
              width: 1,
              color: Theme.of(context).colorScheme.outline
                  .withValues(alpha: 0.1),
            ),
            Expanded(child: _detail(_section)),
          ],
        );
      },
    );
  }
}

class _AppearanceSettings extends StatefulWidget {
  const _AppearanceSettings({required this.appearance, required this.runtime});

  final AppAppearance appearance;
  final AppRuntime runtime;

  @override
  State<_AppearanceSettings> createState() {
    AppLog.instance.trace(
      "lib/pages/settings_page.dart::_AppearanceSettings.createState",
    );
    return _AppearanceSettingsState();
  }
}

class _AppearanceSettingsState extends State<_AppearanceSettings> {
  bool _editingColor = false;
  AppAppearance get appearance {
    AppLog.instance.trace(
      "lib/pages/settings_page.dart::_AppearanceSettingsState.appearance.get",
    );
    return widget.appearance;
  }

  AppRuntime get runtime {
    AppLog.instance.trace(
      "lib/pages/settings_page.dart::_AppearanceSettingsState.runtime.get",
    );
    return widget.runtime;
  }

  static const _colors = [
    (label: '松绿', color: Color(AppAppearance.defaultSeedColor)),
    (label: '浅红', color: Color(0xFFE57373)),
    (label: '青绿', color: Color(0xFF006A67)),
    (label: '蓝色', color: Color(0xFF295EA6)),
    (label: '紫色', color: Color(0xFF7054A2)),
    (label: '橙色', color: Color(0xFF9C4324)),
    (label: '粉色', color: Color(0xFF994568)),
  ];

  @override
  Widget build(BuildContext context) {
    AppLog.instance.trace(
      "lib/pages/settings_page.dart::_AppearanceSettingsState.build",
    );

    return ListenableBuilder(
      listenable: appearance,
      builder: (context, _) {
        AppLog.instance.trace(
          "lib/pages/settings_page.dart::_AppearanceSettingsState.build.closure#1",
        );
        return ListView(
          padding: const EdgeInsets.all(20),
          children: [
            AdaptiveText('外观', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            if (appearance.error != null)
              Text(
                appearance.error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            const SizedBox(height: 24),
            _SettingsCard(
              title: '主题',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final option in const [
                        (label: '跟随系统', mode: ThemeMode.system),
                        (label: '浅色', mode: ThemeMode.light),
                        (label: '深色', mode: ThemeMode.dark),
                      ])
                        ChoiceChip(
                          showCheckmark: false,
                          label: Text(
                            option.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          selected: appearance.themeMode == option.mode,
                          onSelected: (_) {
                            AppLog.instance.trace(
                              "lib/pages/settings_page.dart::_AppearanceSettingsState.build.closure#1.closure#1",
                            );
                            appearance.themeMode = option.mode;
                          },
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  SwitchListTile.adaptive(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('OLED 纯黑'),
                    subtitle: const Text('仅深色主题生效，主背景使用纯黑色'),
                    value: appearance.oledBlack,
                    onChanged: (value) {
                      AppLog.instance.trace(
                        "lib/pages/settings_page.dart::_AppearanceSettingsState.build.closure#1.closure#2",
                      );
                      appearance.oledBlack = value;
                    },
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            _SettingsCard(
              title: '主题色',
              child: AnimatedSize(
                duration: MediaQuery.disableAnimationsOf(context)
                    ? Duration.zero
                    : const Duration(milliseconds: 220),
                curve: Curves.easeOutCubic,
                alignment: Alignment.topCenter,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final option in _colors)
                          ChoiceChip(
                            showCheckmark: false,
                            label: Text(
                              option.label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            avatar: CircleAvatar(
                              backgroundColor: option.color,
                              radius: 8,
                            ),
                            selected: appearance.seedColor == option.color,
                            onSelected: (_) {
                              AppLog.instance.trace(
                                "lib/pages/settings_page.dart::_AppearanceSettingsState.build.closure#1.closure#3",
                              );

                              setState(() {
                                AppLog.instance.trace(
                                  "lib/pages/settings_page.dart::_AppearanceSettingsState.build.closure#1.closure#3.closure#1",
                                );
                                _editingColor = false;
                              });
                              appearance.seedColor = option.color;
                            },
                          ),
                        ChoiceChip(
                          key: const ValueKey('customThemeColor'),
                          showCheckmark: false,
                          avatar: const Icon(Icons.colorize_outlined, size: 18),
                          label: const Text('自定义'),
                          selected:
                              _editingColor ||
                              !_colors.any((option) {
                                AppLog.instance.trace(
                                  "lib/pages/settings_page.dart::_AppearanceSettingsState.build.closure#1.closure#4",
                                );
                                return option.color == appearance.seedColor;
                              }),
                          onSelected: (_) {
                            AppLog.instance.trace(
                              "lib/pages/settings_page.dart::_AppearanceSettingsState.build.closure#1.closure#5",
                            );

                            setState(() {
                              AppLog.instance.trace(
                                "lib/pages/settings_page.dart::_AppearanceSettingsState.build.closure#1.closure#5.closure#1",
                              );
                              _editingColor = !_editingColor;
                            });
                          },
                        ),
                      ],
                    ),
                    if (_editingColor)
                      Padding(
                        padding: const EdgeInsets.only(top: 20),
                        child: ThemeColorEditor(
                          initialColor: appearance.seedColor,
                          oledBlack: appearance.oledBlack,
                          onCancel: () {
                            AppLog.instance.trace(
                              "lib/pages/settings_page.dart::_AppearanceSettingsState.build.closure#1.closure#6",
                            );
                            setState(() {
                              AppLog.instance.trace(
                                "lib/pages/settings_page.dart::_AppearanceSettingsState.build.closure#1.closure#6.closure#1",
                              );
                              _editingColor = false;
                            });
                          },
                          onApply: (color) {
                            AppLog.instance.trace(
                              "lib/pages/settings_page.dart::_AppearanceSettingsState.build.closure#1.closure#7",
                            );

                            appearance.seedColor = color;
                            setState(() {
                              AppLog.instance.trace(
                                "lib/pages/settings_page.dart::_AppearanceSettingsState.build.closure#1.closure#7.closure#1",
                              );
                              _editingColor = false;
                            });
                          },
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            _SettingsCard(
              title: '字号 ${(appearance.textScale * 100).round()}%',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Slider(
                    label: '${(appearance.textScale * 100).round()}%',
                    semanticFormatterCallback: (value) {
                      AppLog.instance.trace(
                        "lib/pages/settings_page.dart::_AppearanceSettingsState.build.closure#1.closure#8",
                      );
                      return '字号 ${(value * 100).round()}%';
                    },
                    min: 0.8,
                    max: 1.5,
                    divisions: 14,
                    value: appearance.textScale,
                    onChanged: (value) {
                      AppLog.instance.trace(
                        "lib/pages/settings_page.dart::_AppearanceSettingsState.build.closure#1.closure#9",
                      );
                      appearance.textScale = value;
                    },
                  ),
                  const Text('文字预览 0123456789'),
                  const SizedBox(height: 8),
                  const Text('在系统字号基础上调整，仍保留系统无障碍文字缩放。'),
                ],
              ),
            ),
            if (Platform.isWindows) ...[
              const SizedBox(height: 16),
              _SettingsCard(
                title: '窗口',
                child: WindowClosePreference(runtime: runtime),
              ),
            ],
          ],
        );
      },
    );
  }
}

class _SettingsCard extends StatelessWidget {
  const _SettingsCard({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    AppLog.instance.trace("lib/pages/settings_page.dart::_SettingsCard.build");

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AdaptiveText(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            child,
          ],
        ),
      ),
    );
  }
}

class _AboutSettings extends StatelessWidget {
  const _AboutSettings({required this.updates});

  final UpdateService updates;

  Future<void> _openContact(BuildContext context, String url) {
    AppLog.instance.trace(
      "lib/pages/settings_page.dart::_AboutSettings._openContact",
    );
    return AppLog.instance.runWithErrorScope(() async {
      AppLog.instance.trace(
        "lib/pages/settings_page.dart::_AboutSettings._openContact.closure#1",
      );

      try {
        if (!await launchUrl(
          Uri.parse(url),
          mode: LaunchMode.externalApplication,
        )) {
          throw const FormatException('无法打开链接');
        }
      } catch (error, stack) {
        if (!AppLog.instance.errorWasRecorded(error)) {
          AppLog.instance.write(
            AppLogLevel.warning,
            'settings',
            'Opening contact link failed',
            error: error,
            stackTrace: stack,
            promptUser: false,
          );
        }
        if (context.mounted)
          ScaffoldMessenger.of(context)
              .showSnackBar(const SnackBar(content: Text('无法打开浏览器，请复制链接')));
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    AppLog.instance.trace("lib/pages/settings_page.dart::_AboutSettings.build");

    return ListenableBuilder(
      listenable: updates,
      builder: (context, _) {
        AppLog.instance.trace(
          "lib/pages/settings_page.dart::_AboutSettings.build.closure#1",
        );
        return ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Row(
              children: [
                Image.asset(
                  'assets/branding/xmplus.png',
                  width: 64,
                  height: 64,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: AdaptiveText(
                    'XMPlus',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            AdaptiveText(updates.versionLabel),
            const SizedBox(height: 16),
            _SettingsCard(
              title: '应用更新',
              child: Column(
                children: [
                  SwitchListTile.adaptive(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('启动时自动检查更新'),
                    subtitle: const Text('仅检查 GitHub 稳定版，不会自动下载或安装'),
                    value: updates.autoCheck,
                    onChanged: updates.setAutoCheck,
                  ),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.system_update_outlined),
                    title: Text(updates.checking ? '正在检查更新…' : '检查更新'),
                    subtitle: Text(updates.message ?? '手动检查不受忽略版本限制'),
                    trailing: updates.checking
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.chevron_right),
                    onTap: updates.checking
                        ? null
                        : () {
                            AppLog.instance.trace(
                              "lib/pages/settings_page.dart::_AboutSettings.build.closure#1.closure#1",
                            );
                            updates.check(context, manual: true);
                          },
                  ),
                  if (updates.ignoredVersion != null)
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        AdaptiveText('已忽略 ${updates.ignoredVersion}'),
                        Align(
                          alignment: AlignmentDirectional.centerEnd,
                          child: TextButton(
                            onPressed: updates.clearIgnoredVersion,
                            child: const Text('恢复提醒'),
                          ),
                        ),
                      ],
                    ),
                  if (updates.error != null)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Text(
                        updates.error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('官方发布页'),
                    subtitle: const SelectableText(
                      'https://github.com/teikengstudio/XMPlus/releases/latest',
                    ),
                    trailing: IconButton(
                      tooltip: '打开官方发布页',
                      icon: const Icon(Icons.open_in_new),
                      onPressed: () {
                        AppLog.instance.trace(
                          "lib/pages/settings_page.dart::_AboutSettings.build.closure#1.closure#2",
                        );
                        _openContact(
                          context,
                          'https://github.com/teikengstudio/XMPlus/releases/latest',
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            _SettingsCard(
              title: '联系与项目',
              child: Column(
                children: [
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.send_outlined),
                    title: const Text('Telegram'),
                    subtitle: const SelectableText(
                      'https://t.me/+csbfHjIyqkoyNDA1',
                    ),
                    trailing: IconButton(
                      tooltip: '打开 Telegram',
                      icon: const Icon(Icons.open_in_new),
                      onPressed: () {
                        AppLog.instance.trace(
                          "lib/pages/settings_page.dart::_AboutSettings.build.closure#1.closure#3",
                        );

                        _openContact(context, 'https://t.me/+csbfHjIyqkoyNDA1');
                      },
                    ),
                  ),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.code),
                    title: const Text('GitHub'),
                    subtitle: const SelectableText(
                      'https://github.com/teikengstudio/xmplus',
                    ),
                    trailing: IconButton(
                      tooltip: '打开 GitHub',
                      icon: const Icon(Icons.open_in_new),
                      onPressed: () {
                        AppLog.instance.trace(
                          "lib/pages/settings_page.dart::_AboutSettings.build.closure#1.closure#4",
                        );
                        _openContact(
                          context,
                          'https://github.com/teikengstudio/xmplus',
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            const _SettingsCard(
              title: '开源声明',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('界面与 Windows 窗口改编自 PiliPlus，采用 GNU GPL v3。'),
                  SizedBox(height: 8),
                  SelectableText('https://github.com/bggRGjQaUbCoE/PiliPlus'),
                  SizedBox(height: 8),
                  SelectableText('d9e9626f1a3f89cd9ca85e18f61aaba02634e12a'),
                  SizedBox(height: 16),
                  Text('原喜马拉雅组件来自 XIAOYA Nano，采用 AGPL-3.0-or-later。'),
                  SizedBox(height: 8),
                  Text('本应用使用 HarmonyOS Sans 字体，版权归华为终端有限公司所有。完整字体许可见“查看许可”。'),
                  SizedBox(height: 8),
                  Text(
                    '应用与第三方许可证见“查看许可”，对应源码和构建来源见项目仓库；桌面包另附 LICENSE、NOTICE 和 licenses。',
                  ),
                ],
              ),
            ),
            TextButton.icon(
              icon: const Icon(Icons.description_outlined),
              label: const Text('查看许可'),
              onPressed: () {
                AppLog.instance.trace(
                  "lib/pages/settings_page.dart::_AboutSettings.build.closure#1.closure#5",
                );
                showLicensePage(
                  context: context,
                  applicationName: 'XMPlus',
                  applicationVersion: updates.packageInfo?.version,
                );
              },
            ),
            TextButton.icon(
              icon: const Icon(Icons.folder_open),
              label: const Text('许可与来源'),
              onPressed: () {
                AppLog.instance.trace(
                  "lib/pages/settings_page.dart::_AboutSettings.build.closure#1.closure#6",
                );
                AppLog.instance.runWithErrorScope(() async {
                  AppLog.instance.trace(
                    "lib/pages/settings_page.dart::_AboutSettings.build.closure#1.closure#6.closure#1",
                  );

                  try {
                    if (Platform.isAndroid) {
                      final version = updates.packageInfo?.version;
                      final ref = version == null ? 'main' : 'v$version';
                      if (!await launchUrl(
                        Uri.https(
                          'github.com',
                          '/teikengstudio/XMPlus/tree/$ref/licenses/android',
                        ),
                        mode: LaunchMode.externalApplication,
                      )) {
                        throw const FormatException('无法打开来源页面');
                      }
                      return;
                    }
                    final root = p.dirname(Platform.resolvedExecutable);
                    final opener = Platform.isWindows
                        ? 'explorer.exe'
                        : Platform.isMacOS
                        ? 'open'
                        : 'xdg-open';
                    await Process.start(opener, [root], runInShell: false);
                  } catch (error, stack) {
                    if (!AppLog.instance.errorWasRecorded(error)) {
                      AppLog.instance.write(
                        AppLogLevel.warning,
                        'settings',
                        'Opening licenses failed',
                        error: error,
                        stackTrace: stack,
                        promptUser: false,
                      );
                    }
                    if (context.mounted)
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('无法打开许可与来源，请查看项目仓库中的 licenses 目录'),
                        ),
                      );
                  }
                });
              },
            ),
          ],
        );
      },
    );
  }
}
