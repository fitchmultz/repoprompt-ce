@testable import RepoPrompt
import XCTest

final class PiNativeSessionControllerTests: XCTestCase {
    private var temporaryURLs: [URL] = []

    override func tearDown() {
        AgentPiModelRegistry.shared.test_reset()
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
            options: .init(modelRaw: "zai/glm-5.2:high", requestTimeout: 2)
        )
        addTeardownBlock { await controller.shutdown() }

        let ref = try await controller.startOrResume(existing: nil)

        XCTAssertEqual(ref.sessionID, "pi-session-id")
        XCTAssertEqual(ref.sessionFile, "/tmp/pi-session.jsonl")
        XCTAssertEqual(ref.model, "zai/glm-5.2")
        XCTAssertEqual(ref.thinkingLevel, "high")
        let commands = recordedCommands(at: recordURL)
        XCTAssertEqual(commands.prefix(3).map(\.type), ["set_model", "set_thinking_level", "get_state"])
        XCTAssertEqual(commands.first?.provider, "zai")
        XCTAssertEqual(commands.first?.modelID, "glm-5.2")
        XCTAssertEqual(commands.dropFirst().first?.level, "high")
    }

    func testStartSendsSupportedModelWithoutThinkingSuffix() async throws {
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
            options: .init(modelRaw: "deepseek/deepseek-v4-flash", requestTimeout: 2)
        )
        addTeardownBlock { await controller.shutdown() }

        _ = try await controller.startOrResume(existing: nil)

        let commands = recordedCommands(at: recordURL)
        XCTAssertEqual(commands.prefix(2).map(\.type), ["set_model", "get_state"])
        XCTAssertEqual(commands.first?.provider, "deepseek")
        XCTAssertEqual(commands.first?.modelID, "deepseek-v4-flash")
        XCTAssertFalse(commands.contains { $0.type == "set_thinking_level" })
    }

    func testStartSendsSupportedModelWithExplicitThinkingSuffix() async throws {
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
            options: .init(modelRaw: "deepseek/deepseek-v4-flash:high", requestTimeout: 2)
        )
        addTeardownBlock { await controller.shutdown() }

        _ = try await controller.startOrResume(existing: nil)

        let commands = recordedCommands(at: recordURL)
        XCTAssertEqual(commands.prefix(3).map(\.type), ["set_model", "set_thinking_level", "get_state"])
        XCTAssertEqual(commands.first?.provider, "deepseek")
        XCTAssertEqual(commands.first?.modelID, "deepseek-v4-flash")
        XCTAssertEqual(commands.dropFirst().first?.level, "high")
    }

    func testStartPreservesSupportedKnownModelIDWithoutThinkingSuffix() async throws {
        let directory = try makeTemporaryDirectory()
        let recordURL = directory.appendingPathComponent("commands.jsonl")
        let scriptURL = try makeFakePiControllerScript(recordURL: recordURL)
        let rawModel = "deepseek/deepseek-v4-flash"
        XCTAssertTrue(AgentPiModelRegistry.shared.updateDiscoveredModels(PiDiscoveredModels(
            options: [
                AgentModelOption(
                    rawValue: rawModel,
                    displayName: "DeepSeek V4 Flash",
                    description: nil,
                    isDefault: false
                )
            ],
            currentModelRaw: nil
        )))
        let client = PiRPCClient(config: .init(
            commandName: scriptURL.path,
            additionalPathHints: [],
            requestTimeout: 2,
            launchArguments: [],
            requiresSupportedVersionCheck: false
        ))
        let controller = PiNativeSessionController(
            client: client,
            options: .init(modelRaw: rawModel, requestTimeout: 2)
        )
        addTeardownBlock { await controller.shutdown() }

        _ = try await controller.startOrResume(existing: nil)

        let commands = recordedCommands(at: recordURL)
        XCTAssertEqual(commands.prefix(2).map(\.type), ["set_model", "get_state"])
        XCTAssertEqual(commands.first?.provider, "deepseek")
        XCTAssertEqual(commands.first?.modelID, "deepseek-v4-flash")
        XCTAssertFalse(commands.contains { $0.type == "set_thinking_level" })
    }

    func testStartWarmsPersistedWorkspaceSnapshotBeforeParsingColdModelSelection() async throws {
        let directory = try makeTemporaryDirectory()
        let workspaceURL = directory.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        let recordURL = directory.appendingPathComponent("commands.jsonl")
        let scriptURL = try makeFakePiControllerScript(recordURL: recordURL)
        let rawModel = "deepseek/deepseek-v4-flash"
        XCTAssertTrue(AgentPiModelRegistry.shared.updateDiscoveredModels(PiDiscoveredModels(
            options: [
                AgentModelOption(
                    rawValue: rawModel,
                    displayName: "DeepSeek V4 Flash",
                    description: nil,
                    isDefault: false,
                    supportedPiThinkingLevels: [.low, .high]
                )
            ],
            currentModelRaw: nil
        ), workspacePath: workspaceURL.path))
        AgentPiModelRegistry.shared.test_clearMemoryPreservingStore()
        XCTAssertEqual(AgentPiModelRegistry.shared.resolvedSnapshot(workspacePath: workspaceURL.path)?.options.map(\.rawValue), [rawModel])
        let client = PiRPCClient(config: .init(
            commandName: scriptURL.path,
            additionalPathHints: [],
            requestTimeout: 2,
            launchArguments: [],
            requiresSupportedVersionCheck: false
        ))
        let controller = PiNativeSessionController(
            client: client,
            options: .init(modelRaw: rawModel, requestTimeout: 2),
            workspacePath: workspaceURL.path
        )
        addTeardownBlock { await controller.shutdown() }

        _ = try await controller.startOrResume(existing: nil, thinkingLevel: "low")

        let commands = recordedCommands(at: recordURL)
        XCTAssertEqual(commands.prefix(3).map(\.type), ["set_model", "set_thinking_level", "get_state"])
        XCTAssertEqual(commands.first?.provider, "deepseek")
        XCTAssertEqual(commands.first?.modelID, "deepseek-v4-flash")
        XCTAssertEqual(commands.dropFirst().first?.level, "low")
    }

    func testStartRefreshesModelRegistryInWorkspaceScopeNotGlobal() async throws {
        AgentPiModelRegistry.shared.test_reset()
        let directory = try makeTemporaryDirectory()
        let workspaceURL = directory.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        let scriptURL = try makeFakePiControllerScript(recordURL: directory.appendingPathComponent("commands.jsonl"))
        let client = PiRPCClient(config: .init(
            commandName: scriptURL.path,
            additionalPathHints: [],
            requestTimeout: 2,
            launchArguments: [],
            requiresSupportedVersionCheck: false
        ))
        let controller = PiNativeSessionController(
            client: client,
            options: .init(requestTimeout: 2),
            workspacePath: workspaceURL.path
        )
        addTeardownBlock { await controller.shutdown() }

        _ = try await controller.startOrResume(existing: nil)

        XCTAssertNil(AgentPiModelRegistry.shared.resolvedSnapshot())
        let workspaceSnapshot = try XCTUnwrap(AgentPiModelRegistry.shared.resolvedSnapshot(workspacePath: workspaceURL.path))
        XCTAssertEqual(workspaceSnapshot.options.map(\.rawValue), ["anthropic/claude-opus-4-6", "deepseek/deepseek-v4-flash", "zai/glm-5.2"])
        XCTAssertEqual(workspaceSnapshot.currentModelRaw, "zai/glm-5.2")
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
        let controller = makeController(client: client)
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
        let controller = makeController(client: client)
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
        let messageStop = streamResults.first { $0.type == "message_stop" && $0.stopReason == "end_turn" }
        XCTAssertEqual(messageStop?.promptTokens, 13)
        XCTAssertEqual(messageStop?.completionTokens, 7)
        XCTAssertEqual(messageStop?.contextUsedTokens, 20)
        XCTAssertEqual(messageStop?.cost, 0.03)
        XCTAssertTrue(streamResults.contains { $0.type == "usage" && $0.promptTokens == 13 && $0.completionTokens == 7 })
        XCTAssertTrue(events.contains { event in
            if case let .turnCompleted(completedTurnID, status) = event {
                return completedTurnID == turnID && status == .completed
            }
            return false
        })
    }

    func testDoneDeltaBeforeUsageDoesNotEmitPrematureMessageStop() async throws {
        let directory = try makeTemporaryDirectory()
        let scriptURL = try makeFakePiControllerScript(recordURL: directory.appendingPathComponent("commands.jsonl"))
        let client = PiRPCClient(config: .init(
            commandName: scriptURL.path,
            additionalPathHints: [],
            requestTimeout: 2,
            launchArguments: [],
            requiresSupportedVersionCheck: false
        ))
        let controller = makeController(client: client)
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

        _ = try await controller.sendUserMessage("done-before-usage")
        let streamResults = await collector.value.compactMap { event -> AIStreamResult? in
            if case let .stream(result) = event { return result }
            return nil
        }
        let stops = streamResults.filter { $0.type == "message_stop" }

        XCTAssertEqual(stops.count, 1)
        XCTAssertEqual(stops.first?.promptTokens, 6)
        XCTAssertEqual(stops.first?.completionTokens, 3)
        XCTAssertEqual(stops.first?.contextUsedTokens, 9)
    }

    func testMultipleTurnEndsBeforeAgentEndEachEmitMessageStopWithUsage() async throws {
        let directory = try makeTemporaryDirectory()
        let scriptURL = try makeFakePiControllerScript(recordURL: directory.appendingPathComponent("commands.jsonl"))
        let client = PiRPCClient(config: .init(
            commandName: scriptURL.path,
            additionalPathHints: [],
            requestTimeout: 2,
            launchArguments: [],
            requiresSupportedVersionCheck: false
        ))
        let controller = makeController(client: client)
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

        _ = try await controller.sendUserMessage("multi-turn-before-agent-end")
        let streamResults = await collector.value.compactMap { event -> AIStreamResult? in
            if case let .stream(result) = event { return result }
            return nil
        }
        let stops = streamResults.filter { $0.type == "message_stop" }

        XCTAssertEqual(stops.count, 2)
        XCTAssertEqual(stops.map(\.promptTokens), [3, 5])
        XCTAssertEqual(stops.map(\.completionTokens), [2, 4])
        XCTAssertEqual(stops.map(\.contextUsedTokens), [5, 9])
    }

    func testTurnEndWithoutUsageUsesFinalAgentEndUsageFallback() async throws {
        let directory = try makeTemporaryDirectory()
        let scriptURL = try makeFakePiControllerScript(recordURL: directory.appendingPathComponent("commands.jsonl"))
        let client = PiRPCClient(config: .init(
            commandName: scriptURL.path,
            additionalPathHints: [],
            requestTimeout: 2,
            launchArguments: [],
            requiresSupportedVersionCheck: false
        ))
        let controller = makeController(client: client)
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

        _ = try await controller.sendUserMessage("agent-end-usage")
        let streamResults = await collector.value.compactMap { event -> AIStreamResult? in
            if case let .stream(result) = event { return result }
            return nil
        }

        let messageStop = streamResults.first { $0.type == "message_stop" }
        XCTAssertEqual(messageStop?.promptTokens, 9)
        XCTAssertEqual(messageStop?.completionTokens, 4)
        XCTAssertEqual(messageStop?.contextUsedTokens, 14)
        XCTAssertTrue(streamResults.contains { $0.type == "usage" && $0.promptTokens == 9 && $0.completionTokens == 4 })
    }

    func testSubagentUnknownToolEndStatusRemainsRunning() {
        let status = PiRunProgressPresentation.toolEndStatus(
            toolName: "subagent",
            result: .object([
                "status": .string("unknown"),
                "summary_only": .bool(true),
                "summary_text": .string("subagent • unknown")
            ]),
            isError: false
        )

        XCTAssertEqual(status, "Subagent running")
    }

    func testPromptWithQueuedSteerTerminalizesOnceAfterFinalAgentEnd() async throws {
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
        let sleeper = ManualRecoverySleeper()
        let controller = makeController(client: client, recoverySleeper: { await sleeper.sleep($0) })
        addTeardownBlock { await controller.shutdown() }
        _ = try await controller.startOrResume(existing: nil)
        await controller.resetEventsStreamForNewRun()

        let stream = await controller.events
        let recorder = EventRecorder()
        let collector = Task {
            for await event in stream {
                await recorder.append(event)
            }
        }

        let promptTurnID = try await controller.sendUserMessage("queued-steer-boundaries")
        try await controller.steer("queued steer")
        await sleeper.waitForSleep(interval: 1)
        await sleeper.resumeAll()
        let events = await waitForRecordedEvents(recorder, timeoutNanoseconds: 1_500_000_000) { events in
            events.contains { event in
                if case .turnCompleted = event { return true }
                return false
            }
        }
        collector.cancel()

        let completedTurnIDs = events.compactMap { event -> UUID? in
            if case let .turnCompleted(turnID, _) = event { return turnID }
            return nil
        }
        XCTAssertEqual(completedTurnIDs, [promptTurnID])
        let interruptOutcome = await controller.interruptTurn(reason: "already completed")
        XCTAssertEqual(interruptOutcome, .noTurnInFlight)
        XCTAssertEqual(recordedCommands(at: recordURL).map(\.type).filter { $0 == "prompt" || $0 == "steer" }, ["prompt", "steer"])

        let streamText = events.compactMap { event -> String? in
            guard case let .stream(result) = event, result.type == "content" else { return nil }
            return result.text
        }.joined()
        XCTAssertTrue(streamText.contains("first turn"))
        XCTAssertTrue(streamText.contains("steered turn"))

        var completionGate = PiRunCompletionGate()
        let terminalStates = events.compactMap { event -> AgentSessionRunState? in
            switch event {
            case let .sessionState(state):
                completionGate.recordSessionState(state)
                return nil
            case let .turnCompleted(_, status):
                return completionGate.terminalState(for: status)
            default:
                return nil
            }
        }
        XCTAssertEqual(terminalStates, [.completed])
    }

    func testPromptWithQueuedFollowUpTerminalizesOnceAfterFinalAgentEnd() async throws {
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
        let sleeper = ManualRecoverySleeper()
        let controller = makeController(client: client, recoverySleeper: { await sleeper.sleep($0) })
        addTeardownBlock { await controller.shutdown() }
        _ = try await controller.startOrResume(existing: nil)
        await controller.resetEventsStreamForNewRun()

        let stream = await controller.events
        let recorder = EventRecorder()
        let collector = Task {
            for await event in stream {
                await recorder.append(event)
            }
        }

        let promptTurnID = try await controller.sendUserMessage("queued-follow-up-boundaries")
        try await controller.followUp("queued follow up")
        await sleeper.waitForSleep(interval: 1)
        await sleeper.resumeAll()
        let events = await waitForRecordedEvents(recorder, timeoutNanoseconds: 1_500_000_000) { events in
            events.contains { event in
                if case .turnCompleted = event { return true }
                return false
            }
        }
        collector.cancel()

        let completedTurnIDs = events.compactMap { event -> UUID? in
            if case let .turnCompleted(turnID, _) = event { return turnID }
            return nil
        }
        XCTAssertEqual(completedTurnIDs, [promptTurnID])
        let interruptOutcome = await controller.interruptTurn(reason: "already completed")
        XCTAssertEqual(interruptOutcome, .noTurnInFlight)
        XCTAssertEqual(recordedCommands(at: recordURL).map(\.type).filter { $0 == "prompt" || $0 == "follow_up" }, ["prompt", "follow_up"])

        let streamText = events.compactMap { event -> String? in
            guard case let .stream(result) = event, result.type == "content" else { return nil }
            return result.text
        }.joined()
        XCTAssertTrue(streamText.contains("first turn"))
        XCTAssertTrue(streamText.contains("follow-up turn"))

        var completionGate = PiRunCompletionGate()
        let terminalStates = events.compactMap { event -> AgentSessionRunState? in
            switch event {
            case let .sessionState(state):
                completionGate.recordSessionState(state)
                return nil
            case let .turnCompleted(_, status):
                return completionGate.terminalState(for: status)
            default:
                return nil
            }
        }
        XCTAssertEqual(terminalStates, [.completed])
    }

    func testFinalAgentEndRefreshFailureEmitsIdleStateBeforeCompletion() async throws {
        let directory = try makeTemporaryDirectory()
        let scriptURL = try makeFakePiControllerScript(recordURL: directory.appendingPathComponent("commands.jsonl"))
        let client = PiRPCClient(config: .init(
            commandName: scriptURL.path,
            additionalPathHints: [],
            requestTimeout: 2,
            launchArguments: [],
            requiresSupportedVersionCheck: false
        ))
        let sleeper = ManualRecoverySleeper()
        let controller = makeController(client: client, recoverySleeper: { await sleeper.sleep($0) })
        addTeardownBlock { await controller.shutdown() }
        _ = try await controller.startOrResume(existing: nil)
        await controller.resetEventsStreamForNewRun()

        let stream = await controller.events
        let recorder = EventRecorder()
        let collector = Task {
            for await event in stream {
                await recorder.append(event)
            }
        }

        let turnID = try await controller.sendUserMessage("agent-end-refresh-fails-after-stale-pending")
        var events = await waitForRecordedEvents(recorder, timeoutNanoseconds: 1_500_000_000) { events in
            events.contains { event in
                if case let .sessionState(state) = event { return state.pendingMessageCount == 1 }
                return false
            }
        }
        XCTAssertFalse(events.contains { event in
            if case .turnCompleted = event { return true }
            return false
        }, "stale pending get_state must not complete before the terminal recovery path runs")

        events = await waitForRecordedEvents(recorder, timeoutNanoseconds: 1_500_000_000) { events in
            events.contains { event in
                if case let .diagnostic(diagnostic) = event {
                    return diagnostic.eventType == "agent_end"
                        && diagnostic.message.contains("scheduling bounded terminal completion recovery")
                }
                return false
            }
        }
        XCTAssertFalse(events.contains { event in
            if case .turnCompleted = event { return true }
            return false
        }, "agent_end get_state failure must schedule recovery without terminalizing synchronously")

        await sleeper.waitForSleep(interval: 1)
        events = await recorder.events()
        XCTAssertFalse(events.contains { event in
            if case .turnCompleted = event { return true }
            return false
        }, "terminal completion must wait for the test-controlled recovery sleeper")

        await sleeper.resumeAll()
        events = await waitForRecordedEvents(recorder, timeoutNanoseconds: 1_500_000_000) { events in
            events.contains { event in
                if case let .turnCompleted(completedTurnID, status) = event {
                    return completedTurnID == turnID && status == .completed
                }
                return false
            }
        }
        collector.cancel()

        let staleStateIndex = events.firstIndex { event in
            if case let .sessionState(state) = event { return state.pendingMessageCount == 1 }
            return false
        }
        let fallbackStateIndex = events.firstIndex { event in
            if case let .sessionState(state) = event { return state.pendingMessageCount == 0 }
            return false
        }
        let completionIndex = events.firstIndex { event in
            if case let .turnCompleted(completedTurnID, status) = event {
                return completedTurnID == turnID && status == .completed
            }
            return false
        }

        XCTAssertNotNil(staleStateIndex)
        XCTAssertNotNil(fallbackStateIndex)
        XCTAssertNotNil(completionIndex)
        XCTAssertLessThan(try XCTUnwrap(staleStateIndex), try XCTUnwrap(fallbackStateIndex))
        XCTAssertLessThan(try XCTUnwrap(fallbackStateIndex), try XCTUnwrap(completionIndex))

        var completionGate = PiRunCompletionGate()
        let terminalStates = events.compactMap { event -> AgentSessionRunState? in
            switch event {
            case let .sessionState(state):
                completionGate.recordSessionState(state)
                return nil
            case let .turnCompleted(_, status):
                return completionGate.terminalState(for: status)
            default:
                return nil
            }
        }
        XCTAssertEqual(terminalStates, [.completed])
        XCTAssertTrue(events.contains { event in
            if case let .diagnostic(diagnostic) = event {
                return diagnostic.eventType == "agent_end"
                    && diagnostic.message.contains("scheduling bounded terminal completion recovery")
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
        let controller = makeController(client: client)
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
            XCTAssertTrue(error.localizedDescription.contains("must be local files"))
            XCTAssertTrue(error.localizedDescription.contains("Save the image locally"))
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
        let controller = makeController(client: client)
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

    func testProtocolDiagnosticsAreForwardedToNativeEvents() async throws {
        let directory = try makeTemporaryDirectory()
        let scriptURL = try makeFakePiControllerScript(recordURL: directory.appendingPathComponent("commands.jsonl"))
        let client = PiRPCClient(config: .init(
            commandName: scriptURL.path,
            additionalPathHints: [],
            requestTimeout: 2,
            launchArguments: [],
            requiresSupportedVersionCheck: false
        ))
        let controller = makeController(client: client)
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

        _ = try await controller.sendUserMessage("protocol-drift")
        let events = await collector.value
        let diagnostics = events.compactMap { event -> PiRPCClient.ProtocolDiagnostic? in
            if case let .diagnostic(diagnostic) = event { return diagnostic }
            return nil
        }

        XCTAssertEqual(diagnostics.first?.kind, .unknownEventType)
        XCTAssertEqual(diagnostics.first?.eventType, "future_event")
        XCTAssertTrue(diagnostics.first?.payloadPreview?.contains("REDACTED") == true)
        XCTAssertFalse(diagnostics.first?.payloadPreview?.contains("sk-fixture-redaction-value") == true)
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
        let controller = makeController(client: client)
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
        let controller = makeController(client: client)
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

    func testSubagentToolAndCustomMessagesProduceProgressStatus() async throws {
        let directory = try makeTemporaryDirectory()
        let scriptURL = try makeFakePiControllerScript(recordURL: directory.appendingPathComponent("commands.jsonl"))
        let client = PiRPCClient(config: .init(
            commandName: scriptURL.path,
            additionalPathHints: [],
            requestTimeout: 2,
            launchArguments: [],
            requiresSupportedVersionCheck: false
        ))
        let controller = makeController(client: client)
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

        _ = try await controller.sendUserMessage("subagent-progress")
        let streamResults = await collector.value.compactMap { event -> AIStreamResult? in
            if case let .stream(result) = event { return result }
            return nil
        }

        XCTAssertTrue(streamResults.contains { $0.type == "status" && $0.text == "Subagent worker started" })
        XCTAssertFalse(streamResults.contains { result in
            result.type == "status"
                && (result.text?.contains("hidden-worker") ?? false)
        })
        XCTAssertTrue(streamResults.contains { result in
            result.type == "status"
                && (result.text?.contains("Subagent worker needs attention") ?? false)
                && (result.text?.contains("tool: bash") ?? false)
        })
        XCTAssertTrue(streamResults.contains { result in
            result.type == "status"
                && (result.text?.contains("Subagent worker") ?? false)
                && (result.text?.contains("detached") ?? false)
                && (result.text?.contains("7bee22c2") ?? false)
        })
        XCTAssertTrue(streamResults.contains { $0.type == "tool_call" && $0.toolName == "subagent" })
        XCTAssertTrue(streamResults.contains { $0.type == "tool_result" && $0.toolName == "subagent" })
    }

    func testSubagentRunningSentinelProducesRunningStatus() async throws {
        let directory = try makeTemporaryDirectory()
        let scriptURL = try makeFakePiControllerScript(recordURL: directory.appendingPathComponent("commands.jsonl"))
        let client = PiRPCClient(config: .init(
            commandName: scriptURL.path,
            additionalPathHints: [],
            requestTimeout: 2,
            launchArguments: [],
            requiresSupportedVersionCheck: false
        ))
        let controller = makeController(client: client)
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

        _ = try await controller.sendUserMessage("subagent-running")
        let streamResults = await collector.value.compactMap { event -> AIStreamResult? in
            if case let .stream(result) = event { return result }
            return nil
        }

        XCTAssertTrue(streamResults.contains { result in
            result.type == "status"
                && (result.text?.contains("Subagent worker") ?? false)
                && (result.text?.contains("running") ?? false)
                && (result.text?.contains("running1") ?? false)
        })
        XCTAssertFalse(streamResults.contains { result in
            result.type == "status"
                && (result.text?.contains("failed") ?? false)
                && (result.text?.contains("running1") ?? false)
        })
    }

    func testSubagentErrorStatusPreservesChildLifecycleDetails() async throws {
        let directory = try makeTemporaryDirectory()
        let scriptURL = try makeFakePiControllerScript(recordURL: directory.appendingPathComponent("commands.jsonl"))
        let client = PiRPCClient(config: .init(
            commandName: scriptURL.path,
            additionalPathHints: [],
            requestTimeout: 2,
            launchArguments: [],
            requiresSupportedVersionCheck: false
        ))
        let controller = makeController(client: client)
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

        _ = try await controller.sendUserMessage("subagent-timeout")
        let streamResults = await collector.value.compactMap { event -> AIStreamResult? in
            if case let .stream(result) = event { return result }
            return nil
        }

        XCTAssertTrue(streamResults.contains { result in
            result.type == "status"
                && (result.text?.contains("Subagent worker") ?? false)
                && (result.text?.contains("timed out") ?? false)
                && (result.text?.contains("deadbeef") ?? false)
        })
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
        let controller = makeController(client: client)
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

    func testRetryingAgentEndDoesNotCompleteUntilFinalAgentEnd() async throws {
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
        let controller = makeController(client: client)
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

        let turnID = try await controller.sendUserMessage("auto-retry")
        let events = await collector.value
        let streamResults = events.compactMap { event -> AIStreamResult? in
            if case let .stream(result) = event { return result }
            return nil
        }

        XCTAssertTrue(streamResults.contains { $0.type == "status" && ($0.text?.contains("retrying the turn") ?? false) })
        XCTAssertTrue(streamResults.contains { $0.type == "content" && $0.text == "retry success" })
        XCTAssertTrue(events.contains { event in
            if case let .turnCompleted(completedTurnID, status) = event {
                return completedTurnID == turnID && status == .completed
            }
            return false
        })
        let retrySuccessIndex = events.firstIndex { event in
            if case let .stream(result) = event { return result.type == "content" && result.text == "retry success" }
            return false
        }
        let completionIndex = events.firstIndex { event in
            if case .turnCompleted = event { return true }
            return false
        }
        XCTAssertNotNil(retrySuccessIndex)
        XCTAssertNotNil(completionIndex)
        XCTAssertLessThan(try XCTUnwrap(retrySuccessIndex), try XCTUnwrap(completionIndex))
        XCTAssertGreaterThanOrEqual(recordedCommands(at: recordURL).map(\.type).count(where: { $0 == "get_state" }), 3)
    }

    func testRetryingTurnEndWithUsageEmitsOnlyFinalMessageStopAndUsage() async throws {
        let directory = try makeTemporaryDirectory()
        let scriptURL = try makeFakePiControllerScript(recordURL: directory.appendingPathComponent("commands.jsonl"))
        let client = PiRPCClient(config: .init(
            commandName: scriptURL.path,
            additionalPathHints: [],
            requestTimeout: 2,
            launchArguments: [],
            requiresSupportedVersionCheck: false
        ))
        let controller = makeController(client: client)
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

        let turnID = try await controller.sendUserMessage("auto-retry-usage")
        let events = await collector.value
        let streamResults = events.compactMap { event -> AIStreamResult? in
            if case let .stream(result) = event { return result }
            return nil
        }
        let stops = streamResults.filter { $0.type == "message_stop" }
        let usageResults = streamResults.filter { $0.type == "usage" }

        XCTAssertEqual(stops.count, 1)
        XCTAssertEqual(stops.first?.stopReason, "end_turn")
        XCTAssertEqual(stops.first?.promptTokens, 11)
        XCTAssertEqual(stops.first?.completionTokens, 5)
        XCTAssertEqual(stops.first?.contextUsedTokens, 16)
        XCTAssertEqual(usageResults.count, 1)
        XCTAssertEqual(usageResults.first?.promptTokens, 11)
        XCTAssertEqual(usageResults.first?.completionTokens, 5)
        XCTAssertTrue(events.contains { event in
            if case let .turnCompleted(completedTurnID, status) = event {
                return completedTurnID == turnID && status == .completed
            }
            return false
        })
        let retryStatusIndex = try XCTUnwrap(events.firstIndex { event in
            if case let .stream(result) = event {
                return result.type == "status" && (result.text?.contains("retrying the turn") ?? false)
            }
            return false
        })
        let retryResumedIndex = try XCTUnwrap(events.firstIndex { event in
            if case let .stream(result) = event {
                return result.type == "status" && (result.text?.contains("resumed the turn") ?? false)
            }
            return false
        })
        let messageStopIndex = try XCTUnwrap(events.firstIndex { event in
            if case let .stream(result) = event { return result.type == "message_stop" }
            return false
        })
        XCTAssertLessThan(retryStatusIndex, messageStopIndex)
        XCTAssertLessThan(retryResumedIndex, messageStopIndex)
    }

    func testCompactionRetryingAgentEndDoesNotCompleteUntilFinalAgentEnd() async throws {
        let directory = try makeTemporaryDirectory()
        let scriptURL = try makeFakePiControllerScript(recordURL: directory.appendingPathComponent("commands.jsonl"))
        let client = PiRPCClient(config: .init(
            commandName: scriptURL.path,
            additionalPathHints: [],
            requestTimeout: 2,
            launchArguments: [],
            requiresSupportedVersionCheck: false
        ))
        let controller = makeController(client: client)
        addTeardownBlock { await controller.shutdown() }
        _ = try await controller.startOrResume(existing: nil)

        let stream = await controller.events
        let recorder = EventRecorder()
        let collector = Task {
            for await event in stream {
                await recorder.append(event)
            }
        }

        let turnID = try await controller.sendUserMessage("compaction-retry")
        var events = await waitForRecordedEvents(recorder, timeoutNanoseconds: 1_500_000_000) { events in
            events.contains { event in
                if case let .stream(result) = event {
                    return result.type == "status" && (result.text?.contains("compacting context") ?? false)
                }
                return false
            }
        }
        XCTAssertFalse(events.contains { event in
            if case .turnCompleted = event { return true }
            return false
        }, "agent_end before compaction_start must not complete while pi is compacting")

        _ = try await client.sendCommand([
            "type": .string("test_emit"),
            "scenario": .string("compaction_retry_continue")
        ])
        events = await waitForRecordedEvents(recorder, timeoutNanoseconds: 1_500_000_000) { events in
            events.contains { event in
                if case let .turnCompleted(completedTurnID, status) = event {
                    return completedTurnID == turnID && status == .completed
                }
                return false
            }
        }
        collector.cancel()
        let streamResults = events.compactMap { event -> AIStreamResult? in
            if case let .stream(result) = event { return result }
            return nil
        }

        XCTAssertTrue(streamResults.contains { $0.type == "status" && ($0.text?.contains("compaction will retry") ?? false) })
        XCTAssertTrue(streamResults.contains { $0.type == "content" && $0.text == "after compaction retry" })
    }

    func testThresholdCompactionDoesNotCompleteUntilCompactionEnds() async throws {
        let directory = try makeTemporaryDirectory()
        let scriptURL = try makeFakePiControllerScript(recordURL: directory.appendingPathComponent("commands.jsonl"))
        let client = PiRPCClient(config: .init(
            commandName: scriptURL.path,
            additionalPathHints: [],
            requestTimeout: 2,
            launchArguments: [],
            requiresSupportedVersionCheck: false
        ))
        let controller = makeController(client: client)
        addTeardownBlock { await controller.shutdown() }
        _ = try await controller.startOrResume(existing: nil)

        let stream = await controller.events
        let recorder = EventRecorder()
        let collector = Task {
            for await event in stream {
                await recorder.append(event)
            }
        }

        let turnID = try await controller.sendUserMessage("compaction-threshold")
        var events = await waitForRecordedEvents(recorder, timeoutNanoseconds: 1_500_000_000) { events in
            events.contains { event in
                if case let .stream(result) = event {
                    return result.type == "status" && (result.text?.contains("compacting context") ?? false)
                }
                return false
            }
        }
        XCTAssertFalse(events.contains { event in
            if case .turnCompleted = event { return true }
            return false
        })

        _ = try await client.sendCommand([
            "type": .string("test_emit"),
            "scenario": .string("compaction_threshold_finish")
        ])
        events = await waitForRecordedEvents(recorder, timeoutNanoseconds: 1_500_000_000) { events in
            events.contains { event in
                if case let .turnCompleted(completedTurnID, status) = event {
                    return completedTurnID == turnID && status == .completed
                }
                return false
            }
        }
        collector.cancel()
        XCTAssertEqual(events.count { event in
            if case .turnCompleted = event { return true }
            return false
        }, 1)
    }

    func testTerminalCompactionEndTransientStateFailureStillCompletesWithinBounds() async throws {
        let directory = try makeTemporaryDirectory()
        let scriptURL = try makeFakePiControllerScript(recordURL: directory.appendingPathComponent("commands.jsonl"))
        let client = PiRPCClient(config: .init(
            commandName: scriptURL.path,
            additionalPathHints: [],
            requestTimeout: 2,
            launchArguments: [],
            requiresSupportedVersionCheck: false
        ))
        let sleeper = ManualRecoverySleeper()
        let controller = makeController(client: client, recoverySleeper: { await sleeper.sleep($0) })
        addTeardownBlock { await controller.shutdown() }
        _ = try await controller.startOrResume(existing: nil)

        let stream = await controller.events
        let recorder = EventRecorder()
        let collector = Task {
            for await event in stream {
                await recorder.append(event)
            }
        }

        let turnID = try await controller.sendUserMessage("compaction-terminal-state-failure")
        var events = await waitForRecordedEvents(recorder, timeoutNanoseconds: 1_500_000_000) { events in
            events.contains { event in
                if case let .stream(result) = event {
                    return result.type == "status" && (result.text?.contains("compacting context") ?? false)
                }
                return false
            }
        }
        XCTAssertFalse(events.contains { event in
            if case .turnCompleted = event { return true }
            return false
        })

        _ = try await client.sendCommand([
            "type": .string("test_emit"),
            "scenario": .string("compaction_terminal_state_failure")
        ])
        await sleeper.waitForSleep(interval: 1)
        await sleeper.resumeAll()
        events = await waitForRecordedEvents(recorder, timeoutNanoseconds: 1_500_000_000) { events in
            events.contains { event in
                if case let .turnCompleted(completedTurnID, status) = event {
                    return completedTurnID == turnID && status == .completed
                }
                return false
            }
        }
        collector.cancel()

        XCTAssertEqual(events.compactMap { event -> PiNativeSessionController.TurnStatus? in
            if case let .turnCompleted(completedTurnID, status) = event,
               completedTurnID == turnID
            {
                return status
            }
            return nil
        }, [.completed])
        XCTAssertTrue(events.contains { event in
            if case let .diagnostic(diagnostic) = event {
                return diagnostic.eventType == "compaction_end"
                    && diagnostic.message.contains("scheduling bounded terminal completion recovery")
            }
            return false
        })
    }

    func testNonRetryCompactionWithQueuedContinuationWaitsForTrueFinalAgentEnd() async throws {
        let directory = try makeTemporaryDirectory()
        let scriptURL = try makeFakePiControllerScript(recordURL: directory.appendingPathComponent("commands.jsonl"))
        let client = PiRPCClient(config: .init(
            commandName: scriptURL.path,
            additionalPathHints: [],
            requestTimeout: 2,
            launchArguments: [],
            requiresSupportedVersionCheck: false
        ))
        let controller = makeController(client: client)
        addTeardownBlock { await controller.shutdown() }
        _ = try await controller.startOrResume(existing: nil)

        let stream = await controller.events
        let recorder = EventRecorder()
        let collector = Task {
            for await event in stream {
                await recorder.append(event)
            }
        }

        let turnID = try await controller.sendUserMessage("compaction-nonretry-queued-continuation")
        var events = await waitForRecordedEvents(recorder, timeoutNanoseconds: 1_500_000_000) { events in
            events.contains { event in
                if case let .stream(result) = event {
                    return result.type == "status" && (result.text?.contains("compacting context") ?? false)
                }
                return false
            }
        }
        XCTAssertFalse(events.contains { event in
            if case .turnCompleted = event { return true }
            return false
        }, "agent_end before compaction_start must not complete while pi is compacting")

        _ = try await client.sendCommand([
            "type": .string("test_emit"),
            "scenario": .string("compaction_nonretry_queued_continuation_end")
        ])
        events = await waitForRecordedEvents(recorder, timeoutNanoseconds: 1_500_000_000) { events in
            events.contains { event in
                if case let .sessionState(state) = event {
                    return state.pendingMessageCount == 1
                }
                return false
            }
        }
        XCTAssertFalse(events.contains { event in
            if case .turnCompleted = event { return true }
            return false
        }, "non-retry compaction_end with queued pi messages must wait for the continuation's final agent_end")

        _ = try await client.sendCommand([
            "type": .string("test_emit"),
            "scenario": .string("compaction_nonretry_queued_continuation_final")
        ])
        events = await waitForRecordedEvents(recorder, timeoutNanoseconds: 1_500_000_000) { events in
            events.contains { event in
                if case let .turnCompleted(completedTurnID, status) = event {
                    return completedTurnID == turnID && status == .completed
                }
                return false
            }
        }
        collector.cancel()

        let terminalStatuses = events.compactMap { event -> PiNativeSessionController.TurnStatus? in
            if case let .turnCompleted(completedTurnID, status) = event,
               completedTurnID == turnID
            {
                return status
            }
            return nil
        }
        XCTAssertEqual(terminalStatuses, [.completed])
        let streamText = events.compactMap { event -> String? in
            guard case let .stream(result) = event, result.type == "content" else { return nil }
            return result.text
        }.joined()
        XCTAssertTrue(streamText.contains("before compaction"))
        XCTAssertTrue(streamText.contains("continued after non-retry compaction"))
    }

    func testAutoRetryFinalFailureCompletesOnceAsFailedAfterFinalAgentEndThenRetryEnd() async throws {
        let directory = try makeTemporaryDirectory()
        let scriptURL = try makeFakePiControllerScript(recordURL: directory.appendingPathComponent("commands.jsonl"))
        let client = PiRPCClient(config: .init(
            commandName: scriptURL.path,
            additionalPathHints: [],
            requestTimeout: 2,
            launchArguments: [],
            requiresSupportedVersionCheck: false
        ))
        let controller = makeController(client: client)
        addTeardownBlock { await controller.shutdown() }
        _ = try await controller.startOrResume(existing: nil)

        let stream = await controller.events
        let recorder = EventRecorder()
        let collector = Task {
            for await event in stream {
                await recorder.append(event)
            }
        }

        let turnID = try await controller.sendUserMessage("auto-retry-failure")
        let events = await waitForRecordedEvents(recorder, timeoutNanoseconds: 1_500_000_000) { events in
            events.contains { event in
                if case let .turnCompleted(completedTurnID, status) = event {
                    return completedTurnID == turnID && status == .failed
                }
                return false
            } && events.contains { event in
                if case let .stream(result) = event {
                    return result.type == "status" && (result.text?.contains("final retry failed") ?? false)
                }
                return false
            }
        }
        collector.cancel()

        XCTAssertTrue(events.contains { event in
            if case let .stream(result) = event {
                return result.type == "status" && (result.text?.contains("final retry failed") ?? false)
            }
            return false
        })
        let streamResults = events.compactMap { event -> AIStreamResult? in
            if case let .stream(result) = event { return result }
            return nil
        }
        let stops = streamResults.filter { $0.type == "message_stop" }
        XCTAssertEqual(stops.count, 1)
        XCTAssertEqual(stops.first?.stopReason, "failed")
        XCTAssertNotEqual(stops.first?.stopReason, "end_turn")
        XCTAssertEqual(stops.first?.promptTokens, 9)
        XCTAssertEqual(stops.first?.completionTokens, 4)
        let terminalStatuses = events.compactMap { event -> PiNativeSessionController.TurnStatus? in
            if case let .turnCompleted(completedTurnID, status) = event,
               completedTurnID == turnID
            {
                return status
            }
            return nil
        }
        XCTAssertEqual(terminalStatuses, [.failed])
    }

    func testAutoRetryFinalFailureTimerFallbackEmitsFailedMessageStopOnce() async throws {
        let directory = try makeTemporaryDirectory()
        let scriptURL = try makeFakePiControllerScript(recordURL: directory.appendingPathComponent("commands.jsonl"))
        let client = PiRPCClient(config: .init(
            commandName: scriptURL.path,
            additionalPathHints: [],
            requestTimeout: 2,
            launchArguments: [],
            requiresSupportedVersionCheck: false
        ))
        let sleeper = ManualRecoverySleeper()
        let controller = makeController(
            client: client,
            options: .init(requestTimeout: 2, pendingMessageStopRecoveryGraceInterval: 5),
            recoverySleeper: { await sleeper.sleep($0) }
        )
        addTeardownBlock { await controller.shutdown() }
        _ = try await controller.startOrResume(existing: nil)

        let stream = await controller.events
        let recorder = EventRecorder()
        let collector = Task {
            for await event in stream {
                await recorder.append(event)
            }
        }

        let turnID = try await controller.sendUserMessage("auto-retry-final-agent-end-without-retry-end")
        await sleeper.waitForSleep(interval: 1)
        await sleeper.resumeAll()
        let events = await waitForRecordedEvents(recorder, timeoutNanoseconds: 1_500_000_000) { events in
            events.contains { event in
                if case let .turnCompleted(completedTurnID, status) = event {
                    return completedTurnID == turnID && status == .failed
                }
                return false
            }
        }
        collector.cancel()

        let streamResults = events.compactMap { event -> AIStreamResult? in
            if case let .stream(result) = event { return result }
            return nil
        }
        let stops = streamResults.filter { $0.type == "message_stop" }
        XCTAssertEqual(stops.count, 1)
        XCTAssertEqual(stops.first?.stopReason, "failed")
        XCTAssertNotEqual(stops.first?.stopReason, "end_turn")
        XCTAssertEqual(stops.first?.promptTokens, 7)
        XCTAssertEqual(stops.first?.completionTokens, 3)
        let terminalStatuses = events.compactMap { event -> PiNativeSessionController.TurnStatus? in
            if case let .turnCompleted(completedTurnID, status) = event,
               completedTurnID == turnID
            {
                return status
            }
            return nil
        }
        XCTAssertEqual(terminalStatuses, [.failed])
    }

    func testPostAgentEndContinuationWaitsForTrueFinalAgentEndBeforeCompleting() async throws {
        let directory = try makeTemporaryDirectory()
        let scriptURL = try makeFakePiControllerScript(recordURL: directory.appendingPathComponent("commands.jsonl"))
        let client = PiRPCClient(config: .init(
            commandName: scriptURL.path,
            additionalPathHints: [],
            requestTimeout: 2,
            launchArguments: [],
            requiresSupportedVersionCheck: false
        ))
        let controller = makeController(client: client)
        addTeardownBlock { await controller.shutdown() }
        _ = try await controller.startOrResume(existing: nil)
        await controller.resetEventsStreamForNewRun()

        let stream = await controller.events
        let recorder = EventRecorder()
        let collector = Task {
            for await event in stream {
                await recorder.append(event)
            }
        }

        let turnID = try await controller.sendUserMessage("post-agent-end-continuation")
        var events = await waitForRecordedEvents(recorder, timeoutNanoseconds: 1_500_000_000) { events in
            events.contains { event in
                if case let .stream(result) = event { return result.type == "message_stop" }
                return false
            }
        }
        XCTAssertFalse(events.contains { event in
            if case .turnCompleted = event { return true }
            return false
        }, "the first non-retrying agent_end must not complete before the test releases the post-agent_end continuation")

        _ = try await client.sendCommand([
            "type": .string("test_emit"),
            "scenario": .string("post_agent_end_continuation")
        ])
        events = await waitForRecordedEvents(recorder, timeoutNanoseconds: 1_500_000_000) { events in
            events.contains { event in
                if case let .turnCompleted(completedTurnID, status) = event {
                    return completedTurnID == turnID && status == .completed
                }
                return false
            }
        }
        collector.cancel()

        let terminalStatuses = events.compactMap { event -> PiNativeSessionController.TurnStatus? in
            if case let .turnCompleted(completedTurnID, status) = event,
               completedTurnID == turnID
            {
                return status
            }
            return nil
        }
        XCTAssertEqual(terminalStatuses, [.completed])
        let streamText = events.compactMap { event -> String? in
            guard case let .stream(result) = event, result.type == "content" else { return nil }
            return result.text
        }.joined()
        XCTAssertTrue(streamText.contains("before continuation"))
        XCTAssertTrue(streamText.contains("continued after agent end"))
    }

    func testExtensionQueuedContinuationWithIdleStateDoesNotCompleteBeforeContinuationRuns() async throws {
        let directory = try makeTemporaryDirectory()
        let scriptURL = try makeFakePiControllerScript(recordURL: directory.appendingPathComponent("commands.jsonl"))
        let client = PiRPCClient(config: .init(
            commandName: scriptURL.path,
            additionalPathHints: [],
            requestTimeout: 2,
            launchArguments: [],
            requiresSupportedVersionCheck: false
        ))
        let sleeper = ManualRecoverySleeper()
        let controller = makeController(client: client, recoverySleeper: { await sleeper.sleep($0) })
        addTeardownBlock { await controller.shutdown() }
        _ = try await controller.startOrResume(existing: nil)
        await controller.resetEventsStreamForNewRun()

        let stream = await controller.events
        let recorder = EventRecorder()
        let collector = Task {
            for await event in stream {
                await recorder.append(event)
            }
        }

        let turnID = try await controller.sendUserMessage("extension-queued-continuation")
        await sleeper.waitForSleep(interval: 1)
        var events = await recorder.events()
        XCTAssertFalse(events.contains { event in
            if case .turnCompleted = event { return true }
            return false
        }, "idle get_state after the first agent_end must not complete before the delayed extension continuation is released")

        _ = try await client.sendCommand([
            "type": .string("test_emit"),
            "scenario": .string("extension_queued_continuation_after_idle_state")
        ])
        events = await waitForRecordedEvents(recorder, timeoutNanoseconds: 1_500_000_000) { events in
            events.contains { event in
                if case let .stream(result) = event {
                    return result.type == "content" && result.text == "continued after agent end"
                }
                return false
            }
        }
        XCTAssertFalse(events.contains { event in
            if case .turnCompleted = event { return true }
            return false
        }, "the continuation content must arrive before terminal completion")
        await sleeper.waitForSleep(interval: 1)
        await sleeper.resumeAll()
        events = await waitForRecordedEvents(recorder, timeoutNanoseconds: 1_500_000_000) { events in
            events.contains { event in
                if case let .turnCompleted(completedTurnID, status) = event {
                    return completedTurnID == turnID && status == .completed
                }
                return false
            }
        }
        collector.cancel()

        let terminalStatuses = events.compactMap { event -> PiNativeSessionController.TurnStatus? in
            if case let .turnCompleted(completedTurnID, status) = event,
               completedTurnID == turnID
            {
                return status
            }
            return nil
        }
        XCTAssertEqual(terminalStatuses, [.completed])
        let streamText = events.compactMap { event -> String? in
            guard case let .stream(result) = event, result.type == "content" else { return nil }
            return result.text
        }.joined()
        XCTAssertTrue(streamText.contains("before extension continuation"))
        XCTAssertTrue(streamText.contains("continued after agent end"))

        let firstContinuationIndex = try XCTUnwrap(events.firstIndex { event in
            if case let .stream(result) = event {
                return result.type == "content" && result.text == "continued after agent end"
            }
            return false
        })
        let completionIndex = try XCTUnwrap(events.firstIndex { event in
            if case .turnCompleted = event { return true }
            return false
        })
        XCTAssertLessThan(firstContinuationIndex, completionIndex)
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
        let sleeper = ManualRecoverySleeper()
        let controller = makeController(
            client: client,
            options: .init(requestTimeout: 2, pendingMessageStopRecoveryGraceInterval: 5),
            recoverySleeper: { await sleeper.sleep($0) }
        )
        addTeardownBlock { await controller.shutdown() }
        _ = try await controller.startOrResume(existing: nil)
        await controller.resetEventsStreamForNewRun()

        let stream = await controller.events
        let recorder = EventRecorder()
        let collector = Task {
            for await event in stream {
                await recorder.append(event)
            }
        }

        let turnID = try await controller.sendUserMessage("no-agent-end")
        await sleeper.waitForSleep(interval: 5)
        var events = await recorder.events()

        XCTAssertFalse(events.contains { event in
            if case .turnCompleted = event { return true }
            return false
        }, "pi turn_end must not complete the RepoPrompt run before pi agent_end or the bounded recovery grace expires")

        await sleeper.resumeAll()
        events = await waitForRecordedEvents(recorder) { events in
            events.contains { event in
                if case .turnCompleted = event { return true }
                return false
            }
        }
        collector.cancel()

        let streamResults = events.compactMap { event -> AIStreamResult? in
            if case let .stream(result) = event { return result }
            return nil
        }
        let stops = streamResults.filter { $0.type == "message_stop" }
        let usageResults = streamResults.filter { $0.type == "usage" }

        XCTAssertEqual(stops.count, 1)
        XCTAssertEqual(stops.first?.stopReason, "end_turn")
        XCTAssertEqual(stops.first?.promptTokens, 13)
        XCTAssertEqual(stops.first?.completionTokens, 7)
        XCTAssertEqual(usageResults.count, 1)
        XCTAssertTrue(events.contains { event in
            if case let .diagnostic(diagnostic) = event {
                return diagnostic.kind == .pendingMessageStopRecovery && diagnostic.eventType == "turn_end"
            }
            return false
        })
        XCTAssertTrue(events.contains { event in
            if case let .turnCompleted(completedTurnID, status) = event {
                return completedTurnID == turnID && status == .completed
            }
            return false
        })
        let recoveryStateIndex = events.firstIndex { event in
            if case let .sessionState(state) = event {
                return state.pendingMessageCount == 0
            }
            return false
        }
        let completionIndex = events.firstIndex { event in
            if case .turnCompleted = event { return true }
            return false
        }
        XCTAssertNotNil(recoveryStateIndex)
        XCTAssertNotNil(completionIndex)
        XCTAssertLessThan(try XCTUnwrap(recoveryStateIndex), try XCTUnwrap(completionIndex))

        var completionGate = PiRunCompletionGate()
        completionGate.recordSessionState(stalePendingSessionState())
        let terminalStates = events.compactMap { event -> AgentSessionRunState? in
            switch event {
            case let .sessionState(state):
                completionGate.recordSessionState(state)
                return nil
            case let .turnCompleted(_, status):
                return completionGate.terminalState(for: status)
            default:
                return nil
            }
        }
        XCTAssertEqual(terminalStates, [.completed])
    }

    func testLateRetryEventsAfterGraceRecoveryAreIgnored() async throws {
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
        let sleeper = ManualRecoverySleeper()
        let controller = makeController(
            client: client,
            options: .init(requestTimeout: 2, pendingMessageStopRecoveryGraceInterval: 5),
            recoverySleeper: { await sleeper.sleep($0) }
        )
        addTeardownBlock { await controller.shutdown() }
        _ = try await controller.startOrResume(existing: nil)
        await controller.resetEventsStreamForNewRun()

        let stream = await controller.events
        let recorder = EventRecorder()
        let collector = Task {
            for await event in stream {
                await recorder.append(event)
            }
        }

        let turnID = try await controller.sendUserMessage("late-retry-after-recovery")
        await sleeper.waitForSleep(interval: 5)
        await sleeper.resumeAll()
        var events = await waitForRecordedEvents(recorder) { events in
            events.contains { event in
                if case .turnCompleted = event { return true }
                return false
            }
        }

        XCTAssertEqual(events.compactMap { event -> PiNativeSessionController.TurnStatus? in
            if case let .turnCompleted(completedTurnID, status) = event,
               completedTurnID == turnID
            {
                return status
            }
            return nil
        }, [.completed])

        _ = try await client.sendCommand([
            "type": .string("test_emit"),
            "scenario": .string("late_retry_after_recovery")
        ])
        events = await waitForRecordedEvents(recorder, timeoutNanoseconds: 1_500_000_000) { events in
            events.contains { event in
                if case let .diagnostic(diagnostic) = event {
                    return diagnostic.kind == .lateEventAfterTerminalRecovery && diagnostic.eventType == "agent_end"
                }
                return false
            } && events.contains { event in
                if case let .diagnostic(diagnostic) = event {
                    return diagnostic.kind == .lateEventAfterTerminalRecovery && diagnostic.eventType == "auto_retry_start"
                }
                return false
            } && events.contains { event in
                if case let .diagnostic(diagnostic) = event {
                    return diagnostic.kind == .lateEventAfterTerminalRecovery && diagnostic.eventType == "session_info_changed"
                }
                return false
            } && events.contains { event in
                if case let .diagnostic(diagnostic) = event {
                    return diagnostic.kind == .lateEventAfterTerminalRecovery && diagnostic.eventType == "thinking_level_changed"
                }
                return false
            }
        }
        collector.cancel()

        let terminalEvents = events.compactMap { event -> PiNativeSessionController.TurnStatus? in
            if case let .turnCompleted(_, status) = event { return status }
            return nil
        }
        XCTAssertEqual(terminalEvents, [.completed])
        XCTAssertTrue(events.contains { event in
            if case let .diagnostic(diagnostic) = event {
                return diagnostic.kind == .lateEventAfterTerminalRecovery && diagnostic.eventType == "auto_retry_start"
            }
            return false
        })
        XCTAssertTrue(events.contains { event in
            if case let .diagnostic(diagnostic) = event {
                return diagnostic.kind == .lateEventAfterTerminalRecovery && diagnostic.eventType == "session_info_changed"
            }
            return false
        })
        XCTAssertTrue(events.contains { event in
            if case let .diagnostic(diagnostic) = event {
                return diagnostic.kind == .lateEventAfterTerminalRecovery && diagnostic.eventType == "thinking_level_changed"
            }
            return false
        })
        XCTAssertEqual(recordedCommands(at: recordURL).map(\.type).count(where: { $0 == "get_state" }), 2)
    }

    func testPendingMessageStopRecoveryTimerDefersAfterInterveningClientActivity() async throws {
        let directory = try makeTemporaryDirectory()
        let scriptURL = try makeFakePiControllerScript(recordURL: directory.appendingPathComponent("commands.jsonl"))
        let client = PiRPCClient(config: .init(
            commandName: scriptURL.path,
            additionalPathHints: [],
            requestTimeout: 2,
            launchArguments: [],
            requiresSupportedVersionCheck: false
        ))
        let sleeper = ManualRecoverySleeper()
        let controller = makeController(
            client: client,
            options: .init(requestTimeout: 2, pendingMessageStopRecoveryGraceInterval: 5),
            recoverySleeper: { await sleeper.sleep($0) }
        )
        addTeardownBlock { await controller.shutdown() }
        _ = try await controller.startOrResume(existing: nil)

        let stream = await controller.events
        let recorder = EventRecorder()
        let collector = Task {
            for await event in stream {
                await recorder.append(event)
            }
        }

        _ = try await controller.sendUserMessage("activity-after-turn-end")
        await sleeper.waitForSleep(interval: 5)
        _ = try await client.sendCommand([
            "type": .string("test_emit"),
            "scenario": .string("late_activity_after_turn_end")
        ])
        var events = await waitForRecordedEvents(recorder, timeoutNanoseconds: 1_500_000_000) { events in
            events.contains { event in
                if case let .stream(result) = event { return result.type == "content" && result.text == "late activity" }
                return false
            }
        }
        XCTAssertFalse(events.contains { event in
            if case .turnCompleted = event { return true }
            return false
        }, "client activity after turn_end should restart the recovery grace timer")

        await sleeper.waitForSleep(interval: 5)
        await sleeper.resumeAll()
        events = await waitForRecordedEvents(recorder, timeoutNanoseconds: 1_500_000_000) { events in
            events.contains { event in
                if case .turnCompleted = event { return true }
                return false
            }
        }
        collector.cancel()

        XCTAssertEqual(events.count { event in
            if case .turnCompleted = event { return true }
            return false
        }, 1)
    }

    func testAbortAfterTurnEndPreservesPendingStopAndUsageAsCancelled() async throws {
        let directory = try makeTemporaryDirectory()
        let scriptURL = try makeFakePiControllerScript(recordURL: directory.appendingPathComponent("commands.jsonl"))
        let client = PiRPCClient(config: .init(
            commandName: scriptURL.path,
            additionalPathHints: [],
            requestTimeout: 2,
            launchArguments: [],
            requiresSupportedVersionCheck: false
        ))
        let sleeper = ManualRecoverySleeper()
        let controller = makeController(
            client: client,
            options: .init(requestTimeout: 2, pendingMessageStopRecoveryGraceInterval: 5),
            recoverySleeper: { await sleeper.sleep($0) }
        )
        addTeardownBlock { await controller.shutdown() }
        _ = try await controller.startOrResume(existing: nil)

        let stream = await controller.events
        let recorder = EventRecorder()
        let collector = Task {
            for await event in stream {
                await recorder.append(event)
            }
        }

        let turnID = try await controller.sendUserMessage("no-agent-end")
        _ = await waitForRecordedEvents(recorder) { events in
            events.contains { event in
                if case let .stream(result) = event { return result.type == "content" && result.text == "hello back" }
                return false
            }
        }
        let interruptOutcome = await controller.interruptTurn(reason: "cancel")
        XCTAssertEqual(interruptOutcome, .acknowledged)
        let events = await waitForRecordedEvents(recorder) { events in
            events.contains { event in
                if case .turnCompleted = event { return true }
                return false
            }
        }
        collector.cancel()

        let streamResults = events.compactMap { event -> AIStreamResult? in
            if case let .stream(result) = event { return result }
            return nil
        }
        let stops = streamResults.filter { $0.type == "message_stop" }
        let usageResults = streamResults.filter { $0.type == "usage" }

        XCTAssertEqual(stops.count, 1)
        XCTAssertEqual(stops.first?.stopReason, "cancelled")
        XCTAssertEqual(stops.first?.promptTokens, 13)
        XCTAssertEqual(stops.first?.completionTokens, 7)
        XCTAssertEqual(usageResults.count, 1)
        XCTAssertTrue(events.contains { event in
            if case let .turnCompleted(completedTurnID, status) = event {
                return completedTurnID == turnID && status == .cancelled
            }
            return false
        })
    }

    func testTransportCloseAfterTurnEndPreservesPendingStopAndUsageAsFailed() async throws {
        let directory = try makeTemporaryDirectory()
        let scriptURL = try makeFakePiControllerScript(recordURL: directory.appendingPathComponent("commands.jsonl"))
        let client = PiRPCClient(config: .init(
            commandName: scriptURL.path,
            additionalPathHints: [],
            requestTimeout: 2,
            launchArguments: [],
            requiresSupportedVersionCheck: false
        ))
        let sleeper = ManualRecoverySleeper()
        let controller = makeController(
            client: client,
            options: .init(requestTimeout: 2, pendingMessageStopRecoveryGraceInterval: 5),
            recoverySleeper: { await sleeper.sleep($0) }
        )
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

        let turnID = try await controller.sendUserMessage("transport-close-after-turn-end")
        let events = await collector.value
        let streamResults = events.compactMap { event -> AIStreamResult? in
            if case let .stream(result) = event { return result }
            return nil
        }
        let stops = streamResults.filter { $0.type == "message_stop" }
        let usageResults = streamResults.filter { $0.type == "usage" }

        XCTAssertEqual(stops.count, 1)
        XCTAssertEqual(stops.first?.stopReason, "failed")
        XCTAssertEqual(stops.first?.promptTokens, 13)
        XCTAssertEqual(stops.first?.completionTokens, 7)
        XCTAssertEqual(usageResults.count, 1)
        XCTAssertTrue(events.contains { event in
            if case let .turnCompleted(completedTurnID, status) = event {
                return completedTurnID == turnID && status == .failed
            }
            return false
        })
    }

    func testModelSpecifierParsesProviderModelAndThinking() {
        XCTAssertEqual(
            PiModelSpecifier(raw: "zai/glm-5.2:high", knownModelIDs: []),
            PiModelSpecifier(provider: "zai", modelID: "glm-5.2", thinkingLevel: "high")
        )
        XCTAssertEqual(
            PiModelSpecifier(raw: "openai-codex/gpt-5.5:low", knownModelIDs: []),
            PiModelSpecifier(provider: "openai-codex", modelID: "gpt-5.5", thinkingLevel: "low")
        )
        XCTAssertEqual(
            PiModelSpecifier(raw: "zai/glm-5.2:High", knownModelIDs: []),
            PiModelSpecifier(provider: "zai", modelID: "glm-5.2", thinkingLevel: "high")
        )
        XCTAssertEqual(
            PiModelSpecifier(raw: "zai/glm-5.2:XHIGH", knownModelIDs: []),
            PiModelSpecifier(provider: "zai", modelID: "glm-5.2", thinkingLevel: "xhigh")
        )
        XCTAssertEqual(
            PiModelSpecifier(raw: "openai-codex/gpt-5.5:low", knownModelIDs: [])?.providerQualifiedModelRaw,
            "openai-codex/gpt-5.5"
        )
        XCTAssertEqual(
            PiModelSpecifier(raw: "deepseek/deepseek-v4-flash", knownModelIDs: []),
            PiModelSpecifier(provider: "deepseek", modelID: "deepseek-v4-flash", thinkingLevel: nil)
        )
        XCTAssertEqual(
            PiModelSpecifier(raw: "deepseek/deepseek-v4-flash:none", knownModelIDs: []),
            PiModelSpecifier(provider: "deepseek", modelID: "deepseek-v4-flash:none", thinkingLevel: nil)
        )
        XCTAssertEqual(
            PiModelSpecifier(raw: "deepseek/deepseek-v4-flash:x-high", knownModelIDs: []),
            PiModelSpecifier(provider: "deepseek", modelID: "deepseek-v4-flash:x-high", thinkingLevel: nil)
        )
        XCTAssertEqual(
            PiModelSpecifier(raw: "deepseek/deepseek-v4-flash:high", knownModelIDs: []),
            PiModelSpecifier(provider: "deepseek", modelID: "deepseek-v4-flash", thinkingLevel: "high")
        )
        XCTAssertEqual(
            PiModelSpecifier(raw: "deepseek/deepseek-v4-flash", knownModelIDs: ["deepseek/deepseek-v4-flash"]),
            PiModelSpecifier(provider: "deepseek", modelID: "deepseek-v4-flash", thinkingLevel: nil)
        )
        XCTAssertEqual(
            PiModelSpecifier(raw: "openai-codex/gpt-5.4-mini", knownModelIDs: []),
            PiModelSpecifier(provider: "openai-codex", modelID: "gpt-5.4-mini", thinkingLevel: nil)
        )
        XCTAssertEqual(
            PiModelSpecifier(raw: "glm-5.2", knownModelIDs: []),
            PiModelSpecifier(provider: nil, modelID: "glm-5.2", thinkingLevel: nil)
        )
        XCTAssertNil(PiModelSpecifier(raw: "default", knownModelIDs: []))
    }

    private func makeController(
        client: PiRPCClient,
        options: PiNativeSessionController.Options = .init(requestTimeout: 2),
        workspacePath: String? = nil,
        recoverySleeper: @escaping @Sendable (TimeInterval) async -> Void = { _ in }
    ) -> PiNativeSessionController {
        PiNativeSessionController(
            client: client,
            options: options,
            workspacePath: workspacePath,
            recoverySleeper: recoverySleeper
        )
    }

    private func stalePendingSessionState() -> PiRPCClient.SessionState {
        PiRPCClient.SessionState(
            sessionID: "stale-pi-session",
            sessionFile: "/tmp/stale-pi-session.jsonl",
            sessionName: nil,
            thinkingLevel: nil,
            isStreaming: false,
            isCompacting: false,
            messageCount: nil,
            pendingMessageCount: 1,
            model: nil
        )
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
        PENDING_COUNT_OVERRIDES = []
        GET_STATE_FAILURES = 0
        FAIL_AFTER_PENDING_STATE = False
        COMPACTION_ACTIVE = False
        EMIT_EXTENSION_CONTINUATION_AFTER_IDLE_STATE = False
        EXTENSION_CONTINUATION_READY = False

        def emit_post_agent_end_continuation():
            emit({"type": "agent_start"})
            emit({"type": "turn_start"})
            emit({"type": "message_update", "assistantMessageEvent": {"type": "text_delta", "contentIndex": 0, "delta": "continued after agent end"}})
            emit({"type": "message_end", "message": {"role": "assistant", "content": "continued after agent end", "usage": {"input": 5, "output": 3, "totalTokens": 8}}})
            emit({"type": "turn_end", "toolResults": []})
            emit({"type": "agent_end", "messages": [], "willRetry": False})

        def emit_late_retry_after_recovery():
            emit({"type": "agent_end", "messages": [], "willRetry": True})
            emit({"type": "auto_retry_start", "attempt": 2, "maxAttempts": 3, "delayMs": 25, "errorMessage": "provider overloaded"})
            emit({"type": "agent_start"})
            emit({"type": "session_info_changed", "name": "late"})
            emit({"type": "thinking_level_changed", "level": "medium"})

        def emit_late_activity_after_turn_end():
            emit({"type": "message_update", "assistantMessageEvent": {"type": "text_delta", "contentIndex": 0, "delta": "late activity"}})

        def emit_compaction_retry_continuation():
            global COMPACTION_ACTIVE
            COMPACTION_ACTIVE = False
            emit({"type": "compaction_end", "reason": "overflow", "result": {"messageCount": 2}, "aborted": False, "willRetry": True, "errorMessage": "context overflow"})
            emit({"type": "agent_start"})
            emit({"type": "turn_start"})
            emit({"type": "message_update", "assistantMessageEvent": {"type": "text_delta", "contentIndex": 0, "delta": "after compaction retry"}})
            emit({"type": "turn_end", "toolResults": []})
            emit({"type": "agent_end", "messages": [], "willRetry": False})

        def emit_compaction_nonretry_queued_continuation_end():
            global COMPACTION_ACTIVE
            COMPACTION_ACTIVE = False
            PENDING_COUNT_OVERRIDES.append(1)
            emit({"type": "compaction_end", "reason": "threshold", "result": {"messageCount": 2}, "aborted": False, "willRetry": False})

        def emit_compaction_nonretry_queued_continuation_final():
            emit({"type": "agent_start"})
            emit({"type": "turn_start"})
            emit({"type": "message_update", "assistantMessageEvent": {"type": "text_delta", "contentIndex": 0, "delta": "continued after non-retry compaction"}})
            emit({"type": "message_end", "message": {"role": "assistant", "content": "continued after non-retry compaction", "usage": {"input": 12, "output": 6, "totalTokens": 18}}})
            emit({"type": "turn_end", "toolResults": []})
            emit({"type": "agent_end", "messages": [], "willRetry": False})

        def emit_compaction_terminal_state_failure():
            global COMPACTION_ACTIVE, GET_STATE_FAILURES
            COMPACTION_ACTIVE = False
            GET_STATE_FAILURES = 1
            emit({"type": "compaction_end", "reason": "threshold", "result": {"messageCount": 2}, "aborted": False, "willRetry": False})

        def state(request_id):
            global GET_STATE_FAILURES, FAIL_AFTER_PENDING_STATE, EMIT_EXTENSION_CONTINUATION_AFTER_IDLE_STATE, EXTENSION_CONTINUATION_READY
            if GET_STATE_FAILURES > 0:
                GET_STATE_FAILURES -= 1
                emit({"type": "response", "id": request_id, "command": "get_state", "success": False, "error": "transient get_state failure"})
                return
            pending_count = PENDING_COUNT_OVERRIDES.pop(0) if PENDING_COUNT_OVERRIDES else 0
            is_streaming = pending_count > 0
            if pending_count > 0 and FAIL_AFTER_PENDING_STATE:
                GET_STATE_FAILURES = 1
                FAIL_AFTER_PENDING_STATE = False
            emit({
                "type": "response",
                "id": request_id,
                "command": "get_state",
                "success": True,
                "data": {
                    "sessionId": SESSION_ID,
                    "sessionFile": SESSION_FILE,
                    "thinkingLevel": "high",
                    "isStreaming": is_streaming,
                    "isCompacting": COMPACTION_ACTIVE,
                    "messageCount": 1,
                    "pendingMessageCount": pending_count,
                    "model": {"provider": "zai", "id": "glm-5.2", "displayName": "GLM 5.2"}
                }
            })
            if EMIT_EXTENSION_CONTINUATION_AFTER_IDLE_STATE and pending_count == 0 and not is_streaming and not COMPACTION_ACTIVE:
                EXTENSION_CONTINUATION_READY = True

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
            elif command == "get_available_models":
                emit({
                    "type": "response",
                    "id": request_id,
                    "command": "get_available_models",
                    "success": True,
                    "data": {"models": [
                        {"provider": "zai", "id": "glm-5.2", "displayName": "GLM 5.2", "description": "Strong GLM", "reasoning": True},
                        {"provider": "anthropic", "id": "claude-opus-4-6", "displayName": "Claude Opus 4.6"},
                        {"provider": "deepseek", "id": "deepseek-v4-flash", "displayName": "DeepSeek V4 Flash", "reasoning": True}
                    ]}
                })
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
                elif request.get("message") == "subagent-progress":
                    emit({"type": "tool_execution_start", "toolCallId": "call-sub", "toolName": "subagent", "args": {"agent": "worker", "task": "Refactor"}})
                    emit({"type": "message_end", "message": {"role": "custom", "customType": "subagent_control_notice", "display": False, "content": "Hidden control notice", "details": {"event": {"agent": "hidden-worker", "message": "hidden should not display", "currentTool": "bash"}}}})
                    emit({"type": "message_end", "message": {"role": "custom", "customType": "subagent_control_notice", "display": True, "content": "Subagent needs attention: worker", "details": {"event": {"agent": "worker", "message": "worker needs attention (no observed activity for 60s)", "currentTool": "bash"}}}})
                    emit({"type": "tool_execution_end", "toolCallId": "call-sub", "toolName": "subagent", "result": {"content": [{"type": "text", "text": "Detached for intercom coordination: worker."}], "details": {"mode": "single", "runId": "7bee22c2", "results": [{"agent": "worker", "exitCode": 0, "detached": True}]}}, "isError": False})
                elif request.get("message") == "subagent-running":
                    emit({"type": "tool_execution_start", "toolCallId": "call-sub", "toolName": "subagent", "args": {"agent": "worker", "task": "Refactor"}})
                    emit({"type": "tool_execution_end", "toolCallId": "call-sub", "toolName": "subagent", "result": {"content": [{"type": "text", "text": "Subagent still running."}], "details": {"mode": "parallel", "runId": "running1", "results": [{"agent": "worker", "exitCode": -1}]}}, "isError": False})
                elif request.get("message") == "subagent-timeout":
                    emit({"type": "tool_execution_start", "toolCallId": "call-sub", "toolName": "subagent", "args": {"agent": "worker", "task": "Refactor"}})
                    emit({"type": "tool_execution_end", "toolCallId": "call-sub", "toolName": "subagent", "result": {"content": [{"type": "text", "text": "Subagent timed out."}], "details": {"mode": "single", "runId": "deadbeef", "results": [{"agent": "worker", "exitCode": 1, "timedOut": True}]}}, "isError": True})
                elif request.get("message") == "done-before-usage":
                    emit({"type": "message_update", "assistantMessageEvent": {"type": "text_delta", "contentIndex": 0, "delta": "done path"}})
                    emit({"type": "message_update", "assistantMessageEvent": {"type": "done", "reason": "stop"}})
                    emit({"type": "message_end", "message": {"role": "assistant", "content": "done path", "usage": {"input": 6, "output": 3, "totalTokens": 9}}})
                elif request.get("message") == "multi-turn-before-agent-end":
                    emit({"type": "message_update", "assistantMessageEvent": {"type": "text_delta", "contentIndex": 0, "delta": "first"}})
                    emit({"type": "message_end", "message": {"role": "assistant", "content": "first", "usage": {"input": 3, "output": 2, "totalTokens": 5}}})
                    emit({"type": "turn_end", "toolResults": []})
                    emit({"type": "turn_start"})
                    emit({"type": "message_update", "assistantMessageEvent": {"type": "text_delta", "contentIndex": 0, "delta": "second"}})
                    emit({"type": "message_end", "message": {"role": "assistant", "content": "second", "usage": {"input": 5, "output": 4, "totalTokens": 9}}})
                elif request.get("message") == "auto-retry":
                    emit({"type": "message_update", "assistantMessageEvent": {"type": "text_delta", "contentIndex": 0, "delta": "first attempt failed"}})
                elif request.get("message") == "auto-retry-usage":
                    emit({"type": "message_update", "assistantMessageEvent": {"type": "text_delta", "contentIndex": 0, "delta": "retrying attempt with usage"}})
                    emit({"type": "message_end", "message": {"role": "assistant", "content": "retrying attempt with usage", "usage": {"input": 4, "output": 2, "totalTokens": 6}}})
                elif request.get("message") in ["compaction-retry", "compaction-threshold", "compaction-nonretry-queued-continuation", "compaction-terminal-state-failure"]:
                    emit({"type": "message_update", "assistantMessageEvent": {"type": "text_delta", "contentIndex": 0, "delta": "before compaction"}})
                    emit({"type": "message_end", "message": {"role": "assistant", "content": "before compaction", "usage": {"input": 4, "output": 2, "totalTokens": 6}}})
                elif request.get("message") == "auto-retry-failure":
                    emit({"type": "message_update", "assistantMessageEvent": {"type": "text_delta", "contentIndex": 0, "delta": "first attempt failed"}})
                elif request.get("message") == "auto-retry-final-agent-end-without-retry-end":
                    emit({"type": "message_update", "assistantMessageEvent": {"type": "text_delta", "contentIndex": 0, "delta": "first attempt failed"}})
                elif request.get("message") == "post-agent-end-continuation":
                    emit({"type": "message_update", "assistantMessageEvent": {"type": "text_delta", "contentIndex": 0, "delta": "before continuation"}})
                    emit({"type": "message_end", "message": {"role": "assistant", "content": "before continuation", "usage": {"input": 4, "output": 2, "totalTokens": 6}}})
                elif request.get("message") == "extension-queued-continuation":
                    emit({"type": "message_update", "assistantMessageEvent": {"type": "text_delta", "contentIndex": 0, "delta": "before extension continuation"}})
                    emit({"type": "message_end", "message": {"role": "assistant", "content": "before extension continuation", "usage": {"input": 4, "output": 2, "totalTokens": 6}}})
                elif request.get("message") == "protocol-drift":
                    emit({"type": "future_event", "note": "sk-fixture-redaction-value", "payload": {"message": "new shape"}})
                    emit({"type": "message_update", "assistantMessageEvent": {"type": "text_delta", "contentIndex": 0, "delta": "continued after drift"}})
                elif request.get("message") == "agent-end-usage":
                    emit({"type": "message_update", "assistantMessageEvent": {"type": "text_delta", "contentIndex": 0, "delta": "final usage"}})
                elif request.get("message") == "transport-close-after-turn-end":
                    emit({"type": "message_update", "assistantMessageEvent": {"type": "text_delta", "contentIndex": 0, "delta": "transport close"}})
                    emit({"type": "message_end", "message": {"role": "assistant", "content": "transport close", "usage": {"input": 10, "output": 7, "cacheRead": 2, "cacheWrite": 1, "totalTokens": 20, "cost": {"total": 0.03}}}})
                elif request.get("message") == "queued-steer-boundaries":
                    emit({"type": "message_update", "assistantMessageEvent": {"type": "text_delta", "contentIndex": 0, "delta": "first turn"}})
                    emit({"type": "message_end", "message": {"role": "assistant", "content": "first turn", "usage": {"input": 4, "output": 2, "totalTokens": 6}}})
                elif request.get("message") == "queued-follow-up-boundaries":
                    emit({"type": "message_update", "assistantMessageEvent": {"type": "text_delta", "contentIndex": 0, "delta": "first turn"}})
                    emit({"type": "message_end", "message": {"role": "assistant", "content": "first turn", "usage": {"input": 4, "output": 2, "totalTokens": 6}}})
                elif request.get("message") == "agent-end-refresh-fails-after-stale-pending":
                    PENDING_COUNT_OVERRIDES.append(1)
                    FAIL_AFTER_PENDING_STATE = True
                    emit({"type": "session_info_changed", "name": "stale pending"})
                    emit({"type": "message_update", "assistantMessageEvent": {"type": "text_delta", "contentIndex": 0, "delta": "final answer"}})
                    emit({"type": "message_end", "message": {"role": "assistant", "content": "final answer", "usage": {"input": 4, "output": 2, "totalTokens": 6}}})
                else:
                    emit({"type": "message_update", "assistantMessageEvent": {"type": "thinking_delta", "contentIndex": 0, "delta": "thinking..."}})
                    emit({"type": "message_update", "assistantMessageEvent": {"type": "text_delta", "contentIndex": 1, "delta": "hello back"}})
                    emit({"type": "tool_execution_start", "toolCallId": "call-1", "toolName": "bash", "args": {"command": "echo hi"}})
                    emit({"type": "tool_execution_end", "toolCallId": "call-1", "toolName": "bash", "result": {"content": [{"type": "text", "text": "hi"}]}, "isError": False})
                    emit({"type": "message_end", "message": {"role": "assistant", "content": "hello back", "usage": {"input": 10, "output": 7, "cacheRead": 2, "cacheWrite": 1, "totalTokens": 20, "cost": {"total": 0.03}}}})
                emit({"type": "turn_end", "toolResults": []})
                emit({"type": "response", "id": request_id, "command": "prompt", "success": True})
                if request.get("message") == "auto-retry":
                    emit({"type": "agent_end", "messages": [], "willRetry": True})
                    emit({"type": "auto_retry_start", "attempt": 2, "maxAttempts": 3, "delayMs": 25, "errorMessage": "provider overloaded"})
                    emit({"type": "agent_start"})
                    emit({"type": "turn_start"})
                    emit({"type": "message_update", "assistantMessageEvent": {"type": "text_delta", "contentIndex": 0, "delta": "retry success"}})
                    emit({"type": "turn_end", "toolResults": []})
                    emit({"type": "auto_retry_end", "success": True, "attempt": 2})
                    emit({"type": "agent_end", "messages": [], "willRetry": False})
                elif request.get("message") == "auto-retry-usage":
                    emit({"type": "agent_end", "messages": [], "willRetry": True})
                    emit({"type": "auto_retry_start", "attempt": 2, "maxAttempts": 3, "delayMs": 25, "errorMessage": "provider overloaded"})
                    emit({"type": "agent_start"})
                    emit({"type": "turn_start"})
                    emit({"type": "message_update", "assistantMessageEvent": {"type": "text_delta", "contentIndex": 0, "delta": "retry success with usage"}})
                    emit({"type": "message_end", "message": {"role": "assistant", "content": "retry success with usage", "usage": {"input": 11, "output": 5, "totalTokens": 16}}})
                    emit({"type": "turn_end", "toolResults": []})
                    emit({"type": "auto_retry_end", "success": True, "attempt": 2})
                    emit({"type": "agent_end", "messages": [], "willRetry": False})
                elif request.get("message") == "compaction-retry":
                    COMPACTION_ACTIVE = True
                    emit({"type": "agent_end", "messages": [], "willRetry": False})
                    emit({"type": "compaction_start", "reason": "overflow"})
                elif request.get("message") == "compaction-threshold":
                    COMPACTION_ACTIVE = True
                    emit({"type": "agent_end", "messages": [], "willRetry": False})
                    emit({"type": "compaction_start", "reason": "threshold"})
                elif request.get("message") == "compaction-nonretry-queued-continuation":
                    COMPACTION_ACTIVE = True
                    emit({"type": "agent_end", "messages": [], "willRetry": False})
                    emit({"type": "compaction_start", "reason": "threshold"})
                elif request.get("message") == "compaction-terminal-state-failure":
                    COMPACTION_ACTIVE = True
                    emit({"type": "agent_end", "messages": [], "willRetry": False})
                    emit({"type": "compaction_start", "reason": "threshold"})
                elif request.get("message") == "agent-end-usage":
                    emit({"type": "agent_end", "messages": [{"role": "assistant", "content": "final", "usage": {"input": 8, "output": 4, "cacheRead": 1, "totalTokens": 14}}], "willRetry": False})
                elif request.get("message") == "auto-retry-failure":
                    emit({"type": "agent_end", "messages": [], "willRetry": True})
                    emit({"type": "auto_retry_start", "attempt": 3, "maxAttempts": 3, "delayMs": 25, "errorMessage": "provider overloaded"})
                    emit({"type": "agent_start"})
                    emit({"type": "turn_start"})
                    emit({"type": "message_update", "assistantMessageEvent": {"type": "text_delta", "contentIndex": 0, "delta": "final attempt failed"}})
                    emit({"type": "message_end", "message": {"role": "assistant", "content": "final attempt failed", "usage": {"input": 9, "output": 4, "totalTokens": 13}, "stopReason": "error", "errorMessage": "final retry failed"}})
                    emit({"type": "turn_end", "toolResults": []})
                    PENDING_COUNT_OVERRIDES.append(1)
                    emit({"type": "agent_end", "messages": [], "willRetry": False})
                    emit({"type": "auto_retry_end", "success": False, "attempt": 3, "finalError": "final retry failed"})
                elif request.get("message") == "auto-retry-final-agent-end-without-retry-end":
                    emit({"type": "agent_end", "messages": [], "willRetry": True})
                    emit({"type": "auto_retry_start", "attempt": 3, "maxAttempts": 3, "delayMs": 25, "errorMessage": "provider overloaded"})
                    emit({"type": "agent_start"})
                    emit({"type": "turn_start"})
                    emit({"type": "message_update", "assistantMessageEvent": {"type": "text_delta", "contentIndex": 0, "delta": "final attempt timed out"}})
                    emit({"type": "message_end", "message": {"role": "assistant", "content": "final attempt timed out", "usage": {"input": 7, "output": 3, "totalTokens": 10}, "stopReason": "error", "errorMessage": "final retry timed out"}})
                    emit({"type": "turn_end", "toolResults": []})
                    emit({"type": "agent_end", "messages": [], "willRetry": False})
                elif request.get("message") == "post-agent-end-continuation":
                    PENDING_COUNT_OVERRIDES.append(1)
                    emit({"type": "agent_end", "messages": [], "willRetry": False})
                elif request.get("message") == "extension-queued-continuation":
                    EMIT_EXTENSION_CONTINUATION_AFTER_IDLE_STATE = True
                    emit({"type": "agent_end", "messages": [], "willRetry": False})
                elif request.get("message") == "transport-close-after-turn-end":
                    sys.exit(0)
                elif request.get("message") not in ["no-agent-end", "late-retry-after-recovery", "activity-after-turn-end", "queued-steer-boundaries", "queued-follow-up-boundaries"]:
                    emit({"type": "agent_end", "messages": [], "willRetry": False})
            elif command == "steer" and request.get("message") == "queued steer":
                emit({"type": "response", "id": request_id, "command": "steer", "success": True})

                def drain_queued_steer_before_final_agent_end():
                    emit({"type": "turn_start"})
                    emit({"type": "message_update", "assistantMessageEvent": {"type": "text_delta", "contentIndex": 0, "delta": "steered turn"}})
                    emit({"type": "message_end", "message": {"role": "assistant", "content": "steered turn", "usage": {"input": 5, "output": 3, "totalTokens": 8}}})
                    emit({"type": "turn_end", "toolResults": []})
                    emit({"type": "agent_end", "messages": [], "willRetry": False})

                drain_queued_steer_before_final_agent_end()
            elif command == "follow_up" and request.get("message") == "queued follow up":
                emit({"type": "response", "id": request_id, "command": "follow_up", "success": True})

                def drain_queued_follow_up_before_final_agent_end():
                    emit({"type": "turn_start"})
                    emit({"type": "message_update", "assistantMessageEvent": {"type": "text_delta", "contentIndex": 0, "delta": "follow-up turn"}})
                    emit({"type": "message_end", "message": {"role": "assistant", "content": "follow-up turn", "usage": {"input": 5, "output": 3, "totalTokens": 8}}})
                    emit({"type": "turn_end", "toolResults": []})
                    emit({"type": "agent_end", "messages": [], "willRetry": False})

                drain_queued_follow_up_before_final_agent_end()
            elif command == "test_emit":
                scenario = request.get("scenario")
                if scenario == "post_agent_end_continuation":
                    emit_post_agent_end_continuation()
                elif scenario == "late_retry_after_recovery":
                    emit_late_retry_after_recovery()
                elif scenario == "late_activity_after_turn_end":
                    emit_late_activity_after_turn_end()
                elif scenario == "compaction_retry_continue":
                    emit_compaction_retry_continuation()
                elif scenario == "compaction_threshold_finish":
                    COMPACTION_ACTIVE = False
                    emit({"type": "compaction_end", "reason": "threshold", "result": {"messageCount": 2}, "aborted": False, "willRetry": False})
                elif scenario == "compaction_nonretry_queued_continuation_end":
                    emit_compaction_nonretry_queued_continuation_end()
                elif scenario == "compaction_nonretry_queued_continuation_final":
                    emit_compaction_nonretry_queued_continuation_final()
                elif scenario == "compaction_terminal_state_failure":
                    emit_compaction_terminal_state_failure()
                elif scenario == "extension_queued_continuation_after_idle_state":
                    if EXTENSION_CONTINUATION_READY:
                        EMIT_EXTENSION_CONTINUATION_AFTER_IDLE_STATE = False
                        EXTENSION_CONTINUATION_READY = False
                        emit_post_agent_end_continuation()
                emit({"type": "response", "id": request_id, "command": "test_emit", "success": True})
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

    private func waitForRecordedEvents(
        _ recorder: EventRecorder,
        timeoutNanoseconds: UInt64 = 1_000_000_000,
        file: StaticString = #filePath,
        line: UInt = #line,
        until predicate: @escaping @Sendable ([PiNativeSessionController.Event]) -> Bool
    ) async -> [PiNativeSessionController.Event] {
        if let events = await recorder.wait(timeoutNanoseconds: timeoutNanoseconds, until: predicate) {
            return events
        }
        let events = await recorder.events()
        if !predicate(events) {
            XCTFail("Timed out waiting for expected pi native controller events", file: file, line: line)
        }
        return events
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

private actor ManualRecoverySleeper {
    private struct Waiter {
        var interval: TimeInterval?
        var count: Int
        var continuation: CheckedContinuation<Void, Never>
    }

    private struct SleepRequest {
        var interval: TimeInterval
        var continuation: CheckedContinuation<Void, Never>
    }

    private var continuations: [UUID: SleepRequest] = [:]
    private var waiters: [UUID: Waiter] = [:]

    func sleep(_ interval: TimeInterval) async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                continuations[id] = SleepRequest(interval: interval, continuation: continuation)
                resolveSatisfiedWaiters()
            }
        } onCancel: {
            Task { await self.cancelSleep(id: id) }
        }
    }

    func waitForSleepCount(_ count: Int) async {
        await waitForSleepCount(count, interval: nil)
    }

    func waitForSleep(interval: TimeInterval) async {
        await waitForSleepCount(1, interval: interval)
    }

    private func waitForSleepCount(_ count: Int, interval: TimeInterval?) async {
        if matchingSleepCount(interval: interval) >= count {
            return
        }
        let id = UUID()
        await withCheckedContinuation { continuation in
            waiters[id] = Waiter(interval: interval, count: count, continuation: continuation)
        }
    }

    func resumeAll() {
        let pending = continuations.values.map(\.continuation)
        continuations.removeAll()
        for continuation in pending {
            continuation.resume()
        }
    }

    private func cancelSleep(id: UUID) {
        let continuation = continuations.removeValue(forKey: id)?.continuation
        continuation?.resume()
        resolveSatisfiedWaiters()
    }

    private func resolveSatisfiedWaiters() {
        for (id, waiter) in waiters where matchingSleepCount(interval: waiter.interval) >= waiter.count {
            waiters.removeValue(forKey: id)
            waiter.continuation.resume()
        }
    }

    private func matchingSleepCount(interval: TimeInterval?) -> Int {
        guard let interval else { return continuations.count }
        return continuations.values.count { abs($0.interval - interval) < 0.000_001 }
    }
}

private actor EventRecorder {
    typealias Event = PiNativeSessionController.Event

    private struct Waiter {
        var predicate: @Sendable ([Event]) -> Bool
        var continuation: CheckedContinuation<[Event]?, Never>
    }

    private var collected: [Event] = []
    private var waiters: [UUID: Waiter] = [:]

    func append(_ event: Event) {
        collected.append(event)
        resolveSatisfiedWaiters()
    }

    func events() -> [Event] {
        collected
    }

    func wait(
        timeoutNanoseconds: UInt64,
        until predicate: @escaping @Sendable ([Event]) -> Bool
    ) async -> [Event]? {
        if predicate(collected) {
            return collected
        }
        let id = UUID()
        return await withTaskGroup(of: [Event]?.self) { group in
            group.addTask { await self.waitForMatch(id: id, until: predicate) }
            group.addTask {
                do {
                    try await Task.sleep(nanoseconds: timeoutNanoseconds)
                } catch {
                    return nil
                }
                await self.cancelWaiter(id: id)
                return nil
            }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }

    private func waitForMatch(
        id: UUID,
        until predicate: @escaping @Sendable ([Event]) -> Bool
    ) async -> [Event]? {
        if predicate(collected) {
            return collected
        }
        return await withCheckedContinuation { continuation in
            waiters[id] = Waiter(predicate: predicate, continuation: continuation)
        }
    }

    private func cancelWaiter(id: UUID) {
        guard let waiter = waiters.removeValue(forKey: id) else { return }
        waiter.continuation.resume(returning: nil)
    }

    private func resolveSatisfiedWaiters() {
        for (id, waiter) in waiters where waiter.predicate(collected) {
            waiters.removeValue(forKey: id)
            waiter.continuation.resume(returning: collected)
        }
    }
}
