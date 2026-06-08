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
        case error(String)
    }

    struct SessionRef: Equatable {
        var sessionID: String
        var sessionFile: String?
        var model: String?
        var thinkingLevel: String?
    }

    struct Options: Equatable {
        var modelRaw: String?
        var requestTimeout: TimeInterval?
        var enableDebugLogging: Bool
        var launchArguments: [String]

        init(
            modelRaw: String? = nil,
            requestTimeout: TimeInterval? = 30,
            enableDebugLogging: Bool = false,
            launchArguments: [String] = ["--mode", "rpc"]
        ) {
            self.modelRaw = modelRaw
            self.requestTimeout = requestTimeout
            self.enableDebugLogging = enableDebugLogging
            self.launchArguments = launchArguments
        }
    }

    enum ControllerError: Error, LocalizedError, Equatable {
        case sessionFileMissing
        case modelProviderMissing(String)
        case processUnavailable(String)

        var errorDescription: String? {
            switch self {
            case .sessionFileMissing:
                "Cannot resume pi because the persisted pi session file is missing."
            case let .modelProviderMissing(raw):
                "Cannot select pi model \(raw) because it does not include a provider prefix. Use provider/model, for example zai/glm-5.1."
            case let .processUnavailable(message):
                message
            }
        }
    }

    private let client: PiRPCClient
    private var options: Options
    private var eventForwardingTask: Task<Void, Never>?
    private var eventsStream: AsyncStream<Event>
    private var eventsContinuation: AsyncStream<Event>.Continuation?
    private var currentRef: SessionRef?
    private var pendingTurnIDs: [UUID] = []
    private var hasStartedForwarding = false

    init(
        client: PiRPCClient,
        options: Options = Options()
    ) {
        self.client = client
        self.options = options
        let stream = Self.makeEventsStream()
        eventsStream = stream.stream
        eventsContinuation = stream.continuation
    }

    convenience init(
        workspacePath: String?,
        options: Options = Options()
    ) {
        let client = PiRPCClient(config: .init(
            enableDebugLogging: options.enableDebugLogging,
            requestTimeout: options.requestTimeout,
            workingDirectory: workspacePath,
            launchArguments: options.launchArguments
        ))
        self.init(client: client, options: options)
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
            _ = try await client.switchSession(path: sessionFile)
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
        let specifier = PiModelSpecifier(raw: model)
        if let requestedModel = specifier?.modelID {
            guard let provider = specifier?.provider else {
                throw ControllerError.modelProviderMissing(model ?? requestedModel)
            }
            _ = try await client.setModel(provider: provider, modelID: requestedModel)
        }
        let requestedThinking = normalized(thinkingLevel) ?? specifier?.thinkingLevel
        if let requestedThinking {
            _ = try await client.setThinkingLevel(requestedThinking)
        }
    }

    @discardableResult
    func sendUserMessage(_ text: String, streamingBehavior: String? = nil) async throws -> UUID {
        let turnID = UUID()
        pendingTurnIDs.append(turnID)
        do {
            _ = try await client.prompt(text, streamingBehavior: streamingBehavior)
            return turnID
        } catch {
            completeTurnIfNeeded(status: .failed)
            throw error
        }
    }

    func steer(_ text: String) async throws {
        _ = try await client.steer(text)
    }

    func followUp(_ text: String) async throws {
        _ = try await client.followUp(text)
    }

    func interruptTurn(reason _: String) async -> InterruptOutcome {
        guard hasTurnInFlight else { return .noTurnInFlight }
        do {
            _ = try await client.abort()
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
        pendingTurnIDs.removeAll()
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
        AgentPiModelRegistry.shared.updateDiscoveredModels(snapshot)
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
        switch event {
        case .agentStart, .turnStart:
            break
        case let .messageUpdate(messageEvent):
            for streamResult in Self.streamResults(from: messageEvent) {
                emit(.stream(streamResult))
            }
        case let .toolExecutionStart(_, toolName, args):
            emit(.stream(AIStreamResult(
                type: "tool_call",
                text: nil,
                toolName: toolName,
                toolArgs: Self.jsonString(from: .object(args)),
                toolArgsJSON: Self.jsonString(from: .object(args))
            )))
        case let .toolExecutionUpdate(_, toolName, partialResult):
            guard let output = Self.toolOutputText(from: partialResult) else { return }
            emit(.stream(AIStreamResult(
                type: "tool_result",
                text: nil,
                toolName: toolName,
                toolOutput: output,
                toolResultJSON: Self.toolResultJSON(from: partialResult)
            )))
        case let .toolExecutionEnd(_, toolName, result, isError):
            emit(.stream(AIStreamResult(
                type: "tool_result",
                text: nil,
                toolName: toolName,
                toolOutput: Self.toolOutputText(from: result),
                toolResultJSON: Self.toolResultJSON(from: result),
                toolIsError: isError
            )))
        case .turnEnd:
            emit(.stream(AIStreamResult(type: "message_stop", text: nil, stopReason: "end_turn")))
        case .agentEnd:
            if hasTurnInFlight {
                completeTurnIfNeeded(status: .completed)
            }
        case let .extensionUIRequest(request):
            emit(.extensionUIRequest(request))
        case let .extensionError(message):
            emit(.error(message))
        case let .transportClosed(reason):
            if hasTurnInFlight {
                completeTurnIfNeeded(status: .failed)
            }
            emit(.error(reason))
        case .messageStart, .messageEnd, .queueUpdate, .compactionStart, .compactionEnd, .unhandled:
            break
        }
    }

    private func completeTurnIfNeeded(status: TurnStatus) {
        guard !pendingTurnIDs.isEmpty else { return }
        let turnID = pendingTurnIDs.removeFirst()
        emit(.turnCompleted(turnID: turnID, status: status))
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

    private static func streamResults(from event: PiRPCClient.PiAssistantMessageEvent) -> [AIStreamResult] {
        switch event.type {
        case "text_delta":
            guard let delta = event.delta, !delta.isEmpty else { return [] }
            return [AIStreamResult(type: "content", text: delta)]
        case "thinking_delta":
            guard let delta = event.delta, !delta.isEmpty else { return [] }
            return [AIStreamResult(type: "content", text: nil, reasoning: delta)]
        case "done":
            return [AIStreamResult(type: "message_stop", text: nil, stopReason: event.reason)]
        case "error":
            return [AIStreamResult(type: "error", text: event.reason ?? "pi message stream failed")]
        default:
            return []
        }
    }

    private static func toolOutputText(from value: PiJSONValue?) -> String? {
        guard let value else { return nil }
        if let text = value.stringValue {
            return text
        }
        if let text = value.objectValue?["text"]?.stringValue {
            return text
        }
        if let content = value.objectValue?["content"]?.arrayValue {
            let parts = content.compactMap { entry -> String? in
                guard let object = entry.objectValue else { return nil }
                return object["text"]?.stringValue
            }
            if !parts.isEmpty {
                return parts.joined(separator: "\n")
            }
        }
        return jsonString(from: value)
    }

    private static func toolResultJSON(from value: PiJSONValue?) -> String? {
        guard let value else { return nil }
        if let bridgePayload = bridgeToolResultPayload(from: value) {
            return bridgePayload
        }
        return jsonString(from: value)
    }

    private static func bridgeToolResultPayload(from value: PiJSONValue) -> String? {
        guard let object = value.objectValue,
              let details = object["details"]?.objectValue,
              details["bridgeVersion"]?.stringValue != nil,
              let output = toolOutputText(from: value)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !output.isEmpty,
              let data = output.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data)) != nil
        else { return nil }
        return output
    }

    private static func jsonString(from value: PiJSONValue) -> String? {
        guard JSONSerialization.isValidJSONObject(value.toAny()),
              let data = try? JSONSerialization.data(withJSONObject: value.toAny(), options: [.sortedKeys])
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func modelDisplayRaw(_ model: PiRPCClient.RemoteModel) -> String {
        if let provider = normalized(model.provider) {
            return "\(provider)/\(model.id)"
        }
        return model.id
    }

    private func normalized(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else { return nil }
        guard trimmed.caseInsensitiveCompare(AgentModel.defaultModel.rawValue) != .orderedSame else { return nil }
        return trimmed
    }
}

struct PiModelSpecifier: Equatable {
    let provider: String?
    let modelID: String
    let thinkingLevel: String?

    init(provider: String?, modelID: String, thinkingLevel: String?) {
        self.provider = provider
        self.modelID = modelID
        self.thinkingLevel = thinkingLevel
    }

    init?(raw: String?) {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty,
              trimmed.caseInsensitiveCompare(AgentModel.defaultModel.rawValue) != .orderedSame
        else { return nil }

        let providerSplit = trimmed.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        let provider: String?
        let modelAndThinking: Substring
        if providerSplit.count == 2 {
            let rawProvider = providerSplit[0].trimmingCharacters(in: .whitespacesAndNewlines)
            provider = rawProvider.isEmpty ? nil : rawProvider
            modelAndThinking = providerSplit[1]
        } else {
            provider = nil
            modelAndThinking = providerSplit[0]
        }

        let thinkingSplit = modelAndThinking.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let modelID = thinkingSplit[0].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !modelID.isEmpty else { return nil }
        let thinkingLevel: String? = if thinkingSplit.count == 2 {
            thinkingSplit[1].trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        } else {
            nil
        }

        self.provider = provider
        self.modelID = modelID
        self.thinkingLevel = thinkingLevel
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
