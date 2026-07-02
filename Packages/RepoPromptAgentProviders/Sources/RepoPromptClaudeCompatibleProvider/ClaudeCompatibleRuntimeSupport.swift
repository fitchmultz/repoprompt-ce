import Foundation

public enum ClaudeCompatibleProviderError: Error, Equatable, Sendable {
    case invalidConfiguration(detail: String)
}

extension ClaudeCompatibleProviderError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .invalidConfiguration(detail):
            detail
        }
    }
}

public enum ClaudeCompatibleRuntimeVariant: String, CaseIterable, Codable, Hashable, Sendable {
    case standard
    case glm
    case kimi
    case customCompatible

    public var pluginID: ClaudeCompatibleProviderPluginID {
        switch self {
        case .standard:
            .claudeCode
        case .glm:
            .zaiClaudeCode
        case .kimi:
            .kimiClaudeCode
        case .customCompatible:
            .customClaudeCompatible
        }
    }

    public var compatibleBackendID: ClaudeCompatibleBackendID? {
        switch self {
        case .standard:
            nil
        case .glm:
            .glmZAI
        case .kimi:
            .kimi
        case .customCompatible:
            .custom
        }
    }

    public init(pluginID: ClaudeCompatibleProviderPluginID) {
        switch pluginID {
        case .claudeCode:
            self = .standard
        case .zaiClaudeCode:
            self = .glm
        case .kimiClaudeCode:
            self = .kimi
        case .customClaudeCompatible:
            self = .customCompatible
        }
    }
}

public enum ClaudeCompatiblePromptDeliveryMode: String, CaseIterable, Codable, Hashable, Sendable {
    case userMessageXML
    case userMessageXMLWithEmptySystemPrompt
    case nativeSystemPrompt

    public var sendsRepoPromptAsUserMessage: Bool {
        switch self {
        case .userMessageXML, .userMessageXMLWithEmptySystemPrompt:
            true
        case .nativeSystemPrompt:
            false
        }
    }

    public func nativeSystemPromptOverride(instructions: String) -> String? {
        switch self {
        case .userMessageXML:
            nil
        case .userMessageXMLWithEmptySystemPrompt:
            ""
        case .nativeSystemPrompt:
            instructions
        }
    }
}

public enum ClaudeCompatiblePromptDelivery {
    public static let instructionsTag = "claude_code_instructions"

    public static func decoratedUserMessage(_ userMessage: String, instructions: String) -> String {
        let trimmedInstructions = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedInstructions.isEmpty else {
            return userMessage
        }

        let instructionsBlock = """
        <\(instructionsTag)>
        \(trimmedInstructions)
        </\(instructionsTag)>
        """

        let trimmedUserMessage = userMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedUserMessage.isEmpty else {
            return instructionsBlock
        }

        return """
        \(instructionsBlock)

        \(userMessage)
        """
    }

    public static func userMessage(
        _ userMessage: String,
        instructions: String,
        mode: ClaudeCompatiblePromptDeliveryMode
    ) -> String {
        mode.sendsRepoPromptAsUserMessage
            ? decoratedUserMessage(userMessage, instructions: instructions)
            : userMessage
    }
}

public extension ClaudeCompatibleBackendAuth {
    var environmentVariableName: String {
        switch self {
        case .anthropicAPIKey:
            "ANTHROPIC_API_KEY"
        case .anthropicAuthToken:
            "ANTHROPIC_AUTH_TOKEN"
        }
    }
}

public extension ClaudeCompatibleBackendID {
    var defaultDisplayName: String {
        switch self {
        case .glmZAI:
            "CC Zai"
        case .kimi:
            "CC Moonshot"
        case .custom:
            "CC Custom"
        }
    }

    var defaultPreset: ClaudeCompatibleBackendConfig {
        switch self {
        case .glmZAI:
            ClaudeCompatibleBackendConfig(
                id: self,
                isEnabled: true,
                displayName: defaultDisplayName,
                baseURL: "https://api.z.ai/api/anthropic",
                auth: .anthropicAuthToken,
                modelBehavior: .claudeSlotMapping(ClaudeCompatibleSlotMapping(
                    haiku: "glm-4.7",
                    sonnet: "glm-5-turbo",
                    opus: "glm-5.1"
                ))
            )
        case .kimi:
            ClaudeCompatibleBackendConfig(
                id: self,
                isEnabled: true,
                displayName: defaultDisplayName,
                baseURL: "https://api.kimi.com/coding/",
                auth: .anthropicAPIKey,
                modelBehavior: .noModel
            )
        case .custom:
            ClaudeCompatibleBackendConfig(
                id: self,
                isEnabled: false,
                displayName: defaultDisplayName,
                baseURL: "",
                auth: .anthropicAPIKey,
                modelBehavior: .noModel
            )
        }
    }
}

public extension ClaudeCompatibleSlotMapping {
    var normalized: ClaudeCompatibleSlotMapping {
        ClaudeCompatibleSlotMapping(
            haiku: haiku.trimmingCharacters(in: .whitespacesAndNewlines),
            sonnet: sonnet.trimmingCharacters(in: .whitespacesAndNewlines),
            opus: opus.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    var isValid: Bool {
        let mapping = normalized
        return !mapping.haiku.isEmpty && !mapping.sonnet.isEmpty && !mapping.opus.isEmpty
    }
}

public extension ClaudeCompatibleBackendConfig {
    var normalizedDisplayName: String {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return id.defaultDisplayName }
        return trimmed
    }

    var normalizedBaseURL: String? {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              components.host?.isEmpty == false
        else {
            return nil
        }
        return trimmed
    }

    var normalized: ClaudeCompatibleBackendConfig {
        let normalizedBehavior: ClaudeCompatibleBackendModelBehavior = switch modelBehavior {
        case .noModel:
            .noModel
        case let .claudeSlotMapping(mapping):
            .claudeSlotMapping(mapping.normalized)
        }
        return ClaudeCompatibleBackendConfig(
            id: id,
            isEnabled: isEnabled,
            displayName: normalizedDisplayName,
            baseURL: baseURL.trimmingCharacters(in: .whitespacesAndNewlines),
            auth: auth,
            modelBehavior: normalizedBehavior
        )
    }

    var isValid: Bool {
        guard normalizedBaseURL != nil else { return false }
        switch modelBehavior {
        case .noModel:
            return true
        case let .claudeSlotMapping(mapping):
            return mapping.isValid
        }
    }
}

public enum ClaudeCompatibleBackendEnvironmentBuilder {
    private static let glmTimeoutMilliseconds = "3000000"

    public static func removedEnvironmentKeys(config: ClaudeCompatibleBackendConfig) -> Set<String> {
        let configuredAuthKey = config.normalized.auth.environmentVariableName
        return Set(["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN"].filter { $0 != configuredAuthKey })
    }

    public static func environment(
        config: ClaudeCompatibleBackendConfig,
        apiKey: String
    ) -> [String: String] {
        let normalizedConfig = config.normalized
        var environment: [String: String] = [
            "ANTHROPIC_BASE_URL": normalizedConfig.normalizedBaseURL ?? normalizedConfig.baseURL,
            normalizedConfig.auth.environmentVariableName: apiKey
        ]

        if normalizedConfig.id == .glmZAI {
            environment["API_TIMEOUT_MS"] = glmTimeoutMilliseconds
        }

        if case let .claudeSlotMapping(mapping) = normalizedConfig.modelBehavior {
            let normalizedMapping = mapping.normalized
            environment["ANTHROPIC_DEFAULT_HAIKU_MODEL"] = normalizedMapping.haiku
            environment["ANTHROPIC_DEFAULT_SONNET_MODEL"] = normalizedMapping.sonnet
            environment["ANTHROPIC_DEFAULT_OPUS_MODEL"] = normalizedMapping.opus
        }

        return environment
    }
}

public enum ClaudeCompatibleModelNormalizer {
    public static let defaultModelRawValue = "glm-5-turbo"
    public static let haikuEquivalentModelRawValue = "glm-4.7"
    public static let opusEquivalentModelRawValue = "glm-5.1"
    public static let defaultRequestedModelRawValue = "sonnet"
    public static let haikuRequestedModelRawValue = "haiku"
    public static let opusRequestedModelRawValue = "opus"
    public static let defaultSentinelRawValue = "default"
    public static let kimiNoModelRawValue = "kimi-code"
    public static let customNoModelRawValue = "custom-claude-compatible"

    public static let supportedModelRawValues: [String] = [
        haikuEquivalentModelRawValue,
        defaultModelRawValue,
        opusEquivalentModelRawValue
    ]

    public static func normalizedRequestedModel(_ rawModel: String?) -> String? {
        guard let rawModel else { return nil }
        let trimmed = rawModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != defaultSentinelRawValue else { return nil }
        return trimmed
    }

    public static func isGLMModel(
        _ rawModel: String?,
        config: ClaudeCompatibleBackendConfig
    ) -> Bool {
        guard let normalized = normalizedRequestedModel(rawModel)?.lowercased() else { return false }
        if slot(forBackendModelID: normalized, in: slotMapping(from: config)) != nil {
            return true
        }
        return supportedModelRawValues.contains(normalized)
    }

    public static func normalizedGLMModel(
        _ rawModel: String?,
        config: ClaudeCompatibleBackendConfig
    ) -> String? {
        guard let normalized = normalizedRequestedModel(rawModel)?.lowercased() else {
            return defaultRequestedModelRawValue
        }

        let mapping = slotMapping(from: config)
        switch normalized {
        case haikuRequestedModelRawValue:
            return haikuRequestedModelRawValue
        case defaultRequestedModelRawValue:
            return defaultRequestedModelRawValue
        case opusRequestedModelRawValue:
            return opusRequestedModelRawValue
        default:
            break
        }

        if let configuredSlot = slot(forBackendModelID: normalized, in: mapping) {
            return configuredSlot
        }

        switch normalized {
        case haikuEquivalentModelRawValue:
            return haikuRequestedModelRawValue
        case defaultModelRawValue:
            return defaultRequestedModelRawValue
        case opusEquivalentModelRawValue:
            return opusRequestedModelRawValue
        default:
            return nil
        }
    }

    public static func normalizedSlotModel(
        _ rawModel: String?,
        config: ClaudeCompatibleBackendConfig
    ) -> String? {
        guard let normalized = normalizedRequestedModel(rawModel)?.lowercased() else {
            return defaultRequestedModelRawValue
        }

        let mapping = slotMapping(from: config)
        switch normalized {
        case haikuRequestedModelRawValue:
            return haikuRequestedModelRawValue
        case defaultRequestedModelRawValue:
            return defaultRequestedModelRawValue
        case opusRequestedModelRawValue:
            return opusRequestedModelRawValue
        default:
            break
        }

        if let configuredSlot = slot(forBackendModelID: normalized, in: mapping) {
            return configuredSlot
        }

        switch normalized {
        case haikuEquivalentModelRawValue:
            return haikuRequestedModelRawValue
        case defaultModelRawValue:
            return defaultRequestedModelRawValue
        case opusEquivalentModelRawValue:
            return opusRequestedModelRawValue
        default:
            return nil
        }
    }

    public static func noModelRawValue(for backendID: ClaudeCompatibleBackendID) -> String {
        switch backendID {
        case .glmZAI:
            defaultRequestedModelRawValue
        case .kimi:
            kimiNoModelRawValue
        case .custom:
            customNoModelRawValue
        }
    }

    private static func slotMapping(
        from config: ClaudeCompatibleBackendConfig
    ) -> ClaudeCompatibleSlotMapping {
        if case let .claudeSlotMapping(mapping) = config.modelBehavior {
            return mapping.normalized
        }
        if case let .claudeSlotMapping(mapping) = ClaudeCompatibleBackendID.glmZAI.defaultPreset.modelBehavior {
            return mapping.normalized
        }
        return ClaudeCompatibleSlotMapping(
            haiku: haikuEquivalentModelRawValue,
            sonnet: defaultModelRawValue,
            opus: opusEquivalentModelRawValue
        )
    }

    private static func slot(
        forBackendModelID modelID: String,
        in mapping: ClaudeCompatibleSlotMapping
    ) -> String? {
        let normalizedMapping = mapping.normalized
        if modelID == normalizedMapping.haiku.lowercased() {
            return haikuRequestedModelRawValue
        }
        if modelID == normalizedMapping.sonnet.lowercased() {
            return defaultRequestedModelRawValue
        }
        if modelID == normalizedMapping.opus.lowercased() {
            return opusRequestedModelRawValue
        }
        return nil
    }
}

public struct ClaudeCompatibleLaunchEnvironmentResolver: Sendable {
    public typealias BackendConfigProvider = @Sendable (_ backendID: ClaudeCompatibleBackendID) -> ClaudeCompatibleBackendConfig
    public typealias ZAISecretProvider = @Sendable () async throws -> String?
    public typealias BackendSecretProvider = @Sendable (_ backendID: ClaudeCompatibleBackendID) async throws -> String?

    private let backendConfigProvider: BackendConfigProvider
    private let zaiSecretProvider: ZAISecretProvider
    private let backendSecretProvider: BackendSecretProvider

    public init(
        backendConfigProvider: @escaping BackendConfigProvider,
        zaiSecretProvider: @escaping ZAISecretProvider,
        backendSecretProvider: @escaping BackendSecretProvider
    ) {
        self.backendConfigProvider = backendConfigProvider
        self.zaiSecretProvider = zaiSecretProvider
        self.backendSecretProvider = backendSecretProvider
    }

    public func resolve(
        variant: ClaudeCompatibleRuntimeVariant,
        requestedModel: String?
    ) async throws -> ClaudeCompatibleLaunchEnvironment {
        switch variant {
        case .standard:
            let normalizedModel = ClaudeCompatibleModelNormalizer.normalizedRequestedModel(requestedModel)
            let glmConfig = backendConfigProvider(.glmZAI)
            if ClaudeCompatibleModelNormalizer.isGLMModel(normalizedModel, config: glmConfig) {
                throw ClaudeCompatibleProviderError.invalidConfiguration(detail: "GLM models require the Claude Code GLM agent.")
            }
            if isKnownNoModelCompatibleRaw(normalizedModel) {
                throw ClaudeCompatibleProviderError.invalidConfiguration(detail: "Compatible backend models require their matching Claude-compatible agent.")
            }
            return ClaudeCompatibleLaunchEnvironment(
                effectiveModel: normalizedModel,
                environmentOverrides: [:],
                backendID: nil
            )
        case .glm, .kimi, .customCompatible:
            guard let backendID = variant.compatibleBackendID else {
                throw ClaudeCompatibleProviderError.invalidConfiguration(detail: "Unsupported Claude Code runtime variant.")
            }
            return try await resolveCompatibleBackend(backendID, variant: variant, requestedModel: requestedModel)
        }
    }

    private func resolveCompatibleBackend(
        _ backendID: ClaudeCompatibleBackendID,
        variant: ClaudeCompatibleRuntimeVariant,
        requestedModel: String?
    ) async throws -> ClaudeCompatibleLaunchEnvironment {
        let config = backendConfigProvider(backendID).normalized
        guard config.isEnabled, config.isValid else {
            throw ClaudeCompatibleProviderError.invalidConfiguration(detail: "\(config.normalizedDisplayName) has an invalid backend configuration.")
        }

        let effectiveModel: String?
        switch config.modelBehavior {
        case .noModel:
            guard isAllowedNoModelSelection(requestedModel, backendID: backendID) else {
                throw ClaudeCompatibleProviderError.invalidConfiguration(detail: "Unsupported \(config.normalizedDisplayName) model selection.")
            }
            effectiveModel = nil
        case .claudeSlotMapping:
            guard let slot = ClaudeCompatibleModelNormalizer.normalizedSlotModel(
                requestedModel,
                config: config
            ) else {
                throw ClaudeCompatibleProviderError.invalidConfiguration(detail: "Unsupported \(config.normalizedDisplayName) model selection.")
            }
            effectiveModel = slot
        }

        let rawSecret: String? = if backendID == .glmZAI {
            try await zaiSecretProvider()
        } else {
            try await backendSecretProvider(backendID)
        }
        guard let apiKey = rawSecret?.trimmingCharacters(in: .whitespacesAndNewlines), !apiKey.isEmpty else {
            throw ClaudeCompatibleProviderError.invalidConfiguration(detail: "\(config.normalizedDisplayName) requires a configured API key.")
        }

        return ClaudeCompatibleLaunchEnvironment(
            effectiveModel: effectiveModel,
            environmentOverrides: ClaudeCompatibleBackendEnvironmentBuilder.environment(config: config, apiKey: apiKey),
            removedEnvironmentKeys: ClaudeCompatibleBackendEnvironmentBuilder.removedEnvironmentKeys(config: config),
            backendID: backendID,
            suppressesEffortSettings: config.modelBehavior == .noModel
        )
    }

    private func isAllowedNoModelSelection(
        _ rawModel: String?,
        backendID: ClaudeCompatibleBackendID
    ) -> Bool {
        guard let normalized = ClaudeCompatibleModelNormalizer.normalizedRequestedModel(rawModel)?.lowercased() else {
            return true
        }
        return normalized == ClaudeCompatibleModelNormalizer.noModelRawValue(for: backendID)
    }

    private func isKnownNoModelCompatibleRaw(_ rawModel: String?) -> Bool {
        guard let normalized = ClaudeCompatibleModelNormalizer.normalizedRequestedModel(rawModel)?.lowercased() else {
            return false
        }
        return normalized == ClaudeCompatibleModelNormalizer.noModelRawValue(for: .kimi)
            || normalized == ClaudeCompatibleModelNormalizer.noModelRawValue(for: .custom)
    }
}

public struct ClaudeCompatibleHeadlessArgumentsRequest: Codable, Hashable, Sendable {
    public let runtimeConfig: ClaudeCompatibleRuntimeConfig
    public let mcpConfigPath: String?
    public let launchEnvironment: ClaudeCompatibleLaunchEnvironment?
    public let resumeSessionID: String?
    public let systemPromptOverride: String?

    public init(
        runtimeConfig: ClaudeCompatibleRuntimeConfig,
        mcpConfigPath: String?,
        launchEnvironment: ClaudeCompatibleLaunchEnvironment?,
        resumeSessionID: String? = nil,
        systemPromptOverride: String? = nil
    ) {
        self.runtimeConfig = runtimeConfig
        self.mcpConfigPath = mcpConfigPath
        self.launchEnvironment = launchEnvironment
        self.resumeSessionID = resumeSessionID
        self.systemPromptOverride = systemPromptOverride
    }
}

public enum ClaudeCompatibleIdentityPreamble {
    /// Non-empty suffix that makes Claude Code emit its interactive identity preamble for GLM/z.ai.
    /// Empty values are ignored by the CLI; this value avoids the SDK identity trigger words.
    public static let glmZAIAppendSystemPrompt = "Running within RepoPrompt CE."

    public static func appendSystemPrompt(for launchEnvironment: ClaudeCompatibleLaunchEnvironment?) -> String? {
        launchEnvironment?.backendID == .glmZAI ? glmZAIAppendSystemPrompt : nil
    }
}

public enum ClaudeCompatibleHeadlessRuntime {
    public static func buildArguments(_ request: ClaudeCompatibleHeadlessArgumentsRequest) -> [String] {
        var args: [String] = [
            "-p",
            "--verbose",
            "--output-format", "stream-json"
        ]

        if let sessionID = request.resumeSessionID {
            args.append(contentsOf: ["--resume", sessionID])
        }
        if let model = runtimeModelParam(request.launchEnvironment?.effectiveModel) {
            args.append(contentsOf: ["--model", model])
        }
        if let systemPromptOverride = request.systemPromptOverride {
            args.append(contentsOf: ["--system-prompt", systemPromptOverride])
        }
        if let appendSystemPrompt = ClaudeCompatibleIdentityPreamble.appendSystemPrompt(for: request.launchEnvironment) {
            args.append(contentsOf: ["--append-system-prompt", appendSystemPrompt])
        }

        args.append("--dangerously-skip-permissions")

        if let mcpConfigPath = request.mcpConfigPath {
            args.append(contentsOf: ["--mcp-config", mcpConfigPath])
            if request.runtimeConfig.mcpStrictMode {
                args.append("--strict-mcp-config")
            }
        }

        if !request.runtimeConfig.disallowedBuiltInTools.isEmpty {
            args.append(contentsOf: ["--disallowedTools", request.runtimeConfig.disallowedBuiltInTools.joined(separator: ",")])
        }

        return args
    }

    public static func runtimeModelParam(_ raw: String?) -> String? {
        guard let normalized = ClaudeCompatibleModelNormalizer.normalizedRequestedModel(raw) else { return nil }
        guard let effortSeparator = normalized.lastIndex(of: ":") else { return normalized }
        let suffixStart = normalized.index(after: effortSeparator)
        guard suffixStart < normalized.endIndex else { return normalized }
        let suffix = normalized[suffixStart...].lowercased()
        guard ["low", "medium", "high", "max", "xhigh"].contains(suffix) else { return normalized }
        let base = String(normalized[..<effortSeparator]).trimmingCharacters(in: .whitespacesAndNewlines)
        return base.isEmpty ? nil : base
    }
}
