@_spi(TestSupport) @testable import RepoPrompt
import XCTest

final class PiAgentProviderKindTests: XCTestCase {
    func testPiProviderKindMetadataIsNativeRPCAndExpectedPIDRouted() {
        XCTAssertEqual(AgentProviderKind.pi.rawValue, "pi")
        XCTAssertEqual(AgentProviderKind.pi.commandName, "pi")
        XCTAssertEqual(AgentProviderKind.pi.displayName, "pi")
        XCTAssertEqual(AgentProviderKind.pi.mcpClientNameHint, "pi")
        XCTAssertEqual(AgentProviderKind.pi.runtimeKind, "pi_rpc")
        XCTAssertNil(AgentProviderKind.pi.acpProviderID)
        XCTAssertFalse(AgentProviderKind.pi.usesClaudeNativeRuntime)
        XCTAssertTrue(AgentProviderKind.pi.requiresExpectedPIDOwnedAgentModeMCPRouting)
    }

    @MainActor
    func testPiAgentModeBootstrapSpecUsesMultiUseExpectedPIDPolicy() {
        let spec = MCPBootstrapLeaseSpec.agentMode(
            tabID: UUID(),
            runID: UUID(),
            gateID: UUID(),
            windowID: 7,
            agent: .pi
        )

        XCTAssertEqual(spec.clientName, "pi")
        XCTAssertFalse(spec.oneShot)
        XCTAssertEqual(spec.ttl, 3600)
        XCTAssertTrue(spec.requiresExpectedAgentPID)
        XCTAssertEqual(spec.purpose, .agentModeRun)
        XCTAssertEqual(spec.additionalTools, AgentModeMCPToolPolicy.piGrantedTools)
    }

    func testPiMCPConnectionPolicyProfileIsSharedSessionCapableBridgeProfile() {
        let profile = AgentMCPConnectionPolicyProfile.headless(agent: .pi, requestedTTL: 15)
        XCTAssertFalse(profile.oneShot)
        XCTAssertGreaterThanOrEqual(profile.ttl, 3600)
        XCTAssertTrue(profile.requiresExpectedAgentPID)

        let codexProfile = AgentMCPConnectionPolicyProfile.headless(agent: .codexExec, requestedTTL: 15)
        XCTAssertTrue(codexProfile.oneShot)
        XCTAssertEqual(codexProfile.ttl, 15)
        XCTAssertEqual(
            codexProfile.requiresExpectedAgentPID,
            AgentProviderKind.codexExec.requiresExpectedPIDOwnedAgentModeMCPRouting
        )
    }

    func testPiParticipatesInRecommendationProviderFilteringAndRoleDefaults() {
        AgentPiModelRegistry.shared.test_reset()
        defer { AgentPiModelRegistry.shared.test_reset() }
        XCTAssertTrue(AgentPiModelRegistry.shared.updateDiscoveredModels(Self.piSnapshot()))
        let availability = AgentModelCatalog.AvailabilityContext(
            claudeCodeAvailable: false,
            codexAvailable: false,
            openCodeAvailable: true,
            cursorAvailable: true,
            piAvailable: true
        )
        let filtered = availability.filteredForRecommendationProviders([.pi])
        XCTAssertTrue(filtered.piAvailable)
        XCTAssertFalse(filtered.cursorAvailable)
        XCTAssertFalse(filtered.openCodeAvailable)

        let explore = AgentModelCatalog.resolveTaskLabelKind(.explore, availability: filtered)
        XCTAssertEqual(explore?.agent, .pi)
        XCTAssertEqual(explore?.modelRaw, "openai-codex/gpt-5.5")
    }

    func testPiTaskLabelsResolveAheadOfOpenCodeAndCursorWhenReady() {
        AgentPiModelRegistry.shared.test_reset()
        AgentACPModelRegistry.shared.test_reset(providerID: .openCode)
        defer {
            AgentPiModelRegistry.shared.test_reset()
            AgentACPModelRegistry.shared.test_reset(providerID: .openCode)
        }
        XCTAssertTrue(AgentPiModelRegistry.shared.updateDiscoveredModels(Self.piSnapshot()))
        XCTAssertTrue(AgentACPModelRegistry.shared.updateDiscoveredModels(
            ACPDiscoveredSessionModels(
                options: [AgentModelOption(
                    rawValue: "anthropic/claude-sonnet-4-5",
                    displayName: "Claude Sonnet 4.5",
                    description: nil,
                    isPlaceholderDefault: false,
                    isProviderDefault: true
                )],
                currentModelRaw: "anthropic/claude-sonnet-4-5"
            ),
            for: .openCode
        ))
        let availability = AgentModelCatalog.AvailabilityContext(
            claudeCodeAvailable: false,
            codexAvailable: false,
            openCodeAvailable: true,
            cursorAvailable: true,
            piAvailable: true
        )

        let engineer = AgentModelCatalog.resolveTaskLabelKind(.engineer, availability: availability)
        XCTAssertEqual(engineer?.agent, .pi)
        XCTAssertEqual(engineer?.modelRaw, "openai-codex/gpt-5.5")
    }

    func testPiTaskLabelsSkipPiWhenReadyButNoUsableModelCatalog() {
        AgentPiModelRegistry.shared.test_reset()
        AgentACPModelRegistry.shared.test_reset(providerID: .openCode)
        defer {
            AgentPiModelRegistry.shared.test_reset()
            AgentACPModelRegistry.shared.test_reset(providerID: .openCode)
        }
        XCTAssertTrue(AgentACPModelRegistry.shared.updateDiscoveredModels(
            ACPDiscoveredSessionModels(
                options: [AgentModelOption(
                    rawValue: "anthropic/claude-sonnet-4-5",
                    displayName: "Claude Sonnet 4.5",
                    description: nil,
                    isPlaceholderDefault: false,
                    isProviderDefault: true
                )],
                currentModelRaw: "anthropic/claude-sonnet-4-5"
            ),
            for: .openCode
        ))
        let availability = AgentModelCatalog.AvailabilityContext(
            claudeCodeAvailable: false,
            codexAvailable: false,
            openCodeAvailable: true,
            cursorAvailable: true,
            piAvailable: true
        )

        let engineer = AgentModelCatalog.resolveTaskLabelKind(.engineer, availability: availability)
        XCTAssertEqual(engineer?.agent, .openCode)
        XCTAssertEqual(engineer?.modelRaw, "anthropic/claude-sonnet-4-5")
        XCTAssertFalse(AgentModelCatalog.isValid(rawModel: "openai-codex/gpt-5.5", for: .pi, availability: availability))
    }

    func testOpenCodeParticipatesInRecommendationProviderFilteringAndRoleDefaults() {
        AgentACPModelRegistry.shared.test_reset(providerID: .openCode)
        defer { AgentACPModelRegistry.shared.test_reset(providerID: .openCode) }
        XCTAssertTrue(AgentACPModelRegistry.shared.updateDiscoveredModels(
            ACPDiscoveredSessionModels(
                options: [
                    AgentModelOption(
                        rawValue: "anthropic/claude-sonnet-4-5",
                        displayName: "Claude Sonnet 4.5",
                        description: nil,
                        isPlaceholderDefault: false,
                        isProviderDefault: true
                    )
                ],
                currentModelRaw: "anthropic/claude-sonnet-4-5"
            ),
            for: .openCode
        ))

        let availability = AgentModelCatalog.AvailabilityContext(
            claudeCodeAvailable: false,
            codexAvailable: false,
            openCodeAvailable: true,
            cursorAvailable: true,
            piAvailable: true
        )
        let filtered = availability.filteredForRecommendationProviders([.openCode])
        XCTAssertTrue(filtered.openCodeAvailable)
        XCTAssertFalse(filtered.cursorAvailable)
        XCTAssertFalse(filtered.piAvailable)

        let explore = AgentModelCatalog.resolveTaskLabelKind(.explore, availability: filtered)
        XCTAssertEqual(explore?.agent, .openCode)
        XCTAssertEqual(explore?.modelRaw, "anthropic/claude-sonnet-4-5")
    }

    func testProviderFactoryCreatesPiHeadlessProviderWhenWindowRoutingIsAvailable() {
        let provider = AgentRuntimeProviderService.shared.makeProvider(
            for: .pi,
            modelString: "openai-codex/gpt-5.5",
            workspacePath: "/tmp/repoprompt-ce",
            windowID: 7
        )
        let piProvider = provider as? PiHeadlessAgentProvider
        XCTAssertNotNil(piProvider)
        XCTAssertEqual(piProvider?.permissionLevel, .managedDefault)
    }

    func testProviderFactoryPassesPiRuntimePermissionToHeadlessProvider() {
        let provider = AgentRuntimeProviderService.shared.makeProvider(
            for: .pi,
            modelString: "openai-codex/gpt-5.5",
            workspacePath: "/tmp/repoprompt-ce",
            windowID: 7,
            runtimePermission: AgentProviderRuntimePermissionBinding(piPermissionLevel: .readOnly)
        )
        let piProvider = provider as? PiHeadlessAgentProvider
        XCTAssertNotNil(piProvider)
        XCTAssertEqual(piProvider?.permissionLevel, .readOnly)
    }

    func testProviderFactoryRejectsPiHeadlessProviderWithoutWindowRouting() {
        let provider = AgentRuntimeProviderService.shared.makeProvider(
            for: .pi,
            modelString: "openai-codex/gpt-5.5",
            workspacePath: "/tmp/repoprompt-ce"
        )
        XCTAssertTrue(provider is UnsupportedHeadlessAgentProvider)
    }

    func testPiModelsAreSelectableWhenRuntimeAvailabilityIsProven() {
        AgentPiModelRegistry.shared.test_reset()
        defer { AgentPiModelRegistry.shared.test_reset() }
        XCTAssertTrue(AgentPiModelRegistry.shared.updateDiscoveredModels(Self.piSnapshot()))
        let availability = AgentModelCatalog.AvailabilityContext(piAvailable: true)

        XCTAssertTrue(AgentModelCatalog.isAgentAvailable(.pi, availability: availability))
        XCTAssertEqual(AgentModel.modelsForAgent(.pi), [.defaultModel])
        XCTAssertEqual(
            AgentModelCatalog.defaultModelRaw(for: .pi, availability: availability),
            "openai-codex/gpt-5.5"
        )
        XCTAssertEqual(
            AgentModelCatalog.options(for: .pi, availability: availability).map(\.rawValue),
            ["openai-codex/gpt-5.5"]
        )
        XCTAssertTrue(AgentModelCatalog.selectableAgents(availability: availability).contains(.pi))
        XCTAssertEqual(AgentProviderKind.pi.providerBindingID, .pi)
    }

    private static func piSnapshot() -> PiDiscoveredModels {
        PiDiscoveredModels(
            options: [
                AgentModelOption(
                    rawValue: "openai-codex/gpt-5.5",
                    displayName: "GPT 5.5",
                    description: nil,
                    isDefault: true
                )
            ],
            currentModelRaw: "openai-codex/gpt-5.5"
        )
    }
}
