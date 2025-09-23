// adaptive_flow.dart
// Unsaid - Adaptive attachment assessment flow
//
// Builds quick 6-8 item assessment sets with smart selection
// from both core attachment items and scenario bank.
// ------------------------------------------------------------

import 'dart:math';
import 'attachment_assessment.dart';
import 'attachment_scenarios.dart';

/// Simple unique list with truncate utility
class _UniqueList<T> {
  final List<T> _xs = [];

  void add(T x) {
    if (!_xs.contains(x)) _xs.add(x);
  }

  void addAll(Iterable<T> it) {
    for (final x in it) {
      add(x);
    }
  }

  void truncateTo(int n) {
    if (_xs.length > n) _xs.removeRange(n, _xs.length);
  }

  List<T> toList() => List.unmodifiable(_xs);
}

class AdaptiveAttachmentFlow {
  /// Build a quick assessment set combining core items and scenarios
  ///
  /// `total` = desired number of items (6-8 works well)
  /// `preferScenarios` = favor scenario items over core ECR items
  /// `includeQualityChecks` = add attention/social desirability items
  static List<PersonalityQuestion> buildQuickSet({
    int total = 8,
    bool preferScenarios = true,
    bool includeQualityChecks = true,
  }) {
    final rng = Random();
    final unique = _UniqueList<PersonalityQuestion>();

    // Helper to pick random item from list
    T pick<T>(List<T> xs) => xs[rng.nextInt(xs.length)];

    // Get pools of items by dimension
    List<PersonalityQuestion> anxiousPool, avoidantPool, securePool;

    if (preferScenarios) {
      // Primary: scenarios, fallback: core items
      anxiousPool = [
        ...ScenarioBank.anxiousScenarios,
        ...attachmentItems.where(
          (q) => q.dimension == Dimension.anxiety && !q.reversed,
        ),
      ];
      avoidantPool = [
        ...ScenarioBank.avoidantScenarios,
        ...attachmentItems.where(
          (q) => q.dimension == Dimension.avoidance && !q.reversed,
        ),
      ];
      securePool = [
        ...ScenarioBank.secureScenarios,
        ...attachmentItems.where((q) => q.reversed),
      ];
    } else {
      // Primary: core items, fallback: scenarios
      anxiousPool = [
        ...attachmentItems.where(
          (q) => q.dimension == Dimension.anxiety && !q.reversed,
        ),
        ...ScenarioBank.anxiousScenarios,
      ];
      avoidantPool = [
        ...attachmentItems.where(
          (q) => q.dimension == Dimension.avoidance && !q.reversed,
        ),
        ...ScenarioBank.avoidantScenarios,
      ];
      securePool = [
        ...attachmentItems.where((q) => q.reversed),
        ...ScenarioBank.secureScenarios,
      ];
    }

    // Reserve slots for quality checks if requested
    int contentSlots = total;
    if (includeQualityChecks) {
      // Add attention check
      final attentionCheck = attachmentItems.firstWhere(
        (q) => q.isAttentionCheck,
        orElse: () => attachmentItems.first,
      );
      unique.add(attentionCheck);

      // Add one social desirability item
      final sdItems = attachmentItems
          .where((q) => q.isSocialDesirability)
          .toList();
      if (sdItems.isNotEmpty) {
        unique.add(pick(sdItems));
      }

      contentSlots = total - unique.toList().length;
    }

    // Build seed set: balanced across dimensions
    final seedSize = (contentSlots * 0.6)
        .round(); // 60% for initial balanced set
    final followUpSize = contentSlots - seedSize;

    // Seed: 2 anxious, 2 avoidant, rest secure (balanced foundation)
    if (anxiousPool.isNotEmpty) {
      unique.add(pick(anxiousPool));
      if (seedSize > 3 && anxiousPool.length > 1) {
        unique.add(pick(anxiousPool));
      }
    }

    if (avoidantPool.isNotEmpty) {
      unique.add(pick(avoidantPool));
      if (seedSize > 3 && avoidantPool.length > 1) {
        unique.add(pick(avoidantPool));
      }
    }

    // Fill remaining seed slots with secure items
    while (unique.toList().length < (total - followUpSize) &&
        securePool.isNotEmpty) {
      unique.add(pick(securePool));
    }

    // Add paradox probe if we have room
    final paradoxItems = ScenarioBank.paradoxScenarios;
    if (followUpSize > 0 && paradoxItems.isNotEmpty) {
      unique.add(pick(paradoxItems));
    }

    // Fill any remaining slots with mixed items
    final allContentItems = [...anxiousPool, ...avoidantPool, ...securePool];
    while (unique.toList().length < total && allContentItems.isNotEmpty) {
      unique.add(pick(allContentItems));
    }

    unique.truncateTo(total);
    final result = unique.toList();

    // Shuffle to avoid dimension clustering (except keep attention check near beginning)
    final shuffled = <PersonalityQuestion>[];
    final attentionItem = result.firstWhere(
      (q) => q.isAttentionCheck,
      orElse: () => result.first,
    );

    // Put attention check in position 2-4
    final nonAttention = result.where((q) => !q.isAttentionCheck).toList();
    nonAttention.shuffle(rng);

    if (result.contains(attentionItem) && result.length > 3) {
      shuffled.addAll(nonAttention.take(2));
      shuffled.add(attentionItem);
      shuffled.addAll(nonAttention.skip(2));
    } else {
      shuffled.addAll(nonAttention);
      if (result.contains(attentionItem)) shuffled.add(attentionItem);
    }

    return shuffled.take(total).toList();
  }

  /// Build a minimal 4-item screener (2 anxious, 2 avoidant scenarios)
  static List<PersonalityQuestion> buildMiniScreener() {
    final rng = Random();

    final result = <PersonalityQuestion>[];

    // 2 anxious scenarios
    final anxiousScenarios = ScenarioBank.anxiousScenarios;
    if (anxiousScenarios.length >= 2) {
      final shuffled = List<PersonalityQuestion>.from(anxiousScenarios)
        ..shuffle(rng);
      result.addAll(shuffled.take(2));
    }

    // 2 avoidant scenarios
    final avoidantScenarios = ScenarioBank.avoidantScenarios;
    if (avoidantScenarios.length >= 2) {
      final shuffled = List<PersonalityQuestion>.from(avoidantScenarios)
        ..shuffle(rng);
      result.addAll(shuffled.take(2));
    }

    // Shuffle final order
    result.shuffle(rng);
    return result;
  }

  /// Get a follow-up question set based on provisional anxiety/avoidance scores
  static List<PersonalityQuestion> buildFollowUpSet(
    Map<String, int> provisionalResponses,
    List<PersonalityQuestion> alreadyAsked, {
    int maxFollowUps = 3,
  }) {
    // Calculate provisional means
    double calculateMean(Dimension dim) {
      final responses = alreadyAsked
          .where(
            (q) => q.dimension == dim && provisionalResponses.containsKey(q.id),
          )
          .map((q) => provisionalResponses[q.id]!)
          .toList();
      return responses.isEmpty
          ? 3.0
          : responses.reduce((a, b) => a + b) / responses.length;
    }

    final anxMean = calculateMean(Dimension.anxiety);
    final avdMean = calculateMean(Dimension.avoidance);

    final rng = Random();
    final followUps = <PersonalityQuestion>[];
    final available = <PersonalityQuestion>[
      ...scenarioItems,
      ...attachmentItems.where(
        (q) =>
            q.dimension != Dimension.none &&
            !q.isAttentionCheck &&
            !q.isSocialDesirability,
      ),
    ].where((q) => !alreadyAsked.contains(q)).toList();

    // Branching logic based on provisional scores (3.5 cutoff)
    if (anxMean >= 3.5 && avdMean < 3.5) {
      // High anxiety, low avoidance → more anxious probes
      final anxiousItems = available
          .where((q) => q.dimension == Dimension.anxiety && !q.reversed)
          .toList();
      anxiousItems.shuffle(rng);
      followUps.addAll(anxiousItems.take(maxFollowUps));
    } else if (avdMean >= 3.5 && anxMean < 3.5) {
      // High avoidance, low anxiety → more avoidant probes
      final avoidantItems = available
          .where((q) => q.dimension == Dimension.avoidance && !q.reversed)
          .toList();
      avoidantItems.shuffle(rng);
      followUps.addAll(avoidantItems.take(maxFollowUps));
    } else if (anxMean >= 3.5 && avdMean >= 3.5) {
      // High both → paradox probes + mixed
      final paradoxItems = available
          .where((q) => q.dimension == Dimension.none)
          .toList();
      final mixedItems = available
          .where((q) => q.dimension != Dimension.none)
          .toList();

      paradoxItems.shuffle(rng);
      mixedItems.shuffle(rng);

      followUps.addAll(paradoxItems.take((maxFollowUps / 2).round()));
      followUps.addAll(mixedItems.take(maxFollowUps - followUps.length));
    } else {
      // Low both → secure probes to confirm
      final secureItems = available.where((q) => q.reversed).toList();
      secureItems.shuffle(rng);
      followUps.addAll(secureItems.take(maxFollowUps));
    }

    return followUps.take(maxFollowUps).toList();
  }

  /// Get item distribution summary for debugging
  static Map<String, dynamic> analyzeItemSet(List<PersonalityQuestion> items) {
    return {
      'total': items.length,
      'anxiety_items': items
          .where((q) => q.dimension == Dimension.anxiety && !q.reversed)
          .length,
      'avoidance_items': items
          .where((q) => q.dimension == Dimension.avoidance && !q.reversed)
          .length,
      'secure_items': items.where((q) => q.reversed).length,
      'paradox_items': items.where((q) => q.dimension == Dimension.none).length,
      'scenario_items': items.where((q) => q.id.startsWith('S_')).length,
      'core_items': items
          .where(
            (q) =>
                !q.id.startsWith('S_') &&
                !q.isAttentionCheck &&
                !q.isSocialDesirability,
          )
          .length,
      'quality_checks': items
          .where((q) => q.isAttentionCheck || q.isSocialDesirability)
          .length,
      'weighted_items': items.where((q) => q.weight > 1.0).length,
    };
  }
}
