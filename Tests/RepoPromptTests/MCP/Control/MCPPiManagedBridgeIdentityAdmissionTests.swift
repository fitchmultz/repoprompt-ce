import Darwin
import Foundation
@testable import RepoPrompt
import XCTest

final class MCPPiManagedBridgeIdentityAdmissionTests: XCTestCase {
    private let manager = ServerNetworkManager.shared
    private let agentClientName = AgentProviderKind.piMCPClientID
    private let managedBridgeClientName = PiRepoPromptBridgeExtensionInstaller.managedBridgeExecutionClientName
    private let personalBridgeClientName = PiRepoPromptBridgeExtensionInstaller.personalBridgeClientName

    func testManagedPiBridgeClientConsumesPiAgentModePolicyWhenExpectedPIDMatches() async throws {
        #if DEBUG
            let runID = UUID()
            let connectionID = UUID()
            let windowID = 62001
            try await withInstalledPiPolicy(runID: runID, windowID: windowID) {
                await manager.registerExpectedAgentPID(getpid(), for: agentClientName, runID: runID)
                try await assertPiPolicyApplies(
                    clientName: managedBridgeClientName,
                    connectionID: connectionID,
                    runID: runID,
                    windowID: windowID
                )
            } cleanup: {
                await manager.removeConnection(connectionID)
            }
        #else
            throw XCTSkip("Pi managed bridge admission diagnostics require DEBUG helpers.")
        #endif
    }

    func testExactPiClientConsumesPiAgentModePolicyWhenExpectedPIDMatches() async throws {
        #if DEBUG
            let runID = UUID()
            let connectionID = UUID()
            let windowID = 62004
            try await withInstalledPiPolicy(runID: runID, windowID: windowID) {
                await manager.registerExpectedAgentPID(getpid(), for: agentClientName, runID: runID)
                try await assertPiPolicyApplies(
                    clientName: agentClientName,
                    connectionID: connectionID,
                    runID: runID,
                    windowID: windowID
                )
            } cleanup: {
                await manager.removeConnection(connectionID)
            }
        #else
            throw XCTSkip("Pi managed bridge admission diagnostics require DEBUG helpers.")
        #endif
    }

    func testManagedPiBridgeClientCannotConsumePiAgentModePolicyWithoutExpectedPID() async throws {
        #if DEBUG
            let runID = UUID()
            let connectionID = UUID()
            let windowID = 62002
            try await withInstalledPiPolicy(runID: runID, windowID: windowID) {
                let result = await manager.debugApplyPendingPolicy(
                    clientName: managedBridgeClientName,
                    connectionID: connectionID,
                    clientPid: Int(getpid()),
                    bootstrapClientName: managedBridgeClientName,
                    pidGateTimeout: 0.01,
                    requireRunRouting: false
                )

                XCTAssertEqual(result.outcome, "rejected:ownership_timeout")
                XCTAssertEqual(result.runID, runID)
                let mappedRunID = await manager.runIDForConnection(connectionID)
                XCTAssertNil(mappedRunID)
                let pendingAfterReject = await manager.debugPendingPolicySnapshot(for: agentClientName)
                XCTAssertTrue(pendingAfterReject.contains { $0.runID == runID })
            } cleanup: {
                await manager.removeConnection(connectionID)
            }
        #else
            throw XCTSkip("Pi managed bridge admission diagnostics require DEBUG helpers.")
        #endif
    }

    func testUnrelatedManagedPiBridgeClientFallsBackWhileAnotherPiAgentPIDIsExpected() async throws {
        #if DEBUG
            let runID = UUID()
            let connectionID = UUID()
            let windowID = 62006
            let unrelatedExpectedPID = pid_t(Int32.max - 7)
            try await withInstalledPiPolicy(runID: runID, windowID: windowID) {
                await manager.registerExpectedAgentPID(unrelatedExpectedPID, for: agentClientName, runID: runID)

                let bootstrapAdmission = await manager.debugBootstrapPolicyAdmissionStatus(
                    bootstrapClientName: managedBridgeClientName,
                    connectionID: connectionID,
                    clientPid: Int(getpid()),
                    timeout: 0.01
                )
                XCTAssertEqual(bootstrapAdmission, "notRequired")

                let admission = await manager.debugAgentPolicyAdmissionStatus(
                    clientName: managedBridgeClientName,
                    bootstrapClientName: managedBridgeClientName,
                    connectionID: connectionID,
                    clientPid: Int(getpid()),
                    timeout: 0.01
                )
                XCTAssertEqual(admission, "notRequired")

                let autoApproved = await manager.debugShouldAutoApproveExpectedAgentClient(
                    clientName: managedBridgeClientName,
                    clientPid: Int(getpid())
                )
                XCTAssertFalse(autoApproved)

                let result = await manager.debugApplyPendingPolicy(
                    clientName: managedBridgeClientName,
                    connectionID: connectionID,
                    clientPid: Int(getpid()),
                    bootstrapClientName: managedBridgeClientName,
                    pidGateTimeout: 0.01,
                    requireRunRouting: false
                )

                await manager.clearExpectedAgentPID(unrelatedExpectedPID, for: agentClientName, runID: runID)

                XCTAssertEqual(result.outcome, "fallback")
                XCTAssertNil(result.runID)
                let mappedRunID = await manager.runIDForConnection(connectionID)
                XCTAssertNil(mappedRunID)
                let pendingAfterFallback = await manager.debugPendingPolicySnapshot(for: agentClientName)
                XCTAssertTrue(pendingAfterFallback.contains { $0.runID == runID })
            } cleanup: {
                await manager.removeConnection(connectionID)
            }
        #else
            throw XCTSkip("Pi managed bridge admission diagnostics require DEBUG helpers.")
        #endif
    }

    func testPersonalPiBridgeClientCannotConsumeManagedPiAgentModePolicy() async throws {
        #if DEBUG
            let runID = UUID()
            let connectionID = UUID()
            let windowID = 62003
            try await withInstalledPiPolicy(runID: runID, windowID: windowID) {
                await manager.registerExpectedAgentPID(getpid(), for: agentClientName, runID: runID)
                try await assertClientCannotConsumePiPolicy(
                    clientName: personalBridgeClientName,
                    connectionID: connectionID,
                    runID: runID
                )
            } cleanup: {
                await manager.removeConnection(connectionID)
            }
        #else
            throw XCTSkip("Pi managed bridge admission diagnostics require DEBUG helpers.")
        #endif
    }

    func testNearMatchPiFamilyNamesCannotConsumeOrAutoApproveManagedPiPolicy() async throws {
        #if DEBUG
            let runID = UUID()
            let windowID = 62005
            let rejectedClientNames = ["pischema", "pi-schema-evil", "pifoo", "xpi", "pi2"]
            var connectionIDs: [UUID] = []

            try await withInstalledPiPolicy(runID: runID, windowID: windowID) {
                await manager.registerExpectedAgentPID(getpid(), for: agentClientName, runID: runID)

                for rejectedClientName in rejectedClientNames {
                    let connectionID = UUID()
                    connectionIDs.append(connectionID)
                    try await assertClientCannotConsumePiPolicy(
                        clientName: rejectedClientName,
                        connectionID: connectionID,
                        runID: runID
                    )

                    let admission = await manager.debugAgentPolicyAdmissionStatus(
                        clientName: rejectedClientName,
                        bootstrapClientName: rejectedClientName,
                        connectionID: connectionID,
                        clientPid: Int(getpid()),
                        timeout: 0.01
                    )
                    XCTAssertEqual(admission, "notRequired", "\(rejectedClientName) must not be a known pi agent client")
                    let autoApproved = await manager.debugShouldAutoApproveExpectedAgentClient(
                        clientName: rejectedClientName,
                        clientPid: Int(getpid())
                    )
                    XCTAssertFalse(autoApproved, "\(rejectedClientName) must not auto-approve under the pi expected PID")
                }
            } cleanup: {
                for connectionID in connectionIDs {
                    await manager.removeConnection(connectionID)
                }
            }
        #else
            throw XCTSkip("Pi managed bridge admission diagnostics require DEBUG helpers.")
        #endif
    }

    #if DEBUG
        private static let additionalTools: Set<String> = [MCPWindowToolName.workspaceContext]

        private func assertPiPolicyApplies(
            clientName: String,
            connectionID: UUID,
            runID: UUID,
            windowID: Int
        ) async throws {
            let pendingForClientName = await manager.debugPendingPolicySnapshot(for: clientName)
            XCTAssertTrue(pendingForClientName.contains { $0.runID == runID })
            let admission = await manager.debugAgentPolicyAdmissionStatus(
                clientName: clientName,
                bootstrapClientName: clientName,
                connectionID: connectionID,
                clientPid: Int(getpid())
            )
            XCTAssertEqual(admission, "ready")
            let autoApproved = await manager.debugShouldAutoApproveExpectedAgentClient(
                clientName: clientName,
                clientPid: Int(getpid())
            )
            XCTAssertTrue(autoApproved)

            let result = await manager.debugApplyPendingPolicy(
                clientName: clientName,
                connectionID: connectionID,
                clientPid: Int(getpid()),
                bootstrapClientName: clientName,
                requireRunRouting: false
            )

            XCTAssertEqual(result.outcome, "applied")
            XCTAssertEqual(result.runID, runID)
            XCTAssertEqual(result.windowID, windowID)
            XCTAssertEqual(result.purpose, .agentModeRun)
            XCTAssertEqual(result.restrictedTools, AgentModeMCPToolPolicy.restrictedTools)
            XCTAssertEqual(result.additionalTools, Self.additionalTools)
            let mappedRunID = await manager.runIDForConnection(connectionID)
            XCTAssertEqual(mappedRunID, runID)
            let pendingAfterApply = await manager.debugPendingPolicySnapshot(for: agentClientName)
            XCTAssertTrue(pendingAfterApply.contains { $0.runID == runID })
        }

        private func assertClientCannotConsumePiPolicy(
            clientName: String,
            connectionID: UUID,
            runID: UUID
        ) async throws {
            let pendingForClientName = await manager.debugPendingPolicySnapshot(for: clientName)
            XCTAssertFalse(pendingForClientName.contains { $0.runID == runID })

            let result = await manager.debugApplyPendingPolicy(
                clientName: clientName,
                connectionID: connectionID,
                clientPid: Int(getpid()),
                bootstrapClientName: clientName,
                requireRunRouting: false
            )

            XCTAssertEqual(result.outcome, "fallback")
            XCTAssertNil(result.runID)
            let mappedRunID = await manager.runIDForConnection(connectionID)
            XCTAssertNil(mappedRunID)
            let pendingAfterFallback = await manager.debugPendingPolicySnapshot(for: agentClientName)
            XCTAssertTrue(pendingAfterFallback.contains { $0.runID == runID })
        }

        private func withInstalledPiPolicy(
            runID: UUID,
            windowID: Int,
            operation: () async throws -> Void,
            cleanup: () async -> Void
        ) async throws {
            await manager.installClientConnectionPolicy(
                for: agentClientName,
                windowID: windowID,
                restrictedTools: AgentModeMCPToolPolicy.restrictedTools,
                oneShot: false,
                reason: "pi managed bridge identity admission test",
                ttl: 10,
                tabID: nil,
                runID: runID,
                additionalTools: Self.additionalTools,
                purpose: .agentModeRun,
                taskLabelKind: nil,
                allowsAgentExternalControlTools: false,
                requiresExpectedAgentPID: true
            )
            do {
                try await operation()
                await cleanupPiPolicy(runID: runID, windowID: windowID)
                await cleanup()
            } catch {
                await cleanupPiPolicy(runID: runID, windowID: windowID)
                await cleanup()
                throw error
            }
        }

        private func cleanupPiPolicy(runID: UUID, windowID: Int) async {
            await manager.clearExpectedAgentPID(getpid(), for: agentClientName, runID: runID)
            await manager.clearExpectedAgentPID(getpid(), for: managedBridgeClientName, runID: runID)
            await manager.clearClientConnectionPolicy(for: agentClientName, windowID: windowID, runID: runID)
            await manager.cleanupRunRoutingState(for: runID, windowID: windowID)
        }
    #endif
}
