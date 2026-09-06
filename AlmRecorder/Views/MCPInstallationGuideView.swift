import AppKit
import SwiftUI

struct MCPInstallationGuideView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var controller: MCPServiceController

    @State private var copiedConfiguration = false
    @State private var copiedAgentSetup = false

    private var enabled: Binding<Bool> {
        Binding(
            get: { controller.isEnabled },
            set: { controller.setEnabled($0) }
        )
    }

    private var transcriptAccess: Binding<Bool> {
        Binding(
            get: { controller.credential.allowTranscripts },
            set: { controller.setTranscriptAccess($0) }
        )
    }

    private var writeAccess: Binding<Bool> {
        Binding(
            get: { controller.credential.allowWrites },
            set: { controller.setWriteAccess($0) }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    introduction

                    guideStep(
                        number: 1,
                        title: "Turn on AlmRecorder's local server",
                        detail: "Leave AlmRecorder open whenever an agent needs your recordings."
                    ) {
                        Toggle("Enable local MCP server", isOn: enabled)
                            .toggleStyle(.switch)

                        HStack(spacing: 7) {
                            Circle()
                                .fill(controller.isRunning ? Color.green : Color.secondary)
                                .frame(width: 8, height: 8)
                            Text(controller.statusMessage)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }

                    guideStep(
                        number: 2,
                        title: "Choose what the agent may access",
                        detail: "Metadata is available by default. Start with the minimum; recording and tag privacy rules always win."
                    ) {
                        Toggle(
                            "Content, summaries, notes, and transcript search",
                            isOn: transcriptAccess
                        )
                        Toggle(
                            "Change tags, notes, and comments",
                            isOn: writeAccess
                        )
                        Text("Notes and comments require both switches. Tag changes require write access.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    guideStep(
                        number: 3,
                        title: "Add AlmRecorder to your AI client",
                        detail: "Use the raw configuration yourself, or copy a complete prompt for an agent that can edit its own MCP settings."
                    ) {
                        HStack(spacing: 10) {
                            Button(copiedConfiguration ? "Configuration copied" : "Copy configuration") {
                                copyToPasteboard(controller.clientConfigurationJSON)
                                copiedConfiguration = true
                                copiedAgentSetup = false
                            }

                            Button(copiedAgentSetup ? "Setup copied" : "Copy complete setup for my agent") {
                                copyToPasteboard(
                                    MCPInstallationInstructions.agentPrompt(
                                        configurationJSON: controller.clientConfigurationJSON
                                    )
                                )
                                copiedAgentSetup = true
                                copiedConfiguration = false
                            }
                            .buttonStyle(.borderedProminent)
                        }

                        Label(
                            "Both copy actions include your secret token. Paste only into a client you trust.",
                            systemImage: "lock.fill"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }

                    guideStep(
                        number: 4,
                        title: "Reload the client and test",
                        detail: "Reload its MCP servers—or restart the client—then ask it to use AlmRecorder."
                    ) {
                        Text("“Use AlmRecorder to list my most recent recordings.”")
                            .font(.system(.callout, design: .rounded))
                            .textSelection(.enabled)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(nsColor: .textBackgroundColor))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
                .padding(24)
            }

            Divider()
            footer
        }
        .frame(width: 700, height: 650)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 25, weight: .medium))
                .foregroundStyle(.tint)
                .frame(width: 34)

            VStack(alignment: .leading, spacing: 2) {
                Text("Connect an AI agent")
                    .font(.headline)
                Text("Set up AlmRecorder through the Model Context Protocol")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Done") {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
        }
        .padding(16)
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Nothing else to install")
                .font(.title2.bold())
            Text(
                "AlmRecorder already contains the MCP server and bridge. Connect ChatGPT and Codex, Claude Desktop, Cursor, GitHub Copilot, Visual Studio Code, Antigravity, or any compatible MCP client."
            )
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        HStack {
            Button {
                NSWorkspace.shared.open(MCPInstallationInstructions.documentationURL)
            } label: {
                Label("Open client-specific guide", systemImage: "safari")
            }

            Spacer()

            Text("The connection is local; your client may send permitted data to its provider.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
    }

    private func guideStep<Content: View>(
        number: Int,
        title: String,
        detail: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text("\(number)")
                .font(.caption.bold())
                .frame(width: 26, height: 26)
                .background(Color.accentColor)
                .foregroundStyle(.white)
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.headline)
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func copyToPasteboard(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}
