import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/foundation.dart';
import 'admin_service.dart';

/// Service for tracking personality test completion
class PersonalityTestService {
  static const String _testCompletedKey = 'personality_test_completed';

  /// Check if the personality test has been completed
  static Future<bool> isTestCompleted() async {
    try {
      final prefs = await SharedPreferences.getInstance();

      // Admin bypass: admins can always retake the test
      if (AdminService.instance.canRetakePersonalityTest) {
        AdminService.instance.logAdminAction(
          'Checking personality test completion (admin can retake)',
        );
        return false; // Always allow admin to retake
      }

      return prefs.getBool(_testCompletedKey) ?? false;
    } catch (e) {
      if (kDebugMode) {
        print('Error checking test completion: $e');
      }
      return false;
    }
  }

  /// Mark the personality test as completed (used by modern assessment system)
  static Future<void> markTestCompleted() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_testCompletedKey, true);

      if (AdminService.instance.isCurrentUserAdmin) {
        AdminService.instance.logAdminAction('Completed personality test');
      }

      if (kDebugMode) {
        print('✅ Personality test marked as completed');
      }
    } catch (e) {
      if (kDebugMode) {
        print('Error marking test completed: $e');
      }
    }
  }

  /// Reset test completion (for testing purposes only)
  static Future<void> resetTest() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_testCompletedKey);
      if (kDebugMode) {
        print('🔄 Personality test reset');
      }
    } catch (e) {
      if (kDebugMode) {
        print('Error resetting test: $e');
      }
    }
  }
}
