# SuggestionChip Integration Guide & Troubleshooting

## Quick Integration Checklist

### ✅ 1. Delegate Setup (KeyboardController)
```swift
final class KeyboardController: UIViewController, SuggestionChipManagerDelegate {
    private lazy var chipManager = SuggestionChipManager(containerView: view)

    override func viewDidLoad() {
        super.viewDidLoad()
        chipManager.delegate = self
        chipManager.configure(suggestionBar: suggestionBarView) // Required for proper positioning
    }

    // MARK: - SuggestionChipManagerDelegate
    func suggestionChipDidExpand(_ chip: SuggestionChipView) {
        // Handle expansion: pause network polls, log analytics, etc.
        dbg("Chip expanded")
    }
    
    func suggestionChipDidDismiss(_ chip: SuggestionChipView) {
        // Handle dismissal: clear highlights, resume polls, etc.
        dbg("Chip dismissed")
    }
}
```

### ✅ 2. ToneSuggestionCoordinator Integration
```swift
// In your coordinator's delegate implementation:
func didUpdateSuggestions(_ suggestions: [String]) {
    guard let first = suggestions.first, !first.isEmpty else { return }
    
    DispatchQueue.main.async { [weak self] in
        guard let self = self else { return }
        // Option A: If you have tone as string
        self.chipManager.showSuggestionChip(text: first, toneString: self.currentToneString)
        
        // Option B: If you already have ToneStatus
        // self.chipManager.showSuggestion(text: first, tone: self.currentTone)
    }
}
```

### ✅ 3. Suggestion Bar Configuration
```swift
// Must be called for chips to anchor under the suggestion bar
chipManager.configure(suggestionBar: suggestionBarView)
```

## Common "Nothing Happens" Causes & Fixes

### 🚨 Issue: Delegate Never Set
**Symptom**: Chip appears but no expand/dismiss callbacks
**Fix**: 
```swift
chipManager.delegate = self // Must be set in viewDidLoad or init
```

### 🚨 Issue: Wrong Entry Point
**Symptom**: Backend sends suggestions but no chips appear
**Fix**: Ensure you call one of these methods:
```swift
// For string tone values ("alert"|"caution"|"clear"|"neutral")
chipManager.showSuggestionChip(text: suggestionText, toneString: uiToneString)

// For ToneStatus enum values
chipManager.showSuggestion(text: suggestionText, tone: uiToneStatus)
```

### 🚨 Issue: SuggestionBar Not Configured
**Symptom**: Chips appear at bottom instead of under suggestion bar
**Fix**:
```swift
chipManager.configure(suggestionBar: suggestionBarView)
```

### 🚨 Issue: Container View Mismatch
**Symptom**: Chips don't appear at all
**Fix**: Verify the container view is still in the view hierarchy
```swift
// In KeyboardController init or viewDidLoad:
chipManager = SuggestionChipManager(containerView: self.view)
```

### 🚨 Issue: Tone Mapping Missing
**Symptom**: Chips appear but with wrong colors/icons
**Fix**: Ensure `ToneStatus(from:)` handles all cases:
```swift
init(from string: String) {
    switch string.lowercased() {
    case "alert": self = .alert
    case "caution": self = .caution  
    case "clear": self = .clear
    case "neutral": self = .neutral
    default: self = .neutral // Fallback
    }
}
```

## Debug Tools

### Comprehensive State Check
```swift
#if DEBUG
chipManager.debugSuggestionChipState()
#endif
```

This prints:
- Container view existence
- Suggestion bar configuration
- Active chip state and visibility
- Chip text content
- View hierarchy info

### Integration Proof Snippet
Drop this into any suggestion result handler:
```swift
func handleSuggestionResult(_ result: SuggestionResult) {
    chipManager.handleSuggestionResult(text: result.previewText, uiToneString: result.uiTone)
    // This method includes automatic debug logging
}
```

### Minimal Test Integration
```swift
// Test chip display manually
func testChipDisplay() {
    chipManager.showSuggestionChip(text: "Test suggestion", toneString: "alert")
    #if DEBUG
    chipManager.debugSuggestionChipState()
    #endif
}
```

## Advanced Features

### Late Bar Attachment
If your suggestion bar is created after the chip manager:
```swift
func attachSuggestionBarIfNeeded(_ bar: UIView?) {
    chipManager.attachSuggestionBarIfNeeded(bar)
}
```

### Tone-Only Updates
If you receive tone updates without new suggestion text:
```swift
func updateChipTone(_ newTone: ToneStatus) {
    chipManager.updateTone(newTone)
}
```

## Signal Flow Diagram

```
Backend Suggestion → ToneSuggestionCoordinator → didUpdateSuggestions()
                                               ↓
KeyboardController (ToneSuggestionDelegate) → chipManager.showSuggestion()
                                               ↓
SuggestionChipManager → creates SuggestionChipView → anchors to container
                     ↓
User Interaction → SuggestionChipView callbacks → SuggestionChipManager
                                                ↓
                SuggestionChipManagerDelegate → KeyboardController callbacks
```

## Tone Status Reference

| Backend String | ToneStatus | Icon | Background Color |
|----------------|------------|------|------------------|
| "alert" | .alert | ⚠️ exclamationmark.triangle.fill | Red |
| "caution" | .caution | ⚠️ exclamationmark.triangle.fill | Yellow |
| "clear" | .clear | ✅ checkmark.seal.fill | Green |
| "neutral" | .neutral | (none) | Pink (dimmed) |

## Troubleshooting Commands

```swift
// Check if manager is properly initialized
print("Manager exists: \(chipManager != nil)")

// Check delegate setup
print("Delegate set: \(chipManager.delegate != nil)")

// Check container view
print("Container valid: \(chipManager.containerView?.superview != nil)")

// Force show test chip
chipManager.showSuggestionChip(text: "Debug test", toneString: "alert")

// Check active chip state
chipManager.debugSuggestionChipState()
```

## Performance Notes

- Chips automatically coalesce duplicate text to prevent spam
- Auto-hide after 18 seconds in collapsed state
- Expand prevents auto-hide until manually dismissed
- Shadow rendering disabled in Low Power Mode
- Animations respect Reduce Motion accessibility setting