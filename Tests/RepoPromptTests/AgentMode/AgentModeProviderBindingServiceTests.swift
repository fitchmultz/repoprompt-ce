@testable import RepoPrompt
import XCTest

@MainActor
final class AgentModeProviderBindingServiceTests: XCTestCase {
    func testMCPActivationLoadsPersistedCustomPiSubagentPolicyOnCacheMiss() throws {
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

    func testMCPActivationRetriesSubagentPolicyAfterTransientReadFailure() throws {
        let suiteName = "AgentModeProviderBindingServiceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let secureStrings = AgentModeProviderBindingServiceFakeSecureStore(failReadsRemaining: 1)
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
            .mcpSafeDefaults
        )
        XCTAssertEqual(
            service.permissionProfileForMCPActivation(isSubagent: true, provider: .pi),
            .providerOverride(.pi(.fullAccess))
        )
    }
}

private final class AgentModeProviderBindingServiceFakeSecureStore: SecurePlainStringStoring {
    var plainValues: [String: String] = [:]
    var failReadsRemaining: Int

    init(failReadsRemaining: Int = 0) {
        self.failReadsRemaining = failReadsRemaining
    }

    var persistsValuesAcrossLaunches: Bool {
        true
    }

    func getPlainValue(for account: SecureStorageAccount, accessMode _: KeychainAccessMode) throws -> String? {
        if failReadsRemaining > 0 {
            failReadsRemaining -= 1
            throw KeychainService.KeychainError.interactionNotAllowed
        }
        return plainValues[account.identifier]
    }

    func savePlainValue(_ value: String, for account: SecureStorageAccount, accessMode _: KeychainAccessMode) throws {
        plainValues[account.identifier] = value
    }

    func deletePlainValue(for account: SecureStorageAccount, accessMode _: KeychainAccessMode) throws {
        plainValues.removeValue(forKey: account.identifier)
    }
}
