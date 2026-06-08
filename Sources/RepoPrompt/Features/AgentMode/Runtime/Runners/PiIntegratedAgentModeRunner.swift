import Foundation

@MainActor
final class PiIntegratedAgentModeRunner {
    private let windowID: Int
    private let hooks: AgentModeRunService.Hooks
    private let terminalCommitBarrier: AgentRunTerminalCommitBarrier

    init(
        windowID: Int,
        hooks: AgentModeRunService.Hooks,
        terminalCommitBarrier: AgentRunTerminalCommitBarrier
    ) {
        self.windowID = windowID
        self.hooks = hooks
        self.terminalCommitBarrier = terminalCommitBarrier
    }

    func startRun(
        tabID: UUID,
        session: AgentModeViewModel.TabSession,
        initialUserMessage: String,
        initialMessageForRun: String,
        attachments: [AgentImageAttachment],
        workspacePath: String?,
        makeLease: (_ runID: UUID) -> MCPBootstrapLease
    ) async {
        let attachmentReservationID = hooks.reserveAttachmentsForTurn(attachments, session)
        if initialMessageForRun != initialUserMessage,
           !session.pendingNonCodexUserInputTokenQueue.isEmpty
        {
            session.pendingNonCodexUserInputTokenQueue[0] = hooks.estimateRuntimeTokens(initialMessageForRun)
        }
        hooks.startNonCodexTurnAccountingIfNeeded(session, initialMessageForRun)

        let runID = AgentModeProcessRunIdentity.startFreshProcessRun(for: session)
        let lease = makeLease(runID)
        let ownership = session.beginRunAttempt(source: "pi")
        let runAttemptID = ownership.attemptID
        session.recordRunProgress(ownership: ownership, kind: .stageTransition, stage: .preparingRuntime)
        session.activeReasoningItemID = nil
        session.reasoningItemIDsByGroupID.removeAll()
        session.codexReasoningSegmentsByKey.removeAll()
        session.runningStatusText = nil
        session.runningStatusSource = nil
        session.runState = .running
        hooks.setAgentRunActive(tabID, true)
        hooks.updateBindings(session)

        let bridgeExtensionURL: URL
        do {
            bridgeExtensionURL = try PiRepoPromptBridgeExtensionInstaller.install(windowID: windowID)
        } catch {
            await terminalCommitBarrier.commit(.init(
                session: session,
                ownership: ownership,
                expectedRunID: runID,
                terminalState: .failed,
                source: "pi.bridgeExtensionInstallFailed",
                errorText: error.localizedDescription,
                attachmentReservationID: attachmentReservationID,
                attachmentDisposition: .deleteFiles,
                finalizeNonCodexUsage: true,
                supportsFollowUp: false,
                notifyTurnComplete: false,
                prepareProviderState: {
                    session.runID = nil
                    AgentModeProcessRunIdentity.clearProcessRunID(for: session)
                    return nil
                }
            ))
            return
        }

        let controller = PiNativeSessionController(
            workspacePath: workspacePath,
            options: .init(
                modelRaw: session.selectedModelRaw,
                launchArguments: ["--mode", "rpc", "--extension", bridgeExtensionURL.path]
            )
        )
        session.piController = controller
        session.installRunAttemptTerminalResources(ownership: ownership) { terminalState in
            if session.piController === controller {
                session.piController = nil
            }
            if session.runID == runID {
                session.runID = nil
            }
            AgentModeProcessRunIdentity.clearProcessRunID(for: session)
            let windowID = self.windowID
            return {
                if terminalState == .cancelled {
                    _ = await controller.interruptTurn(reason: "cancel")
                }
                await Self.cleanupManagedMCPRouting(windowID: windowID, runID: runID)
                await controller.shutdown()
            }
        }

        session.agentTask = Task { [weak self, weak session] in
            guard let self, let session else { return }
            await controller.setExpectedAgentPIDRegistration(
                clientName: AgentProviderKind.pi.mcpClientNameHint,
                runID: runID
            )
            let acquired = await lease.acquire()
            guard acquired else {
                await terminalCommitBarrier.commit(.init(
                    session: session,
                    ownership: ownership,
                    expectedRunID: runID,
                    terminalState: .cancelled,
                    source: "pi.acquireFailure",
                    attachmentReservationID: attachmentReservationID,
                    attachmentDisposition: .deleteFiles,
                    finalizeNonCodexUsage: true,
                    supportsFollowUp: false,
                    notifyTurnComplete: false,
                    prepareProviderState: {
                        if session.piController === controller {
                            session.piController = nil
                        }
                        if session.runID == runID {
                            session.runID = nil
                        }
                        AgentModeProcessRunIdentity.clearProcessRunID(for: session)
                        let windowID = self.windowID
                        return {
                            await Self.cleanupManagedMCPRouting(windowID: windowID, runID: runID)
                            await controller.shutdown()
                        }
                    }
                ))
                return
            }
            await executePiRun(
                session: session,
                controller: controller,
                initialMessageForRun: initialMessageForRun,
                runID: runID,
                runAttemptID: runAttemptID,
                ownership: ownership,
                attachments: attachments,
                attachmentReservationID: attachmentReservationID,
                lease: lease
            )
        }
    }

    private func executePiRun(
        session: AgentModeViewModel.TabSession,
        controller: PiNativeSessionController,
        initialMessageForRun: String,
        runID: UUID,
        runAttemptID: UUID,
        ownership: AgentRunOwnership,
        attachments: [AgentImageAttachment],
        attachmentReservationID: UUID?,
        lease: MCPBootstrapLease
    ) async {
        var didCommitTerminal = false
        func commitTerminal(
            _ state: AgentSessionRunState,
            source: String,
            errorText: String? = nil,
            notifyTurnComplete: Bool
        ) async {
            guard !didCommitTerminal else { return }
            didCommitTerminal = true
            await terminalCommitBarrier.commit(.init(
                session: session,
                ownership: ownership,
                expectedRunID: runID,
                terminalState: state,
                source: source,
                errorText: errorText,
                attachmentReservationID: attachmentReservationID,
                attachmentDisposition: .deleteFiles,
                finalizeNonCodexUsage: true,
                supportsFollowUp: false,
                notifyTurnComplete: notifyTurnComplete,
                prepareProviderState: {
                    if session.piController === controller {
                        session.piController = nil
                    }
                    if session.runID == runID {
                        session.runID = nil
                    }
                    AgentModeProcessRunIdentity.clearProcessRunID(for: session)
                    let windowID = self.windowID
                    return {
                        await Self.cleanupManagedMCPRouting(windowID: windowID, runID: runID)
                        await controller.shutdown()
                    }
                }
            ))
        }

        do {
            let existingRef = PiNativeSessionController.SessionRef(
                sessionID: session.providerSessionID ?? "",
                sessionFile: session.piSessionFile,
                model: session.selectedModelRaw,
                thinkingLevel: session.selectedReasoningEffortRaw
            )
            let shouldResume = session.providerSessionID != nil || session.piSessionFile != nil
            let ref = try await controller.startOrResume(
                existing: shouldResume ? existingRef : nil,
                model: session.selectedModelRaw,
                thinkingLevel: session.selectedReasoningEffortRaw
            )
            await lease.releaseWithoutRoutingWait()
            applySessionRef(ref, to: session)
            hooks.recordPendingHandoffSendOutcome(session, true)
            hooks.stageConsumedAttachmentFilesForDeferredCleanup(attachments, session)
            hooks.markAttachmentsConsumed(session, attachmentReservationID)
            if let currentOwnership = session.activeRunOwnership, currentOwnership.attemptID == runAttemptID {
                session.recordRunProgress(ownership: currentOwnership, kind: .stageTransition, stage: .running)
            }

            let events = await controller.events
            let eventTask = Task { @MainActor [weak self, weak session] in
                guard let self, let session else { return }
                for await event in events {
                    guard session.isCurrentRunAttempt(ownership, expectedRunID: runID) else { return }
                    session.recordRunProgress(ownership: ownership, kind: .providerEvent, stage: .running)
                    switch event {
                    case let .stream(result):
                        await hooks.handleHeadlessStreamResult(result, session, runID, runAttemptID)
                    case let .sessionState(state):
                        applySessionState(state, to: session)
                    case let .turnCompleted(_, status):
                        let terminalState: AgentSessionRunState = switch status {
                        case .completed: .completed
                        case .cancelled: .cancelled
                        case .failed: .failed
                        }
                        await commitTerminal(
                            terminalState,
                            source: "pi.turnCompleted",
                            notifyTurnComplete: status == .completed
                        )
                        return
                    case let .extensionUIRequest(request):
                        if request.requiresResponse {
                            await handleBlockingExtensionUIRequest(request, controller: controller)
                        }
                    case let .error(message):
                        await commitTerminal(
                            .failed,
                            source: "pi.error",
                            errorText: message,
                            notifyTurnComplete: false
                        )
                        return
                    }
                }
            }

            _ = try await controller.sendUserMessage(initialMessageForRun)
            await eventTask.value
        } catch is CancellationError {
            hooks.recordPendingHandoffSendOutcome(session, false)
            await commitTerminal(.cancelled, source: "pi.cancelled", notifyTurnComplete: false)
        } catch {
            hooks.recordPendingHandoffSendOutcome(session, false)
            await commitTerminal(
                .failed,
                source: "pi.failed",
                errorText: "pi failed: \(error.localizedDescription)",
                notifyTurnComplete: false
            )
        }
    }

    private func handleBlockingExtensionUIRequest(
        _ request: PiRPCClient.PiExtensionUIRequest,
        controller: PiNativeSessionController
    ) async {
        do {
            try await controller.respondToExtensionUIRequest(.cancelled(id: request.id))
        } catch {
            // The follow-up error will surface through the pi event stream or transport close.
        }
    }

    private static func cleanupManagedMCPRouting(windowID: Int, runID: UUID) async {
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

    private func applySessionState(_ state: PiRPCClient.SessionState, to session: AgentModeViewModel.TabSession) {
        session.providerSessionID = state.sessionID
        session.piSessionFile = state.sessionFile
        session.selectedReasoningEffortRaw = state.thinkingLevel
        session.isDirty = true
    }

    private func applySessionRef(_ ref: PiNativeSessionController.SessionRef, to session: AgentModeViewModel.TabSession) {
        session.providerSessionID = ref.sessionID
        session.piSessionFile = ref.sessionFile
        session.selectedReasoningEffortRaw = ref.thinkingLevel
        session.isDirty = true
    }
}
