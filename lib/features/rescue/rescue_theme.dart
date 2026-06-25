import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../ride/presentation/widgets/figma_ride_selection_widgets.dart';

/// Shared rescue flow colors — matches Figma / app gold palette.
abstract final class RescueTheme {
  static const Color accent = figmaRideAccent;
  static const Color cardBg = Color(0xFFF9F8F6);
  static const Color screenBg = Color(0xFFF6EFE4);
  static const Color textPrimary = Color(0xFF1A1A1A);
  static const Color textSecondary = Color(0xFF5B5B5B);
  static const Color textMuted = Color(0xFF929292);
  static const Color stroke = Color(0xFFE8E0D4);
  static const Color panelBg = Color(0xFFF1F1F1);
  static const Color success = Color(0xFF2E7D32);

  static TextStyle titleLarge = GoogleFonts.poppins(
    fontSize: 22,
    fontWeight: FontWeight.w700,
    color: textPrimary,
    height: 1.25,
  );

  static TextStyle titleMedium = GoogleFonts.poppins(
    fontSize: 18,
    fontWeight: FontWeight.w600,
    color: textPrimary,
    height: 1.3,
  );

  static TextStyle body = GoogleFonts.poppins(
    fontSize: 15,
    fontWeight: FontWeight.w400,
    color: textSecondary,
    height: 1.45,
  );

  static TextStyle label = GoogleFonts.poppins(
    fontSize: 14,
    fontWeight: FontWeight.w500,
    color: textPrimary,
    height: 1.35,
  );

  static TextStyle price = GoogleFonts.poppins(
    fontSize: 16,
    fontWeight: FontWeight.w600,
    color: textPrimary,
  );

  static InputDecoration fieldDecoration(String hint) => InputDecoration(
        hintText: hint,
        hintStyle: GoogleFonts.poppins(color: const Color(0xFFBDBDBD), fontSize: 15),
        filled: true,
        fillColor: Colors.white,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: stroke),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: stroke),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: accent, width: 1.5),
        ),
      );

  static ButtonStyle primaryButton = FilledButton.styleFrom(
    backgroundColor: accent,
    foregroundColor: Colors.white,
    minimumSize: const Size(double.infinity, 54),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    textStyle: GoogleFonts.poppins(fontSize: 16, fontWeight: FontWeight.w600),
  );
}
