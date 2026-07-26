import Foundation
import UserNotifications
import AppKit

/// Manages notifications for transcription jobs
class NotificationManager: ObservableObject {
    
    static let shared = NotificationManager()
    
    @Published var notifications: [AppNotification] = []
    @Published var hasUnreadNotifications = false
    
    private let logger = VoxtralLogger.shared
    private let isProperlyBundled: Bool
    
    private init() {
        // Check if we're running as a proper app bundle
        self.isProperlyBundled = Bundle.main.bundleIdentifier != nil && 
                                  Bundle.main.bundleURL.pathExtension == "app"
        
        logger.info("[NotificationManager] Bundle check - ID: \(Bundle.main.bundleIdentifier ?? "none"), Extension: \(Bundle.main.bundleURL.pathExtension)")
        
        if isProperlyBundled {
            requestNotificationPermission()
        } else {
            logger.warning("[NotificationManager] Running as command-line tool - system notifications disabled")
        }
    }
    
    /// In-app notification model
    struct AppNotification: Identifiable {
        let id = UUID()
        let title: String
        let message: String
        let type: NotificationType
        let timestamp = Date()
        var isRead = false
        let jobId: UUID?
        
        enum NotificationType {
            case success
            case error
            case warning
            case info
            
            var icon: String {
                switch self {
                case .success: return "checkmark.circle.fill"
                case .error: return "xmark.circle.fill"
                case .warning: return "exclamationmark.triangle.fill"
                case .info: return "info.circle.fill"
                }
            }
            
            var color: NSColor {
                switch self {
                case .success: return .systemGreen
                case .error: return .systemRed
                case .warning: return .systemOrange
                case .info: return .systemBlue
                }
            }
        }
    }
    
    // MARK: - Public Methods
    
    /// Send completion notification for a job
    func sendCompletionNotification(for job: TranscriptionJob) {
        let title: String
        let message: String
        let type: AppNotification.NotificationType
        
        switch job.status {
        case .completed:
            title = "Transcription Complete"
            message = "\(job.fileName) has been transcribed successfully"
            type = .success
            
        case .failed:
            title = "Transcription Failed"
            message = "\(job.fileName) failed: \(job.error ?? "Unknown error")"
            type = .error
            
        case .cancelled:
            title = "Transcription Cancelled"
            message = "\(job.fileName) was cancelled"
            type = .warning
            
        default:
            return
        }
        
        // Add in-app notification
        addNotification(
            title: title,
            message: message,
            type: type,
            jobId: job.id
        )
        
        // Send system notification if app is in background (only if properly bundled)
        if !NSApp.isActive && isProperlyBundled {
            sendSystemNotification(title: title, body: message)
        }
    }
    
    /// Add an in-app notification
    func addNotification(
        title: String,
        message: String,
        type: AppNotification.NotificationType,
        jobId: UUID? = nil
    ) {
        let notification = AppNotification(
            title: title,
            message: message,
            type: type,
            jobId: jobId
        )
        
        DispatchQueue.main.async {
            self.notifications.insert(notification, at: 0)
            self.hasUnreadNotifications = true
            
            // Keep only last 50 notifications
            if self.notifications.count > 50 {
                self.notifications = Array(self.notifications.prefix(50))
            }
        }
        
        logger.info("[NotificationManager] Added notification: \(title)")
    }
    
    /// Mark a notification as read
    func markAsRead(_ notificationId: UUID) {
        if let index = notifications.firstIndex(where: { $0.id == notificationId }) {
            notifications[index].isRead = true
            updateUnreadStatus()
        }
    }
    
    /// Mark all notifications as read
    func markAllAsRead() {
        for index in notifications.indices {
            notifications[index].isRead = true
        }
        hasUnreadNotifications = false
    }
    
    /// Clear all notifications
    func clearAll() {
        notifications.removeAll()
        hasUnreadNotifications = false
    }
    
    /// Clear old notifications (older than 24 hours)
    func clearOldNotifications() {
        let cutoffDate = Date().addingTimeInterval(-86400) // 24 hours ago
        notifications.removeAll { $0.timestamp < cutoffDate }
        updateUnreadStatus()
    }
    
    // MARK: - Private Methods
    
    private func requestNotificationPermission() {
        guard isProperlyBundled else {
            logger.info("[NotificationManager] Skipping notification permission - not bundled")
            return
        }
        
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if granted {
                self.logger.info("[NotificationManager] Notification permission granted")
            } else if let error = error {
                self.logger.error("[NotificationManager] Notification permission error: \(error)")
            }
        }
    }
    
    private func sendSystemNotification(title: String, body: String) {
        guard isProperlyBundled else {
            logger.info("[NotificationManager] System notification skipped (not bundled): \(title)")
            return
        }
        
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                self.logger.error("[NotificationManager] Failed to send system notification: \(error)")
            }
        }
    }

    // MARK: - Meeting auto-record prompts

    enum MeetingNotification {
        static let startCategory = "MEETING_START"
        static let endCategory = "MEETING_END"
        static let recordAction = "RECORD"
        static let stopAction = "STOP"
        static let keepAction = "KEEP"
        static let eventIdKey = "eventId"
    }

    /// Register the actionable Record / Stop / Keep categories. Call once at launch.
    func registerMeetingCategories() {
        let record = UNNotificationAction(identifier: MeetingNotification.recordAction,
                                          title: "Record", options: [.foreground])
        let stop = UNNotificationAction(identifier: MeetingNotification.stopAction,
                                        title: "Stop & Transcribe", options: [.foreground])
        let keep = UNNotificationAction(identifier: MeetingNotification.keepAction,
                                        title: "Keep Recording", options: [])
        let startCat = UNNotificationCategory(identifier: MeetingNotification.startCategory,
                                              actions: [record], intentIdentifiers: [], options: [])
        let endCat = UNNotificationCategory(identifier: MeetingNotification.endCategory,
                                            actions: [stop, keep], intentIdentifiers: [], options: [])
        UNUserNotificationCenter.current().setNotificationCategories([startCat, endCat])
    }

    func sendRecordPrompt(_ meeting: Meeting) {
        guard isProperlyBundled else { return }
        let content = UNMutableNotificationContent()
        content.title = "Record this meeting?"
        let hostSuffix = MeetingQualifier.evaluate(meeting).joinURL?.host.map { " · \($0)" } ?? ""
        content.body = meeting.title + hostSuffix
        content.sound = .default
        content.categoryIdentifier = MeetingNotification.startCategory
        content.userInfo = [MeetingNotification.eventIdKey: meeting.calendarEventId]
        let request = UNNotificationRequest(
            identifier: "meeting-start-\(meeting.calendarEventId)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    func sendStopPrompt(_ meeting: Meeting) {
        guard isProperlyBundled else { return }
        let content = UNMutableNotificationContent()
        content.title = "Stop recording?"
        content.body = "\(meeting.title) has ended."
        content.sound = .default
        content.categoryIdentifier = MeetingNotification.endCategory
        content.userInfo = [MeetingNotification.eventIdKey: meeting.calendarEventId]
        let request = UNNotificationRequest(
            identifier: "meeting-end-\(meeting.calendarEventId)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private func updateUnreadStatus() {
        hasUnreadNotifications = notifications.contains { !$0.isRead }
    }
}