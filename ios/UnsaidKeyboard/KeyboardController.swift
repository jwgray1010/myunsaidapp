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
final class KeyboardController: UIInputView,
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
    
    // MARK: - Router Pattern for Sentence-Aware Analysis
    
    /// Captures the full text snapshot from the document proxy
    private func snapshotFullText() -> String {
        guard let proxy = textDocumentProxy else { return "" }
        let before = proxy.documentContextBeforeInput ?? ""
        let after = proxy.documentContextAfterInput ?? ""
        return before + after
    }
    
    /// Router method that calls the new sentence-aware coordinator API
    private func scheduleAnalysisRouter(lastInserted: String? = nil, isDeletion: Bool = false, urgent: Bool = false) {
        guard let coordinator = coordinator else { return }
        
        analyzeTask?.cancel()
        analyzeTask = Task { [weak self] in
            if !urgent {
                try? await Task.sleep(nanoseconds: 220_000_000) // 220ms idle pause
            }
            guard let self = self else { return }
            
            await MainActor.run {
                let fullText = self.snapshotFullText()
                #if DEBUG
                let preview = String(fullText.prefix(60))
                if self.logGate.allow("router", preview) {
                    KBDLog("🔄 Router analysis: '\(preview)…' inserted='\(lastInserted ?? "none")' deletion=\(isDeletion)", .debug, "KeyboardController")
                }
                #endif
                
                // Prevent overlapping tone requests
                if !self.toneRequestInFlight {
                    self.toneRequestInFlight = true
                    coordinator.onTextChanged(fullText: fullText, lastInserted: lastInserted?.first, isDeletion: isDeletion)
                    
                    // Reset flag after a reasonable timeout (coordinator should reset it sooner)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
                        self?.toneRequestInFlight = false
                    }
                }
            }
        }
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
    
    // Safe area constraint management
    private var safeAreaBottomConstraint: NSLayoutConstraint?

    // MARK: - Convenience
    private var textDocumentProxy: UITextDocumentProxy? { parentInputVC?.textDocumentProxy }

    // MARK: - Lifecycle
    override var intrinsicContentSize: CGSize {
        // Width: let the system take full screen width
        // Height: let constraints/safe area drive height (suggestion bar + keyboard + margins)
        return CGSize(width: UIView.noIntrinsicMetric, height: UIView.noIntrinsicMetric)
    }

    override init(frame: CGRect, inputViewStyle: UIInputView.Style) {
        super.init(frame: frame, inputViewStyle: inputViewStyle)
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
                #if DEBUG
                    KBDLog("ToneButton: post-config state -> visible, alpha=\(button.alpha), hidden=\(button.isHidden)", .debug, "KeyboardController")
                #endif
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
        KBDLog("🔧 API Config - API Key: \(apiKey.prefix(10))...", .debug, "KeyboardController")
        KBDLog("🔧 Coordinator initialized: \(self.coordinator != nil)", .debug, "KeyboardController")
        
        // Note: Removed immediate analysis ping to prevent any startup tone changes
        // coordinator?.forceImmediateAnalysis("ping")
        
        // NOTE: Removed automatic tone cycling for better UX
        // Manual tone test still available via long press on tone button
        
        // Note: Removed DEBUG testToneAPIWithDebugText() call to prevent
        // automatic tone cycling when keyboard opens
    }
    
    deinit {
        // Ensure haptic session is stopped when keyboard is deallocated
        hapticIdleTimer?.cancel()
        if isHapticSessionStarted {
            coordinator?.stopHapticSession()
        }
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
        
        // Apply QWERTY stagger after layout
        applyQwertyStaggerIfNeeded()
        
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
            g.frame = nonZeroRect(bg.bounds.integral)
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
        spellCheckerIntegration.refreshSpellCandidates(for: snapshotFullText())
        // Use router pattern for sentence-aware analysis after deletion
        scheduleAnalysisRouter(lastInserted: nil, isDeletion: true, urgent: false)
    }
    
    func performDeleteTick() {
        guard let proxy = textDocumentProxy else { return }
        proxy.deleteBackward()
        // 👉 refresh candidates on repeat delete
        spellCheckerIntegration.refreshSpellCandidates(for: snapshotFullText())
        // Use router pattern for sentence-aware analysis after deletion
        scheduleAnalysisRouter(lastInserted: nil, isDeletion: true, urgent: false)
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
        // Reset SecureFix gate when advice is dismissed
        secureFixManager.resetAdviceGate()
        quickFixButton?.alpha = 0.5
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
        scheduleAnalysisRouter(lastInserted: correction, isDeletion: false, urgent: true)
        
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
        suggestionChipManager.showSuggestion(text: message, tone: .caution)  // Type-safe
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
        
        // Debug logging for button lifecycle
        #if DEBUG
        logger.info("ToneButton: didAdd - button added to view hierarchy")
        logger.info("ToneButton: state -> visible, alpha=\(toneButton.alpha), hidden=\(toneButton.isHidden)")
        #endif

        // ✅ CRITICAL: Configure chip manager with suggestion bar so chips anchor properly
        self.suggestionChipManager.configure(suggestionBar: pBar)

        // Create gradient layer for smaller background circle
        let g = CAGradientLayer()
        g.startPoint = CGPoint(x: 0, y: 0)
        g.endPoint = CGPoint(x: 1, y: 1)
        g.cornerRadius = 18  // Match smaller background circle
        g.masksToBounds = true
        g.colors = [UIColor.white.cgColor, UIColor.white.cgColor]  // Start with white visible
        toneButtonBackground.layer.insertSublayer(g, at: 0)
        toneGradient = g

        // Add shadow
        toneButtonBackground.layer.shadowColor = UIColor.black.cgColor
        toneButtonBackground.layer.shadowOffset = CGSize(width: 0, height: 1)
        toneButtonBackground.layer.shadowRadius = 3
        toneButtonBackground.layer.shadowOpacity = 0

        // Add actions
        toneButton.addTarget(self, action: #selector(toneButtonPressed(_:)), for: .touchUpInside)

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
            spellStrip.leadingAnchor.constraint(equalTo: toneButtonBackground.trailingAnchor, constant: 8),
            spellStrip.trailingAnchor.constraint(equalTo: undoButton.leadingAnchor, constant: -8)
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
            #if DEBUG
            logger.info("ToneButton: initial state -> visible, alpha=\(button.alpha), hidden=\(button.isHidden)")
            #endif
        }
        
        // Force layout pass to ensure gradient frame is correct  
        DispatchQueue.main.async { [weak self] in
            // Removed redundant setToneStatus call - already set on line 796
            
            // Double-check visibility after layout
            if let button = self?.toneButton {
                button.isHidden = false
                button.alpha = 1.0
                #if DEBUG
                self?.logger.info("ToneButton: post-layout state -> visible, alpha=\(button.alpha), hidden=\(button.isHidden)")
                #endif
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
        #if DEBUG
        if logGate.allow("tone_set", tone.rawValue) {
            KBDLog("🎯 setToneStatus(\(tone.rawValue)) animated=\(animated) bg=\(self.toneButtonBackground != nil) btn=\(self.toneButton != nil)", .info, "KeyboardController")
        }
        #endif
        
        guard let bg = toneButtonBackground else {
            KBDLog("🎯 ❌ CRITICAL ERROR: No tone button background found!", .error, "KeyboardController")
            return
        }
        
        // Better visual state detection for re-application
        let visualOutOfSync =
            (toneGradient == nil) ||
            (toneGradient?.colors == nil) ||
            (bg.layer.animation(forKey: "alertPulse") == nil && tone == .alert)
        
        guard tone != currentTone || bg.alpha < 0.99 || visualOutOfSync else {
            return // skip redundant work, but allow refresh when visual state is stale
        }

        // Ensure background is definitely visible
        bg.isHidden = false
        bg.alpha = max(bg.alpha, 1.0)
        
        // Ensure tone button itself is also visible
        if let button = toneButton {
            button.isHidden = false
            button.alpha = max(button.alpha, 1.0)
            #if DEBUG
            logger.info("ToneButton: state -> visible, alpha=\(button.alpha), hidden=\(button.isHidden)")
            #endif
        }

        // Destination visual state
        let gradientResult = gradientColors(for: tone)
        let (colors, baseColor) = gradientResult
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

        // Shift (caps) on the left
        let shift = KeyButtonFactory.makeShiftButton()
        shift.addTarget(self, action: #selector(handleShiftPressed), for: .touchUpInside)
        shift.addTarget(self, action: #selector(specialButtonTouchDown(_:)), for: .touchDown)
        shift.addTarget(self, action: #selector(specialButtonTouchUp(_:)), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        shiftButton = shift

        // Letter keys
        let lettersRow = UIStackView()
        lettersRow.axis = .horizontal
        lettersRow.spacing = horizontalSpacing
        lettersRow.distribution = .fillEqually
        for title in titles {
            let b = KeyButtonFactory.makeKeyButton(title: shouldCapitalizeKey(title) ? title.uppercased() : title)
            b.addTarget(self, action: #selector(keyTapped(_:)), for: UIControl.Event.touchUpInside)
            b.addTarget(self, action: #selector(buttonTouchDown(_:)), for: UIControl.Event.touchDown)
            b.addTarget(self, action: #selector(buttonTouchUp(_:)), for: [UIControl.Event.touchUpInside, UIControl.Event.touchUpOutside, UIControl.Event.touchCancel])
            lettersRow.addArrangedSubview(b)
        }

        // Delete on the right
        let delete = KeyButtonFactory.makeDeleteButton()
        delete.addTarget(self, action: #selector(deleteTouchDown), for: UIControl.Event.touchDown)
        delete.addTarget(self, action: #selector(deleteTouchUp), for: [UIControl.Event.touchUpInside, UIControl.Event.touchUpOutside, UIControl.Event.touchCancel])
        deleteButton = delete

        // Width hints (like iOS: wider modifiers, equal letters)
        shift.widthAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        delete.widthAnchor.constraint(greaterThanOrEqualToConstant: 52).isActive = true

        stack.addArrangedSubview(shift)
        stack.addArrangedSubview(lettersRow)
        stack.addArrangedSubview(delete)

        // Let letters expand; keep shift/delete compact
        shift.setContentHuggingPriority(UILayoutPriority.required, for: NSLayoutConstraint.Axis.horizontal)
        delete.setContentHuggingPriority(UILayoutPriority.required, for: NSLayoutConstraint.Axis.horizontal)
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

        // Mode (123/ABC)
        let mode = KeyButtonFactory.makeModeButton(title: currentMode == .letters ? "123" : "ABC")
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

        // Constraint-clean layout: Equal width for 123/Secure/Return, smaller globe, expandable space
        
        // 1. Equal width constraints for mode, secureFix, and return
        mode.widthAnchor.constraint(equalTo: secureFix.widthAnchor).isActive = true
        mode.widthAnchor.constraint(equalTo: returnBtn.widthAnchor).isActive = true
        
        // 2. Globe gets smaller fixed width
        globe.widthAnchor.constraint(equalToConstant: 44).isActive = true
        
        // 3. Mode gets baseline width (others will match via equal width constraints)
        mode.widthAnchor.constraint(equalToConstant: 68).isActive = true
        
        // 4. Space expands to fill remaining space - low hugging priority
        space.setContentHuggingPriority(.defaultLow, for: .horizontal)
        space.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        
        // 5. Fixed-width buttons resist expansion
        [mode, globe, secureFix, returnBtn].forEach { button in
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
        spellCheckerIntegration.refreshSpellCandidates(for: snapshotFullText())
        
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
        
        // Use router pattern for sentence-aware analysis
        let urgent = ".!?".contains(title) // Urgent if punctuation that might end sentence
        scheduleAnalysisRouter(lastInserted: textToInsert, isDeletion: false, urgent: urgent)
    }
    
    @objc private func handleSpaceKey() {
        spaceHandler.handleSpaceKey()
        // Use router pattern for sentence-aware analysis after space insertion
        scheduleAnalysisRouter(lastInserted: " ", isDeletion: false, urgent: false)
        // 👉 refresh (shows/hides strip appropriately after commit)
        spellCheckerIntegration.refreshSpellCandidates(for: snapshotFullText())
    }
    
    @objc private func handleReturnKey() {
        guard let proxy = textDocumentProxy else { return }
        proxy.insertText("\n")
        // Use router pattern for sentence-aware analysis after return insertion
        scheduleAnalysisRouter(lastInserted: "\n", isDeletion: false, urgent: true) // Urgent for new line
        // 👉 refresh after newline
        spellCheckerIntegration.refreshSpellCandidates(for: snapshotFullText())
    }
    
    @objc private func handleGlobeKey() {
        parentInputVC?.advanceToNextInputMode()
    }
    
    @objc private func handleShiftPressed() {
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
    
    @objc private func handleModeSwitch() {
        setKeyboardMode(currentMode == .letters ? .numbers : .letters)
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
        modeButton?.setTitle(currentMode == .letters ? "123" : "ABC", for: .normal)
        updateShiftButtonAppearance()
        updateKeycaps()
        
        // Apply stagger on next runloop so frames are valid
        DispatchQueue.main.async { [weak self] in 
            self?.applyQwertyStaggerIfNeeded() 
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
        // Ensure tone button is visible when text changes (analysis may update it)
        ensureToneButtonVisible()
        
        // Use router pattern for sentence-aware analysis
        scheduleAnalysisRouter(lastInserted: nil, isDeletion: false, urgent: false)
        updateShiftForContext()
        
        // 👉 feed the spell bar
        spellCheckerIntegration.refreshSpellCandidates(for: snapshotFullText())
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
            scheduleAnalysisRouter(lastInserted: nil, isDeletion: false, urgent: true)
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
        guard let b = undoButton, b.isHidden == visible else { return }
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
        logger.info("💡 suggestions.count=\(suggestions.count)")
        guard let first = suggestions.first, !first.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            logger.info("💡 No suggestions to show")
            return
        }
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.suggestionChipManager.showSuggestion(text: first, tone: self.currentUITone)
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
        // Reset in-flight flag since we got a response
        toneRequestInFlight = false
        
        // Performance Optimization #1: Fast guard for redundant tone updates
        let normalizedTone = tone.lowercased()
        if lastToneStatusString == normalizedTone {
            return // Skip redundant update - tone hasn't actually changed
        }
        
        KBDLog("🎯 🔥 KEYBOARD RECEIVED TONE: '\(tone)'", .info, "KeyboardController")
        let toneStatus = ToneStatus(from: tone)
        
        // Gate neutral to avoid flicker + spam
        if toneStatus == .neutral && !shouldAllowNeutralNow() && !sentenceLikelyEnded(currentText) {
            logger.info("🎯 Neutral suppressed by idle gate (no sentence boundary)")
            return
        }
        
        currentUITone = toneStatus
        setToneStatus(toneStatus)
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
                #if DEBUG
                self.logger.info("ToneButton: ensured visible - alpha=\(button.alpha), hidden=\(button.isHidden)")
                #endif
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
        logger.info("🎯 Received \(noticings.count) feature noticings from FeatureSpotter")
        
        // Display feature noticings as helpful suggestions using the existing suggestion chip system
        if !noticings.isEmpty {
            // Use the first noticing as the primary suggestion with a distinct tone
            suggestionChipManager.showSuggestion(text: noticings[0], tone: .clear)
            
            // Log all noticings for debugging
            for (i, notice) in noticings.enumerated() {
                logger.info("  Feature noticing \(i+1): \(notice)")
            }
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
            self.suggestionChipManager.showSuggestion(text: message, tone: .neutral)
            
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
        // Always give crisp feedback
        pressPop()

        // Kick an immediate analysis using router pattern
        scheduleAnalysisRouter(lastInserted: nil, isDeletion: false, urgent: true)

        // If tone is risky, fetch suggestions too
        if currentTone == .alert || currentTone == .caution {
            guard let textBefore = textDocumentProxy?.documentContextBeforeInput?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  !textBefore.isEmpty else {
                logger.info("🎯 No text available for suggestions")
                return
            }
            
            // Performance Optimization #2: Single-flight + tap throttling (0.8s)
            let now = CFAbsoluteTimeGetCurrent()
            if now - lastSuggestionFetchTime < 0.8 {
                return // Throttle rapid taps
            }
            
            // Cancel any in-flight suggestion request
            activeSuggestionTask?.cancel()
            
            lastSuggestionFetchTime = now
            activeSuggestionTask = Task { // @MainActor context here
                let suggestions: [String] = await withUnsafeContinuation { continuation in
                    coordinator?.fetchSuggestions(for: textBefore) { suggestions in
                        continuation.resume(returning: suggestions ?? [])
                    }
                }
                guard !Task.isCancelled else { return }
                
                guard let first = suggestions.first else {
                    logger.info("🎯 No suggestions received")
                    return
                }
                suggestionChipManager.showSuggestion(text: first, tone: currentTone)
                secureFixManager.markAdviceShown(toneString: currentTone.rawValue)
                quickFixButton?.alpha = 1.0
                activeSuggestionTask = nil
            }
        }
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
                logger.info("🎨 Tone button alpha: \(button.alpha)")
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
                self.suggestionChipManager.showSuggestion(text: text, tone: tone)
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
