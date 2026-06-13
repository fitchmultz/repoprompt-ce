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
                launchArguments: PiIntegrationConfiguration.managedRPCLaunchArguments(
                    bridgeExtensionPath: bridgeExtensionURL.path
                )
            )
        )
        session.piController = controller
        session.installRunAttemptTerminalResources(ownership: ownership) { terminalState in
            self.makeTerminalTeardown(
                session: session,
                controller: controller,
                runID: runID,
                terminalState: terminalState
            )
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
                        self.makeTerminalTeardown(
                            session: session,
                            controller: controller,
                            runID: runID
                        )
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
        var didReleaseLease = false
        func commitTerminal(
            _ state: AgentSessionRunState,
            source: String,
            errorText: String? = nil,
            notifyTurnComplete: Bool
        ) async {
            guard !didCommitTerminal else { return }
            didCommitTerminal = true
            if !didReleaseLease {
                didReleaseLease = true
                await lease.cancelAndCleanup()
            }
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
                supportsFollowUp: state == .completed,
                notifyTurnComplete: notifyTurnComplete,
                prepareProviderState: {
                    self.makeTerminalTeardown(
                        session: session,
                        controller: controller,
                        runID: runID
                    )
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
            didReleaseLease = true
            PiRunSessionStateMapper.applySessionRef(ref, to: session)
            hooks.recordPendingHandoffSendOutcome(session, true)
            hooks.stageConsumedAttachmentFilesForDeferredCleanup(attachments, session)
            hooks.markAttachmentsConsumed(session, attachmentReservationID)
            if let currentOwnership = session.activeRunOwnership, currentOwnership.attemptID == runAttemptID {
                session.recordRunProgress(ownership: currentOwnership, kind: .stageTransition, stage: .running)
            }

            let events = await controller.events
            var didReceivePostPromptProviderEvent = false
            var firstEventWatchdogTask: Task<Void, Never>?
            func markPostPromptProviderEvent(session: AgentModeViewModel.TabSession) {
                didReceivePostPromptProviderEvent = true
                firstEventWatchdogTask?.cancel()
                session.recordRunProgress(ownership: ownership, kind: .providerEvent, stage: .running)
            }
            let eventTask = Task { @MainActor [weak self, weak session] in
                guard let self, let session else { return }
                var completionGate = PiRunCompletionGate()
                for await event in events {
                    guard session.isCurrentRunAttempt(ownership, expectedRunID: runID) else { return }
                    switch event {
                    case let .stream(result):
                        markPostPromptProviderEvent(session: session)
                        await hooks.handleHeadlessStreamResult(result, session, runID, runAttemptID)
                    case let .sessionState(state):
                        completionGate.recordSessionState(state)
                        PiRunSessionStateMapper.applySessionState(state, to: session)
                    case let .turnCompleted(_, status):
                        markPostPromptProviderEvent(session: session)
                        guard let terminalState = completionGate.terminalState(for: status) else { continue }
                        await commitTerminal(
                            terminalState,
                            source: "pi.turnCompleted",
                            notifyTurnComplete: status == .completed
                        )
                        return
                    case let .extensionUIRequest(request):
                        markPostPromptProviderEvent(session: session)
                        if request.requiresResponse {
                            await handleBlockingExtensionUIRequest(request, session: session, controller: controller)
                        }
                    case let .error(message):
                        markPostPromptProviderEvent(session: session)
                        await commitTerminal(
                            .failed,
                            source: "pi.error",
                            errorText: message,
                            notifyTurnComplete: false
                        )
                        return
                    case let .diagnostic(diagnostic):
                        let diagnosticText = PiRunDiagnosticPresentation.statusText(from: diagnostic)
                        session.setRunningStatus(diagnosticText, source: .transport)
                        await hooks.handleHeadlessStreamResult(
                            AIStreamResult(type: "status", text: diagnosticText),
                            session,
                            runID,
                            runAttemptID
                        )
                    }
                }
            }

            let images = try PiRPCImageContentBuilder.images(from: attachments)
            _ = try await controller.sendUserMessage(initialMessageForRun, images: images)
            firstEventWatchdogTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: PiFirstProviderEventWatchdog.timeoutNanoseconds)
                guard !Task.isCancelled,
                      PiFirstProviderEventWatchdog.shouldFire(
                          didReceivePostPromptProviderEvent: didReceivePostPromptProviderEvent,
                          didCommitTerminal: didCommitTerminal,
                          isCurrentRunAttempt: session.isCurrentRunAttempt(ownership, expectedRunID: runID)
                      )
                else { return }
                _ = await controller.interruptTurn(reason: "first provider event timeout")
                await commitTerminal(
                    .failed,
                    source: PiFirstProviderEventWatchdog.source,
                    errorText: PiFirstProviderEventWatchdog.errorText,
                    notifyTurnComplete: false
                )
            }
            await eventTask.value
            firstEventWatchdogTask?.cancel()
        } catch is CancellationError {
            hooks.recordPendingHandoffSendOutcome(session, false)
            await commitTerminal(.cancelled, source: "pi.cancelled", notifyTurnComplete: false)
        } catch PiNativeSessionController.ControllerError.sessionSwitchCancelled(_) {
            hooks.recordPendingHandoffSendOutcome(session, false)
            await commitTerminal(.cancelled, source: "pi.sessionSwitchCancelled", notifyTurnComplete: false)
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

    private func makeTerminalTeardown(
        session: AgentModeViewModel.TabSession,
        controller: PiNativeSessionController,
        runID: UUID,
        terminalState: AgentSessionRunState? = nil
    ) -> AgentRunAttemptTerminalResources.Teardown {
        PiRunTerminalCleanup.makeTeardown(
            session: session,
            controller: controller,
            runID: runID,
            windowID: windowID,
            terminalState: terminalState,
            restoreUndeliveredPiSteeringDrafts: hooks.restoreDraftText
        )
    }

    private func handleBlockingExtensionUIRequest(
        _ request: PiRPCClient.PiExtensionUIRequest,
        session: AgentModeViewModel.TabSession,
        controller: PiNativeSessionController
    ) async {
        guard let interaction = PiExtensionUIInteractionMapper.interaction(from: request) else {
            try? await controller.respondToExtensionUIRequest(.cancelled(id: request.id))
            return
        }

        await deliverBlockingExtensionUIResponse(
            request,
            interaction: interaction,
            session: session,
            respond: { response in
                try await controller.respondToExtensionUIRequest(response)
            }
        )
    }

    private func deliverBlockingExtensionUIResponse(
        _ request: PiRPCClient.PiExtensionUIRequest,
        interaction: AgentAskUserInteraction,
        session: AgentModeViewModel.TabSession,
        respond: (PiExtensionUIResponse) async throws -> Void
    ) async {
        hooks.setPiExtensionUIResponseInFlight(session, true)
        var didDeliverResponse = false
        defer {
            hooks.setPiExtensionUIResponseInFlight(session, false)
            if didDeliverResponse {
                hooks.flushQueuedPiSteeringAfterBlockingResponse(session)
            }
        }
        do {
            let response = try await hooks.askUserInteraction(session.tabID, interaction)
            let rpcResponse = PiExtensionUIInteractionMapper.response(for: request, from: response)
            try await respond(rpcResponse)
            didDeliverResponse = true
        } catch {
            do {
                try await respond(.cancelled(id: request.id))
                didDeliverResponse = true
            } catch {
                // The follow-up error will surface through the pi event stream or transport close.
            }
        }
    }

    #if DEBUG
        func test_handleBlockingExtensionUIRequest(
            _ request: PiRPCClient.PiExtensionUIRequest,
            session: AgentModeViewModel.TabSession,
            respond: @escaping (PiExtensionUIResponse) async throws -> Void
        ) async {
            guard let interaction = PiExtensionUIInteractionMapper.interaction(from: request) else { return }
            await deliverBlockingExtensionUIResponse(
                request,
                interaction: interaction,
                session: session,
                respond: respond
            )
        }
    #endif
}
