@testable import RepoPrompt
import XCTest

@MainActor
final class AgentSubagentPermissionsSettingsViewModelTests: XCTestCase {
    func testPolicyMutationsNotifyActiveSessionRefreshCallback() throws {
        let suiteName = "AgentSubagentPermissionsSettingsViewModelTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var callbackCount = 0
        let viewModel = AgentSubagentPermissionsSettingsViewModel(
            defaults: defaults,
            securePermissions: nil,
            notificationCenter: NotificationCenter()
        ) {
            callbackCount += 1
        }

        viewModel.setGlobalPolicy(.custom)
        viewModel.setProviderPermissionLevel(.codex(.readOnly), for: .codex)
        viewModel.setProviderPermissionLevel(.codex(.readOnly), for: .codex)

        XCTAssertEqual(viewModel.globalPolicy, .custom)
        XCTAssertEqual(viewModel.providerPermissionLevelsByID[.codex], .codex(.readOnly))
        XCTAssertEqual(callbackCount, 2)
    }
}
