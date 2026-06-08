@testable import RepoPrompt
import XCTest

final class PiRPCClientTests: XCTestCase {
    private var temporaryURLs: [URL] = []

    override func tearDown() {
        for url in temporaryURLs {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryURLs.removeAll()
        super.tearDown()
    }

    func testStateAndModelDiscoveryParseRPCResponses() async throws {
        let scriptURL = try makeFakePiRPCScript()
        let client = PiRPCClient(config: .init(
            commandName: scriptURL.path,
            additionalPathHints: [],
            requestTimeout: 2,
            launchArguments: []
        ))
        defer { Task { await client.shutdown() } }

        let state = try await client.getState()
        XCTAssertEqual(state.sessionID, "session-123")
        XCTAssertEqual(state.sessionFile, "/tmp/pi-session.jsonl")
        XCTAssertEqual(state.thinkingLevel, "high")
        XCTAssertFalse(state.isStreaming)
        XCTAssertEqual(state.model?.provider, "zai")
        XCTAssertEqual(state.model?.id, "glm-5.1")

        let models = try await client.getAvailableModels()
        XCTAssertEqual(models.map(\.provider), ["zai", "cursor"])
        XCTAssertEqual(models.map(\.id), ["glm-5.1", "composer-2-5"])
        XCTAssertEqual(models.map(\.displayName), ["GLM 5.1", "Composer 2.5"])
    }

    func testPromptStreamsEventsBeforePromptResponse() async throws {
        let scriptURL = try makeFakePiRPCScript()
        let client = PiRPCClient(config: .init(
            commandName: scriptURL.path,
            additionalPathHints: [],
            requestTimeout: 2,
            launchArguments: []
        ))
        defer { Task { await client.shutdown() } }

        let events = await client.events
        let collector = Task { () -> [PiRPCClient.Event] in
            var collected: [PiRPCClient.Event] = []
            for await event in events {
                collected.append(event)
                if collected.count >= 4 { break }
            }
            return collected
        }

        let response = try await client.prompt("hello")
        XCTAssertEqual(response["command"]?.stringValue, "prompt")

        let collected = await collector.value
        XCTAssertTrue(collected.contains(.agentStart))
        XCTAssertTrue(collected.contains(.extensionUIRequest(.init(
            id: "status-1",
            method: "setStatus",
            title: nil,
            message: nil,
            statusKey: "fake",
            statusText: "running",
            raw: [
                "type": .string("extension_ui_request"),
                "id": .string("status-1"),
                "method": .string("setStatus"),
                "statusKey": .string("fake"),
                "statusText": .string("running")
            ]
        ))))
        XCTAssertTrue(collected.contains(.messageUpdate(.init(
            type: "text_delta",
            contentIndex: 0,
            delta: "hello back",
            content: nil,
            reason: nil,
            toolCall: nil,
            partial: nil,
            raw: [
                "type": .string("text_delta"),
                "contentIndex": .number(0),
                "delta": .string("hello back")
            ]
        ))))
        XCTAssertTrue(collected.contains(.turnEnd(message: nil, toolResults: [])))
    }

    func testClientSurfacesFailedRPCResponse() async throws {
        let scriptURL = try makeFakePiRPCScript()
        let client = PiRPCClient(config: .init(
            commandName: scriptURL.path,
            additionalPathHints: [],
            requestTimeout: 2,
            launchArguments: []
        ))
        defer { Task { await client.shutdown() } }

        do {
            _ = try await client.setThinkingLevel("explode")
            XCTFail("Expected failed pi RPC response")
        } catch let error as PiRPCClient.ClientError {
            XCTAssertEqual(error, .requestFailed("bad thinking level"))
        }
    }

    func testExtensionUIResponsePreservesOriginalRequestID() async throws {
        let directory = try makeTemporaryDirectory()
        let recordURL = directory.appendingPathComponent("ui-responses.jsonl")
        let scriptURL = try makeFakePiUIResponseRecorderScript(recordURL: recordURL)
        let client = PiRPCClient(config: .init(
            commandName: scriptURL.path,
            additionalPathHints: [],
            requestTimeout: 2,
            launchArguments: []
        ))
        defer { Task { await client.shutdown() } }

        try await client.respondToExtensionUIRequest(.value(id: "ui-request-1", "accepted"))
        let recorded = try await waitForRecordedObjects(at: recordURL, count: 1)

        XCTAssertEqual(recorded.first?["type"] as? String, "extension_ui_response")
        XCTAssertEqual(recorded.first?["id"] as? String, "ui-request-1")
        XCTAssertEqual(recorded.first?["value"] as? String, "accepted")
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PiRPCClientTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        temporaryURLs.append(url)
        return url
    }

    private func makeFakePiRPCScript() throws -> URL {
        let directory = try makeTemporaryDirectory()
        let scriptURL = directory.appendingPathComponent("fake_pi_rpc.py")
        let script = #"""
        #!/usr/bin/env python3
        import json
        import sys

        def emit(payload):
            print(json.dumps(payload), flush=True)

        for line in sys.stdin:
            try:
                request = json.loads(line)
            except Exception:
                continue
            request_id = request.get("id")
            command = request.get("type")
            if command == "get_state":
                emit({
                    "type": "response",
                    "id": request_id,
                    "command": "get_state",
                    "success": True,
                    "data": {
                        "sessionId": "session-123",
                        "sessionFile": "/tmp/pi-session.jsonl",
                        "thinkingLevel": "high",
                        "isStreaming": False,
                        "isCompacting": False,
                        "messageCount": 3,
                        "pendingMessageCount": 0,
                        "model": {"provider": "zai", "id": "glm-5.1", "displayName": "GLM 5.1"}
                    }
                })
            elif command == "get_available_models":
                emit({
                    "type": "response",
                    "id": request_id,
                    "command": "get_available_models",
                    "success": True,
                    "data": {"models": [
                        {"provider": "zai", "id": "glm-5.1", "displayName": "GLM 5.1"},
                        {"provider": "cursor", "id": "composer-2-5", "displayName": "Composer 2.5"}
                    ]}
                })
            elif command == "prompt":
                emit({"type": "agent_start"})
                emit({
                    "type": "extension_ui_request",
                    "id": "status-1",
                    "method": "setStatus",
                    "statusKey": "fake",
                    "statusText": "running"
                })
                emit({
                    "type": "message_update",
                    "assistantMessageEvent": {"type": "text_delta", "contentIndex": 0, "delta": "hello back"}
                })
                emit({"type": "turn_end", "toolResults": []})
                emit({"type": "response", "id": request_id, "command": "prompt", "success": True})
            elif command == "set_thinking_level":
                emit({
                    "type": "response",
                    "id": request_id,
                    "command": "set_thinking_level",
                    "success": False,
                    "error": "bad thinking level"
                })
            else:
                emit({"type": "response", "id": request_id, "command": command, "success": True})
        """#
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        return scriptURL
    }

    private func makeFakePiUIResponseRecorderScript(recordURL: URL) throws -> URL {
        let scriptURL = recordURL.deletingLastPathComponent().appendingPathComponent("fake_pi_ui_response_rpc.py")
        let recordPath = recordURL.path
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = #"""
        #!/usr/bin/env python3
        import json
        import sys

        RECORD_PATH = "__RECORD_PATH__"

        for line in sys.stdin:
            try:
                request = json.loads(line)
            except Exception:
                continue
            with open(RECORD_PATH, "a", encoding="utf-8") as handle:
                handle.write(json.dumps(request) + "\n")
            if request.get("type") == "extension_ui_response":
                continue
            print(json.dumps({"type": "response", "id": request.get("id"), "command": request.get("type"), "success": True}), flush=True)
        """#.replacingOccurrences(of: "__RECORD_PATH__", with: recordPath)
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        return scriptURL
    }

    private func waitForRecordedObjects(at url: URL, count: Int) async throws -> [[String: Any]] {
        for _ in 0 ..< 40 {
            let objects = recordedObjects(at: url)
            if objects.count >= count { return objects }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        return recordedObjects(at: url)
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
}
