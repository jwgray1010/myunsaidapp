//
//  UnsaidKeyboardHelper.swift
//  Unsaid
//
//  Runner-side helper for the keyboard extension handshake + UX
//

import Foundation
import UIKit

struct KeyboardStatus {
    let enabledRecently: Bool
    let hasFullAccess: Bool
    let lastSeen: TimeInterval
    var lastSeenDate: Date? { lastSeen > 0 ? Date(timeIntervalSince1970: lastSeen) : nil }
}

final class UnsaidKeyboardHelper {
    
    // MARK: - App Group Configuration
    static let appGroupID = AppGroups.id
    
    // MARK: - Shared Keys (single source of truth)
    private enum Keys {
        static let lastSeen = "kb_last_seen"         // Double (epoch seconds) set by the extension
        static let fullAccessOK = "kb_full_access_ok"// Bool set by the extension when it detects open access
    }
    
    // MARK: - Low-level access
    private static var sharedDefaults: UserDefaults? {
        UserDefaults(suiteName: appGroupID)
    }
    
    // MARK: - Status
    
    /// Returns whether the keyboard was seen recently (default 7 days).
    /// This is a *heuristic*—Apple doesn't expose a direct API to check keyboard enablement.
    static func isKeyboardEnabled(staleAfter days: Double = 7) -> Bool {
        guard let defaults = sharedDefaults else { return false }
        let lastSeen = defaults.double(forKey: Keys.lastSeen)
        guard lastSeen > 0 else { return false }
        let elapsedDays = Date().timeIntervalSince1970 - lastSeen
        return elapsedDays < days * 24 * 60 * 60
    }
    
    /// Whether the extension reported it has full access.
    static func hasFullAccess() -> Bool {
        guard let defaults = sharedDefaults else { return false }
        return defaults.bool(forKey: Keys.fullAccessOK)
    }
    
    /// Convenience status snapshot.
    static func keyboardStatus(staleAfter days: Double = 7) -> KeyboardStatus {
        let enabled = isKeyboardEnabled(staleAfter: days)
        let access = hasFullAccess()
        let last = sharedDefaults?.double(forKey: Keys.lastSeen) ?? 0
        return KeyboardStatus(enabledRecently: enabled, hasFullAccess: access, lastSeen: last)
    }
    
    /// Debug/status dictionary if you really want a map (e.g., for logging).
    static func getKeyboardStatus(staleAfter days: Double = 7) -> [String: Any] {
        let s = keyboardStatus(staleAfter: days)
        return [
            "enabledRecently": s.enabledRecently,
            "hasFullAccess": s.hasFullAccess,
            "appGroupID": appGroupID,
            "lastSeen": s.lastSeen,
            "lastSeenDate": s.lastSeenDate as Any,
            "lastChecked": Date().timeIntervalSince1970
        ]
    }
    
    // MARK: - Settings Navigation
    
    /// Opens app Settings. Apple does not provide a public deep-link directly to the Keyboard pane.
    @MainActor
    static func openAppSettings(completion: ((Bool) -> Void)? = nil) {
        guard let url = URL(string: UIApplication.openSettingsURLString) else {
            completion?(false); return
        }
        UIApplication.shared.open(url, options: [:], completionHandler: completion)
    }
    
    /// For consistency; currently just calls `openAppSettings()`.
    @MainActor
    static func openKeyboardSettings(completion: ((Bool) -> Void)? = nil) {
        openAppSettings(completion: completion)
    }
    
    // MARK: - UX Helpers
    
    /// Presents guidance to enable keyboard and/or full access (if needed).
    @MainActor
    static func showEnableKeyboardInstructions(from presenter: UIViewController,
                                               staleAfter days: Double = 7) {
        let status = keyboardStatus(staleAfter: days)
        guard !status.enabledRecently || !status.hasFullAccess else { return }
        
        let title: String
        let message: String
        
        if !status.enabledRecently {
            title = "Enable Unsaid Keyboard"
            message = """
            To get AI-powered communication coaching:

            1. Open Settings → General → Keyboard → Keyboards
            2. Tap “Add New Keyboard…”
            3. Select “Unsaid Keyboard”
            4. Then enable “Allow Full Access” for AI features
            """
        } else {
            // enabledRecently == true, but missing full access
            title = "Enable Full Access"
            message = """
            To unlock AI coaching features:

            1. Open Settings → General → Keyboard → Keyboards
            2. Tap “Unsaid Keyboard”
            3. Enable “Allow Full Access”

            This is required for personalized coaching and tone analysis.
            """
        }
        
        // Avoid double-presenting if something is already on-screen
        guard presenter.presentedViewController == nil else { return }
        
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Open Settings", style: .default) { _ in
            openAppSettings()
        })
        alert.addAction(UIAlertAction(title: "Later", style: .cancel))
        presenter.present(alert, animated: true)
    }
    
    /// One-shot: checks status and (if needed) shows instructions, then calls completion.
    @MainActor
    static func checkAndSetupKeyboard(from presenter: UIViewController,
                                      staleAfter days: Double = 7,
                                      completion: @escaping (_ enabledRecently: Bool, _ hasFullAccess: Bool) -> Void) {
        let status = keyboardStatus(staleAfter: days)
        if !status.enabledRecently || !status.hasFullAccess {
            showEnableKeyboardInstructions(from: presenter, staleAfter: days)
        }
        completion(status.enabledRecently, status.hasFullAccess)
    }
    
    /// Just a convenience wrapper if you want a “Request Full Access” button.
    @MainActor
    static func requestFullAccess() { openAppSettings() }
}
