import SwiftUI

/// Hero row at the top of the dashboard: start/open recording, import, and the library
/// search field with a semantic-search handoff.
struct DashboardQuickActionsRow: View {
    @ObservedObject private var recorder = MeetingRecorder.shared
    @Binding var searchText: String
    let onStartRecording: () -> Void
    let onImport: () -> Void
    let onSubmitSearch: () -> Void
    let onClearSearch: () -> Void
    let onSemanticSearch: () -> Void

    @State private var isPulsing = false
    @State private var isHoveringSemantic = false

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            HStack(spacing: 12) {
                recordButton

                Button(action: onImport) {
                    Label("Import", systemImage: "square.and.arrow.down")
                }
                .glassButton()
                .controlSize(.large)
                .help("Import audio files for transcription")

                Spacer(minLength: 12)

                searchField
            }

            if !searchText.isEmpty {
                semanticSearchButton
            }
        }
    }

    // MARK: - Record

    private var recordButton: some View {
        Button(action: onStartRecording) {
            HStack(spacing: 8) {
                if recorder.isRecording {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 8, height: 8)
                        .opacity(isPulsing ? 0.35 : 1)
                        .onAppear {
                            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                                isPulsing = true
                            }
                        }
                        .onDisappear { isPulsing = false }
                    Text("Recording")
                    Text(timeString(recorder.duration))
                        .monospacedDigit()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                } else {
                    Label("Start Recording", systemImage: "mic.fill")
                }
            }
        }
        .glassButton(tint: .red, prominent: true)
        .controlSize(.large)
        .help(recorder.isRecording
              ? "Recording in progress — open the Record page"
              : "Records mic + system audio and opens the Record page")
    }

    // MARK: - Search

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
                .font(.body)

            TextField("Search recordings...", text: $searchText)
                .textFieldStyle(.plain)
                .font(.body)
                .onSubmit(onSubmitSearch)

            if !searchText.isEmpty {
                Button(action: onClearSearch) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .cardSurface(cornerRadius: 10)
        .frame(maxWidth: 360)
    }

    private var semanticSearchButton: some View {
        Button(action: onSemanticSearch) {
            HStack(spacing: 6) {
                Image(systemName: "brain")
                Text("Search transcripts semantically")
                Image(systemName: "arrow.right")
            }
            .font(.caption)
            .foregroundColor(.indigo)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .contentSurface(in: Capsule())
            .overlay(
                Capsule().strokeBorder(
                    Color.indigo.opacity(isHoveringSemantic ? 0.4 : 0.15),
                    lineWidth: 1
                )
            )
        }
        .buttonStyle(.plain)
        .onHover { isHoveringSemantic = $0 }
        .animation(.easeInOut(duration: 0.12), value: isHoveringSemantic)
        .help("Run this query as a semantic search over all transcripts")
    }

    private func timeString(_ t: TimeInterval) -> String {
        let total = Int(t)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%02d:%02d", minutes, seconds)
    }
}
