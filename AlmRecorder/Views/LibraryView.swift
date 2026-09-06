import SwiftUI

/// The single user-facing collection of recordings.
///
/// Dashboard cards, search results, and this view all open the same GRDB-backed `Recording` detail
/// surface. Legacy `TranscriptionItem` history remains available only for migration/debugging.
struct LibraryView: View {
    @Binding var selection: NavigationItem?

    @State private var recordings: [Recording] = []
    @State private var totalCount = 0
    @State private var searchText = ""
    @State private var source: Recording.RecordingSource?
    @State private var selectedRecording: Recording?
    @State private var loadError: String?
    @State private var searchTask: Task<Void, Never>?

    @ObservedObject private var queue = TranscriptionQueueManager.shared
    private let repository = GRDBRecordingRepository()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if let loadError {
                errorBanner(loadError)
            }

            if recordings.isEmpty {
                emptyState
            } else {
                ScrollView {
                    FilteredRecordingListView(
                        recordings: recordings,
                        showsCount: false,
                        onSelect: { selectedRecording = $0 }
                    )
                    .padding(20)
                }
            }
        }
        .sheet(item: $selectedRecording) { recording in
            RecordingDetailSheet(recording: recording)
        }
        .task { loadRecordings() }
        .onDisappear { searchTask?.cancel() }
        .onChange(of: searchText) { _, _ in scheduleSearch() }
        .onChange(of: source) { _, _ in loadRecordings() }
        .onChange(of: queue.isProcessing) { _, isProcessing in
            if !isProcessing { loadRecordings() }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Library")
                        .font(.title2.weight(.semibold))
                    Text(countDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    selection = .import
                } label: {
                    Label("Import", systemImage: "square.and.arrow.down")
                }

                Button {
                    openRecorder()
                } label: {
                    Label("Record", systemImage: "mic.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }

            HStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)

                    TextField("Find by title or transcript…", text: $searchText)
                        .textFieldStyle(.plain)

                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear library search")
                    }
                }
                .padding(9)
                .cardSurface(cornerRadius: 9)

                Picker("Source", selection: $source) {
                    Text("All sources")
                        .tag(Optional<Recording.RecordingSource>.none)
                    ForEach(Recording.RecordingSource.allCases, id: \.self) { item in
                        Text(item.displayName)
                            .tag(Optional(item))
                    }
                }
                .frame(width: 190)

                if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button {
                        searchTranscriptMeaning()
                    } label: {
                        Label("Search meaning", systemImage: "sparkle.magnifyingglass")
                    }
                    .help("Search for conceptually related moments in every transcript")
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    @ViewBuilder
    private var emptyState: some View {
        if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && source == nil {
            VStack(spacing: 14) {
                Image(systemName: "waveform")
                    .font(.system(size: 46))
                    .foregroundStyle(.secondary)

                Text("Your recordings will appear here")
                    .font(.title3.weight(.semibold))

                Text("Record something new or import an audio file. Transcripts remain on this Mac.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)

                HStack {
                    Button {
                        selection = .import
                    } label: {
                        Label("Import Audio", systemImage: "square.and.arrow.down")
                    }

                    Button {
                        openRecorder()
                    } label: {
                        Label("Start Recording", systemImage: "mic.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 36))
                    .foregroundStyle(.secondary)
                Text("No matching recordings")
                    .font(.title3.weight(.semibold))
                Text("Try a shorter phrase, another source, or search by meaning.")
                    .foregroundStyle(.secondary)

                if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button {
                        searchTranscriptMeaning()
                    } label: {
                        Label("Search Transcript Meaning", systemImage: "sparkle.magnifyingglass")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text("Library couldn’t refresh: \(message)")
                .font(.caption)
            Spacer()
            Button("Try Again") { loadRecordings() }
        }
        .padding(10)
        .background(Color.orange.opacity(0.1))
        .padding(.horizontal, 20)
        .padding(.top, 10)
    }

    private var countDescription: String {
        let isFiltered = source != nil
            || !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if isFiltered {
            return "\(recordings.count) of \(totalCount) recordings"
        }
        return "\(totalCount) recording\(totalCount == 1 ? "" : "s")"
    }

    private func scheduleSearch() {
        searchTask?.cancel()
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 220_000_000)
            guard !Task.isCancelled else { return }
            loadRecordings()
        }
    }

    private func loadRecordings() {
        do {
            totalCount = try repository.count()
            let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            recordings = try repository.getFiltered(
                source: source,
                searchText: query.isEmpty ? nil : query,
                limit: 500
            )
            loadError = nil
        } catch {
            recordings = []
            loadError = error.localizedDescription
        }
    }

    private func openRecorder() {
        if !MeetingRecorder.shared.isRecording {
            Task { await MeetingRecorder.shared.start() }
        }
        selection = .record
    }

    private func searchTranscriptMeaning() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        AppState.shared.pendingSearch = .init(query: query, semantic: true)
        selection = .search
    }
}
