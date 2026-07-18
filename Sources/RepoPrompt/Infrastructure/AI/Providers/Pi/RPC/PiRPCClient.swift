import Darwin
import Foundation

actor PiRPCClient {
    private struct RegisteredExpectedAgentPID: Equatable {
        let pid: pid_t
        let clientName: String
        let runID: UUID
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
    private var protocolDiagnosticCounts: [String: Int] = [:]
    private var expectedAgentPIDRegistration: ExpectedAgentPIDRegistration?
    private var registeredExpectedAgentPID: RegisteredExpectedAgentPID?
    private var didPassSupportedVersionCheck = false
    private let expectedAgentPIDRegistrar: ExpectedAgentPIDRegistrar

    init(
        config: Config = Config(),
        expectedAgentPIDRegistrar: ExpectedAgentPIDRegistrar = .serverNetworkManager
    ) {
        self.config = config
        self.expectedAgentPIDRegistrar = expectedAgentPIDRegistrar
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
        didPassSupportedVersionCheck = false
    }

    func setExpectedAgentPIDRegistration(_ registration: ExpectedAgentPIDRegistration?) async {
        expectedAgentPIDRegistration = registration
        guard registration != nil else {
            await clearRegisteredExpectedAgentPIDIfNeeded()
            return
        }
        guard let process else {
            await clearRegisteredExpectedAgentPIDIfNeeded()
            return
        }
        await registerExpectedAgentPIDIfNeeded(for: process.pid)
    }

    func clearExpectedAgentPIDRegistration() async {
        expectedAgentPIDRegistration = nil
        await clearRegisteredExpectedAgentPIDIfNeeded()
    }

    private func registerExpectedAgentPIDIfNeeded(for pid: pid_t) async {
        guard let registration = expectedAgentPIDRegistration else { return }
        let target = RegisteredExpectedAgentPID(
            pid: pid,
            clientName: registration.clientName,
            runID: registration.runID
        )
        guard registeredExpectedAgentPID != target else { return }
        await clearRegisteredExpectedAgentPIDIfNeeded()
        guard expectedAgentPIDRegistration == registration, process?.pid == pid else { return }
        registeredExpectedAgentPID = target
        await expectedAgentPIDRegistrar.register(target.pid, target.clientName, target.runID)
        guard expectedAgentPIDRegistration == registration, process?.pid == pid else {
            if registeredExpectedAgentPID == target {
                registeredExpectedAgentPID = nil
            }
            await expectedAgentPIDRegistrar.clear(target.pid, target.clientName, target.runID)
            return
        }
    }

    private func clearRegisteredExpectedAgentPIDIfNeeded() async {
        guard let registered = takeRegisteredExpectedAgentPIDForDeferredClear() else { return }
        await expectedAgentPIDRegistrar.clear(registered.pid, registered.clientName, registered.runID)
    }

    private func takeRegisteredExpectedAgentPIDForDeferredClear() -> RegisteredExpectedAgentPID? {
        let registered = registeredExpectedAgentPID
        registeredExpectedAgentPID = nil
        return registered
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
        let environment = environmentResult.environment.merging(config.environmentOverrides) { _, override in override }
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
        if config.requiresSupportedVersionCheck, !didPassSupportedVersionCheck {
            let availability = await PiIntegrationConfiguration.checkManagedRPCAvailability(
                commandName: resolvedCommand,
                workingDirectory: workingDirectory,
                enableDebugLogging: config.enableDebugLogging,
                allowCachedSupportedVersionOnTimeout: true
            )
            guard availability.isAvailable else {
                throw ClientError.executableUnavailable(
                    availability.diagnostic ?? "pi is unavailable or unsupported."
                )
            }
            didPassSupportedVersionCheck = true
        }
        let spawned = try ProcessLauncher.spawn(
            command: resolvedCommand,
            arguments: config.launchArguments,
            environment: environment,
            workingDirectory: workingDirectory,
            processGroup: .newProcessGroup
        )
        process = spawned
        await registerExpectedAgentPIDIfNeeded(for: spawned.pid)
        stdoutFramer = LineFramer()
        protocolDiagnosticCounts.removeAll(keepingCapacity: true)
        stderrTail.removeAll(keepingCapacity: false)
        do {
            try startStdoutReader(handle: spawned.stdout)
            try startStderrReader(handle: spawned.stderr)
        } catch {
            spawned.stdout.readabilityHandler = nil
            spawned.stderr.readabilityHandler = nil
            spawned.stdin?.closeFile()
            process = nil
            await clearRegisteredExpectedAgentPIDIfNeeded()
            _ = await terminate(spawned)
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
        let expectedAgentPIDToClear = takeRegisteredExpectedAgentPIDForDeferredClear()
        process = nil
        didPassSupportedVersionCheck = false
        protocolDiagnosticCounts.removeAll(keepingCapacity: false)
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
        if let expectedAgentPIDToClear {
            await expectedAgentPIDRegistrar.clear(
                expectedAgentPIDToClear.pid,
                expectedAgentPIDToClear.clientName,
                expectedAgentPIDToClear.runID
            )
        }
        if let activeProcess {
            _ = await terminate(activeProcess)
        }
        eventsContinuation?.finish()
        eventsContinuation = nil
        isShuttingDown = false
    }

    private func terminate(_ process: SpawnedProcess) async -> Int32 {
        let logger: (String) -> Void = config.enableDebugLogging ? { print("[PiRPCClient] \($0)") } : { _ in }
        if let processGroupID = process.processGroupID {
            return await ProcessTermination.terminateProcessGroupAndReapRoot(
                pid: process.pid,
                processGroupID: processGroupID,
                logger: logger
            )
        }
        return await ProcessTermination.terminateAndReap(pid: process.pid, logger: logger)
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

    func getCommands() async throws -> [SlashCommand] {
        let response = try await sendCommand(["type": .string("get_commands")])
        guard let data = response["data"]?.objectValue,
              let commands = data["commands"]?.arrayValue
        else {
            throw ClientError.invalidResponse("pi get_commands response did not include a commands array.")
        }
        return commands.compactMap { value in
            guard let object = value.objectValue else { return nil }
            return Self.parseSlashCommand(object)
        }
    }

    @discardableResult
    func prompt(
        _ message: String,
        streamingBehavior: String? = nil,
        images: [ImageContent] = []
    ) async throws -> [String: PiJSONValue] {
        var command = messageCommand(type: "prompt", message: message, images: images)
        if let streamingBehavior {
            command["streamingBehavior"] = .string(streamingBehavior)
        }
        return try await sendCommand(command)
    }

    @discardableResult
    func steer(_ message: String, images: [ImageContent] = []) async throws -> [String: PiJSONValue] {
        try await sendCommand(messageCommand(type: "steer", message: message, images: images))
    }

    @discardableResult
    func followUp(_ message: String, images: [ImageContent] = []) async throws -> [String: PiJSONValue] {
        try await sendCommand(messageCommand(type: "follow_up", message: message, images: images))
    }

    private func messageCommand(
        type: String,
        message: String,
        images: [ImageContent]
    ) -> [String: PiJSONValue] {
        var command: [String: PiJSONValue] = [
            "type": .string(type),
            "message": .string(message)
        ]
        if !images.isEmpty {
            command["images"] = .array(images.map(\.jsonValue))
        }
        return command
    }

    @discardableResult
    func abort() async throws -> [String: PiJSONValue] {
        try await sendCommand(["type": .string("abort")])
    }

    @discardableResult
    func switchSession(path: String) async throws -> SessionMutationResult {
        let response = try await sendCommand(["type": .string("switch_session"), "sessionPath": .string(path)])
        return Self.parseSessionMutationResult(response)
    }

    @discardableResult
    func newSession(parentSession: String? = nil) async throws -> SessionMutationResult {
        var command: [String: PiJSONValue] = ["type": .string("new_session")]
        if let parentSession {
            command["parentSession"] = .string(parentSession)
        }
        let response = try await sendCommand(command)
        return Self.parseSessionMutationResult(response)
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
        let trimmed = PiRPCLineData.trimmingASCIIWhitespaceAndNewlines(lineData)
        guard !trimmed.isEmpty else { return }
        do {
            guard let value = try PiJSONValue.decodeObject(from: trimmed) else { return }
            await routeInbound(value)
        } catch {
            let preview = Self.preview(trimmed)
            emitProtocolDiagnostic(
                kind: .malformedJSON,
                eventType: nil,
                message: "pi RPC skipped malformed JSON line.",
                payloadPreview: preview
            )
            if config.enableDebugLogging {
                print("[PiRPCClient] skipped invalid JSON line: \(preview)")
            }
        }
    }

    private func routeInbound(_ payload: [String: PiJSONValue]) async {
        guard let type = payload["type"]?.stringValue else {
            emitProtocolDiagnostic(
                kind: .missingEventType,
                eventType: nil,
                message: "pi RPC event did not include a type string.",
                payload: payload
            )
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
                emitProtocolDiagnostic(
                    kind: .malformedEventPayload,
                    eventType: type,
                    message: "pi RPC extension_ui_request payload was missing required id or method.",
                    payload: payload
                )
                emit(.unhandled(type: type, payload: payload))
            }
            return
        }
        if type == "custom_message" {
            emit(.customMessage(Self.parseCustomMessage(payload)))
            return
        }
        let event = Self.parseEvent(type: type, payload: payload)
        if case let .unhandled(unhandledType, unhandledPayload) = event {
            emitProtocolDiagnostic(
                kind: .unknownEventType,
                eventType: unhandledType,
                message: "pi RPC emitted an unknown or unsupported event type: \(unhandledType).",
                payload: unhandledPayload
            )
        }
        emit(event)
    }

    private func handleResponse(_ payload: [String: PiJSONValue]) {
        guard let id = payload["id"]?.stringValue,
              let pending = pendingRequests.removeValue(forKey: id)
        else {
            emitProtocolDiagnostic(
                kind: .lateResponse,
                eventType: payload["command"]?.stringValue,
                message: "pi RPC emitted a response with no pending request.",
                payload: payload
            )
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
        guard let activeProcess = process else { return }
        let stderr = String(data: stderrTail, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let reason = stderr?.isEmpty == false ? "pi RPC stdout closed. stderr: \(stderr!)" : "pi RPC stdout closed."
        let expectedAgentPIDToClear = takeRegisteredExpectedAgentPIDForDeferredClear()
        process = nil
        didPassSupportedVersionCheck = false
        stdoutConsumerTask = nil
        stderrConsumerTask?.cancel()
        stderrConsumerTask = nil
        stdoutChunkChannel = nil
        stderrChunkChannel?.finish()
        stderrChunkChannel = nil
        activeProcess.stdout.readabilityHandler = nil
        activeProcess.stderr.readabilityHandler = nil
        activeProcess.stdin?.closeFile()
        failAllPendingRequests(ClientError.transportClosed(reason))
        emit(.transportClosed(reason: reason))
        if let expectedAgentPIDToClear {
            await expectedAgentPIDRegistrar.clear(
                expectedAgentPIDToClear.pid,
                expectedAgentPIDToClear.clientName,
                expectedAgentPIDToClear.runID
            )
        }
        let exitCode = await terminate(activeProcess)
        if config.enableDebugLogging {
            print("[PiRPCClient] reaped pid=\(activeProcess.pid) after stdout EOF with exitCode=\(exitCode)")
        }
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
        let timeout = Self.usesPromptRequestTimeout(command: command)
            ? config.promptRequestTimeout
            : config.requestTimeout
        guard let timeout, timeout > 0 else { return }
        let nanos = UInt64(timeout * 1_000_000_000)
        timeoutTasks[id] = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: nanos)
                await self?.handleRequestTimeout(id: id, command: command)
            } catch {
                return
            }
        }
    }

    private func handleRequestTimeout(id: String, command: String) async {
        guard let pending = pendingRequests.removeValue(forKey: id) else { return }
        timeoutTasks[id]?.cancel()
        timeoutTasks.removeValue(forKey: id)
        if Self.invalidatesProcessOnTimeout(command: command) {
            await shutdown()
        }
        pending.continuation.resume(throwing: ClientError.requestTimedOut(id: id, command: command))
    }

    private static func usesPromptRequestTimeout(command: String) -> Bool {
        switch command {
        case "prompt", "steer", "follow_up":
            true
        default:
            false
        }
    }

    private static func invalidatesProcessOnTimeout(command: String) -> Bool {
        switch command {
        case "prompt", "steer", "follow_up", "abort", "switch_session", "new_session", "set_model", "set_thinking_level":
            true
        default:
            false
        }
    }

    private func makeRequestID(command: String) -> String {
        defer { nextRequestNumber += 1 }
        return "rp-pi-\(command)-\(nextRequestNumber)"
    }

    private func emitProtocolDiagnostic(
        kind: ProtocolDiagnostic.Kind,
        eventType: String?,
        message: String,
        payload: [String: PiJSONValue]
    ) {
        emitProtocolDiagnostic(
            kind: kind,
            eventType: eventType,
            message: message,
            payloadPreview: Self.payloadPreview(payload)
        )
    }

    private func emitProtocolDiagnostic(
        kind: ProtocolDiagnostic.Kind,
        eventType: String?,
        message: String,
        payloadPreview: String?
    ) {
        let key = "\(kind.rawValue):\(eventType ?? "")"
        let occurrence = (protocolDiagnosticCounts[key] ?? 0) + 1
        protocolDiagnosticCounts[key] = occurrence
        guard occurrence <= 3 else { return }
        let diagnostic = ProtocolDiagnostic(
            kind: kind,
            eventType: eventType,
            message: message,
            payloadPreview: payloadPreview,
            occurrence: occurrence
        )
        if config.enableDebugLogging {
            let preview = payloadPreview.map { " preview=\($0)" } ?? ""
            print("[PiRPCClient][protocol] \(message) kind=\(kind.rawValue) eventType=\(eventType ?? "<none>") occurrence=\(occurrence)\(preview)")
        }
        emit(.protocolDiagnostic(diagnostic))
    }

    private func emit(_ event: Event) {
        _ = eventsContinuation?.yield(event)
    }

    private static func payloadPreview(_ payload: [String: PiJSONValue]) -> String? {
        let redacted = redact(payload)
        guard JSONSerialization.isValidJSONObject(redacted),
              let data = try? JSONSerialization.data(withJSONObject: redacted, options: [.sortedKeys])
        else { return nil }
        return preview(data)
    }

    private static func preview(_ data: Data, maxBytes: Int = 512) -> String {
        let prefix = data.prefix(maxBytes)
        let text = String(data: prefix, encoding: .utf8) ?? "<non-utf8>"
        let preview = data.count > maxBytes ? text + "…" : text
        return redactedTextPreview(preview)
    }

    private static func redactedTextPreview(_ text: String) -> String {
        let lowercased = text.lowercased()
        let sensitiveFragments = [
            "authorization",
            "bearer ",
            "api_key",
            "apikey",
            "api-key",
            "password",
            "secret",
            "token"
        ]
        if sensitiveFragments.contains(where: { lowercased.contains($0) }) {
            return "[REDACTED sensitive pi RPC preview]"
        }
        let sensitivePatterns = [
            #"sk-[A-Za-z0-9][A-Za-z0-9._-]{8,}"#,
            #"github_pat_[A-Za-z0-9_]{12,}"#,
            #"gh[pousr]_[A-Za-z0-9_]{12,}"#,
            #"xox[baprs]-[A-Za-z0-9-]{12,}"#,
            #"AKIA[0-9A-Z]{16}"#,
            #"[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{10,}"#
        ]
        guard sensitivePatterns.contains(where: { pattern in
            text.range(of: pattern, options: .regularExpression) != nil
        }) else { return text }
        return "[REDACTED sensitive pi RPC preview]"
    }

    private static func redact(_ payload: [String: PiJSONValue]) -> [String: Any] {
        var redacted: [String: Any] = [:]
        for (key, value) in payload {
            redacted[key] = isSensitiveKey(key) ? "[REDACTED]" : redact(value)
        }
        return redacted
    }

    private static func redact(_ value: PiJSONValue) -> Any {
        switch value {
        case let .object(object):
            redact(object)
        case let .array(array):
            array.map(redact)
        case .string, .number, .bool, .null:
            value.toAny()
        }
    }

    private static func isSensitiveKey(_ key: String) -> Bool {
        let lowercased = key.lowercased()
        return lowercased.contains("authorization")
            || lowercased.contains("password")
            || lowercased.contains("secret")
            || lowercased.contains("token")
            || lowercased.contains("api_key")
            || lowercased.contains("apikey")
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

    private static func parseSessionMutationResult(_ response: [String: PiJSONValue]) -> SessionMutationResult {
        let cancelled = response["data"]?.objectValue?["cancelled"]?.boolValue ?? false
        return SessionMutationResult(cancelled: cancelled)
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

    private static func parseSlashCommand(_ object: [String: PiJSONValue]) -> SlashCommand? {
        guard let name = object["name"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty
        else { return nil }
        return SlashCommand(
            name: name,
            description: object["description"]?.stringValue,
            source: object["source"]?.stringValue,
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

    private static func parseCustomMessage(_ payload: [String: PiJSONValue]) -> PiCustomMessage {
        PiCustomMessage(
            customType: payload["customType"]?.stringValue,
            content: payload["content"]?.stringValue,
            display: payload["display"]?.boolValue ?? false,
            details: payload["details"]?.objectValue,
            raw: payload
        )
    }

    private static func parseCustomMessageFromRoleMessage(_ message: [String: PiJSONValue]) -> PiCustomMessage? {
        guard message["role"]?.stringValue == "custom" else { return nil }
        return parseCustomMessage(message)
    }

    private static func parseEvent(type: String, payload: [String: PiJSONValue]) -> Event {
        switch type {
        case "agent_start":
            return .agentStart
        case "agent_end":
            let messages = payload["messages"]?.arrayValue?.compactMap(\.objectValue) ?? []
            return .agentEnd(messages: messages, willRetry: payload["willRetry"]?.boolValue ?? false)
        case "agent_settled":
            return .agentSettled
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
            if let message = payload["message"]?.objectValue,
               let customMessage = parseCustomMessageFromRoleMessage(message)
            {
                return .customMessage(customMessage)
            }
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
            return .compactionEnd(
                reason: payload["reason"]?.stringValue,
                result: payload["result"],
                aborted: payload["aborted"]?.boolValue ?? false,
                willRetry: payload["willRetry"]?.boolValue ?? false,
                errorMessage: payload["errorMessage"]?.stringValue
            )
        case "auto_retry_start":
            return .autoRetryStart(
                attempt: payload["attempt"]?.intValue ?? 0,
                maxAttempts: payload["maxAttempts"]?.intValue ?? 0,
                delayMs: payload["delayMs"]?.intValue ?? 0,
                errorMessage: payload["errorMessage"]?.stringValue ?? "pi agent request failed."
            )
        case "auto_retry_end":
            return .autoRetryEnd(
                success: payload["success"]?.boolValue ?? false,
                attempt: payload["attempt"]?.intValue ?? 0,
                finalError: payload["finalError"]?.stringValue
            )
        case "session_info_changed":
            return .sessionInfoChanged(name: payload["name"]?.stringValue)
        case "thinking_level_changed":
            return .thinkingLevelChanged(level: payload["level"]?.stringValue ?? "")
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
