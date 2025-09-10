import 'package:flutter/services.dart' show rootBundle;

/// Asset verification utility for debugging missing assets
class AssetVerifier {
  /// Verifies that all core assets exist and are loadable
  static Future<void> verifyCoreAssets() async {
    final paths = <String>[
      'assets/unsaid_logo.png', // PRIMARY LOGO - single source of truth
      'assets/apple.png', // Fresh Apple sign-in logo
      'assets/google.png', // Fresh Google sign-in logo
      'assets/balance.png', // Fresh balance icon
      'assets/conflict.png', // Fresh conflict icon
      'assets/coparent.png', // Fresh co-parent icon
      'assets/emotional.png', // Fresh emotional state icon
      'assets/gentle.png', // Fresh gentle icon
      'assets/home.png', // Fresh home icon
      'assets/independent.png', // Fresh independent icon
      'assets/insight.png', // Fresh insight icon
      'assets/premium.png', // Fresh premium icon
      'assets/question.png', // Fresh questions icon
      'assets/relationship.png', // Fresh relationship icon
      'assets/settings.png', // Fresh settings icon
    ];

    print('🔍 Verifying core assets...');

    for (final path in paths) {
      try {
        await rootBundle.load(path);
        print('✅ Asset OK: $path');
      } catch (e) {
        print('❌ Missing asset: $path ($e)');
      }
    }

    print('🔍 Asset verification complete');
  }

  /// Verifies that a specific asset exists
  static Future<bool> assetExists(String path) async {
    try {
      await rootBundle.load(path);
      return true;
    } catch (e) {
      print('❌ Asset not found: $path');
      return false;
    }
  }

  /// Gets a fallback logo path if the primary one doesn't exist
  static Future<String> getValidLogoPath() async {
    const primaryLogo = 'assets/unsaid_logo.png';

    if (await assetExists(primaryLogo)) {
      return primaryLogo;
    }

    // Return primary option as fallback (will show error in UI)
    return primaryLogo;
  }
}
