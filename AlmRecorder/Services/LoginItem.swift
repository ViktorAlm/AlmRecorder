import Foundation
import ServiceManagement

/// Thin wrapper over `SMAppService` for the "Launch at startup" setting. Registering the main app
/// as a login item is the modern (macOS 13+) replacement for the deprecated login-item APIs.
enum LoginItem {
    /// Whether the app is currently registered to launch at login.
    static var isEnabled: Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return false
    }

    /// Register / unregister the app as a login item. No-ops on < macOS 13.
    static func setEnabled(_ enabled: Bool) {
        guard #available(macOS 13.0, *) else { return }
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
            } else {
                if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            }
        } catch {
            VoxtralLogger.shared.warning("[LoginItem] \(enabled ? "register" : "unregister") failed: \(error.localizedDescription)")
        }
    }
}
