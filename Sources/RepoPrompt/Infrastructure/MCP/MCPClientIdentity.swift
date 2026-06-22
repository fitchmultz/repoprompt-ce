import Foundation

enum MCPClientIdentity {
    static let managedPiFamilyClientNames: Set<String> = [
        "pi",
        "pi-schema"
    ]

    private static let separatorCharacters = CharacterSet(charactersIn: " -_./")

    private enum FamilyMatchRule {
        case exactAliases(Set<String>)
        case tolerantTokenFamilies([[String]])
    }

    private struct FamilyRule {
        let familyID: String
        let matchRule: FamilyMatchRule
    }

    private static let familyRules: [FamilyRule] = [
        FamilyRule(
            familyID: "claude-code",
            matchRule: .tolerantTokenFamilies([["claude", "code"]])
        ),
        FamilyRule(
            familyID: "pi",
            matchRule: .exactAliases(Set(managedPiFamilyClientNames.compactMap(normalized)))
        ),
        FamilyRule(
            familyID: "codex-mcp-client",
            matchRule: .tolerantTokenFamilies([["codex", "mcp", "client"]])
        ),
        FamilyRule(
            familyID: "gemini-cli-mcp-client",
            matchRule: .tolerantTokenFamilies([
                ["gemini", "cli", "mcp", "client"],
                ["gemini", "cli"]
            ])
        ),
        FamilyRule(
            familyID: "cursor",
            matchRule: .tolerantTokenFamilies([
                ["cursor", "mcp", "client"],
                ["cursor", "agent"],
                ["cursor"]
            ])
        ),
        FamilyRule(
            familyID: "claude-ai",
            matchRule: .tolerantTokenFamilies([["claude", "ai"]])
        ),
        FamilyRule(
            familyID: "repoprompt-cli",
            matchRule: .tolerantTokenFamilies([["repoprompt", "cli"]])
        )
    ]

    static func normalized(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty ? nil : normalized
    }

    private static func isSeparator(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy(separatorCharacters.contains)
    }

    private static func matchesTolerantFamily(_ normalized: String, tokens: [String]) -> Bool {
        guard !tokens.isEmpty else { return false }
        var remainder = normalized[...]
        for (index, token) in tokens.enumerated() {
            guard remainder.hasPrefix(token) else { return false }
            remainder.removeFirst(token.count)
            guard index < tokens.count - 1 else { continue }
            while let next = remainder.first, isSeparator(next) {
                remainder.removeFirst()
            }
        }

        guard !remainder.isEmpty else { return true }
        guard let boundary = remainder.first, isSeparator(boundary) else { return false }
        while let next = remainder.first, isSeparator(next) {
            remainder.removeFirst()
        }
        guard let suffixStart = remainder.first else { return true }
        return suffixStart.isNumber || suffixStart == "v"
    }

    static func canonicalFamilyID(_ raw: String?) -> String? {
        guard let normalized = normalized(raw) else { return nil }
        for rule in familyRules {
            switch rule.matchRule {
            case let .exactAliases(aliases):
                if aliases.contains(normalized) { return rule.familyID }
            case let .tolerantTokenFamilies(tokenFamilies):
                if tokenFamilies.contains(where: { matchesTolerantFamily(normalized, tokens: $0) }) {
                    return rule.familyID
                }
            }
        }
        return nil
    }

    static func storageKey(_ raw: String?) -> String? {
        canonicalFamilyID(raw) ?? normalized(raw)
    }

    static func sameFamily(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhsFamily = canonicalFamilyID(lhs),
              let rhsFamily = canonicalFamilyID(rhs)
        else {
            return false
        }
        return lhsFamily == rhsFamily
    }

    static func matches(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhsNormalized = normalized(lhs),
              let rhsNormalized = normalized(rhs)
        else {
            return false
        }
        if lhsNormalized == rhsNormalized {
            return true
        }
        return sameFamily(lhsNormalized, rhsNormalized)
    }

    static func isManagedPiBridgeExecutionClient(_ raw: String?) -> Bool {
        normalized(raw) == "pi-schema"
    }

    static func isHeadlessAgentClient(_ raw: String?) -> Bool {
        guard let family = canonicalFamilyID(raw) else { return false }
        switch family {
        case "claude-code", "pi", "codex-mcp-client", "gemini-cli-mcp-client", "cursor":
            return true
        default:
            return false
        }
    }
}
