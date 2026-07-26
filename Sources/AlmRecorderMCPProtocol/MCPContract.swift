import Foundation

public struct MCPToolEffects: Hashable, Sendable {
    public let readOnly: Bool
    public let destructive: Bool
    public let idempotent: Bool
    public let openWorld: Bool

    public init(
        readOnly: Bool,
        destructive: Bool,
        idempotent: Bool,
        openWorld: Bool = false
    ) {
        self.readOnly = readOnly
        self.destructive = destructive
        self.idempotent = idempotent
        self.openWorld = openWorld
    }
}

public struct MCPToolDefinition: Hashable, Sendable {
    public let name: String
    public let title: String
    public let description: String
    public let inputSchema: MCPJSONValue
    public let outputSchema: MCPJSONValue
    public let effects: MCPToolEffects
    public let requiresContent: Bool
    public let requiresWrite: Bool

    public init(
        name: String,
        title: String,
        description: String,
        inputSchema: MCPJSONValue,
        outputSchema: MCPJSONValue,
        effects: MCPToolEffects,
        requiresContent: Bool = false,
        requiresWrite: Bool = false
    ) {
        self.name = name
        self.title = title
        self.description = description
        self.inputSchema = inputSchema
        self.outputSchema = outputSchema
        self.effects = effects
        self.requiresContent = requiresContent
        self.requiresWrite = requiresWrite
    }
}

public struct MCPContractValidationError: LocalizedError, Hashable, Sendable {
    public let path: String
    public let reason: String

    public init(path: String, reason: String) {
        self.path = path
        self.reason = reason
    }

    public var errorDescription: String? {
        path.isEmpty ? reason : "\(path): \(reason)"
    }
}

/// The single model-visible contract shared by the stdio bridge and the app-owned handlers.
///
/// Schemas intentionally use JSON Schema 2020-12 features supported by the MCP specification.
/// `validateToolArguments` enforces the same subset at runtime so schema declarations cannot be
/// treated as documentation-only hints.
public enum AlmRecorderMCPContract {
    public static let tools: [MCPToolDefinition] = makeTools()
    private static let toolsByName = Dictionary(uniqueKeysWithValues: tools.map { ($0.name, $0) })

    public static func tool(named name: String) -> MCPToolDefinition? {
        toolsByName[name]
    }

    public static func validateToolArguments(
        name: String,
        arguments: [String: MCPJSONValue]
    ) throws {
        guard let tool = tool(named: name) else {
            throw MCPContractValidationError(path: "name", reason: "Unknown tool '\(name)'.")
        }
        try MCPJSONSchemaValidator.validate(.object(arguments), against: tool.inputSchema)
    }

    public static func validateToolOutput(
        name: String,
        value: MCPJSONValue
    ) throws {
        guard let tool = tool(named: name) else {
            throw MCPContractValidationError(path: "name", reason: "Unknown tool '\(name)'.")
        }
        try MCPJSONSchemaValidator.validate(value, against: tool.outputSchema)
    }

    private static func makeTools() -> [MCPToolDefinition] {
        let readOnly = MCPToolEffects(
            readOnly: true,
            destructive: false,
            idempotent: true
        )
        let additiveWrite = MCPToolEffects(
            readOnly: false,
            destructive: false,
            idempotent: true
        )
        let nonIdempotentAdditiveWrite = MCPToolEffects(
            readOnly: false,
            destructive: false,
            idempotent: false
        )
        let mutatingWrite = MCPToolEffects(
            readOnly: false,
            destructive: true,
            idempotent: false
        )
        let idempotentMutation = MCPToolEffects(
            readOnly: false,
            destructive: true,
            idempotent: true
        )
        let reversibleStatusWrite = MCPToolEffects(
            readOnly: false,
            destructive: false,
            idempotent: true
        )

        return [
            MCPToolDefinition(
                name: "get_library_status",
                title: "Get library status",
                description: """
                    Return library counts, content-index coverage, and whether pure semantic or \
                    hybrid search can run without loading or downloading a model.
                    """,
                inputSchema: Schema.object(),
                outputSchema: libraryStatusSchema,
                effects: readOnly
            ),
            MCPToolDefinition(
                name: "list_recordings",
                title: "List recordings",
                description: """
                    Browse recordings newest-first. Filter categories combine with AND; values \
                    within sources, speakers, and meetings use OR, while tag_match selects all or \
                    any. The text filter searches titles only unless content access is enabled. \
                    Preserve the same filters when using next_cursor.
                    """,
                inputSchema: Schema.object(
                    properties: recordingFilterProperties.merging([
                        "cursor": Schema.string(
                            "Opaque cursor returned by the preceding page.",
                            maxLength: 1_024
                        ),
                        "limit": Schema.integer(
                            "Page size.",
                            minimum: 1,
                            maximum: 100,
                            defaultValue: 20
                        )
                    ]) { _, new in new }
                ),
                outputSchema: Schema.object(
                    properties: [
                        "recordings": Schema.array(recordingSummarySchema),
                        "next_cursor": Schema.nullable(
                            Schema.string("Cursor for the next page.", maxLength: 1_024)
                        )
                    ],
                    required: ["recordings", "next_cursor"]
                ),
                effects: readOnly
            ),
            MCPToolDefinition(
                name: "get_recording",
                title: "Get recording",
                description: """
                    Return compact metadata, tags, speakers, linked meetings, and resource URIs. \
                    Full transcript text is never inlined; read transcript_uri when content access \
                    is enabled.
                    """,
                inputSchema: Schema.object(
                    properties: ["recording_id": recordingIdSchema],
                    required: ["recording_id"]
                ),
                outputSchema: recordingDetailSchema,
                effects: readOnly
            ),
            MCPToolDefinition(
                name: "search_recordings",
                title: "Search recordings",
                description: """
                    Search visible transcript utterances. keyword is ranked lexical search; exact \
                    is a deprecated alias. semantic is pure vector search and may use an exact \
                    filtered scan for recall; ann forces pure HNSW approximate-nearest-neighbor \
                    retrieval. hybrid uses reciprocal-rank fusion. auto chooses hybrid only when \
                    the local model and index are ready. MCP never downloads or loads a model.
                    """,
                inputSchema: Schema.object(
                    properties: recordingFilterProperties.merging([
                        "query": Schema.string(
                            "Search query.",
                            minLength: 1,
                            maxLength: 2_000
                        ),
                        "mode": Schema.enumeration(
                            ["auto", "keyword", "exact", "semantic", "ann", "hybrid"],
                            """
                            Search strategy. exact aliases keyword; semantic is vector-only with \
                            recall-safe filtered execution; ann forces HNSW ANN.
                            """,
                            defaultValue: "auto"
                        ),
                        "limit": Schema.integer(
                            "Maximum number of utterance hits.",
                            minimum: 1,
                            maximum: 50,
                            defaultValue: 20
                        )
                    ]) { _, new in new },
                    required: ["query"]
                ),
                outputSchema: searchResponseSchema,
                effects: readOnly,
                requiresContent: true
            ),
            MCPToolDefinition(
                name: "list_tags",
                title: "List tags",
                description: "List every tag with its stable ID, description, color, and recording count.",
                inputSchema: Schema.object(),
                outputSchema: Schema.object(
                    properties: ["tags": Schema.array(tagWithCountSchema)],
                    required: ["tags"]
                ),
                effects: readOnly
            ),
            MCPToolDefinition(
                name: "get_meeting_notes",
                title: "Get meeting notes",
                description: """
                    Read user agenda and notes. Provide exactly one calendar_event_id or recording_id. \
                    A recording linked to multiple calendar events returns every linked meeting.
                    """,
                inputSchema: Schema.object(
                    properties: [
                        "calendar_event_id": Schema.string(
                            "Apple Calendar event ID.",
                            minLength: 1,
                            maxLength: 2_048
                        ),
                        "recording_id": recordingIdSchema
                    ],
                    oneOf: [
                        Schema.object(
                            required: ["calendar_event_id"],
                            not: Schema.object(
                                required: ["recording_id"],
                                additionalProperties: true
                            ),
                            additionalProperties: true
                        ),
                        Schema.object(
                            required: ["recording_id"],
                            not: Schema.object(
                                required: ["calendar_event_id"],
                                additionalProperties: true
                            ),
                            additionalProperties: true
                        )
                    ]
                ),
                outputSchema: Schema.object(
                    properties: ["meetings": Schema.array(meetingNotesSchema)],
                    required: ["meetings"]
                ),
                effects: readOnly,
                requiresContent: true
            ),
            MCPToolDefinition(
                name: "list_comments",
                title: "List recording comments",
                description: "List open and/or resolved comments, including recording-time anchors.",
                inputSchema: Schema.object(
                    properties: [
                        "recording_id": recordingIdSchema,
                        "status": Schema.enumeration(
                            ["open", "resolved"],
                            "Optional status filter. Omit to return both."
                        )
                    ],
                    required: ["recording_id"]
                ),
                outputSchema: Schema.object(
                    properties: [
                        "recording_id": recordingIdSchema,
                        "comments": Schema.array(commentSchema)
                    ],
                    required: ["recording_id", "comments"]
                ),
                effects: readOnly,
                requiresContent: true
            ),
            MCPToolDefinition(
                name: "add_recording_tags",
                title: "Add recording tags",
                description: "Attach existing tags to one recording using stable tag IDs or exact names.",
                inputSchema: tagMutationInputSchema,
                outputSchema: tagMutationOutputSchema(changeKey: "added"),
                effects: additiveWrite,
                requiresWrite: true
            ),
            MCPToolDefinition(
                name: "remove_recording_tags",
                title: "Remove recording tags",
                description: "Detach existing tags from one recording using stable tag IDs or exact names.",
                inputSchema: tagMutationInputSchema,
                outputSchema: tagMutationOutputSchema(changeKey: "removed"),
                effects: idempotentMutation,
                requiresWrite: true
            ),
            MCPToolDefinition(
                name: "update_meeting_notes",
                title: "Update meeting notes",
                description: """
                    Replace agenda and/or notes on an existing calendar event. Pass if_updated_at \
                    from a read result to prevent overwriting a newer edit.
                    """,
                inputSchema: Schema.object(
                    properties: [
                        "calendar_event_id": Schema.string(
                            "Existing Apple Calendar event ID.",
                            minLength: 1,
                            maxLength: 2_048
                        ),
                        "agenda": Schema.string(
                            "Replacement agenda.",
                            maxLength: 100_000
                        ),
                        "notes": Schema.string(
                            "Replacement notes.",
                            maxLength: 500_000
                        ),
                        "if_updated_at": dateTimeSchema(
                            "Optional optimistic-concurrency timestamp from get_meeting_notes."
                        )
                    ],
                    required: ["calendar_event_id"],
                    anyOf: [
                        Schema.object(required: ["agenda"], additionalProperties: true),
                        Schema.object(required: ["notes"], additionalProperties: true)
                    ]
                ),
                outputSchema: meetingNotesSchema,
                effects: mutatingWrite,
                requiresContent: true,
                requiresWrite: true
            ),
            MCPToolDefinition(
                name: "add_comment",
                title: "Add recording comment",
                description: """
                    Add a comment, optionally anchored to visible transcript time. Reusing an \
                    idempotency key for the same intent returns the original comment; reusing it for \
                    different content returns conflict.
                    """,
                inputSchema: Schema.object(
                    properties: [
                        "recording_id": recordingIdSchema,
                        "body": Schema.string(
                            "Comment body.",
                            minLength: 1,
                            maxLength: 20_000
                        ),
                        "anchor_start": Schema.number(
                            "Optional start time in seconds.",
                            minimum: 0
                        ),
                        "anchor_end": Schema.number(
                            "Optional end time in seconds. Requires anchor_start.",
                            minimum: 0
                        ),
                        "source_utterance_id": Schema.integer(
                            "Optional visible source utterance row ID from a transcript resource.",
                            minimum: 1
                        ),
                        "idempotency_key": Schema.string(
                            "Caller-generated retry key, scoped to this client and intent.",
                            minLength: 1,
                            maxLength: 256
                        )
                    ],
                    required: ["recording_id", "body"],
                    dependentRequired: ["anchor_end": ["anchor_start"]]
                ),
                outputSchema: commentSchema,
                effects: nonIdempotentAdditiveWrite,
                requiresContent: true,
                requiresWrite: true
            ),
            MCPToolDefinition(
                name: "update_comment",
                title: "Update comment",
                description: """
                    Patch a comment body and/or anchors. Omitted anchor fields are preserved; explicit \
                    null clears that anchor. Pass if_updated_at to prevent overwriting a newer edit.
                    """,
                inputSchema: Schema.object(
                    properties: [
                        "comment_id": commentIdSchema,
                        "body": Schema.string(
                            "Replacement body.",
                            minLength: 1,
                            maxLength: 20_000
                        ),
                        "anchor_start": Schema.nullable(
                            Schema.number("Replacement start time, or null to clear.", minimum: 0)
                        ),
                        "anchor_end": Schema.nullable(
                            Schema.number("Replacement end time, or null to clear.", minimum: 0)
                        ),
                        "if_updated_at": dateTimeSchema(
                            "Optional optimistic-concurrency timestamp from list_comments."
                        )
                    ],
                    required: ["comment_id"],
                    anyOf: [
                        Schema.object(required: ["body"], additionalProperties: true),
                        Schema.object(required: ["anchor_start"], additionalProperties: true),
                        Schema.object(required: ["anchor_end"], additionalProperties: true)
                    ]
                ),
                outputSchema: commentSchema,
                effects: mutatingWrite,
                requiresContent: true,
                requiresWrite: true
            ),
            MCPToolDefinition(
                name: "set_comment_status",
                title: "Set comment status",
                description: "Resolve or reopen a comment, with optional optimistic concurrency.",
                inputSchema: Schema.object(
                    properties: [
                        "comment_id": commentIdSchema,
                        "status": Schema.enumeration(["open", "resolved"], "New status."),
                        "if_updated_at": dateTimeSchema(
                            "Optional optimistic-concurrency timestamp from list_comments."
                        )
                    ],
                    required: ["comment_id", "status"]
                ),
                outputSchema: commentSchema,
                effects: reversibleStatusWrite,
                requiresContent: true,
                requiresWrite: true
            )
        ]
    }

    private static let recordingFilterProperties: [String: MCPJSONValue] = [
        "tags": Schema.array(
            Schema.string("Stable tag ID or exact tag name.", minLength: 1, maxLength: 256),
            description: "Tag identifiers interpreted using tag_match (default: all).",
            minItems: 1,
            maxItems: 100,
            uniqueItems: true
        ),
        "tag_match": Schema.enumeration(
            ["all", "any"],
            "Whether all or any supplied tags must match.",
            defaultValue: "all"
        ),
        "speaker_id": Schema.string(
            "Deprecated single speaker UUID; prefer speaker_ids.",
            minLength: 1,
            maxLength: 256
        ),
        "speaker_ids": Schema.array(
            Schema.string("Speaker UUID.", minLength: 1, maxLength: 256),
            description: "Match any supplied speaker; search returns only those speakers' utterances.",
            minItems: 1,
            maxItems: 100,
            uniqueItems: true
        ),
        "source": Schema.enumeration(
            ["recording", "voiceMemos", "imported"],
            "Deprecated single recording source; prefer sources."
        ),
        "sources": Schema.array(
            Schema.enumeration(
                ["recording", "voiceMemos", "imported"],
                "Recording source."
            ),
            description: "Match any supplied recording source.",
            minItems: 1,
            maxItems: 3,
            uniqueItems: true
        ),
        "calendar_event_ids": Schema.array(
            Schema.string("Linked Apple Calendar event ID.", minLength: 1, maxLength: 2_048),
            description: "Match a recording linked to any supplied calendar event.",
            minItems: 1,
            maxItems: 100,
            uniqueItems: true
        ),
        "has_transcript": Schema.boolean(
            "Require or exclude at least one visible utterance. Requires content access."
        ),
        "has_open_comments": Schema.boolean(
            "Require or exclude an open comment. Requires content access."
        ),
        "date_from": dateTimeSchema("Inclusive earliest recording creation timestamp."),
        "date_to": dateTimeSchema("Inclusive latest recording creation timestamp."),
        "text": Schema.string(
            "Browse prefilter. Searches titles and, with content access, visible transcript text.",
            minLength: 1,
            maxLength: 2_000
        )
    ]

    private static let recordingIdSchema = Schema.string(
        "Stable recording ID.",
        minLength: 5,
        maxLength: 64,
        pattern: #"^rec_[A-Za-z0-9-]+$"#
    )

    private static let commentIdSchema = Schema.string(
        "Stable comment ID.",
        minLength: 5,
        maxLength: 64,
        pattern: #"^cmt_[A-Za-z0-9-]+$"#
    )

    private static let dateTimeValueSchema = dateTimeSchema("ISO-8601 timestamp.")

    private static func dateTimeSchema(_ description: String) -> MCPJSONValue {
        Schema.string(description, maxLength: 64, format: "date-time")
    }

    private static let tagSchema = Schema.object(
        properties: [
            "id": Schema.string("Stable tag ID.", minLength: 5, maxLength: 64),
            "name": Schema.string("Tag name.", minLength: 1, maxLength: 256),
            "color": Schema.nullable(Schema.string("Optional display color.", maxLength: 128)),
            "description": Schema.nullable(
                Schema.string("Optional tag description.", maxLength: 10_000)
            ),
            "updated_at": Schema.nullable(dateTimeValueSchema)
        ],
        required: ["id", "name", "color", "description", "updated_at"]
    )

    private static let tagWithCountSchema = Schema.object(
        properties: (tagSchema.objectValue?["properties"]?.objectValue ?? [:]).merging([
            "recording_count": Schema.integer("Attached recording count.", minimum: 0)
        ]) { _, new in new },
        required: ["id", "name", "color", "description", "updated_at", "recording_count"]
    )

    private static let recordingSummarySchema = Schema.object(
        properties: [
            "id": recordingIdSchema,
            "title": Schema.string("Recording title.", minLength: 1, maxLength: 10_000),
            "created_at": dateTimeValueSchema,
            "updated_at": Schema.nullable(dateTimeValueSchema),
            "duration_seconds": Schema.nullable(
                Schema.number("Recording duration in seconds.", minimum: 0)
            ),
            "language": Schema.nullable(Schema.string("Detected language.", maxLength: 128)),
            "source": Schema.enumeration(
                ["recording", "voiceMemos", "imported"],
                "Recording source."
            ),
            "summary": Schema.nullable(
                Schema.string("Transcript-derived summary; null without content access.", maxLength: 100_000)
            ),
            "topics": Schema.array(
                Schema.string("Transcript-derived topic.", maxLength: 1_000),
                description: "Empty without content access.",
                maxItems: 1_000
            ),
            "uri": Schema.string("Recording resource URI.", format: "uri")
        ],
        required: [
            "id", "title", "created_at", "updated_at", "duration_seconds", "language",
            "source", "summary", "topics", "uri"
        ]
    )

    private static let speakerSchema = Schema.object(
        properties: [
            "id": Schema.nullable(Schema.string("Speaker UUID.", maxLength: 256)),
            "name": Schema.string("Display name.", minLength: 1, maxLength: 1_000),
            "utterance_count": Schema.integer("Visible utterance count.", minimum: 0)
        ],
        required: ["id", "name", "utterance_count"]
    )

    private static let meetingSummarySchema = Schema.object(
        properties: [
            "calendar_event_id": Schema.string("Calendar event ID.", minLength: 1, maxLength: 2_048),
            "title": Schema.string("Meeting title.", maxLength: 10_000),
            "start_at": dateTimeValueSchema,
            "end_at": dateTimeValueSchema
        ],
        required: ["calendar_event_id", "title", "start_at", "end_at"]
    )

    private static let meetingNotesSchema = Schema.object(
        properties: [
            "calendar_event_id": Schema.string("Calendar event ID.", minLength: 1, maxLength: 2_048),
            "title": Schema.nullable(Schema.string("Meeting title.", maxLength: 10_000)),
            "start_at": Schema.nullable(dateTimeValueSchema),
            "end_at": Schema.nullable(dateTimeValueSchema),
            "agenda": Schema.string("User agenda.", maxLength: 100_000),
            "notes": Schema.string("User meeting notes.", maxLength: 500_000),
            "updated_at": Schema.nullable(dateTimeValueSchema)
        ],
        required: [
            "calendar_event_id", "title", "start_at", "end_at", "agenda", "notes", "updated_at"
        ]
    )

    private static let recordingDetailSchema = Schema.object(
        properties: (recordingSummarySchema.objectValue?["properties"]?.objectValue ?? [:]).merging([
            "tags": Schema.array(tagSchema),
            "speakers": Schema.array(speakerSchema),
            "meetings": Schema.array(meetingSummarySchema),
            "comment_count": Schema.nullable(
                Schema.integer("Comment count; null without content access.", minimum: 0)
            ),
            "comments_uri": Schema.nullable(
                Schema.string("Comments resource URI; null without content access.", format: "uri")
            ),
            "transcript_uri": Schema.nullable(
                Schema.string("Transcript resource URI; null without content access.", format: "uri")
            ),
            "content_access": Schema.enumeration(
                ["enabled", "disabled"],
                "Whether content resources and derived fields are available."
            )
        ]) { _, new in new },
        required: [
            "id", "title", "created_at", "updated_at", "duration_seconds", "language",
            "source", "summary", "topics", "uri", "tags", "speakers", "meetings",
            "comment_count", "comments_uri", "transcript_uri", "content_access"
        ]
    )

    private static let searchHitSchema = Schema.object(
        properties: [
            "recording_id": recordingIdSchema,
            "recording_title": Schema.string("Recording title.", maxLength: 10_000),
            "recorded_at": dateTimeValueSchema,
            "utterance_id": Schema.nullable(
                Schema.integer("Visible utterance row ID; null for a title-only hit.", minimum: 1)
            ),
            "start_time": Schema.number("Start time in seconds.", minimum: 0),
            "end_time": Schema.number("End time in seconds.", minimum: 0),
            "speaker": Schema.nullable(Schema.string("Display speaker name.", maxLength: 1_000)),
            "speaker_id": Schema.nullable(Schema.string("Speaker UUID.", maxLength: 256)),
            "text": Schema.string("Visible matching text.", minLength: 1, maxLength: 100_000),
            "score": Schema.number("Response-local ranking score."),
            "match": Schema.enumeration(
                ["keyword", "exact", "semantic", "hybrid"],
                "How this hit contributed to the result."
            ),
            "match_field": Schema.enumeration(
                ["title", "transcript"],
                "Field that produced the hit."
            ),
            "recording_uri": Schema.string("Recording resource URI.", format: "uri"),
            "transcript_uri": Schema.string("Transcript resource URI.", format: "uri")
        ],
        required: [
            "recording_id", "recording_title", "recorded_at", "utterance_id",
            "start_time", "end_time", "speaker", "speaker_id", "text", "score",
            "match", "match_field", "recording_uri", "transcript_uri"
        ]
    )

    private static let searchResponseSchema = Schema.object(
        properties: [
            "query": Schema.string("Normalized query.", minLength: 1, maxLength: 2_000),
            "mode_requested": Schema.enumeration(
                ["auto", "keyword", "exact", "semantic", "ann", "hybrid"],
                "Mode requested by the caller."
            ),
            "mode": Schema.enumeration(
                ["keyword", "semantic", "ann", "hybrid"],
                "Mode actually used."
            ),
            "semantic_strategy": Schema.enumeration(
                ["not_used", "exact_filtered", "ann"],
                "Concrete vector execution strategy used for this response."
            ),
            "results": Schema.array(searchHitSchema, maxItems: 50),
            "semantic_search_ready": Schema.boolean("Whether semantic search was ready."),
            "indexed_utterance_count": Schema.integer("Indexed visible utterance count.", minimum: 0),
            "visible_utterance_count": Schema.integer("Total visible utterance count.", minimum: 0),
            "eligible_visible_utterance_count": Schema.integer(
                "Visible utterances remaining after all recording and speaker filters.",
                minimum: 0
            ),
            "eligible_indexed_utterance_count": Schema.integer(
                "Filtered visible utterances with a durable embedding.",
                minimum: 0
            ),
            "ann_candidates_examined": Schema.integer(
                "Global HNSW candidates examined; zero when ANN was not used.",
                minimum: 0
            ),
            "index_coverage": Schema.number(
                "Fraction of visible utterances with a durable embedding.",
                minimum: 0,
                maximum: 1
            ),
            "complete": Schema.boolean(
                "False when a bounded filtered ANN search could not prove exhaustive coverage."
            )
        ],
        required: [
            "query", "mode_requested", "mode", "semantic_strategy", "results", "semantic_search_ready",
            "indexed_utterance_count", "visible_utterance_count",
            "eligible_visible_utterance_count", "eligible_indexed_utterance_count",
            "ann_candidates_examined", "index_coverage", "complete"
        ]
    )

    private static let libraryStatusSchema = Schema.object(
        properties: [
            "recording_count": Schema.integer("Recording count.", minimum: 0),
            "tag_count": Schema.integer("Tag count.", minimum: 0),
            "comment_count": Schema.nullable(
                Schema.integer("Comment count; null without content access.", minimum: 0)
            ),
            "newest_recording_at": Schema.nullable(dateTimeValueSchema),
            "visible_utterance_count": Schema.nullable(
                Schema.integer("Visible utterance count; null without content access.", minimum: 0)
            ),
            "indexed_utterance_count": Schema.nullable(
                Schema.integer(
                    "Durably indexed visible utterance count; null without content access.",
                    minimum: 0
                )
            ),
            "index_coverage": Schema.nullable(
                Schema.number(
                    "Indexed fraction from 0 to 1; null without content access.",
                    minimum: 0,
                    maximum: 1
                )
            ),
            "semantic_search_ready": Schema.nullable(
                Schema.boolean("Whether model plus index are ready; null without content access.")
            ),
            "semantic_search_note": Schema.string("Human-readable readiness detail.", maxLength: 2_000),
            "bridge_protocol_version": Schema.integer("Private app/bridge wire version.", minimum: 1)
        ],
        required: [
            "recording_count", "tag_count", "comment_count", "newest_recording_at",
            "visible_utterance_count", "indexed_utterance_count", "index_coverage",
            "semantic_search_ready", "semantic_search_note", "bridge_protocol_version"
        ]
    )

    private static let commentSchema = Schema.object(
        properties: [
            "id": commentIdSchema,
            "body": Schema.string("Comment body.", minLength: 1, maxLength: 20_000),
            "anchor_start": Schema.nullable(Schema.number("Start seconds.", minimum: 0)),
            "anchor_end": Schema.nullable(Schema.number("End seconds.", minimum: 0)),
            "source_utterance_id": Schema.nullable(
                Schema.integer("Source utterance row ID.", minimum: 1)
            ),
            "status": Schema.enumeration(["open", "resolved"], "Comment status."),
            "created_by": Schema.string("MCP client ID.", minLength: 1, maxLength: 256),
            "created_at": dateTimeValueSchema,
            "updated_at": dateTimeValueSchema,
            "resolved_at": Schema.nullable(dateTimeValueSchema)
        ],
        required: [
            "id", "body", "anchor_start", "anchor_end", "source_utterance_id",
            "status", "created_by", "created_at", "updated_at", "resolved_at"
        ]
    )

    private static let tagMutationInputSchema = Schema.object(
        properties: [
            "recording_id": recordingIdSchema,
            "tags": Schema.array(
                Schema.string("Stable tag ID or exact tag name.", minLength: 1, maxLength: 256),
                description: "One or more existing tags.",
                minItems: 1,
                maxItems: 100,
                uniqueItems: true
            )
        ],
        required: ["recording_id", "tags"]
    )

    private static func tagMutationOutputSchema(changeKey: String) -> MCPJSONValue {
        Schema.object(
            properties: [
                "recording_id": recordingIdSchema,
                changeKey: Schema.array(tagSchema),
                "tags": Schema.array(tagSchema),
                "updated_at": dateTimeValueSchema
            ],
            required: ["recording_id", changeKey, "tags", "updated_at"]
        )
    }
}

private enum Schema {
    static func object(
        properties: [String: MCPJSONValue] = [:],
        required: [String] = [],
        anyOf: [MCPJSONValue] = [],
        oneOf: [MCPJSONValue] = [],
        not: MCPJSONValue? = nil,
        dependentRequired: [String: [String]] = [:],
        additionalProperties: Bool = false
    ) -> MCPJSONValue {
        var schema: [String: MCPJSONValue] = [
            "type": .string("object"),
            "properties": .object(properties),
            "additionalProperties": .bool(additionalProperties)
        ]
        if !required.isEmpty {
            schema["required"] = .array(required.map(MCPJSONValue.string))
        }
        if !anyOf.isEmpty {
            schema["anyOf"] = .array(anyOf)
        }
        if !oneOf.isEmpty {
            schema["oneOf"] = .array(oneOf)
        }
        if let not {
            schema["not"] = not
        }
        if !dependentRequired.isEmpty {
            schema["dependentRequired"] = .object(
                dependentRequired.mapValues { .array($0.map(MCPJSONValue.string)) }
            )
        }
        return .object(schema)
    }

    static func string(
        _ description: String,
        minLength: Int? = nil,
        maxLength: Int? = nil,
        pattern: String? = nil,
        format: String? = nil
    ) -> MCPJSONValue {
        var schema: [String: MCPJSONValue] = [
            "type": .string("string"),
            "description": .string(description)
        ]
        if let minLength { schema["minLength"] = .integer(Int64(minLength)) }
        if let maxLength { schema["maxLength"] = .integer(Int64(maxLength)) }
        if let pattern { schema["pattern"] = .string(pattern) }
        if let format { schema["format"] = .string(format) }
        return .object(schema)
    }

    static func number(
        _ description: String,
        minimum: Double? = nil,
        maximum: Double? = nil
    ) -> MCPJSONValue {
        var schema: [String: MCPJSONValue] = [
            "type": .string("number"),
            "description": .string(description)
        ]
        if let minimum { schema["minimum"] = .double(minimum) }
        if let maximum { schema["maximum"] = .double(maximum) }
        return .object(schema)
    }

    static func integer(
        _ description: String,
        minimum: Int? = nil,
        maximum: Int? = nil,
        defaultValue: Int? = nil
    ) -> MCPJSONValue {
        var schema: [String: MCPJSONValue] = [
            "type": .string("integer"),
            "description": .string(description)
        ]
        if let minimum { schema["minimum"] = .integer(Int64(minimum)) }
        if let maximum { schema["maximum"] = .integer(Int64(maximum)) }
        if let defaultValue { schema["default"] = .integer(Int64(defaultValue)) }
        return .object(schema)
    }

    static func boolean(
        _ description: String,
        defaultValue: Bool? = nil
    ) -> MCPJSONValue {
        var schema: [String: MCPJSONValue] = [
            "type": .string("boolean"),
            "description": .string(description)
        ]
        if let defaultValue { schema["default"] = .bool(defaultValue) }
        return .object(schema)
    }

    static func enumeration(
        _ values: [String],
        _ description: String,
        defaultValue: String? = nil
    ) -> MCPJSONValue {
        var schema: [String: MCPJSONValue] = [
            "type": .string("string"),
            "enum": .array(values.map(MCPJSONValue.string)),
            "description": .string(description)
        ]
        if let defaultValue { schema["default"] = .string(defaultValue) }
        return .object(schema)
    }

    static func array(
        _ items: MCPJSONValue,
        description: String? = nil,
        minItems: Int? = nil,
        maxItems: Int? = nil,
        uniqueItems: Bool = false
    ) -> MCPJSONValue {
        var schema: [String: MCPJSONValue] = [
            "type": .string("array"),
            "items": items
        ]
        if let description { schema["description"] = .string(description) }
        if let minItems { schema["minItems"] = .integer(Int64(minItems)) }
        if let maxItems { schema["maxItems"] = .integer(Int64(maxItems)) }
        if uniqueItems { schema["uniqueItems"] = .bool(true) }
        return .object(schema)
    }

    static func nullable(_ schema: MCPJSONValue) -> MCPJSONValue {
        guard var object = schema.objectValue else { return schema }
        if let type = object["type"]?.stringValue {
            object["type"] = .array([.string(type), .string("null")])
        }
        return .object(object)
    }
}

public enum MCPJSONSchemaValidator {
    public static func validate(
        _ value: MCPJSONValue,
        against schema: MCPJSONValue,
        path: String = "$"
    ) throws {
        guard let object = schema.objectValue else {
            throw MCPContractValidationError(path: path, reason: "Contract schema is not an object.")
        }

        if let notSchema = object["not"], matches(value, schema: notSchema, path: path) {
            throw MCPContractValidationError(path: path, reason: "Value matches a forbidden shape.")
        }
        if let alternatives = object["allOf"]?.arrayValue {
            for alternative in alternatives {
                try validate(value, against: alternative, path: path)
            }
        }
        if let alternatives = object["anyOf"]?.arrayValue,
           !alternatives.isEmpty,
           !alternatives.contains(where: { matches(value, schema: $0, path: path) }) {
            throw MCPContractValidationError(path: path, reason: "Value does not match any allowed shape.")
        }
        if let alternatives = object["oneOf"]?.arrayValue, !alternatives.isEmpty {
            let count = alternatives.filter { matches(value, schema: $0, path: path) }.count
            guard count == 1 else {
                throw MCPContractValidationError(
                    path: path,
                    reason: "Value must match exactly one allowed shape."
                )
            }
        }

        if let allowedTypes = schemaTypes(object["type"]) {
            let actual = typeName(value)
            let accepted = allowedTypes.contains(actual)
                || (actual == "integer" && allowedTypes.contains("number"))
            guard accepted else {
                throw MCPContractValidationError(
                    path: path,
                    reason: "Expected \(allowedTypes.sorted().joined(separator: " or ")); received \(actual)."
                )
            }
            if actual == "null" { return }
        }

        if let allowed = object["enum"]?.arrayValue, !allowed.contains(value) {
            throw MCPContractValidationError(path: path, reason: "Value is not in the allowed enum.")
        }

        switch value {
        case .object(let values):
            let properties = object["properties"]?.objectValue ?? [:]
            let required = Set(object["required"]?.arrayValue?.compactMap(\.stringValue) ?? [])
            for key in required where values[key] == nil {
                throw MCPContractValidationError(
                    path: "\(path).\(key)",
                    reason: "Required property is missing."
                )
            }
            if object["additionalProperties"]?.boolValue == false {
                let unknown = Set(values.keys).subtracting(properties.keys)
                if let first = unknown.sorted().first {
                    throw MCPContractValidationError(
                        path: "\(path).\(first)",
                        reason: "Unknown property."
                    )
                }
            }
            for (key, child) in values {
                if let childSchema = properties[key] {
                    try validate(child, against: childSchema, path: "\(path).\(key)")
                }
            }
            if let dependencies = object["dependentRequired"]?.objectValue {
                for (key, dependencyValue) in dependencies where values[key] != nil {
                    for dependency in dependencyValue.arrayValue?.compactMap(\.stringValue) ?? []
                    where values[dependency] == nil {
                        throw MCPContractValidationError(
                            path: "\(path).\(dependency)",
                            reason: "Property is required when \(key) is supplied."
                        )
                    }
                }
            }

        case .array(let values):
            if let minimum = object["minItems"]?.integerValue, Int64(values.count) < minimum {
                throw MCPContractValidationError(path: path, reason: "Array has too few items.")
            }
            if let maximum = object["maxItems"]?.integerValue, Int64(values.count) > maximum {
                throw MCPContractValidationError(path: path, reason: "Array has too many items.")
            }
            if object["uniqueItems"]?.boolValue == true, Set(values).count != values.count {
                throw MCPContractValidationError(path: path, reason: "Array items must be unique.")
            }
            if let itemSchema = object["items"] {
                for (index, child) in values.enumerated() {
                    try validate(child, against: itemSchema, path: "\(path)[\(index)]")
                }
            }

        case .string(let string):
            if let minimum = object["minLength"]?.integerValue, Int64(string.count) < minimum {
                throw MCPContractValidationError(path: path, reason: "String is too short.")
            }
            if let maximum = object["maxLength"]?.integerValue, Int64(string.count) > maximum {
                throw MCPContractValidationError(path: path, reason: "String is too long.")
            }
            if let pattern = object["pattern"]?.stringValue,
               string.range(of: pattern, options: .regularExpression) == nil {
                throw MCPContractValidationError(path: path, reason: "String does not match the required pattern.")
            }
            if let format = object["format"]?.stringValue {
                try validateFormat(format, string: string, path: path)
            }

        case .integer(let number):
            try validateNumber(Double(number), schema: object, path: path)
        case .double(let number):
            guard number.isFinite else {
                throw MCPContractValidationError(path: path, reason: "Number must be finite.")
            }
            try validateNumber(number, schema: object, path: path)
        case .null, .bool:
            break
        }
    }

    private static func matches(
        _ value: MCPJSONValue,
        schema: MCPJSONValue,
        path: String
    ) -> Bool {
        do {
            try validate(value, against: schema, path: path)
            return true
        } catch {
            return false
        }
    }

    private static func schemaTypes(_ value: MCPJSONValue?) -> Set<String>? {
        if let string = value?.stringValue { return [string] }
        if let values = value?.arrayValue {
            return Set(values.compactMap(\.stringValue))
        }
        return nil
    }

    private static func typeName(_ value: MCPJSONValue) -> String {
        switch value {
        case .null: return "null"
        case .bool: return "boolean"
        case .integer: return "integer"
        case .double: return "number"
        case .string: return "string"
        case .array: return "array"
        case .object: return "object"
        }
    }

    private static func validateNumber(
        _ value: Double,
        schema: [String: MCPJSONValue],
        path: String
    ) throws {
        if let minimum = schema["minimum"]?.doubleValue, value < minimum {
            throw MCPContractValidationError(path: path, reason: "Number is below the minimum.")
        }
        if let maximum = schema["maximum"]?.doubleValue, value > maximum {
            throw MCPContractValidationError(path: path, reason: "Number is above the maximum.")
        }
    }

    private static func validateFormat(
        _ format: String,
        string: String,
        path: String
    ) throws {
        switch format {
        case "date-time":
            guard fractionalDateFormatter.date(from: string) != nil
                    || basicDateFormatter.date(from: string) != nil else {
                throw MCPContractValidationError(path: path, reason: "Expected an ISO-8601 date-time.")
            }
        case "uri":
            guard let components = URLComponents(string: string), components.scheme != nil else {
                throw MCPContractValidationError(path: path, reason: "Expected an absolute URI.")
            }
        default:
            break
        }
    }

    private static let fractionalDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let basicDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
