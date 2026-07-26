import Foundation
import AVFoundation
import CoreGraphics
import EventKit
import UserNotifications

/// Centralizes the system permissions AlmRecorder needs, so the setup wizard (and Settings) can show
/// status + request them in one place instead of the scattered call sites.
@MainActor
final class PermissionsManager: ObservableObject {
    static let shared = PermissionsManager()

    enum Status { case granted, denied, notDetermined }

    @Published var microphone: Status = .notDetermined       // required to record
    @Published var screenRecording: Status = .notDetermined  // required for system/meeting audio
    @Published var calendar: Status = .notDetermined          // optional: auto-record meetings
    @Published var notifications: Status = .notDetermined     // optional: meeting prompts

    func refresh() async {
        microphone = Self.micStatus()
        // Screen Recording has no "denied" query — CGPreflight returns false until granted (and the
        // grant only takes effect after a relaunch).
        screenRecording = CGPreflightScreenCaptureAccess() ? .granted : .notDetermined
        calendar = Self.calendarStatus()
        notifications = await Self.notificationStatus()
    }

    func requestMicrophone() async {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        }
        microphone = Self.micStatus()
    }

    /// Prompts for Screen Recording. macOS requires an app relaunch before the grant takes effect.
    func requestScreenRecording() {
        _ = CGRequestScreenCaptureAccess()
        screenRecording = CGPreflightScreenCaptureAccess() ? .granted : .notDetermined
    }

    func requestCalendar() async {
        _ = await CalendarService.shared.requestAccess()
        calendar = Self.calendarStatus()
    }

    func requestNotifications() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        notifications = await Self.notificationStatus()
    }

    // MARK: - Status readers

    private static func micStatus() -> Status {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .granted
        case .denied, .restricted: return .denied
        default: return .notDetermined
        }
    }

    private static func calendarStatus() -> Status {
        let s = EKEventStore.authorizationStatus(for: .event)
        if #available(macOS 14.0, *), s == .fullAccess { return .granted }
        switch s {
        case .authorized: return .granted
        case .denied, .restricted: return .denied
        default: return .notDetermined
        }
    }

    private static func notificationStatus() async -> Status {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: return .granted
        case .denied: return .denied
        default: return .notDetermined
        }
    }
}
