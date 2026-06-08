@testable import RepoPrompt
import XCTest

final class PiRepoPromptBridgeExtensionInstallerTests: XCTestCase {
    func testExtensionSourceRegistersRepoPromptToolAndEscapesCLIPath() {
        let source = PiRepoPromptBridgeExtensionInstaller.extensionSource(
            windowID: 42,
            cliPath: #"/tmp/RepoPrompt "Debug"/repoprompt-mcp"#
        )

        XCTAssertTrue(source.contains("pi.registerTool"))
        XCTAssertTrue(source.contains("name: \"repoprompt_tool\""))
        XCTAssertTrue(source.contains("const REPOPROMPT_WINDOW_ID = \"42\""))
        XCTAssertTrue(source.contains("\\\"Debug\\\""))
        XCTAssertTrue(source.contains("repoprompt-mcp"))
        XCTAssertTrue(source.contains("get_file_tree"))
        XCTAssertTrue(source.contains("apply_edits"))
        XCTAssertTrue(source.contains("agent_run"))
    }
}
