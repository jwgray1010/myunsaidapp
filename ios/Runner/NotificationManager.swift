import Foundation
import UserNotifications
import os.log

/// Manages local notifications for data insights and reminders
@available(iOS 10.0, *)
class NotificationManager {
    static let shared = NotificationManager()
    private init() {}
    
    private let logger = Logger(subsystem: "com.example.unsaid", category: "Notifications")
    
    // Notification identifiers
    private let insightsAvailableID = "insights_available"
    private let dataReminderID = "data_reminder"
    private let weeklyInsightsID = "weekly_insights"
    
    // MARK: - Setup
    
    func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .badge, .sound]
        ) { [weak self] granted, error in
            if let error = error {
                self?.logger.error("❌ Notification permission error: \(error.localizedDescription)")
            } else {
                self?.logger.info("📱 Notification permission: \(granted ? "granted" : "denied")")
            }
        }
    }
    
    // MARK: - Smart Notifications
    
    func scheduleInsightsAvailableNotification() {
        // Check if we should actually send this notification
        guard shouldSendInsightsNotification() else { return }
        
        let content = UNMutableNotificationContent()
        content.title = "Your communication insights are ready! 📊"
        content.body = "Discover new patterns in your conversations and relationship style."
        content.sound = .default
        content.badge = 1
        
        // Trigger in 30 minutes to avoid immediate interruption
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 30 * 60, repeats: false)
        
        let request = UNNotificationRequest(
            identifier: insightsAvailableID,
            content: content,
            trigger: trigger
        )
        
        UNUserNotificationCenter.current().add(request) { [weak self] error in
            if let error = error {
                self?.logger.error("❌ Failed to schedule insights notification: \(error.localizedDescription)")
            } else {
                self?.logger.info("📅 Insights notification scheduled")
            }
        }
    }
    
    func scheduleGentleReminder() {
        // Only if user hasn't opened app in 3+ days and has data
        guard shouldSendReminderNotification() else { return }
        
        let content = UNMutableNotificationContent()
        content.title = "New communication patterns detected 🔍"
        content.body = "See how your conversation style has evolved this week."
        content.sound = .default
        
        // Schedule for tomorrow at 7 PM (user's likely free time)
        var dateComponents = DateComponents()
        dateComponents.hour = 19
        dateComponents.minute = 0
        
        let trigger = UNCalendarNotificationTrigger(dateMatching: dateComponents, repeats: false)
        
        let request = UNNotificationRequest(
            identifier: dataReminderID,
            content: content,
            trigger: trigger
        )
        
        UNUserNotificationCenter.current().add(request) { [weak self] error in
            if let error = error {
                self?.logger.error("❌ Failed to schedule reminder: \(error.localizedDescription)")
            } else {
                self?.logger.info("📅 Gentle reminder scheduled")
            }
        }
    }
    
    func scheduleWeeklyInsights() {
        // Weekly summary notification
        let content = UNMutableNotificationContent()
        content.title = "Your weekly communication summary ✨"
        content.body = "See your progress and discover insights about your relationship patterns."
        content.sound = .default
        
        // Every Sunday at 6 PM
        var dateComponents = DateComponents()
        dateComponents.weekday = 1 // Sunday
        dateComponents.hour = 18
        dateComponents.minute = 0
        
        let trigger = UNCalendarNotificationTrigger(dateMatching: dateComponents, repeats: true)
        
        let request = UNNotificationRequest(
            identifier: weeklyInsightsID,
            content: content,
            trigger: trigger
        )
        
        UNUserNotificationCenter.current().add(request) { [weak self] error in
            if let error = error {
                self?.logger.error("❌ Failed to schedule weekly insights: \(error.localizedDescription)")
            } else {
                self?.logger.info("📅 Weekly insights notification scheduled")
            }
        }
    }
    
    // MARK: - Smart Logic
    
    private func shouldSendInsightsNotification() -> Bool {
        let defaults = UserDefaults(suiteName: AppGroups.id)
        
        // Check if user has significant data
        let metadata = defaults?.dictionary(forKey: "keyboard_storage_metadata")
        let totalItems = metadata?["total_items"] as? Int ?? 0
        
        // Check last app open time
        let lastAppOpen = defaults?.double(forKey: "last_app_open_time") ?? 0
        let daysSinceOpen = (Date().timeIntervalSince1970 - lastAppOpen) / (24 * 60 * 60)
        
        // Check if we already sent notification recently
        let lastNotificationTime = defaults?.double(forKey: "last_insights_notification") ?? 0
        let daysSinceNotification = (Date().timeIntervalSince1970 - lastNotificationTime) / (24 * 60 * 60)
        
        // Send if:
        // - Has 20+ interactions
        // - Hasn't opened app in 2+ days
        // - Haven't sent notification in last 5 days
        let shouldSend = totalItems >= 20 && daysSinceOpen >= 2 && daysSinceNotification >= 5
        
        if shouldSend {
            // Mark that we're sending notification
            defaults?.set(Date().timeIntervalSince1970, forKey: "last_insights_notification")
        }
        
        return shouldSend
    }
    
    private func shouldSendReminderNotification() -> Bool {
        let defaults = UserDefaults(suiteName: AppGroups.id)
        
        // Check last app open time
        let lastAppOpen = defaults?.double(forKey: "last_app_open_time") ?? 0
        let daysSinceOpen = (Date().timeIntervalSince1970 - lastAppOpen) / (24 * 60 * 60)
        
        // Check if user has been using keyboard
        let metadata = defaults?.dictionary(forKey: "keyboard_storage_metadata")
        let totalItems = metadata?["total_items"] as? Int ?? 0
        
        // Send gentle reminder if:
        // - Hasn't opened app in 3+ days
        // - Has some keyboard activity (5+ items)
        // - Not a completely new user
        return daysSinceOpen >= 3 && totalItems >= 5
    }
    
    // MARK: - Management
    
    func cancelAllNotifications() {
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
        logger.info("🗑️ All notifications cancelled")
    }
    
    func cancelInsightsNotifications() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(
            withIdentifiers: [insightsAvailableID, dataReminderID]
        )
        logger.info("🗑️ Insights notifications cancelled")
    }
    
    func updateLastAppOpenTime() {
        let defaults = UserDefaults(suiteName: AppGroups.id)
        defaults?.set(Date().timeIntervalSince1970, forKey: "last_app_open_time")
        logger.debug("📱 Updated last app open time")
    }
}
