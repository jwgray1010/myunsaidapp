// lib/services/auth_service.dart
import 'package:flutter/foundation.dart'; // kIsWeb
import 'package:firebase_auth/firebase_auth.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';
import 'keyboard_extension.dart';
import 'admin_service.dart';

/// Auth service for:
/// - Google Sign-In (v7+ API) on iOS/Android/Web
/// - Sign in with Apple (iOS)
/// - Anonymous & email/password
class AuthService extends ChangeNotifier {
  static AuthService? _instance;
  static AuthService get instance => _instance ??= AuthService._();
  AuthService._();

  FirebaseAuth? _auth;
  FirebaseAuth get _authInstance => _auth ??= FirebaseAuth.instance;

  bool _isInitialized = false;

  User? _user;

  // Google Sign-In now reads CLIENT_ID automatically from GoogleService-Info.plist (iOS)
  // and google-services.json (Android), so no need for explicit clientId configuration.

  User? get user => _user;
  bool get isAuthenticated => _user != null;
  bool get isAnonymous => _user?.isAnonymous ?? false;

  /// Lazy initialization - called automatically when needed
  Future<void> _ensureInitialized() async {
    if (_isInitialized) return;

    if (kDebugMode) {
      print('🔐 AuthService: Starting lazy initialization...');
    }

    // Keep this service in sync with Firebase Auth state.
    _authInstance.authStateChanges().listen((u) async {
      _user = u;
      notifyListeners();

      // Update keyboard extension user ID based on auth state
      if (u != null && !u.isAnonymous) {
        // User signed in - store user ID for keyboard extension
        await UnsaidKeyboardExtension.setUserId(u.uid);
        // Refresh admin status to sync admin privileges to keyboard extension
        await AdminService.instance.refreshAdminStatus();
        if (kDebugMode) {
          print(
            '🔐 Firebase auth → ${u.uid} (stored for keyboard extension, admin status refreshed)',
          );
        }
      } else {
        // User signed out or anonymous - clear user ID and admin status
        await UnsaidKeyboardExtension.clearUserId();
        await UnsaidKeyboardExtension.setAdminStatus(false);
        if (kDebugMode) {
          if (u == null) {
            print('🔐 Firebase auth → signed out (cleared keyboard extension)');
          } else {
            print(
              '🔐 Firebase auth → ${u.uid} (anonymous - cleared keyboard extension)',
            );
          }
        }
      }
    });

    // Seed current user (if already signed in).
    _user = _authInstance.currentUser;

    // Store user ID for keyboard extension if user is already signed in
    if (_user != null && !_user!.isAnonymous) {
      await UnsaidKeyboardExtension.setUserId(_user!.uid);
      // Refresh admin status to sync admin privileges to keyboard extension
      await AdminService.instance.refreshAdminStatus();
    }

    _isInitialized = true;

    if (kDebugMode) {
      // ignore: avoid_print
      print(
        '✅ AuthService initialized lazily. Current user: ${_user?.uid ?? 'none'}',
      );
    }
  }

  /// Call once from main() after Firebase.initializeApp(...).
  /// Now supports lazy initialization for better platform channel compatibility.
  Future<void> initialize() async {
    await _ensureInitialized();
  }

  /// Google Sign-In using Firebase native provider flow
  /// - Web: use Firebase popup directly
  /// - Mobile: use FirebaseAuth.signInWithProvider(GoogleAuthProvider()) - no platform channels!
  Future<UserCredential?> signInWithGoogle() async {
    // Ensure Firebase is initialized and AuthService is ready
    await _ensureInitialized();

    try {
      final provider = GoogleAuthProvider();
      // Optional: provider.setCustomParameters({'prompt': 'select_account'});

      if (kIsWeb) {
        // Web: use popup flow
        final cred = await _authInstance.signInWithPopup(provider);
        _user = cred.user;
        if (kDebugMode) {
          print('✅ Google web → ${_user?.uid} ${_user?.email}');
        }
        return cred;
      } else {
        // iOS/Android: use Firebase native provider flow (no platform channels!)
        if (kDebugMode) {
          print('🔐 Starting Firebase native Google sign-in...');
        }
        final cred = await _authInstance.signInWithProvider(provider);
        _user = cred.user;
        if (kDebugMode) {
          print('✅ Google mobile → ${_user?.uid} ${_user?.email}');
        }
        return cred;
      }
    } on FirebaseAuthException catch (e) {
      if (kDebugMode) {
        print('❌ Google sign-in failed: ${e.code} - ${e.message}');
      }
      rethrow; // bubble up so UI can show SnackBar
    } catch (e) {
      if (kDebugMode) {
        print('❌ Google sign-in failed: $e');
      }
      rethrow; // bubble up so UI can show SnackBar
    }
  }

  /// Sign in with Apple (iOS only).
  Future<UserCredential?> signInWithApple() async {
    try {
      // Ensure the service is initialized before attempting sign-in
      await _ensureInitialized();

      // Add a small delay to ensure platform channels are ready
      await Future.delayed(const Duration(milliseconds: 100));

      // Check availability with retry logic
      bool isAvailable = false;
      for (int attempts = 0; attempts < 3; attempts++) {
        try {
          isAvailable = await SignInWithApple.isAvailable();
          break;
        } catch (e) {
          if (attempts == 2) {
            if (kDebugMode) {
              print(
                '❌ Sign in with Apple availability check failed after 3 attempts: $e',
              );
            }
            return null;
          }
          await Future.delayed(Duration(milliseconds: 500 * (attempts + 1)));
        }
      }

      if (!isAvailable) {
        if (kDebugMode) {
          // ignore: avoid_print
          print('⚠️ Sign in with Apple not available on this device');
        }
        return null;
      }

      final apple = await SignInWithApple.getAppleIDCredential(
        scopes: [
          AppleIDAuthorizationScopes.email,
          AppleIDAuthorizationScopes.fullName,
        ],
      );

      final oauth = OAuthProvider('apple.com').credential(
        idToken: apple.identityToken,
        accessToken: apple.authorizationCode, // optional
      );

      final res = await _authInstance.signInWithCredential(oauth);
      _user = res.user;

      // Fill displayName once, if Apple provided it.
      final needsName =
          _user != null &&
          (_user!.displayName == null || _user!.displayName!.isEmpty);
      final fullName = [
        apple.givenName ?? '',
        apple.familyName ?? '',
      ].where((s) => s.isNotEmpty).join(' ');
      if (needsName && fullName.isNotEmpty) {
        await _user!.updateDisplayName(fullName);
        await _user!.reload();
        _user = _authInstance.currentUser;
      }

      if (kDebugMode) {
        // ignore: avoid_print
        print('✅ Apple → ${_user?.uid} ${_user?.email}');
      }
      return res;
    } catch (e, st) {
      if (kDebugMode) {
        // ignore: avoid_print
        print('❌ Apple sign-in failed: $e');
        // ignore: avoid_print
        print(st);
      }
      return null;
    }
  }

  /// Anonymous sign-in (useful for trials/beta).
  Future<UserCredential?> signInAnonymously() async {
    try {
      final res = await _authInstance.signInAnonymously();
      _user = res.user;
      if (kDebugMode) {
        // ignore: avoid_print
        print('✅ Anonymous → ${_user?.uid}');
      }
      return res;
    } catch (e) {
      if (kDebugMode) {
        // ignore: avoid_print
        print('❌ Anonymous sign-in failed: $e');
      }
      return null;
    }
  }

  /// Email/password sign-in.
  Future<UserCredential?> signInWithEmailAndPassword(
    String email,
    String password,
  ) async {
    try {
      final res = await _authInstance.signInWithEmailAndPassword(
        email: email,
        password: password,
      );
      _user = res.user;
      if (kDebugMode) {
        // ignore: avoid_print
        print('✅ Email sign-in → ${_user?.uid}');
      }
      return res;
    } catch (e) {
      if (kDebugMode) {
        // ignore: avoid_print
        print('❌ Email sign-in failed: $e');
      }
      return null;
    }
  }

  /// Create account with email/password.
  Future<UserCredential?> createUserWithEmailAndPassword(
    String email,
    String password,
  ) async {
    try {
      final res = await _authInstance.createUserWithEmailAndPassword(
        email: email,
        password: password,
      );
      _user = res.user;
      if (kDebugMode) {
        // ignore: avoid_print
        print('✅ Account created → ${_user?.uid}');
      }
      return res;
    } catch (e) {
      if (kDebugMode) {
        // ignore: avoid_print
        print('❌ Create account failed: $e');
      }
      return null;
    }
  }

  /// Link anonymous user to email/password.
  Future<UserCredential?> linkAnonymousWithEmailAndPassword(
    String email,
    String password,
  ) async {
    try {
      final u = _user;
      if (u == null || !u.isAnonymous) {
        if (kDebugMode) {
          // ignore: avoid_print
          print('⚠️ Cannot link: user not anonymous');
        }
        return null;
      }
      final cred = EmailAuthProvider.credential(
        email: email,
        password: password,
      );
      final res = await u.linkWithCredential(cred);
      _user = res.user;
      if (kDebugMode) {
        // ignore: avoid_print
        print('✅ Anonymous linked → ${_user?.uid}');
      }
      return res;
    } catch (e) {
      if (kDebugMode) {
        // ignore: avoid_print
        print('❌ Link failed: $e');
      }
      return null;
    }
  }

  /// Send password reset email.
  Future<bool> resetPassword(String email) async {
    try {
      await _authInstance.sendPasswordResetEmail(email: email);
      if (kDebugMode) {
        // ignore: avoid_print
        print('📧 Password reset sent to $email');
      }
      return true;
    } catch (e) {
      if (kDebugMode) {
        // ignore: avoid_print
        print('❌ Reset failed: $e');
      }
      return false;
    }
  }

  /// Sign out (Firebase only - no need for Google plugin cleanup).
  Future<void> signOut() async {
    try {
      await _authInstance.signOut();
      _user = null;
      // Clear user ID from keyboard extension
      await UnsaidKeyboardExtension.clearUserId();
      if (kDebugMode) {
        // ignore: avoid_print
        print('🔓 Signed out and cleared keyboard extension user ID');
      }
    } catch (e) {
      if (kDebugMode) {
        // ignore: avoid_print
        print('❌ Sign out failed: $e');
      }
    }
  }

  /// Delete Firebase account.
  Future<bool> deleteAccount() async {
    try {
      final u = _user;
      if (u == null) return false;
      await u.delete();
      _user = null;
      if (kDebugMode) {
        // ignore: avoid_print
        print('🗑️ Account deleted');
      }
      return true;
    } catch (e) {
      if (kDebugMode) {
        // ignore: avoid_print
        print('❌ Delete failed: $e');
      }
      return false;
    }
  }

  /// ID token helpers.
  Future<String?> getIdToken() async {
    try {
      final u = _user;
      if (u == null) return null;
      return await u.getIdToken();
    } catch (e) {
      if (kDebugMode) {
        // ignore: avoid_print
        print('❌ getIdToken failed: $e');
      }
      return null;
    }
  }

  Future<String?> refreshIdToken() async {
    try {
      final u = _user;
      if (u == null) return null;
      return await u.getIdToken(true);
    } catch (e) {
      if (kDebugMode) {
        // ignore: avoid_print
        print('❌ refreshIdToken failed: $e');
      }
      return null;
    }
  }

  /// Minimal user info for UI.
  Map<String, dynamic> getUserInfo() {
    final u = _user;
    if (u == null) return {};
    String provider = 'unknown';
    if (u.isAnonymous) {
      provider = 'anonymous';
    } else if (u.providerData.isNotEmpty) {
      switch (u.providerData.first.providerId) {
        case 'google.com':
          provider = 'google';
          break;
        case 'apple.com':
          provider = 'apple';
          break;
        case 'password':
          provider = 'email';
          break;
        default:
          provider = u.providerData.first.providerId;
      }
    }
    return {
      'uid': u.uid,
      'email': u.email,
      'displayName': u.displayName,
      'photoURL': u.photoURL,
      'isAnonymous': u.isAnonymous,
      'provider': provider,
      'creationTime': u.metadata.creationTime?.toIso8601String(),
      'lastSignInTime': u.metadata.lastSignInTime?.toIso8601String(),
      'emailVerified': u.emailVerified,
    };
  }
}
