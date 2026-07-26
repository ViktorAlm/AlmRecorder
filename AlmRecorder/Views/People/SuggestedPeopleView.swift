import SwiftUI

/// The "Suggested people" inbox: the global surface for the speaker-identity inference engine. Shows who
/// the app thinks each recurring voice is (deduced from meeting attendees) plus who *you* are, and lets
/// you confirm or dismiss in bulk. High-confidence inferences are auto-applied elsewhere; here you lock
/// them in (Confirm) or undo them (Dismiss).
struct SuggestedPeopleView: View {
    var onChange: () -> Void = {}

    @State private var owner: OwnerIdentity = .none
    @State private var ownerVoiceName: String?
    @State private var inferences: [IdentityInference] = []
    @State private var verdicts: [String: IdentityVerdictPolicy.Verdict] = [:]
    @State private var isLoading = false
    @State private var isRerunning = false
    @State private var isVerifying = false

    private let coordinator = IdentityInferenceCoordinator.shared

    private var highConfidence: [IdentityInference] { inferences.filter { $0.confidence >= .strong } }
    private var suggestions: [IdentityInference] { inferences.filter { $0.confidence < .strong } }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if isLoading && inferences.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        ownerCard
                        if !highConfidence.isEmpty {
                            section("Auto-named", subtitle: "We're confident — confirm to lock in, or undo.", rows: highConfidence)
                        }
                        if !suggestions.isEmpty {
                            section("Suggestions", subtitle: "Likely matches from your meetings — your call.", rows: suggestions)
                        }
                        if highConfidence.isEmpty && suggestions.isEmpty {
                            emptyState
                        }
                    }
                    .padding(16)
                }
            }
        }
        .frame(minWidth: 520, minHeight: 480)
        .task { await reload() }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Suggested people").font(.headline)
                Text("Inferred from who attended the meetings each voice appears in.")
                    .font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            Button { verifyWithAI() } label: {
                Label(isVerifying ? "Listening…" : "Verify with AI", systemImage: "text.magnifyingglass")
            }
            .disabled(isVerifying || !LLMTextService.shared.isAvailable)
            .help(LLMTextService.shared.isAvailable
                  ? "Have the AI read the actual calls (who addresses whom by name) and confirm or correct these guesses"
                  : "Needs the Gemma text model (Models tab)")
            Button { rerun() } label: {
                Label("Re-run", systemImage: isRerunning ? "arrow.triangle.2.circlepath" : "sparkles")
            }
            .disabled(isRerunning)
            .help("Recompute identities from the latest recordings and meetings")
        }
        .padding(12)
    }

    // MARK: - Owner

    private var ownerCard: some View {
        let known = (owner.name?.isEmpty == false) || (owner.email?.isEmpty == false)
        return VStack(alignment: .leading, spacing: 8) {
            Label("You", systemImage: "person.crop.circle.badge.checkmark").font(.subheadline.bold())
            HStack(spacing: 10) {
                Circle().fill(Color.accentColor)
                    .frame(width: 34, height: 34)
                    .overlay(Image(systemName: "person.fill").foregroundColor(.white))
                VStack(alignment: .leading, spacing: 2) {
                    Text(known ? (owner.name ?? owner.email ?? "You") : "Not identified yet")
                        .font(.body)
                    Text(ownerStatus).font(.caption).foregroundColor(.secondary)
                }
                Spacer()
                if owner.speakerUuid != nil {
                    Button("Not me") { clearOwnerVoice() }
                        .help("Forget the detected owner voice and re-detect")
                }
            }
        }
        .padding(12)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var ownerStatus: String {
        switch (owner.email?.isEmpty == false, owner.speakerUuid != nil) {
        case (true, true):  return "\(owner.email!) · voice identified\(ownerVoiceName.map { " (\($0))" } ?? "")"
        case (true, false): return "\(owner.email!) · voice not identified yet"
        case (false, true): return "voice identified from your solo recordings"
        case (false, false): return "Sync a calendar or record a voice memo so we can identify you."
        }
    }

    // MARK: - Sections

    private func section(_ title: String, subtitle: String, rows: [IdentityInference]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.subheadline.bold())
                Text(subtitle).font(.caption).foregroundColor(.secondary)
            }
            ForEach(rows, id: \.speakerUuid) { inf in row(inf) }
        }
    }

    private func row(_ inf: IdentityInference) -> some View {
        HStack(spacing: 10) {
            Circle().fill(color(for: inf.confidence).opacity(0.85))
                .frame(width: 32, height: 32)
                .overlay(Text(initials(inf.attendeeName)).font(.system(size: 11, weight: .bold)).foregroundColor(.white))
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(inf.attendeeName).font(.body)
                    tierBadge(inf.confidence)
                    aiChip(for: inf)
                }
                Text(inf.reason).font(.caption).foregroundColor(.secondary).lineLimit(2)
            }
            Spacer()
            Button("Confirm") { confirm(inf) }.buttonStyle(.borderedProminent).controlSize(.small)
            Button("Dismiss") { dismiss(inf) }.controlSize(.small)
        }
        .padding(10)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func tierBadge(_ tier: IdentityInference.Tier) -> some View {
        Text(label(for: tier))
            .font(.caption2.bold())
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color(for: tier).opacity(0.18))
            .foregroundColor(color(for: tier))
            .clipShape(Capsule())
    }

    /// What the AI heard in the actual calls about this guess, with the evidence on hover.
    @ViewBuilder
    private func aiChip(for inf: IdentityInference) -> some View {
        if let verdict = verdicts["\(inf.speakerUuid)|\(inf.attendeeName)"] {
            let agrees = verdict.llmPerson.map { IdentityVerdictPolicy.personsMatch($0, inf.attendeeName) } ?? false
            let text = agrees ? "AI ✓" : (verdict.llmPerson.map { "AI: \($0)" } ?? "AI: unclear")
            let tint: Color = agrees ? .green : (verdict.llmPerson == nil ? .gray : .red)
            Text(text)
                .font(.caption2.bold())
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(tint.opacity(0.15))
                .foregroundColor(tint)
                .clipShape(Capsule())
                .help(verdict.evidence.isEmpty ? "No transcript evidence found" : verdict.evidence)
        }
    }

    private func verifyWithAI() {
        isVerifying = true
        Task {
            _ = await SpeakerIdentityLLMReviewer.shared.reviewPendingSuggestions(maxChecks: 8)
            await reload()
            isVerifying = false
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.seal").font(.system(size: 30)).foregroundColor(.secondary)
            Text("Nothing to review").foregroundColor(.secondary)
            Text("As you record meetings linked to calendar events, we'll suggest who each voice is here.")
                .font(.caption).foregroundColor(.secondary).multilineTextAlignment(.center).frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 30)
    }

    // MARK: - Actions

    private func confirm(_ inf: IdentityInference) {
        coordinator.confirm(inf)
        afterMutation()
    }
    private func dismiss(_ inf: IdentityInference) {
        coordinator.reject(speakerUuid: inf.speakerUuid, attendeeName: inf.attendeeName)
        afterMutation()
    }
    private func clearOwnerVoice() {
        OwnerIdentityService.shared.setOwnerVoice(nil)
        afterMutation()
    }
    private func rerun() {
        isRerunning = true
        Task {
            await Task.detached { _ = coordinator.recompute() }.value
            await reload()
            isRerunning = false
        }
    }
    private func afterMutation() {
        onChange()
        Task { await reload() }
    }

    private func reload() async {
        isLoading = true
        let snapshot = await Task.detached { () -> (OwnerIdentity, [IdentityInference], String?, [String: IdentityVerdictPolicy.Verdict]) in
            let owner = OwnerIdentityService.shared.currentOwner()
            let infs = IdentityInferenceCoordinator.shared.computeAll()
            var ownerVoiceName: String?
            if let uuid = owner.speakerUuid {
                let speakers = (try? GRDBSpeakerRepository().getSpeakersWithStats(includeEmpty: true)) ?? []
                ownerVoiceName = speakers.first { $0.uuid == uuid }?.name
            }
            let verdictList = (try? GRDBDatabaseManager.shared.read { try IdentityLLMVerdictStore.all($0) }) ?? []
            let verdictMap = Dictionary(uniqueKeysWithValues: verdictList.map { ("\($0.speakerUuid)|\($0.suggestedName)", $0) })
            return (owner, infs, ownerVoiceName, verdictMap)
        }.value
        owner = snapshot.0
        inferences = snapshot.1
        ownerVoiceName = snapshot.2
        verdicts = snapshot.3
        isLoading = false
    }

    // MARK: - Formatting

    private func initials(_ name: String) -> String {
        let parts = name.split(separator: " ").prefix(2)
        let s = parts.compactMap { $0.first }.map(String.init).joined()
        return s.isEmpty ? "?" : s.uppercased()
    }
    private func label(for tier: IdentityInference.Tier) -> String {
        switch tier {
        case .forced: return "Certain"
        case .strong: return "High"
        case .likely: return "Likely"
        case .weak:   return "Possible"
        }
    }
    private func color(for tier: IdentityInference.Tier) -> Color {
        switch tier {
        case .forced: return .green
        case .strong: return .teal
        case .likely: return .orange
        case .weak:   return .gray
        }
    }
}
