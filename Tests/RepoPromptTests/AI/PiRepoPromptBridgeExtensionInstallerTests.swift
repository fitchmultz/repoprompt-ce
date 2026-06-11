@testable import RepoPrompt
import XCTest

final class PiRepoPromptBridgeExtensionInstallerTests: XCTestCase {
    func testBridgeCommandArgumentsIncludeClientNameWindowAndJSONCallPayload() {
        XCTAssertEqual(
            PiRepoPromptBridgeExtensionInstaller.schemaArgs(windowID: 42),
            ["--client-name", "pi", "--tools-schema", "--compact", "-w", "42"]
        )
        XCTAssertEqual(
            PiRepoPromptBridgeExtensionInstaller.schemaArgs(windowID: nil),
            ["--tools-schema", "--compact"]
        )
        XCTAssertEqual(
            PiRepoPromptBridgeExtensionInstaller.toolArgs(toolName: "get_file_tree", paramsJSON: "{}", windowID: 42),
            ["--client-name", "pi", "--raw-json", "-w", "42", "-c", "get_file_tree", "-j", "{}"]
        )
    }

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
        XCTAssertTrue(source.contains("repoPromptSchemaArgs()"))
        XCTAssertTrue(source.contains("const REPOPROMPT_SCHEMA_ARGS = JSON.parse(\"[\\\"--client-name\\\",\\\"pi\\\",\\\"--tools-schema\\\",\\\"--compact\\\",\\\"-w\\\",\\\"42\\\"]\") as string[]"))
        XCTAssertTrue(source.contains("repoPromptToolArgs(toolName, params)"))
        XCTAssertTrue(source.contains("name: \"repoprompt_window_status\""))
        XCTAssertTrue(source.contains("callRepoPromptTool(pi, \"bind_context\", { op: \"list\" }, signal)"))
        XCTAssertTrue(source.contains("Use repoprompt_window_status instead of shelling out to repoprompt-mcp"))
        XCTAssertTrue(source.contains("const REPOPROMPT_TOOL_ARGS_PREFIX = JSON.parse(\"[\\\"--client-name\\\",\\\"pi\\\",\\\"--raw-json\\\",\\\"-w\\\",\\\"42\\\"]\") as string[]"))
        XCTAssertTrue(source.contains("const REPOPROMPT_CLIENT_NAME = \"pi\""))
        XCTAssertTrue(source.contains("const REPOPROMPT_WINDOW_ID: string | undefined = \"42\""))
        XCTAssertTrue(source.contains("const REPOPROMPT_IS_MANAGED_WINDOW_BRIDGE = REPOPROMPT_WINDOW_ID !== undefined"))
        XCTAssertTrue(source.contains("process.env[REPOPROMPT_MANAGED_RUN_ENV] === \"1\""))
        XCTAssertTrue(source.contains("\\\"Debug\\\""))
        XCTAssertTrue(source.contains("repoprompt-mcp"))
        XCTAssertFalse(source.contains("name: \"repoprompt_tool\""))
    }

    func testBridgeTemplateIsFirstClassArtifactAndRenderingRemovesPlaceholders() throws {
        let templateURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("AppResources", isDirectory: true)
            .appendingPathComponent("PiBridge", isDirectory: true)
            .appendingPathComponent("repoprompt-bridge.ts", isDirectory: false)
        let template = try String(contentsOf: templateURL, encoding: .utf8)

        XCTAssertTrue(template.contains("__REPOPROMPT_CLI__"))
        XCTAssertTrue(template.contains("export default async function repoPromptBridge"))
        XCTAssertTrue(template.contains("pi.registerTool"))

        let rendered = PiRepoPromptBridgeExtensionInstaller.renderExtensionSource(
            template: template,
            windowID: 42,
            cliPath: #"/tmp/RepoPrompt "Debug"/repoprompt-mcp"#
        )
        XCTAssertFalse(rendered.contains("__REPOPROMPT_"))
        XCTAssertTrue(rendered.contains(#"const REPOPROMPT_CLI = "#))
        XCTAssertTrue(rendered.contains("\\\"Debug\\\""))
        XCTAssertTrue(rendered.contains("repoprompt-mcp"))
        XCTAssertTrue(rendered.contains(#"const REPOPROMPT_WINDOW_ID: string | undefined = "42""#))
    }

    func testBridgeTemplateLoadsFromSourceTreeWhenCurrentDirectoryIsNotRepoRoot() throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let source = PiRepoPromptBridgeExtensionInstaller.bridgeTemplateSource(
            currentDirectoryPath: temp.path,
            sourceFilePath: #filePath
        )

        XCTAssertTrue(source.contains("RepoPrompt CE managed pi bridge extension"))
        XCTAssertTrue(source.contains("__REPOPROMPT_CLI__"))
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
        XCTAssertTrue(source.contains("const REPOPROMPT_IS_MANAGED_WINDOW_BRIDGE = REPOPROMPT_WINDOW_ID !== undefined"))
        XCTAssertTrue(source.contains("process.env[REPOPROMPT_MANAGED_RUN_ENV] === \"1\""))
        XCTAssertTrue(source.contains("const REPOPROMPT_SCHEMA_ARGS = JSON.parse(\"[\\\"--tools-schema\\\",\\\"--compact\\\"]\") as string[]"))
        XCTAssertTrue(source.contains("const REPOPROMPT_TOOL_ARGS_PREFIX = JSON.parse(\"[\\\"--client-name\\\",\\\"pi\\\",\\\"--raw-json\\\"]\") as string[]"))

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
