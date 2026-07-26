import Foundation
import GRDB
import AlmRecorderMCPProtocol

/// The app-owned boundary for every MCP operation. The stdio bridge only translates
/// MCP messages; all database, model, permission, and mutation behavior stays here.
final class RecordingLibraryAPI: @unchecked Sendable {
    static let shared = RecordingLibraryAPI()

    struct Access: Sendable {
        let transcripts: Bool
        let writes: Bool
        let clientId: String
        let authorizationRevision: String
    }

    enum APIError: LocalizedError {
        case invalidArguments(String)
        case notFound(String)
        case forbidden(String)
        case unavailable(String)
        case conflict(String)

        var errorDescription: String? {
            switch self {
            case .invalidArguments(let message), .notFound(let message),
                 .forbidden(let message), .unavailable(let message),
                 .conflict(let message):
                return message
            }
        }

        var code: String {
            switch self {
            case .invalidArguments: return "invalid_arguments"
            case .notFound: return "not_found"
            case .forbidden: return "forbidden"
            case .unavailable: return "unavailable"
            case .conflict: return "conflict"
            }
        }
    }

    private let database = GRDBDatabaseManager.shared
    private let comments = GRDBRecordingCommentRepository()
    private let meetingNotes = GRDBMeetingNotesRepository()
    private let semanticSearch = SemanticSearchService.shared

    private init() {}

    func call(
        method: String,
        arguments: [String: MCPJSONValue],
        access: Access
    ) async throws -> MCPJSONValue {
        try Task.checkCancellation()
        if let definition = AlmRecorderMCPContract.tool(named: method) {
            do {
                try AlmRecorderMCPContract.validateToolArguments(
                    name: method,
                    arguments: arguments
                )
            } catch let error as MCPContractValidationError {
                throw APIError.invalidArguments(error.localizedDescription)
            }
            if definition.requiresContent {
                try requireContent(access)
            }
            if definition.requiresWrite {
                try requireWrites(access)
            }
        }

        let result: MCPJSONValue
        switch method {
        case "get_library_status":
            result = try libraryStatus(access: access)
        case "list_recordings":
            result = try listRecordings(arguments, access: access)
        case "get_recording":
            result = try getRecording(arguments, access: access)
        case "search_recordings":
            result = try await searchRecordings(arguments, access: access)
        case "list_tags":
            result = try listTags()
        case "get_meeting_notes":
            result = try getMeetingNotes(arguments)
        case "list_comments":
            result = try listComments(arguments)
        case "add_recording_tags":
            result = try mutateTags(arguments, add: true, access: access)
        case "remove_recording_tags":
            result = try mutateTags(arguments, add: false, access: access)
        case "update_meeting_notes":
            result = try updateMeetingNotes(arguments, access: access)
        case "add_comment":
            result = try addComment(arguments, access: access)
        case "update_comment":
            result = try updateComment(arguments, access: access)
        case "set_comment_status":
            result = try setCommentStatus(arguments, access: access)
        case "resources/list":
            result = try listResources(arguments)
        case "resources/read":
            result = try readResource(arguments, access: access)
        default:
            throw APIError.notFound("Unknown AlmRecorder MCP method: \(method)")
        }
        try Task.checkCancellation()
        if AlmRecorderMCPContract.tool(named: method) != nil {
            do {
                try AlmRecorderMCPContract.validateToolOutput(name: method, value: result)
            } catch let error as MCPContractValidationError {
                throw APIError.unavailable(
                    "AlmRecorder produced an invalid \(method) response: \(error.localizedDescription)"
                )
            }
        }
        return result
    }

    // MARK: - Read tools

    private func libraryStatus(access: Access) throws -> MCPJSONValue {
        try database.read { db in
            let recordingCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM recordings") ?? 0
            let tagCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tags") ?? 0
            let commentCount = access.transcripts
                ? (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM recording_comments") ?? 0)
                : nil
            let visibleUtteranceCount = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM utterances WHERE is_hidden = 0"
            ) ?? 0
            let indexedUtteranceCount = try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*)
                    FROM utterance_embeddings e
                    JOIN utterances u ON u.id = e.utterance_id
                    WHERE u.is_hidden = 0
                """
            ) ?? 0
            let coverage = visibleUtteranceCount == 0
                ? 1.0
                : min(1.0, Double(indexedUtteranceCount) / Double(visibleUtteranceCount))
            let semanticReady = EmbeddingModelManager.shared.isModelLoaded
                && (visibleUtteranceCount == 0 || indexedUtteranceCount > 0)
            let newest: Date? = try Date.fetchOne(
                db,
                sql: "SELECT MAX(created_at) FROM recordings"
            )
            return .object([
                "recording_count": .integer(Int64(recordingCount)),
                "tag_count": .integer(Int64(tagCount)),
                "comment_count": commentCount.map { .integer(Int64($0)) } ?? .null,
                "newest_recording_at": newest.map { .string(Self.dateString($0)) } ?? .null,
                "visible_utterance_count": access.transcripts
                    ? .integer(Int64(visibleUtteranceCount))
                    : .null,
                "indexed_utterance_count": access.transcripts
                    ? .integer(Int64(indexedUtteranceCount))
                    : .null,
                "index_coverage": access.transcripts ? .double(coverage) : .null,
                "semantic_search_ready": access.transcripts ? .bool(semanticReady) : .null,
                "semantic_search_note": .string(
                    !access.transcripts
                        ? "Enable content access to inspect transcript index coverage and semantic readiness."
                        : semanticReady
                        ? "The local embedding model is loaded; \(indexedUtteranceCount) of \(visibleUtteranceCount) visible utterances are indexed."
                        : "Keyword search is available. Semantic search requires an already-loaded model and a usable local index; MCP will not load or download one."
                ),
                "bridge_protocol_version": .integer(Int64(AlmRecorderMCP.protocolVersion))
            ])
        }
    }

    private func listRecordings(
        _ arguments: [String: MCPJSONValue],
        access: Access
    ) throws -> MCPJSONValue {
        if arguments["has_transcript"] != nil || arguments["has_open_comments"] != nil {
            try requireContent(access)
        }
        let limit = try Self.limit(arguments, default: 20, maximum: 100)
        let result = try queryRecordings(
            arguments,
            limit: limit + 1,
            includeTranscriptTextFilter: access.transcripts
        )
        let page = Array(result.prefix(limit))
        let nextCursor = result.count > limit ? page.last.flatMap(Self.cursor) : nil
        return .object([
            "recordings": .array(
                page.map { Self.recordingSummary($0, includeContent: access.transcripts) }
            ),
            "next_cursor": nextCursor.map(MCPJSONValue.string) ?? .null
        ])
    }

    private func getRecording(
        _ arguments: [String: MCPJSONValue],
        access: Access
    ) throws -> MCPJSONValue {
        let externalId = try Self.requiredString("recording_id", in: arguments)
        return try database.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM recordings WHERE external_id = ?",
                arguments: [externalId]
            ), let recording = Recording(row: row) else {
                throw APIError.notFound("Recording \(externalId) was not found.")
            }

            let tags = try Self.tags(db, recordingId: recording.id!)
            let speakers = try Self.speakers(db, recordingId: recording.id!)
            let meetings = try Self.meetings(db, recordingId: recording.id!)
            let commentCount = access.transcripts
                ? (try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM recording_comments WHERE recording_id = ?",
                    arguments: [recording.id!]
                ) ?? 0)
                : nil

            var object = Self.recordingSummary(
                recording,
                includeContent: access.transcripts
            ).objectValue ?? [:]
            object["tags"] = .array(tags.map(Self.tagValue))
            object["speakers"] = .array(speakers)
            object["meetings"] = .array(meetings)
            object["comment_count"] = commentCount.map { .integer(Int64($0)) } ?? .null
            object["comments_uri"] = access.transcripts
                ? .string("almrecorder://recordings/\(externalId)/comments")
                : .null
            object["transcript_uri"] = access.transcripts
                ? .string("almrecorder://recordings/\(externalId)/transcript")
                : .null
            object["content_access"] = .string(access.transcripts ? "enabled" : "disabled")
            return .object(object)
        }
    }

    private func searchRecordings(
        _ arguments: [String: MCPJSONValue],
        access: Access
    ) async throws -> MCPJSONValue {
        guard access.transcripts else {
            throw APIError.forbidden("Transcript search is disabled for this MCP client.")
        }
        let query = try Self.requiredString("query", in: arguments)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, query.count <= 2_000 else {
            throw APIError.invalidArguments("query must contain 1–2,000 characters.")
        }
        let limit = try Self.limit(arguments, default: 20, maximum: 50)
        let requestedMode = arguments["mode"]?.stringValue ?? "auto"
        let indexStats = try semanticIndexStats()
        let explicitMode: String?
        switch requestedMode {
        case "auto":
            explicitMode = nil
        case "keyword", "exact":
            explicitMode = "keyword"
        case "semantic", "ann", "hybrid":
            explicitMode = requestedMode
        default:
            throw APIError.invalidArguments(
                "mode must be auto, keyword, exact, semantic, ann, or hybrid."
            )
        }

        let candidates = try queryRecordings(
            arguments,
            limit: nil,
            includeTranscriptTextFilter: true
        )
        let recordingIds = Set(candidates.compactMap(\.id))
        let speakerIds = Self.speakerFilters(arguments)
        let eligibleStats = try scopedSemanticIndexStats(
            recordingIds: recordingIds,
            speakerIds: speakerIds
        )
        let selectedMode = explicitMode
            ?? (EmbeddingModelManager.shared.isModelLoaded && eligibleStats.indexed > 0
                ? "hybrid"
                : "keyword")
        if recordingIds.isEmpty {
            return .object([
                "query": .string(query),
                "mode_requested": .string(requestedMode),
                "mode": .string(selectedMode),
                "semantic_strategy": .string("not_used"),
                "results": .array([]),
                "semantic_search_ready": .bool(
                    EmbeddingModelManager.shared.isModelLoaded
                        && eligibleStats.indexed > 0
                ),
                "indexed_utterance_count": .integer(Int64(indexStats.indexed)),
                "visible_utterance_count": .integer(Int64(indexStats.visible)),
                "eligible_visible_utterance_count": .integer(Int64(eligibleStats.visible)),
                "eligible_indexed_utterance_count": .integer(Int64(eligibleStats.indexed)),
                "ann_candidates_examined": .integer(0),
                "index_coverage": .double(indexStats.coverage),
                "complete": .bool(true)
            ])
        }
        var exact: [SearchHit] = []
        var semantic: [SearchHit] = []
        var searchComplete = true
        var semanticStrategy = "not_used"
        var annCandidatesExamined = 0

        if selectedMode == "keyword" || selectedMode == "hybrid" {
            exact = try keywordSearch(
                query: query,
                recordingIds: recordingIds,
                speakerIds: speakerIds,
                limit: limit * 3
            )
        }
        if selectedMode == "semantic" || selectedMode == "ann" || selectedMode == "hybrid" {
            guard EmbeddingModelManager.shared.isModelLoaded else {
                throw APIError.unavailable(
                    "Semantic search requires a model already loaded in AlmRecorder. Open Models in Settings to load it; MCP will not download one implicitly."
                )
            }
            let semanticResponse = try await semanticSearch.searchInRecordings(
                query: query,
                recordingIds: Array(recordingIds),
                limit: min(max(limit * 3, 50), 500),
                loadModelIfNeeded: false,
                speakerIds: speakerIds,
                forceANN: selectedMode == "ann"
            )
            try Task.checkCancellation()
            searchComplete = semanticResponse.complete
            semanticStrategy = semanticResponse.strategy.rawValue
            annCandidatesExamined = semanticResponse.strategy == .ann
                ? semanticResponse.examinedCandidateCount
                : 0
            semantic = semanticResponse.results
                .filter {
                    !$0.utterance.isHidden
                        && (speakerIds.isEmpty
                            || $0.utterance.speakerUuid.map(speakerIds.contains) == true)
                }
                .map {
                    SearchHit(
                        utterance: $0.utterance,
                        recording: $0.recording,
                        score: Double($0.relevanceScore),
                        match: "semantic",
                        field: "transcript"
                    )
                }
        }

        var byUtterance: [String: SearchHit] = [:]
        if selectedMode == "hybrid" {
            // Reciprocal-rank fusion keeps backend-specific scores from being compared directly.
            for (rank, hit) in exact.enumerated() {
                byUtterance[hit.identity] = SearchHit(
                    utterance: hit.utterance,
                    recording: hit.recording,
                    score: 1.0 / Double(60 + rank + 1),
                    match: "keyword",
                    field: hit.field
                )
            }
            for (rank, hit) in semantic.enumerated() {
                let contribution = 1.0 / Double(60 + rank + 1)
                if let current = byUtterance[hit.identity] {
                    byUtterance[hit.identity] = SearchHit(
                        utterance: hit.utterance,
                        recording: hit.recording,
                        score: current.score + contribution,
                        match: "hybrid",
                        field: hit.field
                    )
                } else {
                    byUtterance[hit.identity] = SearchHit(
                        utterance: hit.utterance,
                        recording: hit.recording,
                        score: contribution,
                        match: "semantic",
                        field: hit.field
                    )
                }
            }
        } else {
            for hit in exact + semantic {
                byUtterance[hit.identity] = hit
            }
        }
        let hits = byUtterance.values.sorted {
            $0.score == $1.score
                ? $0.recording.createdAt > $1.recording.createdAt
                : $0.score > $1.score
        }.prefix(limit)

        return .object([
            "query": .string(query),
            "mode_requested": .string(requestedMode),
            "mode": .string(selectedMode),
            "semantic_strategy": .string(semanticStrategy),
            "results": .array(hits.map(Self.searchHitValue)),
            "semantic_search_ready": .bool(
                EmbeddingModelManager.shared.isModelLoaded
                    && (eligibleStats.visible == 0 || eligibleStats.indexed > 0)
            ),
            "indexed_utterance_count": .integer(Int64(indexStats.indexed)),
            "visible_utterance_count": .integer(Int64(indexStats.visible)),
            "eligible_visible_utterance_count": .integer(Int64(eligibleStats.visible)),
            "eligible_indexed_utterance_count": .integer(Int64(eligibleStats.indexed)),
            "ann_candidates_examined": .integer(Int64(annCandidatesExamined)),
            "index_coverage": .double(indexStats.coverage),
            "complete": .bool(searchComplete)
        ])
    }

    private func listTags() throws -> MCPJSONValue {
        try database.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT t.*, COUNT(rt.recording_id) AS recording_count
                    FROM tags t
                    LEFT JOIN recording_tags rt ON rt.tag_id = t.id
                    GROUP BY t.id
                    ORDER BY LOWER(t.name)
                """
            )
            return .object([
                "tags": .array(rows.compactMap { row in
                    guard let tag = Tag(row: row) else { return nil }
                    var value = Self.tagValue(tag).objectValue ?? [:]
                    let count: Int = row["recording_count"] ?? 0
                    value["recording_count"] = .integer(Int64(count))
                    return .object(value)
                })
            ])
        }
    }

    private func getMeetingNotes(_ arguments: [String: MCPJSONValue]) throws -> MCPJSONValue {
        let eventIds = try resolveEventIds(arguments)
        return .object([
            "meetings": .array(try eventIds.map { try meetingNotesValue($0) })
        ])
    }

    private func listComments(_ arguments: [String: MCPJSONValue]) throws -> MCPJSONValue {
        let recordingId = try Self.requiredString("recording_id", in: arguments)
        let status: RecordingComment.Status?
        if let raw = arguments["status"]?.stringValue {
            guard let parsed = RecordingComment.Status(rawValue: raw) else {
                throw APIError.invalidArguments("status must be open or resolved.")
            }
            status = parsed
        } else {
            status = nil
        }
        do {
            let matchingComments = try comments.list(
                recordingExternalId: recordingId,
                status: status
            )
            return .object([
                "recording_id": .string(recordingId),
                "comments": .array(matchingComments.map(Self.commentValue))
            ])
        } catch {
            throw Self.mapCommentError(error)
        }
    }

    // MARK: - Mutation tools

    private func mutateTags(
        _ arguments: [String: MCPJSONValue],
        add: Bool,
        access: Access
    ) throws -> MCPJSONValue {
        try requireWrites(access)
        let recordingExternalId = try Self.requiredString("recording_id", in: arguments)
        guard let identifiers = arguments["tags"]?.arrayValue?.compactMap(\.stringValue),
              !identifiers.isEmpty, identifiers.count <= 100 else {
            throw APIError.invalidArguments("tags must be a non-empty array of at most 100 tag IDs or names.")
        }
        return try database.write { db in
            guard MCPAuthorizationStore.shared.remainsAuthorized(
                access,
                write: true
            ) else {
                throw APIError.forbidden("Write access was revoked before the tag change committed.")
            }
            guard let recordingRow = try Row.fetchOne(
                db,
                sql: "SELECT id, updated_at FROM recordings WHERE external_id = ?",
                arguments: [recordingExternalId]
            ) else {
                throw APIError.notFound("Recording \(recordingExternalId) was not found.")
            }
            let recordingId: Int64 = recordingRow["id"]
            let previousUpdatedAt: Date? = recordingRow["updated_at"]

            var changed: [Tag] = []
            for identifier in identifiers {
                guard let row = try Row.fetchOne(
                    db,
                    sql: "SELECT * FROM tags WHERE external_id = ? OR LOWER(name) = LOWER(?)",
                    arguments: [identifier, identifier]
                ), let tag = Tag(row: row), let tagId = tag.id else {
                    throw APIError.notFound("Tag \(identifier) was not found.")
                }
                try db.execute(
                    sql: add
                        ? "INSERT OR IGNORE INTO recording_tags (recording_id, tag_id) VALUES (?, ?)"
                        : "DELETE FROM recording_tags WHERE recording_id = ? AND tag_id = ?",
                    arguments: [recordingId, tagId]
                )
                if db.changesCount > 0 { changed.append(tag) }
            }
            let now = Date()
            if !changed.isEmpty {
                try db.execute(
                    sql: "UPDATE recordings SET updated_at = ? WHERE id = ?",
                    arguments: [now, recordingId]
                )
            }
            let effectiveUpdatedAt = changed.isEmpty
                ? (previousUpdatedAt ?? now)
                : now
            return .object([
                "recording_id": .string(recordingExternalId),
                add ? "added" : "removed": .array(changed.map(Self.tagValue)),
                "tags": .array(try Self.tags(db, recordingId: recordingId).map(Self.tagValue)),
                "updated_at": .string(Self.dateString(effectiveUpdatedAt))
            ])
        }
    }

    private func updateMeetingNotes(
        _ arguments: [String: MCPJSONValue],
        access: Access
    ) throws -> MCPJSONValue {
        try requireContent(access)
        try requireWrites(access)
        let eventId = try Self.requiredString("calendar_event_id", in: arguments)
        guard arguments.keys.contains("agenda") || arguments.keys.contains("notes") else {
            throw APIError.invalidArguments("Provide agenda and/or notes to update.")
        }
        let meetingExists = try database.read { db in
            try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM meetings WHERE calendar_event_id = ?)",
                arguments: [eventId]
            ) ?? false
        }
        guard meetingExists else {
            throw APIError.notFound("Calendar event \(eventId) was not found.")
        }
        let existing = try meetingNotes.getThrowing(eventId: eventId)
        let agenda = arguments["agenda"]?.stringValue ?? existing.agenda
        let notes = arguments["notes"]?.stringValue ?? existing.notes
        let ifUpdatedAt = try Self.optionalDate("if_updated_at", in: arguments)
        do {
            let updated = try meetingNotes.upsert(
                eventId: eventId,
                agenda: agenda,
                notes: notes,
                ifUpdatedAt: ifUpdatedAt,
                authorize: {
                    MCPAuthorizationStore.shared.remainsAuthorized(
                        access,
                        content: true,
                        write: true
                    )
                }
            )
            return try meetingNotesValue(eventId, notes: updated)
        } catch GRDBMeetingNotesRepository.MeetingNotesError.conflict {
            throw APIError.conflict("Meeting notes changed since they were read. Read them again before updating.")
        } catch GRDBMeetingNotesRepository.MeetingNotesError.authorizationRevoked {
            throw APIError.forbidden("Content or write access was revoked before the note change committed.")
        } catch GRDBMeetingNotesRepository.MeetingNotesError.contentTooLarge {
            throw APIError.invalidArguments("Meeting notes exceed the documented size limit.")
        }
    }

    private func addComment(
        _ arguments: [String: MCPJSONValue],
        access: Access
    ) throws -> MCPJSONValue {
        try requireContent(access)
        try requireWrites(access)
        let recordingId = try Self.requiredString("recording_id", in: arguments)
        let body = try Self.requiredString("body", in: arguments)
        do {
            let comment = try comments.create(
                recordingExternalId: recordingId,
                body: body,
                anchorStart: arguments["anchor_start"]?.doubleValue,
                anchorEnd: arguments["anchor_end"]?.doubleValue,
                sourceUtteranceId: arguments["source_utterance_id"]?.integerValue,
                createdBy: access.clientId,
                idempotencyKey: arguments["idempotency_key"]?.stringValue,
                authorize: {
                    MCPAuthorizationStore.shared.remainsAuthorized(
                        access,
                        content: true,
                        write: true
                    )
                }
            )
            return Self.commentValue(comment)
        } catch {
            throw Self.mapCommentError(error)
        }
    }

    private func updateComment(
        _ arguments: [String: MCPJSONValue],
        access: Access
    ) throws -> MCPJSONValue {
        try requireContent(access)
        try requireWrites(access)
        let id = try Self.requiredString("comment_id", in: arguments)
        let changesStart = arguments.keys.contains("anchor_start")
        let changesEnd = arguments.keys.contains("anchor_end")
        guard arguments["body"]?.stringValue != nil || changesStart || changesEnd else {
            throw APIError.invalidArguments("Provide body and/or timestamp anchors to update.")
        }
        do {
            return Self.commentValue(try comments.update(
                id: id,
                body: arguments["body"]?.stringValue,
                anchorStart: changesStart
                    ? .set(arguments["anchor_start"]?.doubleValue)
                    : .unchanged,
                anchorEnd: changesEnd
                    ? .set(arguments["anchor_end"]?.doubleValue)
                    : .unchanged,
                ifUpdatedAt: try Self.optionalDate("if_updated_at", in: arguments),
                authorize: {
                    MCPAuthorizationStore.shared.remainsAuthorized(
                        access,
                        content: true,
                        write: true
                    )
                }
            ))
        } catch {
            throw Self.mapCommentError(error)
        }
    }

    private func setCommentStatus(
        _ arguments: [String: MCPJSONValue],
        access: Access
    ) throws -> MCPJSONValue {
        try requireContent(access)
        try requireWrites(access)
        let id = try Self.requiredString("comment_id", in: arguments)
        let raw = try Self.requiredString("status", in: arguments)
        guard let status = RecordingComment.Status(rawValue: raw) else {
            throw APIError.invalidArguments("status must be open or resolved.")
        }
        do {
            return Self.commentValue(try comments.setStatus(
                id: id,
                status: status,
                ifUpdatedAt: try Self.optionalDate("if_updated_at", in: arguments),
                authorize: {
                    MCPAuthorizationStore.shared.remainsAuthorized(
                        access,
                        content: true,
                        write: true
                    )
                }
            ))
        } catch {
            throw Self.mapCommentError(error)
        }
    }

    // MARK: - Resources

    private func listResources(_ arguments: [String: MCPJSONValue]) throws -> MCPJSONValue {
        let cursor = arguments["cursor"]?.stringValue
        let queryArguments = cursor.map { ["cursor": MCPJSONValue.string($0)] } ?? [:]
        let pageSize = 25
        let recordings = try queryRecordings(
            queryArguments,
            limit: pageSize + 1,
            includeTranscriptTextFilter: false
        )
        let page = Array(recordings.prefix(pageSize))
        var resources: [MCPJSONValue] = []
        if cursor == nil {
            resources = [
                .object([
                    "uri": .string("almrecorder://help"),
                    "name": .string("AlmRecorder MCP help"),
                    "description": .string("Search modes, filters, permissions, pagination, and recovery"),
                    "mime_type": .string("application/json")
                ]),
                .object([
                    "uri": .string("almrecorder://tags"),
                    "name": .string("AlmRecorder tags"),
                    "description": .string("All recording tags and their usage counts"),
                    "mime_type": .string("application/json")
                ])
            ]
        }
        for recording in page {
            guard let externalId = recording.externalId else { continue }
            resources.append(.object([
                "uri": .string("almrecorder://recordings/\(externalId)"),
                "name": .string(recording.title),
                "description": .string("Recording summary from \(Self.dateString(recording.createdAt))"),
                "mime_type": .string("application/json")
            ]))
        }
        let nextCursor = recordings.count > pageSize ? page.last.flatMap(Self.cursor) : nil
        return .object([
            "resources": .array(resources),
            "next_cursor": nextCursor.map(MCPJSONValue.string) ?? .null
        ])
    }

    private func readResource(
        _ arguments: [String: MCPJSONValue],
        access: Access
    ) throws -> MCPJSONValue {
        let uri = try Self.requiredString("uri", in: arguments)
        if uri == "almrecorder://help" {
            return Self.helpResource()
        }
        if uri == "almrecorder://tags" {
            return try listTags()
        }
        guard let components = URLComponents(string: uri),
              components.scheme == "almrecorder",
              components.host == "recordings" else {
            throw APIError.notFound("Unsupported AlmRecorder resource URI.")
        }
        let parts = components.path.split(separator: "/").map(String.init)
        guard let recordingId = parts.first else {
            throw APIError.notFound("Recording resource URI is missing an ID.")
        }
        if parts.count == 1 {
            return try getRecording(["recording_id": .string(recordingId)], access: access)
        }
        switch parts[1] {
        case "transcript":
            guard access.transcripts else {
                throw APIError.forbidden("Transcript resources are disabled for this MCP client.")
            }
            return try database.read { db in
                guard let id = try Int64.fetchOne(
                    db,
                    sql: "SELECT id FROM recordings WHERE external_id = ?",
                    arguments: [recordingId]
                ) else {
                    throw APIError.notFound("Recording \(recordingId) was not found.")
                }
                return .object([
                    "recording_id": .string(recordingId),
                    "utterances": .array(try Self.utterances(db, recordingId: id))
                ])
            }
        case "comments":
            try requireContent(access)
            return try listComments(["recording_id": .string(recordingId)])
        default:
            throw APIError.notFound("Unsupported recording resource URI.")
        }
    }

    // MARK: - Queries and mapping

    private func queryRecordings(
        _ arguments: [String: MCPJSONValue],
        limit: Int?,
        includeTranscriptTextFilter: Bool
    ) throws -> [Recording] {
        try database.read { db in
            var sql = "SELECT DISTINCT r.* FROM recordings r"
            var conditions: [String] = []
            var values: [DatabaseValueConvertible?] = []

            if let suppliedTags = arguments["tags"]?.arrayValue?.compactMap(\.stringValue),
               !suppliedTags.isEmpty {
                let tags = Array(Set(suppliedTags))
                let placeholders = tags.map { _ in "?" }.joined(separator: ",")
                let match = arguments["tag_match"]?.stringValue ?? "all"
                guard match == "all" || match == "any" else {
                    throw APIError.invalidArguments("tag_match must be all or any.")
                }
                conditions.append("""
                    r.id IN (
                        SELECT rt.recording_id
                        FROM recording_tags rt
                        JOIN tags t ON t.id = rt.tag_id
                        WHERE t.external_id IN (\(placeholders))
                           OR LOWER(t.name) IN (\(placeholders))
                        GROUP BY rt.recording_id
                        \(match == "all" ? "HAVING COUNT(DISTINCT t.id) = ?" : "")
                    )
                """)
                values.append(contentsOf: tags)
                values.append(contentsOf: tags.map { $0.lowercased() })
                if match == "all" { values.append(tags.count) }
            }
            let speakers = Self.speakerFilters(arguments)
            if !speakers.isEmpty {
                let placeholders = speakers.map { _ in "?" }.joined(separator: ",")
                conditions.append("""
                    EXISTS (
                        SELECT 1 FROM utterances u
                        WHERE u.recording_id = r.id
                          AND u.speaker_uuid IN (\(placeholders))
                          AND u.is_hidden = 0
                    )
                """)
                values.append(contentsOf: speakers)
            }
            let sources = Self.sourceFilters(arguments)
            if !sources.isEmpty {
                for source in sources where Recording.RecordingSource(rawValue: source) == nil {
                    throw APIError.invalidArguments("Unknown recording source \(source).")
                }
                let placeholders = sources.map { _ in "?" }.joined(separator: ",")
                conditions.append("r.source IN (\(placeholders))")
                values.append(contentsOf: sources)
            }
            if let eventIds = arguments["calendar_event_ids"]?.arrayValue?.compactMap(\.stringValue),
               !eventIds.isEmpty {
                let ids = Array(Set(eventIds))
                let placeholders = ids.map { _ in "?" }.joined(separator: ",")
                conditions.append("""
                    EXISTS (
                        SELECT 1
                        FROM recording_meetings filter_rm
                        JOIN meetings filter_m ON filter_m.id = filter_rm.meeting_id
                        WHERE filter_rm.recording_id = r.id
                          AND filter_rm.is_dismissed = 0
                          AND filter_m.calendar_event_id IN (\(placeholders))
                    )
                """)
                values.append(contentsOf: ids)
            }
            if let hasTranscript = arguments["has_transcript"]?.boolValue {
                conditions.append("""
                    \(hasTranscript ? "" : "NOT ")EXISTS (
                        SELECT 1 FROM utterances transcript_u
                        WHERE transcript_u.recording_id = r.id
                          AND transcript_u.is_hidden = 0
                    )
                """)
            }
            if let hasOpenComments = arguments["has_open_comments"]?.boolValue {
                conditions.append("""
                    \(hasOpenComments ? "" : "NOT ")EXISTS (
                        SELECT 1 FROM recording_comments filter_c
                        WHERE filter_c.recording_id = r.id
                          AND filter_c.status = 'open'
                    )
                """)
            }
            if let query = arguments["text"]?.stringValue, !query.isEmpty {
                let likeQuery = "%\(Self.escapedLike(query))%"
                if includeTranscriptTextFilter {
                    conditions.append("""
                        (
                            r.title LIKE ? ESCAPE '\\'
                            OR EXISTS (
                                SELECT 1 FROM utterances text_u
                                WHERE text_u.recording_id = r.id
                                  AND text_u.is_hidden = 0
                                  AND text_u.text LIKE ? ESCAPE '\\'
                            )
                        )
                    """)
                    values.append(likeQuery)
                    values.append(likeQuery)
                } else {
                    conditions.append("r.title LIKE ? ESCAPE '\\'")
                    values.append(likeQuery)
                }
            }
            let from = try Self.optionalDate("date_from", in: arguments)
            let to = try Self.optionalDate("date_to", in: arguments)
            if let from, let to, from > to {
                throw APIError.invalidArguments("date_from must be earlier than or equal to date_to.")
            }
            if let from {
                conditions.append("r.created_at >= ?")
                values.append(from)
            }
            if let to {
                conditions.append("r.created_at <= ?")
                values.append(to)
            }
            if let cursor = arguments["cursor"]?.stringValue {
                let decoded = try Self.decodeCursor(cursor)
                conditions.append("(r.created_at < ? OR (r.created_at = ? AND r.id < ?))")
                values.append(decoded.date)
                values.append(decoded.date)
                values.append(decoded.id)
            }

            if !conditions.isEmpty {
                sql += " WHERE " + conditions.joined(separator: " AND ")
            }
            sql += " ORDER BY r.created_at DESC, r.id DESC"
            if let limit {
                sql += " LIMIT ?"
                values.append(limit)
            }
            return try Row.fetchAll(
                db,
                sql: sql,
                arguments: StatementArguments(values)
            ).compactMap(Recording.init(row:))
        }
    }

    private struct SearchHit {
        let utterance: Utterance
        let recording: Recording
        let score: Double
        let match: String
        let field: String

        var identity: String {
            if let id = utterance.id { return "utterance:\(id)" }
            return "recording:\(recording.id ?? 0):\(field)"
        }
    }

    private func keywordSearch(
        query: String,
        recordingIds: Set<Int64>,
        speakerIds: [String],
        limit: Int
    ) throws -> [SearchHit] {
        guard !recordingIds.isEmpty else { return [] }
        guard let pattern = FTS5Pattern(matchingAllTokensIn: query) else {
            throw APIError.invalidArguments("query must contain at least one searchable token.")
        }
        return try database.read { db in
            let placeholders = recordingIds.map { _ in "?" }.joined(separator: ",")
            let speakerPlaceholders = speakerIds.map { _ in "?" }.joined(separator: ",")
            var arguments: [DatabaseValueConvertible?] = Array(recordingIds)
            arguments.append(pattern)
            arguments.append(contentsOf: speakerIds)
            arguments.append(limit)
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT u.*, bm25(utterance_fts) AS mcp_fts_rank
                    FROM utterance_fts
                    JOIN utterances u ON u.id = utterance_fts.rowid
                    JOIN recordings r ON r.id = u.recording_id
                    WHERE u.recording_id IN (\(placeholders))
                      AND u.is_hidden = 0
                      AND utterance_fts MATCH ?
                      \(speakerIds.isEmpty ? "" : "AND u.speaker_uuid IN (\(speakerPlaceholders))")
                    ORDER BY mcp_fts_rank, r.created_at DESC, u.utterance_index
                    LIMIT ?
                """,
                arguments: StatementArguments(arguments)
            )
            var hits = rows.compactMap { row -> SearchHit? in
                guard let utterance = Utterance(row: row),
                      let recordingRow = try? Row.fetchOne(
                        db,
                        sql: "SELECT * FROM recordings WHERE id = ?",
                        arguments: [utterance.recordingId]
                      ),
                      let recording = Recording(row: recordingRow) else { return nil }
                let rank: Double = row["mcp_fts_rank"] ?? 0
                return SearchHit(
                    utterance: utterance,
                    recording: recording,
                    score: max(0, -rank),
                    match: "keyword",
                    field: "transcript"
                )
            }

            // A speaker-scoped query cannot attribute a recording-title hit to that speaker.
            // Omit title-only matches rather than returning a hit that violates the filter.
            if speakerIds.isEmpty {
                var titleArguments: [DatabaseValueConvertible?] = Array(recordingIds)
                titleArguments.append(pattern)
                titleArguments.append(limit)
                let titleRows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT r.*, bm25(recording_title_fts, 5.0) AS mcp_fts_rank
                        FROM recording_title_fts
                        JOIN recordings r ON r.id = recording_title_fts.rowid
                        WHERE r.id IN (\(placeholders))
                          AND recording_title_fts MATCH ?
                        ORDER BY mcp_fts_rank, r.created_at DESC
                        LIMIT ?
                    """,
                    arguments: StatementArguments(titleArguments)
                )
                hits.append(contentsOf: titleRows.compactMap { row -> SearchHit? in
                    guard let recording = Recording(row: row), let recordingId = recording.id else {
                        return nil
                    }
                    let rank: Double = row["mcp_fts_rank"] ?? 0
                    let titleUtterance = Utterance(
                        id: nil,
                        recordingId: recordingId,
                        utteranceIndex: -1,
                        startTime: 0,
                        endTime: 0,
                        speaker: nil,
                        speakerUuid: nil,
                        text: recording.title,
                        confidence: nil
                    )
                    return SearchHit(
                        utterance: titleUtterance,
                        recording: recording,
                        score: 1 + max(0, -rank),
                        match: "keyword",
                        field: "title"
                    )
                })
            }
            return Array(
                hits.sorted {
                    $0.score == $1.score
                        ? $0.recording.createdAt > $1.recording.createdAt
                        : $0.score > $1.score
                }.prefix(limit)
            )
        }
    }

    private func semanticIndexStats() throws -> (visible: Int, indexed: Int, coverage: Double) {
        try database.read { db in
            let visible = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM utterances WHERE is_hidden = 0"
            ) ?? 0
            let indexed = try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*)
                    FROM utterance_embeddings e
                    JOIN utterances u ON u.id = e.utterance_id
                    WHERE u.is_hidden = 0
                """
            ) ?? 0
            let coverage = visible == 0 ? 1.0 : min(1.0, Double(indexed) / Double(visible))
            return (visible, indexed, coverage)
        }
    }

    private func scopedSemanticIndexStats(
        recordingIds: Set<Int64>,
        speakerIds: [String]
    ) throws -> (visible: Int, indexed: Int) {
        guard !recordingIds.isEmpty else { return (0, 0) }
        return try database.read { db in
            let recordings = recordingIds.map(String.init).joined(separator: ",")
            let speakerPlaceholders = speakerIds.map { _ in "?" }.joined(separator: ",")
            let speakerClause = speakerIds.isEmpty
                ? ""
                : "AND u.speaker_uuid IN (\(speakerPlaceholders))"
            let statementArguments = StatementArguments(speakerIds)
            let visible = try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*)
                    FROM utterances u
                    WHERE u.is_hidden = 0
                      AND u.recording_id IN (\(recordings))
                      \(speakerClause)
                """,
                arguments: statementArguments
            ) ?? 0
            let indexed = try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*)
                    FROM utterance_embeddings e
                    JOIN utterances u ON u.id = e.utterance_id
                    WHERE u.is_hidden = 0
                      AND u.recording_id IN (\(recordings))
                      \(speakerClause)
                """,
                arguments: statementArguments
            ) ?? 0
            return (visible, indexed)
        }
    }

    private func resolveEventIds(_ arguments: [String: MCPJSONValue]) throws -> [String] {
        let eventId = arguments["calendar_event_id"]?.stringValue
        let recordingId = arguments["recording_id"]?.stringValue
        guard (eventId == nil) != (recordingId == nil) else {
            throw APIError.invalidArguments(
                "Provide exactly one of calendar_event_id or recording_id."
            )
        }
        if let eventId {
            return [eventId]
        }
        let recordingExternalId = recordingId!
        let ids = try database.read { db in
            try String.fetchAll(
                db,
                sql: """
                    SELECT m.calendar_event_id
                    FROM meetings m
                    JOIN recording_meetings rm ON rm.meeting_id = m.id
                    JOIN recordings r ON r.id = rm.recording_id
                    WHERE r.external_id = ? AND rm.is_dismissed = 0
                    ORDER BY m.start_date
                """,
                arguments: [recordingExternalId]
            )
        }
        if ids.isEmpty {
            throw APIError.notFound("No linked calendar meeting was found for \(recordingExternalId).")
        }
        return ids
    }

    private func meetingNotesValue(
        _ eventId: String,
        notes supplied: GRDBMeetingNotesRepository.MeetingNotes? = nil
    ) throws -> MCPJSONValue {
        guard let meeting = try database.read({ db in
            try Row.fetchOne(
                db,
                sql: """
                    SELECT title, start_date, end_date
                    FROM meetings WHERE calendar_event_id = ?
                """,
                arguments: [eventId]
            )
        }) else {
            throw APIError.notFound("Calendar event \(eventId) was not found.")
        }
        let notes: GRDBMeetingNotesRepository.MeetingNotes
        if let supplied {
            notes = supplied
        } else {
            notes = try meetingNotes.getThrowing(eventId: eventId)
        }
        return .object([
            "calendar_event_id": .string(eventId),
            "title": (meeting["title"] as String?).map(MCPJSONValue.string) ?? .null,
            "start_at": (meeting["start_date"] as Date?).map { .string(Self.dateString($0)) } ?? .null,
            "end_at": (meeting["end_date"] as Date?).map { .string(Self.dateString($0)) } ?? .null,
            "agenda": .string(notes.agenda),
            "notes": .string(notes.notes),
            "updated_at": notes.updatedAt.map { .string(Self.dateString($0)) } ?? .null
        ])
    }

    private static func recordingSummary(
        _ recording: Recording,
        includeContent: Bool
    ) -> MCPJSONValue {
        // v38 makes this a database invariant for every row exposed through MCP.
        let externalId = recording.externalId!
        return .object([
            "id": .string(externalId),
            "title": .string(recording.title),
            "created_at": .string(dateString(recording.createdAt)),
            "updated_at": recording.updatedAt.map { .string(dateString($0)) } ?? .null,
            "duration_seconds": recording.duration.map(MCPJSONValue.double) ?? .null,
            "language": recording.language.map(MCPJSONValue.string) ?? .null,
            "source": .string(recording.source.rawValue),
            "summary": includeContent
                ? (recording.metadata?.summary.map(MCPJSONValue.string) ?? .null)
                : .null,
            "topics": .array(
                includeContent
                    ? (recording.metadata?.topics ?? []).map(MCPJSONValue.string)
                    : []
            ),
            "uri": .string("almrecorder://recordings/\(externalId)")
        ])
    }

    private static func helpResource() -> MCPJSONValue {
        .object([
            "server_version": .string(AlmRecorderMCP.serverVersion),
            "search_modes": .object([
                "keyword": .string("FTS5/BM25 lexical search over visible transcript text and titles."),
                "exact": .string("Deprecated alias for keyword; it is not literal string equality."),
                "semantic": .string("Vector-only search; exact cosine is used for small filtered sets."),
                "ann": .string("Vector-only HNSW ANN; inspect complete and ann_candidates_examined."),
                "hybrid": .string("Reciprocal-rank fusion of keyword and vector ranks."),
                "auto": .string("Hybrid when a loaded model and usable filtered index are ready; otherwise keyword.")
            ]),
            "filters": .object([
                "combination": .string("Filter categories combine with AND."),
                "tags": .string("tags uses tag_match=all by default; set any for OR semantics."),
                "arrays": .string("sources, speaker_ids, and calendar_event_ids match any supplied value."),
                "speaker_scope": .string("Speaker filters constrain returned transcript hits, including ANN."),
                "dates": .string("date_from and date_to are inclusive ISO-8601 timestamps."),
                "content_filters": .string("text, has_transcript, and has_open_comments may require content access.")
            ]),
            "permissions": .object([
                "metadata": .string("Enabled MCP can read titles, dates, tags, speakers, and meeting linkage."),
                "content": .string("Required for transcript text/search, summaries, notes, and comments."),
                "write": .string("Required in addition to content where a note/comment write touches content.")
            ]),
            "pagination": .string(
                "For list_recordings and resources/list, pass next_cursor unchanged with the same filters."
            ),
            "recovery": .object([
                "conflict": .string("Re-read the note/comment, then retry with its latest if_updated_at."),
                "rate_limited": .string("Wait for current local work to finish, then retry."),
                "unavailable": .string("Check get_library_status; MCP never loads or downloads a model."),
                "cancelled": .string("The request stopped; retry only if the operation is still desired.")
            ])
        ])
    }

    private static func tagValue(_ tag: Tag) -> MCPJSONValue {
        .object([
            "id": .string(tag.externalId!),
            "name": .string(tag.name),
            "color": tag.color.map(MCPJSONValue.string) ?? .null,
            "description": tag.description.map(MCPJSONValue.string) ?? .null,
            "updated_at": tag.updatedAt.map { .string(dateString($0)) } ?? .null
        ])
    }

    private static func commentValue(_ comment: RecordingComment) -> MCPJSONValue {
        .object([
            "id": .string(comment.id),
            "body": .string(comment.body),
            "anchor_start": comment.anchorStart.map(MCPJSONValue.double) ?? .null,
            "anchor_end": comment.anchorEnd.map(MCPJSONValue.double) ?? .null,
            "source_utterance_id": comment.sourceUtteranceId.map(MCPJSONValue.integer) ?? .null,
            "status": .string(comment.status.rawValue),
            "created_by": .string(comment.createdBy),
            "created_at": .string(dateString(comment.createdAt)),
            "updated_at": .string(dateString(comment.updatedAt)),
            "resolved_at": comment.resolvedAt.map { .string(dateString($0)) } ?? .null
        ])
    }

    private static func searchHitValue(_ hit: SearchHit) -> MCPJSONValue {
        let recordingId = hit.recording.externalId!
        return .object([
            "recording_id": .string(recordingId),
            "recording_title": .string(hit.recording.title),
            "recorded_at": .string(dateString(hit.recording.createdAt)),
            "utterance_id": hit.utterance.id.map(MCPJSONValue.integer) ?? .null,
            "start_time": .double(hit.utterance.startTime),
            "end_time": .double(hit.utterance.endTime),
            "speaker": hit.utterance.speaker.map(MCPJSONValue.string) ?? .null,
            "speaker_id": hit.utterance.speakerUuid.map(MCPJSONValue.string) ?? .null,
            "text": .string(hit.utterance.text),
            "score": .double(hit.score),
            "match": .string(hit.match),
            "match_field": .string(hit.field),
            "recording_uri": .string("almrecorder://recordings/\(recordingId)"),
            "transcript_uri": .string("almrecorder://recordings/\(recordingId)/transcript")
        ])
    }

    private static func utterances(_ db: Database, recordingId: Int64) throws -> [MCPJSONValue] {
        try Row.fetchAll(
            db,
            sql: """
                SELECT u.*, COALESCE(s.name, u.speaker) AS display_speaker
                FROM utterances u
                LEFT JOIN speakers s ON s.uuid = u.speaker_uuid
                WHERE u.recording_id = ? AND u.is_hidden = 0
                ORDER BY u.utterance_index
            """,
            arguments: [recordingId]
        ).map { row in
            let id: Int64? = row["id"]
            let start: Double = row["start_time"]
            let end: Double = row["end_time"]
            let text: String = row["text"]
            let speaker: String? = row["display_speaker"]
            let speakerId: String? = row["speaker_uuid"]
            return .object([
                "id": id.map(MCPJSONValue.integer) ?? .null,
                "start_time": .double(start),
                "end_time": .double(end),
                "speaker": speaker.map(MCPJSONValue.string) ?? .null,
                "speaker_id": speakerId.map(MCPJSONValue.string) ?? .null,
                "text": .string(text)
            ])
        }
    }

    private static func tags(_ db: Database, recordingId: Int64) throws -> [Tag] {
        try Row.fetchAll(
            db,
            sql: """
                SELECT t.* FROM tags t
                JOIN recording_tags rt ON rt.tag_id = t.id
                WHERE rt.recording_id = ?
                ORDER BY LOWER(t.name)
            """,
            arguments: [recordingId]
        ).compactMap(Tag.init(row:))
    }

    private static func speakers(_ db: Database, recordingId: Int64) throws -> [MCPJSONValue] {
        try Row.fetchAll(
            db,
            sql: """
                SELECT u.speaker_uuid, COALESCE(s.name, u.speaker) AS name,
                       COUNT(*) AS utterance_count
                FROM utterances u
                LEFT JOIN speakers s ON s.uuid = u.speaker_uuid
                WHERE u.recording_id = ? AND u.is_hidden = 0
                GROUP BY u.speaker_uuid, COALESCE(s.name, u.speaker)
                ORDER BY utterance_count DESC
            """,
            arguments: [recordingId]
        ).map { row in
            let uuid: String? = row["speaker_uuid"]
            let name: String? = row["name"]
            let count: Int = row["utterance_count"]
            return .object([
                "id": uuid.map(MCPJSONValue.string) ?? .null,
                "name": name.map(MCPJSONValue.string) ?? .string("Unknown"),
                "utterance_count": .integer(Int64(count))
            ])
        }
    }

    private static func meetings(_ db: Database, recordingId: Int64) throws -> [MCPJSONValue] {
        try Row.fetchAll(
            db,
            sql: """
                SELECT m.calendar_event_id, m.title, m.start_date, m.end_date
                FROM meetings m
                JOIN recording_meetings rm ON rm.meeting_id = m.id
                WHERE rm.recording_id = ? AND rm.is_dismissed = 0
                ORDER BY m.start_date
            """,
            arguments: [recordingId]
        ).map { row in
            let eventId: String = row["calendar_event_id"]
            let title: String = row["title"]
            let start: Date = row["start_date"]
            let end: Date = row["end_date"]
            return .object([
                "calendar_event_id": .string(eventId),
                "title": .string(title),
                "start_at": .string(dateString(start)),
                "end_at": .string(dateString(end))
            ])
        }
    }

    private static func cursor(_ recording: Recording) -> String? {
        guard let id = recording.id else { return nil }
        return Data("\(recording.createdAt.timeIntervalSince1970)|\(id)".utf8)
            .base64EncodedString()
    }

    private static func decodeCursor(_ cursor: String) throws -> (date: Date, id: Int64) {
        guard let data = Data(base64Encoded: cursor),
              let raw = String(data: data, encoding: .utf8) else {
            throw APIError.invalidArguments("cursor is invalid.")
        }
        let parts = raw.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let timestamp = Double(parts[0]),
              let id = Int64(parts[1]) else {
            throw APIError.invalidArguments("cursor is invalid.")
        }
        return (Date(timeIntervalSince1970: timestamp), id)
    }

    private static func requiredString(
        _ key: String,
        in arguments: [String: MCPJSONValue]
    ) throws -> String {
        guard let value = arguments[key]?.stringValue, !value.isEmpty else {
            throw APIError.invalidArguments("\(key) is required.")
        }
        return value
    }

    private static func speakerFilters(
        _ arguments: [String: MCPJSONValue]
    ) -> [String] {
        var values = arguments["speaker_ids"]?.arrayValue?.compactMap(\.stringValue) ?? []
        if let legacy = arguments["speaker_id"]?.stringValue {
            values.append(legacy)
        }
        return Array(Set(values)).sorted()
    }

    private static func sourceFilters(
        _ arguments: [String: MCPJSONValue]
    ) -> [String] {
        var values = arguments["sources"]?.arrayValue?.compactMap(\.stringValue) ?? []
        if let legacy = arguments["source"]?.stringValue {
            values.append(legacy)
        }
        return Array(Set(values)).sorted()
    }

    private static func escapedLike(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    private static func limit(
        _ arguments: [String: MCPJSONValue],
        default defaultValue: Int,
        maximum: Int
    ) throws -> Int {
        let value = Int(arguments["limit"]?.integerValue ?? Int64(defaultValue))
        guard value > 0, value <= maximum else {
            throw APIError.invalidArguments("limit must be between 1 and \(maximum).")
        }
        return value
    }

    private static func optionalDate(
        _ key: String,
        in arguments: [String: MCPJSONValue]
    ) throws -> Date? {
        guard let raw = arguments[key]?.stringValue else { return nil }
        guard let date = dateFormatter.date(from: raw) ?? basicDateFormatter.date(from: raw) else {
            throw APIError.invalidArguments("\(key) must be an ISO-8601 timestamp.")
        }
        return date
    }

    private static let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let basicDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static func dateString(_ date: Date) -> String {
        dateFormatter.string(from: date)
    }

    private func requireWrites(_ access: Access) throws {
        guard access.writes,
              MCPAuthorizationStore.shared.remainsAuthorized(access, write: true) else {
            throw APIError.forbidden("Write tools are disabled for this MCP client.")
        }
    }

    private func requireContent(_ access: Access) throws {
        guard access.transcripts,
              MCPAuthorizationStore.shared.remainsAuthorized(access, content: true) else {
            throw APIError.forbidden("Content access is disabled for this MCP client.")
        }
    }

    private static func mapCommentError(_ error: Error) -> APIError {
        guard let repositoryError = error as? GRDBRecordingCommentRepository.RepositoryError else {
            return .unavailable(error.localizedDescription)
        }
        switch repositoryError {
        case .recordingNotFound:
            return .notFound("Recording was not found.")
        case .commentNotFound:
            return .notFound("Comment was not found.")
        case .invalidBody:
            return .invalidArguments("Comment body must contain 1–20,000 characters.")
        case .invalidAnchor:
            return .invalidArguments("Comment time anchors are invalid for this recording.")
        case .idempotencyConflict:
            return .conflict(
                "The idempotency key was already used for a different recording, body, or anchor."
            )
        case .authorizationRevoked:
            return .forbidden("Content or write access was revoked before the comment change committed.")
        case .conflict:
            return .conflict("Comment changed since it was read. Read it again before updating.")
        }
    }
}
