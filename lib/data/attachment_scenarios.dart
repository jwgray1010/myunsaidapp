// attachment_scenarios.dart
// Unsaid - High-signal, real-life attachment scenarios
//
// Scenario-based questions that "feel like life" but map cleanly to
// anxiety/avoidance dimensions. Each uses standard Likert 1-5 scaling
// with 1.15x weight for extra diagnostic power.
// ------------------------------------------------------------

import 'attachment_assessment.dart';

/// High-signal, real-life scenarios. Each item is Likert 1..5.
/// We set weight:1.15 so they carry a little extra diagnostic power.
final List<PersonalityQuestion> scenarioItems = [
  // --- ANXIOUS-LEANING SCENARIOS ---
  const PersonalityQuestion(
    id: "S_A1",
    question: "Texts slow down for a day after a great weekend together.",
    dimension: Dimension.anxiety,
    reversed: false,
    weight: 1.15,
    options: likert5, // Agree => more anxious
  ),

  const PersonalityQuestion(
    id: "S_A2",
    question:
        "When we pause a tense talk, I feel abandoned until we reconnect.",
    dimension: Dimension.anxiety,
    reversed: false,
    weight: 1.15,
    options: likert5,
  ),

  const PersonalityQuestion(
    id: "S_A3",
    question:
        "If my partner is quieter than usual, I assume I did something wrong.",
    dimension: Dimension.anxiety,
    reversed: false,
    weight: 1.15,
    options: likert5,
  ),

  const PersonalityQuestion(
    id: "S_A4",
    question: "I need reassurance quickly when communication feels off.",
    dimension: Dimension.anxiety,
    reversed: false,
    weight: 1.15,
    options: likert5,
  ),

  const PersonalityQuestion(
    id: "S_A5",
    question:
        "I replay conversations in my head, looking for signs of problems.",
    dimension: Dimension.anxiety,
    reversed: false,
    weight: 1.15,
    options: likert5,
  ),

  // --- AVOIDANT-LEANING SCENARIOS ---
  const PersonalityQuestion(
    id: "S_V1",
    question: "After a very connected day, I need distance the next day.",
    dimension: Dimension.avoidance,
    reversed: false,
    weight: 1.15,
    options: likert5,
  ),

  const PersonalityQuestion(
    id: "S_V2",
    question:
        "Deep feelings talks feel draining; I look for ways to shorten them.",
    dimension: Dimension.avoidance,
    reversed: false,
    weight: 1.15,
    options: likert5,
  ),

  const PersonalityQuestion(
    id: "S_V3",
    question: "I downplay my needs to avoid relying on my partner.",
    dimension: Dimension.avoidance,
    reversed: false,
    weight: 1.15,
    options: likert5,
  ),

  const PersonalityQuestion(
    id: "S_V4",
    question:
        "I prefer to handle emotional issues independently rather than discuss them.",
    dimension: Dimension.avoidance,
    reversed: false,
    weight: 1.15,
    options: likert5,
  ),

  const PersonalityQuestion(
    id: "S_V5",
    question: "When conflict heats up, I disengage rather than stay present.",
    dimension: Dimension.avoidance,
    reversed: false,
    weight: 1.15,
    options: likert5,
  ),

  // --- SECURE (REVERSED; AGREEMENT = LOWER A/V) ---
  const PersonalityQuestion(
    id: "S_SEC1",
    question: "When something feels off, I can name it without blaming.",
    dimension:
        Dimension.anxiety, // reversed lowers A and indirectly V via mapping
    reversed: true,
    weight: 1.10,
    options: likert5,
  ),

  const PersonalityQuestion(
    id: "S_SEC2",
    question: "I can take a break in conflict and reliably return to repair.",
    dimension: Dimension.avoidance, // reversed lowers V and indirectly A
    reversed: true,
    weight: 1.10,
    options: likert5,
  ),

  const PersonalityQuestion(
    id: "S_SEC3",
    question:
        "I feel comfortable with both closeness and independence in relationships.",
    dimension: Dimension.anxiety, // reversed lowers anxiety about intimacy
    reversed: true,
    weight: 1.10,
    options: likert5,
  ),

  const PersonalityQuestion(
    id: "S_SEC4",
    question: "I can express my needs clearly without fear of rejection.",
    dimension:
        Dimension.avoidance, // reversed lowers avoidance of vulnerability
    reversed: true,
    weight: 1.10,
    options: likert5,
  ),

  // --- DISORGANIZED-LEAN SCENARIOS (NOT SCORED, PARADOX PROBES) ---
  const PersonalityQuestion(
    id: "S_PX2",
    question: "I swing between wanting closeness and pushing my partner away.",
    dimension: Dimension.none, // keep out of A/V; use as another paradox probe
    reversed: false,
    weight: 1.0,
    options: likert5,
  ),

  const PersonalityQuestion(
    id: "S_PX3",
    question: "My feelings about intimacy seem contradictory from day to day.",
    dimension: Dimension.none, // paradox probe
    reversed: false,
    weight: 1.0,
    options: likert5,
  ),

  const PersonalityQuestion(
    id: "S_PX4",
    question: "I often feel both clingy and distant at the same time.",
    dimension: Dimension.none, // paradox probe
    reversed: false,
    weight: 1.0,
    options: likert5,
  ),
];

/// All scenario items grouped by type for easy selection
class ScenarioBank {
  static List<PersonalityQuestion> get anxiousScenarios => scenarioItems
      .where((q) => q.dimension == Dimension.anxiety && !q.reversed)
      .toList();

  static List<PersonalityQuestion> get avoidantScenarios => scenarioItems
      .where((q) => q.dimension == Dimension.avoidance && !q.reversed)
      .toList();

  static List<PersonalityQuestion> get secureScenarios =>
      scenarioItems.where((q) => q.reversed).toList();

  static List<PersonalityQuestion> get paradoxScenarios =>
      scenarioItems.where((q) => q.dimension == Dimension.none).toList();

  /// Get a balanced mix of scenarios for quick assessment
  static List<PersonalityQuestion> getBalancedMix({int count = 8}) {
    final mix = <PersonalityQuestion>[];

    // Add 2-3 from each category
    final anxious = List<PersonalityQuestion>.from(anxiousScenarios)..shuffle();
    final avoidant = List<PersonalityQuestion>.from(avoidantScenarios)
      ..shuffle();
    final secure = List<PersonalityQuestion>.from(secureScenarios)..shuffle();
    final paradox = List<PersonalityQuestion>.from(paradoxScenarios)..shuffle();

    // Distribute evenly
    final perCategory = (count / 4).floor();
    final remainder = count % 4;

    mix.addAll(anxious.take(perCategory + (remainder > 0 ? 1 : 0)));
    mix.addAll(avoidant.take(perCategory + (remainder > 1 ? 1 : 0)));
    mix.addAll(secure.take(perCategory + (remainder > 2 ? 1 : 0)));
    mix.addAll(paradox.take(perCategory));

    // Shuffle final order
    mix.shuffle();
    return mix.take(count).toList();
  }
}
