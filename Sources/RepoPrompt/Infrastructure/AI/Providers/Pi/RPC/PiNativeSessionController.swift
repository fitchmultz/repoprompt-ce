import Foundation

actor PiNativeSessionController {
    enum TurnStatus: Equatable {
        case completed
        case cancelled
        case failed
    }

    enum InterruptOutcome: Equatable {
        case acknowledged
        case noTurnInFlight
        case failed
    }

    enum Event {
        case stream(AIStreamResult)
        case sessionState(PiRPCClient.SessionState)
        case turnCompleted(turnID: UUID, status: TurnStatus)
        case extensionUIRequest(PiRPCClient.PiExtensionUIRequest)
        case diagnostic(PiRPCClient.ProtocolDiagnostic)
        case error(String)
    }

    struct SessionRef: Equatable {
        var sessionID: String
        var sessionFile: String?
        var model: String?
        var thinkingLevel: String?
    }

    struct Options: Equatable {
        static let defaultPendingMessageStopRecoveryGraceInterval: TimeInterval = 45
        static let defaultTerminalCompletionGraceInterval: TimeInterval = 1

        var modelRaw: String?
        var requestTimeout: TimeInterval?
        var enableDebugLogging: Bool
        var launchArguments: [String]
        var environmentOverrides: [String: String]
        var pendingMessageStopRecoveryGraceInterval: TimeInterval
        var terminalCompletionGraceInterval: TimeInterval

        init(
            modelRaw: String? = nil,
            requestTimeout: TimeInterval? = 30,
            enableDebugLogging: Bool = false,
            launchArguments: [String] = PiIntegrationConfiguration.managedRPCLaunchArguments(launchPolicy: .defaultPolicy),
            environmentOverrides: [String: String] = PiIntegrationConfiguration.managedRunEnvironment(),
            pendingMessageStopRecoveryGraceInterval: TimeInterval = Self.defaultPendingMessageStopRecoveryGraceInterval,
            terminalCompletionGraceInterval: TimeInterval = Self.defaultTerminalCompletionGraceInterval
        ) {
            self.modelRaw = modelRaw
            self.requestTimeout = requestTimeout
            self.enableDebugLogging = enableDebugLogging
            self.launchArguments = launchArguments
            self.environmentOverrides = environmentOverrides
            self.pendingMessageStopRecoveryGraceInterval = pendingMessageStopRecoveryGraceInterval
            self.terminalCompletionGraceInterval = terminalCompletionGraceInterval
        }
    }

    enum ControllerError: Error, LocalizedError, Equatable {
        case sessionFileMissing
        case sessionSwitchCancelled(String)
        case modelProviderMissing(String)
        case unsupportedThinkingLevel(String)
        case processUnavailable(String)

        var errorDescription: String? {
            switch self {
            case .sessionFileMissing:
                "Cannot resume pi because the persisted pi session file is missing."
            case let .sessionSwitchCancelled(path):
                "pi cancelled switching to session \(path)."
            case let .modelProviderMissing(raw):
                "Cannot select pi model \(raw) because it does not include a provider prefix. Use provider/model, for example zai/glm-5.2."
            case let .unsupportedThinkingLevel(level):
                "Unsupported pi thinking level: \(level)."
            case let .processUnavailable(message):
                message
            }
        }
    }

    private let client: PiRPCClient
    private let workspacePath: String?
    private var options: Options
    private var eventForwardingTask: Task<Void, Never>?
    private var eventsStream: AsyncStream<Event>
    private var eventsContinuation: AsyncStream<Event>.Continuation?
    private var currentRef: SessionRef?
    private var pendingTurnIDs: [UUID] = []
    private var toolInvocationIDs: [String: UUID] = [:]
    private var pendingMessageStopUsage: PiUsage?
    private var pendingMessageStopReason: String?
    private var hasPendingMessageStop = false
    private enum PendingTurnRecovery {
        case messageStop
        case terminalCompletion(eventType: String, stateFailureCount: Int)
    }

    private static let terminalCompletionGetStateFailureLimit = 2

    private var pendingMessageStopRecoveryTask: Task<Void, Never>?
    private var pendingMessageStopRecoveryToken: UUID?
    private var pendingTurnRecovery: PendingTurnRecovery?
    private var autoRetryInProgress = false
    private var compactionInProgress = false
    private var didEmitMessageStopSinceAgentStart = false
    private var ignoringLateEventsAfterTerminalRecovery = false
    private var hasStartedForwarding = false
    private let recoverySleeper: @Sendable (TimeInterval) async -> Void

    init(
        client: PiRPCClient,
        options: Options = Options(),
        workspacePath: String? = nil,
        recoverySleeper: @escaping @Sendable (TimeInterval) async -> Void = PiNativeSessionController.defaultRecoverySleeper
    ) {
        self.client = client
        self.workspacePath = AgentPiModelRegistry.canonicalWorkspacePath(workspacePath)
        self.options = options
        self.recoverySleeper = recoverySleeper
        let stream = Self.makeEventsStream()
        eventsStream = stream.stream
        eventsContinuation = stream.continuation
    }

    init(
        workspacePath: String?,
        options: Options = Options(),
        recoverySleeper: @escaping @Sendable (TimeInterval) async -> Void = PiNativeSessionController.defaultRecoverySleeper
    ) {
        let client = PiRPCClient(config: .init(
            enableDebugLogging: options.enableDebugLogging,
            requestTimeout: options.requestTimeout,
            workingDirectory: workspacePath,
            launchArguments: options.launchArguments,
            environmentOverrides: options.environmentOverrides
        ))
        self.init(client: client, options: options, workspacePath: workspacePath, recoverySleeper: recoverySleeper)
    }

    var events: AsyncStream<Event> {
        eventsStream
    }

    var hasActiveSession: Bool {
        get async { await client.isRunning }
    }

    var hasTurnInFlight: Bool {
        !pendingTurnIDs.isEmpty
    }

    func ensureEventsStreamReady() async {
        guard eventsContinuation == nil else { return }
        let stream = Self.makeEventsStream()
        eventsStream = stream.stream
        eventsContinuation = stream.continuation
    }

    func resetEventsStreamForNewRun() async {
        eventsContinuation?.finish()
        let stream = Self.makeEventsStream()
        eventsStream = stream.stream
        eventsContinuation = stream.continuation
    }

    func startOrResume(
        existing: SessionRef?,
        model: String? = nil,
        thinkingLevel: String? = nil
    ) async throws -> SessionRef {
        await ensureEventsStreamReady()
        try await client.startIfNeeded()
        startForwardingEventsIfNeeded()

        if let sessionFile = normalized(existing?.sessionFile) {
            let result = try await client.switchSession(path: sessionFile)
            if result.cancelled {
                throw ControllerError.sessionSwitchCancelled(sessionFile)
            }
        } else if existing?.sessionID != nil {
            throw ControllerError.sessionFileMissing
        }

        try await applyModelAndThinking(model: model ?? options.modelRaw, thinkingLevel: thinkingLevel)
        let state = try await client.getState()
        await refreshModelRegistry(currentModel: state.model)
        let ref = SessionRef(
            sessionID: state.sessionID,
            sessionFile: state.sessionFile,
            model: state.model.map { modelDisplayRaw($0) },
            thinkingLevel: state.thinkingLevel
        )
        currentRef = ref
        emit(.sessionState(state))
        return ref
    }

    func currentSessionRef() async -> SessionRef? {
        currentRef
    }

    func setExpectedAgentPIDRegistration(clientName: String?, runID: UUID?) async {
        guard let clientName, let runID else {
            await client.clearExpectedAgentPIDRegistration()
            return
        }
        await client.setExpectedAgentPIDRegistration(.init(clientName: clientName, runID: runID))
    }

    func applyModelAndThinking(model: String?, thinkingLevel: String?) async throws {
        let knownModelIDs = await AgentPiModelRegistry.shared
            .resolvedSnapshotAfterWarmingStandardStore(workspacePath: workspacePath)?.knownModelIDs ?? []
        let specifier = PiModelSpecifier(raw: model, knownModelIDs: knownModelIDs)
        if let requestedModel = specifier?.modelID {
            guard let provider = specifier?.provider else {
                throw ControllerError.modelProviderMissing(model ?? requestedModel)
            }
            _ = try await client.setModel(provider: provider, modelID: requestedModel)
        }
        let requestedThinking = normalized(thinkingLevel) ?? specifier?.thinkingLevel
        if let requestedThinking {
            guard let level = PiThinkingLevel.parse(requestedThinking) else {
                throw ControllerError.unsupportedThinkingLevel(requestedThinking)
            }
            _ = try await client.setThinkingLevel(level.rawValue)
        }
    }

    @discardableResult
    func sendUserMessage(
        _ text: String,
        streamingBehavior: String? = nil,
        images: [PiRPCClient.ImageContent] = []
    ) async throws -> UUID {
        let turnID = registerPendingTurnBoundary()
        do {
            _ = try await client.prompt(text, streamingBehavior: streamingBehavior, images: images)
            return turnID
        } catch {
            emitPendingMessageStopIfNeeded(stopReasonOverride: "failed")
            completeTurn(turnID: turnID, status: .failed)
            throw error
        }
    }

    func steer(_ text: String, images: [PiRPCClient.ImageContent] = []) async throws {
        _ = try await client.steer(text, images: images)
    }

    func followUp(_ text: String, images: [PiRPCClient.ImageContent] = []) async throws {
        _ = try await client.followUp(text, images: images)
    }

    func interruptTurn(reason _: String) async -> InterruptOutcome {
        guard hasTurnInFlight else { return .noTurnInFlight }
        do {
            _ = try await client.abort()
            emitPendingMessageStopIfNeeded(stopReasonOverride: "cancelled")
            completeTurnIfNeeded(status: .cancelled)
            return .acknowledged
        } catch {
            emit(.error(error.localizedDescription))
            return .failed
        }
    }

    func shutdown() async {
        eventForwardingTask?.cancel()
        eventForwardingTask = nil
        hasStartedForwarding = false
        emitPendingMessageStopIfNeeded(stopReasonOverride: "cancelled")
        completeAllTurns(status: .cancelled)
        toolInvocationIDs.removeAll()
        clearPendingMessageStop()
        autoRetryInProgress = false
        compactionInProgress = false
        currentRef = nil
        await client.clearExpectedAgentPIDRegistration()
        await client.shutdown()
        eventsContinuation?.finish()
        eventsContinuation = nil
    }

    func respondToExtensionUIRequest(_ response: PiExtensionUIResponse) async throws {
        _ = try await client.respondToExtensionUIRequest(response)
    }

    private func refreshModelRegistry(currentModel: PiRPCClient.RemoteModel?) async {
        guard let remoteModels = try? await client.getAvailableModels(),
              let snapshot = AgentPiModelRegistry.discoveredModels(from: remoteModels, currentModel: currentModel)
        else {
            return
        }
        AgentPiModelRegistry.shared.updateDiscoveredModels(snapshot, workspacePath: workspacePath)
    }

    private func startForwardingEventsIfNeeded() {
        guard !hasStartedForwarding else { return }
        hasStartedForwarding = true
        eventForwardingTask = Task { [weak self, client] in
            let stream = await client.events
            for await event in stream {
                guard let self else { break }
                await handleClientEvent(event)
            }
        }
    }

    private func handleClientEvent(_ event: PiRPCClient.Event) async {
        if ignoreLateEventAfterTerminalRecoveryIfNeeded(event) {
            return
        }
        deferPendingTurnRecoveryAfterLivenessEvent(event)

        switch event {
        case .agentStart:
            compactionInProgress = false
            clearPendingMessageStop()
            didEmitMessageStopSinceAgentStart = false
        case .turnStart:
            emitPendingMessageStopIfNeeded(defaultStopReason: "end_turn")
        case let .messageUpdate(messageEvent):
            for streamResult in Self.streamResults(from: messageEvent) {
                emit(.stream(streamResult))
            }
        case let .toolExecutionStart(toolCallID, toolName, args):
            let invocationID = toolInvocationID(for: toolCallID)
            if let status = PiRunProgressPresentation.toolStartStatus(toolName: toolName, args: args) {
                emit(.stream(AIStreamResult(type: "status", text: status)))
            }
            emit(.stream(AIStreamResult(
                type: "tool_call",
                text: nil,
                toolName: toolName,
                toolArgs: Self.jsonString(from: .object(args)),
                toolOutput: nil,
                toolInvocationID: invocationID,
                toolArgsJSON: Self.jsonString(from: .object(args))
            )))
        case let .toolExecutionUpdate(toolCallID, toolName, partialResult):
            if let status = PiRunProgressPresentation.toolUpdateStatus(toolName: toolName, partialResult: partialResult) {
                emit(.stream(AIStreamResult(type: "status", text: status)))
            }
            guard let output = Self.toolOutputText(from: partialResult) else { return }
            emit(.stream(AIStreamResult(
                type: "tool_result",
                text: nil,
                toolName: toolName,
                toolOutput: output,
                toolInvocationID: toolInvocationID(for: toolCallID),
                toolResultJSON: Self.toolResultJSON(from: partialResult)
            )))
        case let .toolExecutionEnd(toolCallID, toolName, result, isError):
            let invocationID = toolInvocationID(for: toolCallID)
            if let status = PiRunProgressPresentation.toolEndStatus(toolName: toolName, result: result, isError: isError) {
                emit(.stream(AIStreamResult(type: "status", text: status)))
            }
            emit(.stream(AIStreamResult(
                type: "tool_result",
                text: nil,
                toolName: toolName,
                toolOutput: Self.toolOutputText(from: result),
                toolInvocationID: invocationID,
                toolResultJSON: Self.toolResultJSON(from: result),
                toolIsError: isError
            )))
            toolInvocationIDs.removeValue(forKey: toolCallID)
        case let .turnEnd(message, _):
            if let usage = Self.usage(from: message) {
                recordUsage(usage)
            }
            hasPendingMessageStop = true
            pendingMessageStopReason = "end_turn"
            schedulePendingMessageStopRecovery()
        case let .agentEnd(messages, willRetry):
            if willRetry {
                clearPendingMessageStop()
                emit(.stream(AIStreamResult(type: "status", text: "pi is retrying the turn")))
                return
            }
            if hasPendingMessageStop || !didEmitMessageStopSinceAgentStart {
                if let usage = Self.latestUsage(from: messages) {
                    recordUsage(usage)
                }
                if !autoRetryInProgress, hasPendingMessageStop || hasTurnInFlight {
                    emitMessageStop(stopReason: pendingMessageStopReason ?? "completed")
                }
            } else {
                clearPendingMessageStop()
            }
            if hasTurnInFlight {
                await completeTurnIfPiReportsIdle(eventType: "agent_end")
            }
        case let .extensionUIRequest(request):
            emit(.extensionUIRequest(request))
        case let .extensionError(message):
            emit(.error(message))
        case let .customMessage(message):
            if let status = PiRunProgressPresentation.customMessageStatus(message) {
                emit(.stream(AIStreamResult(type: "status", text: status)))
            }
        case let .autoRetryStart(attempt, maxAttempts, delayMs, errorMessage):
            autoRetryInProgress = true
            clearPendingMessageStop()
            emit(.stream(AIStreamResult(
                type: "status",
                text: Self.autoRetryStartStatus(
                    attempt: attempt,
                    maxAttempts: maxAttempts,
                    delayMs: delayMs,
                    errorMessage: errorMessage
                )
            )))
        case let .autoRetryEnd(success, attempt, finalError):
            autoRetryInProgress = false
            if success {
                emit(.stream(AIStreamResult(type: "status", text: "pi retry attempt \(attempt) resumed the turn")))
            } else {
                emit(.stream(AIStreamResult(
                    type: "status",
                    text: finalError.map { "pi retry attempt \(attempt) failed: \($0)" } ?? "pi retry attempt \(attempt) failed"
                )))
                emitPendingMessageStopIfNeeded(stopReasonOverride: "failed")
                if hasTurnInFlight {
                    completeTurnIfNeeded(status: .failed)
                }
            }
        case let .compactionStart(reason):
            compactionInProgress = true
            emit(.stream(AIStreamResult(
                type: "status",
                text: reason.map { "pi is compacting context (\($0))" } ?? "pi is compacting context"
            )))
        case let .compactionEnd(_, _, _, willRetry, errorMessage):
            compactionInProgress = false
            if willRetry {
                emit(.stream(AIStreamResult(
                    type: "status",
                    text: errorMessage.map { "pi compaction will retry after error: \($0)" } ?? "pi compaction will retry"
                )))
            } else if hasTurnInFlight {
                await completeTurnIfPiReportsIdle(eventType: "compaction_end")
            }
        case .sessionInfoChanged, .thinkingLevelChanged:
            await refreshCurrentSessionState()
        case let .messageEnd(message):
            if let usage = Self.usage(from: message) {
                recordUsage(usage)
            }
        case let .protocolDiagnostic(diagnostic):
            emit(.diagnostic(diagnostic))
        case let .transportClosed(reason):
            if hasTurnInFlight {
                emitPendingMessageStopIfNeeded(stopReasonOverride: "failed")
                completeAllTurns(status: .failed)
            }
            emit(.error(reason))
        case .messageStart, .queueUpdate, .unhandled:
            break
        }
    }

    private func ignoreLateEventAfterTerminalRecoveryIfNeeded(_ event: PiRPCClient.Event) -> Bool {
        guard ignoringLateEventsAfterTerminalRecovery,
              event.isLifecycleOrActivityEvent
        else { return false }
        emit(.diagnostic(.init(
            kind: .lateEventAfterTerminalRecovery,
            eventType: event.protocolType,
            message: "Ignoring pi \(event.protocolType) received after pending-stop grace recovery already completed the turn.",
            payloadPreview: nil,
            occurrence: 1
        )))
        return true
    }

    private func deferPendingTurnRecoveryAfterLivenessEvent(_ event: PiRPCClient.Event) {
        guard pendingMessageStopRecoveryToken != nil,
              event.defersPendingMessageStopRecovery
        else { return }
        switch pendingTurnRecovery {
        case .messageStop where hasPendingMessageStop:
            schedulePendingMessageStopRecovery()
        case .terminalCompletion:
            cancelPendingMessageStopRecovery()
        case .messageStop, .none:
            return
        }
    }

    private static func autoRetryStartStatus(
        attempt: Int,
        maxAttempts: Int,
        delayMs: Int,
        errorMessage: String
    ) -> String {
        let retryPrefix = if attempt > 0, maxAttempts > 0 {
            "pi is retrying the turn (attempt \(attempt)/\(maxAttempts))"
        } else if attempt > 0 {
            "pi is retrying the turn (attempt \(attempt))"
        } else {
            "pi is retrying the turn"
        }
        let delayText = delayMs > 0 ? " after \(delayMs) ms" : ""
        return "\(retryPrefix)\(delayText): \(errorMessage)"
    }

    private func toolInvocationID(for toolCallID: String) -> UUID {
        if let existing = toolInvocationIDs[toolCallID] {
            return existing
        }
        let invocationID = UUID()
        toolInvocationIDs[toolCallID] = invocationID
        return invocationID
    }

    @discardableResult
    private func refreshCurrentSessionState() async -> Bool {
        do {
            let state = try await client.getState()
            applySessionState(state)
            return true
        } catch {
            return false
        }
    }

    private func emitIdleSessionStateForTerminalCompletionFallback(eventType: String) {
        guard let currentRef else { return }
        emit(.sessionState(PiRPCClient.SessionState(
            sessionID: currentRef.sessionID,
            sessionFile: currentRef.sessionFile,
            sessionName: nil,
            thinkingLevel: currentRef.thinkingLevel,
            isStreaming: false,
            isCompacting: false,
            messageCount: nil,
            pendingMessageCount: 0,
            model: nil
        )))
        emit(.diagnostic(.init(
            kind: .pendingMessageStopRecovery,
            eventType: eventType,
            message: "pi \(eventType) was received, but get_state failed after bounded recovery; emitted an idle fallback session state so terminal completion is not suppressed by stale pending messages.",
            payloadPreview: nil,
            occurrence: 1
        )))
    }

    private func applySessionState(_ state: PiRPCClient.SessionState) {
        currentRef = SessionRef(
            sessionID: state.sessionID,
            sessionFile: state.sessionFile,
            model: state.model.map { modelDisplayRaw($0) },
            thinkingLevel: state.thinkingLevel
        )
        emit(.sessionState(state))
    }

    private func registerPendingTurnBoundary() -> UUID {
        let turnID = UUID()
        ignoringLateEventsAfterTerminalRecovery = false
        autoRetryInProgress = false
        compactionInProgress = false
        pendingTurnIDs.append(turnID)
        return turnID
    }

    private func completeTurnIfPiReportsIdle(eventType: String) async {
        guard hasTurnInFlight else { return }
        if compactionInProgress {
            return
        }

        do {
            let state = try await client.getState()
            guard hasTurnInFlight else { return }
            applySessionState(state)
            if state.isStreaming || state.isCompacting || (state.pendingMessageCount ?? 0) > 0 {
                emit(.diagnostic(.init(
                    kind: .pendingMessageStopRecovery,
                    eventType: eventType,
                    message: "pi \(eventType) was received, but get_state still reports streaming, compaction, or pending queued messages; waiting for the true final agent_end before completing.",
                    payloadPreview: nil,
                    occurrence: 1
                )))
                return
            }
        } catch {
            guard hasTurnInFlight else { return }
            emit(.diagnostic(.init(
                kind: .pendingMessageStopRecovery,
                eventType: eventType,
                message: "pi \(eventType) was received, but get_state could not confirm pi is idle; scheduling bounded terminal completion recovery.",
                payloadPreview: String(describing: error),
                occurrence: 1
            )))
            scheduleTerminalCompletionRecovery(eventType: eventType, stateFailureCount: 1)
            return
        }

        // Installed pi get_state exposes model, thinkingLevel, isStreaming,
        // isCompacting, steeringMode, followUpMode, sessionFile, sessionId,
        // sessionName, autoCompactionEnabled, messageCount, and
        // pendingMessageCount. pendingMessageCount is only the UI steering and
        // follow-up arrays; extension pi.sendMessage continuations queued while
        // streaming live in agent-core queues that get_state does not expose.
        // Therefore an idle get_state is necessary but not sufficient. The pi
        // RPC prompt response is only a preflight acknowledgement, not a drained
        // run-completion signal, so use a bounded recovery timer plus a final
        // get_state recheck to avoid hanging forever while still leaving room
        // for post-agent_end continuation events to arrive.
        scheduleTerminalCompletionRecovery(eventType: eventType, stateFailureCount: 0)
    }

    private func terminalizeTurnAfterPiTerminalSignal(eventType: String, usedStateFailureFallback: Bool) {
        guard hasTurnInFlight else { return }
        if usedStateFailureFallback {
            emitIdleSessionStateForTerminalCompletionFallback(eventType: eventType)
        }
        if autoRetryInProgress {
            autoRetryInProgress = false
            emitPendingMessageStopIfNeeded(stopReasonOverride: "failed")
            completeTurnIfNeeded(status: .failed)
        } else {
            completeTurnIfNeeded(status: .completed)
        }
    }

    private func completeTurnIfNeeded(status: TurnStatus) {
        guard !pendingTurnIDs.isEmpty else { return }
        cancelPendingMessageStopRecovery()
        let turnID = pendingTurnIDs.removeFirst()
        emit(.turnCompleted(turnID: turnID, status: status))
    }

    private func completeTurn(turnID: UUID, status: TurnStatus) {
        guard let index = pendingTurnIDs.firstIndex(of: turnID) else { return }
        cancelPendingMessageStopRecovery()
        pendingTurnIDs.remove(at: index)
        emit(.turnCompleted(turnID: turnID, status: status))
    }

    private func completeAllTurns(status: TurnStatus) {
        while !pendingTurnIDs.isEmpty {
            completeTurnIfNeeded(status: status)
        }
    }

    private func recordUsage(_ usage: PiUsage) {
        pendingMessageStopUsage = usage
    }

    private func emitPendingMessageStopIfNeeded(defaultStopReason: String) {
        emitPendingMessageStopIfNeeded(stopReasonOverride: nil, defaultStopReason: defaultStopReason)
    }

    private func emitPendingMessageStopIfNeeded(stopReasonOverride: String) {
        emitPendingMessageStopIfNeeded(stopReasonOverride: stopReasonOverride, defaultStopReason: nil)
    }

    private func emitPendingMessageStopIfNeeded(stopReasonOverride: String?, defaultStopReason: String?) {
        guard hasPendingMessageStop else { return }
        emitMessageStop(stopReason: stopReasonOverride ?? pendingMessageStopReason ?? defaultStopReason ?? "completed")
    }

    private func schedulePendingMessageStopRecovery() {
        cancelPendingMessageStopRecovery()
        let token = UUID()
        pendingMessageStopRecoveryToken = token
        pendingTurnRecovery = .messageStop
        let graceInterval = max(0, options.pendingMessageStopRecoveryGraceInterval)
        let recoverySleeper = recoverySleeper
        pendingMessageStopRecoveryTask = Task { [weak self] in
            await recoverySleeper(graceInterval)
            guard !Task.isCancelled else { return }
            await self?.recoverPendingMessageStopIfStillPending(token: token, graceInterval: graceInterval)
        }
    }

    private func scheduleTerminalCompletionRecovery(eventType: String, stateFailureCount: Int) {
        cancelPendingMessageStopRecovery()
        let token = UUID()
        pendingMessageStopRecoveryToken = token
        pendingTurnRecovery = .terminalCompletion(eventType: eventType, stateFailureCount: stateFailureCount)
        let graceInterval = max(0, options.terminalCompletionGraceInterval)
        let recoverySleeper = recoverySleeper
        pendingMessageStopRecoveryTask = Task { [weak self] in
            await recoverySleeper(graceInterval)
            guard !Task.isCancelled else { return }
            await self?.recoverTerminalCompletionIfStillPending(
                token: token,
                eventType: eventType,
                stateFailureCount: stateFailureCount
            )
        }
    }

    private static let defaultRecoverySleeper: @Sendable (TimeInterval) async -> Void = { graceInterval in
        let nanoseconds = UInt64(min(graceInterval, TimeInterval(UInt64.max) / 1_000_000_000) * 1_000_000_000)
        if nanoseconds > 0 {
            try? await Task.sleep(nanoseconds: nanoseconds)
        }
    }

    private func recoverTerminalCompletionIfStillPending(
        token: UUID,
        eventType: String,
        stateFailureCount: Int
    ) async {
        guard pendingMessageStopRecoveryToken == token,
              hasTurnInFlight
        else { return }
        if compactionInProgress {
            emit(.diagnostic(.init(
                kind: .pendingMessageStopRecovery,
                eventType: eventType,
                message: "pi \(eventType) terminal completion grace expired, but compaction started; waiting for compaction_end before completing.",
                payloadPreview: nil,
                occurrence: 1
            )))
            cancelPendingMessageStopRecovery()
            return
        }

        do {
            let state = try await client.getState()
            guard pendingMessageStopRecoveryToken == token,
                  hasTurnInFlight
            else { return }
            applySessionState(state)
            if state.isStreaming || state.isCompacting || (state.pendingMessageCount ?? 0) > 0 {
                emit(.diagnostic(.init(
                    kind: .pendingMessageStopRecovery,
                    eventType: eventType,
                    message: "pi \(eventType) terminal completion grace expired, but get_state still reports streaming, compaction, or pending queued messages; waiting for the true final agent_end before completing.",
                    payloadPreview: nil,
                    occurrence: 1
                )))
                cancelPendingMessageStopRecovery()
                return
            }
            terminalizeTurnAfterPiTerminalSignal(eventType: eventType, usedStateFailureFallback: false)
        } catch {
            guard pendingMessageStopRecoveryToken == token,
                  hasTurnInFlight
            else { return }
            let nextFailureCount = stateFailureCount + 1
            if nextFailureCount < Self.terminalCompletionGetStateFailureLimit {
                emit(.diagnostic(.init(
                    kind: .pendingMessageStopRecovery,
                    eventType: eventType,
                    message: "pi \(eventType) terminal completion grace expired, but get_state still failed; retrying once before bounded fallback.",
                    payloadPreview: String(describing: error),
                    occurrence: 1
                )))
                scheduleTerminalCompletionRecovery(eventType: eventType, stateFailureCount: nextFailureCount)
                return
            }
            emit(.diagnostic(.init(
                kind: .pendingMessageStopRecovery,
                eventType: eventType,
                message: "pi \(eventType) terminal completion grace expired and get_state failed after bounded retries; completing from the pi terminal event to avoid a stuck turn.",
                payloadPreview: String(describing: error),
                occurrence: 1
            )))
            terminalizeTurnAfterPiTerminalSignal(eventType: eventType, usedStateFailureFallback: true)
        }
    }

    private func recoverPendingMessageStopIfStillPending(token: UUID, graceInterval: TimeInterval) async {
        guard pendingMessageStopRecoveryToken == token,
              hasPendingMessageStop,
              hasTurnInFlight
        else { return }

        do {
            let state = try await client.getState()
            guard pendingMessageStopRecoveryToken == token,
                  hasPendingMessageStop,
                  hasTurnInFlight
            else { return }
            applySessionState(state)
            if state.isStreaming || state.isCompacting || (state.pendingMessageCount ?? 0) > 0 {
                emit(.diagnostic(.init(
                    kind: .pendingMessageStopRecovery,
                    eventType: "turn_end",
                    message: "pi turn_end was not followed by agent_end, turn_start, or retry within \(Self.formatGraceInterval(graceInterval)), but get_state still reports activity; deferring pending message_stop recovery.",
                    payloadPreview: nil,
                    occurrence: 1
                )))
                schedulePendingMessageStopRecovery()
                return
            }
        } catch {
            guard pendingMessageStopRecoveryToken == token,
                  hasPendingMessageStop,
                  hasTurnInFlight
            else { return }
            emit(.diagnostic(.init(
                kind: .pendingMessageStopRecovery,
                eventType: "turn_end",
                message: "pi turn_end was not followed by agent_end, turn_start, or retry within \(Self.formatGraceInterval(graceInterval)), and get_state could not confirm pi is idle; completing failed instead of marking a possibly retrying turn completed.",
                payloadPreview: String(describing: error),
                occurrence: 1
            )))
            emitPendingMessageStopIfNeeded(stopReasonOverride: "failed")
            completeTurnIfNeeded(status: .failed)
            ignoringLateEventsAfterTerminalRecovery = true
            return
        }

        // Grace recovery is only a dead-stream fallback: first verify pi still
        // reports idle so a slow auto-retry cannot be committed as success.
        emit(.diagnostic(.init(
            kind: .pendingMessageStopRecovery,
            eventType: "turn_end",
            message: "pi turn_end was not followed by agent_end, turn_start, or retry within \(Self.formatGraceInterval(graceInterval)); get_state reports idle, completing with deferred message_stop.",
            payloadPreview: nil,
            occurrence: 1
        )))
        emitMessageStop(stopReason: pendingMessageStopReason ?? "end_turn")
        completeTurnIfNeeded(status: .completed)
        ignoringLateEventsAfterTerminalRecovery = true
    }

    private static func formatGraceInterval(_ interval: TimeInterval) -> String {
        if interval.rounded() == interval {
            return "\(Int(interval))s"
        }
        return "\(interval)s"
    }

    private func cancelPendingMessageStopRecovery() {
        pendingMessageStopRecoveryTask?.cancel()
        pendingMessageStopRecoveryTask = nil
        pendingMessageStopRecoveryToken = nil
        pendingTurnRecovery = nil
    }

    private func emitMessageStop(stopReason: String) {
        let usage = pendingMessageStopUsage
        if let usage {
            emit(.stream(usage.streamResult(type: "usage", stopReason: nil)))
        }
        emit(.stream(usage?.streamResult(
            type: "message_stop",
            stopReason: stopReason
        ) ?? AIStreamResult(
            type: "message_stop",
            text: nil,
            stopReason: stopReason
        )))
        didEmitMessageStopSinceAgentStart = true
        clearPendingMessageStop()
    }

    private func clearPendingMessageStop() {
        cancelPendingMessageStopRecovery()
        pendingMessageStopUsage = nil
        pendingMessageStopReason = nil
        hasPendingMessageStop = false
    }

    private func emit(_ event: Event) {
        _ = eventsContinuation?.yield(event)
    }

    private static func makeEventsStream() -> (stream: AsyncStream<Event>, continuation: AsyncStream<Event>.Continuation) {
        var captured: AsyncStream<Event>.Continuation?
        let stream = AsyncStream<Event>(bufferingPolicy: .unbounded) { continuation in
            captured = continuation
        }
        guard let captured else {
            fatalError("PiNativeSessionController failed to create event stream")
        }
        return (stream, captured)
    }
}
