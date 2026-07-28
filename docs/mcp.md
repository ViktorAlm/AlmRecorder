# AlmRecorder MCP

AlmRecorder ships a local MCP server for browsing and searching recordings, reading meeting notes,
organizing recordings with tags, and collaborating through timestamped comments.

## Connect a client

1. Open AlmRecorder.
2. Open **Settings → MCP**.
3. Enable the local MCP server.
4. Enable transcript access and/or write access if the client needs them.
5. Copy the generated client configuration into the MCP client.

The generated configuration launches the bundled `AlmRecorderMCPBridge`. AlmRecorder must remain
open while a client uses it.

For a development build, build both executables with:

```bash
swift build
```

The bridge will be at `.build/debug/AlmRecorderMCPBridge`.

## Available tools

| Tool | Purpose |
|---|---|
| `get_library_status` | Counts and semantic-search readiness |
| `list_recordings` | Latest recordings and tag/speaker/date/source browsing |
| `get_recording` | Metadata, tags, speakers, meetings, comments, and resource URIs |
| `search_recordings` | BM25 keyword, vector, forced HNSW ANN, automatic, or hybrid search |
| `list_tags` | Tag catalog and recording counts |
| `get_meeting_notes` | Agenda and notes by event or linked recording |
| `list_comments` | Open/resolved recording comments |
| `add_recording_tags` / `remove_recording_tags` | Change recording tags |
| `update_meeting_notes` | Update agenda/notes with optional conflict detection |
| `add_comment` / `update_comment` / `set_comment_status` | Add, edit, resolve, or reopen comments |

Resources use stable `almrecorder://` URIs for recordings, transcripts, comments, and tags. The
server also includes `prepare_meeting_follow_up` and `weekly_recap` prompt templates.

Read `almrecorder://help` from any connected MCP client for concise model-oriented mode, filter,
permission, pagination, and recovery guidance. The complete generated-style contract reference is
in [mcp-reference.md](mcp-reference.md).

Search and browse share these filters:

- `tags` with `tag_match: "all" | "any"` (`all` by default)
- `speaker_ids` and `sources` (any value matches)
- `calendar_event_ids`
- inclusive `date_from` and `date_to`
- `has_transcript`, `has_open_comments`, and browse `text`

Search modes are `keyword`, `semantic`, `ann`, `hybrid`, and `auto`; `exact` remains a deprecated
alias for `keyword`. `semantic` is vector-only and can use an exact filtered cosine scan for recall.
`ann` always uses vectorlite HNSW. Responses report the actual mode and vector strategy, filtered
index counts and `complete`. The raw shared-index ANN candidate count is privacy-redacted because
it can include locally hidden recordings; ANN therefore reports `complete: false` conservatively.

## Privacy and behavior

- The app listens on a Unix-domain socket inside the user's AlmRecorder Application Support
  directory. The directory, credentials, and socket are restricted to the current macOS user.
- The bridge authenticates every app request with a rotatable 256-bit token.
- Metadata reads are the baseline. Transcript-derived content and writes are separate Settings
  grants; note/comment writes require both content and write access.
- Every recording detail view has an **Allow MCP clients to access this recording** switch. Tags
  also have a **Hide from MCP** switch in Settings → Tags. Either denial wins.
- A recording hidden directly or by a tag is treated as nonexistent across listing, direct lookup,
  keyword/semantic/ANN/hybrid search, resources, prompts, comments, meeting notes, writes, and
  aggregate/index statistics. Direct or cached IDs return `not_found`.
- Privacy-blocking tags are local-only controls: they are omitted from the MCP tag catalog and MCP
  clients cannot add or remove them. Changing recording or tag privacy cancels active MCP work.
- Hidden transcript lines never appear in MCP transcript or search results.
- MCP semantic search only uses an embedding model that is already loaded. It never initiates a
  model download.
- Mutations and reads are recorded in `mcp_audit_log` without content or tokens. Comments support retry-safe idempotency keys, and
  comments and meeting notes support optimistic-concurrency timestamps.
- Requests have socket deadlines, per-client concurrency/rate limits, a semantic single-flight
  limit, and end-to-end cancellation. Permission, token, and recording-privacy changes cancel
  active work.
- AlmRecorder itself does not upload recording data, but an MCP client may send retrieved data to
  an external or cloud model. Enable access only for recordings appropriate for that client.
- Rotate the token immediately if a copied client configuration is exposed.
