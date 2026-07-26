import SwiftUI

struct MeetingDetailView: View {
    let meeting: Meeting
    @State private var matchedRecordings: [Recording] = []
    @State private var suggestedRecordings: [Recording] = []
    @State private var possibleRecordings: [Recording] = []
    @State private var allRecordings: [Recording] = []
    @State private var showLinkPicker = false
    @State private var selectedRecording: Recording?
    @State private var resolution: MeetingResolution = MeetingResolution(matched: [], unmatchedAttendees: [], unmatchedSpeakers: [])
    @State private var speakerProfiles: [String: SpeakerProfile] = [:]
    @State private var agenda: String = ""
    @State private var notes: String = ""
    @Environment(\.dismiss) private var dismiss

    private let meetingRepo = GRDBMeetingRepository()
    private let recordingRepo = GRDBRecordingRepository()
    private let speakerRepo = GRDBSpeakerRepository()
    private let speakerAttendeeRepo = GRDBSpeakerAttendeeRepository()
    private let notesRepo = GRDBMeetingNotesRepository()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            headerSection
                .padding()

            Divider()

            // Linked recordings and speaker-attendee data
            List {
                notesSection

                attendeesSection

                // Speaker-Attendee section
                if !resolution.matched.isEmpty || !resolution.unmatchedAttendees.isEmpty || !resolution.unmatchedSpeakers.isEmpty {
                    speakerAttendeeSection
                }

                // Matched / linked recordings
                if !matchedRecordings.isEmpty {
                    Section("Linked Recordings") {
                        ForEach(matchedRecordings) { recording in
                            linkedRecordingRow(recording)
                        }
                    }
                }

                // Suggested matches
                if !suggestedRecordings.isEmpty {
                    Section("Suggested Matches") {
                        ForEach(suggestedRecordings) { recording in
                            suggestionRow(recording)
                        }
                    }
                }

                // Possible matches
                if !possibleRecordings.isEmpty {
                    Section("Possible Matches") {
                        ForEach(possibleRecordings) { recording in
                            suggestionRow(recording)
                        }
                    }
                }

                // Empty state — only when all three are empty
                if matchedRecordings.isEmpty && suggestedRecordings.isEmpty && possibleRecordings.isEmpty {
                    Section {
                        VStack(spacing: 8) {
                            Text("No recordings linked")
                                .foregroundColor(.secondary)
                            Text("Recordings that overlap with this meeting's time are linked automatically.")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                    }
                }
            }
            .listStyle(.inset)

            Divider()

            // Actions
            HStack {
                Button("Link Recording...") {
                    loadAllRecordings()
                    showLinkPicker = true
                }
                .buttonStyle(.bordered)

                Spacer()

                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
            }
            .padding()
        }
        .frame(minWidth: 500, minHeight: 400)
        .onAppear {
            loadLinkedRecordings()
            loadSpeakerAttendeeData()
            let saved = notesRepo.get(eventId: meeting.calendarEventId)
            agenda = saved.agenda
            notes = saved.notes
        }
        .sheet(isPresented: $showLinkPicker) {
            RecordingLinkPicker(
                recordings: allRecordings,
                linkedIds: Set(matchedRecordings.compactMap(\.id)),
                onLink: { recordingId in
                    guard let meetingId = meeting.id else { return }
                    try? meetingRepo.linkRecording(recordingId: recordingId, meetingId: meetingId, linkType: .manual)
                    loadLinkedRecordings()
                    loadSpeakerAttendeeData()
                },
                onUnlink: { recordingId in
                    guard let meetingId = meeting.id else { return }
                    try? meetingRepo.unlinkRecording(recordingId: recordingId, meetingId: meetingId)
                    loadLinkedRecordings()
                    loadSpeakerAttendeeData()
                }
            )
        }
        .sheet(item: $selectedRecording) { recording in
            RecordingDetailSheet(recording: recording)
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                if let hex = meeting.calendarColor {
                    Circle()
                        .fill(Color(hex: hex))
                        .frame(width: 12, height: 12)
                }
                Text(meeting.title)
                    .font(.title2)
                    .fontWeight(.bold)
            }

            HStack(spacing: 16) {
                Label(meeting.formattedTimeRange, systemImage: "clock")
                    .font(.subheadline)

                Label(meeting.formattedDuration, systemImage: "timer")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            if let calendarName = meeting.calendarName {
                Label(calendarName, systemImage: "calendar")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            if let location = meeting.location, !location.isEmpty {
                Label(location, systemImage: "location")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            if !meeting.parsedAttendees.isEmpty {
                Label("\(meeting.parsedAttendees.count) attendees", systemImage: "person.2")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - Notes & Agenda

    private var notesSection: some View {
        Section("Notes & Agenda") {
            VStack(alignment: .leading, spacing: 8) {
                Text("AGENDA").font(.caption2).foregroundColor(.secondary)
                TextEditor(text: $agenda)
                    .frame(minHeight: 44)
                    .padding(4)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.2)))
                    .onChange(of: agenda) { _ in saveNotes() }

                Text("NOTES").font(.caption2).foregroundColor(.secondary)
                TextEditor(text: $notes)
                    .frame(minHeight: 80)
                    .padding(4)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.2)))
                    .onChange(of: notes) { _ in saveNotes() }

                if let calNotes = meeting.notes, !calNotes.isEmpty {
                    DisclosureGroup("Calendar description") {
                        Text(calNotes)
                            .font(.caption).foregroundColor(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func saveNotes() {
        notesRepo.save(eventId: meeting.calendarEventId, agenda: agenda, notes: notes)
    }

    // MARK: - Attendees (with emails)

    @ViewBuilder private var attendeesSection: some View {
        let participants = meeting.parsedParticipants.filter { !$0.name.isEmpty || $0.email != nil }
        if !participants.isEmpty {
            Section("Attendees (\(participants.count))") {
                ForEach(Array(participants.enumerated()), id: \.offset) { _, p in
                    attendeeRow(p)
                }
            }
        }
    }

    private func attendeeRow(_ p: MeetingAttendee) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "person.circle.fill")
                .font(.title3).foregroundColor(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(p.name.isEmpty ? (p.email ?? "Unknown") : p.name).font(.subheadline)
                if let email = p.email, !email.isEmpty {
                    Text(email).font(.caption).foregroundColor(.secondary)
                }
            }
            Spacer()
            if isAttendeeLinked(p.name) {
                Image(systemName: "waveform.circle.fill")
                    .foregroundColor(.green)
                    .help("Linked to a speaker")
            }
        }
    }

    private func isAttendeeLinked(_ name: String) -> Bool {
        resolution.matched.contains { $0.attendeeName.lowercased() == name.lowercased() }
    }

    // MARK: - Speaker-Attendee Section

    private var speakerAttendeeSection: some View {
        Section("Speakers & Attendees") {
            // Matched pairs
            ForEach(resolution.matched, id: \.speakerUuid) { pair in
                matchedPairRow(attendeeName: pair.attendeeName, speakerUuid: pair.speakerUuid)
            }

            // Unassigned attendees
            ForEach(resolution.unmatchedAttendees, id: \.self) { attendeeName in
                unmatchedAttendeeRow(attendeeName)
            }

            // Unassigned speakers
            ForEach(resolution.unmatchedSpeakers, id: \.self) { speakerUuid in
                unmatchedSpeakerRow(speakerUuid)
            }
        }
    }

    private func matchedPairRow(attendeeName: String, speakerUuid: String) -> some View {
        let profile = speakerProfiles[speakerUuid]
        return HStack(spacing: 8) {
            speakerAvatar(profile: profile, uuid: speakerUuid)

            Text("\(attendeeName) \u{2194} \(profile?.displayName ?? "Speaker \(speakerUuid.prefix(8))")")
                .font(.subheadline)

            Spacer()

            Button("Unlink") {
                try? speakerAttendeeRepo.removeMapping(speakerUuid: speakerUuid, attendeeName: attendeeName)
                loadSpeakerAttendeeData()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private func unmatchedAttendeeRow(_ attendeeName: String) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color.secondary.opacity(0.3))
                .frame(width: 28, height: 28)
                .overlay(
                    Text("?")
                        .font(.caption)
                        .foregroundColor(.secondary)
                )

            Text(attendeeName)
                .font(.subheadline)
                .foregroundColor(.secondary)

            Spacer()

            Menu {
                ForEach(resolution.unmatchedSpeakers, id: \.self) { speakerUuid in
                    let profile = speakerProfiles[speakerUuid]
                    Button(profile?.displayName ?? "Speaker \(speakerUuid.prefix(8))") {
                        let email = meeting.parsedParticipants.first { $0.name == attendeeName }?.email
                        try? speakerAttendeeRepo.setMapping(speakerUuid: speakerUuid, attendeeName: attendeeName, attendeeEmail: email)
                        // If speaker has no name, assign the attendee name
                        if let profile, profile.name == nil || (profile.name?.isEmpty ?? true) {
                            try? speakerRepo.updateName(uuid: speakerUuid, name: attendeeName)
                        }
                        loadSpeakerAttendeeData()
                    }
                }
            } label: {
                Label("Assign Speaker", systemImage: "person.badge.plus")
                    .font(.caption)
            }
            .menuStyle(.borderlessButton)
            .disabled(resolution.unmatchedSpeakers.isEmpty)
        }
    }

    private func unmatchedSpeakerRow(_ speakerUuid: String) -> some View {
        let profile = speakerProfiles[speakerUuid]
        return HStack(spacing: 8) {
            speakerAvatar(profile: profile, uuid: speakerUuid)

            Text(profile?.displayName ?? "Speaker \(speakerUuid.prefix(8))")
                .font(.subheadline)
                .foregroundColor(.secondary)

            Spacer()
        }
    }

    private func speakerAvatar(profile: SpeakerProfile?, uuid: String) -> some View {
        let color = profile?.avatarColor ?? Color.gray
        let initials = profile?.initials ?? String(uuid.prefix(2)).uppercased()
        return Circle()
            .fill(color)
            .frame(width: 28, height: 28)
            .overlay(
                Text(initials)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white)
            )
    }

    // MARK: - Recording Rows

    private func linkedRecordingRow(_ recording: Recording) -> some View {
        HStack {
            Image(systemName: "play.circle.fill")
                .font(.title3)
                .foregroundColor(.accentColor)

            VStack(alignment: .leading, spacing: 4) {
                Text(recording.title)
                    .font(.body)
                Text(recording.formattedDate)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Text(recording.formattedDuration)
                .font(.caption)
                .foregroundColor(.secondary)

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            selectedRecording = recording
        }
    }

    private func suggestionRow(_ recording: Recording) -> some View {
        HStack {
            Image(systemName: "play.circle")
                .font(.title3)
                .foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                Text(recording.title)
                    .font(.body)
                Text(recording.formattedDate)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                selectedRecording = recording
            }

            Spacer()

            Text(recording.formattedDuration)
                .font(.caption)
                .foregroundColor(.secondary)

            Button("Confirm") {
                guard let meetingId = meeting.id, let recordingId = recording.id else { return }
                try? meetingRepo.confirmMatch(recordingId: recordingId, meetingId: meetingId)
                loadLinkedRecordings()
                loadSpeakerAttendeeData()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button("Dismiss") {
                guard let meetingId = meeting.id, let recordingId = recording.id else { return }
                try? meetingRepo.dismissMatch(recordingId: recordingId, meetingId: meetingId)
                loadLinkedRecordings()
                loadSpeakerAttendeeData()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(.red)
        }
    }

    // MARK: - Data Loading

    private func loadLinkedRecordings() {
        guard let meetingId = meeting.id else { return }
        let results = (try? meetingRepo.getRecordingsForMeetingWithConfidence(meetingId: meetingId)) ?? []

        matchedRecordings = results.filter { $0.confidence == .matched }.map(\.recording)
        suggestedRecordings = results.filter { $0.confidence == .suggested }.map(\.recording)
        possibleRecordings = results.filter { $0.confidence == .possible }.map(\.recording)
    }

    private func loadSpeakerAttendeeData() {
        // Collect all speaker UUIDs from matched recordings
        var allSpeakers: [(speaker: Speaker, duration: TimeInterval)] = []
        for recording in matchedRecordings {
            guard let recordingId = recording.id else { continue }
            if let speakers = try? speakerRepo.getSpeakersForRecording(recordingId: recordingId) {
                allSpeakers.append(contentsOf: speakers)
            }
        }

        // Deduplicate speakers by UUID
        var seen = Set<String>()
        var uniqueSpeakers: [Speaker] = []
        for entry in allSpeakers {
            if seen.insert(entry.speaker.uuid).inserted {
                uniqueSpeakers.append(entry.speaker)
            }
        }

        // Build profiles dict
        var profiles: [String: SpeakerProfile] = [:]
        for speaker in uniqueSpeakers {
            let profile = speaker.toProfile()
            profiles[profile.uuid] = profile
        }
        speakerProfiles = profiles

        // Resolve attendee-speaker mappings
        let attendeeNames = meeting.parsedAttendees
        let speakerUuids = uniqueSpeakers.map(\.uuid)
        resolution = speakerAttendeeRepo.resolveForMeeting(attendeeNames: attendeeNames, speakerUuids: speakerUuids)
    }

    private func loadAllRecordings() {
        allRecordings = (try? recordingRepo.getAll(limit: 500)) ?? []
    }
}

// MARK: - Recording Link Picker

struct RecordingLinkPicker: View {
    let recordings: [Recording]
    let linkedIds: Set<Int64>
    let onLink: (Int64) -> Void
    let onUnlink: (Int64) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""

    private var filteredRecordings: [Recording] {
        if searchText.isEmpty { return recordings }
        return recordings.filter { $0.title.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Link Recordings")
                    .font(.headline)
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
            }
            .padding()

            TextField("Search recordings...", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal)

            List(filteredRecordings) { recording in
                HStack {
                    VStack(alignment: .leading) {
                        Text(recording.title)
                            .font(.body)
                        Text(recording.formattedDate)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    if let id = recording.id {
                        if linkedIds.contains(id) {
                            Button("Unlink") { onUnlink(id) }
                                .buttonStyle(.bordered)
                                .tint(.red)
                        } else {
                            Button("Link") { onLink(id) }
                                .buttonStyle(.bordered)
                        }
                    }
                }
            }
            .listStyle(.inset)
        }
        .frame(minWidth: 450, minHeight: 350)
    }
}
