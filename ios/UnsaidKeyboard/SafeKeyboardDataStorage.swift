import Foundation
import os.log
import CryptoKit

/// Safe background analytics storage that prevents keyboard crashes
/// Stores data locally and syncs to main app only when safe
final class SafeKeyboardDataStorage {

    // MARK: - Singleton
    static let shared = SafeKeyboardDataStorage()
    private init() {}

    // MARK: - Properties
    private let logger = Logger(subsystem: "com.example.unsaid.unsaid.UnsaidKeyboard", category: "SafeDataStorage")
    private let sharedDefaults = AppGroups.shared  // Non-optional shared UserDefaults
    private let maxQueueSize = 100          // in-memory bound
    private let maxPersistedSize = 200      // on-disk bound (per bucket)
    private let syncDebounce: TimeInterval = 0.35

    // MARK: - Storage Keys
    private enum StorageKeys {
        static let pendingInteractions = "pending_keyboard_interactions"
        static let pendingAnalytics    = "pending_keyboard_analytics"
        static let pendingToneData     = "pending_tone_analysis_data"
        static let pendingSuggestions  = "pending_suggestion_data"
        static let storageMetadata     = "keyboard_storage_metadata"
        static let lastSyncTimestamp   = "last_sync_timestamp"
    }

    // MARK: - Codable payloads (compact & type-safe)

    private struct StoredInteraction: Codable {
        let id: String
        let timestamp: TimeInterval
        let textBeforeLength: Int
        let textAfterLength: Int
        let toneStatus: String
        let suggestionAccepted: Bool
        let userAcceptedSuggestion: Bool
        let suggestionLength: Int
        let analysisTime: TimeInterval
        let context: String
        let interactionType: String
        let communicationPattern: String
        let attachmentStyle: String
        let relationshipContext: String
        let sentimentScore: Double
        let wordCount: Int
        let appContext: String
    }

    private struct StoredTone: Codable {
        let id: String
        let timestamp: TimeInterval
        let textLength: Int
        let textHash: String    // stable SHA-256 (hex)
        let tone: String
        let confidence: Double
        let analysisTime: TimeInterval
        let source: String
    }

    private struct StoredSuggestion: Codable {
        let id: String
        let timestamp: TimeInterval
        let suggestionLength: Int
        let accepted: Bool
        let context: String
        let source: String
    }

    private struct StoredAnalytics: Codable {
        let id: String
        let timestamp: TimeInterval
        let event: String
        let source: String
        let payload: [String: String]  // stringified to remain Codable
    }

    // MARK: - In-Memory Queues (bounded)

    private var interactionQueue = RingBuffer<StoredInteraction>(capacity: 100)
    private var analyticsQueue   = RingBuffer<StoredAnalytics>(capacity: 100)
    private var toneQueue        = RingBuffer<StoredTone>(capacity: 100)
    private var suggestionQueue  = RingBuffer<StoredSuggestion>(capacity: 100)

    // MARK: - Thread Safety & Coalescing

    private let workQueue = DispatchQueue(label: "com.unsaid.safe.storage", qos: .utility)
    private var isProcessing = false
    private var pendingSyncWork: DispatchWorkItem?

    // MARK: - Shared Defaults

    // sharedDefaults already a UserDefaults

    // MARK: - Public API

    func recordInteraction(_ interaction: KeyboardInteraction) {
        workQueue.async { [weak self] in
            guard let self = self else { return }
            let item = self.toStoredInteraction(interaction)
            self.interactionQueue.append(item)
            self.scheduleCoalescedSync()
            self.logger.debug("✅ queued interaction: \(interaction.interactionType.rawValue)")
        }
    }

    func recordToneAnalysis(text: String, tone: ToneStatus, confidence: Double, analysisTime: TimeInterval) {
        workQueue.async { [weak self] in
            guard let self = self else { return }
            let item = StoredTone(
                id: UUID().uuidString,
                timestamp: Date().timeIntervalSince1970,
                textLength: text.count,
                textHash: Self.sha256Hex(of: text),            // stable across runs
                tone: tone.rawValue,
                confidence: confidence,
                analysisTime: analysisTime,
                source: "keyboard_extension"
            )
            self.toneQueue.append(item)
            self.scheduleCoalescedSync()
            self.logger.debug("✅ queued tone: \(tone.rawValue)")
        }
    }

    func recordSuggestionInteraction(suggestion: String, accepted: Bool, context: String) {
        workQueue.async { [weak self] in
            guard let self = self else { return }
            let item = StoredSuggestion(
                id: UUID().uuidString,
                timestamp: Date().timeIntervalSince1970,
                suggestionLength: suggestion.count,
                accepted: accepted,
                context: context,
                source: "keyboard_extension"
            )
            self.suggestionQueue.append(item)
            self.scheduleCoalescedSync()
            self.logger.debug("✅ queued suggestion accepted=\(accepted)")
        }
    }

    func recordAnalytics(event: String, data: [String: Any]) {
        workQueue.async { [weak self] in
            guard let self = self else { return }
            var stringified: [String: String] = [:]
            for (k, v) in data { stringified[k] = String(describing: v) }
            let item = StoredAnalytics(
                id: UUID().uuidString,
                timestamp: Date().timeIntervalSince1970,
                event: event,
                source: "keyboard_extension",
                payload: stringified
            )
            self.analyticsQueue.append(item)
            self.scheduleCoalescedSync()
            self.logger.debug("✅ queued analytics: \(event)")
        }
    }

    // MARK: - Coalesced Background Sync

    private func scheduleCoalescedSync() {
        // cancel previous pending sync and debounce
        pendingSyncWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.performSyncIfNeeded()
        }
        pendingSyncWork = work
        workQueue.asyncAfter(deadline: .now() + syncDebounce, execute: work)
    }

    private func performSyncIfNeeded() {
        guard !isProcessing else { return }
        guard hasQueuedData() else { return }
        isProcessing = true

        // Do the disk write off the queue but funnel mutations back on workQueue
        DispatchQueue.global(qos: .background).async { [weak self] in
            guard let self = self else { return }
            defer {
                self.workQueue.async { self.isProcessing = false }
            }
            self.persistSnapshots()
        }
    }

    // MARK: - Persistence

    private func persistSnapshots() {
        let defaults = sharedDefaults

        // take immutable snapshots on queue
        let interactions = workQueue.sync { interactionQueue.makeArray(max: maxPersistedSize) }
        let analytics    = workQueue.sync { analyticsQueue.makeArray(max: maxPersistedSize) }
        let tones        = workQueue.sync { toneQueue.makeArray(max: maxPersistedSize) }
        let suggestions  = workQueue.sync { suggestionQueue.makeArray(max: maxPersistedSize) }

        // read existing (as Data) and append
        let mergedInteractions = mergeStored(existingKey: StorageKeys.pendingInteractions, new: interactions, defaults: defaults)
        let mergedAnalytics    = mergeStored(existingKey: StorageKeys.pendingAnalytics,    new: analytics,    defaults: defaults)
        let mergedTones        = mergeStored(existingKey: StorageKeys.pendingToneData,     new: tones,        defaults: defaults)
        let mergedSuggestions  = mergeStored(existingKey: StorageKeys.pendingSuggestions,  new: suggestions,  defaults: defaults)

        // write back
        store(mergedInteractions, forKey: StorageKeys.pendingInteractions, defaults: defaults)
        store(mergedAnalytics,    forKey: StorageKeys.pendingAnalytics,    defaults: defaults)
        store(mergedTones,        forKey: StorageKeys.pendingToneData,     defaults: defaults)
        store(mergedSuggestions,  forKey: StorageKeys.pendingSuggestions,  defaults: defaults)

        // metadata (small, no need to debounce extra)
        let totalItems = mergedInteractions.count + mergedAnalytics.count + mergedTones.count + mergedSuggestions.count
        let metadata: [String: Any] = [
            "last_sync": Date().timeIntervalSince1970,
            "interactions_count": mergedInteractions.count,
            "analytics_count": mergedAnalytics.count,
            "tone_count": mergedTones.count,
            "suggestions_count": mergedSuggestions.count,
            "total_items": totalItems,
            "has_pending_data": totalItems > 0,
            "keyboard_version": "2.0.0",
            "sync_source": "keyboard_extension"
        ]
        defaults.set(metadata, forKey: StorageKeys.storageMetadata)
        
        // TODO: Add smart notification triggers when needed

        // clear in-memory queues after success
        workQueue.async {
            self.interactionQueue.removeAll()
            self.analyticsQueue.removeAll()
            self.toneQueue.removeAll()
            self.suggestionQueue.removeAll()
        }

        logger.debug("🔄 background sync complete")
    }

    // decode + append + bound
    private func mergeStored<T: Codable>(existingKey key: String, new: [T], defaults: UserDefaults) -> [T] {
        guard !new.isEmpty else { return decode([T].self, key: key, defaults: defaults) ?? [] }
        var merged = decode([T].self, key: key, defaults: defaults) ?? []
        merged.append(contentsOf: new)
        if merged.count > maxPersistedSize {
            merged = Array(merged.suffix(maxPersistedSize))
        }
        return merged
    }

    private func store<T: Codable>(_ value: T, forKey key: String, defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(value) {
            defaults.set(data, forKey: key)
        }
    }

    private func decode<T: Codable>(_ type: T.Type, key: String, defaults: UserDefaults) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    // MARK: - Public retrieval (for main app)

    func getAllPendingData() -> [String: [[String: Any]]] {
        let defaults = sharedDefaults

        // decode codable and expose as `[String: Any]` for the app layer that expects dictionaries
        func unwrap<T: Codable>(_ key: String, _: T.Type) -> [[String: Any]] {
            guard let data = defaults.data(forKey: key),
                  let decoded = try? JSONDecoder().decode([T].self, from: data) else { return [] }
            return decoded.map { Self.toDictionary($0) }
        }

        let interactions = unwrap(StorageKeys.pendingInteractions, [StoredInteraction].self)
        let analytics    = unwrap(StorageKeys.pendingAnalytics,   [StoredAnalytics].self)
        let tones        = unwrap(StorageKeys.pendingToneData,    [StoredTone].self)
        let suggestions  = unwrap(StorageKeys.pendingSuggestions, [StoredSuggestion].self)

        logger.info("📥 Retrieved pending data - Interactions: \(interactions.count), Analytics: \(analytics.count), Tone: \(tones.count), Suggestions: \(suggestions.count)")

        return [
            "interactions": interactions,
            "analytics": analytics,
            "tone_data": tones,
            "suggestions": suggestions
        ]
    }

    func clearAllPendingData() {
        let defaults = sharedDefaults
        defaults.removeObject(forKey: StorageKeys.pendingInteractions)
        defaults.removeObject(forKey: StorageKeys.pendingAnalytics)
        defaults.removeObject(forKey: StorageKeys.pendingToneData)
        defaults.removeObject(forKey: StorageKeys.pendingSuggestions)

        let metadata: [String: Any] = [
            "last_clear": Date().timeIntervalSince1970,
            "cleared_by": "main_app",
            "clear_timestamp": ISO8601DateFormatter().string(from: Date())
        ]
        defaults.set(metadata, forKey: StorageKeys.storageMetadata)

        logger.info("🗑️ Cleared all pending data")
    }

    func getStorageMetadata() -> [String: Any] {
        sharedDefaults.dictionary(forKey: StorageKeys.storageMetadata) ?? [:]
    }

    func getCurrentQueueSizes() -> [String: Int] {
        workQueue.sync {
            [
                "interactions": interactionQueue.count,
                "analytics": analyticsQueue.count,
                "tone": toneQueue.count,
                "suggestions": suggestionQueue.count,
                "total": interactionQueue.count + analyticsQueue.count + toneQueue.count + suggestionQueue.count
            ]
        }
    }

    // MARK: - Helpers

    private func hasQueuedData() -> Bool {
        (interactionQueue.count + analyticsQueue.count + toneQueue.count + suggestionQueue.count) > 0
    }

    private func toStoredInteraction(_ i: KeyboardInteraction) -> StoredInteraction {
        StoredInteraction(
            id: UUID().uuidString,
            timestamp: i.timestamp.timeIntervalSince1970,
            textBeforeLength: i.textLength, // Using textLength as approximation
            textAfterLength: i.textLength, // Using textLength as approximation
            toneStatus: i.toneStatus.rawValue,
            suggestionAccepted: i.wasAccepted,
            userAcceptedSuggestion: i.wasAccepted,
            suggestionLength: i.suggestionText?.count ?? 0,
            analysisTime: i.analysisTime,
            context: "keyboard", // Default context since not available in struct
            interactionType: i.interactionType.rawValue,
            communicationPattern: i.communicationPattern.rawValue,
            attachmentStyle: i.attachmentStyleDetected.rawValue,
            relationshipContext: i.relationshipContext.rawValue,
            sentimentScore: 0.0, // Default value since not available in struct
            wordCount: max(1, i.textLength / 5), // Rough approximation: average word length ~5 chars
            appContext: "unknown" // Default value since not available in struct
        )
    }

    private static func sha256Hex(of text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.compactMap { String(format: "%02x", $0) }.joined()
    }

    private static func toDictionary<T: Encodable>(_ value: T) -> [String: Any] {
        // Safe “lossy” bridge for callers needing dictionaries
        guard let data = try? JSONEncoder().encode(value),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return obj
    }
}

// MARK: - Small RingBuffer to bound memory

private struct RingBuffer<Element> {
    private var buffer: [Element] = []
    private let capacity: Int

    init(capacity: Int) { self.capacity = max(1, capacity) }

    var count: Int { buffer.count }

    mutating func append(_ element: Element) {
        if buffer.count == capacity { buffer.removeFirst() }
        buffer.append(element)
    }

    mutating func removeAll() { buffer.removeAll(keepingCapacity: true) }

    func makeArray(max: Int) -> [Element] {
        if buffer.count <= max { return buffer }
        return Array(buffer.suffix(max))
    }
}
