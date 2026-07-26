import Foundation
import Combine

/// Watches the synced calendar while the app runs and fires "Record this meeting?" / "Stop recording?"
/// notifications at the right moments. The decision logic is a pure static function (`decide`) so it's
/// unit-testable; this class only handles the timer, DB query, and notification side-effects.
@MainActor
final class MeetingMonitor: ObservableObject {
    static let shared = MeetingMonitor()

    /// UserDefaults key for the opt-in toggle (shared with the Settings view).
    nonisolated static let offerToRecordKey = "offerToRecordMeetings"

    struct Decision: Equatable {
        var startPrompts: [String] // eventIds to prompt "Record?"
        var stopPrompt: String?    // eventId to prompt "Stop?"
    }

    @Published private(set) var isMonitoring = false

    private var timer: Timer?
    private var promptedStartIds: Set<String> = []
    private var promptedStopIds: Set<String> = []
    private var activeRecording: Meeting?

    private let meetingRepo = GRDBMeetingRepository()
    private let logger = VoxtralLogger.shared

    private init() {}

    // MARK: - Pure decision core (unit-tested)

    nonisolated static func decide(now: Date, qualifyingUpcoming: [Meeting],
                                   promptedStartIds: Set<String>, promptedStopIds: Set<String>,
                                   isRecording: Bool, activeRecording: Meeting?,
                                   leadWindow: TimeInterval = 120) -> Decision {
        var starts: [String] = []
        if !isRecording { // skip new prompts while recording (also handles overlapping meetings)
            for m in qualifyingUpcoming {
                let delta = m.startDate.timeIntervalSince(now)
                if delta > 0, delta <= leadWindow, !promptedStartIds.contains(m.calendarEventId) {
                    starts.append(m.calendarEventId)
                }
            }
        }
        var stop: String?
        if isRecording, let active = activeRecording,
           now >= active.endDate, !promptedStopIds.contains(active.calendarEventId) {
            stop = active.calendarEventId
        }
        return Decision(startPrompts: starts, stopPrompt: stop)
    }

    // MARK: - Lifecycle

    private var isEnabled: Bool { UserDefaults.standard.bool(forKey: Self.offerToRecordKey) }

    func startMonitoring() {
        guard isEnabled, !isMonitoring else { return }
        isMonitoring = true
        logger.info("[MeetingMonitor] started")
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
        isMonitoring = false
    }

    /// Called by the notification RECORD handler so we know which meeting we're recording (for the
    /// end-of-meeting stop prompt).
    func setActiveRecording(eventId: String, meeting: Meeting) {
        activeRecording = meeting
        promptedStopIds.remove(eventId)
    }

    func clearActiveRecording() {
        activeRecording = nil
    }

    // MARK: - Tick

    private func tick() {
        guard isEnabled else { stopMonitoring(); return }
        let now = Date()
        let upcoming = (try? meetingRepo.getUpcomingMeetings(
            startingBetween: now, and: now.addingTimeInterval(120))) ?? []
        let qualifying = upcoming.filter { MeetingQualifier.evaluate($0).qualifies }

        let decision = Self.decide(
            now: now, qualifyingUpcoming: qualifying,
            promptedStartIds: promptedStartIds, promptedStopIds: promptedStopIds,
            isRecording: MeetingRecorder.shared.isRecording, activeRecording: activeRecording)

        for eventId in decision.startPrompts {
            if let meeting = qualifying.first(where: { $0.calendarEventId == eventId }) {
                NotificationManager.shared.sendRecordPrompt(meeting)
                promptedStartIds.insert(eventId)
                logger.info("[MeetingMonitor] prompted record for \(meeting.title)")
            }
        }
        if let stopId = decision.stopPrompt, let active = activeRecording {
            NotificationManager.shared.sendStopPrompt(active)
            promptedStopIds.insert(stopId)
        }

        pruneOldIds(now: now)
    }

    /// Bound memory across long sessions: forget ids for meetings that ended > 6h ago. (Persistent OS
    /// notification identifiers prevent duplicate banners across relaunch regardless.)
    private func pruneOldIds(now: Date) {
        guard !promptedStartIds.isEmpty || !promptedStopIds.isEmpty else { return }
        let recent = (try? meetingRepo.getMeetings(
            from: now.addingTimeInterval(-6 * 3600), to: now.addingTimeInterval(3600))) ?? []
        let liveIds = Set(recent.map { $0.calendarEventId })
        promptedStartIds.formIntersection(liveIds)
        promptedStopIds.formIntersection(liveIds)
    }
}
