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
        XCTAssertTrue(source.contains("repoPromptToolArgs(toolName, params)"))
        XCTAssertTrue(source.contains("args.push(\"-w\", REPOPROMPT_WINDOW_ID)"))
        XCTAssertTrue(source.contains("const REPOPROMPT_CLIENT_NAME = \"pi\""))
        XCTAssertTrue(source.contains("const REPOPROMPT_WINDOW_ID: string | undefined = \"42\""))
        XCTAssertTrue(source.contains("\\\"Debug\\\""))
        XCTAssertTrue(source.contains("repoprompt-mcp"))
        XCTAssertFalse(source.contains("name: \"repoprompt_tool\""))
    }

    func testGlobalInstallWritesWindowlessAutoDiscoveredBridgeAndUninstallRemovesIt() throws {
        let home = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let cliPath = #"/tmp/RepoPrompt Debug/repoprompt-mcp"#

        XCTAssertEqual(
            PiRepoPromptBridgeExtensionInstaller.globalInstallStatus(homeDirectory: home, cliPath: cliPath),
            .notInstalled
        )

        let result = try PiRepoPromptBridgeExtensionInstaller.installGlobal(homeDirectory: home, cliPath: cliPath)
        let extensionURL = PiRepoPromptBridgeExtensionInstaller.globalExtensionURL(homeDirectory: home)
        XCTAssertEqual(result.extensionURL, extensionURL)
        XCTAssertFalse(result.wasAlreadyInstalled)
        XCTAssertEqual(
            PiRepoPromptBridgeExtensionInstaller.globalInstallStatus(homeDirectory: home, cliPath: cliPath),
            .installed
        )

        let source = try String(contentsOf: extensionURL, encoding: .utf8)
        XCTAssertTrue(source.contains("RepoPrompt CE managed pi bridge extension"))
        XCTAssertTrue(source.contains("const REPOPROMPT_WINDOW_ID: string | undefined = undefined"))
        XCTAssertTrue(source.contains("args.push(\"-w\", REPOPROMPT_WINDOW_ID)"))

        XCTAssertTrue(try PiRepoPromptBridgeExtensionInstaller.uninstallGlobal(homeDirectory: home, cliPath: cliPath))
        XCTAssertEqual(
            PiRepoPromptBridgeExtensionInstaller.globalInstallStatus(homeDirectory: home, cliPath: cliPath),
            .notInstalled
        )
    }

    func testGlobalStatusDetectsStaleManagedBridge() throws {
        let home = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let extensionURL = PiRepoPromptBridgeExtensionInstaller.globalExtensionURL(homeDirectory: home)
        try FileManager.default.createDirectory(at: extensionURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PiRepoPromptBridgeExtensionInstaller.extensionSource(windowID: nil, cliPath: "/old/repoprompt-mcp")
            .write(to: extensionURL, atomically: true, encoding: .utf8)

        XCTAssertEqual(
            PiRepoPromptBridgeExtensionInstaller.globalInstallStatus(homeDirectory: home, cliPath: "/new/repoprompt-mcp"),
            .installedButStale
        )
    }

    func testGlobalInstallAndUninstallRefuseUnmanagedExistingExtension() throws {
        let home = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let extensionURL = PiRepoPromptBridgeExtensionInstaller.globalExtensionURL(homeDirectory: home)
        try FileManager.default.createDirectory(at: extensionURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "export default function other() {}".write(to: extensionURL, atomically: true, encoding: .utf8)

        XCTAssertEqual(
            PiRepoPromptBridgeExtensionInstaller.globalInstallStatus(homeDirectory: home, cliPath: "/tmp/repoprompt-mcp"),
            .installedByOther
        )
        XCTAssertThrowsError(try PiRepoPromptBridgeExtensionInstaller.installGlobal(homeDirectory: home, cliPath: "/tmp/repoprompt-mcp")) { error in
            XCTAssertEqual(error as? PiRepoPromptBridgeExtensionInstaller.InstallerError, .globalBridgeAlreadyExists(extensionURL))
        }
        XCTAssertThrowsError(try PiRepoPromptBridgeExtensionInstaller.uninstallGlobal(homeDirectory: home, cliPath: "/tmp/repoprompt-mcp")) { error in
            XCTAssertEqual(error as? PiRepoPromptBridgeExtensionInstaller.InstallerError, .globalBridgeNotManaged(extensionURL))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: extensionURL.path))
    }

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PiRepoPromptBridgeExtensionInstallerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
