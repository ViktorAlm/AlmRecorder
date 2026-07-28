import SwiftUI

/// Controls the exact speaker pipeline used for new transcriptions.  Presets are immutable so
/// benchmark names remain reproducible; choosing Custom exposes the underlying knobs.
struct SpeakerPipelineSettingsView: View {
    @ObservedObject private var settings = SpeakerPipelineSettings.shared

    var body: some View {
        Form {
            Section("Pipeline profile") {
                Picker("Profile", selection: $settings.selectedProfile) {
                    ForEach(SpeakerPipelineProfile.allCases) { profile in
                        Text(profile.displayName).tag(profile)
                    }
                }
                .pickerStyle(.segmented)

                Text(settings.selectedProfile.explanation)
                    .font(.caption)
                    .foregroundColor(.secondary)

                profileSummary(settings.activeConfiguration)
            }

            if settings.selectedProfile == .custom {
                customControls
            }

            Section("Evaluation") {
                Text("Legacy, Balanced, Highest accuracy, and Targeted Sortformer can be run against the same confirmed test set. Reports include diarization error, word-level speaker error, speaker-count error, identity precision/recall, runtime, and real-time factor. Multi-speaker clips are quarantined from identity scoring.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("Only recordings explicitly confirmed as ‘Speaker gold’ after whole-conversation review are treated as ground truth.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("Continuous global identity") {
                Toggle(
                    "Reconcile voices after new recordings",
                    isOn: $settings.continuousReconciliationEnabled
                )
                Text(
                    "Uses your private calibration labels and held-out safety labels to merge "
                        + "and split automatic People assignments. It writes only when the safety "
                        + "set has zero false merges, and every run can be undone in Evaluation."
                )
                .font(.caption)
                .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    @ViewBuilder
    private func profileSummary(_ configuration: SpeakerPipelineConfiguration) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 5) {
            summaryRow("Diarization", configuration.diarizationBackend.displayName)
            summaryRow(
                "Simultaneous speech",
                configuration.diarizationBackend == .offlineVBx
                    || configuration.diarizationBackend == .offlineVBxTargetedSortformer
                    ? "Preserved + excluded from identity learning"
                    : "No overlap-aware output"
            )
            summaryRow("ASR segmentation", configuration.transcriptionSegmentation.displayName)
            summaryRow("Alignment", configuration.alignmentStrategy.displayName)
            summaryRow(
                "Transcript rows",
                configuration.effectiveUtteranceSegmentation.displayName
            )
            summaryRow("Identity", configuration.identityMatcher.displayName)
            summaryRow("Centroids", configuration.centroidPolicy.displayName)
            summaryRow("Persona grouping", configuration.personaLinkage.displayName)
        }
        .font(.caption)
    }

    @ViewBuilder
    private func summaryRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundColor(.secondary)
            Text(value)
        }
    }

    private var customControls: some View {
        Group {
            Section("Segmentation and alignment") {
                Picker("Diarizer", selection: diarizationBackend) {
                    ForEach(SpeakerDiarizationBackend.allCases) { Text($0.displayName).tag($0) }
                }
                Picker("Transcription segments", selection: $settings.customConfiguration.transcriptionSegmentation) {
                    ForEach(SpeakerTranscriptionSegmentation.allCases) { Text($0.displayName).tag($0) }
                }
                .disabled(settings.customConfiguration.diarizationBackend == .segmentDBSCAN)
                Picker("Timestamp alignment", selection: $settings.customConfiguration.alignmentStrategy) {
                    ForEach(SpeakerAlignmentStrategy.allCases) { Text($0.displayName).tag($0) }
                }
                .disabled(settings.customConfiguration.diarizationBackend == .segmentDBSCAN)
                Picker(
                    "Transcript row splitting",
                    selection: utteranceSegmentation
                ) {
                    ForEach(SpeakerUtteranceSegmentation.allCases) {
                        Text($0.displayName).tag($0)
                    }
                }
                .disabled(settings.customConfiguration.diarizationBackend == .segmentDBSCAN)
                Text(settings.customConfiguration.effectiveUtteranceSegmentation.explanation)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("Diarization") {
                switch settings.customConfiguration.diarizationBackend {
                case .legacyStreaming:
                    floatSlider(
                        "Streaming clustering threshold",
                        value: $settings.customConfiguration.streamingClusteringThreshold,
                        range: 0.50...0.90
                    )
                case .offlineVBx, .offlineVBxTargetedSortformer:
                    Label(
                        "Overlap-aware: keeps simultaneous VBx speaker activity, chooses one "
                            + "display label, and prevents overlapping excerpts from training "
                            + "global identities.",
                        systemImage: "person.2.wave.2"
                    )
                    .font(.caption)
                    .foregroundColor(.secondary)
                    if settings.customConfiguration.diarizationBackend
                        == .offlineVBxTargetedSortformer {
                        Label(
                            "Targets coalesced recording-local utterances with FluidAudio's "
                                + "Offline Sortformer in short context windows, then maps its local slots "
                                + "back to clean global-identity evidence.",
                            systemImage: "scope"
                        )
                        .font(.caption)
                        .foregroundColor(.secondary)
                    }
                    doubleSlider(
                        "VBx clustering distance",
                        value: $settings.customConfiguration.offlineClusteringThreshold,
                        range: 0.35...0.90
                    )
                    doubleSlider(
                        "Window step ratio",
                        value: $settings.customConfiguration.offlineStepRatio,
                        range: 0.10...0.40
                    )
                    doubleSlider(
                        "Minimum embedding segment",
                        value: $settings.customConfiguration.offlineMinimumSegmentDuration,
                        range: 0.0...2.0
                    )
                    Toggle("Recover zero-vote spans", isOn: $settings.customConfiguration.enableZeroVoteReembedding)
                    Toggle("Constrain speaker count", isOn: speakerBoundsEnabled)
                    if settings.customConfiguration.minimumSpeakers != nil {
                        Stepper(
                            "Minimum speakers: \(settings.customConfiguration.minimumSpeakers ?? 1)",
                            value: minimumSpeakers,
                            in: 1...32
                        )
                        Stepper(
                            "Maximum speakers: \(settings.customConfiguration.maximumSpeakers ?? 8)",
                            value: maximumSpeakers,
                            in: (settings.customConfiguration.minimumSpeakers ?? 1)...64
                        )
                    }
                case .segmentDBSCAN:
                    Text("Control pipeline: TinyDiarize cuts each VAD block, then adaptive DBSCAN searches a fixed cosine-distance grid. Its search grid is intentionally frozen so legacy comparisons remain reproducible.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Section("Cross-recording identity") {
                Picker("Matcher", selection: $settings.customConfiguration.identityMatcher) {
                    ForEach(SpeakerIdentityMatcher.allCases) { Text($0.displayName).tag($0) }
                }
                floatSlider(
                    "Similarity threshold",
                    value: $settings.customConfiguration.identitySimilarityThreshold,
                    range: settings.customConfiguration.identityMatcher == .evidenceGraph
                        ? 0.35...0.70
                        : 0.50...0.95
                )
                if settings.customConfiguration.identityMatcher == .evidenceGraph {
                    Text("The default cross-recording matcher. Development gold selected 0.46; repeated evidence and cannot-link constraints guard each merge. Every automatic merge is reversible.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                if settings.customConfiguration.identityMatcher != .greedy {
                    floatSlider(
                        "Ambiguity margin",
                        value: $settings.customConfiguration.identityAmbiguityMargin,
                        range: 0.0...0.15
                    )
                }
                Picker("Centroid weighting", selection: $settings.customConfiguration.centroidPolicy) {
                    ForEach(SpeakerCentroidPolicy.allCases) { Text($0.displayName).tag($0) }
                }
                Toggle("Refresh centroids after ingest", isOn: $settings.customConfiguration.updateCentroidsAfterIngest)
                Text("Computer microphone tracks are always diarized. The host is identified only when their voice matches an enrolled profile; other people in the room remain separate speakers.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("Persona grouping") {
                Picker("Linkage", selection: $settings.customConfiguration.personaLinkage) {
                    ForEach(PersonaLinkage.allCases) { Text($0.displayName).tag($0) }
                }
                floatSlider(
                    "Persona similarity",
                    value: $settings.customConfiguration.personaSimilarityThreshold,
                    range: 0.65...0.95
                )
            }
        }
    }

    @ViewBuilder
    private func floatSlider(
        _ title: String,
        value: Binding<Float>,
        range: ClosedRange<Float>
    ) -> some View {
        VStack(alignment: .leading) {
            HStack {
                Text(title)
                Spacer()
                Text(value.wrappedValue.formatted(.number.precision(.fractionLength(2))))
                    .foregroundColor(.secondary)
                    .monospacedDigit()
            }
            Slider(value: value, in: range)
        }
    }

    @ViewBuilder
    private func doubleSlider(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>
    ) -> some View {
        VStack(alignment: .leading) {
            HStack {
                Text(title)
                Spacer()
                Text(value.wrappedValue.formatted(.number.precision(.fractionLength(2))))
                    .foregroundColor(.secondary)
                    .monospacedDigit()
            }
            Slider(value: value, in: range)
        }
    }

    private var speakerBoundsEnabled: Binding<Bool> {
        Binding(
            get: { settings.customConfiguration.minimumSpeakers != nil },
            set: { enabled in
                settings.customConfiguration.minimumSpeakers = enabled ? 1 : nil
                settings.customConfiguration.maximumSpeakers = enabled ? 8 : nil
            }
        )
    }

    private var diarizationBackend: Binding<SpeakerDiarizationBackend> {
        Binding(
            get: { settings.customConfiguration.diarizationBackend },
            set: { backend in
                settings.customConfiguration.diarizationBackend = backend
                if backend == .segmentDBSCAN {
                    // This control path obtains its transcription cuts from TinyDiarize and does
                    // not have an independent timed-ASR alignment stage.
                    settings.customConfiguration.transcriptionSegmentation = .tinyDiarizeTurns
                    settings.customConfiguration.alignmentStrategy = .maximumOverlap
                }
            }
        )
    }

    private var utteranceSegmentation: Binding<SpeakerUtteranceSegmentation> {
        Binding(
            get: { settings.customConfiguration.effectiveUtteranceSegmentation },
            set: { settings.customConfiguration.utteranceSegmentation = $0 }
        )
    }

    private var minimumSpeakers: Binding<Int> {
        Binding(
            get: { settings.customConfiguration.minimumSpeakers ?? 1 },
            set: { value in
                settings.customConfiguration.minimumSpeakers = value
                if let maximum = settings.customConfiguration.maximumSpeakers, maximum < value {
                    settings.customConfiguration.maximumSpeakers = value
                }
            }
        )
    }

    private var maximumSpeakers: Binding<Int> {
        Binding(
            get: { settings.customConfiguration.maximumSpeakers ?? 8 },
            set: { settings.customConfiguration.maximumSpeakers = $0 }
        )
    }
}
