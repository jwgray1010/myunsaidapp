import Foundation
#if os(iOS)
import BackgroundTasks
import UIKit
#endif
import os.log

/// Manages background app refresh for automatic keyboard data sync
@available(iOS 13.0, *)
class BackgroundTaskManager {
    static let shared = BackgroundTaskManager()
    private init() {}
    
    private let logger = Logger(subsystem: "com.example.unsaid", category: "BackgroundTask")
    
    // Background task identifiers
    private let dataProcessingTaskID = "com.example.unsaid.data-processing"
    private let keyboardSyncTaskID = "com.example.unsaid.keyboard-sync"
    
    // MARK: - Registration
    
    func registerBackgroundTasks() {
        #if os(iOS)
        // Register data processing task
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: dataProcessingTaskID,
            using: nil
        ) { [weak self] task in
            self?.handleDataProcessing(task: task as! BGProcessingTask)
        }
        
        // Register keyboard sync task  
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: keyboardSyncTaskID,
            using: nil
        ) { [weak self] task in
            self?.handleKeyboardSync(task: task as! BGAppRefreshTask)
        }
        
        logger.info("✅ Background tasks registered")
        #endif
    }
    
    // MARK: - Scheduling
    
    func scheduleDataProcessing() {
        #if os(iOS)
        let request = BGProcessingTaskRequest(identifier: dataProcessingTaskID)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        request.earliestBeginDate = Date(timeIntervalSinceNow: 4 * 60 * 60) // 4 hours
        
        do {
            try BGTaskScheduler.shared.submit(request)
            logger.info("📅 Data processing task scheduled")
        } catch {
            logger.error("❌ Failed to schedule data processing: \(error.localizedDescription)")
        }
        #endif
    }
    
    func scheduleKeyboardSync() {
        #if os(iOS)
        let request = BGAppRefreshTaskRequest(identifier: keyboardSyncTaskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 2 * 60 * 60) // 2 hours
        
        do {
            try BGTaskScheduler.shared.submit(request)
            logger.info("📅 Keyboard sync task scheduled")
        } catch {
            logger.error("❌ Failed to schedule keyboard sync: \(error.localizedDescription)")
        }
        #endif
    }
    
    // MARK: - Task Handlers
    
    #if os(iOS)
    private func handleDataProcessing(task: BGProcessingTask) {
        logger.info("🔄 Background data processing started")
        
        // Schedule next task
        scheduleDataProcessing()
        
        let operationQueue = OperationQueue()
        operationQueue.maxConcurrentOperationCount = 1
        
        let operation = DataProcessingOperation()
        
        task.expirationHandler = {
            self.logger.warning("⏰ Background data processing expired")
            operationQueue.cancelAllOperations()
        }
        
        operation.completionBlock = {
            task.setTaskCompleted(success: !operation.isCancelled)
            self.logger.info("✅ Background data processing completed")
        }
        
        operationQueue.addOperation(operation)
    }
    
    private func handleKeyboardSync(task: BGAppRefreshTask) {
        logger.info("🔄 Background keyboard sync started")
        
        // Schedule next task
        scheduleKeyboardSync()
        
        let operationQueue = OperationQueue()
        operationQueue.maxConcurrentOperationCount = 1
        
        let operation = KeyboardSyncOperation()
        
        task.expirationHandler = {
            self.logger.warning("⏰ Background keyboard sync expired")
            operationQueue.cancelAllOperations()
        }
        
        operation.completionBlock = {
            task.setTaskCompleted(success: !operation.isCancelled)
            self.logger.info("✅ Background keyboard sync completed")
        }
        
        operationQueue.addOperation(operation)
    }
    #endif
}

// MARK: - Background Operations

@available(iOS 13.0, *)
class DataProcessingOperation: Operation, @unchecked Sendable {
    private let logger = Logger(subsystem: "com.example.unsaid", category: "DataProcessing")
    
    override func main() {
        guard !isCancelled else { return }
        
        logger.info("📊 Processing accumulated keyboard data...")
        
        // Sync keyboard data
        let success = syncKeyboardData()
        
        guard !isCancelled else { return }
        
        if success {
            // Send insights notification if significant patterns found
            checkForInsightsNotification()
        }
        
        logger.info("📊 Data processing completed")
    }
    
    private func syncKeyboardData() -> Bool {
        // Call the Flutter method channel to sync data
        #if canImport(UIKit)
        guard let delegate = UIApplication.shared.delegate as? AppDelegate else {
            logger.error("❌ Could not access AppDelegate")
            return false
        }
        #endif
        
        // This would need to call into Flutter's keyboard data service
        // Implementation depends on your Flutter method channel setup
        return true
    }
    
    private func checkForInsightsNotification() {
        // Check if user should be notified about new insights
        // This would examine the synced data for significant patterns
        // NotificationManager.shared.scheduleInsightsNotificationIfNeeded()
        logger.info("📊 Checking for insights notification")
    }
}

@available(iOS 13.0, *)
class KeyboardSyncOperation: Operation, @unchecked Sendable {
    private let logger = Logger(subsystem: "com.example.unsaid", category: "KeyboardSync")
    
    override func main() {
        guard !isCancelled else { return }
        
        logger.info("⌨️ Syncing keyboard data...")
        
        // Quick sync of keyboard data to main app storage
        let defaults = UserDefaults(suiteName: "group.com.example.unsaid")
        let metadata = defaults?.dictionary(forKey: "keyboard_storage_metadata")
        let totalItems: Int = metadata?["total_items"] as? Int ?? 0
        
        if totalItems > 20 { // Threshold for notification
            // Schedule notification about available data
            logger.info("📊 Data available for notification: \(totalItems) items")
        }
        
        logger.info("⌨️ Keyboard sync completed, items: \(totalItems)")
    }
}
