# AlmRecorder MCP Contract Reference

Version: 0.2.0

The authoritative machine-readable contract is returned by MCP `tools/list`. AlmRecorder builds
that catalog and validates both requests and successful structured outputs from the same
`AlmRecorderMCPProtocol` definitions. Unknown properties are rejected.

## Shared recording filters

Filter categories combine with AND. Array values for speakers, sources, and meetings use OR.

| Argument | Type | Meaning |
|---|---|---|
| `tags` | unique string array, 1–100 | Stable tag IDs or exact case-insensitive names |
| `tag_match` | `all` or `any`; default `all` | Require every supplied tag or at least one |
| `speaker_ids` | unique string array, 1–100 | Match any UUID; search hits are restricted to those speakers |
| `speaker_id` | string | Deprecated single-speaker form |
| `sources` | unique enum array | Any of `recording`, `voiceMemos`, `imported` |
| `source` | enum | Deprecated single-source form |
| `calendar_event_ids` | unique string array, 1–100 | Match any linked, non-dismissed calendar event |
| `date_from` | ISO-8601 date-time | Inclusive earliest recording creation time |
| `date_to` | ISO-8601 date-time | Inclusive latest recording creation time; must not precede `date_from` |
| `has_transcript` | boolean | Require/exclude a visible utterance; requires content scope |
| `has_open_comments` | boolean | Require/exclude an open comment; requires content scope |
| `text` | string, 1–2,000 | Browse substring. Title-only without content scope; otherwise title or visible transcript |

## Search modes

| Mode | Execution |
|---|---|
| `keyword` | FTS5 `unicode61 remove_diacritics 2`, all query tokens, BM25 ranking, title boost |
| `exact` | Deprecated alias for `keyword`; not literal equality |
| `semantic` | Vector-only. Exact cosine over small filtered durable sets; bounded adaptive HNSW for large sets |
| `ann` | Vector-only, forced vectorlite HNSW ANN |
| `hybrid` | Reciprocal-rank fusion of keyword and vector ranks with constant 60 |
| `auto` | Hybrid only when a model is already loaded and the filtered index is usable; otherwise keyword |

MCP never loads or downloads an embedding model. Search responses include `mode_requested`, `mode`,
`semantic_strategy` (`not_used`, `exact_filtered`, or `ann`), global and eligible index counts,
`ann_candidates_examined`, index coverage, and `complete`. A false `complete` means bounded ANN
could not prove it had found every nearest eligible result.

## Tools

### `get_library_status`

No arguments. Returns recording/tag/comment counts, global visible/indexed utterance counts,
coverage, semantic readiness and an explanatory note. `comment_count` is null without content
scope; transcript/index counts, coverage, and semantic readiness are also null without content
scope.

### `list_recordings`

Accepts all shared recording filters plus:

| Argument | Type | Default |
|---|---|---|
| `limit` | integer 1–100 | 20 |
| `cursor` | opaque string, max 1,024 | omitted |

Results are newest-first by `(created_at, internal id)` and return `next_cursor`. Preserve every
filter when continuing. Summaries/topics are null/empty without content access.

### `get_recording`

Requires `recording_id` matching `^rec_[A-Za-z0-9-]+$`. Returns compact metadata, tags, visible
speakers, linked meetings, and content resource URIs. The transcript is not inlined.

### `search_recordings`

Requires `query` (1–2,000 characters). Accepts all shared filters, `mode` (default `auto`), and
`limit` (1–50, default 20). Content scope is required. Results are utterance/title hits with stable
recording resources, timestamps, speaker identity, response-local score, contributing mode, and
matching field.

### `list_tags`

No arguments. Returns stable tag ID, name, optional color/description/update time, and recording
count.

### `get_meeting_notes`

Requires exactly one of `calendar_event_id` or `recording_id`. Returns all matching linked meetings;
it never guesses when a recording has multiple meetings. Content scope is required.

### `list_comments`

Requires `recording_id`; optional `status` is `open` or `resolved`. Content scope is required.

### `add_recording_tags` / `remove_recording_tags`

Require one `recording_id` and 1–100 existing stable tag IDs or exact names. Write scope is
required. Both operations are transactionally idempotent at the association level.

### `update_meeting_notes`

Requires `calendar_event_id` and at least one of `agenda` (max 100,000 characters) or `notes`
(max 500,000). Optional ISO-8601 `if_updated_at` prevents lost updates. Content and write scopes
are required.

### `add_comment`

Requires `recording_id` and nonblank `body` (max 20,000). Optional `anchor_start`, `anchor_end`,
`source_utterance_id`, and `idempotency_key` are supported. `anchor_end` requires `anchor_start`;
anchors must be ordered and within recording duration. A retry key reused for another intent
returns `conflict`. Content and write scopes are required.

### `update_comment`

Requires `comment_id` matching `^cmt_[A-Za-z0-9-]+$` and at least one patch field. Omitted anchors
are preserved; explicit null clears an anchor. Optional `if_updated_at` prevents lost updates.

### `set_comment_status`

Requires `comment_id` and `status: "open" | "resolved"`. Optional `if_updated_at` prevents lost
updates. Repeating the current status returns the existing comment without changing its timestamp.

## Resources and prompts

- `almrecorder://help`
- `almrecorder://tags`
- `almrecorder://recordings/{recording_id}`
- `almrecorder://recordings/{recording_id}/transcript`
- `almrecorder://recordings/{recording_id}/comments`

`resources/list` is cursor-paginated. The server exposes `prepare_meeting_follow_up(recording_id)`
and `weekly_recap` prompts.

## Errors and recovery

Tool errors use structured `{code, message, retryable, details}` content.

| Code | Recovery |
|---|---|
| `invalid_arguments` | Correct the property/type/constraint named in the message |
| `not_found` | Re-list the relevant recording, tag, meeting, comment, or resource |
| `forbidden` / `unauthorized` | Enable the required scope or copy a fresh client configuration |
| `conflict` | Re-read, then retry with the latest `if_updated_at` |
| `unavailable` | Check `get_library_status`; load a model in the app if semantic search is required |
| `rate_limited` | Wait for current local work to finish and retry |
| `cancelled` | Retry only if the operation is still wanted |
