import Foundation

enum PiAgentToolPreferences {
    enum PermissionLevel: String, CaseIterable, Hashable {
        case managedBridge = "managed_bridge"

        static let managedDefault: PermissionLevel = .managedBridge

        var displayName: String {
            "Managed Bridge"
        }

        var iconName: String {
            "lock.shield"
        }

        var detailText: String? {
            "RepoPrompt bridge tools use Agent Mode MCP routing and permissions. pi built-in tools remain governed by pi's own runtime configuration."
        }

        var isWarning: Bool {
            false
        }
    }

    static func permissionLevel() -> PermissionLevel {
        .managedDefault
    }
}
