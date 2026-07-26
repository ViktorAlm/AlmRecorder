import Foundation
import Combine

/// Filter state for Dashboard browsing
struct DashboardFilters: Equatable {
    var tagIds: [Int64] = []
    var speakerUuid: String? = nil
    var speakerName: String? = nil
    var datePeriod: DatePeriod? = nil
    var source: Recording.RecordingSource? = nil
    var searchText: String? = nil

    static let empty = DashboardFilters()

    var isActive: Bool {
        !tagIds.isEmpty || speakerUuid != nil || datePeriod != nil || source != nil || (searchText != nil && !searchText!.isEmpty)
    }

    /// Label for the active-speaker chip: the name when known, else the stable global
    /// "Speaker <uuid8>" — never the raw full UUID. Nil when no speaker is filtered.
    var speakerChipLabel: String? {
        guard let uuid = speakerUuid else { return nil }
        if let name = speakerName, !name.isEmpty { return name }
        return "Speaker \(uuid.prefix(8))"
    }

    var descriptions: [(label: String, id: String)] {
        var chips: [(String, String)] = []
        if let label = speakerChipLabel {
            chips.append(("Speaker: \(label)", "speaker"))
        }
        for tagId in tagIds {
            chips.append(("Tag #\(tagId)", "tag_\(tagId)"))
        }
        if let period = datePeriod {
            chips.append((period.displayName, "date"))
        }
        if let source = source {
            chips.append((source.displayName, "source"))
        }
        if let text = searchText, !text.isEmpty {
            chips.append(("Search: \(text)", "search"))
        }
        return chips
    }
}

enum DatePeriod: Equatable {
    case today, yesterday, thisWeek, thisMonth, older

    var displayName: String {
        switch self {
        case .today: return "Today"
        case .yesterday: return "Yesterday"
        case .thisWeek: return "This Week"
        case .thisMonth: return "This Month"
        case .older: return "Older"
        }
    }

    var dateRange: (from: Date, to: Date) {
        let calendar = Calendar.current
        let now = Date()
        let startOfToday = calendar.startOfDay(for: now)

        switch self {
        case .today:
            return (startOfToday, now)
        case .yesterday:
            let startOfYesterday = calendar.date(byAdding: .day, value: -1, to: startOfToday)!
            return (startOfYesterday, startOfToday)
        case .thisWeek:
            let startOfWeek = calendar.date(from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now))!
            return (startOfWeek, now)
        case .thisMonth:
            let startOfMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: now))!
            return (startOfMonth, now)
        case .older:
            let startOfMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: now))!
            return (Date.distantPast, startOfMonth)
        }
    }
}

@MainActor
class DashboardViewModel: ObservableObject {
    // Dashboard data
    @Published var recentRecordings: [Recording] = []
    @Published var totalRecordings: Int = 0
    @Published var totalDuration: TimeInterval = 0
    @Published var speakerCount: Int = 0
    @Published var sourceCounts: [String: Int] = [:]
    @Published var allTags: [(tag: Tag, count: Int)] = []
    @Published var speakers: [(speakerUuid: String, speakerName: String?, recordingCount: Int)] = []
    @Published var dateGroups: [(period: String, count: Int)] = []

    // Needs-attention + activity
    @Published var untranscribedCount: Int = 0
    @Published var identitySuggestionCount: Int = 0
    @Published var isTranscriptionModelMissing: Bool = false
    @Published var dailyActivity: [GRDBRecordingRepository.DailyActivityBucket] = []
    @Published var thisWeekCount: Int = 0

    // People row: recently-heard speakers, named people first
    @Published var rowSpeakers: [SpeakerProfile] = []

    // Filters
    @Published var activeFilters = DashboardFilters.empty
    @Published var filteredRecordings: [Recording] = []
    @Published var isFiltering: Bool = false

    // Search
    @Published var searchQuery: String = ""
    @Published var isSearching: Bool = false

    // Selection
    @Published var selectedRecording: Recording? = nil

    // Tag name cache for filter chips
    var tagNameCache: [Int64: String] = [:]

    private let recordingRepo = GRDBRecordingRepository()
    private let tagRepo = GRDBTagRepository()
    private let speakerRepo = GRDBSpeakerRepository()
    private let searchService = SemanticSearchService.shared

    func loadDashboard() {
        do {
            recentRecordings = try recordingRepo.getAll(limit: 10)
            totalRecordings = try recordingRepo.count()
            totalDuration = try recordingRepo.totalDuration()
            sourceCounts = try recordingRepo.countBySource()

            let speakerData = try recordingRepo.getSpeakersWithRecordingCounts()
            speakers = speakerData
            speakerCount = speakerData.count

            allTags = try tagRepo.getTagsWithCounts()
            tagNameCache = Dictionary(uniqueKeysWithValues: allTags.compactMap { item in
                guard let id = item.tag.id else { return nil }
                return (id, item.tag.name)
            })

            // Build date group counts
            let grouped = try recordingRepo.getGroupedByDate()
            dateGroups = grouped.map { (period: $0.period, count: $0.recordings.count) }

            // Needs-attention + activity (cheap — safe on the 5s refresh tick)
            untranscribedCount = try recordingRepo.getRecordingsWithoutTranscript().count
            dailyActivity = try recordingRepo.getDailyActivity(days: 28)
            let calendar = Calendar.current
            let startOfWeek = calendar.date(
                from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: Date()))!
            thisWeekCount = dailyActivity.filter { $0.day >= startOfWeek }.reduce(0) { $0 + $1.count }
            isTranscriptionModelMissing = Self.checkTranscriptionModelMissing()

            // People row (named first, then recently-heard clusters)
            rowSpeakers = Self.speakerRowOrder(
                try speakerRepo.getSpeakersWithStats(includeEmpty: false),
                limit: 14
            )
        } catch {
            print("[DashboardViewModel] Failed to load dashboard: \(error)")
        }
    }

    /// Pending speaker-name suggestions (the People page's confirm-inbox). `pendingSuggestions()`
    /// re-runs identity inference over the whole library, so it stays off the 5-second refresh
    /// tick and off the main thread (same detached pattern as `scheduleRecompute()`).
    func refreshIdentitySuggestions() {
        Task.detached(priority: .utility) { [weak self] in
            let count = IdentityInferenceCoordinator.shared.pendingSuggestions().count
            guard let self else { return }
            await MainActor.run { self.identitySuggestionCount = count }
        }
    }

    /// Ordering for the dashboard People row: named people first, each group most recently
    /// heard first, capped at `limit`.
    nonisolated static func speakerRowOrder(_ profiles: [SpeakerProfile], limit: Int) -> [SpeakerProfile] {
        let sorted = profiles.sorted { a, b in
            let aNamed = !(a.name ?? "").isEmpty
            let bNamed = !(b.name ?? "").isEmpty
            if aNamed != bNamed { return aNamed }
            return a.lastSeen > b.lastSeen
        }
        return Array(sorted.prefix(limit))
    }

    /// True when the selected transcription backend's model isn't on disk (first run, or the
    /// user switched backends without downloading) — every transcription would just queue up.
    static func checkTranscriptionModelMissing() -> Bool {
        let settings = GlobalModelSettings.shared
        switch settings.transcriptionBackend {
        case .whisper:
            guard let variant = settings.selectedWhisperVariant else { return true }
            return !WhisperModelManager.shared.isModelDownloaded(variant)
        case .llm:
            switch settings.selectedLLMEngine {
            case .voxtral:
                return !VoxtralModelManager().isModelDownloaded(settings.selectedVoxtralTranscriptionModel)
            case .gemma:
                return !GemmaModelManager().isModelDownloaded(settings.selectedGemmaTranscriptionModel)
            }
        case .vibeVoice:
            return !VibeVoiceModelManager.shared.isModelDownloaded(
                settings.selectedVibeVoiceQuantization
            ) || !VibeVoiceService.shared.isRuntimeInstalled
        }
    }

    func applyFilter(tagId: Int64? = nil, speakerUuid: String? = nil, speakerName: String? = nil,
                     datePeriod: DatePeriod? = nil, source: Recording.RecordingSource? = nil) {
        if let tagId = tagId, !activeFilters.tagIds.contains(tagId) {
            activeFilters.tagIds.append(tagId)
        }
        if let uuid = speakerUuid {
            activeFilters.speakerUuid = uuid
            activeFilters.speakerName = speakerName
        }
        if let period = datePeriod {
            activeFilters.datePeriod = period
        }
        if let source = source {
            activeFilters.source = source
        }
        runFilter()
    }

    func removeFilter(id: String) {
        if id == "speaker" {
            activeFilters.speakerUuid = nil
            activeFilters.speakerName = nil
        } else if id == "date" {
            activeFilters.datePeriod = nil
        } else if id == "source" {
            activeFilters.source = nil
        } else if id == "search" {
            activeFilters.searchText = nil
            searchQuery = ""
        } else if id.hasPrefix("tag_"), let tagId = Int64(id.replacingOccurrences(of: "tag_", with: "")) {
            activeFilters.tagIds.removeAll { $0 == tagId }
        }
        runFilter()
    }

    func clearFilters() {
        activeFilters = .empty
        searchQuery = ""
        filteredRecordings = []
        isFiltering = false
    }

    func performSearch() {
        guard !searchQuery.trimmingCharacters(in: .whitespaces).isEmpty else {
            if activeFilters.searchText != nil {
                activeFilters.searchText = nil
                runFilter()
            }
            return
        }
        activeFilters.searchText = searchQuery
        runFilter()
    }

    private func runFilter() {
        guard activeFilters.isActive else {
            isFiltering = false
            filteredRecordings = []
            return
        }

        isFiltering = true
        do {
            let dateRange = activeFilters.datePeriod?.dateRange
            filteredRecordings = try recordingRepo.getFiltered(
                tagIds: activeFilters.tagIds.isEmpty ? nil : activeFilters.tagIds,
                speakerUuid: activeFilters.speakerUuid,
                dateFrom: dateRange?.from,
                dateTo: dateRange?.to,
                source: activeFilters.source,
                searchText: activeFilters.searchText,
                limit: 200
            )
        } catch {
            print("[DashboardViewModel] Filter failed: \(error)")
            filteredRecordings = []
        }
    }

    /// Formatted total duration string
    var formattedTotalDuration: String {
        let hours = Int(totalDuration) / 3600
        let minutes = (Int(totalDuration) % 3600) / 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m"
    }

    /// Get filter chip descriptions with tag names resolved
    var filterChips: [(label: String, id: String)] {
        var chips: [(String, String)] = []
        if let label = activeFilters.speakerChipLabel {
            chips.append(("Speaker: \(label)", "speaker"))
        }
        for tagId in activeFilters.tagIds {
            let name = tagNameCache[tagId] ?? "Tag"
            chips.append((name, "tag_\(tagId)"))
        }
        if let period = activeFilters.datePeriod {
            chips.append((period.displayName, "date"))
        }
        if let source = activeFilters.source {
            chips.append((source.displayName, "source"))
        }
        if let text = activeFilters.searchText, !text.isEmpty {
            chips.append(("\"\(text)\"", "search"))
        }
        return chips
    }
}
