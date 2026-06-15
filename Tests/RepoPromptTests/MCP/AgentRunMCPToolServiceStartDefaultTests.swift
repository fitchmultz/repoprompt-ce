import Foundation
@testable import RepoPrompt
import XCTest

@MainActor
final class AgentRunMCPToolServiceStartDefaultTests: XCTestCase {
    override func tearDown() {
        AgentPiModelRegistry.shared.test_reset()
        super.tearDown()
    }

    func testUntargetedStartWithoutModelIDResolvesThroughPairDefault() throws {
        let defaultLabel = AgentRunMCPToolService.defaultTaskLabelForStart(resolvedTabID: nil)
        XCTAssertEqual(defaultLabel, .pair)

        var requestedRole: AgentModelCatalog.TaskLabelKind?
        let resolved = try AgentMCPSelectionResolver.resolve(
            modelID: nil,
            defaultTaskLabel: defaultLabel,
            availability: .current,
            roleSelectionProvider: { role, _ in
                requestedRole = role
                return AgentModelCatalog.NormalizedAgentSelection(agent: .codexExec, modelRaw: "pair-default-model")
            }
        )

        XCTAssertEqual(requestedRole, .pair)
        XCTAssertEqual(resolved.taskLabelKind, .pair)
        XCTAssertEqual(resolved.agentRaw, AgentProviderKind.codexExec.rawValue)
        XCTAssertEqual(resolved.modelRaw, "pair-default-model")
    }

    func testFreshPairEngineerAndExploreStartsUseCodexSafeManagedDefaults() throws {
        let suiteName = "AgentRunMCPToolServiceStartDefaultTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.removePersistentDomain(forName: suiteName)
        CodexAgentToolPreferences.setBashToolEnabled(false, defaults: defaults)
        CodexAgentToolPreferences.setMCPServerEnabled(
            normalizedName: "external-tools",
            isEnabled: true,
            defaults: defaults
        )
        let service = makeBindingService(defaults: defaults)

        for role in [AgentModelCatalog.TaskLabelKind.pair, .engineer, .explore] {
            let selection = try AgentMCPSelectionResolver.resolve(
                modelID: role.rawValue,
                defaultTaskLabel: nil,
                availability: .current,
                roleSelectionProvider: { requestedRole, _ in
                    XCTAssertEqual(requestedRole, role)
                    return AgentModelCatalog.NormalizedAgentSelection(
                        agent: .codexExec,
                        modelRaw: "\(role.rawValue)-codex-model"
                    )
                }
            )
            XCTAssertEqual(selection.agentRaw, AgentProviderKind.codexExec.rawValue)

            let profile = service.permissionProfileForMCPActivation(
                isSubagent: true,
                provider: .codex
            )
            XCTAssertEqual(profile, .mcpSafeDefaults)

            let snapshot = service.controlsBinding(
                selectedAgent: .codexExec,
                selectedModelRaw: selection.modelRaw,
                permissionProfile: profile,
                isSubagent: true,
                externallyManagedReason: nil
            )
            XCTAssertEqual(snapshot.permission.displayName, CodexAgentToolPreferences.PermissionLevel.autoReview.displayName)
            XCTAssertEqual(snapshot.runtimePermission.codexSandboxMode, .workspaceWrite)
            XCTAssertEqual(snapshot.runtimePermission.codexApprovalPolicy, .onRequest)
            XCTAssertEqual(snapshot.runtimePermission.codexApprovalReviewer, .autoReview)
            XCTAssertEqual(snapshot.codexTools?.bashToolEnabled, true)
            XCTAssertEqual(snapshot.codexTools?.mcpServerStatesByNormalizedName["external-tools"], false)
            XCTAssertTrue(profile.codexBashToolEnabled(userConfigured: false))
            XCTAssertTrue(profile.codexSuppressesThirdPartyMCPServers)
        }
    }

    func testFreshPiStartsUseSafeManagedPermissionGate() throws {
        let suiteName = "AgentRunMCPToolServiceStartDefaultTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.removePersistentDomain(forName: suiteName)
        PiAgentToolPreferences.setPermissionLevel(.fullAccess, defaults: defaults)
        let service = makeBindingService(defaults: defaults)

        let profile = service.permissionProfileForMCPActivation(isSubagent: true, provider: .pi)
        let snapshot = service.controlsBinding(
            selectedAgent: .pi,
            permissionProfile: profile,
            isSubagent: true,
            externallyManagedReason: nil
        )

        XCTAssertEqual(profile, .mcpSafeDefaults)
        XCTAssertEqual(snapshot.permission.displayName, PiAgentToolPreferences.PermissionLevel.managedDefault.displayName)
        XCTAssertEqual(snapshot.runtimePermission.piPermissionLevel, .managedDefault)
        XCTAssertTrue(snapshot.runtimePermission.piRequiresApprovalForMutatingBuiltIns)
        XCTAssertFalse(snapshot.runtimePermission.piAllowsMutatingBuiltInsWithoutApproval)
    }

    func testCustomPiOverrideWinsOverSafeManagedDefaults() throws {
        let suiteName = "AgentRunMCPToolServiceStartDefaultTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.removePersistentDomain(forName: suiteName)
        AgentModePermissionPreferences.setSubagentPermissionPolicy(.custom, defaults: defaults)
        AgentModePermissionPreferences.setProviderSubagentPermissionLevel(
            .pi(.readOnly),
            for: .pi,
            defaults: defaults
        )
        let service = makeBindingService(defaults: defaults)

        let profile = service.permissionProfileForMCPActivation(isSubagent: true, provider: .pi)
        let snapshot = service.controlsBinding(
            selectedAgent: .pi,
            permissionProfile: profile,
            isSubagent: true,
            externallyManagedReason: nil
        )

        XCTAssertEqual(profile, .providerOverride(.pi(.readOnly)))
        XCTAssertEqual(snapshot.permission.displayName, PiAgentToolPreferences.PermissionLevel.readOnly.displayName)
        XCTAssertEqual(snapshot.runtimePermission.piPermissionLevel, .readOnly)
        XCTAssertTrue(snapshot.runtimePermission.piBlocksMutatingBuiltIns)
    }

    func testInheritedRestrictiveCodexSettingsRemainRestrictive() throws {
        let suiteName = "AgentRunMCPToolServiceStartDefaultTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.removePersistentDomain(forName: suiteName)
        AgentModePermissionPreferences.setSubagentPermissionPolicy(.inheritProviderSettings, defaults: defaults)
        CodexAgentToolPreferences.setPermissionLevel(.readOnly, defaults: defaults)
        CodexAgentToolPreferences.setBashToolEnabled(false, defaults: defaults)
        let service = makeBindingService(defaults: defaults)

        let profile = service.permissionProfileForMCPActivation(isSubagent: true, provider: .codex)
        let snapshot = service.controlsBinding(
            selectedAgent: .codexExec,
            permissionProfile: profile,
            isSubagent: true,
            externallyManagedReason: nil
        )

        XCTAssertEqual(profile, .userConfigured)
        XCTAssertEqual(snapshot.permission.displayName, CodexAgentToolPreferences.PermissionLevel.readOnly.displayName)
        XCTAssertEqual(snapshot.runtimePermission.codexSandboxMode, .readOnly)
        XCTAssertEqual(snapshot.runtimePermission.codexApprovalReviewer, .user)
        XCTAssertEqual(snapshot.codexTools?.bashToolEnabled, false)
        XCTAssertFalse(profile.codexBashToolEnabled(userConfigured: false))
        XCTAssertFalse(profile.codexSuppressesThirdPartyMCPServers)
    }

    func testCustomRestrictiveCodexOverrideWinsOverSafeManagedDefaults() throws {
        let suiteName = "AgentRunMCPToolServiceStartDefaultTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.removePersistentDomain(forName: suiteName)
        AgentModePermissionPreferences.setSubagentPermissionPolicy(.custom, defaults: defaults)
        AgentModePermissionPreferences.setProviderSubagentPermissionLevel(
            .codex(.readOnly),
            for: .codex,
            defaults: defaults
        )
        CodexAgentToolPreferences.setBashToolEnabled(false, defaults: defaults)
        let service = makeBindingService(defaults: defaults)

        let profile = service.permissionProfileForMCPActivation(isSubagent: true, provider: .codex)
        let snapshot = service.controlsBinding(
            selectedAgent: .codexExec,
            permissionProfile: profile,
            isSubagent: true,
            externallyManagedReason: nil
        )

        XCTAssertEqual(profile, .providerOverride(.codex(.readOnly)))
        XCTAssertEqual(snapshot.permission.displayName, CodexAgentToolPreferences.PermissionLevel.readOnly.displayName)
        XCTAssertEqual(snapshot.runtimePermission.codexSandboxMode, .readOnly)
        XCTAssertEqual(snapshot.runtimePermission.codexApprovalReviewer, .user)
        XCTAssertEqual(snapshot.codexTools?.bashToolEnabled, false)
        XCTAssertFalse(profile.codexBashToolEnabled(userConfigured: false))
        XCTAssertFalse(profile.codexSuppressesThirdPartyMCPServers)
    }

    func testSubagentPolicyUnavailableUsesCodexSafeManagedSnapshotWithoutKeychainRead() throws {
        let suiteName = "AgentRunMCPToolServiceStartDefaultTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.removePersistentDomain(forName: suiteName)
        let secureStore = AgentPermissionSecureStore(
            secureStrings: AgentRunFailingSecurePlainStringStore(),
            notificationCenter: NotificationCenter()
        )
        let service = makeBindingService(defaults: defaults, secureStore: secureStore)

        let profile = service.permissionProfileForMCPActivation(isSubagent: true, provider: .codex)
        let snapshot = service.controlsBinding(
            selectedAgent: .codexExec,
            permissionProfile: profile,
            isSubagent: true,
            externallyManagedReason: nil
        )

        XCTAssertEqual(profile, .mcpSafeDefaults)
        XCTAssertEqual(snapshot.permission.displayName, CodexAgentToolPreferences.PermissionLevel.autoReview.displayName)
        XCTAssertEqual(snapshot.runtimePermission.codexApprovalReviewer, .autoReview)
        XCTAssertEqual(snapshot.codexTools?.bashToolEnabled, true)
        XCTAssertEqual(snapshot.codexTools?.mcpServerStatesByNormalizedName["external-tools"], false)
        XCTAssertTrue(profile.codexBashToolEnabled(userConfigured: false))
        XCTAssertTrue(profile.codexSuppressesThirdPartyMCPServers)
        XCTAssertNil(secureStore.diagnostic(for: .subagent))
    }

    func testExplicitTargetTabWithOmittedModelIDPreservesCurrentSelection() {
        let targetTabID = UUID()

        XCTAssertNil(AgentRunMCPToolService.defaultTaskLabelForStart(resolvedTabID: targetTabID))
    }

    func testWorkflowDefaultDoesNotOverridePairForUntargetedStart() {
        XCTAssertEqual(AgentWorkflow.oracleExport.defaultTaskLabelKind, .explore)

        let defaultLabel = AgentRunMCPToolService.defaultTaskLabelForStart(
            resolvedTabID: nil,
            workflow: AgentWorkflow.oracleExport.definition
        )

        XCTAssertEqual(defaultLabel, .pair)
    }

    private func makeBindingService(
        defaults: UserDefaults,
        secureStore: AgentPermissionSecureStore? = nil
    ) -> AgentModeProviderBindingService {
        AgentModeProviderBindingService(
            preferences: AgentProviderPreferenceSnapshotStore(
                defaults: defaults,
                securePermissions: secureStore,
                codexMCPServerEntries: {
                    [
                        MCPIntegrationHelper.CodexServerEntry(
                            rawName: "external-tools",
                            normalizedName: "external-tools",
                            cliPathComponent: "external-tools"
                        )
                    ]
                }
            )
        )
    }

    func testExplicitModelIDTakesPrecedenceOverStartPairDefault() throws {
        let defaultLabel = AgentRunMCPToolService.defaultTaskLabelForStart(resolvedTabID: nil)

        let resolved = try AgentMCPSelectionResolver.resolve(
            modelID: "codexExec:explicit-model",
            defaultTaskLabel: defaultLabel,
            availability: AgentModelCatalog.AvailabilityContext(codexAvailable: true)
        )

        XCTAssertNil(resolved.taskLabelKind)
        XCTAssertEqual(resolved.agentRaw, AgentProviderKind.codexExec.rawValue)
        XCTAssertEqual(resolved.modelRaw, "explicit-model")
    }

    func testExplicitPiModelIDAcceptsThinkingSuffixAndExtractsEffort() throws {
        installPiSnapshot()

        let resolved = try AgentMCPSelectionResolver.resolve(
            modelID: "pi:openai-codex/gpt-5.5:low",
            defaultTaskLabel: AgentRunMCPToolService.defaultTaskLabelForStart(resolvedTabID: nil),
            availability: AgentModelCatalog.AvailabilityContext(piAvailable: true)
        )

        XCTAssertNil(resolved.taskLabelKind)
        XCTAssertEqual(resolved.agentRaw, AgentProviderKind.pi.rawValue)
        XCTAssertEqual(resolved.modelRaw, "openai-codex/gpt-5.5")
        XCTAssertEqual(resolved.reasoningEffortRaw, "low")
    }

    func testExplicitPiModelIDPreservesSupportedRealModelRaw() throws {
        let rawModel = "deepseek/deepseek-v4-flash"
        let snapshot = PiDiscoveredModels(
            options: [
                AgentModelOption(
                    rawValue: rawModel,
                    displayName: "DeepSeek V4 Flash",
                    description: nil,
                    isDefault: false
                )
            ],
            currentModelRaw: nil
        )
        XCTAssertTrue(AgentPiModelRegistry.shared.updateDiscoveredModels(snapshot))

        let resolved = try AgentMCPSelectionResolver.resolve(
            modelID: "pi:\(rawModel)",
            defaultTaskLabel: AgentRunMCPToolService.defaultTaskLabelForStart(resolvedTabID: nil),
            availability: AgentModelCatalog.AvailabilityContext(piAvailable: true)
        )

        XCTAssertNil(resolved.taskLabelKind)
        XCTAssertEqual(resolved.agentRaw, AgentProviderKind.pi.rawValue)
        XCTAssertEqual(resolved.modelRaw, rawModel)
        XCTAssertNil(resolved.reasoningEffortRaw)
    }

    func testRoleDefaultPiModelIDPreservesThinkingSuffixAndResolverExtractsEffort() throws {
        installPiSnapshot()
        let store = InMemoryRoleDefaultsStore()
        let availability = AgentModelCatalog.AvailabilityContext(piAvailable: true)
        let selection = AgentModelCatalog.NormalizedAgentSelection(
            agent: .pi,
            modelRaw: "openai-codex/gpt-5.5:low"
        )

        XCTAssertTrue(MCPAgentRoleDefaultsService.setSelection(
            selection,
            for: .explore,
            availability: availability,
            settingsStore: store
        ))
        let resolution = try XCTUnwrap(MCPAgentRoleDefaultsService.effectiveSelection(
            for: .explore,
            availability: availability,
            settingsStore: store
        ))
        XCTAssertEqual(resolution.effective, selection)
        XCTAssertEqual(resolution.effectiveDisplayName, "pi · OpenAI Codex · GPT 5.5 Low")

        let resolved = try AgentMCPSelectionResolver.resolve(
            modelID: "explore",
            availability: availability,
            roleSelectionProvider: { role, availability in
                MCPAgentRoleDefaultsService.effectiveNormalizedSelection(
                    for: role,
                    availability: availability,
                    settingsStore: store
                )
            }
        )

        XCTAssertEqual(resolved.taskLabelKind, .explore)
        XCTAssertEqual(resolved.agentRaw, AgentProviderKind.pi.rawValue)
        XCTAssertEqual(resolved.modelRaw, "openai-codex/gpt-5.5")
        XCTAssertEqual(resolved.reasoningEffortRaw, "low")
    }

    private func installPiSnapshot() {
        let snapshot = PiDiscoveredModels(
            options: [
                AgentModelOption(
                    rawValue: "openai-codex/gpt-5.5",
                    displayName: "GPT 5.5",
                    description: nil,
                    isDefault: true,
                    supportedPiThinkingLevels: [.off, .low, .medium, .high]
                )
            ],
            currentModelRaw: "openai-codex/gpt-5.5"
        )
        XCTAssertTrue(AgentPiModelRegistry.shared.updateDiscoveredModels(snapshot))
    }
}

@MainActor
private final class InMemoryRoleDefaultsStore: MCPAgentRoleDefaultsStoring {
    private var overrides: [String: String]?

    func globalMCPAgentRoleOverrides() -> [String: String]? {
        overrides
    }

    func updateGlobalMCPAgentRoleOverrides(_ overrides: [String: String]?, commit: Bool) {
        _ = commit
        self.overrides = overrides
    }
}

private final class AgentRunFailingSecurePlainStringStore: SecurePlainStringStoring {
    let persistsValuesAcrossLaunches = true

    func getPlainValue(for account: SecureStorageAccount, accessMode: KeychainAccessMode) throws -> String? {
        throw KeychainService.KeychainError.interactionNotAllowed
    }

    func savePlainValue(_ value: String, for account: SecureStorageAccount, accessMode: KeychainAccessMode) throws {
        throw KeychainService.KeychainError.interactionNotAllowed
    }

    func deletePlainValue(for account: SecureStorageAccount, accessMode: KeychainAccessMode) throws {
        throw KeychainService.KeychainError.interactionNotAllowed
    }
}
