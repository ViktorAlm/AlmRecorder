import Foundation
import EventKit

/// Service for accessing Apple Calendar via EventKit and syncing to local database
@MainActor
class CalendarService: ObservableObject {
    static let shared = CalendarService()

    private let eventStore = EKEventStore()
    private let meetingRepo = GRDBMeetingRepository()
    private let logger = VoxtralLogger.shared
    private var syncTimer: Timer?

    @Published var authorizationStatus: EKAuthorizationStatus = .notDetermined
    @Published var isSyncing = false
    @Published var lastSyncDate: Date?

    private init() {
        updateAuthorizationStatus()
    }

    // MARK: - Authorization

    func updateAuthorizationStatus() {
        authorizationStatus = EKEventStore.authorizationStatus(for: .event)
    }

    func requestAccess() async -> Bool {
        do {
            let granted: Bool
            if #available(macOS 14.0, *) {
                granted = try await eventStore.requestFullAccessToEvents()
            } else {
                granted = try await eventStore.requestAccess(to: .event)
            }
            updateAuthorizationStatus()
            if granted {
                await syncEvents()
            }
            return granted
        } catch {
            logger.error("[CalendarService] Failed to request access: \(error)")
            updateAuthorizationStatus()
            return false
        }
    }

    var hasAccess: Bool {
        let status = EKEventStore.authorizationStatus(for: .event)
        if #available(macOS 14.0, *) {
            return status == .fullAccess
        } else {
            return status == .authorized
        }
    }

    // MARK: - Sync

    /// Sync calendar events covering the full recording date range + next 7 days.
    /// Looks at the oldest recording to determine how far back to fetch.
    func syncEvents() async {
        guard hasAccess else {
            logger.warning("[CalendarService] No calendar access, skipping sync")
            return
        }

        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }

        let calendar = Calendar.current
        let now = Date()

        // Go back far enough to cover all recordings (minimum 30 days)
        let recordingRepo = GRDBRecordingRepository()
        let oldestRecording = try? recordingRepo.getAll(limit: 10000).last
        let oldestDate = oldestRecording?.createdAt ?? now
        let thirtyDaysAgo = calendar.date(byAdding: .day, value: -30, to: now)!
        let startDate = min(oldestDate, thirtyDaysAgo)
        let endDate = calendar.date(byAdding: .day, value: 7, to: now)!

        logger.info("[CalendarService] Syncing events from \(startDate) to \(endDate)")

        let predicate = eventStore.predicateForEvents(withStart: startDate, end: endDate, calendars: nil)
        let events = eventStore.events(matching: predicate).filter { !$0.isAllDay }

        logger.info("[CalendarService] Found \(events.count) calendar events")

        var syncedEventIds = Set<String>()
        // The calendar owner ("you"), captured from the current-user participant — near-certain identity
        // that anchors speaker-identity inference. First non-empty match across events wins.
        var ownerName: String?
        var ownerEmail: String?

        for event in events {
            // Capture name + email (from the participant's mailto: URL) so attendees can be matched
            // to speakers/people by a stable identity. Stored as JSON [{name,email}] (the parser is
            // backward-compatible with old name-only rows). Every invitee counts regardless of RSVP
            // status — people (the owner especially) rarely "accept" meetings they attend anyway —
            // and the organizer is merged in because EventKit doesn't always list them in attendees.
            var attendees: [MeetingAttendee] = event.attendees?.compactMap { participant in
                let name = participant.name ?? ""
                let email = MeetingAttendee.email(from: participant.url)
                guard !name.isEmpty || email != nil else { return nil }
                return MeetingAttendee(name: name, email: email)
            } ?? []
            attendees = MeetingAttendee.mergingOrganizer(
                into: attendees,
                organizerName: event.organizer?.name,
                organizerEmail: MeetingAttendee.email(from: event.organizer?.url))
            let attendeesJSON: String? = attendees.isEmpty ? nil : {
                guard let data = try? JSONEncoder().encode(attendees) else { return nil }
                return String(data: data, encoding: .utf8)
            }()

            // Detect "you" on this event: the current-user attendee, else the organizer if that's you.
            if ownerName == nil, ownerEmail == nil,
               let me = event.attendees?.first(where: { $0.isCurrentUser })
                        ?? (event.organizer?.isCurrentUser == true ? event.organizer : nil) {
                ownerName = me.name
                ownerEmail = MeetingAttendee.email(from: me.url)
            }

            let colorHex: String? = event.calendar.cgColor.flatMap { cgColor in
                let components = cgColor.components ?? []
                guard components.count >= 3 else { return nil }
                let r = Int(components[0] * 255)
                let g = Int(components[1] * 255)
                let b = Int(components[2] * 255)
                return String(format: "#%02X%02X%02X", r, g, b)
            }

            let meeting = Meeting(
                id: nil,
                calendarEventId: event.eventIdentifier,
                title: event.title ?? "Untitled",
                startDate: event.startDate,
                endDate: event.endDate,
                calendarName: event.calendar.title,
                calendarColor: colorHex,
                location: event.location,
                notes: event.notes,
                attendees: attendeesJSON,
                isRecurring: event.hasRecurrenceRules,
                lastSyncedAt: now
            )

            do {
                try meetingRepo.upsert(meeting)
                syncedEventIds.insert(event.eventIdentifier)
            } catch {
                logger.error("[CalendarService] Failed to upsert meeting '\(event.title ?? "?")': \(error)")
            }
        }

        // Persist the calendar owner once per sync (idempotent; ignores empties).
        if ownerName != nil || ownerEmail != nil {
            OwnerIdentityService.shared.setCalendarIdentity(name: ownerName, email: ownerEmail)
        }

        // Remove stale events that are no longer in the calendar
        do {
            try meetingRepo.deleteStaleEvents(keepingEventIds: syncedEventIds)
        } catch {
            logger.error("[CalendarService] Failed to clean stale events: \(error)")
        }

        // Auto-link all existing recordings to the freshly synced meetings
        autoLinkAllRecordings()

        // Fresh meetings/attendees/links → re-run speaker-identity inference in the background.
        IdentityInferenceCoordinator.shared.scheduleRecompute()

        lastSyncDate = now
        logger.info("[CalendarService] Sync complete: \(syncedEventIds.count) events synced")
    }

    /// Run tiered matching for every existing recording against all meetings.
    /// Uses INSERT OR IGNORE so already-linked pairs are skipped cheaply.
    private func autoLinkAllRecordings() {
        let recordingRepo = GRDBRecordingRepository()
        do {
            let recordings = try recordingRepo.getAll(limit: 10000)
            for recording in recordings {
                try meetingRepo.autoLinkRecording(recording)
            }
            logger.info("[CalendarService] Auto-link backfill complete: checked \(recordings.count) recordings")
        } catch {
            logger.error("[CalendarService] Failed to backfill recording-meeting links: \(error)")
        }
    }

    /// Auto-link a recording to any overlapping meetings
    func autoLinkRecording(_ recording: Recording) {
        guard hasAccess else { return }
        do {
            try meetingRepo.autoLinkRecording(recording)
        } catch {
            logger.error("[CalendarService] Failed to auto-link recording: \(error)")
        }
    }

    // MARK: - Periodic Sync

    func startPeriodicSync() {
        stopPeriodicSync()
        syncTimer = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.syncEvents()
            }
        }
    }

    func stopPeriodicSync() {
        syncTimer?.invalidate()
        syncTimer = nil
    }
}
