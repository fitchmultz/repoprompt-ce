// RepoPrompt CE managed pi bridge extension
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

const BRIDGE_VERSION = "__REPOPROMPT_BRIDGE_VERSION__";
const REPOPROMPT_CLI = "__REPOPROMPT_CLI__";
const REPOPROMPT_WINDOW_ID: string | undefined = "__REPOPROMPT_WINDOW_ID__";
const REPOPROMPT_IS_MANAGED_WINDOW_BRIDGE = REPOPROMPT_WINDOW_ID !== undefined;
const REPOPROMPT_MANAGED_RUN_ENV = "__REPOPROMPT_MANAGED_RUN_ENV__";
const REPOPROMPT_SCHEMA_ARGS = JSON.parse("__REPOPROMPT_SCHEMA_ARGS_JSON__") as string[];
const REPOPROMPT_TOOL_ARGS_PREFIX = JSON.parse("__REPOPROMPT_TOOL_ARGS_PREFIX_JSON__") as string[];
const SCHEMA_LOAD_TIMEOUT_MS = 60_000;
const TOOL_EXEC_TIMEOUT_MS = 600_000;
const MAX_RESULT_CHARS = 50 * 1024;
const MANAGED_BRIDGE_DYNAMIC_TOOL_ALLOWLIST = new Set([
  "workspace_context",
  "get_file_tree",
  "get_code_structure",
  "read_file",
  "file_search",
  "agent_manage",
  "ask_oracle",
  "oracle_chat_log",
  "ask_user",
  "set_status",
  "app_settings",
]);

type JSONRecord = Record<string, unknown>;

type RepoPromptToolEntry = {
  name: string;
  description?: string;
  inputSchema?: unknown;
};

type RepoPromptToolsEnvelope = {
  tools?: RepoPromptToolEntry[];
};

type RepoPromptBridgeDetails = {
  bridgeVersion: string;
  tool: string;
  windowID: string | undefined;
  exitCode: number;
  truncated: boolean;
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
    text: text.slice(0, MAX_RESULT_CHARS) + `\n\n[RepoPrompt bridge output truncated to ${MAX_RESULT_CHARS} characters.]`,
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

function sanitizedBindContextParams(params: unknown): JSONRecord {
  const record = isRecord(params) ? params : {};
  const op = typeof record.op === "string" ? record.op.trim().toLowerCase() : "";
  if (op !== "list" && op !== "status") {
    throw new Error("Managed pi bridge bind_context supports only read-only op=list or op=status.");
  }
  const sanitized: JSONRecord = { op };
  if (typeof record.window_id === "number" && Number.isInteger(record.window_id)) {
    sanitized.window_id = record.window_id;
  }
  return sanitized;
}

async function callRepoPromptTool(
  pi: ExtensionAPI,
  toolName: string,
  params: JSONRecord,
  signal?: AbortSignal,
): Promise<{ content: Array<{ type: "text"; text: string }>; details: RepoPromptBridgeDetails }> {
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
    content: [{ type: "text" as const, text: truncated.text }],
    details: {
      bridgeVersion: BRIDGE_VERSION,
      tool: toolName,
      windowID: REPOPROMPT_WINDOW_ID,
      exitCode: result.code,
      truncated: truncated.truncated,
    },
  };
}

function registerRepoPromptBindContextTool(pi: ExtensionAPI) {
  if (!REPOPROMPT_IS_MANAGED_WINDOW_BRIDGE) return;
  pi.registerTool({
    name: "bind_context",
    label: "RepoPrompt bind context",
    description: "Read RepoPrompt CE window, tab, workspace, and current bridge routing binding state. Managed pi runs allow only op=list and op=status.",
    promptSnippet: "Inspect RepoPrompt CE window/tab routing binding",
    promptGuidelines: [
      "Use bind_context with op=list or op=status to inspect RepoPrompt routing state.",
      "Do not use bind_context op=bind from managed pi Agent Mode runs; mutating routing is blocked.",
    ],
    parameters: {
      type: "object",
      properties: {
        op: { type: "string", enum: ["list", "status"] },
        window_id: { type: "integer" },
      },
      required: ["op"],
      additionalProperties: false,
    },
    async execute(_toolCallId: string, params: unknown, signal?: AbortSignal) {
      return await callRepoPromptTool(pi, "bind_context", sanitizedBindContextParams(params), signal);
    },
  });
}

function registerRepoPromptBridgeStatusTool(pi: ExtensionAPI, schemaLoadError: string | undefined) {
  pi.registerTool({
    name: "repoprompt_bridge_status",
    label: "RepoPrompt bridge status",
    description: "Report whether the RepoPrompt CE pi bridge loaded dynamic MCP tool schemas.",
    promptSnippet: "Check RepoPrompt bridge status when dynamic RepoPrompt tools are unavailable",
    promptGuidelines: [
      "Use repoprompt_bridge_status if expected RepoPrompt tools are missing from pi.",
      "Report the bridge error to the user instead of retrying unavailable RepoPrompt tools blindly.",
    ],
    parameters: {
      type: "object",
      properties: {},
      additionalProperties: false,
    },
    async execute() {
      const status = schemaLoadError === undefined
        ? `RepoPrompt bridge ${BRIDGE_VERSION} loaded dynamic tool schemas.`
        : `RepoPrompt bridge ${BRIDGE_VERSION} could not load dynamic tool schemas: ${schemaLoadError}`;
      return {
        content: [{ type: "text" as const, text: status }],
        details: {
          bridgeVersion: BRIDGE_VERSION,
          tool: "repoprompt_bridge_status",
          windowID: REPOPROMPT_WINDOW_ID,
          exitCode: schemaLoadError === undefined ? 0 : 1,
          truncated: false,
        },
      };
    },
  });
}

function registerRepoPromptWindowStatusTool(pi: ExtensionAPI) {
  pi.registerTool({
    name: "repoprompt_window_status",
    label: "RepoPrompt window status",
    description: "List RepoPrompt CE windows, tabs, workspaces, and the current bridge routing binding.",
    promptSnippet: "List RepoPrompt CE windows/tabs/workspaces and current bridge routing binding",
    promptGuidelines: [
      "Use repoprompt_window_status to discover the current RepoPrompt CE window, workspace, tab, and routing binding before choosing a window-scoped RepoPrompt tool.",
      "Use repoprompt_window_status instead of shelling out to repoprompt-mcp when a pi run needs RepoPrompt window or tab routing status.",
    ],
    parameters: {
      type: "object",
      properties: {},
      additionalProperties: false,
    },
    async execute(_toolCallId: string, _params: unknown, signal?: AbortSignal) {
      return await callRepoPromptTool(pi, "bind_context", { op: "list" }, signal);
    },
  });
}

export default async function repoPromptBridge(pi: ExtensionAPI) {
  if (!REPOPROMPT_IS_MANAGED_WINDOW_BRIDGE && process.env[REPOPROMPT_MANAGED_RUN_ENV] === "1") {
    return;
  }

  registerRepoPromptBindContextTool(pi);
  registerRepoPromptWindowStatusTool(pi);

  let tools: RepoPromptToolEntry[] = [];
  let schemaLoadError: string | undefined;
  try {
    tools = await loadRepoPromptTools(pi);
  } catch (error) {
    schemaLoadError = String(error instanceof Error ? error.message : error);
  }
  registerRepoPromptBridgeStatusTool(pi, schemaLoadError);
  for (const tool of tools) {
    const toolName = requireToolName(tool.name);
    if (REPOPROMPT_IS_MANAGED_WINDOW_BRIDGE && !MANAGED_BRIDGE_DYNAMIC_TOOL_ALLOWLIST.has(toolName)) {
      continue;
    }
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
      async execute(_toolCallId: string, params: unknown, signal?: AbortSignal) {
        return await callRepoPromptTool(pi, toolName, isRecord(params) ? params : {}, signal);
      },
    });
  }
}
