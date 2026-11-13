import 'package:flutter/material.dart';

import "../../services/app_log.dart";

Future<bool> showConfirmationDialog(
  BuildContext context,
  Widget title, {
  Widget? content,
  String confirmLabel = '确认',
}) async {
  AppLog.instance.trace(
    "lib/common/widgets/confirmation_dialog.dart::showConfirmationDialog",
  );
  return await showDialog<bool>(
        context: context,
        builder: (context) {
          AppLog.instance.trace(
            "lib/common/widgets/confirmation_dialog.dart::showConfirmationDialog.closure#1",
          );
          return AlertDialog(
            title: title,
            content: content,
            actions: [
              TextButton(
                onPressed: () {
                  AppLog.instance.trace(
                    "lib/common/widgets/confirmation_dialog.dart::showConfirmationDialog.closure#1.closure#1",
                  );
                  Navigator.pop(context, false);
                },
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () {
                  AppLog.instance.trace(
                    "lib/common/widgets/confirmation_dialog.dart::showConfirmationDialog.closure#1.closure#2",
                  );
                  Navigator.pop(context, true);
                },
                child: Text(confirmLabel),
              ),
            ],
          );
        },
      ) ==
      true;
}
