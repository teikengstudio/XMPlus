import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import "../../services/app_log.dart";

bool get usesWindowHeader {
  AppLog.instance.trace(
    "lib/common/widgets/app_header.dart::usesWindowHeader.get",
  );
  return !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;
}

/// A single toolbar for page navigation and the Windows window controls.
class AppHeader extends StatelessWidget implements PreferredSizeWidget {
  const AppHeader({
    required this.title,
    this.leading,
    this.actions,
    this.automaticallyImplyLeading = true,
    this.centerTitle,
    this.toolbarHeight = kToolbarHeight,
    this.showBrand = false,
    this.allowMaximize = true,
    this.windowControls = true,
    this.closeTooltip = '关闭窗口',
    super.key,
  });

  final Widget title;
  final Widget? leading;
  final List<Widget>? actions;
  final bool automaticallyImplyLeading, showBrand, allowMaximize;
  final bool windowControls;
  final String closeTooltip;
  final bool? centerTitle;
  final double toolbarHeight;

  @override
  Size get preferredSize {
    AppLog.instance.trace(
      "lib/common/widgets/app_header.dart::AppHeader.preferredSize.get",
    );
    return Size.fromHeight(toolbarHeight);
  }

  @override
  Widget build(BuildContext context) {
    AppLog.instance.trace(
      "lib/common/widgets/app_header.dart::AppHeader.build",
    );

    if (!usesWindowHeader || !windowControls) {
      return AppBar(
        title: title,
        leading: leading,
        actions: actions,
        automaticallyImplyLeading: automaticallyImplyLeading,
        centerTitle: centerTitle,
        toolbarHeight: toolbarHeight,
      );
    }
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final back =
        leading ??
        (automaticallyImplyLeading &&
                ModalRoute.of(context)?.impliesAppBarDismissal == true
            ? const BackButton()
            : null);
    return Material(
      color: colors.surface,
      child: SafeArea(
        bottom: false,
        child: SizedBox(
          height: toolbarHeight,
          child: Row(
            children: [
              if (back != null) SizedBox(width: 48, child: back),
              Expanded(
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onSecondaryTapUp: (_) {
                    AppLog.instance.trace(
                      "lib/common/widgets/app_header.dart::AppHeader.build.closure#1",
                    );
                    windowManager.popUpWindowMenu();
                  },
                  onPanStart: (_) {
                    AppLog.instance.trace(
                      "lib/common/widgets/app_header.dart::AppHeader.build.closure#2",
                    );
                    windowManager.startDragging();
                  },
                  onDoubleTap: allowMaximize
                      ? () async {
                          AppLog.instance.trace(
                            "lib/common/widgets/app_header.dart::AppHeader.build.closure#3",
                          );

                          if (await windowManager.isMaximized()) {
                            await windowManager.unmaximize();
                          } else {
                            await windowManager.maximize();
                          }
                        }
                      : null,
                  child: SizedBox.expand(
                    child: Padding(
                      padding: EdgeInsets.only(
                        left: back == null ? 20 : 4,
                        right: 12,
                      ),
                      child: Row(
                        children: [
                          if (showBrand) ...[
                            Image.asset(
                              'assets/branding/xmplus.png',
                              width: 26,
                              height: 26,
                              excludeFromSemantics: true,
                            ),
                            const SizedBox(width: 12),
                          ],
                          Expanded(
                            child: DefaultTextStyle(
                              style:
                                  theme.appBarTheme.titleTextStyle ??
                                  theme.textTheme.titleMedium!,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              child: title,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              ...?actions,
              const SizedBox(width: 8),
              SizedBox(
                height: 18,
                child: VerticalDivider(width: 1, color: colors.outlineVariant),
              ),
              const SizedBox(width: 8),
              _WindowControls(
                allowMaximize: allowMaximize,
                closeTooltip: closeTooltip,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _WindowControls extends StatefulWidget {
  const _WindowControls({
    required this.allowMaximize,
    required this.closeTooltip,
  });
  final bool allowMaximize;
  final String closeTooltip;

  @override
  State<_WindowControls> createState() {
    AppLog.instance.trace(
      "lib/common/widgets/app_header.dart::_WindowControls.createState",
    );
    return _WindowControlsState();
  }
}

class _WindowControlsState extends State<_WindowControls> with WindowListener {
  bool _maximized = false;

  @override
  void initState() {
    AppLog.instance.trace(
      "lib/common/widgets/app_header.dart::_WindowControlsState.initState",
    );

    super.initState();
    windowManager.addListener(this);
    unawaited(_refresh());
  }

  Future<void> _refresh() async {
    AppLog.instance.trace(
      "lib/common/widgets/app_header.dart::_WindowControlsState._refresh",
    );

    final value = await windowManager.isMaximized();
    if (mounted)
      setState(() {
        AppLog.instance.trace(
          "lib/common/widgets/app_header.dart::_WindowControlsState._refresh.closure#1",
        );
        _maximized = value;
      });
  }

  @override
  void onWindowMaximize() {
    AppLog.instance.trace(
      "lib/common/widgets/app_header.dart::_WindowControlsState.onWindowMaximize",
    );
    setState(() {
      AppLog.instance.trace(
        "lib/common/widgets/app_header.dart::_WindowControlsState.onWindowMaximize.closure#1",
      );
      _maximized = true;
    });
  }

  @override
  void onWindowUnmaximize() {
    AppLog.instance.trace(
      "lib/common/widgets/app_header.dart::_WindowControlsState.onWindowUnmaximize",
    );
    setState(() {
      AppLog.instance.trace(
        "lib/common/widgets/app_header.dart::_WindowControlsState.onWindowUnmaximize.closure#1",
      );
      _maximized = false;
    });
  }

  @override
  void dispose() {
    AppLog.instance.trace(
      "lib/common/widgets/app_header.dart::_WindowControlsState.dispose",
    );

    windowManager.removeListener(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    AppLog.instance.trace(
      "lib/common/widgets/app_header.dart::_WindowControlsState.build",
    );
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _WindowButton(
          label: '最小化',
          icon: Icons.remove,
          onPressed: windowManager.minimize,
        ),
        if (widget.allowMaximize)
          _WindowButton(
            label: _maximized ? '还原窗口' : '最大化',
            icon: _maximized ? Icons.filter_none : Icons.crop_square,
            onPressed: () async {
              AppLog.instance.trace(
                "lib/common/widgets/app_header.dart::_WindowControlsState.build.closure#1",
              );

              if (await windowManager.isMaximized()) {
                await windowManager.unmaximize();
              } else {
                await windowManager.maximize();
              }
            },
          ),
        _WindowButton(
          label: widget.closeTooltip,
          icon: Icons.close,
          close: true,
          onPressed: windowManager.close,
        ),
      ],
    );
  }
}

class _WindowButton extends StatelessWidget {
  const _WindowButton({
    required this.label,
    required this.icon,
    required this.onPressed,
    this.close = false,
  });

  final String label;
  final IconData icon;
  final VoidCallback onPressed;
  final bool close;

  @override
  Widget build(BuildContext context) {
    AppLog.instance.trace(
      "lib/common/widgets/app_header.dart::_WindowButton.build",
    );

    final colors = Theme.of(context).colorScheme;
    return SizedBox(
      width: 42,
      child: IconButton(
        tooltip: label,
        onPressed: onPressed,
        icon: Icon(icon, size: 17),
        style: ButtonStyle(
          shape: const WidgetStatePropertyAll(LinearBorder()),
          padding: const WidgetStatePropertyAll(EdgeInsets.zero),
          foregroundColor: WidgetStateProperty.resolveWith((states) {
            AppLog.instance.trace(
              "lib/common/widgets/app_header.dart::_WindowButton.build.closure#1",
            );

            if (close && states.contains(WidgetState.hovered)) {
              return Colors.white;
            }
            return colors.onSurfaceVariant;
          }),
          backgroundColor: WidgetStateProperty.resolveWith((states) {
            AppLog.instance.trace(
              "lib/common/widgets/app_header.dart::_WindowButton.build.closure#2",
            );

            if (states.contains(WidgetState.hovered)) {
              return close
                  ? const Color(0xFFC42B1C)
                  : colors.onSurface.withValues(alpha: 0.07);
            }
            return Colors.transparent;
          }),
        ),
      ),
    );
  }
}
