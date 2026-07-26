import SwiftUI

struct SpeakerUnmergeSheet: View {
    let speaker: SpeakerProfile
    @ObservedObject var viewModel: SpeakerManagementViewModel
    @Binding var isPresented: Bool
    
    @State private var selectedSpeakersToRestore: Set<String> = []
    @State private var mergeHistory: [SpeakerMergeHistory] = []
    @State private var mergedSpeakersData: [(history: SpeakerMergeHistory, data: SerializedSpeakerData)] = []
    @State private var isLoading = true
    @State private var showConfirmation = false
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            header
            
            Divider()
            
            // Content
            if isLoading {
                ProgressView("Loading merge history...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if mergedSpeakersData.isEmpty {
                emptyState
            } else {
                mergedSpeakersList
            }
            
            // Footer buttons
            footerButtons
        }
        .frame(width: 600, height: 500)
        .onAppear {
            loadMergeHistory()
        }
        .alert("Confirm Unmerge", isPresented: $showConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Unmerge", role: .destructive) {
                performUnmerge()
            }
        } message: {
            Text("This will restore \(selectedSpeakersToRestore.isEmpty ? "all" : "\(selectedSpeakersToRestore.count)") speaker(s) and reassign their utterances. Continue?")
        }
    }
    
    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Unmerge Speakers")
                    .font(.title2)
                    .fontWeight(.bold)
                
                Text("Select speakers to restore from \(speaker.displayName)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            Button("Cancel") {
                isPresented = false
            }
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
    }
    
    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.2.slash")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            
            Text("No Merge History")
                .font(.title3)
                .fontWeight(.semibold)
            
            Text("This speaker has not been merged with any other speakers")
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    private var mergedSpeakersList: some View {
        VStack(spacing: 0) {
            // Select all/none buttons
            HStack {
                Button("Select All") {
                    selectedSpeakersToRestore = Set(mergedSpeakersData.map { $0.data.uuid })
                }
                .disabled(selectedSpeakersToRestore.count == mergedSpeakersData.count)
                
                Button("Select None") {
                    selectedSpeakersToRestore.removeAll()
                }
                .disabled(selectedSpeakersToRestore.isEmpty)
                
                Spacer()
                
                Text("\(selectedSpeakersToRestore.count) of \(mergedSpeakersData.count) selected")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            
            Divider()
            
            // List of merged speakers
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(mergedSpeakersData, id: \.data.uuid) { item in
                        MergedSpeakerRow(
                            history: item.history,
                            speakerData: item.data,
                            isSelected: selectedSpeakersToRestore.contains(item.data.uuid),
                            onToggle: {
                                if selectedSpeakersToRestore.contains(item.data.uuid) {
                                    selectedSpeakersToRestore.remove(item.data.uuid)
                                } else {
                                    selectedSpeakersToRestore.insert(item.data.uuid)
                                }
                            }
                        )
                    }
                }
                .padding()
            }
        }
    }
    
    private var footerButtons: some View {
        HStack {
            // Info about what will happen
            HStack(spacing: 4) {
                Image(systemName: "info.circle")
                    .foregroundColor(.blue)
                
                Text(selectedSpeakersToRestore.isEmpty ? 
                    "All speakers will be restored" : 
                    "\(selectedSpeakersToRestore.count) speaker(s) will be restored")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            Button("Cancel") {
                isPresented = false
            }
            .keyboardShortcut(.escape)
            
            Button("Unmerge Selected") {
                showConfirmation = true
            }
            .buttonStyle(.borderedProminent)
            .disabled(mergedSpeakersData.isEmpty)
            .keyboardShortcut(.return)
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
    }
    
    private func loadMergeHistory() {
        Task {
            do {
                let repo = SpeakerMergeHistoryRepository()
                mergedSpeakersData = try repo.getMergedSpeakers(for: speaker.uuid)
                
                // Select all by default
                selectedSpeakersToRestore = Set(mergedSpeakersData.map { $0.data.uuid })
                
                await MainActor.run {
                    isLoading = false
                }
            } catch {
                VoxtralLogger.shared.error("[SpeakerUnmerge] Failed to load merge history: \(error)")
                await MainActor.run {
                    isLoading = false
                }
            }
        }
    }
    
    private func performUnmerge() {
        Task {
            let uuidsToRestore = selectedSpeakersToRestore.isEmpty ? nil : Array(selectedSpeakersToRestore)
            await viewModel.unmergeSpeaker(speaker.uuid, restoreUUIDs: uuidsToRestore)
            
            await MainActor.run {
                isPresented = false
            }
        }
    }
}

// MARK: - Merged Speaker Row

struct MergedSpeakerRow: View {
    let history: SpeakerMergeHistory
    let speakerData: SerializedSpeakerData
    let isSelected: Bool
    let onToggle: () -> Void
    
    var body: some View {
        HStack(spacing: 12) {
            // Selection checkbox
            Button(action: onToggle) {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .foregroundColor(isSelected ? .accentColor : .secondary)
            }
            .buttonStyle(.plain)
            
            // Speaker avatar
            Circle()
                .fill(avatarColor)
                .frame(width: 40, height: 40)
                .overlay(
                    Text(initials)
                        .foregroundColor(.white)
                        .fontWeight(.semibold)
                )
            
            // Speaker info
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(displayName)
                        .fontWeight(.medium)
                    
                    if speakerData.name == nil {
                        Text("(Unnamed)")
                            .foregroundColor(.secondary)
                            .italic()
                    }
                }
                
                HStack(spacing: 12) {
                    Label("\(speakerData.utteranceCount) utterances", systemImage: "text.bubble")
                        .font(.caption)
                    
                    Label(formatDuration(speakerData.totalDuration), systemImage: "clock")
                        .font(.caption)
                    
                    Label("Merged \(history.mergedAt.formatted(.relative(presentation: .named)))", systemImage: "calendar")
                        .font(.caption)
                }
                .foregroundColor(.secondary)
            }
            
            Spacer()
            
            // Original utterance count
            if !speakerData.originalUtteranceIds.isEmpty {
                Text("\(speakerData.originalUtteranceIds.count) utterances")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.1))
                    .cornerRadius(4)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(isSelected ? Color.accentColor.opacity(0.1) : Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? Color.accentColor.opacity(0.3) : Color.clear, lineWidth: 1)
        )
    }
    
    private var displayName: String {
        speakerData.name ?? "Speaker \(speakerData.uuid.prefix(8))"
    }
    
    private var initials: String {
        if let name = speakerData.name {
            let components = name.components(separatedBy: " ")
            let initials = components.compactMap { $0.first }.prefix(2)
            return String(initials).uppercased()
        }
        return String(speakerData.uuid.prefix(2)).uppercased()
    }
    
    private var avatarColor: Color {
        Color.speakerColor(for: speakerData.uuid)
    }
    
    private func formatDuration(_ seconds: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute, .second]
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: seconds) ?? "0s"
    }
}