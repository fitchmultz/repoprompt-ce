import Foundation

enum PiRepoPromptBridgeExtensionInstaller {
    enum InstallerError: Error, LocalizedError, Equatable {
        case applicationSupportUnavailable
        case cliHelperUnavailable
        case globalBridgeAlreadyExists(URL)
        case globalBridgeNotManaged(URL)

        var errorDescription: String? {
            switch self {
            case .applicationSupportUnavailable:
                "Application Support is unavailable; cannot prepare RepoPrompt pi bridge extension."
            case .cliHelperUnavailable:
                "RepoPrompt MCP CLI helper is unavailable; cannot prepare RepoPrompt pi bridge extension."
            case let .globalBridgeAlreadyExists(url):
                "A pi extension already exists at \(url.path), but it is not managed by RepoPrompt."
            case let .globalBridgeNotManaged(url):
                "The pi extension at \(url.path) is not managed by RepoPrompt and was not removed."
            }
        }
    }

    enum GlobalInstallationStatus: Equatable {
        case notInstalled
        case installed
        case installedButStale
        case installedByOther
    }

    struct GlobalInstallResult: Equatable {
        let statusBeforeInstall: GlobalInstallationStatus
        let extensionURL: URL

        var wasAlreadyInstalled: Bool {
            statusBeforeInstall == .installed
        }
    }

    static let extensionVersion = "2"

    private static let bridgeClientName = "pi"
    private static let managedMarker = "// RepoPrompt CE managed pi bridge extension"
    private static let globalExtensionFileName = "repoprompt-bridge.ts"

    static func install(
        windowID: Int,
        fileManager: FileManager = .default,
        cliPath: String? = Bundle.main.url(forAuxiliaryExecutable: "repoprompt-mcp")?.path
    ) throws -> URL {
        guard let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw InstallerError.applicationSupportUnavailable
        }
        guard let cliPath, !cliPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw InstallerError.cliHelperUnavailable
        }

        let directory = appSupport
            .appendingPathComponent("RepoPrompt CE", isDirectory: true)
            .appendingPathComponent("PiBridge", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let extensionURL = directory.appendingPathComponent("repoprompt-bridge.ts", isDirectory: false)
        let source = extensionSource(windowID: windowID, cliPath: cliPath)
        if let existing = try? String(contentsOf: extensionURL, encoding: .utf8), existing == source {
            return extensionURL
        }
        try source.write(to: extensionURL, atomically: true, encoding: .utf8)
        return extensionURL
    }

    static func globalExtensionURL(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        homeDirectory
            .appendingPathComponent(".pi", isDirectory: true)
            .appendingPathComponent("agent", isDirectory: true)
            .appendingPathComponent("extensions", isDirectory: true)
            .appendingPathComponent(globalExtensionFileName, isDirectory: false)
    }

    static func globalInstallStatus(
        fileManager: FileManager = .default,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        cliPath: String? = Bundle.main.url(forAuxiliaryExecutable: "repoprompt-mcp")?.path
    ) -> GlobalInstallationStatus {
        let extensionURL = globalExtensionURL(homeDirectory: homeDirectory)
        guard fileManager.fileExists(atPath: extensionURL.path),
              let existing = try? String(contentsOf: extensionURL, encoding: .utf8)
        else {
            return .notInstalled
        }
        guard existing.contains(managedMarker) else {
            return .installedByOther
        }
        guard let cliPath, !cliPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .installedButStale
        }
        let expected = extensionSource(windowID: nil, cliPath: cliPath)
        return existing == expected ? .installed : .installedButStale
    }

    @discardableResult
    static func installGlobal(
        fileManager: FileManager = .default,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        cliPath: String? = Bundle.main.url(forAuxiliaryExecutable: "repoprompt-mcp")?.path
    ) throws -> GlobalInstallResult {
        guard let cliPath, !cliPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw InstallerError.cliHelperUnavailable
        }
        let extensionURL = globalExtensionURL(homeDirectory: homeDirectory)
        let status = globalInstallStatus(fileManager: fileManager, homeDirectory: homeDirectory, cliPath: cliPath)
        guard status != .installedByOther else {
            throw InstallerError.globalBridgeAlreadyExists(extensionURL)
        }
        let directory = extensionURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = extensionSource(windowID: nil, cliPath: cliPath)
        if status != .installed {
            try source.write(to: extensionURL, atomically: true, encoding: .utf8)
        }
        return GlobalInstallResult(statusBeforeInstall: status, extensionURL: extensionURL)
    }

    @discardableResult
    static func uninstallGlobal(
        fileManager: FileManager = .default,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        cliPath: String? = Bundle.main.url(forAuxiliaryExecutable: "repoprompt-mcp")?.path
    ) throws -> Bool {
        let extensionURL = globalExtensionURL(homeDirectory: homeDirectory)
        let status = globalInstallStatus(fileManager: fileManager, homeDirectory: homeDirectory, cliPath: cliPath)
        switch status {
        case .notInstalled:
            return false
        case .installed, .installedButStale:
            try fileManager.removeItem(at: extensionURL)
            return true
        case .installedByOther:
            throw InstallerError.globalBridgeNotManaged(extensionURL)
        }
    }

    static func extensionSource(windowID: Int?, cliPath: String) -> String {
        let escapedCLIPath = jsonStringLiteral(cliPath)
        let escapedWindowID = windowID.map { jsonStringLiteral(String($0)) } ?? "undefined"
        return """
        \(managedMarker)
        import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

        const BRIDGE_VERSION = "\(extensionVersion)";
        const REPOPROMPT_CLI = \(escapedCLIPath);
        const REPOPROMPT_CLIENT_NAME = \(jsonStringLiteral(bridgeClientName));
        const REPOPROMPT_WINDOW_ID: string | undefined = \(escapedWindowID);
        const REPOPROMPT_IS_MANAGED_WINDOW_BRIDGE = REPOPROMPT_WINDOW_ID !== undefined;
        const REPOPROMPT_MANAGED_RUN_ENV = \(jsonStringLiteral(PiIntegrationConfiguration.managedRunEnvironmentKey));
        const REPOPROMPT_SCHEMA_ARGS = \(jsonStringArray(schemaArgs(windowID: windowID)));
        const REPOPROMPT_TOOL_ARGS_PREFIX = \(jsonStringArray(toolArgsPrefix(windowID: windowID)));
        const SCHEMA_LOAD_TIMEOUT_MS = 60_000;
        const TOOL_EXEC_TIMEOUT_MS = 600_000;
        const MAX_RESULT_CHARS = 50 * 1024;

        type JSONRecord = Record<string, unknown>;

        type RepoPromptToolEntry = {
          name: string;
          description?: string;
          inputSchema?: unknown;
        };

        type RepoPromptToolsEnvelope = {
          tools?: RepoPromptToolEntry[];
        };

        function isRecord(value: unknown): value is JSONRecord {
          return typeof value === "object" && value !== null && !Array.isArray(value);
        }

        function asParameterSchema(schema: unknown): any {
          if (!isRecord(schema)) {
            return { type: "object", properties: {}, additionalProperties: false };
          }
          return schema;
        }

        function requireToolName(name: unknown): string {
          if (typeof name !== "string" || name.trim().length === 0) {
            throw new Error("RepoPrompt MCP tool schema included a tool without a valid name.");
          }
          return name.trim();
        }

        function truncate(text: string): { text: string; truncated: boolean } {
          if (text.length <= MAX_RESULT_CHARS) return { text, truncated: false };
          return {
            text: text.slice(0, MAX_RESULT_CHARS) + `\\n\\n[RepoPrompt bridge output truncated to ${MAX_RESULT_CHARS} characters.]`,
            truncated: true,
          };
        }

        function parseToolsSchema(stdout: string): RepoPromptToolEntry[] {
          let parsed: RepoPromptToolsEnvelope;
          try {
            parsed = JSON.parse(stdout) as RepoPromptToolsEnvelope;
          } catch (error) {
            throw new Error(`RepoPrompt MCP tool schema was not valid JSON: ${String(error)}`);
          }
          if (!Array.isArray(parsed.tools)) {
            throw new Error("RepoPrompt MCP tool schema did not include a tools array.");
          }
          return parsed.tools.map((tool) => ({
            ...tool,
            name: requireToolName(tool.name),
          }));
        }

        function repoPromptSchemaArgs(): string[] {
          return [...REPOPROMPT_SCHEMA_ARGS];
        }

        async function loadRepoPromptTools(pi: ExtensionAPI): Promise<RepoPromptToolEntry[]> {
          const result = await pi.exec(
            REPOPROMPT_CLI,
            repoPromptSchemaArgs(),
            { timeout: SCHEMA_LOAD_TIMEOUT_MS },
          );
          const stdout = result.stdout.trim();
          const stderr = result.stderr.trim();
          if (result.code !== 0) {
            throw new Error(stderr || stdout || `RepoPrompt MCP tool schema export failed with exit code ${result.code}`);
          }
          return parseToolsSchema(stdout);
        }

        function repoPromptToolArgs(toolName: string, params: JSONRecord): string[] {
          return [...REPOPROMPT_TOOL_ARGS_PREFIX, "-c", toolName, "-j", JSON.stringify(params ?? {})];
        }

        async function callRepoPromptTool(
          pi: ExtensionAPI,
          toolName: string,
          params: JSONRecord,
          signal?: AbortSignal,
        ) {
          const result = await pi.exec(
            REPOPROMPT_CLI,
            repoPromptToolArgs(toolName, params),
            { signal, timeout: TOOL_EXEC_TIMEOUT_MS },
          );
          const stdout = result.stdout.trim();
          const stderr = result.stderr.trim();
          if (result.code !== 0) {
            throw new Error(stderr || stdout || `RepoPrompt tool ${toolName} failed with exit code ${result.code}`);
          }
          const merged = stdout || stderr || `RepoPrompt tool ${toolName} completed.`;
          const truncated = truncate(merged);
          return {
            content: [{ type: "text", text: truncated.text }],
            details: {
              bridgeVersion: BRIDGE_VERSION,
              tool: toolName,
              windowID: REPOPROMPT_WINDOW_ID,
              exitCode: result.code,
              truncated: truncated.truncated,
            },
          };
        }

        export default async function repoPromptBridge(pi: ExtensionAPI) {
          if (!REPOPROMPT_IS_MANAGED_WINDOW_BRIDGE && process.env[REPOPROMPT_MANAGED_RUN_ENV] === "1") {
            return;
          }

          const tools = await loadRepoPromptTools(pi);
          for (const tool of tools) {
            const toolName = requireToolName(tool.name);
            const description = tool.description?.trim() || `Call RepoPrompt MCP tool ${toolName} through the current RepoPrompt CE window.`;
            pi.registerTool({
              name: toolName,
              label: toolName,
              description,
              promptSnippet: `RepoPrompt: ${description}`,
              promptGuidelines: [
                `Use ${toolName} when RepoPrompt workspace context, selection, editing, user interaction, or Agent Mode control requires this RepoPrompt MCP tool.`,
                "RepoPrompt bridge tools are routed to the current RepoPrompt CE window and governed by RepoPrompt Agent Mode permissions.",
              ],
              parameters: asParameterSchema(tool.inputSchema),
              async execute(_toolCallId: string, params: JSONRecord, signal?: AbortSignal) {
                return await callRepoPromptTool(pi, toolName, params ?? {}, signal);
              },
            });
          }
        }
        """
    }

    static func schemaArgs(windowID: Int?) -> [String] {
        guard let windowID else {
            return ["--tools-schema", "--compact"]
        }
        return ["--client-name", bridgeClientName, "--tools-schema", "--compact", "-w", String(windowID)]
    }

    static func toolArgsPrefix(windowID: Int?) -> [String] {
        var args = ["--client-name", bridgeClientName, "--raw-json"]
        if let windowID {
            args.append(contentsOf: ["-w", String(windowID)])
        }
        return args
    }

    static func toolArgs(toolName: String, paramsJSON: String, windowID: Int?) -> [String] {
        toolArgsPrefix(windowID: windowID) + ["-c", toolName, "-j", paramsJSON]
    }

    private static func jsonStringArray(_ strings: [String]) -> String {
        let data = try! JSONEncoder().encode(strings)
        return String(data: data, encoding: .utf8)!
    }

    private static func jsonStringLiteral(_ string: String) -> String {
        let data = try! JSONEncoder().encode(string)
        return String(data: data, encoding: .utf8)!
    }
}
