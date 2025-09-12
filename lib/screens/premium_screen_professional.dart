import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../theme/app_theme.dart';
import '../widgets/gradient_button.dart';
import '../widgets/data_privacy_disclaimer.dart';
import '../services/onboarding_service.dart';
import '../services/trial_service.dart';
import '../services/subscription_service.dart';

class PremiumScreenProfessional extends StatefulWidget {
  final VoidCallback? onContinue;
  final List<String>? personalityTestAnswers;

  const PremiumScreenProfessional({
    super.key,
    this.onContinue,
    this.personalityTestAnswers,
  });

  @override
  State<PremiumScreenProfessional> createState() =>
      _PremiumScreenProfessionalState();
}

class _PremiumScreenProfessionalState extends State<PremiumScreenProfessional>
    with TickerProviderStateMixin {
  late AnimationController _fadeController;
  late AnimationController _slideController;
  late AnimationController _scaleController;
  late AnimationController _sparkleController;
  late AnimationController _bgController; // Gradient parallax
  late Animation<double> _fadeAnimation;
  late Animation<Offset> _slideAnimation;
  late Animation<double> _scaleAnimation;
  late Animation<double> _sparkleAnimation;

  int _secretTapCount = 0;
  SubscriptionService? _subscriptionService;
  bool _isPurchasing = false; // Debounce protection

  @override
  void initState() {
    super.initState();
    _initializeAnimations();
    _startAnimations();
    _initializeSubscriptionService();
  }

  void _initializeSubscriptionService() async {
    _subscriptionService = SubscriptionService();
    await _subscriptionService!.initialize();
    if (mounted) {
      setState(() {}); // Refresh UI once subscription service is ready
    }
  }

  void _initializeAnimations() {
    _fadeController = AnimationController(
      duration: const Duration(milliseconds: 1200),
      vsync: this,
    );
    _slideController = AnimationController(
      duration: const Duration(milliseconds: 1000),
      vsync: this,
    );
    _scaleController = AnimationController(
      duration: const Duration(milliseconds: 800),
      vsync: this,
    );
    _sparkleController = AnimationController(
      duration: const Duration(seconds: 2),
      vsync: this,
    )..repeat();

    // Premium gradient parallax
    _bgController = AnimationController(
      duration: const Duration(seconds: 10),
      vsync: this,
    )..repeat(reverse: true);

    _fadeAnimation = Tween<double>(
      begin: 0.0,
      end: 1.0,
    ).animate(CurvedAnimation(parent: _fadeController, curve: Curves.easeOut));

    _slideAnimation =
        Tween<Offset>(begin: const Offset(0.0, 0.5), end: Offset.zero).animate(
          CurvedAnimation(parent: _slideController, curve: Curves.elasticOut),
        );

    _scaleAnimation = Tween<double>(begin: 0.8, end: 1.0).animate(
      CurvedAnimation(parent: _scaleController, curve: Curves.bounceOut),
    );

    _sparkleAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _sparkleController, curve: Curves.easeInOut),
    );
  }

  void _startAnimations() {
    Future.delayed(const Duration(milliseconds: 200), () {
      _scaleController.forward();
    });
    Future.delayed(const Duration(milliseconds: 400), () {
      _fadeController.forward();
    });
    Future.delayed(const Duration(milliseconds: 600), () {
      _slideController.forward();
    });
  }

  @override
  void dispose() {
    _fadeController.dispose();
    _slideController.dispose();
    _scaleController.dispose();
    _sparkleController.dispose();
    _bgController.dispose();
    super.dispose();
  }

  void _handleStartTrial() async {
    // Bulletproof debounce protection
    if (_isPurchasing) {
      if (kDebugMode) print('Purchase already in progress, ignoring tap');
      return;
    }

    setState(() => _isPurchasing = true);

    try {
      HapticFeedback.mediumImpact();

      // Check if subscription service is available
      if (_subscriptionService == null || !_subscriptionService!.isAvailable) {
        _showErrorDialog(
          'Store not available',
          'Unable to connect to the App Store. Please try again later.',
        );
        return;
      }

      // Check if subscription service is still loading
      if (_subscriptionService!.loading) {
        _showErrorDialog(
          'Loading...',
          'Please wait while we load subscription information.',
        );
        return;
      }

      // Check if there are any products available
      if (_subscriptionService!.products.isEmpty) {
        _showErrorDialog(
          'No subscription available',
          _subscriptionService!.queryProductError ??
              'No subscription products found. Please try again later.',
        );
        return;
      }

      // Show loading indicator
      _showLoadingDialog();

      // Attempt to purchase subscription with timeout
      final bool success = await _subscriptionService!
          .purchaseSubscription()
          .timeout(
            const Duration(seconds: 30),
            onTimeout: () {
              Navigator.of(context).pop(); // Hide loading dialog
              throw TimeoutException(
                'Purchase timed out',
                const Duration(seconds: 30),
              );
            },
          );

      // Hide loading dialog
      if (Navigator.canPop(context)) Navigator.of(context).pop();

      if (success) {
        // Success haptic feedback
        HapticFeedback.heavyImpact();

        // Start the trial locally (this might be redundant if the purchase handles it)
        await TrialService().startTrial();

        // Mark onboarding as complete
        await OnboardingService.instance.markOnboardingComplete();

        // Navigate based on context
        if (widget.onContinue != null) {
          widget.onContinue!();
        } else if (widget.personalityTestAnswers != null) {
          Navigator.pushReplacementNamed(context, '/emotional-state');
        } else {
          Navigator.pushReplacementNamed(context, '/emotional-state');
        }
      } else {
        // Purchase failed or was cancelled
        HapticFeedback.heavyImpact();
        _showErrorDialog(
          'Purchase Failed',
          'The subscription could not be started. Please try again.',
        );
      }
    } catch (e) {
      // Hide loading dialog if still showing
      if (Navigator.canPop(context)) Navigator.of(context).pop();

      HapticFeedback.heavyImpact();

      // Enhanced error handling for production
      String userMessage;
      if (e is TimeoutException) {
        userMessage = 'Purchase timed out. Please try again.';
      } else if (e.toString().toLowerCase().contains('cancelled')) {
        userMessage = 'Purchase was cancelled.';
      } else if (e.toString().toLowerCase().contains('network')) {
        userMessage =
            'Network error. Please check your connection and try again.';
      } else {
        userMessage =
            'An error occurred while starting your subscription. Please try again.';
      }

      _showErrorDialog('Error', userMessage);

      if (kDebugMode) {
        print('Purchase error: $e');
      }
    } finally {
      // Always reset purchasing state
      if (mounted) {
        setState(() => _isPurchasing = false);
      }
    }
  }

  void _showLoadingDialog() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => WillPopScope(
        onWillPop: () async => false,
        child: AlertDialog(
          backgroundColor: Colors.white,
          content: Row(
            children: [
              const CircularProgressIndicator(),
              const SizedBox(width: 20),
              Expanded(
                child: Text(
                  'Starting your subscription...',
                  style: Theme.of(
                    context,
                  ).textTheme.bodyMedium?.copyWith(color: Colors.black87),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showErrorDialog(String title, String message) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Colors.white,
        title: Text(title, style: TextStyle(color: Colors.black87)),
        content: Text(message, style: TextStyle(color: Colors.black87)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('OK', style: TextStyle(color: Colors.black87)),
          ),
        ],
      ),
    );
  }

  void _showDataPrivacyDisclaimer() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => DataPrivacyDisclaimer(onAccept: _handleStartTrial),
    );
  }

  void _handleSecretTap() {
    _secretTapCount++;

    if (_secretTapCount >= 7) {
      // Enable admin mode after 7 taps
      final trialService = Provider.of<TrialService>(context, listen: false);
      trialService.enableAdminMode();

      HapticFeedback.heavyImpact();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(' Admin mode activated'),
          backgroundColor: Colors.red,
          duration: Duration(seconds: 2),
        ),
      );

      _secretTapCount = 0;
    } else if (_secretTapCount >= 5) {
      // Give hint after 5 taps
      HapticFeedback.lightImpact();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Keep tapping... (${7 - _secretTapCount} more)'),
          duration: const Duration(seconds: 1),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final mediaQuery = MediaQuery.of(context);
    final isReducedMotion = mediaQuery.disableAnimations;

    return GestureDetector(
      onTap: _handleSecretTap,
      child: Scaffold(
        backgroundColor: theme.colorScheme.surface,
        body: Stack(
          children: [
            // Premium animated background (respects reduced motion)
            Positioned.fill(
              child: isReducedMotion
                  ? Container(
                      decoration: BoxDecoration(
                        gradient: RadialGradient(
                          center: Alignment.topLeft,
                          radius: 1.2,
                          colors: [
                            theme.colorScheme.primary.withOpacity(0.15),
                            theme.colorScheme.primary.withOpacity(0.05),
                            theme.colorScheme.surface,
                          ],
                        ),
                      ),
                    )
                  : AnimatedBuilder(
                      animation: _bgController,
                      builder: (context, child) {
                        return Container(
                          decoration: BoxDecoration(
                            gradient: RadialGradient(
                              center: Alignment(
                                -1.0 + (_bgController.value * 0.3),
                                -1.0 + (_bgController.value * 0.2),
                              ),
                              radius: 1.2 + _bgController.value * 0.3,
                              colors: [
                                theme.colorScheme.primary.withOpacity(0.15),
                                theme.colorScheme.primary.withOpacity(0.05),
                                theme.colorScheme.surface,
                              ],
                            ),
                          ),
                        );
                      },
                    ),
            ),

            // CustomPainter sparkles for battery efficiency
            Positioned.fill(
              child: CustomPaint(
                painter: _SparklePainter(
                  animation: _sparkleAnimation,
                  isReducedMotion: isReducedMotion,
                ),
              ),
            ),

            SafeArea(
              child: AnimatedBuilder(
                animation: Listenable.merge([
                  _fadeController,
                  _slideController,
                  _scaleController,
                  _sparkleController,
                ]),
                builder: (context, child) {
                  return CustomScrollView(
                    physics: const BouncingScrollPhysics(),
                    slivers: [
                      // Header with animated logo
                      SliverToBoxAdapter(
                        child: Container(
                          padding: EdgeInsets.all(AppTheme.spacing.xl),
                          child: Column(
                            children: [
                              // Premium badge with sparkle effect
                              Stack(
                                children: [
                                  ScaleTransition(
                                    scale: _scaleAnimation,
                                    child: GestureDetector(
                                      onTap: _handleSecretTap,
                                      child: Container(
                                        padding: EdgeInsets.all(
                                          AppTheme.spacing.lg,
                                        ),
                                        decoration: BoxDecoration(
                                          color: Colors.white.withValues(
                                            alpha: 0.15,
                                          ),
                                          shape: BoxShape.circle,
                                          boxShadow: [
                                            BoxShadow(
                                              color: Colors.white.withValues(
                                                alpha: 0.3,
                                              ),
                                              blurRadius: 20,
                                              spreadRadius: 5,
                                            ),
                                          ],
                                        ),
                                        child: Image.asset(
                                          'assets/unsaid_logo.png',
                                          width: 100,
                                          height: 100,
                                          semanticLabel: 'Unsaid app logo',
                                        ),
                                      ),
                                    ),
                                  ),
                                  // Sparkle effects
                                  ...List.generate(6, (index) {
                                    final angle =
                                        (index * 60.0) * (3.14159 / 180);
                                    const radius = 80.0;
                                    return Positioned(
                                      left:
                                          75 +
                                          radius *
                                              math.cos(
                                                angle +
                                                    _sparkleAnimation.value *
                                                        2 *
                                                        3.14159,
                                              ),
                                      top:
                                          75 +
                                          radius *
                                              math.sin(
                                                angle +
                                                    _sparkleAnimation.value *
                                                        2 *
                                                        3.14159,
                                              ),
                                      child: FadeTransition(
                                        opacity: _sparkleAnimation,
                                        child: Image.asset(
                                          'assets/unsaid_logo.png',
                                          width: 16,
                                          height: 16,
                                          color: Colors.white.withValues(
                                            alpha: 0.7,
                                          ),
                                          semanticLabel: 'Sparkle',
                                        ),
                                      ),
                                    );
                                  }),
                                ],
                              ),

                              SizedBox(height: AppTheme.spacing.lg),

                              // App title
                              FadeTransition(
                                opacity: _fadeAnimation,
                                child: Text(
                                  'Welcome to Unsaid',
                                  style: theme.textTheme.displayMedium
                                      ?.copyWith(
                                        color: Colors.black87,
                                        fontWeight: FontWeight.bold,
                                        shadows: [
                                          Shadow(
                                            offset: const Offset(0, 2),
                                            blurRadius: 4,
                                            color: Colors.black.withValues(
                                              alpha: 0.3,
                                            ),
                                          ),
                                        ],
                                      ),
                                  textAlign: TextAlign.center,
                                ),
                              ),

                              SizedBox(height: AppTheme.spacing.sm),

                              // Subtitle
                              FadeTransition(
                                opacity: _fadeAnimation,
                                child: Text(
                                  'Your AI-powered relationship communication assistant',
                                  style: theme.textTheme.titleLarge?.copyWith(
                                    color: Colors.black54,
                                    fontWeight: FontWeight.w400,
                                  ),
                                  textAlign: TextAlign.center,
                                ),
                              ),
                              SizedBox(height: AppTheme.spacing.xs),
                              // Research-backed badge
                              FadeTransition(
                                opacity: _fadeAnimation,
                                child: Container(
                                  margin: EdgeInsets.only(
                                    top: AppTheme.spacing.sm,
                                  ),
                                  padding: EdgeInsets.symmetric(
                                    horizontal: AppTheme.spacing.md,
                                    vertical: AppTheme.spacing.xs,
                                  ),
                                  decoration: BoxDecoration(
                                    color: Colors.white.withValues(alpha: 0.15),
                                    borderRadius: BorderRadius.circular(16),
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(
                                        Icons.verified,
                                        color: theme.colorScheme.primary,
                                        size: 18,
                                        semanticLabel: 'Research-backed',
                                      ),
                                      const SizedBox(width: 6),
                                      Text(
                                        'Research-backed insights',
                                        style: theme.textTheme.bodyMedium
                                            ?.copyWith(
                                              color: Colors.black87,
                                              fontWeight: FontWeight.w600,
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

                      // Features list
                      SliverPadding(
                        padding: EdgeInsets.symmetric(
                          horizontal: AppTheme.spacing.lg,
                        ),
                        sliver: SliverList(
                          delegate: SliverChildListDelegate([
                            SlideTransition(
                              position: _slideAnimation,
                              child: FadeTransition(
                                opacity: _fadeAnimation,
                                child: Container(
                                  padding: EdgeInsets.all(AppTheme.spacing.lg),
                                  decoration: BoxDecoration(
                                    gradient: const LinearGradient(
                                      colors: [
                                        Color(0xFF6C47FF),
                                        Color(0xFF4A2FE7),
                                      ],
                                      begin: Alignment.topLeft,
                                      end: Alignment.bottomRight,
                                    ),
                                    borderRadius: BorderRadius.circular(
                                      AppTheme.radiusLG,
                                    ),
                                    boxShadow: [
                                      BoxShadow(
                                        color: Colors.black.withValues(
                                          alpha: 0.2,
                                        ),
                                        blurRadius: 20,
                                        offset: const Offset(0, 10),
                                      ),
                                    ],
                                  ),
                                  child: Column(
                                    children: [
                                      Text(
                                        'App Features',
                                        style: theme.textTheme.headlineSmall
                                            ?.copyWith(
                                              color:
                                                  theme.colorScheme.onSurface,
                                              fontWeight: FontWeight.bold,
                                            ),
                                      ),
                                      SizedBox(height: AppTheme.spacing.lg),
                                      ..._buildFeaturesList(),
                                    ],
                                  ),
                                ),
                              ),
                            ),

                            SizedBox(height: AppTheme.spacing.xl),

                            // Pricing section
                            SlideTransition(
                              position: _slideAnimation,
                              child: FadeTransition(
                                opacity: _fadeAnimation,
                                child: _buildPricingSection(),
                              ),
                            ),

                            SizedBox(height: AppTheme.spacing.xl),

                            // Action buttons
                            SlideTransition(
                              position: _slideAnimation,
                              child: FadeTransition(
                                opacity: _fadeAnimation,
                                child: Column(
                                  children: [
                                    // Start trial button
                                    GradientButton(
                                      onPressed: _showDataPrivacyDisclaimer,
                                      gradient: LinearGradient(
                                        colors: [
                                          Colors.white,
                                          Colors.white.withValues(alpha: 0.95),
                                        ],
                                      ),
                                      borderRadius: BorderRadius.circular(
                                        AppTheme.radius.lg,
                                      ),
                                      padding: EdgeInsets.symmetric(
                                        horizontal: AppTheme.spacing.xl,
                                        vertical: AppTheme.spacing.md,
                                      ),
                                      elevation: 12,
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Icon(
                                            Icons.play_arrow,
                                            color: theme.colorScheme.primary,
                                            size: 24,
                                            semanticLabel: 'Start Free Trial',
                                          ),
                                          SizedBox(width: AppTheme.spacing.sm),
                                          Text(
                                            'Start 7-Day Free Trial',
                                            style: theme.textTheme.titleLarge
                                                ?.copyWith(
                                                  color:
                                                      theme.colorScheme.primary,
                                                  fontWeight: FontWeight.bold,
                                                ),
                                          ),
                                        ],
                                      ),
                                    ),

                                    SizedBox(height: AppTheme.spacing.md),

                                    // Auto-billing disclaimer
                                    Container(
                                      padding: EdgeInsets.all(
                                        AppTheme.spacing.md,
                                      ),
                                      decoration: BoxDecoration(
                                        color: Colors.white.withValues(
                                          alpha: 0.1,
                                        ),
                                        borderRadius: BorderRadius.circular(
                                          AppTheme.radius.md,
                                        ),
                                        border: Border.all(
                                          color: Colors.white.withValues(
                                            alpha: 0.2,
                                          ),
                                          width: 1,
                                        ),
                                      ),
                                      child: Column(
                                        children: [
                                          Row(
                                            mainAxisAlignment:
                                                MainAxisAlignment.center,
                                            children: [
                                              Icon(
                                                Icons.info_outline,
                                                color: Colors.black54,
                                                size: 18,
                                              ),
                                              SizedBox(
                                                width: AppTheme.spacing.xs,
                                              ),
                                              Text(
                                                'Auto-billing after trial',
                                                style: theme
                                                    .textTheme
                                                    .bodyMedium
                                                    ?.copyWith(
                                                      color: Colors.black87,
                                                      fontWeight:
                                                          FontWeight.w600,
                                                    ),
                                              ),
                                            ],
                                          ),
                                          SizedBox(height: AppTheme.spacing.xs),
                                          Text(
                                            'Your subscription will automatically renew at ${_subscriptionService?.subscriptionPrice ?? '\$2.99'}/month after the 7-day trial unless cancelled in your iPhone Settings.',
                                            style: theme.textTheme.bodySmall
                                                ?.copyWith(
                                                  color: Colors.black54,
                                                ),
                                            textAlign: TextAlign.center,
                                          ),
                                        ],
                                      ),
                                    ),

                                    SizedBox(height: AppTheme.spacing.sm),

                                    // Privacy notice
                                    TextButton(
                                      onPressed: _showDataPrivacyDisclaimer,
                                      style: TextButton.styleFrom(
                                        padding: EdgeInsets.symmetric(
                                          horizontal: AppTheme.spacing.lg,
                                          vertical: AppTheme.spacing.sm,
                                        ),
                                      ),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Icon(
                                            Icons.privacy_tip_outlined,
                                            color: Colors.black54,
                                            size: 18,
                                          ),
                                          SizedBox(width: AppTheme.spacing.xs),
                                          Text(
                                            'Privacy & Data Usage',
                                            style: theme.textTheme.titleMedium
                                                ?.copyWith(
                                                  color: Colors.black54,
                                                  decoration:
                                                      TextDecoration.underline,
                                                  decorationColor:
                                                      Colors.black54,
                                                ),
                                          ),
                                        ],
                                      ),
                                    ),

                                    SizedBox(height: AppTheme.spacing.md),

                                    // No Thanks button
                                    TextButton(
                                      onPressed: () async {
                                        await OnboardingService.instance
                                            .markOnboardingComplete();
                                        Navigator.of(
                                          context,
                                        ).pushNamedAndRemoveUntil(
                                          '/main',
                                          (route) => false,
                                        );
                                      },
                                      style: TextButton.styleFrom(
                                        padding: EdgeInsets.symmetric(
                                          horizontal: AppTheme.spacing.lg,
                                          vertical: AppTheme.spacing.sm,
                                        ),
                                      ),
                                      child: Text(
                                        'No Thanks',
                                        style: theme.textTheme.titleMedium
                                            ?.copyWith(
                                              color: Colors.black54,
                                              decoration:
                                                  TextDecoration.underline,
                                              decorationColor: Colors.black54,
                                            ),
                                      ),
                                    ),

                                    SizedBox(height: AppTheme.spacing.md),

                                    // Restore purchases button
                                    if (_subscriptionService != null &&
                                        _subscriptionService!.isAvailable)
                                      TextButton(
                                        onPressed: () async {
                                          HapticFeedback.lightImpact();
                                          try {
                                            await _subscriptionService!
                                                .restorePurchases();
                                            if (_subscriptionService!
                                                .hasActiveSubscription) {
                                              // User has active subscription, complete onboarding
                                              await OnboardingService.instance
                                                  .markOnboardingComplete();
                                              Navigator.of(
                                                context,
                                              ).pushNamedAndRemoveUntil(
                                                '/main',
                                                (route) => false,
                                              );
                                            } else {
                                              ScaffoldMessenger.of(
                                                context,
                                              ).showSnackBar(
                                                const SnackBar(
                                                  content: Text(
                                                    'No active subscriptions found.',
                                                  ),
                                                  backgroundColor:
                                                      Colors.orange,
                                                ),
                                              );
                                            }
                                          } catch (e) {
                                            ScaffoldMessenger.of(
                                              context,
                                            ).showSnackBar(
                                              SnackBar(
                                                content: Text(
                                                  'Error restoring purchases: $e',
                                                ),
                                                backgroundColor: Colors.red,
                                              ),
                                            );
                                          }
                                        },
                                        style: TextButton.styleFrom(
                                          padding: EdgeInsets.symmetric(
                                            horizontal: AppTheme.spacing.lg,
                                            vertical: AppTheme.spacing.sm,
                                          ),
                                        ),
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Icon(
                                              Icons.restore,
                                              color: theme.colorScheme.onSurface
                                                  .withOpacity(0.7),
                                              size: 18,
                                            ),
                                            SizedBox(
                                              width: AppTheme.spacing.xs,
                                            ),
                                            Text(
                                              'Restore Purchases',
                                              style: theme.textTheme.titleMedium
                                                  ?.copyWith(
                                                    color: theme
                                                        .colorScheme
                                                        .onSurface
                                                        .withOpacity(0.8),
                                                    decoration: TextDecoration
                                                        .underline,
                                                    decorationColor: theme
                                                        .colorScheme
                                                        .onSurface
                                                        .withOpacity(0.8),
                                                  ),
                                            ),
                                          ],
                                        ),
                                      ),

                                    SizedBox(height: AppTheme.spacing.md),

                                    // Continue button
                                    TextButton(
                                      onPressed: () async {
                                        await OnboardingService.instance
                                            .markOnboardingComplete();
                                        Navigator.of(
                                          context,
                                        ).pushNamedAndRemoveUntil(
                                          '/main',
                                          (route) => false,
                                        );
                                      },
                                      style: TextButton.styleFrom(
                                        padding: EdgeInsets.symmetric(
                                          horizontal: AppTheme.spacing.lg,
                                          vertical: AppTheme.spacing.sm,
                                        ),
                                      ),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Icon(
                                            Icons.arrow_forward,
                                            color: theme.colorScheme.onSurface
                                                .withOpacity(0.8),
                                            size: 22,
                                          ),
                                          SizedBox(width: AppTheme.spacing.xs),
                                          Text(
                                            'Continue to Home',
                                            style: theme.textTheme.titleMedium
                                                ?.copyWith(
                                                  color: theme
                                                      .colorScheme
                                                      .onSurface
                                                      .withOpacity(0.8),
                                                  decoration:
                                                      TextDecoration.underline,
                                                  decorationColor: theme
                                                      .colorScheme
                                                      .onSurface
                                                      .withOpacity(0.8),
                                                ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),

                            // Add bottom safe area padding to prevent overflow
                            SizedBox(height: AppTheme.spacing.xl),
                            SizedBox(
                              height:
                                  MediaQuery.of(context).padding.bottom + 20,
                            ),
                          ]),
                        ),
                      ),
                    ],
                  );
                }, // builder function closing
              ), // AnimatedBuilder closing
            ), // SafeArea closing
            // Back button overlay (always on top)
            Positioned(
              top: MediaQuery.of(context).padding.top + 8,
              left: 8,
              child: IconButton(
                icon: const Icon(
                  Icons.arrow_back,
                  color: Colors.white,
                  size: 28,
                ),
                tooltip: 'Back',
                onPressed: () {
                  Navigator.of(context).pop();
                },
              ),
            ),
          ], // Stack children closing
        ),
      ),
    );
  }

  List<Widget> _buildFeaturesList() {
    final features = [
      {
        'icon': Icons.keyboard_outlined,
        'title': 'Smart Keyboard Extension',
        'description': 'Real-time tone analysis and suggestions as you type',
        'semantic': 'Smart Keyboard Extension',
      },
      {
        'icon': Icons.security_outlined,
        'title': '10 Daily Secure Quick Fixes',
        'description':
            'Get 10 secure communication fixes per day during your trial',
        'semantic': 'Daily Secure Quick Fixes',
      },
      {
        'icon': Icons.psychology_outlined,
        'title': 'Unlimited Therapy Advice',
        'description':
            'Access all therapeutic insights and relationship guidance',
        'semantic': 'Unlimited Therapy Advice',
      },
      {
        'icon': Icons.favorite_outline,
        'title': 'Tone Analysis',
        'description': 'Real-time tone detection and communication insights',
        'semantic': 'Tone Analysis',
      },
      {
        'icon': Icons.trending_up_outlined,
        'title': 'Communication Progress',
        'description': 'Track and improve your communication over time',
        'semantic': 'Communication Progress',
      },
      {
        'icon': Icons.lightbulb_outline,
        'title': 'Premium Features After Trial',
        'description':
            'Unlimited secure fixes, advanced insights, and premium analytics',
        'semantic': 'Premium Features',
      },
    ];

    return features.asMap().entries.map<Widget>((entry) {
      final index = entry.key;
      final feature = entry.value;
      return TweenAnimationBuilder<double>(
        duration: Duration(milliseconds: 600 + (index * 100)),
        tween: Tween(begin: 0.0, end: 1.0),
        curve: Curves.easeOut,
        builder: (context, value, child) {
          return Transform.translate(
            offset: Offset(0, (1 - value) * 20),
            child: Opacity(
              opacity: value,
              child: Container(
                margin: EdgeInsets.only(bottom: AppTheme.spacing.md),
                padding: EdgeInsets.all(AppTheme.spacing.md),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(AppTheme.radius.md),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.2),
                    width: 1,
                  ),
                ),
                child: Row(
                  children: [
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            feature['title'] as String,
                            style: Theme.of(context).textTheme.titleMedium
                                ?.copyWith(
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold,
                                ),
                          ),
                          SizedBox(height: AppTheme.spacing.xs),
                          Text(
                            feature['description'] as String,
                            style: Theme.of(context).textTheme.bodyMedium
                                ?.copyWith(
                                  color: Colors.white.withValues(alpha: 0.8),
                                  height: 1.3,
                                ),
                          ),
                        ],
                      ),
                    ),
                    const Icon(
                      Icons.check_circle,
                      color: Colors.white,
                      size: 20,
                      semanticLabel: 'Included',
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      );
    }).toList();
  }

  Widget _buildPricingSection() {
    final theme = Theme.of(context);

    return Container(
      padding: EdgeInsets.all(AppTheme.spacing.lg),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF6C47FF), Color(0xFF4A2FE7)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(AppTheme.radiusLG),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.2),
            blurRadius: 20,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Column(
        children: [
          Text(
            'Subscription Details',
            style: theme.textTheme.headlineSmall?.copyWith(
              color: Colors.white,
              fontWeight: FontWeight.bold,
            ),
          ),
          SizedBox(height: AppTheme.spacing.lg),

          // Free trial highlight
          Container(
            padding: EdgeInsets.all(AppTheme.spacing.md),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(AppTheme.radius.lg),
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.3),
                width: 2,
              ),
            ),
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(
                      Icons.timer,
                      color: Colors.white,
                      size: 24,
                      semanticLabel: 'Free Trial',
                    ),
                    SizedBox(width: AppTheme.spacing.sm),
                    Text(
                      '7-Day Free Trial',
                      style: theme.textTheme.titleLarge?.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
                SizedBox(height: AppTheme.spacing.sm),
                Text(
                  'Then ${_subscriptionService?.subscriptionPrice ?? '\$2.99'}/month (auto-renewing)',
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: Colors.white.withValues(alpha: 0.9),
                    fontWeight: FontWeight.w600,
                  ),
                ),
                SizedBox(height: AppTheme.spacing.xs),
                Text(
                  'Cancel anytime in iPhone Settings → Subscriptions',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: Colors.white.withValues(alpha: 0.8),
                  ),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// CustomPainter for battery-efficient sparkles
class _SparklePainter extends CustomPainter {
  final Animation<double> animation;
  final bool isReducedMotion;

  _SparklePainter({required this.animation, required this.isReducedMotion})
    : super(repaint: animation);

  @override
  void paint(Canvas canvas, Size size) {
    if (isReducedMotion) return; // Respect reduced motion setting

    final paint = Paint()
      ..color = Colors.white.withOpacity(0.6)
      ..strokeWidth = 1.0;

    final sparkleCount = 8;
    final animValue = animation.value;

    for (int i = 0; i < sparkleCount; i++) {
      final progress = (animValue + (i / sparkleCount)) % 1.0;
      final opacity = (1.0 - progress).clamp(0.0, 1.0);

      // Calculate sparkle position based on golden ratio distribution
      final angle = i * 2.356; // Golden angle in radians
      final radius = progress * size.width * 0.6;
      final x = size.width * 0.5 + radius * math.cos(angle);
      final y = size.height * 0.3 + radius * math.sin(angle);

      if (x >= 0 && x <= size.width && y >= 0 && y <= size.height) {
        paint.color = Colors.white.withOpacity(opacity * 0.4);
        canvas.drawCircle(Offset(x, y), 1.5, paint);

        // Add sparkle cross effect
        canvas.drawLine(
          Offset(x - 3, y),
          Offset(x + 3, y),
          paint..strokeWidth = 0.5,
        );
        canvas.drawLine(Offset(x, y - 3), Offset(x, y + 3), paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}
