import SwiftUI

struct SpeakerReviewWizard: View {
    @StateObject private var viewModel = SpeakerReviewViewModel()
    @Binding var isPresented: Bool

    // Mode 1: Post-transcription
    private let recordingId: Int64
    private let audioFilePath: String
    private let transcriptionResult: TranscriptionResult?

    // Mode 2: On-demand from Speaker Management
    private let speakerProfiles: [SpeakerProfile]?

    let onComplete: (SpeakerAssignmentResult) -> Void

    @State private var showingCancelAlert = false
    @State private var selectedMatchId: String?

    /// Mode 1: Post-transcription review
    init(
        isPresented: Binding<Bool>,
        recordingId: Int64,
        audioFilePath: String,
        transcriptionResult: TranscriptionResult,
        onComplete: @escaping (SpeakerAssignmentResult) -> Void
    ) {
        self._isPresented = isPresented
        self.recordingId = recordingId
        self.audioFilePath = audioFilePath
        self.transcriptionResult = transcriptionResult
        self.speakerProfiles = nil
        self.onComplete = onComplete
    }

    /// Mode 2: On-demand review/merge from Speaker Management
    init(
        isPresented: Binding<Bool>,
        speakers: [SpeakerProfile],
        onComplete: @escaping (SpeakerAssignmentResult) -> Void
    ) {
        self._isPresented = isPresented
        self.recordingId = 0
        self.audioFilePath = ""
        self.transcriptionResult = nil
        self.speakerProfiles = speakers
        self.onComplete = onComplete
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerView
            
            Divider()
            
            // Main Content
            if viewModel.session == nil {
                ProgressView("Loading speakers...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onAppear {
                        Task {
                            if let profiles = speakerProfiles {
                                await viewModel.initializeFromProfiles(profiles)
                            } else if let result = transcriptionResult {
                                await viewModel.initializeSession(
                                    recordingId: recordingId,
                                    audioFilePath: audioFilePath,
                                    transcriptionResult: result
                                )
                            }
                        }
                    }
            } else if let speaker = viewModel.currentSpeaker {
                ScrollView {
                    VStack(spacing: 24) {
                        // Speaker Info Card
                        speakerInfoCard(speaker)
                        
                        // Audio Examples
                        if !speaker.exampleSegments.isEmpty {
                            audioExamplesSection(speaker)
                        }

                        // From this meeting (calendar attendees, fused with voice)
                        meetingSuggestionsSection

                        // Potential Matches
                        potentialMatchesSection
                        
                        // New Speaker Option
                        newSpeakerSection
                    }
                    .padding()
                }
            } else {
                Text("No speakers to review")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            
            Divider()
            
            // Footer
            footerView
        }
        .frame(width: 800, height: 700)
        .alert("Cancel Review?", isPresented: $showingCancelAlert) {
            Button("Continue Review", role: .cancel) { }
            Button("Cancel", role: .destructive) {
                isPresented = false
            }
        } message: {
            Text("Are you sure you want to cancel? Speaker assignments will not be saved.")
        }
    }
    
    // MARK: - Header
    
    private var headerView: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Speaker Review")
                    .font(.title2)
                    .fontWeight(.bold)
                
                Text(viewModel.progressText)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            Button(action: { showingCancelAlert = true }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding()
    }
    
    // MARK: - Speaker Info Card
    
    private func speakerInfoCard(_ speaker: DetectedSpeaker) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                // Speaker Avatar
                Circle()
                    .fill(LinearGradient(
                        colors: [.blue, .purple],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
                    .frame(width: 60, height: 60)
                    .overlay(
                        Text(speaker.displayInitials)
                            .font(.title2)
                            .fontWeight(.bold)
                            .foregroundColor(.white)
                    )

                VStack(alignment: .leading, spacing: 4) {
                    Text(speaker.displayLabel)
                        .font(.headline)
                    
                    HStack(spacing: 16) {
                        Label(speaker.formattedDuration, systemImage: "clock")
                        Label("\(speaker.utteranceCount) segments", systemImage: "text.bubble")
                    }
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                }
                
                Spacer()
                
                // Assignment Status
                if let assignment = viewModel.selectedAssignment {
                    assignmentBadge(assignment)
                }
            }
            
            // Sample Text
            Text("Sample:")
                .font(.subheadline)
                .foregroundColor(.secondary)
            
            Text(speaker.sampleText)
                .font(.body)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(8)
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
        .cornerRadius(12)
    }
    
    private func assignmentBadge(_ assignment: SpeakerAssignment) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
            
            Text(assignment.displayName)
                .font(.subheadline)
                .fontWeight(.medium)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.green.opacity(0.1))
        .cornerRadius(20)
    }
    
    // MARK: - Audio Examples
    
    private func audioExamplesSection(_ speaker: DetectedSpeaker) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Audio Examples", systemImage: "waveform")
                .font(.headline)
            
            ForEach(Array(speaker.exampleSegments.enumerated()), id: \.element.id) { index, segment in
                // Convert AudioSegment to Utterance for TranscriptSegmentView
                TranscriptSegmentView(
                    utterance: Utterance(
                        id: Int64(index),
                        recordingId: 0,
                        utteranceIndex: index,
                        startTime: segment.startTime,
                        endTime: segment.endTime,
                        speaker: segment.speakerTempId,
                        speakerUuid: nil,
                        text: segment.text,
                        confidence: nil,
                        hasEmbedding: false
                    ),
                    displayMode: .card,
                    audioPath: audioFilePath,
                    currentSpeaker: nil
                )
            }
        }
    }
    
    // MARK: - From This Meeting (calendar suggestions)

    @ViewBuilder
    private var meetingSuggestionsSection: some View {
        let meetingSuggestions = viewModel.suggestions.filter { $0.inMeeting }
        if !meetingSuggestions.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Label("From this meeting", systemImage: "calendar")
                    .font(.headline)

                ForEach(meetingSuggestions) { suggestion in
                    SuggestionRow(
                        suggestion: suggestion,
                        isSelected: selectedMatchId == suggestion.id,
                        onSelect: {
                            selectedMatchId = suggestion.id
                            viewModel.assignToSuggestion(suggestion)
                        }
                    )
                }
            }
        }
    }

    // MARK: - Potential Matches

    private var potentialMatchesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Potential Matches", systemImage: "person.2")
                    .font(.headline)
                
                Spacer()
                
                if viewModel.isLoadingMatches {
                    ProgressView()
                        .scaleEffect(0.7)
                }
            }
            
            if viewModel.potentialMatches.isEmpty && !viewModel.isLoadingMatches {
                Text("No similar speakers found in database")
                    .foregroundColor(.secondary)
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(Color(NSColor.controlBackgroundColor))
                    .cornerRadius(8)
            } else {
                ForEach(viewModel.potentialMatches) { match in
                    SpeakerMatchRow(
                        match: match,
                        isSelected: selectedMatchId == match.id,
                        onSelect: {
                            selectedMatchId = match.id
                            viewModel.assignToExistingSpeaker(match.profile)
                        }
                    )
                }
            }
        }
    }
    
    // MARK: - New Speaker Section
    
    private var newSpeakerSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Create New Speaker", systemImage: "person.badge.plus")
                .font(.headline)
            
            VStack(spacing: 12) {
                HStack {
                    Text("Name:")
                        .frame(width: 60, alignment: .trailing)
                    
                    TextField("Enter speaker name", text: $viewModel.newSpeakerName)
                        .textFieldStyle(.roundedBorder)
                }
                
                HStack(alignment: .top) {
                    Text("Notes:")
                        .frame(width: 60, alignment: .trailing)
                        .padding(.top, 8)
                    
                    TextEditor(text: $viewModel.newSpeakerNotes)
                        .font(.body)
                        .frame(height: 60)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.gray.opacity(0.2), lineWidth: 1)
                        )
                }
                
                HStack {
                    Spacer()
                    
                    Button("Create Speaker") {
                        viewModel.createNewSpeaker()
                        selectedMatchId = nil
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(viewModel.newSpeakerName.isEmpty)
                }
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(8)
        }
    }
    
    // MARK: - Footer
    
    private var footerView: some View {
        HStack {
            Button(action: {
                Task {
                    await viewModel.previousSpeaker()
                    selectedMatchId = nil
                }
            }) {
                Label("Previous", systemImage: "chevron.left")
            }
            .disabled(!viewModel.hasPreviousSpeaker)
            
            Spacer()
            
            Button("Skip This Speaker") {
                viewModel.skipSpeaker()
                Task {
                    if viewModel.hasNextSpeaker {
                        await viewModel.nextSpeaker()
                        selectedMatchId = nil
                    }
                }
            }
            .buttonStyle(.bordered)
            
            if viewModel.hasNextSpeaker {
                Button(action: {
                    Task {
                        await viewModel.nextSpeaker()
                        selectedMatchId = nil
                    }
                }) {
                    Label("Next", systemImage: "chevron.right")
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.selectedAssignment == nil)
            } else {
                Button("Complete Review") {
                    Task {
                        if let result = await viewModel.saveAssignments() {
                            onComplete(result)
                            isPresented = false
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.selectedAssignment == nil)
            }
        }
        .padding()
    }
}

// MARK: - Speaker Match Row

struct SpeakerMatchRow: View {
    let match: SpeakerMatch
    let isSelected: Bool
    let onSelect: () -> Void
    
    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                // Selection indicator
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(isSelected ? .accentColor : .secondary)
                
                // Speaker avatar
                Circle()
                    .fill(match.profile.avatarColor)
                    .frame(width: 40, height: 40)
                    .overlay(
                        Text(match.profile.initials)
                            .foregroundColor(.white)
                            .fontWeight(.semibold)
                    )
                
                // Speaker info
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(match.profile.displayName)
                            .fontWeight(.medium)
                        
                        // Confidence badge
                        Text("\(match.similarityPercentage)%")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundColor(confidenceColor(match.similarity))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(confidenceColor(match.similarity).opacity(0.1))
                            .cornerRadius(4)
                    }
                    
                    Text("Last seen: \(match.profile.lastSeenFormatted)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                // Example recordings
                if !match.exampleRecordings.isEmpty {
                    VStack(alignment: .trailing, spacing: 2) {
                        ForEach(match.exampleRecordings.prefix(2)) { recording in
                            Text(recording.title)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Color.accentColor.opacity(0.1) : Color(NSColor.controlBackgroundColor))
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
    }
    
    private func confidenceColor(_ similarity: Float) -> Color {
        if similarity >= 0.85 {
            return .green
        } else if similarity >= 0.70 {
            return .orange
        } else {
            return .red
        }
    }
}

// MARK: - Suggestion Row (calendar + voice fused)

struct SuggestionRow: View {
    let suggestion: SpeakerSuggestion
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(isSelected ? .accentColor : .secondary)

                Image(systemName: "calendar")
                    .foregroundColor(.accentColor)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 2) {
                    Text(suggestion.title)
                        .fontWeight(.medium)
                    Text(suggestion.reason)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                if case .newFromAttendee = suggestion.kind {
                    Text("New")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.blue)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.blue.opacity(0.1))
                        .cornerRadius(4)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Color.accentColor.opacity(0.1) : Color(NSColor.controlBackgroundColor))
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
    }
}