@testable import RepoPrompt
import XCTest

final class PiNativeSessionControllerTests: XCTestCase {
    private var temporaryURLs: [URL] = []

    override func tearDown() {
        for url in temporaryURLs {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryURLs.removeAll()
        super.tearDown()
    }

    func testStartAppliesProviderModelThinkingAndCapturesSessionRef() async throws {
        let directory = try makeTemporaryDirectory()
        let recordURL = directory.appendingPathComponent("commands.jsonl")
        let scriptURL = try makeFakePiControllerScript(recordURL: recordURL)
        let client = PiRPCClient(config: .init(
            commandName: scriptURL.path,
            additionalPathHints: [],
            requestTimeout: 2,
            launchArguments: [],
            requiresSupportedVersionCheck: false
        ))
        let controller = PiNativeSessionController(
            client: client,
            options: .init(modelRaw: "zai/glm-5.1:high", requestTimeout: 2)
        )
        addTeardownBlock { await controller.shutdown() }

        let ref = try await controller.startOrResume(existing: nil)

        XCTAssertEqual(ref.sessionID, "pi-session-id")
        XCTAssertEqual(ref.sessionFile, "/tmp/pi-session.jsonl")
        XCTAssertEqual(ref.model, "zai/glm-5.1")
        XCTAssertEqual(ref.thinkingLevel, "high")
        let commands = recordedCommands(at: recordURL)
        XCTAssertEqual(commands.prefix(3).map(\.type), ["set_model", "set_thinking_level", "get_state"])
        XCTAssertEqual(commands.first?.provider, "zai")
        XCTAssertEqual(commands.first?.modelID, "glm-5.1")
        XCTAssertEqual(commands.dropFirst().first?.level, "high")
    }

    func testCancelledSessionSwitchFailsWithoutOverwritingState() async throws {
        let directory = try makeTemporaryDirectory()
        let recordURL = directory.appendingPathComponent("commands.jsonl")
        let scriptURL = try makeFakePiControllerScript(recordURL: recordURL)
        let client = PiRPCClient(config: .init(
            commandName: scriptURL.path,
            additionalPathHints: [],
            requestTimeout: 2,
            launchArguments: [],
            requiresSupportedVersionCheck: false
        ))
        let controller = PiNativeSessionController(client: client, options: .init(requestTimeout: 2))
        addTeardownBlock { await controller.shutdown() }

        do {
            _ = try await controller.startOrResume(existing: .init(
                sessionID: "existing-session-id",
                sessionFile: "/tmp/cancelled.jsonl",
                model: nil,
                thinkingLevel: nil
            ))
            XCTFail("Expected cancelled pi session switch to throw")
        } catch let error as PiNativeSessionController.ControllerError {
            XCTAssertEqual(error, .sessionSwitchCancelled("/tmp/cancelled.jsonl"))
        }

        let commands = recordedCommands(at: recordURL)
        XCTAssertEqual(commands.map(\.type), ["switch_session"])
        XCTAssertEqual(commands.first?.sessionPath, "/tmp/cancelled.jsonl")
        let currentRef = await controller.currentSessionRef()
        XCTAssertNil(currentRef)
    }

    func testPromptMapsPiRPCEventsToNativeStreamResultsAndTurnCompletion() async throws {
        let directory = try makeTemporaryDirectory()
        let scriptURL = try makeFakePiControllerScript(recordURL: directory.appendingPathComponent("commands.jsonl"))
        let client = PiRPCClient(config: .init(
            commandName: scriptURL.path,
            additionalPathHints: [],
            requestTimeout: 2,
            launchArguments: [],
            requiresSupportedVersionCheck: false
        ))
        let controller = PiNativeSessionController(client: client, options: .init(requestTimeout: 2))
        addTeardownBlock { await controller.shutdown() }
        _ = try await controller.startOrResume(existing: nil)

        let stream = await controller.events
        let collector = Task { () -> [PiNativeSessionController.Event] in
            var events: [PiNativeSessionController.Event] = []
            for await event in stream {
                events.append(event)
                if case .turnCompleted = event { break }
            }
            return events
        }

        let turnID = try await controller.sendUserMessage("hello")
        let events = await collector.value

        let streamResults = events.compactMap { event -> AIStreamResult? in
            if case let .stream(result) = event { return result }
            return nil
        }
        XCTAssertTrue(streamResults.contains { $0.reasoning == "thinking..." })
        XCTAssertTrue(streamResults.contains { $0.type == "content" && $0.text == "hello back" })
        XCTAssertTrue(streamResults.contains { $0.type == "tool_call" && $0.toolName == "bash" && $0.toolArgsJSON?.contains("echo hi") == true })
        XCTAssertTrue(streamResults.contains { $0.type == "tool_result" && $0.toolName == "bash" && $0.toolOutput == "hi" && $0.toolIsError == false })
        XCTAssertTrue(streamResults.contains { $0.type == "message_stop" && $0.stopReason == "end_turn" })
        XCTAssertTrue(events.contains { event in
            if case let .turnCompleted(completedTurnID, status) = event {
                return completedTurnID == turnID && status == .completed
            }
            return false
        })
    }

    func testPromptSteerAndFollowUpSendImagePayloads() async throws {
        let directory = try makeTemporaryDirectory()
        let recordURL = directory.appendingPathComponent("commands.jsonl")
        let imageURL = directory.appendingPathComponent("fixture.png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: imageURL)
        let expectedBase64 = try Data(contentsOf: imageURL).base64EncodedString()
        let scriptURL = try makeFakePiControllerScript(recordURL: recordURL)
        let client = PiRPCClient(config: .init(
            commandName: scriptURL.path,
            additionalPathHints: [],
            requestTimeout: 2,
            launchArguments: [],
            requiresSupportedVersionCheck: false
        ))
        let controller = PiNativeSessionController(client: client, options: .init(requestTimeout: 2))
        addTeardownBlock { await controller.shutdown() }
        _ = try await controller.startOrResume(existing: nil)

        let images = try PiRPCImageContentBuilder.images(from: [
            AgentImageAttachment(source: .localFile(path: imageURL.path), title: "fixture.png")
        ])

        _ = try await controller.sendUserMessage("image prompt", images: images)
        try await controller.steer("image steer", images: images)
        try await controller.followUp("image follow", images: images)

        let commands = recordedObjects(at: recordURL)
        try assertImagePayload(
            in: XCTUnwrap(commands.first { $0["type"] as? String == "prompt" }),
            expectedBase64: expectedBase64
        )
        try assertImagePayload(
            in: XCTUnwrap(commands.first { $0["type"] as? String == "steer" }),
            expectedBase64: expectedBase64
        )
        try assertImagePayload(
            in: XCTUnwrap(commands.first { $0["type"] as? String == "follow_up" }),
            expectedBase64: expectedBase64
        )
    }

    func testPiImageBuilderRejectsRemoteURLsAndOversizedLocalImages() throws {
        XCTAssertThrowsError(try PiRPCImageContentBuilder.images(from: [
            AgentImageAttachment(source: .url("https://example.com/image.png"), title: "image.png")
        ])) { error in
            XCTAssertEqual(
                error as? PiRPCImageContentBuilder.Error,
                .unsupportedRemoteImageURL("https://example.com/image.png")
            )
        }

        let directory = try makeTemporaryDirectory()
        let imageURL = directory.appendingPathComponent("huge.png")
        try Data(repeating: 0x41, count: PiRPCImageContentBuilder.maxImageBytes + 1).write(to: imageURL)

        XCTAssertThrowsError(try PiRPCImageContentBuilder.images(from: [
            AgentImageAttachment(source: .localFile(path: imageURL.path), title: "huge.png")
        ])) { error in
            XCTAssertEqual(
                error as? PiRPCImageContentBuilder.Error,
                .localImageTooLarge(
                    path: imageURL.path,
                    byteCount: PiRPCImageContentBuilder.maxImageBytes + 1,
                    maxBytes: PiRPCImageContentBuilder.maxImageBytes
                )
            )
        }
    }

    func testTextOnlyPromptSteerAndFollowUpOmitImagePayloads() async throws {
        let directory = try makeTemporaryDirectory()
        let recordURL = directory.appendingPathComponent("commands.jsonl")
        let scriptURL = try makeFakePiControllerScript(recordURL: recordURL)
        let client = PiRPCClient(config: .init(
            commandName: scriptURL.path,
            additionalPathHints: [],
            requestTimeout: 2,
            launchArguments: [],
            requiresSupportedVersionCheck: false
        ))
        let controller = PiNativeSessionController(client: client, options: .init(requestTimeout: 2))
        addTeardownBlock { await controller.shutdown() }
        _ = try await controller.startOrResume(existing: nil)

        _ = try await controller.sendUserMessage("text prompt")
        try await controller.steer("text steer")
        try await controller.followUp("text follow")

        let commands = recordedObjects(at: recordURL)
        XCTAssertNil(commands.first { $0["type"] as? String == "prompt" }?["images"])
        XCTAssertNil(commands.first { $0["type"] as? String == "steer" }?["images"])
        XCTAssertNil(commands.first { $0["type"] as? String == "follow_up" }?["images"])
    }

    func testAgentEndRefreshesSessionStateForProviderSideSessionChanges() async throws {
        let directory = try makeTemporaryDirectory()
        let recordURL = directory.appendingPathComponent("commands.jsonl")
        let scriptURL = try makeFakePiControllerScript(recordURL: recordURL)
        let client = PiRPCClient(config: .init(
            commandName: scriptURL.path,
            additionalPathHints: [],
            requestTimeout: 2,
            launchArguments: [],
            requiresSupportedVersionCheck: false
        ))
        let controller = PiNativeSessionController(client: client, options: .init(requestTimeout: 2))
        addTeardownBlock { await controller.shutdown() }
        _ = try await controller.startOrResume(existing: nil)

        let stream = await controller.events
        let collector = Task { () -> [PiNativeSessionController.Event] in
            var events: [PiNativeSessionController.Event] = []
            for await event in stream {
                events.append(event)
                if case .turnCompleted = event { break }
            }
            return events
        }

        _ = try await controller.sendUserMessage("state-change")
        let events = await collector.value
        let states = events.compactMap { event -> PiRPCClient.SessionState? in
            if case let .sessionState(state) = event { return state }
            return nil
        }

        XCTAssertGreaterThanOrEqual(recordedCommands(at: recordURL).map(\.type).count(where: { $0 == "get_state" }), 2)
        XCTAssertEqual(states.last?.sessionID, "pi-session-id-updated")
        XCTAssertEqual(states.last?.sessionFile, "/tmp/pi-session-updated.jsonl")
        let currentRef = await controller.currentSessionRef()
        XCTAssertEqual(currentRef?.sessionID, "pi-session-id-updated")
        XCTAssertEqual(currentRef?.sessionFile, "/tmp/pi-session-updated.jsonl")
    }

    func testToolInvocationIDsTrackInterleavedRepeatedToolNames() async throws {
        let directory = try makeTemporaryDirectory()
        let scriptURL = try makeFakePiControllerScript(recordURL: directory.appendingPathComponent("commands.jsonl"))
        let client = PiRPCClient(config: .init(
            commandName: scriptURL.path,
            additionalPathHints: [],
            requestTimeout: 2,
            launchArguments: [],
            requiresSupportedVersionCheck: false
        ))
        let controller = PiNativeSessionController(client: client, options: .init(requestTimeout: 2))
        addTeardownBlock { await controller.shutdown() }
        _ = try await controller.startOrResume(existing: nil)

        let stream = await controller.events
        let collector = Task { () -> [PiNativeSessionController.Event] in
            var events: [PiNativeSessionController.Event] = []
            for await event in stream {
                events.append(event)
                if case .turnCompleted = event { break }
            }
            return events
        }

        _ = try await controller.sendUserMessage("interleaved-tools")
        let streamResults = await collector.value.compactMap { event -> AIStreamResult? in
            if case let .stream(result) = event { return result }
            return nil
        }

        let firstCall = streamResults.first { $0.type == "tool_call" && $0.toolArgsJSON?.contains("one") == true }
        let secondCall = streamResults.first { $0.type == "tool_call" && $0.toolArgsJSON?.contains("two") == true }
        XCTAssertEqual(firstCall?.toolName, "bash")
        XCTAssertEqual(secondCall?.toolName, "bash")
        let firstInvocationID = try XCTUnwrap(firstCall?.toolInvocationID)
        let secondInvocationID = try XCTUnwrap(secondCall?.toolInvocationID)
        XCTAssertNotEqual(firstInvocationID, secondInvocationID)

        let firstResults = streamResults.filter { $0.type == "tool_result" && ($0.toolOutput?.hasPrefix("one") ?? false) }
        let secondResults = streamResults.filter { $0.type == "tool_result" && ($0.toolOutput?.hasPrefix("two") ?? false) }
        XCTAssertFalse(firstResults.isEmpty)
        XCTAssertFalse(secondResults.isEmpty)
        for result in firstResults {
            XCTAssertEqual(try XCTUnwrap(result.toolInvocationID), firstInvocationID)
        }
        for result in secondResults {
            XCTAssertEqual(try XCTUnwrap(result.toolInvocationID), secondInvocationID)
        }
    }

    func testBridgeToolResultUsesInnerRawJSONForTranscriptPayload() async throws {
        let directory = try makeTemporaryDirectory()
        let scriptURL = try makeFakePiControllerScript(recordURL: directory.appendingPathComponent("commands.jsonl"))
        let client = PiRPCClient(config: .init(
            commandName: scriptURL.path,
            additionalPathHints: [],
            requestTimeout: 2,
            launchArguments: [],
            requiresSupportedVersionCheck: false
        ))
        let controller = PiNativeSessionController(client: client, options: .init(requestTimeout: 2))
        addTeardownBlock { await controller.shutdown() }
        _ = try await controller.startOrResume(existing: nil)

        let stream = await controller.events
        let collector = Task { () -> [PiNativeSessionController.Event] in
            var events: [PiNativeSessionController.Event] = []
            for await event in stream {
                events.append(event)
                if case .turnCompleted = event { break }
            }
            return events
        }

        _ = try await controller.sendUserMessage("bridge-result")
        let events = await collector.value
        let result = events.compactMap { event -> AIStreamResult? in
            if case let .stream(result) = event,
               result.type == "tool_result",
               result.toolName == "get_file_tree",
               result.toolIsError == false
            {
                return result
            }
            return nil
        }.last

        XCTAssertEqual(result?.toolOutput, #"{"roots_count":1,"tree":"repoprompt-ce","uses_legend":false}"#)
        XCTAssertEqual(result?.toolResultJSON, #"{"roots_count":1,"tree":"repoprompt-ce","uses_legend":false}"#)
        XCTAssertFalse(result?.toolResultJSON?.contains("bridgeVersion") ?? true)
    }

    func testPromptWaitsForAgentEndAfterTurnEndBeforeCompleting() async throws {
        let directory = try makeTemporaryDirectory()
        let scriptURL = try makeFakePiControllerScript(recordURL: directory.appendingPathComponent("commands.jsonl"))
        let client = PiRPCClient(config: .init(
            commandName: scriptURL.path,
            additionalPathHints: [],
            requestTimeout: 2,
            launchArguments: [],
            requiresSupportedVersionCheck: false
        ))
        let controller = PiNativeSessionController(client: client, options: .init(requestTimeout: 2))
        addTeardownBlock { await controller.shutdown() }
        _ = try await controller.startOrResume(existing: nil)

        let stream = await controller.events
        let recorder = EventRecorder()
        let collector = Task {
            for await event in stream {
                await recorder.append(event)
            }
        }

        _ = try await controller.sendUserMessage("no-agent-end")
        try? await Task.sleep(nanoseconds: 100_000_000)
        let events = await recorder.events()

        XCTAssertFalse(events.contains { event in
            if case .turnCompleted = event { return true }
            return false
        }, "pi turn_end must not complete the RepoPrompt run before pi agent_end")
        collector.cancel()
    }

    func testModelSpecifierParsesProviderModelAndThinking() {
        XCTAssertEqual(
            PiModelSpecifier(raw: "zai/glm-5.1:high"),
            PiModelSpecifier(provider: "zai", modelID: "glm-5.1", thinkingLevel: "high")
        )
        XCTAssertEqual(
            PiModelSpecifier(raw: "openai-codex/gpt-5.5:low"),
            PiModelSpecifier(provider: "openai-codex", modelID: "gpt-5.5", thinkingLevel: "low")
        )
        XCTAssertEqual(PiModelSpecifier(raw: "openai-codex/gpt-5.5:low")?.providerQualifiedModelRaw, "openai-codex/gpt-5.5")
        XCTAssertEqual(
            PiModelSpecifier(raw: "cursor/composer-2-5"),
            PiModelSpecifier(provider: "cursor", modelID: "composer-2-5", thinkingLevel: nil)
        )
        XCTAssertEqual(
            PiModelSpecifier(raw: "glm-5.1"),
            PiModelSpecifier(provider: nil, modelID: "glm-5.1", thinkingLevel: nil)
        )
        XCTAssertNil(PiModelSpecifier(raw: "default"))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PiNativeSessionControllerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        temporaryURLs.append(url)
        return url
    }

    private func makeFakePiControllerScript(recordURL: URL) throws -> URL {
        let directory = recordURL.deletingLastPathComponent()
        let scriptURL = directory.appendingPathComponent("fake_pi_controller_rpc.py")
        let recordPath = recordURL.path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script = #"""
        #!/usr/bin/env python3
        import json
        import sys

        RECORD_PATH = "__RECORD_PATH__"

        def record(payload):
            with open(RECORD_PATH, "a", encoding="utf-8") as handle:
                handle.write(json.dumps(payload) + "\n")

        def emit(payload):
            print(json.dumps(payload), flush=True)

        SESSION_ID = "pi-session-id"
        SESSION_FILE = "/tmp/pi-session.jsonl"

        def state(request_id):
            emit({
                "type": "response",
                "id": request_id,
                "command": "get_state",
                "success": True,
                "data": {
                    "sessionId": SESSION_ID,
                    "sessionFile": SESSION_FILE,
                    "thinkingLevel": "high",
                    "isStreaming": False,
                    "isCompacting": False,
                    "messageCount": 1,
                    "pendingMessageCount": 0,
                    "model": {"provider": "zai", "id": "glm-5.1", "displayName": "GLM 5.1"}
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
            elif command == "get_state":
                state(request_id)
            elif command == "prompt":
                emit({"type": "turn_start"})
                if request.get("message") == "state-change":
                    SESSION_ID = "pi-session-id-updated"
                    SESSION_FILE = "/tmp/pi-session-updated.jsonl"
                    emit({"type": "message_update", "assistantMessageEvent": {"type": "text_delta", "contentIndex": 0, "delta": "state changed"}})
                elif request.get("message") == "interleaved-tools":
                    emit({"type": "tool_execution_start", "toolCallId": "call-a", "toolName": "bash", "args": {"command": "echo one"}})
                    emit({"type": "tool_execution_start", "toolCallId": "call-b", "toolName": "bash", "args": {"command": "echo two"}})
                    emit({"type": "tool_execution_update", "toolCallId": "call-a", "toolName": "bash", "partialResult": {"content": [{"type": "text", "text": "one partial"}]}})
                    emit({"type": "tool_execution_end", "toolCallId": "call-b", "toolName": "bash", "result": {"content": [{"type": "text", "text": "two done"}]}, "isError": False})
                    emit({"type": "tool_execution_end", "toolCallId": "call-a", "toolName": "bash", "result": {"content": [{"type": "text", "text": "one done"}]}, "isError": False})
                elif request.get("message") == "bridge-result":
                    inner = '{"roots_count":1,"tree":"repoprompt-ce","uses_legend":false}'
                    emit({"type": "tool_execution_start", "toolCallId": "call-1", "toolName": "get_file_tree", "args": {"type": "roots"}})
                    emit({"type": "tool_execution_end", "toolCallId": "call-1", "toolName": "get_file_tree", "result": {"content": [{"type": "text", "text": inner}], "details": {"bridgeVersion": "2", "tool": "get_file_tree", "exitCode": 0}}, "isError": False})
                else:
                    emit({"type": "message_update", "assistantMessageEvent": {"type": "thinking_delta", "contentIndex": 0, "delta": "thinking..."}})
                    emit({"type": "message_update", "assistantMessageEvent": {"type": "text_delta", "contentIndex": 1, "delta": "hello back"}})
                    emit({"type": "tool_execution_start", "toolCallId": "call-1", "toolName": "bash", "args": {"command": "echo hi"}})
                    emit({"type": "tool_execution_end", "toolCallId": "call-1", "toolName": "bash", "result": {"content": [{"type": "text", "text": "hi"}]}, "isError": False})
                emit({"type": "turn_end", "toolResults": []})
                emit({"type": "response", "id": request_id, "command": "prompt", "success": True})
                if request.get("message") != "no-agent-end":
                    emit({"type": "agent_end", "messages": []})
            elif command == "abort":
                emit({"type": "response", "id": request_id, "command": "abort", "success": True})
            elif command == "switch_session":
                cancelled = request.get("sessionPath") == "/tmp/cancelled.jsonl"
                emit({"type": "response", "id": request_id, "command": "switch_session", "success": True, "data": {"cancelled": cancelled}})
            else:
                emit({"type": "response", "id": request_id, "command": command, "success": True})
        """#.replacingOccurrences(of: "__RECORD_PATH__", with: recordPath)
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        return scriptURL
    }

    private func assertImagePayload(
        in command: [String: Any],
        expectedBase64: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let images = try XCTUnwrap(command["images"] as? [[String: Any]], file: file, line: line)
        XCTAssertEqual(images.count, 1, file: file, line: line)
        let image = try XCTUnwrap(images.first, file: file, line: line)
        XCTAssertEqual(image["type"] as? String, "image", file: file, line: line)
        XCTAssertEqual(image["data"] as? String, expectedBase64, file: file, line: line)
        XCTAssertEqual(image["mimeType"] as? String, "image/png", file: file, line: line)
    }

    private struct RecordedCommand {
        let type: String
        let provider: String?
        let modelID: String?
        let level: String?
        let sessionPath: String?
    }

    private func recordedObjects(at url: URL) -> [[String: Any]] {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8)
        else { return [] }
        return text.split(whereSeparator: { $0.isNewline }).compactMap { line in
            guard let data = String(line).data(using: .utf8) else { return nil }
            return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        }
    }

    private func recordedCommands(at url: URL) -> [RecordedCommand] {
        recordedObjects(at: url).compactMap { object in
            guard let type = object["type"] as? String else { return nil }
            return RecordedCommand(
                type: type,
                provider: object["provider"] as? String,
                modelID: object["modelId"] as? String,
                level: object["level"] as? String,
                sessionPath: object["sessionPath"] as? String
            )
        }
    }
}

private actor EventRecorder {
    private var collected: [PiNativeSessionController.Event] = []

    func append(_ event: PiNativeSessionController.Event) {
        collected.append(event)
    }

    func events() -> [PiNativeSessionController.Event] {
        collected
    }
}
