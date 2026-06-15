# pi Integration Architecture

Current as of 2026-06-14. This document is contributor-facing: use it when editing RepoPrompt CE's pi provider, managed pi RPC runs, model discovery, Agent Mode runner, or RepoPrompt MCP bridge extension.

## Scope and goals

RepoPrompt CE integrates with pi as an external CLI/runtime while keeping RepoPrompt-owned workspace state, MCP routing, Agent Mode transcript state, and permission policy in the app. The integration supports two RepoPrompt entry points:

- **Agent Mode** interactive runs through `PiIntegratedAgentModeRunner` and `PiNativeSessionController`.
- **Context Builder/headless** prompts through `PiHeadlessAgentProvider` and the same pi RPC transport.

The contract preserves:

- RepoPrompt's public `AgentProviderKind.pi` and persisted `AgentModel` raw values;
- pi session identity and session-file persistence for follow-up runs;
- RepoPrompt MCP tool routing through the selected CE window;
- RepoPrompt Agent Mode permission and transcript ownership;
- pi's external runtime ownership of provider calls, model registry, session storage, message queueing, and extension UI requests.

pi is not a Claude-compatible provider plugin. It remains app-integrated because the current contract spans the pi CLI process, an installed/generated pi extension, RepoPrompt's MCP server, and Agent Mode state.

## Runtime flow

```text
+---------------------------- RepoPrompt CE app -----------------------------+
|                                                                            |
| Agent Mode / Context Builder                                               |
|   │                                                                        |
|   │  selected model, reasoning effort, prompt text, images, workspace cwd   |
|   ▼                                                                        |
| PiIntegratedAgentModeRunner / PiHeadlessAgentProvider                      |
|   │                                                                        |
|   │  install bridge, acquire MCP routing lease, launch pi RPC               |
|   ▼                                                                        |
| PiNativeSessionController                                                  |
|   │                                                                        |
|   │  command/event mapping, session state, tool-result stream mapping       |
|   ▼                                                                        |
| PiRPCClient                                                                |
|   │                                                                        |
|   │  JSONL stdin/stdout, request ids, timeouts, process lifecycle           |
+---│------------------------------------------------------------------------+
    │
    ▼
+---------------------------- pi CLI process --------------------------------+
| pi --mode rpc --approve [--extension <RepoPrompt bridge>]                 |
|   │                                                                        |
|   │  loads trusted project inputs, runs model/provider loop, emits events   |
|   ▼                                                                        |
| RepoPrompt pi bridge extension                                             |
|   │                                                                        |
|   │  pi.on("tool_call") preflight gate for pi built-ins                    |
|   │  pi.exec(repoprompt-mcp --tools-schema / -c <tool> -j <json>)           |
+---│------------------------------------------------------------------------+
    │
    ▼
+---------------------------- RepoPrompt MCP CLI ----------------------------+
| repoprompt-mcp routed by managed pi-schema identity and -w <windowID>      |
+----------------------------------------------------------------------------+
```

## Source map

| Concern | Owner path |
| --- | --- |
| pi availability, version gate, managed launch args/env | `Sources/RepoPrompt/Infrastructure/AI/Providers/Pi/PiIntegrationConfiguration.swift` |
| JSONL RPC transport, request ids, process lifecycle, event parsing | `Sources/RepoPrompt/Infrastructure/AI/Providers/Pi/RPC/PiRPCClient.swift` |
| Native session mapping, model/thinking apply, stream conversion | `Sources/RepoPrompt/Infrastructure/AI/Providers/Pi/RPC/PiNativeSessionController.swift` |
| Agent Mode lifecycle, MCP routing lease, extension UI mapping, terminal commit | `Sources/RepoPrompt/Features/AgentMode/Runtime/Runners/PiIntegratedAgentModeRunner.swift` |
| Bridge extension install and rendering | `Sources/RepoPrompt/Infrastructure/AI/Providers/Pi/Bridge/PiRepoPromptBridgeExtensionInstaller.swift` |
| Bridge extension source artifact | `AppResources/PiBridge/repoprompt-bridge.ts` |
| Model discovery/catalog polling | `Sources/RepoPrompt/Infrastructure/AI/Providers/Pi/` and Agent Mode model-selection surfaces |
| App/CLI MCP protocol | `Sources/RepoPromptShared/MCP`, `Sources/RepoPromptMCP` |

Follow `docs/architecture/source-layout.md` for placement. Keep new pi provider substrate under `Infrastructure/AI/Providers/Pi`, Agent Mode product flow under `Features/AgentMode`, and shared app/CLI MCP DTOs under `Sources/RepoPromptShared/MCP`.

## Owned contracts

### Launch and project trust

RepoPrompt-managed pi runs use:

```text
pi --mode rpc --approve [--extension <bridge.ts>]
```

`--approve` is intentional. pi 0.79+ treats project trust as an input-loading gate for project-local `.pi` resources, settings, packages, extensions, and `.agents/skills`. RepoPrompt-managed runs are explicit user actions for the selected workspace, so the run must load the workspace inputs that a normal trusted pi session would load. Do not replace this with a more conservative default unless product behavior changes explicitly.

RepoPrompt sets `REPOPROMPT_PI_MANAGED_RUN=1` for managed runs. The global/window bridge uses this to avoid loading the global auto-discovered bridge inside RepoPrompt-managed runs where a window-specific bridge is supplied.

RepoPrompt also sets `REPOPROMPT_PI_PERMISSION_LEVEL` for managed runs. The window-scoped bridge reads this value before pi built-in tools execute and applies RepoPrompt's preflight policy gate. This gate is a RepoPrompt approval/policy boundary; it is not an OS or kernel sandbox.

Minimum supported pi version is currently `0.79.0`, enforced by `PiIntegrationConfiguration.checkManagedRPCAvailability` before managed RPC runs that require the supported-version check.

### Built-in tool permission policy

RepoPrompt-managed pi runs gate pi built-ins through the managed bridge `tool_call` extension hook for `bash`, `read`, `edit`, `write`, `grep`, `find`, and `ls`. RepoPrompt dynamic MCP tools are not intercepted by this hook; they continue through the RepoPrompt MCP policy path.

Permission levels:

| Level | Behavior |
| --- | --- |
| `readOnly` | Allows `read`, `grep`, `find`, and `ls`; blocks `bash`, `edit`, and `write` before pi executes them. |
| `askBeforeWrite` | Allows read/search/list built-ins; asks before `bash`, `edit`, and `write`. |
| `autoReview` | Uses the same preflight gate as `askBeforeWrite` until pi auto-review routing is wired, then should route eligible requests through reviewer policy. |
| `fullAccess` | Allows built-ins without prompts for direct user-configured runs. MCP/Safe Managed policy can still override this at launch. |

Safe Managed and headless Context Builder pi runs use `askBeforeWrite` by default. Mutating built-ins that require approval are routed back to the app through the managed `pi-schema` RepoPrompt MCP path and the `ask_user` interaction surface; endpoint failures, malformed responses, timeouts, lost routing, or unavailable UI all fail closed before pi executes the tool. Session grants use an unredacted canonical input hash, stay in memory, and are scoped to the current managed pi process.

### Session identity and persistence

pi owns the session file and session ID. RepoPrompt stores both on the Agent Mode tab session:

- `providerSessionID`
- `piSessionFile`

On follow-up runs, RepoPrompt resumes by passing the persisted `piSessionFile` to `switch_session`. A stored session ID without a session file is not enough to resume and should fail clearly rather than inventing a new session.

After `get_state` or `agent_end`, RepoPrompt applies pi session state back to the tab session, including current model and thinking level when present.

### Model and thinking format

RepoPrompt must expose the user's pi model catalog without its own provider or model allowlist. If `pi` reports a model in `get_available_models` / `pi --list-models`, RepoPrompt and MitchPrompt should show that model in pi pickers and MCP settings. Provider/model names used in tests, docs, or smoke commands are examples for cost control, not a product allowlist.

Persisted model selection uses provider-qualified raw values when possible:

```text
<provider>/<modelID>
<provider>/<modelID>:<thinkingLevel>
```

`PiModelSpecifier` parses user/persisted raw values. Selecting a concrete pi model normally uses a provider prefix; pi default/no-model selections should use RepoPrompt's default-model sentinel and let pi choose from its own settings.

Thinking levels are translated through `PiThinkingLevel` and then sent to pi via `set_thinking_level`. Do not persist pi-specific thinking values outside the existing `selectedReasoningEffortRaw` path. pi supports both forms for every pi model:

```text
pi --model <provider>/<modelID> --thinking high
pi --model <provider>/<modelID>:high
```

The pi catalog is workspace-scoped and state-aware. `AgentPiModelRegistry.catalogState` is the synchronous read model for menus and can be `loading`, `loaded(PiDiscoveredModels)`, or `unavailable`. Cold persisted snapshots are synchronously warmed on first read so the first menu open can show cached models. Menus must render loaded model rows, a disabled `Loading pi models…` row, or a disabled `No pi models available` row; no provider menu should be enabled with an empty child list.

### Image payloads

RepoPrompt image attachments are converted by `PiRPCImageContentBuilder` into pi RPC image content blocks:

```json
{"type":"image","data":"<base64>","mimeType":"image/png"}
```

Image forwarding must be preserved for initial prompts, steering messages, and follow-up messages. Current pi RPC image support is local-file only. Remote image URLs fail explicitly with copy that asks the user to save the image locally before retrying; they must not be silently dropped or fetched without an explicit product decision.

### Context usage

pi does not currently expose a Codex-equivalent native context usage event through RepoPrompt's RPC mapping. RepoPrompt therefore uses the non-Codex estimator for pi and labels pi context usage as estimated/best-effort (`piBestEffortEstimate` / `Estimated (pi)`) rather than Codex live/exact usage. If pi later exposes native usage, add a pi-specific source and tests before changing that label.

### RPC framing and events

pi RPC is JSON Lines over stdin/stdout. RepoPrompt splits only on LF, trims ASCII whitespace, parses JSON objects, and routes:

- `response` payloads by request id;
- `extension_ui_request` payloads to Agent Mode user interactions;
- agent, turn, message, tool, queue, compaction, and extension events to `PiNativeSessionController.Event`.

Unknown event types should remain non-fatal. Protocol drift should produce bounded diagnostics rather than crashing normal runs or silently losing all evidence.

### Request timeout policy

Timeout behavior must be explicit because pi commands can mutate session/runtime state.

- **State-mutating commands** such as `prompt`, `steer`, `follow_up`, `set_model`, `set_thinking_level`, `switch_session`, and `new_session` must fail closed when they time out. The RPC process should be invalidated or shut down so RepoPrompt does not continue against unknown state.
- **Read-only commands** such as `get_state` and `get_available_models` may retry only when the process state is known or after a fresh resync policy has been applied.
- Late responses for timed-out requests must not satisfy future requests or mutate session state.

### Bridge extension

RepoPrompt installs a managed pi extension that dynamically exposes RepoPrompt MCP tools as pi tools.

- Window-scoped bridge: installed under the app support `RepoPrompt CE/PiBridge` directory for a specific window and passed via `--extension` to managed pi RPC runs.
- Global bridge: installed at `~/.pi/agent/extensions/repoprompt-bridge.ts` only through explicit RepoPrompt settings/UI flows. It is unmanaged by a specific window and must not load during `REPOPROMPT_PI_MANAGED_RUN=1`.
- Managed marker: `// RepoPrompt CE managed pi bridge extension`. Never overwrite an extension at the global path unless this marker is present.

The bridge source is maintained as `AppResources/PiBridge/repoprompt-bridge.ts` and rendered by Swift with placeholder substitution for the CLI path, window ID, managed env key, client identity, and argument arrays.

Bridge constants:

| Constant | Contract |
| --- | --- |
| `BRIDGE_VERSION` | Must match `PiRepoPromptBridgeExtensionInstaller.extensionVersion`. |
| `SCHEMA_LOAD_TIMEOUT_MS` | Timeout for `repoprompt-mcp --tools-schema --compact`. |
| `TOOL_EXEC_TIMEOUT_MS` | Timeout for individual RepoPrompt MCP tool invocations. |
| `TOOL_APPROVAL_TIMEOUT_MS` | Timeout for pi built-in preflight approval prompts. Timeout denies the tool before execution. |
| `MAX_RESULT_CHARS` | Maximum returned text payload before bridge-side truncation. |
| `MAX_TOOL_INPUT_UI_CHARS` | Maximum serialized pi built-in input shown in approval UI before redaction/truncation. |

Bridge tool results include `details.bridgeVersion`, `details.tool`, `details.windowID`, `details.exitCode`, `details.truncated`, `details.cliPath`, `details.schemaArgs`, `details.toolArgsPrefix`, and `details.isManagedWindowBridge` for downstream rendering and diagnostics. The `repoprompt_bridge_status` tool also reports structured schema-load diagnostics: `schemaLoadStatus`, `schemaToolCount`, `failureClass`, and `error`.

The bridge also registers a fixed read-only `repoprompt_window_status` tool. It calls RepoPrompt MCP `bind_context` with `op=list` and exists as a stable pi-facing routing discovery tool when provider/tool adapters fail to expose or select the raw `bind_context` name. Agents should use `repoprompt_window_status` instead of shelling out to `repoprompt-mcp` when they need the current RepoPrompt window, tab, workspace, or binding status.

Agent Mode connections must allow `bind_context` execution for read-only `op=list` and `op=status` so pi can inspect its own tab/window binding. Mutating `bind_context` operations and workspace-level routing mutation through `manage_workspaces` remain restricted during Agent Mode runs.

The managed pi bridge registers an explicit read-only `bind_context` wrapper plus the `repoprompt_window_status` alias. Window-scoped managed bridge schema discovery and tool calls use `--client-name pi-schema`; `MCPClientIdentity` canonicalizes only the exact client names `pi` and `pi-schema` into the managed `pi` Agent Mode identity family so the existing pi lease, expected-PID, routing, and tool-policy gates govern every managed bridge MCP call. Separator-less or suffixed near-matches such as `pischema`, `pi-schema-evil`, and `pifoo` are not managed pi identities. The global/personal bridge uses the separate `repoprompt-pi-bridge` client name and does not belong to the managed `pi` identity family. The managed bridge does not maintain a bridge-local dynamic tool allowlist. It registers every dynamic RepoPrompt tool exported by `repoprompt-mcp --tools-schema --compact -w <windowID>` except raw dynamic `bind_context`, because the bridge provides its own read-only wrapper for `op=list` and `op=status`. Tool advertisement, mutation boundaries, and execution permissions stay centralized in RepoPrompt Agent Mode policy, giving pi the same first-class supported RepoPrompt tool surface as Claude Code and Codex before RepoPrompt policy applies.

### MCP routing and permissions

RepoPrompt owns the MCP permission boundary for RepoPrompt tools and the preflight policy boundary for managed pi built-ins. The pi bridge exposes RepoPrompt tools, calls `repoprompt-mcp`, and intercepts only pi built-ins through `tool_call`; RepoPrompt still controls routing, active window selection, auto-approval, Agent Mode permission UI, and Safe Managed policy resolution.

Managed Agent Mode runs register the expected pi process PID and acquire an MCP bootstrap/routing lease before pi starts tool execution. Terminal cleanup must release leases, clear client connection policy, clean run routing state, and shut down the pi controller, which clears in-process session grants.

### Extension UI

pi RPC dialog methods (`select`, `confirm`, `input`, `editor`) are converted to `AgentAskUserInteraction` and answered through `extension_ui_response`. Fire-and-forget UI requests (`notify`, `setStatus`, `setWidget`, `setTitle`, `set_editor_text`) may be logged or surfaced later, but they must not block a run waiting for a response.

Timeouts from pi extension UI are milliseconds and map to RepoPrompt question timeouts in seconds.

## Validation matrix

Run the smallest coordinated validation that covers the changed contract, then broaden as needed.

| Change area | Required focused validation |
| --- | --- |
| Version gate / launch args / project trust docs | `make dev-test FILTER=PiIntegrationConfigurationTests` |
| RPC framing, event parsing, timeout policy | `make dev-test FILTER=PiRPCClientTests` |
| Session controller, stream mapping, image forwarding | `make dev-test FILTER=PiNativeSessionControllerTests` |
| Agent Mode pi runner behavior | `make dev-test FILTER=AgentModePi` or specific pi Agent Mode test filters |
| Headless Context Builder pi provider | `make dev-test FILTER=PiHeadlessAgentProviderTests` |
| Bridge rendering/install behavior | `make dev-test FILTER=PiRepoPromptBridgeExtensionInstallerTests` |
| Model catalog/polling/settings changes | `make dev-test FILTER=PiModelCatalogTests` and related model-selection filters |
| Source placement-sensitive changes | `make guardrails` |
| Swift code changes | `make dev-format`, `make dev-lint`, and a relevant `make dev-swift-build PRODUCT=RepoPrompt` or focused test lane |
| Runtime behavior that depends on a running app or MCP routing | live CE MCP smoke from `AGENTS.md`; use `make dev-smoke` if the debug app is already running, or `make dev-smoke-launch` only when a visible app relaunch is safe and approved |

Use the coordinated `make dev-*` commands by default so builds, tests, and launches do not collide with other agents.

## Developer setup and smoke notes

- Install pi `0.79.0` or newer.
- RepoPrompt launches pi through the configured `pi` CLI profile and supplemental PATH hints.
- Managed runs use `--mode rpc --approve`; model discovery and prompt-only flows can add `--no-session --no-tools`.
- The window-scoped bridge is generated and installed automatically for Agent Mode pi runs.
- The global bridge is optional and user-managed through RepoPrompt; it must not overwrite a non-RepoPrompt extension at the same path.
- Live smoke requires a CE debug app and CE debug CLI that talk to this checkout, not a production non-CE app.

A typical non-disruptive smoke, when the debug app is already running and the debug CLI is installed, is:

```bash
make dev-smoke
```

For pi-specific runtime changes, also exercise an Agent Mode pi run only when provider credentials/model access are available and visible app launch/relaunch is safe under `AGENTS.md`.

Cost-sensitive live pi call guidance:

- Use `zai/glm-5.2`, `deepseek/deepseek-v4-pro`, and `deepseek/deepseek-v4-flash` freely for real pi calls; they are cheap test models.
- Prefer colon or flag thinking syntax with those models, for example `zai/glm-5.2:high` or `--model zai/glm-5.2 --thinking high`.
- If the cheaper models are unreliable, use real `openai-codex/gpt-5.5` calls sparingly relative to the cheap models; low and medium thinking levels are acceptable for practical validation.
- This list is only cost-control guidance for real provider calls. It must never be copied into discovery, picker, settings, validation, or persistence logic as an allowlist.

## Upstream PR expectations

This integration is intended to be reviewable upstream. Keep diffs behavior-preserving unless a task explicitly changes behavior, prefer small named seams over hidden coupling, and include tests for every cross-boundary contract change. Do not leave generated output, protocol assumptions, or bridge behavior only in chat; update this document when the contract changes.

## References

- `docs/architecture/source-layout.md` — placement and guardrails.
- `docs/architecture/provider-plugins.md` — provider plugin seam; useful contrast for why pi is currently app-integrated.
- `AGENTS.md` — coordinated validation, live MCP smoke, and contribution preflight.
- Installed pi docs: `docs/usage.md`, `docs/security.md`, `docs/settings.md`, `docs/extensions.md`, and `docs/rpc.md` under the installed `@earendil-works/pi-coding-agent` package.
