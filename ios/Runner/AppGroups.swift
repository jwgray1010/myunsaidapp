//
//  AppGroups.swift
//  Runner
//
//  Centralized App Group configuration for main app and keyboard extension
//

import Foundation

/// Centralized App Group configuration (single canonical API shared by Runner & Keyboard)
enum AppGroups {
    /// App Group identifier (match entitlements in both targets)
    static let id = "group.com.example.unsaid"

    /// Primary UserDefaults for shared storage
    static var defaults: UserDefaults {
        guard let ud = UserDefaults(suiteName: id) else {
            assertionFailure("App Group missing or not enabled: \(id)")
            return .standard
        }
        return ud
    }

    /// Preferred accessor (alias)
    static var shared: UserDefaults { defaults }

    /// Deprecated / legacy aliases
    @available(*, deprecated, message: "Use AppGroups.defaults instead")
    static var userDefaults: UserDefaults { defaults }
    @available(*, deprecated, message: "Use AppGroups.id instead")
    static var sharedID: String { id }
}
