import 'dart:async';
import 'dart:io';

import 'package:tray_manager/tray_manager.dart' as tray;

import 'app_log.dart';

/// The tray owns presentation and commands; the existing player keeps running.
class DesktopTray {
  DesktopTray({
    required this.onRestore,
    required this.onMini,
    required this.onPlayPause,
    required this.onNext,
    required this.onExit,
  }) {
    AppLog.instance.trace("lib/services/desktop_tray.dart::DesktopTray.new");
  }

  final Future<void> Function() onRestore, onMini, onPlayPause, onNext, onExit;
  tray.TrayIcon? _icon;
  tray.Image? _image;
  tray.Menu? _menu;
  tray.MenuItem? _playItem, _nextItem;
  int? _listener;
  final _items = <(tray.MenuItem, int)>[];
  (String, bool, bool, bool)? _state;

  bool ensureReady() {
    AppLog.instance.trace(
      "lib/services/desktop_tray.dart::DesktopTray.ensureReady",
    );

    if (!Platform.isWindows) return false;
    try {
      if (_icon == null) {
        final icon = _icon = tray.TrayIcon.create();
        final image = _image = tray.ImageAsset.fromAsset(
          'windows/runner/resources/app_icon.ico',
        );
        final menu = _menu = tray.Menu.create();
        if (icon == null || image == null || menu == null) {
          throw StateError('Tray creation failed');
        }
        icon.icon = image;
        icon.setTooltip('XMPlus');
        _listener = icon.addListener((event) {
          AppLog.instance.trace(
            "lib/services/desktop_tray.dart::DesktopTray.ensureReady.closure#1",
          );

          switch (event) {
            case tray.TrayIconClickedEvent():
              return onRestore();
            case tray.TrayIconRightClickedEvent():
              icon.openContextMenu();
            case tray.TrayIconDoubleClickedEvent():
              break;
          }
        });
        _addItem('恢复主窗口', onRestore);
        _addItem('小窗播放', onMini);
        menu.addSeparator();
        _playItem = _addItem('播放', onPlayPause);
        _nextItem = _addItem('下一集', onNext);
        menu.addSeparator();
        _addItem('彻底退出', onExit);
        icon.setContextMenu(menu);
      }
      if (_icon!.setVisible(true)) return true;
    } catch (error, stack) {
      AppLog.instance.write(
        AppLogLevel.error,
        'tray',
        'Unable to initialize the desktop tray',
        error: error,
        stackTrace: stack,
      );
      // Never hide the app unless the tray is available to bring it back.
    }
    dispose();
    return false;
  }

  tray.MenuItem _addItem(String label, Future<void> Function() action) {
    AppLog.instance.trace(
      "lib/services/desktop_tray.dart::DesktopTray._addItem",
    );

    final item = tray.MenuItem.createWithLabelAndType(
      label,
      tray.MenuItemType.normal,
    );
    if (item == null) throw StateError('Tray menu creation failed');
    final listener = item.addListener((event) async {
      AppLog.instance.trace(
        "lib/services/desktop_tray.dart::DesktopTray._addItem.closure#1",
      );

      if (event is tray.MenuItemClickedEvent) await action();
    });
    _items.add((item, listener));
    _menu!.addItem(item);
    return item;
  }

  void update({
    required String title,
    required bool playing,
    required bool loading,
    required bool enabled,
  }) {
    AppLog.instance.trace("lib/services/desktop_tray.dart::DesktopTray.update");

    if (_icon == null) return;
    final state = (title, playing, loading, enabled);
    if (_state == state) return;
    _state = state;
    _icon!.setTooltip(title.isEmpty ? 'XMPlus' : 'XMPlus · $title');
    _playItem!
      ..label = loading
          ? '取消加载'
          : playing
          ? '暂停'
          : '播放'
      ..isEnabled = enabled;
    _nextItem!.isEnabled = enabled;
  }

  void dispose() {
    AppLog.instance.trace(
      "lib/services/desktop_tray.dart::DesktopTray.dispose",
    );

    _icon?.setVisible(false);
    _icon?.setContextMenu(null);
    if (_listener != null) _icon?.removeListener(_listener!);
    _listener = null;
    for (final (item, listener) in _items) {
      item.removeListener(listener);
      item.dispose();
    }
    _items.clear();
    _menu?.dispose();
    _menu = null;
    _icon?.dispose();
    _icon = null;
    _image?.dispose();
    _image = null;
    _playItem = _nextItem = null;
    _state = null;
  }
}
