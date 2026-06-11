// RepoPrompt CE managed pi bridge extension
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

const BRIDGE_VERSION = "__REPOPROMPT_BRIDGE_VERSION__";
const REPOPROMPT_CLI = "__REPOPROMPT_CLI__";
const REPOPROMPT_CLIENT_NAME = "__REPOPROMPT_CLIENT_NAME__";
const REPOPROMPT_WINDOW_ID: string | undefined = "__REPOPROMPT_WINDOW_ID__";
const REPOPROMPT_IS_MANAGED_WINDOW_BRIDGE = REPOPROMPT_WINDOW_ID !== undefined;
const REPOPROMPT_MANAGED_RUN_ENV = "__REPOPROMPT_MANAGED_RUN_ENV__";
const REPOPROMPT_SCHEMA_ARGS = JSON.parse("__REPOPROMPT_SCHEMA_ARGS_JSON__") as string[];
const REPOPROMPT_TOOL_ARGS_PREFIX = JSON.parse("__REPOPROMPT_TOOL_ARGS_PREFIX_JSON__") as string[];
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
      async execute(_toolCallId: string, params: unknown, signal?: AbortSignal) {
        return await callRepoPromptTool(pi, toolName, isRecord(params) ? params : {}, signal);
      },
    });
  }
}
