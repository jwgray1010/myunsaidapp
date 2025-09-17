import Foundation
import os.log
import Network
import QuartzCore
#if canImport(UIKit)
import UIKit
#endif

// MARK: - API Error Types
enum APIError: LocalizedError {
    case authRequired
    case paymentRequired
    case serverError(Int)
    case networkError
    case unknown
    
    var errorDescription: String? {
        switch self {
        case .authRequired:       return "Authentication required - please sign in"
        case .paymentRequired:    return "Trial expired - subscription required"
        case .serverError(let c): return "Server error: \(c)"
        case .networkError:       return "Network connection error"
        case .unknown:            return "Unknown error occurred"
        }
    }
    
    var recoverySuggestion: String? {
        switch self {
        case .authRequired:     return "Please sign in to continue using AI features"
        case .paymentRequired:  return "Subscribe to Unsaid Premium to continue using AI coaching"
        case .serverError:      return "Please try again later"
        case .networkError:     return "Check your internet connection and try again"
        case .unknown:          return "Please try again"
        }
    }
}

// MARK: - Delegate Protocol
@MainActor
protocol ToneSuggestionDelegate: AnyObject {
    func didUpdateSuggestions(_ suggestions: [String])
    func didUpdateToneStatus(_ tone: String)  // "clear" | "caution" | "alert" | "neutral"
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
    // MARK: Public
    weak var delegate: ToneSuggestionDelegate?
    
    // MARK: - Circuit Breaker (used for suggestions/observe)
    private struct CircuitKey: Hashable { let host: String; let path: String }
    private var circuitBreakers: [CircuitKey: Date] = [:]
    private var breakerOpen: Set<CircuitKey> = []
    private func setBreaker(_ key: CircuitKey, open: Bool) {
        if open {
            if breakerOpen.insert(key).inserted { throttledLog("🚨 CB OPEN \(key.path)", category: "breaker") }
        } else {
            if breakerOpen.remove(key) != nil { throttledLog("✅ CB CLOSE \(key.path)", category: "breaker") }
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
    private func isoTimestamp() -> String { Self.iso8601.string(from: Date()) }
    
    // MARK: - URL normalization helper (for suggestions/observe)
    private func normalizedBaseURLString() -> String {
        let raw = apiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        var s = raw.hasSuffix("/") ? String(raw.dropLast()) : raw
        let lowers = s.lowercased()
        if lowers.hasSuffix("/api/v1") { s = String(s.dropLast(7)) }
        else if lowers.hasSuffix("/api") { s = String(s.dropLast(4)) }
        return s // e.g. https://yourapp.vercel.app
    }
    
    // MARK: - Idempotency helper (for suggestions/observe)
    private func contentHash(for path: String, payload: [String: Any]) -> String {
        var hashableContent = path
        if let text = payload["text"] as? String { hashableContent += text }
        if let context = payload["context"] as? String { hashableContent += context }
        if let toneOverride = payload["toneOverride"] as? String { hashableContent += toneOverride }
        return String(hashableContent.hash)
    }
    
    // MARK: Configuration
    private var apiBaseURL: String { cachedAPIBaseURL }
    private var apiKey: String { cachedAPIKey }
    private var isAPIConfigured: Bool {
        if Date() < authBackoffUntil {
            print("🔴 API blocked due to auth backoff until \(authBackoffUntil)")
            return false
        }
        let configured = !apiBaseURL.isEmpty && !apiKey.isEmpty
        print("🔧 API configured: \(configured) - URL: '\(apiBaseURL)', Key: '\(apiKey.prefix(10))...'")
        return configured
    }
    
    // MARK: Networking (used only by suggestions/observe)
    private lazy var session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.waitsForConnectivity = false
        cfg.allowsCellularAccess = true
        cfg.allowsConstrainedNetworkAccess = true
        cfg.allowsExpensiveNetworkAccess = true
        cfg.httpShouldUsePipelining = true
        cfg.httpMaximumConnectionsPerHost = 2
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.timeoutIntervalForRequest = 10.0
        cfg.timeoutIntervalForResource = 30.0
        cfg.httpCookieAcceptPolicy = .never
        cfg.httpCookieStorage = nil
        cfg.httpAdditionalHeaders = [
            "Accept": "application/json",
            "Accept-Encoding": "gzip",
            "Cache-Control": "no-cache"
        ]
        return URLSession(configuration: cfg)
    }()
    private var inFlightTask: URLSessionDataTask?
    
    // MARK: - Queue / Debounce (for suggestions only)
    private let workQueue = DispatchQueue(label: "com.unsaid.coordinator", qos: .utility)
    private var pendingWorkItem: DispatchWorkItem?
    private let debounceInterval: TimeInterval = 0.2
    private let workQueueKey = DispatchSpecificKey<Bool>()
    private func setupWorkQueueIdentification() { workQueue.setSpecific(key: workQueueKey, value: true) }
    private func onQ(_ block: @escaping () -> Void) {
        if DispatchQueue.getSpecific(key: workQueueKey) != nil { block() }
        else { workQueue.async(execute: block) }
    }
    
    // MARK: - Network Monitoring (minimal stub)
    private var networkMonitor: NWPathMonitor?
    private let networkQueue = DispatchQueue(label: "com.unsaid.network", qos: .utility)
    private(set) var isNetworkAvailable: Bool = true
    private var didStartMonitoring = false
    
    // MARK: - State
    private var currentText: String = ""
    private var suggestions: [String] = []
    
    // Sentence-aware tone state (NEW system)
    private var sentenceTracker = SentenceTracker()
    private var lastUiTone: Bucket = .neutral
    private var smoothedBuckets: (clear: Double, caution: Double, alert: Double) = (0.33, 0.33, 0.34)
    private var pendingAnalysisTask: Task<Void, Never>?
    private let newSystemDebounceInterval: TimeInterval = 0.2
    var onToneUpdate: ((Bucket, Bool) -> Void)?
    
    // Suggestions helpers
    private var suggestionSnapshot: String?
    private let allowedSuggestionFeatures: Set<String> = ["advice", "quick_fixes", "evidence", "emotional_support", "context_analysis"]
    private var suggestionsInFlight = false
    private var lastSuggestionsAt: Date = .distantPast
    private let suggestionTapCooldown: TimeInterval = 0.6
    
    // Request Mgmt / Backoff / Client Sequence (for suggestions/observe)
    private var latestRequestID = UUID()
    private var clientSequence: UInt64 = 0
    private var pendingClientSeq: UInt64 = 0
    private var authBackoffUntil: Date = .distantPast
    private var netBackoffUntil: Date = .distantPast
    private var inFlightRequests: [String: URLSessionDataTask] = [:]
    private var requestCompletionTimes: [String: Date] = [:]
    private func cacheTTL(for path: String) -> TimeInterval {
        switch path {
        case "/api/v1/suggestions": return 5.0
        case "/api/v1/communicator": return 10.0
        default: return 5.0
        }
    }
    
    // Shared Defaults & Persona
    private let sharedUserDefaults: UserDefaults = UserDefaults.standard
    private var cachedPersona: [String: Any] = [:]
    private var cachedPersonaAt: Date = .distantPast
    private let personaTTL: TimeInterval = 10 * 60
    
    // Logging & Haptics
    private let logger = Logger(subsystem: "com.example.unsaid.unsaid.UnsaidKeyboard", category: "ToneSuggestionCoordinator")
    private let netLog = OSLog(subsystem: Bundle.main.bundleIdentifier ?? "UnsaidKeyboard", category: "Network")
    private let hapticController: Any? = nil
    private var isHapticSessionActive = false
    
    // MARK: - Headers Helper (for suggestions/observe)
    private func setEssentialHeaders(on request: inout URLRequest, clientSeq: UInt64) {
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(self.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(getUserId(), forHTTPHeaderField: "x-user-id")
        request.setValue("\(clientSeq)", forHTTPHeaderField: "x-client-seq")
    }
    
    // MARK: - API Config & Debug
    func dumpAPIConfig() {
        let base = Bundle.main.object(forInfoDictionaryKey: "UNSAID_API_BASE_URL") as? String ?? "<missing>"
        let key  = Bundle.main.object(forInfoDictionaryKey: "UNSAID_API_KEY") as? String ?? "<missing>"
        os_log("🔧 API Config - Base URL: %{public}@, Key prefix: %{public}@", log: netLog, type: .info, base, String(key.prefix(8)))
    }
    
    func debugPing() {
        logger.info("🔥 Debug ping triggered")
        debugPingAll()
    }
    
    func debugPingAll() {
        print("🔧 normalized base:", normalizedBaseURLString())
        print("🔧 suggestions:", normalizedBaseURLString() + "/api/v1/suggestions")
        print("🔧 communicator:", normalizedBaseURLString() + "/api/v1/communicator")
        print("🔧 tone:", normalizedBaseURLString() + "/api/v1/tone")
        dumpAPIConfig()
        
        // Test a sample suggestion request to verify endpoints work
        let testPayload: [String: Any] = [
            "text": "Hello test",
            "context": "general"
        ]
        print("🔧 Testing suggestions endpoint...")
        callEndpoint(path: "api/v1/suggestions", payload: testPayload) { result in
            if result != nil {
                print("✅ Suggestions endpoint responded")
            } else {
                print("❌ Suggestions endpoint failed")
            }
        }
    }
    
    private func checkBackoffStatus() {
        let currentTextTrimmed = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !currentTextTrimmed.isEmpty {
            Task { @MainActor in
                self.onTextChanged(fullText: currentTextTrimmed, lastInserted: nil, isDeletion: false)
            }
        }
    }
    
    // MARK: - Init/Deinit
    init() {
        setupWorkQueueIdentification()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.startNetworkMonitoringSafely() }
        #if DEBUG
        debugPrint("🧠 Personality Data Bridge Status:")
        debugPrint(" - Attachment Style: '\(getAttachmentStyle())'")
        debugPrint(" - Emotional State: '\(getEmotionalState())'")
        #endif
    }
    
    deinit {
        print("🗑️ ToneSuggestionCoordinator deinit - cleaning up resources")
        pendingWorkItem?.cancel()
        inFlightTask?.cancel()
        stopNetworkMonitoring()
        print("✅ ToneSuggestionCoordinator cleanup complete")
    }
    
    // MARK: - Public API
    func analyzeFinalSentence(_ sentence: String) {
        Task { @MainActor in
            self.onTextChanged(fullText: sentence, lastInserted: nil, isDeletion: false)
        }
    }
    
    func startHapticSession() {
        guard !isHapticSessionActive else { return }
        isHapticSessionActive = true
        // start haptics if needed
    }
    
    func stopHapticSession() {
        guard isHapticSessionActive else { return }
        isHapticSessionActive = false
        // stop haptics if needed
    }
    
    // MARK: - Suggestions (no tone side-effects)
    private func cancelInFlightRequestsForCurrentField() {
        // Keeping per-field map to maintain existing calling semantics
        let key = "default"
        if let task = pendingRequests[key] {
            task.cancel()
            pendingRequests.removeValue(forKey: key)
            throttledLog("cancelled in-flight request for field: \(key)", category: "api")
        }
    }
    private var pendingRequests: [String: URLSessionDataTask] = [:]
    
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
    
    func fetchSuggestions(for text: String, completion: @escaping ([String]?) -> Void) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            completion(nil); return
        }
        let now = Date()
        if suggestionsInFlight || now.timeIntervalSince(lastSuggestionsAt) < suggestionTapCooldown {
            completion(nil); return
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
            "features": ["advice", "evidence"],
            "meta": [
                "source": "keyboard_tone_button",
                "request_type": "suggestion",
                "context": "general",
                "timestamp": isoTimestamp()
            ]
        ]
        context.merge(personalityPayload()) { _, new in new }
        
        callSuggestionsAPI(context: context, usingSnapshot: textToAnalyze) { [weak self] suggestion in
            self?.suggestionsInFlight = false
            if let s = suggestion, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                completion([s])
            } else {
                completion(nil)
            }
        }
    }
    
    func acceptSuggestion(_ suggestion: String, completion: (() -> Void)? = nil) {
        onQ {
            self.storeSuggestionAccepted(suggestion: suggestion)
            self.suggestions = []
            DispatchQueue.main.async {
                self.delegate?.didUpdateSuggestions([])
                self.delegate?.didUpdateSecureFixButtonState()
                completion?()
            }
        }
    }
    
    func resetToCleanState() {
        onQ {
            self.currentText = ""
            self.suggestions = []
            DispatchQueue.main.async {
                self.delegate?.didUpdateSuggestions([])
                self.delegate?.didUpdateSecureFixButtonState()
            }
        }
    }
    
    // MARK: - Suggestion Generation
    private func generatePerfectSuggestion(from snapshot: String = "") {
        var textToAnalyze = snapshot.isEmpty ? currentText : snapshot
        if textToAnalyze.count > 1000 { textToAnalyze = String(textToAnalyze.suffix(1000)) }
        
        var context: [String: Any] = [
            "text": textToAnalyze,
            "userId": getUserId(),
            "userEmail": getUserEmail() ?? NSNull(),
            "features": ["advice", "evidence"],
            "meta": [
                "source": "keyboard_manual",
                "request_type": "suggestion",
                "context": "general",
                "timestamp": isoTimestamp()
            ]
        ]
        context.merge(personalityPayload()) { _, new in new }
        
        callSuggestionsAPI(context: context, usingSnapshot: textToAnalyze) { [weak self] suggestion in
            guard let self else { return }
            DispatchQueue.main.async {
                if let s = suggestion, !s.isEmpty {
                    self.suggestions = [s]
                    self.delegate?.didUpdateSuggestions(self.suggestions)
                    self.delegate?.didUpdateSecureFixButtonState()
                    self.storeSuggestionGenerated(suggestion: s)
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
            "features": ["advice"],
            "meta": [
                "source": "keyboard_tone_specific",
                "requested_tone": tone,
                "context": "general",
                "timestamp": isoTimestamp(),
                "emotionalIndicators": getEmotionalIndicatorsForTone(tone),
                "communicationStyle": getCommunicationStyleForTone(tone)
            ]
        ]
        context.merge(personalityPayload()) { _, new in new }
        
        callSuggestionsAPI(context: context, usingSnapshot: textToAnalyze) { [weak self] suggestion in
            guard let self else { return }
            DispatchQueue.main.async {
                if let s = suggestion, !s.isEmpty {
                    self.suggestions = [s]
                    self.delegate?.didUpdateSuggestions([s])
                    self.delegate?.didUpdateSecureFixButtonState()
                    self.storeSuggestionGenerated(suggestion: s)
                } else {
                    self.suggestions = []
                    self.delegate?.didUpdateSuggestions([])
                    self.delegate?.didUpdateSecureFixButtonState()
                }
            }
        }
    }
    
    // MARK: - Suggestions API (tone side-effects removed)
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
        
        var safePayload = payload
        if var feats = safePayload["features"] as? [String] {
            feats = feats.filter { allowedSuggestionFeatures.contains($0) }
            safePayload["features"] = Array(Set(feats))
        }
        throttledLog("suggestions features: \((safePayload["features"] as? [String])?.joined(separator: ",") ?? "<none>")", category: "api")
        
        callEndpoint(path: "api/v1/suggestions", payload: safePayload) { [weak self] data in
            guard let self else { completion(nil); return }
            guard requestID == self.latestRequestID else { completion(nil); return }
            
            let root = data ?? [:]
            let body: [String: Any] = (root["data"] as? [String: Any]) ?? root
            
            if !root.isEmpty {
                self.storeAPIResponseInSharedStorage(endpoint: "suggestions", request: payload, response: root)
            }
            let suggestion = extractSuggestionSafely(from: body)
            completion(suggestion)
        }
    }
    
    private func extractSuggestionSafely(from dict: [String: Any]) -> String? {
        if let arr = dict["suggestions"] as? [[String: Any]], let first = arr.first {
            let t = safeString(from: first, keys: ["text", "message", "advice"])
            if !t.isEmpty { return t }
        }
        if let fixes = dict["quickFixes"] as? [String], let first = fixes.first, !first.isEmpty { return first }
        let advice = safeString(from: dict, keys: ["advice", "tip", "suggestion", "general_suggestion"])
        if !advice.isEmpty { return advice }
        if let extras = dict["extras"] as? [String: Any],
           let arr = extras["suggestions"] as? [[String: Any]],
           let first = arr.first {
            let t = safeString(from: first, keys: ["text"])
            if !t.isEmpty { return t }
        }
        if let s = dict["data"] as? String, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return s }
        return nil
    }
    
    // MARK: - Core networking for suggestions/observe
    private func callEndpoint(path: String, payload: [String: Any], completion: @escaping ([String: Any]?) -> Void) {
        guard isAPIConfigured else { throttledLog("API not configured; skipping \(path)", category: "api"); completion(nil); return }
        guard isNetworkAvailable else { throttledLog("Network unavailable; skipping \(path)", category: "api"); completion(nil); return }
        if Date() < netBackoffUntil { throttledLog("network backoff active; skipping \(path)", category: "api"); completion(nil); return }
        
        let requestHash = contentHash(for: path, payload: payload)
        let now = Date()
        let ttl = cacheTTL(for: path)
        
        onQ {
            let cutoff = now.addingTimeInterval(-ttl)
            self.requestCompletionTimes = self.requestCompletionTimes.filter { $0.value > cutoff }
        }
        if let lastCompletion = requestCompletionTimes[requestHash], now.timeIntervalSince(lastCompletion) < ttl {
            throttledLog("Skipping duplicate request within \(ttl)s cache window", category: "api")
            completion(nil); return
        }
        if let existingTask = inFlightRequests[requestHash], existingTask.state == .running {
            throttledLog("Skipping duplicate in-flight request", category: "api")
            completion(nil); return
        }
        
        let normalized = path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).replacingOccurrences(of: "//", with: "/")
        let circuitKey = CircuitKey(host: normalizedBaseURLString(), path: normalized)
        if let breakerUntil = circuitBreakers[circuitKey], Date() < breakerUntil {
            if !breakerOpen.contains(circuitKey) { setBreaker(circuitKey, open: true) }
            completion(nil); return
        }
        let allowed = Set(["api/v1/suggestions", "api/v1/communicator"])
        guard allowed.contains(normalized) else {
            throttledLog("invalid endpoint \(normalized); expected one of \(allowed)", category: "api")
            completion(nil); return
        }
        
        let origin = normalizedBaseURLString()
        guard !origin.isEmpty, origin.contains("://") else { throttledLog("invalid base URL '\(origin)'", category: "api"); completion(nil); return }
        guard let url = URL(string: origin + "/" + normalized) else {
            throttledLog("failed to construct URL from origin: '\(origin)', path: '\(normalized)'", category: "api")
            completion(nil); return
        }
        throttledLog("🔧 REQUEST \(url.absoluteString)", category: "api")
        guard url.scheme == "http" || url.scheme == "https" else { throttledLog("unsupported URL scheme", category: "api"); completion(nil); return }
        
        workQueue.async { [weak self] in
            guard let self else { completion(nil); return }
            let currentClientSeq = self.clientSequence
            self.clientSequence += 1
            
            let startTime = Date()
            let inputLength = (payload["text"] as? String)?.count ?? 0
            
            var req = URLRequest(url: url, timeoutInterval: 10.0)
            req.httpMethod = "POST"
            self.setEssentialHeaders(on: &req, clientSeq: currentClientSeq)
            
            var enhancedPayload = payload
            enhancedPayload["client_seq"] = currentClientSeq
            enhancedPayload["input_length"] = inputLength
            enhancedPayload["timestamp"] = self.isoTimestamp()
            
            do {
                req.httpBody = try JSONSerialization.data(withJSONObject: enhancedPayload, options: [])
            } catch {
                self.throttledLog("payload serialization failed: \(error.localizedDescription)", category: "api")
                DispatchQueue.main.async { completion(nil) }
                return
            }
            
            DispatchQueue.main.async {
                self.cancelInFlightRequestsForCurrentField()
                let task = self.session.dataTask(with: req) { data, response, error in
                    let _ = Date().timeIntervalSince(startTime) * 1000  // latency measurement
                    self.onQ { self.inFlightRequests.removeValue(forKey: requestHash) }
                    
                    if let error = error as NSError? {
                        if error.code == NSURLErrorCancelled { completion(nil); return }
                        self.handleNetworkError(error, url: url)
                        // Basic backoff
                        self.netBackoffUntil = Date().addingTimeInterval(2.0)
                        completion(nil); return
                    }
                    self.netBackoffUntil = .distantPast
                    
                    guard let http = response as? HTTPURLResponse else {
                        self.throttledLog("no HTTPURLResponse for \(normalized)", category: "api")
                        completion(nil); return
                    }
                    
                    guard (200..<300).contains(http.statusCode), let data = data else {
                        switch http.statusCode {
                        case 401:
                            Task { @MainActor in self.delegate?.didReceiveAPIError(.authRequired) }
                            completion(nil); return
                        case 402:
                            Task { @MainActor in self.delegate?.didReceiveAPIError(.paymentRequired) }
                            completion(nil); return
                        case 404:
                            break
                        default: break
                        }
                        self.throttledLog("HTTP \(http.statusCode) \(normalized)", category: "api")
                        completion(nil); return
                    }
                    
                    if self.circuitBreakers[circuitKey] != nil {
                        self.circuitBreakers.removeValue(forKey: circuitKey)
                        self.setBreaker(circuitKey, open: false)
                    }
                    
                    let contentType = http.allHeaderFields["Content-Type"] as? String ?? ""
                    if !contentType.lowercased().contains("application/json") {
                        if let bodyString = String(data: data, encoding: .utf8) {
                            self.throttledLog("Non-JSON response (\(contentType)): \(bodyString.prefix(200))", category: "api")
                        }
                        completion(nil); return
                    }
                    
                    do {
                        let json = try JSONSerialization.jsonObject(with: data, options: [])
                        guard let responseDict = json as? [String: Any] else {
                            self.throttledLog("Response is not a dictionary", category: "api")
                            completion(nil); return
                        }
                        let responseClientSeq = (responseDict["client_seq"] as? NSNumber)?.uint64Value ?? currentClientSeq
                        self.onQ {
                            guard responseClientSeq >= self.pendingClientSeq else {
                                self.throttledLog("Discarding stale response (seq: \(responseClientSeq) < \(self.pendingClientSeq))", category: "api")
                                DispatchQueue.main.async { completion(nil) }
                                return
                            }
                            guard responseClientSeq <= self.clientSequence else {
                                self.throttledLog("Discarding out-of-bounds response", category: "api")
                                DispatchQueue.main.async { completion(nil) }
                                return
                            }
                            self.pendingClientSeq = responseClientSeq
                            self.requestCompletionTimes[requestHash] = Date()
                            DispatchQueue.main.async { completion(responseDict) }
                        }
                    } catch {
                        let bodyString = String(data: data, encoding: .utf8) ?? "<non-UTF8>"
                        self.throttledLog("JSON decode failed: \(error.localizedDescription). Body: \(bodyString.prefix(200))", category: "api")
                        completion(nil)
                    }
                }
                self.pendingRequests["default"] = task
                self.onQ { self.inFlightRequests[requestHash] = task }
                
                // Debug logging before starting the request
                print("🌐 \(req.httpMethod ?? "POST") \(req.url!.absoluteString)")
                print("🌐 Headers:", req.allHTTPHeaderFields ?? [:])
                if let body = req.httpBody { 
                    print("🌐 Body:", String(data: body, encoding: .utf8) ?? "<non-utf8>") 
                }
                
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
    
    // MARK: - Personality payload (cached)
    private func personalityPayload() -> [String: Any] {
        let now = Date()
        if now.timeIntervalSince(cachedPersonaAt) < personaTTL, !cachedPersona.isEmpty {
            return cachedPersona
        }
        let profile = personalityProfileForAPI() ?? [:]
        let resolved = resolvedAttachmentStyle()
        var metaDict: [String: Any] = [:]
        metaDict["emotional_state"] = profile["emotionalState"] ?? "neutral"
        metaDict["communication_style"] = profile["communicationStyle"] ?? "direct"
        metaDict["emotional_bucket"] = profile["emotionalBucket"] ?? "moderate"
        metaDict["personality_type"] = profile["personalityType"] ?? "unknown"
        metaDict["new_user"] = profile["newUser"] ?? false
        metaDict["attachment_provisional"] = profile["attachmentProvisional"] ?? false
        metaDict["learning_days_remaining"] = profile["learningDaysRemaining"] ?? 0
        metaDict["attachment_source"] = resolved.source
        
        var payload: [String: Any] = [
            "attachmentStyle": resolved.style ?? "secure",
            "meta": metaDict,
            "context": "general",
            "user_profile": profile
        ]
        // Optional: if you still want to pass current tone to suggestions, mirror lastUiTone:
        let toneString = lastUiTone.rawValue
        if toneString != "neutral" { payload["toneOverride"] = toneString }
        
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
        
        callEndpoint(path: "api/v1/communicator", payload: payload) { [weak self] _ in
            self?.throttledLog("communicator profile updated", category: "learning")
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
        
        callEndpoint(path: "api/v1/communicator", payload: payload) { [weak self] _ in
            self?.throttledLog("communicator learned from accepted suggestion", category: "learning")
        }
    }
    
    // MARK: - Misc helpers / stubs
    private func personalityProfileForAPI() -> [String: Any]? { return [:] }
    private func resolvedAttachmentStyle() -> (style: String?, provisional: Bool, source: String) { ("secure", false, "default") }
    private func getAttachmentStyle() -> String { "secure" }
    private func getEmotionalState() -> String { "neutral" }
    private func getUserId() -> String {
        let userIdKey = "unsaid_user_id"
        let appGroupId = "group.com.example.unsaid"
        if let sharedDefaults = UserDefaults(suiteName: appGroupId),
           let userId = sharedDefaults.string(forKey: userIdKey) { return userId }
        let fallbackId = UUID().uuidString
        if let sharedDefaults = UserDefaults(suiteName: appGroupId) { sharedDefaults.set(fallbackId, forKey: userIdKey) }
        return fallbackId
    }
    private func getUserEmail() -> String? { nil }
    private func throttledLog(_ message: String, category: String) { print("[\(category)] \(message)") }
    private func startNetworkMonitoringSafely() { /* stub */ }
    private func stopNetworkMonitoring() { /* stub */ }
    private func storeSuggestionAccepted(suggestion: String) { /* stub */ }
    private func storeSuggestionGenerated(suggestion: String) { /* stub */ }
    private func storeAPIResponseInSharedStorage(endpoint: String, request: [String: Any], response: [String: Any]) { /* stub */ }
    private func safeString(from dict: [String: Any], keys: [String], fallback: String = "") -> String {
        for key in keys { if let v = dict[key] as? String, !v.isEmpty { return v } }
        return fallback
    }
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
    
    // MARK: - Text & History
    private func updateCurrentText(_ text: String) {
        let maxLen = 1000
        let trimmed = text.count > maxLen ? String(text.suffix(maxLen)) : text
        onQ { self.currentText = trimmed }
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
        if !current.isEmpty { history.append(["sender": "user", "text": current, "timestamp": now]) }
        if history.count > 20 { history = Array(history.suffix(20)) }
        return history
    }
    
    // MARK: - Debug
    #if DEBUG
    func setupSentenceAwareSystem() {
        onToneUpdate = { [weak self] bucket, hasChanged in
            guard hasChanged else { return }
            let toneString = bucket.rawValue
            Task { @MainActor in self?.delegate?.didUpdateToneStatus(toneString) }
        }
        logger.info("🎯 Sentence-aware tone system initialized")
    }
    
    func testToneAPIWithDebugText() {
        throttledLog("🧪 Testing tone API with debug text", category: "test")
        let testText = "I'm so frustrated with this situation"
        updateCurrentText(testText)
        Task { @MainActor in self.onTextChanged(fullText: testText, lastInserted: " ", isDeletion: false) }
    }
    #endif
}

// MARK: - Sentence-Aware Tone Coordination (New System)
extension ToneSuggestionCoordinator {
    enum Bucket: String, CaseIterable { case clear, caution, alert, neutral }
    enum TriggerReason { case wordEdge, timeoutEdge, sentenceFinalized, deleteEdge, none }
    
    private class SentenceTracker {
        private var lastTriggerTime: Date = .distantPast
        private let triggerTimeout: TimeInterval = 0.6
        private let sentenceEnders = CharacterSet(charactersIn: ".?!\n")
        private var prevFullText: String = ""
        private(set) var currentSentence: String = ""
        
        func update(fullText: String, lastInserted: Character?, isDeletion: Bool) -> TriggerReason {
            defer { prevFullText = fullText }
            let now = Date()
            
            let segments = fullText.components(separatedBy: sentenceEnders)
            let tailSentence = segments.last?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let wasTail = currentSentence
            currentSentence = tailSentence
            
            if let last = lastInserted {
                if sentenceEnders.contains(last.unicodeScalars.first!) {
                    if tailSentence.isEmpty {
                        lastTriggerTime = now
                        return .sentenceFinalized
                    }
                }
                if last == " " && fullText.hasSuffix("  ") {
                    lastTriggerTime = now
                    return .sentenceFinalized
                }
                if last == " " {
                    lastTriggerTime = now
                    return .wordEdge
                }
            }
            
            if isDeletion {
                let removedEnder = prevFullText.last.map { sentenceEnders.contains($0.unicodeScalars.first!) } ?? false
                if removedEnder { lastTriggerTime = now; return .deleteEdge }
                let crossedWordBoundary =
                    (wasTail.count > tailSentence.count && (wasTail.last == " " || tailSentence.last == " ")) ||
                    (prevFullText.hasSuffix(" ") && !fullText.hasSuffix(" "))
                if crossedWordBoundary { lastTriggerTime = now; return .deleteEdge }
            }
            
            if !tailSentence.isEmpty && now.timeIntervalSince(lastTriggerTime) >= triggerTimeout {
                lastTriggerTime = now
                return .timeoutEdge
            }
            return .none
        }
    }
    
    @MainActor
    func onTextChanged(fullText: String, lastInserted: Character?, isDeletion: Bool = false) {
        // Keep currentText in sync for suggestions
        updateCurrentText(fullText)
        
        let trigger = sentenceTracker.update(fullText: fullText, lastInserted: lastInserted, isDeletion: isDeletion)
        switch trigger {
        case .sentenceFinalized:
            flushAnalyze(sentenceTracker.currentSentence)
        case .wordEdge, .timeoutEdge, .deleteEdge:
            scheduleAnalyze(sentenceTracker.currentSentence)
        case .none:
            break
        }
    }
    
    private func scheduleAnalyze(_ sentence: String) {
        pendingAnalysisTask?.cancel()
        pendingAnalysisTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((self?.newSystemDebounceInterval ?? 0.2) * 1_000_000_000))
            if !Task.isCancelled { await self?.analyze(sentence) }
        }
    }
    
    private func flushAnalyze(_ sentence: String) {
        pendingAnalysisTask?.cancel()
        Task { [weak self] in await self?.analyze(sentence) }
    }
    
    private func analyze(_ sentence: String) async {
        let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let apiBase = cachedAPIBaseURL.nilIfEmpty else { return }
        do {
            let toneOut = try await postTone(base: apiBase, text: trimmed, token: cachedAPIKey.nilIfEmpty)
            let newBuckets = (
                clear: toneOut.buckets["clear"] ?? 0.33,
                caution: toneOut.buckets["caution"] ?? 0.33,
                alert: toneOut.buckets["alert"] ?? 0.34
            )
            let newTone = pickUiTone(newBuckets, current: lastUiTone)
            let isSeverityDrop = severityRank(for: newTone) < severityRank(for: lastUiTone)
            let alpha = isSeverityDrop ? 0.50 : 0.30
            smoothedBuckets = smoothBuckets(prev: smoothedBuckets, curr: newBuckets, alpha: alpha)
            let finalTone = pickUiTone(smoothedBuckets, current: lastUiTone)
            await MainActor.run { maybeUpdateIndicator(to: finalTone) }
        } catch {
            logger.info("🎯 Analysis failed, retaining current tone: \(error.localizedDescription)")
        }
    }
    
    private func smoothBuckets(
        prev: (clear: Double, caution: Double, alert: Double),
        curr: (clear: Double, caution: Double, alert: Double),
        alpha: Double = 0.30
    ) -> (clear: Double, caution: Double, alert: Double) {
        (
            clear: alpha * curr.clear + (1 - alpha) * prev.clear,
            caution: alpha * curr.caution + (1 - alpha) * prev.caution,
            alert: alpha * curr.alert + (1 - alpha) * prev.alert
        )
    }
    
    private func severityRank(for bucket: Bucket) -> Int {
        switch bucket {
        case .clear: return 0
        case .caution: return 1
        case .alert: return 2
        case .neutral: return -1
        }
    }
    
    private func pickUiTone(
        _ buckets: (clear: Double, caution: Double, alert: Double),
        current: Bucket? = nil,
        threshold: Double = 0.45,
        flipMarginUp: Double = 0.05,
        flipMarginDown: Double = 0.0
    ) -> Bucket {
        let current = current ?? lastUiTone
        let scores: [(Bucket, Double)] = [(.clear, buckets.clear), (.caution, buckets.caution), (.alert, buckets.alert)]
        let (topTone, topValue) = scores.max(by: { $0.1 < $1.1 })!
        if topValue < threshold { return .neutral }
        guard current != .neutral, let currentValue = scores.first(where: { $0.0 == current })?.1 else { return topTone }
        let order: [Bucket] = [.clear, .caution, .alert]
        let isUpgrade = (order.firstIndex(of: topTone) ?? 0) > (order.firstIndex(of: current) ?? 0)
        let marginNeeded = isUpgrade ? flipMarginUp : flipMarginDown
        return (topValue - currentValue) >= marginNeeded ? topTone : current
    }
    
    @MainActor
    private func maybeUpdateIndicator(to newTone: Bucket) {
        guard newTone != lastUiTone else { return }
        lastUiTone = newTone
        onToneUpdate?(newTone, true)
        logger.info("🎯 Sentence-aware tone update: \(newTone.rawValue)")
    }
    
    // MARK: - API Helper for Tone
    private struct ToneOut: Decodable { let buckets: [String: Double] }
    
    private func postTone(base: String, text: String, token: String?) async throws -> ToneOut {
        let origin = normalizedBaseURLString()  // Use the normalizer to prevent doubled paths
        let url = URL(string: "\(origin)/api/v1/tone")!
        print("🎯 TONE URL: \(url.absoluteString)")
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = token?.nilIfEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        request.setValue(getUserId(), forHTTPHeaderField: "x-user-id")
        
        // Include context and client_seq to match schema/handler expectations
        let body: [String: Any] = [
            "text": text,
            "context": "general",
            "client_seq": clientSequence
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, 200...299 ~= httpResponse.statusCode else {
            throw URLError(.badServerResponse)
        }
        if let direct = try? JSONDecoder().decode(ToneOut.self, from: data) { return direct }
        struct Wrapped: Decodable { let data: ToneOut }
        if let wrapped = try? JSONDecoder().decode(Wrapped.self, from: data) { return wrapped.data }
        struct UI: Decodable { let ui_distribution: [String: Double]?; let buckets: [String: Double]? }
        let ui = try JSONDecoder().decode(UI.self, from: data)
        return ToneOut(buckets: ui.ui_distribution ?? ui.buckets ?? [:])
    }
}

// MARK: - Helpers
private extension String { var nilIfEmpty: String? { isEmpty ? nil : self } }
