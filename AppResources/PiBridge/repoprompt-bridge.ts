// RepoPrompt CE managed pi bridge extension
import { createHash } from "node:crypto";
import type { ExtensionAPI, ExtensionContext, ToolCallEvent, ToolCallEventResult } from "@earendil-works/pi-coding-agent";

const BRIDGE_VERSION = "__REPOPROMPT_BRIDGE_VERSION__";
const REPOPROMPT_CLI = "__REPOPROMPT_CLI__";
const REPOPROMPT_WINDOW_ID: string | undefined = "__REPOPROMPT_WINDOW_ID__";
const REPOPROMPT_IS_MANAGED_WINDOW_BRIDGE = REPOPROMPT_WINDOW_ID !== undefined;
const REPOPROMPT_MANAGED_RUN_ENV = "__REPOPROMPT_MANAGED_RUN_ENV__";
const REPOPROMPT_PI_PERMISSION_LEVEL_ENV = "__REPOPROMPT_PI_PERMISSION_LEVEL_ENV__";
const REPOPROMPT_SCHEMA_ARGS = JSON.parse("__REPOPROMPT_SCHEMA_ARGS_JSON__") as string[];
const REPOPROMPT_TOOL_ARGS_PREFIX = JSON.parse("__REPOPROMPT_TOOL_ARGS_PREFIX_JSON__") as string[];
const SCHEMA_LOAD_TIMEOUT_MS = 60_000;
const TOOL_EXEC_TIMEOUT_MS = 600_000;
const TOOL_APPROVAL_TIMEOUT_MS = 120_000;
const MAX_RESULT_CHARS = 50 * 1024;
const MAX_TOOL_INPUT_UI_CHARS = 1_200;
type JSONRecord = Record<string, unknown>;
type PiExecResult = Awaited<ReturnType<ExtensionAPI["exec"]>>;
type PiBuiltInToolName = "bash" | "read" | "edit" | "write" | "grep" | "find" | "ls";
type PiPermissionLevel = "readOnly" | "askBeforeWrite" | "autoReview" | "fullAccess";

const PI_BUILT_IN_TOOLS = new Set<string>(["bash", "read", "edit", "write", "grep", "find", "ls"]);
const PI_READ_ONLY_TOOLS = new Set<string>(["read", "grep", "find", "ls"]);
const PI_MUTATING_TOOLS = new Set<string>(["bash", "edit", "write"]);
const PI_SESSION_TOOL_GRANTS = new Set<string>();

type RepoPromptToolEntry = {
  name: string;
  description?: string;
  inputSchema?: unknown;
};

type RepoPromptToolsEnvelope = {
  tools?: RepoPromptToolEntry[];
};

type RepoPromptBridgeFailureClass =
  | "app_unavailable"
  | "connection_closed"
  | "schema_parse_failure"
  | "tool_registration_failure"
  | "routing_rejection"
  | "timeout"
  | "cli_failure"
  | "unknown";

type RepoPromptSchemaLoadDiagnostics = {
  status: "loaded" | "degraded" | "failed";
  toolCount: number;
  registeredToolCount: number;
  registrationFailureCount?: number;
  registrationFailures?: string[];
  failureClass?: RepoPromptBridgeFailureClass;
  error?: string;
};

type RepoPromptBridgeDetails = {
  bridgeVersion: string;
  tool: string;
  windowID: string | undefined;
  exitCode: number;
  truncated: boolean;
  cliPath: string;
  schemaArgs: string[];
  toolArgsPrefix: string[];
  isManagedWindowBridge: boolean;
  schemaLoadStatus?: RepoPromptSchemaLoadDiagnostics["status"];
  schemaToolCount?: number;
  registeredToolCount?: number;
  registrationFailureCount?: number;
  registrationFailures?: string[];
  failureClass?: RepoPromptBridgeFailureClass;
  error?: string;
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

function classifyBridgeFailure(message: string, exitCode?: number): RepoPromptBridgeFailureClass {
  const lower = message.toLowerCase();
  for (const failureClass of ["app_unavailable", "connection_closed", "schema_parse_failure", "routing_rejection", "timeout", "cli_failure"] as const) {
    if (lower.includes(`[${failureClass}]`)) return failureClass;
  }
  if (lower.includes("timed out") || lower.includes("timeout")) return "timeout";
  if (lower.includes("connection closed") || lower.includes("server closed") || lower.includes("connection reset")) {
    return "connection_closed";
  }
  if (lower.includes("schema") && (lower.includes("json") || lower.includes("tools array"))) {
    return "schema_parse_failure";
  }
  if (lower.includes("bind_context") && lower.includes("mutating")) return "routing_rejection";
  if (lower.includes("handshake rejected") || lower.includes("approval denied") || lower.includes("connection approval was denied") || lower.includes("protocol_version_mismatch") || lower.includes("protocol version mismatch")) {
    return "routing_rejection";
  }
  if (lower.includes("app is not running") || lower.includes("mcp is disabled") || lower.includes("socket not found")) {
    return "app_unavailable";
  }
  if (exitCode !== undefined && exitCode !== 0) return "cli_failure";
  return "unknown";
}

function recordToolRegistrationFailure(
  diagnostics: RepoPromptSchemaLoadDiagnostics,
  toolName: string,
  error: unknown,
) {
  const message = `Tool ${toolName}: ${String(error instanceof Error ? error.message : error)}`;
  diagnostics.status = diagnostics.status === "failed" ? "failed" : "degraded";
  diagnostics.failureClass = diagnostics.failureClass ?? "tool_registration_failure";
  diagnostics.registrationFailureCount = (diagnostics.registrationFailureCount ?? 0) + 1;
  diagnostics.registrationFailures = [...(diagnostics.registrationFailures ?? []), message].slice(0, 10);
  diagnostics.error = diagnostics.error ? `${diagnostics.error}; ${message}` : message;
}

function parseToolsSchema(stdout: string): RepoPromptToolEntry[] {
  let parsed: RepoPromptToolsEnvelope;
  try {
    parsed = JSON.parse(stdout) as RepoPromptToolsEnvelope;
  } catch (error) {
    const message = `RepoPrompt MCP tool schema was not valid JSON: ${String(error)}`;
    throw new Error(`[schema_parse_failure] ${message}`);
  }
  if (!Array.isArray(parsed.tools)) {
    throw new Error("[schema_parse_failure] RepoPrompt MCP tool schema did not include a tools array.");
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
    const message = stderr || stdout || `RepoPrompt MCP tool schema export failed with exit code ${result.code}`;
    const failureClass = classifyBridgeFailure(message, result.code);
    throw new Error(`[${failureClass}] ${message}`);
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
    const message = stderr || stdout || `RepoPrompt tool ${toolName} failed with exit code ${result.code}`;
    const failureClass = classifyBridgeFailure(message, result.code);
    throw new Error(`RepoPrompt tool ${toolName} failed (class=${failureClass}, exitCode=${result.code}): ${message}`);
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
      cliPath: REPOPROMPT_CLI,
      schemaArgs: repoPromptSchemaArgs(),
      toolArgsPrefix: [...REPOPROMPT_TOOL_ARGS_PREFIX],
      isManagedWindowBridge: REPOPROMPT_IS_MANAGED_WINDOW_BRIDGE,
    },
  };
}

function piPermissionLevelFromEnv(): PiPermissionLevel | undefined {
  const raw = process.env[REPOPROMPT_PI_PERMISSION_LEVEL_ENV]?.trim();
  switch (raw) {
    case "readOnly":
    case "askBeforeWrite":
    case "autoReview":
    case "fullAccess":
      return raw;
    default:
      return undefined;
  }
}

function isPiBuiltInToolName(toolName: string): toolName is PiBuiltInToolName {
  return PI_BUILT_IN_TOOLS.has(toolName);
}

function redactValue(key: string, value: unknown): unknown {
  const normalized = key.toLowerCase();
  if (
    normalized.includes("password")
    || normalized.includes("token")
    || normalized.includes("secret")
    || normalized.includes("api_key")
    || normalized.includes("apikey")
    || normalized.includes("authorization")
  ) {
    return "[REDACTED]";
  }
  if (typeof value === "string" && value.length > MAX_TOOL_INPUT_UI_CHARS) {
    return `${value.slice(0, MAX_TOOL_INPUT_UI_CHARS)}… [truncated ${value.length - MAX_TOOL_INPUT_UI_CHARS} chars]`;
  }
  return value;
}

function safeJSONString(value: unknown, maxChars: number): string {
  let text: string;
  try {
    text = JSON.stringify(value, (key, nested) => redactValue(key, nested), 2) ?? "null";
  } catch (error) {
    text = `[unserializable input: ${String(error)}]`;
  }
  if (text.length <= maxChars) return text;
  return `${text.slice(0, maxChars)}… [truncated ${text.length - maxChars} chars]`;
}

function canonicalizeForHash(value: unknown, seen: WeakSet<object> = new WeakSet()): unknown {
  if (Array.isArray(value)) {
    return value.map((item) => canonicalizeForHash(item, seen));
  }
  if (isRecord(value)) {
    if (seen.has(value)) throw new Error("cyclic tool input");
    seen.add(value);
    const sorted: JSONRecord = {};
    for (const key of Object.keys(value).sort()) {
      sorted[key] = canonicalizeForHash(value[key], seen);
    }
    seen.delete(value);
    return sorted;
  }
  return value === undefined ? null : value;
}

function canonicalJSONString(value: unknown): string {
  try {
    return JSON.stringify(canonicalizeForHash(value)) ?? "null";
  } catch (error) {
    return `[unserializable input: ${String(error)}]`;
  }
}

function sha256Hex(value: string): string {
  return createHash("sha256").update(value).digest("hex");
}

function piToolSessionGrantKey(event: ToolCallEvent, ctx: ExtensionContext): string {
  return [event.toolName, ctx.cwd, sha256Hex(canonicalJSONString(event.input))].join("\u{1f}");
}

function blockPiTool(reason: string): ToolCallEventResult {
  return { block: true, reason };
}

function parseRepoPromptJSONOutput(stdout: string): unknown {
  const trimmed = stdout.trim();
  if (!trimmed) throw new Error("empty RepoPrompt approval response");
  const parsed = JSON.parse(trimmed);
  if (
    isRecord(parsed)
    && Array.isArray(parsed.content)
    && parsed.content.length === 1
    && isRecord(parsed.content[0])
    && typeof parsed.content[0].text === "string"
  ) {
    return parseRepoPromptJSONOutput(parsed.content[0].text);
  }
  return parsed;
}

function approvalChoiceFromAskUserResponse(value: unknown): string | undefined {
  if (!isRecord(value)) return undefined;
  if (value.timed_out === true || value.skipped === true) return undefined;
  const answers = value.answers;
  if (!isRecord(answers)) return undefined;
  const answer = answers.pi_tool_approval;
  if (!isRecord(answer)) return undefined;
  if (answer.skipped === true) return undefined;
  if (Array.isArray(answer.selected_options) && typeof answer.selected_options[0] === "string") {
    return answer.selected_options[0];
  }
  if (Array.isArray(answer.answers) && typeof answer.answers[0] === "string") {
    return answer.answers[0];
  }
  return undefined;
}

async function requestRepoPromptPiToolApproval(
  pi: ExtensionAPI,
  event: ToolCallEvent,
  ctx: ExtensionContext,
  permissionLevel: PiPermissionLevel,
  inputSummary: string,
): Promise<ToolCallEventResult | void> {
  const modeCopy = permissionLevel === "autoReview"
    ? "Auto Review is not yet wired for pi built-ins, so RepoPrompt is routing this request to explicit app approval."
    : "RepoPrompt asks before pi mutating built-ins run.";
  const payload: JSONRecord = {
    title: `RepoPrompt pi preflight approval: ${event.toolName}`,
    context: [
      modeCopy,
      "This is a RepoPrompt policy gate before pi executes the built-in tool, not an OS sandbox.",
      `Workspace: ${ctx.cwd || "unknown"}`,
      "Input:",
      inputSummary,
    ].join("\n"),
    timeout_seconds: Math.ceil(TOOL_APPROVAL_TIMEOUT_MS / 1000),
    questions: [
      {
        id: "pi_tool_approval",
        question: `Allow pi to run built-in ${event.toolName} before execution?`,
        options: [
          { label: "Allow once", description: "Allow only this tool call." },
          { label: "Allow for session", description: "Allow matching tool calls for this pi run only." },
          { label: "Deny", description: "Block this tool call before pi executes it." },
        ],
        allows_multiple: false,
        allows_custom: false,
      },
    ],
  };

  let result: PiExecResult;
  try {
    result = await pi.exec(
      REPOPROMPT_CLI,
      repoPromptToolArgs("ask_user", payload),
      { signal: ctx.signal, timeout: TOOL_APPROVAL_TIMEOUT_MS + 5_000 },
    );
  } catch (error) {
    return blockPiTool(`RepoPrompt failed closed while requesting app approval for pi ${event.toolName}: ${String(error)}`);
  }

  const stdout = result.stdout.trim();
  const stderr = result.stderr.trim();
  if (result.code !== 0) {
    const message = stderr || stdout || `RepoPrompt ask_user approval failed with exit code ${result.code}`;
    const failureClass = classifyBridgeFailure(message, result.code);
    return blockPiTool(`RepoPrompt blocked pi ${event.toolName}; app approval failed (class=${failureClass}, exitCode=${result.code}): ${message}`);
  }

  let choice: string | undefined;
  try {
    choice = approvalChoiceFromAskUserResponse(parseRepoPromptJSONOutput(stdout));
  } catch (error) {
    return blockPiTool(`RepoPrompt blocked pi ${event.toolName}; malformed approval response: ${String(error)}`);
  }

  switch (choice) {
    case "Allow once":
      return;
    case "Allow for session":
      PI_SESSION_TOOL_GRANTS.add(piToolSessionGrantKey(event, ctx));
      return;
    case "Deny":
      return blockPiTool(`RepoPrompt denied pi ${event.toolName} before execution.`);
    default:
      return blockPiTool(`RepoPrompt cancelled or timed out waiting for pi ${event.toolName} approval.`);
  }
}

async function evaluatePiBuiltInToolPolicy(
  pi: ExtensionAPI,
  event: ToolCallEvent,
  ctx: ExtensionContext,
): Promise<ToolCallEventResult | void> {
  if (!isPiBuiltInToolName(event.toolName)) return;

  const permissionLevel = piPermissionLevelFromEnv();
  if (!permissionLevel) {
    return blockPiTool("RepoPrompt blocked pi built-in tool call because the managed pi permission policy was missing or invalid.");
  }

  if (PI_READ_ONLY_TOOLS.has(event.toolName)) return;
  if (!PI_MUTATING_TOOLS.has(event.toolName)) {
    return blockPiTool(`RepoPrompt blocked unknown pi built-in tool '${event.toolName}'.`);
  }

  if (permissionLevel === "readOnly") {
    return blockPiTool(`RepoPrompt pi Read Only policy blocks ${event.toolName} before execution.`);
  }

  if (permissionLevel === "fullAccess") return;

  const grantKey = piToolSessionGrantKey(event, ctx);
  if (PI_SESSION_TOOL_GRANTS.has(grantKey)) return;

  const inputSummary = safeJSONString(event.input, MAX_TOOL_INPUT_UI_CHARS);
  return await requestRepoPromptPiToolApproval(pi, event, ctx, permissionLevel, inputSummary);
}

function registerPiBuiltInToolPolicy(pi: ExtensionAPI) {
  if (!REPOPROMPT_IS_MANAGED_WINDOW_BRIDGE) return;
  pi.on("session_shutdown", () => {
    PI_SESSION_TOOL_GRANTS.clear();
  });
  pi.on("tool_call", async (event, ctx) => {
    try {
      return await evaluatePiBuiltInToolPolicy(pi, event, ctx);
    } catch (error) {
      return blockPiTool(`RepoPrompt failed closed while evaluating pi built-in tool policy: ${String(error)}`);
    }
  });
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

function registerRepoPromptBridgeStatusTool(pi: ExtensionAPI, schemaDiagnostics: RepoPromptSchemaLoadDiagnostics) {
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
      const status = schemaDiagnostics.status === "loaded"
        ? `RepoPrompt bridge ${BRIDGE_VERSION} loaded ${schemaDiagnostics.registeredToolCount} dynamic tool schema(s).`
        : schemaDiagnostics.status === "degraded"
          ? `RepoPrompt bridge ${BRIDGE_VERSION} loaded ${schemaDiagnostics.registeredToolCount}/${schemaDiagnostics.toolCount} dynamic tool schema(s); ${schemaDiagnostics.registrationFailureCount ?? 0} failed registration(s): ${schemaDiagnostics.error ?? "unknown error"}`
          : `RepoPrompt bridge ${BRIDGE_VERSION} could not load dynamic tool schemas (class=${schemaDiagnostics.failureClass ?? "unknown"}): ${schemaDiagnostics.error ?? "unknown error"}`;
      return {
        content: [{ type: "text" as const, text: status }],
        details: {
          bridgeVersion: BRIDGE_VERSION,
          tool: "repoprompt_bridge_status",
          windowID: REPOPROMPT_WINDOW_ID,
          exitCode: schemaDiagnostics.status === "loaded" ? 0 : 1,
          truncated: false,
          cliPath: REPOPROMPT_CLI,
          schemaArgs: repoPromptSchemaArgs(),
          toolArgsPrefix: [...REPOPROMPT_TOOL_ARGS_PREFIX],
          isManagedWindowBridge: REPOPROMPT_IS_MANAGED_WINDOW_BRIDGE,
          schemaLoadStatus: schemaDiagnostics.status,
          schemaToolCount: schemaDiagnostics.toolCount,
          registeredToolCount: schemaDiagnostics.registeredToolCount,
          registrationFailureCount: schemaDiagnostics.registrationFailureCount,
          registrationFailures: schemaDiagnostics.registrationFailures,
          failureClass: schemaDiagnostics.failureClass,
          error: schemaDiagnostics.error,
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

  registerPiBuiltInToolPolicy(pi);
  registerRepoPromptBindContextTool(pi);
  registerRepoPromptWindowStatusTool(pi);

  let tools: RepoPromptToolEntry[] = [];
  let schemaDiagnostics: RepoPromptSchemaLoadDiagnostics = { status: "loaded", toolCount: 0, registeredToolCount: 0 };
  try {
    tools = await loadRepoPromptTools(pi);
    schemaDiagnostics = { status: "loaded", toolCount: tools.length, registeredToolCount: 0 };
  } catch (error) {
    const errorMessage = String(error instanceof Error ? error.message : error);
    schemaDiagnostics = {
      status: "failed",
      toolCount: 0,
      registeredToolCount: 0,
      failureClass: classifyBridgeFailure(errorMessage),
      error: errorMessage,
    };
  }
  registerRepoPromptBridgeStatusTool(pi, schemaDiagnostics);
  for (const tool of tools) {
    const toolName = requireToolName(tool.name);
    if (REPOPROMPT_IS_MANAGED_WINDOW_BRIDGE && toolName === "bind_context") {
      continue;
    }
    const description = tool.description?.trim() || `Call RepoPrompt MCP tool ${toolName} through the current RepoPrompt CE window.`;
    try {
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
      schemaDiagnostics.registeredToolCount += 1;
    } catch (error) {
      recordToolRegistrationFailure(schemaDiagnostics, toolName, error);
    }
  }
}
