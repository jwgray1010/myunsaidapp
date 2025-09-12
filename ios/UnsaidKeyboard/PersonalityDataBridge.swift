//
//  PersonalityDataBridge.swift
//  UnsaidKeyboard
//
//  Lightweight bridge for personality data shared via App Group UserDefaults.
//  Keeps a tiny in-memory cache with TTL and batches writes to reduce I/O.
//

import Foundation
import os.log

// MARK: - Light typed model
struct PersonalityProfile: Codable {
    var attachmentStyle: String = "secure"
    var communicationStyle: String = "direct"
    var personalityType: String = "analytical"
    var emotionalState: String = "neutral"
    var emotionalBucket: String = "moderate"
    var profanityLevel: Int = 2  // 1-5 scale
    var sarcasmLevel: Int = 2    // 1-5 scale

    var scores: [String: Int]? = nil
    var preferences: [String: AnyCodable]? = nil
    var partnerAttachmentStyle: String? = nil
    var relationshipContext: String? = nil

    var isComplete: Bool = false
    var lastUpdate: Date? = nil
    var version: String = "v2.0"

    // Encode to a flat dictionary compatible with UserDefaults
    func toDictionary() -> [String: Any] {
        var d: [String: Any] = [
            "attachment_style": attachmentStyle,
            "communication_style": communicationStyle,
            "personality_type": personalityType,
            "currentEmotionalState": emotionalState,
            "currentEmotionalStateBucket": emotionalBucket,
            "profanity_level": profanityLevel,
            "sarcasm_level": sarcasmLevel,
            "personality_test_complete": isComplete,
            "personality_data_version": version
        ]
        if let last = lastUpdate { d["personality_last_update"] = last }
        if let s = scores { d["personality_scores"] = s }
        if let p = preferences { d["communication_preferences"] = p.mapValues { $0.value } }
        if let partner = partnerAttachmentStyle { d["partner_attachment_style"] = partner }
        if let ctx = relationshipContext { d["relationship_context"] = ctx }
        return d
    }
}

// AnyCodable for small, safe downcasting to UserDefaults
struct AnyCodable: Codable {
    let value: Any
    init(_ value: Any) { self.value = value }
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let i = try? c.decode(Int.self) { value = i }
        else if let d = try? c.decode(Double.self) { value = d }
        else if let b = try? c.decode(Bool.self) { value = b }
        else if let s = try? c.decode(String.self) { value = s }
        else if let dict = try? c.decode([String: AnyCodable].self) { value = dict.mapValues { $0.value } }
        else if let arr = try? c.decode([AnyCodable].self) { value = arr.map { $0.value } }
        else { value = NSNull() }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch value {
        case let v as Int: try c.encode(v)
        case let v as Double: try c.encode(v)
        case let v as Bool: try c.encode(v)
        case let v as String: try c.encode(v)
        case let v as [String: Any]:
            try c.encode(Dictionary(uniqueKeysWithValues: v.map { ($0.key, AnyCodable($0.value)) }))
        case let v as [Any]:
            try c.encode(v.map { AnyCodable($0) })
        default: try c.encodeNil()
        }
    }
}

// MARK: - Bridge
final class PersonalityDataBridge {

    static let shared = PersonalityDataBridge()

    // App group (hard‑coded identifier to avoid build ordering issues if AppGroups enum not seen)
    // NOTE: This should match AppGroups.id. If AppGroups is available at compile time, consider refactoring
    // back to `AppGroups.shared` for single‑source configuration.
    // Use central AppGroups if visible; if build ordering temporarily hides it, fall back to suite directly.
    private let ud: UserDefaults = {
        #if canImport(UIKit) // dummy condition just to allow compilation branch
        if let suite = UserDefaults(suiteName: "group.com.example.unsaid") {
            return suite
        }
        #endif
        return UserDefaults(suiteName: "group.com.example.unsaid") ?? .standard
    }()

    // Logging (throttled)
    private let logger = Logger(subsystem: "com.example.unsaid.unsaid.UnsaidKeyboard", category: "PersonalityDataBridge")
    private var lastLog: [String: Date] = [:]
    private let logWindow: TimeInterval = 1.0

    // Small cache to reduce cross-process reads
    private var cache: [String: Any] = [:]
    private var cacheStamp: Date = .distantPast
    private let cacheTTL: TimeInterval = 10 // seconds—short and safe

    // Batched write buffer
    private var pendingWrites: [String: Any] = [:]

    private init() {
        log("Bridge ready (app group defaults active)", level: .info)
    }

    // MARK: - Public lightweight getters (used by keyboard)

    // Quick getters for common lookups
    func getAttachmentStyle() -> String { string("attachment_style", fallback: "secure") }
    func getCommunicationStyle() -> String { string("communication_style", fallback: "direct") }
    func getPersonalityType() -> String { string("personality_type", fallback: "analytical") }
    func getCurrentEmotionalState() -> String { string("currentEmotionalState", fallback: "neutral") }
    func getCurrentEmotionalBucket() -> String { string("currentEmotionalStateBucket", fallback: "moderate") }
    func getProfanityLevel() -> Int { ud.integer(forKey: "profanity_level") > 0 ? ud.integer(forKey: "profanity_level") : 2 }
    func getSarcasmLevel() -> Int { ud.integer(forKey: "sarcasm_level") > 0 ? ud.integer(forKey: "sarcasm_level") : 2 }

    /// Returns a flattened profile dictionary suitable for API payloads.
    func getPersonalityProfile() -> [String: Any] {
        refreshCacheIfStale()
        var profile: [String: Any] = [
            "attachment_style": getAttachmentStyle(),
            "communication_style": getCommunicationStyle(),
            "personality_type": getPersonalityType(),
            "emotional_state": getCurrentEmotionalState(),
            "emotional_bucket": getCurrentEmotionalBucket(),
            "is_complete": ud.bool(forKey: "personality_test_complete")
        ]
        if let scores = ud.dictionary(forKey: "personality_scores") {
            profile["personality_scores"] = scores
        }
        if let prefs = ud.dictionary(forKey: "communication_preferences") {
            profile["communication_preferences"] = prefs
        }
        if let partner = ud.string(forKey: "partner_attachment_style") {
            profile["partner_attachment_style"] = partner
        }
        if let ctx = ud.string(forKey: "relationship_context") {
            profile["relationship_context"] = ctx
        }
        profile["data_freshness"] = getDataFreshness()
        return profile
    }

    func isPersonalityTestComplete() -> Bool {
        ud.bool(forKey: "personality_test_complete")
    }

    /// Hours since last update, or -1 if unknown.
    func getDataFreshness() -> Double {
        guard let date = ud.object(forKey: "personality_last_update") as? Date else { return -1 }
        return Date().timeIntervalSince(date) / 3600.0
    }

    // MARK: - Writer APIs used by the runner (batched & minimal)

    func storePersonalityData(_ profile: PersonalityProfile) {
        writeTransaction(profile.toDictionary().merging([
            "personality_data_v2": profile.toDictionary(),
            "personality_test_complete": profile.isComplete,
            "personality_data_version": profile.version,
            "personality_last_update": profile.lastUpdate ?? Date(),
            "sync_status": "synced",
            "last_sync_timestamp": Date().timeIntervalSince1970
        ]) { $1 })
        log("Stored personality profile", level: .info)
    }

    func storeEmotionalState(state: String, bucket: String, label: String) {
        writeTransaction([
            "currentEmotionalState": state,
            "currentEmotionalStateBucket": bucket,
            "emotional_state_label": label,
            "emotional_state_timestamp": Date().timeIntervalSince1970,
            "personality_last_update": Date()
        ])
        log("Updated emotional state (\(label))", level: .info)
    }

    func storeRelationshipContext(partnerStyle: String? = nil, context: String? = nil) {
        var payload: [String: Any] = ["personality_last_update": Date()]
        if let p = partnerStyle { payload["partner_attachment_style"] = p }
        if let c = context { payload["relationship_context"] = c }
        writeTransaction(payload)
        log("Updated relationship context", level: .info)
    }

    func markSyncPending() { writeTransaction(["sync_status": "pending"]) }
    func markSyncComplete() {
        writeTransaction([
            "sync_status": "synced",
            "last_sync_timestamp": Date().timeIntervalSince1970
        ])
    }

    func needsSync() -> Bool {
        let status = ud.string(forKey: "sync_status") ?? "never"
        let last = ud.double(forKey: "last_sync_timestamp")
        return status != "synced" || (Date().timeIntervalSince1970 - last) > 300
    }

    func clearAllData() {
        let allKeys = [
            "personality_data_v2", "attachment_style", "communication_style", "personality_type",
            "dominant_type_label", "personality_scores", "communication_preferences",
            "currentEmotionalState", "currentEmotionalStateBucket", "emotional_state_label", "emotional_state_timestamp",
            "partner_attachment_style", "relationship_context",
            "personality_data_version", "personality_last_update", "personality_test_complete", "sync_status", "last_sync_timestamp"
        ]
        for key in allKeys {
            ud.removeObject(forKey: key)
        }
        cache.removeAll()
        cacheStamp = .distantPast
        log("Cleared personality data", level: .info)
    }
}

// MARK: - Internals

private extension PersonalityDataBridge {

    func string(_ key: String, fallback: String) -> String {
        refreshCacheIfStale()
        if let v = cache[key] as? String { return v }
        return ud.string(forKey: key) ?? fallback
    }

    func refreshCacheIfStale() {
        guard Date().timeIntervalSince(cacheStamp) >= cacheTTL else { return }
        var newCache: [String: Any] = [:]
        // Small set only; avoid pulling large blobs
        let keys = [
            "attachment_style", "communication_style", "personality_type",
            "currentEmotionalState", "currentEmotionalStateBucket",
            "personality_test_complete", "personality_last_update"
        ]
        for k in keys {
            newCache[k] = ud.object(forKey: k)
        }
        cache = newCache
        cacheStamp = Date()
    }

    func writeTransaction(_ fields: [String: Any]) {
        // Buffer
        for (k, v) in fields { pendingWrites[k] = v }
        // Flush immediately for keyboard <-> host coherence but as one pass
    for (k, v) in pendingWrites { ud.set(v, forKey: k) }
        pendingWrites.removeAll()
        cacheStamp = .distantPast // invalidate cache
    }

    func log(_ msg: String, level: OSLogType) {
        let key = "\(level.rawValue):\(msg)"
        let now = Date()
        if let last = lastLog[key], now.timeIntervalSince(last) < logWindow { return }
        lastLog[key] = now
        switch level {
        case .error: logger.error("\(msg)")
        case .info:  logger.info("\(msg)")
        default:     logger.debug("\(msg)")
        }
    }
}

// MARK: - Removed PersonalityKeys extension as we're using string literals directly

// MARK: - Attachment Learning Extensions
extension PersonalityDataBridge {
    private var udSafe: UserDefaults { ud }

    func getAttachmentLearningStartedAt() -> TimeInterval? {
    udSafe.double(forKey: "attachment_learning_started_at").nilIfZero
    }

    func markAttachmentLearningStartedIfNeeded(days: Int = 7) {
        if udSafe.object(forKey: "attachment_learning_started_at") == nil {
            udSafe.set(Date().timeIntervalSince1970, forKey: "attachment_learning_started_at")
            udSafe.set(days, forKey: "attachment_learning_days")
            log("Started attachment learning window (\(days) days)", level: .info)
        }
    }

    func setLearnerAttachmentStyle(_ style: String, confidence: Double?, source: String = "backend") {
    udSafe.set(style, forKey: "learner_attachment_style")
    if let c = confidence { udSafe.set(c, forKey: "attachment_confidence") }
    udSafe.set(source, forKey: "attachment_source")
        log("Set learner attachment style: \(style) (confidence: \(confidence ?? 0))", level: .info)
    }

    func markAttachmentConfirmed(style: String, source: String) {
        udSafe.set(style, forKey: "attachment_style")
        udSafe.set(Date(), forKey: "attachment_confirmed_at")
        udSafe.set(source, forKey: "attachment_source")
        udSafe.set(true, forKey: "personality_test_complete")
        log("Confirmed attachment style: \(style) (source: \(source))", level: .info)
    }

    func isLearningWindowComplete() -> Bool {
        let start = getAttachmentLearningStartedAt() ?? 0
        guard start > 0 else { return false }
    let rawDays1 = udSafe.integer(forKey: "attachment_learning_days")
        let days = rawDays1 == 0 ? 7 : rawDays1
        return Date().timeIntervalSince1970 - start >= Double(days) * 86400.0
    }

    func learningDaysRemaining() -> Int {
        let start = getAttachmentLearningStartedAt() ?? 0
        guard start > 0 else { return 7 }
    let rawDays2 = udSafe.integer(forKey: "attachment_learning_days")
        let days = rawDays2 == 0 ? 7 : rawDays2
        let elapsed = Date().timeIntervalSince1970 - start
        let remain = Int(ceil((Double(days) * 86400.0 - elapsed) / 86400.0))
        return max(0, remain)
    }

    func isNewUser() -> Bool {
        // New if we haven't started learning and test isn't complete
        return (getAttachmentLearningStartedAt() == nil) && !isPersonalityTestComplete()
    }
}

private extension Double {
    var nilIfZero: Double? { self == 0 ? nil : self }
}
