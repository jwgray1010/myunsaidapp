//
//  KeyboardController.swift
//  UnsaidKeyboard
//
//  SIMPLIFIED COORDINATOR VERSION
//  Main keyboard controller that orchestrates managers and services
//  Following the architecture documented at the top of the original file
//

import Foundation
import os.log
import AudioToolbox
import UIKit
import CryptoKit

// MARK: - Analysis Result for switch-in analysis
struct AnalysisResult {
    let topSuggestion: String?
    let rewrite: String?
    let confidence: Double
}

// MARK: - Switch-in Analyzer
final class SwitchInAnalyzer {
    static let shared = SwitchInAnalyzer()
    
    // LRU-ish in-memory cache: hash(text) -> result
    private var cache: [String: AnalysisResult] = [:]
    private var order: [String] = []
    private let maxEntries = 64
    private let workQ = DispatchQueue(label: "switchin.analyzer", qos: .userInitiated)
    
    private init() {}
    
    func prewarm() {
        // Build regexes, load small dictionaries, prime NL models, etc.
        // You can add additional setup here if needed.
    }

    // MARK: - First-time User Management

}

// MARK: - Simple Apple-like candidate strip
final class SpellCandidatesStrip: UIView {
    private let stack = UIStackView()
    private var onTap: ((String) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor.systemGray6.withAlphaComponent(0.8)
        layer.cornerRadius = 8
        stack.axis = .horizontal
        stack.distribution = .fillEqually
        stack.alignment = .center  // ⬅️ Fix: center buttons vertically to avoid constraint conflicts
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 0), // Full width - no margins
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: 0), // Full width - no margins
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4)
        ])
    }
    
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setSuggestions(_ suggestions: [String], onTap: @escaping (String) -> Void) {
        self.onTap = onTap
        if suggestions.isEmpty {
            if !isHidden { isHidden = true; stack.arrangedSubviews.forEach { $0.removeFromSuperview() } }
            return
        }
        isHidden = false
        // If unchanged, do nothing
        let current = stack.arrangedSubviews.compactMap { ($0 as? UIButton)?.title(for: .normal) }
        let new = Array(suggestions.prefix(3))
        guard current != new else { return }
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        new.forEach { stack.addArrangedSubview(pill($0)) }
    }
    
    func updateCandidates(_ suggestions: [String]) {
        setSuggestions(suggestions, onTap: self.onTap ?? { _ in })
    }
    
    func setSpellCorrectionHandler(_ handler: @escaping (String) -> Void) {
        self.onTap = handler
    }

    private func pill(_ title: String) -> UIButton {
        // Use specialized spell strip button factory to avoid constraint conflicts
        let button = KeyButtonFactory.makeSpellStripButton(title: title)
        button.addTarget(self, action: #selector(pillButtonPressed(_:)), for: .touchUpInside)
        return button
    }
    
    @objc private func pillButtonPressed(_ sender: UIButton) {
        guard let title = sender.title(for: .normal) else { return }
        onTap?(title)
    }
}

// MARK: - Shift State Management
enum ShiftState {
    case enabled   // shift is on (capital letters)
    case disabled  // shift is off (lowercase letters)
    case locked    // caps lock
}

// MARK: - Main Keyboard Controller (Simplified Coordinator)
@MainActor
final class KeyboardController: UIView,
                                ToneSuggestionDelegate,
                                UIInputViewAudioFeedback,
                                UIGestureRecognizerDelegate,
                                DeleteManagerDelegate,
                                SuggestionChipManagerDelegate,
                                SpaceHandlerDelegate,
                                SpellCheckerIntegrationDelegate,
                                SecureFixManagerDelegate {

    // MARK: - Services and Managers
    private var coordinator: ToneSuggestionCoordinator?
    private var isNetworkReachable = true // Track network state for UI updates
    
    // MARK: - Thread context and dispatcher
    private var currentThreadID: String = UUID().uuidString
    weak var toneSuggestionDispatcher: ToneSuggestionDispatcher?
    
    // MARK: - Suggestion Gating
    internal var suggestionsArmed = false // Accessible to SuggestionChipManager
    private var suggestionCooldownUntil: CFTimeInterval = 0
    private let suggestionCooldown: CFTimeInterval = 0.8
    
    // MARK: - Configuration and Logging
    private var didConfigure = false
    private let logger = Logger(subsystem: "com.example.unsaid.UnsaidKeyboard", category: "KeyboardController")
    #if DEBUG
    private let logGate = LogGate(0.40) // 400ms collapse window
    #endif
    
    // MARK: - In-flight tracking
    private var toneRequestInFlight = false
    
    // Managers (UIKit-heavy, per-feature)
    private let deleteManager = DeleteManager()
    private let keyPreviewManager = KeyPreviewManager()
    private let spaceHandler = SpaceHandler()
    private let secureFixManager = SecureFixManager()
    private lazy var suggestionChipManager = SuggestionChipManager(containerView: self)
    
    // Services (Logic, async, networking)
    private let spellCheckerIntegration = SpellCheckerIntegration()
    
    // MARK: - OpenAI Configuration
    private var openAIAPIKey: String {
        // First try App Group (recommended approach)
    let apiKey = AppGroups.shared.string(forKey: "OPENAI_API_KEY")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if !apiKey.isEmpty { return apiKey }
        
        // Fallback to Info.plist for backward compatibility
        let extBundle = Bundle(for: KeyboardController.self)
        let mainBundle = Bundle.main
        let fromExt = extBundle.object(forInfoDictionaryKey: "OPENAI_API_KEY") as? String
        let fromMain = mainBundle.object(forInfoDictionaryKey: "OPENAI_API_KEY") as? String
        return (fromExt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? fromMain?.trimmingCharacters(in: .whitespacesAndNewlines)) ?? ""
    }
    
    // MARK: - Advanced Haptic Integration
    private var isHapticSessionStarted = false
    private var hapticIdleTimer: DispatchSourceTimer?
    private let hapticSessionTimeout: TimeInterval = 10.0 // Stop session after 10s of inactivity
    
    // Haptic debouncing to prevent double-buzz
    private var lastHapticAt: CFTimeInterval = 0
    private var lastHapticPrepareAt: CFTimeInterval = 0
    private let hapticMinGap: CFTimeInterval = 0.06 // 60ms
    private let hapticPrepareMinGap: CFTimeInterval = 0.2 // 200ms

    // Unified haptic feedback (replaced individual UIImpactFeedbackGenerator)    // MARK: - Error Message Debouncing
    private var lastErrorShownAt = Date.distantPast
    private let errorCooldown: TimeInterval = 5

    // MARK: - Debug State
    private class DebugState {
        static let shared = DebugState()
        var isOn = false
        private init() {}
    }
    
    // MARK: - Debounce & Coalesce
    private var analyzeTask: Task<Void, Never>?
    
    // MARK: - Word-Boundary Analysis Gating
    private var wordDirty = false           // set while user is editing a word
    private var idleToken: DispatchSourceTimer? // short idle fallback
    private let idleWordMs: TimeInterval = 0.45  // "paused typing" = analyze
    
    // MARK: - Text Analysis Gating
    
    /// Determines if text is substantial enough to warrant tone analysis
    private func shouldAnalyze(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Too short overall
        if trimmed.count < 4 {
            print("📏 Analysis skipped: text too short (\(trimmed.count) chars)")
            return false
        }
        
        // Single word that's too short
        let words = trimmed.split(separator: " ")
        if words.count == 1 && trimmed.count < 5 {
            print("📏 Analysis skipped: single short word '\(trimmed)'")
            return false
        }
        
        return true
    }
    
    // MARK: - Security Utilities
    
    /// Redacts API keys/tokens for safe logging
    private func redact(_ token: String) -> String {
        guard !token.isEmpty else { return "EMPTY" }
        guard token.count > 10 else { return "TOO_SHORT" }
        let prefix = token.prefix(6)
        let suffix = token.suffix(4)
        return "\(prefix)…\(suffix)"
    }
    
    // MARK: - Router Pattern for Sentence-Aware Analysis
    
    /// Captures the full text snapshot from the document proxy
    private func snapshotFullText() -> String {
        guard let proxy = textDocumentProxy else { return "" }
        let before = proxy.documentContextBeforeInput ?? ""
        let after = proxy.documentContextAfterInput ?? ""
        return before + after
    }
    
    /// Hash just the visible window we already keep (~800 chars)
    private func snapshotHash() -> Int {
        var hasher = Hasher()
        hasher.combine(beforeContext)
        hasher.combine(afterContext)
        return hasher.finalize()
    }
    
    /// Optimized spelling refresh that only triggers on meaningful content changes
    private func refreshSpellingIfMeaningful() {
        let currentText = beforeContext + afterContext
        let h = currentText.hash
        if h == lastSpellTextHash { return } // no-op
        lastSpellTextHash = h
        spellCheckerIntegration.refreshSpellCandidates(for: currentText)
    }
    
    // MARK: - Word-Boundary Detection
    
    private func markTypingActivity() {
        // restart idle timer whenever a non-boundary key is pressed
        idleToken?.cancel()
        idleToken = DispatchSource.makeTimerSource(queue: .main)
        idleToken?.schedule(deadline: .now() + idleWordMs)
        idleToken?.setEventHandler { [weak self] in
            guard let self = self else { return }
            if self.wordDirty {                 // only fire if a word changed
                self.wordDirty = false
                self.routeIfChanged(lastInserted: nil, isDeletion: false, urgent: false)
            }
            self.idleToken?.cancel()
            self.idleToken = nil
        }
        idleToken?.resume()
    }

    private func isWordChar(_ s: String) -> Bool {
        return s.count == 1 && s.rangeOfCharacter(from: CharacterSet.letters.union(.decimalDigits).union(CharacterSet(charactersIn: "'''"))) != nil
    }

    private func isWordBoundary(_ s: String) -> Bool {
        return s == " " || s == "\n" || [".","!","?",",",";",":"].contains(s)
    }
    
    /// Optimized router that skips work when nothing changed
    private func routeIfChanged(lastInserted: String?, isDeletion: Bool, urgent: Bool) {
        refreshContext() // already trims to 600/200; cheap string ops
        let h = snapshotHash()
        if h == lastRouterSnapshotHash,
           lastRouterTrigger.inserted == lastInserted,
           lastRouterTrigger.deletion == isDeletion,
           !urgent {
            return // no-op, nothing changed from router's POV
        }
        lastRouterSnapshotHash = h
        lastRouterTrigger = (lastInserted, isDeletion)
        scheduleAnalysisRouter(lastInserted: lastInserted, isDeletion: isDeletion, urgent: urgent)
    }
    
    /// Router method that calls the new sentence-aware coordinator API
    private func scheduleAnalysisRouter(lastInserted: String? = nil, isDeletion: Bool = false, urgent: Bool = false) {
        print("🔄 DEBUG: scheduleAnalysisRouter called - lastInserted: \(lastInserted ?? "nil"), isDeletion: \(isDeletion), urgent: \(urgent)")
        
        // Check network connectivity first
        guard isNetworkReachable else {
            print("📶 DEBUG: Network unreachable, skipping analysis")
            return
        }
        
        guard let coordinator = coordinator else {
            print("❌ DEBUG: coordinator is nil in scheduleAnalysisRouter")
            return
        }
        
        print("✅ DEBUG: coordinator exists and network is reachable, proceeding with full-text analysis")
        
        // Cancel any existing analysis task (debouncing handled by ToneSuggestionCoordinator)
        analyzeTask?.cancel()
        
        // Get full text for document-level analysis
        let fullText = snapshotFullText()
        print("📝 DEBUG: Full text snapshot: '\(String(fullText.prefix(100)))...' (length: \(fullText.count))")
        
        // Special case: If text is completely empty, reset to neutral
        // Only reset if this appears to be an intentional clear (not momentary empty proxy)
        let trimmedText = fullText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedText.isEmpty {
            // Guard against momentary empty snapshots - only reset if we previously had substantial text
            if currentText.trimmingCharacters(in: .whitespacesAndNewlines).count > 10 {
                print("🔄 DEBUG: Text cleared from substantial content, resetting tone to neutral")
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.didUpdateToneStatus("neutral")
                    self.suggestionChipManager.dismissCurrentChip()
                    self.suggestionsArmed = false        // ← critical
                    self.coordinator?.resetToCleanState()
                }
            } else {
                print("🚫 DEBUG: Ignoring momentary empty snapshot (previous text was minimal)")
            }
            return
        }
        
        // Gate analysis for micro-tokens (same as before)
        guard shouldAnalyze(fullText) else {
            print("🚫 Analysis skipped: text doesn't meet minimum requirements")
            return
        }
        
        #if DEBUG
        let preview = String(fullText.prefix(60))
        if logGate.allow("router", preview) {
            KBDLog("� Full-text analysis: '\(preview)…' inserted='\(lastInserted ?? "none")' deletion=\(isDeletion) urgent=\(urgent)", .debug, "KeyboardController")
        }
        #endif
        
        // Determine trigger reason based on context
        let triggerReason: String
        if urgent {
            triggerReason = isDeletion ? "urgent_deletion" : "urgent_input"
        } else if isDeletion {
            triggerReason = "deletion_pause" // Updated: deletion with idle
        } else if let inserted = lastInserted {
            // Check for punctuation that should trigger immediate analysis
            if coordinator.shouldTriggerImmediate(for: String(inserted)) {
                triggerReason = "sentence_punct"
            } else if isWordBoundary(String(inserted)) {
                triggerReason = "word_boundary"
            } else {
                triggerReason = "input_activity"
            }
        } else {
            triggerReason = "idle_pause"
        }
        
        // Use ToneSuggestionCoordinator for document-level analysis with word-boundary optimization
        if urgent || triggerReason == "sentence_punct" {
            // Immediate analysis for urgent cases or sentence punctuation
            coordinator.scheduleImmediateFullTextAnalysis(fullText: fullText, triggerReason: triggerReason)
        } else if triggerReason == "idle_pause" || triggerReason == "word_boundary" || triggerReason == "deletion_pause" {
            // Use word-boundary API for idle triggers, word boundaries, and deletion pauses
            coordinator.analyzeOnWordBoundary(fullText: fullText, reason: triggerReason)
        } else {
            // Fallback to regular debounced analysis for continuous typing
            coordinator.scheduleFullTextAnalysis(fullText: fullText, triggerReason: triggerReason)
        }
        
        print("🚀 DEBUG: Full-text analysis scheduled with ToneSuggestionCoordinator - reason: \(triggerReason)")
    }
    
    // Unified haptic feedback method with instant micro-haptics
    private func performHapticFeedback() {
        let now = CACurrentMediaTime()
        if now - lastHapticAt < hapticMinGap { return }   // debounce
        lastHapticAt = now

        // Use unified haptic controller instead of individual generator
        if now - lastHapticPrepareAt >= hapticPrepareMinGap {
            UnifiedHapticsController.shared.start()
            lastHapticPrepareAt = now
        }
        UnifiedHapticsController.shared.mediumTap()
        
        // Keep session timer behavior as-is (optional)
        if !isHapticSessionStarted {
            coordinator?.startHapticSession()
            isHapticSessionStarted = true
        }
        resetHapticSessionTimer()
    }
    
    private func resetHapticSessionTimer() {
        hapticIdleTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + hapticSessionTimeout, leeway: .milliseconds(200))
        timer.setEventHandler { [weak self] in self?.stopHapticSessionDueToInactivity() }
        timer.resume()
        hapticIdleTimer = timer
    }
    
    private func stopHapticSessionDueToInactivity() {
        guard isHapticSessionStarted else { return }
        coordinator?.stopHapticSession()
        isHapticSessionStarted = false
        hapticIdleTimer?.cancel()
        hapticIdleTimer = nil
    }
    
    var enableInputClicksWhenVisible: Bool { true }

    // MARK: - Spell checking
    private let spellStrip = SpellCandidatesStrip()

    // MARK: - Parent VC
    private weak var parentInputVC: UIInputViewController?

    // MARK: - UI Components
    private var suggestionBar: UIView!
    private var toneButtonBackground: UIView?
    private var toneButton: UIButton?
    private var undoButton: UIButton?
    private var keyboardStackView: UIStackView?

    // Tone badge visuals
    private var toneAnimator: UIViewPropertyAnimator?
    private let toneShadowOpacity: Float = 0.22
    private var toneGradient: CAGradientLayer?

    // Control buttons
    private var spaceButton: UIButton?
    private var quickFixButton: UIButton?
    private var globeButton: UIButton?
    private var modeButton: UIButton?
    private var symbolsButton: UIButton?
    private var returnButton: UIButton?
    private var deleteButton: UIButton?
    private var shiftButton: UIButton?

    // State
    private var currentMode: KeyboardMode = .letters
    private var shiftState: ShiftState = .enabled // Start with caps (iOS default)
    private var lastShiftTapAt: TimeInterval = 0
    private var lastShiftUpdateTime: Date = .distantPast
    private var currentTone: ToneStatus = .neutral
    
    // Legacy shift properties for compatibility (will be removed)
    private var isShifted: Bool { shiftState == .enabled || shiftState == .locked }
    private var isCapsLocked: Bool { shiftState == .locked }
    
    // Host trait sync
    private var smartQuotesEnabled = true
    private var smartDashesEnabled = true
    private var smartInsertDeleteEnabled = true

    // Text cache
    private var currentText: String = ""
    
    // Tone tracking for SecureFix gating
    private var lastToneStatusString: String = "neutral"
    private var currentUITone: ToneStatus = .neutral

    // Performance optimization state
    private var lastSuggestionFetchTime: TimeInterval = 0
    private var activeSuggestionTask: Task<Void, Never>?
    
    // Neutral idle gate to prevent immediate snap-back
    private var lastToneChangeAt = CACurrentMediaTime()
    private let clearNeutralIdleMs: CFTimeInterval = 1.2

    // Layout constants
    private let verticalSpacing: CGFloat = 8
    private let horizontalSpacing: CGFloat = 4  // Reduced from 6 to 4 for tighter spacing
    private let sideMargins: CGFloat = 3  // Reduced from 8 to 3 for fuller screen width
    
    // First-time user tutorial management
    private static let keyboardUsedKey = "UnsaidKeyboardHasBeenUsed"
    private lazy var isFirstLaunch: Bool = { !AppGroups.shared.bool(forKey: Self.keyboardUsedKey) }()

    // Rows
    private let topRowKeys = ["q","w","e","r","t","y","u","i","o","p"]
    private let midRowKeys = ["a","s","d","f","g","h","j","k","l"]
    private let botRowKeys = ["z","x","c","v","b","n","m"]
    private let topRowNumbers = ["1","2","3","4","5","6","7","8","9","0"]
    private let midRowNumbers = ["-","/",":",";","(",")","$","&","@","\""]
    private let botRowNumbers = [".",",","?","!","'"]
    private let topRowSymbols = ["[","]","{","}","#","%","^","*","+","="]
    private let midRowSymbols = ["_","\\","|","~","<",">","€","£","¥","•"]
    private let botRowSymbols = [".",",","?","!","'"]

    // QWERTY stagger references for dynamic margin calculation
    private weak var topRowRef: UIStackView?
    private weak var midRowRef: UIStackView?

    // Context refresh properties
    private var beforeContext: String = ""
    private var afterContext: String = ""
    private var didInitialSwitchAnalyze = false
    
    // Router snapshot guards to prevent over-invoking analysis
    private var lastRouterSnapshotHash: Int = 0
    private var lastRouterTrigger: (inserted: String?, deletion: Bool) = (nil, false)
    
    // Spell refresh optimization
    private var lastSpellTextHash: Int = 0
    
    // Safe area constraint management
    private var safeAreaBottomConstraint: NSLayoutConstraint?

    // MARK: - Convenience
    private var textDocumentProxy: UITextDocumentProxy? { parentInputVC?.textDocumentProxy }

    // MARK: - Network Management
    private func startNetworkMonitoring() {
        NetworkGate.shared.start { [weak self] reachable in
            DispatchQueue.main.async {
                self?.handleNetworkStateChange(reachable: reachable)
            }
        }
    }
    
    private func handleNetworkStateChange(reachable: Bool) {
        print("🌐 DEBUG: Network state changed to \(reachable ? "ONLINE" : "OFFLINE")")
        isNetworkReachable = reachable
        
        // Update tone button state based on connectivity
        if let toneButton = toneButton {
            toneButton.isEnabled = reachable
            // REMOVED: Don't force-neutral on brief offline - just disable button
            // This prevents tone state corruption during network blips
        }
        
        // Update quickFix button state based on connectivity
        if let quickFix = quickFixButton {
            quickFix.isEnabled = reachable
            quickFix.alpha = reachable ? 1.0 : 0.5
        }
        
        // Dismiss suggestion chips when going offline
        if !reachable {
            suggestionChipManager.dismissCurrentChip()
            suggestionsArmed = false
        } else {
            // When coming back online, re-attempt analysis if there's text
            let fullText = snapshotFullText()
            if !fullText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                routeIfChanged(lastInserted: nil, isDeletion: false, urgent: true)
            }
        }
    }

    // MARK: - Lifecycle
    override var intrinsicContentSize: CGSize {
        // Width: let the system take full screen width
        // Height: let constraints/safe area drive height (suggestion bar + keyboard + margins)
        return CGSize(width: UIView.noIntrinsicMetric, height: UIView.noIntrinsicMetric)
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    func configure(with inputVC: UIInputViewController) {
        guard !didConfigure else {
            KBDLog("⚠️ configure(with:) called again; ignoring duplicate", .warn, "KeyboardController")
            return
        }
        didConfigure = true
        
        KBDLog("✅ KeyboardController.configure() OK", .info, "KeyboardController")
        
        parentInputVC = inputVC
        coordinator = ToneSuggestionCoordinator()
        let coordId = UUID().uuidString.prefix(8) // Short ID for readability
        #if DEBUG
        coordinator?.debugInstanceId = String(coordId)
        #endif
        KBDLog("🔧 Coordinator initialized id=\(coordId)", .info, "KeyboardController")
        coordinator?.delegate = self
        
        // Wire up coordinator as manual tone suggestion dispatcher
        toneSuggestionDispatcher = coordinator
        
        KBDLog("📄 ToneCoordinator ready for full-text analysis", .info, "KeyboardController")
        
        // Start network monitoring
        startNetworkMonitoring()
        
        // Test API connectivity
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.coordinator?.pingAPI()
        }
        
        refreshContext()
        syncHostTraits()
        
        // Initialize shift state based on context
        updateShiftForContext()
        
        // Mark keyboard as accessed (disable first-time tutorial messages)
        markKeyboardAsUsed()
        
        // Ensure tone button is visible immediately after configuration
        DispatchQueue.main.async { [weak self] in
            if let button = self?.toneButton {
                button.isHidden = false
                button.alpha = 1.0
            }
        }
        
        // App Group sanity check
    let test = AppGroups.shared
    test.set(true, forKey: "groupRoundtrip")
    let ok = test.bool(forKey: "groupRoundtrip")
        KBDLog("App Group roundtrip ok: \(ok)", .info, "KeyboardController")
        
        // Debug API configuration
        let extBundle = Bundle(for: KeyboardController.self)
        let baseURL = extBundle.object(forInfoDictionaryKey: "UNSAID_API_BASE_URL") as? String ?? "NOT FOUND"
        let apiKey = extBundle.object(forInfoDictionaryKey: "UNSAID_API_KEY") as? String ?? "NOT FOUND"
        KBDLog("🔧 API Config - Base URL: \(baseURL)", .debug, "KeyboardController")
        KBDLog("🔧 API Config - API Key: \(redact(apiKey))", .debug, "KeyboardController")
        KBDLog("🔧 Coordinator initialized: \(self.coordinator != nil)", .debug, "KeyboardController")
        
        // Note: Removed immediate analysis ping to prevent any startup tone changes
        // coordinator?.forceImmediateAnalysis("ping")
        
        // NOTE: Removed automatic tone cycling for better UX
        // Manual tone test still available via long press on tone button
        
        // Note: Removed DEBUG testToneAPIWithDebugText() call to prevent
        // automatic tone cycling when keyboard opens
    }
    
    @MainActor
    func hostDidAppear() {
        // Host view is now on-screen, ensure UI components are visible and properly initialized
        KBDLog("🎬 KeyboardController hostDidAppear called", .info, "KeyboardController")
        
        // Ensure suggestion bar is visible and ready
        if let bar = suggestionBar {
            bar.isHidden = false
            bar.alpha = 1.0
            KBDLog("✅ Suggestion bar made visible", .debug, "KeyboardController")
        }
        
        // Ensure tone button is visible and responsive
        if let button = toneButton {
            button.isHidden = false
            button.alpha = 1.0
            ensureToneButtonVisible()
            KBDLog("✅ Tone button made visible", .debug, "KeyboardController")
        }
        
        // Subscribe to tone updates now that UI is ready
        coordinator?.delegate = self
        
        // Perform any additional UI refresh that should happen after host appears
        layoutIfNeeded()
    }
    
    deinit {
        hapticIdleTimer?.cancel()
        idleToken?.cancel() // Cancel word-boundary idle timer
        if isHapticSessionStarted {
            coordinator?.stopHapticSession()
        }
        coordinator?.resetToCleanState() // ensure compose ends
    }
    
    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        updateAppearance(traitCollection.userInterfaceStyle == .dark ? .dark : .default)
    }

    private func commonInit() {
        KBDLog("🔧 KeyboardController.commonInit() starting...", .debug, "KeyboardController")
        
        // Start unified haptic system for responsive feedback
        UnifiedHapticsController.shared.start()
        
        KBDLog("🔧 Setting up delegates...", .debug, "KeyboardController")
        setupDelegates()
        KBDLog("✅ Delegates setup complete", .debug, "KeyboardController")
        
        KBDLog("🔧 Setting up suggestion bar...", .debug, "KeyboardController")
        setupSuggestionBar()    // create it first
        KBDLog("✅ Suggestion bar setup complete", .debug, "KeyboardController")
        
        KBDLog("🔧 Setting up keyboard layout...", .debug, "KeyboardController")
        setupKeyboardLayout()   // then layout that pins to it
        KBDLog("✅ Keyboard layout setup complete", .debug, "KeyboardController")
        
        #if DEBUG
        setupDebugGestures()
        #endif
        
        KBDLog("✅ KeyboardController.commonInit() OK", .info, "KeyboardController")
    }
    
    #if DEBUG
    private var lastDebugTime: Date = Date.distantPast
    private let debugCooldownInterval: TimeInterval = 10.0  // 10 seconds cooldown
    
    private func setupDebugGestures() {
        // Add a four-finger tap gesture to trigger debug tests
        let debugGesture = UITapGestureRecognizer(target: self, action: #selector(handleDebugGesture))
        debugGesture.numberOfTouchesRequired = 4
        debugGesture.numberOfTapsRequired = 2
        addGestureRecognizer(debugGesture)
        KBDLog("🔧 Debug gesture added: Four-finger double-tap to run debug tests (10s cooldown)", .debug, "KeyboardController")
    }
    
    @objc private func handleDebugGesture() {
        let now = Date()
        let timeSinceLastDebug = now.timeIntervalSince(lastDebugTime)
        
        if timeSinceLastDebug < debugCooldownInterval {
            let remaining = debugCooldownInterval - timeSinceLastDebug
            KBDLog("🔍 DEBUG COOLDOWN: \(String(format: "%.1f", remaining))s remaining", .warn, "KeyboardController")
            return
        }
        
        lastDebugTime = now
        toggleDebugHUD()
    }
    
    @MainActor
    private func toggleDebugHUD() {
        DebugState.shared.isOn.toggle()
        
        if DebugState.shared.isOn {
            KBDLog("🔍 DEBUG MODE ON - Running system diagnostics...", .info, "KeyboardController")
            coordinator?.dumpAPIConfig()
            coordinator?.debugCoordinatorState()
            coordinator?.debugPing()
            // Optional: coordinator?.debugTestToneAPI()
        } else {
            KBDLog("🔍 DEBUG MODE OFF", .info, "KeyboardController")
        }
    }
    #endif
    
    private func setupDelegates() {
        // Setup all manager delegates
        deleteManager.delegate = self
        suggestionChipManager.delegate = self
        spaceHandler.delegate = self
        spellCheckerIntegration.delegate = self
        secureFixManager.delegate = self
    }
    
    override func willMove(toSuperview newSuperview: UIView?) {
        super.willMove(toSuperview: newSuperview)
        // Ensure tone button is visible when moving to superview
        if newSuperview != nil {
            ensureToneButtonVisible()
        }
    }
    
    override func removeFromSuperview() {
        keyPreviewManager.dismissAllKeyPreviews()
        super.removeFromSuperview()
    }
    
    override func layoutSubviews() {
        super.layoutSubviews()
        
        // Ensure tone button remains visible after layout
        ensureToneButtonVisible()
        
        // Apply QWERTY stagger after layout (only for letters mode)
        if currentMode == .letters {
            applyQwertyStaggerIfNeeded()
        }
        
        guard let bg = toneButtonBackground, let g = toneGradient else { return }
        let newBounds = bg.bounds.integral
        guard g.frame != newBounds else { return } // ✨ skip redundant work
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        g.frame = nonZeroRect(newBounds)
        g.cornerRadius = nonZero(newBounds.height) / 2
        bg.layer.shadowPath = UIBezierPath(roundedRect: newBounds, cornerRadius: g.cornerRadius).cgPath
        CATransaction.commit()
    }
    
    override func didMoveToWindow() {
        super.didMoveToWindow()
        DispatchQueue.main.async { [weak self] in
            guard let self = self,
                  let bg = self.toneButtonBackground,
                  let g = self.toneGradient else { return }
            let newFrame = nonZeroRect(bg.bounds.integral)
            guard g.frame != newFrame else { return }     // Skip redundant layout
            g.frame = newFrame
            g.cornerRadius = nonZero(bg.bounds.height) / 2
            bg.layer.shadowPath = UIBezierPath(roundedRect: bg.bounds, cornerRadius: g.cornerRadius).cgPath
        }
    }

    // MARK: - DeleteManagerDelegate
    func performDelete() {
        guard let proxy = textDocumentProxy else { return }
        
        // Try undo first
        if spellCheckerIntegration.undoLastCorrection(in: proxy) {
            return
        }
        
        proxy.deleteBackward()
        performHapticFeedback()
        // 👉 refresh candidates on delete
        refreshSpellingIfMeaningful()
        wordDirty = true
        markTypingActivity() // idle fallback will trigger if user pauses
        
        // Notify coordinator of deletion
        coordinator?.onTextChanged(fullText: snapshotFullText(), lastInserted: nil, isDeletion: true)
    }
    
    func performDeleteTick() {
        guard let proxy = textDocumentProxy else { return }
        proxy.deleteBackward()
        // 👉 refresh candidates on repeat delete
        refreshSpellingIfMeaningful()
        wordDirty = true
        markTypingActivity()
        
        // Notify coordinator of deletion
        coordinator?.onTextChanged(fullText: snapshotFullText(), lastInserted: nil, isDeletion: true)
    }
    
    func hapticLight() {
        performHapticFeedback()
    }

    // MARK: - SuggestionChipManagerDelegate
    func suggestionChipDidExpand(_ chip: SuggestionChipView) {
        // Handle expansion analytics
        performHapticFeedback()
    }
    
    func suggestionChipDidDismiss(_ chip: SuggestionChipView) {
        secureFixManager.resetAdviceGate()
        quickFixButton?.alpha = 0.5
        suggestionsArmed = false  // require re-tap
    }

    // MARK: - SpaceHandlerDelegate
    func insertText(_ text: String) {
        guard let proxy = textDocumentProxy else { return }
        proxy.insertText(text)
        
        // Handle autocorrection on space
        if text == " " {
            spellCheckerIntegration.autocorrectLastWordIfNeeded(afterTyping: " ", in: proxy)
        }
        
        textDidChange()
    }
    
    func moveSelection(by offset: Int) {
        guard let proxy = textDocumentProxy else { return }
        
        if offset > 0 {
            for _ in 0..<offset {
                proxy.adjustTextPosition(byCharacterOffset: 1)
            }
        } else {
            for _ in 0..<abs(offset) {
                proxy.adjustTextPosition(byCharacterOffset: -1)
            }
        }
    }
    
    func getTextDocumentProxy() -> UITextDocumentProxy? {
        return textDocumentProxy
    }
    
    func requestSentenceAutoCap() {
        guard let proxy = textDocumentProxy,
              (proxy.autocapitalizationType ?? .none) == .sentences else { return }
        shiftState = .enabled
        updateShiftButtonAppearance()
        updateKeycaps()
    }

    // MARK: - SpellCheckerIntegrationDelegate
    func didUpdateSpellingSuggestions(_ suggestions: [String]) {
        spellStrip.updateCandidates(suggestions)
    }
    
    func didApplySpellCorrection(_ correction: String, original: String) {
        // Handle spell correction analytics
    }
    
    private func applySpellCorrection(_ correction: String) {
        guard let proxy = textDocumentProxy else { return }
        
        // Get the current word being typed
        let beforeCursor = proxy.documentContextBeforeInput ?? ""
        let words = beforeCursor.components(separatedBy: .whitespacesAndNewlines)
        guard let lastWord = words.last, !lastWord.isEmpty else { return }
        
        // Delete the current word and insert the correction
        for _ in 0..<lastWord.count {
            proxy.deleteBackward()
        }
        proxy.insertText(correction)
        
        // Update our text state using router pattern
        routeIfChanged(lastInserted: correction, isDeletion: false, urgent: true)
        
        // Trigger haptic feedback
        performHapticFeedback()
        
        // Log the correction
        logger.info("📝 Applied spell correction: '\(lastWord)' → '\(correction)'")
        
        // Notify spell checker delegate - applyCorrection method not available
        // The spell checker integration handles corrections automatically
        didApplySpellCorrection(correction, original: lastWord)
    }

    // MARK: - SecureFixManagerDelegate
    func getOpenAIAPIKey() -> String {
        return openAIAPIKey
    }
    
    func getCurrentTextForAnalysis() -> String {
        let before = beforeContext
        let after = afterContext
        return before + after
    }
    
    func replaceCurrentMessage(with newText: String) {
        guard let proxy = textDocumentProxy else { return }
        replaceAllText(with: newText, on: proxy)
    }
    
    func buildUserProfileForSecureFix() -> [String: Any] {
        return [
            "typing_style": "casual",
            "communication_tone": "friendly"
        ]
    }
    
    func showUsageLimitAlert(message: String) {
        suggestionChipManager.showAutoSuggestion(text: message, toneString: "caution")  // System message - bypass restriction
    }

    // MARK: - Host Traits Sync
    private func syncHostTraits() {
        guard let proxy = textDocumentProxy else { return }
        
        // Autocapitalization
        switch proxy.autocapitalizationType ?? .none {
        case .sentences, .words, .allCharacters:
            updateShiftButtonAppearance()
            updateKeycaps()
        default:
            break
        }

        // Autocorrection / spell strip
        let wantsAutocorrect = (proxy.autocorrectionType ?? .default) != .no
        spellStrip.isHidden = !wantsAutocorrect

        // Smart quotes / dashes / insert-delete
        smartQuotesEnabled = (proxy.smartQuotesType ?? .default) != .no
        smartDashesEnabled = (proxy.smartDashesType ?? .default) != .no
        smartInsertDeleteEnabled = (proxy.smartInsertDeleteType ?? .default) != .no

        // Return key label and behavior
        if let returnButton = returnButton {
            KeyButtonFactory.updateReturnButtonAppearance(returnButton, for: proxy.returnKeyType ?? .default)
        }

        // Keyboard appearance
        updateAppearance(proxy.keyboardAppearance ?? .default)
    }
    
    private func updateAppearance(_ appearance: UIKeyboardAppearance) {
        let isDark = (appearance == .dark || (appearance == .default && traitCollection.userInterfaceStyle == .dark))
        let bg: UIColor = isDark ? UIColor.black : (UIColor.keyboardBackground ?? UIColor.systemBackground)
        backgroundColor = bg
    }

        // MARK: - Prediction bar (integrated into KeyboardController)
    private func setupSuggestionBar() {
        // Create prediction bar container
        let pBar = UIView()
        pBar.translatesAutoresizingMaskIntoConstraints = false
        pBar.backgroundColor = .systemGray5
        pBar.clipsToBounds = false
        pBar.layer.zPosition = 1
        addSubview(pBar)
        suggestionBar = pBar

        // Hairline top separator like iOS
        let sep = UIView()
        sep.translatesAutoresizingMaskIntoConstraints = false
        sep.backgroundColor = .separator
        pBar.addSubview(sep)

        // Create tone button background (circular, smaller than logo for glow-through effect)
        let toneButtonBackground = UIView()
        toneButtonBackground.translatesAutoresizingMaskIntoConstraints = false
        toneButtonBackground.backgroundColor = .white  // White background for better contrast
        toneButtonBackground.layer.cornerRadius = 18  // Smaller circle (36pt diameter)
        toneButtonBackground.clipsToBounds = false  // Allow shadow to show
        toneButtonBackground.layer.masksToBounds = false  // Allow shadow to show
        pBar.addSubview(toneButtonBackground)

        // Create tone button (logo) - larger than background for glow-through
        let toneButton = UIButton(type: .custom)
        toneButton.translatesAutoresizingMaskIntoConstraints = false
        toneButton.backgroundColor = .clear
        toneButton.contentEdgeInsets = UIEdgeInsets(top: 2, left: 2, bottom: 2, right: 2) // Minimal padding for 65x65 logo
        toneButton.imageView?.contentMode = .scaleAspectFit
        toneButton.layer.cornerRadius = 32.5  // Half of 65pt
        toneButton.clipsToBounds = true
        
        // Configure accessibility
        toneButton.isAccessibilityElement = true
        toneButton.accessibilityLabel = "Tone indicator"
        toneButton.accessibilityHint = "Shows the tone analysis of your message"
        toneButton.accessibilityValue = "Neutral" // Will be updated dynamically
        
        // ✅ CRITICAL: Ensure button is always visible from creation
        toneButton.isHidden = false
        toneButton.alpha = 1.0
        
        pBar.addSubview(toneButton)
        
        // Debug logging for button lifecycle
        #if DEBUG
        logger.info("ToneButton: willAdd - button created and about to be added to view")
        #endif

        // Create undo button
        let undoButton = UIButton(type: .system)
        undoButton.translatesAutoresizingMaskIntoConstraints = false
        undoButton.setTitle("↶", for: .normal)
        undoButton.titleLabel?.font = .systemFont(ofSize: 16, weight: .medium)
        undoButton.backgroundColor = .secondarySystemFill
        undoButton.layer.cornerCurve = .continuous
        undoButton.layer.cornerRadius = 16
        undoButton.isHidden = true
        undoButton.alpha = 0
        pBar.addSubview(undoButton)

        // Load and configure logo for tone button
        configureLogoImage(for: toneButton)

        // Store references for later use
        self.toneButtonBackground = toneButtonBackground
        self.toneButton = toneButton
        self.undoButton = undoButton
        
        // ✅ CRITICAL: Configure chip manager with suggestion bar so chips anchor properly
        self.suggestionChipManager.configure(suggestionBar: pBar)

        // Create gradient layer for smaller background circle
        let g = CAGradientLayer()
        g.startPoint = CGPoint(x: 0, y: 0)
        g.endPoint = CGPoint(x: 1, y: 1)
        g.masksToBounds = true
        g.colors = [UIColor.white.cgColor, UIColor.white.cgColor]  // Start with white visible
        // Don't set frame/cornerRadius here - will be set in layoutSubviews after Auto Layout
        toneButtonBackground.layer.insertSublayer(g, at: 0)
        toneGradient = g

        // Add shadow
        toneButtonBackground.layer.shadowColor = UIColor.black.cgColor
        toneButtonBackground.layer.shadowOffset = CGSize(width: 0, height: 1)
        toneButtonBackground.layer.shadowRadius = 3
        toneButtonBackground.layer.shadowOpacity = 0

        // Add actions
        toneButton.addTarget(self, action: #selector(toneButtonPressed(_:)), for: .touchUpInside)
        
        // ✅ CRITICAL: Trigger initial layout pass to set gradient frame after creation
        setNeedsLayout()

        undoButton.addTarget(self, action: #selector(undoButtonPressed(_:)), for: .touchUpInside)

        // Layout constraints
        NSLayoutConstraint.activate([
            // Prediction bar positioning
            pBar.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor),
            pBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            pBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            pBar.heightAnchor.constraint(equalToConstant: 70), // Increased height for logo

            // Separator
            sep.topAnchor.constraint(equalTo: pBar.topAnchor),
            sep.leadingAnchor.constraint(equalTo: pBar.leadingAnchor),
            sep.trailingAnchor.constraint(equalTo: pBar.trailingAnchor),
            sep.heightAnchor.constraint(equalToConstant: 1.0 / UIScreen.main.scale),

            // Tone button background (smaller circle for glow-through effect)
            toneButtonBackground.leadingAnchor.constraint(equalTo: pBar.leadingAnchor, constant: 12),
            toneButtonBackground.centerYAnchor.constraint(equalTo: pBar.centerYAnchor),
            toneButtonBackground.widthAnchor.constraint(equalToConstant: 36),   // Smaller background
            toneButtonBackground.heightAnchor.constraint(equalToConstant: 36),

            // Tone button (logo) - larger, overlays background for glow-through
            toneButton.centerXAnchor.constraint(equalTo: toneButtonBackground.centerXAnchor),
            toneButton.centerYAnchor.constraint(equalTo: toneButtonBackground.centerYAnchor),
            toneButton.widthAnchor.constraint(equalToConstant: 65),             // Larger logo
            toneButton.heightAnchor.constraint(equalToConstant: 65),

            // Undo button
            undoButton.trailingAnchor.constraint(equalTo: pBar.trailingAnchor, constant: -12),
            undoButton.centerYAnchor.constraint(equalTo: pBar.centerYAnchor),
            undoButton.widthAnchor.constraint(equalToConstant: 32),
            undoButton.heightAnchor.constraint(equalToConstant: 32),
        ])

        // Add spell strip
        pBar.addSubview(spellStrip)
        spellStrip.translatesAutoresizingMaskIntoConstraints = false
        spellStrip.backgroundColor = UIColor.systemGray6.withAlphaComponent(0.8)
        spellStrip.layer.cornerRadius = 8

        NSLayoutConstraint.activate([
            spellStrip.topAnchor.constraint(equalTo: pBar.topAnchor, constant: 8),
            spellStrip.bottomAnchor.constraint(equalTo: pBar.bottomAnchor, constant: -8),
            spellStrip.leadingAnchor.constraint(equalTo: toneButtonBackground.trailingAnchor, constant: 24), // Increased from 16 to 24
            spellStrip.trailingAnchor.constraint(equalTo: undoButton.leadingAnchor, constant: -24), // Increased from -16 to -24
            spellStrip.centerYAnchor.constraint(equalTo: pBar.centerYAnchor) // Center vertically
        ])
        
        // Set up spell correction handler
        spellStrip.setSpellCorrectionHandler { [weak self] correction in
            self?.applySpellCorrection(correction)
        }

        // Don't set initial neutral - let coordinator emit first real tone
        // setToneStatus(.neutral) // REMOVED: was forcing neutral on startup
        
        // Force immediate visibility check
        if let button = self.toneButton {
            button.isHidden = false
            button.alpha = 1.0
        }
        
        // Force layout pass to ensure gradient frame is correct
        DispatchQueue.main.async { [weak self] in
            // Removed redundant setToneStatus call - already set on line 796
            
            // Double-check visibility after layout
            if let button = self?.toneButton {
                button.isHidden = false
                button.alpha = 1.0
            }
        }
        
        
        // Apply accessibility improvements
        applyAccessibility()
    }
    
    private func applyAccessibility() {
        toneButton?.accessibilityTraits = [.button]
        toneButton?.accessibilityLabel = "Analyze tone"
        quickFixButton?.titleLabel?.adjustsFontForContentSizeCategory = true
        suggestionBar.accessibilityTraits = [.staticText]
    }

    // MARK: - Logo Loading

    private func configureLogoImage(for button: UIButton) {
        let keyboardBundle = Bundle(for: KeyboardController.self)

        // Method 1: Try Asset Catalog first (automatically picks correct scale)
        if let logoImage = UIImage(named: "unsaid_logo", in: keyboardBundle, compatibleWith: traitCollection) {
            // Use original rendering mode (not template) so logo keeps its design
            button.setImage(logoImage.withRenderingMode(.alwaysOriginal), for: .normal)
            button.adjustsImageWhenHighlighted = false
            KBDLog("✅ KeyboardController: Loaded from keyboard Asset Catalog with correct scale", .debug, "KeyboardController")
            return
        }

        // Method 2: Try direct PNG file in keyboard extension bundle (simple & reliable)
        if let logoPath = keyboardBundle.path(forResource: "unsaid_logo", ofType: "png"),
           let logoImage = UIImage(contentsOfFile: logoPath) {
            // Use original rendering mode (not template) so logo keeps its design
            button.setImage(logoImage.withRenderingMode(.alwaysOriginal), for: .normal)
            button.adjustsImageWhenHighlighted = false
            KBDLog("✅ KeyboardController: Loaded unsaid_logo.png directly from keyboard bundle", .debug, "KeyboardController")
            return
        }

        // Method 3: Try main app bundle as last resort
        if let logoImage = UIImage(named: "unsaid_logo", in: Bundle.main, compatibleWith: traitCollection) {
            // Use original rendering mode (not template) so logo keeps its design
            button.setImage(logoImage.withRenderingMode(.alwaysOriginal), for: .normal)
            button.adjustsImageWhenHighlighted = false
            KBDLog("✅ KeyboardController: Loaded from main app bundle", .debug, "KeyboardController")
            return
        }

        // Method 4: Create a simple programmatic logo as backup
        KBDLog("❌ KeyboardController: All methods failed, creating programmatic logo", .warn, "KeyboardController")
        let image = createSimpleLogoImage()
        button.setImage(image.withRenderingMode(.alwaysOriginal), for: .normal)
        button.adjustsImageWhenHighlighted = false
    }

    private func createSimpleLogoImage() -> UIImage {
        // Create a simple circular logo programmatically - 50x50 for better visibility
        let size = CGSize(width: 50, height: 50)
        let renderer = UIGraphicsImageRenderer(size: size)

        let image = renderer.image { context in
            let ctx = context.cgContext
            
            // Create a white circle background for better contrast
            ctx.setFillColor(UIColor.white.cgColor)
            ctx.fillEllipse(in: CGRect(x: 0, y: 0, width: nonZero(size.width), height: nonZero(size.height)))
            
            // Add a subtle border
            ctx.setStrokeColor(UIColor.systemGray3.cgColor)
            ctx.setLineWidth(1.0)
            ctx.strokeEllipse(in: CGRect(x: 0.5, y: 0.5, width: nonZero(size.width) - 1, height: nonZero(size.height) - 1))
            
            // Draw "U" in the center
            ctx.setFillColor(UIColor.systemBlue.cgColor)
            let font = UIFont.systemFont(ofSize: 24, weight: .bold)
            let text = "U"
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: UIColor.systemBlue
            ]
            let textSize = text.size(withAttributes: attributes)
            let safeWidth = nonZero(size.width)
            let safeHeight = nonZero(size.height)
            let textRect = CGRect(
                x: (safeWidth - nonZero(textSize.width)) / 2.0,
                y: (safeHeight - nonZero(textSize.height)) / 2.0,
                width: nonZero(textSize.width),
                height: nonZero(textSize.height)
            )
            text.draw(in: textRect, withAttributes: attributes)
        }

        return image.withRenderingMode(.alwaysOriginal)
    }

    // MARK: - Tone Status Management

    private func setToneStatus(_ tone: ToneStatus, animated: Bool = true) {
        // Guard against redundant updates (reduces gradient/layout churn)
        guard let bg = toneButtonBackground else {
            KBDLog("🎯 ❌ CRITICAL ERROR: No tone button background found!", .error, "KeyboardController")
            return
        }
        
        // Skip redundant work if tone is same and visuals are synchronized
        let noGradient = (toneGradient == nil)
        let noColors = (toneGradient?.colors as? [CGColor])?.isEmpty ?? true
        let wantsAlertPulse = (tone == .alert) && (bg.layer.animation(forKey: "alertPulse") == nil)
        let visualOutOfSync = noGradient || noColors || wantsAlertPulse || (bg.alpha < 0.99)
        
        if tone == currentTone && !visualOutOfSync {
            print("🎨 APPLY skipped: redundant tone=\(tone.rawValue) (same as current)")
            return // skip redundant work
        }
        
        // 🎨 APPLY - Log the apply request
        print("🎨 APPLY requested: current=\(currentTone.rawValue) -> new=\(tone.rawValue) animated=\(animated)")
        
        #if DEBUG
        if logGate.allow("tone_set", tone.rawValue) {
            KBDLog("🎯 setToneStatus(\(tone.rawValue)) animated=\(animated) bg=\(self.toneButtonBackground != nil) btn=\(self.toneButton != nil)", .info, "KeyboardController")
        }
        #endif
        
        print("🎨 APPLY proceeding: tone=\(tone.rawValue) visualOutOfSync=\(visualOutOfSync)")

        // Ensure background is definitely visible
        bg.isHidden = false
        bg.alpha = max(bg.alpha, 1.0)
        
        // Ensure tone button itself is also visible
        if let button = toneButton {
            button.isHidden = false
            button.alpha = max(button.alpha, 1.0)
            
            // Update accessibility value for VoiceOver
            button.accessibilityValue = tone.accessibilityDescription
        }

        // Destination visual state
        let gradientResult = gradientColors(for: tone)
        let (colors, baseColor) = gradientResult
        
        print("🎨 🔥 GRADIENT COLORS FOR \(tone.rawValue): \(colors.count) colors")
        if colors.count >= 2 {
            let color1 = UIColor(cgColor: colors[0])
            let color2 = UIColor(cgColor: colors[1])
            print("🎨 🔥 COLOR 1: \(color1)")
            print("🎨 🔥 COLOR 2: \(color2)")
        }
        
        let targetAlpha: CGFloat = 1.0  // Always show background (white or colored)
        let targetScale: CGFloat = (tone == .alert) ? CGFloat(1.06) : CGFloat(1.0)
        let targetShadow: Float = toneShadowOpacity  // Always show shadow for better contrast

        // Fix white-on-white: clear background for non-neutral so gradient shows through
        if tone == .neutral {
            bg.backgroundColor = .white
        } else {
            bg.backgroundColor = .clear  // Let gradient be the visible color
        }

        // Ensure gradient layer exists
        if toneGradient == nil {
            let g = CAGradientLayer()
            g.startPoint = CGPoint(x: 0, y: 0)
            g.endPoint = CGPoint(x: 1, y: 1)
            g.cornerRadius = nonZero(bg.bounds.height) / 2.0
            g.frame = nonZeroRect(bg.bounds)
            g.colors = [UIColor.white.cgColor, UIColor.white.cgColor]  // Start with white visible
            g.masksToBounds = true  // Keep gradient within circle bounds
            bg.layer.insertSublayer(g, at: 0)
            toneGradient = g
        }
        
        // Ensure shadows can render (background allows overflow, gradient stays bounded)
        bg.clipsToBounds = false
        toneGradient?.masksToBounds = true

        // Animate with a single property animator for smoothness + interruptibility
        self.toneAnimator?.stopAnimation(true)
        let duration: TimeInterval = animated ? 0.35 : 0.0
        let curve: UIView.AnimationCurve = (tone == .alert) ? .easeIn : .easeInOut
        let animator = UIViewPropertyAnimator(duration: duration, curve: curve) {
            bg.alpha = targetAlpha
            bg.transform = CGAffineTransform(scaleX: targetScale, y: targetScale)
            bg.layer.shadowOpacity = targetShadow
        }
        self.toneAnimator = animator

        // ✅ CRITICAL: Trigger layout pass to update gradient frame after tone changes
        setNeedsLayout()

        // Crossfade gradient colors using Core Animation (keeps UIKit animator in sync)
        if let g = toneGradient {
            if animated {
                let anim = CABasicAnimation(keyPath: "colors")
                anim.fromValue = g.colors
                anim.toValue = colors
                anim.duration = duration
                anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                g.add(anim, forKey: "colors")
            }
            g.colors = colors // final state
            
            // Instrument gradient updates to prove they're happening
            #if DEBUG
            if let g = toneGradient, logGate.allow("grad", tone.rawValue) {
                KBDLog("🎨 tone=\(tone.rawValue) gradientColors=\(g.colors?.count ?? 0) frame=\(g.frame.debugDescription)", .debug, "KeyboardController")
            }
            #endif
        } else if let baseColor = baseColor {
            // fallback background if gradient missing
            bg.backgroundColor = baseColor
        }

        if animated {
            animator.startAnimation()
        } else {
            // Apply immediately
            bg.alpha = targetAlpha
            bg.transform = CGAffineTransform(scaleX: targetScale, y: targetScale)
            bg.layer.shadowOpacity = targetShadow
        }
        
        // Optional: Add pulse for alert
        if tone == .alert {
            startAlertPulse()
        } else {
            stopAlertPulse()
        }
        
        // Set currentTone only after visual updates complete to avoid logical/visual drift
        currentTone = tone
    }

    private func startAlertPulse() {
        guard let bg = toneButtonBackground else { return }
        let pulse = CABasicAnimation(keyPath: "transform.scale")
        pulse.fromValue = 1.0
        pulse.toValue = 1.15   // Bigger pulse to shine behind logo
        pulse.duration = 0.9
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        bg.layer.add(pulse, forKey: "alertPulse")
    }

    private func stopAlertPulse() {
        toneButtonBackground?.layer.removeAnimation(forKey: "alertPulse")
    }

    private func gradientColors(for tone: ToneStatus) -> ([CGColor], UIColor?) {
        let result: ([CGColor], UIColor?)
        switch tone {
        case .alert:
            let c1 = UIColor.systemRed
            let c2 = UIColor.systemRed.withAlphaComponent(0.85)
            result = ([c1.cgColor, c2.cgColor], nil)
        case .caution:
            let c1 = UIColor.systemYellow
            let c2 = UIColor.systemYellow.withAlphaComponent(0.85)
            result = ([c1.cgColor, c2.cgColor], nil)
        case .clear:
            let c1 = UIColor.systemGreen
            let c2 = UIColor.systemTeal.withAlphaComponent(0.85)
            result = ([c1.cgColor, c2.cgColor], nil)
        case .neutral:
            let c = UIColor.white
            result = ([c.cgColor, c.cgColor], UIColor.white)
        @unknown default:
            let c = UIColor.white
            result = ([c.cgColor, c.cgColor], UIColor.white)
        }
        
        KBDLog("🎯 🎨 GRADIENT COLORS FOR \(String(describing: tone)): \(result.0.count) colors", .debug, "KeyboardController")
        return result
    }

    // MARK: - Animation

    private func pressPop() {
        guard let toneButton = self.toneButton else { return }
        let t = CGAffineTransform(scaleX: 0.92, y: 0.92)
        UIView.animate(withDuration: 0.12, delay: 0,
                       usingSpringWithDamping: 0.6, initialSpringVelocity: 0.8,
                       options: [.allowUserInteraction]) {
            toneButton.transform = t
        } completion: { _ in
            UIView.animate(withDuration: 0.12, delay: 0,
                           usingSpringWithDamping: 0.8, initialSpringVelocity: 0.6,
                           options: [.allowUserInteraction]) {
                toneButton.transform = .identity
            }
        }
    }

    // MARK: - Keyboard layout
    private func setupKeyboardLayout() {
        let mainStack = UIStackView()
        mainStack.axis = .vertical
        mainStack.spacing = verticalSpacing
        mainStack.translatesAutoresizingMaskIntoConstraints = false

        let (topKeys, midKeys, botKeys) = getKeysForCurrentMode()

        let topRow = rowStack(for: topKeys)
        let midRow = rowStack(for: midKeys, centerNine: currentMode == .letters)
        let thirdRow: UIStackView = (currentMode == .letters)
            ? thirdRowWithShiftAndDelete(for: botKeys)
            : rowStack(for: botKeys)

        let controlRow = controlRowStack()

        // Store references for QWERTY stagger calculation
        topRowRef = topRow
        midRowRef = midRow

        mainStack.addArrangedSubview(topRow)
        mainStack.addArrangedSubview(midRow)
        mainStack.addArrangedSubview(thirdRow)
        mainStack.addArrangedSubview(controlRow)

        addSubview(mainStack)
        keyboardStackView = mainStack

        NSLayoutConstraint.activate([
            mainStack.topAnchor.constraint(equalTo: suggestionBar.bottomAnchor, constant: 8), // Back to original spacing
            mainStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 0), // Full width - no side margins
            mainStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: 0), // Full width - no side margins
            mainStack.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -8)
        ])
    }

    private func rowStack(for titles: [String], centerNine: Bool = false) -> UIStackView {
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.distribution = .fillEqually
        stack.spacing = horizontalSpacing

        if centerNine && titles.count == 9 {
            // Enable layout margins for QWERTY stagger - margins will be set dynamically
            stack.isLayoutMarginsRelativeArrangement = true
            // margins will be set dynamically after layout
        }

        for title in titles {
            let button = KeyButtonFactory.makeKeyButton(title: shouldCapitalizeKey(title) ? title.uppercased() : title)
            button.addTarget(self, action: #selector(keyTapped(_:)), for: UIControl.Event.touchUpInside)
            button.addTarget(self, action: #selector(buttonTouchDown(_:)), for: UIControl.Event.touchDown)
            button.addTarget(self, action: #selector(buttonTouchUp(_:)), for: [UIControl.Event.touchUpInside, UIControl.Event.touchUpOutside, UIControl.Event.touchCancel])
            stack.addArrangedSubview(button)
        }

        return stack
    }

    // MARK: - QWERTY Stagger Calculation
    /// Calculates the indent needed for QWERTY stagger effect
    /// The middle row (9 keys) should be centered between the top row (10 keys) columns
    private func qwertyIndent(containerWidth: CGFloat, spacing: CGFloat) -> CGFloat {
        // 10 columns, 9 gaps
        let w10 = (containerWidth - spacing * 9) / 10.0
        // shift by half a 10-col cell plus half the inter-key gap
        return (w10 + spacing) * 0.5
    }

    /// Applies QWERTY stagger to the middle row when in letters mode
    private func applyQwertyStaggerIfNeeded() {
        guard currentMode == .letters, let mid = midRowRef else {
            // Clear margins when not in letters mode
            midRowRef?.directionalLayoutMargins = .zero
            return
        }
        
        // Use the mid row's own width for accuracy
        let W = mid.bounds.width
        guard W > 0, mid.arrangedSubviews.count == 9 else { return }
        
        let indent = qwertyIndent(containerWidth: W, spacing: horizontalSpacing)
        mid.directionalLayoutMargins = .init(top: 0, leading: indent, bottom: 0, trailing: indent)
    }

    // New helper builds the z..m row with Shift on left and Delete on right
    private func thirdRowWithShiftAndDelete(for titles: [String]) -> UIStackView {
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.alignment = .fill
        stack.spacing = horizontalSpacing
        stack.distribution = .fill

        // LEFT: in letters -> Shift; in numbers/symbols -> mode toggle
        let leftButton: UIButton
        if currentMode == .letters {
            let shift = KeyButtonFactory.makeShiftButton()
            shift.addTarget(self, action: #selector(handleShiftPressed), for: .touchUpInside)
            shift.addTarget(self, action: #selector(specialButtonTouchDown(_:)), for: .touchDown)
            shift.addTarget(self, action: #selector(specialButtonTouchUp(_:)), for: [.touchUpInside, .touchUpOutside, .touchCancel])
            shiftButton = shift
            leftButton = shift
            // width hint
            leftButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        } else {
            // Numbers/Symbols: show toggle ("#+=" on Numbers -> Symbols, "123" on Symbols -> Numbers)
            let title = (currentMode == .numbers) ? "#+=" : "123"
            let toggle = KeyButtonFactory.makeModeButton(title: title)
            toggle.addTarget(self, action: #selector(handleThirdRowToggle), for: .touchUpInside)
            // reuse shiftButton slot so the rest of the class doesn't break
            shiftButton = toggle
            leftButton = toggle
            leftButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        }

        // MIDDLE: the letters/symbol row
        let lettersRow = UIStackView()
        lettersRow.axis = .horizontal
        lettersRow.spacing = horizontalSpacing
        lettersRow.distribution = .fillEqually
        for title in titles {
            let b = KeyButtonFactory.makeKeyButton(title: shouldCapitalizeKey(title) ? title.uppercased() : title)
            b.addTarget(self, action: #selector(keyTapped(_:)), for: .touchUpInside)
            b.addTarget(self, action: #selector(buttonTouchDown(_:)), for: .touchDown)
            b.addTarget(self, action: #selector(buttonTouchUp(_:)), for: [.touchUpInside, .touchUpOutside, .touchCancel])
            lettersRow.addArrangedSubview(b)
        }

        // RIGHT: Delete
        let delete = KeyButtonFactory.makeDeleteButton()
        delete.addTarget(self, action: #selector(deleteTouchDown), for: .touchDown)
        delete.addTarget(self, action: #selector(deleteTouchUp), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        deleteButton = delete
        delete.widthAnchor.constraint(greaterThanOrEqualToConstant: 52).isActive = true

        stack.addArrangedSubview(leftButton)
        stack.addArrangedSubview(lettersRow)
        stack.addArrangedSubview(delete)

        // let letters expand; keep edges compact
        leftButton.setContentHuggingPriority(.required, for: .horizontal)
        delete.setContentHuggingPriority(.required, for: .horizontal)
        lettersRow.setContentHuggingPriority(.defaultLow, for: .horizontal)
        lettersRow.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        return stack
    }

    private func controlRowStack() -> UIStackView {
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.spacing = horizontalSpacing
        stack.distribution = .fill
        stack.alignment = .center

        // ABC button (only in symbols mode)
        var abcButton: UIButton?
        if currentMode == .symbols {
            let abc = KeyButtonFactory.makeModeButton(title: "ABC")
            abc.addTarget(self, action: #selector(handleABCButtonPressed), for: .touchUpInside)
            abc.addTarget(self, action: #selector(specialButtonTouchDown(_:)), for: .touchDown)
            abc.addTarget(self, action: #selector(specialButtonTouchUp(_:)), for: [.touchUpInside, .touchUpOutside, .touchCancel])
            abcButton = abc
            stack.addArrangedSubview(abc)
        }

        // Mode (123/ABC)
        let mode = KeyButtonFactory.makeModeButton(title: "123")  // Start with letters mode, so show "123"
        mode.addTarget(self, action: #selector(handleModeSwitch), for: .touchUpInside)
        mode.addTarget(self, action: #selector(specialButtonTouchDown(_:)), for: .touchDown)
        mode.addTarget(self, action: #selector(specialButtonTouchUp(_:)), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        modeButton = mode

        // Globe (smaller)
        let globe = KeyButtonFactory.makeGlobeButton()
        globe.addTarget(self, action: #selector(handleGlobeKey), for: .touchUpInside)
        globe.addTarget(self, action: #selector(specialButtonTouchDown(_:)), for: .touchDown)
        globe.addTarget(self, action: #selector(specialButtonTouchUp(_:)), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        globeButton = globe
        globe.accessibilityLabel = "Next Keyboard"
        globe.titleLabel?.font = .systemFont(ofSize: 13, weight: .regular)
        globe.titleLabel?.adjustsFontForContentSizeCategory = false

        // Space (bigger - expandable)
        let space = KeyButtonFactory.makeSpaceButton()
        space.addTarget(self, action: #selector(handleSpaceKey), for: .touchUpInside)
        space.addTarget(self, action: #selector(specialButtonTouchDown(_:)), for: .touchDown)
        space.addTarget(self, action: #selector(specialButtonTouchUp(_:)), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        spaceButton = space
        spaceHandler.setupSpaceButton(space)

        // Secure Fix
        let secureFix = KeyButtonFactory.makeSecureButton()
        quickFixButton = secureFix
        secureFix.addTarget(self, action: #selector(handleSecureFix), for: UIControl.Event.touchUpInside)
        secureFix.addTarget(self, action: #selector(secureFixTouchDown(_:)), for: UIControl.Event.touchDown)
        secureFix.addTarget(self, action: #selector(secureFixTouchUp(_:)), for: [UIControl.Event.touchUpInside, UIControl.Event.touchUpOutside])

        // Return
        let returnBtn = KeyButtonFactory.makeReturnButton()
        returnBtn.addTarget(self, action: #selector(handleReturnKey), for: UIControl.Event.touchUpInside)
        returnBtn.addTarget(self, action: #selector(specialButtonTouchDown(_:)), for: UIControl.Event.touchDown)
        returnBtn.addTarget(self, action: #selector(specialButtonTouchUp(_:)), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        returnButton = returnBtn

        // Order: [mode][globe][space][secureFix][return]
        stack.addArrangedSubview(mode)
        stack.addArrangedSubview(globe)
        stack.addArrangedSubview(space)
        stack.addArrangedSubview(secureFix)
        stack.addArrangedSubview(returnBtn)

        // iOS-style constraint layout with proper button sizing
        
        // 1. Make mode button same width as globe button (44pt)
        mode.widthAnchor.constraint(equalTo: globe.widthAnchor).isActive = true
        
        // 2. Globe gets fixed width (baseline)
        globe.widthAnchor.constraint(equalToConstant: 44).isActive = true
        
        // 3. ABC button (when present) same width as globe and mode
        if let abc = abcButton {
            abc.widthAnchor.constraint(equalTo: globe.widthAnchor).isActive = true
        }
        
        // 4. Return button 50% wider than mode/globe
        returnBtn.widthAnchor.constraint(equalTo: mode.widthAnchor, multiplier: 1.5).isActive = true
        
        // 5. Secure button same width as mode/globe
        secureFix.widthAnchor.constraint(equalTo: mode.widthAnchor).isActive = true
        
        // 6. Space expands to fill remaining space - low hugging priority
        space.setContentHuggingPriority(.defaultLow, for: .horizontal)
        space.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        
        // 7. Fixed-width buttons resist expansion
        var fixedButtons = [mode, globe, secureFix, returnBtn]
        if let abc = abcButton {
            fixedButtons.append(abc)
        }
        fixedButtons.forEach { button in
            button.setContentHuggingPriority(.defaultHigh, for: .horizontal)
            button.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        }

        return stack
    }

    // MARK: - Key input handling
    @objc private func keyTapped(_ sender: UIButton) {
        guard let title = sender.title(for: .normal), let proxy = textDocumentProxy else { return }
        
        var textToInsert = title
        
        // Apply smart quotes/dashes if enabled
        if smartQuotesEnabled {
            textToInsert = applyTextReplacements(textToInsert)
        }
        
        proxy.insertText(textToInsert)
        
        // 👉 feed the spell bar after each keypress
        refreshSpellingIfMeaningful()
        
        // Auto-switch to letters mode after punctuation
        if [".", "!", "?", ",", ";", ":"].contains(title) && currentMode != .letters {
            setKeyboardMode(.letters)
        }
        
        // Auto-disable shift after typing a letter (but not caps lock)
        if currentMode == .letters &&
           shiftState == .enabled &&
           title.count == 1 &&
           title.rangeOfCharacter(from: .letters) != nil {
            shiftState = .disabled
            updateShiftButtonAppearance()
            updateKeycaps()
        }
        
        // 🔑 NEW: gate analysis per word and notify coordinator
        if isWordChar(textToInsert) {
            wordDirty = true
            markTypingActivity()            // only idle-trigger, no router call here
            // Notify coordinator of text change
            coordinator?.onTextChanged(fullText: snapshotFullText(), lastInserted: textToInsert.first, isDeletion: false)
        } else if isWordBoundary(textToInsert) {
            // boundary → analyze immediately
            wordDirty = false
            let urgent = ".!?".contains(textToInsert)
            routeIfChanged(lastInserted: textToInsert, isDeletion: false, urgent: urgent)
            // Notify coordinator of text change
            coordinator?.onTextChanged(fullText: snapshotFullText(), lastInserted: textToInsert.first, isDeletion: false)
        } else {
            // symbols etc. treat like activity but not boundary
            markTypingActivity()
            // Notify coordinator of text change
            coordinator?.onTextChanged(fullText: snapshotFullText(), lastInserted: textToInsert.first, isDeletion: false)
        }
    }
    
    @objc private func handleSpaceKey() {
        spaceHandler.handleSpaceKey()
        // commit autocorrect is already happening in SpaceHandler
        // word boundary → analyze
        wordDirty = false
        routeIfChanged(lastInserted: " ", isDeletion: false, urgent: false)
        
        // Notify coordinator of space input
        coordinator?.onTextChanged(fullText: snapshotFullText(), lastInserted: " ", isDeletion: false)
        
        // 👉 refresh (shows/hides strip appropriately after commit)
        refreshSpellingIfMeaningful()
    }
    
    private func hostBundleIsMessages() -> Bool {
        // For keyboard extensions, detecting the host app is limited due to privacy restrictions
        // We can try to infer based on available context, but this is not guaranteed
        guard let inputVC = self.parentInputVC else { return false }
        
        // In iOS keyboard extensions, direct host bundle access is restricted
        // For now, we'll use conservative logic and assume Messages context when uncertain
        // This ensures Return-as-Send behavior works in the most common messaging scenario
        
        // Check if there are any textual clues in the input context
        let textDocumentProxy = inputVC.textDocumentProxy
        // Messages app typically has specific keyboard traits
        let keyboardType = textDocumentProxy.keyboardType
        let returnKeyType = textDocumentProxy.returnKeyType
        
        // Messages often uses .send return key type
        if returnKeyType == .send {
            return true
        }
        
        // Conservative fallback: assume Messages context for safety
        return true
    }
    
    @objc private func handleReturnKey() {
        guard let proxy = textDocumentProxy else { return }
        proxy.insertText("\n")
        routeIfChanged(lastInserted: "\n", isDeletion: false, urgent: true)
        refreshSpellingIfMeaningful()

        if (proxy.returnKeyType ?? .default) == .send || hostBundleIsMessages() {
            coordinator?.analyzeFinalSentence(snapshotFullText())
            coordinator?.resetToCleanState()
        }
    }
    
    @objc private func handleGlobeKey() {
        parentInputVC?.advanceToNextInputMode()
    }
    
    @objc private func handleShiftPressed() {
        // In numbers mode, shift toggles to symbols (iOS behavior)
        if currentMode == .numbers {
            setKeyboardMode(.symbols)
            performHapticFeedback()
            return
        }
        
        // In symbols mode, shift returns to numbers (not letters)
        if currentMode == .symbols {
            setKeyboardMode(.numbers)
            performHapticFeedback()
            return
        }
        
        // Standard shift behavior for letters mode
        let now = CACurrentMediaTime()
        let timeSinceLastTap = now - lastShiftTapAt
        
        if timeSinceLastTap < 0.3 {
            // Double tap - toggle caps lock
            shiftState = shiftState == .locked ? .disabled : .locked
        } else {
            // Single tap - cycle through states
            switch shiftState {
            case .enabled:
                shiftState = .disabled
            case .disabled:
                shiftState = .enabled
            case .locked:
                shiftState = .disabled
            }
        }
        
        lastShiftTapAt = now
        updateShiftButtonAppearance()
        updateKeycaps()
        performHapticFeedback()
    }
    
    @objc private func handleABCButtonPressed() {
        setKeyboardMode(.letters)
        performHapticFeedback()
    }

    @objc private func handleThirdRowToggle() {
        // Numbers <-> Symbols
        let next: KeyboardMode = (currentMode == .numbers) ? .symbols : .numbers
        setKeyboardMode(next)
        performHapticFeedback()
    }

    @objc private func handleModeSwitch() {
        let next: KeyboardMode
        switch currentMode {
        case .letters:
            next = .numbers          // 123 -> Numbers
        case .numbers, .symbols:
            next = .letters          // ABC -> Letters
        }
        setKeyboardMode(next)
        performHapticFeedback()
    }
    
    private func setKeyboardMode(_ mode: KeyboardMode) {
        guard mode != currentMode else { return }
        currentMode = mode
        updateKeyboardForCurrentMode()
    }
    
    @objc private func handleSecureFix() {
        secureFixManager.handleSecureFix()
        performHapticFeedback()
        
        // TEMP: Health ping debug trigger
        #if DEBUG
        coordinator?.debugPing()
        #endif
    }
    
    @objc private func deleteTouchDown() {
        deleteManager.beginDeleteRepeat()
    }
    
    @objc private func deleteTouchUp() {
        deleteManager.endDeleteRepeat()
    }
    
    // MARK: - SecureFix enhanced feedback
    @objc private func secureFixTouchDown(_ button: UIButton) {
        // No-op; move brand animation into isHighlighted if needed
    }
    
    @objc private func secureFixTouchUp(_ button: UIButton) {
        // No-op
    }

    // MARK: - Visual feedback
    @objc private func buttonTouchDown(_ button: UIButton) {
        // Keep only preview; let KeyButton's isHighlighted drive animation
        keyPreviewManager.showKeyPreview(for: button)
        performHapticFeedback()
    }
    
    @objc private func buttonTouchUp(_ button: UIButton) {
        keyPreviewManager.hideKeyPreview(for: button)
    }
    
    @objc private func specialButtonTouchDown(_ button: UIButton) {
        // No-op; rely on button.isHighlighted animation in the subclass
        performHapticFeedback()
    }
    
    @objc private func specialButtonTouchUp(_ button: UIButton) {
        // No-op
    }


    // MARK: - State updates
    private func updateShiftButtonAppearance() {
        guard let shiftButton = shiftButton else { return }
        KeyButtonFactory.updateShiftButtonAppearance(shiftButton, isShifted: isShifted, isCapsLocked: isCapsLocked)
    }
    
    // MARK: - Shift State Management
    private func updateKeycaps() {
        guard let stack = keyboardStackView else { return }
        updateKeysInStackView(stack)
    }
    
    private func updateKeysInStackView(_ stack: UIStackView) {
        for view in stack.arrangedSubviews {
            if let button = view as? UIButton,
               let title = button.title(for: .normal),
               title.count == 1,
               title.rangeOfCharacter(from: .letters) != nil {
                let newTitle = shouldCapitalizeKey(title) ? title.uppercased() : title.lowercased()
                button.setTitle(newTitle, for: .normal)
            } else if let nestedStack = view as? UIStackView {
                updateKeysInStackView(nestedStack)
            }
        }
    }
    
    private func updateShiftForContext() {
        guard let proxy = textDocumentProxy,
              let before = proxy.documentContextBeforeInput else { return }
        guard shiftState == .disabled else { return }
        
        let trimmed = before.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.hasSuffix(".") || trimmed.hasSuffix("!") || trimmed.hasSuffix("?") {
            shiftState = .enabled
            updateKeycaps()
            updateShiftButtonAppearance()
        }
    }
    
    // MARK: - Legacy keyboard layout methods (updated for new shift state)
    private func updateKeyboardForCurrentMode() {
        keyboardStackView?.removeFromSuperview()
        setupKeyboardLayout()
        
        // iOS-style titles
        let modeTitle: String
        switch currentMode {
        case .letters:
            modeTitle = "123"   // go to Numbers
        case .numbers, .symbols:
            modeTitle = "ABC"   // go back to Letters
        }
        modeButton?.setTitle(modeTitle, for: .normal)
        
        updateShiftButtonAppearance()
        updateKeycaps()
        
        // Apply stagger on next runloop so frames are valid (only for letters mode)
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.currentMode == .letters else { return }
            self.applyQwertyStaggerIfNeeded()
        }
    }
    
    private func shouldCapitalizeKey(_ key: String) -> Bool {
        guard currentMode == .letters else { return false }
        return shiftState == .enabled || shiftState == .locked
    }
    
    private func getKeysForCurrentMode() -> ([String], [String], [String]) {
        switch currentMode {
        case .letters:
            return (topRowKeys, midRowKeys, botRowKeys)
        case .numbers:
            return (topRowNumbers, midRowNumbers, botRowNumbers)
        case .symbols:
            return (topRowSymbols, midRowSymbols, botRowSymbols)
        default:
            return (topRowKeys, midRowKeys, botRowKeys)
        }
    }

    // MARK: - Text change handling
    func textDidChange() {
        print("🔄 DEBUG: textDidChange() called")
        
        // Get current text for debugging
        let currentFullText = snapshotFullText()
        print("📝 DEBUG: Current text in textDidChange: '\(currentFullText)' (length: \(currentFullText.count))")
        
        // Ensure tone button is visible when text changes (analysis may update it)
        ensureToneButtonVisible()
        
        // Notify coordinator of external text changes (paste, autocorrect, etc.)
        coordinator?.onTextChanged(fullText: currentFullText, lastInserted: nil, isDeletion: false)
        
        // REMOVED: Auto-trigger analysis on text change
        // We now only trigger suggestions via manual tone button tap
        /*
        // If the last character is boundary → analyze; else set dirty and idle-fallback.
        let snap = snapshotFullText()
        if let last = snap.trimmingCharacters(in: .whitespacesAndNewlines).last,
           ".!?,".contains(last) {
            wordDirty = false
            routeIfChanged(lastInserted: String(last), isDeletion: false, urgent: ".!?".contains(last))
        } else {
            wordDirty = true
            markTypingActivity()
        }
        */
        
        updateShiftForContext()
        
        // 👉 feed the spell bar
        refreshSpellingIfMeaningful()
    }
    

    
    private func updateCurrentText() {
        guard let proxy = textDocumentProxy else {
            currentText = ""
            return
        }
        
        let before = proxy.documentContextBeforeInput ?? ""
        let after = proxy.documentContextAfterInput ?? ""
        currentText = before + after
    }
    
    private func refreshContext() {
        guard let proxy = textDocumentProxy else { return }
        beforeContext = String((proxy.documentContextBeforeInput ?? "").suffix(600))
        afterContext  = String((proxy.documentContextAfterInput  ?? "").prefix(200))

        let fullText = (beforeContext + afterContext).trimmingCharacters(in: .whitespacesAndNewlines)
        updateCurrentText()

        if !fullText.isEmpty, !didInitialSwitchAnalyze {
            didInitialSwitchAnalyze = true
            routeIfChanged(lastInserted: nil, isDeletion: false, urgent: true)
        }
    }

    // MARK: - Text replacement helpers
    private func applyTextReplacements(_ text: String) -> String {
        var result = text
        if smartQuotesEnabled {
            if result == "\"" {
                let beforeText = beforeContext
                _ = beforeText // placeholder to avoid unused warning
                result = "\""
            }
        }
        return result
    }
    
    private func replaceAllText(with newText: String, on proxy: UITextDocumentProxy) {
        // For long messages, move to start before deleting to reduce proxy roundtrips
        var deleteCount = 0
        while let before = proxy.documentContextBeforeInput, !before.isEmpty {
            proxy.deleteBackward()
            deleteCount += 1
            if deleteCount > 500 { // Safety limit for very long text
                proxy.adjustTextPosition(byCharacterOffset: -1000)
                break
            }
        }
        proxy.insertText(newText)
    }

    // MARK: - Undo functionality
    @objc private func undoButtonTapped() {
        if let proxy = textDocumentProxy {
            _ = spellCheckerIntegration.undoLastCorrection(in: proxy)
            performHapticFeedback()
        }
    }
    
    private func setUndoVisible(_ visible: Bool) {
        guard let b = undoButton, b.isHidden != visible else { return }
        // perform animation only when state changes
        b.isHidden = !visible
        UIView.animate(withDuration: 0.18) { b.alpha = visible ? 1 : 0 }
    }

    private func setToneStatusString(_ status: String) {
        // Keep logger interpolation simple and fully typed
        logger.info("🎯 Setting tone status: \(status)")

        switch status.lowercased() {
        case "alert":   setToneStatus(.alert)
        case "caution": setToneStatus(.caution)
        case "clear":   setToneStatus(.clear)
        default:
            // Don't force neutral on unknown status - retain last tone
            KBDLog("[tone_debug] Unknown status '\(status)' - retaining current tone", .warn, "KeyboardController")
        }

        // Avoid optional-chain interpolation ambiguity; assign plainly
        if let button = toneButton {
            button.accessibilityLabel = "Tone: " + status.capitalized
        }

        // Disambiguate enum-to-string for os.Logger
        logger.info("🎯 Tone status set to: \(String(describing: self.currentTone))")
    }

    // MARK: - ToneSuggestionDelegate
    func didUpdateSuggestions(_ suggestions: [String]) {
        logger.info("💡 didUpdateSuggestions called with \(suggestions.count) suggestions")

        // Only show if the user explicitly armed by tapping the tone button
        guard suggestionsArmed else {
            logger.info("💡 Suggestions suppressed (not armed)")
            return
        }

        guard let first = suggestions.first?.trimmingCharacters(in: .whitespacesAndNewlines),
              !first.isEmpty else {
            logger.info("💡 No valid suggestions to show")
            return
        }

        // Consume the arm so we require another tap next time
        suggestionsArmed = false

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.suggestionChipManager.showButtonSuggestion(text: first, toneString: self.currentUITone.rawValue)
            self.secureFixManager.markAdviceShown(toneString: self.currentUITone.rawValue)
            self.quickFixButton?.alpha = 1.0
        }
    }

    // MARK: - Neutral Idle Gate
    private func shouldAllowNeutralNow() -> Bool {
        let dt = CACurrentMediaTime() - lastToneChangeAt
        return dt >= clearNeutralIdleMs
    }
    
    private func sentenceLikelyEnded(_ text: String) -> Bool {
        guard let last = text.trimmingCharacters(in: .whitespaces).last else { return false }
        return ".!?".contains(last)
    }

    func didUpdateToneStatus(_ tone: String) {
        let timestamp = Date().timeIntervalSince1970
        print("🎯 🔥 [\(String(format: "%.3f", timestamp))] KEYBOARD RECEIVED TONE: '\(tone)'")
        
        // Reset in-flight flag since we got a response
        toneRequestInFlight = false
        
        // Performance Optimization #1: Fast guard for redundant tone updates
        let normalizedTone = tone.lowercased()
        if lastToneStatusString == normalizedTone {
            print("🎯 DEBUG: [\(String(format: "%.3f", timestamp))] Skipping redundant tone update - already set to '\(normalizedTone)'")
            return // Skip redundant update - tone hasn't actually changed
        }
        
        print("🎯 🔥 [\(String(format: "%.3f", timestamp))] KEYBOARD RECEIVED TONE: '\(tone)' (normalized: '\(normalizedTone)')")
        let toneStatus = ToneStatus(from: tone)
        print("🎯 🔥 [\(String(format: "%.3f", timestamp))] CONVERTED TO TONE STATUS: \(toneStatus) (raw value: '\(toneStatus.rawValue)')")
        
        // Gate neutral to avoid flicker + spam
        if toneStatus == .neutral && !shouldAllowNeutralNow() && !sentenceLikelyEnded(currentText) {
            logger.info("🎯 [\(String(format: "%.3f", timestamp))] Neutral suppressed by idle gate (no sentence boundary)")
            return
        }
        
        currentUITone = toneStatus
        print("🎯 🔥 [\(String(format: "%.3f", timestamp))] SETTING TONE STATUS TO: \(toneStatus)")
        setToneStatus(toneStatus)
        
        // Record tone analysis for analytics
        SafeKeyboardDataStorage.shared.recordToneAnalysis(
            text: snapshotFullText(),
            tone: toneStatus,
            confidence: 0.7,    // if you have it from coordinator, pass that instead
            analysisTime: 0.0,  // or real timing if available
            categories: nil
        )
        
        // ✅ CRITICAL: Trigger layout pass after tone data changes
        setNeedsLayout()
        
        if toneStatus != .neutral {    // only mark when "real" tone lands
            lastToneChangeAt = CACurrentMediaTime()
        }
        lastToneStatusString = normalizedTone
        logger.info("🎯 ✅ TONE UPDATE COMPLETE: '\(tone)' -> \(String(describing: toneStatus))")
    }
    
    // MARK: - Tone Button Management
    
    /// Ensures the tone button is always visible and properly configured
    private func ensureToneButtonVisible() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            if let button = self.toneButton {
                button.isHidden = false
                button.alpha = 1.0
            }
            
            if let background = self.toneButtonBackground {
                background.isHidden = false
                background.alpha = 1.0
            }
            
            // Removed: Don't force neutral from visibility helper - causes spam
            // Visibility should not set tone state
        }
    }
    
    // MARK: - Debug Methods
    #if DEBUG
    /// Manually trigger tone analysis for debugging
    func debugTriggerToneAnalysis() {
        logger.info("🔍 Debug: Manually triggering tone analysis")
        coordinator?.analyzeFinalSentence("Debug tone analysis trigger")
    }
    
    /// Force a specific tone for testing
    func debugForceTone(_ tone: String) {
        logger.info("🔥 Debug: Forcing tone to '\(tone)'")
        DispatchQueue.main.async { [weak self] in
            self?.didUpdateToneStatus(tone)
        }
    }
    #endif

    // MARK: - Tone Analysis Integration
    
    // Note: Tone analysis is now handled entirely by ToneSuggestionCoordinator
    // No bridge methods needed - coordinator calls didUpdateToneStatus() directly

    func didUpdateSecureFixButtonState() {
        let remaining = secureFixManager.getRemainingSecureFixUses()
        let hasAdvice = secureFixManager.hasAdviceBeenShown()
        let alpha: CGFloat = (remaining > 0 && hasAdvice) ? 1.0 : 0.5
        quickFixButton?.alpha = alpha
    }
    
    func didReceiveAPIError(_ error: APIError) {
        logger.error("🚨 API Error received: \(error.localizedDescription)")
        
        // Handle different error types with appropriate UI feedback
        switch error {
        case .authRequired:
            // Show authentication required message
            showErrorMessage("Sign in required to use AI features")
            
        case .paymentRequired:
            // Show payment required message with upgrade prompt
            showErrorMessage("Your trial has expired. Subscribe to continue using AI coaching.")
            
        case .serverError(let code):
            // Show generic server error
            showErrorMessage("Server error (\(code)). Please try again later.")
            
        case .networkError:
            // Show network error
            showErrorMessage("Network connection error. Please check your internet connection.")
            
        case .unknown:
            // Show generic unknown error
            showErrorMessage("An unexpected error occurred. Please try again.")
        }
    }
    
    func didReceiveFeatureNoticings(_ noticings: [String]) {
        logger.info("📣 Feature noticings received: \(noticings)")
        // For now, just log the feature noticings
        // Could be expanded to show them in UI or store for analytics
        guard let firstNoticing = noticings.first, !firstNoticing.isEmpty else { return }
        
        DispatchQueue.main.async { [weak self] in
            // Could show feature noticings in suggestion chip or other UI element
            // For now, we'll just log them
            self?.logger.info("📣 First feature noticing: \(firstNoticing)")
        }
    }
    
    // MARK: - Error Handling
    
    /// Shows an error message to the user via a temporary overlay or alert
    private func showErrorMessage(_ message: String) {
        // Debounce error messages to avoid spamming
        guard Date().timeIntervalSince(lastErrorShownAt) > errorCooldown else { return }
        lastErrorShownAt = Date()
        
        logger.info("📢 Showing error message: \(message)")
        
        // For now, we'll use the suggestion chip to show the error message
        // This provides immediate feedback to the user
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            // Show error in suggestion chip with neutral tone
            self.suggestionChipManager.showAutoSuggestion(text: message, toneString: "neutral")  // System error - bypass restriction
            
            // Also log to console for debugging
            #if DEBUG
            KBDLog("🚨 Keyboard API Error: \(message)", .error, "KeyboardController")
            #endif
        }
    }
    
    // MARK: - First-time User Management
    
    private func markKeyboardAsUsed() {
        guard isFirstLaunch else { return }
        AppGroups.shared.set(true, forKey: Self.keyboardUsedKey)
    }

    private func isFirstTimeUser() -> Bool {
        return isFirstLaunch
    }
    
    // MARK: - Selector Methods
    
    @objc private func toneButtonPressed(_ sender: UIButton) {
        pressPop()

        // Prevent accidental double taps
        let now = CACurrentMediaTime()
        guard now >= suggestionCooldownUntil else { return }
        suggestionCooldownUntil = now + suggestionCooldown

        // Get current text for analysis
        let text = snapshotFullText().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            suggestionChipManager.showButtonSuggestion(
                text: "Type a message, then tap the tone icon to see suggestions.",
                toneString: "neutral"
            )
            return
        }

        // Arm suggestions for this explicit request
        suggestionsArmed = true
        
        // Request tone suggestions through dispatcher
        toneSuggestionDispatcher?.requestToneSuggestions(text: text, threadID: currentThreadID)
    }
    
    // MARK: - Debug Methods
    
    #if DEBUG
    /// Debug method to test spell checker functionality
    func debugSpellChecker() {
        logger.info("🔤 Testing spell checker functionality...")
        
        let spellChecker = LightweightSpellChecker.shared
        logger.info("🔤 Spell checker instance obtained: \(type(of: spellChecker))")
        
        // Test common typos
        let testWords = ["hte", "teh", "yuor", "recieve", "definately", "seperate"]
        
        for word in testWords {
            logger.info("🔤 Testing word: '\(word)'")
            
            // Get suggestions using the async API
            spellChecker.requestSuggestions(for: word, range: NSRange(location: 0, length: word.count)) { [weak self] suggestions in
                DispatchQueue.main.async {
                    self?.logger.info("🔤 Suggestions for '\(word)': \(suggestions ?? [])")
                }
            }
        }
        
        // Test app groups
        let testKey = "debug_spell_test"
        AppGroups.shared.set("test_value", forKey: testKey)
        let retrieved = AppGroups.shared.string(forKey: testKey)
        logger.info("🔤 App Groups test - stored/retrieved: \(retrieved == "test_value")")
        AppGroups.shared.removeObject(forKey: testKey)
        
        // Test spell checker integration in keyboard
        if let spellIntegration = spellCheckerIntegration as? SpellCheckerIntegration {
            logger.info("🔤 Spell checker integration: \(type(of: spellIntegration))")
            
            // Test spell checking a sentence
            let testSentence = "Ths is a test sentance with som typos"
            logger.info("🔤 Testing sentence: '\(testSentence)'")
            
            // Note: We can't easily test the actual integration without mocking UITextDocumentProxy
            logger.info("🔤 Spell checker integration test requires active text input")
        }
    }
    
    /// Debug method to test tone color functionality
    func debugToneColors() {
        logger.info("🎨 Testing tone color functionality...")
        
        // Test each tone status
        let tones: [ToneStatus] = [.clear, .caution, .alert, .neutral]
        
        for tone in tones {
            logger.info("🎨 Testing tone: \(tone.rawValue)")
            
            // Manually trigger tone update
            setToneStatus(tone, animated: false)
            
            // Check button colors
            if let button = toneButton {
                logger.info("🎨 Tone button background color: \(button.backgroundColor?.debugDescription ?? "nil")")
                logger.info("🎨 Tone button tint color: \(button.tintColor?.debugDescription ?? "nil")")
                logger.info("🎨 Tone button is hidden: \(button.isHidden)")
            } else {
                logger.error("🎨 Tone button is nil!")
            }
            
            // Check gradient layer
            if let gradient = toneGradient {
                logger.info("🎨 Gradient layer colors count: \(gradient.colors?.count ?? 0)")
                logger.info("🎨 Gradient layer opacity: \(gradient.opacity)")
            } else {
                logger.info("🎨 No gradient layer found")
            }
        }
        
        // Test coordinator state
        if let coord = coordinator {
            logger.info("🎨 Coordinator last tone: \(self.lastToneStatusString)")
            logger.info("🎨 Current UI tone: \(self.currentUITone.rawValue)")
        } else {
            logger.error("🎨 Coordinator is nil!")
        }
    }
    
    /// Debug method to test the full tone analysis pipeline
    func debugToneAnalysis(text: String = "You always do this wrong and it makes me angry") {
        logger.info("🎯 Testing tone analysis pipeline with text: '\(text)'")
        
        guard let coord = coordinator else {
            logger.error("🎯 Coordinator is nil - cannot test tone analysis")
            return
        }
        
        // Trigger analysis manually
        coord.onTextChanged(fullText: text, lastInserted: nil, isDeletion: false)
        
        // Check if delegate methods are being called
        logger.info("🎯 Waiting for tone analysis results...")
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            self.logger.info("🎯 After 2 seconds - last tone: \(self.lastToneStatusString)")
            self.logger.info("🎯 Current UI tone: \(self.currentUITone.rawValue)")
        }
    }
    
    /// Debug method to test suggestion chip display
    func debugSuggestionChip() {
        logger.info("💬 Testing suggestion chip functionality...")
        
        // Test different tone suggestions
        let testSuggestions = [
            ("Try saying: 'I feel frustrated when...'", ToneStatus.alert),
            ("Consider: 'Help me understand your perspective'", ToneStatus.caution),
            ("Great communication! Keep it up.", ToneStatus.clear),
            ("This is a neutral suggestion", ToneStatus.neutral)
        ]
        
        for (i, (text, tone)) in testSuggestions.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 2.0) {
                self.logger.info("💬 Showing suggestion \(i+1): '\(text)' with tone: \(tone.rawValue)")
                self.suggestionChipManager.showAutoSuggestion(text: text, toneString: tone.rawValue)  // Debug mode - bypass restriction
            }
        }
    }
    
    /// Comprehensive debug method to test the entire keyboard system
    func debugFullSystem() {
        logger.info("🔍 FULL SYSTEM DEBUG - Starting comprehensive tests...")
        
        // Test 1: Coordinator state
        logger.info("🔍 TEST 1: Coordinator State")
        coordinator?.debugCoordinatorState()
        
        // Test 2: Spell checker (delay to see output)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            self.logger.info("🔍 TEST 2: Spell Checker")
            self.debugSpellChecker()
        }
        
        // Test 3: Tone colors (delay to see output)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            self.logger.info("🔍 TEST 3: Tone Colors")
            self.debugToneColors()
        }
        
        // Test 4: API connectivity (delay to see output)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            self.logger.info("🔍 TEST 4: API Connectivity")
            self.coordinator?.debugTestToneAPI()
        }
        
        // Test 5: Delegate callbacks (delay to see output)
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
            self.logger.info("🔍 TEST 5: Delegate Callbacks")
            self.coordinator?.debugDelegateCallbacks()
        }
        
        // Test 6: Suggestion chips (delay to see output)
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
            self.logger.info("🔍 TEST 6: Suggestion Chips")
            self.debugSuggestionChip()
            self.suggestionChipManager.debugSuggestionChipState()
        }
        
        // Test 7: Advanced spell checker integration (delay to see output)
        DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) {
            self.logger.info("🔍 TEST 7: Advanced Spell Checker Integration")
            self.debugSpellCheckerIntegration()
        }
        
        // Test 8: Advanced tone color system (delay to see output)
        DispatchQueue.main.asyncAfter(deadline: .now() + 7.0) {
            self.logger.info("🔍 TEST 8: Advanced Tone Color System")
            self.debugToneColorSystem()
        }
        
        // Test 9: Text processing pipeline (delay to see output)
        DispatchQueue.main.asyncAfter(deadline: .now() + 8.0) {
            self.logger.info("🔍 TEST 9: Text Processing Pipeline")
            self.debugTextProcessingPipeline()
        }
        
        logger.info("🔍 FULL SYSTEM DEBUG - All 9 tests scheduled. Check logs for results.")
    }
    
    // MARK: - Advanced Debug Methods
    
    /// Debug method specifically for spell checker integration issues
    func debugSpellCheckerIntegration() {
        logger.info("🔍 SPELL CHECKER INTEGRATION DEBUG")
        logger.info("=====================================")
        
        // Test 1: Check if spell checker integration exists and is configured
        logger.info("🔤 Test 1: Spell Checker Integration State")
        logger.info("🔤 Spell integration object: \(type(of: self.spellCheckerIntegration))")
        
        // Test 2: Check if UITextChecker is available
        #if canImport(UIKit)
        let textChecker = UITextChecker()
        let availableLanguages = UITextChecker.availableLanguages
        logger.info("🔤 UITextChecker available languages: \(availableLanguages.count)")
        logger.info("🔤 First few languages: \(Array(availableLanguages.prefix(5)))")
        #endif
        
        // Test 3: Check spell strip functionality
        logger.info("🔤 Test 3: Spell Strip State")
        logger.info("🔤 Spell strip superview: \(self.spellStrip.superview != nil)")
        logger.info("🔤 Spell strip frame: \(String(describing: self.spellStrip.frame))")
        logger.info("🔤 Spell strip hidden: \(self.spellStrip.isHidden)")
        
        // Test 4: Simulate text input for spell checking
        logger.info("🔤 Test 4: Simulating Text Input")
        simulateTextForSpellCheck()
        
        // Test 5: Check delegate connections
        logger.info("🔤 Test 5: Delegate Connections")
        
        logger.info("🔤 SPELL CHECKER INTEGRATION DEBUG COMPLETE")
    }
    
    /// Debug method specifically for tone color display issues
    func debugToneColorSystem() {
        logger.info("🎨 TONE COLOR SYSTEM DEBUG")
        logger.info("===============================")
        
        // Test 1: Check tone button hierarchy
        logger.info("🎨 Test 1: Tone Button Hierarchy")
        if let button = toneButton {
            logger.info("🎨 Tone button exists: \(type(of: button))")
            logger.info("🎨 Button superview: \(button.superview != nil)")
            logger.info("🎨 Button frame: \(String(describing: button.frame))")
            logger.info("🎨 Button bounds: \(String(describing: button.bounds))")
            logger.info("🎨 Button center: \(String(describing: button.center))")
            logger.info("🎨 Button alpha: \(button.alpha)")
            logger.info("🎨 Button hidden: \(button.isHidden)")
            logger.info("🎨 Button background color: \(button.backgroundColor?.debugDescription ?? "nil")")
            logger.info("🎨 Button tint color: \(button.tintColor?.debugDescription ?? "nil")")
            
            // Check button layers
            logger.info("🎨 Button layer count: \(button.layer.sublayers?.count ?? 0)")
            if let sublayers = button.layer.sublayers {
                for (i, layer) in sublayers.enumerated() {
                    logger.info("🎨 Sublayer \(i): \(type(of: layer)) - hidden: \(layer.isHidden)")
                }
            }
        } else {
            logger.error("🎨 ❌ CRITICAL: Tone button is nil!")
        }
        
        // Test 2: Check tone button background
        logger.info("🎨 Test 2: Tone Button Background")
        if let background = toneButtonBackground {
            logger.info("🎨 Background exists: \(type(of: background))")
            logger.info("🎨 Background frame: \(String(describing: background.frame))")
            logger.info("🎨 Background alpha: \(background.alpha)")
            logger.info("🎨 Background hidden: \(background.isHidden)")
            logger.info("🎨 Background color: \(background.backgroundColor?.debugDescription ?? "nil")")
        } else {
            logger.error("🎨 ❌ CRITICAL: Tone button background is nil!")
        }
        
        // Test 3: Check gradient layer
        logger.info("🎨 Test 3: Gradient Layer")
        if let gradient = toneGradient {
            logger.info("🎨 Gradient exists: \(type(of: gradient))")
            logger.info("🎨 Gradient frame: \(String(describing: gradient.frame))")
            logger.info("🎨 Gradient colors count: \(gradient.colors?.count ?? 0)")
            logger.info("🎨 Gradient opacity: \(gradient.opacity)")
            logger.info("🎨 Gradient hidden: \(gradient.isHidden)")
            
            if let colors = gradient.colors {
                for (i, colorRef) in colors.enumerated() {
                    // colorRef is already CGColor, no need for conditional cast
                    let cgColor = colorRef as! CGColor
                    let uiColor = UIColor(cgColor: cgColor)
                    logger.info("🎨 Gradient color \(i): \(uiColor.debugDescription)")
                }
            }
        } else {
            logger.info("🎨 No gradient layer found")
        }
        
        // Test 4: Test each tone status manually
        logger.info("🎨 Test 4: Manual Tone Status Testing")
        testAllToneStates()
        
        logger.info("🎨 TONE COLOR SYSTEM DEBUG COMPLETE")
    }
    
    /// Helper method to simulate text input for spell checking
    private func simulateTextForSpellCheck() {
        let testTexts = [
            "hte quick brown fox",
            "recieve the message",
            "definately correct",
            "seperate the items"
        ]
        
        for (i, text) in testTexts.enumerated() {
            logger.info("🔤 Simulating text \(i+1): '\(text)'")
            
            // Simulate text change
            currentText = text
            textDidChange()
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.logger.info("🔤 After text change - current text: '\(self.currentText)'")
            }
        }
    }
    
    /// Helper method to test all tone states
    private func testAllToneStates() {
        let tones: [ToneStatus] = [.clear, .caution, .alert, .neutral]
        
        for (i, tone) in tones.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 1.0) {
                self.logger.info("🎨 Setting tone to: \(tone.rawValue)")
                self.setToneStatus(tone, animated: true)
                
                // Check colors after setting
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    self.logToneButtonState(for: tone)
                }
            }
        }
    }
    
    /// Helper method to log tone button state
    private func logToneButtonState(for tone: ToneStatus) {
        logger.info("🎨 State after setting \(tone.rawValue):")
        
        if let button = toneButton {
            logger.info("🎨   Button alpha: \(button.alpha)")
            logger.info("🎨   Button hidden: \(button.isHidden)")
            logger.info("🎨   Button bg color: \(button.backgroundColor?.debugDescription ?? "nil")")
        }
        
        if let background = toneButtonBackground {
            logger.info("🎨   Background alpha: \(background.alpha)")
            logger.info("🎨   Background hidden: \(background.isHidden)")
            logger.info("🎨   Background color: \(background.backgroundColor?.debugDescription ?? "nil")")
        }
        
        if let gradient = toneGradient {
            logger.info("🎨   Gradient opacity: \(gradient.opacity)")
            logger.info("🎨   Gradient colors: \(gradient.colors?.count ?? 0)")
        }
    }
    
    /// Debug method to test the complete text processing pipeline
    func debugTextProcessingPipeline() {
        logger.info("⚙️ TEXT PROCESSING PIPELINE DEBUG")
        logger.info("====================================")
        
        let testSentence = "hte quick brown fox jumps over teh lazy dog"
        
        logger.info("⚙️ Test 1: Simple Text Analysis (without character simulation)")
        logger.info("⚙️ Input text: '\(testSentence)'")
        
        // DISABLED: Character-by-character simulation to prevent API flooding
        // Instead, just test final sentence analysis
        logger.info("⚙️ Simulating final text entry...")
        currentText = testSentence
        
        // Test spell checking after setup
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            self.logger.info("⚙️ Test 2: Final Spell Check")
            self.debugSpellCheckerIntegration()
        }
        
        // Test tone analysis with final sentence only
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            self.logger.info("⚙️ Test 3: Final Tone Analysis")
            self.coordinator?.debugTestToneAPI(with: testSentence)
        }
        
        // Test suggestion chip integration
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            self.logger.info("⚙️ Test 4: Suggestion Chip Integration")
            self.debugTestSuggestionChips()
        }
    }
    #endif
    
    #if DEBUG
    /// Test the entire suggestion chip integration flow
    private func debugTestSuggestionChips() {
        logger.info("🧪 TESTING SUGGESTION CHIP INTEGRATION")
        logger.info("=====================================")
        
        // Test 1: Direct chip manager test
        logger.info("🧪 Test 1: Direct chip manager integration test")
        suggestionChipManager.testIntegration()
        
        // Test 2: Simulate coordinator suggestion update
        DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) {
            self.logger.info("🧪 Test 2: Simulating coordinator suggestion")
            self.didUpdateSuggestions(["This is a test suggestion from the coordinator simulation"])
        }
        
        // Test 3: Test delegate callbacks
        DispatchQueue.main.asyncAfter(deadline: .now() + 12.0) {
            self.logger.info("🧪 Test 3: Current delegate setup:")
            self.logger.info("🧪   - Chip manager delegate set: \(self.suggestionChipManager.delegate != nil)")
            self.logger.info("🧪   - Coordinator delegate set: \(self.coordinator?.delegate != nil)")
            self.logger.info("🧪   - Suggestion bar configured: \(self.suggestionBar != nil)")
        }
    }
    #endif
    
    @objc private func undoButtonPressed(_ sender: UIButton) {
        undoButtonTapped()
    }
}

// MARK: - Logging
extension OSLog {
    static let api = OSLog(subsystem: Bundle.main.bundleIdentifier ?? "com.example.unsaid.UnsaidKeyboard", category: "api")
    static let tone = OSLog(subsystem: Bundle.main.bundleIdentifier ?? "com.example.unsaid.UnsaidKeyboard", category: "tone")
    static let layout = OSLog(subsystem: Bundle.main.bundleIdentifier ?? "com.example.unsaid.UnsaidKeyboard", category: "layout")
}
