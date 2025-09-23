// adaptive_picker.dart
// Unsaid - Runtime adaptive question selection
//
// Smart question picker that analyzes provisional responses and selects
// the next most diagnostic question based on emerging attachment patterns.
// ------------------------------------------------------------

import 'attachment_assessment.dart';

class AdaptivePicker {
  /// Pick the next best question based on provisional responses.
  ///
  /// `answers` is partial map {id -> 1..5} of responses so far.
  /// `pool` is the available question bank to choose from.
  /// Returns the next best question id or null if pool is exhausted.
  static PersonalityQuestion? pickNext(
    Map<String, int> answers,
    List<PersonalityQuestion> pool,
  ) {
    // Calculate provisional dimensional means
    double mean(List<int> xs) =>
        xs.isEmpty ? 3.0 : xs.reduce((a, b) => a + b) / xs.length;

    final anxAnswered = pool
        .where(
          (q) => q.dimension == Dimension.anxiety && answers.containsKey(q.id),
        )
        .map((q) => answers[q.id]!)
        .toList();
    final avdAnswered = pool
        .where(
          (q) =>
              q.dimension == Dimension.avoidance && answers.containsKey(q.id),
        )
        .map((q) => answers[q.id]!)
        .toList();

    final anxMean = mean(anxAnswered);
    final avdMean = mean(avdAnswered);

    // Determine target dimension based on provisional scores
    // Thresholds match your 3.5 cutoff for attachment classification
    Dimension target = Dimension.none;
    if (anxMean >= 3.5 && avdMean < 3.5) {
      target = Dimension.anxiety;
    } else if (avdMean >= 3.5 && anxMean < 3.5) {
      target = Dimension.avoidance;
    } else if (anxMean >= 3.5 && avdMean >= 3.5) {
      target = Dimension.none; // Consider paradox probes for disorganized
    } else {
      target = Dimension.none; // Look for secure confirmation
    }

    // Get unseen questions
    final unseen = pool.where((q) => !answers.containsKey(q.id)).toList();
    if (unseen.isEmpty) return null;

    PersonalityQuestion? pick;

    if (target != Dimension.none) {
      // Look for questions in the target dimension
      pick = unseen.firstWhere(
        (q) => q.dimension == target,
        orElse: () => unseen.firstWhere(
          (q) => q.reversed, // Fall back to secure probes
          orElse: () => unseen.first,
        ),
      );
    } else {
      // Target is none - look for secure reversed or paradox probes
      if (anxMean >= 3.5 && avdMean >= 3.5) {
        // High both - prefer paradox probes
        pick = unseen.firstWhere(
          (q) => q.dimension == Dimension.none && q.id.contains('PX'),
          orElse: () => unseen.firstWhere(
            (q) => q.dimension == Dimension.none,
            orElse: () => unseen.first,
          ),
        );
      } else {
        // Low both - prefer secure confirmation
        pick = unseen.firstWhere((q) => q.reversed, orElse: () => unseen.first);
      }
    }

    return pick;
  }

  /// Get the most diagnostic question for the current response pattern.
  ///
  /// This version considers both provisional scores AND response consistency
  /// to pick questions that will provide maximum information gain.
  static PersonalityQuestion? pickMostDiagnostic(
    Map<String, int> answers,
    List<PersonalityQuestion> pool, {
    double consistencyThreshold = 0.8,
  }) {
    final unseen = pool.where((q) => !answers.containsKey(q.id)).toList();
    if (unseen.isEmpty) return null;

    // Calculate response consistency within each dimension
    double calculateConsistency(Dimension dim) {
      final responses = pool
          .where((q) => q.dimension == dim && answers.containsKey(q.id))
          .map((q) => answers[q.id]!)
          .toList();

      if (responses.length < 2) return 1.0;

      final mean = responses.reduce((a, b) => a + b) / responses.length;
      final variance =
          responses
              .map((r) => (r - mean) * (r - mean))
              .reduce((a, b) => a + b) /
          responses.length;

      // Convert variance to consistency (0-1, higher = more consistent)
      return (1.0 / (1.0 + variance)).clamp(0.0, 1.0);
    }

    final anxConsistency = calculateConsistency(Dimension.anxiety);
    final avdConsistency = calculateConsistency(Dimension.avoidance);

    // If we have low consistency in a dimension, prioritize more questions there
    if (anxConsistency < consistencyThreshold &&
        avdConsistency >= consistencyThreshold) {
      final anxiousQuestions = unseen
          .where((q) => q.dimension == Dimension.anxiety)
          .toList();
      if (anxiousQuestions.isNotEmpty) return anxiousQuestions.first;
    }

    if (avdConsistency < consistencyThreshold &&
        anxConsistency >= consistencyThreshold) {
      final avoidantQuestions = unseen
          .where((q) => q.dimension == Dimension.avoidance)
          .toList();
      if (avoidantQuestions.isNotEmpty) return avoidantQuestions.first;
    }

    // Fall back to regular adaptive picking
    return pickNext(answers, pool);
  }

  /// Predict attachment quadrant from partial responses
  static String predictQuadrant(
    Map<String, int> answers,
    List<PersonalityQuestion> items,
  ) {
    // Calculate provisional scores using same logic as assessment
    final core = items.where(
      (q) =>
          (q.dimension == Dimension.anxiety ||
              q.dimension == Dimension.avoidance) &&
          !q.isAttentionCheck &&
          !q.isSocialDesirability,
    );

    double anxSum = 0, anxW = 0, avdSum = 0, avdW = 0;

    for (final q in core) {
      if (!answers.containsKey(q.id)) continue;

      final raw = answers[q.id]!.toDouble().clamp(1, 5);
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
    }

    // Map to 0-100 scale
    double map100(double m) => ((m - 1.0) / 4.0 * 100.0).clamp(0, 100);
    final anxMean = anxW > 0 ? (anxSum / anxW) : 3.0;
    final avdMean = avdW > 0 ? (avdSum / avdW) : 3.0;

    final anxiety = map100(anxMean).round();
    final avoidance = map100(avdMean).round();

    // Simple quadrant classification (using 45-55 gray zones)
    const low = 45, high = 55;

    if (anxiety <= low && avoidance <= low) return "secure";
    if (anxiety >= high && avoidance <= low) return "anxious";
    if (anxiety <= low && avoidance >= high) return "avoidant";
    if (anxiety >= high && avoidance >= high) return "disorganized_lean";

    return "mixed";
  }

  /// Get confidence in current prediction based on response count and consistency
  static double getConfidence(
    Map<String, int> answers,
    List<PersonalityQuestion> items,
  ) {
    final attachmentResponses = items
        .where(
          (q) =>
              (q.dimension == Dimension.anxiety ||
                  q.dimension == Dimension.avoidance) &&
              answers.containsKey(q.id),
        )
        .length;

    // Base confidence on response count (more responses = higher confidence)
    final countConfidence = (attachmentResponses / 8.0).clamp(0.0, 1.0);

    // Adjust for response pattern clarity
    final prediction = predictQuadrant(answers, items);
    final clarityBoost = prediction == "mixed" ? 0.0 : 0.2;

    return (countConfidence + clarityBoost).clamp(0.0, 1.0);
  }

  /// Generate explanation of current adaptive strategy
  static String explainStrategy(
    Map<String, int> answers,
    List<PersonalityQuestion> pool,
  ) {
    final next = pickNext(answers, pool);
    if (next == null) return "Assessment complete - no more questions needed.";

    final prediction = predictQuadrant(answers, pool);
    final confidence = getConfidence(answers, pool);

    final strategy = <String>[];

    strategy.add("Current prediction: $prediction");
    strategy.add("Confidence: ${(confidence * 100).round()}%");

    if (next.dimension == Dimension.anxiety) {
      strategy.add("Next question targets anxiety patterns");
    } else if (next.dimension == Dimension.avoidance) {
      strategy.add("Next question targets avoidance patterns");
    } else if (next.reversed) {
      strategy.add("Next question confirms secure attachment");
    } else {
      strategy.add("Next question explores mixed/paradox patterns");
    }

    return strategy.join(" • ");
  }
}
