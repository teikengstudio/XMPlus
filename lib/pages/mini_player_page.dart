import 'package:flutter/material.dart';

import '../common/widgets/app_header.dart';
import '../services/app_runtime.dart';
import 'player_panel.dart';
import '../services/app_log.dart';

class MiniPlayerPage extends StatelessWidget {
  const MiniPlayerPage({
    required this.runtime,
    required this.onRestore,
    required this.onExit,
    super.key,
  });

  static const routeName = '/mini-player';
  final AppRuntime runtime;
  final VoidCallback onRestore, onExit;

  @override
  Widget build(BuildContext context) {
    AppLog.instance.trace(
      "lib/pages/mini_player_page.dart::MiniPlayerPage.build",
    );
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        AppLog.instance.trace(
          "lib/pages/mini_player_page.dart::MiniPlayerPage.build.closure#1",
        );
        if (!didPop) onRestore();
      },
      child: Scaffold(
        appBar: AppHeader(
          automaticallyImplyLeading: false,
          allowMaximize: false,
          closeTooltip: '收起到托盘，继续播放',
          toolbarHeight: 40,
          title: const Text('小窗播放', style: TextStyle(fontSize: 14)),
          actions: [
            IconButton(
              tooltip: '恢复主窗口',
              onPressed: onRestore,
              icon: const Icon(Icons.open_in_full),
            ),
            IconButton(
              tooltip: '彻底退出',
              onPressed: onExit,
              icon: const Icon(Icons.power_settings_new),
            ),
          ],
        ),
        body: SingleChildScrollView(
          child: PlayerPanel(
            runtime: runtime,
            miniWindow: true,
            onExpand: onRestore,
          ),
        ),
      ),
    );
  }
}
