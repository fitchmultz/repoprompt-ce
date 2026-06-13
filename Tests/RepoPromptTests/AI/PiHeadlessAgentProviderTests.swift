@testable import RepoPrompt
import XCTest

final class PiHeadlessAgentProviderTests: XCTestCase {
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
            modelString: "zai/glm-5.1:high",
            workspacePath: directory.path,
            windowID: 7,
            bridgeInstaller: { windowID in
                XCTAssertEqual(windowID, 7)
                return bridgeURL
            },
            controllerFactory: { workspacePath, modelString, enableDebugLogging, installedBridgeURL in
                XCTAssertEqual(workspacePath, directory.path)
                XCTAssertEqual(modelString, "zai/glm-5.1:high")
                XCTAssertFalse(enableDebugLogging)
                XCTAssertEqual(installedBridgeURL, bridgeURL)
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
        XCTAssertTrue(recordedCommands(at: recordURL).contains { $0.type == "set_model" && $0.provider == "zai" && $0.modelID == "glm-5.1" })
        XCTAssertTrue(recordedCommands(at: recordURL).contains { $0.type == "set_thinking_level" && $0.level == "high" })
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PiHeadlessAgentProviderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        temporaryURLs.append(url)
        return url
    }

    private func makeFakePiRPCScript(recordURL: URL) throws -> URL {
        let directory = recordURL.deletingLastPathComponent()
        let scriptURL = directory.appendingPathComponent("fake_pi_headless_rpc.py")
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
                    "sessionId": "pi-headless-session",
                    "sessionFile": "/tmp/pi-headless.jsonl",
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
            elif command == "get_available_models":
                emit({"type": "response", "id": request_id, "command": "get_available_models", "success": True, "data": {"models": [{"provider": "zai", "id": "glm-5.1", "displayName": "GLM 5.1"}]}})
            elif command == "get_state":
                state(request_id)
            elif command == "prompt":
                emit({"type": "turn_start"})
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
}
