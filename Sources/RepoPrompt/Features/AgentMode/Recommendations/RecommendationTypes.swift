import Foundation

// MARK: - Recommendation Kind

/// Identifies distinct recommendation categories for the auto-recommendation wizard.
enum RecommendationKind: String, Codable, CaseIterable {
    case chatModel
    case contextBuilderAgent
    case mcpPresetExposure
    case mcpAgentDefaults
}

// MARK: - Recommendation Providers

/// Providers the recommendation wizard can consider when choosing models and agents.
enum RecommendationProviderKind: String, CaseIterable, Identifiable {
    case claudeCode
    case codex
    case cursor
    case pi
    case openCode
    case openAI

    var id: String {
        rawValue
    }

    var displayName: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codex: "Codex CLI"
        case .cursor: "Cursor CLI"
        case .pi: "pi"
        case .openCode: "OpenCode"
        case .openAI: "OpenAI API"
        }
    }

    var shortDisplayName: String {
        switch self {
        case .claudeCode: "Claude"
        case .codex: "Codex"
        case .cursor: "Cursor"
        case .pi: "pi"
        case .openCode: "OpenCode"
        case .openAI: "OpenAI"
        }
    }
}

// MARK: - Provider Status

/// Snapshot of provider availability without network calls.
struct ProviderStatusSnapshot {
    enum Availability: Equatable {
        case notConfigured // No key/connection present
        case configured // Key present or CLI installed flag set
        case ready // Verified key or successful connection test
    }

    let claudeCodeCLI: Availability
    let codexCLI: Availability
    let cursorCLI: Availability
    let piCLI: Availability
    let openCodeCLI: Availability

    let openAI: Availability

    /// Returns true if at least one provider is ready for chat.
    var hasAnyReadyProvider: Bool {
        [claudeCodeCLI, codexCLI, cursorCLI, piCLI, openCodeCLI, openAI].contains(.ready)
    }

    /// Returns true if any CLI agent is ready.
    var hasAnyCLIAgentReady: Bool {
        [claudeCodeCLI, codexCLI, cursorCLI, piCLI, openCodeCLI].contains(.ready)
    }

    /// Returns a copy with providers outside the enabled set treated as unavailable.
    func filtered(to enabledProviders: Set<RecommendationProviderKind>) -> ProviderStatusSnapshot {
        ProviderStatusSnapshot(
            claudeCodeCLI: enabledProviders.contains(.claudeCode) ? claudeCodeCLI : .notConfigured,
            codexCLI: enabledProviders.contains(.codex) ? codexCLI : .notConfigured,
            cursorCLI: enabledProviders.contains(.cursor) ? cursorCLI : .notConfigured,
            piCLI: enabledProviders.contains(.pi) ? piCLI : .notConfigured,
            openCodeCLI: enabledProviders.contains(.openCode) ? openCodeCLI : .notConfigured,
            openAI: enabledProviders.contains(.openAI) ? openAI : .notConfigured
        )
    }
}

// MARK: - Chat Backend

/// Identifies the backend type for chat model recommendations.
enum ChatBackendKind: String, Codable {
    case claudeCode
    case codex
    case pi
    case openAI

    var displayName: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codex: "Codex CLI"
        case .pi: "pi"
        case .openAI: "OpenAI API"
        }
    }
}

/// Represents a selectable chat backend option with its recommended model.
struct ChatBackendOption {
    let kind: ChatBackendKind
    let displayName: String
    let modelString: String?
    let description: String

    /// Tradeoff points shown in the UI.
    let tradeoffs: [String]
}

// MARK: - Recommendation DTOs

/// Recommendation for which chat model/backend to use.
struct ChatModelRecommendation {
    /// Whether this recommendation is already satisfied by current settings.
    var alreadySatisfied: Bool = false

    /// Whether the user has muted this recommendation.
    var isMuted: Bool = false

    /// The default backend selection based on priority rules.
    let defaultBackend: ChatBackendKind

    /// Option for Codex CLI, if available.
    let codexOption: ChatBackendOption?

    /// Option for OpenAI API, if available.
    let openAIOption: ChatBackendOption?

    /// Option for Claude Code CLI, if available.
    let claudeCodeOption: ChatBackendOption?

    /// Option for pi RPC, if available.
    let piOption: ChatBackendOption?

    /// Priority path used to determine the default (e.g., ["OpenAI API", "Codex CLI"]).
    let priorityPath: [String]

    /// Optional hint to show user how to upgrade to a better setup.
    let upgradeHint: String?

    /// Returns all available options.
    var availableOptions: [ChatBackendOption] {
        [piOption, claudeCodeOption, codexOption, openAIOption].compactMap(\.self)
    }

    /// Returns the option for a specific backend kind.
    func option(for kind: ChatBackendKind) -> ChatBackendOption? {
        switch kind {
        case .claudeCode: claudeCodeOption
        case .codex: codexOption
        case .pi: piOption
        case .openAI: openAIOption
        }
    }

    init(defaultBackend: ChatBackendKind, codexOption: ChatBackendOption?, openAIOption: ChatBackendOption?, claudeCodeOption: ChatBackendOption?, piOption: ChatBackendOption? = nil, priorityPath: [String], upgradeHint: String? = nil) {
        self.defaultBackend = defaultBackend
        self.codexOption = codexOption
        self.openAIOption = openAIOption
        self.claudeCodeOption = claudeCodeOption
        self.piOption = piOption
        self.priorityPath = priorityPath
        self.upgradeHint = upgradeHint
    }
}

/// Recommendation for context builder agent configuration.
struct ContextBuilderRecommendation {
    /// Whether this recommendation is already satisfied by current settings.
    var alreadySatisfied: Bool = false

    /// Whether the user has muted this recommendation.
    var isMuted: Bool = false

    let recommendedAgent: AgentProviderKind
    let recommendedModelRaw: String
    let rationale: String
    /// Optional hint to show user how to upgrade to a better setup.
    let upgradeHint: String?

    init(recommendedAgent: AgentProviderKind, recommendedModel: AgentModel, rationale: String, upgradeHint: String? = nil) {
        self.init(
            recommendedAgent: recommendedAgent,
            recommendedModelRaw: recommendedModel.rawValue,
            rationale: rationale,
            upgradeHint: upgradeHint
        )
    }

    init(recommendedAgent: AgentProviderKind, recommendedModelRaw: String, rationale: String, upgradeHint: String? = nil) {
        self.recommendedAgent = recommendedAgent
        self.recommendedModelRaw = recommendedModelRaw
        self.rationale = rationale
        self.upgradeHint = upgradeHint
    }
}

/// Resolved default for a single MCP agent role.
struct MCPAgentRoleDefault: Equatable {
    let role: AgentModelCatalog.TaskLabelKind
    let roleLabel: String
    let roleDescription: String
    let agent: AgentProviderKind
    let model: AgentModel
    let modelDisplayName: String
    /// Compound selection ID (e.g. "codexExec:gpt-5.4-mini-high").
    let selectionIDRaw: String
}

/// Recommendation for MCP agent role defaults (explore, engineer, pair, design).
struct MCPAgentDefaultsRecommendation {
    /// Whether this recommendation is already satisfied by current settings.
    var alreadySatisfied: Bool = false

    /// Whether the user has muted this recommendation.
    var isMuted: Bool = false

    /// Current effective defaults per role (may include user overrides).
    let currentRoleDefaults: [MCPAgentRoleDefault]

    /// Recommended defaults per role (no overrides).
    let recommendedRoleDefaults: [MCPAgentRoleDefault]

    /// Upgrade hint when not all CLIs are configured.
    let upgradeHint: String?
}

/// Recommendation for MCP preset exposure.
struct MCPPresetExposureRecommendation {
    /// Whether this recommendation is already satisfied by current settings.
    var alreadySatisfied: Bool = false

    /// Whether the user has muted this recommendation.
    var isMuted: Bool = false

    /// If true, presets should be temporarily hidden to use MCP chat model selector.
    let shouldTemporarilyDisablePresets: Bool
    let rationale: String
}

/// Container for all recommendations for a workspace.
struct RecommendationSet {
    var chatModel: ChatModelRecommendation?
    var contextBuilder: ContextBuilderRecommendation?
    var mcpPresetExposure: MCPPresetExposureRecommendation?
    var mcpAgentDefaults: MCPAgentDefaultsRecommendation?

    /// Returns true if any recommendation is present.
    var hasAny: Bool {
        chatModel != nil || contextBuilder != nil || mcpPresetExposure != nil || mcpAgentDefaults != nil
    }

    /// Number of recommendations that need action (not already satisfied and not muted).
    var actionableUnsatisfiedCount: Int {
        var count = 0
        if let chat = chatModel, !chat.alreadySatisfied, !chat.isMuted { count += 1 }
        if let cb = contextBuilder, !cb.alreadySatisfied, !cb.isMuted { count += 1 }
        if let mcp = mcpPresetExposure, !mcp.alreadySatisfied, !mcp.isMuted { count += 1 }
        if let agentDefaults = mcpAgentDefaults, !agentDefaults.alreadySatisfied, !agentDefaults.isMuted { count += 1 }
        return count
    }

    /// Returns true if any recommendation needs action (not already satisfied and not muted).
    var hasUnsatisfied: Bool {
        actionableUnsatisfiedCount > 0
    }

    /// Returns true if any recommendation is muted but differs from recommended.
    var hasMutedDifferences: Bool {
        if let chat = chatModel, chat.isMuted, !chat.alreadySatisfied { return true }
        if let cb = contextBuilder, cb.isMuted, !cb.alreadySatisfied { return true }
        if let mcp = mcpPresetExposure, mcp.isMuted, !mcp.alreadySatisfied { return true }
        if let agentDefaults = mcpAgentDefaults, agentDefaults.isMuted, !agentDefaults.alreadySatisfied { return true }
        return false
    }
}

// MARK: - Best Practice Profiles (July 2026)

/// Canonical best practice recommendations, versioned by date.
/// Update `versionCode` when recommendations change significantly.
enum BestPracticeProfiles {
    /// Bump when the table changes (used for gating mutes/badge).
    /// Format: YYYYMM plus a two-digit patch when the recommendation provider set changes inside a month.
    static let versionCode: Int = 20_260_701
    static let tableTitle = "Best Models by Use Case (pi + GPT-5.6)"

    struct UseCase {
        let id: String
        let title: String
        let modelLabel: String
        let accessLabel: String
        /// Canonical model identifier for direct API where applicable.
        let modelString: String?
        /// Optional Context Builder agent kind for CLI-style agents.
        let agentKind: AgentProviderKind?
        /// Optional Context Builder agent model.
        let agentModel: AgentModel?
        /// Strengths/reasons for this recommendation.
        let strengths: [String]
    }

    // MARK: Use Cases

    static let bestAgent = UseCase(
        id: "bestAgent",
        title: "Best Agent",
        modelLabel: "GPT-5.6 Sol Medium",
        accessLabel: "pi · OpenAI Codex",
        modelString: AIModel.piCustom(name: AgentModelCatalog.preferredPiModelRaw(thinkingLevel: .medium)).rawValue,
        agentKind: .pi,
        agentModel: .defaultModel,
        strengths: [
            "Preferred default for exploration and implementation",
            "Native pi RPC sessions and RepoPrompt bridge tools",
            "Balanced reasoning effort for routine agentic work",
            "Uses OpenAI Codex subscription auth through pi"
        ]
    )

    static let bestPlanning = UseCase(
        id: "bestPlanning",
        title: "Best Planning",
        modelLabel: "GPT-5.6 Sol XHigh",
        accessLabel: "pi · OpenAI Codex",
        modelString: AIModel.piCustom(name: AgentModelCatalog.preferredPiModelRaw(thinkingLevel: .xhigh)).rawValue,
        agentKind: .pi,
        agentModel: .defaultModel,
        strengths: [
            "Deep reasoning for architecture and whole-codebase analysis",
            "Native pi RPC sessions and RepoPrompt bridge tools",
            "Produces clear, actionable specifications",
            "Catches edge cases and cross-boundary implications"
        ]
    )

    static let bestInAppPlanningReview = UseCase(
        id: "bestInAppPlanningReview",
        title: "Best In‑App Planning/Review",
        modelLabel: "GPT-5.6 Sol XHigh",
        accessLabel: "pi · OpenAI Codex",
        modelString: AIModel.piCustom(name: AgentModelCatalog.preferredPiModelRaw(thinkingLevel: .xhigh)).rawValue,
        agentKind: .pi,
        agentModel: .defaultModel,
        strengths: [
            "Deep reasoning for Oracle planning and review",
            "Native pi RPC sessions and RepoPrompt bridge tools",
            "Excellent diff and architecture analysis",
            "Max remains available for exceptional cases"
        ]
    )

    static let bestContextBuilder = UseCase(
        id: "bestContextBuilder",
        title: "Best Context Builder",
        modelLabel: "GPT-5.6 Sol Low",
        accessLabel: "pi · OpenAI Codex",
        modelString: AIModel.piCustom(name: AgentModelCatalog.preferredPiModelRaw(thinkingLevel: .low)).rawValue,
        agentKind: .pi,
        agentModel: .defaultModel,
        strengths: [
            "Strong codebase understanding",
            "Efficient file exploration and selection",
            "Lower usage burn than higher reasoning efforts",
            "Practical default for repeated discovery runs"
        ]
    )

    static let all: [UseCase] = [
        bestAgent,
        bestPlanning,
        bestInAppPlanningReview,
        bestContextBuilder
    ]

    // MARK: Model Strength Summary

    static let claudeStrengths = """
    Claude Fable 5 XHigh remains the preferred design model for architecture and creative problem solving. \
    GPT-5.6 Sol through pi is the default for exploration, engineering, pairing, Context Builder, and Oracle.
    """

    static let gpt5HighStrengths = """
    GPT-5.6 Sol through pi provides the preferred reasoning range for RepoPrompt workflows. \
    Low is recommended for Context Builder, Medium for exploration, High for engineering and pair work, and XHigh for Oracle. \
    Max is available for exceptional cases but is not the default.
    """

    static let geminiStrengths = """
    Gemini 3.1 Pro excels at design and creative discussions. \
    Gemini 3.0 Flash is the preferred Gemini option for fast exploration.
    """

    // MARK: Explanatory Text

    static let codexVsOpenAIExplanation = """
    GPT-5.6 Sol is available through pi's OpenAI Codex provider. RepoPrompt discovers it from pi's authenticated model catalog rather than hard-coding provider availability.

    Use Low for Context Builder, Medium for exploration, High for engineering and pair work, and XHigh for Oracle. \
    Direct Codex CLI and API models remain fallbacks when the preferred pi model is unavailable.
    """

    static let contextBuilderRationale = "pi with OpenAI Codex GPT-5.6 Sol Low is the preferred Context Builder default for strong exploration with practical usage burn."

    static let contextWindowNote = """
    You can use XHigh or Max for context building, but context windows are finite, \
    and reasoning takes space. Prefer GPT-5.6 Sol Low for prompt and context building, \
    then use higher effort only when the task needs it.
    """

}
