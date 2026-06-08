import Darwin
import Foundation

actor PiRPCClient {
    struct Config: Equatable {
        var commandName: String
        var additionalPathHints: [String]
        var enableDebugLogging: Bool
        var requestTimeout: TimeInterval?
        var workingDirectory: String?
        var launchArguments: [String]

        init(
            commandName: String = CLILaunchProfiles.pi.commandName,
            additionalPathHints: [String] = CLILaunchProfiles.pi.supplementalSearchPaths,
            enableDebugLogging: Bool = false,
            requestTimeout: TimeInterval? = 30,
            workingDirectory: String? = nil,
            launchArguments: [String] = ["--mode", "rpc"]
        ) {
            self.commandName = commandName
            self.additionalPathHints = additionalPathHints
            self.enableDebugLogging = enableDebugLogging
            self.requestTimeout = requestTimeout
            self.workingDirectory = workingDirectory
            self.launchArguments = launchArguments
        }
    }

    struct SessionState: Equatable {
        var sessionID: String
        var sessionFile: String?
        var sessionName: String?
        var thinkingLevel: String?
        var isStreaming: Bool
        var isCompacting: Bool
        var messageCount: Int?
        var pendingMessageCount: Int?
        var model: RemoteModel?
    }

    struct RemoteModel: Hashable {
        var provider: String?
        var id: String
        var displayName: String
        var description: String?
        var raw: [String: PiJSONValue]
    }

    enum Event: Equatable {
        case agentStart
        case agentEnd(messages: [[String: PiJSONValue]])
        case turnStart
        case turnEnd(message: [String: PiJSONValue]?, toolResults: [[String: PiJSONValue]])
        case messageStart(message: [String: PiJSONValue]?)
        case messageUpdate(PiAssistantMessageEvent)
        case messageEnd(message: [String: PiJSONValue]?)
        case toolExecutionStart(toolCallID: String, toolName: String, args: [String: PiJSONValue])
        case toolExecutionUpdate(toolCallID: String, toolName: String, partialResult: PiJSONValue?)
        case toolExecutionEnd(toolCallID: String, toolName: String, result: PiJSONValue?, isError: Bool)
        case queueUpdate(steering: [String], followUp: [String])
        case compactionStart(reason: String?)
        case compactionEnd(result: PiJSONValue?)
        case extensionUIRequest(PiExtensionUIRequest)
        case extensionError(String)
        case transportClosed(reason: String)
        case unhandled(type: String, payload: [String: PiJSONValue])
    }

    struct PiAssistantMessageEvent: Equatable {
        var type: String
        var contentIndex: Int?
        var delta: String?
        var content: String?
        var reason: String?
        var toolCall: PiJSONValue?
        var partial: PiJSONValue?
        var raw: [String: PiJSONValue]
    }

    struct PiExtensionUIRequest: Equatable {
        var id: String
        var method: String
        var title: String?
        var message: String?
        var statusKey: String?
        var statusText: String?
        var raw: [String: PiJSONValue]

        var requiresResponse: Bool {
            switch method {
            case "select", "confirm", "input", "editor": true
            default: false
            }
        }
    }

    enum ClientError: Error, LocalizedError, Equatable {
        case processNotRunning
        case executableUnavailable(String)
        case invalidResponse(String)
        case requestFailed(String)
        case requestTimedOut(id: String, command: String)
        case inputWriteFailed(String)
        case transportClosed(String)
        case readerSetupFailed(String)

        var errorDescription: String? {
            switch self {
            case .processNotRunning:
                "pi RPC process is not running."
            case let .executableUnavailable(message):
                message
            case let .invalidResponse(message):
                message
            case let .requestFailed(message):
                message
            case let .requestTimedOut(_, command):
                "Timed out waiting for pi RPC response to \(command)."
            case let .inputWriteFailed(message):
                "Failed writing to pi RPC stdin: \(message)"
            case let .transportClosed(message):
                message
            case let .readerSetupFailed(message):
                message
            }
        }
    }

    private struct PendingRequest {
        let command: String
        let continuation: CheckedContinuation<[String: PiJSONValue], Error>
    }

    private var config: Config
    private var process: SpawnedProcess?
    private var stdoutFramer = LineFramer()
    private var stdoutChunkChannel: FileHandleChunkChannel?
    private var stderrChunkChannel: FileHandleChunkChannel?
    private var stdoutConsumerTask: Task<Void, Never>?
    private var stderrConsumerTask: Task<Void, Never>?
    private var stderrTail = Data()
    private var pendingRequests: [String: PendingRequest] = [:]
    private var timeoutTasks: [String: Task<Void, Never>] = [:]
    private var nextRequestNumber = 1
    private var eventsStream: AsyncStream<Event>
    private var eventsContinuation: AsyncStream<Event>.Continuation?
    private var isShuttingDown = false

    init(config: Config = Config()) {
        self.config = config
        let stream = Self.makeEventsStream()
        eventsStream = stream.stream
        eventsContinuation = stream.continuation
    }

    var events: AsyncStream<Event> {
        eventsStream
    }

    var isRunning: Bool {
        process != nil
    }

    func updateConfig(_ config: Config) {
        self.config = config
    }

    func ensureEventsStreamReady() {
        guard eventsContinuation == nil else { return }
        let stream = Self.makeEventsStream()
        eventsStream = stream.stream
        eventsContinuation = stream.continuation
    }

    func resetEventsStreamForNewRun() {
        eventsContinuation?.finish()
        let stream = Self.makeEventsStream()
        eventsStream = stream.stream
        eventsContinuation = stream.continuation
    }

    func startIfNeeded() async throws {
        guard process == nil else { return }
        ensureEventsStreamReady()
        isShuttingDown = false
        let environmentResult = await ProcessEnvironmentBuilder.build(
            ProcessEnvironmentRequest(
                purpose: .cliRunner,
                enableDebugLogging: config.enableDebugLogging
            )
        )
        let environment = environmentResult.environment
        let resolvedCommand = CommandPathResolver.resolve(
            config.commandName,
            environment: environment,
            additionalPaths: config.additionalPathHints,
            logger: config.enableDebugLogging ? { print("[PiRPCClient] \($0)") } : nil,
            preferredBasenames: CLILaunchProfiles.pi.preferredBasenames
        )
        switch CommandPathResolver.launchability(of: resolvedCommand) {
        case .launchable, .bareCommandFallback:
            break
        case .missingPath:
            throw ClientError.executableUnavailable("pi executable was not found at \(resolvedCommand). Install pi or update PATH.")
        case .directory:
            throw ClientError.executableUnavailable("pi executable path resolves to a directory: \(resolvedCommand).")
        case .notExecutable:
            throw ClientError.executableUnavailable("pi executable is not runnable: \(resolvedCommand).")
        }
        let workingDirectory = normalizedWorkingDirectory(config.workingDirectory) ?? FileManager.default.temporaryDirectory.path
        let spawned = try ProcessLauncher.spawn(
            command: resolvedCommand,
            arguments: config.launchArguments,
            environment: environment,
            workingDirectory: workingDirectory
        )
        process = spawned
        stdoutFramer = LineFramer()
        stderrTail.removeAll(keepingCapacity: false)
        do {
            try startStdoutReader(handle: spawned.stdout)
            try startStderrReader(handle: spawned.stderr)
        } catch {
            spawned.stdout.readabilityHandler = nil
            spawned.stderr.readabilityHandler = nil
            spawned.stdin?.closeFile()
            process = nil
            _ = await ProcessTermination.terminateAndReap(
                pid: spawned.pid,
                logger: config.enableDebugLogging ? { print("[PiRPCClient] \($0)") } : { _ in }
            )
            throw ClientError.readerSetupFailed("Failed to start pi RPC readers: \(error.localizedDescription)")
        }
        if config.enableDebugLogging {
            print("[PiRPCClient] launched pid=\(spawned.pid) command=\(resolvedCommand) args=\(config.launchArguments) cwd=\(workingDirectory)")
        }
    }

    func shutdown() async {
        guard !isShuttingDown else { return }
        isShuttingDown = true
        let activeProcess = process
        process = nil
        stdoutConsumerTask?.cancel()
        stderrConsumerTask?.cancel()
        stdoutConsumerTask = nil
        stderrConsumerTask = nil
        stdoutChunkChannel?.finish()
        stderrChunkChannel?.finish()
        stdoutChunkChannel = nil
        stderrChunkChannel = nil
        activeProcess?.stdout.readabilityHandler = nil
        activeProcess?.stderr.readabilityHandler = nil
        activeProcess?.stdin?.closeFile()
        failAllPendingRequests(ClientError.transportClosed("pi RPC transport shut down."))
        if let pid = activeProcess?.pid {
            _ = await ProcessTermination.terminateAndReap(
                pid: pid,
                logger: config.enableDebugLogging ? { print("[PiRPCClient] \($0)") } : { _ in }
            )
        }
        eventsContinuation?.finish()
        eventsContinuation = nil
        isShuttingDown = false
    }

    func getState() async throws -> SessionState {
        let response = try await sendCommand(["type": .string("get_state")])
        guard let data = response["data"]?.objectValue else {
            throw ClientError.invalidResponse("pi get_state response did not include an object data payload.")
        }
        return try Self.parseSessionState(data)
    }

    func getAvailableModels() async throws -> [RemoteModel] {
        let response = try await sendCommand(["type": .string("get_available_models")])
        guard let data = response["data"]?.objectValue,
              let models = data["models"]?.arrayValue
        else {
            throw ClientError.invalidResponse("pi get_available_models response did not include a models array.")
        }
        return models.compactMap { value in
            guard let object = value.objectValue else { return nil }
            return Self.parseRemoteModel(object)
        }
    }

    @discardableResult
    func prompt(_ message: String, streamingBehavior: String? = nil) async throws -> [String: PiJSONValue] {
        var command: [String: PiJSONValue] = [
            "type": .string("prompt"),
            "message": .string(message)
        ]
        if let streamingBehavior {
            command["streamingBehavior"] = .string(streamingBehavior)
        }
        return try await sendCommand(command)
    }

    @discardableResult
    func steer(_ message: String) async throws -> [String: PiJSONValue] {
        try await sendCommand(["type": .string("steer"), "message": .string(message)])
    }

    @discardableResult
    func followUp(_ message: String) async throws -> [String: PiJSONValue] {
        try await sendCommand(["type": .string("follow_up"), "message": .string(message)])
    }

    @discardableResult
    func abort() async throws -> [String: PiJSONValue] {
        try await sendCommand(["type": .string("abort")])
    }

    @discardableResult
    func switchSession(path: String) async throws -> [String: PiJSONValue] {
        try await sendCommand(["type": .string("switch_session"), "sessionPath": .string(path)])
    }

    @discardableResult
    func newSession(parentSession: String? = nil) async throws -> [String: PiJSONValue] {
        var command: [String: PiJSONValue] = ["type": .string("new_session")]
        if let parentSession {
            command["parentSession"] = .string(parentSession)
        }
        return try await sendCommand(command)
    }

    @discardableResult
    func setModel(provider: String, modelID: String) async throws -> [String: PiJSONValue] {
        try await sendCommand([
            "type": .string("set_model"),
            "provider": .string(provider),
            "modelId": .string(modelID)
        ])
    }

    @discardableResult
    func setThinkingLevel(_ level: String) async throws -> [String: PiJSONValue] {
        try await sendCommand(["type": .string("set_thinking_level"), "level": .string(level)])
    }

    @discardableResult
    func respondToExtensionUIRequest(_ response: PiExtensionUIResponse) async throws -> [String: PiJSONValue] {
        try await sendCommand(response.commandPayload, expectsStandardResponse: false)
    }

    @discardableResult
    func sendCommand(
        _ payload: [String: PiJSONValue],
        expectsStandardResponse: Bool = true
    ) async throws -> [String: PiJSONValue] {
        try await startIfNeeded()
        guard let command = payload["type"]?.stringValue else {
            throw ClientError.invalidResponse("pi RPC command payload is missing a type string.")
        }
        let requestID = expectsStandardResponse
            ? makeRequestID(command: command)
            : (payload["id"]?.stringValue ?? makeRequestID(command: command))
        var framePayload = payload
        if expectsStandardResponse || framePayload["id"] == nil {
            framePayload["id"] = .string(requestID)
        }
        let frame = try Self.encodeJSONLine(framePayload)
        guard let stdinDescriptor = process?.stdinDescriptor else {
            throw ClientError.processNotRunning
        }

        return try await withCheckedThrowingContinuation { continuation in
            if expectsStandardResponse {
                pendingRequests[requestID] = PendingRequest(command: command, continuation: continuation)
                installTimeoutIfNeeded(id: requestID, command: command)
            }
            do {
                try FDWriteSupport.writeAll(frame, to: stdinDescriptor)
                if !expectsStandardResponse {
                    continuation.resume(returning: [:])
                }
            } catch {
                if expectsStandardResponse {
                    pendingRequests.removeValue(forKey: requestID)
                    timeoutTasks[requestID]?.cancel()
                    timeoutTasks.removeValue(forKey: requestID)
                }
                continuation.resume(throwing: ClientError.inputWriteFailed(error.localizedDescription))
            }
        }
    }

    private func startStdoutReader(handle: FileHandle) throws {
        try ReadSourceFDPreflight.validateOpenFD(handle.fileDescriptor, label: "pi RPC stdout")
        let channel = FileHandleChunkChannel()
        stdoutChunkChannel = channel
        handle.readabilityHandler = { readable in
            let data = readable.availableData
            if data.isEmpty {
                channel.finish()
                readable.readabilityHandler = nil
            } else {
                channel.yield(data)
            }
        }
        stdoutConsumerTask = Task { [weak self] in
            for await chunk in channel.stream {
                guard let self else { break }
                await handleStdoutChunk(chunk)
            }
            guard let self else { return }
            await handleStdoutEOF()
        }
    }

    private func startStderrReader(handle: FileHandle) throws {
        try ReadSourceFDPreflight.validateOpenFD(handle.fileDescriptor, label: "pi RPC stderr")
        let channel = FileHandleChunkChannel()
        stderrChunkChannel = channel
        handle.readabilityHandler = { readable in
            let data = readable.availableData
            if data.isEmpty {
                channel.finish()
                readable.readabilityHandler = nil
            } else {
                channel.yield(data)
            }
        }
        stderrConsumerTask = Task { [weak self] in
            for await chunk in channel.stream {
                guard let self else { break }
                await handleStderrChunk(chunk)
            }
        }
    }

    private func handleStdoutChunk(_ data: Data) async {
        var lines: [Data] = []
        stdoutFramer.feed(data) { line in
            lines.append(line)
        }
        for line in lines {
            await handleLine(line)
        }
    }

    private func handleStderrChunk(_ data: Data) {
        appendTail(&stderrTail, chunk: data, limit: 256 * 1024)
        if config.enableDebugLogging,
           let text = String(data: data, encoding: .utf8),
           !text.isEmpty
        {
            print("[PiRPCClient][stderr] \(text)")
        }
    }

    private func handleLine(_ lineData: Data) async {
        let trimmed = lineData.trimmingASCIIWhitespaceAndNewlines()
        guard !trimmed.isEmpty else { return }
        do {
            guard let value = try PiJSONValue.decodeObject(from: trimmed) else { return }
            await routeInbound(value)
        } catch {
            if config.enableDebugLogging {
                let preview = String(data: trimmed.prefix(512), encoding: .utf8) ?? "<non-utf8>"
                print("[PiRPCClient] skipped invalid JSON line: \(preview)")
            }
        }
    }

    private func routeInbound(_ payload: [String: PiJSONValue]) async {
        guard let type = payload["type"]?.stringValue else {
            emit(.unhandled(type: "", payload: payload))
            return
        }
        if type == "response" {
            handleResponse(payload)
            return
        }
        if type == "extension_ui_request" {
            if let request = Self.parseExtensionUIRequest(payload) {
                emit(.extensionUIRequest(request))
            } else {
                emit(.unhandled(type: type, payload: payload))
            }
            return
        }
        emit(Self.parseEvent(type: type, payload: payload))
    }

    private func handleResponse(_ payload: [String: PiJSONValue]) {
        guard let id = payload["id"]?.stringValue,
              let pending = pendingRequests.removeValue(forKey: id)
        else {
            return
        }
        timeoutTasks[id]?.cancel()
        timeoutTasks.removeValue(forKey: id)
        let success = payload["success"]?.boolValue ?? false
        if success {
            pending.continuation.resume(returning: payload)
        } else {
            let errorMessage = payload["error"]?.stringValue ?? "pi RPC command \(pending.command) failed."
            pending.continuation.resume(throwing: ClientError.requestFailed(errorMessage))
        }
    }

    private func handleStdoutEOF() async {
        guard process != nil else { return }
        let stderr = String(data: stderrTail, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let reason = stderr?.isEmpty == false ? "pi RPC stdout closed. stderr: \(stderr!)" : "pi RPC stdout closed."
        process = nil
        failAllPendingRequests(ClientError.transportClosed(reason))
        emit(.transportClosed(reason: reason))
    }

    private func failAllPendingRequests(_ error: Error) {
        let pending = pendingRequests
        pendingRequests.removeAll()
        for task in timeoutTasks.values {
            task.cancel()
        }
        timeoutTasks.removeAll()
        for request in pending.values {
            request.continuation.resume(throwing: error)
        }
    }

    private func installTimeoutIfNeeded(id: String, command: String) {
        guard let requestTimeout = config.requestTimeout, requestTimeout > 0 else { return }
        let nanos = UInt64(requestTimeout * 1_000_000_000)
        timeoutTasks[id] = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: nanos)
                await self?.handleRequestTimeout(id: id, command: command)
            } catch {
                return
            }
        }
    }

    private func handleRequestTimeout(id: String, command: String) {
        guard let pending = pendingRequests.removeValue(forKey: id) else { return }
        timeoutTasks[id]?.cancel()
        timeoutTasks.removeValue(forKey: id)
        pending.continuation.resume(throwing: ClientError.requestTimedOut(id: id, command: command))
    }

    private func makeRequestID(command: String) -> String {
        defer { nextRequestNumber += 1 }
        return "rp-pi-\(command)-\(nextRequestNumber)"
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
            fatalError("PiRPCClient failed to create event stream")
        }
        return (stream, captured)
    }

    private static func encodeJSONLine(_ payload: [String: PiJSONValue]) throws -> Data {
        let object = payload.mapValues { $0.toAny() }
        let data = try JSONSerialization.data(withJSONObject: object, options: [])
        var frame = data
        frame.append(0x0A)
        return frame
    }

    private static func parseSessionState(_ object: [String: PiJSONValue]) throws -> SessionState {
        guard let sessionID = object["sessionId"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !sessionID.isEmpty
        else {
            throw ClientError.invalidResponse("pi session state is missing sessionId.")
        }
        return SessionState(
            sessionID: sessionID,
            sessionFile: object["sessionFile"]?.stringValue,
            sessionName: object["sessionName"]?.stringValue,
            thinkingLevel: object["thinkingLevel"]?.stringValue,
            isStreaming: object["isStreaming"]?.boolValue ?? false,
            isCompacting: object["isCompacting"]?.boolValue ?? false,
            messageCount: object["messageCount"]?.intValue,
            pendingMessageCount: object["pendingMessageCount"]?.intValue,
            model: object["model"]?.objectValue.flatMap(Self.parseRemoteModel)
        )
    }

    private static func parseRemoteModel(_ object: [String: PiJSONValue]) -> RemoteModel? {
        let provider = object["provider"]?.stringValue
            ?? object["providerId"]?.stringValue
            ?? object["providerID"]?.stringValue
        let id = object["id"]?.stringValue
            ?? object["modelId"]?.stringValue
            ?? object["modelID"]?.stringValue
            ?? object["name"]?.stringValue
        guard let id = id?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty else { return nil }
        let displayName = object["displayName"]?.stringValue
            ?? object["name"]?.stringValue
            ?? id
        return RemoteModel(
            provider: provider,
            id: id,
            displayName: displayName,
            description: object["description"]?.stringValue,
            raw: object
        )
    }

    private static func parseExtensionUIRequest(_ payload: [String: PiJSONValue]) -> PiExtensionUIRequest? {
        guard let id = payload["id"]?.stringValue,
              let method = payload["method"]?.stringValue
        else { return nil }
        return PiExtensionUIRequest(
            id: id,
            method: method,
            title: payload["title"]?.stringValue,
            message: payload["message"]?.stringValue,
            statusKey: payload["statusKey"]?.stringValue,
            statusText: payload["statusText"]?.stringValue,
            raw: payload
        )
    }

    private static func parseEvent(type: String, payload: [String: PiJSONValue]) -> Event {
        switch type {
        case "agent_start":
            return .agentStart
        case "agent_end":
            let messages = payload["messages"]?.arrayValue?.compactMap(\.objectValue) ?? []
            return .agentEnd(messages: messages)
        case "turn_start":
            return .turnStart
        case "turn_end":
            let toolResults = payload["toolResults"]?.arrayValue?.compactMap(\.objectValue) ?? []
            return .turnEnd(message: payload["message"]?.objectValue, toolResults: toolResults)
        case "message_start":
            return .messageStart(message: payload["message"]?.objectValue)
        case "message_update":
            if let eventObject = payload["assistantMessageEvent"]?.objectValue {
                return .messageUpdate(parseAssistantMessageEvent(eventObject))
            }
            return .unhandled(type: type, payload: payload)
        case "message_end":
            return .messageEnd(message: payload["message"]?.objectValue)
        case "tool_execution_start":
            return .toolExecutionStart(
                toolCallID: payload["toolCallId"]?.stringValue ?? payload["toolCallID"]?.stringValue ?? "",
                toolName: payload["toolName"]?.stringValue ?? "",
                args: payload["args"]?.objectValue ?? [:]
            )
        case "tool_execution_update":
            return .toolExecutionUpdate(
                toolCallID: payload["toolCallId"]?.stringValue ?? payload["toolCallID"]?.stringValue ?? "",
                toolName: payload["toolName"]?.stringValue ?? "",
                partialResult: payload["partialResult"]
            )
        case "tool_execution_end":
            return .toolExecutionEnd(
                toolCallID: payload["toolCallId"]?.stringValue ?? payload["toolCallID"]?.stringValue ?? "",
                toolName: payload["toolName"]?.stringValue ?? "",
                result: payload["result"],
                isError: payload["isError"]?.boolValue ?? false
            )
        case "queue_update":
            return .queueUpdate(
                steering: payload["steering"]?.arrayValue?.compactMap(\.stringValue) ?? [],
                followUp: payload["followUp"]?.arrayValue?.compactMap(\.stringValue) ?? []
            )
        case "compaction_start":
            return .compactionStart(reason: payload["reason"]?.stringValue)
        case "compaction_end":
            return .compactionEnd(result: payload["result"])
        case "extension_error":
            return .extensionError(payload["error"]?.stringValue ?? payload["message"]?.stringValue ?? "pi extension error")
        default:
            return .unhandled(type: type, payload: payload)
        }
    }

    private static func parseAssistantMessageEvent(_ object: [String: PiJSONValue]) -> PiAssistantMessageEvent {
        PiAssistantMessageEvent(
            type: object["type"]?.stringValue ?? "",
            contentIndex: object["contentIndex"]?.intValue,
            delta: object["delta"]?.stringValue,
            content: object["content"]?.stringValue,
            reason: object["reason"]?.stringValue,
            toolCall: object["toolCall"],
            partial: object["partial"],
            raw: object
        )
    }

    private func normalizedWorkingDirectory(_ path: String?) -> String? {
        let trimmed = path?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else { return nil }
        return (trimmed as NSString).expandingTildeInPath
    }
}

struct PiExtensionUIResponse: Equatable {
    var id: String
    var value: String?
    var confirmed: Bool?
    var cancelled: Bool

    static func value(id: String, _ value: String) -> PiExtensionUIResponse {
        PiExtensionUIResponse(id: id, value: value, confirmed: nil, cancelled: false)
    }

    static func confirmed(id: String, _ confirmed: Bool) -> PiExtensionUIResponse {
        PiExtensionUIResponse(id: id, value: nil, confirmed: confirmed, cancelled: false)
    }

    static func cancelled(id: String) -> PiExtensionUIResponse {
        PiExtensionUIResponse(id: id, value: nil, confirmed: nil, cancelled: true)
    }

    var commandPayload: [String: PiJSONValue] {
        var payload: [String: PiJSONValue] = [
            "type": .string("extension_ui_response"),
            "id": .string(id)
        ]
        if let value {
            payload["value"] = .string(value)
        }
        if let confirmed {
            payload["confirmed"] = .bool(confirmed)
        }
        if cancelled {
            payload["cancelled"] = .bool(true)
        }
        return payload
    }
}

enum PiJSONValue: Hashable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: PiJSONValue])
    case array([PiJSONValue])
    case null

    var stringValue: String? {
        if case let .string(value) = self { return value }
        return nil
    }

    var boolValue: Bool? {
        if case let .bool(value) = self { return value }
        return nil
    }

    var intValue: Int? {
        switch self {
        case let .number(value): Int(value)
        case let .string(value): Int(value)
        default: nil
        }
    }

    var objectValue: [String: PiJSONValue]? {
        if case let .object(value) = self { return value }
        return nil
    }

    var arrayValue: [PiJSONValue]? {
        if case let .array(value) = self { return value }
        return nil
    }

    func toAny() -> Any {
        switch self {
        case let .string(value): value
        case let .number(value): value
        case let .bool(value): value
        case let .object(value): value.mapValues { $0.toAny() }
        case let .array(value): value.map { $0.toAny() }
        case .null: NSNull()
        }
    }

    static func decodeObject(from data: Data) throws -> [String: PiJSONValue]? {
        let raw = try JSONSerialization.jsonObject(with: data, options: [])
        guard let object = raw as? [String: Any] else { return nil }
        return object.compactMapValues(Self.fromAny)
    }

    static func fromAny(_ value: Any) -> PiJSONValue? {
        switch value {
        case let string as String:
            return .string(string)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return .bool(number.boolValue)
            }
            return .number(number.doubleValue)
        case let object as [String: Any]:
            return .object(object.compactMapValues(Self.fromAny))
        case let array as [Any]:
            return .array(array.compactMap(Self.fromAny))
        case _ as NSNull:
            return .null
        default:
            return nil
        }
    }
}

private extension Data {
    func trimmingASCIIWhitespaceAndNewlines() -> Data {
        var start = startIndex
        var end = endIndex
        while start < end, self[start].isASCIIWhitespaceOrNewline {
            start = index(after: start)
        }
        while end > start {
            let beforeEnd = index(before: end)
            guard self[beforeEnd].isASCIIWhitespaceOrNewline else { break }
            end = beforeEnd
        }
        return subdata(in: start ..< end)
    }
}

private extension UInt8 {
    var isASCIIWhitespaceOrNewline: Bool {
        self == 0x20 || self == 0x09 || self == 0x0A || self == 0x0D
    }
}
