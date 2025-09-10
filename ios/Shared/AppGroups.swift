//
//  AppGroups.swift
//  Unsaid
//
//  Centralized App Group configuration for main app and keyboard extension
//

import Foundation

/// Centralized App Group configuration to prevent mismatches and crashes
enum AppGroups {
    /// The App Group identifier used for sharing data between main app and keyboard extension
    /// Must match the identifier configured in both targets' entitlements
    static let id = "group.com.example.unsaid"
    
    /// Safe UserDefaults accessor that falls back to standard if App Group is unavailable
    /// Never crashes - provides detailed error info for debugging
    static var defaults: UserDefaults {
        guard let ud = UserDefaults(suiteName: id) else {
            assertionFailure("App Group missing or not enabled: \(id)")
            return .standard
        }
        return ud
    }
    
    /// Alias for backwards compatibility
    static var shared: UserDefaults { defaults }
}
