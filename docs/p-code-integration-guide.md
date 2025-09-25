# P-Code Classification System Integration Guide

## Overview
The P-Code system makes your `spacyLink` fields functional by providing intelligent classification and routing of therapy advice based on communication patterns.

## Architecture

### Core Components

1. **P-Taxonomy** (`api/_lib/services/p-taxonomy.ts`)
   - Defines 8 P-codes with semantic meanings
   - Pattern rules and keyword seeds for classification
   - Human-readable descriptions

2. **P-Classifier** (`api/_lib/services/p-classifier.ts`)
   - Rule-based classification engine
   - Pattern matching and keyword detection
   - Extensible for future ML integration

3. **Advice Router** (`api/_lib/services/advice-router.ts`)
   - Links P-code scores to therapy advice
   - Contextual scoring with tone/context bonuses
   - Severity threshold enforcement

4. **API Endpoint** (`api/v1/p-classify.ts`)
   - HTTP interface for P-code classification
   - Therapy advice routing
   - Real-time text analysis

## P-Code Definitions

| Code | Name | Purpose | Example Patterns |
|------|------|---------|------------------|
| P031 | Thread Management | Keep conversations focused | "TLDR", "one topic", "parking lot" |
| P044 | Clarity Checks | Verify understanding | "assumption", "what did you mean", "clarify" |
| P061 | Boundary Setting | Set limits, concrete asks | "boundary", "not available", "one request" |
| P099 | Validation | Reflective listening | "I hear", "makes sense", "that sounds" |
| P122 | Safety Control | Manage intensity | "cool down", "pause", "revisit" |
| P170 | Planning | Set expectations, timelines | "check-in", "by when", "cadence" |
| P217 | Repair | Take responsibility, appreciate | "I own my part", "thanks for", "appreciate" |
| P981 | Context Labeling | Organize conversation scope | "scope", "lane", "process map" |

## Usage Examples

### 1. Direct P-Code Classification
```typescript
import { classifyP } from './api/_lib/services/p-classifier';

const result = await classifyP(
  "This thread is spinning—can we do a TLDR and one question?",
  { threshold: 0.45 }
);

// Result: { p_scores: { P031: 0.6, P044: 0.3 }, method: 'enhanced_rules' }
```

### 2. Therapy Advice Routing
```typescript
import { pickAdvice } from './api/_lib/services/advice-router';

const advice = await pickAdvice(
  "I'm feeling overwhelmed by this conversation",
  therapyAdviceArray,
  { tone: "alert", context: "safety", maxResults: 3 }
);

// Returns top-matched advice based on spacyLink P-codes
```

### 3. API Endpoint Usage
```bash
# Classify text only
curl -X POST /api/v1/p-classify \
  -H "Content-Type: application/json" \
  -d '{"text": "Can we pause and revisit this later?", "classifyOnly": true}'

# Get therapy advice recommendations
curl -X POST /api/v1/p-classify \
  -H "Content-Type: application/json" \
  -d '{
    "text": "This is getting confusing. What did you mean by that?",
    "tone": "frustrated",
    "context": "conflict",
    "includeScores": true
  }'
```

## Integration with Existing Systems

### 1. Update Suggestions Service
```typescript
// In your suggestions.ts service
import { pickAdvice } from './advice-router';

// Replace or enhance existing advice selection
const pCodeAdvice = await pickAdvice(
  inputText, 
  therapyAdviceData,
  { tone: detectedTone, context: primaryContext }
);
```

### 2. iOS Keyboard Integration
```swift
// Add P-code classification to ToneSuggestionCoordinator
struct PCodeRequest: Codable {
    let text: String
    let tone: String?
    let context: String?
}

// Call new endpoint
let response = try await networkService.post("/api/v1/p-classify", body: request)
```

### 3. Flutter App Integration
```dart
// Add P-code service to your existing tone analysis
class PCodeService {
  Future<PClassifyResponse> classifyText(String text, {
    String? tone,
    String? context,
  }) async {
    // HTTP call to /api/v1/p-classify
  }
}
```

## Testing

Run the test script to validate the system:
```bash
node test-p-classification.js
```

This will test:
- P-code pattern matching
- Classification accuracy
- Advice routing integration

## Performance Considerations

1. **Rule-Based Speed**: Current implementation is fast (~1-2ms)
2. **Caching**: P-code patterns are precompiled
3. **Serverless Ready**: No external dependencies
4. **Future ML**: Ready for @xenova/transformers integration

## Extending the System

### Adding New P-Codes
1. Update `P_MAP` in `p-taxonomy.ts`
2. Add patterns to `P_PATTERNS`
3. Update therapy advice `spacyLink` arrays
4. Add test cases

### Enhanced Classification
- Replace rule-based with ML when needed
- Add multi-language support
- Implement confidence scoring

## Migration Strategy

1. **Phase 1**: Deploy P-code system alongside existing suggestions
2. **Phase 2**: A/B test P-code routing vs current system  
3. **Phase 3**: Gradually replace with P-code routing
4. **Phase 4**: Remove unused `spacyLink` references or enhance them

Your `spacyLink` arrays in therapy advice are now functional and will route intelligently based on communication patterns detected in user text!