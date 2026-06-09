@testable import RepoPrompt
import XCTest

@MainActor
final class AgentModeProviderBindingServiceTests: XCTestCase {
    func testMCPActivationPermissionProfileDoesNotSynchronouslyReadSecureStorage() throws {
        let suiteName = "AgentModeProviderBindingServiceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let secureStore = AgentPermissionSecureStore(secureStrings: TrapSecurePlainStringStore())
        let preferences = AgentProviderPreferenceSnapshotStore(defaults: defaults, securePermissions: secureStore)
        let service = AgentModeProviderBindingService(preferences: preferences)

        XCTAssertEqual(
            service.permissionProfileForMCPActivation(isSubagent: false, provider: .pi),
            .mcpSafeDefaults
        )
    }
}

private struct TrapSecurePlainStringStore: SecurePlainStringStoring {
    var persistsValuesAcrossLaunches: Bool {
        true
    }

    func getPlainValue(for account: SecureStorageAccount, accessMode: KeychainAccessMode) throws -> String? {
        XCTFail("MCP activation permission profile must not synchronously read secure storage; attempted \(account.identifier) with \(accessMode).")
        return nil
    }

    func savePlainValue(_ value: String, for account: SecureStorageAccount, accessMode: KeychainAccessMode) throws {
        XCTFail("Unexpected secure storage write for \(account.identifier) with \(accessMode): \(value)")
    }

    func deletePlainValue(for account: SecureStorageAccount, accessMode: KeychainAccessMode) throws {
        XCTFail("Unexpected secure storage delete for \(account.identifier) with \(accessMode)")
    }
}
