@testable import RepoPrompt
import XCTest

final class PiRepoPromptBridgeExtensionInstallerTests: XCTestCase {
    func testExtensionSourceRegistersConcreteRepoPromptToolsFromExportedSchemasAndEscapesCLIPath() {
        let source = PiRepoPromptBridgeExtensionInstaller.extensionSource(
            windowID: 42,
            cliPath: #"/tmp/RepoPrompt "Debug"/repoprompt-mcp"#
        )

        XCTAssertTrue(source.contains("export default async function repoPromptBridge"))
        XCTAssertTrue(source.contains("loadRepoPromptTools"))
        XCTAssertTrue(source.contains("pi.registerTool"))
        XCTAssertTrue(source.contains("name: toolName"))
        XCTAssertTrue(source.contains("parameters: asParameterSchema(tool.inputSchema)"))
        XCTAssertTrue(source.contains("[\"--tools-schema\", \"--compact\"]"))
        XCTAssertFalse(source.contains("[\"--client-name\", REPOPROMPT_CLIENT_NAME, \"--tools-schema\", \"--compact\"]"))
        XCTAssertTrue(source.contains("[\"--client-name\", REPOPROMPT_CLIENT_NAME, \"--raw-json\", \"-w\", REPOPROMPT_WINDOW_ID, \"-c\", toolName"))
        XCTAssertTrue(source.contains("const REPOPROMPT_CLIENT_NAME = \"pi\""))
        XCTAssertTrue(source.contains("const REPOPROMPT_WINDOW_ID = \"42\""))
        XCTAssertTrue(source.contains("\\\"Debug\\\""))
        XCTAssertTrue(source.contains("repoprompt-mcp"))
        XCTAssertFalse(source.contains("name: \"repoprompt_tool\""))
    }
}
