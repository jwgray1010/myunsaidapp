import Foundation
import os.log
import Network
#if canImport(UIKit)
import UIKit
#endif
// Ensure shared types (ToneStatus, InteractionType, KeyboardInteraction, etc.) are compiled in this target.
// If the file name differs, adjust the import path via project settings. This comment documents the dependency.

// MARK: - Delegate Protocol
protocol ToneSuggestionDelegate: AnyObject {
    func didUpdateSuggestions(_ suggestions: [String])
    func didUpdateToneStatus(_ status: String)
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
final class ToneSuggestionCoordinator: ToneStreamDelegate {
    // MARK: Public
    weak var delegate: ToneSuggestionDelegate?

    // MARK: - Helper for API timestamp format
    private func isoTimestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }

    // MARK: Configuration
    private var apiBaseURL: String {
        let extBundle = Bundle(for: ToneSuggestionCoordinator.self)
        let mainBundle = Bundle.main
        let fromExt = extBundle.object(forInfoDictionaryKey: "UNSAID_API_BASE_URL") as? String
        let fromMain = mainBundle.object(forInfoDictionaryKey: "UNSAID_API_BASE_URL") as? String
        let picked = (fromExt?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                      ?? fromMain?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty)
        return picked ?? ""
    }
    private var apiKey: String {
        let extBundle = Bundle(for: ToneSuggestionCoordinator.self)
        let mainBundle = Bundle.main
        let fromExt = extBundle.object(forInfoDictionaryKey: "UNSAID_API_KEY") as? String
        let fromMain = mainBundle.object(forInfoDictionaryKey: "UNSAID_API_KEY") as? String
        return (fromExt?.nilIfEmpty ?? fromMain?.nilIfEmpty) ?? ""
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

    // MARK: - Queue / Debounce
    private let workQueue = DispatchQueue(label: "com.unsaid.coordinator", qos: .utility)
    private var pendingWorkItem: DispatchWorkItem?
    private let debounceInterval: TimeInterval = 0.1

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

    // MARK: - Request Mgmt / Backoff
    private var latestRequestID = UUID()
    private var authBackoffUntil: Date = .distantPast
    private var netBackoffUntil: Date = .distantPast  // NEW: general backoff

    // MARK: - Shared Defaults
    private let sharedUserDefaults: UserDefaults = AppGroups.shared

    // MARK: - Personality Bridge
    private let personalityBridge = PersonalityDataBridge.shared
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
    
    // MARK: - WebSocket Stream Client
    private let streamClient = ToneStreamClient()
    private var isStreamEnabled = false
    
    // MARK: - Health Debug
    private let netLog = OSLog(subsystem: Bundle.main.bundleIdentifier ?? "UnsaidKeyboard", category: "Network")
    
    func dumpAPIConfig() {
        let base = Bundle.main.object(forInfoDictionaryKey: "UNSAID_API_BASE_URL") as? String ?? "<missing>"
        let key  = Bundle.main.object(forInfoDictionaryKey: "UNSAID_API_KEY") as? String ?? "<missing>"
        os_log("🔧 API Config - Base URL: %{public}@, Key prefix: %{public}@", log: netLog, type: .info, base, String(key.prefix(8)))
    }
    
    func debugPing() {
        dumpAPIConfig()

        // Ensure base has no trailing /api/v1 because we append it here.
        let rawBase = (Bundle.main.object(forInfoDictionaryKey: "UNSAID_API_BASE_URL") as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedBase: String = rawBase.hasSuffix("/api/v1") ? String(rawBase.dropLast(7)) : rawBase
        guard var comps = URLComponents(string: cleanedBase) else {
            os_log("❌ Invalid base URL", log: self.netLog, type: .error); return
        }
        comps.path = "/api/v1/health"
        guard let url = comps.url else { os_log("❌ Could not build health URL", log: self.netLog, type: .error); return }

        os_log("🌐 GET %{public}@", log: self.netLog, type: .info, url.absoluteString)

        var req = URLRequest(url: url)
        req.timeoutInterval = 15

        let cfg = URLSessionConfiguration.ephemeral
        cfg.waitsForConnectivity = true
        let session = URLSession(configuration: cfg)
        session.dataTask(with: req) { data, resp, err in
            if let err = err {
                os_log("❌ Request error: %{public}@", log: self.netLog, type: .error, String(describing: err))
                return
            }
            let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
            os_log("✅ Status: %d", log: self.netLog, type: .info, status)
            if let data = data, let body = String(data: data, encoding: .utf8) {
                #if DEBUG
                os_log("Body: %{public}@", log: self.netLog, type: .debug, body)
                #endif
            }
        }.resume()
    }

    // MARK: - Init/Deinit
    init() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.startNetworkMonitoringSafely()
        }
        
        // Start attachment learning window if needed
        personalityBridge.markAttachmentLearningStartedIfNeeded(days: 7)
        
        #if DEBUG
        debugPrint("🧠 Personality Data Bridge Status:")
        debugPrint(" - Attachment Style: '\(getAttachmentStyle())'")
        debugPrint(" - Communication Style: '\(personalityBridge.getCommunicationStyle())'")
        debugPrint(" - Personality Type: '\(personalityBridge.getPersonalityType())'")
        debugPrint(" - Emotional State: '\(getEmotionalState())'")
        debugPrint(" - Test Complete: \(personalityBridge.isPersonalityTestComplete())")
        debugPrint(" - Data Freshness: \(personalityBridge.getDataFreshness()) hours")
        debugPrint(" - New User: \(personalityBridge.isNewUser())")
        debugPrint(" - Learning Days Remaining: \(personalityBridge.learningDaysRemaining())")
        
        // Health ping to verify API configuration
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            self.debugPing()
        }
        #endif
    }

    deinit {
        print("🗑️ ToneSuggestionCoordinator deinit - cleaning up resources")
        
        // Stop haptic session and WebSocket streaming
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
        
        // Connect WebSocket for real-time tone updates
        streamClient.delegate = self
        streamClient.connect()
    }
    
    /// Stop haptic session (call once when user stops typing or app backgrounds)
    func stopHapticSession() {
        guard isHapticSessionActive else { return }
        isHapticSessionActive = false
        // hapticController.stopHapticSession() // TODO: Uncomment when types are resolved
        
        // Disconnect WebSocket
        streamClient.disconnect()
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
        updateCurrentText(text)
        
        // Stream text to WebSocket for real-time analysis (if connected)
        if isStreamEnabled && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            streamClient.sendTextUpdate(text)
        }
        
        guard shouldEnqueueAnalysis() else {
            throttledLog("skip enqueue (timing / unchanged / short)", category: "analysis")
            return
        }
        print("📝 Enqueueing tone analysis for: '\(text.prefix(50))...'")
        pendingWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.performTextUpdate() }
        pendingWorkItem = work
        let delay: TimeInterval = currentText.count > 20 ? 0.05 : debounceInterval
        workQueue.asyncAfter(deadline: .now() + delay, execute: work)
        throttledLog("scheduled analysis in \(delay)s", category: "analysis")
    }

    // Force immediate text analysis (useful when switching from iOS keyboard)
    func forceImmediateAnalysis(_ text: String) {
        updateCurrentText(text)
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            pendingWorkItem?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.performTextUpdate() }
            pendingWorkItem = work
            workQueue.async(execute: work)
            throttledLog("forced immediate analysis", category: "analysis")
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
        pendingWorkItem?.cancel()
        inFlightTask?.cancel()
        currentText = ""
        lastAnalyzedText = ""
        currentToneStatus = "neutral"
        suggestions = []
        consecutiveFailures = 0
        lastEscalationAt = .distantPast
        suggestionSnapshot = nil
        DispatchQueue.main.async {
            self.delegate?.didUpdateToneStatus("neutral")
            self.delegate?.didUpdateSuggestions([])
        }
        throttledLog("state reset", category: "coordinator")
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
        currentText = trimmed
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

    private func shouldEnqueueAnalysis() -> Bool {
        let now = Date()
        let trimmed = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count < 5, !trimmed.isEmpty { return false }
        if trimmed.isEmpty, !lastAnalyzedText.isEmpty { return true }
        if now.timeIntervalSince(lastAnalysisTime) < 0.1 { return false }

        // NEW: skip micro deltas within 500ms (user still mid-token)
        if now.timeIntervalSince(lastAnalysisTime) < 0.5,
           abs(trimmed.count - lastAnalyzedText.count) <= 1 {
            return false
        }
        return normalized(trimmed) != normalized(lastAnalyzedText)
    }

    // MARK: - Tone update
    private func performTextUpdate() {
        let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            lastAnalyzedText = currentText
            lastAnalysisTime = Date()
            suggestions.removeAll()
            currentToneStatus = "neutral"
            DispatchQueue.main.async {
                self.delegate?.didUpdateSuggestions([])
                self.delegate?.didUpdateToneStatus("neutral")
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
                DispatchQueue.main.async {
                    if self.shouldUpdateToneStatus(from: self.currentToneStatus, to: tone) {
                        self.currentToneStatus = tone
                        self.delegate?.didUpdateToneStatus(tone)
                        
                        // Update haptic feedback (throttled to 10 Hz)
                        self.updateHapticFeedback(for: tone)
                    }
                }
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

            // Update tone if present
            if let toneStatus = (d["tone"] as? String)
                ?? (d["toneStatus"] as? String)
                ?? ((d["extras"] as? [String: Any])?["toneStatus"] as? String)
                ?? (d["primaryTone"] as? String) {
                DispatchQueue.main.async {
                    if self.shouldUpdateToneStatus(from: self.currentToneStatus, to: toneStatus) {
                        self.currentToneStatus = toneStatus
                        self.delegate?.didUpdateToneStatus(toneStatus)
                        if let conf = (d["confidence"] as? Double)
                            ?? ((d["extras"] as? [String: Any])?["confidence"] as? Double) {
                            let status = ToneStatus(rawValue: toneStatus) ?? .neutral
                            self.storeToneAnalysisResult(data: d, status: status, confidence: conf)
                        }
                    }
                }
            }

            // Extract ONE suggestion string
            var suggestion: String?
            if let rewrite = d["rewrite"] as? String, !rewrite.isEmpty {
                suggestion = rewrite
            } else if let extras = d["extras"] as? [String: Any],
                      let arr = extras["suggestions"] as? [[String: Any]],
                      let first = arr.first, let text = first["text"] as? String {
                suggestion = text
            } else if let quick = d["quickFixes"] as? [String], let first = quick.first, !first.isEmpty {
                suggestion = first
            } else if let arr = d["suggestions"] as? [[String: Any]],
                      let first = arr.first, let text = first["text"] as? String {
                suggestion = text
            } else if let s = d["general_suggestion"] as? String {
                suggestion = s
            } else if let s = d["suggestion"] as? String {
                suggestion = s
            } else if let dataField = d["data"] as? String {
                suggestion = dataField
            }
            completion(suggestion)
        }
    }

    private func callToneAnalysisAPI(context: [String: Any], completion: @escaping (String?) -> Void) {
        guard isNetworkAvailable, isAPIConfigured, Date() >= netBackoffUntil else { completion(nil); return }

        let requestID = UUID()
        latestRequestID = requestID

        var payload = context
        payload["requestId"] = requestID.uuidString
        payload["userId"] = getUserId()
        payload["userEmail"] = getUserEmail()

        callEndpoint(path: "api/v1/tone", payload: payload) { [weak self] data in
            guard let self else { completion(nil); return }
            guard requestID == self.latestRequestID else { completion(nil); return }

            let d = data ?? [:]
            let detectedTone =
                (d["tone"] as? String)
                ?? (d["primaryTone"] as? String)
                ?? ((d["analysis"] as? [String: Any])?["tone"] as? String)
                ?? ((d["extras"] as? [String: Any])?["tone"] as? String)

            completion(detectedTone)
        }
    }

    // MARK: - Core networking (with cancel, general backoff, off-main serialization)
    private func callEndpoint(path: String, payload: [String: Any], completion: @escaping ([String: Any]?) -> Void) {
        guard isAPIConfigured else { throttledLog("API not configured; skipping \(path)", category: "api"); completion(nil); return }
        if Date() < netBackoffUntil { completion(nil); return }

        let normalized = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let base = apiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: base.hasSuffix("/") ? base + normalized : base + "/" + normalized) else {
            throttledLog("invalid URL for \(normalized)", category: "api"); completion(nil); return
        }

        workQueue.async { [weak self] in
            guard let self else { completion(nil); return }
            var req = URLRequest(url: url, timeoutInterval: 10.0)  // Increased from 5.0
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("Bearer \(self.apiKey)", forHTTPHeaderField: "Authorization")
            
            // CRITICAL: Add user identification headers that server expects
            req.setValue(self.getUserId(), forHTTPHeaderField: "x-user-id")
            if let email = self.getUserEmail() {
                req.setValue(email, forHTTPHeaderField: "x-user-email")
            }

            do {
                req.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])
            } catch {
                self.throttledLog("payload serialization failed: \(error.localizedDescription)", category: "api")
                DispatchQueue.main.async { completion(nil) }
                return
            }

            DispatchQueue.main.async {
                self.inFlightTask?.cancel()  // NEW: cancel previous
                let task = self.session.dataTask(with: req) { data, response, error in
                    if let error = error as NSError? {
                        if error.code == NSURLErrorCancelled { completion(nil); return }
                        self.handleNetworkError(error, url: url)
                        self.consecutiveFailures += 1
                        if self.consecutiveFailures >= 2 {
                            let seconds = min(pow(2.0, Double(self.consecutiveFailures - 1)), 16)
                            let jitter = Double.random(in: 0...0.5)
                            self.netBackoffUntil = Date().addingTimeInterval(seconds + jitter)
                        }
                        completion(nil); return
                    }
                    self.consecutiveFailures = 0
                    self.netBackoffUntil = .distantPast

                    guard let http = response as? HTTPURLResponse else {
                        self.throttledLog("no HTTPURLResponse for \(normalized)", category: "api")
                        completion(nil); return
                    }
                    guard (200..<300).contains(http.statusCode), let data = data else {
                        if http.statusCode == 401 || http.statusCode == 403 {
                            self.authBackoffUntil = Date().addingTimeInterval(60)
                        }
                        #if DEBUG
                        self.throttledLog("HTTP \(http.statusCode) \(normalized)", category: "api")
                        if let d = data, let s = String(data: d, encoding: .utf8) {
                            print("[\(normalized)] body: \(s)")
                        }
                        #endif
                        completion(nil); return
                    }

                    do {
                        let json = try JSONSerialization.jsonObject(with: data, options: [])
                        completion(json as? [String: Any])
                    } catch {
                        self.throttledLog("JSON parse failed: \(error.localizedDescription)", category: "api")
                        completion(nil)
                    }
                }
                self.inFlightTask = task
                task.resume()
            }
        }
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
        if new == current { return false }
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
        if nxt > cur { lastEscalationAt = Date(); return true }
        let dwell: TimeInterval = 3.0
        if current == "alert" || current == "caution" {
            if Date().timeIntervalSince(lastEscalationAt) < dwell { return false }
        }
        if let imp = improvementDetected, imp, (improvementScore ?? 0) > 0.3 { return true }
        if currentText.count + 3 < lastAnalyzedText.count { return true }
        return true
    }

    // MARK: - Offline Fallback
    private func fallbackSuggestion(for text: String) -> String? {
        LightweightSpellChecker.shared.getCapitalizationAndPunctuationSuggestions(for: text).first
    }
    private func fallbackSuggestionForTone(_ tone: String, text: String) -> String? {
        switch tone {
        case "alert":   return "I'd like to discuss this calmly when you have a moment."
        case "caution": return "I want to make sure we're understanding each other correctly."
        case "clear":   return "I appreciate us being able to communicate openly about this."
        default:        return fallbackSuggestion(for: text)
        }
    }

    // MARK: - Storage / Analytics (trimmed)
    private func storeToneAnalysisResult(data: [String: Any], status: ToneStatus, confidence: Double) {
        SafeKeyboardDataStorage.shared.recordToneAnalysis(text: currentText, tone: status, confidence: confidence, analysisTime: 0.0)
        let interaction = KeyboardInteraction(
            timestamp: Date(),
            textBefore: currentText,
            textAfter: currentText,
            toneStatus: status,
            suggestionAccepted: false,
            suggestionText: nil,
            analysisTime: 0.0,
            context: "ml_tone_analysis",
            interactionType: .toneAnalysis,
            userAcceptedSuggestion: false,
            communicationPattern: .neutral,
            attachmentStyleDetected: .unknown,
            relationshipContext: .unknown,
            sentimentScore: 0.0,
            wordCount: currentText.split(separator: " ").count,
            appContext: "keyboard_extension"
        )
        SafeKeyboardDataStorage.shared.recordInteraction(interaction)
    }

    private func storeSuggestionGenerated(suggestion: String) {
        SafeKeyboardDataStorage.shared.recordSuggestionInteraction(suggestion: suggestion, accepted: false, context: "ml_suggestion_generated")
        let interaction = KeyboardInteraction(
            timestamp: Date(),
            textBefore: currentText,
            textAfter: currentText,
            toneStatus: ToneStatus(rawValue: currentToneStatus) ?? .neutral,
            suggestionAccepted: false,
            suggestionText: suggestion,
            analysisTime: 0.0,
            context: "ml_suggestion_generated",
            interactionType: .suggestion,
            userAcceptedSuggestion: false,
            communicationPattern: .neutral,
            attachmentStyleDetected: .unknown,
            relationshipContext: .unknown,
            sentimentScore: 0.0,
            wordCount: currentText.split(separator: " ").count,
            appContext: "keyboard_extension"
        )
        SafeKeyboardDataStorage.shared.recordInteraction(interaction)
    }

    func recordSuggestionAccepted(_ suggestion: String) {
        SafeKeyboardDataStorage.shared.recordSuggestionInteraction(suggestion: suggestion, accepted: true, context: "ml_suggestion_accepted")
        updateCommunicatorProfileWithSuggestion(suggestion, accepted: true)
    }
    func recordSuggestionRejected(_ suggestion: String) {
        SafeKeyboardDataStorage.shared.recordSuggestionInteraction(suggestion: suggestion, accepted: false, context: "ml_suggestion_rejected")
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
        if let toneStr = (analysis["tone_status"] as? String) ?? (analysis["tone"] as? String) {
            DispatchQueue.main.async {
                if self.shouldUpdateToneStatus(from: self.currentToneStatus, to: toneStr) {
                    self.currentToneStatus = toneStr
                    self.delegate?.didUpdateToneStatus(toneStr)
                }
            }
        }
    }
    func updateToneFromAnalysis(_ analysis: [String: Any]) {
        if let toneStr = (analysis["tone_status"] as? String) ?? (analysis["tone"] as? String),
           let _ = ToneStatus(rawValue: toneStr) {
            currentToneStatus = toneStr
            DispatchQueue.main.async { self.delegate?.didUpdateToneStatus(toneStr) }
        }
    }

    // MARK: - Shared storage (trim long fields, no synchronize)
    private func storeAPIResponseInSharedStorage(endpoint: String, request: [String: Any], response: [String: Any]) {
    let sharedDefaults = sharedUserDefaults
        // NEW: clip large fields to keep writes light
        var clipped = response
        if var extras = clipped["extras"] as? [String: Any],
           let longText = extras["longText"] as? String, longText.count > 800 {
            extras["longText"] = String(longText.prefix(800))
            clipped["extras"] = extras
        }

        let timestamp = isoTimestamp()
        let apiData: [String: Any] = [
            "endpoint": endpoint,
            "request": request,
            "response": clipped,
            "timestamp": timestamp,
            "user_id": getUserId(),
            "user_email": getUserEmail() ?? NSNull()
        ]

        sharedDefaults.set(apiData, forKey: "latest_api_\(endpoint)")
        var queue = sharedDefaults.array(forKey: "api_\(endpoint)_queue") as? [[String: Any]] ?? []
        queue.append(apiData)
        if queue.count > 10 { queue.removeFirst(queue.count - 10) }
        sharedDefaults.set(queue, forKey: "api_\(endpoint)_queue")
        throttledLog("Stored API response for \(endpoint)", category: "storage")
    }

    // MARK: - Attachment Style Resolution
    private func resolvedAttachmentStyle() -> (style: String?, provisional: Bool, source: String) {
        // 1) Test Manager
        if personalityBridge.isPersonalityTestComplete() {
            let tested = personalityBridge.getAttachmentStyle()
            if !tested.isEmpty && tested != "secure" { // Don't treat default "secure" as confirmed
                return (tested, false, "test")
            }
        }

        // 2) Backend learner (provisional or confirmed)
    if let learned = sharedUserDefaults.string(forKey: "learner_attachment_style"),
       !learned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let provisional = !personalityBridge.isLearningWindowComplete()
            return (learned, provisional, provisional ? "provisional" : "backend")
        }

        // 3) Bridge default might be "secure"; treat it as unknown unless confirmed
        let bridged = personalityBridge.getAttachmentStyle()
        if personalityBridge.isPersonalityTestComplete() && !bridged.isEmpty {
            return (bridged, false, "bridge")
        }

        // 4) Unknown
        return (nil, true, "unknown")
    }

    // MARK: - Personality payload & communicator observe payload
    private func personalityProfileForAPI() -> [String: Any]? {
        let prof = personalityBridge.getPersonalityProfile()
        let res = resolvedAttachmentStyle()
        let mapped: [String: Any?] = [
            "attachmentStyle": res.style,                 // may be nil
            "communicationStyle": prof["communication_style"] as? String,
            "personalityType": prof["personality_type"] as? String,
            "emotionalState": prof["emotional_state"] as? String,
            "emotionalBucket": prof["emotional_bucket"] as? String,
            "personalityScores": prof["personality_scores"] as? [String: Int],
            "communicationPreferences": prof["communication_preferences"] as? [String: Any],
            "isComplete": prof["is_complete"] as? Bool,
            // NEW metadata helpful for the backend
            "newUser": personalityBridge.isNewUser(),
            "attachmentProvisional": res.provisional,
            "learningDaysRemaining": personalityBridge.learningDaysRemaining()
        ]
        return mapped.compactMapValues { $0 }
    }

    // MARK: - Personality / Shared Data
    private func getAttachmentStyle() -> String { 
        let resolved = resolvedAttachmentStyle()
        return resolved.style ?? "secure" // fallback to secure if unknown
    }
    private func getUserId() -> String {
    return sharedUserDefaults.string(forKey: "user_id")
    ?? sharedUserDefaults.string(forKey: "userId")
    ?? "keyboard_user"
    }
    private func getUserEmail() -> String? {
    return sharedUserDefaults.string(forKey: "user_email")
    ?? sharedUserDefaults.string(forKey: "userEmail")
    }
    private func getEmotionalState() -> String { personalityBridge.getCurrentEmotionalState() }
    
    // MARK: - Haptic Feedback
    /// Update haptic feedback based on tone status (throttled to 10 Hz)
    private func updateHapticFeedback(for toneStatus: String) {
        let now = Date()
        guard now.timeIntervalSince(lastToneUpdateTime) >= toneUpdateThrottle else {
            return // Throttle updates to 10 Hz
        }
        lastToneUpdateTime = now
        
        // TODO: Uncomment when types are resolved
        // Convert string to ToneStatus enum
        // let toneStatusEnum = ToneStatus(rawValue: toneStatus) ?? .neutral
        // let (intensity, sharpness) = UnifiedHapticsController.toneToHaptics(toneStatusEnum)
        // hapticController.applyTone(intensity: intensity, sharpness: sharpness)
    }

    // MARK: - Network monitoring
    private func startNetworkMonitoringSafely() {
    startNetworkMonitoring()
    }
    private func startNetworkMonitoring() {
        guard !didStartMonitoring else { return }
        didStartMonitoring = true
        let monitor = NWPathMonitor()
        networkMonitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let available = (path.status != .unsatisfied)
            if available != self.isNetworkAvailable {
                self.isNetworkAvailable = available
                self.throttledLog("network \(available ? "available" : "unavailable")", category: "network")
            }
        }
        monitor.start(queue: networkQueue)
    }
    private func stopNetworkMonitoring() {
        networkMonitor?.cancel()
        networkMonitor = nil
        didStartMonitoring = false
    }

    // MARK: - Logging (throttled)
    private func throttledLog(_ message: String, category: String = "general") {
        #if DEBUG
        let key = "\(category):\(message)"
        let now = Date()
        if let last = logThrottle[key], now.timeIntervalSince(last) < logThrottleInterval { return }
        logThrottle[key] = now
        logger.debug("[\(category)] \(message)")
        #endif
    }
}

// MARK: - ToneStreamDelegate
extension ToneSuggestionCoordinator {
    func toneStreamDidConnect() {
        isStreamEnabled = true
        throttledLog("tone stream connected", category: "stream")
    }
    
    func toneStreamDidDisconnect() {
        isStreamEnabled = false
        throttledLog("tone stream disconnected", category: "stream")
        
        // Fall back to neutral tone on network loss
        updateHapticFeedback(for: "neutral")
    }
    
    func toneStreamDidReceiveToneUpdate(intensity: Float, sharpness: Float) {
        // Apply real-time haptic updates from WebSocket
        guard isHapticSessionActive else { return }
        
        let now = Date()
        guard now.timeIntervalSince(lastToneUpdateTime) >= toneUpdateThrottle else {
            return // Throttle to 10 Hz
        }
        lastToneUpdateTime = now
        
        // TODO: Uncomment when types are resolved
        // hapticController.applyTone(intensity: intensity, sharpness: sharpness)
        throttledLog("applied stream tone: I=\(String(format: "%.2f", intensity)) S=\(String(format: "%.2f", sharpness))", category: "stream")
    }
}

// MARK: - Helpers
private extension String { var nilIfEmpty: String? { isEmpty ? nil : self } }
