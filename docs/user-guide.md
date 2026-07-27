# AlmRecorder User Guide

AlmRecorder records, imports, transcribes, searches, and organizes audio locally on a Mac. This
guide covers the prebuilt release. For source builds, see [CONTRIBUTING.md](../CONTRIBUTING.md).

## Contents

- [Install AlmRecorder](#install-almrecorder)
- [Complete first-run setup](#complete-first-run-setup)
- [Choose and manage models](#choose-and-manage-models)
- [Navigate the app](#navigate-the-app)
- [Record a meeting](#record-a-meeting)
- [Import audio and Voice Memos](#import-audio-and-voice-memos)
- [Manage the processing queue](#manage-the-processing-queue)
- [Open and edit a recording](#open-and-edit-a-recording)
- [Search recordings](#search-recordings)
- [Organize recordings and speakers](#organize-recordings-and-speakers)
- [Review transcript cleanup](#review-transcript-cleanup)
- [Connect calendar meetings](#connect-calendar-meetings)
- [Connect an MCP client](#connect-an-mcp-client)
- [Back up or remove local data](#back-up-or-remove-local-data)
- [Keyboard shortcuts](#keyboard-shortcuts)
- [Troubleshooting](#troubleshooting)

## Install AlmRecorder

The prebuilt release requires:

- macOS 14 Sonoma or later;
- an Apple Silicon Mac;
- enough free disk space for the models selected during setup.

The setup wizard recommends at least 16 GB of memory. Lower-memory Macs can use lighter models,
with reduced speed or quality for some features.

1. Download the latest `AlmRecorder-<version>.dmg` from
   [GitHub Releases](https://github.com/ViktorAlm/AlmRecorder/releases/latest).
2. Open the disk image.
3. Drag **AlmRecorder** to **Applications**.
4. On the first launch, right-click AlmRecorder and choose **Open**. Confirm **Open** in the
   Gatekeeper dialog.
5. If macOS still blocks the app, open **System Settings → Privacy & Security**, scroll to the
   security message for AlmRecorder, and choose **Open Anyway**.

The hobby release is ad-hoc signed and is not Apple-notarized, which causes this one-time warning.

## Complete first-run setup

The setup wizard has five steps.

### 1. System check

AlmRecorder checks memory, processor count, and free disk space. It uses this information to
recommend local models appropriate for the Mac.

### 2. Permissions

Grant only the capabilities you intend to use:

| Permission | Used for | Required? |
|---|---|---|
| Microphone | Capturing your microphone track | Required for microphone recording |
| Screen Recording | Capturing system and meeting audio | Required only for system audio |
| Calendar | Matching recordings to calendar events | Optional |
| Notifications | Offering to record upcoming meetings | Optional |
| Voice Memos folder | Reading and importing Apple Voice Memos | Optional |

macOS places system-audio capture under the Screen Recording permission even though AlmRecorder
uses it to capture audio. After granting it, quit and reopen AlmRecorder once.

Permissions can be changed later under **System Settings → Privacy & Security**. Run the wizard
again from **Settings → General → Run Setup Again**.

### 3. Models

Choose **Download Models** to install the recommended transcription, AI, and search models.
Downloads continue in the background if the wizard is closed. You can skip this step and install
models later from **Settings → Models**.

### 4. Voice Memos

Choose **Connect Voice Memos Folder** if AlmRecorder should read and process Apple Voice Memos.
macOS remembers the selected-folder permission. This step can be skipped.

### 5. Finish

Choose **Start Using AlmRecorder**. The Dashboard opens and any unfinished model downloads remain
visible in the app.

## Choose and manage models

Open **Settings** with the sidebar gear or `Command-,`.

- **Transcription** selects the default engine for new jobs.
- **Models** downloads, selects, or removes local transcription, Gemma, and embedding models.
- The first-run recommendation is the simplest starting point.

AlmRecorder supports Whisper, the local LLM transcription backends, and VibeVoice. A downloaded
embedding model enables semantic search. Gemma models power optional local summaries, tags, and
audio-assisted transcript verification.

Models are downloaded from their public providers. Recording audio and transcript text are not
sent with a model download.

Removing an unused model frees disk space but disables features that depend on that model until it
is downloaded again. Removing a model does not delete recordings or transcripts.

## Navigate the app

| Area | Purpose |
|---|---|
| Dashboard | Start or import recordings, open recent items, and browse by date, speaker, tag, or source |
| Search | Run text or semantic searches across transcripts |
| Meetings | Match recordings to optional calendar events and edit meeting details |
| Record | Capture microphone and system audio |
| People | Review and manage speaker identities across recordings |
| Review | Resolve suspicious or corrected transcript lines |
| Queue | Monitor transcription and background processing |
| Settings | Configure recording, models, speakers, tags, appearance, and MCP access |

The Dashboard is the main library view. Choose a recent recording to open it, or choose **See all**
to open the complete history. The application menus also provide direct links to Import, Library,
History, Voice Memos, Models, and batch processing.

## Record a meeting

1. Choose **Start Recording** on the Dashboard or open **Record** in the sidebar.
2. Check the source cards:
   - **Microphone** captures your local microphone;
   - **System audio** captures remote participants or other audio playing on the Mac.
3. If system audio is unavailable, grant Screen Recording permission and relaunch the app.
   Microphone-only recording still works.
4. Optionally expand **Transcription Settings** before starting to override the default run
   settings.
5. Use headphones when practical to keep system audio out of the microphone track.
6. Choose the large record button to start. Live levels show whether each track is active.
7. Choose **Stop recording** when finished.

The tracks are queued for transcription and become available from the Dashboard and History. If an
older meeting appears as duplicate microphone and system recordings, use
**Settings → General → Merge Meeting Tracks**.

## Import audio and Voice Memos

Choose **Import** on the Dashboard or use `Command-O`.

### Import audio files

1. Choose **Import Files**, or drag supported audio files onto the Import page.
2. Select the files to process.
3. Review the current transcription settings.
4. Choose **Transcribe Selected**.

For a larger group of files, use **Transcription → Batch Transcribe** from the menu bar. Imported
items enter the same processing queue as new recordings.

### Import Voice Memos

1. Choose **Voice Memos Folder**.
2. Select the Voice Memos recording folder when macOS asks.
3. Select individual memos or use **Select All**.
4. Choose **Transcribe Selected**.

The Voice Memos monitor can scan for new memos and process pending items. Reconnect the folder if it
was moved or its macOS permission was revoked.

## Manage the processing queue

The status strip appears while work is active. Open **Queue** to inspect all jobs.

- Pending jobs wait for their turn.
- Active jobs show their current phase and progress.
- Completed jobs can be cleared from the queue display.
- Failed jobs can be retried after correcting the reported problem.
- A job waiting for a model resumes after the required model is available.

Large transcription, embedding, speaker, cleanup, and insight tasks share local compute resources.
It is normal for background work to wait while a higher-priority transcription is active.

## Open and edit a recording

Select a recording from the Dashboard, a filtered result, History, Search, Meetings, or a person
profile.

The recording detail view supports:

- editing the title;
- playing and scrubbing the audio;
- viewing local summaries and topics when generated;
- adding or removing tags;
- jumping to individual transcript lines;
- editing transcript text and reverting an edit;
- renaming a speaker globally or reassigning a line;
- copying the transcript;
- exporting TXT, Markdown, SRT, or VTT;
- re-transcribing the recording;
- running transcript cleanup.

**Re-transcribe** replaces the current transcript and speaker assignments. Export or back up
anything you need before confirming it.

## Search recordings

### Dashboard search

The Dashboard search field filters the library. Filters can also be built by selecting a date
group, speaker, tag, or recording source. Active filters appear as removable chips.

### Search page

Open **Search** and choose a mode:

- **Text** finds matching words in transcripts.
- **Semantic** finds related meaning using the selected local embedding model.

Semantic search requires a downloaded and loaded embedding model. If indexing is still in
progress, the Search page shows coverage and queue status. Text search remains available without
an embedding model.

MCP clients additionally support keyword, vector, forced ANN, hybrid, and automatic search with
structured filters. See the [MCP guide](mcp.md) and
[MCP contract reference](mcp-reference.md).

## Organize recordings and speakers

### Tags

Add tags from a recording detail view. Create, rename, and delete the shared tag catalog under
**Settings → Tags**. Deleting a tag removes it from associated recordings but does not delete the
recordings.

The Dashboard can browse or filter recordings by tag.

### People and speakers

Open **People** to view speaker identities found across recordings. Speaker names and corrections
remain local. Use the management controls to review suggested identities, rename profiles, and
correct merges or assignments.

Speaker diarization is an automated estimate. Confirm important labels by listening to the
associated audio.

## Review transcript cleanup

Choose **Clean up transcript** in a recording to scan for likely transcription artifacts. Open
**Review** to inspect pending lines.

- **Keep** marks the line as valid.
- **Fix** saves corrected text while retaining the original for reversal.
- **Hide** soft-hides the line.
- **Undo** or **Revert** restores a hidden or changed line.
- **Verify now** uses an installed compatible Gemma model to compare flagged spans with their
  local audio.

Automatic cleanup is intentionally conservative. Review decisions are reversible, and the source
audio remains the final authority.

## Connect calendar meetings

Calendar integration is optional.

1. Open **Meetings**.
2. Choose **Allow Calendar Access**.
3. Choose **Sync Calendar** after relevant recordings exist.
4. Review proposed matches and confirm or dismiss them.
5. Open a meeting to view linked recordings, attendees, agenda, and notes.

Under **Settings → General**, **Offer to record my meetings** enables notifications before meetings
with other participants. AlmRecorder must be running, and Calendar and Notifications permissions
must be granted.

## Connect an MCP client

1. Open **Settings → MCP Access**.
2. Enable **Enable local MCP server**.
3. Enable content access only if the client should read notes, comments, summaries, or transcript
   search.
4. Enable write access only if the client should change tags, notes, or comments.
5. Choose **Copy configuration** and add the configuration to the MCP client.
6. Keep AlmRecorder open while the client is connected.

The configuration contains a secret token. Treat it like a password: do not commit it, paste it
into an issue, or share it. Choose **Rotate token** if it may have been exposed, then replace the
configuration in every client.

Metadata access is the baseline. Transcript-derived content and writes are separate grants. Full
tool arguments, filters, search modes, permissions, pagination, and recovery behavior are
documented in the [MCP contract reference](mcp-reference.md).

## Back up or remove local data

AlmRecorder stores its managed database, recordings, models, and service state below:

```text
~/Library/Application Support/AlmRecorder/
```

For a manual backup:

1. Quit AlmRecorder so the database is closed cleanly.
2. Copy the complete `AlmRecorder` Application Support folder to protected storage.
3. Treat the backup as private because it can contain recordings, transcripts, speaker names, and
   the MCP credential.

After restoring on another Mac, reconnect Voice Memos or other external folders if macOS requests
permission again.

To permanently remove the in-app library, use **Settings → General → Clear All Data**. Read the
confirmation carefully: the operation removes recordings, transcriptions, and settings and cannot
be undone.

## Keyboard shortcuts

| Shortcut | Action |
|---|---|
| `Command-N` | Start a new recording |
| `Command-.` | Stop the active recording |
| `Command-O` | Import audio files |
| `Command-1` | Dashboard |
| `Command-2` | Search |
| `Command-3` | Record |
| `Command-4` | Queue |
| `Command-,` | Settings |

The **File**, **Recording**, **Search**, **Transcription**, **View**, and **Models** menus list
additional actions and shortcuts.

## Troubleshooting

### macOS blocks the first launch

Right-click the app and choose **Open**. If needed, approve it under
**System Settings → Privacy & Security**. This is expected for the unsigned hobby release.

### Microphone or system audio is missing

Check the corresponding permission under **System Settings → Privacy & Security**. Screen
Recording permission requires one app restart before system audio capture becomes available.

### A model-dependent feature is unavailable

Open **Settings → Models** and confirm the required model is downloaded and selected. Check free
disk space and network access. Model downloads can continue in the background.

### Semantic search is unavailable or incomplete

Install and load an embedding model, then allow the embedding queue to finish indexing. The Search
page reports current index coverage. Text search does not require embeddings.

### An imported item fails

Open **Queue** for the error and retry controls. Confirm the original audio file still exists and
that AlmRecorder retains access to its folder.

### Voice Memos are not found

Return to Import and choose **Voice Memos Folder** again. Select the folder requested by the app
and allow macOS access.

### An MCP client cannot connect

Confirm that AlmRecorder is open, the MCP server is enabled, and the client uses the latest copied
configuration. Check the content and write grants required by the requested operation. Rotate and
replace the token if its state is uncertain.

### Get logs or report a problem

Use **Help → Show Logs** for diagnostic information and **Help → Report Issue** for the public issue
tracker. Before sharing anything, inspect and redact local filenames, paths, recording metadata,
names, transcript text, and other private content. Never attach audio, the AlmRecorder database, an
MCP configuration, or a private evaluation artifact to a public issue.
