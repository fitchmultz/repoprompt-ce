import Darwin
@testable import RepoPrompt
import XCTest

final class PiHeadlessAgentProviderTests: XCTestCase {
    private actor ExpectedPIDRecorder {
        enum Event: Equatable {
            case register(pid_t)
            case clear(pid_t)
        }

        private var recordedEvents: [Event] = []

        func record(_ event: Event) {
            recordedEvents.append(event)
        }

        func events() -> [Event] {
            recordedEvents
        }
    }

    private actor CleanupGate {
        private var clearStarted = false
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func waitUntilOpen() async {
            clearStarted = true
            guard !isOpen else { return }
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        }

        func release() {
            isOpen = true
            let continuations = waiters
            waiters.removeAll()
            for continuation in continuations {
                continuation.resume()
            }
        }

        func hasClearStarted() -> Bool {
            clearStarted
        }
    }

    private actor StreamCompletionProbe {
        private var completed = false

        func markCompleted() {
            completed = true
        }

        func isCompleted() -> Bool {
            completed
        }
    }

    private final class ScriptQueue: @unchecked Sendable {
        private let lock = NSLock()
        private var urls: [URL]

        init(_ urls: [URL]) {
            self.urls = urls
        }

        func next() -> URL {
            lock.lock()
            defer { lock.unlock() }
            if urls.count > 1 {
                return urls.removeFirst()
            }
            return urls[0]
        }
    }

    private var temporaryURLs: [URL] = []

    override func tearDown() {
        for url in temporaryURLs {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryURLs.removeAll()
        AgentPiModelRegistry.shared.test_reset()
        super.tearDown()
    }

    func testHeadlessProviderStreamsContextBuilderPromptThroughPiRPC() async throws {
        let directory = try makeTemporaryDirectory()
        let recordURL = directory.appendingPathComponent("commands.jsonl")
        let scriptURL = try makeFakePiRPCScript(recordURL: recordURL)
        let bridgeURL = directory.appendingPathComponent("repoprompt-bridge.ts")
        try "export default function bridge() {}".write(to: bridgeURL, atomically: true, encoding: .utf8)

        let provider = PiHeadlessAgentProvider(
            modelString: "zai/glm-5.2:high",
            workspacePath: directory.path,
            windowID: 7,
            bridgeInstaller: { windowID in
                XCTAssertEqual(windowID, 7)
                return bridgeURL
            },
            controllerFactory: { workspacePath, modelString, enableDebugLogging, installedBridgeURL, permissionLevel, launchPolicy in
                XCTAssertEqual(workspacePath, directory.path)
                XCTAssertEqual(modelString, "zai/glm-5.2:high")
                XCTAssertFalse(enableDebugLogging)
                XCTAssertEqual(installedBridgeURL, bridgeURL)
                XCTAssertEqual(permissionLevel, .managedDefault)
                XCTAssertEqual(launchPolicy, .defaultPolicy)
                let client = PiRPCClient(config: .init(
                    commandName: scriptURL.path,
                    additionalPathHints: [],
                    requestTimeout: 2,
                    workingDirectory: workspacePath,
                    launchArguments: [],
                    requiresSupportedVersionCheck: false
                ))
                return PiNativeSessionController(client: client, options: .init(modelRaw: modelString, requestTimeout: 2, launchArguments: []))
            }
        )
        addTeardownBlock { await provider.dispose() }

        let stream = try await provider.streamAgentMessage(
            AgentMessage(systemPrompt: "Use RepoPrompt context.", userMessage: "Build a context brief."),
            runID: UUID()
        )

        var results: [AIStreamResult] = []
        for try await result in stream {
            results.append(result)
        }

        XCTAssertTrue(results.contains { $0.reasoning == "pi is thinking" })
        XCTAssertTrue(results.contains { $0.type == "content" && $0.text == "context ready" })
        XCTAssertTrue(results.contains { $0.type == "tool_call" && $0.toolName == "get_file_tree" && $0.toolInvocationID != nil })
        XCTAssertTrue(results.contains { $0.type == "tool_result" && $0.toolName == "get_file_tree" && $0.toolOutput == "tree ok" && $0.toolInvocationID != nil })
        let stops = results.filter { $0.type == "message_stop" }
        XCTAssertEqual(stops.count, 1)
        XCTAssertEqual(stops.first?.providerSessionID, "pi-headless-session")

        let prompt = try XCTUnwrap(recordedCommands(at: recordURL).first { $0.type == "prompt" })
        XCTAssertTrue(prompt.message?.contains("<system_instructions>") ?? false)
        XCTAssertTrue(prompt.message?.contains("Use RepoPrompt context.") ?? false)
        XCTAssertTrue(prompt.message?.contains("<user_instructions>") ?? false)
        XCTAssertTrue(prompt.message?.contains("Build a context brief.") ?? false)
        XCTAssertTrue(recordedCommands(at: recordURL).contains { $0.type == "set_model" && $0.provider == "zai" && $0.modelID == "glm-5.2" })
        XCTAssertTrue(recordedCommands(at: recordURL).contains { $0.type == "set_thinking_level" && $0.level == "high" })
    }

    func testManagedControllerOptionsPublishBridgeForHeadlessSubagentInheritance() throws {
        let directory = try makeTemporaryDirectory()
        let bridgeURL = directory.appendingPathComponent("repoprompt-bridge.ts")
        let options = PiHeadlessAgentProvider.managedControllerOptions(
            modelString: "zai/glm-5.2:high",
            enableDebugLogging: true,
            bridgeExtensionURL: bridgeURL,
            permissionLevel: .fullAccess,
            launchPolicy: .disableDiscoveredExtensions
        )

        XCTAssertEqual(options.modelRaw, "zai/glm-5.2:high")
        XCTAssertTrue(options.enableDebugLogging)
        XCTAssertEqual(
            options.launchArguments,
            ["--mode", "rpc", "--approve", "--no-extensions", "--extension", bridgeURL.path]
        )
        XCTAssertEqual(
            options.environmentOverrides[PiIntegrationConfiguration.permissionLevelEnvironmentKey],
            PiAgentToolPreferences.PermissionLevel.fullAccess.rawValue
        )
        let rawInheritedExtensions = try XCTUnwrap(options.environmentOverrides[PiIntegrationConfiguration.inheritedSubagentExtensionsEnvironmentKey])
        let decoded = try JSONDecoder().decode([String].self, from: Data(rawInheritedExtensions.utf8))
        XCTAssertEqual(decoded, [bridgeURL.path])
    }

    func testHeadlessProviderWaitsForPiRPCShutdownBeforeNormalStreamFinishes() async throws {
        let directory = try makeTemporaryDirectory()
        let recordURL = directory.appendingPathComponent("commands.jsonl")
        let scriptURL = try makeFakePiRPCScript(recordURL: recordURL)
        let bridgeURL = directory.appendingPathComponent("repoprompt-bridge.ts")
        try "export default function bridge() {}".write(to: bridgeURL, atomically: true, encoding: .utf8)

        let cleanupGate = CleanupGate()
        let completionProbe = StreamCompletionProbe()
        let pidRecorder = ExpectedPIDRecorder()
        let runID = UUID()
        let provider = PiHeadlessAgentProvider(
            modelString: nil,
            workspacePath: directory.path,
            windowID: 7,
            bridgeInstaller: { _ in bridgeURL },
            controllerFactory: { workspacePath, modelString, _, _, _, _ in
                let registrar = PiRPCClient.ExpectedAgentPIDRegistrar(
                    register: { pid, _, _ in
                        await pidRecorder.record(.register(pid))
                    },
                    clear: { pid, _, _ in
                        await cleanupGate.waitUntilOpen()
                        await pidRecorder.record(.clear(pid))
                    }
                )
                let client = PiRPCClient(
                    config: .init(
                        commandName: scriptURL.path,
                        additionalPathHints: [],
                        requestTimeout: 2,
                        workingDirectory: workspacePath,
                        launchArguments: [],
                        requiresSupportedVersionCheck: false
                    ),
                    expectedAgentPIDRegistrar: registrar
                )
                return PiNativeSessionController(
                    client: client,
                    options: .init(
                        modelRaw: modelString,
                        requestTimeout: 2,
                        launchArguments: [],
                        terminalCompletionGraceInterval: 0
                    )
                )
            }
        )
        addTeardownBlock {
            await cleanupGate.release()
            await provider.dispose()
        }

        let stream = try await provider.streamAgentMessage(
            AgentMessage(systemPrompt: "", userMessage: "Build a context brief."),
            runID: runID
        )
        let consumer = Task { () throws -> [AIStreamResult] in
            var results: [AIStreamResult] = []
            for try await result in stream {
                results.append(result)
            }
            await completionProbe.markCompleted()
            return results
        }

        let didStartCleanup = await eventually {
            await cleanupGate.hasClearStarted()
        }
        guard didStartCleanup else {
            await cleanupGate.release()
            consumer.cancel()
            _ = try? await consumer.value
            XCTFail("Expected normal stream completion to start pi RPC shutdown.")
            return
        }

        let didFinishBeforeCleanup = await completionProbe.isCompleted()
        XCTAssertFalse(
            didFinishBeforeCleanup,
            "Normal stream completion must wait for pi RPC shutdown instead of relying on asynchronous onTermination cleanup."
        )

        await cleanupGate.release()
        let results = try await consumer.value
        XCTAssertTrue(results.contains { $0.type == "content" && $0.text == "context ready" })
        XCTAssertTrue(results.contains { $0.type == "message_stop" })

        let didRecordClear = await eventually {
            let events = await pidRecorder.events()
            return events.count == 2
        }
        let pidEvents = await pidRecorder.events()
        XCTAssertTrue(didRecordClear)
        XCTAssertEqual(pidEvents.count, 2)
        if case let (.some(.register(registeredPID)), .some(.clear(clearedPID))) = (pidEvents.first, pidEvents.dropFirst().first) {
            XCTAssertEqual(clearedPID, registeredPID)
        } else {
            XCTFail("Expected registered pi RPC PID to be cleared during normal completion cleanup.")
        }
    }

    func testHeadlessProviderReplacingInFlightStreamInterruptsAndClearsPreviousRun() async throws {
        let directory = try makeTemporaryDirectory()
        let stalledRecordURL = directory.appendingPathComponent("stalled-commands.jsonl")
        let normalRecordURL = directory.appendingPathComponent("normal-commands.jsonl")
        let stalledScriptURL = try makeFakePiRPCScript(recordURL: stalledRecordURL, stallAfterPrompt: true)
        let normalScriptURL = try makeFakePiRPCScript(recordURL: normalRecordURL)
        let scriptQueue = ScriptQueue([stalledScriptURL, normalScriptURL])
        let bridgeURL = directory.appendingPathComponent("repoprompt-bridge.ts")
        try "export default function bridge() {}".write(to: bridgeURL, atomically: true, encoding: .utf8)

        let pidRecorder = ExpectedPIDRecorder()
        let provider = PiHeadlessAgentProvider(
            modelString: nil,
            workspacePath: directory.path,
            windowID: 7,
            bridgeInstaller: { _ in bridgeURL },
            controllerFactory: { workspacePath, modelString, _, _, _, _ in
                let registrar = PiRPCClient.ExpectedAgentPIDRegistrar(
                    register: { pid, _, _ in
                        await pidRecorder.record(.register(pid))
                    },
                    clear: { pid, _, _ in
                        await pidRecorder.record(.clear(pid))
                    }
                )
                let client = PiRPCClient(
                    config: .init(
                        commandName: scriptQueue.next().path,
                        additionalPathHints: [],
                        requestTimeout: 2,
                        workingDirectory: workspacePath,
                        launchArguments: [],
                        requiresSupportedVersionCheck: false
                    ),
                    expectedAgentPIDRegistrar: registrar
                )
                return PiNativeSessionController(
                    client: client,
                    options: .init(
                        modelRaw: modelString,
                        requestTimeout: 2,
                        launchArguments: [],
                        terminalCompletionGraceInterval: 0
                    )
                )
            }
        )
        addTeardownBlock { await provider.dispose() }

        let firstStream = try await provider.streamAgentMessage(
            AgentMessage(systemPrompt: "", userMessage: "Hold the first stream open."),
            runID: UUID()
        )
        let firstConsumer = Task { () async -> Error? in
            do {
                for try await _ in firstStream {}
                return nil
            } catch {
                return error
            }
        }

        let didStartFirstRun = await eventually {
            await pidRecorder.events().contains { event in
                if case .register = event { return true }
                return false
            }
        }
        guard didStartFirstRun else {
            firstConsumer.cancel()
            _ = await firstConsumer.value
            XCTFail("Expected first headless pi run to start before replacement.")
            return
        }

        _ = try await provider.streamAgentMessage(
            AgentMessage(systemPrompt: "", userMessage: "Replace the first stream."),
            runID: UUID()
        )

        let didClearFirstRun = await eventually {
            let events = await pidRecorder.events()
            guard let firstEvent = events.first else { return false }
            guard case let .register(firstPID) = firstEvent else { return false }
            return events.contains(.clear(firstPID))
        }
        XCTAssertTrue(didClearFirstRun, "Replacing an in-flight headless stream must clear/shutdown the previous pi RPC process.")

        _ = await firstConsumer.value
    }

    func testHeadlessProviderWaitsForPiRPCShutdownBeforeErrorStreamFinishes() async throws {
        let directory = try makeTemporaryDirectory()
        let recordURL = directory.appendingPathComponent("commands.jsonl")
        let scriptURL = try makeFakePiRPCScript(recordURL: recordURL, errorAfterPrompt: true)
        let bridgeURL = directory.appendingPathComponent("repoprompt-bridge.ts")
        try "export default function bridge() {}".write(to: bridgeURL, atomically: true, encoding: .utf8)

        let cleanupGate = CleanupGate()
        let completionProbe = StreamCompletionProbe()
        let pidRecorder = ExpectedPIDRecorder()
        let provider = PiHeadlessAgentProvider(
            modelString: nil,
            workspacePath: directory.path,
            windowID: 7,
            bridgeInstaller: { _ in bridgeURL },
            controllerFactory: { workspacePath, modelString, _, _, _, _ in
                let registrar = PiRPCClient.ExpectedAgentPIDRegistrar(
                    register: { pid, _, _ in
                        await pidRecorder.record(.register(pid))
                    },
                    clear: { pid, _, _ in
                        await cleanupGate.waitUntilOpen()
                        await pidRecorder.record(.clear(pid))
                    }
                )
                let client = PiRPCClient(
                    config: .init(
                        commandName: scriptURL.path,
                        additionalPathHints: [],
                        requestTimeout: 2,
                        workingDirectory: workspacePath,
                        launchArguments: [],
                        requiresSupportedVersionCheck: false
                    ),
                    expectedAgentPIDRegistrar: registrar
                )
                return PiNativeSessionController(
                    client: client,
                    options: .init(
                        modelRaw: modelString,
                        requestTimeout: 2,
                        launchArguments: [],
                        terminalCompletionGraceInterval: 0
                    )
                )
            }
        )
        addTeardownBlock {
            await cleanupGate.release()
            await provider.dispose()
        }

        let stream = try await provider.streamAgentMessage(
            AgentMessage(systemPrompt: "", userMessage: "Build a context brief."),
            runID: UUID()
        )
        let consumer = Task { () async -> Error? in
            do {
                for try await _ in stream {}
                return nil
            } catch {
                await completionProbe.markCompleted()
                return error
            }
        }

        let didStartCleanup = await eventually {
            await cleanupGate.hasClearStarted()
        }
        guard didStartCleanup else {
            await cleanupGate.release()
            consumer.cancel()
            _ = await consumer.value
            XCTFail("Expected error stream completion to start pi RPC shutdown.")
            return
        }

        let didFinishBeforeCleanup = await completionProbe.isCompleted()
        XCTAssertFalse(
            didFinishBeforeCleanup,
            "Error stream completion must wait for pi RPC shutdown instead of finishing before expected-PID cleanup."
        )

        await cleanupGate.release()
        let error = await consumer.value
        XCTAssertTrue(String(describing: error).contains("simulated extension failure"))
        let didRecordClear = await eventually {
            let events = await pidRecorder.events()
            return events.count == 2
        }
        XCTAssertTrue(didRecordClear)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PiHeadlessAgentProviderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        temporaryURLs.append(url)
        return url
    }

    private func makeFakePiRPCScript(recordURL: URL, errorAfterPrompt: Bool = false, stallAfterPrompt: Bool = false) throws -> URL {
        let directory = recordURL.deletingLastPathComponent()
        let scriptURL = directory.appendingPathComponent("fake_pi_headless_rpc.py")
        let recordPath = recordURL.path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script = #"""
        #!/usr/bin/env python3
        import json
        import sys

        RECORD_PATH = "__RECORD_PATH__"
        ERROR_AFTER_PROMPT = __ERROR_AFTER_PROMPT__
        STALL_AFTER_PROMPT = __STALL_AFTER_PROMPT__

        def record(payload):
            with open(RECORD_PATH, "a", encoding="utf-8") as handle:
                handle.write(json.dumps(payload) + "\n")

        def emit(payload):
            print(json.dumps(payload), flush=True)

        def state(request_id):
            emit({
                "type": "response",
                "id": request_id,
                "command": "get_state",
                "success": True,
                "data": {
                    "sessionId": "pi-headless-session",
                    "sessionFile": "/tmp/pi-headless.jsonl",
                    "thinkingLevel": "high",
                    "isStreaming": False,
                    "isCompacting": False,
                    "messageCount": 1,
                    "pendingMessageCount": 0,
                    "model": {"provider": "zai", "id": "glm-5.2", "displayName": "GLM 5.2"}
                }
            })

        for line in sys.stdin:
            try:
                request = json.loads(line)
            except Exception:
                continue
            command = request.get("type")
            request_id = request.get("id")
            record(request)
            if command == "set_model":
                emit({"type": "response", "id": request_id, "command": "set_model", "success": True, "data": {"provider": request.get("provider"), "id": request.get("modelId")}})
            elif command == "set_thinking_level":
                emit({"type": "response", "id": request_id, "command": "set_thinking_level", "success": True})
            elif command == "get_available_models":
                emit({"type": "response", "id": request_id, "command": "get_available_models", "success": True, "data": {"models": [{"provider": "zai", "id": "glm-5.2", "displayName": "GLM 5.2"}]}})
            elif command == "get_state":
                state(request_id)
            elif command == "prompt":
                if ERROR_AFTER_PROMPT:
                    emit({"type": "response", "id": request_id, "command": "prompt", "success": True})
                    emit({"type": "extension_error", "error": "simulated extension failure"})
                    continue
                emit({"type": "turn_start"})
                if STALL_AFTER_PROMPT:
                    emit({"type": "response", "id": request_id, "command": "prompt", "success": True})
                    continue
                emit({"type": "message_update", "assistantMessageEvent": {"type": "thinking_delta", "contentIndex": 0, "delta": "pi is thinking"}})
                emit({"type": "tool_execution_start", "toolCallId": "tool-1", "toolName": "get_file_tree", "args": {"type": "roots"}})
                emit({"type": "tool_execution_end", "toolCallId": "tool-1", "toolName": "get_file_tree", "result": {"content": [{"type": "text", "text": "tree ok"}]}, "isError": False})
                emit({"type": "message_update", "assistantMessageEvent": {"type": "text_delta", "contentIndex": 1, "delta": "context ready"}})
                emit({"type": "turn_end", "toolResults": []})
                emit({"type": "response", "id": request_id, "command": "prompt", "success": True})
                emit({"type": "agent_end", "messages": []})
            elif command == "abort":
                emit({"type": "response", "id": request_id, "command": "abort", "success": True})
            else:
                emit({"type": "response", "id": request_id, "command": command, "success": True})
        """#
        .replacingOccurrences(of: "__RECORD_PATH__", with: recordPath)
        .replacingOccurrences(of: "__ERROR_AFTER_PROMPT__", with: errorAfterPrompt ? "True" : "False")
        .replacingOccurrences(of: "__STALL_AFTER_PROMPT__", with: stallAfterPrompt ? "True" : "False")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        return scriptURL
    }

    private struct RecordedCommand {
        let type: String
        let provider: String?
        let modelID: String?
        let level: String?
        let message: String?
    }

    private func recordedCommands(at url: URL) -> [RecordedCommand] {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8)
        else { return [] }
        return text.split(whereSeparator: { $0.isNewline }).compactMap { line in
            guard let data = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = object["type"] as? String
            else { return nil }
            return RecordedCommand(
                type: type,
                provider: object["provider"] as? String,
                modelID: object["modelId"] as? String,
                level: object["level"] as? String,
                message: object["message"] as? String
            )
        }
    }

    private func eventually(
        timeout: TimeInterval = 2,
        intervalNanoseconds: UInt64 = 20_000_000,
        _ condition: () async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: intervalNanoseconds)
        }
        return await condition()
    }
}
