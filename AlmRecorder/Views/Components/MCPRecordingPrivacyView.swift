import SwiftUI

/// Local-only control for whether one recording may cross the MCP boundary.
struct MCPRecordingPrivacyView: View {
    let recordingId: Int64

    @State private var status: MCPRecordingPrivacyStatus?
    @State private var errorMessage: String?
    @State private var isSaving = false

    private let repository = GRDBRecordingRepository()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: status?.isAvailableToMCP == true ? "network" : "network.slash")
                    .foregroundStyle(status?.isAvailableToMCP == true ? Color.accentColor : Color.orange)
                Text("MCP privacy")
                    .font(.subheadline)
                    .fontWeight(.medium)
                Spacer()
                if isSaving {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            Toggle(
                "Allow MCP clients to access this recording",
                isOn: Binding(
                    get: { status?.recordingAllowsAccess ?? false },
                    set: setAccess
                )
            )
            .disabled(status == nil || isSaving)

            if let status, !status.blockingTags.isEmpty {
                Label(
                    "Hidden from MCP by \(blockingTagDescription(status.blockingTags))",
                    systemImage: "shield.lefthalf.filled"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            } else if status?.recordingAllowsAccess == false {
                Text("Hidden recordings are treated as nonexistent by MCP tools, resources, search, notes, comments, and statistics.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("A connected MCP client may send retrieved metadata or content to an external service, depending on the global MCP permissions.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(12)
        .background(Color.orange.opacity(status?.isAvailableToMCP == true ? 0.04 : 0.09))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .onAppear(perform: load)
        .onReceive(
            NotificationCenter.default.publisher(for: .mcpRecordingPrivacyDidChange)
        ) { _ in
            load()
        }
    }

    private func setAccess(_ enabled: Bool) {
        isSaving = true
        errorMessage = nil
        do {
            try repository.setMCPAccessEnabled(id: recordingId, enabled: enabled)
            load()
        } catch {
            errorMessage = "Could not update MCP privacy: \(error.localizedDescription)"
        }
        isSaving = false
    }

    private func load() {
        do {
            status = try repository.mcpPrivacyStatus(id: recordingId)
            errorMessage = status == nil ? "Recording no longer exists." : nil
        } catch {
            errorMessage = "Could not read MCP privacy: \(error.localizedDescription)"
        }
    }

    private func blockingTagDescription(_ tags: [Tag]) -> String {
        let names = tags.map { "“\($0.name)”" }
        if names.count <= 2 {
            return names.joined(separator: " and ")
        }
        return "\(names[0]), \(names[1]), and \(names.count - 2) more tags"
    }
}
