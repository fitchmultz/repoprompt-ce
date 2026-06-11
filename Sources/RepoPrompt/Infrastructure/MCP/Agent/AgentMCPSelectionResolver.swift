import Foundation
import MCP

// SEARCH-HELPER: model_id, compound identifier, task label, agent+model resolution, MCP parsing, global role defaults
// Related:
// - AgentModelSelectionID.swift (compound ID format)
// - AgentModelCatalog.swift (discovery/validation/task label recommendations)
// - MCPAgentRoleDefaultsService.swift (global role-default overrides)
// - AgentRunMCPToolService.swift / AgentManageMCPToolService.swift (consumers)

/// Resolves `model_id` into agent + model for session configuration.
///
/// Accepts two forms:
/// 1. **Task label**: `explore`, `engineer`, `pair`, `design` — auto-picks the global effective role default
/// 2. **Compound ID**: `claudeCode:sonnet`, `codexExec:gpt-5.4-high` — explicit selection
enum AgentMCPSelectionResolver {
    typealias RoleSelectionProvider = @MainActor (
        _ role: AgentModelCatalog.TaskLabelKind,
        _ availability: AgentModelCatalog.AvailabilityContext
    ) -> AgentModelCatalog.NormalizedAgentSelection?

    struct ResolvedSelection {
        let agentRaw: String?
        let modelRaw: String?
        /// Provider-specific reasoning/thinking level extracted from the model id, when supported.
        let reasoningEffortRaw: String?
        /// The resolved task label kind, if the selection was role-driven.
        /// `nil` when the model_id was a compound ID or no role was involved.
        let taskLabelKind: AgentModelCatalog.TaskLabelKind?

        init(
            agentRaw: String?,
            modelRaw: String?,
            reasoningEffortRaw: String? = nil,
            taskLabelKind: AgentModelCatalog.TaskLabelKind?
        ) {
            self.agentRaw = agentRaw
            self.modelRaw = modelRaw
            self.reasoningEffortRaw = reasoningEffortRaw
            self.taskLabelKind = taskLabelKind
        }
    }

    /// Resolves a `model_id` string into agent + model components.
    ///
    /// - If `modelID` is nil/empty and `defaultTaskLabel` is provided, resolves that role's global effective default.
    /// - If `modelID` is nil/empty and no default is provided, returns nils (use agent defaults).
    /// - Task labels (`explore`, `engineer`, `pair`, `design`) resolve through global effective role defaults.
    /// - Compound IDs are validated against the catalog and are never rewritten by role defaults.
    ///
    /// - Throws: `MCPError.invalidParams` for unrecognized or invalid IDs.
    @MainActor
    static func resolve(
        modelID: String?,
        defaultTaskLabel: AgentModelCatalog.TaskLabelKind? = nil,
        availability: AgentModelCatalog.AvailabilityContext = .current,
        roleSelectionProvider: RoleSelectionProvider? = nil
    ) throws -> ResolvedSelection {
        let trimmed = modelID?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else {
            // No explicit model_id — use default global role if provided
            if let defaultKind = defaultTaskLabel,
               let resolved = resolveRoleSelection(defaultKind, availability: availability, roleSelectionProvider: roleSelectionProvider)
            {
                let normalizedPiSelection = normalizedPiSelection(agent: resolved.agent, modelRaw: resolved.modelRaw)
                return ResolvedSelection(
                    agentRaw: resolved.agent.rawValue,
                    modelRaw: normalizedPiSelection.modelRaw,
                    reasoningEffortRaw: normalizedPiSelection.reasoningEffortRaw,
                    taskLabelKind: defaultKind
                )
            }
            return ResolvedSelection(agentRaw: nil, modelRaw: nil, taskLabelKind: nil)
        }

        // Try task label first (no colon = not a compound ID)
        if !trimmed.contains(":") {
            let lowered = trimmed.lowercased()
            if let entry = AgentModelCatalog.taskLabels.first(where: { $0.label == lowered }) {
                guard let resolved = resolveRoleSelection(entry.kind, availability: availability, roleSelectionProvider: roleSelectionProvider) else {
                    throw MCPError.invalidParams("No available agent/model for task label '\(trimmed)'.")
                }
                let normalizedPiSelection = normalizedPiSelection(agent: resolved.agent, modelRaw: resolved.modelRaw)
                return ResolvedSelection(
                    agentRaw: resolved.agent.rawValue,
                    modelRaw: normalizedPiSelection.modelRaw,
                    reasoningEffortRaw: normalizedPiSelection.reasoningEffortRaw,
                    taskLabelKind: entry.kind
                )
            }
            let knownLabels = AgentModelCatalog.taskLabels.map(\.label).joined(separator: ", ")
            throw MCPError.invalidParams(
                "Unknown model_id '\(trimmed)'. Use a task label (\(knownLabels)) or a compound ID from agent_manage op=list_agents."
            )
        }

        // Parse compound ID
        guard let parsed = AgentModelSelectionID.parse(trimmed) else {
            throw MCPError.invalidParams(
                "Invalid model_id '\(trimmed)'. Use agent_manage op=list_agents to get valid model_id values."
            )
        }

        guard let agent = AgentProviderKind(rawValue: parsed.agentRaw) else {
            throw MCPError.invalidParams(
                "Unknown agent '\(parsed.agentRaw)' in model_id. Use agent_manage op=list_agents."
            )
        }

        guard AgentModelCatalog.isAgentAvailable(agent, availability: availability) else {
            throw MCPError.invalidParams(
                "Agent '\(parsed.agentRaw)' is currently unavailable."
            )
        }

        // Codex is intentionally permissive for dynamic/stale model IDs
        if agent != .codexExec {
            guard AgentModelCatalog.isValid(rawModel: parsed.modelRaw, for: agent, availability: availability) else {
                throw MCPError.invalidParams(
                    "Model '\(parsed.modelRaw)' is not valid for agent '\(parsed.agentRaw)'. Use agent_manage op=list_agents."
                )
            }
        }

        let normalizedPiSelection = normalizedPiSelection(agent: agent, modelRaw: parsed.modelRaw)
        return ResolvedSelection(
            agentRaw: parsed.agentRaw,
            modelRaw: normalizedPiSelection.modelRaw,
            reasoningEffortRaw: normalizedPiSelection.reasoningEffortRaw,
            taskLabelKind: nil
        )
    }

    private static func normalizedPiSelection(agent: AgentProviderKind, modelRaw: String) -> (modelRaw: String, reasoningEffortRaw: String?) {
        guard agent == .pi,
              let specifier = PiModelSpecifier(raw: modelRaw),
              let thinkingLevel = specifier.thinkingLevel
        else {
            return (modelRaw, nil)
        }
        return (specifier.providerQualifiedModelRaw, PiThinkingLevel.parse(thinkingLevel)?.rawValue)
    }

    @MainActor
    private static func resolveRoleSelection(
        _ role: AgentModelCatalog.TaskLabelKind,
        availability: AgentModelCatalog.AvailabilityContext,
        roleSelectionProvider: RoleSelectionProvider?
    ) -> AgentModelCatalog.NormalizedAgentSelection? {
        if let provided = roleSelectionProvider?(role, availability) {
            return provided
        }
        if let effective = MCPAgentRoleDefaultsService.effectiveNormalizedSelection(for: role, availability: availability) {
            return effective
        }
        return AgentModelCatalog.resolveTaskLabelKind(role, availability: availability)
    }
}
