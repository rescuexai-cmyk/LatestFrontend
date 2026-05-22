import 'package:flutter/material.dart';

import 'error_banner.dart';

/// App-wide **error / warning** messaging using the Figma red pill ([ErrorBanner]).
///
/// Call [showErrorBanner] instead of ad-hoc [SnackBar]s for failures, validation,
/// and warnings so the UI stays consistent with the schedule-ride sheet.
///
/// **Do not use** for success flows — keep green [SnackBar]s or a dedicated
/// success pattern so positive feedback is not shown as an error.
abstract final class AppMessenger {
  static const Duration kDefaultDuration = Duration(seconds: 4);

  /// Shows the standard dismissible red pill at the bottom (floating).
  static void showErrorBanner(
    BuildContext context,
    String message, {
    Duration duration = kDefaultDuration,
    bool clearSnackBars = false,
  }) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    if (clearSnackBars) messenger.clearSnackBars();

    final bottomInset = MediaQuery.paddingOf(context).bottom;

    messenger.showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        elevation: 0,
        backgroundColor: Colors.transparent,
        padding: EdgeInsets.zero,
        duration: duration,
        margin: EdgeInsets.only(
          left: 12,
          right: 12,
          bottom: bottomInset + 12,
        ),
        dismissDirection: DismissDirection.horizontal,
        content: ErrorBanner(
          message: message,
          onDismiss: () => messenger.hideCurrentSnackBar(),
        ),
      ),
    );
  }
}
