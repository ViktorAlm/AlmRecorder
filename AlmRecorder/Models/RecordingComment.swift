import Foundation

struct RecordingComment: Codable, Identifiable, Equatable {
    enum Status: String, Codable, CaseIterable {
        case open
        case resolved
    }

    let id: String
    let recordingId: Int64
    var body: String
    var anchorStart: TimeInterval?
    var anchorEnd: TimeInterval?
    var sourceUtteranceId: Int64?
    var status: Status
    let createdBy: String
    let idempotencyKey: String?
    let createdAt: Date
    var updatedAt: Date
    var resolvedAt: Date?
}
