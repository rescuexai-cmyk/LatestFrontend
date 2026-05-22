import 'package:flutter/material.dart';

/// Standard error / warning banner used across the app.
///
/// Visual spec (Figma):
/// - Pill background: rgba(209, 69, 68, 0.1), radius 172
/// - Text: Poppins 14 / 21, color #D14544
/// - Trailing close button: 24x24 circle, same red bg, X icon (#D14544)
///
/// Usage:
///   ErrorBanner(
///     message: 'Please select a time at least 15 mins from now',
///     onDismiss: () => setState(() => _showBanner = false),
///   )
///
/// `onDismiss` is optional — when null, the close button is hidden.
class ErrorBanner extends StatelessWidget {
  const ErrorBanner({
    super.key,
    required this.message,
    this.onDismiss,
    this.margin,
  });

  /// Localized message to display.
  final String message;

  /// Called when the user taps the close (✕) circle. If null, the close
  /// button is not rendered (use this for non-dismissible errors).
  final VoidCallback? onDismiss;

  /// Optional outer margin. Defaults to no margin (caller controls spacing).
  final EdgeInsetsGeometry? margin;

  static const Color _redBg = Color.fromRGBO(209, 69, 68, 0.1);
  static const Color _redFg = Color(0xFFD14544);

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: margin,
      padding: const EdgeInsets.only(left: 12, right: 4, top: 5, bottom: 5),
      decoration: BoxDecoration(
        color: _redBg,
        borderRadius: BorderRadius.circular(172),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              message,
              style: const TextStyle(
                fontFamily: 'Poppins',
                fontWeight: FontWeight.w400,
                fontSize: 14,
                height: 21 / 14,
                color: _redFg,
              ),
            ),
          ),
          if (onDismiss != null)
            InkWell(
              onTap: onDismiss,
              borderRadius: BorderRadius.circular(12),
              child: Container(
                width: 24,
                height: 24,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: const Color.fromRGBO(209, 69, 68, 0.12),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(
                  Icons.close,
                  size: 14,
                  color: _redFg,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
