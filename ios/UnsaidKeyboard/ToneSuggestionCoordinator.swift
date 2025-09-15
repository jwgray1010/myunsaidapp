import Foundation
import os.log
import Network
#if canImport(UIKit)
import UIKit
#endif

// Import shared types for ToneStatus, InteractionType, KeyboardInteraction, etc.
// This ensures proper compilation order in the UnsaidKeyboard target build sequence.

// Import additional dependencies used by ToneSuggestionCoordinator
// Note: The specific file references ensure proper compilation order
// in the UnsaidKeyboard target build sequence.

// MARK: - Delegate Protocol
@MainActor
protocol ToneSuggestionDelegate: AnyObject {
    func didUpdateSuggestions(_ suggestions: [String])
    func didUpdateToneStatus(_ tone: String)  // <- back to String for Xcode compatibility
    func didUpdateSecureFixButtonState()
    #if canImport(UIKit)
    func getTextDocumentProxy() -> UITextDocumentProxy?
    #endif
}

// MARK: - Conversation History Models
private struct SharedConvItem: Codable {
    let sender: String
    let text: String
    let timestamp: TimeInterval
}

// MARK: - Coordinator
final class ToneSuggestionCoordinator {
    // MARK: Public
    weak var delegate: ToneSuggestionDelegate?

    // MARK: - Cached utilities
    private static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    
    // MARK: - Cached config
    private lazy var cachedAPIBaseURL: String = {
        let extBundle = Bundle(for: ToneSuggestionCoordinator.self)
        let mainBundle = Bundle.main
        let fromExt = extBundle.object(forInfoDictionaryKey: "UNSAID_API_BASE_URL") as? String
        let fromMain = mainBundle.object(forInfoDictionaryKey: "UNSAID_API_BASE_URL") as? String
        let picked = (fromExt?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                      ?? fromMain?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty)
        return picked ?? ""
    }()
    
    private lazy var cachedAPIKey: String = {
        let extBundle = Bundle(for: ToneSuggestionCoordinator.self)
        let mainBundle = Bundle.main
        let fromExt = extBundle.object(forInfoDictionaryKey: "UNSAID_API_KEY") as? String
        let fromMain = mainBundle.object(forInfoDictionaryKey: "UNSAID_API_KEY") as? String
        return (fromExt?.nilIfEmpty ?? fromMain?.nilIfEmpty) ?? ""
    }()

    // MARK: - Helper for API timestamp format
    private func isoTimestamp() -> String {
        Self.iso8601.string(from: Date())
    }
    
    // MARK: - URL normalization helper
    private func normalizedBaseURLString() -> String {
        let raw = apiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)

        // strip trailing slash
        var s = raw.hasSuffix("/") ? String(raw.dropLast()) : raw

        // remove any accidental /api or /api/v1 suffix (case-insensitive)
        let lowers = s.lowercased()
        if lowers.hasSuffix("/api/v1") { s = String(s.dropLast(7)) } // remove "/api/v1"
        else if lowers.hasSuffix("/api") { s = String(s.dropLast(4)) } // remove "/api"

        return s // origin only, like "https://yourapp.vercel.app"
    }
    
    // MARK: - Idempotency helper
    private func contentHash(for path: String, payload: [String: Any]) -> String {
        // Create a deterministic hash based on endpoint + key payload fields
        var hashableContent = path
        
        // Include key fields that affect the response (exclude volatile fields like timestamps)
        if let text = payload["text"] as? String {
            hashableContent += text
        }
        if let context = payload["context"] as? String {
            hashableContent += context
        }
        if let toneOverride = payload["toneOverride"] as? String {
            hashableContent += toneOverride
        }
        
        return String(hashableContent.hash)
    }

    // MARK: Configuration
    private var apiBaseURL: String {
        return cachedAPIBaseURL
    }
    private var apiKey: String {
        return cachedAPIKey
    }
    private var isAPIConfigured: Bool {
        if Date() < authBackoffUntil { 
            print("🔴 API blocked due to auth backoff until \(authBackoffUntil)")
            return false 
        }
        let configured = !apiBaseURL.isEmpty && !apiKey.isEmpty
        print("🔧 API configured: \(configured) - URL: '\(apiBaseURL)', Key: '\(apiKey.prefix(10))...'")
        return configured
    }

    // MARK: Networking
    private lazy var session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.waitsForConnectivity = false
        cfg.allowsCellularAccess = true
        cfg.allowsConstrainedNetworkAccess = true
        cfg.allowsExpensiveNetworkAccess = true
        cfg.httpShouldUsePipelining = true
        cfg.httpMaximumConnectionsPerHost = 2
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.timeoutIntervalForRequest = 10.0  // Increased from 5.0 for cellular
        cfg.timeoutIntervalForResource = 30.0  // Increased from 15.0
        cfg.httpCookieAcceptPolicy = .never
        cfg.httpCookieStorage = nil
        cfg.httpAdditionalHeaders = [
            "Accept": "application/json",
            "Accept-Encoding": "gzip",
            "Cache-Control": "no-cache"
        ]
        return URLSession(configuration: cfg)
    }()
    private var inFlightTask: URLSessionDataTask?   // NEW: allow cancellation

    // MARK: - Queue / Debounce & Coalescing
    private let workQueue = DispatchQueue(label: "com.unsaid.coordinator", qos: .utility)
    private var pendingWorkItem: DispatchWorkItem?
    private let debounceInterval: TimeInterval = 0.2  // Increased to 200ms as requested
    private let pauseBasedInterval: TimeInterval = 0.25  // 250ms idle-based throttling
    private var lastKeyStrokeTime: Date = .distantPast
    private var currentTextFieldKey: String = "default"  // Key by active text field
    private var pendingRequests: [String: URLSessionDataTask] = [:] // Track per-field requests

    /// Helper to ensure all shared state mutations happen on workQueue only
    private func onQ(_ block: @escaping () -> Void) {
        if DispatchQueue.getSpecific(key: workQueueKey) != nil {
            // Already on workQueue
            block()
        } else {
            workQueue.async(execute: block)
        }
    }
    
    // Queue identification key for thread safety
    private let workQueueKey = DispatchSpecificKey<Bool>()
    
    private func setupWorkQueueIdentification() {
        workQueue.setSpecific(key: workQueueKey, value: true)
    }

    // MARK: - Network Monitoring
    private var networkMonitor: NWPathMonitor?
    private let networkQueue = DispatchQueue(label: "com.unsaid.network", qos: .utility)
    private(set) var isNetworkAvailable: Bool = true
    private var didStartMonitoring = false

    // MARK: - State
    private var currentText: String = ""
    private var lastAnalyzedText: String = ""
    private var lastAnalysisTime: Date = .distantPast
    private var consecutiveFailures: Int = 0
    private var currentToneStatus: String = "neutral"
    private var suggestions: [String] = []
    private var lastEscalationAt: Date = .distantPast
    private var suggestionSnapshot: String?
    private var enhancedAnalysisResults: [String: Any]?
    
    // MARK: - Snapshot-based UI updates
    private var lastNotifiedSuggestions: [String] = []
    private var lastNotifiedToneStatus: String = "neutral"
    private var lastNotificationTime: Date = .distantPast

    // MARK: - Request Mgmt / Backoff / Client Sequence
    private var latestRequestID = UUID()
    private var clientSequence: UInt64 = 0  // Monotonic counter for last-writer-wins
    private var pendingClientSeq: UInt64 = 0  // Track latest sequence in UI
    private var authBackoffUntil: Date = .distantPast
    private var netBackoffUntil: Date = .distantPast  // NEW: general backoff
    
    // MARK: - Idempotency Guards
    private var inFlightRequests: [String: URLSessionDataTask] = [:] // content hash -> task
    private var inFlightRequestHashes: Set<String> = [] // Track request hashes for deduplication
    private var requestCompletionTimes: [String: Date] = [:] // content hash -> completion time
    private let requestCacheTTL: TimeInterval = 5.0 // 5 second cache for identical requests

    // MARK: - Shared Defaults
    // private let sharedUserDefaults: UserDefaults = AppGroups.shared
    private let sharedUserDefaults: UserDefaults = UserDefaults.standard

    // MARK: - Personality Bridge
    // private let personalityBridge = PersonalityDataBridge.shared
    // NEW: persona cache
    private var cachedPersona: [String: Any] = [:]
    private var cachedPersonaAt: Date = .distantPast
    private let personaTTL: TimeInterval = 10 * 60

    // MARK: - Logging
    private let logger = Logger(subsystem: "com.example.unsaid.unsaid.UnsaidKeyboard", category: "ToneSuggestionCoordinator")
    private var logThrottle: [String: Date] = [:]
    private let logThrottleInterval: TimeInterval = 1.0
    
    // MARK: - Haptic Controller
    // Note: Temporarily commented out due to missing shared types
    // Will need to uncomment once the shared types compilation issues are resolved
    private let hapticController: Any? = nil // UnifiedHapticsController.shared
    private var isHapticSessionActive = false
    private var lastToneUpdateTime: Date = .distantPast
    private let toneUpdateThrottle: TimeInterval = 0.1 // 10 Hz max
    
    // MARK: - Health Debug
    private let netLog = OSLog(subsystem: Bundle.main.bundleIdentifier ?? "UnsaidKeyboard", category: "Network")
    
    // MARK: - Snapshot-based UI Updates Helper
    
    /// Only notify delegate if suggestions or tone status actually changed
    private func notifyDelegateIfChanged(suggestions: [String], toneStatus: String) {
        onQ { [weak self] in
            guard let self = self else { return }
            
            let now = Date()
            let timeSinceLastNotification = now.timeIntervalSince(self.lastNotificationTime)
            
            let suggestionsChanged = suggestions != self.lastNotifiedSuggestions
            let toneChanged = toneStatus != self.lastNotifiedToneStatus
            
            // Skip notification if nothing changed and it's been less than 500ms
            if !suggestionsChanged && !toneChanged && timeSinceLastNotification < 0.5 {
                return
            }
            
            // Update snapshots
            self.lastNotifiedSuggestions = suggestions
            self.lastNotifiedToneStatus = toneStatus
            self.lastNotificationTime = now
            
            // Notify on main queue only what changed
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                if suggestionsChanged {
                    self.delegate?.didUpdateSuggestions(suggestions)
                }
                if toneChanged {
                    self.delegate?.didUpdateToneStatus(toneStatus)
                }
            }
        }
    }

    // MARK: - Lightweight HTTP Headers Helper
    
    /// Set only essential headers to reduce HTTP overhead
    private func setEssentialHeaders(on request: inout URLRequest, clientSeq: UInt64) {
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(self.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("default-user", forHTTPHeaderField: "x-user-id") // getUserId() placeholder
        request.setValue("\(clientSeq)", forHTTPHeaderField: "x-client-seq")
        
        // Only add user email if available (avoid expensive lookups)
        // if let email = self.getUserEmail() {
        //     request.setValue(email, forHTTPHeaderField: "x-user-email")
        // }
    }
    
    private func stopNetworkMonitoring() {
        // Placeholder for network monitoring cleanup
    }
    
    private func updateHapticFeedback(for toneStatus: String) {
        // Placeholder for haptic feedback
    }
    
    private func personalityProfileForAPI() -> [String: Any]? {
        // Placeholder - return empty profile
        return [:]
    }
    
    private func resolvedAttachmentStyle() -> (style: String?, provisional: Bool, source: String) {
        // Placeholder - return default attachment style
        return ("secure", false, "default")
    }

    // MARK: - Missing Method Placeholders
    
    private func getAttachmentStyle() -> String {
        return "secure" // Default attachment style
    }
    
    private func getEmotionalState() -> String {
        return "neutral" // Default emotional state
    }
    
    private func getUserId() -> String {
        return "default-user"
    }
    
    private func getUserEmail() -> String? {
        return nil
    }
    
    private func throttledLog(_ message: String, category: String) {
        print("[\(category)] \(message)")
    }
    
    private func startNetworkMonitoringSafely() {
        // Placeholder for network monitoring
    }
    
    private func storeSuggestionAccepted(suggestion: String) {
        // Placeholder for suggestion storage
    }
    
    private func storeSuggestionGenerated(suggestion: String) {
        // Placeholder for suggestion storage
    }
    
    private func storeAPIResponseInSharedStorage(endpoint: String, request: [String: Any], response: [String: Any]) {
        // Placeholder for API response storage
    }

    // MARK: - API Config & Debug

    func dumpAPIConfig() {
        let base = Bundle.main.object(forInfoDictionaryKey: "UNSAID_API_BASE_URL") as? String ?? "<missing>"
        let key  = Bundle.main.object(forInfoDictionaryKey: "UNSAID_API_KEY") as? String ?? "<missing>"
        os_log("🔧 API Config - Base URL: %{public}@, Key prefix: %{public}@", log: netLog, type: .info, base, String(key.prefix(8)))
    }
    
    func debugPing() {
        dumpAPIConfig()

        // Don't call /health endpoint as requested - just log configuration
        let rawBase = (Bundle.main.object(forInfoDictionaryKey: "UNSAID_API_BASE_URL") as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedBase: String = rawBase.hasSuffix("/api/v1") ? String(rawBase.dropLast(7)) : rawBase
        
        os_log("🔧 API Base URL configured: %{public}@", log: self.netLog, type: .info, cleanedBase)
        os_log("🔧 Network available: %{public}@", log: self.netLog, type: .info, String(self.isNetworkAvailable))
        os_log("🔧 Current text length: %d", log: self.netLog, type: .info, self.currentText.count)
        
        // Only trigger analysis if there's real text (not just testing ping)
        let currentTextTrimmed = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !currentTextTrimmed.isEmpty {
            os_log("🔧 Triggering force analyze for current text", log: self.netLog, type: .info)
            forceImmediateAnalysis(currentTextTrimmed)
        } else {
            os_log("🔧 No current text - skipping force analyze to avoid test pollution", log: self.netLog, type: .info)
        }
    }
    
    // MARK: - Force Analyze (keep on tone button)
    func forceAnalyzeCurrentText() {
        let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throttledLog("force analyze: no text to analyze", category: "analysis")
            return
        }
        
        throttledLog("force analyze triggered", category: "analysis")
        forceImmediateAnalysis(text)
    }
    
    // MARK: - Debug Test Function for UI Updates
    func testToneAPIWithDebugText() {
        throttledLog("🧪 Testing tone API with debug text", category: "test")
        let testText = "I'm so frustrated with this situation"
        updateCurrentText(testText)
        
        var context: [String: Any] = [
            "text": testText,
            "context": "general",
            "meta": [
                "platform": "ios_keyboard",
                "timestamp": isoTimestamp(),
                "test_mode": true
            ]
        ]
        context.merge(personalityPayload()) { _, new in new }
        
        callToneAnalysisAPI(context: context) { [weak self] toneResult in
            guard let self = self else { return }
            self.throttledLog("🧪 Test API result: '\(toneResult ?? "nil")'", category: "test")
            
            if let tone = toneResult {
                DispatchQueue.main.async {
                    self.currentToneStatus = tone
                    self.delegate?.didUpdateToneStatus(tone)
                    self.throttledLog("🧪 Test UI tone set to \(tone)", category: "test")
                }
            }
        }
    }

    // MARK: - Init/Deinit
    init() {
        setupWorkQueueIdentification()
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.startNetworkMonitoringSafely()
        }
        
        // Start attachment learning window if needed
        // personalityBridge.markAttachmentLearningStartedIfNeeded(days: 7)
        
        #if DEBUG
        debugPrint("🧠 Personality Data Bridge Status:")
        debugPrint(" - Attachment Style: '\(getAttachmentStyle())'")
        // debugPrint(" - Communication Style: '\(personalityBridge.getCommunicationStyle())'")
        // debugPrint(" - Personality Type: '\(personalityBridge.getPersonalityType())'")
        debugPrint(" - Emotional State: '\(getEmotionalState())'")
        // debugPrint(" - Test Complete: \(personalityBridge.isPersonalityTestComplete())")
        // debugPrint(" - Data Freshness: \(personalityBridge.getDataFreshness()) hours")
        // debugPrint(" - New User: \(personalityBridge.isNewUser())")
        // debugPrint(" - Learning Days Remaining: \(personalityBridge.learningDaysRemaining())")
        
        // Health ping to verify API configuration - only if no real text to avoid overwriting tone
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            if self.currentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                self.debugPing()
            }
        }
        #endif
    }

    deinit {
        print("🗑️ ToneSuggestionCoordinator deinit - cleaning up resources")
        
        // Stop haptic session
        stopHapticSession()
        
        // Cancel any pending work
        pendingWorkItem?.cancel()
        inFlightTask?.cancel()
        
        // Stop network monitoring
        stopNetworkMonitoring()
        
        print("✅ ToneSuggestionCoordinator cleanup complete")
    }

    // MARK: - Public API
    func analyzeFinalSentence(_ sentence: String) { handleTextChange(sentence) }
    
    /// Start haptic session (call once when user begins typing)
    func startHapticSession() {
        guard !isHapticSessionActive else { return }
        isHapticSessionActive = true
        // hapticController.startHapticSession() // TODO: Uncomment when types are resolved
    }
    
    /// Stop haptic session (call once when user stops typing or app backgrounds)
    func stopHapticSession() {
        guard isHapticSessionActive else { return }
        isHapticSessionActive = false
        // hapticController.stopHapticSession() // TODO: Uncomment when types are resolved
    }
    
    /// Get haptic metrics for debugging
    func getHapticMetrics() -> (starts: Int, stops: Int, updates: Int, latencyMs: Double) {
        // TODO: Uncomment when types are resolved
        // if let controller = hapticController as? UnifiedHapticsController {
        //     return controller.getMetrics()
        // } else {
            // Fallback when haptic controller is not available
            return (starts: 0, stops: 0, updates: 0, latencyMs: 0.0)
        // }
    }

    func handleTextChange(_ text: String) {
        // Single source of truth: Only textDidChange triggers tone calls
        updateCurrentText(text)
        lastKeyStrokeTime = Date()
        
        // Guard against empty/unchanged text (don't fire network calls)
        guard shouldEnqueueAnalysis() else {
            throttledLog("🚫 Skipping analysis - shouldEnqueueAnalysis returned false for text: '\(text.prefix(50))'", category: "analysis")
            return
        }
        
        // Cancel in-flight requests for this text field when new keystroke arrives
        cancelInFlightRequestsForCurrentField()
        
        // Wrap network trigger in trailing debounce (200ms) keyed by active text field
        print("📝 Enqueueing tone analysis for: '\(text.prefix(50))...'")
        pendingWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in 
            // Switch to pause-based throttling: check if user paused typing for 250ms
            guard let self = self else { return }
            let timeSinceLastKeystroke = Date().timeIntervalSince(self.lastKeyStrokeTime)
            if timeSinceLastKeystroke >= self.pauseBasedInterval {
                self.performTextUpdate()
            } else {
                // Reschedule if user is still actively typing
                let remainingDelay = self.pauseBasedInterval - timeSinceLastKeystroke
                self.workQueue.asyncAfter(deadline: .now() + remainingDelay) {
                    self.performTextUpdate()
                }
            }
        }
        pendingWorkItem = work
        workQueue.asyncAfter(deadline: .now() + debounceInterval, execute: work)
        throttledLog("scheduled analysis in \(debounceInterval)s (pause-based)", category: "analysis")
    }

    // Force immediate text analysis (useful when switching from iOS keyboard)
    func forceImmediateAnalysis(_ text: String) {
        updateCurrentText(text)
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            pendingWorkItem?.cancel()
            cancelInFlightRequestsForCurrentField()
            let work = DispatchWorkItem { [weak self] in self?.performTextUpdate() }
            pendingWorkItem = work
            workQueue.async(execute: work)
            throttledLog("forced immediate analysis", category: "analysis")
        }
    }
    
    // MARK: - Request Cancellation Management
    private func cancelInFlightRequestsForCurrentField() {
        // Cancel in-flight requests when new keystroke arrives
        if let task = pendingRequests[currentTextFieldKey] {
            task.cancel()
            pendingRequests.removeValue(forKey: currentTextFieldKey)
            throttledLog("cancelled in-flight request for field: \(currentTextFieldKey)", category: "api")
        }
    }

    func requestSuggestions() {
        pendingWorkItem?.cancel()
        let snapshot = currentText
        suggestionSnapshot = snapshot
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard !snapshot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                DispatchQueue.main.async {
                    self.delegate?.didUpdateSuggestions([])
                    self.delegate?.didUpdateSecureFixButtonState()
                }
                return
            }
            self.generatePerfectSuggestion(from: snapshot)
        }
        pendingWorkItem = work
        workQueue.async(execute: work)
    }

    func requestBestSuggestion(forTone tone: String) {
        pendingWorkItem?.cancel()
        let snapshot = currentText
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard !snapshot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                DispatchQueue.main.async { self.delegate?.didUpdateSuggestions([]) }
                return
            }
            self.generateBestSuggestionForTone(tone, from: snapshot)
        }
        pendingWorkItem = work
        workQueue.async(execute: work)
    }

    func resetState() {
        onQ {
            self.pendingWorkItem?.cancel()
            self.inFlightTask?.cancel()
            self.currentText = ""
            self.lastAnalyzedText = ""
            self.currentToneStatus = "neutral"
            self.suggestions = []
            self.consecutiveFailures = 0
            self.lastEscalationAt = .distantPast
            self.suggestionSnapshot = nil
            DispatchQueue.main.async {
                self.delegate?.didUpdateToneStatus("neutral")
                self.delegate?.didUpdateSuggestions([])
            }
            self.throttledLog("state reset", category: "coordinator")
        }
    }

    func getCurrentToneStatus() -> String { currentToneStatus }
    func recordUserMessageSent(_ text: String) {}
    func recordOtherMessage(_ text: String, at timestampMs: Int64? = nil) {}

    // MARK: - Text + History
    private func normalized(_ s: String) -> String {
        s.lowercased().components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    }

    private func updateCurrentText(_ text: String) {
        let maxLen = 1000
        let trimmed = text.count > maxLen ? String(text.suffix(maxLen)) : text
        guard trimmed != currentText else { return }
        onQ {
            self.currentText = trimmed
        }
    }

    private func loadSharedConversationHistory() -> [[String: Any]] {
        guard let d = sharedUserDefaults.data(forKey: "conversation_history_buffer"),
              let items = try? JSONDecoder().decode([SharedConvItem].self, from: d) else { return [] }
        return items.map { ["sender": $0.sender, "text": $0.text, "timestamp": $0.timestamp] }
    }

    private func exportConversationHistoryForAPI(withCurrentText overrideText: String? = nil) -> [[String: Any]] {
        var history = loadSharedConversationHistory()
        let now = Date().timeIntervalSince1970
        let current = (overrideText ?? currentText).trimmingCharacters(in: .whitespacesAndNewlines)
        if !current.isEmpty {
            history.append(["sender": "user", "text": current, "timestamp": now])
        }
        if history.count > 20 { history = Array(history.suffix(20)) }
        return history
    }

    // MARK: - Ergonomics & Convenience Methods
    
    /// Convenience method to quickly check if suggestions are available
    var hasSuggestions: Bool {
        return !suggestions.isEmpty
    }
    
    /// Convenience method to get current tone status safely
    var safeToneStatus: String {
        return currentToneStatus.isEmpty ? "neutral" : currentToneStatus
    }
    
    /// Convenience method to reset coordinator to clean state
    func resetToCleanState() {
        onQ {
            self.currentText = ""
            self.lastAnalyzedText = ""
            self.currentToneStatus = "neutral"
            self.suggestions = []
            self.lastNotifiedSuggestions = []
            self.lastNotifiedToneStatus = "neutral"
            self.lastNotificationTime = .distantPast
            self.inFlightRequestHashes.removeAll()
            
            DispatchQueue.main.async {
                self.delegate?.didUpdateSuggestions([])
                self.delegate?.didUpdateToneStatus("neutral")
                self.delegate?.didUpdateSecureFixButtonState()
            }
        }
    }
    
    /// Convenience method to perform suggestion acceptance with proper cleanup
    func acceptSuggestion(_ suggestion: String, completion: (() -> Void)? = nil) {
        onQ {
            // Store acceptance for learning
            self.storeSuggestionAccepted(suggestion: suggestion)
            
            // Clear suggestions since one was accepted
            self.suggestions = []
            
            // Notify delegate
            DispatchQueue.main.async {
                self.delegate?.didUpdateSuggestions([])
                self.delegate?.didUpdateSecureFixButtonState()
                completion?()
            }
        }
    }
    
    /// Enhanced error propagation with structured error types
    enum CoordinatorError: LocalizedError {
        case networkUnavailable
        case apiConfigurationMissing
        case invalidResponse
        case requestThrottled
        
        var errorDescription: String? {
            switch self {
            case .networkUnavailable:
                return "Network connection unavailable"
            case .apiConfigurationMissing:
                return "API configuration is missing"
            case .invalidResponse:
                return "Invalid response from server"
            case .requestThrottled:
                return "Request throttled due to rate limiting"
            }
        }
    }

    // MARK: - Defensive JSON Parsing Helpers
    
    /// Safely extract string values with fallback and validation
    private func safeString(from dict: [String: Any], keys: [String], fallback: String = "") -> String {
        for key in keys {
            if let value = dict[key] as? String, !value.isEmpty {
                return value
            }
        }
        return fallback
    }
    
    /// Safely extract double values with validation
    private func safeDouble(from dict: [String: Any], keys: [String], fallback: Double = 0.0) -> Double {
        for key in keys {
            if let value = dict[key] as? Double, value.isFinite {
                return value
            }
            if let value = dict[key] as? Int {
                return Double(value)
            }
        }
        return fallback
    }
    
    /// Safely extract array of dictionaries with validation
    private func safeArrayOfDicts(from dict: [String: Any], keys: [String]) -> [[String: Any]] {
        for key in keys {
            if let array = dict[key] as? [[String: Any]] {
                return array
            }
        }
        return []
    }

    // MARK: - Enhanced Tone Change Throttling Helper
    
    /// Check if text changes are semantically significant enough to warrant re-analysis
    private func isSemanticallySimilar(_ text1: String, _ text2: String) -> Bool {
        let t1 = text1.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let t2 = text2.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Exact match
        if t1 == t2 { return true }
        
        // Just punctuation/capitalization changes
        let t1Clean = t1.replacingOccurrences(of: "[^a-z0-9\\s]", with: "", options: .regularExpression)
        let t2Clean = t2.replacingOccurrences(of: "[^a-z0-9\\s]", with: "", options: .regularExpression)
        if t1Clean == t2Clean { return true }
        
        // For short texts (< 25 chars), be more aggressive about detecting changes
        // This catches critical tone flips like "ok" → "ok!!" or "fine" → "not fine"
        if max(t1.count, t2.count) < 25 {
            return false  // Always analyze short text changes
        }
        
        // For longer texts, use raised similarity threshold to catch more meaningful changes
        let words1 = t1.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        let words2 = t2.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        let maxWords = max(words1.count, words2.count)
        let commonWords = Set(words1).intersection(Set(words2)).count
        let similarity = maxWords > 0 ? Double(commonWords) / Double(maxWords) : 1.0
        
        // Raised from 0.8 to 0.92 to catch more tone-changing edits
        return similarity > 0.92
    }

    private func shouldEnqueueAnalysis() -> Bool {
        let now = Date()
        let trimmed = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Guard: empty text doesn't fire network calls
        if trimmed.isEmpty && lastAnalyzedText.isEmpty { return false }
        
        if trimmed.count < 2, !trimmed.isEmpty { return false }
        if trimmed.isEmpty, !lastAnalyzedText.isEmpty { return true }
        if now.timeIntervalSince(lastAnalysisTime) < 0.1 { return false }

        // NEW: skip micro deltas within 500ms (user still mid-token)
        if now.timeIntervalSince(lastAnalysisTime) < 0.5,
           abs(trimmed.count - lastAnalyzedText.count) <= 1 {
            return false
        }
        
        // Enhanced: Skip semantically similar text to prevent redundant analysis
        if isSemanticallySimilar(trimmed, lastAnalyzedText) {
            return false
        }
        
        return normalized(trimmed) != normalized(lastAnalyzedText)
    }

    // MARK: - Tone update
    private func performTextUpdate() {
        let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            onQ {
                self.lastAnalyzedText = self.currentText
                self.lastAnalysisTime = Date()
                self.suggestions.removeAll()
                self.currentToneStatus = "neutral"
                DispatchQueue.main.async {
                    self.delegate?.didUpdateSuggestions([])
                    self.delegate?.didUpdateToneStatus("neutral")
                }
            }
            return
        }
        if text.count > 1000 { currentText = String(text.suffix(1000)) }

        var context: [String: Any] = [
            "text": currentText,
            "context": "general",
            "meta": [
                "source": "keyboard",
                "analysis_type": "realtime",
                "timestamp": isoTimestamp()
            ]
        ]
        context.merge(personalityPayload()) { _, new in new }

        callToneAnalysisAPI(context: context) { [weak self] toneResult in
            guard let self else { return }
            self.lastAnalysisTime = Date()
            let prevAnalyzed = self.lastAnalyzedText
            self.lastAnalyzedText = self.currentText
            self.consecutiveFailures = 0

            if let tone = toneResult {
                self.throttledLog("🎯 API returned tone: '\(tone)', current: '\(self.currentToneStatus)'", category: "tone_debug")
                DispatchQueue.main.async {
                    if self.shouldUpdateToneStatus(from: self.currentToneStatus, to: tone) {
                        self.throttledLog("🎯 Updating tone status from '\(self.currentToneStatus)' to '\(tone)'", category: "tone_debug")
                        self.currentToneStatus = tone
                        self.delegate?.didUpdateToneStatus(tone)  // Pass string directly
                        
                        // KEY DEBUG LINE - this is the canary that shows UI update is called
                        self.throttledLog("UI tone set to \(tone) | raw=\(tone) seq=-1", category: "tone_debug")
                        
                        // Update haptic feedback (throttled to 10 Hz)
                        self.updateHapticFeedback(for: tone)
                    } else {
                        self.throttledLog("🎯 Skipped tone update - shouldUpdateToneStatus returned false", category: "tone_debug")
                    }
                }
            } else {
                self.throttledLog("🎯 API returned nil tone result", category: "tone_debug")
            }

            // NEW: only observe when edit change is meaningful (>= 3 chars)
            if abs(self.lastAnalyzedText.count - prevAnalyzed.count) >= 3 {
                self.updateCommunicatorProfile(with: self.currentText)
            }
        }
    }

    // MARK: - Personality payload (cached)
    private func personalityPayload() -> [String: Any] {
        let now = Date()
        if now.timeIntervalSince(cachedPersonaAt) < personaTTL, !cachedPersona.isEmpty {
            return cachedPersona
        }
        
        // Use enhanced personality profile with learning metadata
        let profile = personalityProfileForAPI() ?? [:]
        let resolved = resolvedAttachmentStyle()
        
        // Build meta dictionary step by step to help compiler
        var metaDict: [String: Any] = [:]
        metaDict["emotional_state"] = profile["emotionalState"] ?? "neutral"
        metaDict["communication_style"] = profile["communicationStyle"] ?? "direct"
        metaDict["emotional_bucket"] = profile["emotionalBucket"] ?? "moderate"
        metaDict["personality_type"] = profile["personalityType"] ?? "unknown"
        // Learning metadata for backend processing
        metaDict["new_user"] = profile["newUser"] ?? false
        metaDict["attachment_provisional"] = profile["attachmentProvisional"] ?? false
        metaDict["learning_days_remaining"] = profile["learningDaysRemaining"] ?? 0
        metaDict["attachment_source"] = resolved.source
        
        // Build main payload dictionary
        var payload: [String: Any] = [
            "attachmentStyle": resolved.style ?? "secure",
            "features": ["rewrite", "advice", "evidence"],
            "meta": metaDict,
            "context": "general",
            "user_profile": profile
        ]
        
        // Add tone override if not neutral
        if currentToneStatus != "neutral" {
            payload["toneOverride"] = currentToneStatus
        }
        
        let finalPayload = payload.compactMapValues { $0 }
        
        cachedPersona = finalPayload
        cachedPersonaAt = now
        return finalPayload
    }

    // MARK: - Communicator Learning
    private func updateCommunicatorProfile(with text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count >= 10 else { return }

        var payload: [String: Any] = [
            "text": trimmed,
            "meta": [
                "source": "keyboard",
                "timestamp": isoTimestamp(),
                "context": "realtime_typing"
            ],
            "userId": getUserId()
        ]
        if let email = getUserEmail() { payload["userEmail"] = email }

        callEndpoint(path: "api/v1/communicator/observe", payload: payload) { [weak self] response in
            guard let self = self else { return }
            if let _ = response {
                self.throttledLog("communicator profile updated", category: "learning")
            }
        }
    }

    private func updateCommunicatorProfileWithSuggestion(_ suggestion: String, accepted: Bool) {
        guard accepted else { return }
        let trimmed = suggestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        var payload: [String: Any] = [
            "text": trimmed,
            "meta": [
                "source": "keyboard_suggestion",
                "timestamp": isoTimestamp(),
                "context": "accepted_suggestion",
                "suggestion_accepted": true,
                "original_text": currentText
            ],
            "userId": getUserId()
        ]
        if let email = getUserEmail() { payload["userEmail"] = email }

        callEndpoint(path: "api/v1/communicator/observe", payload: payload) { [weak self] _ in
            self?.throttledLog("communicator learned from accepted suggestion", category: "learning")
        }
    }

    // MARK: - Suggestion Generation (returns ONE advice)
    private func generatePerfectSuggestion(from snapshot: String = "") {
        var textToAnalyze = snapshot.isEmpty ? currentText : snapshot
        if textToAnalyze.count > 1000 { textToAnalyze = String(textToAnalyze.suffix(1000)) }

        var context: [String: Any] = [
            "text": textToAnalyze,
            "userId": getUserId(),
            "userEmail": getUserEmail() ?? NSNull(),
            "features": ["advice", "evidence"], // Only advice, not rewrite
            "meta": [
                "source": "keyboard_manual",
                "request_type": "suggestion",
                "context": "general", // Server expects meta.context for working context
                "timestamp": isoTimestamp()
            ]
        ]
        // Let personality payload override keys like context, features (personality-driven context wins)
        context.merge(personalityPayload()) { _, new in new }

        callSuggestionsAPI(context: context, usingSnapshot: textToAnalyze) { [weak self] suggestion in
            guard let self else { return }
            DispatchQueue.main.async {
                if let s = suggestion, !s.isEmpty {
                    self.suggestions = [s]        // ONE item only
                    self.delegate?.didUpdateSuggestions(self.suggestions)
                    self.delegate?.didUpdateSecureFixButtonState()
                    self.storeSuggestionGenerated(suggestion: s)
                } else if let fallback = self.fallbackSuggestion(for: textToAnalyze), !fallback.isEmpty {
                    self.suggestions = [fallback]
                    self.delegate?.didUpdateSuggestions(self.suggestions)
                    self.delegate?.didUpdateSecureFixButtonState()
                } else {
                    self.suggestions = []
                    self.delegate?.didUpdateSuggestions([])
                    self.delegate?.didUpdateSecureFixButtonState()
                }
            }
        }
    }

    private func generateBestSuggestionForTone(_ tone: String, from snapshot: String = "") {
        var textToAnalyze = snapshot.isEmpty ? currentText : snapshot
        if textToAnalyze.count > 1000 { textToAnalyze = String(textToAnalyze.suffix(1000)) }

        var context: [String: Any] = [
            "text": textToAnalyze,
            "userId": getUserId(),
            "userEmail": getUserEmail() ?? NSNull(),
            "toneOverride": tone,
            "features": ["advice"], // Only advice for tone-specific requests
            "meta": [
                "source": "keyboard_tone_specific",
                "requested_tone": tone,
                "context": "general", // Server expects meta.context for working context
                "timestamp": isoTimestamp(),
                "emotionalIndicators": getEmotionalIndicatorsForTone(tone),
                "communicationStyle": getCommunicationStyleForTone(tone)
            ]
        ]
        // Let personality payload override keys like context, features (personality-driven context wins)
        context.merge(personalityPayload()) { _, new in new }

        callSuggestionsAPI(context: context, usingSnapshot: textToAnalyze) { [weak self] suggestion in
            guard let self else { return }
            DispatchQueue.main.async {
                if let s = suggestion, !s.isEmpty {
                    self.suggestions = [s]
                    self.delegate?.didUpdateSuggestions([s])
                    self.delegate?.didUpdateSecureFixButtonState() // Parity with generatePerfectSuggestion
                    self.storeSuggestionGenerated(suggestion: s)
                } else if let fallback = self.fallbackSuggestionForTone(tone, text: textToAnalyze) {
                    self.suggestions = [fallback]
                    self.delegate?.didUpdateSuggestions([fallback])
                    self.delegate?.didUpdateSecureFixButtonState() // Parity with generatePerfectSuggestion
                } else {
                    self.suggestions = []
                    self.delegate?.didUpdateSuggestions([])
                    self.delegate?.didUpdateSecureFixButtonState() // Parity with generatePerfectSuggestion
                }
            }
        }
    }

    // MARK: - Tone/Suggestion API plumbing
    private func callSuggestionsAPI(context: [String: Any], usingSnapshot snapshot: String? = nil, completion: @escaping (String?) -> Void) {
        guard isNetworkAvailable, isAPIConfigured, Date() >= netBackoffUntil else { completion(nil); return }

        let requestID = UUID()
        latestRequestID = requestID

        var payload = context
        payload["requestId"] = requestID.uuidString
        payload["userId"] = getUserId()
        payload["userEmail"] = getUserEmail()
        payload.merge(personalityPayload()) { _, new in new }
        payload["conversationHistory"] = exportConversationHistoryForAPI(withCurrentText: snapshot)

        callEndpoint(path: "api/v1/suggestions", payload: payload) { [weak self] data in
            guard let self else { completion(nil); return }
            guard requestID == self.latestRequestID else { completion(nil); return }

            let d = data ?? [:]
            if !d.isEmpty {
                self.enhancedAnalysisResults = d
                self.storeAPIResponseInSharedStorage(endpoint: "suggestions", request: payload, response: d)
            }

            // Update tone with defensive parsing - NOW with UI tone bucketing like tone endpoint
            let uiTone = self.uiToneString(from: d)
            
            if uiTone != "neutral" {
                DispatchQueue.main.async {
                    if self.shouldUpdateToneStatus(from: self.currentToneStatus, to: uiTone) {
                        self.currentToneStatus = uiTone
                        self.delegate?.didUpdateToneStatus(uiTone)  // Only send clamped UI tones
                        
                        // Extract confidence with defensive parsing
                        let confidence = self.safeDouble(from: d, keys: ["confidence"], fallback: 0.0)
                        if confidence > 0.0 {
                            self.storeToneAnalysisResult(data: d, status: uiTone, confidence: confidence)
                        }
                    }
                }
            }

            // Extract suggestion with defensive parsing
            let suggestion = extractSuggestionSafely(from: d)
            completion(suggestion)
        }
    }
    
    /// Safely extract suggestion from API response with multiple fallbacks
    private func extractSuggestionSafely(from dict: [String: Any]) -> String? {
        // Try simple string fields first
        let simpleSuggestion = safeString(from: dict, keys: ["rewrite", "general_suggestion", "suggestion", "data"])
        if !simpleSuggestion.isEmpty {
            return simpleSuggestion
        }
        
        // Try nested suggestion arrays
        let suggestionArrays = safeArrayOfDicts(from: dict, keys: ["suggestions"])
        if let firstSuggestion = suggestionArrays.first {
            let text = safeString(from: firstSuggestion, keys: ["text"])
            if !text.isEmpty { return text }
        }
        
        // Try quickFixes array
        if let quickFixes = dict["quickFixes"] as? [String], let first = quickFixes.first, !first.isEmpty {
            return first
        }
        
        // Try extras nested suggestions
        if let extras = dict["extras"] as? [String: Any] {
            let nestedSuggestions = safeArrayOfDicts(from: extras, keys: ["suggestions"])
            if let firstNested = nestedSuggestions.first {
                let text = safeString(from: firstNested, keys: ["text"])
                if !text.isEmpty { return text }
            }
        }
        
        return nil
    }

    // MARK: - Tone Parsing Helpers (Unified across all endpoints)
    
    // Copilot: 'neutral' is a valid pill state. Do not coerce it to 'clear'.
    /// Safety normalizer (prevents "angry" from blanking the UI)
    private func normalizeToneLabel(_ s: String) -> String {
        switch s.lowercased() {
        case "alert", "caution", "clear", "neutral": return s
        case "angry", "hostile", "toxic": return "alert"
        case "frustrated", "anxious", "sad": return "caution"
        default: return "clear"
        }
    }
    
    // Always drive the pill from ui_tone when provided.
    // Fall back to ui_distribution (or legacy 'buckets') if ui_tone missing.
    // 'angry' and similar raw labels must never directly set the pill.
    /// Convert server response to clamped UI tone string (alert|caution|clear|neutral only)
    private func uiToneString(from response: [String: Any]) -> String {
        // FIRST: Check for direct ui_tone field (this is what the API returns!)
        let directUITone = safeString(from: response, keys: ["ui_tone", "uiTone"], fallback: "")
        if !directUITone.isEmpty {
            let normalized = normalizeToneLabel(directUITone)
            throttledLog("🎯 Found direct ui_tone: '\(directUITone)' -> normalized: '\(normalized)'", category: "tone_debug")
            return normalized
        }
        
        // SECOND: Try explicit ui_distribution buckets (including neutral)
        if let buckets = response["ui_distribution"] as? [String: Double] {
            let scored: [(String, Double)] = [
                ("alert",   buckets["alert"]   ?? 0),
                ("caution", buckets["caution"] ?? 0),
                ("clear",   buckets["clear"]   ?? 0),
                ("neutral", buckets["neutral"] ?? 0)
            ]
            if let maxPair = scored.max(by: { $0.1 < $1.1 }), maxPair.1 > 0.1 {
                throttledLog("🎯 Using ui_distribution bucket: '\(maxPair.0)' with score: \(maxPair.1)", category: "tone_debug")
                return maxPair.0
            }
        }
        
        // THIRD: Fallback to legacy buckets field
        if let buckets = response["buckets"] as? [String: Double] {
            let scored: [(String, Double)] = [
                ("alert",   buckets["alert"]   ?? 0),
                ("caution", buckets["caution"] ?? 0),
                ("clear",   buckets["clear"]   ?? 0),
                ("neutral", buckets["neutral"] ?? 0)
            ]
            if let maxPair = scored.max(by: { $0.1 < $1.1 }), maxPair.1 > 0.1 {
                throttledLog("🎯 Using legacy buckets: '\(maxPair.0)' with score: \(maxPair.1)", category: "tone_debug")
                return maxPair.0
            }
        }

        // LAST: Fallback mapping from raw tone analysis
        var raw = ""
        // Try nested analysis object first
        if let analysis = response["analysis"] as? [String: Any] {
            raw = safeString(from: analysis, keys: ["primary_tone", "primaryTone"], fallback: "")
        }
        // Fallback to top-level keys
        if raw.isEmpty {
            raw = safeString(from: response, keys: ["primary_tone", "classification", "tone"], fallback: "")
        }
        raw = raw.lowercased()
        let intense = safeDouble(from: response, keys: ["intensity"], fallback: 0.0) >= 0.55
        throttledLog("🎯 Fallback mapping from raw tone: '\(raw)' intense: \(intense)", category: "tone_debug")
        
        // Check for targeted profanity flag
        var targeted = false
        if let flags = response["flags"] as? [String: Any] {
            targeted = flags["targetedProfanity"] as? Bool ?? false
        }
        if let profanity = response["profanity"] as? [String: Any] {
            targeted = targeted || (profanity["hasTargetedSecondPerson"] as? Bool ?? false)
        }

        switch raw {
        case "angry":
            return (targeted || intense) ? "alert" : "caution"
        case "frustrated", "anxious", "sad", "negative", "tense", "passive_aggressive":
            return "caution"
        case "happy", "positive", "calm", "confident", "supportive":
            return "clear"
        default:
            return "neutral"
        }
    }
    
    /// Map server variants into the 4 UI tone buckets with smart classification fallback
    /// @deprecated Use uiToneString instead for cleaner clamping
    private func parseUITone(from response: [String: Any]) -> String {
        // First try direct UI tone field
        let rawUITone = safeString(from: response, keys: [
            "ui_tone","uiTone","tone_status","toneStatus","tone","primaryTone"
        ], fallback: "")
        
        // Check if it's already a valid UI bucket
        let normalized = rawUITone.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        switch normalized {
        case "alert": return "alert"
        case "caution": return "caution"  
        case "clear": return "clear"
        case "neutral": return "neutral"
        case "warning", "warn": return "caution"
        case "danger", "negative", "error", "red": return "alert"
        case "ok", "positive", "green", "safe", "secure", "good": return "clear"
        default: break
        }
        
        // Fallback: use buckets if available
        if let buckets = response["buckets"] as? [String: Double] {
            let pairs: [(String, Double)] = [
                ("alert",   buckets["alert"] ?? 0),
                ("caution", buckets["caution"] ?? 0),
                ("clear",   buckets["clear"] ?? 0),
                ("neutral", buckets["neutral"] ?? 0)
            ]
            if let maxPair = pairs.max(by: { $0.1 < $1.1 }), maxPair.1 > 0.1 {
                return maxPair.0
            }
        }
        
        // Final fallback: map raw classification with intensity/flags
        let rawClassification = safeString(from: response, keys: ["classification"], fallback: "").lowercased()
        let intensity = safeDouble(from: response, keys: ["intensity"], fallback: 0.0)
        let intense = intensity >= 0.55
        
        // Check for targeted profanity flag
        var targeted = false
        if let flags = response["flags"] as? [String: Any] {
            targeted = flags["targetedProfanity"] as? Bool ?? false
        }
        
        switch rawClassification {
        case "angry": 
            return (targeted || intense) ? "alert" : "caution"
        case "frustrated", "anxious", "sad", "negative", "tense", "passive_aggressive":
            return "caution"
        case "happy", "positive", "calm", "confident", "supportive":
            return "clear"
        default:
            return "neutral"
        }
    }

    private func callToneAnalysisAPI(context: [String: Any], completion: @escaping (String?) -> Void) {
        guard isNetworkAvailable, isAPIConfigured, Date() >= netBackoffUntil else { 
            completion("neutral")
            return 
        }

        let requestID = UUID()
        latestRequestID = requestID

        var payload = context
        payload["requestId"] = requestID.uuidString
        payload["userId"] = getUserId()
        payload["userEmail"] = getUserEmail()

        callEndpoint(path: "api/v1/tone", payload: payload) { [weak self] data in
            guard let self else { 
                completion("neutral")  // Safe fallback
                return 
            }
            guard requestID == self.latestRequestID else { 
                completion("neutral")  // Safe fallback
                return 
            }

            let d = data ?? [:]
            self.throttledLog("🎯 Tone API response: \(String(describing: d).prefix(200))", category: "tone_debug")

            // Check client sequence for last-writer-wins
            let responseClientSeq = d["client_seq"] as? Int ?? -1
            self.throttledLog("🎯 Response client_seq: \(responseClientSeq), current coordinator seq: \(self.clientSequence)", category: "tone_debug")

            // Use new clamped tone string function - only returns alert|caution|clear|neutral
            let uiTone = self.uiToneString(from: d)

            #if DEBUG
            // Guardrail: never leak raw labels to UI
            assert(["alert", "caution", "clear", "neutral"].contains(uiTone))
            #endif

            // Get raw analysis for debugging
            var rawTone = "unknown"
            if let analysis = d["analysis"] as? [String: Any] {
                rawTone = self.safeString(from: analysis, keys: ["primary_tone", "primaryTone"], fallback: "unknown")
            }
            if rawTone == "unknown" {
                rawTone = self.safeString(from: d, keys: ["primary_tone", "tone"], fallback: "unknown")
            }
            
            self.throttledLog("🎯 Extracted UI tone: '\(uiTone)' | raw=\(rawTone) seq=\(responseClientSeq)", category: "tone_debug")
            completion(uiTone)
        }
    }

    // MARK: - Core networking (robust endpoint + headers + decoding + metrics + last-writer-wins)
    private func callEndpoint(path: String, payload: [String: Any], completion: @escaping ([String: Any]?) -> Void) {
        guard isAPIConfigured else { 
            throttledLog("API not configured; skipping \(path)", category: "api")
            completion(nil)
            return 
        }
        
        // 🚀 Network Gate: Short-circuit doomed requests immediately
        guard isNetworkAvailable else {
            throttledLog("NetworkGate: Network unavailable; skipping \(path)", category: "api")
            completion(nil)
            return
        }
        
        if Date() < netBackoffUntil { 
            throttledLog("network backoff active; skipping \(path)", category: "api")
            completion(nil)
            return 
        }
        
        // 🛡️ Idempotency Guards: Check for duplicate/recent requests
        let requestHash = contentHash(for: path, payload: payload)
        let now = Date()
        
        // Clean up old completion times
        onQ {
            let cutoff = now.addingTimeInterval(-self.requestCacheTTL)
            self.requestCompletionTimes = self.requestCompletionTimes.filter { $0.value > cutoff }
        }
        
        // Check if identical request completed recently
        if let lastCompletion = requestCompletionTimes[requestHash],
           now.timeIntervalSince(lastCompletion) < requestCacheTTL {
            throttledLog("Skipping duplicate request within \(requestCacheTTL)s cache window", category: "api")
            completion(nil)
            return
        }
        
        // Check if identical request is already in flight
        if let existingTask = inFlightRequests[requestHash], existingTask.state == .running {
            throttledLog("Skipping duplicate in-flight request for same content", category: "api")
            completion(nil)
            return
        }

        // Foolproof path normalization
        let normalized = path
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .replacingOccurrences(of: "//", with: "/")
        
        // Allow tone, suggestions, and communicator/observe endpoints
        let allowed = Set([
            "api/v1/tone",
            "api/v1/suggestions",
            "api/v1/communicator/observe"
        ])
        guard allowed.contains(normalized) else {
            throttledLog("invalid endpoint \(normalized); expected one of \(allowed)", category: "api")
            completion(nil)
            return
        }
        
        // Robust URL building with validation and fallback behavior
        let origin = normalizedBaseURLString()
        
        // Validate base URL format
        guard !origin.isEmpty, origin.contains("://") else {
            throttledLog("invalid base URL format: '\(origin)'", category: "api")
            completion(nil)
            return
        }
        
        // Simple, robust URL construction: origin + "/" + normalized
        guard let url = URL(string: origin + "/" + normalized) else {
            throttledLog("failed to construct URL from origin: '\(origin)', path: '\(normalized)'", category: "api")
            completion(nil)
            return
        }
        
        // Additional validation: ensure URL is well-formed
        guard url.scheme == "http" || url.scheme == "https" else {
            throttledLog("unsupported URL scheme: '\(url.scheme ?? "nil")'", category: "api")
            completion(nil)
            return
        }

        workQueue.async { [weak self] in
            guard let self else { completion(nil); return }
            
            // Increment client sequence for last-writer-wins
            let currentClientSeq = self.clientSequence
            self.clientSequence += 1
            
            // Metrics: Start timing
            let startTime = Date()
            let inputLength = (payload["text"] as? String)?.count ?? 0
            
            var req = URLRequest(url: url, timeoutInterval: 10.0)
            req.httpMethod = "POST"
            
            // Set essential headers only (lighter HTTP overhead)
            setEssentialHeaders(on: &req, clientSeq: currentClientSeq)

            // Enhanced payload with client sequence
            var enhancedPayload = payload
            enhancedPayload["client_seq"] = currentClientSeq
            enhancedPayload["input_length"] = inputLength
            enhancedPayload["timestamp"] = self.isoTimestamp()

            do {
                req.httpBody = try JSONSerialization.data(withJSONObject: enhancedPayload, options: [])
            } catch {
                let latencyMs = Date().timeIntervalSince(startTime) * 1000
                self.throttledLog("payload serialization failed: \(error.localizedDescription)", category: "api")
                self.logMetrics(clientSeq: currentClientSeq, inputLength: inputLength, latencyMs: latencyMs, error: "serialization_failed")
                DispatchQueue.main.async { completion(nil) }
                return
            }

            DispatchQueue.main.async {
                // Cancel in-flight requests for this text field when new request arrives
                self.cancelInFlightRequestsForCurrentField()
                
                let task = self.session.dataTask(with: req) { data, response, error in
                    let latencyMs = Date().timeIntervalSince(startTime) * 1000
                    
                    // 🛡️ Idempotency: Clean up tracking on completion
                    self.onQ {
                        self.inFlightRequests.removeValue(forKey: requestHash)
                        self.requestCompletionTimes[requestHash] = Date()
                    }
                    
                    if let error = error as NSError? {
                        if error.code == NSURLErrorCancelled { 
                            self.logMetrics(clientSeq: currentClientSeq, inputLength: inputLength, latencyMs: latencyMs, error: "cancelled")
                            completion(nil)
                            return 
                        }
                        self.handleNetworkError(error, url: url)
                        self.consecutiveFailures += 1
                        if self.consecutiveFailures >= 2 {
                            // Jittered exponential backoff with 0.8-1.2x multiplier
                            let baseSeconds = min(pow(2.0, Double(self.consecutiveFailures - 1)), 16)
                            let jitterMultiplier = Double.random(in: 0.8...1.2)
                            let jitteredSeconds = baseSeconds * jitterMultiplier
                            
                            // Network-aware backoff: longer delays for poor connectivity
                            let networkMultiplier = self.isNetworkAvailable ? 1.0 : 2.0
                            let finalDelay = jitteredSeconds * networkMultiplier
                            
                            self.netBackoffUntil = Date().addingTimeInterval(finalDelay)
                            self.throttledLog("Exponential backoff: \(self.consecutiveFailures) failures, delay: \(String(format: "%.1f", finalDelay))s", category: "api")
                        }
                        self.logMetrics(clientSeq: currentClientSeq, inputLength: inputLength, latencyMs: latencyMs, error: error.localizedDescription)
                        completion(nil)
                        return
                    }
                    self.consecutiveFailures = 0
                    self.netBackoffUntil = .distantPast

                    guard let http = response as? HTTPURLResponse else {
                        self.throttledLog("no HTTPURLResponse for \(normalized)", category: "api")
                        self.logMetrics(clientSeq: currentClientSeq, inputLength: inputLength, latencyMs: latencyMs, error: "no_http_response")
                        completion(nil)
                        return
                    }
                    
                    guard (200..<300).contains(http.statusCode), let data = data else {
                        // Enhanced jittered backoff for different HTTP status codes
                        let baseDelay: TimeInterval
                        switch http.statusCode {
                        case 401, 403:
                            baseDelay = 60 // Auth errors: longer backoff
                        case 429:
                            baseDelay = min(pow(2.0, Double(self.consecutiveFailures)), 30) // Rate limiting: exponential
                        case 500...599:
                            baseDelay = min(pow(1.5, Double(self.consecutiveFailures)), 20) // Server errors: moderate backoff
                        default:
                            baseDelay = 5 // Other errors: short backoff
                        }
                        
                        // Apply jitter (0.8-1.2x multiplier)
                        let jitterMultiplier = Double.random(in: 0.8...1.2)
                        let finalDelay = baseDelay * jitterMultiplier
                        
                        if http.statusCode == 401 || http.statusCode == 403 {
                            self.authBackoffUntil = Date().addingTimeInterval(finalDelay)
                        } else {
                            self.netBackoffUntil = Date().addingTimeInterval(finalDelay)
                            self.consecutiveFailures += 1
                        }
                        
                        self.throttledLog("HTTP \(http.statusCode) \(normalized), backoff: \(String(format: "%.1f", finalDelay))s", category: "api")
                        if let d = data, let s = String(data: d, encoding: .utf8) {
                            self.throttledLog("Response body: \(s.prefix(200))", category: "api")
                        }
                        self.logMetrics(clientSeq: currentClientSeq, inputLength: inputLength, latencyMs: latencyMs, error: "http_\(http.statusCode)")
                        completion(nil)
                        return
                    }

                    // Robust decoding: Check Content-Type and gracefully handle plaintext or unexpected bodies
                    let contentType = http.allHeaderFields["Content-Type"] as? String ?? ""
                    
                    if !contentType.lowercased().contains("application/json") {
                        // If Content-Type ≠ application/json, log the body and skip UI update
                        if let bodyString = String(data: data, encoding: .utf8) {
                            self.throttledLog("Non-JSON response (Content-Type: \(contentType)): \(bodyString.prefix(200))", category: "api")
                        }
                        self.logMetrics(clientSeq: currentClientSeq, inputLength: inputLength, latencyMs: latencyMs, error: "non_json_response")
                        completion(nil)
                        return
                    }

                    do {
                        // Decode JSON into structured response and gracefully handle unexpected bodies
                        let json = try JSONSerialization.jsonObject(with: data, options: [])
                        guard let responseDict = json as? [String: Any] else {
                            self.throttledLog("Response is not a dictionary", category: "api")
                            self.logMetrics(clientSeq: currentClientSeq, inputLength: inputLength, latencyMs: latencyMs, error: "invalid_json_structure")
                            completion(nil)
                            return
                        }
                        
                        // Main-thread UI apply + last-writer-wins: Update tone indicator only if response's client_seq matches latest input
                        let responseClientSeq = (responseDict["client_seq"] as? NSNumber)?.uint64Value ?? currentClientSeq
                        
                        self.logMetrics(clientSeq: currentClientSeq, inputLength: inputLength, latencyMs: latencyMs, error: nil)
                        
                        // Stronger last-writer-wins with enhanced sequence validation
                        self.onQ {
                            // Validate response sequence is not stale
                            guard responseClientSeq >= self.pendingClientSeq else {
                                self.throttledLog("Discarding stale response (seq: \(responseClientSeq), current: \(self.pendingClientSeq))", category: "api")
                                DispatchQueue.main.async { completion(nil) }
                                return
                            }
                            
                            // Additional validation: ensure sequence is not from the future beyond expected bounds
                            guard responseClientSeq <= self.clientSequence else {
                                self.throttledLog("Discarding out-of-bounds response (seq: \(responseClientSeq), max: \(self.clientSequence))", category: "api")
                                DispatchQueue.main.async { completion(nil) }
                                return
                            }
                            
                            // Update pendingClientSeq atomically on workQueue
                            self.pendingClientSeq = responseClientSeq
                            
                            DispatchQueue.main.async {
                                completion(responseDict)
                            }
                        }
                        
                    } catch {
                        // If decode fails, log first 200 chars of the body
                        let bodyString = String(data: data, encoding: .utf8) ?? "<non-UTF8>"
                        self.throttledLog("JSON decode failed: \(error.localizedDescription). Body: \(bodyString.prefix(200))", category: "api")
                        self.logMetrics(clientSeq: currentClientSeq, inputLength: inputLength, latencyMs: latencyMs, error: "json_decode_failed")
                        completion(nil)
                    }
                }
                
                // Store task for cancellation and idempotency tracking
                self.pendingRequests[self.currentTextFieldKey] = task
                
                // 🛡️ Idempotency: Track in-flight request
                self.onQ {
                    self.inFlightRequests[requestHash] = task
                }
                
                task.resume()
            }
        }
    }

    // MARK: - Metrics Logging
    private func logMetrics(clientSeq: UInt64, inputLength: Int, latencyMs: TimeInterval, error: String?) {
        let logMessage = "API Metrics - client_seq: \(clientSeq), input_length: \(inputLength), latency_ms: \(Int(latencyMs))" + (error != nil ? ", error: \(error!)" : "")
        throttledLog(logMessage, category: "metrics")
        
        #if DEBUG
        print("📊 \(logMessage)")
        #endif
    }

    private func handleNetworkError(_ error: Error, url: URL) {
        let ns = error as NSError
        #if DEBUG
        switch ns.code {
        case NSURLErrorNotConnectedToInternet: print("🔌 offline: \(url)")
        case NSURLErrorTimedOut:               print("⏱️ timeout: \(url)")
        case NSURLErrorCannotFindHost:         print("🌐 cannot find host: \(url)")
        case NSURLErrorCannotConnectToHost:    print("🔌 cannot connect: \(url)")
        default:                               print("❌ network error \(ns.code): \(error.localizedDescription)")
        }
        #endif
        throttledLog("network error \(ns.code)", category: "api")
    }

    // MARK: - Helpers for tone buckets
    private func getEmotionalIndicatorsForTone(_ tone: String) -> [String] {
        switch tone {
        case "alert": return ["anger", "frustration", "urgency"]
        case "caution": return ["concern", "worry", "uncertainty"]
        case "clear": return ["confidence", "clarity", "positivity"]
        default: return []
        }
    }
    private func getCommunicationStyleForTone(_ tone: String) -> String {
        switch tone {
        case "alert": return "direct"
        case "caution": return "tentative"
        case "clear": return "confident"
        default: return "neutral"
        }
    }

    // MARK: - Decisioning
    private func shouldUpdateToneStatus(from current: String, to new: String,
                                        improvementDetected: Bool? = nil, improvementScore: Double? = nil) -> Bool {
        self.throttledLog("🎯 shouldUpdateToneStatus: '\(current)' -> '\(new)'", category: "tone_debug")
        
        if new == current { 
            self.throttledLog("🎯 Same tone, skipping update", category: "tone_debug")
            return false 
        }
        
        func severity(_ s: String) -> Int {
            switch s {
            case "neutral": return 0
            case "caution": return 1
            case "alert":   return 2
            case "clear":   return 0
            case "analyzing": return 0
            default: return 0
            }
        }
        
        let cur = severity(current), nxt = severity(new)
        if nxt > cur { 
            lastEscalationAt = Date()
            self.throttledLog("🎯 Escalation detected (\(cur) -> \(nxt)), allowing update", category: "tone_debug")
            return true 
        }
        
        let dwell: TimeInterval = 3.0
        if current == "alert" || current == "caution" {
            let timeSinceEscalation = Date().timeIntervalSince(lastEscalationAt)
            if timeSinceEscalation < dwell { 
                self.throttledLog("🎯 Dwell period active (\(String(format: "%.1f", timeSinceEscalation))s < \(dwell)s), skipping update", category: "tone_debug")
                return false 
            }
        }
        
        if let imp = improvementDetected, imp, (improvementScore ?? 0) > 0.3 { 
            self.throttledLog("🎯 Improvement detected, allowing update", category: "tone_debug")
            return true 
        }
        
        if currentText.count + 3 < lastAnalyzedText.count { 
            self.throttledLog("🎯 Significant text reduction, allowing update", category: "tone_debug")
            return true 
        }
        
        self.throttledLog("🎯 Default case, allowing update", category: "tone_debug")
        return true
    }

    // MARK: - Offline Fallback
    private func fallbackSuggestion(for text: String) -> String? {
        // LightweightSpellChecker.shared.getCapitalizationAndPunctuationSuggestions(for: text).first
        return nil // Placeholder since LightweightSpellChecker is not available
    }
    private func fallbackSuggestionForTone(_ tone: String, text: String) -> String? {
        switch tone {
        case "alert":   return "I'd like to discuss this calmly when you have a moment."
        case "caution": return "I want to make sure we're understanding each other correctly."
        case "clear":   return "I appreciate us being able to communicate openly about this."
        default:        return fallbackSuggestion(for: text)
        }
    }

    // MARK: - Storage / Analytics (commented out due to missing dependencies)
    private func storeToneAnalysisResult(data: [String: Any], status: String, confidence: Double) {
        // SafeKeyboardDataStorage.shared.recordToneAnalysis(text: currentText, tone: status, confidence: confidence, analysisTime: 0.0)
        // let interaction = KeyboardInteraction(...)
        // SafeKeyboardDataStorage.shared.recordInteraction(interaction)
        print("Tone analysis result: \(status) (confidence: \(confidence))")
    }

    // MARK: - SpaCy Bridge (unchanged)
    func checkForSpacyResults() {
    let shared = sharedUserDefaults
    if let analysisData = shared.dictionary(forKey: "spacy_analysis_result"),
           let timestamp = analysisData["timestamp"] as? TimeInterval {
            let lastProcessed = UserDefaults.standard.double(forKey: "last_spacy_result_timestamp")
            if timestamp > lastProcessed {
                enhancedAnalysisResults = analysisData
                UserDefaults.standard.set(timestamp, forKey: "last_spacy_result_timestamp")
                throttledLog("spacy analysis received", category: "spacy")
                DispatchQueue.main.async { [weak self] in self?.applyEnhancedSpacyAnalysis() }
            }
        }
    }
    func requestSpacyAnalysis(text: String, context: String = "typing") {
    let shared = sharedUserDefaults
        let req: [String: Any] = [
            "text": text,
            "context": context,
            "timestamp": isoTimestamp(),
            "requestId": UUID().uuidString
        ]
        shared.set(req, forKey: "spacy_analysis_request")
        throttledLog("spacy request queued", category: "spacy")
    }
    private func applyEnhancedSpacyAnalysis() {
        guard let analysis = enhancedAnalysisResults else { return }
        if let toneStr = (analysis["ui_tone"] as? String) ?? (analysis["tone_status"] as? String) ?? (analysis["tone"] as? String) {
            DispatchQueue.main.async {
                if self.shouldUpdateToneStatus(from: self.currentToneStatus, to: toneStr) {
                    self.currentToneStatus = toneStr
                    self.delegate?.didUpdateToneStatus(toneStr)
                }
            }
        }
    }
    func updateToneFromAnalysis(_ analysis: [String: Any]) {
        if let toneStr = (analysis["ui_tone"] as? String) ?? (analysis["tone_status"] as? String) ?? (analysis["tone"] as? String),
           !toneStr.isEmpty { // Simple validation instead of ToneStatus enum
            currentToneStatus = toneStr
            DispatchQueue.main.async { self.delegate?.didUpdateToneStatus(toneStr) }
        }
    }

    // MARK: - ToneStreamDelegate (commented out for compilation)
    /*
    func onToneData(_ intensity: Float, _ sharpness: Float) {
        isStreamEnabled = true
        
        // TODO: Implement when dependencies are available
    }
    
    func onToneEnd() {
        isStreamEnabled = false
    }
    */
}

/*
// MARK: - ToneStreamDelegate (commented out due to missing dependencies)
extension ToneSuggestionCoordinator {
    // ToneStream delegate methods would go here
}
*/

// MARK: - Helpers
private extension String { var nilIfEmpty: String? { isEmpty ? nil : self } }
