import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../ui/unsaid_widgets.dart';

class PersonalityTestDisclaimerScreenProfessional extends StatefulWidget {
  final VoidCallback? onAgree; // Made optional for backward compatibility
  final VoidCallback? onAgreeModern; // New callback for modern assessment

  const PersonalityTestDisclaimerScreenProfessional({
    super.key,
    this.onAgree,
    this.onAgreeModern,
  });

  @override
  State<PersonalityTestDisclaimerScreenProfessional> createState() =>
      _PersonalityTestDisclaimerScreenProfessionalState();
}

class _PersonalityTestDisclaimerScreenProfessionalState
    extends State<PersonalityTestDisclaimerScreenProfessional>
    with TickerProviderStateMixin {
  late AnimationController _slideController;
  late AnimationController _fadeController;
  late AnimationController _logoController;
  late Animation<Offset> _slideAnimation;
  late Animation<double> _fadeAnimation;
  late Animation<double> _logoAnimation;

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
      begin: 0.0,
      end: 1.0,
    ).animate(CurvedAnimation(parent: _fadeController, curve: Curves.easeOut));

    _logoAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _logoController, curve: Curves.elasticOut),
    );

    _startAnimations();
  }

  void _startAnimations() async {
    await Future.delayed(const Duration(milliseconds: 300));
    _logoController.forward();
    await Future.delayed(const Duration(milliseconds: 500));
    _fadeController.forward();
    _slideController.forward();
  }

  @override
  void dispose() {
    _slideController.dispose();
    _fadeController.dispose();
    _logoController.dispose();
    super.dispose();
  }

  void _openUrl(BuildContext context, String url) async {
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } else {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Could not open the link.'),
          backgroundColor: Colors.red,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final keyPoints = [
      {
        'icon': Icons.science_outlined,
        'iconColor': theme.colorScheme.primary,
        'title': 'Research-Based',
        'description':
            'Based on established attachment theory research by Bowlby, Ainsworth, and contemporary psychologists.',
        'semantic': 'Research-Based',
      },
      {
        'icon': Icons.warning_amber_outlined,
        'iconColor': Colors.orange,
        'title': 'Educational Purpose',
        'description':
            'This assessment is for self-reflection and educational purposes only, not clinical diagnosis.',
        'semantic': 'Educational Purpose',
      },
      {
        'icon': Icons.person_outline,
        'iconColor': Colors.blue,
        'title': 'Individual Results',
        'description':
            'Results may vary and should be interpreted as general tendencies, not absolute categories.',
        'semantic': 'Individual Results',
      },
      {
        'icon': Icons.chat_bubble_outline,
        'iconColor': Colors.green,
        'title': 'Communication Style',
        'description':
            'You’ll also learn about your communication style (e.g., assertive, passive, aggressive, or passive-aggressive).',
        'semantic': 'Communication Style',
      },
      {
        'icon': Icons.health_and_safety_outlined,
        'iconColor': Colors.red,
        'title': 'Professional Support',
        'description':
            'If you have mental health concerns, please consult with a qualified professional.',
        'semantic': 'Professional Support',
      },
      {
        'icon': Icons.shuffle_outlined,
        'iconColor': theme.colorScheme.primary,
        'title': 'Fair Assessment',
        'description':
            'Questions and answer options are randomized for each test to prevent pattern bias and ensure accurate results.',
        'semantic': 'Fair Assessment',
      },
    ];

    return UnsaidGradientScaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 500),
            child: FadeTransition(
              opacity: _fadeAnimation,
              child: SlideTransition(
                position: _slideAnimation,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    // Animated Logo
                    ScaleTransition(
                      scale: _logoAnimation,
                      child: Container(
                        padding: const EdgeInsets.all(24),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(
                              color: theme.colorScheme.primary.withValues(
                                alpha: 0.3,
                              ),
                              blurRadius: 20,
                              spreadRadius: 5,
                            ),
                          ],
                        ),
                        child: Image.asset(
                          'assets/unsaid_logo.png',
                          width: 80,
                          height: 80,
                        ),
                      ),
                    ),

                    const SizedBox(height: 32),

                    // Title (icon removed for clarity / accessibility contrast)
                    Text(
                      'Personality Assessment',
                      style: theme.textTheme.headlineMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                        letterSpacing: 0.5,
                      ),
                      textAlign: TextAlign.center,
                    ),

                    const SizedBox(height: 24),

                    // Main Disclaimer Card
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(24),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(20),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.1),
                            blurRadius: 15,
                            offset: const Offset(0, 5),
                          ),
                        ],
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Important notice header
                          Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: Colors.blue.withValues(alpha: 0.1),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Row(
                              children: [
                                const Icon(
                                  Icons.info_outline,
                                  color: Colors.blue,
                                  size: 20,
                                  semanticLabel: 'Important Information',
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  'Important Information',
                                  style: theme.textTheme.titleMedium?.copyWith(
                                    color: Colors.blue,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ],
                            ),
                          ),

                          const SizedBox(height: 20),

                          // Main disclaimer text
                          Text(
                            'Before taking this personality assessment, please understand:',
                            style: theme.textTheme.bodyLarge?.copyWith(
                              fontWeight: FontWeight.w600,
                              height: 1.5,
                              color: Colors.black,
                            ),
                          ),

                          const SizedBox(height: 16),

                          // Key points (with communication style surfaced)
                          ...keyPoints.map(
                            (item) => Padding(
                              padding: const EdgeInsets.only(bottom: 16),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          item['title'] as String,
                                          style: theme.textTheme.bodyMedium
                                              ?.copyWith(
                                                fontWeight: FontWeight.bold,
                                                color: Colors.black,
                                              ),
                                        ),
                                        const SizedBox(height: 4),
                                        Text(
                                          item['description'] as String,
                                          style: theme.textTheme.bodySmall
                                              ?.copyWith(
                                                color: Colors.black87,
                                                height: 1.4,
                                              ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),

                          const SizedBox(height: 16),

                          // Privacy notice
                          Container(
                            padding: const EdgeInsets.all(16),
                            decoration: BoxDecoration(
                              color: Colors.green.withValues(alpha: 0.05),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: Colors.green.withValues(alpha: 0.2),
                              ),
                            ),
                            child: Row(
                              children: [
                                const Icon(
                                  Icons.security_outlined,
                                  color: Colors.green,
                                  size: 20,
                                  semanticLabel: 'Privacy',
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Text(
                                    'Your responses are private and used only to generate your personal results.',
                                    style: theme.textTheme.bodySmall?.copyWith(
                                      color: Colors.green[800],
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 32),

                    // Action Buttons
                    Column(
                      children: [
                        // Primary Assessment Button
                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton.icon(
                            onPressed: widget.onAgreeModern ?? widget.onAgree,
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.green,
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(
                                vertical: 16,
                                horizontal: 24,
                              ),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(16),
                              ),
                              elevation: 2,
                            ),
                            icon: const Icon(
                              Icons.psychology_outlined,
                              size: 20,
                            ),
                            label: Text(
                              'Start Personality Assessment',
                              style: theme.textTheme.titleMedium?.copyWith(
                                fontWeight: FontWeight.w600,
                                color: Colors.white,
                              ),
                            ),
                          ),
                        ),

                        const SizedBox(height: 16),

                        // Learn More Button
                        TextButton.icon(
                          onPressed: () => _openUrl(
                            context,
                            'https://en.wikipedia.org/wiki/Attachment_theory',
                          ),
                          style: TextButton.styleFrom(
                            padding: const EdgeInsets.symmetric(
                              vertical: 12,
                              horizontal: 24,
                            ),
                          ),
                          icon: Icon(
                            Icons.open_in_new,
                            size: 16,
                            color: Colors.white70,
                          ),
                          label: Text(
                            'Learn About Attachment Theory',
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: Colors.white70,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),

                        const SizedBox(height: 24),

                        // Development Skip Button
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: Colors.orange.shade50,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: Colors.orange.shade200,
                              width: 1,
                            ),
                          ),
                          child: Column(
                            children: [
                              Row(
                                children: [
                                  Icon(
                                    Icons.developer_mode,
                                    color: Colors.orange.shade600,
                                    size: 20,
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    'Development Mode',
                                    style: TextStyle(
                                      color: Colors.orange.shade800,
                                      fontWeight: FontWeight.w600,
                                      fontSize: 14,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 12),
                              SizedBox(
                                width: double.infinity,
                                child: ElevatedButton(
                                  onPressed: () =>
                                      Navigator.pushReplacementNamed(
                                        context,
                                        '/premium',
                                      ),
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: Colors.orange.shade600,
                                    foregroundColor: Colors.white,
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 12,
                                    ),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    elevation: 2,
                                  ),
                                  child: const Text(
                                    'Skip Questions → Go to Premium',
                                    style: TextStyle(
                                      fontWeight: FontWeight.w600,
                                      color: Colors
                                          .white, // Explicitly set white text
                                      fontSize:
                                          16, // Larger font for better readability
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),

                    const SizedBox(height: 16),

                    // Footer text
                    Text(
                      'Taking this assessment indicates your agreement with these terms and understanding of its educational purpose.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurface.withValues(
                          alpha: 0.6,
                        ),
                        fontStyle: FontStyle.italic,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
