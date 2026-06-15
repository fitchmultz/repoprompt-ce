import Foundation

enum PiAgentToolPreferences {
    enum PermissionLevel: String, CaseIterable, Hashable {
        case readOnly
        case askBeforeWrite
        case autoReview
        case fullAccess

        static let managedDefault: PermissionLevel = .askBeforeWrite

        var displayName: String {
            switch self {
            case .readOnly:
                "Read Only"
            case .askBeforeWrite:
                "Ask Before Write"
            case .autoReview:
                "Auto Review"
            case .fullAccess:
                "Full Access"
            }
        }

        var iconName: String {
            switch self {
            case .readOnly:
                "lock.shield"
            case .askBeforeWrite:
                "shield"
            case .autoReview:
                "checkmark.shield"
            case .fullAccess:
                "exclamationmark.shield.fill"
            }
        }

        var detailText: String? {
            switch self {
            case .readOnly:
                "RepoPrompt allows pi read/search/list built-ins and blocks bash, edit, and write before execution."
            case .askBeforeWrite:
                "RepoPrompt allows pi read/search/list built-ins and asks before bash, edit, or write."
            case .autoReview:
                "RepoPrompt uses the pi preflight approval gate. Auto-review falls back to user approval until reviewer routing is wired."
            case .fullAccess:
                "RepoPrompt allows pi built-ins without prompting for direct runs. Safe Managed and MCP policies can still override this."
            }
        }

        var isWarning: Bool {
            self == .fullAccess
        }

        var allowsReadOnlyBuiltIns: Bool {
            true
        }

        var allowsMutatingBuiltInsWithoutApproval: Bool {
            self == .fullAccess
        }

        var requiresApprovalForMutatingBuiltIns: Bool {
            self == .askBeforeWrite || self == .autoReview
        }

        var blocksMutatingBuiltIns: Bool {
            self == .readOnly
        }

        static func from(rawValue: String?) -> PermissionLevel {
            guard let raw = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty
            else {
                return .managedDefault
            }
            return PermissionLevel(rawValue: raw) ?? .managedDefault
        }
    }

    private static let permissionLevelKey = "piBuiltInToolPermissionLevel"

    static func permissionLevel(
        defaults: UserDefaults = .standard,
        secureStore: AgentPermissionSecureStore? = nil
    ) -> PermissionLevel {
        if let secureStore = resolvedSecureStore(defaults: defaults, secureStore: secureStore) {
            return secureStore.piPermissions().permissionLevel()
        }
        return PermissionLevel.from(rawValue: defaults.string(forKey: permissionLevelKey))
    }

    static func setPermissionLevel(
        _ level: PermissionLevel,
        defaults: UserDefaults = .standard,
        secureStore: AgentPermissionSecureStore? = nil
    ) {
        if let secureStore = resolvedSecureStore(defaults: defaults, secureStore: secureStore) {
            secureStore.setPiPermissionLevel(level)
            return
        }
        defaults.set(level.rawValue, forKey: permissionLevelKey)
    }

    private static func resolvedSecureStore(
        defaults: UserDefaults,
        secureStore: AgentPermissionSecureStore?
    ) -> AgentPermissionSecureStore? {
        if let secureStore {
            return secureStore
        }
        return defaults === UserDefaults.standard ? AgentPermissionSecureStore.shared : nil
    }
}
