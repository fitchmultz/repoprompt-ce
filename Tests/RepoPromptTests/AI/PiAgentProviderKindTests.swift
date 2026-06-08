@testable import RepoPrompt
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

    func testPiModelsAreAvailableButHiddenFromSelectableAgentsUntilRunnerWiring() {
        let availability = AgentModelCatalog.AvailabilityContext(piAvailable: true)

        XCTAssertTrue(AgentModelCatalog.isAgentAvailable(.pi, availability: availability))
        XCTAssertEqual(AgentModel.modelsForAgent(.pi), [.defaultModel])
        XCTAssertEqual(
            AgentModelCatalog.defaultModelRaw(for: .pi, availability: availability),
            AgentModel.defaultModel.rawValue
        )
        XCTAssertEqual(
            AgentModelCatalog.options(for: .pi, availability: availability).map(\.rawValue),
            [AgentModel.defaultModel.rawValue]
        )
        XCTAssertFalse(
            AgentModelCatalog.selectableAgents(availability: availability).contains(.pi),
            "pi should stay hidden from visible Agent Mode selection until native runner support is wired."
        )
    }
}
