@testable import RepoPrompt
import XCTest

@MainActor
final class AgentModeProviderBindingServiceTests: XCTestCase {
    func testPreloadedMCPActivationUsesPersistedCustomPiSubagentPolicy() throws {
        let suiteName = "AgentModeProviderBindingServiceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let secureStrings = AgentModeProviderBindingServiceFakeSecureStore()
        let payload = try JSONEncoder().encode(SecureSubagentPermissionDocument(
            globalPolicyRaw: AgentSubagentPermissionPolicy.custom.rawValue,
            providerPermissionLevelsRawByProviderID: [
                AgentProviderBindingID.pi.rawValue: PiAgentToolPreferences.PermissionLevel.fullAccess.rawValue
            ]
        ))
        secureStrings.plainValues[AgentPermissionSecureDomain.subagent.storageKey] = try XCTUnwrap(String(data: payload, encoding: .utf8))
        let secureStore = AgentPermissionSecureStore(secureStrings: secureStrings)
        let preferences = AgentProviderPreferenceSnapshotStore(defaults: defaults, securePermissions: secureStore)
        let service = AgentModeProviderBindingService(preferences: preferences)

        XCTAssertEqual(
            service.permissionProfileForMCPActivation(isSubagent: true, provider: .pi),
            .providerOverride(.pi(.fullAccess))
        )
    }

    func testMCPActivationPermissionProfileDoesNotSynchronouslyReadSecureStorage() throws {
        let suiteName = "AgentModeProviderBindingServiceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let secureStore = AgentPermissionSecureStore(secureStrings: TrapSecurePlainStringStore())
        let preferences = AgentProviderPreferenceSnapshotStore(defaults: defaults, securePermissions: secureStore)
        let service = AgentModeProviderBindingService(
            preferences: preferences,
            preloadSubagentPermissions: false
        )

        XCTAssertEqual(
            service.permissionProfileForMCPActivation(isSubagent: false, provider: .pi),
            .mcpSafeDefaults
        )
    }
}

private final class AgentModeProviderBindingServiceFakeSecureStore: SecurePlainStringStoring {
    var plainValues: [String: String] = [:]

    var persistsValuesAcrossLaunches: Bool {
        true
    }

    func getPlainValue(for account: SecureStorageAccount, accessMode _: KeychainAccessMode) throws -> String? {
        plainValues[account.identifier]
    }

    func savePlainValue(_ value: String, for account: SecureStorageAccount, accessMode _: KeychainAccessMode) throws {
        plainValues[account.identifier] = value
    }

    func deletePlainValue(for account: SecureStorageAccount, accessMode _: KeychainAccessMode) throws {
        plainValues.removeValue(forKey: account.identifier)
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
