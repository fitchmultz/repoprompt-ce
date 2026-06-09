@testable import RepoPrompt
import XCTest

final class ServerControllerAdmissionTests: XCTestCase {
    func testRepoPromptCLIClientNamesAreRecognizedForVerificationOnly() {
        #if DEBUG
            XCTAssertTrue(ServerController.test_isRepoPromptCLIClientName("RepoPrompt CLI"))
            XCTAssertTrue(ServerController.test_isRepoPromptCLIClientName(" RepoPrompt CLI (Exec) "))
            XCTAssertTrue(ServerController.test_isRepoPromptCLIClientName("RepoPrompt CLI 1.2.3"))
            XCTAssertFalse(ServerController.test_isRepoPromptCLIClientName("Spoofed RepoPrompt CLI"))
            XCTAssertFalse(ServerController.test_isRepoPromptCLIClientName("repoPrompt CLI"))
        #else
            throw XCTSkip("DEBUG-only ServerController admission seams are unavailable in release builds")
        #endif
    }

    func testDefaultAllowListDoesNotIncludeRepoPromptCLIOrPi() {
        #if DEBUG
            XCTAssertFalse(
                ServerController.test_defaultAlwaysAllowedClients.contains {
                    ServerController.test_isRepoPromptCLIClientName($0)
                }
            )
            XCTAssertFalse(ServerController.test_defaultAlwaysAllowedClients.contains("pi"))
        #else
            throw XCTSkip("DEBUG-only ServerController admission seams are unavailable in release builds")
        #endif
    }

    func testDefaultAllowListIncludesSynchronousACPClients() throws {
        #if DEBUG
            let allowed = ServerController.test_defaultAlwaysAllowedClients

            XCTAssertTrue(allowed.contains(AgentProviderKind.openCodeMCPClientID))
            XCTAssertTrue(allowed.contains(AgentProviderKind.cursorMCPClientID))
        #else
            throw XCTSkip("DEBUG-only ServerController admission seams are unavailable in release builds")
        #endif
    }

    func testServerControllerHasExpectedAgentClientAutoApprovalBeforeGenericAllowList() throws {
        let source = try String(
            contentsOf: RepoRoot.url().appendingPathComponent("Sources/RepoPrompt/Infrastructure/MCP/ServerController.swift"),
            encoding: .utf8
        )
        let expectedAgentRange = try XCTUnwrap(source.range(of: "shouldAutoApproveExpectedAgentClient"))
        let allowListRange = try XCTUnwrap(source.range(of: "isClientAlwaysAllowed", range: expectedAgentRange.upperBound ..< source.endIndex))
        XCTAssertLessThan(expectedAgentRange.lowerBound, allowListRange.lowerBound)
        XCTAssertTrue(source.contains("expected managed agent client"))
    }

    func testExpectedPIDAutoApprovalDoesNotRequirePriorAdmittedBootstrap() async throws {
        let manager = ServerNetworkManager.shared
        let runID = UUID()
        let pid = getpid()
        let clientName = try XCTUnwrap(AgentProviderKind.pi.mcpClientNameHint)
        await manager.debugSeedRunPolicyState(
            runID: runID,
            windowID: 1,
            restrictedTools: [],
            additionalTools: nil,
            purpose: .agentModeRun
        )
        await manager.registerExpectedAgentPID(pid, for: clientName, runID: runID)

        let approved = await manager.debugShouldAutoApproveExpectedAgentClient(
            clientName: clientName,
            clientPid: Int(pid)
        )

        await manager.clearExpectedAgentPID(pid, for: clientName, runID: runID)
        await manager.cleanupRunRoutingState(for: runID, windowID: 1)

        XCTAssertTrue(approved)
    }

    func testSanitizerRemovesPersistedRepoPromptCLIAllowListEntries() {
        #if DEBUG
            let sanitized = ServerController.test_sanitizedAlwaysAllowedClients([
                "RepoPrompt CLI",
                "RepoPrompt CLI (Exec)",
                "RepoPrompt CLI 1.2.3",
                "claude-code",
                "custom-client"
            ])

            XCTAssertEqual(sanitized, ["claude-code", "custom-client"])
        #else
            throw XCTSkip("DEBUG-only ServerController admission seams are unavailable in release builds")
        #endif
    }
}
