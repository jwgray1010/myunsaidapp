import Foundation
import os.log
import Network
import QuartzCore  // For CACurrentMediaTime
#if canImport(UIKit)
import UIKit
#endif

// Import shared types for ToneStatus, InteractionType, KeyboardInteraction, etc.
// This ensures proper compilation order in the UnsaidKeyboard target build sequence.

// Import additional dependencies used by ToneSuggestionCoordinator
// Note: The specific file references ensure proper compilation order
// in the UnsaidKeyboard target build sequence.

// MARK: - API Error Types
enum APIError: LocalizedError {
    case authRequired
    case paymentRequired
    case serverError(Int)
    case networkError
    case unknown
    
    var errorDescription: String? {
        switch self {
        case .authRequired:
            return "Authentication required - please sign in"
        case .paymentRequired:
            return "Trial expired - subscription required"
        case .serverError(let code):
            return "Server error: \(code)"
        case .networkError:
            return "Network connection error"
        case .unknown:
            return "Unknown error occurred"
        }
    }
    
    var recoverySuggestion: String? {
        switch self {
        case .authRequired:
            return "Please sign in to continue using AI features"
        case .paymentRequired:
            return "Subscribe to Unsaid Premium to continue using AI coaching"
        case .serverError:
            return "Please try again later"
        case .networkError:
            return "Check your internet connection and try again"
        case .unknown:
            return "Please try again"
        }
    }
}

// MARK: - Async Wrappers
extension ToneSuggestionCoordinator {
    /// Async wrapper for fetchSuggestions to avoid closure capture issues
    func fetchSuggestionsAsync(for text: String) async -> [String] {
        await withCheckedContinuation { cont in
            self.fetchSuggestions(for: text) { arr in
                cont.resume(returning: arr ?? [])
            }
        }
    }
}

// MARK: - API Response Models
struct ToneEnvelope: Decodable {
    let version: String?
    let timestamp: String?
    let client_seq: Int?
    let success: Bool?
    let data: ToneData
}

struct ToneData: Decodable {
    let ui_tone: String?
    let raw_tone: String?
    let intense: Bool?
    let score: Double?
    let explanations: [String]?
}

enum UITone: String, CaseIterable {
    case alert = "alert"
    case caution = "caution" 
    case clear = "clear"
    case neutral = "neutral"
}

// MARK: - Delegate Protocol
@MainActor
protocol ToneSuggestionDelegate: AnyObject {
    func didUpdateSuggestions(_ suggestions: [String])
    func didUpdateToneStatus(_ tone: String)  // <- back to String for Xcode compatibility
    func didUpdateSecureFixButtonState()
    func didReceiveAPIError(_ error: APIError)
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
    // MARK: - Request Token Management (Phase 1: Safe without client_seq)
    private var latestRequestToken: UUID?
    private var currentTone: UITone = .neutral
    private var lastChangeAt: CFTimeInterval = 0
    
    // MARK: Public
    weak var delegate: ToneSuggestionDelegate?
    
    // MARK: - Circuit Breaker per endpoint
    private struct CircuitKey: Hashable { 
        let host: String
        let path: String 
    }
    private var circuitBreakers: [CircuitKey: Date] = [:]
    
    // Performance Optimization #4: Track circuit breaker state to reduce log chatter
    private var breakerOpen: Set<CircuitKey> = []
    
    private func setBreaker(_ key: CircuitKey, open: Bool) {
        if open {
            if breakerOpen.insert(key).inserted { 
                throttledLog("🚨 CB OPEN \(key.path)", category: "breaker") 
            }
        } else {
            if breakerOpen.remove(key) != nil { 
                throttledLog("✅ CB CLOSE \(key.path)", category: "breaker") 
            }
        }
    }

    // MARK: - Robust UI Tone Extraction
    
    /// Extract UI tone from response envelope with robust fallback
    private func extractUITone(from env: ToneEnvelope) -> UITone {
        // Prefer explicit ui_tone from data
        if let t = env.data.ui_tone, let mapped = UITone(rawValue: t) {
            throttledLog("🎯 ✅ EXTRACTED ui_tone: '\(t)' -> \(mapped)", category: "tone_debug")
            return mapped
        }
        
        // Fallback mapping from raw_tone + intensity  
        let raw = (env.data.raw_tone ?? "").lowercased()
        let intense = env.data.intense ?? false
        let result: UITone
        
        switch (raw, intense) {
        case ("anger", _), ("hostile", _), ("contempt", _), ("threat", _):
            result = .alert
        case ("frustration", _), ("critique", _), ("defensive", _):
            result = .caution
        case ("clear", _):
            result = .clear
        case ("", _):
            result = .neutral
        default:
            result = intense ? .alert : .caution
        }
        
        throttledLog("🎯 ⚠️ FALLBACK MAPPING: raw='\(raw)' intense=\(intense) -> \(result)", category: "tone_debug")
        return result
    }
    
    /// Single source of truth for tone updates (Phase 1: Clean without client_seq)
    private func setToneIfNeeded(_ new: UITone, animated: Bool = true) {
        let now = CACurrentMediaTime()
        
        // Update conditions: tone changed, periodic refresh, or neutral->non-neutral
        if new != currentTone || now - lastChangeAt > 0.8 || (currentTone == .neutral && new != .neutral) {
            throttledLog("🎯 ✅ UPDATING TONE: \(currentTone.rawValue) -> \(new.rawValue)", category: "tone_debug")
            currentTone = new
            lastChangeAt = now
            
            // Call delegate on main thread
            DispatchQueue.main.async {
                self.delegate?.didUpdateToneStatus(new.rawValue)
            }
        } else {
            throttledLog("🎯 ⚠️ SKIP SET_TONE \(currentTone.rawValue) -> \(new.rawValue)", category: "tone_debug")
        }
    }
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
    
    // MARK: - Constants
    
    /// Single source of truth for allowed suggestion features
    private let allowedSuggestionFeatures: Set<String> = [
        "advice", "quick_fixes", "evidence", "emotional_support", "context_analysis"
    ]
    
    // MARK: - Snapshot-based UI updates
    private var lastNotifiedSuggestions: [String] = []
    private var lastNotifiedToneStatus: String = "neutral"
    private var lastNotificationTime: Date = .distantPast
    
    // NEW: once we show a non-neutral tone, don't allow neutral again until the field is empty
    private var neutralBlockActive = false

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
    
    // Performance Optimization #7: Single-flight suggestions with tap throttling
    private var suggestionsInFlight = false
    private var lastSuggestionsAt: Date = .distantPast
    private let suggestionTapCooldown: TimeInterval = 0.6
    // Performance Optimization #3: Per-endpoint cache TTLs
    private func cacheTTL(for path: String) -> TimeInterval {
        switch path {
        case "/api/v1/tone": return 0.8 // Fast turnaround for real-time analysis
        case "/api/v1/suggestions": return 5.0 // Medium cache for suggestion stability
        case "/api/v1/communicator/observe": return 10.0 // Longer cache for profile updates
        default: return 5.0 // Default fallback
        }
    }

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
        request.setValue(getUserId(), forHTTPHeaderField: "x-user-id")
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
        let userIdKey = "unsaid_user_id"
        let appGroupId = "group.com.example.unsaid"
        
        if let sharedDefaults = UserDefaults(suiteName: appGroupId),
           let userId = sharedDefaults.string(forKey: userIdKey) {
            return userId
        }
        
        // Fallback to a UUID if somehow not set (shouldn't happen with proper initialization)
        let fallbackId = UUID().uuidString
        if let sharedDefaults = UserDefaults(suiteName: appGroupId) {
            sharedDefaults.set(fallbackId, forKey: userIdKey)
        }
        return fallbackId
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
        
        // Note: Removed debugPing() call to prevent any startup tone changes
        // DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
        //     if self.currentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        //         self.debugPing()
        //     }
        // }
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
        
        throttledLog("🎯 📝 HANDLE_TEXT_CHANGE: '\(String(text.prefix(50)))...', length: \(text.count)", category: "tone_debug")
        
        // Guard against empty/unchanged text (don't fire network calls)
        guard shouldEnqueueAnalysis() else {
            throttledLog("🚫 Skipping analysis - shouldEnqueueAnalysis returned false for text: '\(text.prefix(50))'", category: "analysis")
            return
        }
        
        throttledLog("🎯 ✅ PASSED shouldEnqueueAnalysis - proceeding with tone analysis", category: "tone_debug")
        
        // Cancel in-flight requests for this text field when new keystroke arrives
        cancelInFlightRequestsForCurrentField()
        
        // Wrap network trigger in trailing debounce (200ms) keyed by active text field
        print("📝 Enqueueing tone analysis for: '\(text.prefix(50))...'")
        throttledLog("🎯 🕐 DEBOUNCING ANALYSIS: \(debounceInterval)s", category: "tone_debug")
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

    /// Fetch suggestions for specific text with callback (for tone button tap)
    func fetchSuggestions(for text: String, completion: @escaping ([String]?) -> Void) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            completion(nil)
            return
        }
        
        // Performance Optimization #7: Single-flight + tap throttling
        let now = Date()
        if suggestionsInFlight || now.timeIntervalSince(lastSuggestionsAt) < suggestionTapCooldown {
            completion(nil)
            return
        }
        suggestionsInFlight = true
        lastSuggestionsAt = now
        
        throttledLog("🎯 Fetching suggestions for tone button tap", category: "suggestions")
        
        var textToAnalyze = text
        if textToAnalyze.count > 1000 { textToAnalyze = String(textToAnalyze.suffix(1000)) }

        var context: [String: Any] = [
            "text": textToAnalyze,
            "userId": getUserId(),
            "userEmail": getUserEmail() ?? NSNull(),
            "features": ["advice", "evidence"], // Only advice, not rewrite
            "meta": [
                "source": "keyboard_tone_button",
                "request_type": "suggestion",
                "context": "general",
                "timestamp": isoTimestamp()
            ]
        ]
        context.merge(personalityPayload()) { _, new in new }

        callSuggestionsAPI(context: context, usingSnapshot: textToAnalyze) { [weak self] suggestion in
            self?.suggestionsInFlight = false // Reset single-flight flag
            if let suggestion = suggestion, !suggestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                completion([suggestion])
            } else {
                completion(nil)
            }
        }
    }

    func resetState() {
        onQ {
            self.pendingWorkItem?.cancel()
            self.inFlightTask?.cancel()
            self.currentText = ""
            self.lastAnalyzedText = ""
            self.currentToneStatus = "neutral"
            self.neutralBlockActive = false   // ← reset latch on full reset
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
            self.neutralBlockActive = false   // ← reset latch here too
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

    func shouldAttemptAnalysis() -> Bool {
        return shouldEnqueueAnalysis()
    }
    
    private func shouldEnqueueAnalysis() -> Bool {
        // Performance Optimization #6: Don't queue work during global network backoff
        if Date() < netBackoffUntil { return false }
        
        let now = Date()
        let trimmed = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Guard: empty text doesn't fire network calls
        if trimmed.isEmpty && lastAnalyzedText.isEmpty { return false }
        if trimmed.isEmpty, !lastAnalyzedText.isEmpty { return true }
        if now.timeIntervalSince(lastAnalysisTime) < 0.1 { return false }

        // Enhanced logic: neutral doesn't "stick", plus key triggers
        let prevLen = lastAnalyzedText.count
        let newLen = trimmed.count
        let lastChar = trimmed.last
        
        // Always analyze if current tone is neutral (prevents sticking)
        if currentTone == .neutral { return true }
        
        // Analyze on significant length changes
        if abs(newLen - prevLen) >= 3 { return true }
        
        // Analyze on punctuation or space
        if let k = lastChar, ".!? ".contains(k) { return true }
        
        // Reduced blocking for micro-changes
        if now.timeIntervalSince(lastAnalysisTime) < 0.2,
           abs(newLen - prevLen) <= 2 {
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
                self.neutralBlockActive = false   // ← reset the policy when the field is empty
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
                
                // Enforce the latch: while text is non-empty, never go back to neutral
                let trimmed = self.currentText.trimmingCharacters(in: .whitespacesAndNewlines)
                if tone == "neutral", self.neutralBlockActive, !trimmed.isEmpty {
                    self.throttledLog("🎯 NEUTRAL BLOCKED: latch active + text exists", category: "tone_debug")
                    return
                }
                
                DispatchQueue.main.async {
                    if self.shouldUpdateToneStatus(from: self.currentToneStatus, to: tone) {
                        self.throttledLog("🎯 ✅ UPDATING TONE: '\(self.currentToneStatus)' -> '\(tone)'", category: "tone_debug")
                        self.currentToneStatus = tone
                        self.throttledLog("🎯 🔄 CALLING DELEGATE: didUpdateToneStatus('\(tone)')", category: "tone_debug")
                        self.delegate?.didUpdateToneStatus(tone)  // Pass string directly
                        
                        // Once we've shown a non-neutral tone, activate the block
                        if tone != "neutral" { self.neutralBlockActive = true }
                        
                        // KEY DEBUG LINE - this is the canary that shows UI update is called
                        self.throttledLog("🎯 ✅ UI TONE SET: \(tone)", category: "tone_debug")
                        
                        // Update haptic feedback (throttled to 10 Hz)
                        self.updateHapticFeedback(for: tone)
                    } else {
                        self.throttledLog("🎯 ❌ BLOCKED: shouldUpdateToneStatus returned false", category: "tone_debug")
                    }
                }
            } else {
                // No update on failure/skip — keep whatever is showing
                self.throttledLog("🎯 ❌ NIL RESULT: leaving pill as \(self.currentToneStatus)", category: "tone_debug")
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

        // 🛡️ Sanitize features right before network call (covers all code paths)
        var safePayload = payload
        if var feats = safePayload["features"] as? [String] {
            feats = feats.filter { allowedSuggestionFeatures.contains($0) }
            // dedupe to be tidy
            safePayload["features"] = Array(Set(feats))
        }
        
        // Optional: Log the final sanitized features for debugging
        throttledLog("suggestions features: \((safePayload["features"] as? [String])?.joined(separator: ",") ?? "<none>")", category: "api")

        callEndpoint(path: "api/v1/suggestions", payload: safePayload) { [weak self] data in
            guard let self else { completion(nil); return }
            guard requestID == self.latestRequestID else { completion(nil); return }

            let root = data ?? [:]
            let body: [String: Any] = (root["data"] as? [String: Any]) ?? root  // ← prefer top-level, fallback to data{}
            
            if !root.isEmpty {
                self.enhancedAnalysisResults = root
                self.storeAPIResponseInSharedStorage(endpoint: "suggestions", request: payload, response: root)
            }

            // Update tone with defensive parsing - parse from body (top-level or data{})
            let uiTone = self.uiToneString(from: body)
            
            if uiTone != "neutral" {
                DispatchQueue.main.async {
                    if self.shouldUpdateToneStatus(from: self.currentToneStatus, to: uiTone) {
                        self.currentToneStatus = uiTone
                        self.neutralBlockActive = true   // ← latch once we show non-neutral
                        self.throttledLog("🎯 UI tone -> \(uiTone)", category: "tone_debug")
                        self.delegate?.didUpdateToneStatus(uiTone)  // Only send clamped UI tones
                        
                        // Extract confidence with defensive parsing
                        let confidence = self.safeDouble(from: body, keys: ["confidence"], fallback: 0.0)
                        if confidence > 0.0 {
                            self.storeToneAnalysisResult(data: body, status: uiTone, confidence: confidence)
                        }
                    }
                }
            }

            // Extract suggestion with defensive parsing - parse from body (top-level or data{})
            let suggestion = extractSuggestionSafely(from: body)
            completion(suggestion)
        }
    }
    
    /// Safely extract suggestion from API response with multiple fallbacks
    private func extractSuggestionSafely(from dict: [String: Any]) -> String? {
        // 1) Preferred: suggestions[0].text  (your new server)
        if let arr = dict["suggestions"] as? [[String: Any]],
           let first = arr.first {
            let t = safeString(from: first, keys: ["text", "message", "advice"])
            if !t.isEmpty { return t }
        }

        // 2) quickFixes: [String]
        if let fixes = dict["quickFixes"] as? [String], let first = fixes.first, !first.isEmpty {
            return first
        }

        // 3) single-field advice string (some backends)
        let advice = safeString(from: dict, keys: ["advice", "tip", "suggestion", "general_suggestion"])
        if !advice.isEmpty { return advice }

        // 4) extras.suggestions[0].text (legacy nesting)
        if let extras = dict["extras"] as? [String: Any],
           let arr = extras["suggestions"] as? [[String: Any]],
           let first = arr.first {
            let t = safeString(from: first, keys: ["text"])
            if !t.isEmpty { return t }
        }

        // 5) absolute last resort (legacy): data as a plain string
        if let s = dict["data"] as? String, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return s
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
        throttledLog("🎯 🔍 PARSING UI TONE - Full response keys: \(Array(response.keys))", category: "tone_debug")
        
        // FIRST: Check for direct ui_tone field (this is what the API returns!)
        let directUITone = safeString(from: response, keys: ["ui_tone", "uiTone"], fallback: "")
        if !directUITone.isEmpty {
            let normalized = normalizeToneLabel(directUITone)
            throttledLog("🎯 ✅ Found direct ui_tone: '\(directUITone)' -> normalized: '\(normalized)'", category: "tone_debug")
            return normalized
        } else {
            throttledLog("🎯 ⚠️ No direct ui_tone found, checking nested analysis...", category: "tone_debug")
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
        let textToAnalyze = context["text"] as? String ?? ""
        
        // Generate unique token for this request (Phase 1: Safe without client_seq)
        let token = UUID()
        latestRequestToken = token
        
        throttledLog("🎯 🚀 INITIATING TONE API CALL - Text: '\(String(textToAnalyze.prefix(50)))...' Token: \(token.uuidString.prefix(8))", category: "tone_debug")
        
        guard isNetworkAvailable, isAPIConfigured, Date() >= netBackoffUntil else { 
            throttledLog("🎯 ❌ API CALL BLOCKED - Network: \(isNetworkAvailable), Configured: \(isAPIConfigured), Backoff until: \(netBackoffUntil)", category: "tone_debug")
            completion(nil)
            return 
        }

        let requestID = UUID()
        latestRequestID = requestID

        var payload = context
        payload["requestId"] = requestID.uuidString
        payload["userId"] = getUserId()
        payload["userEmail"] = getUserEmail()
        // Note: client_seq will be added in Phase 2

        callEndpoint(path: "api/v1/tone", payload: payload) { [weak self] data in
            guard let self else { 
                completion(nil)
                return 
            }
            
            // ✅ Drop stale replies automatically with token check
            guard token == self.latestRequestToken else {
                self.throttledLog("🎯 ⚠️ DROPPING STALE TONE REPLY (token mismatch)", category: "tone_debug")
                completion(nil)
                return
            }
            
            guard requestID == self.latestRequestID else { 
                completion(nil)
                return 
            }

            guard let d = data else {
                self.throttledLog("🎯 Tone API returned nil data - keeping current pill state", category: "tone_debug")
                completion(nil)
                return
            }
            
            self.throttledLog("🎯 Tone API response: \(String(describing: d).prefix(200))", category: "tone_debug")

            // Try to parse as new ToneEnvelope format
            do {
                let jsonData = try JSONSerialization.data(withJSONObject: d)
                let decoder = JSONDecoder()
                let envelope = try decoder.decode(ToneEnvelope.self, from: jsonData)
                
                // Extract UI tone and update
                let ui = self.extractUITone(from: envelope)
                self.setToneIfNeeded(ui)
                completion(envelope.data.ui_tone ?? ui.rawValue)
                return
                
            } catch {
                self.throttledLog("🎯 ⚠️ Failed to parse as ToneEnvelope, falling back to legacy parsing: \(error)", category: "tone_debug")
            }

            // Fallback to legacy parsing for backward compatibility
            let legacyTone = self.uiToneString(from: d)
            if let uiTone = UITone(rawValue: legacyTone) {
                self.setToneIfNeeded(uiTone)
            }
            self.throttledLog("🎯 Legacy extracted UI tone: '\(legacyTone)'", category: "tone_debug")
            completion(legacyTone)
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
        
        // ️ Idempotency Guards: Check for duplicate/recent requests
        let requestHash = contentHash(for: path, payload: payload)
        let now = Date()
        let ttl = cacheTTL(for: path)
        
        // Clean up old completion times
        onQ {
            let cutoff = now.addingTimeInterval(-ttl)
            self.requestCompletionTimes = self.requestCompletionTimes.filter { $0.value > cutoff }
        }
        
        // Check if identical request completed recently
        if let lastCompletion = requestCompletionTimes[requestHash],
           now.timeIntervalSince(lastCompletion) < ttl {
            throttledLog("Skipping duplicate request within \(ttl)s cache window", category: "api")
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
        
        // 🔧 Circuit Breaker: Check per-endpoint breakers (prevents observe 404s from blocking tone/suggestions)
        let circuitKey = CircuitKey(host: normalizedBaseURLString(), path: normalized)
        if let breakerUntil = circuitBreakers[circuitKey], Date() < breakerUntil {
            // Only log if we haven't already marked this breaker as open (reduces spam)
            if !breakerOpen.contains(circuitKey) {
                setBreaker(circuitKey, open: true)
            }
            completion(nil)
            return
        }
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
        
        // 🔧 DEBUG: Log full URL before each request to catch path issues
        throttledLog("🔧 REQUEST \(url.absoluteString)", category: "api")
        
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
                    
                    // 🛡️ Always remove the in-flight marker
                    self.onQ { self.inFlightRequests.removeValue(forKey: requestHash) }
                    
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
                        // Handle specific error cases that should notify the UI
                        switch http.statusCode {
                        case 401:
                            self.throttledLog("Authentication required (401)", category: "api")
                            Task { @MainActor in
                                self.delegate?.didReceiveAPIError(.authRequired)
                            }
                            completion(nil)
                            return
                        case 402:
                            self.throttledLog("Payment required (402)", category: "api")
                            Task { @MainActor in
                                self.delegate?.didReceiveAPIError(.paymentRequired)
                            }
                            completion(nil)
                            return
                        case 404:
                            // Special handling for /communicator/observe 404s - don't freeze other endpoints
                            if normalized == "api/v1/communicator/observe" {
                                let jitterMultiplier = Double.random(in: 0.8...1.2)
                                let circuitDelay = 10.0 * jitterMultiplier // 8-12 seconds with jitter
                                self.circuitBreakers[circuitKey] = Date().addingTimeInterval(circuitDelay)
                                // Performance Optimization #4: Use quiet state tracking for breaker logging
                                self.setBreaker(circuitKey, open: true)
                                completion(nil)
                                return
                            }
                            // For other endpoints, fall through to normal error handling
                            break
                        default:
                            break
                        }
                        
                        // Enhanced jittered backoff for other HTTP status codes
                        let baseDelay: TimeInterval
                        switch http.statusCode {
                        case 403:
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
                        
                        if http.statusCode == 403 {
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

                    // Performance Optimization #5: Auto-close circuit breaker on successful response
                    if self.circuitBreakers[circuitKey] != nil {
                        self.circuitBreakers.removeValue(forKey: circuitKey)
                        self.setBreaker(circuitKey, open: false)
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
                            
                            // 🛡️ Only cache successful requests (prevents retries from being suppressed)
                            self.requestCompletionTimes[requestHash] = Date()
                            
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
        
        // NEW: latch policy - prevent neutral when text exists and latch is active
        if new == "neutral", neutralBlockActive, !currentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throttledLog("🎯 ❌ NEUTRAL LATCH: blocked (text exists, latch active)", category: "tone_debug")
            return false
        }
        
        if new == current { 
            self.throttledLog("🎯 ❌ SAME TONE: skipping update", category: "tone_debug")
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
            self.throttledLog("🎯 ✅ ESCALATION: (\(cur) -> \(nxt)) allowing update", category: "tone_debug")
            return true 
        }
        
        let dwell: TimeInterval = 3.0
        if current == "alert" || current == "caution" {
            let timeSinceEscalation = Date().timeIntervalSince(lastEscalationAt)
            if timeSinceEscalation < dwell { 
                self.throttledLog("🎯 ❌ DWELL: \(String(format: "%.1f", timeSinceEscalation))s < \(dwell)s", category: "tone_debug")
                return false 
            }
        }
        
        if let imp = improvementDetected, imp, (improvementScore ?? 0) > 0.3 { 
            self.throttledLog("🎯 ✅ IMPROVEMENT: detected, allowing update", category: "tone_debug")
            return true 
        }
        
        if currentText.count + 3 < lastAnalyzedText.count { 
            self.throttledLog("🎯 ✅ TEXT REDUCTION: significant change, allowing update", category: "tone_debug")
            return true 
        }
        
        self.throttledLog("🎯 ✅ DEFAULT: allowing update", category: "tone_debug")
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
            // Respect the latch policy
            if toneStr == "neutral", neutralBlockActive, !currentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throttledLog("SpaCy: neutral blocked by latch", category: "tone_debug")
            } else if self.shouldUpdateToneStatus(from: self.currentToneStatus, to: toneStr) {
                DispatchQueue.main.async {
                    self.currentToneStatus = toneStr
                    if toneStr != "neutral" { self.neutralBlockActive = true }
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

    // MARK: - Debug Methods
    #if DEBUG
    /// Public method to trigger tone analysis for debugging
    func debugTriggerToneAnalysis() {
        throttledLog("🔍 Debug: Manually triggering tone analysis", category: "debug")
        performTextUpdate()
    }
    #endif
}

/*
// MARK: - ToneStreamDelegate (commented out due to missing dependencies)
extension ToneSuggestionCoordinator {
    // ToneStream delegate methods would go here
}
*/

// MARK: - Helpers
private extension String { var nilIfEmpty: String? { isEmpty ? nil : self } }
