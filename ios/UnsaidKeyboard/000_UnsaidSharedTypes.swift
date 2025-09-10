//
//  SharedTypes.swift
//  Unsaid
//
//  General shared types and enums used across both communication and keyboard modules
//
//  Created by John Gray on 7/11/25.
//

import Foundation
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Core Shared Types

/// Represents tone indicator position preferences
enum ToneIndicatorPosition: String, CaseIterable, Codable {
    case topLeft = "topLeft"
    case topRight = "topRight"
    case bottomLeft = "bottomLeft"
    case bottomRight = "bottomRight"
    case center = "center"
    
    var displayName: String {
        switch self {
        case .topLeft:
            return "Top Left"
        case .topRight:
            return "Top Right"
        case .bottomLeft:
            return "Bottom Left"
        case .bottomRight:
            return "Bottom Right"
        case .center:
            return "Center"
        }
    }
}

/// Represents keyboard layout style preferences
enum KeyboardLayoutStyle: String, CaseIterable, Codable {
    case overlay = "overlay"
    case inline = "inline"
    case popup = "popup"
    case minimal = "minimal"
    
    var displayName: String {
        switch self {
        case .overlay:
            return "Overlay"
        case .inline:
            return "Inline"
        case .popup:
            return "Popup"
        case .minimal:
            return "Minimal"
        }
    }
}

/// Represents user profile information
struct UserProfile: Codable {
    let attachmentStyle: AttachmentStyle
    let communicationPreferences: [CommunicationPattern]
    let relationshipContext: RelationshipContext
    let preferredToneIndicatorPosition: ToneIndicatorPosition
    let keyboardLayoutStyle: KeyboardLayoutStyle

    init(
        attachmentStyle: AttachmentStyle = .unknown,
        communicationPreferences: [CommunicationPattern] = [],
        relationshipContext: RelationshipContext = .unknown,
        preferredToneIndicatorPosition: ToneIndicatorPosition = .topRight,
        keyboardLayoutStyle: KeyboardLayoutStyle = .overlay
    ) {
        self.attachmentStyle = attachmentStyle
        self.communicationPreferences = communicationPreferences
        self.relationshipContext = relationshipContext
        self.preferredToneIndicatorPosition = preferredToneIndicatorPosition
        self.keyboardLayoutStyle = keyboardLayoutStyle
    }
}


/// Represents different attachment styles based on psychology research
enum AttachmentStyle: String, CaseIterable, Codable {
    case secure = "secure"
    case anxious = "anxious"
    case avoidant = "avoidant"
    case disorganized = "disorganized"
    case unknown = "unknown"
    
    var displayName: String {
        switch self {
        case .secure:
            return "Secure"
        case .anxious:
            return "Anxious"
        case .avoidant:
            return "Avoidant"
        case .disorganized:
            return "Disorganized"
        case .unknown:
            return "Unknown"
        }
    }
}

/// Represents different communication patterns
enum CommunicationPattern: String, CaseIterable, Codable {
    case aggressive
    case passiveAggressive
    case assertive
    case defensive
    case withdrawing
    case pursuing
    case neutral
    case iStatement
    case youStatement
    
    var displayName: String {
        switch self {
        case .aggressive:
            return "Aggressive"
        case .passiveAggressive:
            return "Passive Aggressive"
        case .assertive:
            return "Assertive"
        case .defensive:
            return "Defensive"
        case .withdrawing:
            return "Withdrawing"
        case .pursuing:
            return "Pursuing"
        case .neutral:
            return "Neutral"
        case .iStatement:
            return "I-Statement"
        case .youStatement:
            return "You-Statement"
        }
    }
    
    #if canImport(UIKit)
    var color: UIColor {
        switch self {
        case .aggressive:
            return UIColor.systemRed
        case .passiveAggressive:
            return UIColor.systemOrange
        case .assertive:
            return UIColor.systemGreen
        case .defensive:
            return UIColor.systemPurple
        case .withdrawing:
            return UIColor.systemBlue
        case .pursuing:
            return UIColor.systemYellow
        case .neutral:
            return UIColor.systemGray
        case .iStatement:
            return UIColor.systemGreen
        case .youStatement:
            return UIColor.systemRed
        }
    }
    #endif
}

/// Represents different relationship contexts
enum RelationshipContext: String, CaseIterable, Codable {
    case unknown = "unknown"
    case romantic = "romantic"
    case family = "family"
    case friendship = "friendship"
    case professional = "professional"
    case acquaintance = "acquaintance"
    
    var displayName: String {
        switch self {
        case .unknown:
            return "Unknown"
        case .romantic:
            return "Romantic"
        case .family:
            return "Family"
        case .friendship:
            return "Friendship"
        case .professional:
            return "Professional"
        case .acquaintance:
            return "Acquaintance"
        }
    }
    
    #if canImport(UIKit)
    var color: UIColor {
        switch self {
        case .unknown:
            return UIColor.systemGray
        case .romantic:
            return UIColor.systemPink
        case .family:
            return UIColor.systemBlue
        case .friendship:
            return UIColor.systemGreen
        case .professional:
            return UIColor.systemYellow
        case .acquaintance:
            return UIColor.systemTeal
        }
    }
    #endif
}

/// Represents urgency levels for suggestions and analysis
enum UrgencyLevel: String, CaseIterable, Codable {
    case low = "low"
    case medium = "medium"
    case high = "high"
    case critical = "critical"
    
    var displayName: String {
        switch self {
        case .low:
            return "Low"
        case .medium:
            return "Medium"
        case .high:
            return "High"
        case .critical:
            return "Critical"
        }
    }
    
    #if canImport(UIKit)
    var color: UIColor {
        switch self {
        case .low:
            return UIColor.systemGreen
        case .medium:
            return UIColor.systemYellow
        case .high:
            return UIColor.systemOrange
        case .critical:
            return UIColor.systemRed
        }
    }
    #endif
}

/// Represents types of analysis suggestions
enum AnalysisSuggestionType: String, CaseIterable, Codable {
    case tone = "tone"
    case clarity = "clarity"
    case empathy = "empathy"
    case timing = "timing"
    case context = "context"
    case attachment = "attachment"
    case conflict = "conflict"
    case emotional = "emotional"
    
    var displayName: String {
        switch self {
        case .tone:
            return "Tone"
        case .clarity:
            return "Clarity"
        case .empathy:
            return "Empathy"
        case .timing:
            return "Timing"
        case .context:
            return "Context"
        case .attachment:
            return "Attachment"
        case .conflict:
            return "Conflict"
        case .emotional:
            return "Emotional"
        }
    }
    
    #if canImport(UIKit)
    var color: UIColor {
        switch self {
        case .tone:
            return UIColor.systemBlue
        case .clarity:
            return UIColor.systemGreen
        case .empathy:
            return UIColor.systemPink
        case .timing:
            return UIColor.systemOrange
        case .context:
            return UIColor.systemYellow
        case .attachment:
            return UIColor.systemPurple
        case .conflict:
            return UIColor.systemRed
        case .emotional:
            return UIColor.systemTeal
        }
    }
    #endif
}

/// Represents conversation types for contextual analysis
enum ConversationType: String, CaseIterable, Codable {
    case casual = "casual"
    case serious = "serious"
    case conflict = "conflict"
    case intimate = "intimate"
    case professional = "professional"
    case supportive = "supportive"
    case planning = "planning"
    case emotional = "emotional"
    
    var displayName: String {
        switch self {
        case .casual:
            return "Casual"
        case .serious:
            return "Serious"
        case .conflict:
            return "Conflict"
        case .intimate:
            return "Intimate"
        case .professional:
            return "Professional"
        case .supportive:
            return "Supportive"
        case .planning:
            return "Planning"
        case .emotional:
            return "Emotional"
        }
    }
    
    #if canImport(UIKit)
    var color: UIColor {
        switch self {
        case .casual:
            return UIColor.systemGreen
        case .serious:
            return UIColor.systemBlue
        case .conflict:
            return UIColor.systemRed
        case .intimate:
            return UIColor.systemPink
        case .professional:
            return UIColor.systemYellow
        case .supportive:
            return UIColor.systemTeal
        case .planning:
            return UIColor.systemPurple
        case .emotional:
            return UIColor.systemOrange
        }
    }
    #endif
}

/// Represents different tone statuses
enum ToneStatus: String, CaseIterable, Codable {
    case clear = "clear"
    case caution = "caution"
    case alert = "alert"
    case neutral = "neutral"
    
    var displayName: String {
        switch self {
        case .clear:
            return "Clear"
        case .caution:
            return "Caution"
        case .alert:
            return "Alert"
        case .neutral:
            return "Neutral"
        }
    }
    
    #if canImport(UIKit)
    var color: UIColor {
        switch self {
        case .clear:
            return UIColor.systemGreen
        case .caution:
            return UIColor.systemYellow
        case .alert:
            return UIColor.systemRed
        case .neutral:
            return UIColor.systemPink
        }
    }
    #endif
}

// MARK: - Constants

/// Shared constants for the application
struct SharedConstants {
    static let appGroupIdentifier = AppGroups.shared
    static let maxAnalysisLength = 500
    static let analysisTimeoutInterval: TimeInterval = 5.0
    static let suggestionDisplayDuration: TimeInterval = 3.0
    static let keyboardAnimationDuration: TimeInterval = 0.3
    static let toneIndicatorSize: CGSize = CGSize(width: 60, height: 60)
    static let suggestionBarHeight: CGFloat = 44
    static let keyboardCornerRadius: CGFloat = 8
    static let keyCornerRadius: CGFloat = 4
    static let standardKeySpacing: CGFloat = 6
    static let standardKeyHeight: CGFloat = 42
}

// MARK: - Performance Optimization Types

// MARK: - Analysis Data Structures

/// Performance-related constants for optimization
struct PerformanceConstants {
    static let analysisDebounceInterval: TimeInterval = 0.3
    static let toneUpdateInterval: TimeInterval = 0.1
    static let cacheTimeout: TimeInterval = 30.0
    static let maxCacheSize: Int = 100
    static let minTextLengthForAnalysis: Int = 3
    static let maxTextLengthForRealtime: Int = 500
    static let batchAnalysisSize: Int = 10
    static let maxHistorySize: Int = 50
    static let confidenceThreshold: Float = 0.5
}

// MARK: - Communication Shared Types

/// Represents turn-taking patterns in conversations
enum TurnTakingPattern: String, CaseIterable, Codable {
    case balanced = "balanced"
    case userDominated = "userDominated"
    case partnerDominated = "partnerDominated"
    case rapidFire = "rapidFire"
    case slowResponse = "slowResponse"
    
    var displayName: String {
        switch self {
        case .balanced:
            return "Balanced"
        case .userDominated:
            return "User Dominated"
        case .partnerDominated:
            return "Partner Dominated"
        case .rapidFire:
            return "Rapid Fire"
        case .slowResponse:
            return "Slow Response"
        }
    }
    
    #if canImport(UIKit)
    var color: UIColor {
        switch self {
        case .balanced:
            return UIColor.systemGreen
        case .userDominated:
            return UIColor.systemOrange
        case .partnerDominated:
            return UIColor.systemYellow
        case .rapidFire:
            return UIColor.systemRed
        case .slowResponse:
            return UIColor.systemBlue
        }
    }
    #endif
}

/// Represents emotional trajectory in conversations
enum EmotionalTrajectory: String, CaseIterable, Codable {
    case improving = "improving"
    case declining = "declining"
    case stable = "stable"
    case volatile = "volatile"
    
    var displayName: String {
        switch self {
        case .improving:
            return "Improving"
        case .declining:
            return "Declining"
        case .stable:
            return "Stable"
        case .volatile:
            return "Volatile"
        }
    }
    
    #if canImport(UIKit)
    var color: UIColor {
        switch self {
        case .improving:
            return UIColor.systemGreen
        case .declining:
            return UIColor.systemRed
        case .stable:
            return UIColor.systemBlue
        case .volatile:
            return UIColor.systemOrange
        }
    }
    #endif
}

/// Represents attachment dynamic types
enum AttachmentDynamicType: String, CaseIterable, Codable {
    case secure = "secure"
    case anxiousAvoidant = "anxiousAvoidant"
    case anxiousAnxious = "anxiousAnxious"
    case avoidantAvoidant = "avoidantAvoidant"
    case chaotic = "chaotic"
    
    var displayName: String {
        switch self {
        case .secure:
            return "Secure"
        case .anxiousAvoidant:
            return "Anxious-Avoidant"
        case .anxiousAnxious:
            return "Anxious-Anxious"
        case .avoidantAvoidant:
            return "Avoidant-Avoidant"
        case .chaotic:
            return "Chaotic"
        }
    }
    
    #if canImport(UIKit)
    var color: UIColor {
        switch self {
        case .secure:
            return UIColor.systemGreen
        case .anxiousAvoidant:
            return UIColor.systemYellow
        case .anxiousAnxious:
            return UIColor.systemOrange
        case .avoidantAvoidant:
            return UIColor.systemBlue
        case .chaotic:
            return UIColor.systemRed
        }
    }
    #endif
}

/// Represents conversation quality levels
enum ConversationQuality: String, CaseIterable, Codable {
    case healthy = "healthy"
    case strained = "strained"
    case conflicted = "conflicted"
    case disconnected = "disconnected"
    case improving = "improving"
    
    var displayName: String {
        switch self {
        case .healthy:
            return "Healthy"
        case .strained:
            return "Strained"
        case .conflicted:
            return "Conflicted"
        case .disconnected:
            return "Disconnected"
        case .improving:
            return "Improving"
        }
    }
    
    #if canImport(UIKit)
    var color: UIColor {
        switch self {
        case .healthy:
            return UIColor.systemGreen
        case .strained:
            return UIColor.systemYellow
        case .conflicted:
            return UIColor.systemOrange
        case .disconnected:
            return UIColor.systemRed
        case .improving:
            return UIColor.systemBlue
        }
    }
    #endif
}

/// Represents response patterns
enum ResponsePattern: String, CaseIterable, Codable {
    case rapid = "rapid"
    case normal = "normal"
    case slow = "slow"
    case insufficient = "insufficient"
    
    var displayName: String {
        switch self {
        case .rapid:
            return "Rapid"
        case .normal:
            return "Normal"
        case .slow:
            return "Slow"
        case .insufficient:
            return "Insufficient"
        }
    }
    
    #if canImport(UIKit)
    var color: UIColor {
        switch self {
        case .rapid:
            return UIColor.systemRed
        case .normal:
            return UIColor.systemGreen
        case .slow:
            return UIColor.systemBlue
        case .insufficient:
            return UIColor.systemGray
        }
    }
    #endif
}

/// Represents emotional progression
enum EmotionalProgression: String, CaseIterable, Codable {
    case improving = "improving"
    case stable = "stable"
    case deteriorating = "deteriorating"
    
    var displayName: String {
        switch self {
        case .improving:
            return "Improving"
        case .stable:
            return "Stable"
        case .deteriorating:
            return "Deteriorating"
        }
    }
    
    #if canImport(UIKit)
    var color: UIColor {
        switch self {
        case .improving:
            return UIColor.systemGreen
        case .stable:
            return UIColor.systemBlue
        case .deteriorating:
            return UIColor.systemRed
        }
    }
    #endif
}

/// Represents communication health levels
enum CommunicationHealth: String, CaseIterable, Codable {
    case healthy = "healthy"
    case concerning = "concerning"
    case poor = "poor"
    case unhealthy = "unhealthy"
    case toxic = "toxic"
    case unknown = "unknown"
    
    var displayName: String {
        switch self {
        case .healthy:
            return "Healthy"
        case .concerning:
            return "Concerning"
        case .poor:
            return "Poor"
        case .unhealthy:
            return "Unhealthy"
        case .toxic:
            return "Toxic"
        case .unknown:
            return "Unknown"
        }
    }
    
    #if canImport(UIKit)
    var color: UIColor {
        switch self {
        case .healthy:
            return UIColor.systemGreen
        case .concerning:
            return UIColor.systemYellow
        case .poor:
            return UIColor.systemRed
        case .unhealthy:
            return UIColor.systemRed
        case .toxic:
            return UIColor.systemRed
        case .unknown:
            return UIColor.systemGray
        }
    }
    #endif
}

/// Represents suggested actions
enum SuggestedAction: String, CaseIterable, Codable {
    case replace = "replace"
    case append = "append"
    case rephrase = "rephrase"
    
    var displayName: String {
        switch self {
        case .replace:
            return "Replace"
        case .append:
            return "Append"
        case .rephrase:
            return "Rephrase"
        }
    }
    
    #if canImport(UIKit)
    var color: UIColor {
        switch self {
        case .replace:
            return UIColor.systemOrange
        case .append:
            return UIColor.systemBlue
        case .rephrase:
            return UIColor.systemPurple
        }
    }
    #endif
}

/// Represents priority levels for suggestions
enum SuggestionPriority: Int, CaseIterable, Codable {
    case critical = 0      // Immediate attention needed
    case high = 1         // Important but not urgent
    case medium = 2       // Helpful improvement
    case low = 3          // Optional enhancement
    case info = 4         // Informational feedback
    
    var displayName: String {
        switch self {
        case .critical:
            return "Critical"
        case .high:
            return "High"
        case .medium:
            return "Medium"
        case .low:
            return "Low"
        case .info:
            return "Info"
        }
    }
    
    #if canImport(UIKit)
    var color: UIColor {
        switch self {
        case .critical:
            return UIColor.systemRed
        case .high:
            return UIColor.systemOrange
        case .medium:
            return UIColor.systemYellow
        case .low:
            return UIColor.systemBlue
        case .info:
            return UIColor.systemGray
        }
    }
    #endif
}

/// Represents intervention types for suggestions
enum InterventionType: String, CaseIterable, Codable {
    case preventive = "preventive"        // Prevent potential issues
    case corrective = "corrective"        // Fix current problems
    case enhancement = "enhancement"      // Improve communication
    case educational = "educational"      // Teach better practices
    case therapeutic = "therapeutic"      // Emotional healing
    case strategic = "strategic"          // Long-term relationship building
    
    var displayName: String {
        switch self {
        case .preventive:
            return "Preventive"
        case .corrective:
            return "Corrective"
        case .enhancement:
            return "Enhancement"
        case .educational:
            return "Educational"
        case .therapeutic:
            return "Therapeutic"
        case .strategic:
            return "Strategic"
        }
    }
    
    #if canImport(UIKit)
    var color: UIColor {
        switch self {
        case .preventive:
            return UIColor.systemGreen
        case .corrective:
            return UIColor.systemRed
        case .enhancement:
            return UIColor.systemBlue
        case .educational:
            return UIColor.systemYellow
        case .therapeutic:
            return UIColor.systemPurple
        case .strategic:
            return UIColor.systemTeal
        }
    }
    #endif
}

/// Represents who sent a message
enum MessageSender: String, CaseIterable, Codable {
    case user = "user"
    case partner = "partner"
    case system = "system"
    
    var displayName: String {
        switch self {
        case .user:
            return "You"
        case .partner:
            return "Partner"
        case .system:
            return "System"
        }
    }
}

// MARK: - Communication Data Structures

/// Represents tone analysis results
struct ToneAnalysis: Codable {
    let status: ToneStatus
    let confidence: Double
    let suggestions: [String]
    let attachmentContext: AttachmentStyle?
    let communicationPattern: CommunicationPattern?
    let urgencyLevel: UrgencyLevel
    let timestamp: Date
    
    init(status: ToneStatus = .neutral, confidence: Double = 0.0, suggestions: [String] = [], attachmentContext: AttachmentStyle? = nil, communicationPattern: CommunicationPattern? = nil, urgencyLevel: UrgencyLevel = .low, timestamp: Date = Date()) {
        self.status = status
        self.confidence = confidence
        self.suggestions = suggestions
        self.attachmentContext = attachmentContext
        self.communicationPattern = communicationPattern
        self.urgencyLevel = urgencyLevel
        self.timestamp = timestamp
    }
}

/// Represents communication suggestions
struct CommunicationSuggestion: Codable {
    let type: AnalysisSuggestionType
    let originalText: String
    let suggestedText: String
    let reason: String
    let confidence: Double
    let action: SuggestedAction
    let priority: Int
    
    init(type: AnalysisSuggestionType, originalText: String, suggestedText: String, reason: String, confidence: Double = 0.0, action: SuggestedAction = .replace, priority: Int = 0) {
        self.type = type
        self.originalText = originalText
        self.suggestedText = suggestedText
        self.reason = reason
        self.confidence = confidence
        self.action = action
        self.priority = priority
    }
}

/// Advanced suggestion structure with comprehensive metadata
struct AdvancedSuggestion: Codable, Identifiable {
    var id: UUID
    let text: String
    let type: AnalysisSuggestionType
    let priority: SuggestionPriority
    let interventionType: InterventionType
    let attachmentStyleSpecific: Bool
    let repairScript: String?
    let alternativeText: String?
    let confidence: Double
    let reasoning: String
    let expectedOutcome: String?
    let timeToImplement: TimeInterval?
    let followUpSuggestion: String?
    let attachmentContext: AttachmentStyle?
    let relationshipContext: RelationshipContext?
    let emotionalImpact: String?
    let learnMoreURL: String?
    
    init(
        text: String,
        type: AnalysisSuggestionType,
        priority: SuggestionPriority = .medium,
        interventionType: InterventionType = .enhancement,
        attachmentStyleSpecific: Bool = false,
        repairScript: String? = nil,
        alternativeText: String? = nil,
        confidence: Double = 0.5,
        reasoning: String = "",
        expectedOutcome: String? = nil,
        timeToImplement: TimeInterval? = nil,
        followUpSuggestion: String? = nil,
        attachmentContext: AttachmentStyle? = nil,
        relationshipContext: RelationshipContext? = nil,
        emotionalImpact: String? = nil,
        learnMoreURL: String? = nil
    ) {
        self.id = UUID()
        self.text = text
        self.type = type
        self.priority = priority
        self.interventionType = interventionType
        self.attachmentStyleSpecific = attachmentStyleSpecific
        self.repairScript = repairScript
        self.alternativeText = alternativeText
        self.confidence = confidence
        self.reasoning = reasoning
        self.expectedOutcome = expectedOutcome
        self.timeToImplement = timeToImplement
        self.followUpSuggestion = followUpSuggestion
        self.attachmentContext = attachmentContext
        self.relationshipContext = relationshipContext
        self.emotionalImpact = emotionalImpact
        self.learnMoreURL = learnMoreURL
    }
}

/// Contextual suggestion for real-time guidance
struct ContextualSuggestion: Codable, Identifiable {
    var id: UUID
    let suggestion: String
    let type: AnalysisSuggestionType
    let priority: SuggestionPriority
    let applicableContext: RelationshipContext
    let triggerPattern: String
    let expectedBenefit: String
    let timeframe: String?
    
    init(
        suggestion: String,
        type: AnalysisSuggestionType,
        priority: SuggestionPriority = .medium,
        applicableContext: RelationshipContext = .unknown,
        triggerPattern: String = "",
        expectedBenefit: String = "",
        timeframe: String? = nil
    ) {
        self.id = UUID()
        self.suggestion = suggestion
        self.type = type
        self.priority = priority
        self.applicableContext = applicableContext
        self.triggerPattern = triggerPattern
        self.expectedBenefit = expectedBenefit
        self.timeframe = timeframe
    }
}

/// Represents a single message in a conversation
struct ConversationMessage: Codable, Identifiable {
    var id: UUID
    let text: String
    let timestamp: Date
    let sender: MessageSender
    let toneStatus: ToneStatus
    let attachmentStyle: AttachmentStyle?
    let communicationPattern: CommunicationPattern?
    let emotionalValence: Double // -1.0 to 1.0
    let urgencyLevel: UrgencyLevel
    let wordCount: Int
    let responseTime: TimeInterval? // Time since previous message
    
    init(
        text: String,
        timestamp: Date = Date(),
        sender: MessageSender = .user,
        toneStatus: ToneStatus = .neutral,
        attachmentStyle: AttachmentStyle? = nil,
        communicationPattern: CommunicationPattern? = nil,
        emotionalValence: Double = 0.0,
        urgencyLevel: UrgencyLevel = .low,
        wordCount: Int? = nil,
        responseTime: TimeInterval? = nil
    ) {
        self.id = UUID()
        self.text = text
        self.timestamp = timestamp
        self.sender = sender
        self.toneStatus = toneStatus
        self.attachmentStyle = attachmentStyle
        self.communicationPattern = communicationPattern
        self.emotionalValence = emotionalValence
        self.urgencyLevel = urgencyLevel
        self.wordCount = wordCount ?? text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.count
        self.responseTime = responseTime
    }
}

/// Represents conversation history with metadata
struct ConversationHistory: Codable {
    let messages: [ConversationMessage]
    let relationshipContext: RelationshipContext
    let startTime: Date
    let endTime: Date?
    let participantCount: Int
    let dominantTone: ToneStatus
    let averageResponseTime: TimeInterval
    let totalWordCount: Int
    let escalationEvents: Int
    let repairAttempts: Int
    
    init(
        messages: [ConversationMessage],
        relationshipContext: RelationshipContext = .unknown,
        startTime: Date? = nil,
        endTime: Date? = nil,
        participantCount: Int = 2,
        dominantTone: ToneStatus = .neutral,
        averageResponseTime: TimeInterval = 0,
        totalWordCount: Int? = nil,
        escalationEvents: Int = 0,
        repairAttempts: Int = 0
    ) {
        self.messages = messages
        self.relationshipContext = relationshipContext
        self.startTime = startTime ?? messages.first?.timestamp ?? Date()
        self.endTime = endTime ?? messages.last?.timestamp
        self.participantCount = participantCount
        self.dominantTone = dominantTone
        self.averageResponseTime = averageResponseTime
        self.totalWordCount = totalWordCount ?? messages.reduce(0) { $0 + $1.wordCount }
        self.escalationEvents = escalationEvents
        self.repairAttempts = repairAttempts
    }
}

/// Represents attachment dynamics between conversation participants
struct AttachmentDynamics: Codable {
    let userStyle: AttachmentStyle
    let partnerStyle: AttachmentStyle
    let dynamicType: AttachmentDynamicType
    let compatibilityScore: Double // 0.0 to 1.0
    let triggerPatterns: [String]
    let repairStrategies: [String]
    let stabilityFactor: Double // 0.0 to 1.0
    let growthPotential: Double // 0.0 to 1.0
    
    init(
        userStyle: AttachmentStyle = .unknown,
        partnerStyle: AttachmentStyle = .unknown,
        dynamicType: AttachmentDynamicType = .secure,
        compatibilityScore: Double = 0.5,
        triggerPatterns: [String] = [],
        repairStrategies: [String] = [],
        stabilityFactor: Double = 0.5,
        growthPotential: Double = 0.5
    ) {
        self.userStyle = userStyle
        self.partnerStyle = partnerStyle
        self.dynamicType = dynamicType
        self.compatibilityScore = compatibilityScore
        self.triggerPatterns = triggerPatterns
        self.repairStrategies = repairStrategies
        self.stabilityFactor = stabilityFactor
        self.growthPotential = growthPotential
    }
}

/// Represents conversation flow analysis
struct ConversationFlowAnalysis: Codable {
    let responsePattern: ResponsePattern
    let emotionalProgression: EmotionalProgression
    let communicationHealth: CommunicationHealth
    let averageResponseTime: TimeInterval
    let responseTimeVariability: Double
    let escalationRisk: Double
    let repairSuccessRate: Double
    let engagementLevel: Double // 0.0 to 1.0
    let mutualUnderstanding: Double // 0.0 to 1.0
    
    init(
        responsePattern: ResponsePattern = .normal,
        emotionalProgression: EmotionalProgression = .stable,
        communicationHealth: CommunicationHealth = .healthy,
        averageResponseTime: TimeInterval = 0,
        responseTimeVariability: Double = 0,
        escalationRisk: Double = 0,
        repairSuccessRate: Double = 0,
        engagementLevel: Double = 0.5,
        mutualUnderstanding: Double = 0.5
    ) {
        self.responsePattern = responsePattern
        self.emotionalProgression = emotionalProgression
        self.communicationHealth = communicationHealth
        self.averageResponseTime = averageResponseTime
        self.responseTimeVariability = responseTimeVariability
        self.escalationRisk = escalationRisk
        self.repairSuccessRate = repairSuccessRate
        self.engagementLevel = engagementLevel
        self.mutualUnderstanding = mutualUnderstanding
    }
}

/// Comprehensive conversation analysis results
struct ConversationAnalysis: Codable {
    let history: ConversationHistory
    let overallQuality: ConversationQuality
    let emotionalTrajectory: EmotionalTrajectory
    let turnTakingPattern: TurnTakingPattern
    let attachmentDynamics: AttachmentDynamics
    let communicationHealth: CommunicationHealth
    let escalationRisk: Double // 0.0 to 1.0
    let repairOpportunities: [String]
    let strengths: [String]
    let concerns: [String]
    let recommendations: [AdvancedSuggestion]
    let flowAnalysis: ConversationFlowAnalysis
    let timestamp: Date
    
    init(
        history: ConversationHistory,
        overallQuality: ConversationQuality = .healthy,
        emotionalTrajectory: EmotionalTrajectory = .stable,
        turnTakingPattern: TurnTakingPattern = .balanced,
        attachmentDynamics: AttachmentDynamics = AttachmentDynamics(),
        communicationHealth: CommunicationHealth = .healthy,
        escalationRisk: Double = 0.0,
        repairOpportunities: [String] = [],
        strengths: [String] = [],
        concerns: [String] = [],
        recommendations: [AdvancedSuggestion] = [],
        flowAnalysis: ConversationFlowAnalysis = ConversationFlowAnalysis(),
        timestamp: Date = Date()
    ) {
        self.history = history
        self.overallQuality = overallQuality
        self.emotionalTrajectory = emotionalTrajectory
        self.turnTakingPattern = turnTakingPattern
        self.attachmentDynamics = attachmentDynamics
        self.communicationHealth = communicationHealth
        self.escalationRisk = escalationRisk
        self.repairOpportunities = repairOpportunities
        self.strengths = strengths
        self.concerns = concerns
        self.recommendations = recommendations
        self.flowAnalysis = flowAnalysis
        self.timestamp = timestamp
    }
}

// MARK: - Additional Analysis Data Structures

/// Represents preprocessed text data for analysis
struct PreprocessedTextData: Codable {
    let originalText: String
    let cleanedText: String
    let tokens: [String]
    let sentences: [String]
    let wordCount: Int
    let sentenceCount: Int
    let averageWordsPerSentence: Double
    let punctuationCount: Int
    let capitalizedWordsCount: Int
    let metadata: [String: String]
    
    init(
        originalText: String,
        cleanedText: String = "",
        tokens: [String] = [],
        sentences: [String] = [],
        wordCount: Int = 0,
        sentenceCount: Int = 0,
        averageWordsPerSentence: Double = 0,
        punctuationCount: Int = 0,
        capitalizedWordsCount: Int = 0,
        metadata: [String: String] = [:]
    ) {
        self.originalText = originalText
        self.cleanedText = cleanedText
        self.tokens = tokens
        self.sentences = sentences
        self.wordCount = wordCount
        self.sentenceCount = sentenceCount
        self.averageWordsPerSentence = averageWordsPerSentence
        self.punctuationCount = punctuationCount
        self.capitalizedWordsCount = capitalizedWordsCount
        self.metadata = metadata
    }
}

/// Represents parallel analysis results
struct ParallelAnalysisResults: Codable {
    let sentimentScores: SentimentScores
    let emotionProfile: EmotionProfile
    let linguisticFeatures: LinguisticFeatures
    let timestamp: Date
    
    init(
        sentimentScores: SentimentScores = SentimentScores(),
        emotionProfile: EmotionProfile = EmotionProfile(),
        linguisticFeatures: LinguisticFeatures = LinguisticFeatures(),
        timestamp: Date = Date()
    ) {
        self.sentimentScores = sentimentScores
        self.emotionProfile = emotionProfile
        self.linguisticFeatures = linguisticFeatures
        self.timestamp = timestamp
    }
}

/// Represents sentiment scores
struct SentimentScores: Codable {
    let positive: Float
    let negative: Float
    let neutral: Float
    let composite: Float
    let confidence: Float
    
    init(
        positive: Float = 0,
        negative: Float = 0,
        neutral: Float = 0,
        composite: Float = 0,
        confidence: Float = 0
    ) {
        self.positive = positive
        self.negative = negative
        self.neutral = neutral
        self.composite = composite
        self.confidence = confidence
    }
}

/// Represents emotion profile
struct EmotionProfile: Codable {
    let primaryEmotion: String
    let secondaryEmotions: [String]
    let intensity: Float
    let confidence: Float
    let emotionMap: [String: Float]
    let emotionIntensity: Float
    let emotionStability: Float
    let emotionComplexity: Float
    let emotionHistory: [String]

    init(
        primaryEmotion: String = "neutral",
        secondaryEmotions: [String] = [],
        intensity: Float = 0,
        confidence: Float = 0,
        emotionMap: [String: Float] = [:],
        emotionIntensity: Float = 0,
        emotionStability: Float = 0,
        emotionComplexity: Float = 0,
        emotionHistory: [String] = []
    ) {
        self.primaryEmotion = primaryEmotion
        self.secondaryEmotions = secondaryEmotions
        self.intensity = intensity
        self.confidence = confidence
        self.emotionMap = emotionMap
        self.emotionIntensity = emotionIntensity
        self.emotionStability = emotionStability
        self.emotionComplexity = emotionComplexity
        self.emotionHistory = emotionHistory
    }
}

/// Represents linguistic features
struct LinguisticFeatures: Codable {
    let wordCount: Int
    let sentenceCount: Int
    let averageWordsPerSentence: Double
    let complexityScore: Float
    let formalityScore: Float
    let features: [String: Float]
    
    init(
        wordCount: Int = 0,
        sentenceCount: Int = 0,
        averageWordsPerSentence: Double = 0,
        complexityScore: Float = 0,
        formalityScore: Float = 0,
        features: [String: Float] = [:]
    ) {
        self.wordCount = wordCount
        self.sentenceCount = sentenceCount
        self.averageWordsPerSentence = averageWordsPerSentence
        self.complexityScore = complexityScore
        self.formalityScore = formalityScore
        self.features = features
    }
}

/// Represents comprehensive tone analysis results
struct ComprehensiveToneAnalysis: Codable {
    let primaryTone: ToneStatus
    let confidence: Float
    let secondaryTones: [ToneStatus]
    let emotionProfile: EmotionProfile
    let communicationIntent: CommunicationIntent
    let attachmentAnalysis: AttachmentAnalysis
    let psychologicalState: PsychologicalState
    let relationshipDynamics: RelationshipDynamics
    let interventionRecommendations: [InterventionRecommendation]
    let riskAssessment: RiskAssessment
    let effectivenessPrediction: EffectivenessPrediction
    let confidenceMetrics: ConfidenceMetrics
    let timestamp: Date
    
    init(
        primaryTone: ToneStatus = .neutral,
        confidence: Float = 0,
        secondaryTones: [ToneStatus] = [],
        emotionProfile: EmotionProfile = EmotionProfile(),
        communicationIntent: CommunicationIntent = CommunicationIntent(),
        attachmentAnalysis: AttachmentAnalysis = AttachmentAnalysis(),
        psychologicalState: PsychologicalState = PsychologicalState(),
        relationshipDynamics: RelationshipDynamics = RelationshipDynamics(),
        interventionRecommendations: [InterventionRecommendation] = [],
        riskAssessment: RiskAssessment = RiskAssessment(),
        effectivenessPrediction: EffectivenessPrediction = EffectivenessPrediction(),
        confidenceMetrics: ConfidenceMetrics = ConfidenceMetrics(),
        timestamp: Date = Date()
    ) {
        self.primaryTone = primaryTone
        self.confidence = confidence
        self.secondaryTones = secondaryTones
        self.emotionProfile = emotionProfile
        self.communicationIntent = communicationIntent
        self.attachmentAnalysis = attachmentAnalysis
        self.psychologicalState = psychologicalState
        self.relationshipDynamics = relationshipDynamics
        self.interventionRecommendations = interventionRecommendations
        self.riskAssessment = riskAssessment
        self.effectivenessPrediction = effectivenessPrediction
        self.confidenceMetrics = confidenceMetrics
        self.timestamp = timestamp
    }
}

/// Represents communication intent
struct CommunicationIntent: Codable {
    let primaryIntent: String
    let confidence: Float
    let implicitIntents: [String]
    let goalOrientation: String
    
    init(
        primaryIntent: String = "neutral",
        confidence: Float = 0,
        implicitIntents: [String] = [],
        goalOrientation: String = "neutral"
    ) {
        self.primaryIntent = primaryIntent
        self.confidence = confidence
        self.implicitIntents = implicitIntents
        self.goalOrientation = goalOrientation
    }
}

/// Represents attachment analysis
struct AttachmentAnalysis: Codable {
    let detectedStyle: AttachmentStyle
    let confidence: Float
    let triggers: [String]
    let manifestations: [String]
    
    init(
        detectedStyle: AttachmentStyle = .unknown,
        confidence: Float = 0,
        triggers: [String] = [],
        manifestations: [String] = []
    ) {
        self.detectedStyle = detectedStyle
        self.confidence = confidence
        self.triggers = triggers
        self.manifestations = manifestations
    }
}

/// Represents psychological state
struct PsychologicalState: Codable {
    let distressLevel: Float
    let stabilityLevel: Float
    let copingCapacity: Float
    let emotionalRegulation: Float
    let mentalHealthIndicators: [String]
    
    init(
        distressLevel: Float = 0,
        stabilityLevel: Float = 0,
        copingCapacity: Float = 0,
        emotionalRegulation: Float = 0,
        mentalHealthIndicators: [String] = []
    ) {
        self.distressLevel = distressLevel
        self.stabilityLevel = stabilityLevel
        self.copingCapacity = copingCapacity
        self.emotionalRegulation = emotionalRegulation
        self.mentalHealthIndicators = mentalHealthIndicators
    }
}

/// Represents relationship dynamics
struct RelationshipDynamics: Codable {
    let dynamicType: String
    let healthScore: Float
    let communicationQuality: Float
    let conflictResolutionCapacity: Float
    let attachmentSecurity: Float
    let growthPotential: Float
    let riskFactors: [String]
    let strengthFactors: [String]
    
    init(
        dynamicType: String = "unknown",
        healthScore: Float = 0,
        communicationQuality: Float = 0,
        conflictResolutionCapacity: Float = 0,
        attachmentSecurity: Float = 0,
        growthPotential: Float = 0,
        riskFactors: [String] = [],
        strengthFactors: [String] = []
    ) {
        self.dynamicType = dynamicType
        self.healthScore = healthScore
        self.communicationQuality = communicationQuality
        self.conflictResolutionCapacity = conflictResolutionCapacity
        self.attachmentSecurity = attachmentSecurity
        self.growthPotential = growthPotential
        self.riskFactors = riskFactors
        self.strengthFactors = strengthFactors
    }
}

/// Represents intervention recommendations
struct InterventionRecommendation: Codable {
    let type: InterventionType
    let priority: SuggestionPriority
    let description: String
    let expectedOutcome: String
    let timeframe: String
    let difficulty: String
    
    init(
        type: InterventionType = .enhancement,
        priority: SuggestionPriority = .medium,
        description: String = "",
        expectedOutcome: String = "",
        timeframe: String = "",
        difficulty: String = ""
    ) {
        self.type = type
        self.priority = priority
        self.description = description
        self.expectedOutcome = expectedOutcome
        self.timeframe = timeframe
        self.difficulty = difficulty
    }
}

/// Represents risk assessment
struct RiskAssessment: Codable {
    let overallRisk: String
    let riskFactors: [String]
    let mitigationStrategies: [String]
    let urgencyLevel: UrgencyLevel
    let confidenceLevel: Float
    
    init(
        overallRisk: String = "low",
        riskFactors: [String] = [],
        mitigationStrategies: [String] = [],
        urgencyLevel: UrgencyLevel = .low,
        confidenceLevel: Float = 0
    ) {
        self.overallRisk = overallRisk
        self.riskFactors = riskFactors
        self.mitigationStrategies = mitigationStrategies
        self.urgencyLevel = urgencyLevel
        self.confidenceLevel = confidenceLevel
    }
}

/// Represents effectiveness prediction
struct EffectivenessPrediction: Codable {
    let predictedEffectiveness: Float
    let confidence: Float
    let factors: [String]
    let recommendations: [String]
    
    init(
        predictedEffectiveness: Float = 0,
        confidence: Float = 0,
        factors: [String] = [],
        recommendations: [String] = []
    ) {
        self.predictedEffectiveness = predictedEffectiveness
        self.confidence = confidence
        self.factors = factors
        self.recommendations = recommendations
    }
}

/// Represents confidence metrics
struct ConfidenceMetrics: Codable {
    let overallConfidence: Float
    let toneConfidence: Float
    let emotionConfidence: Float
    let intentConfidence: Float
    let attachmentConfidence: Float
    
    init(
        overallConfidence: Float = 0,
        toneConfidence: Float = 0,
        emotionConfidence: Float = 0,
        intentConfidence: Float = 0,
        attachmentConfidence: Float = 0
    ) {
        self.overallConfidence = overallConfidence
        self.toneConfidence = toneConfidence
        self.emotionConfidence = emotionConfidence
        self.intentConfidence = intentConfidence
        self.attachmentConfidence = attachmentConfidence
    }
}

/// Represents tone classification
struct ToneClassification: Codable {
    let primaryTone: ToneStatus
    let confidence: Float
    let secondaryTones: [ToneStatus]
    let reasoning: String
    
    init(
        primaryTone: ToneStatus = .neutral,
        confidence: Float = 0,
        secondaryTones: [ToneStatus] = [],
        reasoning: String = ""
    ) {
        self.primaryTone = primaryTone
        self.confidence = confidence
        self.secondaryTones = secondaryTones
        self.reasoning = reasoning
    }
}

/// Represents analysis context
struct AnalysisContext: Codable {
    let relationshipContext: RelationshipContext
    let conversationHistory: [String]
    let userProfile: UserProfile?
    let timestamp: Date
    
    init(
        relationshipContext: RelationshipContext = .unknown,
        conversationHistory: [String] = [],
        userProfile: UserProfile? = nil,
        timestamp: Date = Date()
    ) {
        self.relationshipContext = relationshipContext
        self.conversationHistory = conversationHistory
        self.userProfile = userProfile
        self.timestamp = timestamp
    }
}

/// Represents conversation turn
struct ConversationTurn: Codable {
    let message: String
    let sender: MessageSender
    let timestamp: Date
    let toneStatus: ToneStatus
    
    init(
        message: String,
        sender: MessageSender = .user,
        timestamp: Date = Date(),
        toneStatus: ToneStatus = .neutral
    ) {
        self.message = message
        self.sender = sender
        self.timestamp = timestamp
        self.toneStatus = toneStatus
    }
}

/// Represents cultural context
struct CulturalContext: Codable {
    let culturalBackground: String
    let communicationStyle: String
    let languageNuances: [String]
    
    init(
        culturalBackground: String = "unknown",
        communicationStyle: String = "neutral",
        languageNuances: [String] = []
    ) {
        self.culturalBackground = culturalBackground
        self.communicationStyle = communicationStyle
        self.languageNuances = languageNuances
    }
}

/// Represents advanced pattern analysis
struct AdvancedPatternAnalysis: Codable {
    let defensivePatterns: DefensivePatterns
    let attachmentActivation: AttachmentActivation
    let communicationPatterns: [String]
    
    init(
        defensivePatterns: DefensivePatterns = DefensivePatterns(),
        attachmentActivation: AttachmentActivation = AttachmentActivation(),
        communicationPatterns: [String] = []
    ) {
        self.defensivePatterns = defensivePatterns
        self.attachmentActivation = attachmentActivation
        self.communicationPatterns = communicationPatterns
    }
}

/// Represents defensive patterns
struct DefensivePatterns: Codable {
    let intensity: Float
    let patterns: [String]
    
    init(intensity: Float = 0, patterns: [String] = []) {
        self.intensity = intensity
        self.patterns = patterns
    }
}

/// Represents attachment activation
struct AttachmentActivation: Codable {
    let activationLevel: Float
    let triggers: [String]
    
    init(activationLevel: Float = 0, triggers: [String] = []) {
        self.activationLevel = activationLevel
        self.triggers = triggers
    }
}

/// Represents psychological profile
struct PsychologicalProfile: Codable {
    let distressLevel: Float
    let attachmentStyle: AttachmentStyle
    let copingStrategies: [String]
    
    init(
        distressLevel: Float = 0,
        attachmentStyle: AttachmentStyle = .unknown,
        copingStrategies: [String] = []
    ) {
        self.distressLevel = distressLevel
        self.attachmentStyle = attachmentStyle
        self.copingStrategies = copingStrategies
    }
}

/// Represents contextual insights
struct ContextualInsights: Codable {
    let context: String
    let insights: [String]
    let confidence: Float
    
    init(context: String = "", insights: [String] = [], confidence: Float = 0) {
        self.context = context
        self.insights = insights
        self.confidence = confidence
    }
}

/// Represents predictive insights
struct PredictiveInsights: Codable {
    let predictions: [String]
    let confidence: Float
    let timeframe: String
    
    init(predictions: [String] = [], confidence: Float = 0, timeframe: String = "") {
        self.predictions = predictions
        self.confidence = confidence
        self.timeframe = timeframe
    }
}

/// Represents cognitive load
struct CognitiveLoad: Codable {
    let loadLevel: Float
    let factors: [String]
    
    init(loadLevel: Float = 0, factors: [String] = []) {
        self.loadLevel = loadLevel
        self.factors = factors
    }
}

/// Represents emotional regulation
struct EmotionalRegulation: Codable {
    let regulationLevel: Float
    let strategies: [String]
    
    init(regulationLevel: Float = 0, strategies: [String] = []) {
        self.regulationLevel = regulationLevel
        self.strategies = strategies
    }
}
protocol PredictionResult: Codable {
    var confidence: Float { get }
    var timestamp: Date { get }
}

// MARK: - Keyboard Shared Types

/// Represents different keyboard operational modes
enum KeyboardMode: String, CaseIterable, Codable {
    case compact = "compact"           // Minimal UI, just tone indicator
    case expanded = "expanded"         // Full suggestion panel visible
    case suggestion = "suggestion"     // Showing specific suggestions
    case analysis = "analysis"         // Performing detailed analysis
    case settings = "settings"         // Keyboard settings view
    case letters = "letters"
    case numbers = "numbers"  
    case symbols = "symbols"
    
    var displayName: String {
        switch self {
        case .compact:
            return "Compact"
        case .expanded:
            return "Expanded"
        case .suggestion:
            return "Suggestion"
        case .analysis:
            return "Analysis"
        case .settings:
            return "Settings"
        case .letters:
            return "Letters"
        case .numbers:
            return "Numbers"
        case .symbols:
            return "Symbols"
        }
    }
    
    var keyboardHeight: CGFloat {
        switch self {
        case .compact:
            return 44
        case .expanded:
            return 120
        case .suggestion:
            return 180
        case .analysis:
            return 260
        case .settings:
            return 200
        case .letters, .numbers, .symbols:
            return 216 // Default keyboard height for these modes
        }
    }
    
    var buttonTitle: String {
        switch self {
        case .letters:
            return "123"
        case .numbers:
            return "#+"
        case .symbols:
            return "ABC"
        default:
            return ""
        }
    }
}

/// Represents the current keyboard operational state
enum KeyboardState: String, CaseIterable, Codable {
    case idle = "idle"                 // No active analysis
    case typing = "typing"             // User is actively typing
    case analyzing = "analyzing"       // Performing tone analysis
    case suggesting = "suggesting"     // Showing suggestions
    case error = "error"              // Error state
    
    var displayName: String {
        switch self {
        case .idle:
            return "Idle"
        case .typing:
            return "Typing"
        case .analyzing:
            return "Analyzing"
        case .suggesting:
            return "Suggesting"
        case .error:
            return "Error"
        }
    }
}

/// Represents different categories of suggestions the keyboard UI can display
enum SuggestionType: String, CaseIterable, Codable {
    case tone = "tone"                 // Tone improvement suggestions
    case grammar = "grammar"           // Grammar corrections
    case clarity = "clarity"           // Clarity improvements
    case attachment = "attachment"     // Attachment style adjustments
    case context = "context"          // Context-appropriate suggestions
    case emotional = "emotional"       // Emotional intelligence suggestions
    
    var displayName: String {
        switch self {
        case .tone:
            return "Tone"
        case .grammar:
            return "Grammar"
        case .clarity:
            return "Clarity"
        case .attachment:
            return "Attachment Style"
        case .context:
            return "Context"
        case .emotional:
            return "Emotional Intelligence"
        }
    }
    
    #if canImport(UIKit)
    var color: UIColor {
        switch self {
        case .tone:
            return UIColor.systemBlue
        case .grammar:
            return UIColor.systemGreen
        case .clarity:
            return UIColor.systemPurple
        case .attachment:
            return UIColor.systemOrange
        case .context:
            return UIColor.systemTeal
        case .emotional:
            return UIColor.systemPink
        }
    }
    
    var icon: String {
        switch self {
        case .tone:
            return "waveform.circle"
        case .grammar:
            return "checkmark.circle"
        case .clarity:
            return "eye.circle"
        case .attachment:
            return "heart.circle"
        case .context:
            return "bubble.left.and.bubble.right"
        case .emotional:
            return "brain.head.profile"
        }
    }
    #endif
}

/// Represents the keyboard UI visibility state
enum KeyboardUIState: String, CaseIterable, Codable {
    case hidden = "hidden"             // UI elements hidden
    case indicator = "indicator"       // Only tone indicator visible
    case suggestions = "suggestions"   // Suggestion panel visible
    case detailed = "detailed"         // Detailed analysis view
    case fullScreen = "fullScreen"     // Full keyboard analysis mode
    
    var displayName: String {
        switch self {
        case .hidden:
            return "Hidden"
        case .indicator:
            return "Indicator Only"
        case .suggestions:
            return "Suggestions"
        case .detailed:
            return "Detailed View"
        case .fullScreen:
            return "Full Screen"
        }
    }
}

/// Represents analysis modes for the keyboard
enum AnalysisMode: String, CaseIterable, Codable {
    case realTime = "realTime"         // Analyze as user types
    case onDemand = "onDemand"         // Analyze when requested
    case contextual = "contextual"     // Analyze based on context changes
    case scheduled = "scheduled"       // Periodic analysis
    
    var displayName: String {
        switch self {
        case .realTime:
            return "Real-time"
        case .onDemand:
            return "On Demand"
        case .contextual:
            return "Contextual"
        case .scheduled:
            return "Scheduled"
        }
    }
}

// MARK: - Keyboard Data Structures

/// Represents suggestion bar layout options
enum SuggestionBarLayout: String, CaseIterable, Codable {
    case horizontal = "horizontal"
    case vertical = "vertical"
    case grid = "grid"
    case popup = "popup"
    
    var displayName: String {
        switch self {
        case .horizontal:
            return "Horizontal"
        case .vertical:
            return "Vertical"
        case .grid:
            return "Grid"
        case .popup:
            return "Popup"
        }
    }
}

/// Represents keyboard suggestion metadata
struct KeyboardSuggestion: Codable {
    let type: SuggestionType
    let text: String
    let confidence: Double
    let priority: Int
    let analysisType: AnalysisSuggestionType?
    
    init(type: SuggestionType, text: String, confidence: Double = 0.0, priority: Int = 0, analysisType: AnalysisSuggestionType? = nil) {
        self.type = type
        self.text = text
        self.confidence = confidence
        self.priority = priority
        self.analysisType = analysisType
    }
}

/// Represents complete keyboard configuration
struct KeyboardConfiguration: Codable {
    let mode: KeyboardMode
    let state: KeyboardState
    let uiState: KeyboardUIState
    let analysisMode: AnalysisMode
    let layoutStyle: KeyboardLayoutStyle
    let suggestionBarLayout: SuggestionBarLayout
    let toneIndicatorPosition: ToneIndicatorPosition
    let userProfile: UserProfile
    
    init(mode: KeyboardMode = .compact, state: KeyboardState = .idle, uiState: KeyboardUIState = .indicator, analysisMode: AnalysisMode = .realTime, layoutStyle: KeyboardLayoutStyle = .overlay, suggestionBarLayout: SuggestionBarLayout = .horizontal, toneIndicatorPosition: ToneIndicatorPosition = .topRight, userProfile: UserProfile = UserProfile()) {
        self.mode = mode
        self.state = state
        self.uiState = uiState
        self.analysisMode = analysisMode
        self.layoutStyle = layoutStyle
        self.suggestionBarLayout = suggestionBarLayout
        self.toneIndicatorPosition = toneIndicatorPosition
        self.userProfile = userProfile
    }
}

/// Represents a keyboard interaction for analytics and learning
/// Represents interaction types for analytics
enum InteractionType: String, CaseIterable, Codable {
    case toneAnalysis = "tone_analysis"
    case suggestion = "suggestion"
    case quickFix = "quick_fix"
    case typing = "typing"
    case selection = "selection"
    case correction = "correction"
    
    var displayName: String {
        switch self {
        case .toneAnalysis:
            return "Tone Analysis"
        case .suggestion:
            return "Suggestion"
        case .quickFix:
            return "Quick Fix"
        case .typing:
            return "Typing"
        case .selection:
            return "Selection"
        case .correction:
            return "Correction"
        }
    }
}
struct KeyboardInteraction: Codable {
    let timestamp: Date
    let textBefore: String
    let textAfter: String
    let toneStatus: ToneStatus
    let suggestionAccepted: Bool
    let suggestionText: String?
    let analysisTime: TimeInterval
    let context: String
    let interactionType: InteractionType
    let userAcceptedSuggestion: Bool
    let communicationPattern: CommunicationPattern
    let attachmentStyleDetected: AttachmentStyle
    let relationshipContext: RelationshipContext
    let sentimentScore: Double
    let wordCount: Int
    let appContext: String
    
    init(
        timestamp: Date,
        textBefore: String,
        textAfter: String,
        toneStatus: ToneStatus,
        suggestionAccepted: Bool,
        suggestionText: String?,
        analysisTime: TimeInterval,
        context: String,
        interactionType: InteractionType,
        userAcceptedSuggestion: Bool = false,
        communicationPattern: CommunicationPattern = .neutral,
        attachmentStyleDetected: AttachmentStyle = .unknown,
        relationshipContext: RelationshipContext = .unknown,
        sentimentScore: Double = 0.0,
        wordCount: Int = 0,
        appContext: String = ""
    ) {
        self.timestamp = timestamp
        self.textBefore = textBefore
        self.textAfter = textAfter
        self.toneStatus = toneStatus
        self.suggestionAccepted = suggestionAccepted
        self.suggestionText = suggestionText
        self.analysisTime = analysisTime
        self.context = context
        self.interactionType = interactionType
        self.userAcceptedSuggestion = userAcceptedSuggestion
        self.communicationPattern = communicationPattern
        self.attachmentStyleDetected = attachmentStyleDetected
        self.relationshipContext = relationshipContext
        self.sentimentScore = sentimentScore
        self.wordCount = wordCount
        self.appContext = appContext
    }
    
    func toDictionary() -> [String: Any] {
        return [
            "timestamp": timestamp.timeIntervalSince1970,
            "text_before": textBefore,
            "text_after": textAfter,
            "tone_status": toneStatus.rawValue,
            "suggestion_accepted": suggestionAccepted,
            "suggestion_text": suggestionText ?? "",
            "analysis_time": analysisTime,
            "context": context,
            "interaction_type": interactionType.rawValue
        ]
    }
}

/// Represents communication metrics for analytics
struct CommunicationMetrics: Codable {
    let totalInteractions: Int
    let toneDistribution: [ToneStatus: Int]
    let suggestionAcceptanceRate: Float
    let averageResponseTime: Float
    let mostTriggeredPatterns: [String]
    let improvementTrend: Float
}

/// Represents comprehensive conversation analysis results
struct ConversationAnalysisResult: Codable {
    let toneStatus: ToneStatus
    let suggestions: [String]
    let attachmentStyle: AttachmentStyle?
    let communicationPattern: CommunicationPattern?
    let relationshipContext: RelationshipContext?
    let sentimentScore: Float
    let confidence: Float
}

/// Represents conversation context for analysis
struct ConversationContext: Codable {
    let appName: String
    let conversationLength: Int
    let recentMessages: [String]
    let participants: [String]
    let conversationType: ConversationType
    let emotionalTone: ToneStatus?
    let urgencyLevel: UrgencyLevel
    let lastInteractionTime: Date
}

/// Tracks suggestion usage and effectiveness
struct SuggestionUsageAnalytics: Codable {
    let suggestionId: String
    let type: AnalysisSuggestionType
    let wasAccepted: Bool
    let timeToDecision: TimeInterval
    let followUpAction: String?
    let perceivedHelpfulness: Double? // 1.0 to 5.0
    let userFeedback: String?
    let contextualFactors: [String]
    let timestamp: Date
    
    init(
        suggestionId: String,
        type: AnalysisSuggestionType,
        wasAccepted: Bool,
        timeToDecision: TimeInterval = 0,
        followUpAction: String? = nil,
        perceivedHelpfulness: Double? = nil,
        userFeedback: String? = nil,
        contextualFactors: [String] = [],
        timestamp: Date = Date()
    ) {
        self.suggestionId = suggestionId
        self.type = type
        self.wasAccepted = wasAccepted
        self.timeToDecision = timeToDecision
        self.followUpAction = followUpAction
        self.perceivedHelpfulness = perceivedHelpfulness
        self.userFeedback = userFeedback
        self.contextualFactors = contextualFactors
        self.timestamp = timestamp
    }
}

// MARK: - Personality Test Integration

/// Represents personality test results from the main app
struct PersonalityTestResults: Codable {
    let userAttachmentStyle: AttachmentStyle
    let partnerAttachmentStyle: AttachmentStyle?
    let communicationPreferences: [CommunicationPattern]
    let primaryRelationshipContext: RelationshipContext
    let testCompletionDate: Date
    let testVersion: String
    let confidenceScore: Double // 0.0 to 1.0
    let additionalTraits: [String: String]? // For future personality dimensions
    
    init(
        userAttachmentStyle: AttachmentStyle,
        partnerAttachmentStyle: AttachmentStyle? = nil,
        communicationPreferences: [CommunicationPattern] = [],
        primaryRelationshipContext: RelationshipContext = .unknown,
        testCompletionDate: Date = Date(),
        testVersion: String = "1.0",
        confidenceScore: Double = 1.0,
        additionalTraits: [String: String]? = nil
    ) {
        self.userAttachmentStyle = userAttachmentStyle
        self.partnerAttachmentStyle = partnerAttachmentStyle
        self.communicationPreferences = communicationPreferences
        self.primaryRelationshipContext = primaryRelationshipContext
        self.testCompletionDate = testCompletionDate
        self.testVersion = testVersion
        self.confidenceScore = confidenceScore
        self.additionalTraits = additionalTraits
    }
    
    /// Convert to dictionary for UserDefaults storage
    func toDictionary() -> [String: Any] {
        var dict: [String: Any] = [
            "userAttachmentStyle": userAttachmentStyle.rawValue,
            "primaryRelationshipContext": primaryRelationshipContext.rawValue,
            "communicationPreferences": communicationPreferences.map { $0.rawValue },
            "testCompletionDate": testCompletionDate.timeIntervalSince1970,
            "testVersion": testVersion,
            "confidenceScore": confidenceScore
        ]
        
        if let partnerStyle = partnerAttachmentStyle {
            dict["partnerAttachmentStyle"] = partnerStyle.rawValue
        }
        
        if let traits = additionalTraits {
            dict["additionalTraits"] = traits
        }
        
        return dict
    }
    
    /// Create from dictionary retrieved from UserDefaults
    static func fromDictionary(_ dict: [String: Any]) -> PersonalityTestResults? {
        guard let userStyleRaw = dict["userAttachmentStyle"] as? String,
              let userStyle = AttachmentStyle(rawValue: userStyleRaw),
              let contextRaw = dict["primaryRelationshipContext"] as? String,
              let context = RelationshipContext(rawValue: contextRaw),
              let timestamp = dict["testCompletionDate"] as? TimeInterval,
              let version = dict["testVersion"] as? String,
              let confidence = dict["confidenceScore"] as? Double else {
            return nil
        }
        
        let partnerStyle: AttachmentStyle? = {
            if let partnerStyleRaw = dict["partnerAttachmentStyle"] as? String {
                return AttachmentStyle(rawValue: partnerStyleRaw)
            }
            return nil
        }()
        
        let preferences: [CommunicationPattern] = {
            if let prefsRaw = dict["communicationPreferences"] as? [String] {
                return prefsRaw.compactMap { CommunicationPattern(rawValue: $0) }
            }
            return []
        }()
        
        return PersonalityTestResults(
            userAttachmentStyle: userStyle,
            partnerAttachmentStyle: partnerStyle,
            communicationPreferences: preferences,
            primaryRelationshipContext: context,
            testCompletionDate: Date(timeIntervalSince1970: timestamp),
            testVersion: version,
            confidenceScore: confidence,
            additionalTraits: dict["additionalTraits"] as? [String: String]
        )
    }
}

// MARK: - UnsaidSharedTypes Access
class UnsaidSharedTypes {
    static let appGroupIdentifier = AppGroups.shared
}

