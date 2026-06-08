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

    func testPiModelsAreSelectableWhenRuntimeAvailabilityIsProven() {
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
        XCTAssertTrue(AgentModelCatalog.selectableAgents(availability: availability).contains(.pi))
        XCTAssertEqual(AgentProviderKind.pi.providerBindingID, .pi)
    }
}
