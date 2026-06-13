@testable import RepoPrompt
import XCTest

final class PiCLIProviderTests: XCTestCase {
    private var temporaryURLs: [URL] = []

    override func tearDown() {
        for url in temporaryURLs {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryURLs.removeAll()
        AgentPiModelRegistry.shared.test_reset()
        super.tearDown()
    }

    func testCLIProviderForwardsExactlyOneMessageStopPerTurn() async throws {
        let directory = try makeTemporaryDirectory()
        let scriptURL = try makeFakePiRPCScript(recordURL: directory.appendingPathComponent("commands.jsonl"))
        let provider = PiCLIProvider { modelString in
            let client = PiRPCClient(config: .init(
                commandName: scriptURL.path,
                additionalPathHints: [],
                requestTimeout: 2,
                launchArguments: [],
                requiresSupportedVersionCheck: false
            ))
            return PiNativeSessionController(
                client: client,
                options: .init(modelRaw: modelString, requestTimeout: 2, launchArguments: [])
            )
        }
        addTeardownBlock { await provider.dispose() }

        let stream = try await provider.streamMessage(
            AIMessage(systemPrompt: "Reply briefly.", userMessage: "Hello"),
            model: .piCustom(name: "zai/glm-5.1")
        )

        var results: [AIStreamResult] = []
        for try await result in stream {
            results.append(result)
        }

        XCTAssertTrue(results.contains { $0.type == "content" && $0.text == "oracle ready" })
        let stops = results.filter { $0.type == "message_stop" }
        XCTAssertEqual(stops.count, 1)
        XCTAssertEqual(stops.first?.stopReason, "end_turn")
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PiCLIProviderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        temporaryURLs.append(url)
        return url
    }

    private func makeFakePiRPCScript(recordURL: URL) throws -> URL {
        let directory = recordURL.deletingLastPathComponent()
        let scriptURL = directory.appendingPathComponent("fake_pi_cli_rpc.py")
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
                    "sessionId": "pi-cli-session",
                    "sessionFile": "/tmp/pi-cli.jsonl",
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
            elif command == "get_available_models":
                emit({"type": "response", "id": request_id, "command": "get_available_models", "success": True, "data": {"models": [{"provider": "zai", "id": "glm-5.1", "displayName": "GLM 5.1"}]}})
            elif command == "get_state":
                state(request_id)
            elif command == "prompt":
                emit({"type": "turn_start"})
                emit({"type": "message_update", "assistantMessageEvent": {"type": "text_delta", "contentIndex": 0, "delta": "oracle ready"}})
                emit({"type": "message_end", "message": {"role": "assistant", "content": "oracle ready", "usage": {"input": 4, "output": 2, "totalTokens": 6}}})
                emit({"type": "turn_end", "toolResults": []})
                emit({"type": "response", "id": request_id, "command": "prompt", "success": True})
                emit({"type": "agent_end", "messages": [], "willRetry": False})
            elif command == "abort":
                emit({"type": "response", "id": request_id, "command": "abort", "success": True})
            else:
                emit({"type": "response", "id": request_id, "command": command, "success": True})
        """#.replacingOccurrences(of: "__RECORD_PATH__", with: recordPath)
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        return scriptURL
    }
}
