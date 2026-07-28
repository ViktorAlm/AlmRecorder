import Foundation

struct LibrarySearchMoment: Identifiable {
    let hit: LibrarySearchHit
    let matchingHits: [LibrarySearchHit]
    let startTime: TimeInterval
    let endTime: TimeInterval

    var id: String { hit.id }
    var score: Double { hit.score }
}

struct LibraryConversationSearchResult: Identifiable {
    let recording: Recording
    let moments: [LibrarySearchMoment]
    let titleHit: LibrarySearchHit?
    let score: Double

    var id: String {
        if let recordingId = recording.id {
            return "recording:\(recordingId)"
        }
        if let externalId = recording.externalId {
            return "recording-external:\(externalId)"
        }
        return "recording-file:\(recording.fileName):\(recording.createdAt.timeIntervalSince1970)"
    }

    var isTitleOnly: Bool { moments.isEmpty && titleHit != nil }
    var bestHit: LibrarySearchHit? { moments.first?.hit ?? titleHit }
}

enum LibrarySearchGrouper {
    static let nearbyUtteranceDistance = 2
    static let nearbyTimeDistance: TimeInterval = 20

    static func group(
        _ hits: [LibrarySearchHit],
        limit: Int
    ) -> [LibraryConversationSearchResult] {
        guard limit > 0 else { return [] }

        let transcriptHits = hits.filter {
            $0.field == .transcript && $0.recording.id != nil
        }
        let titleHits = hits.filter {
            $0.field == .title && $0.recording.id != nil
        }
        let transcriptByRecording = Dictionary(
            grouping: transcriptHits,
            by: { $0.recording.id! }
        )
        let titleByRecording = Dictionary(
            grouping: titleHits,
            by: { $0.recording.id! }
        )
        let recordingIds = Set(transcriptByRecording.keys).union(titleByRecording.keys)

        let groups = recordingIds.compactMap { recordingId -> LibraryConversationSearchResult? in
            let recordingHits = transcriptByRecording[recordingId] ?? []
            let titleHit = titleByRecording[recordingId]?.sorted(by: hitOrder).first
            guard let recording = recordingHits.first?.recording ?? titleHit?.recording else {
                return nil
            }

            let moments = collapseNearbyHits(recordingHits).sorted(by: momentOrder)
            let score = conversationScore(moments: moments, titleHit: titleHit)
            return LibraryConversationSearchResult(
                recording: recording,
                moments: moments,
                titleHit: titleHit,
                score: score
            )
        }

        return Array(groups.sorted(by: conversationOrder).prefix(limit))
    }

    private static func collapseNearbyHits(
        _ hits: [LibrarySearchHit]
    ) -> [LibrarySearchMoment] {
        let chronological = hits.sorted {
            if $0.utterance.startTime != $1.utterance.startTime {
                return $0.utterance.startTime < $1.utterance.startTime
            }
            return $0.utterance.utteranceIndex < $1.utterance.utteranceIndex
        }
        guard !chronological.isEmpty else { return [] }

        var clusters: [[LibrarySearchHit]] = []
        for hit in chronological {
            guard var current = clusters.popLast() else {
                clusters.append([hit])
                continue
            }

            let first = current[0]
            let utteranceDistance = abs(
                hit.utterance.utteranceIndex - first.utterance.utteranceIndex
            )
            let timeDistance = hit.utterance.startTime - first.utterance.startTime
            if utteranceDistance <= nearbyUtteranceDistance
                || (timeDistance > 0 && timeDistance <= nearbyTimeDistance) {
                current.append(hit)
                clusters.append(current)
            } else {
                clusters.append(current)
                clusters.append([hit])
            }
        }

        return clusters.compactMap { cluster in
            guard let anchor = cluster.sorted(by: hitOrder).first else { return nil }
            return LibrarySearchMoment(
                hit: anchor,
                matchingHits: cluster.sorted(by: hitOrder),
                startTime: cluster.map(\.utterance.startTime).min() ?? anchor.utterance.startTime,
                endTime: cluster.map(\.utterance.endTime).max() ?? anchor.utterance.endTime
            )
        }
    }

    private static func conversationScore(
        moments: [LibrarySearchMoment],
        titleHit: LibrarySearchHit?
    ) -> Double {
        guard let best = moments.first else {
            return titleHit?.score ?? 0
        }

        var score = best.score
        if moments.count > 1 {
            score += moments[1].score * 0.20
        }
        if moments.count > 2 {
            score += moments[2].score * 0.10
        }
        if let titleHit {
            score += min(titleHit.score, best.score * 0.10)
        }
        return score
    }

    private static func conversationOrder(
        _ lhs: LibraryConversationSearchResult,
        _ rhs: LibraryConversationSearchResult
    ) -> Bool {
        if lhs.isTitleOnly != rhs.isTitleOnly {
            return !lhs.isTitleOnly
        }
        if lhs.score != rhs.score {
            return lhs.score > rhs.score
        }
        if lhs.recording.createdAt != rhs.recording.createdAt {
            return lhs.recording.createdAt > rhs.recording.createdAt
        }
        return lhs.id < rhs.id
    }

    private static func momentOrder(
        _ lhs: LibrarySearchMoment,
        _ rhs: LibrarySearchMoment
    ) -> Bool {
        if lhs.score != rhs.score {
            return lhs.score > rhs.score
        }
        if lhs.startTime != rhs.startTime {
            return lhs.startTime < rhs.startTime
        }
        return lhs.id < rhs.id
    }

    private static func hitOrder(
        _ lhs: LibrarySearchHit,
        _ rhs: LibrarySearchHit
    ) -> Bool {
        if lhs.score != rhs.score {
            return lhs.score > rhs.score
        }
        let lhsBestRank = min(lhs.keywordRank ?? .max, lhs.semanticRank ?? .max)
        let rhsBestRank = min(rhs.keywordRank ?? .max, rhs.semanticRank ?? .max)
        if lhsBestRank != rhsBestRank {
            return lhsBestRank < rhsBestRank
        }
        if lhs.utterance.startTime != rhs.utterance.startTime {
            return lhs.utterance.startTime < rhs.utterance.startTime
        }
        return lhs.id < rhs.id
    }
}
