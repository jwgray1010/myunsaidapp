import 'dart:math';

class PersonalityQuestionOption {
  final String text;
  final String? type; // For goal profiling questions
  final int? anxietyScore; // 1-5 scale for anxiety dimension
  final int? avoidanceScore; // 1-5 scale for avoidance dimension
  final int? value;

  const PersonalityQuestionOption({
    required this.text,
    this.type,
    this.anxietyScore,
    this.avoidanceScore,
    this.value,
  });
}

class PersonalityQuestion {
  final String question;
  final List<PersonalityQuestionOption> options;
  final bool isGoalQuestion; // true for profiling, false for attachment
  final bool isReversed; // true if higher scores indicate more security

  const PersonalityQuestion({
    required this.question,
    required this.options,
    this.isGoalQuestion = false,
    this.isReversed = false,
  });
}

// Enum for attachment styles
enum AttachmentStyle {
  secure('B', 'Secure'),
  anxious('A', 'Anxious'),
  avoidant('C', 'Avoidant'),
  disorganized('D', 'Disorganized');

  const AttachmentStyle(this.shortName, this.longName);
  final String shortName;
  final String longName;
}

class PersonalityTest {
  static final Random _random = Random();

  // Calculate dimensional scores from answers
  static Map<String, double> calculateDimensionalScores(
    List<String> answers,
    List<PersonalityQuestion> questions,
  ) {
    double anxietySum = 0;
    double avoidanceSum = 0;
    int anxietyCount = 0;
    int avoidanceCount = 0;

    for (int i = 0; i < answers.length && i < questions.length; i++) {
      final question = questions[i];

      // Skip goal profiling questions
      if (question.isGoalQuestion) continue;

      final answer = answers[i];
      final option = question.options.firstWhere(
        (opt) => opt.text == answer,
        orElse: () => question.options.first,
      );

      if (option.anxietyScore != null) {
        double score = option.anxietyScore!.toDouble();
        if (question.isReversed) score = 6 - score; // Reverse score
        anxietySum += score;
        anxietyCount++;
      }

      if (option.avoidanceScore != null) {
        double score = option.avoidanceScore!.toDouble();
        if (question.isReversed) score = 6 - score; // Reverse score
        avoidanceSum += score;
        avoidanceCount++;
      }
    }

    return {
      'anxiety': anxietyCount > 0 ? anxietySum / anxietyCount : 3.0,
      'avoidance': avoidanceCount > 0 ? avoidanceSum / avoidanceCount : 3.0,
      'disorganized': 0.0, // Will be calculated based on anxiety + avoidance
    };
  }

  // Get questions with shuffled answers (keep question order for consistency)
  static List<PersonalityQuestion> getQuestionsWithShuffledAnswers() {
    return improvedPersonalityQuestions.map((question) {
      if (question.isGoalQuestion) {
        // Don't shuffle goal questions - order matters for user experience
        return question;
      }

      List<PersonalityQuestionOption> shuffledOptions = List.from(
        question.options,
      );
      shuffledOptions.shuffle(_random);

      return PersonalityQuestion(
        question: question.question,
        options: shuffledOptions,
        isGoalQuestion: question.isGoalQuestion,
        isReversed: question.isReversed,
      );
    }).toList();
  }

  // BRANCHING LOGIC FOR QUICK ASSESSMENT
  // Generate adaptive question set based on attachment style probes
  static List<PersonalityQuestion> getAdaptiveQuestionSet({
    int goalQuestionCount = 10,
    int maxAttachmentQuestions = 8,
  }) {
    List<PersonalityQuestion> adaptiveQuestions = [];

    // Start with goal profiling questions
    final goalQuestions = improvedPersonalityQuestions
        .where((q) => q.isGoalQuestion)
        .take(goalQuestionCount)
        .toList();
    adaptiveQuestions.addAll(goalQuestions);

    // Add one probe from each attachment style category
    adaptiveQuestions.addAll(_getInitialProbes());

    return adaptiveQuestions;
  }

  // Get one probe from each attachment style for initial screening
  static List<PersonalityQuestion> _getInitialProbes() {
    return [
      anxiousProbes[_random.nextInt(anxiousProbes.length)],
      avoidantProbes[_random.nextInt(avoidantProbes.length)],
      disorganizedProbes[_random.nextInt(disorganizedProbes.length)],
      secureProbes[_random.nextInt(secureProbes.length)],
    ];
  }

  // Calculate provisional scores from partial answers to determine branching
  static Map<String, double> calculateProvisionalScores(
    List<String> answers,
    List<PersonalityQuestion> questions,
  ) {
    double anxietySum = 0;
    double avoidanceSum = 0;
    int anxietyCount = 0;
    int avoidanceCount = 0;

    for (int i = 0; i < answers.length && i < questions.length; i++) {
      final question = questions[i];

      // Skip goal profiling questions for attachment scoring
      if (question.isGoalQuestion) continue;

      final answer = answers[i];
      final option = question.options.firstWhere(
        (opt) => opt.text == answer,
        orElse: () => question.options.first,
      );

      if (option.anxietyScore != null) {
        double score = option.anxietyScore!.toDouble();
        if (question.isReversed) score = 6 - score;

        // Apply probe weighting (1.15x multiplier for probe questions)
        if (_isProbeQuestion(question)) {
          score *= 1.15;
        }

        anxietySum += score;
        anxietyCount++;
      }

      if (option.avoidanceScore != null) {
        double score = option.avoidanceScore!.toDouble();
        if (question.isReversed) score = 6 - score;

        // Apply probe weighting
        if (_isProbeQuestion(question)) {
          score *= 1.15;
        }

        avoidanceSum += score;
        avoidanceCount++;
      }
    }

    return {
      'anxiety': anxietyCount > 0 ? anxietySum / anxietyCount : 3.0,
      'avoidance': avoidanceCount > 0 ? avoidanceSum / avoidanceCount : 3.0,
    };
  }

  // Get follow-up questions based on provisional attachment style
  static List<PersonalityQuestion> getFollowUpQuestions(
    Map<String, double> provisionalScores, {
    int maxFollowUps = 2,
  }) {
    final anxiety = provisionalScores['anxiety'] ?? 3.0;
    final avoidance = provisionalScores['avoidance'] ?? 3.0;

    List<PersonalityQuestion> followUps = [];

    // Branching logic based on provisional scores (3.5 cutoff)
    if (anxiety >= 3.5 && avoidance < 3.5) {
      // High anxiety, low avoidance → Anxious pattern
      followUps.addAll(_getRandomFromList(anxiousProbes, maxFollowUps));
    } else if (avoidance >= 3.5 && anxiety < 3.5) {
      // High avoidance, low anxiety → Avoidant pattern
      followUps.addAll(_getRandomFromList(avoidantProbes, maxFollowUps));
    } else if (anxiety >= 3.5 && avoidance >= 3.5) {
      // High both → Disorganized pattern
      followUps.addAll(_getRandomFromList(disorganizedProbes, maxFollowUps));
    } else {
      // Low both → Secure pattern (show reversed secure probes to confirm)
      followUps.addAll(_getRandomFromList(secureProbes, maxFollowUps));
    }

    return followUps;
  }

  // Helper: Check if question is from probe lists (for weighting)
  static bool _isProbeQuestion(PersonalityQuestion question) {
    return anxiousProbes.contains(question) ||
        avoidantProbes.contains(question) ||
        disorganizedProbes.contains(question) ||
        secureProbes.contains(question);
  }

  // Helper: Get random questions from a list
  static List<PersonalityQuestion> _getRandomFromList(
    List<PersonalityQuestion> sourceList,
    int count,
  ) {
    final shuffled = List<PersonalityQuestion>.from(sourceList)
      ..shuffle(_random);
    return shuffled.take(count).toList();
  }

  // Enhanced dimensional calculation with probe weighting
  static Map<String, double> calculateDimensionalScoresWithWeighting(
    List<String> answers,
    List<PersonalityQuestion> questions,
  ) {
    double anxietySum = 0;
    double avoidanceSum = 0;
    int anxietyCount = 0;
    int avoidanceCount = 0;

    for (int i = 0; i < answers.length && i < questions.length; i++) {
      final question = questions[i];

      // Skip goal profiling questions
      if (question.isGoalQuestion) continue;

      final answer = answers[i];
      final option = question.options.firstWhere(
        (opt) => opt.text == answer,
        orElse: () => question.options.first,
      );

      if (option.anxietyScore != null) {
        double score = option.anxietyScore!.toDouble();
        if (question.isReversed) score = 6 - score;

        // Apply 1.15x weighting for probe questions
        if (_isProbeQuestion(question)) {
          score *= 1.15;
        }

        anxietySum += score;
        anxietyCount++;
      }

      if (option.avoidanceScore != null) {
        double score = option.avoidanceScore!.toDouble();
        if (question.isReversed) score = 6 - score;

        // Apply 1.15x weighting for probe questions
        if (_isProbeQuestion(question)) {
          score *= 1.15;
        }

        avoidanceSum += score;
        avoidanceCount++;
      }
    }

    return {
      'anxiety': anxietyCount > 0 ? anxietySum / anxietyCount : 3.0,
      'avoidance': avoidanceCount > 0 ? avoidanceSum / avoidanceCount : 3.0,
      'disorganized': 0.0, // Will be calculated based on anxiety + avoidance
    };
  }
}

// ADAPTIVE FLOW MANAGER
// Complete system for 6-8 item quick assessment with smart branching
//
// USAGE EXAMPLE:
// ```dart
// final flow = AdaptivePersonalityFlow();
//
// // Get questions one by one
// while (true) {
//   final question = flow.getNextQuestion();
//   if (question == null) break;
//
//   // Show question to user and get answer
//   final answer = await showQuestionToUser(question);
//   flow.addAnswer(answer);
//
//   // Check progress
//   final progress = flow.getProgress();
//   print('Question ${progress['current_question']} of ${progress['total_questions']}');
// }
//
// // Get final results with attachment style and goal profiling
// final results = flow.getFinalResults();
// final attachmentStyle = results['attachment_style'];
// final goalTypes = results['goal_types'];
// ```
class AdaptivePersonalityFlow {
  final List<PersonalityQuestion> _allQuestions = [];
  final List<String> _answers = [];
  bool _isComplete = false;

  AdaptivePersonalityFlow() {
    _initializeFlow();
  }

  void _initializeFlow() {
    // Start with goal questions (10 items)
    final goalQuestions = improvedPersonalityQuestions
        .where((q) => q.isGoalQuestion)
        .toList();
    _allQuestions.addAll(goalQuestions);

    // Add initial screening probes (4 items - one from each style)
    _allQuestions.addAll(PersonalityTest._getInitialProbes());
  }

  // Get next question to show
  PersonalityQuestion? getNextQuestion() {
    if (_answers.length >= _allQuestions.length) {
      if (!_isComplete && _shouldAddFollowUps()) {
        _addFollowUpQuestions();
      } else {
        _isComplete = true;
        return null;
      }
    }

    if (_answers.length < _allQuestions.length) {
      return _allQuestions[_answers.length];
    }

    return null;
  }

  // Add answer and potentially trigger branching
  void addAnswer(String answer) {
    if (_answers.length < _allQuestions.length) {
      _answers.add(answer);
    }
  }

  // Check if we should add follow-up questions after initial probes
  bool _shouldAddFollowUps() {
    // Add follow-ups after goal questions + initial 4 probes (14 questions total)
    final goalCount = improvedPersonalityQuestions
        .where((q) => q.isGoalQuestion)
        .length;
    return _answers.length >= goalCount + 4 &&
        _allQuestions.length <= goalCount + 4;
  }

  // Add targeted follow-up questions based on attachment patterns
  void _addFollowUpQuestions() {
    // Calculate provisional scores from attachment questions only
    final attachmentQuestions = _allQuestions
        .where((q) => !q.isGoalQuestion)
        .toList();
    final attachmentAnswers = _answers
        .skip(
          improvedPersonalityQuestions.where((q) => q.isGoalQuestion).length,
        )
        .toList();

    final provisionalScores = PersonalityTest.calculateProvisionalScores(
      attachmentAnswers,
      attachmentQuestions,
    );

    // Get 2-3 targeted follow-ups based on highest pattern
    final followUps = PersonalityTest.getFollowUpQuestions(
      provisionalScores,
      maxFollowUps: 3,
    );

    _allQuestions.addAll(followUps);
  }

  // Get final results with full weighting
  Map<String, dynamic> getFinalResults() {
    if (!_isComplete) return {};

    final dimensionalScores =
        PersonalityTest.calculateDimensionalScoresWithWeighting(
          _answers,
          _allQuestions,
        );

    final attachmentStyle = inferAttachmentStyle(dimensionalScores);

    // Extract goal profile types from answers
    final goalTypes = <String>[];
    final goalQuestions = _allQuestions.where((q) => q.isGoalQuestion).toList();

    for (int i = 0; i < goalQuestions.length && i < _answers.length; i++) {
      final question = goalQuestions[i];
      final answer = _answers[i];
      final option = question.options.firstWhere(
        (opt) => opt.text == answer,
        orElse: () => question.options.first,
      );

      if (option.type != null) {
        goalTypes.add(option.type!);
      }
    }

    return {
      'attachment_style': attachmentStyle,
      'dimensional_scores': dimensionalScores,
      'goal_types': goalTypes,
      'total_questions': _allQuestions.length,
      'answers': List.from(_answers),
    };
  }

  // Get progress information
  Map<String, dynamic> getProgress() {
    return {
      'current_question': _answers.length + 1,
      'total_questions': _allQuestions.length,
      'is_complete': _isComplete,
      'in_follow_up_phase': _answers.length > 14, // After goal + initial probes
    };
  }
}

// Infer attachment style from dimensional scores
AttachmentStyle inferAttachmentStyle(Map<String, double> dimensions) {
  final anxiety = dimensions['anxiety'] ?? 3.0;
  final avoidance = dimensions['avoidance'] ?? 3.0;

  // Cutoffs based on research (3.5 on a 1-5 scale)
  final highAnxiety = anxiety >= 3.5;
  final highAvoidance = avoidance >= 3.5;

  if (highAnxiety && highAvoidance) {
    return AttachmentStyle.disorganized;
  } else if (highAnxiety && !highAvoidance) {
    return AttachmentStyle.anxious;
  } else if (!highAnxiety && highAvoidance) {
    return AttachmentStyle.avoidant;
  } else {
    return AttachmentStyle.secure;
  }
}

const List<PersonalityQuestion> improvedPersonalityQuestions = [
  // ========================================
  // GOAL PROFILING QUESTIONS (1-10)
  // These determine weight multiplier profiles
  // ========================================
  PersonalityQuestion(
    question:
        "What's your main goal in using tone and attachment analysis right now?",
    isGoalQuestion: true,
    options: [
      PersonalityQuestionOption(
        text: "New connection or dating",
        type: "dating_sensitive",
      ),
      PersonalityQuestionOption(
        text: "Repairing or deepening an existing relationship",
        type: "empathetic_mirror",
      ),
      PersonalityQuestionOption(
        text: "Staying consistent and becoming more secure",
        type: "secure_training",
      ),
      PersonalityQuestionOption(
        text: "Managing co-parenting communication",
        type: "coparenting_support",
      ),
      PersonalityQuestionOption(
        text: "Getting through tough conversations better",
        type: "boundary_forward",
      ),
    ],
  ),

  PersonalityQuestion(
    question:
        "Do you find yourself feeling emotionally distant or disconnected in your current relationship?",
    isGoalQuestion: true,
    options: [
      PersonalityQuestionOption(text: "Yes, often", type: "dating_sensitive"),
      PersonalityQuestionOption(text: "Sometimes", type: "empathetic_mirror"),
      PersonalityQuestionOption(text: "Rarely", type: "secure_training"),
      PersonalityQuestionOption(
        text: "No, not at all",
        type: "empathetic_mirror",
      ),
    ],
  ),

  PersonalityQuestion(
    question:
        "Do you tend to avoid conflict or shut down during difficult conversations?",
    isGoalQuestion: true,
    options: [
      PersonalityQuestionOption(
        text: "Yes, I always avoid conflict",
        type: "deescalator",
      ),
      PersonalityQuestionOption(
        text: "I often shut down",
        type: "coparenting_support",
      ),
      PersonalityQuestionOption(
        text: "Sometimes I avoid it",
        type: "empathetic_mirror",
      ),
      PersonalityQuestionOption(
        text: "No, I engage with difficult conversations",
        type: "boundary_forward",
      ),
    ],
  ),

  PersonalityQuestion(
    question:
        "Are you often the one trying to repair or bring things back together after conflict?",
    isGoalQuestion: true,
    options: [
      PersonalityQuestionOption(
        text: "Yes, always me",
        type: "empathetic_mirror",
      ),
      PersonalityQuestionOption(text: "Usually me", type: "empathetic_mirror"),
      PersonalityQuestionOption(text: "Sometimes", type: "empathetic_mirror"),
      PersonalityQuestionOption(
        text: "No, we both work on it",
        type: "secure_training",
      ),
    ],
  ),

  PersonalityQuestion(
    question:
        "Are you currently trying to build a connection with someone new?",
    isGoalQuestion: true,
    options: [
      PersonalityQuestionOption(
        text: "Yes, actively dating",
        type: "dating_sensitive",
      ),
      PersonalityQuestionOption(
        text: "Yes, new relationship",
        type: "dating_sensitive",
      ),
      PersonalityQuestionOption(
        text: "No, focusing on existing relationships",
        type: "empathetic_mirror",
      ),
      PersonalityQuestionOption(
        text: "No, single and not dating",
        type: "secure_training",
      ),
    ],
  ),

  PersonalityQuestion(
    question:
        "Do you want to focus on how to express your emotions more clearly and vulnerably?",
    isGoalQuestion: true,
    options: [
      PersonalityQuestionOption(
        text: "Yes, definitely",
        type: "empathetic_mirror",
      ),
      PersonalityQuestionOption(
        text: "Yes, somewhat",
        type: "empathetic_mirror",
      ),
      PersonalityQuestionOption(text: "Maybe", type: "empathetic_mirror"),
      PersonalityQuestionOption(
        text: "No, I'm comfortable with my expression",
        type: "secure_training",
      ),
    ],
  ),

  PersonalityQuestion(
    question:
        "Are you navigating a challenging topic right now (like boundaries, needs, or big changes)?",
    isGoalQuestion: true,
    options: [
      PersonalityQuestionOption(
        text: "Yes, very challenging topics",
        type: "boundary_forward",
      ),
      PersonalityQuestionOption(
        text: "Yes, some difficult conversations",
        type: "deescalator",
      ),
      PersonalityQuestionOption(
        text: "Maybe some smaller issues",
        type: "empathetic_mirror",
      ),
      PersonalityQuestionOption(
        text: "No, things are stable",
        type: "secure_training",
      ),
    ],
  ),

  PersonalityQuestion(
    question:
        "Is your co-parenting communication more about logistics or emotional conflict?",
    isGoalQuestion: true,
    options: [
      PersonalityQuestionOption(
        text: "Mostly logistics",
        type: "coparenting_support",
      ),
      PersonalityQuestionOption(
        text: "Mix of both",
        type: "coparenting_support",
      ),
      PersonalityQuestionOption(
        text: "Mostly emotional conflict",
        type: "empathetic_mirror",
      ),
      PersonalityQuestionOption(
        text: "Not applicable - no co-parenting",
        type: "empathetic_mirror",
      ),
    ],
  ),

  PersonalityQuestion(
    question:
        "Would you prefer gentle daily check-ins to help regulate tone, even in casual texts?",
    isGoalQuestion: true,
    options: [
      PersonalityQuestionOption(
        text: "Yes, that sounds helpful",
        type: "balanced",
      ),
      PersonalityQuestionOption(
        text: "Maybe occasionally",
        type: "secure_training",
      ),
      PersonalityQuestionOption(
        text: "Not really needed",
        type: "empathetic_mirror",
      ),
      PersonalityQuestionOption(
        text: "No, I prefer minimal intervention",
        type: "deescalator",
      ),
    ],
  ),

  PersonalityQuestion(
    question:
        "Would you describe your tone goal as: more clarity, more warmth, or more calm?",
    isGoalQuestion: true,
    options: [
      PersonalityQuestionOption(text: "More clarity", type: "boundary_forward"),
      PersonalityQuestionOption(text: "More warmth", type: "dating_sensitive"),
      PersonalityQuestionOption(text: "More calm", type: "secure_training"),
      PersonalityQuestionOption(
        text: "All of the above",
        type: "empathetic_mirror",
      ),
    ],
  ),

  // ========================================
  // ATTACHMENT STYLE QUESTIONS (11+)
  // Scored on anxiety and avoidance dimensions
  // ========================================

  // ANXIETY DIMENSION QUESTIONS
  PersonalityQuestion(
    question:
        "I worry about being abandoned or rejected in close relationships.",
    options: [
      PersonalityQuestionOption(
        text: "Strongly Disagree",
        anxietyScore: 1,
        avoidanceScore: 1,
      ),
      PersonalityQuestionOption(
        text: "Disagree",
        anxietyScore: 2,
        avoidanceScore: 2,
      ),
      PersonalityQuestionOption(
        text: "Neutral",
        anxietyScore: 3,
        avoidanceScore: 3,
      ),
      PersonalityQuestionOption(
        text: "Agree",
        anxietyScore: 4,
        avoidanceScore: 3,
      ),
      PersonalityQuestionOption(
        text: "Strongly Agree",
        anxietyScore: 5,
        avoidanceScore: 3,
      ),
    ],
  ),

  PersonalityQuestion(
    question: "I often worry that my partner doesn't really care about me.",
    options: [
      PersonalityQuestionOption(
        text: "Strongly Disagree",
        anxietyScore: 1,
        avoidanceScore: 3,
      ),
      PersonalityQuestionOption(
        text: "Disagree",
        anxietyScore: 2,
        avoidanceScore: 3,
      ),
      PersonalityQuestionOption(
        text: "Neutral",
        anxietyScore: 3,
        avoidanceScore: 3,
      ),
      PersonalityQuestionOption(
        text: "Agree",
        anxietyScore: 4,
        avoidanceScore: 3,
      ),
      PersonalityQuestionOption(
        text: "Strongly Agree",
        anxietyScore: 5,
        avoidanceScore: 3,
      ),
    ],
  ),

  PersonalityQuestion(
    question: "I need a lot of reassurance from my partner.",
    options: [
      PersonalityQuestionOption(
        text: "Strongly Disagree",
        anxietyScore: 1,
        avoidanceScore: 4,
      ),
      PersonalityQuestionOption(
        text: "Disagree",
        anxietyScore: 2,
        avoidanceScore: 3,
      ),
      PersonalityQuestionOption(
        text: "Neutral",
        anxietyScore: 3,
        avoidanceScore: 3,
      ),
      PersonalityQuestionOption(
        text: "Agree",
        anxietyScore: 4,
        avoidanceScore: 2,
      ),
      PersonalityQuestionOption(
        text: "Strongly Agree",
        anxietyScore: 5,
        avoidanceScore: 1,
      ),
    ],
  ),

  PersonalityQuestion(
    question: "I feel secure in my relationships.", // REVERSED
    isReversed: true,
    options: [
      PersonalityQuestionOption(
        text: "Strongly Disagree",
        anxietyScore: 5,
        avoidanceScore: 4,
      ),
      PersonalityQuestionOption(
        text: "Disagree",
        anxietyScore: 4,
        avoidanceScore: 4,
      ),
      PersonalityQuestionOption(
        text: "Neutral",
        anxietyScore: 3,
        avoidanceScore: 3,
      ),
      PersonalityQuestionOption(
        text: "Agree",
        anxietyScore: 2,
        avoidanceScore: 2,
      ),
      PersonalityQuestionOption(
        text: "Strongly Agree",
        anxietyScore: 1,
        avoidanceScore: 1,
      ),
    ],
  ),

  PersonalityQuestion(
    question: "I find it easy to depend on romantic partners.", // REVERSED
    isReversed: true,
    options: [
      PersonalityQuestionOption(
        text: "Strongly Disagree",
        anxietyScore: 4,
        avoidanceScore: 5,
      ),
      PersonalityQuestionOption(
        text: "Disagree",
        anxietyScore: 3,
        avoidanceScore: 4,
      ),
      PersonalityQuestionOption(
        text: "Neutral",
        anxietyScore: 3,
        avoidanceScore: 3,
      ),
      PersonalityQuestionOption(
        text: "Agree",
        anxietyScore: 2,
        avoidanceScore: 2,
      ),
      PersonalityQuestionOption(
        text: "Strongly Agree",
        anxietyScore: 1,
        avoidanceScore: 1,
      ),
    ],
  ),

  // AVOIDANCE DIMENSION QUESTIONS
  PersonalityQuestion(
    question: "I prefer not to show how I feel deep down.",
    options: [
      PersonalityQuestionOption(
        text: "Strongly Disagree",
        anxietyScore: 2,
        avoidanceScore: 1,
      ),
      PersonalityQuestionOption(
        text: "Disagree",
        anxietyScore: 2,
        avoidanceScore: 2,
      ),
      PersonalityQuestionOption(
        text: "Neutral",
        anxietyScore: 3,
        avoidanceScore: 3,
      ),
      PersonalityQuestionOption(
        text: "Agree",
        anxietyScore: 3,
        avoidanceScore: 4,
      ),
      PersonalityQuestionOption(
        text: "Strongly Agree",
        anxietyScore: 3,
        avoidanceScore: 5,
      ),
    ],
  ),

  PersonalityQuestion(
    question: "I find it difficult to depend on my partners.",
    options: [
      PersonalityQuestionOption(
        text: "Strongly Disagree",
        anxietyScore: 2,
        avoidanceScore: 1,
      ),
      PersonalityQuestionOption(
        text: "Disagree",
        anxietyScore: 2,
        avoidanceScore: 2,
      ),
      PersonalityQuestionOption(
        text: "Neutral",
        anxietyScore: 3,
        avoidanceScore: 3,
      ),
      PersonalityQuestionOption(
        text: "Agree",
        anxietyScore: 3,
        avoidanceScore: 4,
      ),
      PersonalityQuestionOption(
        text: "Strongly Agree",
        anxietyScore: 3,
        avoidanceScore: 5,
      ),
    ],
  ),

  PersonalityQuestion(
    question: "I don't feel comfortable opening up.",
    options: [
      PersonalityQuestionOption(
        text: "Strongly Disagree",
        anxietyScore: 2,
        avoidanceScore: 1,
      ),
      PersonalityQuestionOption(
        text: "Disagree",
        anxietyScore: 2,
        avoidanceScore: 2,
      ),
      PersonalityQuestionOption(
        text: "Neutral",
        anxietyScore: 3,
        avoidanceScore: 3,
      ),
      PersonalityQuestionOption(
        text: "Agree",
        anxietyScore: 3,
        avoidanceScore: 4,
      ),
      PersonalityQuestionOption(
        text: "Strongly Agree",
        anxietyScore: 3,
        avoidanceScore: 5,
      ),
    ],
  ),

  PersonalityQuestion(
    question: "I prefer not to have others depend on me.",
    options: [
      PersonalityQuestionOption(
        text: "Strongly Disagree",
        anxietyScore: 2,
        avoidanceScore: 1,
      ),
      PersonalityQuestionOption(
        text: "Disagree",
        anxietyScore: 2,
        avoidanceScore: 2,
      ),
      PersonalityQuestionOption(
        text: "Neutral",
        anxietyScore: 3,
        avoidanceScore: 3,
      ),
      PersonalityQuestionOption(
        text: "Agree",
        anxietyScore: 3,
        avoidanceScore: 4,
      ),
      PersonalityQuestionOption(
        text: "Strongly Agree",
        anxietyScore: 3,
        avoidanceScore: 5,
      ),
    ],
  ),

  PersonalityQuestion(
    question: "I find it easy to express my feelings.", // REVERSED
    isReversed: true,
    options: [
      PersonalityQuestionOption(
        text: "Strongly Disagree",
        anxietyScore: 3,
        avoidanceScore: 5,
      ),
      PersonalityQuestionOption(
        text: "Disagree",
        anxietyScore: 3,
        avoidanceScore: 4,
      ),
      PersonalityQuestionOption(
        text: "Neutral",
        anxietyScore: 3,
        avoidanceScore: 3,
      ),
      PersonalityQuestionOption(
        text: "Agree",
        anxietyScore: 2,
        avoidanceScore: 2,
      ),
      PersonalityQuestionOption(
        text: "Strongly Agree",
        anxietyScore: 1,
        avoidanceScore: 1,
      ),
    ],
  ),

  // DISORGANIZED-SPECIFIC QUESTIONS
  PersonalityQuestion(
    question: "I want to be very close to my partner but also fear intimacy.",
    options: [
      PersonalityQuestionOption(
        text: "Strongly Disagree",
        anxietyScore: 1,
        avoidanceScore: 2,
      ),
      PersonalityQuestionOption(
        text: "Disagree",
        anxietyScore: 2,
        avoidanceScore: 2,
      ),
      PersonalityQuestionOption(
        text: "Neutral",
        anxietyScore: 3,
        avoidanceScore: 3,
      ),
      PersonalityQuestionOption(
        text: "Agree",
        anxietyScore: 4,
        avoidanceScore: 4,
      ),
      PersonalityQuestionOption(
        text: "Strongly Agree",
        anxietyScore: 5,
        avoidanceScore: 5,
      ),
    ],
  ),

  PersonalityQuestion(
    question: "My feelings about romantic relationships seem contradictory.",
    options: [
      PersonalityQuestionOption(
        text: "Strongly Disagree",
        anxietyScore: 1,
        avoidanceScore: 1,
      ),
      PersonalityQuestionOption(
        text: "Disagree",
        anxietyScore: 2,
        avoidanceScore: 2,
      ),
      PersonalityQuestionOption(
        text: "Neutral",
        anxietyScore: 3,
        avoidanceScore: 3,
      ),
      PersonalityQuestionOption(
        text: "Agree",
        anxietyScore: 4,
        avoidanceScore: 4,
      ),
      PersonalityQuestionOption(
        text: "Strongly Agree",
        anxietyScore: 5,
        avoidanceScore: 5,
      ),
    ],
  ),

  PersonalityQuestion(
    question: "I sometimes send mixed signals about how close I want to be.",
    options: [
      PersonalityQuestionOption(
        text: "Strongly Disagree",
        anxietyScore: 1,
        avoidanceScore: 1,
      ),
      PersonalityQuestionOption(
        text: "Disagree",
        anxietyScore: 2,
        avoidanceScore: 2,
      ),
      PersonalityQuestionOption(
        text: "Neutral",
        anxietyScore: 3,
        avoidanceScore: 3,
      ),
      PersonalityQuestionOption(
        text: "Agree",
        anxietyScore: 4,
        avoidanceScore: 4,
      ),
      PersonalityQuestionOption(
        text: "Strongly Agree",
        anxietyScore: 5,
        avoidanceScore: 5,
      ),
    ],
  ),

  // ADDITIONAL DATING CONTEXT QUESTIONS
  PersonalityQuestion(
    question:
        "When someone I'm dating takes a while to text back, I assume something is wrong.",
    options: [
      PersonalityQuestionOption(
        text: "Strongly Disagree",
        anxietyScore: 1,
        avoidanceScore: 3,
      ),
      PersonalityQuestionOption(
        text: "Disagree",
        anxietyScore: 2,
        avoidanceScore: 3,
      ),
      PersonalityQuestionOption(
        text: "Neutral",
        anxietyScore: 3,
        avoidanceScore: 3,
      ),
      PersonalityQuestionOption(
        text: "Agree",
        anxietyScore: 4,
        avoidanceScore: 3,
      ),
      PersonalityQuestionOption(
        text: "Strongly Agree",
        anxietyScore: 5,
        avoidanceScore: 3,
      ),
    ],
  ),

  PersonalityQuestion(
    question:
        "I'm comfortable expressing interest when I'm attracted to someone.", // REVERSED
    isReversed: true,
    options: [
      PersonalityQuestionOption(
        text: "Strongly Disagree",
        anxietyScore: 4,
        avoidanceScore: 5,
      ),
      PersonalityQuestionOption(
        text: "Disagree",
        anxietyScore: 3,
        avoidanceScore: 4,
      ),
      PersonalityQuestionOption(
        text: "Neutral",
        anxietyScore: 3,
        avoidanceScore: 3,
      ),
      PersonalityQuestionOption(
        text: "Agree",
        anxietyScore: 2,
        avoidanceScore: 2,
      ),
      PersonalityQuestionOption(
        text: "Strongly Agree",
        anxietyScore: 1,
        avoidanceScore: 1,
      ),
    ],
  ),

  PersonalityQuestion(
    question:
        "When dating gets more serious, I start to worry they'll lose interest.",
    options: [
      PersonalityQuestionOption(
        text: "Strongly Disagree",
        anxietyScore: 1,
        avoidanceScore: 3,
      ),
      PersonalityQuestionOption(
        text: "Disagree",
        anxietyScore: 2,
        avoidanceScore: 3,
      ),
      PersonalityQuestionOption(
        text: "Neutral",
        anxietyScore: 3,
        avoidanceScore: 3,
      ),
      PersonalityQuestionOption(
        text: "Agree",
        anxietyScore: 4,
        avoidanceScore: 3,
      ),
      PersonalityQuestionOption(
        text: "Strongly Agree",
        anxietyScore: 5,
        avoidanceScore: 3,
      ),
    ],
  ),

  PersonalityQuestion(
    question:
        "I find it easy to be emotionally close to romantic partners.", // REVERSED
    isReversed: true,
    options: [
      PersonalityQuestionOption(
        text: "Strongly Disagree",
        anxietyScore: 3,
        avoidanceScore: 5,
      ),
      PersonalityQuestionOption(
        text: "Disagree",
        anxietyScore: 3,
        avoidanceScore: 4,
      ),
      PersonalityQuestionOption(
        text: "Neutral",
        anxietyScore: 3,
        avoidanceScore: 3,
      ),
      PersonalityQuestionOption(
        text: "Agree",
        anxietyScore: 2,
        avoidanceScore: 2,
      ),
      PersonalityQuestionOption(
        text: "Strongly Agree",
        anxietyScore: 1,
        avoidanceScore: 1,
      ),
    ],
  ),

  PersonalityQuestion(
    question: "I worry about being alone more than losing my independence.",
    options: [
      PersonalityQuestionOption(
        text: "Strongly Disagree",
        anxietyScore: 1,
        avoidanceScore: 5,
      ),
      PersonalityQuestionOption(
        text: "Disagree",
        anxietyScore: 2,
        avoidanceScore: 4,
      ),
      PersonalityQuestionOption(
        text: "Neutral",
        anxietyScore: 3,
        avoidanceScore: 3,
      ),
      PersonalityQuestionOption(
        text: "Agree",
        anxietyScore: 4,
        avoidanceScore: 2,
      ),
      PersonalityQuestionOption(
        text: "Strongly Agree",
        anxietyScore: 5,
        avoidanceScore: 1,
      ),
    ],
  ),

  PersonalityQuestion(
    question: "It's easy for me to trust new romantic partners.", // REVERSED
    isReversed: true,
    options: [
      PersonalityQuestionOption(
        text: "Strongly Disagree",
        anxietyScore: 5,
        avoidanceScore: 4,
      ),
      PersonalityQuestionOption(
        text: "Disagree",
        anxietyScore: 4,
        avoidanceScore: 3,
      ),
      PersonalityQuestionOption(
        text: "Neutral",
        anxietyScore: 3,
        avoidanceScore: 3,
      ),
      PersonalityQuestionOption(
        text: "Agree",
        anxietyScore: 2,
        avoidanceScore: 2,
      ),
      PersonalityQuestionOption(
        text: "Strongly Agree",
        anxietyScore: 1,
        avoidanceScore: 1,
      ),
    ],
  ),

  PersonalityQuestion(
    question: "I get frustrated when romantic partners want to be very close.",
    options: [
      PersonalityQuestionOption(
        text: "Strongly Disagree",
        anxietyScore: 2,
        avoidanceScore: 1,
      ),
      PersonalityQuestionOption(
        text: "Disagree",
        anxietyScore: 2,
        avoidanceScore: 2,
      ),
      PersonalityQuestionOption(
        text: "Neutral",
        anxietyScore: 3,
        avoidanceScore: 3,
      ),
      PersonalityQuestionOption(
        text: "Agree",
        anxietyScore: 3,
        avoidanceScore: 4,
      ),
      PersonalityQuestionOption(
        text: "Strongly Agree",
        anxietyScore: 3,
        avoidanceScore: 5,
      ),
    ],
  ),
];

// ========================================
// HIGH-SIGNAL ATTACHMENT STYLE PROBES
// Short, punchy scenario questions that strongly separate the four styles
// Use for quick branching assessment and diagnostic clarity
// ========================================

// ANXIOUS PROBES - High anxiety scenarios
const List<PersonalityQuestion> anxiousProbes = [
  PersonalityQuestion(
    question:
        "You sense your partner is quieter than usual today. What's your first move?",
    options: [
      PersonalityQuestionOption(
        text: "Assume they're busy and carry on.",
        anxietyScore: 1,
        avoidanceScore: 2,
      ),
      PersonalityQuestionOption(
        text: "Check in once later.",
        anxietyScore: 2,
        avoidanceScore: 2,
      ),
      PersonalityQuestionOption(
        text: "Ruminate a bit, try to wait.",
        anxietyScore: 3,
        avoidanceScore: 3,
      ),
      PersonalityQuestionOption(
        text: "Send a long message asking if we're okay.",
        anxietyScore: 4,
        avoidanceScore: 2,
      ),
      PersonalityQuestionOption(
        text: "I feel panicky and need fast reassurance now.",
        anxietyScore: 5,
        avoidanceScore: 1,
      ),
    ],
  ),

  PersonalityQuestion(
    question: "Texts slow down for a day after a great weekend together.",
    options: [
      PersonalityQuestionOption(
        text: "Normal ebb/flow — no story made.",
        anxietyScore: 1,
        avoidanceScore: 2,
      ),
      PersonalityQuestionOption(
        text: "Notice it and check my assumptions.",
        anxietyScore: 2,
        avoidanceScore: 2,
      ),
      PersonalityQuestionOption(
        text: "Feel uneasy and reread messages.",
        anxietyScore: 3,
        avoidanceScore: 3,
      ),
      PersonalityQuestionOption(
        text: "Ask if I did something wrong.",
        anxietyScore: 4,
        avoidanceScore: 2,
      ),
      PersonalityQuestionOption(
        text: "Assume they're losing interest and spiral.",
        anxietyScore: 5,
        avoidanceScore: 2,
      ),
    ],
  ),

  PersonalityQuestion(
    question:
        "Your partner needs a few hours alone before talking about a tense moment.",
    options: [
      PersonalityQuestionOption(
        text: "Great — we'll talk when ready.",
        anxietyScore: 1,
        avoidanceScore: 1,
      ),
      PersonalityQuestionOption(
        text: "Okay — I set a time to reconnect.",
        anxietyScore: 2,
        avoidanceScore: 2,
      ),
      PersonalityQuestionOption(
        text: "I'm edgy waiting but will try.",
        anxietyScore: 3,
        avoidanceScore: 2,
      ),
      PersonalityQuestionOption(
        text: "Breaks make me feel abandoned.",
        anxietyScore: 5,
        avoidanceScore: 2,
      ),
      PersonalityQuestionOption(
        text: "I send multiple check-ins while I wait.",
        anxietyScore: 4,
        avoidanceScore: 2,
      ),
    ],
  ),

  PersonalityQuestion(
    question: "They don't reply overnight after a minor disagreement.",
    options: [
      PersonalityQuestionOption(
        text: "Assume sleep won — pick up tomorrow.",
        anxietyScore: 1,
        avoidanceScore: 2,
      ),
      PersonalityQuestionOption(
        text: "I'm a little tense; I'll reconnect in the morning.",
        anxietyScore: 2,
        avoidanceScore: 2,
      ),
      PersonalityQuestionOption(
        text: "I replay the convo in my head.",
        anxietyScore: 3,
        avoidanceScore: 3,
      ),
      PersonalityQuestionOption(
        text: "I send an 'are we okay?' at 1am.",
        anxietyScore: 4,
        avoidanceScore: 2,
      ),
      PersonalityQuestionOption(
        text: "I can't sleep until they reassure me.",
        anxietyScore: 5,
        avoidanceScore: 1,
      ),
    ],
  ),
];

// AVOIDANT PROBES - High avoidance scenarios
const List<PersonalityQuestion> avoidantProbes = [
  PersonalityQuestion(
    question: "Your partner asks for a deeper talk about feelings tonight.",
    options: [
      PersonalityQuestionOption(
        text: "I'm in — I can do emotional depth.",
        anxietyScore: 1,
        avoidanceScore: 1,
      ),
      PersonalityQuestionOption(
        text: "Sure — can we keep it focused?",
        anxietyScore: 2,
        avoidanceScore: 2,
      ),
      PersonalityQuestionOption(
        text: "Maybe later this week.",
        anxietyScore: 2,
        avoidanceScore: 3,
      ),
      PersonalityQuestionOption(
        text: "I suggest changing topics.",
        anxietyScore: 2,
        avoidanceScore: 4,
      ),
      PersonalityQuestionOption(
        text: "I avoid — this kind of talk drains me.",
        anxietyScore: 2,
        avoidanceScore: 5,
      ),
    ],
  ),

  PersonalityQuestion(
    question:
        "After a really connected day, they want to spend the next day together too.",
    options: [
      PersonalityQuestionOption(
        text: "Sounds nice — I'm good with it.",
        anxietyScore: 1,
        avoidanceScore: 1,
      ),
      PersonalityQuestionOption(
        text: "Maybe half the day; balance is good.",
        anxietyScore: 2,
        avoidanceScore: 2,
      ),
      PersonalityQuestionOption(
        text: "I need solo time first.",
        anxietyScore: 2,
        avoidanceScore: 3,
      ),
      PersonalityQuestionOption(
        text: "I feel crowded and pull back.",
        anxietyScore: 2,
        avoidanceScore: 4,
      ),
      PersonalityQuestionOption(
        text: "I shut down or ghost for space.",
        anxietyScore: 2,
        avoidanceScore: 5,
      ),
    ],
  ),

  PersonalityQuestion(
    question: "They ask, \"What do you need from me this week?\"",
    options: [
      PersonalityQuestionOption(
        text: "I share clearly — it helps us.",
        anxietyScore: 1,
        avoidanceScore: 1,
      ),
      PersonalityQuestionOption(
        text: "I name one or two things.",
        anxietyScore: 2,
        avoidanceScore: 2,
      ),
      PersonalityQuestionOption(
        text: "I downplay my needs.",
        anxietyScore: 2,
        avoidanceScore: 4,
      ),
      PersonalityQuestionOption(
        text: "I joke or deflect; feels uncomfortable.",
        anxietyScore: 2,
        avoidanceScore: 4,
      ),
      PersonalityQuestionOption(
        text: "I say \"nothing\" and change the subject.",
        anxietyScore: 2,
        avoidanceScore: 5,
      ),
    ],
  ),

  PersonalityQuestion(
    question: "Conflict starts to heat up.",
    options: [
      PersonalityQuestionOption(
        text: "I stay present and slow it down.",
        anxietyScore: 1,
        avoidanceScore: 1,
      ),
      PersonalityQuestionOption(
        text: "I ask for a short, timed break.",
        anxietyScore: 2,
        avoidanceScore: 2,
      ),
      PersonalityQuestionOption(
        text: "I get quiet and answer minimally.",
        anxietyScore: 2,
        avoidanceScore: 4,
      ),
      PersonalityQuestionOption(
        text: "I redirect to logistics, not feelings.",
        anxietyScore: 2,
        avoidanceScore: 4,
      ),
      PersonalityQuestionOption(
        text: "I disengage — \"let's just drop it.\"",
        anxietyScore: 2,
        avoidanceScore: 5,
      ),
    ],
  ),
];

// DISORGANIZED (FEARFUL-AVOIDANT) PROBES - High anxiety + high avoidance
const List<PersonalityQuestion> disorganizedProbes = [
  PersonalityQuestion(
    question:
        "You feel both a strong pull for closeness and a fear of being hurt.",
    options: [
      PersonalityQuestionOption(
        text: "I can want closeness and stay steady.",
        anxietyScore: 1,
        avoidanceScore: 1,
      ),
      PersonalityQuestionOption(
        text: "I name both feelings and pace it.",
        anxietyScore: 2,
        avoidanceScore: 2,
      ),
      PersonalityQuestionOption(
        text: "I swing between leaning in and backing off.",
        anxietyScore: 4,
        avoidanceScore: 4,
      ),
      PersonalityQuestionOption(
        text: "I cling, then criticize when it feels too close.",
        anxietyScore: 5,
        avoidanceScore: 4,
      ),
      PersonalityQuestionOption(
        text: "I keep them at arm's length, then panic about distance.",
        anxietyScore: 4,
        avoidanceScore: 5,
      ),
    ],
  ),

  PersonalityQuestion(
    question:
        "Your partner offers reassurance — \"I'm here, we're okay.\" Your gut reaction?",
    options: [
      PersonalityQuestionOption(
        text: "I take it in — it lands.",
        anxietyScore: 1,
        avoidanceScore: 1,
      ),
      PersonalityQuestionOption(
        text: "I appreciate it and check in later.",
        anxietyScore: 2,
        avoidanceScore: 2,
      ),
      PersonalityQuestionOption(
        text: "I need it repeated — it fades fast.",
        anxietyScore: 4,
        avoidanceScore: 2,
      ),
      PersonalityQuestionOption(
        text: "I'm suspicious and push them away.",
        anxietyScore: 3,
        avoidanceScore: 5,
      ),
      PersonalityQuestionOption(
        text: "Both — ask for closeness, then doubt it.",
        anxietyScore: 5,
        avoidanceScore: 4,
      ),
    ],
  ),

  PersonalityQuestion(
    question: "They say something slightly off. Hours later you…",
    options: [
      PersonalityQuestionOption(
        text: "Ask directly and repair.",
        anxietyScore: 1,
        avoidanceScore: 1,
      ),
      PersonalityQuestionOption(
        text: "Reflect, then bring it up calmly.",
        anxietyScore: 2,
        avoidanceScore: 2,
      ),
      PersonalityQuestionOption(
        text: "Flip between hurt texts and cold distance.",
        anxietyScore: 5,
        avoidanceScore: 5,
      ),
      PersonalityQuestionOption(
        text: "Act fine, then suddenly unload.",
        anxietyScore: 4,
        avoidanceScore: 4,
      ),
      PersonalityQuestionOption(
        text: "Disengage, then crave closeness at night.",
        anxietyScore: 4,
        avoidanceScore: 5,
      ),
    ],
  ),

  PersonalityQuestion(
    question:
        "A big step is suggested (meet family / combine finances / move).",
    options: [
      PersonalityQuestionOption(
        text: "If it fits, I'm steady and open.",
        anxietyScore: 1,
        avoidanceScore: 1,
      ),
      PersonalityQuestionOption(
        text: "I want it and discuss pacing.",
        anxietyScore: 2,
        avoidanceScore: 2,
      ),
      PersonalityQuestionOption(
        text: "I say yes, then feel trapped.",
        anxietyScore: 4,
        avoidanceScore: 4,
      ),
      PersonalityQuestionOption(
        text: "I panic-agree, then push them away.",
        anxietyScore: 5,
        avoidanceScore: 5,
      ),
      PersonalityQuestionOption(
        text: "I refuse, then fear losing them.",
        anxietyScore: 5,
        avoidanceScore: 4,
      ),
    ],
  ),
];

// SECURE PROBES - Reversed scoring (higher agreement = security)
const List<PersonalityQuestion> secureProbes = [
  PersonalityQuestion(
    question: "When something feels off, I can name it without blaming.",
    isReversed: true,
    options: [
      PersonalityQuestionOption(
        text: "Strongly Disagree",
        anxietyScore: 5,
        avoidanceScore: 5,
      ),
      PersonalityQuestionOption(
        text: "Disagree",
        anxietyScore: 4,
        avoidanceScore: 4,
      ),
      PersonalityQuestionOption(
        text: "Neutral",
        anxietyScore: 3,
        avoidanceScore: 3,
      ),
      PersonalityQuestionOption(
        text: "Agree",
        anxietyScore: 2,
        avoidanceScore: 2,
      ),
      PersonalityQuestionOption(
        text: "Strongly Agree",
        anxietyScore: 1,
        avoidanceScore: 1,
      ),
    ],
  ),

  PersonalityQuestion(
    question:
        "I can take a break during conflict and reliably return to repair.",
    isReversed: true,
    options: [
      PersonalityQuestionOption(
        text: "Strongly Disagree",
        anxietyScore: 5,
        avoidanceScore: 4,
      ),
      PersonalityQuestionOption(
        text: "Disagree",
        anxietyScore: 4,
        avoidanceScore: 4,
      ),
      PersonalityQuestionOption(
        text: "Neutral",
        anxietyScore: 3,
        avoidanceScore: 3,
      ),
      PersonalityQuestionOption(
        text: "Agree",
        anxietyScore: 2,
        avoidanceScore: 2,
      ),
      PersonalityQuestionOption(
        text: "Strongly Agree",
        anxietyScore: 1,
        avoidanceScore: 1,
      ),
    ],
  ),

  PersonalityQuestion(
    question:
        "Closeness and independence both feel possible in this relationship.",
    isReversed: true,
    options: [
      PersonalityQuestionOption(
        text: "Strongly Disagree",
        anxietyScore: 5,
        avoidanceScore: 5,
      ),
      PersonalityQuestionOption(
        text: "Disagree",
        anxietyScore: 4,
        avoidanceScore: 4,
      ),
      PersonalityQuestionOption(
        text: "Neutral",
        anxietyScore: 3,
        avoidanceScore: 3,
      ),
      PersonalityQuestionOption(
        text: "Agree",
        anxietyScore: 2,
        avoidanceScore: 2,
      ),
      PersonalityQuestionOption(
        text: "Strongly Agree",
        anxietyScore: 1,
        avoidanceScore: 1,
      ),
    ],
  ),

  PersonalityQuestion(
    question:
        "When I'm triggered, I can slow down, self-soothe, and reconnect.",
    isReversed: true,
    options: [
      PersonalityQuestionOption(
        text: "Strongly Disagree",
        anxietyScore: 5,
        avoidanceScore: 4,
      ),
      PersonalityQuestionOption(
        text: "Disagree",
        anxietyScore: 4,
        avoidanceScore: 4,
      ),
      PersonalityQuestionOption(
        text: "Neutral",
        anxietyScore: 3,
        avoidanceScore: 3,
      ),
      PersonalityQuestionOption(
        text: "Agree",
        anxietyScore: 2,
        avoidanceScore: 2,
      ),
      PersonalityQuestionOption(
        text: "Strongly Agree",
        anxietyScore: 1,
        avoidanceScore: 1,
      ),
    ],
  ),
];
