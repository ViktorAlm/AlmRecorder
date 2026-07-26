import SwiftUI

/// First-class "People" page: a master–detail split pane. Left = a searchable list of everyone
/// (the global people list); right = the selected person's full profile, including a search over
/// everything they've said. Merge/cleanup tools live on the separate `SpeakerManagementView`,
/// opened via the "Manage" toolbar button (browse + manage split).
struct PeopleView: View {
    @StateObject private var viewModel = SpeakerManagementViewModel()

    @State private var people: [SpeakerProfile] = []
    @State private var selectedUuid: String?
    @State private var searchText = ""
    @State private var sort: SortOrder = .talkTime
    @State private var filter: PeopleFilter = .all
    @State private var emailByUuid: [String: String] = [:]
    @State private var inferredUuids: Set<String> = []
    @State private var ownerUuid: String?
    @State private var showManage = false
    @State private var showSuggested = false
    @State private var suggestionCount = 0
    @State private var isLoading = false

    enum SortOrder: String, CaseIterable, Identifiable {
        case talkTime = "Most talk time"
        case recent = "Recently seen"
        case name = "Name"
        var id: String { rawValue }
    }

    enum PeopleFilter: String, CaseIterable, Identifiable {
        case all = "All"
        case named = "Named"
        case unnamed = "Unnamed"
        var id: String { rawValue }
    }

    var body: some View {
        HSplitView {
            leftPane
                .frame(minWidth: 280, idealWidth: 330, maxWidth: 460)
            rightPane
                .frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showSuggested = true } label: {
                    Label(suggestionCount > 0 ? "Suggested (\(suggestionCount))" : "Suggested", systemImage: "sparkles")
                }
                .help("Review who the app thinks each voice is — including you")
            }
            ToolbarItem(placement: .primaryAction) {
                Button { showManage = true } label: { Label("Manage", systemImage: "slider.horizontal.3") }
                    .help("Merge, rename, and clean up speakers")
            }
            ToolbarItem(placement: .automatic) {
                Menu {
                    Picker("Sort", selection: $sort) { ForEach(SortOrder.allCases) { Text($0.rawValue).tag($0) } }
                    Divider()
                    Picker("Filter", selection: $filter) { ForEach(PeopleFilter.allCases) { Text($0.rawValue).tag($0) } }
                } label: {
                    Label("Sort & Filter", systemImage: "line.3.horizontal.decrease.circle")
                }
            }
        }
        .task { await reload() }
        .onChange(of: showManage) { presenting in
            if !presenting { Task { await reload() } }
        }
        .sheet(isPresented: $showManage) {
            VStack(spacing: 0) {
                HStack {
                    Text("Manage Speakers").font(.headline)
                    Spacer()
                    Button("Done") { showManage = false }
                        .keyboardShortcut(.cancelAction) // Esc closes too
                        .controlSize(.large)
                }
                .padding(12)
                Divider()
                SpeakerManagementView()
            }
            .frame(minWidth: 800, minHeight: 580)
        }
        .onChange(of: showSuggested) { presenting in
            if !presenting { Task { await reload() } }
        }
        .sheet(isPresented: $showSuggested) {
            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    Button("Done") { showSuggested = false }
                        .keyboardShortcut(.cancelAction)
                        .controlSize(.large)
                }
                .padding(.horizontal, 12).padding(.top, 12)
                SuggestedPeopleView(onChange: { Task { await reload() } })
            }
            .frame(minWidth: 540, minHeight: 540)
        }
    }

    // MARK: - Left (searchable list)

    private var leftPane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                TextField("Search people", text: $searchText)
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button { searchText = "" } label: { Image(systemName: "xmark.circle.fill").foregroundColor(.secondary) }
                        .buttonStyle(.plain)
                }
            }
            .padding(8)
            .background(Color(NSColor.controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .padding(10)

            Divider()

            if isLoading && people.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredPeople.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "person.2.slash").font(.system(size: 32)).foregroundColor(.secondary)
                    Text(searchText.isEmpty ? "No people yet" : "No matches")
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selectedUuid) {
                    ForEach(filteredPeople) { person in
                        SpeakerListRow(speaker: person, email: emailByUuid[person.uuid],
                                       isInferred: inferredUuids.contains(person.uuid),
                                       isOwner: person.uuid == ownerUuid)
                            .tag(person.uuid)
                    }
                }
                // Opaque content list (NOT .sidebar glass): the People list is CONTENT, so it
                // stays solid for legibility. The translucent glass belongs to the chrome
                // (the app sidebar), not to this list.
                .listStyle(.inset)
            }

            Divider()
            HStack {
                Text("\(filteredPeople.count) people")
                    .font(.caption2).foregroundColor(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
        }
    }

    // MARK: - Right (person content)

    private var rightPane: some View {
        NavigationStack {
            if let person = selectedPerson {
                PersonProfileView(speaker: person, viewModel: viewModel) {
                    Task { await reload() }
                }
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "person.crop.circle").font(.system(size: 56)).foregroundColor(.secondary)
                    Text("Select a person").font(.title3).foregroundColor(.secondary)
                    Text("Pick someone on the left to see what they've said, when, and who you met them with.")
                        .font(.callout).foregroundColor(.secondary)
                        .multilineTextAlignment(.center).frame(maxWidth: 360)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .id(selectedUuid) // reset the detail stack when the selected person changes
    }

    // MARK: - Derived

    private var selectedPerson: SpeakerProfile? {
        people.first { $0.uuid == selectedUuid }
    }

    private var filteredPeople: [SpeakerProfile] {
        var list = people

        switch filter {
        case .all: break
        case .named: list = list.filter { $0.name?.isEmpty == false }
        case .unnamed: list = list.filter { $0.name?.isEmpty != false }
        }

        let query = searchText.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty {
            list = list.filter {
                $0.displayName.localizedCaseInsensitiveContains(query)
                    || $0.uuid.localizedCaseInsensitiveContains(query)
                    || (emailByUuid[$0.uuid]?.localizedCaseInsensitiveContains(query) ?? false)
            }
        }

        switch sort {
        case .talkTime: list.sort { $0.totalDuration > $1.totalDuration }
        case .recent: list.sort { $0.lastSeen > $1.lastSeen }
        case .name: list.sort { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        }
        return list
    }

    // MARK: - Loading

    private func reload() async {
        isLoading = true
        let repo = GRDBSpeakerRepository()
        let loaded = (try? repo.getSpeakersWithStats(includeEmpty: false)) ?? []
        people = loaded
        inferredUuids = repo.inferredNamedVoiceUuids()
        ownerUuid = OwnerIdentityService.shared.ownerVoiceUuid
        suggestionCount = IdentityInferenceCoordinator.shared.computeAll().count
        loadEmails()
        // One-shot deep link (dashboard People row) — applied before the default-selection
        // fallback so the requested person wins when present.
        if let pending = AppState.shared.pendingPersonUuid {
            AppState.shared.pendingPersonUuid = nil
            selectedUuid = pending
            // On the view's FIRST mount the AppKit-backed List clobbers a selection set in the
            // same update as its row data (it reverts to the default row while building the
            // table). Re-assert once after the table settles; no-op when it stuck.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 250_000_000)
                if selectedUuid != pending { selectedUuid = pending }
            }
        }
        // Keep a valid selection (default to the first / most-talkative person).
        if selectedUuid == nil || !loaded.contains(where: { $0.uuid == selectedUuid }) {
            selectedUuid = filteredPeople.first?.uuid
        }
        isLoading = false
    }

    private func loadEmails() {
        let mappings = (try? GRDBSpeakerAttendeeRepository().getAllMappings()) ?? []
        var dict: [String: String] = [:]
        for m in mappings where m.attendeeEmail?.isEmpty == false {
            if dict[m.speakerUuid] == nil { dict[m.speakerUuid] = m.attendeeEmail }
        }
        emailByUuid = dict
    }
}

// MARK: - List row

private struct SpeakerListRow: View {
    let speaker: SpeakerProfile
    let email: String?
    var isInferred: Bool = false
    var isOwner: Bool = false

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(isOwner ? Color.accentColor : speaker.avatarColor)
                .frame(width: 30, height: 30)
                .overlay(Text(speaker.initials).font(.system(size: 11, weight: .bold)).foregroundColor(.white))
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(speaker.displayName).font(.body).lineLimit(1)
                    if isOwner { chip("You", .accentColor) }
                    else if isInferred { chip("inferred", .orange) }
                }
                Text(subtitle).font(.caption2).foregroundColor(.secondary).lineLimit(1)
            }
            Spacer()
            Text("\(speaker.utteranceCount)")
                .font(.caption).foregroundColor(.secondary).monospacedDigit()
        }
        .padding(.vertical, 2)
    }

    private func chip(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(color.opacity(0.16))
            .foregroundColor(color)
            .clipShape(Capsule())
    }

    private var subtitle: String {
        if let email, !email.isEmpty { return email }
        return shortDuration(speaker.totalDuration)
    }

    private func shortDuration(_ seconds: TimeInterval) -> String {
        let f = DateComponentsFormatter()
        f.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute, .second]
        f.unitsStyle = .abbreviated
        return f.string(from: seconds) ?? "0s"
    }
}
