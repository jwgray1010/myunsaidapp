// Quick sanity script to exercise AttachmentAssessment + AssessmentIntegration
// Run with: flutter pub run lib/dev_assessment_sanity.dart

import 'data/attachment_assessment.dart';
import 'data/assessment_integration.dart';

Future<void> main() async {
  final Map<String, int> responses = {};
  for (final q in attachmentItems) {
    // choose middle value 3 unless limited options
    if (q.options.isNotEmpty) {
      responses[q.id] = q.options[(q.options.length / 2).floor()].value;
    } else {
      responses[q.id] = 3;
    }
  }
  for (final q in goalItems) {
    if (q.options.isNotEmpty) {
      responses[q.id] = q.options.first.value; // pick first option
    } else {
      responses[q.id] = 3;
    }
  }

  final result = AttachmentAssessment.run(responses);
  final merged = await AssessmentIntegration.selectConfiguration(
    result.scores,
    result.routing,
  );
  // ignore: avoid_print
  print('Scores: ${result.scores}');
  // ignore: avoid_print
  print('Routing primary: ${result.routing.primaryProfile}');
  // ignore: avoid_print
  print('Merged config summary: $merged');
}
