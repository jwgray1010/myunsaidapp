import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';
import '../ui/unsaid_theme.dart';
import '../ui/unsaid_widgets.dart';

class OnboardingAccountScreenProfessional extends StatefulWidget {
  const OnboardingAccountScreenProfessional({
    super.key,
    required this.onSignInWithApple,
    required this.onSignInWithGoogle,
    this.onViewTerms,
    this.onViewPrivacy,
  });

  final Future<void> Function() onSignInWithApple;
  final Future<void> Function() onSignInWithGoogle;
  final VoidCallback? onViewTerms;
  final VoidCallback? onViewPrivacy;

  @override
  State<OnboardingAccountScreenProfessional> createState() =>
      _OnboardingAccountScreenProfessionalState();
}

class _OnboardingAccountScreenProfessionalState
    extends State<OnboardingAccountScreenProfessional>
    with TickerProviderStateMixin {
  late final AnimationController _slideController;
  late final AnimationController _fadeController;
  late final AnimationController _logoController;
  late final Animation<Offset> _slideAnimation;
  late final Animation<double> _fadeAnimation;
  late final Animation<double> _logoAnimation;

  // Per-button loading for cleaner UX
  bool _loadingApple = false;
  bool _loadingGoogle = false;

  // Production robustness: double-tap guard and error tracking
  DateTime? _lastButtonTap;
  String _lastErrorMessage = '';

  // Precached assets
  late final AssetImage _appLogo = const AssetImage('assets/unsaid_logo.png');
  late final AssetImage _appleLogo = const AssetImage('assets/apple.png');
  late final AssetImage _googleLogo = const AssetImage('assets/google.png');

  // Production robustness: Platform detection helper
  bool get _shouldShowAppleSignIn {
    if (kIsWeb) return false;
    try {
      return !kIsWeb && Platform.isIOS;
    } catch (e) {
      return false; // Safe fallback
    }
  }

  @override
  void initState() {
    super.initState();

    _slideController = AnimationController(
      duration: const Duration(milliseconds: 800),
      vsync: this,
    );
    _fadeController = AnimationController(
      duration: const Duration(milliseconds: 600),
      vsync: this,
    );
    _logoController = AnimationController(
      duration: const Duration(milliseconds: 1200),
      vsync: this,
    );

    _slideAnimation =
        Tween<Offset>(begin: const Offset(0, 0.5), end: Offset.zero).animate(
          CurvedAnimation(parent: _slideController, curve: Curves.easeOutCubic),
        );

    _fadeAnimation = Tween<double>(
      begin: 0,
      end: 1,
    ).animate(CurvedAnimation(parent: _fadeController, curve: Curves.easeOut));

    _logoAnimation = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(parent: _logoController, curve: Curves.elasticOut),
    );

    // Precache images next frame
    WidgetsBinding.instance.addPostFrameCallback((_) {
      precacheImage(_appLogo, context);
      precacheImage(_appleLogo, context);
      precacheImage(_googleLogo, context);
    });

    _startAnimations();
  }

  Future<void> _startAnimations() async {
    // Check for reduced motion in didChangeDependencies instead of initState
    await Future.delayed(const Duration(milliseconds: 250));
    if (mounted) _logoController.forward();
    await Future.delayed(const Duration(milliseconds: 350));
    if (mounted) {
      _fadeController.forward();
      _slideController.forward();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Check for reduced motion accessibility preference
    final reduceMotion = MediaQuery.accessibleNavigationOf(context);
    if (reduceMotion && !_logoController.isCompleted) {
      // Snap to end states for accessibility
      _logoController.value = 1;
      _fadeController.value = 1;
      _slideController.value = 1;
    }
  }

  Future<void> _handleSignIn({
    required Future<void> Function() action,
    required bool Function() getLoading,
    required void Function(bool) setLoading,
    required String errorContext,
  }) async {
    if (getLoading()) return;

    // Production robustness: Double-tap guard
    final now = DateTime.now();
    if (_lastButtonTap != null &&
        now.difference(_lastButtonTap!).inMilliseconds < 1000) {
      return; // Ignore rapid double-taps
    }
    _lastButtonTap = now;

    // Safe haptic feedback
    try {
      HapticFeedback.lightImpact();
    } catch (e) {
      // Haptics can fail on some devices - don't crash
    }

    setLoading(true);
    setState(() => _lastErrorMessage = '');

    try {
      // Subtle rhythm to feel responsive before async hop
      await Future.delayed(const Duration(milliseconds: 60));
      await action();

      // Telemetry hook for production analytics
      debugPrint('Sign-in success: $errorContext');
    } catch (e) {
      if (!mounted) return;

      // Production-ready error messages with specificity
      String errorMessage;
      if (e.toString().contains('network')) {
        errorMessage =
            'Network connection issue. Please check your internet and try again.';
      } else if (e.toString().contains('cancelled')) {
        errorMessage = 'Sign-in was cancelled.';
      } else if (errorContext.contains('Apple')) {
        errorMessage =
            'Apple Sign In temporarily unavailable. Please try Google or check back later.';
      } else if (errorContext.contains('Google')) {
        errorMessage =
            'Google Sign In temporarily unavailable. Please try Apple or check back later.';
      } else {
        errorMessage = 'Sign-in failed. Please try again in a moment.';
      }

      setState(() => _lastErrorMessage = errorMessage);

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text(errorMessage),
          action: SnackBarAction(
            label: 'Dismiss',
            onPressed: () =>
                ScaffoldMessenger.of(context).hideCurrentSnackBar(),
          ),
        ),
      );

      // Telemetry hook for production error tracking
      debugPrint(
        'Sign-in error: $errorContext - ${e.toString()} (stored: $_lastErrorMessage)',
      );
    } finally {
      if (mounted) setLoading(false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
        statusBarBrightness: Brightness.dark,
      ),
      child: Shortcuts(
        shortcuts: <LogicalKeySet, Intent>{
          LogicalKeySet(LogicalKeyboardKey.enter): const ActivateIntent(),
          LogicalKeySet(LogicalKeyboardKey.numpadEnter): const ActivateIntent(),
          LogicalKeySet(LogicalKeyboardKey.escape): const DismissIntent(),
        },
        child: Actions(
          actions: <Type, Action<Intent>>{
            ActivateIntent: CallbackAction<ActivateIntent>(
              onInvoke: (ActivateIntent intent) {
                // Production UX: Enter key triggers primary action (Apple sign-in on iOS, Google otherwise)
                if (_shouldShowAppleSignIn && !_loadingApple) {
                  _handleSignIn(
                    action: widget.onSignInWithApple,
                    getLoading: () => _loadingApple,
                    setLoading: (v) => setState(() => _loadingApple = v),
                    errorContext: 'Apple sign-in',
                  );
                } else if (!_loadingGoogle) {
                  _handleSignIn(
                    action: widget.onSignInWithGoogle,
                    getLoading: () => _loadingGoogle,
                    setLoading: (v) => setState(() => _loadingGoogle = v),
                    errorContext: 'Google sign-in',
                  );
                }
                return null;
              },
            ),
          },
          child: Scaffold(
            backgroundColor: Colors.transparent,
            body: Container(
              decoration: const BoxDecoration(
                gradient: UnsaidPalette.bgGradient,
              ),
              child: SafeArea(
                child: Center(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      // Max content width for desktop/tablet polish
                      final maxWidth = constraints.maxWidth < 480
                          ? constraints.maxWidth
                          : 420.0;

                      return SingleChildScrollView(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 24,
                          vertical: 32,
                        ),
                        child: Semantics(
                          container: true,
                          label: 'Sign-in options',
                          child: FocusTraversalGroup(
                            policy: OrderedTraversalPolicy(),
                            child: ConstrainedBox(
                              constraints: BoxConstraints.tightFor(
                                width: maxWidth,
                              ),
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  // Logo
                                  ScaleTransition(
                                    scale: _logoAnimation,
                                    child: Semantics(
                                      label: 'Unsaid logo',
                                      child: Container(
                                        padding: const EdgeInsets.all(24),
                                        decoration: BoxDecoration(
                                          color: Colors.white,
                                          shape: BoxShape.circle,
                                          boxShadow: UnsaidPalette.softShadow,
                                          border: Border.all(
                                            color: UnsaidPalette.blush
                                                .withOpacity(0.10),
                                            width: 2,
                                          ),
                                        ),
                                        child: Image(
                                          image: _appLogo,
                                          width: 120,
                                          height: 120,
                                          errorBuilder: (_, __, ___) {
                                            return Container(
                                              width: 120,
                                              height: 120,
                                              decoration: BoxDecoration(
                                                gradient: const LinearGradient(
                                                  colors: [
                                                    UnsaidPalette.blush,
                                                    UnsaidPalette.lavender,
                                                  ],
                                                  begin: Alignment.topLeft,
                                                  end: Alignment.bottomRight,
                                                ),
                                                borderRadius:
                                                    BorderRadius.circular(20),
                                              ),
                                              child: const Center(
                                                child: Text(
                                                  'U',
                                                  style: TextStyle(
                                                    color: Colors.white,
                                                    fontSize: 60,
                                                    fontWeight: FontWeight.bold,
                                                  ),
                                                ),
                                              ),
                                            );
                                          },
                                        ),
                                      ),
                                    ),
                                  ),

                                  const SizedBox(height: 36),

                                  // Animated content
                                  FadeTransition(
                                    opacity: _fadeAnimation,
                                    child: SlideTransition(
                                      position: _slideAnimation,
                                      child: Column(
                                        children: [
                                          // Gradient title with production accessibility
                                          Semantics(
                                            header: true,
                                            child: Text(
                                              'Create Your Experience',
                                              textAlign: TextAlign.center,
                                              textScaler: TextScaler.linear(
                                                // Production UX: Cap scaling to prevent layout breaks
                                                (MediaQuery.textScalerOf(
                                                  context,
                                                ).scale(1.0)).clamp(0.8, 1.4),
                                              ),
                                              style: theme
                                                  .textTheme
                                                  .headlineMedium
                                                  ?.copyWith(
                                                    fontWeight: FontWeight.w800,
                                                    color: Colors.white,
                                                    letterSpacing: 0.2,
                                                  ),
                                            ),
                                          ),
                                          const SizedBox(height: 12),
                                          Text(
                                            'Choose how you want to get started with Unsaid.',
                                            textAlign: TextAlign.center,
                                            textScaler: TextScaler.linear(
                                              // Production UX: Cap scaling to prevent layout breaks
                                              (MediaQuery.textScalerOf(
                                                context,
                                              ).scale(1.0)).clamp(0.8, 1.3),
                                            ),
                                            style: theme.textTheme.bodyLarge
                                                ?.copyWith(
                                                  color: Colors.white
                                                      .withOpacity(0.90),
                                                  height: 1.35,
                                                ),
                                          ),

                                          const SizedBox(height: 40),

                                          // Buttons with production-aware platform detection
                                          Column(
                                            children: [
                                              // Native Apple Sign-In Button - Platform aware
                                              if (_shouldShowAppleSignIn) ...[
                                                SizedBox(
                                                  height: 52,
                                                  child: _loadingApple
                                                      ? Container(
                                                          decoration: BoxDecoration(
                                                            border: Border.all(
                                                              color:
                                                                  Colors.white,
                                                              width: 1,
                                                            ),
                                                            borderRadius:
                                                                BorderRadius.circular(
                                                                  14,
                                                                ),
                                                          ),
                                                          child: Center(
                                                            child: Row(
                                                              mainAxisAlignment:
                                                                  MainAxisAlignment
                                                                      .center,
                                                              children: [
                                                                const SizedBox(
                                                                  width: 20,
                                                                  height: 20,
                                                                  child: CircularProgressIndicator(
                                                                    strokeWidth:
                                                                        2,
                                                                    color: Colors
                                                                        .white,
                                                                  ),
                                                                ),
                                                                const SizedBox(
                                                                  width: 12,
                                                                ),
                                                                Text(
                                                                  'Signing in…',
                                                                  textScaler: TextScaler.linear(
                                                                    // Production UX: Cap scaling for loading text
                                                                    (MediaQuery.textScalerOf(
                                                                          context,
                                                                        ).scale(
                                                                          1.0,
                                                                        ))
                                                                        .clamp(
                                                                          0.8,
                                                                          1.2,
                                                                        ),
                                                                  ),
                                                                  style: const TextStyle(
                                                                    color: Colors
                                                                        .white,
                                                                    fontSize:
                                                                        16,
                                                                    fontWeight:
                                                                        FontWeight
                                                                            .w600,
                                                                  ),
                                                                ),
                                                              ],
                                                            ),
                                                          ),
                                                        )
                                                      : SignInWithAppleButton(
                                                          onPressed: () => _handleSignIn(
                                                            action: widget
                                                                .onSignInWithApple,
                                                            getLoading: () =>
                                                                _loadingApple,
                                                            setLoading: (v) =>
                                                                setState(
                                                                  () =>
                                                                      _loadingApple =
                                                                          v,
                                                                ),
                                                            errorContext:
                                                                'Apple sign-in',
                                                          ),
                                                          style:
                                                              SignInWithAppleButtonStyle
                                                                  .white,
                                                          borderRadius:
                                                              BorderRadius.circular(
                                                                14,
                                                              ),
                                                        ),
                                                ),
                                                const SizedBox(height: 14),
                                              ],
                                              _SignInButton(
                                                label: 'Sign in with Google',
                                                semanticsLabel:
                                                    'Sign in with Google',
                                                leading: Image(
                                                  image: _googleLogo,
                                                  width: 20,
                                                  height: 20,
                                                ),
                                                loading: _loadingGoogle,
                                                onPressed: () => _handleSignIn(
                                                  action:
                                                      widget.onSignInWithGoogle,
                                                  getLoading: () =>
                                                      _loadingGoogle,
                                                  setLoading: (v) => setState(
                                                    () => _loadingGoogle = v,
                                                  ),
                                                  errorContext:
                                                      'Google sign-in',
                                                ),
                                              ),
                                            ],
                                          ),

                                          const SizedBox(height: 28),

                                          // Privacy / Terms with production polish
                                          UnsaidCard(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 16,
                                              vertical: 14,
                                            ),
                                            child: Row(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                const Padding(
                                                  padding: EdgeInsets.only(
                                                    top: 2,
                                                  ),
                                                  child: Icon(
                                                    Icons.security_outlined,
                                                    color: UnsaidPalette.blush,
                                                    size: 20,
                                                  ),
                                                ),
                                                const SizedBox(width: 12),
                                                Expanded(
                                                  child: RichText(
                                                    textScaler: TextScaler.linear(
                                                      // Production UX: Cap scaling for privacy text
                                                      (MediaQuery.textScalerOf(
                                                        context,
                                                      ).scale(1.0)).clamp(
                                                        0.8,
                                                        1.2,
                                                      ),
                                                    ),
                                                    text: TextSpan(
                                                      style: const TextStyle(
                                                        color: Colors
                                                            .black, // Changed from UnsaidPalette.softInk to black
                                                        fontSize: 14,
                                                        height: 1.4,
                                                      ),
                                                      children: [
                                                        const TextSpan(
                                                          text:
                                                              'Your privacy is protected. We never share your personal information. ',
                                                        ),
                                                        if (widget
                                                                .onViewPrivacy !=
                                                            null)
                                                          WidgetSpan(
                                                            alignment:
                                                                PlaceholderAlignment
                                                                    .middle,
                                                            child: _LinkChip(
                                                              label:
                                                                  'Privacy Policy',
                                                              onTap: widget
                                                                  .onViewPrivacy!,
                                                            ),
                                                          ),
                                                        if (widget
                                                                .onViewTerms !=
                                                            null)
                                                          const TextSpan(
                                                            text: '  •  ',
                                                          ),
                                                        if (widget
                                                                .onViewTerms !=
                                                            null)
                                                          WidgetSpan(
                                                            alignment:
                                                                PlaceholderAlignment
                                                                    .middle,
                                                            child: _LinkChip(
                                                              label: 'Terms',
                                                              onTap: widget
                                                                  .onViewTerms!,
                                                            ),
                                                          ),
                                                      ],
                                                    ),
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
        ), // Close Actions
      ), // Close Shortcuts
    );
  }
}

/// Brand-clean secondary button with hover, focus ring, and loading swap.
class _SignInButton extends StatelessWidget {
  const _SignInButton({
    required this.label,
    required this.leading,
    required this.onPressed,
    required this.loading,
    required this.semanticsLabel,
  });

  final String label;
  final Widget leading;
  final VoidCallback onPressed;
  final bool loading;
  final String semanticsLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Semantics(
      button: true,
      label: semanticsLabel,
      enabled: !loading,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 52),
        child: UnsaidSecondaryButton(
          onPressed: loading ? null : onPressed,
          icon: AnimatedSwitcher(
            duration: const Duration(milliseconds: 180),
            switchInCurve: Curves.easeOut,
            switchOutCurve: Curves.easeIn,
            child: loading
                ? const SizedBox(
                    key: ValueKey('spinner'),
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : SizedBox(
                    key: const ValueKey('icon'),
                    width: 20,
                    height: 20,
                    child: leading,
                  ),
          ),
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 180),
            child: Text(
              loading ? 'Signing in…' : label,
              key: ValueKey(loading),
              textScaler: TextScaler.linear(
                // Production UX: Cap scaling to prevent button layout breaks
                (MediaQuery.textScalerOf(context).scale(1.0)).clamp(0.8, 1.2),
              ),
              style: theme.textTheme.labelLarge?.copyWith(
                color:
                    Colors.black, // Changed from UnsaidPalette.softInk to black
                fontWeight: FontWeight.w600,
                letterSpacing: 0.2,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Tiny link chip for Terms/Privacy that looks tappable and accessible.
class _LinkChip extends StatelessWidget {
  const _LinkChip({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
          child: Text(
            label,
            style: theme.textTheme.labelMedium?.copyWith(
              color: UnsaidPalette.blush,
              fontWeight: FontWeight.w600,
              decoration: TextDecoration.underline,
              decorationThickness: 1.4,
            ),
          ),
        ),
      ),
    );
  }
}
