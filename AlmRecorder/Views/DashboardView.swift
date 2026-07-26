import SwiftUI

// MARK: - Recording Hashable Conformance

extension Recording: Hashable {
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

extension Recording: Equatable {
    static func == (lhs: Recording, rhs: Recording) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Dashboard View

struct DashboardView: View {
    /// Sidebar selection, owned by ModernContentView (same pattern as SidebarView) — the
    /// dashboard's quick actions, attention rows, and stat cards navigate through it.
    @Binding var selection: NavigationItem?
    @StateObject var viewModel = DashboardViewModel()
    @Environment(\.colorScheme) var colorScheme
    // Observe the queue so the browse lists + stats refresh as transcriptions complete.
    // Without this the "By Speaker" list went stale: a speaker that had since been re-diarized
    // away stayed visible, and clicking it filtered on a now-dead UUID → 0 results.
    @ObservedObject private var queueManager = TranscriptionQueueManager.shared
    private let refreshTimer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                DashboardQuickActionsRow(
                    searchText: $viewModel.searchQuery,
                    onStartRecording: startOrOpenRecording,
                    onImport: { selection = .import },
                    onSubmitSearch: { viewModel.performSearch() },
                    onClearSearch: {
                        viewModel.searchQuery = ""
                        viewModel.performSearch()
                    },
                    onSemanticSearch: openSemanticSearch
                )

                // Self-hiding: renders nothing while every queue is idle.
                PipelineStatusStrip(onOpenQueue: { selection = .queue })

                // Content: filtering or browsing
                if viewModel.isFiltering {
                    ActiveFilterChips(
                        chips: viewModel.filterChips,
                        onRemove: { id in viewModel.removeFilter(id: id) },
                        onClearAll: { viewModel.clearFilters() }
                    )

                    FilteredRecordingListView(
                        recordings: viewModel.filteredRecordings,
                        onSelect: { recording in
                            viewModel.selectedRecording = recording
                        }
                    )
                } else {
                    // Self-hiding: renders nothing when all clear.
                    NeedsAttentionPanel(
                        untranscribedCount: viewModel.untranscribedCount,
                        identitySuggestionCount: viewModel.identitySuggestionCount,
                        isModelMissing: viewModel.isTranscriptionModelMissing,
                        onNavigate: { selection = $0 },
                        onTranscribeUntranscribed: transcribeUntranscribed
                    )

                    DashboardStatsRow(
                        totalRecordings: viewModel.totalRecordings,
                        formattedDuration: viewModel.formattedTotalDuration,
                        speakerCount: viewModel.speakerCount,
                        thisWeekCount: viewModel.thisWeekCount,
                        onSelectRecordings: { selection = .history },
                        onSelectSpeakers: { selection = .speakers },
                        onSelectThisWeek: { viewModel.applyFilter(datePeriod: .thisWeek) }
                    )

                    RecentRecordingsSection(
                        recordings: viewModel.recentRecordings,
                        onSelect: { recording in
                            viewModel.selectedRecording = recording
                        },
                        onSeeAll: { selection = .history }
                    )

                    // Self-hiding: renders nothing while the library has no speakers.
                    DashboardSpeakersRow(
                        speakers: viewModel.rowSpeakers,
                        onSelect: openPerson,
                        onSeeAll: { selection = .speakers }
                    )

                    if viewModel.totalRecordings > 0 {
                        DashboardActivityChart(data: viewModel.dailyActivity)
                    }

                    BrowseSectionsView(
                        dateGroups: viewModel.dateGroups,
                        speakers: viewModel.speakers,
                        tags: viewModel.allTags,
                        sourceCounts: viewModel.sourceCounts,
                        onSelectDate: { period in
                            viewModel.applyFilter(datePeriod: period)
                        },
                        onSelectSpeaker: { uuid, name in
                            viewModel.applyFilter(speakerUuid: uuid, speakerName: name)
                        },
                        onSelectTag: { tagId in
                            viewModel.applyFilter(tagId: tagId)
                        },
                        onSelectSource: { source in
                            viewModel.applyFilter(source: source)
                        }
                    )
                }
            }
            .padding(24)
        }
        .sheet(item: $viewModel.selectedRecording) { recording in
            RecordingDetailSheet(recording: recording)
        }
        .onAppear {
            viewModel.loadDashboard()
            viewModel.refreshIdentitySuggestions()
        }
        // Keep browse lists/stats current while the queue is actively transcribing (new
        // recordings + speakers appear continuously). Light cadence while processing, plus one
        // refresh when processing flips off so the final state is shown. Identity suggestions
        // are recomputed only on the processing edge — too expensive for the 5s tick.
        .onReceive(refreshTimer) { _ in
            if queueManager.isProcessing {
                viewModel.loadDashboard()
            }
        }
        .onChange(of: queueManager.isProcessing) { _ in
            viewModel.loadDashboard()
            viewModel.refreshIdentitySuggestions()
        }
    }

    // MARK: - Actions

    private func startOrOpenRecording() {
        // Same record-intent path as AppDelegate.handleMeetingAction: the Record page renders
        // MeetingRecorder.shared, so starting here lands the user on live levels. While already
        // recording the button only navigates — stop/enqueue stays on the Record page.
        if !MeetingRecorder.shared.isRecording {
            Task { await MeetingRecorder.shared.start() }
        }
        selection = .record
    }

    private func openPerson(uuid: String) {
        AppState.shared.pendingPersonUuid = uuid
        selection = .speakers
    }

    private func openSemanticSearch() {
        let query = viewModel.searchQuery.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return }
        AppState.shared.pendingSearch = .init(query: query, semantic: true)
        selection = .search
    }

    private func transcribeUntranscribed() {
        TranscriptionQueueManager.shared.requeueEmptyRecordings()
        selection = .queue
        viewModel.loadDashboard()
    }
}

// MARK: - Recent Recordings Section

struct RecentRecordingsSection: View {
    let recordings: [Recording]
    let onSelect: (Recording) -> Void
    var onSeeAll: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Recent Recordings")
                    .font(.title3)
                    .fontWeight(.semibold)

                Spacer()

                if let onSeeAll, !recordings.isEmpty {
                    Button(action: onSeeAll) {
                        HStack(spacing: 4) {
                            Text("See all")
                            Image(systemName: "arrow.right")
                        }
                        .font(.subheadline)
                        .foregroundColor(.accentColor)
                    }
                    .buttonStyle(.plain)
                    .help("Open the full recording history")
                }
            }

            if recordings.isEmpty {
                HStack {
                    Spacer()
                    VStack(spacing: 8) {
                        Image(systemName: "waveform.slash")
                            .font(.system(size: 32))
                            .foregroundColor(.secondary.opacity(0.5))
                        Text("No recordings yet")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 30)
                    Spacer()
                }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(recordings, id: \.id) { recording in
                            DashboardRecordingCard(
                                recording: recording,
                                onTap: { onSelect(recording) }
                            )
                        }
                    }
                    .padding(.horizontal, 2)
                    .padding(.vertical, 4)
                }
            }
        }
    }
}
