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
            "RepoPrompt controls only generated bridge tools. pi built-in read/bash/edit/write/search tools are not sandboxed by RepoPrompt and follow pi's own runtime configuration."
        }

        var isWarning: Bool {
            true
        }
    }

    static func permissionLevel() -> PermissionLevel {
        .managedDefault
    }
}
