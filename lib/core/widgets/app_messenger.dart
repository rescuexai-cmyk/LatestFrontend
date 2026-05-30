import 'dart:async';

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

  static OverlayEntry? _topBannerEntry;
  static Timer? _topBannerTimer;

  static void _removeTopBanner() {
    _topBannerTimer?.cancel();
    _topBannerTimer = null;
    final entry = _topBannerEntry;
    _topBannerEntry = null;
    entry?.remove();
  }

  /// Same as [showErrorBanner] but pins the pill under the status bar so it never
  /// covers driver CTAs (ride accept slider, overlays, etc.).
  static void showDriverErrorBanner(
    BuildContext context,
    String message, {
    Duration duration = kDefaultDuration,
    bool clearSnackBars = false,
  }) {
    showErrorBanner(
      context,
      message,
      duration: duration,
      clearSnackBars: clearSnackBars,
      alignTop: true,
    );
  }

  /// Shows the standard dismissible red pill.
  ///
  /// By default uses a bottom [SnackBar] (rider flows). With [alignTop], uses an
  /// overlay under the safe-area top inset so map / chrome stay unobstructed.
  static void showErrorBanner(
    BuildContext context,
    String message, {
    Duration duration = kDefaultDuration,
    bool clearSnackBars = false,
    bool alignTop = false,
  }) {
    if (alignTop) {
      _showTopAlignedErrorBanner(
        context,
        message,
        duration: duration,
        clearSnackBars: clearSnackBars,
      );
      return;
    }

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

  static void _showTopAlignedErrorBanner(
    BuildContext context,
    String message, {
    required Duration duration,
    bool clearSnackBars = false,
  }) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (clearSnackBars) messenger?.clearSnackBars();

    _removeTopBanner();

    final overlay = Overlay.maybeOf(context, rootOverlay: true) ??
        Overlay.maybeOf(context);
    if (overlay == null) {
      showErrorBanner(
        context,
        message,
        duration: duration,
        alignTop: false,
      );
      return;
    }

    late final OverlayEntry entry;
    entry = OverlayEntry(
      builder: (ctx) {
        return Material(
          color: Colors.transparent,
          child: SafeArea(
            bottom: false,
            child: Align(
              alignment: Alignment.topCenter,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                child: ErrorBanner(
                  message: message,
                  onDismiss: () {
                    if (_topBannerEntry == entry) {
                      _removeTopBanner();
                    }
                  },
                ),
              ),
            ),
          ),
        );
      },
    );

    _topBannerEntry = entry;
    overlay.insert(entry);
    _topBannerTimer = Timer(duration, () {
      if (_topBannerEntry == entry) {
        _removeTopBanner();
      }
    });
  }
}
