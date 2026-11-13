import 'dart:io';

import 'package:sentry_dart_plugin/sentry_dart_plugin.dart';

Future<void> main(List<String> arguments) async {
  exitCode = await SentryDartPlugin().run(arguments);
}
