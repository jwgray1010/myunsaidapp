import 'package:flutter/material.dart';

class UnsaidPalette {
  // Modern color palette with better contrast
  static const primary = Color(
    0xFF1E40AF,
  ); // Blue 800 - beautiful blue like launch screen
  static const primaryDark = Color(0xFF1E3A8A); // Blue 900
  static const primaryLight = Color(0xFF3B82F6); // Blue 500

  static const secondary = Color(
    0xFFEC4899,
  ); // Pink 500 - vibrant accent (Unsaid logo pink)
  static const secondaryDark = Color(0xFFBE185D); // Pink 700
  static const secondaryLight = Color(0xFFFDF2F8); // Pink 50

  static const accent = Color(0xFF10B981); // Emerald 500 - success/positive
  static const accentLight = Color(0xFFD1FAE5); // Emerald 100

  // Neutral colors with proper contrast
  static const surface = Colors.white;
  static const surfaceDim = Color(0xFFF8FAFC); // Slate 50
  static const surfaceDark = Color(0xFF1E293B); // Slate 800

  // Text colors that adapt to background - Updated for white text on blue background
  static const textPrimary = Color(
    0xFFFFFFFF,
  ); // White - for dark/blue backgrounds
  static const textSecondary = Color(
    0xFFF1F5F9,
  ); // Very light gray - for dark/blue backgrounds
  static const textTertiary = Color(
    0xFFCBD5E1,
  ); // Light gray - for dark/blue backgrounds

  static const textPrimaryDark = Color(
    0xFFF1F5F9,
  ); // Slate 100 - for dark backgrounds
  static const textSecondaryDark = Color(
    0xFFCBD5E1,
  ); // Slate 300 - for dark backgrounds
  static const textTertiaryDark = Color(
    0xFF64748B,
  ); // Slate 500 - for dark backgrounds

  // For light backgrounds (cards, etc.)
  static const textPrimaryLight = Color(
    0xFF0F172A,
  ); // Dark text for light backgrounds
  static const textSecondaryLight = Color(
    0xFF475569,
  ); // Medium text for light backgrounds
  static const textTertiaryLight = Color(
    0xFF94A3B8,
  ); // Light text for light backgrounds

  // Background gradients - Beautiful blue to pink like launch screen
  static const bgGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [
      primary,
      Color(0xFF2563EB),
    ], // Blue 800 to Blue 600 - rich blue gradient
  );

  static const bgGradientDark = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [primaryDark, Color(0xFF1D4ED8)], // Even darker blue gradient
  );

  static const bgGradientLight = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [primaryLight, secondary], // Light blue to pink - for accent areas
  );

  // Legacy support (keep for backward compatibility)
  static const blush = secondary; // Pink - matches Unsaid logo
  static const shell = secondaryLight;
  static const lavender = primaryLight; // Light blue now
  static const deepPurple = primaryDark; // Deep blue now
  static const ink = textPrimary; // White now for blue background
  static const softInk = textSecondary; // Light gray now
  static const success = accent;
  static const warn = Color(0xFFF59E0B); // Amber 500
  static const info = Color(0xFF3B82F6); // Blue 500

  // Utility methods for adaptive text colors
  static Color textOnColor(Color backgroundColor) {
    // Calculate luminance to determine if we need light or dark text
    final luminance = backgroundColor.computeLuminance();
    return luminance > 0.5 ? textPrimary : textPrimaryDark;
  }

  static Color secondaryTextOnColor(Color backgroundColor) {
    final luminance = backgroundColor.computeLuminance();
    return luminance > 0.5 ? textSecondary : textSecondaryDark;
  }

  static Color tertiaryTextOnColor(Color backgroundColor) {
    final luminance = backgroundColor.computeLuminance();
    return luminance > 0.5 ? textTertiary : textTertiaryDark;
  }

  // Card/elevation constants and shadows
  static const cardRadius = 16.0;

  // Note: can't be const because of withOpacity at runtime
  static List<BoxShadow> cardShadow = [
    BoxShadow(
      color: Colors.black.withOpacity(0.05),
      blurRadius: 24,
      offset: const Offset(0, 10),
    ),
  ];
  static List<BoxShadow> softShadow = [
    BoxShadow(
      color: Colors.black.withOpacity(0.06),
      blurRadius: 32,
      offset: const Offset(0, 14),
    ),
  ];
}

ThemeData buildUnsaidTheme() {
  final base = ThemeData(
    useMaterial3: true,
    brightness: Brightness.light,
    colorScheme: ColorScheme.fromSeed(
      seedColor: UnsaidPalette.primary,
      primary: UnsaidPalette.primary,
      secondary: UnsaidPalette.secondary,
      surface: UnsaidPalette.surface,
      onPrimary: UnsaidPalette.textPrimaryDark, // White text on primary color
      onSecondary:
          UnsaidPalette.textPrimaryDark, // White text on secondary color
      onSurface: UnsaidPalette.textPrimary, // Dark text on surface
    ),
  );

  return base.copyWith(
    scaffoldBackgroundColor: Colors.transparent, // we'll paint gradient
    textTheme: base.textTheme.copyWith(
      titleLarge: base.textTheme.titleLarge?.copyWith(
        fontWeight: FontWeight.w700,
        color: UnsaidPalette.textPrimary,
        letterSpacing: -0.2,
      ),
      bodyMedium: base.textTheme.bodyMedium?.copyWith(
        color: UnsaidPalette.textSecondary,
        height: 1.35,
      ),
      bodySmall: base.textTheme.bodySmall?.copyWith(
        color: UnsaidPalette.textTertiary,
      ),
    ),
    appBarTheme: base.appBarTheme.copyWith(
      backgroundColor: Colors.transparent,
      elevation: 0,
      foregroundColor: UnsaidPalette.textPrimary,
      titleTextStyle: base.textTheme.titleLarge?.copyWith(
        fontWeight: FontWeight.w700,
        color: UnsaidPalette.textPrimary,
        letterSpacing: -0.2,
      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: UnsaidPalette.surface,
        foregroundColor: UnsaidPalette.primary,
        elevation: 0,
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 18),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        side: BorderSide(
          color: UnsaidPalette.primary.withOpacity(0.2),
          width: 1,
        ),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: UnsaidPalette.primary,
        foregroundColor: UnsaidPalette.textPrimaryDark,
        elevation: 0,
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 18),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    ),
    chipTheme: base.chipTheme.copyWith(
      backgroundColor: UnsaidPalette.secondaryLight,
      labelStyle: TextStyle(color: UnsaidPalette.textPrimary),
      side: BorderSide(color: UnsaidPalette.secondary.withOpacity(0.2)),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ),
    tabBarTheme: base.tabBarTheme.copyWith(
      labelColor: UnsaidPalette.primary,
      unselectedLabelColor: UnsaidPalette.textTertiary,
      indicatorColor: UnsaidPalette.primary,
    ),
    // Optional: global fade transitions to hide tiny route paint gaps
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: {
        TargetPlatform.iOS: FadeUpwardsPageTransitionsBuilder(),
        TargetPlatform.android: FadeUpwardsPageTransitionsBuilder(),
        TargetPlatform.macOS: FadeUpwardsPageTransitionsBuilder(),
      },
    ),
    cardTheme: base.cardTheme.copyWith(
      color: UnsaidPalette.surface,
      margin: EdgeInsets.zero,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(UnsaidPalette.cardRadius),
      ),
    ),
  );
}
