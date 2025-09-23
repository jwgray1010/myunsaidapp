import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme/app_theme.dart';
import '../data/attachment_assessment.dart';
import '../data/assessment_integration.dart';
import '../data/attachment_scenarios.dart';
import '../data/adaptive_flow.dart';

class PersonalityTestScreen extends StatefulWidget {
  final int currentIndex;
  final Map<String, int> responses;
  final Future<void> Function()? markTestTaken;
  final void Function(
    MergedConfig config,
    AttachmentScores scores,
    GoalRoutingResult routing,
  )?
  onComplete;

  const PersonalityTestScreen({
    super.key,
    required this.currentIndex,
    required this.responses,
    this.onComplete,
    this.markTestTaken,
  });

  @override
  State<PersonalityTestScreen> createState() => _PersonalityTestScreenState();
}

class _PersonalityTestScreenState extends State<PersonalityTestScreen> {
  int? _selectedValue;
  int? _selectedIndex; // track option index to avoid duplicate-value ambiguity
  late List<PersonalityQuestion> _allQuestions;

  // Color mapping for different question types
  static const Map<String, Color> typeColors = {
    'anxiety': Color(0xFFFF6B6B), // Warm red for anxiety items
    'avoidance': Color(0xFF4ECDC4), // Teal for avoidance items
    'goal': Color(0xFF45B7D1), // Blue for goal items
    'attention': Color(0xFFFF9F43), // Orange for attention checks
    'social': Color(0xFF96CEB4), // Green for social desirability
    'paradox': Color(0xFFA8E6CF), // Light green for paradox items
  };

  @override
  void initState() {
    super.initState();

    // Use scenario-based questions instead of traditional attachment items
    final scenarioQuestions =
        AdaptiveAttachmentFlow.buildQuickSet(); // Gets 6-8 optimized scenarios
    _allQuestions = [...scenarioQuestions, ...goalItems];

    // Load existing response for this question
    if (widget.currentIndex < _allQuestions.length) {
      final question = _allQuestions[widget.currentIndex];
      final stored = widget.responses[question.id];
      _selectedValue = stored;
      if (stored != null) {
        // pick first matching index; acceptable even if duplicate values exist
        final idx = question.options.indexWhere((o) => o.value == stored);
        if (idx != -1) _selectedIndex = idx;
      }
    }
  }

  Color _getContrastingTextColor(Color backgroundColor) {
    // Calculate luminance to determine if we need light or dark text
    final luminance = backgroundColor.computeLuminance();
    return luminance > 0.5 ? Colors.black87 : Colors.white;
  }

  PersonalityQuestion get currentQuestion => _allQuestions[widget.currentIndex];

  double get progress => (widget.currentIndex + 1) / _allQuestions.length;

  Color _getQuestionTypeColor(PersonalityQuestion question) {
    if (question.isAttentionCheck) return typeColors['attention']!;
    if (question.isSocialDesirability) return typeColors['social']!;
    if (question.isGoal) return typeColors['goal']!;
    if (question.dimension == Dimension.anxiety) return typeColors['anxiety']!;
    if (question.dimension == Dimension.avoidance) {
      return typeColors['avoidance']!;
    }
    if (question.id == 'PX1') return typeColors['paradox']!;
    return Colors.grey;
  }

  void _selectAnswer(int value, int index) {
    print('DEBUG: _selectAnswer called with value: $value, index: $index');
    print(
      'DEBUG: Current _selectedValue before: $_selectedValue, _selectedIndex: $_selectedIndex',
    );
    HapticFeedback.selectionClick();
    setState(() {
      _selectedValue = value;
      _selectedIndex = index;
      widget.responses[currentQuestion.id] = value;
    });
    print(
      'DEBUG: _selectedValue after setState: $_selectedValue, _selectedIndex: $_selectedIndex',
    );
    print(
      'DEBUG: widget.responses[${currentQuestion.id}] = ${widget.responses[currentQuestion.id]}',
    );
  }

  // Helper method for RadioListTile that keeps debug + state in one place
  void _selectByIndex(int idx) {
    final question = currentQuestion;
    if (idx >= 0 && idx < question.options.length) {
      final option = question.options[idx];
      _selectAnswer(option.value, idx); // reuses existing method
    }
  }

  Future<void> _goNext() async {
    print('DEBUG: _goNext() called');
    print(
      'DEBUG: currentIndex=${widget.currentIndex}, totalQuestions=${_allQuestions.length}',
    );
    print('DEBUG: _selectedValue=$_selectedValue');

    if (_selectedValue == null) {
      print('DEBUG: No answer selected, showing selection required');
      _showSelectionRequired();
      return;
    }

    HapticFeedback.mediumImpact();

    if (widget.currentIndex < _allQuestions.length - 1) {
      print('DEBUG: Not last question, navigating to next question');
      if (mounted) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(
            builder: (context) => PersonalityTestScreen(
              currentIndex: widget.currentIndex + 1,
              responses: widget.responses,
              onComplete: widget.onComplete,
              markTestTaken: widget.markTestTaken,
            ),
          ),
        );
      }
    } else {
      print('DEBUG: Last question reached, calling _completeTest()');
      await _completeTest();
    }
  }

  Future<void> _goPrevious() async {
    if (widget.currentIndex > 0) {
      HapticFeedback.lightImpact();

      if (mounted) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(
            builder: (context) => PersonalityTestScreen(
              currentIndex: widget.currentIndex - 1,
              responses: widget.responses,
              onComplete: widget.onComplete,
              markTestTaken: widget.markTestTaken,
            ),
          ),
        );
      }
    }
  }

  Future<void> _completeTest() async {
    print('DEBUG: _completeTest() called');

    if (widget.markTestTaken != null) {
      print('DEBUG: Calling markTestTaken...');
      await widget.markTestTaken!();
      print('DEBUG: markTestTaken completed');
    }

    try {
      print('DEBUG: Starting scenario assessment processing...');

      // Use scenario-specific assessment integration
      final scenarioQuestions = AdaptiveAttachmentFlow.buildQuickSet();
      final mergedConfig =
          await AssessmentIntegration.runScenarioQuick8AndMerge(
            widget.responses,
            [
              ...scenarioQuestions,
              ...goalItems,
            ], // Include goal items for routing
          );
      print('DEBUG: Scenario assessment and merged config created');

      // Extract scores and routing from the merged config for backwards compatibility
      // Note: These are derived from the scenario assessment internally
      final scores = AttachmentScores(
        anxiety: 50, // Placeholder - scenarios handle scoring internally
        avoidance: 50, // Placeholder - scenarios handle scoring internally
        reliabilityAlpha: 0.8,
        attentionPassed: true,
        socialDesirability: 0.5,
        disorganizedLean: false,
        quadrant: mergedConfig.attachmentQuadrant,
        confidenceLabel: mergedConfig.confidenceLevel,
      );

      final routing = GoalRoutingResult(
        routeTags: {mergedConfig.primaryProfile},
        primaryProfile: mergedConfig.primaryProfile,
      );

      if (widget.onComplete != null) {
        print('DEBUG: Calling onComplete callback...');
        widget.onComplete!(mergedConfig, scores, routing);
        print('DEBUG: onComplete callback completed');
      } else {
        // Skip results screen - navigate directly to tone tutorial
        // Personality results are still calculated and stored internally
        print('DEBUG: No onComplete callback, navigating to tone tutorial...');
        if (mounted) {
          print(
            'DEBUG: Widget is mounted, calling Navigator.pushReplacementNamed...',
          );
          Navigator.pushReplacementNamed(context, '/tone_tutorial');
          print('DEBUG: Navigation call completed');
        } else {
          print('DEBUG: Widget not mounted, skipping navigation');
        }
      }
    } catch (e, stackTrace) {
      print('Error completing scenario assessment: $e');
      print('Stack trace: $stackTrace');
      // Fallback to legacy system or show error
      if (mounted) {
        _showError('Assessment processing failed. Please try again.');
      }
    }
  }

  void _showSelectionRequired() {
    HapticFeedback.mediumImpact();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            const Icon(
              Icons.warning_amber_rounded,
              color: Colors.white,
              size: 20,
              semanticLabel: 'Warning',
            ),
            const SizedBox(width: 12),
            Text(
              'Please select an answer to continue',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Colors.white,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
        backgroundColor: Colors.red,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppTheme.radiusMD),
        ),
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.all(AppTheme.spaceMD),
      ),
    );
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: Colors.red),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (widget.currentIndex < 0 ||
        widget.currentIndex >= _allQuestions.length) {
      return Scaffold(
        body: Container(
          decoration: BoxDecoration(gradient: AppTheme.primaryGradient),
          child: const Center(
            child: Text(
              'Invalid question index',
              style: TextStyle(color: Colors.white, fontSize: 18),
            ),
          ),
        ),
      );
    }

    final question = currentQuestion;
    final questionTypeColor = _getQuestionTypeColor(question);
    // (question type label suppressed intentionally)

    // Theme override specifically for personality test with question type colors
    return Theme(
      data: theme.copyWith(
        // Override radio theme for question type colors with better contrast
        radioTheme: RadioThemeData(
          fillColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.selected)) {
              return questionTypeColor;
            }
            return Colors.grey.shade400;
          }),
          overlayColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.pressed)) {
              return questionTypeColor.withOpacity(0.12);
            }
            if (states.contains(WidgetState.hovered)) {
              return questionTypeColor.withOpacity(0.08);
            }
            if (states.contains(WidgetState.focused)) {
              return questionTypeColor.withOpacity(0.12);
            }
            return Colors.transparent;
          }),
          splashRadius: 20,
        ),
      ),
      child: Scaffold(
        body: Container(
          decoration: BoxDecoration(gradient: AppTheme.primaryGradient),
          child: SafeArea(
            child: Column(
              children: [
                // Header with progress
                Container(
                  padding: const EdgeInsets.all(AppTheme.spaceLG),
                  child: Column(
                    children: [
                      // Progress bar
                      Container(
                        height: 6,
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.2),
                          borderRadius: BorderRadius.circular(
                            AppTheme.radiusFull,
                          ),
                        ),
                        child: FractionallySizedBox(
                          alignment: Alignment.centerLeft,
                          widthFactor: progress,
                          child: Container(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                colors: [
                                  Colors.white,
                                  Colors.white.withValues(alpha: 0.8),
                                ],
                              ),
                              borderRadius: BorderRadius.circular(
                                AppTheme.radiusFull,
                              ),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.white.withValues(alpha: 0.5),
                                  blurRadius: 8,
                                  spreadRadius: 1,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),

                      const SizedBox(height: AppTheme.spaceMD),

                      // Question counter and type
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            'Question ${widget.currentIndex + 1} of ${_allQuestions.length}',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: Colors.white.withValues(alpha: 0.9),
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          // Removed type label badge
                        ],
                      ),
                    ],
                  ),
                ),

                // Content
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppTheme.spaceLG,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Question card
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(AppTheme.spaceLG),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(
                              AppTheme.radiusLG,
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: questionTypeColor.withValues(alpha: 0.3),
                                blurRadius: 20,
                                offset: const Offset(0, 10),
                              ),
                            ],
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              const SizedBox(height: 4),

                              // Question text
                              Text(
                                question.question,
                                style: TextStyle(
                                  color: Colors.black87,
                                  fontSize: 18,
                                  fontWeight: FontWeight.w600,
                                  height: 1.2,
                                  shadows: [
                                    Shadow(
                                      color: Colors.white.withValues(
                                        alpha: 0.5,
                                      ),
                                      offset: const Offset(0, 1),
                                      blurRadius: 2,
                                    ),
                                  ],
                                ),
                                textAlign: TextAlign.center,
                              ),

                              // Special instructions for attention check
                              if (question.isAttentionCheck) ...[
                                const SizedBox(height: AppTheme.spaceMD),
                                Container(
                                  padding: const EdgeInsets.all(12),
                                  decoration: BoxDecoration(
                                    color: Colors.orange.withValues(alpha: 0.1),
                                    borderRadius: BorderRadius.circular(8),
                                    border: Border.all(
                                      color: Colors.orange.withValues(
                                        alpha: 0.3,
                                      ),
                                    ),
                                  ),
                                  child: Row(
                                    children: [
                                      Icon(
                                        Icons.info_outline,
                                        color: Colors.orange.shade700,
                                        size: 16,
                                      ),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: Text(
                                          'Please read carefully and follow the instruction',
                                          style: theme.textTheme.bodySmall
                                              ?.copyWith(
                                                color: Colors.orange.shade700,
                                                fontWeight: FontWeight.w500,
                                              ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),

                        const SizedBox(height: AppTheme.spaceLG),

                        // Answer options — RadioListTile version (single-select)
                        Column(
                          children: question.options.asMap().entries.map((
                            entry,
                          ) {
                            final idx = entry.key;
                            final option = entry.value;
                            final isSelected = _selectedIndex == idx;

                            return Card(
                              margin: const EdgeInsets.only(
                                bottom: AppTheme.spaceMD,
                              ),
                              elevation: isSelected ? 1.5 : 0,
                              color: isSelected
                                  ? null
                                  : null, // Allow RadioListTile tileColor to show
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(
                                  AppTheme.radiusLG,
                                ),
                                side: BorderSide(
                                  color: isSelected
                                      ? questionTypeColor
                                      : Colors.grey.withValues(alpha: 0.30),
                                  width: isSelected ? 2 : 1,
                                ),
                              ),
                              child: Theme(
                                // Override theme specifically for RadioListTile to ensure proper text visibility
                                data: Theme.of(context).copyWith(
                                  // Override radio button theme
                                  radioTheme: RadioThemeData(
                                    fillColor: WidgetStateProperty.resolveWith((
                                      states,
                                    ) {
                                      if (states.contains(
                                        WidgetState.selected,
                                      )) {
                                        return questionTypeColor;
                                      }
                                      return Colors.grey.shade400;
                                    }),
                                  ),
                                  // Override list tile theme for better text visibility
                                  listTileTheme: ListTileThemeData(
                                    textColor: isSelected
                                        ? _getContrastingTextColor(
                                            questionTypeColor,
                                          )
                                        : Colors.black87,
                                    selectedColor: _getContrastingTextColor(
                                      questionTypeColor,
                                    ),
                                  ),
                                ),
                                child: RadioListTile<int>(
                                  value: idx, // bind by index
                                  groupValue:
                                      _selectedIndex, // current selection
                                  onChanged: (i) => _selectByIndex(i!),
                                  title: Text(
                                    option.text,
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodyMedium
                                        ?.copyWith(
                                          fontWeight: isSelected
                                              ? FontWeight.w700
                                              : FontWeight.w500,
                                          // Use contrasting color based on background
                                          color: isSelected
                                              ? _getContrastingTextColor(
                                                  questionTypeColor,
                                                )
                                              : Colors.black87,
                                          height: 1.15,
                                        ),
                                  ),
                                  activeColor: questionTypeColor,
                                  selected: isSelected,
                                  tileColor: isSelected
                                      ? questionTypeColor.withValues(
                                          alpha: 0.08,
                                        )
                                      : Colors
                                            .white, // Explicit white background for unselected
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(
                                      AppTheme.radiusLG,
                                    ),
                                  ),
                                  contentPadding: const EdgeInsets.symmetric(
                                    horizontal: AppTheme.spaceLG,
                                    vertical: AppTheme.spaceMD,
                                  ),
                                ),
                              ),
                            );
                          }).toList(),
                        ),

                        // Reduce excessive bottom spacing to prevent overflow on smaller devices
                        const SizedBox(height: AppTheme.spaceLG),
                      ],
                    ),
                  ),
                ),

                // Navigation buttons
                // Navigation footer wrapped in SafeArea padding to avoid pixel overflow
                Container(
                  padding: EdgeInsets.only(
                    left: AppTheme.spaceLG,
                    right: AppTheme.spaceLG,
                    top: AppTheme.spaceLG,
                    bottom:
                        AppTheme.spaceLG +
                        MediaQuery.of(context).padding.bottom,
                  ),
                  child: Row(
                    children: [
                      // Previous button
                      if (widget.currentIndex > 0)
                        Expanded(
                          child: Container(
                            height: 56,
                            margin: const EdgeInsets.only(
                              right: AppTheme.spaceMD,
                            ),
                            child: OutlinedButton.icon(
                              onPressed: _goPrevious,
                              icon: const Icon(
                                Icons.arrow_back_ios,
                                color: Colors.white,
                                size: 18,
                                semanticLabel: 'Previous',
                              ),
                              label: Text(
                                'Previous',
                                style: theme.textTheme.titleMedium?.copyWith(
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              style: OutlinedButton.styleFrom(
                                side: BorderSide(
                                  color: Colors.white.withValues(alpha: 0.5),
                                  width: 2,
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(
                                    AppTheme.radiusLG,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),

                      // Next button
                      Expanded(
                        flex: widget.currentIndex > 0 ? 1 : 1,
                        child: Container(
                          height: 56,
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              colors: [
                                Colors.white,
                                Colors.white.withValues(alpha: 0.9),
                              ],
                            ),
                            borderRadius: BorderRadius.circular(
                              AppTheme.radiusLG,
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.2),
                                offset: const Offset(0, 4),
                                blurRadius: 12,
                                spreadRadius: 0,
                              ),
                            ],
                          ),
                          child: Material(
                            color: Colors.transparent,
                            child: InkWell(
                              onTap: _goNext,
                              borderRadius: BorderRadius.circular(
                                AppTheme.radiusLG,
                              ),
                              child: Center(
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Flexible(
                                      child: Text(
                                        widget.currentIndex <
                                                _allQuestions.length - 1
                                            ? 'Next'
                                            : 'Complete Assessment',
                                        style: theme.textTheme.bodyMedium?.copyWith(
                                          color: theme.colorScheme.primary,
                                          fontWeight: FontWeight.w600,
                                          fontSize:
                                              widget.currentIndex <
                                                  _allQuestions.length - 1
                                              ? 16
                                              : 14, // Smaller font for longer text
                                        ),
                                        overflow: TextOverflow.ellipsis,
                                        maxLines: 1,
                                      ),
                                    ),
                                    const SizedBox(width: AppTheme.spaceSM),
                                    Icon(
                                      widget.currentIndex <
                                              _allQuestions.length - 1
                                          ? Icons.arrow_forward_ios
                                          : Icons.psychology,
                                      color: theme.colorScheme.primary,
                                      size: 20,
                                      semanticLabel:
                                          widget.currentIndex <
                                              _allQuestions.length - 1
                                          ? 'Next'
                                          : 'Complete',
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ), // Close Column
          ), // Close SafeArea
        ), // Close Container (body)
      ), // Close Scaffold
    ); // Close Theme (return statement)
  }

  /// Entry point to start the modern assessment
  // ignore: unused_element
  static void startAssessment(
    BuildContext context, {
    Future<void> Function()? markTestTaken,
    void Function(
      MergedConfig config,
      AttachmentScores scores,
      GoalRoutingResult routing,
    )?
    onComplete,
  }) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => PersonalityTestScreen(
          currentIndex: 0,
          responses: const <String, int>{},
          markTestTaken: markTestTaken,
          onComplete: onComplete,
        ),
      ),
    );
  }
}
