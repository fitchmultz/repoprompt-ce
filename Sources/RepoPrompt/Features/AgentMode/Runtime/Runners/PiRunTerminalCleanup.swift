import Foundation

@MainActor
enum PiRunTerminalCleanup {
    static func makeTeardown(
        session: AgentModeViewModel.TabSession,
        controller: PiNativeSessionController,
        runID: UUID,
        windowID: Int,
        terminalState: AgentSessionRunState? = nil,
        restoreUndeliveredPiSteeringDrafts: ((_ tabID: UUID, _ text: String, _ message: String, _ strategy: AgentModeRunService.DraftRestorationStrategy) -> Void)? = nil
    ) -> AgentRunAttemptTerminalResources.Teardown {
        let undeliveredDrafts = session.pendingPiSteeringInstructions
            .map(\.draftText)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if session.piController === controller {
            session.piController = nil
        }
        session.piExtensionUIResponseInFlight = false
        session.clearPendingPiSteeringInstructions()
        if !undeliveredDrafts.isEmpty {
            restoreUndeliveredPiSteeringDrafts?(
                session.tabID,
                undeliveredDrafts.joined(separator: "\n"),
                "Restored undelivered pi steering messages because the run ended before pi accepted them.",
                .prependAlways
            )
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
