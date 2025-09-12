//
//  EnhancedCommunicatorService.swift
//  UnsaidKeyboard
//
//  Optimized: ephemeral networking, safer Codable, retry/backoff,
//  stricter URL building, and testable DI without losing functionality.
//

import Foundation
import Network

@available(iOS 13.0, *)
final class EnhancedCommunicatorService: ObservableObject {

    // MARK: - Public DTOs (unchanged shapes)
    struct EnhancedAnalysisRequest: Codable {
        let text: String
        let context: AnalysisContext?
        let personalityProfile: PersonalityProfile?

        struct AnalysisContext: Codable {
            let relationshipPhase: String? // "new", "developing", "established", "strained"
            let stressLevel: String?       // "low", "moderate", "high"
            let messageType: String?       // "casual", "serious", "conflict", "support"
        }

        struct PersonalityProfile: Codable {
            let attachmentStyle: String
            let communicationStyle: String
            let personalityType: String
            let emotionalState: String
            let emotionalBucket: String
            let personalityScores: [String: Int]?
            let communicationPreferences: [String: String]? // NOTE: stringified for Codable
            let isComplete: Bool
            let dataFreshness: Double

            init(from bridge: PersonalityDataBridge) {
                attachmentStyle = bridge.getAttachmentStyle()
                communicationStyle = bridge.getCommunicationStyle()
                personalityType = bridge.getPersonalityType()
                emotionalState = bridge.getCurrentEmotionalState()
                emotionalBucket = bridge.getCurrentEmotionalBucket()
                isComplete = bridge.isPersonalityTestComplete()
                dataFreshness = bridge.getDataFreshness()

                let full = bridge.getPersonalityProfile()
                personalityScores = full["personality_scores"] as? [String: Int]

                if let prefs = full["communication_preferences"] as? [String: Any] {
                    // Stringify values to keep Codable lean (avoid AnyCodable)
                    var out: [String: String] = [:]
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

    struct EnhancedAnalysisResponse: Codable {
        let ok: Bool
        let userId: String
        let analysis: AnalysisResult

        struct AnalysisResult: Codable {
            let text: String
            let confidence: Double
            let attachmentScores: AttachmentScores
            let primaryStyle: String
            let microPatterns: [MicroPattern]
            let linguisticFeatures: LinguisticFeatures
            let contextualFactors: [String: Double]?
            let metadata: AnalysisMetadata

            struct AttachmentScores: Codable {
                let anxious: Double
                let avoidant: Double
                let secure: Double
                let disorganized: Double
            }

            struct MicroPattern: Codable {
                let type: String
                let pattern: String
                let weight: Double
                let position: Int?
            }

            struct LinguisticFeatures: Codable {
                let punctuation: PunctuationFeatures?
                let hesitation: HesitationFeatures?
                let complexity: ComplexityFeatures?
                let discourse: DiscourseFeatures?

                struct PunctuationFeatures: Codable {
                    let patterns: [String: Int]
                    let emotionalScore: Double
                }
                struct HesitationFeatures: Codable {
                    let patterns: [String: Int]
                    let uncertaintyScore: Double
                }
                struct ComplexityFeatures: Codable {
                    let score: Double
                    let avgWordsPerSentence: Double
                    let avgSyllablesPerWord: Double
                }
                struct DiscourseFeatures: Codable {
                    let markers: [String: Int]
                    let coherenceScore: Double
                }
            }

            struct AnalysisMetadata: Codable {
                let analysisVersion: String
                let accuracyTarget: String
                let timestamp: String
            }
        }
    }

    struct ObserveRequest: Codable {
        let text: String
        let meta: [String: String]?
        let personalityProfile: EnhancedAnalysisRequest.PersonalityProfile?
    }

    struct ObserveResponse: Codable {
        let ok: Bool
        let userId: String
        let estimate: AttachmentEstimate
        let windowComplete: Bool
        let enhancedAnalysis: EnhancedAnalysisSummary?

        struct AttachmentEstimate: Codable {
            let primary: String?
            let secondary: String?
            let scores: [String: Double]
            let confidence: Double
            let daysObserved: Int
            let windowComplete: Bool
        }

        struct EnhancedAnalysisSummary: Codable {
            let confidence: Double
            let detectedPatterns: Int
            let primaryPrediction: String
        }
    }

    struct ProfileResponse: Codable {
        let ok: Bool
        let userId: String
        let estimate: ObserveResponse.AttachmentEstimate
        let rawScores: [String: Double]
        let daysObserved: Int
        let windowComplete: Bool
        let enhancedFeatures: EnhancedFeatures?

        struct EnhancedFeatures: Codable {
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
        case decodingError
        case offline
        case cancelled

        var errorDescription: String? {
            switch self {
            case .invalidURL: return "Invalid URL"
            case .invalidResponse: return "Invalid response"
            case .serverError(let code): return "Server error: \(code)"
            case .decodingError: return "Failed to decode response"
            case .offline: return "No network connection"
            case .cancelled: return "Request cancelled"
            }
        }
    }

    // MARK: - Dependencies / Config

    private let personalityBridge = PersonalityDataBridge.shared

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
    private let networkMonitor: NWPathMonitor?

    /// Simple reachability flag (monitored if monitor provided)
    private var isOnline: Bool = true

    // MARK: - Init

    /// Designated initializer
    init(
        baseHost: String = "https://api.myunsaidapp.com",
        apiRoot: String = "/api/v1",
    apiKeyProvider: @escaping () -> String? = { AppGroups.shared.string(forKey: "unsaid_api_key") },
    userIdProvider: @escaping () -> String = { AppGroups.shared.string(forKey: "unsaid_user_id") ?? "anonymous" },
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
            self.networkMonitor = nil
            self.isOnline = true
            return
        }
        self.baseURL = url
        self.apiRoot = apiRoot
        self.apiKeyProvider = apiKeyProvider
        self.userIdProvider = userIdProvider

        self.session = EnhancedCommunicatorService.makeEphemeralSession()
        (self.encoder, self.decoder) = EnhancedCommunicatorService.makeCoders()

        if monitorNetwork {
            let monitor = NWPathMonitor()
            self.networkMonitor = monitor
            let queue = DispatchQueue(label: "com.unsaid.enhancedcomm.net")
            monitor.pathUpdateHandler = { [weak self] path in
                self?.isOnline = (path.status != .unsatisfied)
            }
            monitor.start(queue: queue)
        } else {
            self.networkMonitor = nil
            self.isOnline = true
        }
    }

    deinit {
        networkMonitor?.cancel()
    }

    // MARK: - Public API (same behavior)

    func performDetailedAnalysis(
        text: String,
        relationshipPhase: String = "established",
        stressLevel: String = "moderate",
        messageType: String = "casual"
    ) async throws -> EnhancedAnalysisResponse.AnalysisResult {

        let personalityProfile = EnhancedAnalysisRequest.PersonalityProfile(from: personalityBridge)

        let req = EnhancedAnalysisRequest(
            text: text,
            context: .init(
                relationshipPhase: relationshipPhase,
                stressLevel: stressLevel,
                messageType: messageType
            ),
            personalityProfile: personalityProfile
        )

        let res: EnhancedAnalysisResponse = try await request(
            path: "/communicator/analysis/detailed",
            method: "POST",
            body: req
        )
        return res.analysis
    }

    func observeText(
        _ text: String,
        relationshipPhase: String = "established",
        stressLevel: String = "moderate"
    ) async throws -> ObserveResponse {
        let personalityProfile = EnhancedAnalysisRequest.PersonalityProfile(from: personalityBridge)
        let req = ObserveRequest(
            text: text,
            meta: [
                "relationshipPhase": relationshipPhase,
                "stressLevel": stressLevel,
                "source": "ios_keyboard"
            ],
            personalityProfile: personalityProfile
        )
        return try await request(
            path: "/communicator/observe",
            method: "POST",
            body: req
        )
    }

    func getProfile() async throws -> ProfileResponse {
        let emptyBody: [String: String]? = nil
        return try await request(path: "/communicator/profile", method: "GET", body: emptyBody)
    }

    func checkEnhancedCapabilities() async throws -> Bool {
        let profile = try await getProfile()
        return profile.enhancedFeatures?.advancedAnalysisAvailable ?? false
    }

    // MARK: - Keyboard conveniences (unchanged)

    func getAttachmentStyleForText(_ text: String) async -> String? {
        do {
            let analysis = try await performDetailedAnalysis(text: text)
            return analysis.primaryStyle
        } catch {
            // graceful fallback to static assessment
            return personalityBridge.getAttachmentStyle()
        }
    }

    func getConfidenceForText(_ text: String) async -> Double {
        do {
            let analysis = try await performDetailedAnalysis(text: text)
            return analysis.confidence
        } catch {
            return personalityBridge.isPersonalityTestComplete() ? 0.8 : 0.3
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

    func getCombinedPersonalityInsights() -> [String: Any] {
        var insights: [String: Any] = [:]
        let profile = personalityBridge.getPersonalityProfile()
        insights["personality_assessment"] = profile
        insights["enhanced_analysis_available"] = true
        insights["data_freshness"] = personalityBridge.getDataFreshness()
        insights["assessment_complete"] = personalityBridge.isPersonalityTestComplete()
        insights["current_emotional_state"] = personalityBridge.getCurrentEmotionalState()
        insights["current_emotional_bucket"] = personalityBridge.getCurrentEmotionalBucket()
        return insights
    }

    func hasRichPersonalityData() -> Bool {
        personalityBridge.isPersonalityTestComplete() && personalityBridge.getDataFreshness() < 24
    }

    // MARK: - Private: Network Core

    private func request<T: Decodable, Body: Encodable>(
        path: String,
        method: String,
        body: Body? = nil,
        retry: Int = 1
    ) async throws -> T {

        guard isOnline else { throw CommunicatorError.offline }

        let url = buildURL(path: path)
        guard let url else { throw CommunicatorError.invalidURL }

        var req = URLRequest(url: url, timeoutInterval: 8.0)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("ios-keyboard-v2.1.0", forHTTPHeaderField: "User-Agent")
        req.setValue(userIdProvider(), forHTTPHeaderField: "X-User-Id")

        // Add idempotency key for non-GET requests to prevent duplicate server operations
        if method != "GET" {
            req.setValue(UUID().uuidString, forHTTPHeaderField: "Idempotency-Key")
        }

        if let key = apiKeyProvider(), !key.isEmpty {
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }

        if let body = body {
            req.httpBody = try encoder.encode(body)
        }
        
        // Ensure GET requests have no body
        if method == "GET" {
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
                    throw CommunicatorError.decodingError
                }
            case 408, 500, 502, 503, 504:
                if retry > 0 {
                    // Jittered exponential backoff with cap
                    let origRetry = 1 // Original retry count
                    let baseDelay = 200.0 * Double(1 << (origRetry - retry)) // Exponential backoff
                    let cappedDelay = min(baseDelay, 1200.0) // Cap at 1.2 seconds
                    let jitter = cappedDelay * (0.8 + Double.random(in: 0...0.4)) // ±20% jitter
                    try await Task.sleep(nanoseconds: UInt64(jitter * 1_000_000))
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
                let origRetry = 1
                let baseDelay = 200.0 * Double(1 << (origRetry - retry))
                let cappedDelay = min(baseDelay, 1200.0)
                let jitter = cappedDelay * (0.8 + Double.random(in: 0...0.4))
                try await Task.sleep(nanoseconds: UInt64(jitter * 1_000_000))
                return try await request(path: path, method: method, body: body, retry: retry - 1)
            }
            throw error
        }
    }

    private func buildURL(path: String) -> URL? {
        // Guaranteed: baseURL has no trailing slash; apiRoot should start with "/"
        // Path should start with "/" relative to apiRoot.
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        let cleanedRoot = apiRoot.hasPrefix("/") ? apiRoot : "/\(apiRoot)"
        let cleanedPath = path.hasPrefix("/") ? path : "/\(path)"
        components?.path = cleanedRoot + cleanedPath
        return components?.url
    }

    // MARK: - Static helpers

    private static func makeCoders() -> (JSONEncoder, JSONDecoder) {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
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
        return URLSession(configuration: cfg)
    }
}
