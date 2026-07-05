import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Standard primary action buttons: Book Now, Confirm, Continue, Pay, etc.
abstract final class PrimaryCtaStyles {
  static const Color background = Color(0xFF2E2C2A);
  static const double height = 60;
  static const double radius = 16;

  static TextStyle get _labelStyle => GoogleFonts.poppins(
        fontSize: 16,
        fontWeight: FontWeight.w600,
      );

  static ButtonStyle filled({Size? minimumSize}) => FilledButton.styleFrom(
        backgroundColor: background,
        foregroundColor: Colors.white,
        disabledBackgroundColor: background.withValues(alpha: 0.45),
        disabledForegroundColor: Colors.white.withValues(alpha: 0.72),
        minimumSize: minimumSize ?? const Size(double.infinity, height),
        padding: const EdgeInsets.symmetric(horizontal: 24),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radius),
        ),
        textStyle: _labelStyle,
        elevation: 0,
      );

  static ButtonStyle elevated({Size? minimumSize}) => ElevatedButton.styleFrom(
        backgroundColor: background,
        foregroundColor: Colors.white,
        disabledBackgroundColor: background.withValues(alpha: 0.45),
        disabledForegroundColor: Colors.white.withValues(alpha: 0.72),
        minimumSize: minimumSize ?? const Size(double.infinity, height),
        padding: const EdgeInsets.symmetric(horizontal: 24),
        elevation: 0,
        shadowColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radius),
        ),
        textStyle: _labelStyle,
      );
}
