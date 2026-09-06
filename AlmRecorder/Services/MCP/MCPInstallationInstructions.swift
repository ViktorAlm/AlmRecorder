import Foundation

enum MCPInstallationInstructions {
    static let documentationURL = URL(
        string: "https://viktoralm.se/almrecorder/guide/connect-ai"
    )!

    static func agentPrompt(configurationJSON: String) -> String {
        """
        Connect the bundled AlmRecorder MCP server to this AI client.

        There is no separate server package to download or install. AlmRecorder already includes
        the MCP server and stdio bridge.

        1. Add an MCP server named "almrecorder" using the complete configuration below.
        2. Preserve the command and both environment variables exactly. Do not print or expose the
           ALMRECORDER_MCP_TOKEN value.
        3. Reload this client's MCP servers, or restart the client if it cannot reload them.
        4. AlmRecorder must remain open, with Settings → MCP → Enable local MCP server turned on.
        5. Verify the connection by listing AlmRecorder's available MCP tools or recent recordings.

        Complete configuration:

        ```json
        \(configurationJSON)
        ```

        If this client needs a different configuration format, adapt the same command and
        environment variables to its documented MCP format without changing their values.

        Client-specific guide:
        \(documentationURL.absoluteString)
        """
    }
}
