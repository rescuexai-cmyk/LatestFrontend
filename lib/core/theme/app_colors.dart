import 'package:flutter/material.dart';

class AppColors {
  AppColors._();

  // Khakee Theme - Primary colors
  static const Color primary = Color(0xFF252525); // Dark/Black
  static const Color primaryLight = Color(0xFF3A3A3A);
  static const Color primaryDark = Color(0xFF1A1A1A);
  
  // Secondary colors (Khaki/Beige)
  static const Color secondary = Color(0xFFDDCFB6); // Khaki
  static const Color secondaryLight = Color(0xFFEEE4D4);
  static const Color secondaryDark = Color(0xFFCBBDA4);
  
  // Background colors
  static const Color background = Color(0xFFEEE4D4); // Light khaki background
  static const Color surface = Color(0xFFFFFFFF);
  static const Color inputBackground = Color(0xFFF8F5F0);
  
  // Dark mode colors
  static const Color darkBackground = Color(0xFF252525);
  static const Color darkSurface = Color(0xFF1E1E1E);
  
  // Text colors
  static const Color textPrimary = Color(0xFF252525);
  static const Color textSecondary = Color(0xFF524C44);
  static const Color textHint = Color(0xFF999999);
  static const Color textDisabled = Color(0xFFB0B0B0);
  
  // Semantic colors (from Khakee theme)
  static const Color success = Color(0xFF38A35F); // Green
  static const Color error = Color(0xFFEC3D2D); // Red
  static const Color warning = Color(0xFFFCD848); // Yellow
  static const Color warningOrange = Color(0xFFEC932D); // Orange
  static const Color info = Color(0xFF3F9BE7); // Blue
  static const Color infoCyan = Color(0xFF5CE5F3); // Cyan
  
  // Accent colors
  static const Color accent1 = Color(0xFFA0756A); // Brownish
  static const Color accent2 = Color(0xFFABB6BA); // Grayish
  static const Color accent3 = Color(0xFFEE8FCA); // Pink
  static const Color accent4 = Color(0xFF524C44); // Dark gray
  static const Color accent5 = Color(0xFF332F2A); // Darker gray
  
  // Border colors
  static const Color border = Color(0xFFDDCFB6);
  static const Color borderLight = Color(0xFFEEE4D4);
  
  // Map marker colors
  static const Color pickupMarker = Color(0xFF38A35F);
  static const Color dropoffMarker = Color(0xFFEC3D2D);
  static const Color driverMarker = Color(0xFF38A35F);
  static const Color userMarker = Color(0xFFEC3D2D);
  static const Color routeColor = Color(0xFF3F9BE7);
  
  // Ride type colors
  static const Color economyColor = Color(0xFF38A35F);
  static const Color comfortColor = Color(0xFF3F9BE7);
  static const Color premiumColor = Color(0xFFFCD848);
  static const Color xlColor = Color(0xFFA0756A);
  
  // Social button colors
  static const Color googleRed = Color(0xFFDB4437);
  static const Color facebookBlue = Color(0xFF4267B2);
  static const Color truecallerBlue = Color(0xFF0088CC);
  
  // Rating star color
  static const Color starYellow = Color(0xFFFCD848);
  
  // Gradient colors
  static const LinearGradient primaryGradient = LinearGradient(
    colors: [primary, primaryLight],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );
  
  static const LinearGradient secondaryGradient = LinearGradient(
    colors: [secondary, secondaryLight],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );
  
  static const LinearGradient khakiGradient = LinearGradient(
    colors: [Color(0xFFEEE4D4), Color(0xFFDDCFB6)],
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
  );
}
