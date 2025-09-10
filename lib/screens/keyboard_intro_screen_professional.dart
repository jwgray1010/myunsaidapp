import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/keyboard_extension.dart';
import '../ui/unsaid_theme.dart';
import '../ui/unsaid_widgets.dart';
import '../utils/asset_verifier.dart';

class KeyboardIntroScreenProfessional extends StatefulWidget {
  const KeyboardIntroScreenProfessional({super.key, required this.onSkip});

  final VoidCallback onSkip;

  @override
  State<KeyboardIntroScreenProfessional> createState() =>
      _KeyboardIntroScreenProfessionalState();
}

class _KeyboardIntroScreenProfessionalState
    extends State<KeyboardIntroScreenProfessional>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  late AnimationController _slideController;
  late AnimationController _fadeController;
  late AnimationController _scaleController;
  late Animation<Offset> _slideAnimation;
  late Animation<double> _fadeAnimation;
  late Animation<double> _scaleAnimation;

  bool _keyboardEnabled = false;
  bool _isCheckingStatus = false;

  // Production helpers
  void _toast(String message, {Color? backgroundColor}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        backgroundColor: backgroundColor,
        content: Text(message),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }

  // Auto-detect enablement after returning from Settings
  Future<void> _awaitReturnCheck() async {
    if (_isCheckingStatus) return;
    _isCheckingStatus = true;

    for (int i = 0; i < 12; i++) {
      // ~6s @ 500ms
      await Future.delayed(const Duration(milliseconds: 500));
      if (!mounted) return;

      try {
        final isOn = await UnsaidKeyboardExtension.isKeyboardEnabled();
        if (isOn != _keyboardEnabled) {
          setState(() => _keyboardEnabled = isOn);

          // Announce state change for screen readers
          if (isOn) {
            try {
              HapticFeedback.selectionClick();
            } catch (e) {
              if (kDebugMode) print('Haptic feedback failed: $e');
            }
            SemanticsService.announce(
              'Unsaid Keyboard enabled',
              TextDirection.ltr,
            );
          }
          break;
        }
      } catch (e) {
        if (kDebugMode) print('Error checking keyboard status: $e');
      }
    }

    _isCheckingStatus = false;
  }

  // Platform-aware steps
  List<String> get _platformSteps {
    try {
      if (!kIsWeb && Platform.isIOS) {
        return [
          '1. Tap "Enable Unsaid Keyboard" above',
          '2. Go to: Settings → General → Keyboard',
          '3. Select "Keyboards" → "Add New Keyboard"',
          '4. Choose "Unsaid" from the list',
        ];
      }
    } catch (e) {
      if (kDebugMode) print('Platform detection failed: $e');
    }

    // Android/fallback
    return [
      '1. Tap "Enable Unsaid Keyboard" above',
      '2. Go to: Settings → System → Languages & input',
      '3. Select "On-screen keyboard" → "Manage keyboards"',
      '4. Toggle "Unsaid" to ON',
    ];
  }

  // Production status chip widget
  Widget _statusChip(bool enabled) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: enabled
            ? Colors.green.withOpacity(.12)
            : Colors.grey.withOpacity(.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            enabled ? Icons.verified : Icons.hourglass_empty,
            size: 16,
            color: enabled ? Colors.green : Colors.grey,
          ),
          const SizedBox(width: 6),
          Text(
            enabled ? 'Enabled' : 'Not enabled yet',
            style: TextStyle(
              fontWeight: FontWeight.w600,
              color: enabled ? Colors.green.shade700 : Colors.grey.shade700,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }

  @override
  void initState() {
    super.initState();

    // Set consistent status bar style
    SystemChrome.setSystemUIOverlayStyle(
      const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
        statusBarBrightness: Brightness.dark,
      ),
    );

    _slideController = AnimationController(
      duration: const Duration(milliseconds: 800),
      vsync: this,
    );
    _fadeController = AnimationController(
      duration: const Duration(milliseconds: 600),
      vsync: this,
    );
    _scaleController = AnimationController(
      duration: const Duration(milliseconds: 1000),
      vsync: this,
    );

    _slideAnimation =
        Tween<Offset>(begin: const Offset(0, 0.5), end: Offset.zero).animate(
          CurvedAnimation(parent: _slideController, curve: Curves.easeOutCubic),
        );

    _fadeAnimation = Tween<double>(
      begin: 0.0,
      end: 1.0,
    ).animate(CurvedAnimation(parent: _fadeController, curve: Curves.easeOut));

    _scaleAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _scaleController, curve: Curves.elasticOut),
    );

    _startAnimations();
    _checkKeyboardStatus();
    WidgetsBinding.instance.addObserver(this);

    // Verify assets for debugging
    WidgetsBinding.instance.addPostFrameCallback((_) {
      AssetVerifier.verifyCoreAssets();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.resumed) {
      // Check keyboard status when app resumes from settings
      _checkKeyboardStatus();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Respect reduced motion accessibility preference
    final reduceMotion = MediaQuery.accessibleNavigationOf(context);
    if (reduceMotion) {
      _fadeController.value = 1;
      _slideController.value = 1;
      _scaleController.value = 1;
    }
  }

  void _startAnimations() async {
    await Future.delayed(const Duration(milliseconds: 200));
    _fadeController.forward();
    await Future.delayed(const Duration(milliseconds: 300));
    _slideController.forward();
    await Future.delayed(const Duration(milliseconds: 500));
    _scaleController.forward();
  }

  void _checkKeyboardStatus() async {
    try {
      final isEnabled = await UnsaidKeyboardExtension.isKeyboardEnabled();
      if (mounted && isEnabled != _keyboardEnabled) {
        setState(() {
          _keyboardEnabled = isEnabled;
        });
      }
    } catch (e) {
      if (kDebugMode) print('Error checking keyboard status: $e');
    }
  }

  void _continueToEmotionalState() {
    Navigator.pushReplacementNamed(context, '/emotional-state');
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _slideController.dispose();
    _fadeController.dispose();
    _scaleController.dispose();
    super.dispose();
  }

  void _openKeyboardSettings(BuildContext context) async {
    // Gentle haptic feedback
    try {
      HapticFeedback.lightImpact();
    } catch (e) {
      if (kDebugMode) print('Haptic feedback failed: $e');
    }

    // Try to use the keyboard manager first (for platform-specific deep linking)
    try {
      await UnsaidKeyboardExtension.openKeyboardSettings();

      // Auto-detect enablement after returning from Settings
      _awaitReturnCheck();

      // Show helpful guidance with platform-aware copy
      if (mounted) {
        final isIOS = !kIsWeb && Platform.isIOS;
        final settingsPath = isIOS
            ? 'General → Keyboard → Keyboards → Add New Keyboard'
            : 'System → Languages & input → On-screen keyboard';

        _toast(
          'Opening Settings... Look for "$settingsPath"',
          backgroundColor: UnsaidPalette.blush,
        );
      }
    } catch (e) {
      // Fallback to general settings
      const url = 'app-settings:';
      final uri = Uri.parse(url);
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri);
        _awaitReturnCheck();

        if (mounted) {
          _toast(
            'Navigate to keyboard settings using the steps below',
            backgroundColor: Colors.orange,
          );
        }
      } else {
        // Ultimate fallback - copy steps to clipboard
        if (mounted) {
          final steps = _platformSteps.join('\n');
          Clipboard.setData(ClipboardData(text: steps));
          _toast(
            'Could not open settings. Steps copied to clipboard.',
            backgroundColor: Colors.red,
          );
        }
      }
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
        shortcuts: {
          LogicalKeySet(LogicalKeyboardKey.enter): ActivateIntent(),
          LogicalKeySet(LogicalKeyboardKey.numpadEnter): ActivateIntent(),
        },
        child: Actions(
          actions: {
            ActivateIntent: CallbackAction<ActivateIntent>(
              onInvoke: (_) {
                _keyboardEnabled
                    ? _continueToEmotionalState()
                    : _openKeyboardSettings(context);
                return null;
              },
            ),
          },
          child: UnsaidGradientScaffold(
            body: SafeArea(
              child: Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(24),
                  child: FadeTransition(
                    opacity: _fadeAnimation,
                    child: SlideTransition(
                      position: _slideAnimation,
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          // Logo with proper error handling
                          Container(
                            padding: const EdgeInsets.all(20),
                            decoration: BoxDecoration(
                              color: Colors.white,
                              shape: BoxShape.circle,
                              boxShadow: UnsaidPalette.softShadow,
                            ),
                            child: Image.asset(
                              'assets/unsaid_logo.png',
                              width: 60,
                              height: 60,
                              errorBuilder: (context, error, stackTrace) {
                                print('❌ Failed to load logo: $error');
                                return Container(
                                  width: 60,
                                  height: 60,
                                  decoration: BoxDecoration(
                                    gradient: const LinearGradient(
                                      colors: [
                                        UnsaidPalette.blush,
                                        UnsaidPalette.lavender,
                                      ],
                                      begin: Alignment.topLeft,
                                      end: Alignment.bottomRight,
                                    ),
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: const Center(
                                    child: Text(
                                      'U',
                                      style: TextStyle(
                                        color: Colors.white,
                                        fontSize: 32,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ),
                                );
                              },
                            ),
                          ),

                          const SizedBox(height: 32),

                          // Main Title with gradient and semantic header
                          Semantics(
                            header: true,
                            child: ShaderMask(
                              shaderCallback: (bounds) => const LinearGradient(
                                colors: [
                                  UnsaidPalette.blush,
                                  UnsaidPalette.lavender,
                                ],
                              ).createShader(bounds),
                              child: Text(
                                'Unlock the Unsaid Keyboard',
                                style: theme.textTheme.headlineMedium?.copyWith(
                                  fontWeight: FontWeight.bold,
                                  color: Colors.white,
                                ),
                                textAlign: TextAlign.center,
                              ),
                            ),
                          ),

                          const SizedBox(height: 12),

                          // Status chip
                          _statusChip(_keyboardEnabled),

                          const SizedBox(height: 16),

                          // Why enable blurb (conversion-focused)
                          Text(
                            _keyboardEnabled
                                ? 'Your smart keyboard is ready to help you communicate better!'
                                : 'Enable it to get live insights as you type anywhere.',
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: UnsaidPalette.softInk,
                              fontWeight: FontWeight.w500,
                            ),
                            textAlign: TextAlign.center,
                          ),

                          const SizedBox(height: 16),

                          // Subtitle
                          Text(
                            'Our smart keyboard gives you live insights as you type — helping you connect better and avoid misfires.',
                            style: theme.textTheme.bodyLarge?.copyWith(
                              color: UnsaidPalette.softInk,
                              height: 1.5,
                            ),
                            textAlign: TextAlign.center,
                          ),

                          const SizedBox(height: 40),

                          // Features Card with semantic container
                          ScaleTransition(
                            scale: _scaleAnimation,
                            child: Semantics(
                              container: true,
                              label: 'Features list',
                              child: UnsaidCard(
                                padding: const EdgeInsets.all(24),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      'Smart Features',
                                      style: theme.textTheme.titleLarge
                                          ?.copyWith(
                                            fontWeight: FontWeight.bold,
                                            color: UnsaidPalette.ink,
                                          ),
                                    ),
                                    const SizedBox(height: 20),
                                    ...[
                                      {
                                        'icon': Icons.psychology_outlined,
                                        'title':
                                            'See emotional cues as you type',
                                        'color': UnsaidPalette.blush,
                                      },
                                      {
                                        'icon': Icons.tune_outlined,
                                        'title':
                                            'Match tone to each relationship',
                                        'color': UnsaidPalette.lavender,
                                      },
                                      {
                                        'icon': Icons.lightbulb_outline,
                                        'title':
                                            'Suggestions tuned to your personality',
                                        'color': UnsaidPalette.accent,
                                      },
                                      {
                                        'icon': Icons.apps_outlined,
                                        'title': 'Works in all your apps',
                                        'color': UnsaidPalette.ink,
                                      },
                                    ].map(
                                      (feature) => Padding(
                                        padding: const EdgeInsets.only(
                                          bottom: 16,
                                        ),
                                        child: Row(
                                          children: [
                                            Container(
                                              padding: const EdgeInsets.all(8),
                                              decoration: BoxDecoration(
                                                color:
                                                    (feature['color'] as Color)
                                                        .withValues(alpha: 0.1),
                                                borderRadius:
                                                    BorderRadius.circular(8),
                                              ),
                                              child: Icon(
                                                feature['icon'] as IconData,
                                                color:
                                                    feature['color'] as Color,
                                                size: 20,
                                              ),
                                            ),
                                            const SizedBox(width: 16),
                                            Expanded(
                                              child: Text(
                                                feature['title'] as String,
                                                style: theme.textTheme.bodyLarge
                                                    ?.copyWith(
                                                      fontWeight:
                                                          FontWeight.w500,
                                                    ),
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

                          const SizedBox(height: 32),

                          // Action Buttons with semantic container
                          Semantics(
                            container: true,
                            label: 'Setup actions',
                            child: Column(
                              children: [
                                // Enable Button with enhanced tooltip
                                Tooltip(
                                  message:
                                      "This will open Settings → General → Accessibility → Full Keyboard Access. Enable 'Unsaid' there to unlock all keyboard features!",
                                  showDuration: const Duration(seconds: 4),
                                  textStyle: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 14,
                                  ),
                                  decoration: BoxDecoration(
                                    color: theme.colorScheme.primary.withValues(
                                      alpha: 0.9,
                                    ),
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: SizedBox(
                                    width: double.infinity,
                                    child: ElevatedButton.icon(
                                      onPressed: () =>
                                          _openKeyboardSettings(context),
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: UnsaidPalette.blush,
                                        foregroundColor: Colors.white,
                                        padding: const EdgeInsets.symmetric(
                                          vertical: 16,
                                          horizontal: 24,
                                        ),
                                        shape: RoundedRectangleBorder(
                                          borderRadius: BorderRadius.circular(
                                            16,
                                          ),
                                        ),
                                        elevation: 2,
                                      ),
                                      icon: const Icon(
                                        Icons.keyboard_outlined,
                                        size: 20,
                                      ),
                                      label: Text(
                                        'Enable Unsaid Keyboard',
                                        style: theme.textTheme.titleMedium
                                            ?.copyWith(
                                              fontWeight: FontWeight.w600,
                                              color: Colors.white,
                                            ),
                                      ),
                                    ),
                                  ),
                                ),

                                const SizedBox(height: 16),

                                // Continue Button (shown when keyboard is enabled)
                                if (_keyboardEnabled)
                                  Column(
                                    children: [
                                      SizedBox(
                                        width: double.infinity,
                                        child: ElevatedButton.icon(
                                          onPressed: _continueToEmotionalState,
                                          style: ElevatedButton.styleFrom(
                                            backgroundColor: Colors.green,
                                            foregroundColor: Colors.white,
                                            padding: const EdgeInsets.symmetric(
                                              vertical: 16,
                                              horizontal: 24,
                                            ),
                                            shape: RoundedRectangleBorder(
                                              borderRadius:
                                                  BorderRadius.circular(16),
                                            ),
                                            elevation: 2,
                                          ),
                                          icon: const Icon(
                                            Icons.check_circle_outline,
                                            size: 20,
                                          ),
                                          label: Text(
                                            'Continue',
                                            style: theme.textTheme.titleMedium
                                                ?.copyWith(
                                                  fontWeight: FontWeight.w600,
                                                  color: Colors.white,
                                                ),
                                          ),
                                        ),
                                      ),
                                      const SizedBox(height: 16),
                                    ],
                                  ),

                                // Step-by-step guide card (only shown when keyboard is not enabled)
                                if (!_keyboardEnabled)
                                  Semantics(
                                    container: true,
                                    label: 'Setup steps',
                                    child: UnsaidCard(
                                      padding: const EdgeInsets.all(16),
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Row(
                                            children: [
                                              const Icon(
                                                Icons.info_outline,
                                                size: 20,
                                                color: UnsaidPalette.blush,
                                              ),
                                              const SizedBox(width: 8),
                                              Text(
                                                'Setup Steps',
                                                style: theme
                                                    .textTheme
                                                    .titleSmall
                                                    ?.copyWith(
                                                      fontWeight:
                                                          FontWeight.w600,
                                                      color: UnsaidPalette.ink,
                                                    ),
                                              ),
                                            ],
                                          ),
                                          const SizedBox(height: 12),
                                          ..._platformSteps.map(
                                            (step) => Padding(
                                              padding: const EdgeInsets.only(
                                                bottom: 6,
                                              ),
                                              child: Text(
                                                step,
                                                style: theme.textTheme.bodySmall
                                                    ?.copyWith(
                                                      color:
                                                          UnsaidPalette.softInk,
                                                    ),
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),

                                const SizedBox(height: 16),

                                // Skip Button (only shown when keyboard is not enabled)
                                if (!_keyboardEnabled)
                                  TextButton(
                                    onPressed: widget.onSkip,
                                    style: TextButton.styleFrom(
                                      padding: const EdgeInsets.symmetric(
                                        vertical: 12,
                                        horizontal: 24,
                                      ),
                                    ),
                                    child: Text(
                                      'Skip for now',
                                      style: theme.textTheme.bodyMedium
                                          ?.copyWith(
                                            color: theme.colorScheme.onSurface
                                                .withValues(alpha: 0.7),
                                            decoration:
                                                TextDecoration.underline,
                                          ),
                                    ),
                                  ),
                              ],
                            ),
                          ), // Close Semantics for actions

                          const SizedBox(height: 24),

                          // Info Notice
                          Container(
                            padding: const EdgeInsets.all(16),
                            decoration: BoxDecoration(
                              color: theme.colorScheme.surface.withValues(
                                alpha: 0.5,
                              ),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Row(
                              children: [
                                Icon(
                                  Icons.info_outline,
                                  color: theme.colorScheme.primary,
                                  size: 20,
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Text(
                                    'You can always enable this later in Settings',
                                    style: theme.textTheme.bodySmall?.copyWith(
                                      color: theme.colorScheme.onSurface
                                          .withValues(alpha: 0.7),
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
                ),
              ),
            ),
          ),
        ), // Close Actions
      ), // Close Shortcuts
    );
  }
}
