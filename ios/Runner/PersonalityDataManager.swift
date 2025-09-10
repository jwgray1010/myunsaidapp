//
//  PersonalityDataManager.swift
//  Unsaid (Runner)
//  Stores personality data in the app and syncs a bridge-friendly subset to the keyboard.
//

import Foundation
import os.log

final class PersonalityDataManager {

    static let shared = PersonalityDataManager()

    private let appGroupIdentifier = AppGroups.id
    private let sharedUD: UserDefaults
    private var ud: UserDefaults { sharedUD }
    private let log = Logger(subsystem: "com.example.unsaid.unsaid", category: "PersonalityDataManager")

    private init() {
        guard let u = UserDefaults(suiteName: appGroupIdentifier) else {
            fatalError("App Group not available: \(appGroupIdentifier). Check entitlements & provisioning.")
        }
        sharedUD = u
        log.info("Initialized with app group: \(self.appGroupIdentifier)")
    }

    // MARK: - Public API (unchanged signatures)

    func storePersonalityTestResults(_ results: [String: Any]) {
        // Persist full blob for the app
        ud.set(results, forKey: "personality_test_results")
        ud.set(Date(), forKey: "last_personality_update")
    ud.set(true, forKey: "personality_test_complete")

        // Derived fields
        if let counts = results["counts"] as? [String: Int] {
            ud.set(counts, forKey: "personality_scores")
            if let dom = counts.max(by: { $0.value < $1.value })?.key {
                ud.set(dom, forKey: "dominant_personality_type")
            }
        }
        if let label = results["dominant_type_label"] as? String {
            ud.set(label, forKey: "personality_type_label")
        }
        if let attach = results["attachment_style"] as? String {
            ud.set(attach, forKey: "attachment_style")
        }
        if let comm = results["communication_style"] as? String {
            ud.set(comm, forKey: "communication_style")
        }
        if let prefs = results["communication_preferences"] as? [String: Any] {
            ud.set(prefs, forKey: "communication_preferences")
        }

        // Sync a slim view to the keyboard bridge
        syncToKeyboardExtension(results)

        log.info("Stored personality results and synced to keyboard")
    }

    func storePersonalityComponents(
        attachmentStyle: String? = nil,
        communicationStyle: String? = nil,
        personalityType: String? = nil,
        preferences: [String: Any]? = nil
    ) {
        if let v = attachmentStyle { ud.set(v, forKey: "attachment_style") }
        if let v = communicationStyle { ud.set(v, forKey: "communication_style") }
        if let v = personalityType { ud.set(v, forKey: "dominant_personality_type") }
        if let v = preferences { ud.set(v, forKey: "communication_preferences") }
        ud.set(Date(), forKey: "last_personality_update")

        syncComponentsToKeyboardExtension()
        log.info("Updated components and synced to keyboard")
    }

    // … (the rest of your getters can stay as-is if you like)
    // Below are the sync helpers rewritten to use the same keys as the bridge:

    // MARK: - Keyboard Bridge Sync

    private func syncToKeyboardExtension(_ personalityData: [String: Any]) {
    let shared = sharedUD

        // Compose a bridge-friendly payload
        var bridge: [String: Any] = personalityData
        if let v = ud.string(forKey: "attachment_style") { bridge[PersonalityKeys.attachmentStyle.rawValue] = v }
        if let v = ud.string(forKey: "communication_style") { bridge[PersonalityKeys.communicationStyle.rawValue] = v }
        if let v = ud.string(forKey: "dominant_personality_type") { bridge[PersonalityKeys.personalityType.rawValue] = v }

        if let s = ud.dictionary(forKey: "personality_scores") { bridge[PersonalityKeys.personalityScores.rawValue] = s }
        if let p = ud.dictionary(forKey: "communication_preferences") { bridge[PersonalityKeys.communicationPreferences.rawValue] = p }

        // Batch write into app group
        let now = Date()
        let batch: [String: Any] = bridge.merging([
            PersonalityKeys.personalityDataV2.rawValue: bridge,
            PersonalityKeys.lastUpdate.rawValue: now,
            PersonalityKeys.dataVersion.rawValue: "v2.0",
            PersonalityKeys.isComplete.rawValue: true,
            PersonalityKeys.syncStatus.rawValue: "pending"
        ]) { $1 }

        for (k, v) in batch { shared.set(v, forKey: k) }
    }

    private func syncComponentsToKeyboardExtension() {
    let shared = sharedUD
        var batch: [String: Any] = [
            PersonalityKeys.lastUpdate.rawValue: Date(),
            PersonalityKeys.syncStatus.rawValue: "pending"
        ]
        if let v = ud.string(forKey: "attachment_style") { batch[PersonalityKeys.attachmentStyle.rawValue] = v }
        if let v = ud.string(forKey: "communication_style") { batch[PersonalityKeys.communicationStyle.rawValue] = v }
        if let v = ud.string(forKey: "dominant_personality_type") { batch[PersonalityKeys.personalityType.rawValue] = v }
        for (k, v) in batch { shared.set(v, forKey: k) }
    }

    func setUserEmotionalState(state: String, bucket: String, label: String) {
        ud.set(state, forKey: "currentEmotionalState")
        ud.set(bucket, forKey: "currentEmotionalStateBucket")
        ud.set(label, forKey: "emotionalStateLabel")
        ud.set(Date().timeIntervalSince1970, forKey: "emotionalStateTimestamp")

        syncEmotionalStateToKeyboardExtension(state: state, bucket: bucket, label: label)
        log.info("Stored emotional state and synced to keyboard")
    }

    private func syncEmotionalStateToKeyboardExtension(state: String, bucket: String, label: String) {
    let shared = sharedUD
        let batch: [String: Any] = [
            PersonalityKeys.currentEmotionalState.rawValue: state,
            PersonalityKeys.currentEmotionalBucket.rawValue: bucket,
            PersonalityKeys.emotionalStateLabel.rawValue: label,
            PersonalityKeys.emotionalStateTimestamp.rawValue: Date().timeIntervalSince1970,
            PersonalityKeys.lastUpdate.rawValue: Date(),
            PersonalityKeys.syncStatus.rawValue: "pending"
        ]
        for (k, v) in batch { shared.set(v, forKey: k) }
    }

    func forceSyncToKeyboardExtension() {
        guard let results = ud.dictionary(forKey: "personality_test_results") else { return }
        syncToKeyboardExtension(results)

        // Also push latest emotional + relationship if present
        do {
            var batch: [String: Any] = [
                PersonalityKeys.lastUpdate.rawValue: Date(),
                PersonalityKeys.syncStatus.rawValue: "pending"
            ]
            if let state = ud.string(forKey: "currentEmotionalState") {
                batch[PersonalityKeys.currentEmotionalState.rawValue] = state
                batch[PersonalityKeys.currentEmotionalBucket.rawValue] = ud.string(forKey: "currentEmotionalStateBucket") ?? "moderate"
                batch[PersonalityKeys.emotionalStateLabel.rawValue] = ud.string(forKey: "emotionalStateLabel") ?? "Neutral"
                batch[PersonalityKeys.emotionalStateTimestamp.rawValue] = ud.double(forKey: "emotionalStateTimestamp")
            }
            if let partner = ud.string(forKey: "partner_attachment_style") {
                batch[PersonalityKeys.partnerAttachmentStyle.rawValue] = partner
            }
            if let ctx = ud.string(forKey: "relationship_context") {
                batch[PersonalityKeys.relationshipContext.rawValue] = ctx
            }
            for (k, v) in batch { sharedUD.set(v, forKey: k) }
        }

        log.info("Force-synced personality data to keyboard")
    }
}
