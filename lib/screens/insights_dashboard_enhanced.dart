// Minimal Insights Dashboard (clean rebuild)
// Tabs: Secure | Analytics | Therapy | Settings
// Features: secure progress bar, micro-habits, quick actions, tone summary (real keyboard data),
// analytics recent tones list, therapy links, settings integration.
// Excludes legacy charts & attachment style labels.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart'; // Add for HapticFeedback
import 'package:url_launcher/url_launcher.dart';
import '../services/keyboard_manager.dart';
import '../services/secure_storage_service.dart';
import '../services/personality_data_manager.dart';
import '../services/auth_service.dart';
import '../ui/unsaid_theme.dart';
import '../ui/unsaid_widgets.dart';
import 'settings_screen_professional.dart';

// ---- Constants (Secure Progress & Micro-Habits) ----
const List<String> _kConstructiveTones = [
  'positive',
  'calm',
  'confident',
  'supportive',
  'neutral',
];

const List<Map<String, String>> _kMicroHabits = [
  {'title': 'Validate first', 'body': 'Open with one line of understanding.'},
  {'title': 'Name one feeling', 'body': 'Add a single feeling word.'},
  {'title': 'State one need', 'body': 'Use “I need…” or “It helps when…”.'},
  {'title': 'Small ask', 'body': 'Invite: “Could we…?” / “Open to…?”'},
  {'title': 'Shorten spikes', 'body': 'If sharp, add one softening sentence.'},
];

class InsightsDashboardEnhanced extends StatefulWidget {
  const InsightsDashboardEnhanced({super.key});
  @override
  State<InsightsDashboardEnhanced> createState() =>
      _InsightsDashboardEnhancedState();
}

class _InsightsDashboardEnhancedState extends State<InsightsDashboardEnhanced>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  late final TabController _tabs;
  final _storage = SecureStorageService();
  final _keyboard = KeyboardManager();
  final _personality = PersonalityDataManager.shared;
  final _scrollController = ScrollController();
  bool _showTabs = true;
  double _lastScrollPosition = 0.0;

  String _userName = 'Friend';
  double _sensitivity = 0.5;
  String _tonePref = 'Neutral';
  bool _compactHabits = false; // persisted user preference

  bool _loadingSummary = true;
  Map<String, dynamic>? _toneSummary; // {ready, samples, style, score, range}
  DateTime? _toneUpdatedAt; // last time summary refreshed

  // Behavior scores (cached between refreshes)
  int? _secureHabitsScore; // 0-100
  int? _repairEffectivenessScore; // 0-100
  int? _secureProgressScore; // existing constructive ratio 0-100
  bool _habitsHasData = false;
  bool _repairHasData = false;
  bool _progressHasData = false;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 4, vsync: this);
    WidgetsBinding.instance.addObserver(this);
    _scrollController.addListener(_onScroll);
    _bootstrap();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // Refresh lightweight analytics on app focus
      _computeBehaviorScores();
      _loadKeyboardSummary();
    }
    super.didChangeAppLifecycleState(state);
  }

  Future<void> _bootstrap() async {
    await Future.wait([
      _loadPrefs(),
      _loadKeyboardSummary(),
      _computeBehaviorScores(),
    ]);
  }

  Future<void> _loadPrefs() async {
    try {
      // Try to get name from secure storage first
      final name =
          await _storage.getSecureData('display_name') ??
          await _storage.getSecureData('first_name');

      final sens = await _storage.getSecureData('analysis_sensitivity');
      final tone = await _storage.getSecureData('default_tone');
      final compact = await _storage.getSecureData('habits_compact');

      if (!mounted) return;
      setState(() {
        if (name != null && name.isNotEmpty) {
          _userName = name;
        } else {
          // Try Firebase Auth as fallback
          try {
            final currentUser = AuthService.instance.user;
            if (currentUser?.displayName != null &&
                currentUser!.displayName!.isNotEmpty) {
              _userName = currentUser.displayName!;
            } else {
              _userName = 'Friend';
            }
          } catch (_) {
            _userName = 'Friend';
          }
        }
        final s = double.tryParse(sens ?? '');
        if (s != null) _sensitivity = s;
        if (tone != null && tone.isNotEmpty) _tonePref = tone;
        if (compact != null) {
          _compactHabits = compact == '1' || compact.toLowerCase() == 'true';
        }
      });
    } catch (_) {
      // Keep default values on error
      if (mounted) {
        setState(() {
          _userName = 'Friend';
        });
      }
    }
  }

  Future<void> _loadKeyboardSummary() async {
    setState(() => _loadingSummary = true);
    try {
      final analytics = await _personality.performStartupKeyboardAnalysis();
      if (!mounted) return;
      setState(() {
        _toneSummary = _buildSummary(analytics);
        _toneUpdatedAt = DateTime.now();
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _toneSummary = {
          'ready': false,
          'message':
              'Start typing with the Unsaid keyboard to unlock insights.',
        };
        _toneUpdatedAt = DateTime.now();
      });
    }
    if (mounted) setState(() => _loadingSummary = false);
  }

  int _computeStreakDays() {
    final history = _keyboard.analysisHistory.toList();
    final now = DateTime.now();
    int streak = 0;

    for (int i = 0; i < 7; i++) {
      final targetDate = now.subtract(Duration(days: i));
      final dayStart = DateTime(
        targetDate.year,
        targetDate.month,
        targetDate.day,
      );
      final dayEnd = dayStart.add(const Duration(days: 1));

      final dayMessages = history.where((m) {
        final ts = DateTime.tryParse('${m['timestamp'] ?? ''}');
        return ts != null && ts.isAfter(dayStart) && ts.isBefore(dayEnd);
      }).toList();

      // Check if day had any ruptures (alert/angry/aggressive tones)
      final hasRupture = dayMessages.any((m) {
        final tone = ('${m['tone_status'] ?? m['dominant_tone'] ?? 'neutral'}')
            .toLowerCase();
        return {'alert', 'angry', 'aggressive', 'caution'}.contains(tone);
      });

      if (hasRupture || dayMessages.isEmpty) break;
      streak++;
    }

    return streak;
  }

  Future<void> _onRefreshAll() async {
    HapticFeedback.lightImpact();
    await Future.wait([_loadKeyboardSummary(), _computeBehaviorScores()]);
  }

  void _showProgressDetails(String label, int? score, bool hasData) {
    HapticFeedback.lightImpact();

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => DraggableScrollableSheet(
        initialChildSize: 0.6,
        maxChildSize: 0.9,
        minChildSize: 0.4,
        builder: (context, scrollController) => Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(_getIconForLabel(label)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      label,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: Colors.black87,
                      ),
                    ),
                  ),
                  if (hasData && score != null)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: _scoreColor(score),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Text(
                        '$score%',
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              Expanded(
                child: _buildProgressDetailContent(label, scrollController),
              ),
            ],
          ),
        ),
      ),
    );
  }

  IconData _getIconForLabel(String label) {
    switch (label) {
      case 'Secure Habits':
        return Icons.shield_moon;
      case 'Secure Communicator':
        return Icons.check_circle;
      case 'Repair Effectiveness':
        return Icons.healing;
      default:
        return Icons.info;
    }
  }

  Widget _buildProgressDetailContent(
    String label,
    ScrollController controller,
  ) {
    final history = _keyboard.analysisHistory.toList();

    switch (label) {
      case 'Secure Habits':
        return _buildSecureHabitsDetails(history, controller);
      case 'Secure Communicator':
        return _buildSecureCommunicatorDetails(history, controller);
      case 'Repair Effectiveness':
        return _buildRepairEffectivenessDetails(history, controller);
      default:
        return const Text(
          'Details coming soon...',
          style: TextStyle(color: Colors.black87),
        );
    }
  }

  Widget _buildSecureHabitsDetails(List history, ScrollController controller) {
    final recentHabits = history.take(30).toList();
    final examples = <String>[];

    for (final m in recentHabits.take(5)) {
      final txt = ('${m['original_message'] ?? m['original_text'] ?? ''}')
          .toLowerCase();
      final v = RegExp(
        r'\b(i (?:can|do) see|i understand|that makes sense|i hear you)\b',
      ).hasMatch(txt);
      final n = RegExp(r'\b(i need|what would help)\b').hasMatch(txt);
      final a = RegExp(
        "\\b(could we|would you|can we|let'?s try)\\b",
      ).hasMatch(txt);

      if ([v, n, a].where((x) => x).length >= 2) {
        examples.add(
          '${m['original_message'] ?? m['original_text'] ?? 'Example message'}',
        );
      }
    }

    return ListView(
      controller: controller,
      children: [
        const Text(
          'Recent examples of secure habits in your messages:',
          style: TextStyle(fontWeight: FontWeight.w600, color: Colors.black87),
        ),
        const SizedBox(height: 12),
        ...examples.map(
          (example) => Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                example,
                style: const TextStyle(color: Colors.black87),
              ),
            ),
          ),
        ),
        if (examples.isEmpty)
          const Card(
            child: Padding(
              padding: EdgeInsets.all(12),
              child: Text(
                'No recent examples found. Try using phrases like "I understand...", "I need...", or "Could we..."',
                style: TextStyle(color: Colors.black54),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildSecureCommunicatorDetails(
    List history,
    ScrollController controller,
  ) {
    final recent = history.take(10).toList();

    final positive = recent
        .where(
          (m) => ('${m['dominant_tone'] ?? ''}').toLowerCase() == 'positive',
        )
        .length;
    final neutral = recent
        .where(
          (m) => ('${m['dominant_tone'] ?? ''}').toLowerCase() == 'neutral',
        )
        .length;
    final negative = recent.length - positive - neutral;

    return ListView(
      controller: controller,
      children: [
        const Text(
          'Tone breakdown (last 10 messages):',
          style: TextStyle(fontWeight: FontWeight.w600, color: Colors.black87),
        ),
        const SizedBox(height: 12),
        _buildToneRow('Positive', positive, Colors.green),
        _buildToneRow('Neutral', neutral, Colors.orange),
        _buildToneRow('Negative', negative, Colors.red),
        const SizedBox(height: 16),
        SizedBox(
          height: 40,
          child: CustomPaint(
            painter: _SparklinePainter(_generateSparklineData(recent)),
            child: Container(),
          ),
        ),
      ],
    );
  }

  Widget _buildRepairEffectivenessDetails(
    List history,
    ScrollController controller,
  ) {
    final cutoff = DateTime.now().subtract(const Duration(days: 7));
    final recent7d = history.where((m) {
      final ts = DateTime.tryParse('${m['timestamp'] ?? ''}');
      return ts != null && ts.isAfter(cutoff);
    }).toList();

    return ListView(
      controller: controller,
      children: [
        const Text(
          'Repair attempts in the last 7 days:',
          style: TextStyle(fontWeight: FontWeight.w600, color: Colors.black87),
        ),
        const SizedBox(height: 12),
        Text(
          'Total messages analyzed: ${recent7d.length}',
          style: const TextStyle(color: Colors.black87),
        ),
        const SizedBox(height: 8),
        const Text(
          'Look for patterns of repair after tension (like "sorry", "I understand", "let me try again")',
          style: TextStyle(color: Colors.black54),
        ),
      ],
    );
  }

  Widget _buildToneRow(String label, int count, Color color) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Container(
            width: 12,
            height: 12,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 8),
          Text('$label: $count', style: const TextStyle(color: Colors.black87)),
        ],
      ),
    );
  }

  List<double> _generateSparklineData(List history) {
    return history.take(10).map((m) {
      final tone = ('${m['dominant_tone'] ?? ''}').toLowerCase();
      if (_kConstructiveTones.contains(tone)) return 1.0;
      if (tone == 'neutral') return 0.5;
      return 0.0;
    }).toList();
  }

  Future<void> _computeBehaviorScores() async {
    final history = _keyboard.analysisHistory.toList();
    // Secure Progress (existing logic - last 10 messages constructive ratio)
    final recentProgress = history.take(10).toList();
    final constructive = recentProgress.where((m) {
      final tone = ('${m['dominant_tone'] ?? ''}').toLowerCase();
      return _kConstructiveTones.contains(tone);
    }).length;
    final progressScore = recentProgress.isEmpty
        ? null
        : ((constructive / recentProgress.length) * 100).round();

    // Secure Habits (last 30 messages) - hits contain at least 2 of 3 categories
    final recentHabits = history.take(30).toList();
    int hits = 0;
    for (final m in recentHabits) {
      final txt = ('${m['original_message'] ?? m['original_text'] ?? ''}')
          .toLowerCase();
      final v = RegExp(
        r'\b(i (?:can|do) see|i understand|that makes sense|i hear you)\b',
      ).hasMatch(txt);
      final n = RegExp(r'\b(i need|what would help)\b').hasMatch(txt);
      // Use a regular (non-raw) string here to allow the escaped apostrophe inside let's
      final a = RegExp(
        "\\b(could we|would you|can we|let'?s try)\\b",
      ).hasMatch(txt);
      if ([v, n, a].where((x) => x == true).length >= 2) hits++;
    }
    final habitsScore = recentHabits.isEmpty
        ? null
        : ((hits / recentHabits.length) * 100).round();

    // Repair Effectiveness (last 7 days)
    final cutoff = DateTime.now().subtract(const Duration(days: 7));
    final recent7d =
        history.where((m) {
          final ts = DateTime.tryParse('${m['timestamp'] ?? ''}');
          return ts != null && ts.isAfter(cutoff);
        }).toList()..sort((a, b) {
          final ta =
              DateTime.tryParse('${a['timestamp'] ?? ''}') ?? DateTime(2000);
          final tb =
              DateTime.tryParse('${b['timestamp'] ?? ''}') ?? DateTime(2000);
          return ta.compareTo(tb);
        });
    int ruptures = 0, repairs = 0;
    bool isRupture(Map m) {
      final t = ('${m['tone_status'] ?? m['dominant_tone'] ?? 'neutral'}')
          .toLowerCase();
      return {'alert', 'angry', 'aggressive', 'caution'}.contains(t);
    }

    bool isRepair(Map m) {
      final txt = ('${m['original_message'] ?? m['original_text'] ?? ''}')
          .toLowerCase();
      return RegExp(
        r'\b(sorry|apologize|understand|i see|makes sense|thank you|appreciate|can we restart|let me try again|work together)\b',
      ).hasMatch(txt);
    }

    for (int i = 0; i < recent7d.length; i++) {
      if (isRupture(recent7d[i])) {
        ruptures++;
        final t0 =
            DateTime.tryParse('${recent7d[i]['timestamp']}') ?? DateTime(2000);
        for (int j = i + 1; j < recent7d.length; j++) {
          final tj =
              DateTime.tryParse('${recent7d[j]['timestamp']}') ??
              DateTime(2000);
          if (tj.difference(t0).inHours > 24) break;
          if (isRepair(recent7d[j])) {
            repairs++;
            break;
          }
        }
      }
    }
    final repairScore = (ruptures == 0)
        ? (recent7d.isEmpty ? null : 100)
        : ((repairs / ruptures) * 100).round();

    if (!mounted) return;
    setState(() {
      _secureProgressScore = progressScore;
      _secureHabitsScore = habitsScore;
      _repairEffectivenessScore = repairScore;
      _progressHasData =
          progressScore != null &&
          recentProgress.length >= 5; // need >=5 samples
      _habitsHasData =
          habitsScore != null &&
          recentHabits.length >= 5; // threshold for visibility
      _repairHasData =
          repairScore != null &&
          recent7d.isNotEmpty; // at least some data in window
    });
  }

  int _safeInt(dynamic v) {
    if (v is int) return v;
    if (v is double) return v.round();
    if (v is num) return v.toInt();
    if (v is String) {
      final i = int.tryParse(v);
      if (i != null) return i;
      final d = double.tryParse(v);
      if (d != null) return d.round();
    }
    return 0;
  }

  Map<String, dynamic> _buildSummary(Map<String, dynamic>? analytics) {
    if (analytics == null || analytics.isEmpty) {
      return {
        'ready': false,
        'message': 'Enable and use the keyboard to begin.',
      };
    }
    final behavior =
        analytics['behavior_analysis'] as Map<String, dynamic>? ?? {};
    final tonePatterns =
        behavior['tone_patterns'] as Map<String, dynamic>? ?? {};
    final dist =
        (tonePatterns['tone_distribution'] as Map<String, dynamic>? ?? {});
    final pos = _safeInt(dist['positive']);
    final neu = _safeInt(dist['neutral']);
    final neg = _safeInt(dist['negative']);
    final total = pos + neu + neg;
    final score = total == 0
        ? 0
        : ((pos * 1.0 + neu * 0.5) / total * 100).round();
    final dominant = (tonePatterns['dominant_tone'] ?? 'balanced').toString();
    return {
      'ready': true,
      'samples': total,
      'style': _describeTone(dominant),
      'score': score,
      'range': _rangeLabel(pos, neu, neg),
    };
  }

  String _describeTone(String t) {
    switch (t.toLowerCase()) {
      case 'positive':
        return 'Positive & Clear';
      case 'negative':
        return 'Needs Refinement';
      case 'neutral':
        return 'Balanced';
      case 'calm':
        return 'Calm & Steady';
      case 'confident':
        return 'Confident Tone';
      default:
        return 'Evolving';
    }
  }

  String _rangeLabel(int pos, int neu, int neg) {
    final total = pos + neu + neg;
    if (total == 0) return 'No data yet';
    final pr = pos / total;
    final nr = neg / total;
    if (pr > 0.65) return 'Consistently constructive';
    if (nr > 0.30) return 'High variability';
    return 'Balanced range';
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _tabs.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    final currentPosition = _scrollController.position.pixels;
    final delta = currentPosition - _lastScrollPosition;

    // Show tabs when scrolling up, hide when scrolling down
    if (delta > 10 && _showTabs) {
      setState(() => _showTabs = false);
    } else if (delta < -10 && !_showTabs) {
      setState(() => _showTabs = true);
    }

    _lastScrollPosition = currentPosition;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return UnsaidGradientScaffold(
      body: SafeArea(
        top: false, // Let SliverAppBar handle top spacing
        child: NestedScrollView(
          controller: _scrollController,
          headerSliverBuilder: (context, innerBoxIsScrolled) => [
            SliverAppBar(
              pinned: true,
              floating: false,
              expandedHeight:
                  90, // Further reduced height to fix scrolling pixel issues
              forceElevated: innerBoxIsScrolled,
              backgroundColor: Colors.transparent,
              elevation: 0,
              flexibleSpace: FlexibleSpaceBar(
                titlePadding: EdgeInsetsDirectional.only(
                  start: 16,
                  bottom: 16, // Adjusted for smaller header
                  top: MediaQuery.of(
                    context,
                  ).padding.top, // Add status bar padding
                ),
                title: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        CircleAvatar(
                          backgroundColor: UnsaidPalette.textPrimaryDark
                              .withOpacity(0.2),
                          child: Text(
                            _userName.isNotEmpty
                                ? _userName[0].toUpperCase()
                                : '?',
                            style: TextStyle(
                              color: UnsaidPalette.textPrimaryDark,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Text(
                          'Welcome, $_userName',
                          style: TextStyle(
                            color: UnsaidPalette.textPrimaryDark,
                            fontWeight: FontWeight.w700,
                            letterSpacing: -0.2,
                            fontSize:
                                18, // Slightly smaller font for compact header
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8), // Reduced spacing
                    _StreakChip(streakDays: _computeStreakDays()),
                  ],
                ),
                background: Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [colorScheme.primary, colorScheme.tertiary],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                  ),
                  child: Align(
                    alignment: Alignment.bottomRight,
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: IconButton(
                        icon: Icon(
                          Icons.refresh,
                          color: UnsaidPalette.textPrimaryDark,
                        ),
                        onPressed: _onRefreshAll,
                        tooltip: 'Refresh all data',
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
          body: Column(
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                height: _showTabs ? kTextTabBarHeight : 0,
                clipBehavior:
                    Clip.hardEdge, // Prevent overflow during animation
                decoration: const BoxDecoration(),
                child: _showTabs
                    ? Container(
                        color: colorScheme.surface,
                        child: TabBar(
                          controller: _tabs,
                          labelColor: Colors.black,
                          unselectedLabelColor: Colors.black.withOpacity(0.7),
                          indicatorColor: UnsaidPalette.blush,
                          onTap: (_) => HapticFeedback.lightImpact(),
                          tabs: const [
                            Tab(text: 'Secure'),
                            Tab(text: 'Analytics'),
                            Tab(text: 'Therapy'),
                            Tab(text: 'Settings'),
                          ],
                        ),
                      )
                    : const SizedBox.shrink(),
              ),
              Expanded(
                child: TabBarView(
                  controller: _tabs,
                  children: [
                    _secureTab(),
                    _analyticsTab(),
                    _therapyTab(),
                    SettingsScreenProfessional(
                      sensitivity: _sensitivity,
                      onSensitivityChanged: (v) {
                        setState(() => _sensitivity = v);
                        _storage.storeSecureData(
                          'analysis_sensitivity',
                          v.toString(),
                        );
                      },
                      tone: _tonePref,
                      onToneChanged: (t) {
                        setState(() => _tonePref = t);
                        _storage.storeSecureData('tone_preference', t);
                      },
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // Secure Tab
  Widget _secureTab() {
    return RefreshIndicator(
      onRefresh: () async {
        HapticFeedback.lightImpact();
        await Future.wait([_loadKeyboardSummary(), _computeBehaviorScores()]);
        if (mounted) {
          HapticFeedback.lightImpact(); // Success feedback
        }
      },
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _tripleProgressCard(),
            const SizedBox(height: 16),
            _microHabitsCard(),
            const SizedBox(height: 16),
            _quickActions(),
            const SizedBox(height: 16),
            _toneSummaryCard(),
          ],
        ),
      ),
    );
  }

  Widget _tripleProgressCard() => UnsaidCard(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const UnsaidSectionHeader(
          title: 'Secure Pathway',
          subtitle: 'Inputs • Outcome • Safety Net',
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: _progressCircle(
                label: 'Secure Habits',
                subtitle: 'Validation • Need • Ask',
                score: _secureHabitsScore,
                hasData: _habitsHasData,
                icon: Icons.shield_moon,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _progressCircle(
                label: 'Secure Communicator',
                subtitle: 'Recent tone mix',
                score: _secureProgressScore,
                hasData: _progressHasData,
                icon: Icons.check_circle,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _progressCircle(
                label: 'Repair Effectiveness',
                subtitle: 'Repairs within 24h',
                score: _repairEffectivenessScore,
                hasData: _repairHasData,
                icon: Icons.healing,
              ),
            ),
          ],
        ),
      ],
    ),
  );

  Widget _progressCircle({
    required String label,
    required String subtitle,
    required int? score,
    required bool hasData,
    required IconData icon,
  }) {
    final display = (score ?? 0).clamp(0, 100);
    final color = hasData && score != null
        ? _scoreColor(display)
        : Colors.grey.shade400;
    return Semantics(
      label: label,
      value: hasData && score != null ? '$display percent' : 'Getting started',
      hint: 'Double tap for details',
      onTap: () => _showProgressDetails(label, score, hasData),
      child: GestureDetector(
        onTap: () => _showProgressDetails(label, score, hasData),
        child: Column(
          children: [
            SizedBox(
              height: 92,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  AnimatedSegmentedCircle(
                    segments: 20,
                    filled: hasData && score != null
                        ? (display / 5).round()
                        : 0,
                    color: color,
                    background: Colors.grey.withOpacity(0.15),
                  ),
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(icon, size: 18, color: color),
                      const SizedBox(height: 4),
                      Text(
                        hasData && score != null ? '$display%' : '—',
                        style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 16,
                          color: Colors.black87,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 6),
            Text(
              label,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontWeight: FontWeight.w600,
                fontSize: 12,
                color: Colors.black87,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              hasData ? subtitle : 'Getting started',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 10, color: UnsaidPalette.textTertiary),
            ),
          ],
        ),
      ),
    );
  }

  Color _scoreColor(int score) {
    if (score >= 70) return Colors.green.shade600;
    if (score >= 50) return Colors.orange.shade700;
    return Colors.red.shade600;
  }

  Widget _microHabitsCard() {
    final visible = _compactHabits ? _kMicroHabits.take(2) : _kMicroHabits;
    return UnsaidCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: UnsaidSectionHeader(
                  title: 'Micro-Habits',
                  subtitle: 'Practical secure boosters',
                ),
              ),
              TextButton.icon(
                onPressed: _toggleHabits,
                icon: Icon(
                  _compactHabits ? Icons.unfold_more : Icons.unfold_less,
                ),
                label: Text(_compactHabits ? 'Expand' : 'Collapse'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ...visible.map((m) => _TipRow(title: m['title']!, body: m['body']!)),
          if (_compactHabits && _kMicroHabits.length > 2)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                '${_kMicroHabits.length - 2} more tips hidden',
                style: const TextStyle(
                  fontSize: 11,
                  color: UnsaidPalette.softInk,
                ),
              ),
            ),
        ],
      ),
    );
  }

  void _toggleHabits() {
    setState(() => _compactHabits = !_compactHabits);
    _storage.storeSecureData('habits_compact', _compactHabits ? '1' : '0');
  }

  Widget _toneSummaryCard() {
    Widget buildLoading() => UnsaidCard(
      child: _ShimmerEffect(
        child: Column(
          children: [
            Container(
              height: 16,
              width: 120,
              decoration: BoxDecoration(
                color: Colors.grey.shade300,
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            const SizedBox(height: 8),
            Container(
              height: 12,
              width: 200,
              decoration: BoxDecoration(
                color: Colors.grey.shade300,
                borderRadius: BorderRadius.circular(6),
              ),
            ),
            const SizedBox(height: 8),
            Container(
              height: 12,
              width: 160,
              decoration: BoxDecoration(
                color: Colors.grey.shade300,
                borderRadius: BorderRadius.circular(6),
              ),
            ),
          ],
        ),
      ),
    );

    Widget buildEmpty(String msg) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Text(msg, style: const TextStyle(color: Colors.black54)),
    );

    Widget buildData() {
      final style = _toneSummary!['style'] ?? 'Evolving';
      final score = _toneSummary!['score'];
      final samples = _toneSummary!['samples'];
      final range = _toneSummary!['range'];
      final updated = _toneUpdatedAt;
      return Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  style,
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    color: Colors.black87,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Score: $score  •  Samples: $samples',
                  style: const TextStyle(color: Colors.black54, fontSize: 12),
                ),
                const SizedBox(height: 4),
                Text(
                  'Range: $range',
                  style: const TextStyle(color: Colors.black54, fontSize: 12),
                ),
                if (updated != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    'Last updated ${_relativeTime(updated)}',
                    style: const TextStyle(color: Colors.black54, fontSize: 11),
                  ),
                ],
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: UnsaidPalette.accentLight,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: UnsaidPalette.accent.withOpacity(0.3),
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.security,
                        size: 16,
                        color: UnsaidPalette.accent,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          'On-device analysis • Your raw messages aren\'t stored',
                          style: TextStyle(
                            fontSize: 11,
                            color: UnsaidPalette.textOnColor(
                              UnsaidPalette.accentLight,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadingSummary ? null : _loadKeyboardSummary,
            tooltip: _loadingSummary ? 'Refreshing...' : 'Refresh',
          ),
        ],
      );
    }

    Widget child;
    if (_loadingSummary) {
      child = buildLoading();
    } else if (_toneSummary == null || _toneSummary!['ready'] != true) {
      child = buildEmpty(
        _toneSummary?['message'] ?? 'Start using the keyboard to see analysis.',
      );
    } else {
      child = buildData();
    }

    return UnsaidCard(
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 250),
        switchInCurve: Curves.easeOut,
        switchOutCurve: Curves.easeIn,
        child: KeyedSubtree(
          key: ValueKey(
            _loadingSummary
                ? 'loading'
                : (_toneSummary == null || _toneSummary!['ready'] != true)
                ? 'empty'
                : 'data-${_toneSummary!['score']}-${_toneSummary!['samples']}',
          ),
          child: child,
        ),
      ),
    );
  }

  String _relativeTime(DateTime dt) {
    final diff = DateTime.now().difference(dt);
    if (diff.inSeconds < 45) return 'just now';
    if (diff.inMinutes < 2) return '1m ago';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 2) return '1h ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays == 1) return 'yesterday';
    return '${diff.inDays}d ago';
  }

  Widget _quickActions() => UnsaidCard(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const UnsaidSectionHeader(
          title: 'Quick Actions',
          subtitle: 'Boost progress',
        ),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            ElevatedButton.icon(
              onPressed: _showPreSendCoach,
              icon: const Icon(Icons.co_present),
              label: const Text('Pre-Send Coach'),
            ),
            ElevatedButton.icon(
              onPressed: () => _tabs.animateTo(1),
              icon: const Icon(Icons.analytics),
              label: const Text('View Analytics'),
            ),
          ],
        ),
      ],
    ),
  );

  void _showPreSendCoach() {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (_) {
        bool v = false, n = false, a = false;
        return StatefulBuilder(
          builder: (ctx, set) {
            return Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Row(
                    children: [
                      Icon(Icons.shield_moon),
                      SizedBox(width: 8),
                      Text(
                        'Pre-Send Coach',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: Colors.black87,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  CheckboxListTile(
                    value: v,
                    onChanged: (b) => set(() => v = b ?? false),
                    title: const Text('Validation added?'),
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                  ),
                  CheckboxListTile(
                    value: n,
                    onChanged: (b) => set(() => n = b ?? false),
                    title: const Text('Need stated?'),
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                  ),
                  CheckboxListTile(
                    value: a,
                    onChanged: (b) => set(() => a = b ?? false),
                    title: const Text('Clear ask?'),
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      icon: const Icon(Icons.send),
                      label: const Text('Looks good'),
                      onPressed: () => Navigator.pop(ctx),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  // Analytics Tab
  Widget _analyticsTab() {
    final history = _keyboard.analysisHistory;
    if (history.isEmpty) {
      return SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            UnsaidCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const UnsaidSectionHeader(
                    title: 'Communication Analytics',
                    subtitle: 'Track your progress over time',
                  ),
                  const SizedBox(height: 16),
                  Container(
                    height: 200,
                    decoration: BoxDecoration(
                      color: Colors.grey.shade100,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.grey.shade300, width: 2),
                    ),
                    child: Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.analytics_outlined,
                            size: 48,
                            color: Colors.grey.shade400,
                          ),
                          const SizedBox(height: 12),
                          Text(
                            'Start using the keyboard to see your analytics',
                            style: TextStyle(
                              color: Colors.grey.shade600,
                              fontSize: 16,
                            ),
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'Your communication patterns will appear here',
                            style: TextStyle(
                              color: Colors.grey.shade500,
                              fontSize: 14,
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  _buildEmptyAnalyticsChart(),
                ],
              ),
            ),
            const SizedBox(height: 16),
            UnsaidCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'What to expect:',
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 16,
                      color: Colors.black87,
                    ),
                  ),
                  const SizedBox(height: 12),
                  _buildAnalyticsTip(
                    'Tone Analysis',
                    'See your communication style patterns',
                    Icons.chat_bubble_outline,
                  ),
                  _buildAnalyticsTip(
                    'Progress Tracking',
                    'Monitor improvements over time',
                    Icons.trending_up,
                  ),
                  _buildAnalyticsTip(
                    'Confidence Scores',
                    'How certain the analysis is',
                    Icons.verified,
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }
    final recent = history.take(20).toList();
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: recent.length,
      itemBuilder: (ctx, i) {
        final m = recent[i];
        final tone = (m['dominant_tone'] ?? 'unknown').toString();
        final conf = (m['confidence'] ?? 0.5) as double;
        return UnsaidCard(
          margin: const EdgeInsets.only(bottom: 12),
          child: Row(
            children: [
              Icon(
                Icons.chat_bubble_outline,
                color: UnsaidPalette.blush.withOpacity(.85),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      tone,
                      style: const TextStyle(
                        fontWeight: FontWeight.w600,
                        color: Colors.black87,
                      ),
                    ),
                    const SizedBox(height: 4),
                    LinearProgressIndicator(
                      value: conf.clamp(0, 1),
                      backgroundColor: Colors.grey.withOpacity(.15),
                      valueColor: const AlwaysStoppedAnimation(
                        UnsaidPalette.blush,
                      ),
                      minHeight: 4,
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildEmptyAnalyticsChart() {
    return Container(
      height: 150,
      decoration: BoxDecoration(
        color: Colors.grey.shade50,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade200, width: 1),
      ),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.show_chart, size: 32, color: Colors.grey.shade400),
            const SizedBox(height: 8),
            Text(
              'Chart will appear here',
              style: TextStyle(color: Colors.grey.shade500, fontSize: 14),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAnalyticsTip(String title, String description, IconData icon) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: [
          Icon(icon, color: UnsaidPalette.blush.withOpacity(0.7), size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                    color: Colors.black87,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  description,
                  style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // Therapy Tab
  Widget _therapyTab() => SingleChildScrollView(
    padding: const EdgeInsets.all(16),
    child: Column(
      children: [
        UnsaidCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const UnsaidSectionHeader(
                title: 'Online Therapy Options',
                subtitle: 'Find support that fits you',
              ),
              const SizedBox(height: 12),
              _extLink(
                'Psychology Today – Find a Therapist',
                'https://www.psychologytoday.com/us/therapists',
              ),
              _extLink(
                'Open Path Collective (low-cost)',
                'https://openpathcollective.org/',
              ),
              _extLink(
                'Inclusive Therapists',
                'https://www.inclusivetherapists.com/',
              ),
              const SizedBox(height: 8),
              const Text(
                'Tip: try “attachment-focused” or “EFT (Emotionally Focused Therapy)”.',
                style: TextStyle(color: UnsaidPalette.softInk, fontSize: 12),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        UnsaidCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const UnsaidSectionHeader(
                title: 'Streaming / Videos',
                subtitle: 'Learn secure communication',
              ),
              _extLink(
                'Validate → Need → Ask (search)',
                'https://www.youtube.com/results?search_query=validate+need+ask+communication',
              ),
              _extLink(
                'EFT Basics',
                'https://www.youtube.com/results?search_query=emotionally+focused+therapy+repair',
              ),
              _extLink(
                'Secure Scripts',
                'https://www.youtube.com/results?search_query=secure+communication+scripts',
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        const UnsaidCard(
          child: Text(
            'Coaching, not clinical care. If communication feels unsafe, seek licensed support.',
            style: TextStyle(
              color: UnsaidPalette.softInk,
              fontSize: 12,
              fontStyle: FontStyle.italic,
            ),
          ),
        ),
      ],
    ),
  );

  Widget _extLink(String label, String url) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: ElevatedButton.icon(
      onPressed: () => _launchUrlSafely(url),
      style: ElevatedButton.styleFrom(
        foregroundColor: Colors.black87,
        backgroundColor: Colors.white,
      ),
      icon: const Icon(Icons.open_in_new, color: Colors.black87),
      label: Text(label, style: const TextStyle(color: Colors.black87)),
    ),
  );

  Future<void> _launchUrlSafely(String url) async {
    try {
      final uri = Uri.parse(url);
      final canLaunch = await canLaunchUrl(uri);
      if (canLaunch) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      } else {
        _showErrorSnackBar('Unable to open link');
      }
    } catch (e) {
      _showErrorSnackBar('Failed to open link: ${e.toString()}');
    }
  }

  void _showErrorSnackBar(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        action: SnackBarAction(
          label: 'Dismiss',
          onPressed: () {
            ScaffoldMessenger.of(context).hideCurrentSnackBar();
          },
        ),
      ),
    );
  }
}

// Animated segmented circular progress (with smooth transitions)
class AnimatedSegmentedCircle extends ImplicitlyAnimatedWidget {
  final int segments;
  final int filled;
  final Color color;
  final Color background;

  const AnimatedSegmentedCircle({
    super.key,
    required this.segments,
    required this.filled,
    required this.color,
    required this.background,
    super.duration = const Duration(milliseconds: 400),
    super.curve = Curves.easeOut,
  });

  @override
  ImplicitlyAnimatedWidgetState<AnimatedSegmentedCircle> createState() =>
      _AnimatedSegmentedCircleState();
}

class _AnimatedSegmentedCircleState
    extends AnimatedWidgetBaseState<AnimatedSegmentedCircle> {
  IntTween? _filledTween;

  @override
  void forEachTween(TweenVisitor<dynamic> visitor) {
    _filledTween =
        visitor(_filledTween, widget.filled, (v) => IntTween(begin: v as int))
            as IntTween?;
  }

  @override
  Widget build(BuildContext context) => _SegmentedCircle(
    segments: widget.segments,
    filled: _filledTween?.evaluate(animation) ?? widget.filled,
    color: widget.color,
    background: widget.background,
  );
}

// Segmented circular progress painter (20 segments default)
class _SegmentedCircle extends StatelessWidget {
  final int segments;
  final int filled; // number of filled segments
  final Color color;
  final Color background;
  const _SegmentedCircle({
    required this.segments,
    required this.filled,
    required this.color,
    required this.background,
  });
  @override
  Widget build(BuildContext context) => CustomPaint(
    painter: _SegmentedCirclePainter(
      segments: segments,
      filled: filled.clamp(0, segments),
      color: color,
      background: background,
    ),
    size: const Size(92, 92),
  );
}

class _SegmentedCirclePainter extends CustomPainter {
  final int segments;
  final int filled;
  final Color color;
  final Color background;
  _SegmentedCirclePainter({
    required this.segments,
    required this.filled,
    required this.color,
    required this.background,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = 8.0;
    final gapRadians = 0.10; // small gap between segments
    final rect = Offset.zero & size;
    final center = rect.center;
    final radius = (size.shortestSide / 2) - stroke;
    final sweepPer = (2 * 3.141592653589793) / segments;
    final paintBg = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..color = background;
    final paintFill = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..color = color;

    for (int i = 0; i < segments; i++) {
      final start = -3.141592653589793 / 2 + i * sweepPer; // start at top
      final sweep = sweepPer - gapRadians * (sweepPer / (sweepPer));
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        start,
        sweep - 0.01,
        false,
        i < filled ? paintFill : paintBg,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _SegmentedCirclePainter old) {
    return old.filled != filled ||
        old.color != color ||
        old.segments != segments ||
        old.background != background;
  }
}

class _TipRow extends StatelessWidget {
  final String title, body;
  const _TipRow({required this.title, required this.body});
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Icon(Icons.check_circle, size: 18, color: UnsaidPalette.blush),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontWeight: FontWeight.w600,
                  color: Colors.black87,
                ),
              ),
              const SizedBox(height: 2),
              Text(body, style: const TextStyle(color: Colors.black54)),
            ],
          ),
        ),
      ],
    ),
  );
}

// Streak chip widget for header
class _StreakChip extends StatelessWidget {
  final int streakDays;

  const _StreakChip({required this.streakDays});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: theme.colorScheme.onPrimary.withOpacity(0.2),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: theme.colorScheme.onPrimary.withOpacity(0.3),
          width: 1,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.local_fire_department,
            size: 16,
            color: theme.colorScheme.onPrimary,
          ),
          const SizedBox(width: 4),
          Text(
            '$streakDays day${streakDays != 1 ? 's' : ''}',
            style: TextStyle(
              color: theme.colorScheme.onPrimary,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

// Shimmer effect for loading states
class _ShimmerEffect extends StatefulWidget {
  final Widget child;

  const _ShimmerEffect({required this.child});

  @override
  State<_ShimmerEffect> createState() => _ShimmerEffectState();
}

class _ShimmerEffectState extends State<_ShimmerEffect>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _animation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 1500),
      vsync: this,
    )..repeat();
    _animation = Tween<double>(begin: -1.0, end: 2.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOutSine),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _animation,
      builder: (context, child) {
        return ShaderMask(
          shaderCallback: (bounds) {
            return LinearGradient(
              begin: Alignment.centerLeft,
              end: Alignment.centerRight,
              colors: const [
                Colors.transparent,
                Colors.white,
                Colors.transparent,
              ],
              stops: [
                (_animation.value - 0.3).clamp(0.0, 1.0),
                _animation.value.clamp(0.0, 1.0),
                (_animation.value + 0.3).clamp(0.0, 1.0),
              ],
            ).createShader(bounds);
          },
          child: widget.child,
        );
      },
    );
  }
}

// Simple sparkline painter for 7-day trends
class _SparklinePainter extends CustomPainter {
  final List<double> values;

  _SparklinePainter(this.values);

  @override
  void paint(Canvas canvas, Size size) {
    if (values.isEmpty) return;

    final paint = Paint()
      ..color = Colors.blue
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;

    final path = Path();
    final stepX = size.width / (values.length - 1);

    for (int i = 0; i < values.length; i++) {
      final x = i * stepX;
      final y = size.height - (values[i] * size.height);

      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }

    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _SparklinePainter oldDelegate) {
    return oldDelegate.values != values;
  }
}
