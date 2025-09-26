import Foundation
import os.log
import Network
import QuartzCore
import CryptoKit
#if canImport(UIKit)
import UIKit
#endif


// MARK: - Tone Suggestion Dispatcher Protocol
protocol ToneSuggestionDispatcher: AnyObject {
    func requestToneSuggestions(text: String, threadID: String)
}

// MARK: - Network Metrics Delegate for Debugging
final class NetworkMetricsDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didFinishCollecting metrics: URLSessionTaskMetrics) {
        #if DEBUG
        for tm in metrics.transactionMetrics {
            // Calculate durations using date intervals
            let dns = tm.domainLookupEndDate?.timeIntervalSince(tm.domainLookupStartDate ?? Date()) ?? 0
            let connect = tm.connectEndDate?.timeIntervalSince(tm.connectStartDate ?? Date()) ?? 0
            let tls = tm.secureConnectionEndDate?.timeIntervalSince(tm.secureConnectionStartDate ?? Date()) ?? 0
            let ttfb = tm.responseStartDate?.timeIntervalSince(tm.requestStartDate ?? Date()) ?? 0
            
            print("⏱ Network Metrics - dns=\(String(format: "%.3f", dns))s connect=\(String(format: "%.3f", connect))s tls=\(String(format: "%.3f", tls))s ttfb=\(String(format: "%.3f", ttfb))s")
            
            if tls > 2.0 {
                print("🔴 TLS handshake took \(String(format: "%.3f", tls))s - possible ATS/cert issue")
            }
            if connect > 3.0 {
                print("🔴 Connect took \(String(format: "%.3f", connect))s - possible network/VPN filtering")
            }
        }
        #endif
    }
}

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
    func didReceiveFeatureNoticings(_ noticings: [String])
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
    
    #if DEBUG
    var debugInstanceId: String = ""
    private let coordLog = Logger(subsystem: "com.example.unsaid.UnsaidKeyboard", category: "Coordinator")
    private let netLog = Logger(subsystem: "com.example.unsaid.UnsaidKeyboard", category: "Network")
    private let logGate = LogGate(0.40)
    #endif
    private let instanceId = UUID().uuidString
    
    // MARK: - Personality / learning
    private let bridge = PersonalityDataBridge.shared
    private lazy var learner = CommunicationPatternLearner(bridge: PersonalityDataBridge.shared, windowDays: 7)
    private let storage = SafeKeyboardDataStorage.shared
    
    // MARK: - Full-Text Analysis State (replacing ToneScheduler)
    private let debounceInterval: TimeInterval = 3.0 // 3s debounce for better rate limiting
    private var currentDocSeq: Int = 0
    private var lastTextHash: String = ""
    private var isAnalysisInFlight = false
    
    // MARK: - Word-Boundary Coalescing (more explicit)
    private let wordCoalesceMinGap: CFTimeInterval = 0.12
    private var lastWordHash: Int = 0
    private var lastWordAt: CFTimeInterval = 0
    private var lastCompletedWordHash: Int = 0
    private var quietEdgeToken: Timer?
    
    // MARK: - Router short-circuit guards
    private var lastRouterSnapshotHash = 0
    private var lastRouterTrigger: (inserted: Character?, deletion: Bool, urgent: Bool) = (nil, false, false)
    
    // MARK: - Suggestion hash guard
    private var lastSuggestionHash = 0
    
    // MARK: - Last Analysis Cache (fixes empty snapshot issue)
    private struct LastAnalysis {
        let text: String
        let uiTone: String
        let docSeq: Int
        let hash: String
        let timestamp: Date
        
        var isStale: Bool {
            Date().timeIntervalSince(timestamp) > 30.0 // 30s staleness limit
        }
    }
    
    private var lastAnalysis: LastAnalysis?
    
    // MARK: - Smart Triggering Logic
    private var lastAnalyzedTextCount = 0
    private let urgentCharacters: Set<Character> = ["!", "?", ".", "…", "😡", "😤", "💔"]
    
    // MARK: - Centralized text snapshot with fallback
    private func currentPayloadText() -> String {
        let live = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !live.isEmpty { return live }
        
        // Fallback to last analyzed text if live snapshot is empty
        if let cached = lastAnalysis, !cached.isStale {
            dlog("🔄 Using cached analysis text (live snapshot empty)")
            return cached.text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        
        return ""
    }
    
    // MARK: - Network state debouncing
    private var reachabilityWorkItem: DispatchWorkItem?
    
    // MARK: - Response Caching for Scale
    private var analysisCache: [String: (tone: String, timestamp: Date)] = [:]
    private let cacheExpiryInterval: TimeInterval = 60.0 // Cache results for 60s (increased from 30s)
    
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
    
    // ✅ Security: Redact sensitive headers for safe logging
    private func redactSensitiveHeaders(_ headers: [String: String]?) -> [String: String] {
        guard let headers = headers else { return [:] }
        var redacted = headers
        
        // Redact Authorization tokens
        if let auth = redacted["Authorization"], auth.contains("Bearer") {
            redacted["Authorization"] = "Bearer <REDACTED>"
        }
        
        // Redact any other sensitive headers
        let sensitiveKeys = ["X-API-Key", "X-Auth-Token", "Cookie"]
        for key in sensitiveKeys {
            if redacted[key] != nil {
                redacted[key] = "<REDACTED>"
            }
        }
        
        return redacted
    }
    
    // MARK: - URL normalization helper (for suggestions/observe)
    private func normalizedBaseURLString() -> String {
        let raw = apiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        var s = raw.hasSuffix("/") ? String(raw.dropLast()) : raw
        
        // Only strip /api/v1 or /api if they are path components, not part of the domain
        // E.g., strip from "https://localhost:3000/api/v1" but NOT from "https://api.myunsaidapp.com"
        if let url = URL(string: s), let host = url.host {
            // If 'api' is part of the domain (like api.myunsaidapp.com), don't strip anything
            if host.contains("api.") {
                return s
            }
            
            // Otherwise, strip /api/v1 or /api path suffixes for development URLs
            let lowers = s.lowercased()
            if lowers.hasSuffix("/api/v1") { s = String(s.dropLast(7)) }
            else if lowers.hasSuffix("/api") { s = String(s.dropLast(4)) }
        }
        
        return s // e.g. https://api.myunsaidapp.com or https://localhost:3000
    }
    
    // MARK: - Idempotency helper (for suggestions/observe)
    private func contentHash(for path: String, payload: [String: Any]) -> String {
        var hashableContent = path
        if let text = payload["text"] as? String { hashableContent += text }
        if let context = payload["context"] as? String { hashableContent += context }
        if let toneOverride = payload["toneOverride"] as? String { hashableContent += toneOverride }
        return String(hashableContent.hash)
    }
    
    // MARK: - Cheap logging gate for Release
    @inline(__always)
    private func dlog(_ msg: @autoclosure () -> String) {
        #if DEBUG
        print(msg())
        #endif
    }
    
    // MARK: - Word-Boundary Detection Helpers
    
    private func lastCompletedWord(in text: String) -> Substring? {
        // take everything before trailing whitespace
        let trimmedRight = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRight.isEmpty else { return nil }
        // find last delimiter in original text
        let delimiters = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
        let end = trimmedRight.endIndex
        var start = trimmedRight.startIndex
        var i = trimmedRight.index(before: end)
        while i > start {
            if let scalar = trimmedRight[i].unicodeScalars.first, delimiters.contains(scalar) {
                start = trimmedRight.index(after: i); break
            }
            i = trimmedRight.index(before: i)
        }
        return trimmedRight[start..<end]
    }

    @inline(__always)
    private func hashWord(_ w: Substring) -> Int {
        var h = Hasher(); h.combine(w); return h.finalize()
    }
    
    // MARK: - Network diagnostics
    func pingAPI() {
        print("🏓 DEBUG: Starting API ping...")
        guard let baseURL = cachedAPIBaseURL.nilIfEmpty else {
            print("❌ DEBUG: No API base URL for ping")
            return
        }
        
        // Try a simple GET to the base domain first
        guard let url = URL(string: "\(baseURL)") else {
            print("❌ DEBUG: Invalid ping URL: \(baseURL)")
            return
        }
        
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 5.0
        
        print("🏓 DEBUG: Pinging \(url.absoluteString)...")
        
        let task = URLSession.shared.dataTask(with: req) { data, resp, err in
            if let err = err {
                let code = (err as NSError).code
                print("❌ DEBUG: Ping failed with error \(code): \(err.localizedDescription)")
                
                // Specific error code analysis
                if code == -1022 {
                    print("🔒 DEBUG: ATS violation detected - check Info.plist ATS settings")
                } else if code == -1009 {
                    print("📶 DEBUG: No internet connection")
                } else if code == -1001 {
                    print("⏱ DEBUG: Request timeout")
                }
                return
            }
            
            let httpCode = (resp as? HTTPURLResponse)?.statusCode ?? 0
            print("✅ DEBUG: Ping successful - HTTP \(httpCode)")
            
            if let data = data {
                print("📦 DEBUG: Response data length: \(data.count) bytes")
            }
        }
        task.resume()
    }
    
    // MARK: - Configuration
    private var apiBaseURL: String { cachedAPIBaseURL }
    private var apiKey: String { cachedAPIKey }
    
    // MARK: - Full Access Detection
    private var hasFullAccess: Bool {
        // Critical: Third-party keyboards need Allow Full Access to reach the network
        let hasAccess = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: AppGroups.id
        ) != nil
        
        if !hasAccess {
            KBDLog("❌ Full Access disabled - App Group container inaccessible", .warn, "ToneCoordinator")
        }
        
        return hasAccess
    }
    
    private var isAPIConfigured: Bool {
        // Check Full Access first - no point checking API config if we can't reach network
        let fullAccess = hasFullAccess
        print("🔍 DEBUG: hasFullAccess = \(fullAccess)")
        
        guard fullAccess else {
            print("🔴 API blocked - Full Access required for network requests")
            KBDLog("🔴 API blocked - Full Access required for network requests", .warn, "ToneCoordinator")
            return false
        }

        if Date() < authBackoffUntil {
            print("🔴 API blocked due to auth backoff until \(authBackoffUntil)")
            KBDLog("🔴 API blocked due to auth backoff until \(authBackoffUntil)", .warn, "ToneCoordinator")
            return false
        }

        let configured = !apiBaseURL.isEmpty && !apiKey.isEmpty
        print("🔧 DEBUG: API Base URL: '\(apiBaseURL)'")
        print("🔧 DEBUG: API Key: \(redact(apiKey))")
        print("🔧 DEBUG: API configured: \(configured)")
        KBDLog("🔧 API configured: \(configured) - URL: '\(apiBaseURL)', Key: '\(redact(apiKey))'", .debug, "ToneCoordinator")
        return configured
    }    // MARK: Networking (improved for keyboard extension reliability)
    private lazy var session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        
        // Keyboard extension optimized for fail-fast behavior
        cfg.timeoutIntervalForRequest = 5        // fail fast on I/O operations
        cfg.timeoutIntervalForResource = 8       // fail fast on whole transfer
        cfg.waitsForConnectivity = false         // fail fast in extension context
        cfg.networkServiceType = .responsiveData // prioritize responsiveness
        #if canImport(UIKit)
        cfg.multipathServiceType = .handover     // smoother Wi-Fi <-> Cellular
        #endif
        cfg.httpMaximumConnectionsPerHost = 2
        
        // Network access permissions
        cfg.allowsCellularAccess = true
        cfg.allowsConstrainedNetworkAccess = true
        cfg.allowsExpensiveNetworkAccess = true
        cfg.httpShouldUsePipelining = false  // Can cause issues in extensions
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.httpCookieAcceptPolicy = .never
        cfg.httpCookieStorage = nil
        
        // Headers with User-Agent to avoid WAF blocking
        cfg.httpAdditionalHeaders = [
            "Accept": "application/json",
            "Accept-Encoding": "gzip",
            "Cache-Control": "no-cache",
            "User-Agent": "UnsaidKeyboard/1.0 (iOS)"  // Prevent WAF rate-limiting
        ]
        
        return URLSession(configuration: cfg, delegate: networkDelegate, delegateQueue: nil)
    }()
    
    // Network metrics delegate for debugging timeouts
    private lazy var networkDelegate = NetworkMetricsDelegate()
    private var inFlightTask: URLSessionDataTask?
    
    // MARK: - Queue / Debounce (for suggestions only - legacy)
    private let workQueue = DispatchQueue(label: "com.unsaid.coordinator", qos: .utility)
    private var pendingWorkItem: DispatchWorkItem?
    // Note: debounceInterval moved to full-text analysis section above
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
    
    // Per-sentence tone scoping (prevents tone flipping)
    enum Sev: Int {
        case clear = 0, caution = 1, alert = 2
    }
    
    struct SentenceTone {
        let sev: Sev
        let confidence: Double
        let timestamp: Date
        
        init(bucket: Bucket, confidence: Double) {
            self.sev = bucket.toSeverity()
            self.confidence = confidence
            self.timestamp = Date()
        }
    }
    
    private var sentenceToneCache: [String: SentenceTone] = [:]
    private var lastCursorPosition: Int = 0
    private var pendingAnalysisTask: Task<Void, Never>?
    private let newSystemDebounceInterval: TimeInterval = 0.2
    var onToneUpdate: ((Bucket, Bool) -> Void)?
    
    // Store full tone analysis for reuse in suggestions
    private var lastToneAnalysis: [String: Any]?
    private var lastAnalyzedText: String = ""
    
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
    
    // MARK: - Composition Session
    private(set) var composeId: String = ToneSuggestionCoordinator.newComposeId()
    
    private static func newComposeId() -> String {
        "compose-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(8))"
    }
    private var authBackoffUntil: Date = .distantPast
    private var netBackoffUntil: Date = .distantPast
    private var inFlightRequests: [String: URLSessionDataTask] = [:]
    private var requestCompletionTimes: [String: Date] = [:]
    private func cacheTTL(for path: String) -> TimeInterval {
        switch path {
        case "/api/v1/suggestions": return 5.0
        default: return 5.0
        }
    }
    
    // MARK: - Client-Side Rate Limiting
    
    /// Simple token bucket rate limiter (max 6 calls per 12 seconds)
    /// Enhanced token bucket rate limiter with adaptive refill and burst capacity
    private class TokenBucket {
        private var tokens: Int = 12           // Increased from 6
        private let capacity: Int = 16         // Allow burst capacity (+4 tokens)
        private var lastRefill: TimeInterval = CACurrentMediaTime()
        private let baseRefillInterval: TimeInterval = 0.8  // 1 token per 800ms (~12/10s)
        private var adaptiveRefillInterval: TimeInterval = 0.8
        
        // Adaptive rate limiting based on network performance
        private var recentResponseTimes: [TimeInterval] = []
        private var recentErrors = 0
        private let performanceWindow = 5  // Track last 5 requests
        
        init() {
            self.tokens = capacity - 4  // Start with base tokens, not full burst
        }
        
        func allowRequest(isUrgent: Bool = false) -> Bool {
            let now = CACurrentMediaTime()
            let elapsed = now - lastRefill
            
            // Refill tokens based on elapsed time
            let tokensToAdd = Int(elapsed / adaptiveRefillInterval)
            if tokensToAdd > 0 {
                tokens = min(capacity, tokens + tokensToAdd)
                lastRefill = now
            }
            
            // Allow urgent requests even when bucket is empty (single bypass)
            if isUrgent && tokens == 0 {
                print("🔥 Rate limit: URGENT bypass used (punctuation/exclamation)")
                return true
            }
            
            guard tokens > 0 else {
                print("🚫 Rate limit: No tokens available (\(capacity) capacity, \(String(format: "%.1f", adaptiveRefillInterval * 1000))ms refill)")
                return false
            }
            
            tokens -= 1
            print("🪣 Rate limit: \(tokens)/\(capacity) tokens remaining (refill: \(String(format: "%.0f", adaptiveRefillInterval * 1000))ms)")
            return true
        }
        
        /// Update adaptive refill based on network performance
        func recordResponse(responseTime: TimeInterval, hadError: Bool) {
            recentResponseTimes.append(responseTime)
            if recentResponseTimes.count > performanceWindow {
                recentResponseTimes.removeFirst()
            }
            
            if hadError {
                recentErrors += 1
            }
            
            // Adapt refill rate based on recent performance
            if recentResponseTimes.count >= performanceWindow {
                let avgResponseTime = recentResponseTimes.reduce(0, +) / Double(recentResponseTimes.count)
                
                if avgResponseTime < 0.2 && recentErrors == 0 {
                    // Fast responses, no errors - allow faster refill
                    adaptiveRefillInterval = max(0.6, baseRefillInterval * 0.75)  // 25% faster
                } else if avgResponseTime > 1.0 || recentErrors > 1 {
                    // Slow responses or errors - be more conservative
                    adaptiveRefillInterval = min(1.2, baseRefillInterval * 1.5)   // 50% slower
                } else {
                    // Normal performance - use base rate
                    adaptiveRefillInterval = baseRefillInterval
                }
                
                // Reset error counter periodically
                if recentErrors > 0 {
                    recentErrors = max(0, recentErrors - 1)
                }
            }
        }
    }
    
    private let rateLimiter = TokenBucket()
    
    // MARK: - Security Utilities
    
    /// Redacts API keys/tokens for safe logging
    private func redact(_ token: String) -> String {
        guard !token.isEmpty else { return "EMPTY" }
        guard token.count > 10 else { return "TOO_SHORT" }
        let prefix = token.prefix(6)
        let suffix = token.suffix(4)
        return "\(prefix)…\(suffix)"
    }
    
    // MARK: - Per-Sentence Tone Scoping
    private func hashSentenceRange(text: String, range: Range<String.Index>) -> String {
        let sentenceText = String(text[range])
        return sentenceText.replacingOccurrences(of: " ", with: "_")
    }
    
    private func decidePublish(newBucket: Bucket, confidence: Double, text: String, cursorPos: Int) -> Bool {
        // Find current sentence
        guard let currentSentenceRange = findCurrentSentence(in: text, at: cursorPos) else {
            return true // no sentence context, publish immediately
        }
        
        let sentenceHash = hashSentenceRange(text: text, range: currentSentenceRange)
        let newSev = newBucket.toSeverity()
        
        // If this is a new sentence, always publish
        guard let cached = sentenceToneCache[sentenceHash] else {
            sentenceToneCache[sentenceHash] = SentenceTone(bucket: newBucket, confidence: confidence)
            return true
        }
        
        // If severity increased, always publish  
        if newSev.rawValue > cached.sev.rawValue {
            sentenceToneCache[sentenceHash] = SentenceTone(bucket: newBucket, confidence: confidence)
            return true
        }
        
        // If severity decreased, only publish if high confidence or stale cache
        if newSev.rawValue < cached.sev.rawValue {
            let isHighConfidence = confidence > 0.7
            let isStale = Date().timeIntervalSince(cached.timestamp) > 3.0
            
            if isHighConfidence || isStale {
                sentenceToneCache[sentenceHash] = SentenceTone(bucket: newBucket, confidence: confidence)
                return true
            }
            return false // suppress downgrade
        }
        
        // Same severity - update cache but don't republish
        sentenceToneCache[sentenceHash] = SentenceTone(bucket: newBucket, confidence: confidence)
        return false
    }
    
    private func bannerSeverity(for text: String, cursorPos: Int) -> Sev {
        // Get all cached sentence tones and find the maximum severity
        var maxSev: Sev = .clear
        
        for (_, sentenceTone) in sentenceToneCache {
            if sentenceTone.sev.rawValue > maxSev.rawValue {
                maxSev = sentenceTone.sev
            }
        }
        
        return maxSev
    }
    
    private func findCurrentSentence(in text: String, at position: Int) -> Range<String.Index>? {
        guard !text.isEmpty && position >= 0 && position <= text.count else { return nil }
        
        let sentenceEnders = CharacterSet(charactersIn: ".?!\n")
        let startIndex = text.startIndex
        let endIndex = text.endIndex
        let cursorIndex = text.index(startIndex, offsetBy: min(position, text.count))
        
        // Find sentence start (look backwards from cursor)
        var sentenceStart = startIndex
        if cursorIndex > startIndex {
            let prefixEnd = text.index(before: cursorIndex)
            for i in text.indices.reversed() {
                if i > prefixEnd { continue }
                if let asciiValue = text[i].asciiValue,
                   let scalar = Unicode.Scalar(UInt32(asciiValue)),
                   sentenceEnders.contains(scalar) {
                    sentenceStart = text.index(after: i)
                    break
                }
            }
        }
        
        // Find sentence end (look forwards from cursor)
        var sentenceEnd = endIndex
        for i in text.indices {
            if i < cursorIndex { continue }
            if let asciiValue = text[i].asciiValue,
               let scalar = Unicode.Scalar(UInt32(asciiValue)),
               sentenceEnders.contains(scalar) {
                sentenceEnd = i
                break
            }
        }
        
        return sentenceStart..<sentenceEnd
    }
    
    // Shared Defaults & Persona
    private let sharedUserDefaults: UserDefaults = UserDefaults.standard
    private var cachedPersona: [String: Any] = [:]
    private var cachedPersonaAt: Date = .distantPast
    private let personaTTL: TimeInterval = 10 * 60
    
    // Logging & Haptics
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
        #if DEBUG
        netLog.info("🔧 API Config - Base URL: \(base), Key prefix: \(String(key.prefix(8)))")
        #endif
    }
    
    func debugPing() {
        KBDLog("🔥 Debug ping triggered", .info, "Coordinator")
        debugPingAll()
    }
    
    func debugPingAll() {
        KBDLog("🔧 normalized base: \(normalizedBaseURLString())", .debug, "ToneCoordinator")
        KBDLog("🔧 suggestions: \(normalizedBaseURLString() + "/api/v1/suggestions")", .debug, "ToneCoordinator")
        KBDLog("🔧 tone: \(normalizedBaseURLString() + "/api/v1/tone")", .debug, "ToneCoordinator")
        dumpAPIConfig()
        
        // Test a sample suggestion request to verify endpoints work
        let testPayload: [String: Any] = [
            "text": "Hello test",
            "context": "general"
        ]
        KBDLog("🔧 Testing suggestions endpoint...", .debug, "ToneCoordinator")
        callEndpoint(path: "api/v1/suggestions", payload: testPayload) { result in
            if result != nil {
                KBDLog("✅ Suggestions endpoint responded", .info, "ToneCoordinator")
            } else {
                KBDLog("❌ Suggestions endpoint failed", .error, "ToneCoordinator")
            }
        }
    }
    
    private func checkBackoffStatus() {
        let currentTextTrimmed = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !currentTextTrimmed.isEmpty {
            routeIfChanged(fullText: currentTextTrimmed, lastInserted: nil, isDeletion: false, urgent: true)
        }
    }
    
    // MARK: - Init/Deinit
    init() {
        #if DEBUG
        debugInstanceId = String(instanceId.prefix(8))
        coordLog.info("🔧 Coordinator init id=\(self.instanceId)")
        #endif
        
        setupWorkQueueIdentification()
        
        // 📦 Check if triggerwords data is bundled in extension
        let triggerwordsURL = Bundle.main.url(forResource: "tone_triggerwords", withExtension: "json")
        print("📦 triggerwords.json present in extension bundle? \(triggerwordsURL != nil)")
        if let url = triggerwordsURL {
            print("📦 triggerwords.json path: \(url.path)")
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.startNetworkMonitoringSafely() }
        #if DEBUG
        KBDLog("🧠 Personality Data Bridge Status:", .debug, "ToneCoordinator")
        KBDLog(" - Attachment Style: '\(getAttachmentStyle())'", .debug, "ToneCoordinator")
        KBDLog(" - Emotional State: '\(getEmotionalState())'", .debug, "ToneCoordinator")
        #endif
    }
    
    deinit {
        KBDLog("🗑️ ToneSuggestionCoordinator deinit - cleaning up resources", .info, "ToneCoordinator")
        pendingWorkItem?.cancel()
        inFlightTask?.cancel()
        stopNetworkMonitoring()
        KBDLog("✅ ToneSuggestionCoordinator cleanup complete", .info, "ToneCoordinator")
    }
    
    // MARK: - Router Pattern Optimizations
    
    /// Cheap hash of current text snapshot for router guards
    private func snapshotHash(_ text: String) -> Int {
        var hasher = Hasher()
        hasher.combine(text)
        return hasher.finalize()
    }
    
    /// Optimized router that skips work when nothing changed
    private func routeIfChanged(fullText: String, lastInserted: Character?, isDeletion: Bool, urgent: Bool = false) {
        let h = snapshotHash(fullText)
        if h == lastRouterSnapshotHash,
           lastRouterTrigger.inserted == lastInserted,
           lastRouterTrigger.deletion == isDeletion,
           !urgent {
            dlog("🚀 Router: skipped redundant analysis")
            return // no-op, nothing changed from router's POV
        }
        lastRouterSnapshotHash = h
        lastRouterTrigger = (lastInserted, isDeletion, urgent)
        dlog("🚀 Router: proceeding with analysis")
        Task { @MainActor in
            onTextChanged(fullText: fullText, lastInserted: lastInserted, isDeletion: isDeletion)
        }
    }
    
    /// Network state change with debounced UI updates
    private func handleNetworkStateChange(reachable: Bool) {
        reachabilityWorkItem?.cancel()
        let job = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // Update reachability state and trigger analysis if needed
            if reachable {
                dlog("📶 Network: back online")
                // Re-analyze if there's text when coming back online
                // Note: This would need to be called from the appropriate context
                // where fullText is available
            } else {
                dlog("📶 Network: went offline")
            }
        }
        reachabilityWorkItem = job
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: job)
    }
    
    // MARK: - Public API
    func analyzeFinalSentence(_ sentence: String) {
        routeIfChanged(fullText: sentence, lastInserted: nil, isDeletion: false, urgent: true)
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
        let text = currentPayloadText()
        let isFromCache = !currentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "live" : "cache"
        dlog("🎯 DEBUG: requestSuggestions() called - text length: \(text.count), source: \(isFromCache)")
        
        pendingWorkItem?.cancel()
        suggestionSnapshot = text
        
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            
            // Enhanced fallback logic with minimum length guard
            guard !text.isEmpty && text.count >= 6 else {
                let reason = text.isEmpty ? "NO_TEXT_AVAILABLE" : "BELOW_MIN_LENGTH(\(text.count)<6)"
                dlog("🎯 SKIP: Suggestions blocked - reason: \(reason)")
                
                DispatchQueue.main.async {
                    // Don't clear existing suggestions - show hint for user guidance
                    if text.isEmpty {
                        // Could show "Type a message to get suggestions" hint
                    } else {
                        // Could show "Type a bit more for suggestions" hint  
                    }
                    self.delegate?.didUpdateSecureFixButtonState()
                }
                return
            }
            
            // Check if another suggestions request is already in flight
            if self.suggestionsInFlight {
                dlog("🎯 SKIP: Suggestions blocked - reason: REQUEST_IN_FLIGHT")
                return
            }
            
            dlog("🎯 PROCEED: Calling generatePerfectSuggestion with text (\(isFromCache)): '\(String(text.prefix(50)))...'")
            self.generatePerfectSuggestion(from: text)
        }
        pendingWorkItem = work
        workQueue.async(execute: work)
    }
    
    /// Request suggestions for explicit button tap - bypasses all rate limits
    func requestSuggestionsForButtonTap() {
        let text = currentPayloadText()
        let isFromCache = !currentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "live" : "cache"
        dlog("🎯 BUTTON TAP: requestSuggestionsForButtonTap() called - text length: \(text.count), source: \(isFromCache)")
        
        pendingWorkItem?.cancel()
        suggestionSnapshot = text
        
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            
            // Enhanced fallback logic with minimum length guard
            guard !text.isEmpty && text.count >= 6 else {
                let reason = text.isEmpty ? "NO_TEXT_AVAILABLE" : "BELOW_MIN_LENGTH(\(text.count)<6)"
                dlog("🎯 BUTTON TAP SKIP: Suggestions blocked - reason: \(reason)")
                
                DispatchQueue.main.async {
                    // Don't clear existing suggestions - show hint for user guidance
                    // Could show hint to user here
                    self.delegate?.didUpdateSecureFixButtonState()
                }
                return
            }
            
            dlog("🎯 BUTTON TAP PROCEED: Generating suggestions (bypassing rate limits) with text (\(isFromCache)): '\(String(text.prefix(50)))...'")
            self.generatePerfectSuggestionForButtonTap(from: text)
        }
        
        pendingWorkItem = work
        workQueue.async(execute: work)
    }
    
    /// Generate suggestions for button tap - bypasses all rate limits
    private func generatePerfectSuggestionForButtonTap(from snapshot: String) {
        print("🎯 🔥 BUTTON TAP: generatePerfectSuggestionForButtonTap called with snapshot length: \(snapshot.count)")
        dlog("🎯 BUTTON TAP: generatePerfectSuggestionForButtonTap called with snapshot length: \(snapshot.count)")
        
        var textToAnalyze = snapshot
        if textToAnalyze.count > 1000 { textToAnalyze = String(textToAnalyze.suffix(1000)) }
        
        print("🎯 🔥 BUTTON TAP: About to analyze text for suggestions: '\(String(textToAnalyze.prefix(50)))...' (length: \(textToAnalyze.count))")
        
        var context: [String: Any] = [
            "text": textToAnalyze,
            "userId": getUserId(),
            "userEmail": getUserEmail() ?? NSNull(),
            "features": ["advice", "evidence"],
            "maxSuggestions": 3,
            "meta": [
                "source": "keyboard_button_tap", // Mark as explicit user action
                "request_type": "suggestion",
                "context": "general",
                "timestamp": isoTimestamp(),
                "bypass_rate_limits": true // Flag for backend
            ]
        ]
        
        // ✅ Include cached tone analysis if available
        if let storedAnalysis = lastToneAnalysis,
           let toneData = storedAnalysis["toneAnalysis"] as? [String: Any] {
            context["toneAnalysis"] = toneData
            
            if let detectedContext = toneData["context"] as? String, !detectedContext.isEmpty {
                context["meta"] = [
                    "source": "keyboard_button_tap",
                    "request_type": "suggestion", 
                    "context": detectedContext,
                    "timestamp": isoTimestamp(),
                    "bypass_rate_limits": true
                ]
            }
            
            #if DEBUG
            throttledLog("🎯 BUTTON TAP: Using cached tone analysis with ui_tone: \(toneData["ui_tone"] ?? "unknown")", category: "suggestions")
            #endif
        } else {
            #if DEBUG
            throttledLog("🎯 BUTTON TAP: No cached tone analysis available, proceeding with default", category: "suggestions")
            #endif
        }
        
        context.merge(personalityPayload()) { _, new in new }
        
        // Call regular API - the bypass is handled by not checking rate limits above
        callSuggestionsAPI(context: context, usingSnapshot: textToAnalyze) { [weak self] suggestion in
            guard let self else { return }
            DispatchQueue.main.async {
                if let s = suggestion, !s.isEmpty {
                    self.suggestions = [s]
                    self.delegate?.didUpdateSuggestions(self.suggestions)
                    self.delegate?.didUpdateSecureFixButtonState()
                    self.storeSuggestionGenerated(suggestion: s)
                    print("🎯 🔥 BUTTON TAP: Successfully generated suggestion")
                } else {
                    self.suggestions = []
                    self.delegate?.didUpdateSuggestions([])
                    self.delegate?.didUpdateSecureFixButtonState()
                    print("🎯 🔥 BUTTON TAP: No suggestion generated")
                }
            }
        }
    }
    
    func fetchSuggestions(for text: String, completion: @escaping ([String]?) -> Void) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            completion(nil); return
        }
        
        // Check client-side rate limiting
        guard rateLimiter.allowRequest(isUrgent: false) else {
            print("🚫 Suggestions: Rate limit exceeded, skipping")
            completion(nil)
            return
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
            "maxSuggestions": 3, // Limit to prevent API spam
            "meta": [
                "source": "keyboard_tone_button",
                "request_type": "suggestion",
                "context": "general", // Default, will be overridden if tone analysis available
                "timestamp": isoTimestamp()
            ]
        ]
        
        // 🎯 REUSE STORED ANALYSIS - If we have recent analysis for similar text, use it!
        if let storedAnalysis = lastToneAnalysis,
           let storedText = storedAnalysis["text"] as? String,
           let toneData = storedAnalysis["toneAnalysis"] as? [String: Any],
           textToAnalyze.hasSuffix(storedText) || storedText.hasSuffix(textToAnalyze) || 
           abs(textToAnalyze.count - storedText.count) < 50 {
            
            // Use stored analysis instead of letting API re-analyze
            context["toneAnalysis"] = toneData
            
            // ✅ Extract detected context from tone analysis and use it instead of "general"
            if let detectedContext = toneData["context"] as? String, !detectedContext.isEmpty {
                context["meta"] = [
                    "source": "keyboard_tone_button",
                    "request_type": "suggestion",
                    "context": detectedContext, // Use detected context for NLI
                    "timestamp": isoTimestamp()
                ]
                #if DEBUG
                throttledLog("🎯 Using detected context: \(detectedContext)", category: "suggestions")
                #endif
            }
            
            #if DEBUG
            throttledLog("🎯 REUSING stored tone analysis - avoiding redundant API call", category: "suggestions")
            #endif
        }
        
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
            self.lastTextHash = ""
            self.sentenceToneCache.removeAll()
            self.composeId = ToneSuggestionCoordinator.newComposeId()   // ← rotate here
            DispatchQueue.main.async {
                self.lastUiTone = .neutral
                self.delegate?.didUpdateSuggestions([])
                self.delegate?.didUpdateToneStatus("neutral")
                self.delegate?.didUpdateSecureFixButtonState()
            }
        }
    }
    
    // MARK: - Suggestion Generation
    private func generatePerfectSuggestion(from snapshot: String = "") {
        print("🎯 🔥 generatePerfectSuggestion called with snapshot length: \(snapshot.count)")
        dlog("🎯 DEBUG: generatePerfectSuggestion called with snapshot length: \(snapshot.count)")
        
        var textToAnalyze = snapshot.isEmpty ? currentText : snapshot
        if textToAnalyze.count > 1000 { textToAnalyze = String(textToAnalyze.suffix(1000)) }
        
        // Guard against redundant suggestion requests
        let h = snapshotHash(textToAnalyze)
        if h == lastSuggestionHash {
            print("🎯 🔥 Suggestions: skipped redundant generation")
            dlog("🚀 Suggestions: skipped redundant generation")
            return
        }
        lastSuggestionHash = h
        
        print("🎯 🔥 About to analyze text for suggestions: '\(String(textToAnalyze.prefix(50)))...' (length: \(textToAnalyze.count))")
        dlog("🎯 DEBUG: About to analyze text: '\(String(textToAnalyze.prefix(50)))...' (length: \(textToAnalyze.count))")
        
        var context: [String: Any] = [
            "text": textToAnalyze,
            "userId": getUserId(),
            "userEmail": getUserEmail() ?? NSNull(),
            "features": ["advice", "evidence"],
            "maxSuggestions": 3, // Limit to prevent API spam
            "meta": [
                "source": "keyboard_manual",
                "request_type": "suggestion",
                "context": "general", // Default, will be overridden if tone analysis available
                "timestamp": isoTimestamp()
            ]
        ]
        
        // ✅ Check if we have recent tone analysis and pass FULL analysis + context
        if let storedAnalysis = lastToneAnalysis,
           let toneData = storedAnalysis["toneAnalysis"] as? [String: Any] {
            
            // Pass the complete tone analysis to suggestions API
            context["toneAnalysis"] = toneData
            
            // Update context if available
            if let detectedContext = toneData["context"] as? String, !detectedContext.isEmpty {
                context["meta"] = [
                    "source": "keyboard_manual",
                    "request_type": "suggestion", 
                    "context": detectedContext, // Use detected context for NLI
                    "timestamp": isoTimestamp()
                ]
                #if DEBUG
                throttledLog("🎯 Using detected context for manual suggestion: \(detectedContext)", category: "suggestions")
                #endif
            }
            
            #if DEBUG
            throttledLog("🎯 Passing full tone analysis to suggestions API with ui_tone: \(toneData["ui_tone"] ?? "unknown")", category: "suggestions")
            #endif
        }
        
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
    
    // MARK: - Suggestions API (tone side-effects removed)
    private func callSuggestionsAPI(context: [String: Any], usingSnapshot snapshot: String? = nil, completion: @escaping (String?) -> Void) {
        print("🎯 🔥 callSuggestionsAPI called!")
        guard isNetworkAvailable, isAPIConfigured, Date() >= netBackoffUntil else { 
            print("🎯 🔥 callSuggestionsAPI early return - network/API check failed")
            completion(nil); return 
        }
        
        print("🎯 🔥 callSuggestionsAPI proceeding with request...")
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
        
        // Build canonical v1 from the actual snapshot (or context["text"])
        let textForAdvice = snapshot ?? (context["text"] as? String) ?? ""
        let toneFromCache = (lastToneAnalysis?["toneAnalysis"] as? [String: Any])

        let canonicalPayload = buildCanonicalV1Payload(
            text: textForAdvice,
            context: (context["meta"] as? [String: Any])?["context"] as? String ?? (context["context"] as? String) ?? "general",
            persona: personalityPayload(),
            toneFromCache: toneFromCache
        )

        // Ensure user/scalar fields are present if your server uses them
        var payloadToSend = canonicalPayload
        payloadToSend["userId"] = getUserId()
        if let email = getUserEmail() { payloadToSend["userEmail"] = email }
        
        // Use retry wrapper for suggestions to handle transient network errors
        callEndpointWithRetry(path: "api/v1/suggestions", payload: payloadToSend) { [weak self] data in
            guard let self else { completion(nil); return }
            guard requestID == self.latestRequestID else { completion(nil); return }
            
            let root = data ?? [:]
            let body: [String: Any] = (root["data"] as? [String: Any]) ?? root
            
            if !root.isEmpty {
                self.storeAPIResponseInSharedStorage(endpoint: "suggestions", request: payload, response: root)
            }
            let suggestion = extractSuggestionSafely(from: body)
            
            // (Optional) Persist helpful correlation data for debugging
            // TODO: Store learning data locally using SafeKeyboardDataStorage
            if !root.isEmpty {
                // SafeKeyboardDataStorage calls will be added by iOS build
            }
            
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
    
    // MARK: - Helper Methods
    
    // Normalize and sum=1
    private func normalizeUIDistribution(_ d: [String: Double]) -> [String: Double] {
        let c = max(0, d["clear"] ?? 0)
        let ca = max(0, d["caution"] ?? 0)
        let a = max(0, d["alert"] ?? 0)
        let s = (c + ca + a)
        guard s > 0 else { return ["clear": 1.0, "caution": 0.0, "alert": 0.0] }
        return ["clear": c / s, "caution": ca / s, "alert": a / s]
    }
    
    // MARK: - Canonical V1 Contract Transformation
    private func buildCanonicalV1Payload(
        text: String,
        context: String,
        persona: [String: Any],
        toneFromCache: [String: Any]? // lastToneAnalysis?["toneAnalysis"] as? [String: Any]
    ) -> [String: Any] {
        // 1) Hash always matches the provided text
        let textSHA256 = sha256(text)

        // 2) Attachment style from persona (or secure)
        let attachmentStyle = (persona["attachmentStyle"] as? String) ?? "secure"

        // 3) ToneAnalysis: prefer server cache; otherwise fallback to UI state
        let tone: [String: Any]
        if let t = toneFromCache {
            // Expecting ui_tone, ui_distribution, confidence, intensity?
            let classification = (t["ui_tone"] as? String) ?? "neutral"
            let dist = (t["ui_distribution"] as? [String: Double]) ?? ["clear": 0.33, "caution": 0.33, "alert": 0.34]
            let conf = (t["confidence"] as? Double) ?? 0.5
            let intensity = (t["intensity"] as? Double)

            tone = [
                "classification": classification,
                "confidence": conf,
                "ui_distribution": normalizeUIDistribution(dist),
                "intensity": intensity as Any
            ].compactMapValues { $0 }
        } else {
            // Fallback from UI pill + smoothedBuckets
            let classification = lastUiTone.rawValue // "clear"|"caution"|"alert"|"neutral"|...
            let dist = ["clear": smoothedBuckets.clear, "caution": smoothedBuckets.caution, "alert": smoothedBuckets.alert]
            tone = [
                "classification": classification,
                "confidence": 0.5,
                "ui_distribution": normalizeUIDistribution(dist),
                "intensity": 0.5
            ]
        }

        // 4) Rich (optional) – preserve what you stored from tone API if available
        var rich: [String: Any] = [:]
        if toneFromCache != nil {
            // If you stored an `analysis` subtree earlier, surface what you can:
            if let analysis = (lastToneAnalysis?["toneAnalysis"] as? [String: Any])?["analysis"] as? [String: Any] {
                rich["emotions"] = analysis["emotions"] ?? [:]
                rich["linguistic_features"] = analysis["linguistic_features"] ?? [:]
                rich["context_analysis"] = analysis["context_analysis"] ?? [:]
                rich["attachment_insights"] = analysis["attachment_insights"] ?? []
            }
            rich["raw_tone"] = (lastToneAnalysis?["toneAnalysis"] as? [String: Any])?["primary_tone"] ?? ""
            rich["categories"] = (lastToneAnalysis?["toneAnalysis"] as? [String: Any])?["categories"] ?? []
            rich["sentiment_score"] = ((lastToneAnalysis?["toneAnalysis"] as? [String: Any])?["analysis"] as? [String: Any])?["sentiment_score"] ?? 0.0
            rich["timestamp"] = ISO8601DateFormatter().string(from: Date())
            rich["metadata"] = (lastToneAnalysis?["toneAnalysis"] as? [String: Any])?["metadata"] ?? [:]
            rich["attachmentEstimate"] = (lastToneAnalysis?["toneAnalysis"] as? [String: Any])?["attachmentEstimate"] ?? [:]
            rich["isNewUser"] = (lastToneAnalysis?["toneAnalysis"] as? [String: Any])?["isNewUser"] ?? false
        }

        return [
            "text": text,
            "text_sha256": textSHA256,
            "client_seq": clientSequence,           // will be set by callEndpoint()
            "compose_id": composeId,                // stable for session
            "toneAnalysis": tone,                   // REQUIRED
            "context": context,
            "attachmentStyle": attachmentStyle,
            "rich": rich
        ]
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
        let allowed = Set(["api/v1/suggestions"])
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
        // ✅ Security: Enforce HTTPS in production, allow HTTP only in DEBUG
        #if DEBUG
        guard url.scheme == "http" || url.scheme == "https" else { 
            throttledLog("unsupported URL scheme - only http/https allowed", category: "api"); 
            completion(nil); return 
        }
        #else
        guard url.scheme == "https" else { 
            throttledLog("SECURITY: Production requires HTTPS - rejecting \(url.scheme ?? "nil") URL", category: "api"); 
            completion(nil); return 
        }
        #endif
        
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
                        let code = http.statusCode
                        Task { @MainActor in
                            switch code {
                            case 401:
                                self.delegate?.didReceiveAPIError(.authRequired)
                            case 402:
                                self.delegate?.didReceiveAPIError(.paymentRequired)
                            default:
                                self.delegate?.didReceiveAPIError(.serverError(code))
                            }
                        }
                        self.throttledLog("HTTP \(code) \(normalized)", category: "api")
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
                #if DEBUG
                print("🌐 \(req.httpMethod ?? "POST") \(req.url!.absoluteString)")
                print("🌐 Headers: \(self.redactSensitiveHeaders(req.allHTTPHeaderFields))")
                if let body = req.httpBody { 
                    print("🌐 Body: \(String(data: body, encoding: .utf8) ?? "<non-utf8>")")
                }
                #endif
                
                task.resume()
            }
        }
    }
    
    private func handleNetworkError(_ error: Error, url: URL) {
        let ns = error as NSError
        
        // Enhanced error categorization for keyboard extensions
        let isTimeout = ns.code == NSURLErrorTimedOut
        let isSSLIssue = ns.code == NSURLErrorSecureConnectionFailed
        
        #if DEBUG
        print("🌐 Network Error: \(url.absoluteString) → code=\(ns.code) domain=\(ns.domain)")
        print("❌ \(error.localizedDescription) code:\(ns.code)")
        switch ns.code {
        case NSURLErrorNotConnectedToInternet: 
            print("🔌 Device offline: \(url)")
        case NSURLErrorTimedOut:               
            print("⏱️ Request timeout (likely Full Access disabled or WAF blocking): \(url)")
        case NSURLErrorCannotFindHost:         
            print("🌐 DNS resolution failed: \(url)")
        case NSURLErrorCannotConnectToHost:    
            print("🔌 Connection refused (server down or network filtering): \(url)")
        case NSURLErrorSecureConnectionFailed:
            print("🔒 TLS/SSL failure (ATS violation or cert issue): \(url)")
        case NSURLErrorNetworkConnectionLost:
            print("📱 Network connection lost during request: \(url)")
        case NSURLErrorDNSLookupFailed:
            print("🌐 DNS lookup failed: \(url)")
        case NSURLErrorInternationalRoamingOff:
            print("✈️ International roaming disabled: \(url)")
        case NSURLErrorCallIsActive:
            print("📞 Call is active, data restricted: \(url)")
        case NSURLErrorDataNotAllowed:
            print("📵 Data not allowed on device: \(url)")
        default:                               
            print("❌ Network error \(ns.code): \(error.localizedDescription)")
        }
        #endif
        
        // Implement backoff for timeout errors (often Full Access related)
        if isTimeout {
            netBackoffUntil = Date().addingTimeInterval(60) // 1 minute backoff
            print("⏸️ Network backoff activated for 60s due to timeout")
        }
        
        // Different delegate errors based on root cause
        Task { @MainActor in
            if isTimeout && !hasFullAccess {
                // Timeout + no Full Access = likely permission issue
                self.delegate?.didReceiveAPIError(.authRequired)
            } else if isSSLIssue {
                // SSL issues often indicate ATS problems
                self.delegate?.didReceiveAPIError(.serverError(ns.code))
            } else {
                self.delegate?.didReceiveAPIError(.networkError)
            }
        }
        
        throttledLog("network error \(ns.code)", category: "api")
    }
    
    // MARK: - Retry Logic for Transient Errors
    private func isTransientNetworkError(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        
        let transientCodes: Set<URLError.Code> = [
            .timedOut,
            .cannotFindHost,
            .cannotConnectToHost,
            .networkConnectionLost,
            .dnsLookupFailed,
            .notConnectedToInternet,
            .internationalRoamingOff,
            .callIsActive,
            .dataNotAllowed
        ]
        
        return transientCodes.contains(urlError.code)
    }
    
    private func callEndpointWithRetry(path: String, payload: [String: Any], completion: @escaping ([String: Any]?) -> Void) {
        let delays: [TimeInterval] = [0.2, 0.5, 1.0]  // Exponential backoff delays
        
        func attemptRequest(attemptIndex: Int) {
            callEndpoint(path: path, payload: payload) { [weak self] result in
                guard let self = self else { 
                    completion(nil)
                    return 
                }
                
                // If successful or we've exhausted retries, return result
                if result != nil || attemptIndex >= delays.count {
                    completion(result)
                    return
                }
                
                // For failed requests, check if we should retry
                let delay = delays[attemptIndex]
                self.throttledLog("Retrying request in \(delay)s (attempt \(attemptIndex + 2)/\(delays.count + 1))", category: "api")
                
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    attemptRequest(attemptIndex: attemptIndex + 1)
                }
            }
        }
        
        attemptRequest(attemptIndex: 0)
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
        
        let payload: [String: Any] = [
            "attachmentStyle": resolved.style ?? "secure",
            "meta": metaDict,
            "context": "general",
            "user_profile": profile
        ]
        // Note: toneOverride removed - full tone analysis now passed directly in suggestion requests
        
        let finalPayload = payload.compactMapValues { $0 }
        cachedPersona = finalPayload
        cachedPersonaAt = now
        return finalPayload
    }
    
    // MARK: - Local Storage Learning (Client-side)
    private func updateCommunicatorProfile(with text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count >= 10 else { return }
        
        // Use storage for learning events, trigger learner
        storage.storeCommunicationEvent(text: trimmed, category: "general")
        learner.learnNow()  // Trigger learning with fresh data
        
        // Update bridge with learning progress after communication
        Task {
            let newStyle = learner.getAttachmentStyle()
            let newConfidence = learner.getAttachmentConfidence()
            
            // Only update bridge if we have meaningful confidence
            if newConfidence > 0.1 {
                await bridge.updateLearningProgress(
                    newAttachmentHint: newStyle,
                    confidence: newConfidence
                )
            }
        }
        
        throttledLog("stored communication event locally (text length: \(trimmed.count))", category: "learning")
    }
    
    private func updateCommunicatorProfileWithSuggestion(_ suggestion: String, accepted: Bool) {
        guard accepted else { 
            // Store rejection too for learning
            storage.storeSuggestionInteraction(suggestion: suggestion, accepted: false, category: "general")
            return 
        }
        let trimmed = suggestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        
        // Store suggestion acceptance for learning
        storage.storeSuggestionInteraction(suggestion: trimmed, accepted: true, category: "general")
        learner.learnNow()  // Trigger learning with fresh acceptance data
        
        // Update bridge with learning progress after acceptance
        Task {
            await bridge.updateLearningProgress(
                newAttachmentHint: learner.getAttachmentStyle(),
                confidence: learner.getAttachmentConfidence()
            )
        }
        
        throttledLog("stored accepted suggestion locally (length: \(trimmed.count))", category: "learning")
    }
    
    // MARK: - Persona / Bridge integration

    private func personalityProfileForAPI() -> [String: Any]? {
        // Flattened profile already shaped for API-ish usage
        var p = bridge.getPersonalityProfile()
        // Normalize a few keys to camelCase the coordinator expects
        p["attachmentStyle"] = p["attachment_style"]
        p["communicationStyle"] = p["communication_style"]
        p["personalityType"] = p["personality_type"]
        p["emotionalState"] = p["emotional_state"] ?? p["currentEmotionalState"]
        p["emotionalBucket"] = p["emotional_bucket"] ?? p["currentEmotionalStateBucket"]
        p["newUser"] = bridge.isNewUser()
        p["learningDaysRemaining"] = bridge.learningDaysRemaining()
        // Provisional if not confirmed
        let confirmed = (p["personality_test_complete"] as? Bool) ?? false
        p["attachmentProvisional"] = !confirmed
        return p
    }

    private func resolvedAttachmentStyle() -> (style: String?, provisional: Bool, source: String) {
        // Prefer confirmed, else learner, else default
        let confirmed = bridge.isPersonalityTestComplete()
        let style = bridge.getAttachmentStyle()
        let learner = bridge.getLearnerAttachmentStyle()
        let src = confirmed ? (bridge.getAttachmentSource() ?? "confirmed") : (bridge.getAttachmentSource() ?? "learner")
        return (confirmed ? style : (learner ?? style), !confirmed, src)
    }

    private func getAttachmentStyle() -> String { resolvedAttachmentStyle().style ?? "secure" }
    private func getEmotionalState() -> String { bridge.getCurrentEmotionalState() }
    
    /// Simple helper to detect emotional language for testing purposes
    private func containsEmotionalLanguage(_ text: String) -> Bool {
        let emotionalWords = [
            "hate", "fucking", "damn", "shit", "angry", "frustrated", "furious",
            "annoying", "stupid", "idiot", "never", "always", "worst", "terrible"
        ]
        
        let lowercaseText = text.lowercased()
        return emotionalWords.contains { lowercaseText.contains($0) }
    }
    private func getUserId() -> String {
        let userIdKey = "unsaid_user_id"
        let appGroupId = "group.com.example.unsaid"  // AppGroups.id
        if let sharedDefaults = UserDefaults(suiteName: appGroupId),
           let userId = sharedDefaults.string(forKey: userIdKey) { return userId }
        let fallbackId = UUID().uuidString
        if let sharedDefaults = UserDefaults(suiteName: appGroupId) { sharedDefaults.set(fallbackId, forKey: userIdKey) }
        return fallbackId
    }
    private func getUserEmail() -> String? { nil }
    private func throttledLog(_ message: String, category: String) {
        #if DEBUG
        if logGate.allow(category, message) {
            coordLog.debug("[\(category)] \(message)")
        }
        #endif
    }
    private func startNetworkMonitoringSafely() { /* stub */ }
    private func stopNetworkMonitoring() { /* stub */ }
    private func storeSuggestionAccepted(suggestion: String) { /* stub */ }
    private func storeSuggestionGenerated(suggestion: String) { /* stub */ }
    private func storeAPIResponseInSharedStorage(endpoint: String, request: [String: Any], response: [String: Any]) { /* stub */ }
    private func safeString(from dict: [String: Any], keys: [String], fallback: String = "") -> String {
        for key in keys { if let v = dict[key] as? String, !v.isEmpty { return v } }
        return fallback
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
        KBDLog("🎯 Sentence-aware tone system initialized")
    }
    
    func testToneAPIWithDebugText() {
        throttledLog("🧪 Testing tone API with debug text", category: "test")
        let testText = "I'm so frustrated with this situation"
        updateCurrentText(testText)
        Task { @MainActor in self.onTextChanged(fullText: testText, lastInserted: " ", isDeletion: false) }
    }
    
    // MARK: - Debug Methods
    
    func debugCoordinatorState() {
        KBDLog("🔍 ToneSuggestionCoordinator Debug State:", .info)
        KBDLog("🔍 API Base URL: '\(self.apiBaseURL)'", .info)
        KBDLog("🔍 API Key configured: \(!self.apiKey.isEmpty)", .info)
        KBDLog("🔍 Is API configured: \(self.isAPIConfigured)", .info)
        KBDLog("🔍 Current text: '\(self.currentText)'", .info)
        KBDLog("🔍 Last UI tone: \(self.lastUiTone.rawValue)", .info)
        KBDLog("🔍 Smoothed buckets: clear=\(String(format: "%.2f", self.smoothedBuckets.clear)), caution=\(String(format: "%.2f", self.smoothedBuckets.caution)), alert=\(String(format: "%.2f", self.smoothedBuckets.alert))", .info)
        KBDLog("🔍 Suggestions count: \(self.suggestions.count)", .info)
        KBDLog("🔍 Network available: \(self.isNetworkAvailable)", .info)
        KBDLog("🔍 Auth backoff until: \(self.authBackoffUntil)", .info)
        KBDLog("🔍 Net backoff until: \(self.netBackoffUntil)", .info)
        
        if let delegate = delegate {
            KBDLog("🔍 Delegate is set: \(type(of: delegate))", .info)
        } else {
            KBDLog("🔍 Delegate is nil!", .error)
        }
    }
    
    func debugTestToneAPI(with text: String = "You never listen to me and it's really frustrating") {
        KBDLog("🧪 Testing tone API with text: '\(text)'", .info)
        
        // Check client-side rate limiting first
        guard rateLimiter.allowRequest(isUrgent: false) else {
            KBDLog("🧪 Rate limit exceeded - cannot test API", .error)
            return
        }
        
        // 🧪 Quick sanity test - Test aggressive phrase locally
        let testPhrase = "I fucking hate you!"
        print("🧪 SANITY TEST: Testing aggressive phrase '\(testPhrase)'")
        let hasEmotional = containsEmotionalLanguage(testPhrase)
        print("🧪 containsEmotionalLanguage('\(testPhrase)') = \(hasEmotional)")
        
        guard self.isAPIConfigured else {
            KBDLog("🧪 API not configured - cannot test", .error)
            return
        }
        
        Task {
            do {
                let toneOut = try await self.postTone(base: self.apiBaseURL, text: text, token: self.apiKey.nilIfEmpty)
                await MainActor.run {
                    KBDLog("🧪 API Response received:", .info)
                    KBDLog("🧪 Buckets: \(toneOut.buckets)", .info)
                    if let metadata = toneOut.metadata {
                        KBDLog("🧪 Metadata available: \(metadata.feature_noticings?.count ?? 0) feature noticings", .info)
                        if let noticings = metadata.feature_noticings {
                            for (i, noticing) in noticings.enumerated() {
                                KBDLog("🧪 Feature noticing \(i+1): \(noticing.pattern) - \(noticing.message)", .info)
                            }
                        }
                    } else {
                        KBDLog("🧪 No metadata in response", .info)
                    }
                }
            } catch {
                await MainActor.run {
                    KBDLog("🧪 API test failed: \(error.localizedDescription)", .error)
                }
            }
        }
    }
    
    func debugDelegateCallbacks() {
        KBDLog("📡 Testing delegate callbacks...", .info)
        
        guard let delegate = delegate else {
            KBDLog("📡 No delegate set - cannot test callbacks", .error)
            return
        }
        
        // Test tone status update
        Task { @MainActor in
            delegate.didUpdateToneStatus("alert")
            KBDLog("📡 Called didUpdateToneStatus with 'alert'", .info)
            
            // Test suggestions update
            delegate.didUpdateSuggestions(["Test suggestion 1", "Test suggestion 2"])
            KBDLog("📡 Called didUpdateSuggestions with 2 test suggestions", .info)
            
            // Test feature noticings
            delegate.didReceiveFeatureNoticings(["Debug feature noticing: Consider softening your tone"])
            KBDLog("📡 Called didReceiveFeatureNoticings with debug message", .info)
            
            // Test error
            delegate.didReceiveAPIError(.networkError)
            KBDLog("📡 Called didReceiveAPIError with network error", .info)
        }
    }
    #endif
}

// MARK: - Sentence-Aware Tone Coordination (New System)
extension ToneSuggestionCoordinator {
    enum Bucket: String, CaseIterable { 
        case clear, caution, alert, neutral, insufficient
        
        func toSeverity() -> Sev {
            switch self {
            case .clear: return .clear
            case .caution: return .caution
            case .alert: return .alert
            case .neutral: return .clear // neutral defaults to clear severity
            case .insufficient: return .clear // insufficient is not actionable, treat as clear
            }
        }
        
        static func fromString(_ s: String) -> Bucket {
            switch s.lowercased() {
            case "clear": return .clear
            case "caution": return .caution
            case "alert": return .alert
            case "neutral": return .neutral
            case "insufficient": return .insufficient
            default: return .clear
            }
        }
    }
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
        print("📧 DEBUG: ToneSuggestionCoordinator.onTextChanged called")
        print("📧 DEBUG: fullText length: \(fullText.count), lastInserted: \(lastInserted?.description ?? "nil"), isDeletion: \(isDeletion)")
        print("📧 DEBUG: fullText preview: '\(String(fullText.prefix(100)))...'")
        
        // Reset to neutral immediately if text is empty or becomes too short
        let trimmed = fullText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            print("📧 DEBUG: Text is empty - immediately resetting to neutral")
            onQ {
                self.lastUiTone = .neutral
            }
            delegate?.didUpdateToneStatus("neutral")
            // Clear cached analysis data
            sentenceToneCache.removeAll()
            lastTextHash = ""
            updateCurrentText(fullText)
            return
        }
        
        // Keep currentText in sync for suggestions
        updateCurrentText(fullText)
        
        // Update cursor position for scoping system
        #if canImport(UIKit)
        if let proxy = delegate?.getTextDocumentProxy() {
            // Calculate cursor position based on text before cursor + text in cursor
            let beforeCursor = proxy.documentContextBeforeInput ?? ""
            lastCursorPosition = beforeCursor.count
        } else {
            // Fallback: assume cursor is at end of text
            lastCursorPosition = fullText.count
        }
        #else
        // Fallback: assume cursor is at end of text
        lastCursorPosition = fullText.count
        #endif
        
        print("📧 DEBUG: About to check trigger type and route to appropriate analysis")
        let trigger = sentenceTracker.update(fullText: fullText, lastInserted: lastInserted, isDeletion: isDeletion)
        print("📧 DEBUG: sentenceTracker.update returned trigger: \(trigger)")
        print("📧 DEBUG: currentSentence: '\(sentenceTracker.currentSentence)'")
        
        // 🔄 ROUTE TO FULL-TEXT ANALYSIS: Use document-level analysis instead of sentence-based
        switch trigger {
        case .sentenceFinalized:
            dlog("🎯 DEBUG: Sentence finalized - calling scheduleImmediateFullTextAnalysis")
            scheduleImmediateFullTextAnalysis(fullText: fullText, triggerReason: "sentence_finalized")
        case .wordEdge, .timeoutEdge, .deleteEdge:
            dlog("⏱ DEBUG: Word/timeout/delete edge - calling scheduleFullTextAnalysis")
            scheduleFullTextAnalysis(fullText: fullText, triggerReason: "typing_edge")
        case .none:
            dlog("😴 DEBUG: No trigger - no analysis scheduled")
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
        dlog("🔬 DEBUG: analyze() called with sentence: '\(sentence)'")
        
        let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        dlog("🔬 DEBUG: trimmed sentence: '\(trimmed)' (length: \(trimmed.count))")
        
        guard !trimmed.isEmpty else {
            dlog("❌ DEBUG: Trimmed sentence is empty, returning")
            return
        }
        
        // Check client-side rate limiting
        guard rateLimiter.allowRequest(isUrgent: false) else {
            print("🚫 DEBUG: Rate limit exceeded, skipping analysis")
            return
        }
        
        guard let apiBase = cachedAPIBaseURL.nilIfEmpty else {
            print("❌ DEBUG: cachedAPIBaseURL is empty or nil: '\(cachedAPIBaseURL)'")
            return
        }
        
        print("✅ DEBUG: API base URL is valid: '\(apiBase)'")
        print("🔬 DEBUG: About to check subscription and make API call...")
        
        // Check subscription status locally before making API calls (mass user architecture)
        // let storage = SafeKeyboardDataStorage.shared
        // TEMP: Comment out subscription check for testing
        /*
        guard storage.hasAccessToFeatures() else {
            Task { @MainActor in
                if storage.hasActiveTrial() {
                    let daysRemaining = storage.getTrialDaysRemaining()
                    self.delegate?.didReceiveAPIError(.paymentRequired)
                    self.throttledLog("Trial access: \(daysRemaining) days remaining", category: "subscription")
                } else {
                    self.delegate?.didReceiveAPIError(.paymentRequired)
                    self.throttledLog("No subscription access - trial expired", category: "subscription")
                }
            }
            return
        }
        */
        
        do {
            let toneOut = try await postTone(base: apiBase, text: trimmed, token: cachedAPIKey.nilIfEmpty, fullTextMode: false)
            // ✅ Trust server tone decision - use resolvedTone to get server's ui_tone or fallback
            let (resolvedToneString, _) = resolvedTone(from: toneOut)
            let serverBucket = Bucket.fromString(resolvedToneString) // Convert server tone to local enum
            
            // Log server decision for debugging 
            print("🔎 ANALYZED text='\(trimmed.prefix(50))' serverTone=\(resolvedToneString) serverBucket=\(serverBucket.rawValue)")
            
            // Persist tone analysis event for local learning
            storage.storeToneAnalysisEvent(
                text: trimmed,
                primaryTone: toneOut.primary_tone ?? resolvedToneString,
                confidence: toneOut.confidence ?? 0.5,
                uiBucket: resolvedToneString
            )
            
            // Trigger learning after tone analysis
            learner.learnNow()
            
            // Always trust the server's tone decision - no local overrides
            let newTone = serverBucket
            
            // Get server's distribution for smoothing (optional - could skip smoothing entirely)
            let serverDistribution = (
                clear: toneOut.finalDistribution["clear"] ?? 0.33,
                caution: toneOut.finalDistribution["caution"] ?? 0.33,  
                alert: toneOut.finalDistribution["alert"] ?? 0.34
            )
            
            // Light smoothing for UI stability - but don't use for tone decision
            let isSeverityDrop = severityRank(for: newTone) < severityRank(for: lastUiTone)
            let alpha = isSeverityDrop ? 0.50 : 0.30
            smoothedBuckets = smoothBuckets(prev: smoothedBuckets, curr: serverDistribution, alpha: alpha)
            
            let finalTone = newTone
            
            // Extract and forward feature noticings to the delegate
            if let noticings = toneOut.metadata?.feature_noticings {
                let noticeMessages = noticings.map { $0.message }
                await MainActor.run { 
                    delegate?.didReceiveFeatureNoticings(noticeMessages)
                }
            }
            
            await MainActor.run { 
                // Use per-sentence scoping to prevent tone flipping
                let confidence = toneOut.confidence ?? 0.5
                let shouldPublish = decidePublish(
                    newBucket: finalTone, 
                    confidence: confidence, 
                    text: trimmed, 
                    cursorPos: lastCursorPosition
                )
                
                if shouldPublish {
                    print("📡 PUBLISH tone=\(finalTone.rawValue) confidence=\(String(format: "%.2f", confidence)) [SCOPED]")
                    maybeUpdateIndicator(to: finalTone)
                } else {
                    print("📡 SUPPRESS tone=\(finalTone.rawValue) confidence=\(String(format: "%.2f", confidence)) [SCOPED]")
                    // Update banner to show max severity across all sentences
                    let bannerTone = bannerSeverity(for: trimmed, cursorPos: lastCursorPosition)
                    let bannerBucket: Bucket = bannerTone == .alert ? .alert : (bannerTone == .caution ? .caution : .clear)
                    maybeUpdateIndicator(to: bannerBucket)
                }
            }
            
            // ✅ STORE COMPLETE SERVER RESPONSE - Store the raw server data as-is to prevent field drift
            lastAnalyzedText = trimmed
            
            // Store minimal but complete tone analysis for suggestions API
            // Use direct field access to preserve server contract
            lastToneAnalysis = [
                "text": trimmed,
                "toneAnalysis": [
                    "ui_tone": toneOut.ui_tone ?? "clear",
                    "ui_distribution": toneOut.finalDistribution,
                    "confidence": toneOut.confidence ?? 0.5,
                    "primary_tone": toneOut.primary_tone ?? "neutral",
                    "analysis": [
                        "primary_tone": toneOut.primary_tone ?? "neutral",
                        "confidence": toneOut.confidence ?? 0.5,
                        "sentiment_score": toneOut.analysis?.sentimentScore ?? 0.5
                    ]
                ]
            ]
            
            #if DEBUG
            coordLog.info("🎯 Stored COMPLETE tone analysis for optimal therapy advice - text='\(trimmed.prefix(30))' primaryTone=\(toneOut.primary_tone ?? "unknown") emotions=\(toneOut.emotions?.keys.joined(separator: ",") ?? "none")")
            #endif
        } catch {
            #if DEBUG
            coordLog.info("🎯 Analysis failed, retaining current tone: \(error.localizedDescription)")
            #endif
        }
    }
    
    // Helper to detect emotional language that should trigger alerts/cautions
    // MARK: - Tone Processing Utilities
    
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
        case .insufficient: return -2
        }
    }
    
    private func maybeUpdateIndicator(to newTone: Bucket) {
        dispatchPrecondition(condition: .onQueue(workQueue))
        
        // 📨 PUBLISH - Log the publish decision  
        print("📨 PUBLISH current=\(lastUiTone.rawValue) -> new=\(newTone.rawValue) (will update: \(newTone != lastUiTone))")
        
        guard newTone != lastUiTone else { return }
        lastUiTone = newTone
        
        // UI updates must happen on main thread
        DispatchQueue.main.async {
            self.onToneUpdate?(newTone, true)
        }
        
        #if DEBUG
        coordLog.info("🎯 [\(self.instanceId)] UI tone=\(newTone.rawValue) buckets clear=\(String(format: "%.2f", self.smoothedBuckets.clear)) caution=\(String(format: "%.2f", self.smoothedBuckets.caution)) alert=\(String(format: "%.2f", self.smoothedBuckets.alert))")
        #endif
    }
    
    // MARK: - API Response Models
    private struct ToneEnvelope<T: Decodable>: Decodable {
        let success: Bool
        let data: T
    }
    
    private struct ToneOut: Decodable {
        let ok: Bool
        let userId: String
        let text: String
        let uiTone: String?          // "clear" | "caution" | "alert" | "neutral" | "insufficient"
        let uiDistribution: Buckets? // mirrors "buckets"
        let buckets: Buckets?        // legacy alias in server
        let docTone: String?         // document-level tone
        let mode: String?
        let docSeq: Int?
        let textHash: String?
        let analysis: Analysis?
        let metadata: ToneMetadata?
        let categories: [String]?
        let intensity: Double?
        let confidence: Double?
        
        // Legacy compatibility properties
        var ui_tone: String? { return uiTone }
        var primary_tone: String? { return analysis?.primaryTone }
        var emotions: [String: Double]? { return analysis?.emotions }
        var finalDistribution: [String: Double] {
            if let buckets = uiDistribution ?? buckets {
                return ["clear": buckets.clear, "caution": buckets.caution, "alert": buckets.alert]
            }
            return [:]
        }
        var apiTone: Bucket? {
            let (resolvedToneString, _) = resolvedTone(from: self)
            guard !resolvedToneString.isEmpty else { return nil }
            switch resolvedToneString.lowercased() {
            case "clear": return .clear
            case "caution": return .caution
            case "alert": return .alert
            case "neutral": return .neutral
            default: return nil
            }
        }
        
        // Helper method for tone resolution
        func resolvedTone(from toneOut: ToneOut) -> (tone: String, buckets: Buckets?) {
            if let t = toneOut.uiTone { return (t, toneOut.uiDistribution ?? toneOut.buckets) }
            if let t = toneOut.docTone { return (t, toneOut.uiDistribution ?? toneOut.buckets) }
            if let d = toneOut.uiDistribution ?? toneOut.buckets { 
                // Same rule as server: neutral only if all within 0.05
                let vals = [d.clear, d.caution, d.alert].sorted(by: >)
                let (top, mid, low) = (vals[0], vals[1], vals[2])
                if abs(top - mid) <= 0.05 && abs(top - low) <= 0.05 { return ("neutral", d) }
                if d.alert >= d.caution && d.alert >= d.clear { return ("alert", d) }
                if d.caution >= d.clear { return ("caution", d) }
                return ("clear", d)
            }
            return ("", nil)
        }
    }
    
    private struct Buckets: Decodable {
        let clear: Double
        let caution: Double
        let alert: Double
    }
    
    private struct Analysis: Decodable {
        let primaryTone: String?
        let emotions: [String: Double]?
        let intensity: Double?
        let sentimentScore: Double?
        // Using AnyCodable for complex nested objects that we don't need to parse
        let linguisticFeatures: AnyCodable?
        let contextAnalysis: AnyCodable?
        let attachmentInsights: AnyCodable?
    }
    
    // MARK: - Tone Resolution Helpers
    
    // ✅ TRUST SERVER TONE - Use server-provided ui_tone without local overrides
    private func resolvedTone(from toneOut: ToneOut) -> (tone: String, buckets: Buckets?) {
        // Always trust server's ui_tone first (canonical contract)
        if let uiTone = toneOut.ui_tone {
            return (uiTone, toneOut.uiDistribution ?? toneOut.buckets)
        }
        
        // Fallback to docTone if ui_tone missing (shouldn't happen with tone.ts)
        if let docTone = toneOut.docTone {
            return (docTone, toneOut.uiDistribution ?? toneOut.buckets)
        }
        
        // Last resort: use "clear" default if server response corrupted
        let defaultBuckets = Buckets(clear: 1.0, caution: 0.0, alert: 0.0)
        return ("clear", defaultBuckets)
    }
    
    private struct DocumentAnalysis: Decodable {
        let safetyGateApplied: Bool?
        let docSeq: Int?
        let analysisType: String?
        let originalTone: String?
        let safetyReason: String?
        
        enum CodingKeys: String, CodingKey {
            case safetyGateApplied = "safety_gate_applied"
            case docSeq = "doc_seq"
            case analysisType = "analysis_type"
            case originalTone = "original_tone"
            case safetyReason = "safety_reason"
        }
    }
    
    private struct ToneAnalysis: Decodable {
        let primaryTone: String
        let emotions: [String: Double]?
        let intensity: Double?
        let sentimentScore: Double?
        // Using AnyCodable for complex nested objects that we don't need to parse
        let linguisticFeatures: AnyCodable?
        let contextAnalysis: AnyCodable?
        let attachmentInsights: AnyCodable?
        
        enum CodingKeys: String, CodingKey {
            case primaryTone = "primary_tone"
            case emotions
            case intensity
            case sentimentScore = "sentiment_score"
            case linguisticFeatures = "linguistic_features"
            case contextAnalysis = "context_analysis"
            case attachmentInsights = "attachment_insights"
        }
    }
    
    // Helper for decoding arbitrary JSON values
    private struct AnyCodable: Decodable {
        let value: Any
        
        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let intVal = try? container.decode(Int.self) {
                value = intVal
            } else if let doubleVal = try? container.decode(Double.self) {
                value = doubleVal
            } else if let stringVal = try? container.decode(String.self) {
                value = stringVal
            } else if let boolVal = try? container.decode(Bool.self) {
                value = boolVal
            } else if let arrayVal = try? container.decode([AnyCodable].self) {
                value = arrayVal.map { $0.value }
            } else if let dictVal = try? container.decode([String: AnyCodable].self) {
                value = dictVal.mapValues { $0.value }
            } else {
                value = NSNull()
            }
        }
    }
    
    private struct ToneMetadata: Decodable {
        let feature_noticings: [FeatureNoticing]?
    }
    
    private struct FeatureNoticing: Decodable {
        let pattern: String
        let message: String
    }
    
    private func postTone(base: String, text: String, token: String?, fullTextMode: Bool = false) async throws -> ToneOut {
        let origin = normalizedBaseURLString()
        let fullURL = "\(origin)/api/v1/tone"
        print("🌐 DEBUG: Attempting to POST to: \(fullURL)")
        
        guard let url = URL(string: fullURL) else { 
            print("❌ DEBUG: Invalid URL: \(fullURL)")
            throw URLError(.badURL) 
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = token?.nilIfEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        request.setValue(getUserId(), forHTTPHeaderField: "x-user-id")

        // Build request body based on mode
        var body: [String: Any] = [
            "text": text, 
            "context": "general", 
            "client_seq": clientSequence
        ]
        
        if fullTextMode {
            body["mode"] = "full"
            body["doc_seq"] = currentDocSeq
            body["text_hash"] = sha256(text)
            print("📄 DEBUG: Full-text mode request - docSeq: \(currentDocSeq), hash: \(sha256(text).prefix(8))")
        } else {
            body["mode"] = "legacy"
            print("📄 DEBUG: Legacy mode request")
        }
        
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        print("🌐 DEBUG: Request headers: \(self.redactSensitiveHeaders(request.allHTTPHeaderFields))")
        print("🌐 DEBUG: Request body: \(String(data: request.httpBody ?? Data(), encoding: .utf8) ?? "nil")")

        #if DEBUG
        if logGate.allow("tone_req", "\(text.count)") {
            netLog.info("🎯 [\(self.instanceId)] POST /api/v1/tone len=\(text.count)")
        }
        #endif

        print("🌐 DEBUG: Making network request...")
        let (data, response) = try await session.data(for: request)
        
        // Log HTTP response
        if let httpResponse = response as? HTTPURLResponse {
            print("🌐 DEBUG: Received response: \(httpResponse)")
            print("🌐 DEBUG: HTTP Status: \(httpResponse.statusCode)")
            
            // Check for error status codes
            switch httpResponse.statusCode {
            case 401: throw APIError.authRequired
            case 402: throw APIError.paymentRequired
            case 500...599: throw APIError.serverError(httpResponse.statusCode)
            default: break
            }
        }
        
        if let responseString = String(data: data, encoding: .utf8) {
            print("🌐 DEBUG: Response data: \(responseString)")
        }

        // Decode with proper snake_case conversion
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        
        do {
            let envelope = try decoder.decode(ToneEnvelope<ToneOut>.self, from: data)
            let (toneString, buckets) = resolvedTone(from: envelope.data)
            
            print("📄 ToneCoordinator: Analysis complete - ui_tone: \(toneString)")
            if let buckets = buckets {
                print("📄 ToneCoordinator: UI Distribution - clear: \(String(format: "%.2f", buckets.clear)), caution: \(String(format: "%.2f", buckets.caution)), alert: \(String(format: "%.2f", buckets.alert))")
            }
            
            return envelope.data
        } catch {
            print("❌ DEBUG: Envelope decode failed: \(error)")
            throw error
        }
    }
    
    // MARK: - Full Document Analysis Methods
    
    /// Apply document-level tone to UI (called by full-text analysis)
    func applyDocumentTone(uiTone: String, uiDistribution: [String: Double], confidence: Double) {
        // Convert to Bucket enum
        let bucket = Bucket.fromString(uiTone)
        
        print("📄 ToneCoordinator: Applying document tone - \(uiTone) -> \(bucket)")
        print("📄 ToneCoordinator: UI Distribution - clear: \(String(format: "%.2f", uiDistribution["clear"] ?? 0)), caution: \(String(format: "%.2f", uiDistribution["caution"] ?? 0)), alert: \(String(format: "%.2f", uiDistribution["alert"] ?? 0))")
        
        // ✅ Update internal state through the canonical path
        onQ { [weak self] in
            guard let self = self else { return }
            // Optionally keep smoothed buckets in sync too:
            self.smoothedBuckets = (
                clear: uiDistribution["clear"] ?? 0,
                caution: uiDistribution["caution"] ?? 0,
                alert: uiDistribution["alert"] ?? 0
            )
            self.maybeUpdateIndicator(to: bucket)  // updates lastUiTone + notifies UI via onToneUpdate
        }
        
        // Keep your delegate text update & suggestion request on main
        DispatchQueue.main.async { [weak self] in
            // ✅ Map insufficient to neutral for delegate (UI only expects clear|caution|alert|neutral)
            let mappedForPill: String = (bucket == .insufficient) ? "neutral" : bucket.rawValue
            self?.delegate?.didUpdateToneStatus(mappedForPill)
            
            // CRITICAL: Request suggestions after tone analysis completes
            print("📄 ToneCoordinator: Requesting suggestions after tone analysis...")
            self?.requestSuggestions()
        }
    }
    
    // MARK: - Full-Text Analysis Methods (unified ToneScheduler functionality)
    
    /// Schedule full-text analysis with smart triggering and debouncing
    /// - Parameters:
    ///   - fullText: Complete text content to analyze
    ///   - triggerReason: Why analysis was triggered (idle, punctuation, etc.)
    ///   - lastInserted: Last character typed (for smart triggering)
    ///   - isDeletion: Whether this was a deletion operation
    func scheduleFullTextAnalysis(
        fullText: String, 
        triggerReason: String = "idle",
        lastInserted: Character? = nil,
        isDeletion: Bool = false
    ) {
        let trimmed = fullText.trimmingCharacters(in: .whitespacesAndNewlines)
        let textHash = sha256(trimmed)
        
        // Reset to neutral if text is empty
        if trimmed.isEmpty {
            print("📄 ToneCoordinator: Text is empty - resetting to neutral")
            Task { @MainActor in
                self.lastUiTone = .neutral
                self.delegate?.didUpdateToneStatus("neutral")
            }
            lastTextHash = ""
            lastAnalyzedTextCount = 0
            return
        }
        
        // Skip if unchanged
        guard textHash != lastTextHash else {
            print("📄 ToneCoordinator: Skipping analysis - unchanged text")
            return
        }
        
        // Use edge-based routing instead of debounce
        Task {
            await onTextChanged(fullText: trimmed, lastInserted: lastInserted)
        }
    }
    
    /// Perform full-text analysis with enhanced rate limiting
    private func performFullTextAnalysisWithRateLimit(
        fullText: String,
        textHash: String,
        isUrgent: Bool = false
    ) async {
        // Check rate limiting with urgent bypass
        guard rateLimiter.allowRequest(isUrgent: isUrgent) else {
            dlog("🚫 Rate limited: Analysis skipped for text hash \(String(textHash.prefix(8)))")
            return
        }
        
        // Record that we're about to attempt analysis
        lastAnalyzedTextCount = fullText.count
        
        // Perform the actual analysis
        await performFullTextAnalysis(fullText: fullText, textHash: textHash)
    }
    
    /// Immediately trigger analysis (for urgent cases like punctuation)
    func scheduleImmediateFullTextAnalysis(fullText: String, triggerReason: String = "urgent") {
        let trimmed = fullText.trimmingCharacters(in: .whitespacesAndNewlines)
        let textHash = sha256(trimmed)
        
        // Reset to neutral if text is empty
        if trimmed.isEmpty {
            print("📄 ToneCoordinator: [Immediate] Text is empty - resetting to neutral")
            Task { @MainActor in
                self.lastUiTone = .neutral
                self.delegate?.didUpdateToneStatus("neutral")
            }
            lastTextHash = ""
            return
        }
        
        // Skip if unchanged
        guard textHash != lastTextHash else { return }
        
        // Reset to neutral if text is too short (but not empty)
        guard shouldAnalyzeFullText(trimmed) else {
            print("📄 ToneCoordinator: [Immediate] Text too short (\(trimmed.count) chars) - skipping analysis but keeping current tone")
            // Don't reset to neutral - this prevents premature "clear" state
            lastTextHash = textHash
            return
        }
        
        print("📄 ToneCoordinator: Immediate full-text analysis for \(trimmed.count) chars, trigger: \(triggerReason)")
        
        Task { [weak self] in
            await self?.performFullTextAnalysis(fullText: trimmed, textHash: textHash)
        }
    }
    
    /// Check if text ends with punctuation that should trigger immediate analysis
    func shouldTriggerImmediate(for text: String) -> Bool {
        let punctuation: Set<Character> = [".", "!", "?", "\n"]
        return text.last.map(punctuation.contains) ?? false
    }
    
    // MARK: - Word-Boundary Analysis
    
    /// Word-level coalescing gate to prevent analysis spam
    private func allowWordAnalysis(_ text: String) -> Bool {
        let now = CACurrentMediaTime()
        let h = wordHash(text)
        defer { lastWordHash = h; lastWordAt = now }
        return !(h == lastWordHash && (now - lastWordAt) < wordCoalesceMinGap)
    }
    
    private func wordHash(_ text: String) -> Int {
        var h = Hasher()
        h.combine(text.suffix(256)) // cheap-ish locality
        return h.finalize()
    }
    
    /// New API: analyze on word boundary with lighter coalescing
    func analyzeOnWordBoundary(fullText: String, reason: String) {
        // Skip keystroke debouncers; just coalesce *words* a bit to avoid stampede
        guard allowWordAnalysis(fullText) else { return }
        
        let trimmed = fullText.trimmingCharacters(in: .whitespacesAndNewlines)
        let textHash = sha256(trimmed)
        
        // Reset to neutral if text is empty
        if trimmed.isEmpty {
            print("📄 ToneCoordinator: [WordBoundary] Text is empty - resetting to neutral")
            Task { @MainActor in
                self.lastUiTone = .neutral
                self.delegate?.didUpdateToneStatus("neutral")
            }
            lastTextHash = ""
            return
        }
        
        // Skip if unchanged
        guard textHash != lastTextHash else { return }
        
        // Reset to neutral if text is too short (but not empty)
        guard shouldAnalyzeFullText(trimmed) else {
            print("📄 ToneCoordinator: [WordBoundary] Text too short (\(trimmed.count) chars) - skipping analysis")
            lastTextHash = textHash
            return
        }
        
        print("📄 ToneCoordinator: Word-boundary analysis for \(trimmed.count) chars, reason: \(reason)")
        
        Task { [weak self] in
            await self?.performFullTextAnalysis(fullText: trimmed, textHash: textHash)
        }
    }
    
    // MARK: - Private Full-Text Analysis Implementation
    
    private func shouldAnalyzeFullText(_ text: String) -> Bool {
        // More restrictive gating to reduce API calls: require more substantial content
        guard text.count >= 8 else { return false }  // Increased from 4 to 8 chars - reduces calls on short text
        
        let words = text.split(separator: " ").filter { !$0.isEmpty }
        guard words.count >= 2 else { return false }  // Keep at 2 words minimum
        
        // Additional: Skip very short words (likely typos/fragments)
        let meaningfulWords = words.filter { $0.count >= 2 }  // Increased from 1 to 2 to require more substantial words
        guard meaningfulWords.count >= 2 else { return false }
        
        return true
    }
    
    private func performFullTextAnalysis(fullText: String, textHash: String) async {
        // State check and mutation must happen synchronously on workQueue
        let shouldProceed = await withCheckedContinuation { continuation in
            onQ {
                guard !self.isAnalysisInFlight else {
                    print("📄 ToneCoordinator: Analysis already in flight, skipping")
                    continuation.resume(returning: false)
                    return
                }
                
                // Check client-side rate limiting
                guard self.rateLimiter.allowRequest() else {
                    print("📄 ToneCoordinator: Rate limit exceeded, skipping full-text analysis")
                    continuation.resume(returning: false)
                    return
                }
                
                // Check cache first to avoid redundant API calls
                if let cached = self.analysisCache[textHash],
                   Date().timeIntervalSince(cached.timestamp) < self.cacheExpiryInterval {
                    print("📄 ToneCoordinator: Using cached result for hash: \(textHash.prefix(8))")
                    Task {
                        await MainActor.run {
                            self.delegate?.didUpdateToneStatus(cached.tone)
                        }
                    }
                    continuation.resume(returning: false)
                    return
                }
                
                // All checks passed - proceed with analysis
                self.isAnalysisInFlight = true
                self.currentDocSeq += 1
                self.lastTextHash = textHash
                continuation.resume(returning: true)
            }
        }
        
        guard shouldProceed else { return }
        
        let docSeq = currentDocSeq
        let startTime = Date()
        
        print("📄 ToneCoordinator: Starting full-text analysis - docSeq: \(docSeq), hash: \(textHash.prefix(8)), length: \(fullText.count)")
        
        // Use updated postTone method with full-text mode
        do {
            let result = try await postTone(base: apiBaseURL, text: fullText, token: cachedAPIKey.nilIfEmpty, fullTextMode: true)
            let responseTime = Date().timeIntervalSince(startTime)
            
            // Record performance for adaptive rate limiting
            rateLimiter.recordResponse(responseTime: responseTime, hadError: false)
            
            // Handle result on workQueue to maintain thread safety
            onQ {
                self.handleFullTextAnalysisResult(result, expectedDocSeq: docSeq, expectedHash: textHash, startTime: startTime)
            }
        } catch {
            let responseTime = Date().timeIntervalSince(startTime)
            
            // Record error for adaptive rate limiting
            rateLimiter.recordResponse(responseTime: responseTime, hadError: true)
            
            // Handle error on workQueue to maintain thread safety
            onQ {
                print("📄 ToneCoordinator: Full-text analysis failed - \(error)")
                self.isAnalysisInFlight = false
            }
        }
    }
    
    private func handleFullTextAnalysisResult(_ result: ToneOut, expectedDocSeq: Int, expectedHash: String, startTime: Date) {
        // State mutations must happen on workQueue
        onQ {
            defer { self.isAnalysisInFlight = false }
            
            let duration = Date().timeIntervalSince(startTime)

            // Use the resolved tone function to get the correct values
            let (uiTone, buckets) = self.resolvedTone(from: result)
            let uiDistribution = buckets.map { ["clear": $0.clear, "caution": $0.caution, "alert": $0.alert] } ?? [:]
            let confidence = result.confidence ?? 0.0

            print("📄 ToneCoordinator: Analysis complete - docSeq: \(expectedDocSeq), ui_tone: \(uiTone), duration: \(Int(duration * 1000))ms")
            if let buckets = buckets {
                print("📄 ToneCoordinator: UI Distribution - clear: \(String(format: "%.2f", buckets.clear)), caution: \(String(format: "%.2f", buckets.caution)), alert: \(String(format: "%.2f", buckets.alert))")
            }

            // Persist full-text tone analysis event for local learning
            self.storage.storeToneAnalysisEvent(
                text: result.text,
                primaryTone: result.primary_tone ?? uiTone,
                confidence: confidence,
                uiBucket: uiTone
            )
            
            // Trigger learning after full-text analysis
            self.learner.learnNow()

            // Cache the successful analysis for fallback use in suggestions
            self.lastAnalysis = LastAnalysis(
                text: result.text,
                uiTone: uiTone,
                docSeq: expectedDocSeq,
                hash: expectedHash,
                timestamp: Date()
            )
            print("💾 Cached analysis: '\(String(result.text.prefix(50)))...', tone: \(uiTone)")

            // Cache the result for future requests
            self.analysisCache[expectedHash] = (tone: uiTone, timestamp: Date())

            // Clean up old cache entries (keep memory usage bounded)
            let now = Date()
            self.analysisCache = self.analysisCache.filter { _, cached in
                now.timeIntervalSince(cached.timestamp) < self.cacheExpiryInterval
            }

            // Apply document tone to UI directly
            self.applyDocumentTone(uiTone: uiTone, uiDistribution: uiDistribution, confidence: confidence)
        }
    }
    
    private func handleFullTextAnalysisResponse(_ response: [String: Any]?, expectedDocSeq: Int, expectedHash: String, startTime: Date) {
        // State mutations must happen on workQueue
        onQ {
            defer { self.isAnalysisInFlight = false }
            
            let duration = Date().timeIntervalSince(startTime)
            
            guard let response = response else {
                print("📄 ToneCoordinator: Analysis failed - no response")
                return
            }
            
            // Validate response matches current state
            let responseDocSeq = response["doc_seq"] as? Int ?? -1
            let responseHash = response["text_hash"] as? String ?? ""
            
            guard responseDocSeq == expectedDocSeq else {
                print("📄 ToneCoordinator: Dropping stale response - docSeq mismatch (\(responseDocSeq) != \(expectedDocSeq))")
                return
            }
            
            guard responseHash == expectedHash else {
                print("📄 ToneCoordinator: Dropping stale response - hash mismatch")
                return
            }
            
            // Extract document tone from ui_distribution (not buckets)
            let uiTone = response["ui_tone"] as? String ?? "clear"
            let uiDistribution = response["ui_distribution"] as? [String: Double] ?? ["clear": 1.0, "caution": 0.0, "alert": 0.0]
            let confidence = response["confidence"] as? Double ?? 0.0
            
            print("📄 ToneCoordinator: Analysis complete - docSeq: \(expectedDocSeq), ui_tone: \(uiTone), duration: \(Int(duration * 1000))ms")
            print("📄 ToneCoordinator: UI Distribution - clear: \(String(format: "%.2f", uiDistribution["clear"] ?? 0)), caution: \(String(format: "%.2f", uiDistribution["caution"] ?? 0)), alert: \(String(format: "%.2f", uiDistribution["alert"] ?? 0))")
            
            // Apply document tone to UI directly
            self.applyDocumentTone(uiTone: uiTone, uiDistribution: uiDistribution, confidence: confidence)
        }
    }
    
    private func sha256(_ string: String) -> String {
        let data = Data(string.utf8)
        let hash = SHA256.hash(data: data)
        return hash.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - ToneSuggestionDispatcher Conformance
extension ToneSuggestionCoordinator: ToneSuggestionDispatcher {
    func requestToneSuggestions(text: String, threadID: String) {
        #if DEBUG
        dlog("🔘 Manual tone analysis requested - text: '\(text.prefix(50))\(text.count > 50 ? "..." : "")', threadID: \(threadID)")
        #endif
        
        // Guard against spamming (inFlight protection)
        guard !isAnalysisInFlight else {
            #if DEBUG
            dlog("🚫 Analysis already in flight - ignoring manual request")
            #endif
            return
        }
        
        // Cancel any prior task before starting a new one
        if let token = quietEdgeToken {
            token.invalidate()
            quietEdgeToken = nil
            #if DEBUG
            dlog("🔄 Cancelled prior analysis timer for manual request")
            #endif
        }
        
        // Increment document sequence for new manual analysis
        currentDocSeq += 1
        
        // Call the service and publish results back to the UI
        scheduleFullTextAnalysis(
            fullText: text,
            triggerReason: "manual-tone-button-\(threadID)",
            lastInserted: nil,
            isDeletion: false
        )
    }
}

// MARK: - Helpers
private extension String { 
    var nilIfEmpty: String? { isEmpty ? nil : self } 
}
