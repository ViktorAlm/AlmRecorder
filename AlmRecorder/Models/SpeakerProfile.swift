import Foundation
import SwiftUI

// MARK: - Speaker Profile

/// Consolidated speaker profile model used across the app.
/// Represents a persistent speaker identity stored in the database.
struct SpeakerProfile: Identifiable, Equatable {
    var id: Int?
    let uuid: String
    var name: String?
    var notes: String?
    var averageEmbedding: [Float]
    var totalDuration: TimeInterval
    var utteranceCount: Int
    let firstSeen: Date
    var lastSeen: Date
    var confidence: Float
    var sourceRecordingId: Int?

    var displayName: String {
        if let name = name, !name.isEmpty {
            return name
        }
        return "Speaker \(uuid.prefix(8))"
    }

    var initials: String {
        if let name = name, !name.isEmpty {
            let components = name.components(separatedBy: " ")
            let chars = components.compactMap { $0.first }.prefix(2)
            return String(chars).uppercased()
        }
        return String(uuid.prefix(2)).uppercased()
    }

    /// Deterministic avatar color from UUID using djb2 hash.
    /// Unlike `hashValue`, this is stable across app launches.
    var avatarColor: Color {
        Color.speakerColor(for: uuid)
    }

    var lastSeenFormatted: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: lastSeen, relativeTo: Date())
    }

    init(
        id: Int? = nil,
        uuid: String? = nil,
        name: String? = nil,
        notes: String? = nil,
        averageEmbedding: [Float] = [],
        totalDuration: TimeInterval = 0,
        utteranceCount: Int = 0,
        firstSeen: Date? = nil,
        lastSeen: Date? = nil,
        confidence: Float = 0.9,
        sourceRecordingId: Int? = nil
    ) {
        self.id = id
        self.uuid = uuid ?? UUID().uuidString
        self.name = name
        self.notes = notes
        self.averageEmbedding = averageEmbedding
        self.totalDuration = totalDuration
        self.utteranceCount = utteranceCount
        let now = Date()
        self.firstSeen = firstSeen ?? now
        self.lastSeen = lastSeen ?? now
        self.confidence = confidence
        self.sourceRecordingId = sourceRecordingId
    }

    /// Convenience init using `embedding` parameter name for compatibility
    /// with SpeakerIdentificationService call sites.
    init(
        id: Int? = nil,
        uuid: String? = nil,
        name: String? = nil,
        embedding: [Float],
        totalDuration: TimeInterval = 0,
        utteranceCount: Int = 0,
        firstSeen: Date? = nil,
        lastSeen: Date? = nil,
        confidence: Float = 0.9
    ) {
        self.init(
            id: id,
            uuid: uuid,
            name: name,
            averageEmbedding: embedding,
            totalDuration: totalDuration,
            utteranceCount: utteranceCount,
            firstSeen: firstSeen,
            lastSeen: lastSeen,
            confidence: confidence
        )
    }

    static func == (lhs: SpeakerProfile, rhs: SpeakerProfile) -> Bool {
        lhs.uuid == rhs.uuid
    }
}

// MARK: - Supporting Models

struct RecordingInfo: Identifiable {
    let id: Int
    let title: String
    let date: Date
    let speakerDuration: String
}

struct UtteranceDetail: Identifiable, Equatable {
    let id: Int
    let text: String
    let startTime: TimeInterval
    let endTime: TimeInterval
    let speakerUUID: String

    var duration: TimeInterval {
        endTime - startTime
    }
}

struct RecordingDetail: Identifiable, Hashable {
    let id: Int
    let title: String
    let audioPath: String
    let createdAt: Date
    let duration: TimeInterval
}
