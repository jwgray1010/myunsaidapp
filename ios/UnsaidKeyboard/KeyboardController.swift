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

// MARK: - Conditional Debug Logging
#if DEBUG
private func dbg(_ msg: @autoclosure () -> String) {
    let logger = Logger(subsystem: "com.example.unsaid.unsaid.UnsaidKeyboard", category: "KeyboardController")
    let message = msg() // Evaluate the autoclosure immediately
    logger.info("\(message)")
}
#else
private func dbg(_ msg: @autoclosure () -> String) {}
#endif

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
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
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
        // Use KeyButtonFactory for consistent styling
        let button = KeyButtonFactory.makeControlButton(title: title, background: .systemGray6, text: .label)
        button.addAction(UIAction { [weak self] _ in
            self?.onTap?(title)
        }, for: .touchUpInside)
        return button
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
                                SpaceHandlerDelegate,
                                SpellCheckerIntegrationDelegate,
                                SecureFixManagerDelegate {

    // MARK: - Services and Managers
    private let logger = Logger(subsystem: "com.example.unsaid.unsaid.UnsaidKeyboard", category: "KeyboardController")
    private var coordinator: ToneSuggestionCoordinator?
    
    // Managers (UIKit-heavy, per-feature)
    private let deleteManager = DeleteManager()
    private let keyPreviewManager = KeyPreviewManager()
    private let spaceHandler = SpaceHandler()
    private let secureFixManager = SecureFixManager()
    private lazy var suggestionChipManager = SuggestionChipManager(keyboardController: self)
    
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
    private let hapticMinGap: CFTimeInterval = 0.06 // 60ms
    
    // Instant feedback generator for crisp tap response
    private let instantFeedback = UIImpactFeedbackGenerator(style: .light)
    
    // MARK: - Debounce & Coalesce
    private var analyzeTask: Task<Void, Never>?
    
    private func scheduleAnalysis(for text: String, urgent: Bool = false) {
        analyzeTask?.cancel()
        analyzeTask = Task { [weak self] in
            if !urgent {
                try? await Task.sleep(nanoseconds: 150_000_000) // 150ms idle pause (reduced from 220ms)
            }
            guard let self, let coordinator = self.coordinator else { return }
            await MainActor.run {
                self.logger.info("🧠 Debounced analyze: '\(String(text.prefix(60)))…'")
                coordinator.handleTextChange(text)
            }
        }
    }
    
    private func triggerAnalysis(reason: String = "typing") {
        let text = self.currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        let previousText = self.previousTextForDeletion.trimmingCharacters(in: .whitespacesAndNewlines)

        // Trigger analysis after every word (when space is added) or sentence ending
        let wordCount = text.components(separatedBy: .whitespaces).filter { !$0.isEmpty }.count
        let previousWordCount = previousText.components(separatedBy: .whitespaces).filter { !$0.isEmpty }.count
        let hasSentenceEnding = text.contains(where: { ".!?".contains($0) })
        
        // Detect word deletion: fewer words than before
        let wordDeleted = previousWordCount > wordCount && previousWordCount > 0

        // Analyze when we have at least 1 complete word, sentence ending, or word was deleted
        let shouldAnalyze = wordCount >= 1 || hasSentenceEnding || wordDeleted

        if shouldAnalyze {
            let urgent = hasSentenceEnding || wordDeleted // Urgent for sentence endings and deletions
            scheduleAnalysis(for: self.currentText, urgent: urgent)
        }
    }
    
    // Unified haptic feedback method with instant micro-haptics
    private func performHapticFeedback() {
        let now = CACurrentMediaTime()
        if now - lastHapticAt < hapticMinGap { return }   // debounce
        lastHapticAt = now

        // Prepare right before play (improves latency/jitter)
        instantFeedback.prepare()
        instantFeedback.impactOccurred(intensity: 0.8)
        
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
    private var previousTextForDeletion: String = ""  // Track previous text to detect deletions
    
    // Tone tracking for SecureFix gating
    private var lastToneStatusString: String = "neutral"
    private var currentUITone: ToneStatus = .neutral

    // Layout constants
    private let verticalSpacing: CGFloat = 8
    private let horizontalSpacing: CGFloat = 6
    private let sideMargins: CGFloat = 8
    
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
        if let superView = superview, superView.bounds.height > 0 {
            return CGSize(width: UIView.noIntrinsicMetric, height: superView.bounds.height)
        }
        return CGSize(width: UIView.noIntrinsicMetric, height: 422) // Increased from 396 to account for taller prediction bar
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
        parentInputVC = inputVC
        coordinator = ToneSuggestionCoordinator()
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
                self?.logger.info("ToneButton: post-config state -> visible, alpha=\(button.alpha), hidden=\(button.isHidden)")
                #endif
            }
        }
        
        // App Group sanity check
    let test = AppGroups.shared
    test.set(true, forKey: "groupRoundtrip")
    let ok = test.bool(forKey: "groupRoundtrip")
        logger.info("App Group roundtrip ok: \(ok)")
        
        // Debug API configuration
        let extBundle = Bundle(for: KeyboardController.self)
        let baseURL = extBundle.object(forInfoDictionaryKey: "UNSAID_API_BASE_URL") as? String ?? "NOT FOUND"
        let apiKey = extBundle.object(forInfoDictionaryKey: "UNSAID_API_KEY") as? String ?? "NOT FOUND"
        dbg("🔧 API Config - Base URL: \(baseURL)")
        dbg("🔧 API Config - API Key: \(apiKey.prefix(10))...")
        dbg("🔧 Coordinator initialized: \(self.coordinator != nil)")
        
        // Test network connectivity immediately (don't let this affect UI visibility)
        coordinator?.forceImmediateAnalysis("ping")
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
        dbg("🔧 KeyboardController.commonInit() starting...")
        
        // Prepare instant haptic feedback for crisp response
        instantFeedback.prepare()
        
        dbg("🔧 Setting up delegates...")
        setupDelegates()
        dbg("✅ Delegates setup complete")
        
        dbg("🔧 Setting up suggestion bar...")
        setupSuggestionBar()    // create it first
        dbg("✅ Suggestion bar setup complete")
        
        dbg("🔧 Setting up keyboard layout...")
        setupKeyboardLayout()   // then layout that pins to it
        dbg("✅ Keyboard layout setup complete")
        
        dbg("✅ KeyboardController.commonInit() completed successfully")
    }
    
    private func setupDelegates() {
        // Setup all manager delegates
        deleteManager.delegate = self
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
        
        guard let bg = toneButtonBackground, let g = toneGradient else { return }
        let newBounds = bg.bounds.integral
        guard g.frame != newBounds else { return } // ✨ skip redundant work
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        g.frame = newBounds
        g.cornerRadius = newBounds.height / 2
        bg.layer.shadowPath = UIBezierPath(roundedRect: newBounds, cornerRadius: g.cornerRadius).cgPath
        CATransaction.commit()
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
        textDidChange()
    }
    
    func performDeleteTick() {
        guard let proxy = textDocumentProxy else { return }
        proxy.deleteBackward()
        textDidChange()
    }
    
    func hapticLight() {
        performHapticFeedback()
    }
    
    // MARK: - Suggestion Chip Methods
    func performHapticForChipExpansion() {
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
        
        // Update our text state
        handleTextChange()
        
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
        toneButton.addAction(UIAction { [weak self] _ in
            // Request suggestions when tone button is tapped
            self?.coordinator?.requestSuggestions()
            self?.pressPop()
        }, for: .touchUpInside)

        undoButton.addAction(UIAction { [weak self] _ in
            self?.undoButtonTapped()
        }, for: .touchUpInside)

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

        // Start with neutral tone - ensure button is visible
        setToneStatus(.neutral)
        
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
            self?.setToneStatus(self?.currentTone ?? .neutral, animated: false)
            
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
            dbg("✅ KeyboardController: Loaded from keyboard Asset Catalog with correct scale")
            return
        }

        // Method 2: Try direct PNG file in keyboard extension bundle (simple & reliable)
        if let logoPath = keyboardBundle.path(forResource: "unsaid_logo", ofType: "png"),
           let logoImage = UIImage(contentsOfFile: logoPath) {
            // Use original rendering mode (not template) so logo keeps its design
            button.setImage(logoImage.withRenderingMode(.alwaysOriginal), for: .normal)
            button.adjustsImageWhenHighlighted = false
            dbg("✅ KeyboardController: Loaded unsaid_logo.png directly from keyboard bundle")
            return
        }

        // Method 3: Try main app bundle as last resort
        if let logoImage = UIImage(named: "unsaid_logo", in: Bundle.main, compatibleWith: traitCollection) {
            // Use original rendering mode (not template) so logo keeps its design
            button.setImage(logoImage.withRenderingMode(.alwaysOriginal), for: .normal)
            button.adjustsImageWhenHighlighted = false
            dbg("✅ KeyboardController: Loaded from main app bundle")
            return
        }

        // Method 4: Create a simple programmatic logo as backup
        dbg("❌ KeyboardController: All methods failed, creating programmatic logo")
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
            ctx.fillEllipse(in: CGRect(x: 0, y: 0, width: size.width, height: size.height))
            
            // Add a subtle border
            ctx.setStrokeColor(UIColor.systemGray3.cgColor)
            ctx.setLineWidth(1.0)
            ctx.strokeEllipse(in: CGRect(x: 0.5, y: 0.5, width: size.width - 1, height: size.height - 1))
            
            // Draw "U" in the center
            ctx.setFillColor(UIColor.systemBlue.cgColor)
            let font = UIFont.systemFont(ofSize: 24, weight: .bold)
            let text = "U"
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: UIColor.systemBlue
            ]
            let textSize = text.size(withAttributes: attributes)
            let textRect = CGRect(
                x: (size.width - textSize.width) / 2.0,
                y: (size.height - textSize.height) / 2.0,
                width: textSize.width,
                height: textSize.height
            )
            text.draw(in: textRect, withAttributes: attributes)
        }

        return image.withRenderingMode(.alwaysOriginal)
    }

    // MARK: - Tone Status Management

    private func setToneStatus(_ tone: ToneStatus, animated: Bool = true) {
        logger.info("🎯 setToneStatus called with: \(String(describing: tone)), animated: \(animated)")
        logger.info("🎯 Current tone button: exists=\(self.toneButton != nil), visible=\(self.toneButton?.isHidden == false)")
        logger.info("🎯 Current tone background: exists=\(self.toneButtonBackground != nil), visible=\(self.toneButtonBackground?.isHidden == false)")
        
        guard let bg = toneButtonBackground else {
            logger.warning("🎯 No tone button background found!")
            return
        }
        guard tone != currentTone || bg.alpha == 0.0 || (toneGradient?.colors == nil) else {
            logger.info("🎯 Skipping redundant tone update")
            return
        } // skip redundant work, but allow first real change
        currentTone = tone
        logger.info("🎯 Updating tone button to: \(String(describing: tone))")

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
            g.cornerRadius = bg.bounds.height / 2.0
            g.frame = bg.bounds
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
            dbg("🎨 tone=\(tone) colors=\(String(describing: g.colors)) frame=\(g.frame)")
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
        switch tone {
        case .alert:
            let c1 = UIColor.systemRed
            let c2 = UIColor.systemRed.withAlphaComponent(0.85)
            return ([c1.cgColor, c2.cgColor], nil)
        case .caution:
            let c1 = UIColor.systemYellow
            let c2 = UIColor.systemYellow.withAlphaComponent(0.85)
            return ([c1.cgColor, c2.cgColor], nil)
        case .clear:
            let c1 = UIColor.systemGreen
            let c2 = UIColor.systemTeal.withAlphaComponent(0.85)
            return ([c1.cgColor, c2.cgColor], nil)
        case .neutral:
            let c = UIColor.white
            return ([c.cgColor, c.cgColor], UIColor.white)
        @unknown default:
            let c = UIColor.white
            return ([c.cgColor, c.cgColor], UIColor.white)
        }
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

        mainStack.addArrangedSubview(topRow)
        mainStack.addArrangedSubview(midRow)
        mainStack.addArrangedSubview(thirdRow)
        mainStack.addArrangedSubview(controlRow)

        addSubview(mainStack)
        keyboardStackView = mainStack

        NSLayoutConstraint.activate([
            mainStack.topAnchor.constraint(equalTo: suggestionBar.bottomAnchor, constant: 12), // Increased from 8 to 12 for better spacing
            mainStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: sideMargins),
            mainStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -sideMargins),
            mainStack.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -8)
        ])
    }

    private func rowStack(for titles: [String], centerNine: Bool = false) -> UIStackView {
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.distribution = .fillEqually
        stack.spacing = horizontalSpacing

        if centerNine && titles.count == 9 {
            stack.isLayoutMarginsRelativeArrangement = true
            stack.directionalLayoutMargins = .init(top: 0, leading: 18, bottom: 0, trailing: 18)
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

        // Mode (123/ABC)
        let mode = KeyButtonFactory.makeControlButton(title: currentMode == .letters ? "123" : "ABC")
        mode.addTarget(self, action: #selector(handleModeSwitch), for: .touchUpInside)
        mode.addTarget(self, action: #selector(specialButtonTouchDown(_:)), for: .touchDown)
        mode.addTarget(self, action: #selector(specialButtonTouchUp(_:)), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        modeButton = mode

        // Globe (super compact)
        let globe = KeyButtonFactory.makeGlobeButton()     
        globe.addTarget(self, action: #selector(handleGlobeKey), for: .touchUpInside)
        globe.addTarget(self, action: #selector(specialButtonTouchDown(_:)), for: .touchDown)
        globe.addTarget(self, action: #selector(specialButtonTouchUp(_:)), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        globeButton = globe

        // Make globe compact
        globe.accessibilityLabel = "Next Keyboard"
        globe.titleLabel?.font = .systemFont(ofSize: 13, weight: .regular)
        globe.titleLabel?.adjustsFontForContentSizeCategory = false

        // Space (dominant)
        let space = KeyButtonFactory.makeSpaceButton()
        space.addTarget(self, action: #selector(handleSpaceKey), for: .touchUpInside)
        space.addTarget(self, action: #selector(specialButtonTouchDown(_:)), for: .touchDown)
        space.addTarget(self, action: #selector(specialButtonTouchUp(_:)), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        spaceButton = space
        spaceHandler.setupSpaceButton(space)

        // Secure Fix (smaller than space)
        let secureFix = KeyButtonFactory.makeSecureButton()
        quickFixButton = secureFix
        secureFix.addTarget(self, action: #selector(handleSecureFix), for: UIControl.Event.touchUpInside)
        secureFix.addTarget(self, action: #selector(secureFixTouchDown(_:)), for: UIControl.Event.touchDown)
        secureFix.addTarget(self, action: #selector(secureFixTouchUp(_:)), for: [UIControl.Event.touchUpInside, UIControl.Event.touchUpOutside])

        // Return
        let returnBtn = KeyButtonFactory.makeReturnButton()
        returnBtn.addTarget(self, action: #selector(handleReturnKey), for: UIControl.Event.touchUpInside)
        returnBtn.addTarget(self, action: #selector(specialButtonTouchDown(_:)), for: UIControl.Event.touchDown)
        returnBtn.addTarget(self, action: #selector(specialButtonTouchUp(_:)), for: [UIControl.Event.touchUpInside, UIControl.Event.touchUpOutside, UIControl.Event.touchCancel])
        returnButton = returnBtn

        // Order: [mode][globe][space][secureFix][return]
        stack.addArrangedSubview(mode)
        stack.addArrangedSubview(globe)
        stack.addArrangedSubview(space)
        stack.addArrangedSubview(secureFix)
        stack.addArrangedSubview(returnBtn)

        // Sizing rules - let space expand, but fixed widths for other controls
        let standardWidth: CGFloat = 68
        let returnButtonWidth: CGFloat = 51  // 25% smaller than standard
        let secureButtonWidth: CGFloat = 61  // 10% smaller than standard
        
        // Space is the only flexible one
        space.widthAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true  // Reduced minimum
        space.setContentHuggingPriority(.defaultLow, for: .horizontal)
        space.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // Fixed widths for non-space controls
        mode.widthAnchor.constraint(equalToConstant: standardWidth).isActive = true
        secureFix.widthAnchor.constraint(equalToConstant: secureButtonWidth).isActive = true
        returnBtn.widthAnchor.constraint(equalToConstant: returnButtonWidth).isActive = true
        // Globe is intentionally small
        globe.widthAnchor.constraint(equalToConstant: 34).isActive = true

        [secureFix, mode, globe, returnBtn].forEach {
            $0.setContentHuggingPriority(.required, for: .horizontal)
            $0.setContentCompressionResistancePriority(.required, for: .horizontal)
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
        
        textDidChange()
    }
    
    @objc private func handleSpaceKey() {
        spaceHandler.handleSpaceKey()
    }
    
    @objc private func handleReturnKey() {
        guard let proxy = textDocumentProxy else { return }
        proxy.insertText("\n")
        textDidChange() // This will call updateShiftForContext
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
        
        handleTextChange()
        updateShiftForContext()
    }
    
    private func handleTextChange() {
        // Store previous text before updating for deletion detection
        previousTextForDeletion = currentText
        
        updateCurrentText()
        refreshContext()
        spellCheckerIntegration.refreshSpellCandidates(for: currentText)
        
        // Trigger debounced tone analysis
        logger.info("📝 Text changed, triggering debounced analysis: '\(String(self.currentText.prefix(50)))...'")
        triggerAnalysis(reason: "typing")
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
            scheduleAnalysis(for: currentText, urgent: true)
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
        default:        setToneStatus(.neutral)
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
        logger.info("💡 Received suggestions: \(String(describing: suggestions))")
        guard let first = suggestions.first else { return }
        suggestionChipManager.showSuggestion(text: first, tone: currentUITone)  // Type-safe
        secureFixManager.markAdviceShown(toneString: String(describing: currentUITone))
        quickFixButton?.alpha = 1.0
    }

    func didUpdateToneStatus(_ tone: String) {
        logger.info("🎯 Received tone status: \(tone)")
        logger.info("🎯 Current tone button exists: \((self.toneButton != nil))")
        logger.info("🎯 Current tone background exists: \((self.toneButtonBackground != nil))")
        
        // Ensure UI updates happen on main thread
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            // Use the new ToneStatus extension for safe mapping
            let toneStatus = ToneStatus(from: tone)
            self.currentUITone = toneStatus
            self.setToneStatus(toneStatus)
            
            // Update string for legacy compatibility where needed
            self.lastToneStatusString = toneStatus.rawValue
            
            self.logger.info("🎯 Mapped '\(tone)' to '\(toneStatus.rawValue)' -> \(String(describing: toneStatus))")
            self.logger.info("ToneButton: state -> \(toneStatus.rawValue), button visible: \((self.toneButton?.isHidden == false))")
        }
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
            
            // Set to neutral state if no current tone
            if self.currentTone == .neutral {
                self.setToneStatus(.neutral, animated: false)
            }
        }
    }
    
    // MARK: - Tone Analysis Integration
    
    /// Bridge method to call updateToneFromAnalysis on the coordinator
    /// This allows the KeyboardViewController to trigger tone updates from shared storage data
    func updateToneFromAnalysis(_ analysis: [String: Any]) {
        logger.info("🎯 KeyboardController: Bridging tone analysis update to coordinator")
        coordinator?.updateToneFromAnalysis(analysis)
    }

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
    
    // MARK: - Error Handling
    
    /// Shows an error message to the user via a temporary overlay or alert
    private func showErrorMessage(_ message: String) {
        logger.info("📢 Showing error message: \(message)")
        
        // For now, we'll use the suggestion chip to show the error message
        // This provides immediate feedback to the user
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            // Show error in suggestion chip with neutral tone
            self.suggestionChipManager.showSuggestion(text: message, tone: .neutral)
            
            // Also log to console for debugging
            #if DEBUG
            print("🚨 Keyboard API Error: \(message)")
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
}