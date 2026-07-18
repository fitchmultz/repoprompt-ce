@testable import RepoPrompt
import XCTest

final class PiRepoPromptBridgeExtensionInstallerTests: XCTestCase {
    func testBridgeCommandArgumentsIncludeClientNameWindowAndJSONCallPayload() {
        XCTAssertEqual(
            PiRepoPromptBridgeExtensionInstaller.schemaArgs(windowID: 42),
            [
                "--client-name",
                PiRepoPromptBridgeExtensionInstaller.managedBridgeExecutionClientName,
                "--tools-schema",
                "--compact",
                "-w",
                "42"
            ]
        )
        XCTAssertEqual(
            PiRepoPromptBridgeExtensionInstaller.schemaArgs(windowID: nil),
            ["--tools-schema", "--compact"]
        )
        XCTAssertEqual(
            PiRepoPromptBridgeExtensionInstaller.toolArgs(toolName: "get_file_tree", paramsJSON: "{}", windowID: 42),
            [
                "--client-name",
                PiRepoPromptBridgeExtensionInstaller.managedBridgeExecutionClientName,
                "--raw-json",
                "-w",
                "42",
                "-c",
                "get_file_tree",
                "-j",
                "{}"
            ]
        )
    }

    func testManagedInstallKeepsOtherWindowScopedBridgePaths() throws {
        let home = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let appSupport = home.appendingPathComponent("Application Support", isDirectory: true)
        let fileManager = StubApplicationSupportFileManager(applicationSupportURL: appSupport)
        let cliPath = #"/tmp/RepoPrompt Debug/repoprompt-mcp"#

        let first = try PiRepoPromptBridgeExtensionInstaller.install(windowID: 4, fileManager: fileManager, cliPath: cliPath)
        let second = try PiRepoPromptBridgeExtensionInstaller.install(windowID: 5, fileManager: fileManager, cliPath: cliPath)

        XCTAssertEqual(first.lastPathComponent, "repoprompt-bridge-window-4.ts")
        XCTAssertEqual(second.lastPathComponent, "repoprompt-bridge-window-5.ts")
        XCTAssertNotEqual(first, second)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
        XCTAssertTrue(try String(contentsOf: first, encoding: .utf8).contains(#"const REPOPROMPT_WINDOW_ID: string | undefined = "4""#))
        XCTAssertTrue(try String(contentsOf: second, encoding: .utf8).contains(#"const REPOPROMPT_WINDOW_ID: string | undefined = "5""#))
    }

    func testManagedWindowInstallStatusDetectsStaleGeneratedBridgeFiles() throws {
        let home = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let appSupport = home.appendingPathComponent("Application Support", isDirectory: true)
        let directory = appSupport
            .appendingPathComponent("RepoPrompt CE", isDirectory: true)
            .appendingPathComponent("PiBridge", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let cliPath = #"/tmp/RepoPrompt Debug/repoprompt-mcp"#
        let staleURL = PiRepoPromptBridgeExtensionInstaller.managedExtensionURL(directory: directory, windowID: 4)
        let currentURL = PiRepoPromptBridgeExtensionInstaller.managedExtensionURL(directory: directory, windowID: 5)
        let unmanagedURL = directory.appendingPathComponent("repoprompt-bridge-window-6.ts")

        try PiRepoPromptBridgeExtensionInstaller.extensionSource(windowID: 4, cliPath: "/old/repoprompt-mcp")
            .write(to: staleURL, atomically: true, encoding: .utf8)
        try PiRepoPromptBridgeExtensionInstaller.extensionSource(windowID: 5, cliPath: cliPath)
            .write(to: currentURL, atomically: true, encoding: .utf8)
        try "export default function other() {}".write(to: unmanagedURL, atomically: true, encoding: .utf8)

        let statuses = PiRepoPromptBridgeExtensionInstaller.managedWindowInstallStatuses(directory: directory, cliPath: cliPath)

        func status(for url: URL) -> PiRepoPromptBridgeExtensionInstaller.ManagedWindowInstallStatus? {
            statuses.first { $0.extensionURL.lastPathComponent == url.lastPathComponent }
        }

        XCTAssertEqual(statuses.count, 3)
        XCTAssertEqual(status(for: staleURL)?.status, .installedButStale)
        XCTAssertEqual(status(for: staleURL)?.windowID, 4)
        XCTAssertEqual(status(for: currentURL)?.status, .installed)
        XCTAssertEqual(status(for: unmanagedURL)?.status, .installedByOther)
        XCTAssertEqual(
            PiRepoPromptBridgeExtensionInstaller.staleManagedWindowExtensionURLs(directory: directory, cliPath: cliPath)
                .map(\.lastPathComponent),
            [staleURL.lastPathComponent]
        )

        _ = try PiRepoPromptBridgeExtensionInstaller.install(windowID: 5, fileManager: StubApplicationSupportFileManager(applicationSupportURL: appSupport), cliPath: cliPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: staleURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: currentURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unmanagedURL.path))
        XCTAssertTrue(try String(contentsOf: staleURL, encoding: .utf8).contains(#"const REPOPROMPT_WINDOW_ID: string | undefined = "4""#))
        XCTAssertEqual(
            PiRepoPromptBridgeExtensionInstaller.staleManagedWindowExtensionURLs(directory: directory, cliPath: cliPath),
            []
        )
    }

    func testManagedBridgeIdentityBelongsToPiAgentFamilyButPersonalBridgeDoesNot() {
        XCTAssertEqual(MCPClientIdentity.managedPiFamilyClientNames, Set([
            AgentProviderKind.piMCPClientID,
            PiRepoPromptBridgeExtensionInstaller.managedBridgeExecutionClientName
        ]))
        for acceptedClientName in MCPClientIdentity.managedPiFamilyClientNames {
            XCTAssertEqual(
                MCPClientIdentity.canonicalFamilyID(acceptedClientName),
                AgentProviderKind.piMCPClientID,
                "\(acceptedClientName) must canonicalize to the managed pi policy key"
            )
            XCTAssertTrue(
                MCPClientIdentity.matches(acceptedClientName, AgentProviderKind.piMCPClientID),
                "\(acceptedClientName) must match the managed pi family"
            )
        }
        XCTAssertEqual(
            MCPClientIdentity.storageKey(PiRepoPromptBridgeExtensionInstaller.managedBridgeExecutionClientName),
            AgentProviderKind.piMCPClientID
        )
        XCTAssertTrue(MCPClientIdentity.isHeadlessAgentClient(
            PiRepoPromptBridgeExtensionInstaller.managedBridgeExecutionClientName
        ))

        XCTAssertFalse(MCPClientIdentity.matches(
            PiRepoPromptBridgeExtensionInstaller.personalBridgeClientName,
            AgentProviderKind.piMCPClientID
        ))
        XCTAssertEqual(
            MCPClientIdentity.storageKey(PiRepoPromptBridgeExtensionInstaller.personalBridgeClientName),
            PiRepoPromptBridgeExtensionInstaller.personalBridgeClientName
        )
    }

    func testPiIdentityFamilyRejectsNearMatchClientNames() {
        let rejectedClientNames = ["pischema", "pi-schema-evil", "pifoo", "xpi", "pi2"]

        for rejectedClientName in rejectedClientNames {
            XCTAssertFalse(
                MCPClientIdentity.matches(rejectedClientName, AgentProviderKind.piMCPClientID),
                "\(rejectedClientName) must not match the managed pi family"
            )
            XCTAssertNotEqual(
                MCPClientIdentity.storageKey(rejectedClientName),
                AgentProviderKind.piMCPClientID,
                "\(rejectedClientName) must not canonicalize to the managed pi policy key"
            )
            XCTAssertFalse(
                MCPClientIdentity.isHeadlessAgentClient(rejectedClientName),
                "\(rejectedClientName) must not be treated as a known headless pi client"
            )
        }
    }

    func testExtensionSourceRegistersConcreteRepoPromptToolsFromExportedSchemasAndEscapesCLIPath() {
        let source = PiRepoPromptBridgeExtensionInstaller.extensionSource(
            windowID: 42,
            cliPath: #"/tmp/RepoPrompt "Debug"/repoprompt-mcp"#
        )

        XCTAssertTrue(source.contains("export default async function repoPromptBridge"))
        XCTAssertTrue(source.contains("loadRepoPromptTools"))
        XCTAssertTrue(source.contains("try {"))
        XCTAssertTrue(source.contains("schemaDiagnostics = {"))
        XCTAssertTrue(source.contains("failureClass: classifyBridgeFailure(errorMessage)"))
        XCTAssertTrue(source.contains("registerRepoPromptBridgeStatusTool(pi, schemaDiagnostics)"))
        XCTAssertTrue(source.contains("name: \"repoprompt_bridge_status\""))
        XCTAssertTrue(source.contains("schemaLoadStatus: schemaDiagnostics.status"))
        XCTAssertTrue(source.contains("schemaToolCount: schemaDiagnostics.toolCount"))
        XCTAssertTrue(source.contains("registeredToolCount: schemaDiagnostics.registeredToolCount"))
        XCTAssertTrue(source.contains("registrationFailureCount: schemaDiagnostics.registrationFailureCount"))
        XCTAssertTrue(source.contains("registrationFailures: schemaDiagnostics.registrationFailures"))
        XCTAssertTrue(source.contains("cliPath: REPOPROMPT_CLI"))
        XCTAssertTrue(source.contains("classifyBridgeFailure"))
        XCTAssertTrue(source.contains("lower.includes(`[${failureClass}]`)"))
        XCTAssertTrue(source.contains("lower.includes(\"handshake rejected\")"))
        XCTAssertTrue(source.contains("lower.includes(\"protocol_version_mismatch\")"))
        XCTAssertFalse(source.contains("exitCode === 73"))
        XCTAssertTrue(source.contains("pi.registerTool"))
        XCTAssertTrue(source.contains("name: toolName"))
        XCTAssertTrue(source.contains("parameters: asParameterSchema(tool.inputSchema)"))
        XCTAssertTrue(source.contains("repoPromptSchemaArgs()"))
        XCTAssertTrue(source.contains(
            "const REPOPROMPT_SCHEMA_ARGS = JSON.parse(\"[\\\"--client-name\\\",\\\"pi-schema\\\",\\\"--tools-schema\\\",\\\"--compact\\\",\\\"-w\\\",\\\"42\\\"]\") as string[]"
        ))
        XCTAssertTrue(source.contains("repoPromptToolArgs(toolName, params)"))
        XCTAssertTrue(source.contains("name: \"bind_context\""))
        XCTAssertTrue(source.contains("enum: [\"list\", \"status\"]"))
        XCTAssertTrue(source.contains("sanitizedBindContextParams"))
        XCTAssertFalse(source.contains("MANAGED_BRIDGE_DYNAMIC_TOOL_ALLOWLIST"))
        XCTAssertFalse(source.contains("!MANAGED_BRIDGE_DYNAMIC_TOOL_ALLOWLIST.has(toolName)"))
        XCTAssertTrue(source.contains(
            "RepoPrompt bridge tools are routed to the current RepoPrompt CE window and governed by RepoPrompt Agent Mode permissions."
        ))
        XCTAssertTrue(source.contains("name: \"repoprompt_window_status\""))
        XCTAssertTrue(source.contains("callRepoPromptTool(pi, \"bind_context\", { op: \"list\" }, signal)"))
        XCTAssertTrue(source.contains("Use repoprompt_window_status instead of shelling out to repoprompt-mcp"))
        XCTAssertTrue(source.contains(
            "const REPOPROMPT_TOOL_ARGS_PREFIX = JSON.parse(\"[\\\"--client-name\\\",\\\"pi-schema\\\",\\\"--raw-json\\\",\\\"-w\\\",\\\"42\\\"]\") as string[]"
        ))
        XCTAssertTrue(source.contains("const REPOPROMPT_WINDOW_ID: string | undefined = \"42\""))
        XCTAssertTrue(source.contains("const REPOPROMPT_IS_MANAGED_WINDOW_BRIDGE = REPOPROMPT_WINDOW_ID !== undefined"))
        XCTAssertTrue(source.contains("process.env[REPOPROMPT_MANAGED_RUN_ENV] === \"1\""))
        XCTAssertTrue(source.contains("process.env[REPOPROMPT_PI_PERMISSION_LEVEL_ENV]"))
        XCTAssertTrue(source.contains("pi.on(\"tool_call\""))
        XCTAssertTrue(source.contains("const PI_BUILT_IN_TOOLS = new Set<string>([\"bash\", \"read\", \"edit\", \"write\", \"grep\", \"find\", \"ls\"])"))
        XCTAssertTrue(source.contains("import { createHash } from \"node:crypto\";"))
        XCTAssertTrue(source.contains("import { appendFileSync, mkdirSync } from \"node:fs\";"))
        XCTAssertTrue(source.contains("const BRIDGE_DEBUG_LOG_ENV = \"REPOPROMPT_PI_BRIDGE_DEBUG_LOG\""))
        XCTAssertTrue(source.contains("function bridgeDebugLog(event: string, fields: JSONRecord = {})"))
        XCTAssertTrue(source.contains("[\"agent_run\", \"context_builder\", \"ask_oracle\"].includes(toolName) ? 0 : TOOL_EXEC_TIMEOUT_MS"))
        XCTAssertTrue(source.contains("const TOOL_APPROVAL_TIMEOUT_ENV = \"REPOPROMPT_PI_APPROVAL_TIMEOUT_MS\""))
        XCTAssertTrue(source.contains("normalized === \"command\""))
        XCTAssertTrue(source.contains("bridgeDebugLog(\"tool_exit\""))
        XCTAssertTrue(source.contains("stdout: safeTextSummary(stdout)"))
        XCTAssertTrue(source.contains("stderr: safeTextSummary(stderr)"))
        XCTAssertFalse(source.contains("stdoutPreview"))
        XCTAssertFalse(source.contains("stderrPreview"))
        XCTAssertTrue(source.contains("safeToolInputSummary(params)"))
        XCTAssertTrue(source.contains("let repoPromptToolQueue: Promise<unknown> = Promise.resolve()"))
        XCTAssertTrue(source.contains("function serializeRepoPromptToolCall<T>(operation: () => Promise<T>): Promise<T>"))
        XCTAssertTrue(source.contains("result = await serializeRepoPromptToolCall(() => pi.exec("))
        XCTAssertTrue(source.contains("sha256Hex(canonicalJSONString(event.input))"))
        XCTAssertTrue(source.contains("RepoPrompt pi preflight approval"))
        XCTAssertTrue(source.contains("Auto Review is not yet wired for pi built-ins"))
        XCTAssertTrue(source.contains("RepoPrompt pi Read Only policy blocks"))
        XCTAssertTrue(source.contains("repoPromptToolArgs(\"ask_user\", payload)"))
        XCTAssertTrue(source.contains("malformed approval response"))
        XCTAssertTrue(source.contains("PI_SESSION_TOOL_GRANTS.add(piToolSessionGrantKey(event, ctx))"))
        XCTAssertTrue(source.contains("pi.on(\"session_shutdown\""))
        XCTAssertTrue(source.contains("PI_SESSION_TOOL_GRANTS.clear()"))
        XCTAssertFalse(source.contains("ctx.ui.select"))
        XCTAssertTrue(source.contains("RepoPrompt failed closed while evaluating pi built-in tool policy"))
        XCTAssertTrue(source.contains("if (!isPiBuiltInToolName(event.toolName)) return;"))
        XCTAssertFalse(source.contains("pi.on(\"tool_call\", async (event, ctx) => {\n    return;"))
        XCTAssertTrue(source.contains("\\\"Debug\\\""))
        XCTAssertTrue(source.contains("repoprompt-mcp"))
        XCTAssertFalse(source.contains("name: \"repoprompt_tool\""))
    }

    func testManagedBridgeDoesNotStaleFilterPolicyAdvertisedFirstClassProviderTools() {
        let firstClassRequiredTools = [
            "agent_run",
            "agent_manage",
            "context_builder",
            "workspace_context",
            "read_file",
            "file_search",
            "get_file_tree",
            "get_code_structure",
            "manage_selection",
            "prompt",
            "apply_edits",
            "file_actions",
            "git"
        ]
        let source = PiRepoPromptBridgeExtensionInstaller.extensionSource(
            windowID: 42,
            cliPath: #"/tmp/RepoPrompt Debug/repoprompt-mcp"#
        )

        XCTAssertEqual(
            PiRepoPromptBridgeExtensionInstaller.schemaArgs(windowID: 42),
            [
                "--client-name",
                PiRepoPromptBridgeExtensionInstaller.managedBridgeExecutionClientName,
                "--tools-schema",
                "--compact",
                "-w",
                "42"
            ]
        )
        XCTAssertTrue(source.contains("for (const tool of tools)"))
        XCTAssertTrue(source.contains("pi.registerTool"))
        XCTAssertTrue(source.contains("parameters: asParameterSchema(tool.inputSchema)"))
        XCTAssertTrue(source.contains("recordToolRegistrationFailure(schemaDiagnostics, toolName, error)"))
        XCTAssertTrue(source.contains("schemaDiagnostics.registeredToolCount += 1"))
        XCTAssertFalse(source.contains("MANAGED_BRIDGE_DYNAMIC_TOOL_ALLOWLIST"))
        XCTAssertFalse(source.contains("!MANAGED_BRIDGE_DYNAMIC_TOOL_ALLOWLIST.has(toolName)"))
        XCTAssertTrue(
            firstClassRequiredTools.allSatisfy { !AgentModeMCPToolPolicy.restrictedTools.contains($0) },
            "First-class pi bridge tools must be governed by RepoPrompt Agent Mode policy, not restricted before schema export."
        )
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

    func testGlobalExtensionURLRespectsConfiguredPiAgentDirectory() throws {
        let home = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let customAgentDir = home.appendingPathComponent("Custom Pi Agent", isDirectory: true)

        let environment = [PiIntegrationConfiguration.agentDirectoryEnvironmentKey: customAgentDir.path]
        let extensionURL = customAgentDir
            .appendingPathComponent("extensions", isDirectory: true)
            .appendingPathComponent("repoprompt-bridge.ts", isDirectory: false)

        XCTAssertEqual(
            PiRepoPromptBridgeExtensionInstaller.globalExtensionURL(homeDirectory: home, environment: environment),
            extensionURL
        )
        XCTAssertEqual(
            try PiRepoPromptBridgeExtensionInstaller.installGlobal(
                homeDirectory: home,
                environment: environment,
                cliPath: "/tmp/repoprompt-mcp"
            ).extensionURL,
            extensionURL
        )
        XCTAssertEqual(
            PiRepoPromptBridgeExtensionInstaller.globalInstallStatus(
                homeDirectory: home,
                environment: environment,
                cliPath: "/tmp/repoprompt-mcp"
            ),
            .installed
        )
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
        XCTAssertTrue(source.contains("const REPOPROMPT_PI_PERMISSION_LEVEL_ENV = \"REPOPROMPT_PI_PERMISSION_LEVEL\""))
        XCTAssertTrue(source.contains("const REPOPROMPT_SCHEMA_ARGS = JSON.parse(\"[\\\"--tools-schema\\\",\\\"--compact\\\"]\") as string[]"))
        XCTAssertTrue(source.contains("const REPOPROMPT_TOOL_ARGS_PREFIX = JSON.parse(\"[\\\"--client-name\\\",\\\"repoprompt-pi-bridge\\\",\\\"--raw-json\\\"]\") as string[]"))
        XCTAssertTrue(source.contains("const MANAGED_SCHEMA_LOAD_TIMEOUT_MS = 60_000;"))
        XCTAssertTrue(source.contains("const DEFAULT_GLOBAL_SCHEMA_LOAD_TIMEOUT_MS = 10_000;"))
        XCTAssertTrue(source.contains("const GLOBAL_SCHEMA_LOAD_TIMEOUT_ENV = \"REPOPROMPT_PI_GLOBAL_BRIDGE_SCHEMA_TIMEOUT_MS\""))
        XCTAssertTrue(source.contains("function positiveIntegerEnv(name: string, fallback: number): number"))
        XCTAssertTrue(source.contains("function schemaLoadTimeoutMS(): number"))
        XCTAssertTrue(source.contains("if (REPOPROMPT_IS_MANAGED_WINDOW_BRIDGE) return MANAGED_SCHEMA_LOAD_TIMEOUT_MS;"))
        XCTAssertTrue(source.contains("return positiveIntegerEnv(GLOBAL_SCHEMA_LOAD_TIMEOUT_ENV, DEFAULT_GLOBAL_SCHEMA_LOAD_TIMEOUT_MS);"))
        XCTAssertTrue(source.contains("{ timeout: schemaLoadTimeoutMS() }"))

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

    func testManagedBridgeBuiltInToolPolicyBehavior() throws {
        guard let tsc = Self.findExecutable("tsc"), let node = Self.findExecutable("node") else {
            throw XCTSkip("TypeScript bridge behavior harness requires node and tsc.")
        }
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bridgeURL = directory.appendingPathComponent("bridge.ts")
        let harnessURL = directory.appendingPathComponent("bridge-policy-harness.ts")
        let outDir = directory.appendingPathComponent("out", isDirectory: true)

        let rendered = PiRepoPromptBridgeExtensionInstaller.extensionSource(
            windowID: 42,
            cliPath: "/tmp/repoprompt-mcp"
        )
        try Self.nodeExecutableBridgeSource(from: rendered).write(to: bridgeURL, atomically: true, encoding: .utf8)
        try Self.bridgePolicyHarnessSource.write(to: harnessURL, atomically: true, encoding: .utf8)

        try Self.runProcess(
            executable: tsc,
            arguments: [
                "--module", "node16",
                "--target", "es2022",
                "--moduleResolution", "node16",
                "--esModuleInterop",
                "--skipLibCheck",
                "--noImplicitAny", "false",
                "--ignoreDeprecations", "6.0",
                "--outDir", outDir.path,
                harnessURL.path,
                bridgeURL.path
            ],
            workingDirectory: directory
        )
        try Self.runProcess(
            executable: node,
            arguments: [outDir.appendingPathComponent("bridge-policy-harness.js").path],
            workingDirectory: directory
        )
    }

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PiRepoPromptBridgeExtensionInstallerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func nodeExecutableBridgeSource(from rendered: String) -> String {
        let imports = """
        import { createHash } from "node:crypto";
        import { appendFileSync, mkdirSync } from "node:fs";
        import { homedir } from "node:os";
        import { dirname, join } from "node:path";
        import type { ExtensionAPI, ExtensionContext, ToolCallEvent, ToolCallEventResult } from "@earendil-works/pi-coding-agent";
        """
        let harnessPrelude = """
        declare const require: any;
        declare const process: any;
        declare const Buffer: any;
        const { createHash } = require("node:crypto");
        const { appendFileSync, mkdirSync } = require("node:fs");
        const { homedir } = require("node:os");
        const { dirname, join } = require("node:path");
        type ExtensionAPI = any;
        type ExtensionContext = any;
        type ToolCallEvent = any;
        type ToolCallEventResult = any;
        """
        return rendered.replacingOccurrences(of: imports, with: harnessPrelude)
    }

    private static let bridgePolicyHarnessSource = #"""
    declare const require: any;
    declare const process: any;

    const assert = require("node:assert/strict");
    const repoPromptBridge = require("./bridge").default;

    type ExecResponse = { code: number; stdout: string; stderr: string };
    type ExecResponseSource = ExecResponse | (() => Promise<ExecResponse> | ExecResponse);

    class FakePi {
      handlers = new Map<string, Array<(...args: any[]) => Promise<any> | any>>();
      registeredTools: any[] = [];
      execCalls: any[] = [];

      constructor(private responses: ExecResponseSource[]) {}

      on(name: string, handler: (...args: any[]) => Promise<any> | any) {
        const handlers = this.handlers.get(name) ?? [];
        handlers.push(handler);
        this.handlers.set(name, handlers);
      }

      registerTool(tool: any) {
        this.registeredTools.push(tool);
      }

      async exec(command: string, args: string[], options: any): Promise<ExecResponse> {
        this.execCalls.push({ command, args, options });
        const response = this.responses.shift();
        if (!response) throw new Error(`No fake pi.exec response for ${command} ${args.join(" ")}`);
        return typeof response === "function" ? await response() : response;
      }

      async trigger(name: string, ...args: any[]) {
        let result: any;
        for (const handler of this.handlers.get(name) ?? []) {
          result = await handler(...args);
        }
        return result;
      }
    }

    function schemaResponse(tools: any[] = []): ExecResponse {
      return { code: 0, stdout: JSON.stringify({ tools }), stderr: "" };
    }

    function toolSchema(name: string): any {
      return {
        name,
        description: `${name} tool`,
        inputSchema: { type: "object", properties: {}, additionalProperties: false },
      };
    }

    function approvalResponse(choice: string): ExecResponse {
      return {
        code: 0,
        stdout: JSON.stringify({ answers: { pi_tool_approval: { selected_options: [choice] } } }),
        stderr: "",
      };
    }

    async function loadBridge(permissionLevel: string | undefined, responses: ExecResponseSource[] = [schemaResponse()]): Promise<FakePi> {
      if (permissionLevel === undefined) {
        delete process.env.REPOPROMPT_PI_PERMISSION_LEVEL;
      } else {
        process.env.REPOPROMPT_PI_PERMISSION_LEVEL = permissionLevel;
      }
      delete process.env.REPOPROMPT_PI_APPROVAL_TIMEOUT_MS;
      const pi = new FakePi(responses);
      await repoPromptBridge(pi);
      assert.ok(pi.handlers.has("tool_call"), "managed window bridge should register a tool_call policy handler");
      assert.ok(pi.handlers.has("session_shutdown"), "managed window bridge should clear session grants on session shutdown");
      return pi;
    }

    const ctx = { cwd: "/tmp/repoprompt-pi-bridge-policy", signal: undefined };
    const bashEvent = { toolName: "bash", input: { command: "printf ok" } };

    async function main() {
      let pi = await loadBridge(undefined);
      let result = await pi.trigger("tool_call", bashEvent, ctx);
      assert.equal(result.block, true);
      assert.match(result.reason, /missing or invalid/);

      pi = await loadBridge("readOnly");
      assert.equal(await pi.trigger("tool_call", { toolName: "read", input: { path: "README.md" } }, ctx), undefined);
      result = await pi.trigger("tool_call", bashEvent, ctx);
      assert.equal(result.block, true);
      assert.match(result.reason, /Read Only policy blocks bash/);

      result = await pi.trigger("tool_call", { toolName: "workspace_context", input: {} }, ctx);
      assert.equal(result, undefined, "RepoPrompt dynamic tools should stay governed by RepoPrompt MCP policy, not the built-in preflight hook");

      pi = await loadBridge("askBeforeWrite", [schemaResponse(), approvalResponse("Allow once")]);
      process.env.REPOPROMPT_PI_APPROVAL_TIMEOUT_MS = "300000";
      result = await pi.trigger("tool_call", { toolName: "bash", input: { command: "printf SENTINEL_SHOULD_NOT_LEAK" } }, ctx);
      assert.equal(result, undefined);
      assert.equal(pi.execCalls.length, 2);
      assert.ok(pi.execCalls[1].args.includes("ask_user"));
      assert.equal(pi.execCalls[1].options.timeout, 305000);
      const approvalPayload = JSON.parse(pi.execCalls[1].args.at(-1));
      assert.equal(approvalPayload.timeout_seconds, 300);
      assert.doesNotMatch(approvalPayload.context, /SENTINEL_SHOULD_NOT_LEAK/);
      assert.match(approvalPayload.context, /\[REDACTED\]/);
      delete process.env.REPOPROMPT_PI_APPROVAL_TIMEOUT_MS;

      pi = await loadBridge("askBeforeWrite", [schemaResponse(), approvalResponse("Allow for session"), approvalResponse("Deny")]);
      result = await pi.trigger("tool_call", bashEvent, ctx);
      assert.equal(result, undefined);
      assert.equal(pi.execCalls.length, 2);
      result = await pi.trigger("tool_call", bashEvent, ctx);
      assert.equal(result, undefined);
      assert.equal(pi.execCalls.length, 2, "session grant should avoid a second approval for the same canonical call");
      await pi.trigger("session_shutdown");
      result = await pi.trigger("tool_call", bashEvent, ctx);
      assert.equal(result.block, true);
      assert.match(result.reason, /denied/);
      assert.equal(pi.execCalls.length, 3, "session_shutdown should clear the grant and require approval again");

      pi = await loadBridge("fullAccess", [
        schemaResponse([toolSchema("context_builder"), toolSchema("ask_oracle")]),
        { code: 0, stdout: "ok", stderr: "" },
        { code: 0, stdout: "ok", stderr: "" },
      ]);
      await pi.registeredTools.find((entry) => entry.name === "context_builder").execute({});
      assert.equal(pi.execCalls.at(-1).options.timeout, 0);
      await pi.registeredTools.find((entry) => entry.name === "ask_oracle").execute({});
      assert.equal(pi.execCalls.at(-1).options.timeout, 0);

      let activeRepoPromptExecs = 0;
      let maxActiveRepoPromptExecs = 0;
      const execOrder: string[] = [];
      function delayedToolResponse(label: string): () => Promise<ExecResponse> {
        return async () => {
          activeRepoPromptExecs += 1;
          maxActiveRepoPromptExecs = Math.max(maxActiveRepoPromptExecs, activeRepoPromptExecs);
          execOrder.push(`${label}:start`);
          await new Promise((resolve) => setTimeout(resolve, 10));
          execOrder.push(`${label}:end`);
          activeRepoPromptExecs -= 1;
          return { code: 0, stdout: label, stderr: "" };
        };
      }
      pi = await loadBridge("fullAccess", [
        schemaResponse([toolSchema("agent_run"), toolSchema("read_file")]),
        delayedToolResponse("agent_run"),
        delayedToolResponse("read_file"),
      ]);
      await Promise.all([
        pi.registeredTools.find((entry) => entry.name === "agent_run").execute({ op: "start" }),
        pi.registeredTools.find((entry) => entry.name === "read_file").execute({ path: "README.md" }),
      ]);
      assert.equal(maxActiveRepoPromptExecs, 1, "managed RepoPrompt bridge calls must be serialized to avoid socket/admission races");
      assert.deepEqual(execOrder, ["agent_run:start", "agent_run:end", "read_file:start", "read_file:end"]);

      pi = await loadBridge("autoReview", [schemaResponse(), { code: 0, stdout: "not json", stderr: "" }]);
      result = await pi.trigger("tool_call", bashEvent, ctx);
      assert.equal(result.block, true);
      assert.match(result.reason, /malformed approval response/);

      pi = await loadBridge("askBeforeWrite", [schemaResponse(), { code: 1, stdout: "", stderr: "app is not running" }]);
      result = await pi.trigger("tool_call", bashEvent, ctx);
      assert.equal(result.block, true);
      assert.match(result.reason, /app approval failed/);
    }

    main().catch((error: unknown) => {
      console.error(error);
      process.exit(1);
    });
    """#

    private static func findExecutable(_ name: String) -> String? {
        let pathCandidates = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init) + [
                "/opt/homebrew/bin",
                "/usr/local/bin"
            ]
        for directory in pathCandidates {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent(name).path
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    @discardableResult
    private static func runProcess(executable: String, arguments: [String], workingDirectory: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        try process.run()
        process.waitUntilExit()
        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            XCTFail(output)
            throw BridgeHarnessProcessError.failed(status: process.terminationStatus, output: output)
        }
        return output
    }
}

private enum BridgeHarnessProcessError: Error {
    case failed(status: Int32, output: String)
}

private final class StubApplicationSupportFileManager: FileManager, @unchecked Sendable {
    private let applicationSupportURL: URL

    init(applicationSupportURL: URL) {
        self.applicationSupportURL = applicationSupportURL
        super.init()
    }

    override func urls(for directory: FileManager.SearchPathDirectory, in domainMask: FileManager.SearchPathDomainMask) -> [URL] {
        if directory == .applicationSupportDirectory, domainMask.contains(.userDomainMask) {
            return [applicationSupportURL]
        }
        return super.urls(for: directory, in: domainMask)
    }
}
