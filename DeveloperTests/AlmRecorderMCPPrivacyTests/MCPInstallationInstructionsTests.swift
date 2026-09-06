import XCTest
@testable import AlmRecorder

final class MCPInstallationInstructionsTests: XCTestCase {
    func testAgentPromptIsSelfContainedAndPreservesConfiguration() {
        let configuration = """
        {
          "mcpServers": {
            "almrecorder": {
              "command": "/Applications/AlmRecorder.app/Contents/MacOS/AlmRecorderMCPBridge",
              "env": {
                "ALMRECORDER_MCP_SOCKET": "/tmp/almrecorder.sock",
                "ALMRECORDER_MCP_TOKEN": "test-secret-token"
              }
            }
          }
        }
        """

        let prompt = MCPInstallationInstructions.agentPrompt(
            configurationJSON: configuration
        )

        XCTAssertTrue(prompt.contains("There is no separate server package"))
        XCTAssertTrue(prompt.contains(configuration))
        XCTAssertTrue(prompt.contains("AlmRecorder must remain open"))
        XCTAssertTrue(prompt.contains("Do not print or expose"))
        XCTAssertTrue(
            prompt.contains(MCPInstallationInstructions.documentationURL.absoluteString)
        )
    }
}
