@testable import RepoPrompt
import XCTest

@MainActor
final class MCPAgentRoleDefaultsServiceTests: XCTestCase {
    func testResolutionsFallbackToActualAvailabilityWhenRecommendationAvailabilityIsEmpty() {
        let actualAvailability = AgentModelCatalog.AvailabilityContext(
            claudeCodeAvailable: false,
            codexAvailable: true,
            openCodeAvailable: false,
            cursorAvailable: false,
            zaiConfigured: false,
            kimiConfigured: false,
            customClaudeCompatibleConfigured: false
        )

        let resolutions = MCPAgentRoleDefaultsService.resolutions(
            availability: actualAvailability,
            recommendedAvailability: AgentModelCatalog.AvailabilityContext.none,
            settingsStore: RoleDefaultsStoreStub()
        )

        XCTAssertEqual(
            resolutions.map(\.role),
            AgentModelCatalog.TaskLabelKind.allCases
        )

        XCTAssertEqual(resolutions[0].recommended.agent, .codexExec)
        XCTAssertEqual(resolutions[0].recommended.modelRaw, AgentModel.gpt55CodexLow.rawValue)
        XCTAssertEqual(resolutions[1].recommended.agent, .codexExec)
        XCTAssertEqual(resolutions[1].recommended.modelRaw, AgentModel.gpt55CodexLow.rawValue)
        XCTAssertEqual(resolutions[2].recommended.agent, .codexExec)
        XCTAssertEqual(resolutions[2].recommended.modelRaw, AgentModel.gpt55CodexHigh.rawValue)
        XCTAssertEqual(resolutions[3].recommended.agent, .codexExec)
        XCTAssertEqual(resolutions[3].recommended.modelRaw, AgentModel.gpt55CodexMedium.rawValue)
    }

    func testResolutionsPreferRecommendationAvailabilityWhenItCanResolveRole() throws {
        let actualAvailability = AgentModelCatalog.AvailabilityContext(
            claudeCodeAvailable: false,
            codexAvailable: true,
            openCodeAvailable: false,
            cursorAvailable: false,
            zaiConfigured: true,
            kimiConfigured: false,
            customClaudeCompatibleConfigured: false
        )
        let recommendedAvailability = AgentModelCatalog.AvailabilityContext(
            claudeCodeAvailable: false,
            codexAvailable: false,
            openCodeAvailable: false,
            cursorAvailable: false,
            zaiConfigured: true,
            kimiConfigured: false,
            customClaudeCompatibleConfigured: false
        )

        let engineer = try XCTUnwrap(MCPAgentRoleDefaultsService.effectiveSelection(
            for: .engineer,
            availability: actualAvailability,
            recommendedAvailability: recommendedAvailability,
            settingsStore: RoleDefaultsStoreStub()
        ))

        XCTAssertEqual(engineer.recommended.agent, .claudeCodeGLM)
        XCTAssertEqual(engineer.recommended.modelRaw, AgentModel.claudeSonnet.rawValue)
        XCTAssertEqual(engineer.effective, engineer.recommended)
    }

    func testBestPracticeProfilesUseRequestedPiGpt56Defaults() {
        XCTAssertEqual(
            BestPracticeProfiles.bestInAppPlanningReview.modelString,
            AIModel.piCustom(name: AgentModelCatalog.preferredPiModelRaw(thinkingLevel: .xhigh)).rawValue
        )
        XCTAssertEqual(
            BestPracticeProfiles.bestContextBuilder.modelString,
            AIModel.piCustom(name: AgentModelCatalog.preferredPiModelRaw(thinkingLevel: .low)).rawValue
        )
    }

    func testPreferredRoleDefaultsUsePiGpt56SolAndClaudeFable5() {
        AgentPiModelRegistry.shared.test_reset()
        defer { AgentPiModelRegistry.shared.test_reset() }
        XCTAssertTrue(AgentPiModelRegistry.shared.updateDiscoveredModels(PiDiscoveredModels(
            options: [AgentModelOption(
                rawValue: AgentModelCatalog.preferredPiModelBaseRaw,
                displayName: "GPT-5.6 Sol",
                description: nil,
                isDefault: true,
                supportedPiThinkingLevels: [.low, .medium, .high, .xhigh, .max]
            )],
            currentModelRaw: AgentModelCatalog.preferredPiModelBaseRaw
        )))
        let availability = AgentModelCatalog.AvailabilityContext(
            claudeCodeAvailable: true,
            codexAvailable: true,
            openCodeAvailable: false,
            cursorAvailable: false,
            piAvailable: true
        )

        let resolutions = MCPAgentRoleDefaultsService.resolutions(
            availability: availability,
            settingsStore: RoleDefaultsStoreStub()
        )

        XCTAssertEqual(resolutions.map(\.recommended), [
            .init(agent: .pi, modelRaw: AgentModelCatalog.preferredPiModelRaw(thinkingLevel: .medium)),
            .init(agent: .pi, modelRaw: AgentModelCatalog.preferredPiModelRaw(thinkingLevel: .high)),
            .init(agent: .pi, modelRaw: AgentModelCatalog.preferredPiModelRaw(thinkingLevel: .high)),
            .init(agent: .claudeCode, modelRaw: "claude-fable-5:xhigh")
        ])
    }

    func testSetSelectionPersistsExplicitPickEvenWhenItMatchesRecommendation() {
        let actualAvailability = AgentModelCatalog.AvailabilityContext(
            claudeCodeAvailable: false,
            codexAvailable: true,
            openCodeAvailable: false,
            cursorAvailable: false,
            zaiConfigured: false,
            kimiConfigured: false,
            customClaudeCompatibleConfigured: false
        )
        let store = RoleDefaultsStoreStub(overrides: [
            AgentModelCatalog.TaskLabelKind.explore.rawValue: AgentModelSelectionID(
                agentRaw: AgentProviderKind.claudeCode.rawValue,
                modelRaw: AgentModel.claudeOpus.rawValue
            ).rawValue
        ])
        let selection = AgentModelCatalog.NormalizedAgentSelection(
            agent: .codexExec,
            modelRaw: AgentModel.gpt55CodexLow.rawValue
        )

        MCPAgentRoleDefaultsService.setSelection(
            selection,
            for: .explore,
            availability: actualAvailability,
            settingsStore: store
        )

        let expected = AgentModelSelectionID(agentRaw: selection.agent.rawValue, modelRaw: selection.modelRaw).rawValue
        XCTAssertEqual(store.overrides?[AgentModelCatalog.TaskLabelKind.explore.rawValue], expected)
        XCTAssertEqual(
            MCPAgentRoleDefaultsService.effectiveNormalizedSelection(
                for: .explore,
                availability: actualAvailability,
                settingsStore: store
            ),
            selection
        )
    }

    func testClearOverrideStillRevertsRoleToRecommendedTracking() {
        let store = RoleDefaultsStoreStub()
        MCPAgentRoleDefaultsService.setSelection(
            AgentModelCatalog.NormalizedAgentSelection(agent: .codexExec, modelRaw: AgentModel.gpt55CodexHigh.rawValue),
            for: .engineer,
            settingsStore: store
        )
        XCTAssertNotNil(store.overrides?[AgentModelCatalog.TaskLabelKind.engineer.rawValue])

        MCPAgentRoleDefaultsService.clearOverride(for: .engineer, settingsStore: store)

        XCTAssertNil(store.overrides?[AgentModelCatalog.TaskLabelKind.engineer.rawValue])
    }
}

@MainActor
private final class RoleDefaultsStoreStub: MCPAgentRoleDefaultsStoring {
    private(set) var overrides: [String: String]?

    init(overrides: [String: String]? = nil) {
        self.overrides = overrides
    }

    func globalMCPAgentRoleOverrides() -> [String: String]? {
        overrides
    }

    func updateGlobalMCPAgentRoleOverrides(_ overrides: [String: String]?, commit: Bool) {
        self.overrides = overrides
    }
}
