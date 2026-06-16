import Darwin
@testable import RepoPrompt
import XCTest

final class PiRPCClientTests: XCTestCase {
    private actor ExpectedPIDRecorder {
        struct Event: Equatable {
            enum Kind: Equatable {
                case register
                case clear
            }

            var kind: Kind
            var pid: pid_t
            var clientName: String
            var runID: UUID
        }

        private var recordedEvents: [Event] = []

        func record(_ kind: Event.Kind, pid: pid_t, clientName: String, runID: UUID) {
            recordedEvents.append(.init(kind: kind, pid: pid, clientName: clientName, runID: runID))
        }

        func events() -> [Event] {
            recordedEvents
        }
    }

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
            launchArguments: [],
            requiresSupportedVersionCheck: false
        ))
        addTeardownBlock { await client.shutdown() }

        let state = try await client.getState()
        XCTAssertEqual(state.sessionID, "session-123")
        XCTAssertEqual(state.sessionFile, "/tmp/pi-session.jsonl")
        XCTAssertEqual(state.thinkingLevel, "high")
        XCTAssertFalse(state.isStreaming)
        XCTAssertEqual(state.model?.provider, "zai")
        XCTAssertEqual(state.model?.id, "glm-5.2")

        let models = try await client.getAvailableModels()
        XCTAssertEqual(models.map(\.provider), ["zai", "cursor"])
        XCTAssertEqual(models.map(\.id), ["glm-5.2", "composer-2-5"])
        XCTAssertEqual(models.map(\.displayName), ["GLM 5.2", "Composer 2.5"])
    }

    func testPromptStreamsEventsBeforePromptResponse() async throws {
        let scriptURL = try makeFakePiRPCScript()
        let client = PiRPCClient(config: .init(
            commandName: scriptURL.path,
            additionalPathHints: [],
            requestTimeout: 2,
            launchArguments: [],
            requiresSupportedVersionCheck: false
        ))
        addTeardownBlock { await client.shutdown() }

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

    func testParsesCurrentSessionLifecycleEvents() async throws {
        let scriptURL = try makeFakePiCurrentEventsScript()
        let client = PiRPCClient(config: .init(
            commandName: scriptURL.path,
            additionalPathHints: [],
            requestTimeout: 2,
            launchArguments: [],
            requiresSupportedVersionCheck: false
        ))
        addTeardownBlock { await client.shutdown() }

        let events = await client.events
        let collector = Task { () -> [PiRPCClient.Event] in
            var collected: [PiRPCClient.Event] = []
            for await event in events {
                collected.append(event)
                if collected.count >= 7 { break }
            }
            return collected
        }

        _ = try await client.getState()
        let collected = await collector.value

        XCTAssertTrue(collected.contains(.agentEnd(
            messages: [["role": .string("assistant"), "content": .string("retrying")]],
            willRetry: true
        )))
        XCTAssertTrue(collected.contains(.autoRetryStart(
            attempt: 2,
            maxAttempts: 3,
            delayMs: 1000,
            errorMessage: "provider overloaded"
        )))
        XCTAssertTrue(collected.contains(.autoRetryEnd(success: true, attempt: 2, finalError: nil)))
        XCTAssertTrue(collected.contains(.compactionEnd(
            reason: "threshold",
            result: .object(["messageCount": .number(4)]),
            aborted: false,
            willRetry: true,
            errorMessage: "compaction failed"
        )))
        XCTAssertTrue(collected.contains(.thinkingLevelChanged(level: "high")))
        XCTAssertTrue(collected.contains(.sessionInfoChanged(name: "Renamed session")))
        XCTAssertTrue(collected.contains(.agentEnd(messages: [], willRetry: false)))
    }

    func testMutatingRequestTimeoutInvalidatesRPCProcessAndNextCommandRestarts() async throws {
        let scriptURL = try makeFakePiTimeoutScript(ignoredCommands: ["set_model"])
        let client = PiRPCClient(config: .init(
            commandName: scriptURL.path,
            additionalPathHints: [],
            requestTimeout: 0.2,
            launchArguments: [],
            requiresSupportedVersionCheck: false
        ))
        addTeardownBlock { await client.shutdown() }

        do {
            _ = try await client.setModel(provider: "zai", modelID: "glm-5.2")
            XCTFail("Expected mutating set_model to time out")
        } catch let error as PiRPCClient.ClientError {
            XCTAssertEqual(error, .requestTimedOut(id: "rp-pi-set_model-1", command: "set_model"))
        }
        let isRunningAfterTimeout = await client.isRunning
        XCTAssertFalse(isRunningAfterTimeout)

        let state = try await client.getState()
        XCTAssertEqual(state.sessionID, "timeout-session")
        let isRunningAfterRestart = await client.isRunning
        XCTAssertTrue(isRunningAfterRestart)
    }

    func testReadOnlyRequestTimeoutLeavesRPCProcessRunningForSubsequentCommands() async throws {
        let scriptURL = try makeFakePiTimeoutScript(ignoredCommands: ["get_state"])
        let client = PiRPCClient(config: .init(
            commandName: scriptURL.path,
            additionalPathHints: [],
            requestTimeout: 0.2,
            launchArguments: [],
            requiresSupportedVersionCheck: false
        ))
        addTeardownBlock { await client.shutdown() }

        do {
            _ = try await client.getState()
            XCTFail("Expected read-only get_state to time out")
        } catch let error as PiRPCClient.ClientError {
            XCTAssertEqual(error, .requestTimedOut(id: "rp-pi-get_state-1", command: "get_state"))
        }
        let isRunningAfterTimeout = await client.isRunning
        XCTAssertTrue(isRunningAfterTimeout)

        let models = try await client.getAvailableModels()
        XCTAssertEqual(models.map(\.id), ["glm-5.2"])
        let isRunningAfterFollowup = await client.isRunning
        XCTAssertTrue(isRunningAfterFollowup)
    }

    func testProtocolDiagnosticsSurfaceMalformedAndUnknownEventsWithRedactedPreviewAndThrottle() async throws {
        let scriptURL = try makeFakePiProtocolDiagnosticsScript()
        let client = PiRPCClient(config: .init(
            commandName: scriptURL.path,
            additionalPathHints: [],
            requestTimeout: 2,
            launchArguments: [],
            requiresSupportedVersionCheck: false
        ))
        addTeardownBlock { await client.shutdown() }

        let events = await client.events
        let collector = Task { () -> [PiRPCClient.ProtocolDiagnostic] in
            var diagnostics: [PiRPCClient.ProtocolDiagnostic] = []
            for await event in events {
                if case let .protocolDiagnostic(diagnostic) = event {
                    diagnostics.append(diagnostic)
                    if diagnostics.count == 7 { break }
                }
            }
            return diagnostics
        }

        _ = try await client.getState()
        let diagnostics = await collector.value

        XCTAssertTrue(diagnostics.contains { $0.kind == .malformedJSON && $0.payloadPreview == "not-json" })
        XCTAssertTrue(diagnostics.contains { $0.kind == .malformedJSON && $0.payloadPreview == "[REDACTED sensitive pi RPC preview]" })
        XCTAssertTrue(diagnostics.contains { $0.kind == .missingEventType && $0.payloadPreview?.contains("missing type") == true })
        XCTAssertTrue(diagnostics.contains { $0.kind == .malformedEventPayload && $0.eventType == "extension_ui_request" })
        let unknownDiagnostics = diagnostics.filter { $0.kind == .unknownEventType && $0.eventType == "future_event" }
        XCTAssertEqual(unknownDiagnostics.map(\.occurrence), [1, 2, 3])
        XCTAssertTrue(unknownDiagnostics.allSatisfy { $0.payloadPreview?.contains("REDACTED") == true })
        XCTAssertFalse(unknownDiagnostics.contains { $0.payloadPreview?.contains("sk-fixture-redaction-value") == true })
    }

    func testClientSurfacesFailedRPCResponse() async throws {
        let scriptURL = try makeFakePiRPCScript()
        let client = PiRPCClient(config: .init(
            commandName: scriptURL.path,
            additionalPathHints: [],
            requestTimeout: 2,
            launchArguments: [],
            requiresSupportedVersionCheck: false
        ))
        addTeardownBlock { await client.shutdown() }

        do {
            _ = try await client.setThinkingLevel("explode")
            XCTFail("Expected failed pi RPC response")
        } catch let error as PiRPCClient.ClientError {
            XCTAssertEqual(error, .requestFailed("bad thinking level"))
        }
    }

    func testApprovedLaunchRequiresSupportedPiVersionBeforeRPCStart() async throws {
        let scriptURL = try makeFakePiVersionedRPCScript(version: "0.78.1")
        let client = PiRPCClient(config: .init(
            commandName: scriptURL.path,
            additionalPathHints: [],
            requestTimeout: 2,
            launchArguments: PiIntegrationConfiguration.managedRPCLaunchArguments(launchPolicy: .defaultPolicy)
        ))
        addTeardownBlock { await client.shutdown() }

        do {
            _ = try await client.getState()
            XCTFail("Expected unsupported pi version to fail before RPC startup")
        } catch let error as PiRPCClient.ClientError {
            XCTAssertEqual(
                error,
                .executableUnavailable(
                    "RepoPrompt requires pi 0.79.0 or newer for managed RPC project trust; found 0.78.1 at \(scriptURL.path). Update pi and try again."
                )
            )
        }
    }

    func testApprovedLaunchStartsWithSupportedPiVersion() async throws {
        let scriptURL = try makeFakePiVersionedRPCScript(version: "0.79.0")
        let client = PiRPCClient(config: .init(
            commandName: scriptURL.path,
            additionalPathHints: [],
            requestTimeout: 2,
            launchArguments: PiIntegrationConfiguration.managedRPCLaunchArguments(launchPolicy: .defaultPolicy)
        ))
        addTeardownBlock { await client.shutdown() }

        let state = try await client.getState()

        XCTAssertEqual(state.sessionID, "session-123")
    }

    func testApprovedLaunchRechecksSupportedPiVersionAfterShutdown() async throws {
        let recordURL = try makeTemporaryDirectory().appendingPathComponent("version-checks.txt")
        let scriptURL = try makeFakePiVersionedRPCScript(version: "0.79.0", versionProbeRecordURL: recordURL)
        let client = PiRPCClient(config: .init(
            commandName: scriptURL.path,
            additionalPathHints: [],
            requestTimeout: 2,
            launchArguments: PiIntegrationConfiguration.managedRPCLaunchArguments(launchPolicy: .defaultPolicy)
        ))
        addTeardownBlock { await client.shutdown() }

        _ = try await client.getState()
        await client.shutdown()
        _ = try await client.getState()

        let record = (try? String(contentsOf: recordURL, encoding: .utf8)) ?? ""
        XCTAssertEqual(record.split(separator: "\n").count, 2)
    }

    func testExpectedAgentPIDRegistrationRegistersSpawnedPiProcessAndClearsOnShutdown() async throws {
        let scriptURL = try makeFakePiRPCScript()
        let recorder = ExpectedPIDRecorder()
        let runID = UUID()
        let registrar = PiRPCClient.ExpectedAgentPIDRegistrar(
            register: { pid, clientName, runID in
                await recorder.record(.register, pid: pid, clientName: clientName, runID: runID)
            },
            clear: { pid, clientName, runID in
                await recorder.record(.clear, pid: pid, clientName: clientName, runID: runID)
            }
        )
        let client = PiRPCClient(
            config: .init(
                commandName: scriptURL.path,
                additionalPathHints: [],
                requestTimeout: 2,
                launchArguments: [],
                requiresSupportedVersionCheck: false
            ),
            expectedAgentPIDRegistrar: registrar
        )

        await client.setExpectedAgentPIDRegistration(.init(clientName: "pi", runID: runID))
        _ = try await client.getState()
        var events = await recorder.events()
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.kind, .register)
        XCTAssertEqual(events.first?.clientName, "pi")
        XCTAssertEqual(events.first?.runID, runID)
        XCTAssertNotEqual(events.first?.pid, 0)

        await client.shutdown()
        events = await recorder.events()
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[1].kind, .clear)
        XCTAssertEqual(events[1].pid, events[0].pid)
        XCTAssertEqual(events[1].clientName, "pi")
        XCTAssertEqual(events[1].runID, runID)
    }

    func testExpectedAgentPIDRegistrationClearsWhenRPCProcessExits() async throws {
        let scriptURL = try makeFakePiExitAfterStateScript()
        let recorder = ExpectedPIDRecorder()
        let runID = UUID()
        let registrar = PiRPCClient.ExpectedAgentPIDRegistrar(
            register: { pid, clientName, runID in
                await recorder.record(.register, pid: pid, clientName: clientName, runID: runID)
            },
            clear: { pid, clientName, runID in
                await recorder.record(.clear, pid: pid, clientName: clientName, runID: runID)
            }
        )
        let client = PiRPCClient(
            config: .init(
                commandName: scriptURL.path,
                additionalPathHints: [],
                requestTimeout: 2,
                launchArguments: [],
                requiresSupportedVersionCheck: false
            ),
            expectedAgentPIDRegistrar: registrar
        )
        addTeardownBlock { await client.shutdown() }

        await client.setExpectedAgentPIDRegistration(.init(clientName: "pi", runID: runID))
        _ = try await client.getState()
        let didClear = await eventually {
            let events = await recorder.events()
            return events.count == 2 && events[1].kind == .clear
        }
        let events = await recorder.events()

        XCTAssertTrue(didClear)
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0].kind, .register)
        XCTAssertEqual(events[1].kind, .clear)
        XCTAssertEqual(events[1].pid, events[0].pid)
        XCTAssertEqual(events[1].clientName, "pi")
        XCTAssertEqual(events[1].runID, runID)
        let exitedProcessWasReaped = await eventually {
            Self.processNoLongerExists(events[0].pid)
        }
        XCTAssertTrue(exitedProcessWasReaped, "PiRPCClient must reap the raw posix_spawn child after stdout EOF instead of leaving a zombie pi process.")
    }

    func testStdoutEOFTerminatesPiProcessGroupChildren() async throws {
        let directory = try makeTemporaryDirectory()
        let childPIDURL = directory.appendingPathComponent("child-pid.txt")
        let scriptURL = try makeFakePiExitAfterStateWithChildScript(childPIDRecordURL: childPIDURL)
        let client = PiRPCClient(config: .init(
            commandName: scriptURL.path,
            additionalPathHints: [],
            requestTimeout: 2,
            launchArguments: [],
            requiresSupportedVersionCheck: false
        ))
        addTeardownBlock {
            await client.shutdown()
            if let childPID = Self.recordedPID(at: childPIDURL) {
                Self.terminateProcessIfExists(childPID)
            }
        }

        let state = try await client.getState()
        XCTAssertEqual(state.sessionID, "session-exit-child")
        let childPID = try await waitForRecordedPID(at: childPIDURL)

        let childWasReaped = await eventually(timeout: 3) {
            Self.processNoLongerExists(childPID)
        }
        XCTAssertTrue(
            childWasReaped,
            "PiRPCClient must terminate the whole managed pi process group after stdout EOF so child/subagent processes do not become orphaned."
        )
    }

    func testShutdownTerminatesPiProcessGroupChildren() async throws {
        let directory = try makeTemporaryDirectory()
        let childPIDURL = directory.appendingPathComponent("child-pid.txt")
        let scriptURL = try makeFakePiStayRunningWithChildScript(childPIDRecordURL: childPIDURL)
        let client = PiRPCClient(config: .init(
            commandName: scriptURL.path,
            additionalPathHints: [],
            requestTimeout: 2,
            launchArguments: [],
            requiresSupportedVersionCheck: false
        ))
        addTeardownBlock {
            await client.shutdown()
            if let childPID = Self.recordedPID(at: childPIDURL) {
                Self.terminateProcessIfExists(childPID)
            }
        }

        let state = try await client.getState()
        XCTAssertEqual(state.sessionID, "session-running-child")
        let childPID = try await waitForRecordedPID(at: childPIDURL)
        XCTAssertFalse(Self.processNoLongerExists(childPID))

        await client.shutdown()

        let childWasReaped = await eventually(timeout: 3) {
            Self.processNoLongerExists(childPID)
        }
        XCTAssertTrue(
            childWasReaped,
            "PiRPCClient shutdown must terminate the managed pi process group so Stop/cancel does not leave child or subagent processes orphaned."
        )
    }

    func testCommandAfterStdoutEOFStartsFreshRPCProcess() async throws {
        let scriptURL = try makeFakePiExitAfterStateScript()
        let recorder = ExpectedPIDRecorder()
        let runID = UUID()
        let registrar = PiRPCClient.ExpectedAgentPIDRegistrar(
            register: { pid, clientName, runID in
                await recorder.record(.register, pid: pid, clientName: clientName, runID: runID)
            },
            clear: { pid, clientName, runID in
                await recorder.record(.clear, pid: pid, clientName: clientName, runID: runID)
            }
        )
        let client = PiRPCClient(
            config: .init(
                commandName: scriptURL.path,
                additionalPathHints: [],
                requestTimeout: 2,
                launchArguments: [],
                requiresSupportedVersionCheck: false
            ),
            expectedAgentPIDRegistrar: registrar
        )
        addTeardownBlock { await client.shutdown() }

        await client.setExpectedAgentPIDRegistration(.init(clientName: "pi", runID: runID))
        let firstState = try await client.getState()
        XCTAssertEqual(firstState.sessionID, "session-exit")
        let firstExitCleared = await eventually {
            let events = await recorder.events()
            return events.count == 2 && events[1].kind == .clear && Self.processNoLongerExists(events[0].pid)
        }
        XCTAssertTrue(firstExitCleared)

        let secondState = try await client.getState()
        XCTAssertEqual(secondState.sessionID, "session-exit")
        let secondExitCleared = await eventually {
            let events = await recorder.events()
            return events.count == 4 && events[3].kind == .clear && Self.processNoLongerExists(events[2].pid)
        }
        let events = await recorder.events()
        XCTAssertTrue(secondExitCleared)
        XCTAssertEqual(events.map(\.kind), [.register, .clear, .register, .clear])
        XCTAssertEqual(events[0].clientName, "pi")
        XCTAssertEqual(events[2].clientName, "pi")
        XCTAssertEqual(events[0].runID, runID)
        XCTAssertEqual(events[2].runID, runID)
    }

    func testExtensionUIResponsePreservesOriginalRequestID() async throws {
        let directory = try makeTemporaryDirectory()
        let recordURL = directory.appendingPathComponent("ui-responses.jsonl")
        let scriptURL = try makeFakePiUIResponseRecorderScript(recordURL: recordURL)
        let client = PiRPCClient(config: .init(
            commandName: scriptURL.path,
            additionalPathHints: [],
            requestTimeout: 2,
            launchArguments: [],
            requiresSupportedVersionCheck: false
        ))
        addTeardownBlock { await client.shutdown() }

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
                        "model": {"provider": "zai", "id": "glm-5.2", "displayName": "GLM 5.2"}
                    }
                })
            elif command == "get_available_models":
                emit({
                    "type": "response",
                    "id": request_id,
                    "command": "get_available_models",
                    "success": True,
                    "data": {"models": [
                        {"provider": "zai", "id": "glm-5.2", "displayName": "GLM 5.2"},
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

    private func makeFakePiCurrentEventsScript() throws -> URL {
        let directory = try makeTemporaryDirectory()
        let scriptURL = directory.appendingPathComponent("fake_pi_current_events_rpc.py")
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
                emit({"type": "agent_end", "messages": [{"role": "assistant", "content": "retrying"}], "willRetry": True})
                emit({"type": "auto_retry_start", "attempt": 2, "maxAttempts": 3, "delayMs": 1000, "errorMessage": "provider overloaded"})
                emit({"type": "auto_retry_end", "success": True, "attempt": 2})
                emit({
                    "type": "compaction_end",
                    "reason": "threshold",
                    "result": {"messageCount": 4},
                    "aborted": False,
                    "willRetry": True,
                    "errorMessage": "compaction failed"
                })
                emit({"type": "thinking_level_changed", "level": "high"})
                emit({"type": "session_info_changed", "name": "Renamed session"})
                emit({"type": "agent_end", "messages": [], "willRetry": False})
                emit({
                    "type": "response",
                    "id": request_id,
                    "command": "get_state",
                    "success": True,
                    "data": {"sessionId": "current-events-session", "isStreaming": False, "isCompacting": False}
                })
            else:
                emit({"type": "response", "id": request_id, "command": command, "success": True})
        """#
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        return scriptURL
    }

    private func makeFakePiTimeoutScript(ignoredCommands: Set<String>) throws -> URL {
        let directory = try makeTemporaryDirectory()
        let scriptURL = directory.appendingPathComponent("fake_pi_timeout_rpc.py")
        let ignoredCommandsJSON = try String(
            data: JSONSerialization.data(withJSONObject: Array(ignoredCommands).sorted(), options: []),
            encoding: .utf8
        ) ?? "[]"
        let script = #"""
        #!/usr/bin/env python3
        import json
        import sys

        IGNORED_COMMANDS = set(__IGNORED_COMMANDS__)

        def emit(payload):
            print(json.dumps(payload), flush=True)

        for line in sys.stdin:
            try:
                request = json.loads(line)
            except Exception:
                continue
            request_id = request.get("id")
            command = request.get("type")
            if command in IGNORED_COMMANDS:
                continue
            if command == "get_state":
                emit({
                    "type": "response",
                    "id": request_id,
                    "command": "get_state",
                    "success": True,
                    "data": {
                        "sessionId": "timeout-session",
                        "isStreaming": False,
                        "isCompacting": False
                    }
                })
            elif command == "get_available_models":
                emit({
                    "type": "response",
                    "id": request_id,
                    "command": "get_available_models",
                    "success": True,
                    "data": {"models": [{"provider": "zai", "id": "glm-5.2", "displayName": "GLM 5.2"}]}
                })
            else:
                emit({"type": "response", "id": request_id, "command": command, "success": True})
        """#.replacingOccurrences(of: "__IGNORED_COMMANDS__", with: ignoredCommandsJSON)
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        return scriptURL
    }

    private func makeFakePiProtocolDiagnosticsScript() throws -> URL {
        let directory = try makeTemporaryDirectory()
        let scriptURL = directory.appendingPathComponent("fake_pi_protocol_diagnostics.py")
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
                print("not-json", flush=True)
                print('{"value":"sk-fixture-redaction-value"', flush=True)
                emit({"message": "missing type"})
                emit({"type": "extension_ui_request", "id": "broken-ui"})
                for _ in range(4):
                    emit({"type": "future_event", "note": "sk-fixture-redaction-value", "payload": {"message": "new shape"}})
                emit({
                    "type": "response",
                    "id": request_id,
                    "command": "get_state",
                    "success": True,
                    "data": {
                        "sessionId": "session-123",
                        "isStreaming": False,
                        "isCompacting": False
                    }
                })
            else:
                emit({"type": "response", "id": request_id, "command": command, "success": True})
        """#
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        return scriptURL
    }

    private func makeFakePiExitAfterStateScript() throws -> URL {
        let directory = try makeTemporaryDirectory()
        let scriptURL = directory.appendingPathComponent("fake_pi_exit_after_state.py")
        let script = #"""
        #!/usr/bin/env python3
        import json
        import sys

        for line in sys.stdin:
            try:
                request = json.loads(line)
            except Exception:
                continue
            print(json.dumps({
                "type": "response",
                "id": request.get("id"),
                "command": request.get("type"),
                "success": True,
                "data": {
                    "sessionId": "session-exit",
                    "isStreaming": False,
                    "isCompacting": False
                }
            }), flush=True)
            raise SystemExit(0)
        """#
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        return scriptURL
    }

    private func makeFakePiExitAfterStateWithChildScript(childPIDRecordURL: URL) throws -> URL {
        let scriptURL = childPIDRecordURL.deletingLastPathComponent().appendingPathComponent("fake_pi_exit_after_state_with_child.py")
        let recordPath = try Self.pythonStringLiteral(childPIDRecordURL.path)
        let script = #"""
        #!/usr/bin/env python3
        import json
        import subprocess
        import sys

        RECORD_PATH = __RECORD_PATH__

        for line in sys.stdin:
            try:
                request = json.loads(line)
            except Exception:
                continue
            child = subprocess.Popen(
                [sys.executable, "-c", "import time; time.sleep(60)"],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                close_fds=True,
            )
            with open(RECORD_PATH, "w", encoding="utf-8") as handle:
                handle.write(str(child.pid))
            print(json.dumps({
                "type": "response",
                "id": request.get("id"),
                "command": request.get("type"),
                "success": True,
                "data": {
                    "sessionId": "session-exit-child",
                    "isStreaming": False,
                    "isCompacting": False
                }
            }), flush=True)
            raise SystemExit(0)
        """#.replacingOccurrences(of: "__RECORD_PATH__", with: recordPath)
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        return scriptURL
    }

    private func makeFakePiStayRunningWithChildScript(childPIDRecordURL: URL) throws -> URL {
        let scriptURL = childPIDRecordURL.deletingLastPathComponent().appendingPathComponent("fake_pi_stay_running_with_child.py")
        let recordPath = try Self.pythonStringLiteral(childPIDRecordURL.path)
        let script = #"""
        #!/usr/bin/env python3
        import json
        import subprocess
        import sys

        RECORD_PATH = __RECORD_PATH__
        child = None

        for line in sys.stdin:
            try:
                request = json.loads(line)
            except Exception:
                continue
            if child is None:
                child = subprocess.Popen(
                    [sys.executable, "-c", "import time; time.sleep(60)"],
                    stdin=subprocess.DEVNULL,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    close_fds=True,
                )
                with open(RECORD_PATH, "w", encoding="utf-8") as handle:
                    handle.write(str(child.pid))
            print(json.dumps({
                "type": "response",
                "id": request.get("id"),
                "command": request.get("type"),
                "success": True,
                "data": {
                    "sessionId": "session-running-child",
                    "isStreaming": False,
                    "isCompacting": False
                }
            }), flush=True)
        """#.replacingOccurrences(of: "__RECORD_PATH__", with: recordPath)
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        return scriptURL
    }

    private func makeFakePiVersionedRPCScript(version: String, versionProbeRecordURL: URL? = nil) throws -> URL {
        let directory = try makeTemporaryDirectory()
        let scriptURL = directory.appendingPathComponent("fake_pi_versioned_rpc.py")
        let recordPath = try Self.pythonStringLiteral(versionProbeRecordURL?.path)
        let script = #"""
        #!/usr/bin/env python3
        import json
        import sys

        VERSION = "__VERSION__"
        VERSION_PROBE_RECORD_PATH = __VERSION_PROBE_RECORD_PATH__

        if len(sys.argv) > 1 and sys.argv[1] == "--version":
            if VERSION_PROBE_RECORD_PATH is not None:
                with open(VERSION_PROBE_RECORD_PATH, "a", encoding="utf-8") as handle:
                    handle.write("version\n")
            print(VERSION, flush=True)
            raise SystemExit(0)

        for line in sys.stdin:
            try:
                request = json.loads(line)
            except Exception:
                continue
            print(json.dumps({
                "type": "response",
                "id": request.get("id"),
                "command": request.get("type"),
                "success": True,
                "data": {
                    "sessionId": "session-123",
                    "isStreaming": False,
                    "isCompacting": False
                }
            }), flush=True)
        """#
        .replacingOccurrences(of: "__VERSION__", with: version)
        .replacingOccurrences(of: "__VERSION_PROBE_RECORD_PATH__", with: recordPath)
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        return scriptURL
    }

    private static func pythonStringLiteral(_ value: String?) throws -> String {
        guard let value else { return "None" }
        let data = try JSONEncoder().encode(value)
        return (String(data: data, encoding: .utf8) ?? "None").replacingOccurrences(of: "\\/", with: "/")
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

    private func eventually(
        timeout: TimeInterval = 1,
        condition: @escaping () async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return await condition()
    }

    private static func processNoLongerExists(_ pid: pid_t) -> Bool {
        errno = 0
        return kill(pid, 0) == -1 && errno == ESRCH
    }

    private static func terminateProcessIfExists(_ pid: pid_t) {
        guard pid > 1, !processNoLongerExists(pid) else { return }
        _ = kill(pid, SIGKILL)
    }

    private func waitForRecordedPID(at url: URL) async throws -> pid_t {
        for _ in 0 ..< 80 {
            if let pid = Self.recordedPID(at: url) { return pid }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        throw PiRPCClient.ClientError.invalidResponse("Fake pi script did not record child PID at \(url.path).")
    }

    private static func recordedPID(at url: URL) -> pid_t? {
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              let rawPID = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return nil }
        return pid_t(rawPID)
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
