import Foundation

@MainActor
final class PiIntegratedAgentModeRunner {
    private static let firstProviderEventTimeoutNanoseconds: UInt64 = 60 * 1_000_000_000

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
            applySessionRef(ref, to: session)
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
                for await event in events {
                    guard session.isCurrentRunAttempt(ownership, expectedRunID: runID) else { return }
                    switch event {
                    case let .stream(result):
                        markPostPromptProviderEvent(session: session)
                        await hooks.handleHeadlessStreamResult(result, session, runID, runAttemptID)
                    case let .sessionState(state):
                        applySessionState(state, to: session)
                    case let .turnCompleted(_, status):
                        markPostPromptProviderEvent(session: session)
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
                    }
                }
            }

            _ = try await controller.sendUserMessage(initialMessageForRun)
            firstEventWatchdogTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: Self.firstProviderEventTimeoutNanoseconds)
                guard !Task.isCancelled,
                      !didReceivePostPromptProviderEvent,
                      !didCommitTerminal,
                      session.isCurrentRunAttempt(ownership, expectedRunID: runID)
                else { return }
                _ = await controller.interruptTurn(reason: "first provider event timeout")
                await commitTerminal(
                    .failed,
                    source: "pi.firstProviderEventTimeout",
                    errorText: "pi accepted the prompt but did not produce any response events within 60 seconds.",
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
        if session.piController === controller {
            session.piController = nil
        }
        if session.runID == runID {
            session.runID = nil
        }
        AgentModeProcessRunIdentity.clearProcessRunID(for: session)
        let windowID = windowID
        return {
            if terminalState == .cancelled {
                _ = await controller.interruptTurn(reason: "cancel")
            }
            await Self.cleanupManagedMCPRouting(windowID: windowID, runID: runID)
            await controller.shutdown()
        }
    }

    private func handleBlockingExtensionUIRequest(
        _ request: PiRPCClient.PiExtensionUIRequest,
        session: AgentModeViewModel.TabSession,
        controller: PiNativeSessionController
    ) async {
        guard let interaction = makeExtensionUIInteraction(from: request) else {
            await cancelExtensionUIRequest(request, controller: controller)
            return
        }

        do {
            let response = try await hooks.askUserInteraction(session.tabID, interaction)
            let rpcResponse = makeExtensionUIResponse(for: request, from: response)
            try await controller.respondToExtensionUIRequest(rpcResponse)
        } catch {
            await cancelExtensionUIRequest(request, controller: controller)
        }
    }

    private func cancelExtensionUIRequest(
        _ request: PiRPCClient.PiExtensionUIRequest,
        controller: PiNativeSessionController
    ) async {
        do {
            try await controller.respondToExtensionUIRequest(.cancelled(id: request.id))
        } catch {
            // The follow-up error will surface through the pi event stream or transport close.
        }
    }

    private func makeExtensionUIInteraction(
        from request: PiRPCClient.PiExtensionUIRequest
    ) -> AgentAskUserInteraction? {
        let timeoutSeconds = extensionUITimeoutSeconds(from: request)
        let context = extensionUIContext(from: request)
        let title = request.title?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? "pi Extension Request"

        switch request.method {
        case "select":
            let options = extensionUIOptions(from: request)
            guard !options.isEmpty else { return nil }
            return AgentAskUserInteraction(
                title: title,
                context: context,
                timeoutSeconds: timeoutSeconds,
                questions: [
                    AgentAskUserQuestion(
                        id: "value",
                        question: request.message?.nonEmpty ?? title,
                        options: options.map { AgentAskUserOption(label: $0) },
                        allowsMultiple: false,
                        allowsCustom: false
                    )
                ]
            )
        case "confirm":
            return AgentAskUserInteraction(
                title: title,
                context: context,
                timeoutSeconds: timeoutSeconds,
                questions: [
                    AgentAskUserQuestion(
                        id: "confirmed",
                        question: request.message?.nonEmpty ?? title,
                        options: [
                            AgentAskUserOption(label: "Yes"),
                            AgentAskUserOption(label: "No")
                        ],
                        allowsMultiple: false,
                        allowsCustom: false
                    )
                ]
            )
        case "input", "editor":
            let prompt = request.message?.nonEmpty ?? request.raw["placeholder"]?.stringValue?.nonEmpty ?? title
            return AgentAskUserInteraction(
                title: title,
                context: context,
                timeoutSeconds: timeoutSeconds,
                questions: [
                    AgentAskUserQuestion(
                        id: "value",
                        question: prompt,
                        context: extensionUIPrefillContext(from: request),
                        options: [],
                        allowsMultiple: false,
                        allowsCustom: true
                    )
                ]
            )
        default:
            return nil
        }
    }

    private func makeExtensionUIResponse(
        for request: PiRPCClient.PiExtensionUIRequest,
        from response: AgentAskUserResponse
    ) -> PiExtensionUIResponse {
        if response.timedOut || response.skipped {
            return .cancelled(id: request.id)
        }
        switch request.method {
        case "confirm":
            let answer = response.answersByQuestionID["confirmed"]?.answers.first?.lowercased()
            guard let answer else { return .cancelled(id: request.id) }
            return .confirmed(id: request.id, answer == "yes" || answer == "true" || answer == "allow")
        case "select", "input", "editor":
            guard let value = response.answersByQuestionID["value"]?.answers.first?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty
            else {
                return .cancelled(id: request.id)
            }
            return .value(id: request.id, value)
        default:
            return .cancelled(id: request.id)
        }
    }

    private func extensionUITimeoutSeconds(from request: PiRPCClient.PiExtensionUIRequest) -> TimeInterval {
        guard let timeoutMS = request.raw["timeout"]?.intValue, timeoutMS > 0 else {
            return ContextBuilderDefaults.questionTimeoutSeconds
        }
        return max(1, TimeInterval(timeoutMS) / 1000.0)
    }

    private func extensionUIOptions(from request: PiRPCClient.PiExtensionUIRequest) -> [String] {
        request.raw["options"]?.arrayValue?.compactMap { value in
            if let string = value.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !string.isEmpty {
                return string
            }
            if let object = value.objectValue {
                return object["label"]?.stringValue?.nonEmpty
                    ?? object["value"]?.stringValue?.nonEmpty
                    ?? object["title"]?.stringValue?.nonEmpty
            }
            return nil
        } ?? []
    }

    private func extensionUIContext(from request: PiRPCClient.PiExtensionUIRequest) -> String? {
        var lines: [String] = []
        if let message = request.message?.nonEmpty, message != request.title {
            lines.append(message)
        }
        if let statusText = request.statusText?.nonEmpty {
            lines.append(statusText)
        }
        lines.append("Requested by pi extension UI method: \(request.method).")
        return lines.joined(separator: "\n\n")
    }

    private func extensionUIPrefillContext(from request: PiRPCClient.PiExtensionUIRequest) -> String? {
        guard let prefill = request.raw["prefill"]?.stringValue?.nonEmpty else { return nil }
        return "Prefill from pi:\n\(prefill)"
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
        if let modelRaw = state.model.flatMap(AgentPiModelRegistry.rawModel) {
            session.selectedModelRaw = modelRaw
        }
        session.selectedReasoningEffortRaw = state.thinkingLevel
        session.isDirty = true
    }

    private func applySessionRef(_ ref: PiNativeSessionController.SessionRef, to session: AgentModeViewModel.TabSession) {
        session.providerSessionID = ref.sessionID
        session.piSessionFile = ref.sessionFile
        if let modelRaw = ref.model?.trimmingCharacters(in: .whitespacesAndNewlines), !modelRaw.isEmpty {
            session.selectedModelRaw = modelRaw
        }
        session.selectedReasoningEffortRaw = ref.thinkingLevel
        session.isDirty = true
    }
}

private extension String {
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
