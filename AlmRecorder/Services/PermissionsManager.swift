import Foundation
import AVFoundation
import ApplicationServices
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
    @Published var accessibility: Status = .notDetermined     // optional: realtime dictation

    func refresh() async {
        microphone = Self.micStatus()
        // Do not call CGPreflightScreenCaptureAccess while idle. On current macOS versions even the
        // passive preflight is surfaced as AlmRecorder "using" screen capture in the menu bar.
        // Screen/system-audio access is checked only after an explicit grant request or when a
        // recording starts.
        calendar = Self.calendarStatus()
        notifications = await Self.notificationStatus()
        accessibility = AXIsProcessTrusted() ? .granted : .notDetermined
    }

    func requestMicrophone() async {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        }
        microphone = Self.micStatus()
    }

    /// Prompts for Screen Recording. macOS requires an app relaunch before the grant takes effect.
    func requestScreenRecording() {
        screenRecording = CGRequestScreenCaptureAccess() ? .granted : .denied
    }

    /// Records a successful ScreenCaptureKit start without performing another privacy preflight.
    func noteScreenRecordingAccessGranted() {
        screenRecording = .granted
    }

    func requestCalendar() async {
        _ = await CalendarService.shared.requestAccess()
        calendar = Self.calendarStatus()
    }

    func requestNotifications() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        notifications = await Self.notificationStatus()
    }

    func requestAccessibility() {
        let options = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
        ] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        accessibility = AXIsProcessTrusted() ? .granted : .notDetermined
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
