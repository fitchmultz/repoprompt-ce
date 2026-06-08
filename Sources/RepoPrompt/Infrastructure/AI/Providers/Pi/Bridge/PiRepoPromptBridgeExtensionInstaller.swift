import Foundation

enum PiRepoPromptBridgeExtensionInstaller {
    enum InstallerError: Error, LocalizedError, Equatable {
        case applicationSupportUnavailable
        case cliHelperUnavailable

        var errorDescription: String? {
            switch self {
            case .applicationSupportUnavailable:
                "Application Support is unavailable; cannot prepare RepoPrompt pi bridge extension."
            case .cliHelperUnavailable:
                "RepoPrompt MCP CLI helper is unavailable; cannot prepare RepoPrompt pi bridge extension."
            }
        }
    }

    static let extensionVersion = "1"

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

    static func extensionSource(windowID: Int, cliPath: String) -> String {
        let escapedCLIPath = jsonStringLiteral(cliPath)
        return """
        import type { ExtensionAPI } from \"@earendil-works/pi-coding-agent\";
        import { Type } from \"typebox\";

        const BRIDGE_VERSION = \"\(extensionVersion)\";
        const REPOPROMPT_CLI = \(escapedCLIPath);
        const REPOPROMPT_WINDOW_ID = \"\(windowID)\";
        const MAX_RESULT_CHARS = 50 * 1024;

        const repoPromptToolSchema = Type.Object({
          tool: Type.String({
            description: \"RepoPrompt MCP tool name, for example get_file_tree, read_file, file_search, manage_selection, workspace_context, prompt, apply_edits, ask_user, context_builder, agent_run, agent_manage, share_thoughts, set_status, or wait_for_next_user_instruction.\",
          }),
          args: Type.Optional(Type.Record(Type.String(), Type.Any(), {
            description: \"JSON arguments to pass to the RepoPrompt MCP tool.\",
          })),
          timeoutMs: Type.Optional(Type.Number({
            description: \"Execution timeout in milliseconds. Defaults to 120000.\",
          })),
        });

        type RepoPromptToolParams = {
          tool: string;
          args?: Record<string, unknown>;
          timeoutMs?: number;
        };

        function truncate(text: string): { text: string; truncated: boolean } {
          if (text.length <= MAX_RESULT_CHARS) return { text, truncated: false };
          return {
            text: text.slice(0, MAX_RESULT_CHARS) + `\\n\\n[RepoPrompt bridge output truncated to ${MAX_RESULT_CHARS} characters.]`,
            truncated: true,
          };
        }

        export default function repoPromptBridge(pi: ExtensionAPI) {
          pi.registerTool({
            name: \"repoprompt_tool\",
            label: \"RepoPrompt Tool\",
            description: \"Call a RepoPrompt MCP tool through the current RepoPrompt CE window.\",
            promptSnippet: \"Call RepoPrompt MCP tools for workspace context, file tree/read/search, selection, edits, user interaction, and Agent Mode control.\",
            promptGuidelines: [
              \"Use repoprompt_tool when RepoPrompt workspace context, selected files, prompt content, apply-edits review, ask-user UI, or Agent Mode control is needed.\",
              \"For repoprompt_tool, pass the exact RepoPrompt MCP tool name in tool and its JSON arguments in args.\",
              \"Common repoprompt_tool tool names include get_file_tree, read_file, file_search, manage_selection, workspace_context, prompt, apply_edits, ask_user, context_builder, agent_run, agent_manage, share_thoughts, set_status, and wait_for_next_user_instruction.\",
            ],
            parameters: repoPromptToolSchema,
            async execute(_toolCallId: string, params: RepoPromptToolParams, signal) {
              const tool = params.tool.trim();
              if (!tool) throw new Error(\"RepoPrompt tool name is required.\");
              const jsonArgs = JSON.stringify(params.args ?? {});
              const timeout = Math.max(1, Math.min(params.timeoutMs ?? 120_000, 600_000));
              const result = await pi.exec(
                REPOPROMPT_CLI,
                [\"-w\", REPOPROMPT_WINDOW_ID, \"-c\", tool, \"-j\", jsonArgs],
                { signal, timeout },
              );
              const stdout = result.stdout.trim();
              const stderr = result.stderr.trim();
              if (result.code !== 0) {
                throw new Error(stderr || stdout || `RepoPrompt tool ${tool} failed with exit code ${result.code}`);
              }
              const merged = stdout || stderr || `RepoPrompt tool ${tool} completed.`;
              const truncated = truncate(merged);
              return {
                content: [{ type: \"text\", text: truncated.text }],
                details: {
                  bridgeVersion: BRIDGE_VERSION,
                  tool,
                  windowID: REPOPROMPT_WINDOW_ID,
                  exitCode: result.code,
                  truncated: truncated.truncated,
                },
              };
            },
          });
        }
        """
    }

    private static func jsonStringLiteral(_ string: String) -> String {
        let data = try! JSONEncoder().encode(string)
        return String(data: data, encoding: .utf8)!
    }
}
