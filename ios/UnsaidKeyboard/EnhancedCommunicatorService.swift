//
//  EnhancedCommunicatorService.swift
//  UnsaidKeyboard
//
//  Optimized: ephemeral networking, safer Codable, retry/backoff,
//  stricter URL building, and testable DI without losing functionality.
//

import Foundation
import Network

// MARK: - Thread-safe, reusable connectivity
actor Connectivity {
    static let shared = Connectivity()
    private let monitor = NWPathMonitor()
    private(set) var isOnline = true
    private(set) var isConstrained = false
    private(set) var isExpensive = false

    private init() {
        let q = DispatchQueue(label: "net.connectivity")
        monitor.pathUpdateHandler = { path in
            Task { [isOn = (path.status == .satisfied),
                    cons = path.isConstrained,
                    exp = path.isExpensive] in
                await Connectivity.shared.update(isOn: isOn, cons: cons, exp: exp)
            }
        }
        monitor.start(queue: q)
    }

    private func update(isOn: Bool, cons: Bool, exp: Bool) {
        isOnline = isOn; isConstrained = cons; isExpensive = exp
    }
}

// MARK: - HTTP Method enum for type safety
private enum HTTPMethod: String {
    case GET, POST
}

@available(iOS 13.0, *)
final class EnhancedCommunicatorService {

    // MARK: - Public DTOs (unchanged shapes)
    struct EnhancedAnalysisRequest: Codable, Sendable {
        let text: String
        let context: AnalysisContext?
        let personalityProfile: PersonalityProfile?

        struct AnalysisContext: Codable, Sendable {
            let relationshipPhase: String? // "new", "developing", "established", "strained"
            let stressLevel: String?       // "low", "moderate", "high"
            let messageType: String?       // "casual", "serious", "conflict", "support"
        }

        struct PersonalityProfile: Codable, Sendable {
            let attachmentStyle: String
            let communicationStyle: String
            let personalityType: String
            let emotionalState: String
            let emotionalBucket: String
            let personalityScores: [String: Int]?
            let communicationPreferences: [String: String]? // NOTE: stringified for Codable
            let isComplete: Bool
            let dataFreshness: Double

            init(from bridge: PersonalityDataBridge) async {
                async let a = bridge.getAttachmentStyle()
                async let c = bridge.getCommunicationStyle()
                async let p = bridge.getPersonalityType()
                async let e = bridge.getCurrentEmotionalState()
                async let b = bridge.getCurrentEmotionalBucket()
                async let done = bridge.isPersonalityTestComplete()
                async let fresh = bridge.getDataFreshness()
                async let full = bridge.getPersonalityProfile()

                attachmentStyle = await a
                communicationStyle = await c
                personalityType = await p
                emotionalState = await e
                emotionalBucket = await b
                isComplete = await done
                dataFreshness = await fresh

                let dict = await full
                personalityScores = dict["personality_scores"] as? [String: Int]

                if let prefs = dict["communication_preferences"] as? [String: Any] {
                    // Stringify values to keep Codable lean (avoid AnyCodable)
                    var out: [String: String] = [:]
                    out.reserveCapacity(prefs.count)
                    for (k, v) in prefs {
                        out[k] = String(describing: v)
                    }
                    communicationPreferences = out
                } else {
                    communicationPreferences = nil
                }
            }
        }
    }

    struct EnhancedAnalysisResponse: Codable, Sendable {
        let ok: Bool
        let userId: String
        let analysis: AnalysisResult

        struct AnalysisResult: Codable, Sendable {
            let text: String
            let confidence: Double
            let attachmentScores: AttachmentScores
            let primaryStyle: String
            let microPatterns: [MicroPattern]
            let linguisticFeatures: LinguisticFeatures
            let contextualFactors: [String: Double]?
            let metadata: AnalysisMetadata

            struct AttachmentScores: Codable, Sendable {
                let anxious: Double
                let avoidant: Double
                let secure: Double
                let disorganized: Double
            }

            struct MicroPattern: Codable, Sendable {
                let type: String
                let pattern: String
                let weight: Double
                let position: Int?
            }

            struct LinguisticFeatures: Codable, Sendable {
                let punctuation: PunctuationFeatures?
                let hesitation: HesitationFeatures?
                let complexity: ComplexityFeatures?
                let discourse: DiscourseFeatures?

                struct PunctuationFeatures: Codable, Sendable {
                    let patterns: [String: Int]
                    let emotionalScore: Double
                }
                struct HesitationFeatures: Codable, Sendable {
                    let patterns: [String: Int]
                    let uncertaintyScore: Double
                }
                struct ComplexityFeatures: Codable, Sendable {
                    let score: Double
                    let avgWordsPerSentence: Double
                    let avgSyllablesPerWord: Double
                }
                struct DiscourseFeatures: Codable, Sendable {
                    let markers: [String: Int]
                    let coherenceScore: Double
                }
            }

            struct AnalysisMetadata: Codable, Sendable {
                let analysisVersion: String
                let accuracyTarget: String
                let timestamp: String
            }
        }
    }

    struct ObserveRequest: Codable, Sendable {
        let text: String
        let meta: [String: String]?
        let personalityProfile: EnhancedAnalysisRequest.PersonalityProfile?
    }

    struct ObserveResponse: Codable, Sendable {
        let ok: Bool
        let userId: String
        let estimate: AttachmentEstimate
        let windowComplete: Bool
        let enhancedAnalysis: EnhancedAnalysisSummary?

        struct AttachmentEstimate: Codable, Sendable {
            let primary: String?
            let secondary: String?
            let scores: [String: Double]
            let confidence: Double
            let daysObserved: Int
            let windowComplete: Bool
        }

        struct EnhancedAnalysisSummary: Codable, Sendable {
            let confidence: Double
            let detectedPatterns: Int
            let primaryPrediction: String
        }
    }

    struct ProfileResponse: Codable, Sendable {
        let ok: Bool
        let userId: String
        let estimate: ObserveResponse.AttachmentEstimate
        let rawScores: [String: Double]
        let daysObserved: Int
        let windowComplete: Bool
        let enhancedFeatures: EnhancedFeatures?

        struct EnhancedFeatures: Codable, Sendable {
            let advancedAnalysisAvailable: Bool
            let version: String
            let accuracyTarget: String
            let features: [String]
        }
    }

    enum CommunicatorError: LocalizedError {
        case invalidURL
        case invalidResponse
        case serverError(Int)
        case authRequired
        case paymentRequired
        case decodingError
        case offline
        case cancelled

        var errorDescription: String? {
            switch self {
            case .invalidURL: return "Invalid URL"
            case .invalidResponse: return "Invalid response"
            case .serverError(let code): return "Server error: \(code)"
            case .authRequired: return "Authentication required"
            case .paymentRequired: return "Payment required - trial expired"
            case .decodingError: return "Failed to decode response"
            case .offline: return "No network connection"
            case .cancelled: return "Request cancelled"
            }
        }
    }

    // MARK: - Dependencies / Config

    private let personalityBridge = PersonalityDataBridge.shared
    private let learner: CommunicationPatternLearner
    private let storage = SafeKeyboardDataStorage.shared

    /// Base host, no trailing slash, no `/api/v1` suffixed here.
    private let baseURL: URL
    /// API root path (e.g., `/api/v1`) so you can bump versions once.
    private let apiRoot: String

    /// Injectables for better testability
    private let session: URLSession
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let userIdProvider: () -> String
    private let apiKeyProvider: () -> String?          // optional bearer token
    private let onlineCheck: () async -> Bool

    // MARK: - Init

    /// Designated initializer
    init(
        baseHost: String = "https://api.myunsaidapp.com",
        apiRoot: String = "/api/v1",
        apiKeyProvider: @escaping () -> String? = { 
            let appGroupId = "group.com.example.unsaid"
            return UserDefaults(suiteName: appGroupId)?.string(forKey: "unsaid_api_key")
        },
        userIdProvider: @escaping () -> String = { 
            let userIdKey = "unsaid_user_id"
            let appGroupId = "group.com.example.unsaid"
            
            if let sharedDefaults = UserDefaults(suiteName: appGroupId),
               let userId = sharedDefaults.string(forKey: userIdKey) {
                return userId
            }
            
            // Fallback to a UUID if somehow not set
            let fallbackId = UUID().uuidString
            if let sharedDefaults = UserDefaults(suiteName: appGroupId) {
                sharedDefaults.set(fallbackId, forKey: userIdKey)
            }
            return fallbackId
        },
        monitorNetwork: Bool = true
    ) {
        // Base URL validation
        guard let url = URL(string: baseHost) else {
            // Fall back to a benign URL to avoid crashes; calls will throw later.
            self.baseURL = URL(string: "https://invalid.local")!
            self.apiRoot = apiRoot
            self.apiKeyProvider = apiKeyProvider
            self.userIdProvider = userIdProvider
            self.session = EnhancedCommunicatorService.makeEphemeralSession()
            (self.encoder, self.decoder) = EnhancedCommunicatorService.makeCoders()
            self.learner = CommunicationPatternLearner(bridge: personalityBridge, windowDays: 7)
            self.onlineCheck = { true }
            return
        }
        self.baseURL = url
        self.apiRoot = apiRoot
        self.apiKeyProvider = apiKeyProvider
        self.userIdProvider = userIdProvider

        self.session = EnhancedCommunicatorService.makeEphemeralSession()
        (self.encoder, self.decoder) = EnhancedCommunicatorService.makeCoders()
        self.learner = CommunicationPatternLearner(bridge: personalityBridge, windowDays: 7)

        if monitorNetwork {
            _ = Connectivity.shared // start once
            self.onlineCheck = { await Connectivity.shared.isOnline }
        } else {
            self.onlineCheck = { true }
        }
    }

    // MARK: - Public API (same behavior)

    func performDetailedAnalysis(
        text: String,
        relationshipPhase: String = "established",
        stressLevel: String = "moderate",
        messageType: String = "casual"
    ) async throws -> EnhancedAnalysisResponse.AnalysisResult {

        let t0 = Date()
        let personalityProfile = await EnhancedAnalysisRequest.PersonalityProfile(from: personalityBridge)
        
        // Trim text size to reduce payload (API typically only needs last 3k chars)
        let safeText = String(text.suffix(3000))

        let req = EnhancedAnalysisRequest(
            text: safeText,
            context: .init(
                relationshipPhase: relationshipPhase,
                stressLevel: stressLevel,
                messageType: messageType
            ),
            personalityProfile: personalityProfile
        )

        let res: EnhancedAnalysisResponse = try await request(
            path: "/tone",
            method: HTTPMethod.POST,
            body: req
        )
        
        // Extract categories properly as [String]? for learner
        let cats: [String]? = !res.analysis.microPatterns.isEmpty
            ? Array(Set(res.analysis.microPatterns.map { $0.type }))  // preferred: pattern types
            : res.analysis.contextualFactors.map { Array($0.keys) }   // fallback: factor names
        
        // 🔐 Persist a minimal tone sample for local learning
        let toneStatus = mapToToneStatus(res.analysis.primaryStyle)
        storage.recordToneAnalysis(
            text: String(text.suffix(1024)),
            tone: toneStatus,
            confidence: res.analysis.confidence,
            analysisTime: Date().timeIntervalSince(t0),
            categories: cats
        )

        // 🔁 Kick the learner (non-blocking)
        Task { _ = await learner.learnNow() }

        return res.analysis
    }
    
    // Helper to map API response to ToneStatus enum (fallback when no direct tone)
    private func mapToToneStatus(_ primaryStyle: String) -> ToneStatus {
        // Keep as fallback - attachment style to tone mapping
        switch primaryStyle.lowercased() {
        case "secure": return .clear
        case "anxious": return .alert  
        case "avoidant": return .caution
        default: return .neutral
        }
    }

    func observeText(
        _ text: String,
        relationshipPhase: String = "established",
        stressLevel: String = "moderate"
    ) async throws -> ObserveResponse {
        let personalityProfile = await EnhancedAnalysisRequest.PersonalityProfile(from: personalityBridge)
        
        // Store learning data locally instead of sending to server
        let trimmed = String(text.suffix(3000))
        
        // Persist a lightweight interaction sample
        storage.recordAnalytics(
            event: "text_observation",
            data: [
                "text_length": "\(trimmed.count)",
                "relationship_phase": relationshipPhase,
                "stress_level": stressLevel,
                "attachment_style": personalityProfile.attachmentStyle
            ]
        )
        
        // Run learner now to get live estimate
        let rollup = await learner.learnNow()
        
        return ObserveResponse(
            ok: true,
            userId: userIdProvider(),
            estimate: .init(
                primary: rollup.primary,
                secondary: nil,
                scores: rollup.scores,
                confidence: rollup.confidence,
                daysObserved: rollup.daysObserved,
                windowComplete: rollup.windowComplete
            ),
            windowComplete: rollup.windowComplete,
            enhancedAnalysis: .init(
                confidence: rollup.confidence,
                detectedPatterns: rollup.samples,
                primaryPrediction: rollup.primary
            )
        )
    }

    func getProfile() async throws -> ProfileResponse {
        // Get profile data locally from PersonalityDataBridge instead of server
        let personalityProfile = await EnhancedAnalysisRequest.PersonalityProfile(from: personalityBridge)
        let daysObserved = personalityProfile.isComplete ? 7 : 3
        
        return ProfileResponse(
            ok: true,
            userId: userIdProvider(),
            estimate: .init(
                primary: personalityProfile.attachmentStyle,
                secondary: personalityProfile.communicationStyle,
                scores: personalityProfile.personalityScores?.mapValues { Double($0) } ?? [:],
                confidence: personalityProfile.isComplete ? 0.9 : 0.5,
                daysObserved: daysObserved,
                windowComplete: personalityProfile.isComplete
            ),
            rawScores: personalityProfile.personalityScores?.mapValues { Double($0) } ?? [:],
            daysObserved: daysObserved,
            windowComplete: personalityProfile.isComplete,
            enhancedFeatures: .init(
                advancedAnalysisAvailable: true,
                version: "2.0.0-local",
                accuracyTarget: "92%+",
                features: ["local_storage", "real_time_learning", "privacy_first"]
            )
        )
    }

    func checkEnhancedCapabilities() async throws -> Bool {
        let profile = try await getProfile()
        return profile.enhancedFeatures?.advancedAnalysisAvailable ?? false
    }

    // MARK: - Public Learning API
    
    /// Trigger on-demand learning update (for app foreground, periodic refresh)
    public func runLearningTick() async -> ObserveResponse.AttachmentEstimate {
        let rollup = await learner.learnNow()
        return ObserveResponse.AttachmentEstimate(
            primary: rollup.primary,
            secondary: rollup.scores.sorted(by: { $0.value > $1.value }).dropFirst().first?.key,
            scores: rollup.scores,
            confidence: rollup.confidence,
            daysObserved: rollup.daysObserved,
            windowComplete: rollup.windowComplete
        )
    }

    // MARK: - Keyboard conveniences (unchanged)

    func getAttachmentStyleForText(_ text: String) async -> String? {
        do {
            let analysis = try await performDetailedAnalysis(text: text)
            return analysis.primaryStyle
        } catch {
            // graceful fallback to static assessment
            return await personalityBridge.getAttachmentStyle()
        }
    }

    func getConfidenceForText(_ text: String) async -> Double {
        do {
            let analysis = try await performDetailedAnalysis(text: text)
            return analysis.confidence
        } catch {
            return await personalityBridge.isPersonalityTestComplete() ? 0.8 : 0.3
        }
    }

    func getMicroPatternsForText(_ text: String) async -> [String] {
        do {
            let analysis = try await performDetailedAnalysis(text: text)
            return analysis.microPatterns.map { $0.pattern }
        } catch {
            return []
        }
    }

    func getCombinedPersonalityInsights() async -> [String: Any] {
        var insights: [String: Any] = [:]
        let profile = await personalityBridge.getPersonalityProfile()
        insights["personality_assessment"] = profile
        insights["enhanced_analysis_available"] = true
        insights["data_freshness"] = await personalityBridge.getDataFreshness()
        insights["assessment_complete"] = await personalityBridge.isPersonalityTestComplete()
        insights["current_emotional_state"] = await personalityBridge.getCurrentEmotionalState()
        insights["current_emotional_bucket"] = await personalityBridge.getCurrentEmotionalBucket()
        return insights
    }

    func hasRichPersonalityData() async -> Bool {
        let isComplete = await personalityBridge.isPersonalityTestComplete()
        let freshness = await personalityBridge.getDataFreshness()
        return isComplete && freshness < 24
    }

    // MARK: - Private: Network Core

    private func maybeGzip(_ data: Data) -> (data: Data, contentEncoding: String?) {
        guard data.count > 1024 else { return (data, nil) }
        if let deflated = (try? (data as NSData).compressed(using: .zlib)) as Data? {
            return (deflated, "deflate") // ✅ correct header for zlib/deflate
        }
        return (data, nil)
    }

    private func request<T: Decodable, Body: Encodable>(
        path: String,
        method: HTTPMethod,
        body: Body? = nil,
        retry: Int = 1
    ) async throws -> T {

        guard await onlineCheck() else { throw CommunicatorError.offline }

        let url = buildURL(path: path)
        guard let url else { throw CommunicatorError.invalidURL }

        #if DEBUG
        print("🔧 CommunicatorService REQUEST \(url.absoluteString)")
        #endif

        var req = URLRequest(url: url, timeoutInterval: method == .GET ? 6.0 : 8.0)
        req.httpMethod = method.rawValue
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("ios-keyboard-v2.1.0", forHTTPHeaderField: "User-Agent")
        req.setValue(userIdProvider(), forHTTPHeaderField: "X-User-Id")

        // Add idempotency key for non-GET requests to prevent duplicate server operations
        if method != .GET {
            req.setValue(UUID().uuidString, forHTTPHeaderField: "Idempotency-Key")
        }

        if let key = apiKeyProvider(), !key.isEmpty {
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }

        if let body = body {
            let raw = try encoder.encode(body)
            let zipped = maybeGzip(raw)
            req.httpBody = zipped.data
            if let enc = zipped.contentEncoding {
                req.setValue(enc, forHTTPHeaderField: "Content-Encoding")
            }
        }
        
        // Ensure GET requests have no body
        if method == .GET {
            req.httpBody = nil
        }

        do {
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse else { throw CommunicatorError.invalidResponse }

            switch http.statusCode {
            case 200..<300:
                do { 
                    return try decoder.decode(T.self, from: data) 
                } catch {
                    #if DEBUG
                    print("Decoding failed for \(T.self):", error, String(data: data, encoding: .utf8) ?? "<non-utf8>")
                    #endif
                    throw CommunicatorError.decodingError
                }
            case 401:
                throw CommunicatorError.authRequired
            case 402:
                throw CommunicatorError.paymentRequired
            case 408, 500, 502, 503, 504:
                if retry > 0 {
                    let attemptIndex = 1 - retry // 0 for first retry when retry==1
                    try await sleepForBackoff(attempt: max(0, attemptIndex))
                    return try await request(path: path, method: method, body: body, retry: retry - 1)
                }
                throw CommunicatorError.serverError(http.statusCode)
            default:
                throw CommunicatorError.serverError(http.statusCode)
            }
        } catch is CancellationError {
            throw CommunicatorError.cancelled
        } catch {
            // Retry once for transient network errors with jittered backoff
            if retry > 0 {
                let attemptIndex = 1 - retry
                try await sleepForBackoff(attempt: max(0, attemptIndex))
                return try await request(path: path, method: method, body: body, retry: retry - 1)
            }
            throw error
        }
    }

    private func sleepForBackoff(attempt: Int, baseMs: Double = 200, capMs: Double = 1200) async throws {
        // attempt: 0,1,...  (0 = first retry)
        let exp = min(capMs, baseMs * pow(2, Double(attempt)))
        let jitter = exp * (0.8 + Double.random(in: 0...0.4))
        try await Task.sleep(nanoseconds: UInt64(jitter * 1_000_000))
    }

    private func buildURL(path: String) -> URL? {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        let basePath = components?.percentEncodedPath ?? ""
        let root = apiRoot.hasPrefix("/") ? apiRoot : "/\(apiRoot)"
        let leaf = path.hasPrefix("/") ? path : "/\(path)"
        components?.percentEncodedPath = basePath + root + leaf
        return components?.url
    }

    // MARK: - Static helpers

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoBasic: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static func makeCoders() -> (JSONEncoder, JSONDecoder) {
        let enc = JSONEncoder()
        let dec = JSONDecoder()
        
        // ISO8601 with fractional seconds for precise timing
        enc.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(Self.iso.string(from: date))
        }
        
        dec.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            
            // Try with fractional seconds first, fallback to standard
            if let date = Self.iso.date(from: string) {
                return date
            }
            
            // Fallback for non-fractional ISO8601
            if let date = Self.isoBasic.date(from: string) {
                return date
            }
            
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid date format: \(string)")
        }
        
        return (enc, dec)
    }

    private static func makeEphemeralSession() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.allowsConstrainedNetworkAccess = true
        cfg.allowsExpensiveNetworkAccess = true
        cfg.httpShouldUsePipelining = true
        cfg.httpMaximumConnectionsPerHost = 2
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.timeoutIntervalForRequest = 8
        cfg.timeoutIntervalForResource = 15
        cfg.waitsForConnectivity = false
        cfg.httpCookieAcceptPolicy = .never
        cfg.httpCookieStorage = nil
        cfg.tlsMinimumSupportedProtocolVersion = .TLSv12
        return URLSession(configuration: cfg)
    }
}
