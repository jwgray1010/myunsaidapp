import 'package:flutter/foundation.dart';
import 'keyboard_manager.dart';
import 'keyboard_data_service.dart';

/// Service to detect and manage new user experience across the app
class NewUserExperienceService extends ChangeNotifier {
  static final NewUserExperienceService _instance =
      NewUserExperienceService._internal();
  factory NewUserExperienceService() => _instance;
  NewUserExperienceService._internal();

  bool? _isNewUser;
  int _totalInteractions = 0;
  DateTime? _lastDataCheck;

  /// Checks if user is new (has no keyboard data)
  bool get isNewUser => _isNewUser ?? true;

  /// Gets total interactions from keyboard
  int get totalInteractions => _totalInteractions;

  /// Check if user has started generating keyboard data
  Future<bool> checkUserHasData() async {
    // Cache check for 30 seconds to avoid repeated calls
    if (_lastDataCheck != null &&
        DateTime.now().difference(_lastDataCheck!).inSeconds < 30) {
      return !isNewUser;
    }

    try {
      int interactions = 0;

      // 1) Prefer cheap metadata from the bridge
      final meta = await KeyboardDataService().getKeyboardStorageMetadata();
      if (meta != null) {
        interactions += ((meta['interaction_count'] as num?) ?? 0).toInt();
        // treat any recorded items as "has data" for onboarding purposes
        interactions += ((meta['tone_count'] as num?) ?? 0).toInt();
        interactions += ((meta['suggestion_count'] as num?) ?? 0).toInt();
        interactions += ((meta['analytics_count'] as num?) ?? 0).toInt();
        interactions += ((meta['api_suggestions_count'] as num?) ?? 0).toInt();
        interactions += ((meta['api_trial_count'] as num?) ?? 0).toInt();
      }

      // 2) Fallback to local app history
      if (interactions == 0) {
        final km = KeyboardManager();
        interactions = km.analysisHistory.length;
      }

      _totalInteractions = interactions;
      _isNewUser = _totalInteractions == 0;
      _lastDataCheck = DateTime.now();
      notifyListeners();
      return !_isNewUser!;
    } catch (e) {
      debugPrint('Error checking user data: $e');
      _isNewUser = true;
      _totalInteractions = 0;
      notifyListeners();
      return false;
    }
  }

  /// Get new user onboarding message for specific screen
  Map<String, String> getOnboardingMessage(String screenType) {
    switch (screenType) {
      case 'home':
        return {
          'title': '🏠 Welcome Home!',
          'subtitle': 'Your personalized dashboard awaits',
          'message':
              'Enable the Unsaid keyboard to start building your communication insights',
        };
      case 'insights':
        return {
          'title': '📊 Your Insights Dashboard',
          'subtitle': 'Real-time communication analytics',
          'message':
              'Start messaging to see your tone patterns, improvement trends, and personalized suggestions',
        };
      case 'relationship':
        return {
          'title': '💕 Relationship Insights',
          'subtitle': 'Understand your communication together',
          'message':
              'Your relationship insights will develop as you and your partner use Unsaid',
        };
      case 'settings':
        return {
          'title': '⚙️ Personalize Your Experience',
          'subtitle': 'Customize Unsaid for your needs',
          'message':
              'Set up your preferences to get the most helpful suggestions',
        };
      default:
        return {
          'title': '✨ Getting Started with Unsaid',
          'subtitle': 'Your AI communication coach',
          'message': 'Enable the keyboard to unlock personalized insights',
        };
    }
  }

  /// Get actionable next steps for new users
  List<String> getNextSteps() {
    return [
      '📱 Enable the Unsaid keyboard in iOS Settings',
      '💬 Start a conversation with someone',
      '🔮 Watch your insights grow in real-time',
      '🎯 Get personalized suggestions to improve communication',
    ];
  }

  /// Mark user as no longer new (for testing)
  void markUserAsExperienced() {
    _isNewUser = false;
    _totalInteractions = 10; // Simulate some data
    notifyListeners();
  }

  /// Reset user to new status (for testing)
  void markUserAsNew() {
    _isNewUser = true;
    _totalInteractions = 0;
    notifyListeners();
  }

  /// Get encouraging message based on progress
  String getProgressMessage() {
    if (_totalInteractions == 0) {
      return "🌟 Ready to start your communication journey!";
    } else if (_totalInteractions < 10) {
      return "🚀 Great start! Keep using Unsaid to unlock more insights";
    } else if (_totalInteractions < 50) {
      return "📈 Building your profile! Your insights are getting more accurate";
    } else {
      return "🎯 You're getting personalized insights! Keep it up";
    }
  }

  /// Clear cache to force fresh check
  void clearCache() {
    _lastDataCheck = null;
  }
}
