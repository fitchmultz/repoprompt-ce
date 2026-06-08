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
            launchArguments: []
        ))
        let controller = PiNativeSessionController(
            client: client,
            options: .init(modelRaw: "zai/glm-5.1:high", requestTimeout: 2)
        )
        defer { Task { await controller.shutdown() } }

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

    func testPromptMapsPiRPCEventsToNativeStreamResultsAndTurnCompletion() async throws {
        let directory = try makeTemporaryDirectory()
        let scriptURL = try makeFakePiControllerScript(recordURL: directory.appendingPathComponent("commands.jsonl"))
        let client = PiRPCClient(config: .init(
            commandName: scriptURL.path,
            additionalPathHints: [],
            requestTimeout: 2,
            launchArguments: []
        ))
        let controller = PiNativeSessionController(client: client, options: .init(requestTimeout: 2))
        defer { Task { await controller.shutdown() } }
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

    func testBridgeToolResultUsesInnerRawJSONForTranscriptPayload() async throws {
        let directory = try makeTemporaryDirectory()
        let scriptURL = try makeFakePiControllerScript(recordURL: directory.appendingPathComponent("commands.jsonl"))
        let client = PiRPCClient(config: .init(
            commandName: scriptURL.path,
            additionalPathHints: [],
            requestTimeout: 2,
            launchArguments: []
        ))
        let controller = PiNativeSessionController(client: client, options: .init(requestTimeout: 2))
        defer { Task { await controller.shutdown() } }
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
            launchArguments: []
        ))
        let controller = PiNativeSessionController(client: client, options: .init(requestTimeout: 2))
        defer { Task { await controller.shutdown() } }
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

        def state(request_id):
            emit({
                "type": "response",
                "id": request_id,
                "command": "get_state",
                "success": True,
                "data": {
                    "sessionId": "pi-session-id",
                    "sessionFile": "/tmp/pi-session.jsonl",
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
                if request.get("message") == "bridge-result":
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
                emit({"type": "response", "id": request_id, "command": "switch_session", "success": True, "data": {"cancelled": False}})
            else:
                emit({"type": "response", "id": request_id, "command": command, "success": True})
        """#.replacingOccurrences(of: "__RECORD_PATH__", with: recordPath)
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        return scriptURL
    }

    private struct RecordedCommand {
        let type: String
        let provider: String?
        let modelID: String?
        let level: String?
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
                level: object["level"] as? String
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
