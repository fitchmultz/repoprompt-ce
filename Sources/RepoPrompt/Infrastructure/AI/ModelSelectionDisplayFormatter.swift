import Foundation

enum ModelSelectionDisplayFormatter {
    static let defaultSeparator = " · "

    @MainActor
    static func aiModelQualifiedDisplayName(
        forRawValue rawValue: String,
        destinationID: String,
        availableModels: [AIModel],
        customOpenRouterModels: [String],
        compatibleClaudeBackendDisplayName: (AIModel) -> String? = { _ in nil }
    ) -> String {
        if availableModels.isEmpty {
            return "No models available"
        }

        if rawValue.hasPrefix("pi_custom_") {
            let piModelRaw = String(rawValue.dropFirst("pi_custom_".count))
            return AgentModelCatalog.qualifiedDisplayName(
                for: piModelRaw,
                agentKind: .pi,
                availability: .init(piAvailable: true)
            )
        }

        if let customModel = customOpenRouterModels.first(where: { rawValue == "openrouter_custom_\($0)" }) {
            return joined([AIProviderType.displayName(for: .openRouter), customModel])
        }

        if let selectedModel = availableModels.first(where: { $0.rawValue == rawValue }) {
            return aiModelQualifiedDisplayName(
                for: selectedModel,
                compatibleClaudeBackendDisplayName: compatibleClaudeBackendDisplayName
            )
        }

        if let parsed = AIModel.fromModelName(rawValue) {
            return aiModelQualifiedDisplayName(
                for: parsed,
                compatibleClaudeBackendDisplayName: compatibleClaudeBackendDisplayName
            )
        }

        if destinationID == "planningModel" {
            let trimmedRawValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmedRawValue.isEmpty ? "Select an Oracle model" : "Invalid Oracle model"
        }

        if let fallback = availableModels.first {
            return aiModelQualifiedDisplayName(
                for: fallback,
                compatibleClaudeBackendDisplayName: compatibleClaudeBackendDisplayName
            )
        }
        return "Select a model"
    }

    @MainActor
    static func aiModelQualifiedDisplayName(
        for model: AIModel,
        compatibleClaudeBackendDisplayName: (AIModel) -> String? = { _ in nil }
    ) -> String {
        switch model.providerType {
        case .claudeCode:
            return claudeCodeQualifiedDisplayName(
                for: model,
                compatibleClaudeBackendDisplayName: compatibleClaudeBackendDisplayName
            )
        case .codex:
            return joined([
                AIProviderType.displayName(for: .codex),
                codexModelDisplayName(for: model)
            ])
        case .pi:
            return AgentModelCatalog.qualifiedDisplayName(
                for: model.modelName,
                agentKind: .pi,
                availability: .init(piAvailable: true)
            )
        default:
            let providerName = AIProviderType.displayName(for: model.providerType)
            return joined([
                providerName,
                modelDisplayNameRemovingProviderPrefix(model.displayName, providerName: providerName, providerType: model.providerType)
            ])
        }
    }

    static func agentQualifiedDisplayName(
        for rawModel: String,
        agentKind: AgentProviderKind,
        availability: AgentModelCatalog.AvailabilityContext = .current,
        codexDynamicModels: [CodexAppServerClient.RemoteModel]? = nil,
        defaults: UserDefaults = .standard,
        includeEffortSuffix: Bool = true
    ) -> String {
        AgentModelCatalog.qualifiedDisplayName(
            for: rawModel,
            agentKind: agentKind,
            availability: availability,
            codexDynamicModels: codexDynamicModels,
            defaults: defaults,
            includeEffortSuffix: includeEffortSuffix,
            separator: defaultSeparator
        )
    }

    private static func claudeCodeQualifiedDisplayName(
        for model: AIModel,
        compatibleClaudeBackendDisplayName: (AIModel) -> String?
    ) -> String {
        if let descriptor = ClaudeCodeAIModelCatalog.compatibleBackendDescriptor(for: model) {
            let modelName = compatibleClaudeBackendDisplayName(model) ?? descriptor.modelDisplayName
            if modelName == descriptor.groupDisplayName {
                return modelName
            }
            return joined([descriptor.groupDisplayName, compatibleBackendOptionName(modelName, groupDisplayName: descriptor.groupDisplayName)])
        }

        guard let specifier = model.claudeCodeRuntimeSpecifierRaw else {
            return AIProviderType.displayName(for: .claudeCode)
        }
        let modelName = AgentModelCatalog.displayName(
            for: specifier,
            agentKind: .claudeCode,
            availability: .init(claudeCodeAvailable: true)
        )
        return joined([AIProviderType.displayName(for: .claudeCode), modelName])
    }

    private static func compatibleBackendOptionName(_ modelName: String, groupDisplayName: String) -> String {
        let trimmed = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        let group = groupDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !group.isEmpty else { return trimmed }
        let prefixes = ["\(group) ", "\(group) - ", "\(group) · "]
        for prefix in prefixes where trimmed.range(of: prefix, options: [.caseInsensitive, .anchored]) != nil {
            return String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed
    }

    private static func codexModelDisplayName(for model: AIModel) -> String {
        stripLeadingProviderTokens(from: model.displayName, tokens: ["CLI", "Codex CLI"])
    }

    private static func modelDisplayNameRemovingProviderPrefix(
        _ displayName: String,
        providerName: String,
        providerType: AIProviderType
    ) -> String {
        var tokens = [providerName]
        switch providerType {
        case .openRouter:
            tokens.append("oRouter")
        case .zAI:
            tokens.append("Z.AI")
        case .ollama:
            tokens.append("local")
        default:
            break
        }
        return stripLeadingProviderTokens(from: displayName, tokens: tokens)
    }

    private static func stripLeadingProviderTokens(from displayName: String, tokens: [String]) -> String {
        var trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        for token in tokens {
            let separators = [" · ", "·", "/", "-", " "]
            for separator in separators {
                let prefix = "\(token)\(separator)"
                if trimmed.range(of: prefix, options: [.caseInsensitive, .anchored]) != nil {
                    trimmed = String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }
        return trimmed
    }

    private static func joined(_ components: [String]) -> String {
        components
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: defaultSeparator)
    }
}
