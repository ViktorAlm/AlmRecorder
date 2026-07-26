import SwiftUI

struct SpeakerManagementView: View {
    @StateObject private var viewModel = SpeakerManagementViewModel()
    @State private var searchText = ""
    @State private var selectedSpeakers: Set<String> = []
    @State private var showMergeConfirmation = false
    @State private var showUnmergeSheet = false
    @State private var speakerToUnmerge: SpeakerProfile?
    @State private var speakerPendingDeletion: SpeakerProfile?
    @State private var editingSpeaker: SpeakerProfile?
    @State private var showReviewWizard = false
    @State private var filterMode: FilterMode = .all

    enum FilterMode: String, CaseIterable {
        case all = "All"
        case unnamed = "Unnamed"
        case named = "Named"
    }

    var body: some View {
        VStack(spacing: 0) {
            headerView

            // Error banner
            if let error = viewModel.error {
                errorBanner(error)
            }

            toolbar
            speakerList
        }
        .task {
            await viewModel.loadSpeakers()
        }
        .sheet(item: $editingSpeaker) { speaker in
            SpeakerEditSheet(
                speaker: speaker,
                viewModel: viewModel,
                onSave: { updatedSpeaker in
                    Task { await viewModel.updateSpeaker(updatedSpeaker) }
                    editingSpeaker = nil
                },
                onCancel: {
                    editingSpeaker = nil
                }
            )
        }
        .alert("Merge Speakers", isPresented: $showMergeConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Merge", role: .destructive) {
                mergeSpeakers()
            }
        } message: {
            Text("Are you sure you want to merge \(selectedSpeakers.count) speakers? You can unmerge them later if needed.")
        }
        .sheet(isPresented: $showUnmergeSheet) {
            if let speaker = speakerToUnmerge {
                SpeakerUnmergeSheet(
                    speaker: speaker,
                    viewModel: viewModel,
                    isPresented: $showUnmergeSheet
                )
            }
        }
        .sheet(isPresented: $showReviewWizard) {
            if let speakers = viewModel.reviewWizardSpeakers {
                SpeakerReviewWizard(
                    isPresented: $showReviewWizard,
                    speakers: speakers,
                    onComplete: { _ in
                        showReviewWizard = false
                        viewModel.reviewWizardSpeakers = nil
                        Task { await viewModel.loadSpeakers() }
                    }
                )
            }
        }
        .alert(
            "Delete speaker?",
            isPresented: Binding(
                get: { speakerPendingDeletion != nil },
                set: { if !$0 { speakerPendingDeletion = nil } }
            )
        ) {
            Button("Cancel", role: .cancel) { speakerPendingDeletion = nil }
            Button("Delete", role: .destructive) {
                guard let speaker = speakerPendingDeletion else { return }
                speakerPendingDeletion = nil
                Task { await viewModel.deleteSpeaker(uuid: speaker.uuid) }
            }
        } message: {
            Text("This removes \(speakerPendingDeletion?.displayName ?? "this speaker") from People. This cannot be undone.")
        }
    }

    // MARK: - Header

    private var headerView: some View {
        HStack {
            Text("Speaker Management")
                .font(.title2)
                .fontWeight(.bold)

            Spacer()

            if !viewModel.unnamedSpeakers.isEmpty {
                Button(action: {
                    viewModel.launchReviewWizard(for: viewModel.unnamedSpeakers)
                    showReviewWizard = true
                }) {
                    Label("Review Unnamed (\(viewModel.unnamedSpeakers.count))", systemImage: "person.badge.clock")
                }
                .buttonStyle(.borderedProminent)
            }

            Button(action: { Task { await viewModel.loadSpeakers() } }) {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
    }

    // MARK: - Error Banner

    private func errorBanner(_ message: String) -> some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
            Text(message)
                .font(.caption)
            Spacer()
            Button("Dismiss") { viewModel.error = nil }
                .font(.caption)
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.1))
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 12) {
            // Search
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("Search speakers...", text: $searchText)
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button(action: { searchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(6)

            // Filter picker
            Picker("Filter", selection: $filterMode) {
                ForEach(FilterMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 200)

            // Merge button
            if selectedSpeakers.count > 1 {
                Button(action: { showMergeConfirmation = true }) {
                    Label("Merge (\(selectedSpeakers.count))", systemImage: "arrow.triangle.merge")
                }
                .buttonStyle(.borderedProminent)
            }

            // Review selected
            if !selectedSpeakers.isEmpty {
                Button(action: {
                    let selected = viewModel.speakers.filter { selectedSpeakers.contains($0.uuid) }
                    viewModel.launchReviewWizard(for: selected)
                    showReviewWizard = true
                }) {
                    Label("Review Selected", systemImage: "person.badge.clock")
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    // MARK: - Speaker List

    private var speakerList: some View {
        Group {
            if viewModel.isLoading {
                ProgressView("Loading speakers...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredSpeakers.isEmpty {
                emptyStateView
            } else {
                List(selection: $selectedSpeakers) {
                    ForEach(filteredSpeakers) { speaker in
                        SpeakerRow(
                            speaker: speaker,
                            isSelected: selectedSpeakers.contains(speaker.uuid),
                            canUnmerge: viewModel.canUnmergeSpeaker(speaker.uuid),
                            onEdit: { editingSpeaker = speaker },
                            onToggleSelection: {
                                if selectedSpeakers.contains(speaker.uuid) {
                                    selectedSpeakers.remove(speaker.uuid)
                                } else {
                                    selectedSpeakers.insert(speaker.uuid)
                                }
                            },
                            onUnmerge: {
                                speakerToUnmerge = speaker
                                showUnmergeSheet = true
                            },
                            onDelete: {
                                speakerPendingDeletion = speaker
                            }
                        )
                        .tag(speaker.uuid)
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    private var emptyStateView: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.2.slash")
                .font(.system(size: 48))
                .foregroundColor(.secondary)

            Text("No Speakers Found")
                .font(.title3)
                .fontWeight(.semibold)

            Text("Speakers will appear here after transcribing recordings with speaker diarization enabled.")
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Filtering

    private var filteredSpeakers: [SpeakerProfile] {
        var result = viewModel.speakers

        switch filterMode {
        case .unnamed:
            result = result.filter { $0.name == nil }
        case .named:
            result = result.filter { $0.name != nil }
        case .all:
            break
        }

        if !searchText.isEmpty {
            let lowercased = searchText.lowercased()
            result = result.filter {
                $0.displayName.lowercased().contains(lowercased) ||
                $0.uuid.lowercased().contains(lowercased)
            }
        }

        return result
    }

    private func mergeSpeakers() {
        let speakerUUIDs = Array(selectedSpeakers)
        Task { await viewModel.mergeSpeakers(uuids: speakerUUIDs) }
        selectedSpeakers.removeAll()
    }
}

// MARK: - Speaker Row View

struct SpeakerRow: View {
    let speaker: SpeakerProfile
    let isSelected: Bool
    let canUnmerge: Bool
    let onEdit: () -> Void
    let onToggleSelection: () -> Void
    let onUnmerge: () -> Void
    var onDelete: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 12) {
            // Selection checkbox
            Button(action: onToggleSelection) {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .foregroundColor(isSelected ? .accentColor : .secondary)
            }
            .buttonStyle(.plain)

            // Speaker avatar
            Circle()
                .fill(speaker.avatarColor)
                .frame(width: 40, height: 40)
                .overlay(
                    Text(speaker.initials)
                        .foregroundColor(.white)
                        .fontWeight(.semibold)
                )

            // Speaker info
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(speaker.displayName)
                        .fontWeight(.semibold)

                    if speaker.name == nil {
                        Text("(Unnamed)")
                            .foregroundColor(.orange)
                            .font(.caption)
                            .italic()
                    }
                }

                HStack(spacing: 12) {
                    Label("\(speaker.utteranceCount) utterances", systemImage: "text.bubble")
                    Label(formatDuration(speaker.totalDuration), systemImage: "clock")
                    Label("Last: \(speaker.lastSeenFormatted)", systemImage: "calendar")
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }

            Spacer()

            // Confidence indicator
            ConfidenceIndicator(confidence: speaker.confidence)

            // Action buttons
            HStack(spacing: 8) {
                if canUnmerge {
                    Button(action: onUnmerge) {
                        Image(systemName: "arrow.triangle.branch")
                            .foregroundColor(.orange)
                    }
                    .buttonStyle(.plain)
                    .help("Unmerge speakers")
                }

                Button(action: onEdit) {
                    Image(systemName: "pencil.circle")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Edit speaker")

                if let onDelete = onDelete {
                    Button(action: onDelete) {
                        Image(systemName: "trash")
                            .foregroundColor(.red.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                    .help("Delete speaker")
                }
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute, .second]
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: seconds) ?? "0s"
    }
}

// MARK: - Speaker Edit Sheet

struct SpeakerEditSheet: View {
    let speaker: SpeakerProfile
    let viewModel: SpeakerManagementViewModel
    let onSave: (SpeakerProfile) -> Void
    let onCancel: () -> Void

    @State private var name: String = ""
    @State private var notes: String = ""
    @State private var selectedTab = "info"

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Edit Speaker")
                    .font(.title3)
                    .fontWeight(.bold)

                Spacer()

                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.escape, modifiers: [])

                Button("Save") {
                    var updatedSpeaker = speaker
                    updatedSpeaker.name = name.isEmpty ? nil : name
                    updatedSpeaker.notes = notes.isEmpty ? nil : notes
                    onSave(updatedSpeaker)
                }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(name == (speaker.name ?? "") && notes == (speaker.notes ?? ""))
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))

            // Tab selector
            Picker("View", selection: $selectedTab) {
                Text("Info").tag("info")
                Text("Utterances").tag("utterances")
                Text("Statistics").tag("statistics")
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.bottom, 8)

            // Content based on selected tab
            TabView(selection: $selectedTab) {
                infoTab
                    .tag("info")
                    .tabItem { Text("Info") }

                EnhancedSpeakerDetailView(speaker: speaker, viewModel: viewModel)
                    .tag("utterances")
                    .tabItem { Text("Utterances") }

                statsTab
                    .tag("statistics")
                    .tabItem { Text("Statistics") }
            }
            .tabViewStyle(.automatic)
        }
        .frame(minWidth: 700, idealWidth: 800, minHeight: 500, idealHeight: 600)
        .onAppear {
            name = speaker.name ?? ""
            notes = speaker.notes ?? ""
        }
    }

    private var infoTab: some View {
        Form {
            Section {
                HStack(spacing: 16) {
                    Circle()
                        .fill(speaker.avatarColor)
                        .frame(width: 60, height: 60)
                        .overlay(
                            Text(speaker.initials)
                                .foregroundColor(.white)
                                .font(.title2)
                                .fontWeight(.semibold)
                        )

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Speaker ID")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(speaker.uuid)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                    }

                    Spacer()
                }
            }

            Section("Speaker Information") {
                TextField("Name", text: $name, prompt: Text("Enter speaker name..."))

                VStack(alignment: .leading, spacing: 4) {
                    Text("Notes")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextEditor(text: $notes)
                        .frame(minHeight: 100)
                        .font(.body)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private var statsTab: some View {
        Form {
            Section("Overview") {
                LabeledContent("Total Speaking Time") {
                    Text(formatDuration(speaker.totalDuration))
                }
                LabeledContent("Number of Utterances") {
                    Text("\(speaker.utteranceCount)")
                }
                LabeledContent("Average Confidence") {
                    ConfidenceIndicator(confidence: speaker.confidence)
                }
                LabeledContent("First Seen") {
                    Text(speaker.firstSeen, style: .date)
                }
                LabeledContent("Last Seen") {
                    Text(speaker.lastSeen, style: .date)
                }
            }

            Section("Performance") {
                LabeledContent("Average Utterance Length") {
                    Text(formatDuration(speaker.utteranceCount > 0 ? speaker.totalDuration / Double(speaker.utteranceCount) : 0))
                }
                LabeledContent("Identification Confidence") {
                    HStack {
                        ProgressView(value: speaker.confidence)
                            .progressViewStyle(.linear)
                            .frame(width: 100)
                        Text("\(Int(speaker.confidence * 100))%")
                            .font(.caption)
                            .monospacedDigit()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: seconds) ?? "0s"
    }
}

// MARK: - Supporting Views

struct ConfidenceIndicator: View {
    let confidence: Float

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "checkmark.shield.fill")
                .foregroundColor(confidenceColor)
            Text("\(Int(confidence * 100))%")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var confidenceColor: Color {
        if confidence >= 0.9 { return .green }
        else if confidence >= 0.7 { return .orange }
        else { return .red }
    }
}

struct RecordingRowView: View {
    let recording: RecordingInfo

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(recording.title)
                    .fontWeight(.medium)
                Text(recording.date, style: .date)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Text(recording.speakerDuration)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
    }
}
