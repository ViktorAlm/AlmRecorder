import Foundation
import Combine

@MainActor
class MeetingsViewModel: ObservableObject {
    @Published var recordingsWithMeetings: [RecordingWithMeetings] = []
    @Published var isLoading = false

    private let meetingRepo = GRDBMeetingRepository()
    private let calendarService = CalendarService.shared

    func loadData() {
        isLoading = true
        defer { isLoading = false }

        do {
            recordingsWithMeetings = try meetingRepo.getRecordingsWithMeetings()
        } catch {
            print("[MeetingsViewModel] Failed to load: \(error)")
        }
    }

    func refresh() async {
        await calendarService.syncEvents()
        loadData()
    }
}
