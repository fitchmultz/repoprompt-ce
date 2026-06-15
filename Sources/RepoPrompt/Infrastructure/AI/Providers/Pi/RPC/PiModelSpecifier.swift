import Foundation

struct PiModelSpecifier: Equatable {
    let provider: String?
    let modelID: String
    let thinkingLevel: String?

    init(provider: String?, modelID: String, thinkingLevel: String?) {
        self.provider = provider
        self.modelID = modelID
        self.thinkingLevel = thinkingLevel
    }

    var providerQualifiedModelRaw: String {
        if let provider {
            return "\(provider)/\(modelID)"
        }
        return modelID
    }

    init?(raw: String?, knownModelIDs: Set<String>) {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty,
              trimmed.caseInsensitiveCompare(AgentModel.defaultModel.rawValue) != .orderedSame
        else { return nil }

        let normalizedKnownModelIDs = Self.normalizedKnownModelIDs(knownModelIDs)
        let providerSplit = trimmed.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        let provider: String?
        let modelAndThinking: Substring
        if providerSplit.count == 2 {
            let rawProvider = providerSplit[0].trimmingCharacters(in: .whitespacesAndNewlines)
            provider = rawProvider.isEmpty ? nil : rawProvider
            modelAndThinking = providerSplit[1]
        } else {
            provider = nil
            modelAndThinking = providerSplit[0]
        }

        let trimmedModelAndThinking = modelAndThinking.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsed = Self.parseModelIDAndThinking(
            from: trimmedModelAndThinking,
            providerQualifiedRaw: trimmed,
            knownModelIDs: normalizedKnownModelIDs
        )
        guard !parsed.modelID.isEmpty else { return nil }

        self.provider = provider
        modelID = parsed.modelID
        thinkingLevel = parsed.thinkingLevel
    }

    private static func parseModelIDAndThinking(
        from raw: String,
        providerQualifiedRaw: String,
        knownModelIDs: Set<String>
    ) -> (modelID: String, thinkingLevel: String?) {
        // pi dist/core/model-resolver.js parseModelPattern first matches the full model reference before
        // considering a trailing thinking suffix. RepoPrompt can mirror that precedence for exact discovered
        // catalog IDs; it does not have pi's fuzzy tryMatchModel partial-match context at this split point.
        if knownModelIDs.contains(normalizedModelID(providerQualifiedRaw))
            || knownModelIDs.contains(normalizedModelID(raw))
        {
            return (raw, nil)
        }

        guard let colonIndex = raw.lastIndex(of: ":") else {
            return (raw, nil)
        }

        let candidateThinkingLevel = String(raw[raw.index(after: colonIndex)...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard PiThinkingLevel.isCanonicalRawValue(candidateThinkingLevel) else {
            return (raw, nil)
        }

        let modelID = raw[..<colonIndex]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !modelID.isEmpty else {
            return (raw, nil)
        }
        return (modelID, candidateThinkingLevel)
    }

    private static func normalizedKnownModelIDs(_ knownModelIDs: Set<String>) -> Set<String> {
        Set(knownModelIDs.map(normalizedModelID).filter { !$0.isEmpty })
    }

    private static func normalizedModelID(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
