import Darwin
import MCP
@testable import RepoPrompt
import RepoPromptShared
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
            let allowed = ServerController.test_defaultAlwaysAllowedClients
            XCTAssertFalse(
                allowed.contains {
                    ServerController.test_isRepoPromptCLIClientName($0)
                }
            )
            XCTAssertFalse(allowed.contains("pi"))
            XCTAssertFalse(allowed.contains(PiRepoPromptBridgeExtensionInstaller.managedBridgeExecutionClientName))
            XCTAssertFalse(allowed.contains(PiRepoPromptBridgeExtensionInstaller.personalBridgeClientName))
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

    func testManagedPiBridgeAutoApprovesThroughServerControllerWhenExpectedPIDMatches() async throws {
        #if DEBUG
            let manager = ServerNetworkManager()
            let controller = ServerController(
                networkManager: manager,
                installsNetworkCallbacks: false,
                autoApproveAllClientsPreference: .fixed(false)
            )
            let runID = UUID()
            let connectionID = UUID()
            let windowID = 63001
            let pid = getpid()
            let clientName = PiRepoPromptBridgeExtensionInstaller.managedBridgeExecutionClientName
            let autoApproveAllClients = await controller.getAutoApproveAllClients()
            XCTAssertFalse(autoApproveAllClients)
            await manager.installClientConnectionPolicy(
                for: AgentProviderKind.piMCPClientID,
                windowID: windowID,
                restrictedTools: AgentModeMCPToolPolicy.restrictedTools,
                oneShot: false,
                reason: "server controller managed pi bridge admission test",
                ttl: 10,
                tabID: nil,
                runID: runID,
                additionalTools: [MCPWindowToolName.workspaceContext],
                purpose: .agentModeRun,
                taskLabelKind: nil,
                allowsAgentExternalControlTools: false,
                requiresExpectedAgentPID: true
            )
            await manager.registerExpectedAgentPID(pid, for: AgentProviderKind.piMCPClientID, runID: runID)
            await manager.debugInstallDirectAdmissionConnectionForTesting(
                connectionID: connectionID,
                connection: ServerControllerAdmissionTestConnection()
            )
            await manager.debugSetPeerPIDForTesting(Int(pid), connectionID: connectionID)

            let approved = await controller.test_handleConnectionApproval(connectionID: connectionID, clientName: clientName)
            let mappedRunID = await manager.runIDForConnection(connectionID)
            let policyState = await manager.debugConnectionPolicyState(for: connectionID)

            await cleanupPiAdmissionFixture(manager: manager, runID: runID, windowID: windowID, connectionID: connectionID, pid: pid)

            XCTAssertTrue(approved)
            XCTAssertEqual(mappedRunID, runID)
            XCTAssertEqual(policyState.purpose, .agentModeRun)
            XCTAssertEqual(policyState.restrictedTools, AgentModeMCPToolPolicy.restrictedTools)
        #else
            throw XCTSkip("DEBUG-only ServerController admission seams are unavailable in release builds")
        #endif
    }

    func testManagedPiBridgeAlwaysAllowCannotBypassExpectedPIDGate() async throws {
        #if DEBUG
            let manager = ServerNetworkManager()
            let controller = ServerController(
                networkManager: manager,
                installsNetworkCallbacks: false,
                autoApproveAllClientsPreference: .fixed(false)
            )
            let runID = UUID()
            let connectionID = UUID()
            let windowID = 63002
            let pid = getpid()
            let clientName = PiRepoPromptBridgeExtensionInstaller.managedBridgeExecutionClientName
            let autoApproveAllClients = await controller.getAutoApproveAllClients()
            XCTAssertFalse(autoApproveAllClients)
            await controller.setAlwaysAllowed(clientID: clientName, allowed: true)
            await controller.setApprovalCallback { [weak controller] _ in
                await controller?.resolvePendingApproval(allow: false)
            }
            let alwaysAllowedClientIDs = await controller.alwaysAllowedClientIDs()
            XCTAssertFalse(alwaysAllowedClientIDs.contains(clientName))
            await installPiAdmissionFixture(manager: manager, runID: runID, windowID: windowID, pid: nil)
            await manager.debugInstallDirectAdmissionConnectionForTesting(
                connectionID: connectionID,
                connection: ServerControllerAdmissionTestConnection()
            )
            await manager.debugSetPeerPIDForTesting(Int(pid), connectionID: connectionID)

            let approved = await controller.test_handleConnectionApproval(connectionID: connectionID, clientName: clientName)
            let mappedRunID = await manager.runIDForConnection(connectionID)

            await cleanupPiAdmissionFixture(manager: manager, runID: runID, windowID: windowID, connectionID: connectionID, pid: pid)

            XCTAssertFalse(approved)
            XCTAssertNil(mappedRunID)
        #else
            throw XCTSkip("DEBUG-only ServerController admission seams are unavailable in release builds")
        #endif
    }

    func testNearMatchPiNamesDoNotAutoApproveThroughServerController() async throws {
        #if DEBUG
            let manager = ServerNetworkManager()
            let controller = ServerController(
                networkManager: manager,
                installsNetworkCallbacks: false,
                autoApproveAllClientsPreference: .fixed(false)
            )
            let runID = UUID()
            let windowID = 63003
            let pid = getpid()
            let rejectedClientNames = ["pischema", "pi-schema-evil", "pifoo", "xpi", "pi2"]
            var connectionIDs: [UUID] = []
            await controller.setApprovalCallback { [weak controller] _ in
                await controller?.resolvePendingApproval(allow: false)
            }
            await installPiAdmissionFixture(manager: manager, runID: runID, windowID: windowID, pid: pid)

            for rejectedClientName in rejectedClientNames {
                let connectionID = UUID()
                connectionIDs.append(connectionID)
                await manager.debugInstallDirectAdmissionConnectionForTesting(
                    connectionID: connectionID,
                    connection: ServerControllerAdmissionTestConnection()
                )
                await manager.debugSetPeerPIDForTesting(Int(pid), connectionID: connectionID)

                let approved = await controller.test_handleConnectionApproval(
                    connectionID: connectionID,
                    clientName: rejectedClientName
                )
                let mappedRunID = await manager.runIDForConnection(connectionID)

                XCTAssertFalse(approved, "\(rejectedClientName) must not be auto-approved as managed pi")
                XCTAssertNil(mappedRunID, "\(rejectedClientName) must not consume managed pi run routing")
            }

            await cleanupPiAdmissionFixture(
                manager: manager,
                runID: runID,
                windowID: windowID,
                connectionIDs: connectionIDs,
                pid: pid
            )
        #else
            throw XCTSkip("DEBUG-only ServerController admission seams are unavailable in release builds")
        #endif
    }

    #if DEBUG
        private func installPiAdmissionFixture(
            manager: ServerNetworkManager,
            runID: UUID,
            windowID: Int,
            pid: pid_t?
        ) async {
            await manager.installClientConnectionPolicy(
                for: AgentProviderKind.piMCPClientID,
                windowID: windowID,
                restrictedTools: AgentModeMCPToolPolicy.restrictedTools,
                oneShot: false,
                reason: "server controller managed pi bridge admission test",
                ttl: 10,
                tabID: nil,
                runID: runID,
                additionalTools: [MCPWindowToolName.workspaceContext],
                purpose: .agentModeRun,
                taskLabelKind: nil,
                allowsAgentExternalControlTools: false,
                requiresExpectedAgentPID: true
            )
            if let pid {
                await manager.registerExpectedAgentPID(pid, for: AgentProviderKind.piMCPClientID, runID: runID)
            }
        }

        private func cleanupPiAdmissionFixture(
            manager: ServerNetworkManager,
            runID: UUID,
            windowID: Int,
            connectionID: UUID,
            pid: pid_t
        ) async {
            await cleanupPiAdmissionFixture(
                manager: manager,
                runID: runID,
                windowID: windowID,
                connectionIDs: [connectionID],
                pid: pid
            )
        }

        private func cleanupPiAdmissionFixture(
            manager: ServerNetworkManager,
            runID: UUID,
            windowID: Int,
            connectionIDs: [UUID],
            pid: pid_t
        ) async {
            await manager.clearExpectedAgentPID(pid, for: AgentProviderKind.piMCPClientID, runID: runID)
            await manager.clearExpectedAgentPID(pid, for: PiRepoPromptBridgeExtensionInstaller.managedBridgeExecutionClientName, runID: runID)
            for connectionID in connectionIDs {
                await manager.debugSetPeerPIDForTesting(nil, connectionID: connectionID)
                await manager.debugRemoveConnection(connectionID)
            }
            await manager.clearClientConnectionPolicy(for: AgentProviderKind.piMCPClientID, windowID: windowID, runID: runID)
            await manager.cleanupRunRoutingState(for: runID, windowID: windowID)
        }
    #endif

    func testSanitizerRemovesPersistedRepoPromptCLIAndManagedPiAllowListEntries() {
        #if DEBUG
            let sanitized = ServerController.test_sanitizedAlwaysAllowedClients([
                "RepoPrompt CLI",
                "RepoPrompt CLI (Exec)",
                "RepoPrompt CLI 1.2.3",
                "pi",
                PiRepoPromptBridgeExtensionInstaller.managedBridgeExecutionClientName,
                PiRepoPromptBridgeExtensionInstaller.personalBridgeClientName,
                "claude-code",
                "custom-client"
            ])

            XCTAssertEqual(sanitized, [
                "claude-code",
                "custom-client",
                PiRepoPromptBridgeExtensionInstaller.personalBridgeClientName
            ])
        #else
            throw XCTSkip("DEBUG-only ServerController admission seams are unavailable in release builds")
        #endif
    }

    func testBuiltInAlwaysAllowedClientRecognizesConfiguredDefaultsAndVariants() throws {
        #if DEBUG
            for clientID in ServerController.test_defaultAlwaysAllowedClients {
                XCTAssertTrue(
                    ServerController.isBuiltInAlwaysAllowedClient(clientID),
                    "Expected configured default to be recognized: \(clientID)"
                )
            }

            for clientID in ["Claude Code v2.1", "cursor-agent"] {
                XCTAssertTrue(
                    ServerController.isBuiltInAlwaysAllowedClient(clientID),
                    "Expected supported family variant to be recognized: \(clientID)"
                )
            }

            for clientID in ["my-custom-client", "RepoPrompt CLI", "claude-code-wrapper", "cursor-agent-wrapper"] {
                XCTAssertFalse(
                    ServerController.isBuiltInAlwaysAllowedClient(clientID),
                    "Expected non-built-in client to require approval: \(clientID)"
                )
            }
        #else
            throw XCTSkip("DEBUG-only default allow-list seam is unavailable in release builds")
        #endif
    }
}

#if DEBUG
    private actor ServerControllerAdmissionTestConnection: MCPServerConnection {
        nonisolated var isFilesystemBacked: Bool {
            false
        }

        nonisolated var connectionFolderURL: URL? {
            nil
        }

        nonisolated var capabilityToken: String? {
            nil
        }

        func start(approvalHandler _: @escaping (MCP.Client.Info) async -> Bool) async throws {}

        func stop() async {}

        func abortForExecutionWatchdog() async {}

        func notifyToolListChanged() async {}

        func connectionState() -> ConnectionStateSnapshot {
            .ready
        }

        func isViableForRetention() -> Bool {
            true
        }

        func secondsSinceLastActivity() async -> TimeInterval {
            0
        }

        func transportIngressSnapshot() async -> MCPTransportIngressSnapshot? {
            nil
        }

        func terminate(reason _: TerminationReason, message _: String?) async {}

        func sendProgress(
            tool _: String,
            kind _: RepoPromptProgressKind,
            stage _: String,
            message _: String
        ) async {}
    }
#endif
