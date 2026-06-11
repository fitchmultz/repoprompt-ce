import Foundation

@MainActor
enum PiRunTerminalCleanup {
    static func makeTeardown(
        session: AgentModeViewModel.TabSession,
        controller: PiNativeSessionController,
        runID: UUID,
        windowID: Int,
        terminalState: AgentSessionRunState? = nil
    ) -> AgentRunAttemptTerminalResources.Teardown {
        if session.piController === controller {
            session.piController = nil
        }
        if session.runID == runID {
            session.runID = nil
        }
        AgentModeProcessRunIdentity.clearProcessRunID(for: session)
        return {
            if terminalState == .cancelled {
                _ = await controller.interruptTurn(reason: "cancel")
            }
            await cleanupManagedMCPRouting(windowID: windowID, runID: runID)
            await controller.shutdown()
        }
    }

    static func cleanupManagedMCPRouting(windowID: Int, runID: UUID) async {
        if let clientName = AgentProviderKind.pi.mcpClientNameHint {
            await ServerNetworkManager.shared.clearClientConnectionPolicy(
                for: clientName,
                windowID: windowID,
                runID: runID
            )
        }
        await ServerNetworkManager.shared.cleanupRunRoutingState(for: runID, windowID: windowID)
        await AgentRunCoordinator.shared.cleanupRouting(runID: runID)
    }
}
