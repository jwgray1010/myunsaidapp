// attachment_assessment.dart
// Unsaid - Attachment Screener + Goal Routing (two-track, psychometric-first)
//
// No external deps. Pure Dart, UI-agnostic.
// ------------------------------------------------------------

import 'dart:math';

enum Dimension { anxiety, avoidance, none }

class PersonalityQuestion {
  final String id;
  final String question;
  final bool reversed; // for psychometric scoring
  final Dimension dimension; // anxiety | avoidance | none
  final bool isGoal; // separates routing from scoring
  final bool isAttentionCheck; // for attention validation
  final bool isSocialDesirability;
  final List<PersonalityQuestionOption> options;
  final double weight; // default 1.0; useful for pilots

  const PersonalityQuestion({
    required this.id,
    required this.question,
    this.reversed = false,
    this.dimension = Dimension.none,
    this.isGoal = false,
    this.isAttentionCheck = false,
    this.isSocialDesirability = false,
    this.options = const [],
    this.weight = 1.0,
  });
}

class PersonalityQuestionOption {
  final String text;

  /// Likert 1..5 (Strongly Disagree..Strongly Agree) for psychometric items.
  /// For goal items, still store 1..5 for UX consistency (not used in scoring).
  final int value;

  /// For goal items only: route tags for product/profiles.
  final String? routeTag; // e.g., "dating_sensitive", "boundary_forward"
  const PersonalityQuestionOption({
    required this.text,
    required this.value,
    this.routeTag,
  });
}

/// ------------------------------
/// Track A: Attachment Screener
/// ------------------------------

/// 12-item, ECR-style compact set (6 anxiety, 6 avoidance), 50% reversed.
/// Likert: 1=Strongly Disagree ... 5=Strongly Agree
final List<PersonalityQuestion> attachmentItems = [
  // ---- Anxiety (A) ----
  const PersonalityQuestion(
    id: "A1",
    question: "I worry that romantic partners may not love me completely.",
    dimension: Dimension.anxiety,
    options: likert5,
  ),
  const PersonalityQuestion(
    id: "A2",
    question: "I often need reassurance from my partner.",
    dimension: Dimension.anxiety,
    options: likert5,
  ),
  const PersonalityQuestion(
    id: "A3",
    question: "I worry about being abandoned.",
    dimension: Dimension.anxiety,
    options: likert5,
  ),
  const PersonalityQuestion(
    id: "A4",
    question: "I rarely worry about relationship stability.",
    dimension: Dimension.anxiety,
    reversed: true,
    options: likert5,
  ),
  const PersonalityQuestion(
    id: "A5",
    question: "I feel confident my partner cares for me.",
    dimension: Dimension.anxiety,
    reversed: true,
    options: likert5,
  ),
  const PersonalityQuestion(
    id: "A6",
    question: "I'm afraid my partner will lose interest in me.",
    dimension: Dimension.anxiety,
    options: likert5,
  ),

  // ---- Avoidance (V) ----
  const PersonalityQuestion(
    id: "V1",
    question: "I prefer not to show deep feelings.",
    dimension: Dimension.avoidance,
    options: likert5,
  ),
  const PersonalityQuestion(
    id: "V2",
    question: "I find it hard to depend on others.",
    dimension: Dimension.avoidance,
    options: likert5,
  ),
  const PersonalityQuestion(
    id: "V3",
    question: "I'm uncomfortable being emotionally close.",
    dimension: Dimension.avoidance,
    options: likert5,
  ),
  const PersonalityQuestion(
    id: "V4",
    question: "I find it easy to be emotionally close.",
    dimension: Dimension.avoidance,
    reversed: true,
    options: likert5,
  ),
  const PersonalityQuestion(
    id: "V5",
    question: "I'm comfortable depending on my partner.",
    dimension: Dimension.avoidance,
    reversed: true,
    options: likert5,
  ),
  const PersonalityQuestion(
    id: "V6",
    question: "I'm okay with others depending on me.",
    dimension: Dimension.avoidance,
    reversed: true,
    options: likert5,
  ),

  // ---- Lightweight checks (excluded from A/A scoring, used for quality flags) ----
  const PersonalityQuestion(
    id: "CHK_ATTEN",
    question: "Attention check: please select 'Agree' for this item.",
    isAttentionCheck: true,
    options: [
      PersonalityQuestionOption(text: "Strongly Disagree", value: 1),
      PersonalityQuestionOption(text: "Disagree", value: 2),
      PersonalityQuestionOption(text: "Neutral", value: 3),
      PersonalityQuestionOption(text: "Agree", value: 4),
      PersonalityQuestionOption(text: "Strongly Agree", value: 5),
    ],
  ),
  const PersonalityQuestion(
    id: "SD1",
    question: "I always communicate calmly, even when extremely upset.",
    isSocialDesirability: true,
    options: likert5,
  ),
  const PersonalityQuestion(
    id: "SD2",
    question: "I never react defensively in arguments.",
    isSocialDesirability: true,
    options: likert5,
  ),

  // ---- Paradox pattern probe (not scored, used for 'disorganized-leaning' rule) ----
  const PersonalityQuestion(
    id: "PX1",
    question: "I want to be very close to my partner but also fear intimacy.",
    options: likert5,
  ),
];

/// Standard Likert options 1..5
const List<PersonalityQuestionOption> likert5 = [
  PersonalityQuestionOption(text: "Strongly Disagree", value: 1),
  PersonalityQuestionOption(text: "Disagree", value: 2),
  PersonalityQuestionOption(text: "Neutral", value: 3),
  PersonalityQuestionOption(text: "Agree", value: 4),
  PersonalityQuestionOption(text: "Strongly Agree", value: 5),
];

/// ------------------------------
/// Track B: Goal Routing (product profile)
/// ------------------------------

final List<PersonalityQuestion> goalItems = [
  const PersonalityQuestion(
    id: "G1",
    question:
        "What's your main goal in using tone and attachment analysis right now?",
    isGoal: true,
    options: [
      PersonalityQuestionOption(
        text: "New connection or dating",
        value: 4,
        routeTag: "dating_sensitive",
      ),
      PersonalityQuestionOption(
        text: "Repairing or deepening an existing relationship",
        value: 4,
        routeTag: "empathetic_mirror",
      ),
      PersonalityQuestionOption(
        text: "Staying consistent and becoming more secure",
        value: 4,
        routeTag: "secure_training",
      ),
      PersonalityQuestionOption(
        text: "Managing co-parenting communication",
        value: 4,
        routeTag: "coparenting_support",
      ),
      PersonalityQuestionOption(
        text: "Getting through tough conversations better",
        value: 4,
        routeTag: "boundary_forward",
      ),
    ],
  ),
  const PersonalityQuestion(
    id: "G2",
    question:
        "Do you find yourself feeling emotionally distant or disconnected in your current relationship?",
    isGoal: true,
    options: [
      PersonalityQuestionOption(
        text: "Yes, often",
        value: 5,
        routeTag: "dating_sensitive",
      ),
      PersonalityQuestionOption(
        text: "Sometimes",
        value: 4,
        routeTag: "empathetic_mirror",
      ),
      PersonalityQuestionOption(
        text: "Rarely",
        value: 2,
        routeTag: "secure_training",
      ),
      PersonalityQuestionOption(
        text: "No, not at all",
        value: 1,
        routeTag: "empathetic_mirror",
      ),
    ],
  ),
  const PersonalityQuestion(
    id: "G3",
    question:
        "Do you tend to avoid conflict or shut down during difficult conversations?",
    isGoal: true,
    options: [
      PersonalityQuestionOption(
        text: "Yes, I always avoid conflict",
        value: 5,
        routeTag: "deescalator",
      ),
      PersonalityQuestionOption(
        text: "I often shut down",
        value: 4,
        routeTag: "coparenting_support",
      ),
      PersonalityQuestionOption(
        text: "Sometimes I avoid it",
        value: 3,
        routeTag: "empathetic_mirror",
      ),
      PersonalityQuestionOption(
        text: "No, I engage with difficult conversations",
        value: 1,
        routeTag: "boundary_forward",
      ),
    ],
  ),
  const PersonalityQuestion(
    id: "G4",
    question:
        "Are you often the one trying to repair or bring things back together after conflict?",
    isGoal: true,
    options: [
      PersonalityQuestionOption(
        text: "Yes, always me",
        value: 5,
        routeTag: "empathetic_mirror",
      ),
      PersonalityQuestionOption(
        text: "Usually me",
        value: 4,
        routeTag: "empathetic_mirror",
      ),
      PersonalityQuestionOption(
        text: "Sometimes",
        value: 3,
        routeTag: "empathetic_mirror",
      ),
      PersonalityQuestionOption(
        text: "No, we both work on it",
        value: 2,
        routeTag: "secure_training",
      ),
    ],
  ),
  const PersonalityQuestion(
    id: "G5",
    question:
        "Are you currently trying to build a connection with someone new?",
    isGoal: true,
    options: [
      PersonalityQuestionOption(
        text: "Yes, actively dating",
        value: 5,
        routeTag: "dating_sensitive",
      ),
      PersonalityQuestionOption(
        text: "Yes, new relationship",
        value: 4,
        routeTag: "dating_sensitive",
      ),
      PersonalityQuestionOption(
        text: "No, focusing on existing relationships",
        value: 2,
        routeTag: "empathetic_mirror",
      ),
      PersonalityQuestionOption(
        text: "No, single and not dating",
        value: 1,
        routeTag: "secure_training",
      ),
    ],
  ),
  const PersonalityQuestion(
    id: "G6",
    question:
        "Do you want to focus on how to express your emotions more clearly and vulnerably?",
    isGoal: true,
    options: [
      PersonalityQuestionOption(
        text: "Yes, definitely",
        value: 5,
        routeTag: "empathetic_mirror",
      ),
      PersonalityQuestionOption(
        text: "Yes, somewhat",
        value: 4,
        routeTag: "empathetic_mirror",
      ),
      PersonalityQuestionOption(
        text: "Maybe",
        value: 3,
        routeTag: "empathetic_mirror",
      ),
      PersonalityQuestionOption(
        text: "No, I'm comfortable with my expression",
        value: 1,
        routeTag: "secure_training",
      ),
    ],
  ),
  const PersonalityQuestion(
    id: "G7",
    question:
        "Are you navigating a challenging topic right now (like boundaries, needs, or big changes)?",
    isGoal: true,
    options: [
      PersonalityQuestionOption(
        text: "Yes, very challenging topics",
        value: 5,
        routeTag: "boundary_forward",
      ),
      PersonalityQuestionOption(
        text: "Yes, some difficult conversations",
        value: 4,
        routeTag: "deescalator",
      ),
      PersonalityQuestionOption(
        text: "Maybe some smaller issues",
        value: 3,
        routeTag: "empathetic_mirror",
      ),
      PersonalityQuestionOption(
        text: "No, things are stable",
        value: 1,
        routeTag: "secure_training",
      ),
    ],
  ),
  const PersonalityQuestion(
    id: "G8",
    question:
        "Is your co-parenting communication more about logistics or emotional conflict?",
    isGoal: true,
    options: [
      PersonalityQuestionOption(
        text: "Mostly logistics",
        value: 3,
        routeTag: "coparenting_support",
      ),
      PersonalityQuestionOption(
        text: "Mix of both",
        value: 3,
        routeTag: "coparenting_support",
      ),
      PersonalityQuestionOption(
        text: "Mostly emotional conflict",
        value: 4,
        routeTag: "empathetic_mirror",
      ),
      PersonalityQuestionOption(
        text: "Not applicable - no co-parenting",
        value: 1,
        routeTag: "empathetic_mirror",
      ),
    ],
  ),
  const PersonalityQuestion(
    id: "G9",
    question:
        "Would you prefer gentle daily check-ins to help regulate tone, even in casual texts?",
    isGoal: true,
    options: [
      PersonalityQuestionOption(
        text: "Yes, that sounds helpful",
        value: 5,
        routeTag: "balanced",
      ),
      PersonalityQuestionOption(
        text: "Maybe occasionally",
        value: 3,
        routeTag: "secure_training",
      ),
      PersonalityQuestionOption(
        text: "Not really needed",
        value: 2,
        routeTag: "empathetic_mirror",
      ),
      PersonalityQuestionOption(
        text: "No, I prefer minimal intervention",
        value: 1,
        routeTag: "deescalator",
      ),
    ],
  ),
  const PersonalityQuestion(
    id: "G10",
    question:
        "Would you describe your tone goal as: more clarity, more warmth, or more calm?",
    isGoal: true,
    options: [
      PersonalityQuestionOption(
        text: "More clarity",
        value: 5,
        routeTag: "boundary_forward",
      ),
      PersonalityQuestionOption(
        text: "More warmth",
        value: 5,
        routeTag: "dating_sensitive",
      ),
      PersonalityQuestionOption(
        text: "More calm",
        value: 5,
        routeTag: "secure_training",
      ),
      PersonalityQuestionOption(
        text: "All of the above",
        value: 4,
        routeTag: "empathetic_mirror",
      ),
    ],
  ),

  // Communication Style: Profanity Usage
  const PersonalityQuestion(
    id: "G11",
    question:
        "How often do you use strong language or profanity when you're frustrated or angry?",
    isGoal: true,
    options: [
      PersonalityQuestionOption(
        text: "Never - I avoid profanity completely",
        value: 1,
        routeTag: "gentle_communicator",
      ),
      PersonalityQuestionOption(
        text: "Rarely - only in extreme situations",
        value: 2,
        routeTag: "measured_communicator",
      ),
      PersonalityQuestionOption(
        text: "Sometimes - when I'm really upset",
        value: 3,
        routeTag: "moderate_communicator",
      ),
      PersonalityQuestionOption(
        text: "Often - it's part of how I express myself",
        value: 4,
        routeTag: "expressive_communicator",
      ),
      PersonalityQuestionOption(
        text: "Frequently - it's natural for me",
        value: 5,
        routeTag: "direct_communicator",
      ),
    ],
  ),

  // Communication Style: Sarcasm Usage
  const PersonalityQuestion(
    id: "G12",
    question: "How often do you use sarcasm or irony in your communication?",
    isGoal: true,
    options: [
      PersonalityQuestionOption(
        text: "Never - I prefer direct communication",
        value: 1,
        routeTag: "direct_communicator",
      ),
      PersonalityQuestionOption(
        text: "Rarely - only occasionally",
        value: 2,
        routeTag: "measured_communicator",
      ),
      PersonalityQuestionOption(
        text: "Sometimes - when making a point",
        value: 3,
        routeTag: "moderate_communicator",
      ),
      PersonalityQuestionOption(
        text: "Often - it's part of my humor",
        value: 4,
        routeTag: "witty_communicator",
      ),
      PersonalityQuestionOption(
        text: "Frequently - it's my default style",
        value: 5,
        routeTag: "sarcastic_communicator",
      ),
    ],
  ),
];

/// ------------------------------
/// Scoring models & outputs
/// ------------------------------

class AttachmentScores {
  final int anxiety; // 0..100
  final int avoidance; // 0..100
  final double reliabilityAlpha; // Cronbach's alpha across 12 scored items
  final bool attentionPassed;
  final double socialDesirability; // 0..1 (higher means more idealized)
  final bool disorganizedLean;
  final String
  quadrant; // "secure", "anxious", "avoidant", "disorganized_lean", "mixed"
  final String confidenceLabel; // "High", "Moderate", "Cautious"

  const AttachmentScores({
    required this.anxiety,
    required this.avoidance,
    required this.reliabilityAlpha,
    required this.attentionPassed,
    required this.socialDesirability,
    required this.disorganizedLean,
    required this.quadrant,
    required this.confidenceLabel,
  });

  @override
  String toString() =>
      "A:$anxiety V:$avoidance α:${reliabilityAlpha.toStringAsFixed(2)} "
      "attn:${attentionPassed ? 'ok' : 'fail'} "
      "SD:${socialDesirability.toStringAsFixed(2)} "
      "disorg:${disorganizedLean ? 'yes' : 'no'} "
      "quad:$quadrant conf:$confidenceLabel";
}

class GoalRoutingResult {
  final Set<String> routeTags; // unique tag set from selections
  final String primaryProfile; // derived from routeTags (simple heuristic)

  const GoalRoutingResult({
    required this.routeTags,
    required this.primaryProfile,
  });
}

class AttachmentAssessment {
  /// Main entry: provide responses and receive full outputs.
  ///
  /// `responses` = map of questionId -> value(1..5).
  /// You can pass a single combined map for both tracks; the scorer will pull what it needs.
  static ({AttachmentScores scores, GoalRoutingResult routing}) run(
    Map<String, int> responses,
  ) {
    // Back-compat for older saved results where we used G8/G9 twice
    if (responses.containsKey('G8') && !responses.containsKey('G11')) {
      responses['G11'] = responses['G8']!; // old profanity -> new
    }
    if (responses.containsKey('G9') && !responses.containsKey('G12')) {
      responses['G12'] = responses['G9']!; // old sarcasm -> new
    }

    final scores = _scoreAttachment(responses);
    final routing = _routeGoals(responses);
    return (scores: scores, routing: routing);
  }

  /// Run assessment with custom item set (e.g., scenario-based questions).
  ///
  /// `responses` = map of questionId -> value(1..5).
  /// `items` = custom list of PersonalityQuestion items to score.
  /// Goal routing still uses the standard goalItems.
  static ({AttachmentScores scores, GoalRoutingResult routing}) runWithItems(
    Map<String, int> responses,
    List<PersonalityQuestion> items,
  ) {
    final scores = _scoreAttachmentWithItems(responses, items);
    final routing = _routeGoals(responses);
    return (scores: scores, routing: routing);
  }

  /// ------------------------------
  /// Attachment scoring
  /// ------------------------------
  static AttachmentScores _scoreAttachment(Map<String, int> responses) {
    // 1) Extract scored items (12 core)
    final core = attachmentItems.where(
      (q) =>
          (q.dimension == Dimension.anxiety ||
              q.dimension == Dimension.avoidance) &&
          !q.isAttentionCheck &&
          !q.isSocialDesirability,
    );

    // Compute reversed-coded values and split by dimension
    final List<double> scoredAll = [];
    final List<double> scoredAnx = [];
    final List<double> scoredAvd = [];

    double anxSum = 0, anxW = 0, avdSum = 0, avdW = 0;

    for (final q in core) {
      final raw = (responses[q.id] ?? 3).toDouble().clamp(1, 5);
      final val = q.reversed ? (6 - raw) : raw;
      final w = q.weight;

      // z-score approximate: mean=3, sd≈1.118 for uniform Likert; we'll standardize later via alpha calc.
      // For final 0–100 scaling we'll convert with a normal-ish mapping.
      if (q.dimension == Dimension.anxiety) {
        anxSum += val * w;
        anxW += w;
        scoredAnx.add(val.toDouble());
      } else if (q.dimension == Dimension.avoidance) {
        avdSum += val * w;
        avdW += w;
        scoredAvd.add(val.toDouble());
      }
      scoredAll.add(val.toDouble());
    }

    // 2) Map to 0–100 (centered on 50). Use linear mapping against 1..5:
    // 1 -> 0, 3 -> 50, 5 -> 100
    double map100(double m) => ((m - 1.0) / 4.0 * 100.0).clamp(0, 100);
    final anxMean = (anxSum / max(anxW, 1e-6));
    final avdMean = (avdSum / max(avdW, 1e-6));
    int anxiety = map100(anxMean).round();
    int avoidance = map100(avdMean).round();

    // 3) Reliability (Cronbach's alpha) across the 12 core items
    final alpha = _splitHalfConsistency(scoredAll);

    // 4) Attention check
    final attnVal = responses["CHK_ATTEN"];
    final attentionPassed =
        (attnVal == 4 || attnVal == 5); // "Agree" or "Strongly Agree"

    // 5) Social desirability (mean of SD items -> normalize to 0..1)
    final sdVals = [
      "SD1",
      "SD2",
    ].map((id) => (responses[id] ?? 3).toDouble()).toList();
    final sdMean = sdVals.isEmpty
        ? 3.0
        : sdVals.reduce((a, b) => a + b) / sdVals.length;
    final socialDesirability = ((sdMean - 1.0) / 4.0).clamp(0.0, 1.0);

    // 6) Disorganized-leaning flag: both high + paradox endorsement
    final paradox = (responses["PX1"] ?? 3);
    final disorganizedLean = (anxiety >= 60 && avoidance >= 60 && paradox >= 4);

    // 7) Quadrant mapping with gray zones (45–55)
    final quadrant = _quadrant(anxiety, avoidance, disorganizedLean);

    // 8) Confidence label
    final conf = _confidenceLabel(alpha, anxiety, avoidance);

    return AttachmentScores(
      anxiety: anxiety,
      avoidance: avoidance,
      reliabilityAlpha: alpha,
      attentionPassed: attentionPassed,
      socialDesirability: socialDesirability,
      disorganizedLean: disorganizedLean,
      quadrant: quadrant,
      confidenceLabel: conf,
    );
  }

  /// Score attachment with custom item set (for scenario-based assessments)
  static AttachmentScores _scoreAttachmentWithItems(
    Map<String, int> responses,
    List<PersonalityQuestion> items,
  ) {
    // 1) Extract scored items from custom set
    final core = items.where(
      (q) =>
          (q.dimension == Dimension.anxiety ||
              q.dimension == Dimension.avoidance) &&
          !q.isAttentionCheck &&
          !q.isSocialDesirability,
    );

    final List<double> scoredAll = [];
    double anxSum = 0, anxW = 0, avdSum = 0, avdW = 0;

    for (final q in core) {
      final raw = (responses[q.id] ?? 3).toDouble().clamp(1, 5);
      final val = q.reversed ? (6 - raw) : raw;
      final w = q.weight;

      if (q.dimension == Dimension.anxiety) {
        anxSum += val * w;
        anxW += w;
      }
      if (q.dimension == Dimension.avoidance) {
        avdSum += val * w;
        avdW += w;
      }

      scoredAll.add(val.toDouble());
    }

    // 2) Map to 0–100 (centered on 50)
    double map100(double m) => ((m - 1.0) / 4.0 * 100.0).clamp(0, 100);
    final anxMean = anxW > 0 ? (anxSum / anxW) : 3.0;
    final avdMean = avdW > 0 ? (avdSum / avdW) : 3.0;

    final anxiety = map100(anxMean).round();
    final avoidance = map100(avdMean).round();

    // 3) Reliability across scored items
    final alpha = _splitHalfConsistency(scoredAll);

    // 4) Reuse existing quality signals (if present in responses)
    final attnVal = responses["CHK_ATTEN"];
    final attentionPassed = (attnVal == 4 || attnVal == 5);

    final sdVals = ["SD1", "SD2"]
        .where(responses.containsKey)
        .map((id) => responses[id]!.toDouble())
        .toList();
    final sdMean = sdVals.isEmpty
        ? 3.0
        : sdVals.reduce((a, b) => a + b) / sdVals.length;
    final socialDesirability = ((sdMean - 1.0) / 4.0).clamp(0.0, 1.0);

    // 5) Check for paradox indicators (PX1 from core, S_PX2/S_PX3/S_PX4 from scenarios)
    final paradox =
        responses["PX1"] ??
        responses["S_PX2"] ??
        responses["S_PX3"] ??
        responses["S_PX4"] ??
        3;
    final disorganizedLean = (anxiety >= 60 && avoidance >= 60 && paradox >= 4);

    // 6) Quadrant and confidence mapping (reuse existing logic)
    final quadrant = _quadrant(anxiety, avoidance, disorganizedLean);
    final conf = _confidenceLabel(alpha, anxiety, avoidance);

    return AttachmentScores(
      anxiety: anxiety,
      avoidance: avoidance,
      reliabilityAlpha: alpha,
      attentionPassed: attentionPassed,
      socialDesirability: socialDesirability,
      disorganizedLean: disorganizedLean,
      quadrant: quadrant,
      confidenceLabel: conf,
    );
  }

  static double _splitHalfConsistency(List<double> items) {
    if (items.length < 6) return 0.0;
    final odd = <double>[];
    final even = <double>[];
    for (int i = 0; i < items.length; i++) {
      (i % 2 == 0 ? odd : even).add(items[i]);
    }
    double mean(List<double> xs) => xs.reduce((a, b) => a + b) / xs.length;
    double varOf(List<double> xs) {
      if (xs.length < 2) return 0.0;
      final m = mean(xs);
      var s2 = 0.0;
      for (final x in xs) {
        s2 += (x - m) * (x - m);
      }
      return s2 / (xs.length - 1);
    }

    double cov(List<double> a, List<double> b) {
      final mA = mean(a), mB = mean(b);
      var c = 0.0;
      for (var i = 0; i < a.length; i++) {
        c += (a[i] - mA) * (b[i] - mB);
      }
      return c / (a.length - 1);
    }

    final r = cov(odd, even) / (sqrt(varOf(odd) * varOf(even)));
    final sb = (2 * r) / (1 + r); // Spearman–Brown
    return sb.isNaN ? 0.0 : sb.clamp(0.0, 1.0);
  }

  static String _quadrant(int anxiety, int avoidance, bool disorg) {
    if (disorg) return "disorganized_lean";
    const low = 45, high = 55; // ±5 dampens flapping

    final aHigh = anxiety >= high;
    final aLow = anxiety <= low;
    final vHigh = avoidance >= high;
    final vLow = avoidance <= low;

    if (aLow && vLow) return "secure";
    if (aHigh && !vHigh) return "anxious";
    if (vHigh && !aHigh) return "avoidant";

    // If near the diagonals but paradox is not endorsed, keep 'mixed'
    return "mixed";
  }

  static String _confidenceLabel(
    double consistency,
    int anxiety,
    int avoidance,
  ) {
    // distance from center (50,50)
    final dx = (anxiety - 50).abs();
    final dv = (avoidance - 50).abs();
    final radial = sqrt(dx * dx + dv * dv); // 0..~70

    // Combine: strong signal far from center + decent consistency
    if (consistency >= 0.65 && radial >= 20) return "High";
    if (consistency >= 0.50 && radial >= 12) return "Moderate";
    return "Cautious";
  }

  /// ------------------------------
  /// Goal routing
  /// ------------------------------
  static GoalRoutingResult _routeGoals(Map<String, int> responses) {
    final Set<String> tags = {};
    for (final q in goalItems) {
      final val = responses[q.id];
      if (val == null) continue;
      // Find the chosen option (by exact value match OR closest by index if needed)
      // In a real UI, you'd map by index/option id, but we keep it simple here.
      PersonalityQuestionOption? chosen;
      // Prefer exact value match:
      for (final opt in q.options) {
        if (opt.value == val) {
          chosen = opt;
          break;
        }
      }
      chosen ??= q.options.isNotEmpty
          ? q.options[min(val - 1, q.options.length - 1)]
          : null;
      if (chosen?.routeTag != null) tags.add(chosen!.routeTag!);
    }

    final primary = _primaryProfileFrom(tags);
    return GoalRoutingResult(routeTags: tags, primaryProfile: primary);
  }

  static String _primaryProfileFrom(Set<String> tags) {
    // Strong/explicit profiles first
    if (tags.contains("coparenting_support")) return "coparenting_support";
    if (tags.contains("boundary_forward")) return "boundary_forward";
    if (tags.contains("dating_sensitive")) return "dating_sensitive";
    if (tags.contains("deescalator")) return "deescalator";
    if (tags.contains("empathetic_mirror")) return "empathetic_mirror";
    if (tags.contains("balanced")) return "balanced";
    if (tags.contains("secure_training")) return "secure_training";

    // Communication-style tags → nearest core profile
    const styleMap = {
      "gentle_communicator": "deescalator",
      "measured_communicator": "balanced",
      "moderate_communicator": "balanced",
      "expressive_communicator": "dating_sensitive",
      "direct_communicator": "boundary_forward",
      "witty_communicator": "balanced",
      "sarcastic_communicator": "boundary_forward",
    };
    for (final t in tags) {
      if (styleMap.containsKey(t)) return styleMap[t]!;
    }

    return "secure_training";
  }
}

/// ------------------------------
/// Example of how to use
/// ------------------------------
///
/// final responses = <String,int>{
///   // --- Attachment core (12 items) ---
///   "A1": 4, "A2": 3, "A3": 4, "A4": 2, "A5": 2, "A6": 4,
///   "V1": 3, "V2": 3, "V3": 3, "V4": 4, "V5": 4, "V6": 4,
///   // Checks (optional but recommended)
///   "CHK_ATTEN": 4, "SD1": 4, "SD2": 3, "PX1": 4,
///   // --- Goals ---
///   "G1": 4, "G2": 3, "G3": 1, "G4": 4, "G5": 1,
///   "G6": 4, "G7": 3, "G11": 3, "G12": 5, "G10": 5,
/// };
///
/// final result = AttachmentAssessment.run(responses);
/// print(result.scores);  // full scoring summary
/// print(result.routing.primaryProfile); // e.g., "boundary_forward"
///
/// You can now:
/// - Feed `result.routing.primaryProfile` into multiplier.json selection
/// - Use `result.scores.quadrant` for attachment_overrides.json
/// - Gate suggestion intensity via `result.scores.reliabilityAlpha` and confidenceLabel
