import Foundation

/// Detects and persists the device owner ("you"): which voice is yours and who you are on the calendar.
///
/// Two independent signals, persisted in `app_settings`:
///   - **calendar identity** (name/email) — captured from EventKit `isCurrentUser` during calendar sync.
///   - **owner voice** (`speaker_uuid`) — detected from recording stats via `OwnerVoiceSelector`, or set
///     explicitly when the user confirms in the inbox.
final class OwnerIdentityService {
    static let shared = OwnerIdentityService()

    private let settings = GRDBSettingsRepository.shared
    private let db = GRDBDatabaseManager.shared
    private let logger = VoxtralLogger.shared

    private enum Key {
        static let voice = "owner.speakerUuid"
        static let name  = "owner.name"
        static let email = "owner.email"
    }

    private init() {}

    // MARK: - Calendar identity (who you are on the invite)

    /// Record the owner's calendar name/email (from `EKParticipant.isCurrentUser`). Idempotent; ignores
    /// empties so a later event missing the current-user participant can't erase a good value.
    func setCalendarIdentity(name: String?, email: String?) {
        if let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            settings.setString(name, forKey: Key.name)
        }
        if let email = email?.trimmingCharacters(in: .whitespacesAndNewlines), !email.isEmpty {
            settings.setString(email, forKey: Key.email)
        }
    }

    // MARK: - Owner voice

    /// The owner voice if known (explicitly confirmed or previously detected).
    var ownerVoiceUuid: String? { settings.getString(forKey: Key.voice) }

    /// Explicitly set (or clear) the owner voice — used when the user confirms "this is me" in the inbox.
    func setOwnerVoice(_ uuid: String?) { settings.setString(uuid, forKey: Key.voice) }

    /// Detect the owner voice from recording statistics if not already set. High precision: persists only a
    /// clear winner (`OwnerVoiceSelector` returns nil on ambiguity, leaving it for the user to confirm).
    @discardableResult
    func detectOwnerVoiceIfNeeded() -> String? {
        if let existing = ownerVoiceUuid, !existing.isEmpty { return existing }
        let stats = (try? db.read { try GRDBIdentityInferenceQueries.voiceStats($0) }) ?? []
        guard let detected = OwnerVoiceSelector.selectOwnerVoice(stats) else { return nil }
        settings.setString(detected, forKey: Key.voice)
        logger.info("[OwnerIdentity] Auto-detected owner voice: \(detected)")
        return detected
    }

    // MARK: - Snapshot for the engine

    /// The current owner identity passed to `SpeakerIdentityInferenceEngine.infer`.
    func currentOwner() -> OwnerIdentity {
        OwnerIdentity(
            speakerUuid: settings.getString(forKey: Key.voice),
            name: settings.getString(forKey: Key.name),
            email: settings.getString(forKey: Key.email)
        )
    }
}
