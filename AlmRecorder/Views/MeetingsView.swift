import SwiftUI

struct MeetingsView: View {
    @StateObject private var viewModel = MeetingsViewModel()
    @StateObject private var calendarService = CalendarService.shared
    @State private var selectedMeeting: Meeting?
    @State private var selectedRecording: Recording?

    var body: some View {
        Group {
            if !calendarService.hasAccess {
                calendarAccessPrompt
            } else if viewModel.isLoading && viewModel.recordingsWithMeetings.isEmpty {
                ProgressView("Matching recordings to meetings...")
            } else if viewModel.recordingsWithMeetings.isEmpty {
                emptyState
            } else {
                recordingsList
            }
        }
        .onAppear {
            if calendarService.hasAccess {
                viewModel.loadData()
            }
        }
        .sheet(item: $selectedMeeting) { meeting in
            MeetingDetailView(meeting: meeting)
        }
        .sheet(item: $selectedRecording) { recording in
            RecordingDetailSheet(recording: recording)
        }
    }

    // MARK: - Calendar Access Prompt

    private var calendarAccessPrompt: some View {
        VStack {
            VStack(spacing: 18) {
                Image(systemName: "calendar.badge.exclamationmark")
                    .font(.system(size: 54))
                    .foregroundStyle(.orange)

                Text("Connect your calendar")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text("Match recordings to the meetings they came from. Calendar access is optional and does not affect recording or transcription.")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                if calendarService.authorizationStatus == .denied {
                    Text("Access was previously denied. Enable AlmRecorder in System Settings → Privacy & Security → Calendars.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)

                    Button {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
                            NSWorkspace.shared.open(url)
                        }
                    } label: {
                        Label("Open Calendar Privacy Settings", systemImage: "gear")
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button {
                        Task {
                            let granted = await calendarService.requestAccess()
                            if granted {
                                viewModel.loadData()
                            }
                        }
                    } label: {
                        Label("Allow Calendar Access", systemImage: "calendar.badge.plus")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(32)
            .frame(maxWidth: 460)
            .cardSurfaceProminent(strokeColor: Color.secondary.opacity(0.14))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack {
            VStack(spacing: 16) {
                Image(systemName: "calendar.badge.clock")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)

                Text("No matched meetings yet")
                    .font(.title3)
                    .fontWeight(.medium)

                Text("Record during a calendar event, then sync to connect the recording with its meeting title and attendees.")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    Task { await viewModel.refresh() }
                } label: {
                    Label("Sync Calendar", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
            }
            .padding(32)
            .frame(maxWidth: 440)
            .cardSurfaceProminent(strokeColor: Color.secondary.opacity(0.14))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    // MARK: - Recordings List (recording-first)

    private var recordingsList: some View {
        List {
            ForEach(viewModel.recordingsWithMeetings, id: \.recording.id) { item in
                RecordingMeetingRow(
                    item: item,
                    onSelectRecording: { recording in
                        selectedRecording = recording
                    },
                    onSelectMeeting: { meeting in
                        selectedMeeting = meeting
                    },
                    onConfirm: { recordingId, meetingId in
                        try? GRDBMeetingRepository().confirmMatch(recordingId: recordingId, meetingId: meetingId)
                        viewModel.loadData()
                    },
                    onDismiss: { recordingId, meetingId in
                        try? GRDBMeetingRepository().dismissMatch(recordingId: recordingId, meetingId: meetingId)
                        viewModel.loadData()
                    }
                )
            }
        }
        .listStyle(.inset)
        .refreshable {
            await viewModel.refresh()
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button(action: { Task { await viewModel.refresh() } }) {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Sync calendar events")
                .disabled(calendarService.isSyncing)
            }
        }
    }
}

// MARK: - Recording-Meeting Row

struct RecordingMeetingRow: View {
    let item: RecordingWithMeetings
    let onSelectRecording: (Recording) -> Void
    let onSelectMeeting: (Meeting) -> Void
    let onConfirm: (Int64, Int64) -> Void
    let onDismiss: (Int64, Int64) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Recording header
            HStack(spacing: 10) {
                Image(systemName: "play.circle.fill")
                    .font(.title3)
                    .foregroundColor(.accentColor)

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.recording.title)
                        .font(.body)
                        .fontWeight(.medium)
                        .lineLimit(1)

                    HStack(spacing: 8) {
                        Text(item.recording.formattedDate)
                            .font(.caption)
                            .foregroundColor(.secondary)

                        Text(item.recording.formattedDuration)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                onSelectRecording(item.recording)
            }

            // Matched meetings
            ForEach(item.matchedMeetings, id: \.id) { meeting in
                meetingChip(meeting, confidence: .matched)
            }

            // Suggested meetings
            ForEach(item.suggestedMeetings, id: \.id) { meeting in
                meetingChip(meeting, confidence: .suggested)
            }

            // Possible meetings
            ForEach(item.possibleMeetings, id: \.id) { meeting in
                meetingChip(meeting, confidence: .possible)
            }
        }
        .padding(.vertical, 4)
    }

    private func meetingChip(_ meeting: Meeting, confidence: RecordingMeeting.MatchConfidence) -> some View {
        HStack(spacing: 8) {
            // Calendar color dot
            if let hex = meeting.calendarColor {
                Circle()
                    .fill(Color(hex: hex))
                    .frame(width: 8, height: 8)
            }

            Image(systemName: "calendar")
                .font(.caption2)
                .foregroundColor(confidenceColor(confidence))

            Text(meeting.title)
                .font(.caption)
                .lineLimit(1)

            Text(meeting.formattedTimeRange)
                .font(.caption2)
                .foregroundColor(.secondary)

            Spacer()

            // Confidence badge
            Text(confidenceLabel(confidence))
                .font(.caption2)
                .fontWeight(.medium)
                .foregroundColor(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(confidenceColor(confidence))
                .clipShape(Capsule())

            if confidence != .matched {
                // Confirm / dismiss for suggestions
                if let recordingId = item.recording.id, let meetingId = meeting.id {
                    Button {
                        onConfirm(recordingId, meetingId)
                    } label: {
                        Image(systemName: "checkmark")
                            .font(.caption2)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)

                    Button {
                        onDismiss(recordingId, meetingId)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption2)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .tint(.red)
                }
            } else {
                // Tap to view meeting detail
                Button {
                    onSelectMeeting(meeting)
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.leading, 24)
        .contentShape(Rectangle())
        .onTapGesture {
            onSelectMeeting(meeting)
        }
    }

    private func confidenceColor(_ confidence: RecordingMeeting.MatchConfidence) -> Color {
        switch confidence {
        case .matched: return .blue
        case .suggested: return .orange
        case .possible: return .secondary
        }
    }

    private func confidenceLabel(_ confidence: RecordingMeeting.MatchConfidence) -> String {
        switch confidence {
        case .matched: return "Linked"
        case .suggested: return "Likely"
        case .possible: return "Maybe"
        }
    }
}
