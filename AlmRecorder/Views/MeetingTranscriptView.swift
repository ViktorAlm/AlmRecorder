import SwiftUI

/// Merged "Me vs Them" transcript for a dual-channel meeting. Given one track (mic or system), it
/// finds its sibling by the shared `meeting_<stamp>_` file-name prefix, loads both transcripts, and
/// interleaves them on one timeline — mic = "Me" (right, blue), system = "Them" (left, purple).
struct MeetingTranscriptView: View {
    let recording: Recording

    @Environment(\.dismiss) private var dismiss
    @State private var lines: [MeetingTranscriptMerger.MergedLine] = []
    @State private var loading = true
    @State private var copied = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(minWidth: 560, idealWidth: 640, minHeight: 520, idealHeight: 680)
        .onAppear(perform: load)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "person.2.wave.2.fill")
                .font(.title2).foregroundStyle(.purple)
            VStack(alignment: .leading, spacing: 2) {
                Text("Meeting Transcript").font(.title3).fontWeight(.semibold)
                Text("Me vs Them · merged timeline").font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            Button(action: copyAll) {
                Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.bordered)
            .disabled(lines.isEmpty)
            Button(action: { dismiss() }) {
                Image(systemName: "xmark.circle.fill").font(.title2).foregroundColor(.secondary.opacity(0.6))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(20)
    }

    @ViewBuilder private var content: some View {
        if loading {
            ProgressView("Merging tracks…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if lines.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "waveform.slash").font(.system(size: 40)).foregroundColor(.secondary.opacity(0.4))
                Text("No transcript yet").font(.headline).foregroundColor(.secondary)
                Text("Both tracks may still be transcribing — check the Queue.")
                    .font(.caption).foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(spacing: 12) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        bubble(line)
                    }
                }
                .padding(20)
                .frame(maxWidth: 620)
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func bubble(_ line: MeetingTranscriptMerger.MergedLine) -> some View {
        let isMe = line.source == .mic
        let tint: Color = isMe ? .blue : .purple
        return HStack(alignment: .bottom, spacing: 8) {
            if isMe { Spacer(minLength: 64) }
            VStack(alignment: isMe ? .trailing : .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(line.source.label)
                        .font(.caption).fontWeight(.bold).foregroundColor(tint)
                    Text(timeString(line.start))
                        .font(.caption2).foregroundColor(.secondary)
                }
                Text(line.text)
                    .font(.body).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .background(tint.opacity(0.12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(tint.opacity(0.25), lineWidth: 1))
                    .cornerRadius(12)
            }
            if !isMe { Spacer(minLength: 64) }
        }
    }

    // MARK: - Load + merge

    private func load() {
        guard let prefix = Self.meetingPrefix(for: recording.fileName) else {
            loading = false
            return
        }
        Task {
            let recRepo = GRDBRecordingRepository()
            let uttRepo = GRDBUtteranceRepository()
            let pair = (try? recRepo.getByFileNamePrefix(prefix)) ?? []

            var mic: [MeetingTranscriptMerger.SourceUtterance] = []
            var system: [MeetingTranscriptMerger.SourceUtterance] = []
            for rec in pair {
                guard let rid = rec.id else { continue }
                let utts = (try? uttRepo.getByRecordingId(rid)) ?? []
                let mapped = utts.map {
                    MeetingTranscriptMerger.SourceUtterance(
                        speaker: $0.speaker, start: $0.startTime, end: $0.endTime, text: $0.text)
                }
                if rec.fileName.contains("_system") { system = mapped } else { mic = mapped }
            }
            let merged = MeetingTranscriptMerger.merge(mic: mic, system: system)
            await MainActor.run { lines = merged; loading = false }
        }
    }

    /// "meeting_1700000000_mic.caf" → "meeting_1700000000_"
    static func meetingPrefix(for fileName: String) -> String? {
        let base = (fileName as NSString).deletingPathExtension
        let parts = base.split(separator: "_").map(String.init)
        guard parts.count >= 3, parts[0] == "meeting" else { return nil }
        return "meeting_\(parts[1])_"
    }

    static func isMeetingTrack(_ fileName: String) -> Bool {
        meetingPrefix(for: fileName) != nil
    }

    private func copyAll() {
        let text = lines.map { "\($0.source.label): \($0.text)" }.joined(separator: "\n\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        withAnimation { copied = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { withAnimation { copied = false } }
    }

    private func timeString(_ t: TimeInterval) -> String {
        let total = Int(t)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
