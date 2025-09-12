//
//  PersonalityKeys.swift
//  Runner
//
//  Shared constants for personality data keys used between main app and keyboard extension
//

import Foundation

// MARK: - Bridge Keys (centralized so Runner & Extension stay in sync)
enum PersonalityKeys: String {
    // Core
    case personalityDataV2          = "personality_data_v2"
    case attachmentStyle            = "attachment_style"
    case communicationStyle         = "communication_style"
    case personalityType            = "personality_type"
    case dominantTypeLabel          = "dominant_type_label"
    case personalityScores          = "personality_scores"
    case communicationPreferences   = "communication_preferences"
    case profanityLevel             = "profanity_level"
    case sarcasmLevel               = "sarcasm_level"

    // Emotional state
    case currentEmotionalState      = "currentEmotionalState"
    case currentEmotionalBucket     = "currentEmotionalStateBucket"
    case emotionalStateLabel        = "emotionalStateLabel"
    case emotionalStateTimestamp    = "emotionalStateTimestamp"

    // Relationship
    case partnerAttachmentStyle     = "partner_attachment_style"
    case relationshipContext        = "relationship_context"

    // Meta / Sync
    case dataVersion                = "personality_data_version"
    case lastUpdate                 = "personality_last_update"
    case isComplete                 = "personality_test_complete"
    case syncStatus                 = "personality_sync_status"
    case bridgeVersion              = "personality_bridge_version"
    case lastSyncTimestamp          = "last_sync_timestamp"
}
