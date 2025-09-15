//
//  000_UnsaidSharedTypes.swift
//  Unsaid
//
//  Essential share    /// SF Symbol name to use for the tone (nil for neutral).
    var symbolName: String? {
        switch self {
        case .neutral: return nil
        case .alert:   return nil
        case .caution: return nil
        case .clear:   return nil  // No checkmark either
        }
    }nd enums used across keyboard modules
//  Cleaned up to include only actively used types
//
//  Created by John Gray on 7/11/25.
//

import Foundation
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Protocol Definitions

/// Protocol for tone streaming delegate
protocol ToneStreamDelegate: AnyObject {
    func toneStreamDidConnect()
    func toneStreamDidDisconnect()
    func toneStreamDidReceiveToneUpdate(intensity: Float, sharpness: Float)
}

// MARK: - Core Essential Types

/// Represents different tone statuses - ACTIVELY USED
public enum ToneStatus: String, CaseIterable, Codable, Sendable {
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

// MARK: - ToneStatus Extensions

public extension ToneStatus {
    /// Neutral intentionally shows no icon.
    var showsIcon: Bool { self != .neutral }

    /// SF Symbol name to use for the tone (nil for neutral).
    var symbolName: String? {
        switch self {
        case .neutral: return nil
        case .alert:   return nil  // Just use color, no triangle
        case .caution: return nil  // Just use color, no triangle
        case .clear:   return nil  // No checkmark either
        }
    }

    /// Safe mapping from arbitrary strings (e.g. server/UI) to enum.
    /// Returns nil for unknown/invalid strings instead of defaulting to .neutral
    static func fromString(_ string: String?) -> ToneStatus? {
        guard let string = string?.lowercased() else { return nil }
        return ToneStatus(rawValue: string)
    }

    /// Safe mapping from arbitrary strings (e.g. server/UI) to enum.
    /// Defaults to .neutral for unknown strings (for backward compatibility)
    init(from string: String?) {
        self = ToneStatus(rawValue: (string ?? "").lowercased()) ?? .neutral
    }
}

/// Represents different attachment styles - ACTIVELY USED
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

/// Represents different keyboard operational modes - ACTIVELY USED
enum KeyboardMode: String, CaseIterable, Codable {
    case letters = "letters"
    case numbers = "numbers"  
    case symbols = "symbols"
    
    var displayName: String {
        switch self {
        case .letters:
            return "Letters"
        case .numbers:
            return "Numbers"
        case .symbols:
            return "Symbols"
        }
    }
    
    var keyboardHeight: CGFloat {
        return 216 // Default keyboard height
    }
    
    var buttonTitle: String {
        switch self {
        case .letters:
            return "123"
        case .numbers:
            return "#+"
        case .symbols:
            return "ABC"
        }
    }
}

/// Represents different communication patterns - ACTIVELY USED in UserProfile
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
}

/// Represents different relationship contexts - ACTIVELY USED in UserProfile
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
}

/// Represents interaction types for keyboard analytics
enum InteractionType: String, CaseIterable, Codable {
    case toneAnalysis = "tone_analysis"
    case suggestion = "suggestion"
    case keyPress = "key_press"
    case textEntry = "text_entry"
    case correction = "correction"
}

// MARK: - Global Variables

/// Stream enabled state for tone analysis
var isStreamEnabled: Bool = false

// MARK: - Data Structures

/// Represents keyboard interaction for analytics
struct KeyboardInteraction: Codable {
    let id: UUID
    let timestamp: Date
    let textLength: Int
    let toneStatus: ToneStatus
    let confidence: Double
    let responseTime: TimeInterval
    let suggestionText: String?
    let wasAccepted: Bool
    let deviceModel: String
    let interactionType: InteractionType
    let keyboardMode: KeyboardMode
    let communicationPattern: CommunicationPattern
    let attachmentStyleDetected: AttachmentStyle
    let relationshipContext: RelationshipContext
    let analysisTime: TimeInterval
    
    init(
        timestamp: Date = Date(),
        textLength: Int = 0,
        toneStatus: ToneStatus = .neutral,
        confidence: Double = 0.0,
        responseTime: TimeInterval = 0.0,
        suggestionText: String? = nil,
        wasAccepted: Bool = false,
        deviceModel: String = "",
        interactionType: InteractionType = .textEntry,
        keyboardMode: KeyboardMode = .letters,
        communicationPattern: CommunicationPattern = .neutral,
        attachmentStyleDetected: AttachmentStyle = .unknown,
        relationshipContext: RelationshipContext = .unknown,
        analysisTime: TimeInterval = 0.0
    ) {
        self.id = UUID()
        self.timestamp = timestamp
        self.textLength = textLength
        self.toneStatus = toneStatus
        self.confidence = confidence
        self.responseTime = responseTime
        self.suggestionText = suggestionText
        self.wasAccepted = wasAccepted
        self.deviceModel = deviceModel
        self.interactionType = interactionType
        self.keyboardMode = keyboardMode
        self.communicationPattern = communicationPattern
        self.attachmentStyleDetected = attachmentStyleDetected
        self.relationshipContext = relationshipContext
        self.analysisTime = analysisTime
    }
}

// MARK: - Constants

/// Shared constants for the application
struct SharedConstants {
    static let appGroupIdentifier = "group.com.example.unsaid"
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
