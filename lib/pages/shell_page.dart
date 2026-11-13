// Material navigation adapted from PiliPlus lib/pages/main/view.dart
// (NavigationBar and NavigationRail branches), commit
// d9e9626f1a3f89cd9ca85e18f61aaba02634e12a (GNU GPL v3).
// Source: https://github.com/bggRGjQaUbCoE/PiliPlus
import 'dart:async';

import 'package:flutter/material.dart';

import '../common/theme.dart';
import '../common/widgets/adaptive_text.dart';
import '../common/widgets/app_header.dart';
import '../services/app_runtime.dart';
import '../services/app_log.dart';
import '../services/account_service.dart';
import '../services/download_service.dart' show DownloadStopped;
import '../storage/app_storage.dart';
import '../services/update_service.dart';
import 'settings_page.dart';
import 'home_page.dart';
import 'listening_page.dart';
import '../models/xmly_models.dart';
import 'download_page.dart';

class ShellPage extends StatefulWidget {
  const ShellPage({
    required this.appearance,
    required this.runtime,
    this.onMiniPlayer,
    this.onTray,
    super.key,
  });

  final AppAppearance appearance;
  final AppRuntime runtime;
  final VoidCallback? onMiniPlayer;
  final VoidCallback? onTray;

  @override
  State<ShellPage> createState() {
    AppLog.instance.trace("lib/pages/shell_page.dart::ShellPage.createState");
    return _ShellPageState();
  }
}

class _ShellPageState extends State<ShellPage> {
  int _selectedIndex = 0;
  bool _preparingDownload = false;
  late final UpdateService _updates;

  @override
  void initState() {
    AppLog.instance.trace(
      "lib/pages/shell_page.dart::_ShellPageState.initState",
    );

    super.initState();
    _updates = UpdateService(widget.runtime.storage);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      AppLog.instance.trace(
        "lib/pages/shell_page.dart::_ShellPageState.initState.closure#1",
      );

      if (mounted) unawaited(_updates.check(context));
    });
  }

  @override
  void dispose() {
    AppLog.instance.trace("lib/pages/shell_page.dart::_ShellPageState.dispose");

    _updates.dispose();
    super.dispose();
  }

  Future<void> _download(List<Track> tracks) {
    AppLog.instance.trace(
      "lib/pages/shell_page.dart::_ShellPageState._download",
    );
    return AppLog.instance.runWithErrorScope(() async {
      AppLog.instance.trace(
        "lib/pages/shell_page.dart::_ShellPageState._download.closure#1",
      );

      if (_preparingDownload) return;
      _preparingDownload = true;
      try {
        await requestDownloads(context, widget.runtime, tracks);
      } catch (error, stack) {
        final expected =
            error is DownloadStopped ||
            error is FormatException ||
            (error is AccountException &&
                const {
                  'credential_missing',
                  'missing',
                  'paused',
                  'closed',
                  'not_loaded',
                  'credential_mismatch',
                  'archive_invalid',
                  'quota_invalid',
                  'unsettled',
                }.contains(error.code)) ||
            (error is StorageException &&
                const {'too_large', 'secret_in_state'}.contains(error.code)) ||
            (error is XmlyException &&
                const {
                  'invalid_credentials',
                  'invalid_id',
                  'invalid_quality',
                  'login_required',
                  'login_expired',
                  'auth_required',
                  'missing_account',
                  'confirmation_required',
                  'confirmation_changed',
                  'insufficient_quota',
                  'usage_uncertain',
                  'original_account_required',
                  'receipt_required',
                  'task_busy',
                  'batch_invalid',
                  'batch_too_large',
                  'catalogue_limit',
                  'invalid_settings',
                  'invalid_duration',
                  'invalid_space',
                  'invalid_conflict',
                  'media_format',
                  'media_bitrate',
                  'media_settings',
                  'media_tags',
                  'closed',
                  'request_cancelled',
                  'client_closed',
                  'cache_paused',
                  'cache_closed',
                }.contains(error.code));
        if (!expected && !AppLog.instance.errorWasRecorded(error)) {
          AppLog.instance.write(
            AppLogLevel.error,
            'download',
            'Starting selected downloads failed',
            error: error,
            stackTrace: stack,
            promptUser: true,
          );
        }
        if (mounted)
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                error is XmlyException ? error.message : '下载未开始，请检查账号及下载目录',
              ),
            ),
          );
      } finally {
        _preparingDownload = false;
      }
    });
  }

  static const _destinations = [
    (label: '主页', icon: Icons.home_outlined, selected: Icons.home),
    (label: '听过', icon: Icons.headphones_outlined, selected: Icons.headphones),
    (label: '下载', icon: Icons.download_outlined, selected: Icons.download),
    (label: '设置', icon: Icons.settings_outlined, selected: Icons.settings),
  ];

  void _select(int index) {
    AppLog.instance.trace("lib/pages/shell_page.dart::_ShellPageState._select");
    if (_selectedIndex == index) return;
    setState(() {
      AppLog.instance.trace(
        "lib/pages/shell_page.dart::_ShellPageState._select.closure#1",
      );
      _selectedIndex = index;
    });
  }

  @override
  Widget build(BuildContext context) {
    AppLog.instance.trace("lib/pages/shell_page.dart::_ShellPageState.build");

    return LayoutBuilder(
      builder: (context, constraints) {
        AppLog.instance.trace(
          "lib/pages/shell_page.dart::_ShellPageState.build.closure#1",
        );

        final availableWidth =
            constraints.maxWidth - MediaQuery.paddingOf(context).horizontal;
        final useRail = availableWidth >= 840;
        final expandedRail = availableWidth >= 1440;
        final compact = availableWidth < (usesWindowHeader ? 600 : 320);
        final theme = Theme.of(context);
        final colors = theme.colorScheme;
        final railLabelStyle = expandedRail
            ? theme.textTheme.titleMedium
            : theme.textTheme.labelMedium;
        return Scaffold(
          appBar: AppHeader(
            showBrand: !compact,
            title: AdaptiveText(_destinations[_selectedIndex].label),
            actions: [
              if (widget.onMiniPlayer != null)
                PopupMenuButton<String>(
                  tooltip: '窗口操作',
                  offset: const Offset(0, 12),
                  onSelected: (value) {
                    AppLog.instance.trace(
                      "lib/pages/shell_page.dart::_ShellPageState.build.closure#1.closure#1",
                    );

                    if (value == 'mini') {
                      widget.onMiniPlayer!();
                    } else if (value == 'tray') {
                      widget.onTray?.call();
                    } else {
                      widget.runtime.requestExit?.call();
                    }
                  },
                  itemBuilder: (_) {
                    AppLog.instance.trace(
                      "lib/pages/shell_page.dart::_ShellPageState.build.closure#1.closure#2",
                    );
                    return [
                      const PopupMenuItem(value: 'mini', child: Text('收起到小窗')),
                      if (widget.onTray != null)
                        const PopupMenuItem(
                          value: 'tray',
                          child: Text('收起到托盘'),
                        ),
                      const PopupMenuItem(value: 'exit', child: Text('彻底退出')),
                    ];
                  },
                ),
            ],
          ),
          body: SafeArea(
            bottom: useRail,
            child: Row(
              children: [
                if (useRail)
                  ColoredBox(
                    key: const ValueKey('shellNavigation'),
                    color: colors.surfaceContainerLow,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(8, 20, 8, 16),
                      child: NavigationRail(
                        extended: expandedRail,
                        minWidth: 72,
                        minExtendedWidth: 168,
                        groupAlignment: -1,
                        scrollable: true,
                        labelType: expandedRail
                            ? NavigationRailLabelType.none
                            : NavigationRailLabelType.all,
                        backgroundColor: Colors.transparent,
                        selectedLabelTextStyle: railLabelStyle?.copyWith(
                          color: colors.primary,
                          fontWeight: FontWeight.w600,
                        ),
                        unselectedLabelTextStyle: railLabelStyle?.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                        indicatorColor: colors.primaryContainer,
                        selectedIconTheme: IconThemeData(
                          color: colors.onPrimaryContainer,
                          size: 24,
                        ),
                        unselectedIconTheme: IconThemeData(
                          color: colors.onSurfaceVariant,
                          size: 24,
                        ),
                        onDestinationSelected: _select,
                        selectedIndex: _selectedIndex,
                        destinations: _destinations.map((destination) {
                          AppLog.instance.trace(
                            "lib/pages/shell_page.dart::_ShellPageState.build.closure#1.closure#3",
                          );

                          return NavigationRailDestination(
                            label: Text(
                              destination.label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              textAlign: expandedRail
                                  ? TextAlign.start
                                  : TextAlign.center,
                            ),
                            icon: Icon(destination.icon),
                            selectedIcon: Icon(destination.selected),
                          );
                        }).toList(),
                      ),
                    ),
                  ),
                Expanded(
                  key: const ValueKey('shellContent'),
                  child: Column(
                    children: [
                      ListenableBuilder(
                        listenable: widget.runtime,
                        builder: (context, _) {
                          AppLog.instance.trace(
                            "lib/pages/shell_page.dart::_ShellPageState.build.closure#1.closure#4",
                          );
                          return widget.runtime.lifecycleError == null
                              ? const SizedBox.shrink()
                              : MaterialBanner(
                                  content: Text(widget.runtime.lifecycleError!),
                                  actions: [
                                    TextButton(
                                      onPressed: () {
                                        AppLog.instance.trace(
                                          "lib/pages/shell_page.dart::_ShellPageState.build.closure#1.closure#4.closure#1",
                                        );

                                        widget.runtime.lifecycleError = null;
                                        widget.runtime.changed();
                                      },
                                      child: const Text('知道了'),
                                    ),
                                  ],
                                );
                        },
                      ),
                      Expanded(
                        child: _ShellPageStack(
                          index: _selectedIndex,
                          children: [
                            HomePage(
                              runtime: widget.runtime,
                              onDownload: _download,
                              onPlayAlbum: widget.runtime.player.playAlbum,
                            ),
                            ListeningPage(
                              runtime: widget.runtime,
                              onDownload: _download,
                              onPlayAlbum: widget.runtime.player.playAlbum,
                            ),
                            DownloadPage(runtime: widget.runtime),
                            SettingsPage(
                              appearance: widget.appearance,
                              runtime: widget.runtime,
                              updates: _updates,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          bottomNavigationBar: useRail
              ? null
              : compact
              ? Material(
                  child: SafeArea(
                    top: false,
                    child: PopupMenuButton<int>(
                      tooltip: '切换页面',
                      initialValue: _selectedIndex,
                      onSelected: _select,
                      itemBuilder: (_) {
                        AppLog.instance.trace(
                          "lib/pages/shell_page.dart::_ShellPageState.build.closure#1.closure#5",
                        );
                        return [
                          for (
                            var index = 0;
                            index < _destinations.length;
                            index++
                          )
                            PopupMenuItem(
                              value: index,
                              child: Text(_destinations[index].label),
                            ),
                        ];
                      },
                      child: SizedBox(
                        height: 56,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          child: Row(
                            children: [
                              Icon(_destinations[_selectedIndex].selected),
                              const SizedBox(width: 12),
                              Expanded(
                                child: AdaptiveText(
                                  _destinations[_selectedIndex].label,
                                ),
                              ),
                              const Icon(Icons.unfold_more),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                )
              : NavigationBar(
                  maintainBottomViewPadding: true,
                  onDestinationSelected: _select,
                  selectedIndex: _selectedIndex,
                  destinations: _destinations.map((destination) {
                    AppLog.instance.trace(
                      "lib/pages/shell_page.dart::_ShellPageState.build.closure#1.closure#6",
                    );

                    return NavigationDestination(
                      label: destination.label,
                      icon: Icon(destination.icon),
                      selectedIcon: Icon(destination.selected),
                    );
                  }).toList(),
                ),
        );
      },
    );
  }
}

/// Cross-fades destinations without replacing their state or scroll positions.
class _ShellPageStack extends StatefulWidget {
  const _ShellPageStack({required this.index, required this.children});

  final int index;
  final List<Widget> children;

  @override
  State<_ShellPageStack> createState() {
    AppLog.instance.trace(
      "lib/pages/shell_page.dart::_ShellPageStack.createState",
    );
    return _ShellPageStackState();
  }
}

class _ShellPageStackState extends State<_ShellPageStack> {
  final _leaving = <int>{};
  bool _disableAnimations = false;

  @override
  void didChangeDependencies() {
    AppLog.instance.trace(
      "lib/pages/shell_page.dart::_ShellPageStackState.didChangeDependencies",
    );

    super.didChangeDependencies();
    final disabled = MediaQuery.disableAnimationsOf(context);
    if (disabled != _disableAnimations) {
      _disableAnimations = disabled;
      _leaving.clear();
    }
  }

  @override
  void didUpdateWidget(covariant _ShellPageStack oldWidget) {
    AppLog.instance.trace(
      "lib/pages/shell_page.dart::_ShellPageStackState.didUpdateWidget",
    );

    super.didUpdateWidget(oldWidget);
    if (oldWidget.index != widget.index) {
      if (!_disableAnimations) _leaving.add(oldWidget.index);
      _leaving.remove(widget.index);
    }
  }

  void _finishTransition(int index) {
    AppLog.instance.trace(
      "lib/pages/shell_page.dart::_ShellPageStackState._finishTransition",
    );

    if (!mounted || index == widget.index || !_leaving.contains(index)) return;
    setState(() {
      AppLog.instance.trace(
        "lib/pages/shell_page.dart::_ShellPageStackState._finishTransition.closure#1",
      );
      _leaving.remove(index);
    });
  }

  @override
  Widget build(BuildContext context) {
    AppLog.instance.trace(
      "lib/pages/shell_page.dart::_ShellPageStackState.build",
    );
    return Stack(
      fit: StackFit.expand,
      children: [
        for (var index = 0; index < widget.children.length; index++)
          Offstage(
            offstage: index != widget.index && !_leaving.contains(index),
            child: TickerMode(
              enabled: index == widget.index || _leaving.contains(index),
              child: ExcludeFocus(
                excluding: index != widget.index,
                child: ExcludeSemantics(
                  excluding: index != widget.index,
                  child: IgnorePointer(
                    ignoring: index != widget.index,
                    child: AnimatedOpacity(
                      opacity: index == widget.index ? 1 : 0,
                      duration: _disableAnimations
                          ? Duration.zero
                          : const Duration(milliseconds: 180),
                      curve: Curves.easeOutCubic,
                      onEnd: () {
                        AppLog.instance.trace(
                          "lib/pages/shell_page.dart::_ShellPageStackState.build.closure#1",
                        );
                        _finishTransition(index);
                      },
                      child: RepaintBoundary(child: widget.children[index]),
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
