import SwiftUI
import AVFoundation

struct EnhancedSpeakerDetailView: View {
    let speaker: SpeakerProfile
    let viewModel: SpeakerManagementViewModel
    @State private var utterances: [(utterance: UtteranceDetail, recording: RecordingDetail)] = []
    @State private var groupedUtterances: [RecordingDetail: [UtteranceDetail]] = [:]
    @State private var expandedRecordings: Set<Int> = []
    @State private var isLoadingUtterances = false
    @State private var selectedTab = "utterances"
    @State private var playingUtteranceId: Int?
    @State private var searchText = ""
    @State private var linkedEmail: String?

    var body: some View {
        VStack(spacing: 0) {
            speakerHeader

            Picker("View", selection: $selectedTab) {
                Text("Utterances").tag("utterances")
                Text("Statistics").tag("statistics")
                Text("Timeline").tag("timeline")
            }
            .pickerStyle(.segmented)
            .padding()

            switch selectedTab {
            case "utterances":
                utterancesView
            case "statistics":
                statisticsView
            case "timeline":
                timelineView
            default:
                EmptyView()
            }
        }
        .onAppear {
            loadUtterances()
            linkedEmail = GRDBSpeakerAttendeeRepository().getAttendeeForSpeaker(uuid: speaker.uuid)?.attendeeEmail
        }
    }

    // MARK: - Header

    private var speakerHeader: some View {
        HStack(spacing: 16) {
            Circle()
                .fill(speaker.avatarColor)
                .frame(width: 60, height: 60)
                .overlay(
                    Text(speaker.initials)
                        .font(.title2)
                        .foregroundColor(.white)
                        .fontWeight(.semibold)
                )

            VStack(alignment: .leading, spacing: 8) {
                Text(speaker.displayName)
                    .font(.title3)
                    .fontWeight(.bold)

                if let email = linkedEmail, !email.isEmpty {
                    Label(email, systemImage: "envelope")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                HStack(spacing: 20) {
                    Label("\(speaker.utteranceCount) utterances", systemImage: "text.bubble")
                    Label(formatDuration(speaker.totalDuration), systemImage: "clock")
                    Label("Confidence: \(Int(speaker.confidence * 100))%", systemImage: "checkmark.shield")
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }

            Spacer()
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
    }

    // MARK: - Utterances View

    private var utterancesView: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("Search utterances...", text: $searchText)
                    .textFieldStyle(.plain)
            }
            .padding(8)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(8)
            .padding(.horizontal)
            .padding(.top, 8)

            if isLoadingUtterances {
                ProgressView("Loading utterances...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if groupedUtterances.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "text.bubble.rtl")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                    Text("No utterances found")
                        .font(.title3)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 12) {
                        ForEach(sortedRecordings, id: \.self) { recording in
                            RecordingSection(
                                recording: recording,
                                utterances: filteredUtterances(for: recording),
                                isExpanded: expandedRecordings.contains(recording.id),
                                playingUtteranceId: $playingUtteranceId,
                                speakerResolver: SpeakerNameResolver(profiles: [speaker]),
                                onToggleExpand: {
                                    toggleExpanded(recording.id)
                                }
                            )
                        }
                    }
                    .padding()
                }
            }
        }
    }

    // MARK: - Statistics View

    private var statisticsView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                GroupBox("Overall Statistics") {
                    VStack(spacing: 12) {
                        StatRow(label: "Total Speaking Time", value: formatDuration(speaker.totalDuration))
                        StatRow(label: "Number of Utterances", value: "\(speaker.utteranceCount)")
                        StatRow(label: "Average Utterance Length", value: formatDuration(averageUtteranceLength))
                        StatRow(label: "Number of Recordings", value: "\(groupedUtterances.count)")
                        StatRow(label: "First Appearance", value: speaker.firstSeen.formatted())
                        StatRow(label: "Last Appearance", value: speaker.lastSeen.formatted())
                    }
                    .padding(.vertical, 8)
                }

                GroupBox("Per Recording Statistics") {
                    VStack(spacing: 8) {
                        ForEach(sortedRecordings, id: \.self) { recording in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(recording.title)
                                        .fontWeight(.medium)
                                    Text(recording.createdAt, style: .date)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }

                                Spacer()

                                HStack(spacing: 16) {
                                    Text("\(groupedUtterances[recording]?.count ?? 0) utterances")
                                        .font(.caption)
                                    Text(formatDuration(totalDuration(for: recording)))
                                        .font(.caption)
                                        .monospacedDigit()
                                }
                                .foregroundColor(.secondary)
                            }
                            .padding(.vertical, 4)

                            if recording != sortedRecordings.last {
                                Divider()
                            }
                        }
                    }
                    .padding(.vertical, 8)
                }
            }
            .padding()
        }
    }

    // MARK: - Timeline View

    private var timelineView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Speaker Activity Timeline")
                    .font(.headline)
                    .padding(.horizontal)
                    .padding(.top)

                ForEach(sortedRecordings, id: \.self) { recording in
                    TimelineEntry(
                        recording: recording,
                        utterances: groupedUtterances[recording] ?? []
                    )
                }
            }
            .padding(.bottom)
        }
    }

    // MARK: - Helper Methods

    private func loadUtterances() {
        isLoadingUtterances = true

        Task {
            do {
                let results = try await viewModel.getAllUtterancesForSpeaker(speaker.uuid)

                self.utterances = results

                var grouped: [RecordingDetail: [UtteranceDetail]] = [:]
                for (utterance, recording) in results {
                    grouped[recording, default: []].append(utterance)
                }
                self.groupedUtterances = grouped

                if let firstRecording = sortedRecordings.first {
                    expandedRecordings.insert(firstRecording.id)
                }

                isLoadingUtterances = false
            } catch {
                VoxtralLogger.shared.error("[SpeakerDetail] Failed to load utterances: \(error)")
                isLoadingUtterances = false
            }
        }
    }

    private func toggleExpanded(_ recordingId: Int) {
        if expandedRecordings.contains(recordingId) {
            expandedRecordings.remove(recordingId)
        } else {
            expandedRecordings.insert(recordingId)
        }
    }

    private var sortedRecordings: [RecordingDetail] {
        groupedUtterances.keys.sorted { $0.createdAt > $1.createdAt }
    }

    private func filteredUtterances(for recording: RecordingDetail) -> [UtteranceDetail] {
        guard let utterances = groupedUtterances[recording] else { return [] }
        if searchText.isEmpty { return utterances }
        return utterances.filter { $0.text.localizedCaseInsensitiveContains(searchText) }
    }

    private var averageUtteranceLength: TimeInterval {
        guard speaker.utteranceCount > 0 else { return 0 }
        return speaker.totalDuration / Double(speaker.utteranceCount)
    }

    private func totalDuration(for recording: RecordingDetail) -> TimeInterval {
        (groupedUtterances[recording] ?? []).reduce(0) { $0 + $1.duration }
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute, .second] : [.minute, .second]
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: seconds) ?? "0s"
    }
}

// MARK: - Recording Section

struct RecordingSection: View {
    let recording: RecordingDetail
    let utterances: [UtteranceDetail]
    let isExpanded: Bool
    @Binding var playingUtteranceId: Int?
    let speakerResolver: SpeakerNameResolver
    let onToggleExpand: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            recordingHeader

            if isExpanded {
                utterancesList
            }
        }
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
        )
    }

    private var recordingHeader: some View {
        Button(action: onToggleExpand) {
            HStack {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .foregroundColor(.secondary)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 2) {
                    Text(recording.title)
                        .fontWeight(.semibold)
                    Text(recording.createdAt, style: .date)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Text("\(utterances.count) utterances")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(Color(NSColor.controlBackgroundColor))
    }

    private var utterancesList: some View {
        VStack(spacing: 0) {
            ForEach(utterances) { utterance in
                UtteranceRowView(
                    utterance: utterance,
                    audioPath: recording.audioPath,
                    isPlaying: playingUtteranceId == utterance.id,
                    speakerResolver: speakerResolver,
                    onPlayToggle: {
                        if playingUtteranceId == utterance.id {
                            playingUtteranceId = nil
                        } else {
                            playingUtteranceId = utterance.id
                        }
                    }
                )

                if utterance != utterances.last {
                    Divider()
                        .padding(.leading, 48)
                }
            }
        }
        .background(Color(NSColor.textBackgroundColor))
    }
}

// MARK: - Utterance Row

struct UtteranceRowView: View {
    let utterance: UtteranceDetail
    let audioPath: String
    let isPlaying: Bool
    let speakerResolver: SpeakerNameResolver
    let onPlayToggle: () -> Void

    var body: some View {
        TranscriptSegmentView(
            utterance: Utterance(
                id: Int64(utterance.id),
                recordingId: 0,
                utteranceIndex: 0,
                startTime: utterance.startTime,
                endTime: utterance.endTime,
                speaker: nil,   // no local label here — resolve identity from the global uuid
                speakerUuid: utterance.speakerUUID,
                text: utterance.text,
                confidence: nil,
                hasEmbedding: false
            ),
            displayMode: .row,
            audioPath: audioPath,
            currentSpeaker: nil,
            speakerResolver: speakerResolver
        )
    }
}

// MARK: - Statistics Row

struct StatRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .fontWeight(.medium)
        }
    }
}

// MARK: - Timeline Entry

struct TimelineEntry: View {
    let recording: RecordingDetail
    let utterances: [UtteranceDetail]

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 0) {
                Circle()
                    .fill(Color.blue)
                    .frame(width: 12, height: 12)
                if utterances.count > 1 {
                    Rectangle()
                        .fill(Color.blue.opacity(0.3))
                        .frame(width: 2)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(recording.title)
                    .fontWeight(.semibold)
                Text(recording.createdAt, style: .date)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("\(utterances.count) utterances \u{2022} \(formatTotalDuration(utterances))")
                    .font(.caption)
                    .foregroundColor(.secondary)

                if !utterances.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(utterances.prefix(3)) { utterance in
                            Text("\u{2022} \(utterance.text)")
                                .lineLimit(1)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        if utterances.count > 3 {
                            Text("\u{2022} ... and \(utterances.count - 3) more")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .italic()
                        }
                    }
                    .padding(8)
                    .background(Color(NSColor.controlBackgroundColor))
                    .cornerRadius(6)
                }
            }

            Spacer()
        }
        .padding(.horizontal)
    }

    private func formatTotalDuration(_ utterances: [UtteranceDetail]) -> String {
        let total = utterances.reduce(0) { $0 + $1.duration }
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = total >= 60 ? [.minute, .second] : [.second]
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: total) ?? "0s"
    }
}
