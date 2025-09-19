import 'package:flutter/foundation.dart';
import 'auth_service.dart';
import 'keyboard_extension.dart';

/// Admin service for managing admin privileges and bypassing restrictions
class AdminService {
  static AdminService? _instance;
  static AdminService get instance => _instance ??= AdminService._();
  AdminService._();

  // Debug-only local allowlists (never grant in release)
  static const Set<String> _devAdminUids = {'ADMIN_USER_ID_PLACEHOLDER'};
  static const Set<String> _devAdminEmails = {
    'jwgray165@gmail.com',
    'jwgray4219425@gmail.com',
  };

  bool _isAdmin = false;
  bool get isCurrentUserAdmin => _isAdmin;

  /// Call this on app start and on every auth state/token change.
  Future<void> refreshAdminStatus() async {
    final user = AuthService.instance.user;
    if (user == null) {
      _isAdmin = false;
      // Sync admin status to keyboard extension
      await UnsaidKeyboardExtension.setAdminStatus(false);
      return;
    }

    // 1) Source of truth: Firebase custom claims (server-controlled)
    try {
      final token = await user.getIdTokenResult(true); // force refresh
      final claims = token.claims ?? {};
      final claimAdmin = (claims['admin'] as bool?) ?? false;
      if (claimAdmin) {
        _isAdmin = true;
        // Sync admin status to keyboard extension
        await UnsaidKeyboardExtension.setAdminStatus(true);
        if (kDebugMode) {
          print(
            '🔧 Admin status granted via Firebase claims, synced to keyboard extension',
          );
        }
        return;
      }
    } catch (_) {
      // swallow and fall through to debug-only paths
    }

    // 2) Debug-only fallback for local testing
    if (kDebugMode) {
      final byUid = _devAdminUids.contains(user.uid);
      final byEmail =
          (user.emailVerified == true) &&
          user.email != null &&
          _devAdminEmails.contains(user.email!.toLowerCase().trim());
      _isAdmin = byUid || byEmail;
      // Sync admin status to keyboard extension
      await UnsaidKeyboardExtension.setAdminStatus(_isAdmin);
      if (_isAdmin) {
        print(
          '🔧 Admin status granted via debug allowlist (${user.email}), synced to keyboard extension',
        );
      }
      return;
    }

    // 3) Release default: non-admin
    _isAdmin = false;
    // Sync admin status to keyboard extension
    await UnsaidKeyboardExtension.setAdminStatus(false);
  }

  /// Check if current user can bypass restrictions
  bool get canBypassRestrictions => _isAdmin;

  /// Check if current user has unlimited test access
  bool get hasUnlimitedTestAccess => _isAdmin;

  /// Check if current user can retake personality tests
  bool get canRetakePersonalityTest => _isAdmin;

  /// Check if current user can access all features
  bool get hasFullFeatureAccess => _isAdmin;

  /// Get current user's admin status info
  Map<String, dynamic> get adminStatus {
    final user = AuthService.instance.user;
    return {
      'is_admin': _isAdmin,
      'user_id': user?.uid,
      'email': user?.email,
      'email_verified': user?.emailVerified,
      'source': kDebugMode ? 'claims|debug-allowlist' : 'claims',
    };
  }

  /// Log admin actions for debugging
  void logAdminAction(String action) {
    if (kDebugMode && _isAdmin) {
      debugPrint(
        '🔧 Admin Action: $action by ${AuthService.instance.user?.email ?? 'Unknown'}',
      );
    }
  }

  /// Dev helper: this *only* logs; no runtime mutation of allowlist
  static void addAdminUser(String userId) {
    if (kDebugMode) {
      debugPrint(
        '🔧 Admin user to add (update _devAdminUids in code): $userId',
      );
    }
  }

  /// Display current user ID for admin setup
  String getCurrentUserId() {
    return AuthService.instance.user?.uid ?? 'No user authenticated';
  }

  /// Display current user email for admin setup
  String getCurrentUserEmail() {
    return AuthService.instance.user?.email ?? 'No email available';
  }
}
