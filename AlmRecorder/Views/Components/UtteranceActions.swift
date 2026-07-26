import SwiftUI
import GRDB

/// Shared utterance mutations for every surface that renders a transcript line.
///
/// "Mark as trash" is the universal labeling gesture: it soft-hides the line (reversible from
/// the recording's hidden-lines footer / review inbox), TEACHES the bad-exemplar memory, and
/// kicks the retroactive sweep so lookalikes across the whole library surface for review.
/// Edits preserve the original ASR text (revertible) and queue re-embedding.
enum UtteranceActionService {

    /// Soft-hide as user-confirmed trash. Never deletes anything.
    static func markTrash(utteranceId: Int64) async {
        await Task.detached {
            try? GRDBDatabaseManager.shared.write { db in
                try UtteranceReviewStore.hide(db, utteranceId: utteranceId, status: .userHidden)
                if let recordingId = try Int64.fetchOne(
                    db, sql: "SELECT recording_id FROM utterances WHERE id = ?", arguments: [utteranceId]) {
                    try UtteranceReviewStore.rebuildFullTranscript(db, recordingId: recordingId)
                }
            }
        }.value
        await MainActor.run {
            TranscriptCleanupQueueManager.shared.scheduleExemplarSweep()
        }
    }

    /// Replace the line's text with user provenance (original kept, revertible).
    static func saveEdit(utteranceId: Int64, newText: String) async {
        let text = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        await Task.detached {
            try? GRDBDatabaseManager.shared.write { db in
                try UtteranceReviewStore.applyCorrection(db, utteranceId: utteranceId, newText: text,
                                                         source: .user, status: .userCorrected)
                if let recordingId = try Int64.fetchOne(
                    db, sql: "SELECT recording_id FROM utterances WHERE id = ?", arguments: [utteranceId]) {
                    try UtteranceReviewStore.rebuildFullTranscript(db, recordingId: recordingId)
                }
            }
        }.value
    }

    enum RetranscribeLineResult: Equatable {
        case replaced(String)
        case unchanged
        case failed(String)

        var note: String {
            switch self {
            case .replaced: return "Updated"
            case .unchanged: return "Same text"
            case .failed(let reason): return reason
            }
        }
    }

    /// Re-transcribe JUST this line: cut its audio span (±0.3s), re-run the selected whisper
    /// model on it, and apply the result as a revertible correction. "No speech" usually means
    /// the line was hallucinated over silence — the message says so.
    static func retranscribeLine(utteranceId: Int64) async -> RetranscribeLineResult {
        struct Context {
            let recordingId: Int64
            let startTime: Double
            let endTime: Double
            let oldText: String
            let audioPath: String
            let language: String?
        }
        let context: Context? = (try? GRDBDatabaseManager.shared.read { db -> Context? in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT u.recording_id AS rid, u.start_time AS s, u.end_time AS e, u.text AS t,
                       r.file_path AS p, r.language AS lang
                FROM utterances u JOIN recordings r ON r.id = u.recording_id
                WHERE u.id = ?
            """, arguments: [utteranceId]),
                  let path = row["p"] as String? else { return nil }
            return Context(recordingId: row["rid"], startTime: row["s"], endTime: row["e"],
                           oldText: row["t"], audioPath: path, language: row["lang"])
        }) ?? nil
        guard let context, FileManager.default.fileExists(atPath: context.audioPath) else {
            return .failed("Audio file not available")
        }

        let variant = GlobalModelSettings.shared.selectedWhisperVariant ?? WhisperModelVariant.defaultVariant()
        guard WhisperModelManager.shared.isModelDownloaded(variant),
              let modelPath = WhisperModelManager.shared.getModelPath(for: variant) else {
            return .failed("Whisper model not downloaded")
        }

        do {
            let audioData = try await AudioSegmentExtractor.shared.extractSegment(
                from: context.audioPath, startTime: context.startTime, endTime: context.endTime, padding: 0.3)
            let clipPath = FileManager.default.temporaryDirectory
                .appendingPathComponent("retranscribe_line_\(UUID().uuidString).wav").path
            try audioData.write(to: URL(fileURLWithPath: clipPath))
            defer { try? FileManager.default.removeItem(atPath: clipPath) }

            let wavPath = try await VoxtralAudioConverter().convertToWAV(audioFile: clipPath, deleteOriginal: false)
            defer { try? FileManager.default.removeItem(atPath: wavPath) }

            let detailed = try await WhisperProcessRunner().runTranscriptionDetailed(
                modelPath: modelPath.path, audioPath: wavPath, language: context.language)
            let newText = detailed.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !newText.isEmpty else {
                return .failed("No speech recognized — likely silence (Mark as trash?)")
            }
            if TranscriptSuspicionScorer.normalizedText(newText) == TranscriptSuspicionScorer.normalizedText(context.oldText) {
                return .unchanged
            }
            try GRDBDatabaseManager.shared.write { db in
                try UtteranceReviewStore.applyCorrection(db, utteranceId: utteranceId, newText: newText,
                                                         source: .user, status: .userCorrected,
                                                         verifierResultJSON: #"{"source":"line_retranscribe"}"#)
                try UtteranceReviewStore.rebuildFullTranscript(db, recordingId: context.recordingId)
            }
            return .replaced(newText)
        } catch {
            // whisper throws "No transcription output generated" on silent spans — same meaning.
            if error.localizedDescription.localizedCaseInsensitiveContains("no transcription") {
                return .failed("No speech recognized — likely silence (Mark as trash?)")
            }
            return .failed(error.localizedDescription)
        }
    }
}

/// Right-click actions (Edit line… / Mark as trash) plus the edit sheet, attachable to ANY
/// utterance row via `.utteranceActions(utteranceId:text:onChange:)`. Surfaces without an easy
/// refetch can omit `onChange` — the row ghosts itself locally after a trash action.
struct UtteranceActionsModifier: ViewModifier {
    let utteranceId: Int64?
    let text: String
    var onChange: (() -> Void)?

    @State private var showEdit = false
    @State private var editText = ""
    @State private var trashedLocally = false
    @State private var isRetranscribing = false
    @State private var resultNote: String?

    func body(content: Content) -> some View {
        content
            .opacity(trashedLocally ? 0.3 : 1)
            .overlay(alignment: .topTrailing) {
                if trashedLocally {
                    badge("Trashed", systemImage: "trash")
                } else if isRetranscribing {
                    HStack(spacing: 4) {
                        ProgressView().scaleEffect(0.4)
                        Text("Re-transcribing…").font(.caption2.bold())
                    }
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.blue.opacity(0.12))
                    .foregroundColor(.blue)
                    .clipShape(Capsule())
                    .padding(6)
                } else if let note = resultNote {
                    badge(note, systemImage: "info.circle")
                }
            }
            .contextMenu {
                if let id = utteranceId, !trashedLocally, !isRetranscribing {
                    Button {
                        editText = text
                        showEdit = true
                    } label: {
                        Label("Edit line…", systemImage: "pencil")
                    }
                    Button {
                        retranscribeLine(id)
                    } label: {
                        Label("Re-transcribe line", systemImage: "arrow.counterclockwise")
                    }
                    Button(role: .destructive) {
                        trash(id)
                    } label: {
                        Label("Mark as trash", systemImage: "trash")
                    }
                }
            }
            .sheet(isPresented: $showEdit) { editSheet }
    }

    private func badge(_ note: String, systemImage: String) -> some View {
        Label(note, systemImage: systemImage)
            .font(.caption2.bold())
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Color.orange.opacity(0.15))
            .foregroundColor(.orange)
            .clipShape(Capsule())
            .padding(6)
            .lineLimit(1)
    }

    private func trash(_ id: Int64) {
        trashedLocally = true
        Task {
            await UtteranceActionService.markTrash(utteranceId: id)
            onChange?()
        }
    }

    /// Cut this line's audio span and run whisper on just it; the result lands as a revertible
    /// correction. Feedback shows inline ("Updated" / "Same text" / why it failed).
    private func retranscribeLine(_ id: Int64) {
        isRetranscribing = true
        Task {
            let result = await UtteranceActionService.retranscribeLine(utteranceId: id)
            isRetranscribing = false
            resultNote = result.note
            if case .replaced = result { onChange?() }
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            resultNote = nil
        }
    }

    private var editSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit transcript line").font(.headline)
            Text("The original text is kept and can be restored anytime.")
                .font(.caption).foregroundColor(.secondary)
            TextEditor(text: $editText)
                .font(.body)
                .frame(minHeight: 80)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
            HStack {
                Spacer()
                Button("Cancel") { showEdit = false }
                Button("Save") {
                    if let id = utteranceId {
                        let text = editText
                        Task {
                            await UtteranceActionService.saveEdit(utteranceId: id, newText: text)
                            onChange?()
                        }
                    }
                    showEdit = false
                }
                .buttonStyle(.borderedProminent)
                .disabled(editText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
        .frame(minWidth: 420)
    }
}

extension View {
    /// Attach Edit/Mark-as-trash actions (context menu + edit sheet) to an utterance row.
    func utteranceActions(utteranceId: Int64?, text: String, onChange: (() -> Void)? = nil) -> some View {
        modifier(UtteranceActionsModifier(utteranceId: utteranceId, text: text, onChange: onChange))
    }
}
