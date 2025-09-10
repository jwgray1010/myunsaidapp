import Flutter
import UIKit
import Foundation

@objc public class KeyboardDataSyncBridge: NSObject, FlutterPlugin {
    
    // MARK: - Constants
    private static let channelName = "com.unsaid/keyboard_data_sync"
    // Use the String identifier; previously pointed at UserDefaults causing type mismatch
    private static let appGroupID  = AppGroups.id
    
    // Storage keys must match the keyboard extension writers
    private enum Keys {
        // SafeKeyboardDataStorage
        static let pendingInteractions = "pending_keyboard_interactions"
        static let pendingAnalytics    = "pending_keyboard_analytics"
        static let pendingToneData     = "pending_tone_analysis_data"
        static let pendingSuggestions  = "pending_suggestion_data"
        static let storageMetadata     = "keyboard_storage_metadata"
        
        // Coordinator API response storage
        // e.g. endpoint "suggestions" → "latest_api_suggestions" & "api_suggestions_queue"
        static let latestAPISuggestions = "latest_api_suggestions"
        static let apiSuggestionsQueue  = "api_suggestions_queue"
        static let latestTrialStatus    = "latest_trial_status"
        static let apiTrialStatusQueue  = "api_trial_status_queue" // if you choose to queue trial statuses
        // User keys (shared)
        static let userId               = "user_id"
        static let userIdAlt            = "userId"
        static let userEmail            = "user_email"
        static let userEmailAlt         = "userEmail"
        static let attachmentStyle      = "attachment_style"
        static let personalityData      = "personality_data_v2" // Bridge uses v2
    }
    
    // MARK: - Plugin Registration
    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: channelName, binaryMessenger: registrar.messenger())
        let instance = KeyboardDataSyncBridge()
        registrar.addMethodCallDelegate(instance, channel: channel)
    }
    
    // MARK: - Method Channel Handler
    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        print("🔄 KeyboardDataSyncBridge: Handling method '\(call.method)'")
        
        switch call.method {
        case "getAllPendingKeyboardData":
            getAllPendingKeyboardData(result: result)
        case "getKeyboardStorageMetadata":
            getKeyboardStorageMetadata(result: result)
        case "clearAllPendingKeyboardData":
            clearAllPendingKeyboardData(result: result)
        case "getUserData":
            getUserData(result: result)
        case "getAPIData":
            getAPIData(result: result)
        default:
            result(FlutterMethodNotImplemented)
        }
    }
    
    // MARK: - Shared UserDefaults
    private var sharedUserDefaults: UserDefaults? {
        UserDefaults(suiteName: Self.appGroupID)
    }
    
    // MARK: - Helpers (safe reads)
    private func arrayDict(forKey key: String, in defaults: UserDefaults) -> [[String: Any]] {
        (defaults.array(forKey: key) as? [[String: Any]]) ?? []
    }
    
    private func dict(forKey key: String, in defaults: UserDefaults) -> [String: Any] {
        (defaults.dictionary(forKey: key)) ?? [:]
    }
    
    // MARK: - Get All Pending Keyboard Data
    private func getAllPendingKeyboardData(result: @escaping FlutterResult) {
        guard let shared = sharedUserDefaults else {
            print("❌ KeyboardDataSyncBridge: Unable to access shared UserDefaults")
            result(FlutterError(code: "SHARED_STORAGE_ERROR",
                                message: "Unable to access shared storage",
                                details: nil))
            return
        }
        
        let interactions = arrayDict(forKey: Keys.pendingInteractions, in: shared)
        let toneData     = arrayDict(forKey: Keys.pendingToneData,     in: shared)
        let suggestions  = arrayDict(forKey: Keys.pendingSuggestions,  in: shared)
        let analytics    = arrayDict(forKey: Keys.pendingAnalytics,    in: shared)
        
        // API data queues (from ToneSuggestionCoordinator.storeAPIResponseInSharedStorage)
        let apiSuggestionsQueue = arrayDict(forKey: Keys.apiSuggestionsQueue, in: shared)
        let apiTrialQueue       = arrayDict(forKey: Keys.apiTrialStatusQueue, in: shared) // may be empty if unused
        
        let totalItems = interactions.count + toneData.count + suggestions.count + analytics.count
                         + apiSuggestionsQueue.count + apiTrialQueue.count
        
        let metadata: [String: Any] = [
            "total_items": totalItems,
            "sync_timestamp": Date().timeIntervalSince1970,
            "app_group_id": Self.appGroupID,
            "has_pending_data": totalItems > 0
        ]
        
        let allData: [String: Any] = [
            "interactions": interactions,
            "tone_data": toneData,
            "suggestions": suggestions,
            "analytics": analytics,
            "api_suggestions": apiSuggestionsQueue,
            "api_trial_status": apiTrialQueue,
            "metadata": metadata
        ]
        
        print("✅ KeyboardDataSyncBridge: Retrieved \(totalItems) total items")
        // Always return a dictionary (even if empty) so the Dart side has a stable shape
        result(allData)
    }
    
    // MARK: - Get Storage Metadata
    private func getKeyboardStorageMetadata(result: @escaping FlutterResult) {
        guard let shared = sharedUserDefaults else {
            // Return safe defaults for new users instead of error
            let safeDefaults: [String: Any] = [
                "interaction_count": 0,
                "tone_count": 0,
                "suggestion_count": 0,
                "analytics_count": 0,
                "api_suggestions_count": 0,
                "api_trial_count": 0,
                "total_items": 0,
                "has_pending_data": false,
                "last_checked": Date().timeIntervalSince1970,
                "status": "new_user_or_app_group_not_configured"
            ]
            result(safeDefaults)
            return
        }
        
        // Safe count retrieval with error handling
        let interactionCount = max(0, arrayDict(forKey: Keys.pendingInteractions, in: shared).count)
        let toneCount = max(0, arrayDict(forKey: Keys.pendingToneData, in: shared).count)
        let suggestionCount = max(0, arrayDict(forKey: Keys.pendingSuggestions, in: shared).count)
        let analyticsCount = max(0, arrayDict(forKey: Keys.pendingAnalytics, in: shared).count)
        let apiSuggestionsCount = max(0, arrayDict(forKey: Keys.apiSuggestionsQueue, in: shared).count)
        let apiTrialCount = max(0, arrayDict(forKey: Keys.apiTrialStatusQueue, in: shared).count)
        
        let totalItems = interactionCount + toneCount + suggestionCount + analyticsCount
                       + apiSuggestionsCount + apiTrialCount
        
        let metadata: [String: Any] = [
            "interaction_count": interactionCount,
            "tone_count": toneCount,
            "suggestion_count": suggestionCount,
            "analytics_count": analyticsCount,
            "api_suggestions_count": apiSuggestionsCount,
            "api_trial_count": apiTrialCount,
            "total_items": totalItems,
            "has_pending_data": totalItems > 0,
            "last_checked": Date().timeIntervalSince1970,
            "status": "active"
        ]
        
        // If SafeKeyboardDataStorage also writes a metadata blob, merge it in (non-destructively)
        let storageMeta = dict(forKey: Keys.storageMetadata, in: shared)
        let merged = storageMeta.merging(metadata) { _, new in new }
        
        result(merged)
    }
    
    // MARK: - Clear All Pending Data
    private func clearAllPendingKeyboardData(result: @escaping FlutterResult) {
        guard let shared = sharedUserDefaults else {
            result(FlutterError(code: "SHARED_STORAGE_ERROR",
                                message: "Unable to access shared storage",
                                details: nil))
            return
        }
        
        // Clear queues written by SafeKeyboardDataStorage
        shared.removeObject(forKey: Keys.pendingInteractions)
        shared.removeObject(forKey: Keys.pendingAnalytics)
        shared.removeObject(forKey: Keys.pendingToneData)
        shared.removeObject(forKey: Keys.pendingSuggestions)
        
        // Clear API response queues if you want them cleared here too
        shared.removeObject(forKey: Keys.apiSuggestionsQueue)
        shared.removeObject(forKey: Keys.apiTrialStatusQueue)
        
        // Optionally clear “latest” singletons (usually fine to keep)
        // shared.removeObject(forKey: Keys.latestAPISuggestions)
        // shared.removeObject(forKey: Keys.latestTrialStatus)
        
        shared.synchronize()
        
        print("✅ KeyboardDataSyncBridge: Cleared all pending keyboard data")
        result(true)
    }
    
    // MARK: - Get User Data
    private func getUserData(result: @escaping FlutterResult) {
        guard let shared = sharedUserDefaults else {
            result(FlutterError(code: "SHARED_STORAGE_ERROR",
                                message: "Unable to access shared storage",
                                details: nil))
            return
        }
        
        // Resolve fallbacks and avoid optionals in output
        let userId   = shared.string(forKey: Keys.userId) ?? shared.string(forKey: Keys.userIdAlt) ?? ""
        let email    = shared.string(forKey: Keys.userEmail) ?? shared.string(forKey: Keys.userEmailAlt) ?? ""
        let attach   = shared.string(forKey: Keys.attachmentStyle) ?? ""
        let persona  = shared.dictionary(forKey: Keys.personalityData) ?? [:]
        
        let userData: [String: Any] = [
            "user_id": userId,
            "user_email": email,
            "attachment_style": attach,
            "personality_data": persona
        ]
        
        result(userData)
    }
    
    // MARK: - Get API Data (latest + history)
    private func getAPIData(result: @escaping FlutterResult) {
        guard let shared = sharedUserDefaults else {
            result(FlutterError(code: "SHARED_STORAGE_ERROR",
                                message: "Unable to access shared storage",
                                details: nil))
            return
        }
        
        // Latest blobs written by the coordinator
        let latestSuggestion = dict(forKey: Keys.latestAPISuggestions, in: shared) // key: "latest_api_suggestions"
        let latestTrial      = dict(forKey: Keys.latestTrialStatus,   in: shared) // key: "latest_trial_status"
        
        // Queues/history
        let suggestionHistory = arrayDict(forKey: Keys.apiSuggestionsQueue, in: shared) // "api_suggestions_queue"
        let trialHistory      = arrayDict(forKey: Keys.apiTrialStatusQueue, in: shared) // optional
        
        let apiData: [String: Any] = [
            "latest_suggestions": latestSuggestion,   // plural form per coordinator
            "latest_trial_status": latestTrial,
            "suggestion_history": suggestionHistory,
            "trial_status_history": trialHistory
        ]
        
        result(apiData)
    }
}
