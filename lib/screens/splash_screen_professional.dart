import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../ui/unsaid_theme.dart';
import '../services/auth_service.dart';
import '../services/onboarding_service.dart';
import '../services/trial_service.dart';
import '../services/personality_data_manager.dart';

class SplashScreenProfessional extends StatefulWidget {
  const SplashScreenProfessional({super.key});

  @override
  State<SplashScreenProfessional> createState() =>
      _SplashScreenProfessionalState();
}

class _SplashScreenProfessionalState extends State<SplashScreenProfessional>
    with TickerProviderStateMixin {
  late AnimationController _logoController;
  late AnimationController _textController;
  late AnimationController _pulseController;
  late AnimationController _bgController; // Brand-animated gradient
  late Animation<double> _logoScale;
  late Animation<double> _logoOpacity;
  late Animation<double> _textOpacity;
  late Animation<Offset> _textSlide;
  late Animation<double> _pulseAnimation;
  late Animation<double> _bgAnimation; // Background gradient animation
  late Animation<double> _glowAnimation; // Glow pulse tied to loader

  // Preload the logo so first frame is ready
  late final AssetImage _logoImage = const AssetImage('assets/unsaid_logo.png');

  @override
  void initState() {
    super.initState();

    // Status bar style (kept consistent across splash & next pages)
    SystemChrome.setSystemUIOverlayStyle(
      const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
        statusBarBrightness: Brightness.dark,
      ),
    );

    // Controllers
    _logoController = AnimationController(
      duration: const Duration(
        milliseconds: 1000,
      ), // Slightly faster for polish
      vsync: this,
    );
    _textController = AnimationController(
      duration: const Duration(milliseconds: 800),
      vsync: this,
    );
    _pulseController = AnimationController(
      duration: const Duration(milliseconds: 1600), // Sync with loader rhythm
      vsync: this,
    );
    _bgController = AnimationController(
      duration: const Duration(seconds: 8), // Slow battery-safe drift
      vsync: this,
    )..repeat(reverse: true);

    _logoScale = Tween<double>(begin: 0.5, end: 1.0).animate(
      CurvedAnimation(parent: _logoController, curve: Curves.elasticOut),
    );
    _logoOpacity = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _logoController,
        curve: const Interval(0.0, 0.6, curve: Curves.easeOut),
      ),
    );

    // Premium pulsing animation synced with loader
    _pulseAnimation = Tween<double>(begin: 1.0, end: 1.05).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );

    // Soft glow pulse tied to loader rhythm
    _glowAnimation = Tween<double>(begin: 0.15, end: 0.35).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );

    // Background gradient animation
    _bgAnimation = CurvedAnimation(
      parent: _bgController,
      curve: Curves.easeInOut,
    );

    _textOpacity = Tween<double>(
      begin: 0.0,
      end: 1.0,
    ).animate(CurvedAnimation(parent: _textController, curve: Curves.easeOut));
    _textSlide = Tween<Offset>(begin: const Offset(0, 0.5), end: Offset.zero)
        .animate(
          CurvedAnimation(parent: _textController, curve: Curves.easeOutCubic),
        );

    // Defer first frame until brand is ready
    final binding = WidgetsBinding.instance;
    binding.deferFirstFrame();

    // Warm up images so the first paint is smooth
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        await precacheImage(_logoImage, context);
      } catch (_) {}
      binding.allowFirstFrame();
      _startAnimations();
    });
  }

  Future<void> _startAnimations() async {
    try {
      // Premium timing with micro-overlaps for intentional feel
      // Logo opacity: 0 → 1 over 600ms
      if (mounted) _logoController.forward();

      // Tagline starts at T+250ms (overlap for smooth transition)
      await Future.delayed(const Duration(milliseconds: 250));
      if (mounted) _textController.forward();

      // Start the pulsing animation and repeat it
      if (mounted) {
        _pulseController.repeat(reverse: true);
      }

      // Loader appears at T+550ms (slight overlap with text)
      await Future.delayed(const Duration(milliseconds: 300));
      if (!mounted) return;

      await _navigateBasedOnState();
    } catch (_) {
      // Fallback to onboarding on any unexpected error
      if (!mounted) return;
      Navigator.pushReplacementNamed(context, '/onboarding');
    }
  }

  Future<void> _navigateBasedOnState() async {
    try {
      final authService = AuthService.instance;
      final onboardingService = OnboardingService.instance;

      final isAuthenticated = authService.isAuthenticated;
      final isOnboardingComplete = await onboardingService
          .isOnboardingComplete();

      if (!mounted) return;

      if (isAuthenticated && isOnboardingComplete) {
        Navigator.pushReplacementNamed(context, '/main');

        // Run optional/post-startup tasks AFTER navigation (non-blocking)
        // ignore: unawaited_futures
        Future(() async {
          try {
            final personalityManager = PersonalityDataManager.shared;
            if (await personalityManager.hasKeyboardDataAvailable()) {
              await personalityManager.performStartupKeyboardAnalysis();
            }
          } catch (_) {}
          try {
            final trialService = Provider.of<TrialService>(
              context,
              listen: false,
            );
            await trialService.enableAdminModeForReturningUser();
          } catch (_) {}
        });
      } else {
        Navigator.pushReplacementNamed(context, '/onboarding');
      }
    } catch (_) {
      if (!mounted) return;
      Navigator.pushReplacementNamed(context, '/onboarding');
    }
  }

  @override
  void dispose() {
    _logoController.dispose();
    _textController.dispose();
    _pulseController.dispose();
    _bgController.dispose(); // Dispose background controller
    super.dispose();
  }

  // Premium animated background gradient
  Decoration _animatedBackground() {
    // Two "nearby" gradients to cross-fade for subtle motion
    const g1 = LinearGradient(
      begin: Alignment(-0.9, -1),
      end: Alignment(1, 1),
      colors: [Color(0xFF2563EB), Color(0xFFA855F7)],
    );
    const g2 = LinearGradient(
      begin: Alignment(1, -1),
      end: Alignment(-1, 1),
      colors: [Color(0xFF5B8CFF), Color(0xFFB077FF)],
    );

    final t = _bgAnimation.value;
    return BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.lerp(g1.begin as Alignment, g2.begin as Alignment, t)!,
        end: Alignment.lerp(g1.end as Alignment, g2.end as Alignment, t)!,
        colors: List.generate(
          2,
          (i) => Color.lerp(g1.colors[i], g2.colors[i], t)!,
        ),
      ),
    );
  }

  // Glossy logo with shine reveal effect
  Widget _glossyLogo(Widget child) {
    return ShaderMask(
      blendMode: BlendMode.srcATop,
      shaderCallback: (rect) {
        final t = (_logoController.value).clamp(0.0, 1.0);
        final dx = lerpDouble(-rect.width, rect.width, t)!;
        return LinearGradient(
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
          colors: [
            Colors.transparent,
            Colors.white.withOpacity(.45),
            Colors.transparent,
          ],
          stops: const [0.45, 0.5, 0.55],
          transform: const GradientRotation(.35),
        ).createShader(rect.shift(Offset(dx, 0)));
      },
      child: child,
    );
  }

  // Reduced motion accessibility support
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduceMotion = MediaQuery.accessibleNavigationOf(context);
    if (reduceMotion) {
      _logoController.value = 1;
      _textController.value = 1;
      _pulseController.stop();
      _bgController.stop();
    }
  }

  Widget _buildFallbackLogo() {
    return Container(
      width: 140,
      height: 140,
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF2563EB), Color(0xFFA855F7)], // Match main gradient
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: UnsaidPalette.blush.withValues(alpha: 0.3),
            blurRadius: 20,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: const Center(
        child: Text(
          'U',
          style: TextStyle(
            color: Colors.white,
            fontSize: 64,
            fontWeight: FontWeight.w800,
            letterSpacing: -2,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
        statusBarBrightness: Brightness.dark,
      ),
      child: Container(
        // Immediate background to prevent any black screen
        color: const Color(0xFF2563EB), // Launch screen blue
        child: Scaffold(
          backgroundColor: const Color(
            0xFF2563EB,
          ), // prevents any momentary black
          body: Container(
            width: double.infinity,
            height: double.infinity,
            decoration: const BoxDecoration(gradient: UnsaidPalette.bgGradient),
            child: AnimatedBuilder(
              animation: Listenable.merge([
                _logoController,
                _textController,
                _pulseController,
                _bgController, // Include background animation
              ]),
              builder: (context, _) {
                return Container(
                  width: double.infinity,
                  height: double.infinity,
                  decoration: _animatedBackground(), // Use animated gradient
                  child: SafeArea(
                    child: Column(
                      children: [
                        const Spacer(flex: 2),
                        // Logo with pulsing animation and hero tag
                        FadeTransition(
                          opacity: _logoOpacity,
                          child: ScaleTransition(
                            scale: _logoScale,
                            child: ScaleTransition(
                              scale:
                                  _pulseAnimation, // Premium pulsing animation
                              child: Hero(
                                tag:
                                    'brand-logo', // Hero handoff for continuity
                                child: _glossyLogo(
                                  Container(
                                    width: 180,
                                    height: 180,
                                    decoration: BoxDecoration(
                                      color: Colors.white,
                                      borderRadius: BorderRadius.circular(
                                        UnsaidPalette.cardRadius,
                                      ),
                                      boxShadow: [
                                        // Soft glow pulse tied to loader rhythm
                                        BoxShadow(
                                          color: UnsaidPalette.blush
                                              .withOpacity(
                                                _glowAnimation.value,
                                              ),
                                          blurRadius: 30,
                                          spreadRadius: 1,
                                        ),
                                        ...UnsaidPalette.softShadow,
                                      ],
                                      border: Border.all(
                                        color: Colors.black.withValues(
                                          alpha: 0.04,
                                        ),
                                      ),
                                    ),
                                    child: Padding(
                                      padding: const EdgeInsets.all(20),
                                      child: ClipRRect(
                                        borderRadius: BorderRadius.circular(
                                          UnsaidPalette.cardRadius - 20,
                                        ),
                                        child: Image(
                                          image: _logoImage,
                                          width: 140,
                                          height: 140,
                                          fit: BoxFit.contain,
                                          errorBuilder: (_, __, ___) =>
                                              _buildFallbackLogo(),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 40),
                        // Title/Tagline
                        FadeTransition(
                          opacity: _textOpacity,
                          child: SlideTransition(
                            position: _textSlide,
                            child: Column(
                              children: const [
                                Text(
                                  'Unsaid',
                                  style: TextStyle(
                                    color: Colors
                                        .white, // Changed from UnsaidPalette.ink to white for gradient
                                    fontSize: 42,
                                    fontWeight: FontWeight.w800,
                                    letterSpacing: -0.25, // Crisp typography
                                  ),
                                ),
                                SizedBox(height: 12),
                                Padding(
                                  padding: EdgeInsets.symmetric(horizontal: 32),
                                  child: Text(
                                    'AI-Powered Communication\nMade Meaningful',
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      color: UnsaidPalette.softInk,
                                      fontSize: 16,
                                      fontWeight: FontWeight.w400,
                                      height: 1.35, // Improved line height
                                      letterSpacing:
                                          0.15, // Premium letter spacing
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        const Spacer(flex: 2),
                        // Soft loader + text
                        FadeTransition(
                          opacity: _textOpacity,
                          child: Column(
                            children: [
                              SizedBox(
                                width: 48,
                                height: 48,
                                child: DecoratedBox(
                                  decoration: BoxDecoration(
                                    color: Colors.white,
                                    shape: BoxShape.circle,
                                    boxShadow: UnsaidPalette.cardShadow,
                                  ),
                                  child: const Center(
                                    child: SizedBox(
                                      width: 24,
                                      height: 24,
                                      child: CircularProgressIndicator(
                                        valueColor:
                                            AlwaysStoppedAnimation<Color>(
                                              UnsaidPalette.blush,
                                            ),
                                        strokeWidth: 2.5,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(height: 20),
                              const Text(
                                'Loading Experience...',
                                style: TextStyle(
                                  color: UnsaidPalette.softInk,
                                  fontSize: 14,
                                  fontWeight: FontWeight.w400,
                                  letterSpacing: 0.3,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 60),
                      ],
                    ), // Close Column
                  ), // Close SafeArea
                ); // Close Container with semicolon for return
              },
            ),
          ),
        ),
      ),
    );
  }
}
