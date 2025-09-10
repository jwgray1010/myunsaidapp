//
//  AppGroups.swift
//  Unsaid
//
//  Centralized App Group configuration for main app and keyboard extension
//

import Foundation

// Single canonical AppGroups definition (NO fallbacks). Included in both targets.
enum AppGroups {
    static let id = "group.com.example.unsaid"

    static var defaults: UserDefaults {
        guard let ud = UserDefaults(suiteName: id) else {
            fatalError("App Group not configured or missing entitlements: \(id)")
        }
        return ud
    }

    static var shared: UserDefaults { defaults }

    // Keep legacy aliases temporarily to avoid breaking existing references; remove once migrated.
    @available(*, deprecated, message: "Use AppGroups.defaults")
    static var userDefaults: UserDefaults { defaults }
    @available(*, deprecated, message: "Use AppGroups.id")
    static var sharedID: String { id }
}
