//
//  PersonalityDataBridge.swift
//  UnsaidKeyboard
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
actor PersonalityDataBridge {

    static let shared = PersonalityDataBridge()

    // MARK: - Key Constants (compile-time safety)
    private enum K {
        static let attachmentStyle = "attachment_style"
        static let communicationStyle = "communication_style"
        static let personalityType = "personality_type"
        static let emoState = "currentEmotionalState"
        static let emoBucket = "currentEmotionalStateBucket"
        static let profLevel = "profanity_level"
        static let sarcLevel = "sarcasm_level"
        static let scores = "personality_scores"
        static let prefs = "communication_preferences"
        static let partnerStyle = "partner_attachment_style"
        static let relContext = "relationship_context"
        static let testComplete = "personality_test_complete"
        static let lastUpdate = "personality_last_update"
        static let syncStatus = "sync_status"
        static let lastSyncTs = "last_sync_timestamp"
        static let dataV2 = "personality_data_v2"
        static let dataVersion = "personality_data_version"
        static let emoLabel = "emotional_state_label"
        static let emoTimestamp = "emotional_state_timestamp"
        static let schemaVersion = "personality_schema_version"
        static let attachmentLearningStarted = "attachment_learning_started_at"
        static let attachmentLearningDays = "attachment_learning_days"
        static let learnerAttachmentStyle = "learner_attachment_style"
        static let attachmentConfidence = "attachment_confidence"
        static let attachmentSource = "attachment_source"
        static let attachmentConfirmedAt = "attachment_confirmed_at"
    }

    // App group defaults
    private let ud: UserDefaults

    // Logging (throttled)
    private let logger = Logger(subsystem: "com.example.unsaid.unsaid.UnsaidKeyboard", category: "PersonalityDataBridge")
    private var lastLog: [String: Date] = [:]
    private let logWindow: TimeInterval = 1.0

    // Configuration
    private let maxPrefsBytes = 16 * 1024 // 16KB soft cap

    // Small cache to reduce cross-process reads
    private var cache: [String: Any] = [:]
    private var cacheStamp: Date = .distantPast
    private var cacheTTL: TimeInterval {
        ProcessInfo.processInfo.isLowPowerModeEnabled ? 20 : 10
    }

    // Batched write buffer with debounced flush
    private var pendingWrites: [String: Any] = [:]
    private var flushTimer: DispatchSourceTimer?
    private let flushDelay: TimeInterval = 0.15

    // Schema versioning
    private let currentSchemaVersion = 2

    // MARK: - Init (single, non-duplicated)
    #if DEBUG
    init(suiteName: String = "group.com.example.unsaid") {
        self.ud = UserDefaults(suiteName: suiteName) ?? .standard
        Task { @MainActor in
            await self.migrateIfNeeded()
            await self.log("Bridge ready (app group defaults active)", level: .info)
        }
    }
    #else
    private init() {
        self.ud = UserDefaults(suiteName: "group.com.example.unsaid") ?? .standard
        Task { @MainActor in
            await self.migrateIfNeeded()
            await self.log("Bridge ready (app group defaults active)", level: .info)
        }
    }
    #endif

    // MARK: - Public lightweight getters (used by keyboard)

    func getAttachmentStyle() -> String { string(K.attachmentStyle, fallback: "secure") }
    func getCommunicationStyle() -> String { string(K.communicationStyle, fallback: "direct") }
    func getPersonalityType() -> String { string(K.personalityType, fallback: "analytical") }
    func getCurrentEmotionalState() -> String { string(K.emoState, fallback: "neutral") }
    func getCurrentEmotionalBucket() -> String { string(K.emoBucket, fallback: "moderate") }
    func getProfanityLevel() -> Int { (ud.object(forKey: K.profLevel) as? Int) ?? 2 }
    func getSarcasmLevel() -> Int { (ud.object(forKey: K.sarcLevel) as? Int) ?? 2 }

    /// Returns a flattened profile dictionary suitable for API payloads.
    func getPersonalityProfile() -> [String: Any] {
        refreshCacheIfStale()
        var profile: [String: Any] = [
            K.attachmentStyle: getAttachmentStyle(),
            K.communicationStyle: getCommunicationStyle(),
            K.personalityType: getPersonalityType(),
            "emotional_state": getCurrentEmotionalState(),
            "emotional_bucket": getCurrentEmotionalBucket(),
            "is_complete": ud.bool(forKey: K.testComplete)
        ]
        if let scores = ud.dictionary(forKey: K.scores) {
            profile["personality_scores"] = scores
        }
        if let prefs = ud.dictionary(forKey: K.prefs) {
            profile["communication_preferences"] = trimmedPrefs(prefs)
        }
        if let partner = ud.string(forKey: K.partnerStyle) {
            profile["partner_attachment_style"] = partner
        }
        if let ctx = ud.string(forKey: K.relContext) {
            profile["relationship_context"] = ctx
        }
        profile["data_freshness"] = getDataFreshness()
        return profile
    }

    func isPersonalityTestComplete() -> Bool {
        ud.bool(forKey: K.testComplete)
    }

    /// Hours since last update, or -1 if unknown.
    func getDataFreshness() -> Double {
        guard let date = ud.object(forKey: K.lastUpdate) as? Date else { return -1 }
        return Date().timeIntervalSince(date) / 3600.0
    }

    // MARK: - Writer APIs (batched & minimal)

    func storePersonalityData(_ profile: PersonalityProfile) {
        let profileDict = profile.toDictionary()
        writeTransaction(profileDict.merging([
            K.dataV2: profileDict,
            K.testComplete: profile.isComplete,
            K.dataVersion: profile.version,
            K.lastUpdate: profile.lastUpdate ?? Date(),
            K.syncStatus: "synced",
            K.lastSyncTs: Date().timeIntervalSince1970
        ]) { $1 })
        log("Stored personality profile", level: .info)
    }

    func storeEmotionalState(state: String, bucket: String, label: String) {
        writeTransaction([
            K.emoState: state,
            K.emoBucket: bucket,
            K.emoLabel: label,
            K.emoTimestamp: Date().timeIntervalSince1970,
            K.lastUpdate: Date()
        ])
        log("Updated emotional state (\(label))", level: .info)
    }

    func storeRelationshipContext(partnerStyle: String? = nil, context: String? = nil) {
        var payload: [String: Any] = [K.lastUpdate: Date()]
        if let p = partnerStyle { payload[K.partnerStyle] = p }
        if let c = context { payload[K.relContext] = c }
        writeTransaction(payload)
        log("Updated relationship context", level: .info)
    }

    func markSyncPending() { writeTransaction([K.syncStatus: "pending"]) }
    func markSyncComplete() {
        writeTransaction([
            K.syncStatus: "synced",
            K.lastSyncTs: Date().timeIntervalSince1970
        ])
    }

    func needsSync() -> Bool {
        let status = ud.string(forKey: K.syncStatus) ?? "never"
        let last = ud.double(forKey: K.lastSyncTs)
        return status != "synced" || (Date().timeIntervalSince1970 - last) > 300
    }

    func clearAllData() {
        let allKeys = [
            K.dataV2, K.attachmentStyle, K.communicationStyle, K.personalityType,
            "dominant_type_label", K.scores, K.prefs,
            K.emoState, K.emoBucket, K.emoLabel, K.emoTimestamp,
            K.partnerStyle, K.relContext,
            K.dataVersion, K.lastUpdate, K.testComplete, K.syncStatus, K.lastSyncTs
        ]
        for key in allKeys {
            ud.removeObject(forKey: key)
        }
        cache.removeAll()
        cacheStamp = .distantPast
        log("Cleared personality data", level: .info)
    }

    // MARK: - Migration & Helpers

    private func migrateIfNeeded() {
        let stored = ud.integer(forKey: K.schemaVersion)
        guard stored < currentSchemaVersion else { return }
        // Example migrations for future versions could go here.
        ud.set(currentSchemaVersion, forKey: K.schemaVersion)
    }

    private func trimmedPrefs(_ dict: [String: Any]) -> [String: Any] {
        let data = (try? JSONSerialization.data(withJSONObject: dict)) ?? Data()
        guard data.count > maxPrefsBytes else { return dict }
        // Keep only first N entries deterministically
        return dict.sorted { $0.key < $1.key }.prefix(50).reduce(into: [:]) { $0[$1.key] = $1.value }
    }

    private func sanitizePrefs(_ prefs: [String: Any]) -> [String: Any] {
        let allowed: (Any) -> Bool = { v in
            switch v {
            case is String, is Int, is Double, is Bool: return true
            default: return false
            }
        }
        return prefs.filter { allowed($0.value) }
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
            K.attachmentStyle, K.communicationStyle, K.personalityType,
            K.emoState, K.emoBucket,
            K.testComplete, K.lastUpdate
        ]
        for k in keys {
            newCache[k] = ud.object(forKey: k)
        }
        cache = newCache
        cacheStamp = Date()
    }

    func scheduleFlush() {
        flushTimer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + flushDelay, leeway: .milliseconds(50))
        t.setEventHandler { [weak self] in
            Task { await self?.flushPending() }
        }
        t.resume()
        flushTimer = t
    }

    func flushPending() {
        for (k, v) in pendingWrites { ud.set(v, forKey: k) }
        pendingWrites.removeAll()
        cacheStamp = .distantPast // invalidate cache
        flushTimer?.cancel()
        flushTimer = nil
    }

    func writeTransaction(_ fields: [String: Any], immediate: Bool = false) {
        for (k, v) in fields { pendingWrites[k] = v }
        if immediate { flushPending() } else { scheduleFlush() }
    }

    func log(_ msg: @autoclosure () -> String, level: OSLogType) {
        #if DEBUG
        let message = msg()
        let key = "\(level.rawValue):\(message)"
        let now = Date()
        if let last = lastLog[key], now.timeIntervalSince(last) < logWindow { return }
        lastLog[key] = now
        switch level {
        case .error: logger.error("\(message)")
        case .info:  logger.info("\(message)")
        default:     logger.debug("\(message)")
        }
        #endif
    }
}

// MARK: - Attachment Learning Extensions
extension PersonalityDataBridge {
    private var udSafe: UserDefaults { ud }

    func getAttachmentLearningStartedAt() -> TimeInterval? {
        udSafe.double(forKey: K.attachmentLearningStarted).nilIfZero
    }

    func markAttachmentLearningStartedIfNeeded(days: Int = 7) {
        if udSafe.object(forKey: K.attachmentLearningStarted) == nil {
            udSafe.set(Date().timeIntervalSince1970, forKey: K.attachmentLearningStarted)
            udSafe.set(days, forKey: K.attachmentLearningDays)
            log("Started attachment learning window (\(days) days)", level: .info)
        }
    }

    func setLearnerAttachmentStyle(_ style: String, confidence: Double?, source: String = "backend") {
        udSafe.set(style, forKey: K.learnerAttachmentStyle)
        if let c = confidence { udSafe.set(c, forKey: K.attachmentConfidence) }
        udSafe.set(source, forKey: K.attachmentSource)
        log("Set learner attachment style: \(style) (confidence: \(confidence ?? 0))", level: .info)
    }

    func markAttachmentConfirmed(style: String, source: String) {
        udSafe.set(style, forKey: K.attachmentStyle)
        udSafe.set(Date(), forKey: K.attachmentConfirmedAt)
        udSafe.set(source, forKey: K.attachmentSource)
        udSafe.set(true, forKey: K.testComplete)
        log("Confirmed attachment style: \(style) (source: \(source))", level: .info)
    }

    func isLearningWindowComplete() -> Bool {
        let start = getAttachmentLearningStartedAt() ?? 0
        guard start > 0 else { return false }
        let rawDays1 = udSafe.integer(forKey: K.attachmentLearningDays)
        let days = rawDays1 == 0 ? 7 : rawDays1
        return Date().timeIntervalSince1970 - start >= Double(days) * 86_400.0
    }

    func learningDaysRemaining() -> Int {
        let start = getAttachmentLearningStartedAt() ?? 0
        guard start > 0 else { return 7 }
        let rawDays2 = udSafe.integer(forKey: K.attachmentLearningDays)
        let days = rawDays2 == 0 ? 7 : rawDays2
        let elapsed = Date().timeIntervalSince1970 - start
        let remain = Int(ceil((Double(days) * 86_400.0 - elapsed) / 86_400.0))
        return max(0, remain)
    }

    func isNewUser() -> Bool {
        (getAttachmentLearningStartedAt() == nil) && !isPersonalityTestComplete()
    }
}

private extension Double {
    var nilIfZero: Double? { self == 0 ? nil : self }
}
