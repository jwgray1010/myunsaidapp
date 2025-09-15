# Unsaid: AI Coding Agent Instructions

## Project Overview
Unsaid is a Flutter/Dart communication app with an iOS custom keyboard extension that provides real-time tone analysis and relationship insights. The app includes a TypeScript API backend hosted on Vercel and focuses on helping users communicate more effectively in relationships.

## Architecture & Key Components

### Core Structure
- **Flutter App**: Main mobile app (`lib/`) with personality assessment, insights dashboard, and onboarding
- **iOS Keyboard Extension**: Custom keyboard (`ios/UnsaidKeyboard/`) with real-time tone analysis
- **TypeScript API**: Vercel-hosted backend (`api/`) with tone analysis, suggestions, and user profiling
- **Data Assets**: JSON configuration files (`data/`) for tone patterns, attachment styles, and learning models

### Critical API Endpoints
- `api/v1/tone`: Real-time tone analysis returning `ui_tone` buckets (alert|caution|clear|neutral)
- `api/v1/suggestions`: Context-aware communication improvements
- `api/v1/communicator`: User profiling and attachment learning

## Development Patterns & Conventions

### Tone Analysis Response Structure
```typescript
// API responses MUST include these UI-facing fields:
{
  ui_tone: "alert" | "caution" | "clear" | "neutral", 
  ui_distribution: { clear: 0.2, caution: 0.3, alert: 0.5 },
  client_seq: number, // for last-writer-wins sequencing
  analysis: { primary_tone: string, confidence: number }
}
```

### iOS Coordinator Patterns
- **ToneSuggestionCoordinator**: Central networking and state management
- **Debounced Analysis**: 200ms keystroke debouncing + 250ms pause detection
- **Client Sequencing**: Monotonic `client_seq` prevents stale response overwrites
- **Defensive JSON Parsing**: Always use `safeString()`, `safeDouble()` helpers

### Swift Networking Guidelines
```swift
// Use JSONDecoder with snake_case conversion
decoder.keyDecodingStrategy = .convertFromSnakeCase

// Swift models should be camelCase
struct ToneResponse: Decodable {
    let uiTone: String         // maps from "ui_tone"
    let clientSeq: Int?        // maps from "client_seq"
}

// Never use try? - log decode errors explicitly
let resp = try decoder.decode(ToneResponse.self, from: data)
```

### UI Update Patterns
```swift
// Normalize tone labels to prevent UI corruption
func normalizeToneLabel(_ s: String) -> String {
    switch s.lowercased() {
    case "alert", "caution", "clear": return s
    case "angry", "hostile", "toxic": return "alert"
    case "frustrated", "anxious", "sad": return "caution"
    default: return "clear"
    }
}

// Always update UI on main thread
DispatchQueue.main.async {
    self.delegate?.didUpdateToneStatus(bucket)
    self.delegate?.didUpdateSuggestions(suggestions)
}
```

## Essential Build & Debug Commands

### Flutter Development
```bash
flutter pub get                    # Install dependencies
flutter run --debug               # Run debug build
flutter build ios --release       # Production iOS build
flutter test                      # Run Dart tests
```

### iOS Keyboard Extension
```bash
cd ios && pod install             # Install CocoaPods dependencies
# Build through Xcode - scheme: "UnsaidKeyboard"
# Debug keyboard: Settings > General > Keyboard > Add New Keyboard
```

### API Development
```bash
npm install                       # Install API dependencies
npm run dev                       # Local development server
vercel dev                        # Test Vercel functions locally
npm test                          # Run API tests
```

## Key File Relationships

### State Management Flow
1. `ios/UnsaidKeyboard/ToneSuggestionCoordinator.swift` → API calls
2. `api/v1/tone.ts` → `api/_lib/services/toneAnalysis.ts` 
3. `data/tone_patterns.json` & `data/tone_bucket_mapping.json` → UI bucketing
4. Flutter `lib/services/` → Shared preferences & personality data

### Data Dependencies
- Tone analysis requires `data/tone_patterns.json`, `data/evaluation_tones.json`
- Personality features need `data/attachment_learning.json`, `data/onboarding_playbook.json`
- UI buckets defined in `data/tone_bucket_mapping.json`

## Common Debugging Scenarios

### "No UI Tone Updates" Issues
1. Check `client_seq` in request/response logs
2. Verify `JSONDecoder.keyDecodingStrategy = .convertFromSnakeCase`
3. Add debug logging: `dbg("UI tone set to \(bucket) | raw=\(resp.analysis.primaryTone)")`
4. Confirm main thread UI updates

### API Response Failures
- Check `UNSAID_API_BASE_URL` and `UNSAID_API_KEY` in Info.plist
- Verify network connectivity with iOS simulator
- Test endpoints: `curl -X POST /api/v1/tone -d '{"text":"test"}'`

### Personality Data Issues
- Attachment styles: `secure|anxious|avoidant|disorganized`
- Data bridge: `lib/services/personality_data_bridge.dart`
- Shared storage: UserDefaults with app group containers

## Critical File Locations
- Keyboard coordinator: `ios/UnsaidKeyboard/ToneSuggestionCoordinator.swift`
- Main Flutter app: `lib/main.dart` with Provider state management
- Tone service: `api/_lib/services/toneAnalysis.ts`
- Configuration: `data/*.json` files for ML models and mappings
- Tests: `test-tone-integration.js`, `test-enhanced-contexts.js`

## Performance Considerations
- API calls debounced to 200ms to prevent network spam
- Tone responses cached for 5s to prevent duplicate analysis
- Network backoff on failures (exponential with 60s max)
- Swift async/await patterns for iOS 15+ compatibility