import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../widgets/tone_indicator.dart';
import '../ui/unsaid_theme.dart';
import '../ui/unsaid_widgets.dart';
import 'dart:async';

class ToneIndicatorTutorialScreen extends StatefulWidget {
  final VoidCallback? onComplete;

  const ToneIndicatorTutorialScreen({super.key, this.onComplete});

  @override
  State<ToneIndicatorTutorialScreen> createState() =>
      _ToneIndicatorTutorialScreenState();
}

class _ToneIndicatorTutorialScreenState
    extends State<ToneIndicatorTutorialScreen>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  final PageController _pageController = PageController();
  int _currentPage = 0;
  late AnimationController _typingController;
  late AnimationController _pulseController;
  late AnimationController _caretController;
  late bool _reduceMotion;
  Timer? _auto;

  // Tutorial content for each page
  final List<TutorialPage> _pages = [
    TutorialPage(
      title: "Meet Your Tone Assistant",
      subtitle: "The Unsaid logo helps you communicate better",
      description: "",
      messageExample: "",
      toneStatus: ToneStatus.neutral,
      showPhone: false,
    ),
    TutorialPage(
      title: "",
      subtitle: "",
      description:
          "When the logo is green, your message has a warm, supportive tone that's likely to be well-received.",
      messageExample:
          "Thanks so much for your help! I really appreciate you taking the time to explain this to me.",
      toneStatus: ToneStatus.clear,
      showPhone: true,
    ),
    TutorialPage(
      title: "",
      subtitle: "",
      description:
          "Yellow indicates your message could be perceived as urgent or demanding. Consider softening your approach.",
      messageExample:
          "You need to fix this issue immediately. It should have been done yesterday.",
      toneStatus: ToneStatus.caution,
      showPhone: true,
    ),
    TutorialPage(
      title: "",
      subtitle: "",
      description:
          "When the logo turns red and pulses, it's warning you that your message could hurt someone's feelings or damage your relationship.",
      messageExample:
          "This is completely ridiculous! How could you make such a stupid mistake?",
      toneStatus: ToneStatus.alert,
      showPhone: true,
    ),
    TutorialPage(
      title: "You're All Set!",
      subtitle: "Start typing with confidence",
      description:
          "The tone indicator will appear in your keyboard and messaging apps, helping you communicate more effectively in all your conversations.",
      messageExample: "",
      toneStatus: ToneStatus.neutral,
      showPhone: false,
    ),
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    _typingController = AnimationController(
      duration: const Duration(seconds: 3),
      vsync: this,
    );
    _pulseController = AnimationController(
      duration: const Duration(milliseconds: 800),
      vsync: this,
    );
    _caretController = AnimationController(
      duration: const Duration(milliseconds: 700),
      vsync: this,
    )..repeat(reverse: true);

    // Listen for typing completion to stop caret
    _typingController.addStatusListener((status) {
      if (status == AnimationStatus.completed) {
        _caretController.stop();
      }
    });

    // Setup auto-advance listener
    _pageController.addListener(() => _scheduleAutoNext());

    // If first page shows phone, animate on first frame
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final p = _pages[_currentPage];
      if (p.showPhone && p.messageExample.isNotEmpty && !_reduceMotion) {
        _typingController
          ..reset()
          ..forward();
        _caretController
          ..reset()
          ..repeat(reverse: true);
        if (p.toneStatus == ToneStatus.alert) {
          _pulseController.repeat(reverse: true);
        }
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduceMotion = MediaQuery.accessibleNavigationOf(context);
    if (_reduceMotion) {
      _typingController.value = 1;
      _pulseController.stop();
      _caretController.stop();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _typingController.stop();
      _pulseController.stop();
      _caretController.stop();
    } else if (state == AppLifecycleState.resumed && !_reduceMotion) {
      if (_pages[_currentPage].toneStatus == ToneStatus.alert) {
        _pulseController.repeat(reverse: true);
      }
      if (_typingController.status != AnimationStatus.completed) {
        _caretController.repeat(reverse: true);
      }
    }
  }

  void _scheduleAutoNext() {
    _auto?.cancel();
    if (_currentPage == 0 || _currentPage == _pages.length - 1) return;
    _auto = Timer(const Duration(seconds: 5), () {
      if (mounted && _pageController.hasClients) _nextPage();
    });
  }

  @override
  void dispose() {
    _auto?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _pageController.dispose();
    _typingController.dispose();
    _pulseController.dispose();
    _caretController.dispose();
    super.dispose();
  }

  void _nextPage() {
    HapticFeedback.selectionClick();
    if (_currentPage < _pages.length - 1) {
      _pageController.nextPage(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    } else {
      // Navigate to keyboard setup after tone tutorial
      Navigator.pushReplacementNamed(context, '/keyboard_intro');
    }
  }

  void _skipTutorial() {
    // Navigate to keyboard setup when skipping
    Navigator.pushReplacementNamed(context, '/keyboard_intro');
  }

  @override
  Widget build(BuildContext context) {
    return UnsaidGradientScaffold(
      body: Column(
        children: [
          // Header with skip button
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                // Logo
                RepaintBoundary(
                  child: Image.asset(
                    'assets/unsaid_logo.png',
                    width: 32,
                    height: 32,
                  ),
                ),
                // Skip button
                TextButton(
                  onPressed: _skipTutorial,
                  child: const Text(
                    'Skip',
                    style: TextStyle(
                      color: UnsaidPalette.softInk,
                      fontSize: 16,
                    ),
                  ),
                ),
              ],
            ),
          ),

          // Page content
          Expanded(
            child: PageView.builder(
              controller: _pageController,
              onPageChanged: (index) {
                setState(() => _currentPage = index);

                final p = _pages[index];
                if (_reduceMotion) {
                  _typingController.value = 1;
                  _pulseController.stop();
                  _caretController.stop();
                  return;
                }

                if (p.showPhone && p.messageExample.isNotEmpty) {
                  _typingController
                    ..reset()
                    ..forward();
                  _caretController
                    ..reset()
                    ..repeat(reverse: true);
                  if (p.toneStatus == ToneStatus.alert) {
                    _pulseController.repeat(reverse: true);
                  } else {
                    _pulseController.stop();
                  }
                } else {
                  _pulseController.stop();
                  _caretController.stop();
                }

                _scheduleAutoNext();
              },
              itemCount: _pages.length,
              itemBuilder: (context, index) {
                return _buildTutorialPage(_pages[index]);
              },
            ),
          ),

          // Page indicators and navigation
          Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              children: [
                // Page indicators with animations and accessibility
                Semantics(
                  label: 'Page ${_currentPage + 1} of ${_pages.length}',
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: List.generate(
                      _pages.length,
                      (index) => AnimatedContainer(
                        duration: const Duration(milliseconds: 300),
                        margin: const EdgeInsets.symmetric(horizontal: 4),
                        width: index == _currentPage ? 24 : 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: index == _currentPage
                              ? UnsaidPalette.blush
                              : UnsaidPalette.softInk.withValues(alpha: 0.3),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Semantics(
                          label: index == _currentPage
                              ? 'Current page ${index + 1}'
                              : 'Page ${index + 1}',
                          excludeSemantics: true,
                        ),
                      ),
                    ),
                  ),
                ),

                const SizedBox(height: 24),

                // Next/Complete button
                SizedBox(
                  width: double.infinity,
                  height: 56,
                  child: ElevatedButton(
                    onPressed: _nextPage,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: UnsaidPalette.blush,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(28),
                      ),
                      elevation: 0,
                    ),
                    child: Text(
                      _currentPage == _pages.length - 1
                          ? 'Get Started'
                          : 'Next',
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTutorialPage(TutorialPage page) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Column(
        children: [
          // Only show title and subtitle if they're not empty
          if (page.title.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              page.title,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                fontWeight: FontWeight.bold,
                color: UnsaidPalette.ink,
                fontSize: page.showPhone ? 18 : 22,
              ),
            ),
            const SizedBox(height: 1),
          ],

          if (page.subtitle.isNotEmpty) ...[
            Text(
              page.subtitle,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                color: UnsaidPalette.softInk,
                fontSize: page.showPhone ? 14 : 16,
              ),
            ),
            SizedBox(height: page.showPhone ? 8 : 12),
          ],

          // Give phone pages more space by removing title/subtitle spacing
          if (page.title.isEmpty && page.subtitle.isEmpty)
            const SizedBox(height: 8),
          // Main content area
          Expanded(
            child: SingleChildScrollView(
              child: page.showPhone
                  ? _buildPhoneExample(page)
                  : _buildIntroContent(page),
            ),
          ),

          // Description
          if (page.description.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Text(
                page.description,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                  color: UnsaidPalette.softInk,
                  height: 1.2,
                  fontSize: page.showPhone
                      ? 11
                      : 15, // Much smaller for phone pages
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildIntroContent(TutorialPage page) {
    if (_currentPage == 0) {
      // First page - show all tone states and a legend/info card
      return Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _buildToneExample(
                ToneStatus.clear,
                'Good',
                semanticLabel: 'Clear tone',
              ),
              _buildToneExample(
                ToneStatus.caution,
                'Caution',
                semanticLabel: 'Caution tone',
              ),
              _buildToneExample(
                ToneStatus.alert,
                'Alert',
                semanticLabel: 'Alert tone',
              ),
            ],
          ),
          const SizedBox(height: 40),
          UnsaidCard(
            child: Column(
              children: [
                const Icon(
                  Icons.psychology,
                  size: 48,
                  color: UnsaidPalette.blush,
                ),
                const SizedBox(height: 16),
                const Text(
                  'Smart Tone Detection',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                    color: Colors.black87,
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Real-time communication insights',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: UnsaidPalette.softInk),
                ),
                const SizedBox(height: 16),
                // Legend/info card
                UnsaidCard(
                  soft: true,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildLegendRow(
                        ToneStatus.clear,
                        'Green: Positive, friendly tone',
                        'Clear tone',
                      ),
                      _buildLegendRow(
                        ToneStatus.caution,
                        'Yellow: Direct or urgent tone',
                        'Caution tone',
                      ),
                      _buildLegendRow(
                        ToneStatus.alert,
                        'Red: Potentially harsh tone (with pulse)',
                        'Alert tone',
                      ),
                      _buildLegendRow(
                        ToneStatus.neutral,
                        'White: Neutral tone',
                        'Neutral tone',
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      );
    } else {
      // Last page - completion
      return Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 120,
            height: 120,
            decoration: BoxDecoration(
              color: UnsaidPalette.success.withValues(alpha: 0.1),
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.check_circle,
              size: 80,
              color: UnsaidPalette.success,
            ),
          ),
          const SizedBox(height: 24),
          Text(
            'Tutorial Complete!',
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.bold,
              color: UnsaidPalette.success,
            ),
          ),
        ],
      );
    }
  }

  Widget _buildLegendRow(ToneStatus status, String text, String semanticLabel) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          ToneIndicator(status: status, size: 18),
          const SizedBox(width: 8),
          Text(text, style: const TextStyle(fontSize: 13)),
        ],
      ),
    );
  }

  Widget _buildToneExample(
    ToneStatus status,
    String label, {
    String? semanticLabel,
  }) {
    return Column(
      children: [
        ToneIndicator(
          status: status,
          size: 48,
          showPulse: status == ToneStatus.alert,
        ),
        Text(
          label,
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
        ),
      ],
    );
  }

  Widget _buildPhoneExample(TutorialPage page) {
    return Center(
      child: RepaintBoundary(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final screenWidth = constraints.maxWidth;
            final phoneWidth = (screenWidth * 0.75).clamp(240.0, 320.0);
            final phoneHeight = phoneWidth * 2.0;

            return _PhoneChrome(
              width: phoneWidth,
              height: phoneHeight,
              child: _buildMessageInterface(page, phoneWidth),
            );
          },
        ),
      ),
    );
  }

  Widget _buildMessageInterface(TutorialPage page, double phoneWidth) {
    return Column(
      children: [
        // Status bar
        Container(
          height: 40,
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: const Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                '9:41',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: Colors.black,
                ),
              ),
              Row(
                children: [
                  Icon(Icons.signal_cellular_4_bar, size: 14),
                  SizedBox(width: 3),
                  Icon(Icons.wifi, size: 14),
                  SizedBox(width: 3),
                  Icon(Icons.battery_full, size: 14),
                ],
              ),
            ],
          ),
        ),

        // App header
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              CircleAvatar(
                radius: 14,
                backgroundColor: Colors.blue.shade100,
                child: Icon(
                  Icons.person,
                  size: 16,
                  color: Colors.blue.shade600,
                ),
              ),
              const SizedBox(width: 12),
              const Text(
                'Jamie',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: Colors.black,
                ),
              ),
            ],
          ),
        ),

        // Message area
        Expanded(
          child: Container(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 20),
                _buildAnimatedText(page.messageExample),
                const SizedBox(height: 12),
                _buildToneIndicator(page.toneStatus),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _PhoneChrome({
    required double width,
    required double height,
    required Widget child,
  }) {
    return RepaintBoundary(
      child: Container(
        width: width,
        height: height,
        decoration: BoxDecoration(
          color: Colors.black,
          borderRadius: BorderRadius.circular(width * 0.125),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.3),
              blurRadius: 25,
              offset: const Offset(0, 12),
              spreadRadius: 2,
            ),
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.1),
              blurRadius: 8,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Container(
          margin: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(width * 0.1),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(width * 0.1),
            child: child,
          ),
        ),
      ),
    );
  }

  Widget _buildToneIndicator(ToneStatus status) {
    return AnimatedBuilder(
      animation: _pulseController,
      builder: (context, child) {
        final scale = status == ToneStatus.alert
            ? 1.0 + (_pulseController.value * 0.2)
            : 1.0;
        return Transform.scale(
          scale: scale,
          child: ToneIndicator(status: status, size: 32),
        );
      },
    );
  }

  Widget _buildAnimatedText(String text, {bool isOutgoing = false}) {
    return AnimatedBuilder(
      animation: Listenable.merge([_typingController, _caretController]),
      builder: (context, child) {
        final progress = _typingController.value;
        final visibleLength = (text.length * progress).round();
        final visibleText = text.substring(0, visibleLength);

        // Enhanced caret logic
        bool showCaret = false;
        if (!_reduceMotion && visibleLength < text.length) {
          // Show blinking caret while typing
          showCaret = _caretController.value > 0.5;
        } else if (!_reduceMotion &&
            progress == 1.0 &&
            visibleLength == text.length) {
          // Show static caret briefly after completion, then fade out
          final timeSinceCompletion =
              DateTime.now().millisecondsSinceEpoch % 2000;
          showCaret = timeSinceCompletion < 500;
        }

        return RepaintBoundary(
          child: Text(
            visibleText + (showCaret ? '|' : ''),
            style: TextStyle(
              fontSize: 13,
              color: isOutgoing ? Colors.white : Colors.black,
            ),
          ),
        );
      },
    );
  }
}

class TutorialPage {
  final String title;
  final String subtitle;
  final String description;
  final String messageExample;
  final ToneStatus toneStatus;
  final bool showPhone;

  TutorialPage({
    required this.title,
    required this.subtitle,
    required this.description,
    required this.messageExample,
    required this.toneStatus,
    required this.showPhone,
  });
}
