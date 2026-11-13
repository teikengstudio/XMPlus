// Adapted from PiliPlus lib/main.dart, commit
// d9e9626f1a3f89cd9ca85e18f61aaba02634e12a (GNU GPL v3).
// Source: https://github.com/bggRGjQaUbCoE/PiliPlus
// Desktop setup only; audio and account services are not initialized here.
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:window_manager/window_manager.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

import 'pages/startup_page.dart';
import 'services/app_log.dart';
import 'services/error_reporting.dart';

Future<void> main(List<String> arguments) async {
  AppLog.instance.trace("lib/main.dart::main");

  WidgetsFlutterBinding.ensureInitialized();
  await AppLog.instance.initialize();
  AppLog.instance.write(
    AppLogLevel.info,
    'lifecycle',
    '应用启动',
    data: {'phase': 'bootstrap'},
  );
  await initializeErrorReporting(() async {
    AppLog.instance.trace("lib/main.dart::main.closure#1");

    LicenseRegistry.addLicense(() async* {
      AppLog.instance.trace("lib/main.dart::main.closure#1.closure#1");

      for (final entry in const {
        'XMPlus': 'LICENSE',
        'XMPlus — 版权与来源': 'NOTICE',
        'PiliPlus': 'windows/LICENSE.PiliPlus',
        'Android 原生音频组件': 'licenses/android/THIRD-PARTY-NOTICES.txt',
        'FFmpeg / FFprobe 与 LAME': 'licenses/media/THIRD-PARTY-NOTICES.txt',
        'HarmonyOS Sans': 'licenses/fonts/HarmonyOS_Sans_SC_LICENSE.txt',
      }.entries) {
        yield LicenseEntryWithLineBreaks([
          entry.key,
        ], (await rootBundle.loadString(entry.value)).replaceAll('\u0000', ''));
      }
    });
    if (!kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.windows ||
            defaultTargetPlatform == TargetPlatform.macOS ||
            defaultTargetPlatform == TargetPlatform.linux)) {
      await windowManager.ensureInitialized();
      if (defaultTargetPlatform == TargetPlatform.windows) {
        await windowManager.waitUntilReadyToShow();
        await windowManager.setTitleBarStyle(TitleBarStyle.hidden);
      }
      await windowManager.setMinimumSize(const Size(320, 320));
    }
    runApp(SentryWidget(child: StartupPage(arguments: arguments)));
  });
}
