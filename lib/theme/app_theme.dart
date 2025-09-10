import 'package:flutter/material.dart';
import '../ui/unsaid_theme.dart';

/// Unified AppTheme that bridges the old AppTheme usage with the modern UnsaidPalette system
/// This prevents theme conflicts and provides backward compatibility
class AppTheme {
  // Spacing values (mapped to Unsaid design system)
  static const spacing = _Spacing();

  // Border radius values (mapped to Unsaid design system)
  static const borderRadius = _BorderRadius();
  static const radius = _BorderRadius(); // Alternative naming for compatibility

  // Shadow values (mapped to Unsaid design system)
  static const shadows = _Shadows();

  // Colors (use UnsaidPalette for consistency)
  static const colors = UnsaidPalette;

  // Spacing constants for backward compatibility
  static const double spaceXS = 4.0;
  static const double spaceSM = 8.0;
  static const double spaceMD = 16.0;
  static const double spaceLG = 24.0;
  static const double spaceXL = 32.0;
  static const double spaceXXL = 48.0;

  // Border radius constants for backward compatibility
  static const double radiusLG = 16.0;
  static const double radiusMD = 12.0;
  static const double radiusFull = 999.0;

  // Animation durations
  static const Duration fastAnimation = Duration(milliseconds: 200);
  static const Duration normalAnimation = Duration(milliseconds: 300);

  // Shadow styles
  static List<BoxShadow> get floatingShadow => [
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.08),
          blurRadius: 16,
          offset: const Offset(0, 8),
          spreadRadius: 0,
        ),
      ];

  // Gradient for backward compatibility
  static const LinearGradient primaryGradient = LinearGradient(
    colors: [UnsaidPalette.blush, UnsaidPalette.lavender],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  /// Use the unified Unsaid theme (this replaces the old lightTheme)
  static ThemeData get lightTheme => buildUnsaidTheme();
}

/// Spacing class for backward compatibility with existing AppTheme.spacing usage
class _Spacing {
  const _Spacing();

  double get xs => 4.0;
  double get sm => 8.0;
  double get md => 16.0;
  double get lg => 24.0;
  double get xl => 32.0;
  double get xxl => 48.0;
}

/// Border radius class for backward compatibility
class _BorderRadius {
  const _BorderRadius();

  double get sm => 8.0;
  double get md => 12.0;
  double get lg => 16.0;
  double get xl => 24.0;
}

/// Shadow class for backward compatibility
class _Shadows {
  const _Shadows();

  List<BoxShadow> get soft => [
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.04),
          blurRadius: 4,
          offset: const Offset(0, 2),
        ),
      ];

  List<BoxShadow> get medium => [
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.08),
          blurRadius: 8,
          offset: const Offset(0, 4),
        ),
      ];

  List<BoxShadow> get strong => [
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.12),
          blurRadius: 16,
          offset: const Offset(0, 8),
        ),
      ];
}
