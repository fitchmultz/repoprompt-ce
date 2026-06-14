import Foundation
@_spi(TestSupport) @testable import RepoPrompt
import XCTest

@MainActor
final class AgentModePiSteeringQueueTests: XCTestCase {
    private var temporaryURLs: [URL] = []

    override func tearDown() {
        for url in temporaryURLs {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryURLs.removeAll()
        super.tearDown()
    }

    func testPiFollowUpBlockedByPendingInteractionsQueuesThenSteersAfterResolution() async throws {
        for blockingState in PiBlockingState.allCases {
            let fixture = try await makeRunningPiSession()
            install(blockingState, on: fixture.session)

            let result = fixture.viewModel.submitUserTurn(
                text: "blocked \(blockingState.rawValue)",
                tabID: fixture.tabID
            )

            XCTAssertEqual(result, .submitted, blockingState.rawValue)
            XCTAssertEqual(fixture.session.pendingPiSteeringInstructions.count, 1, blockingState.rawValue)
            try await Task.sleep(nanoseconds: 100_000_000)
            XCTAssertFalse(recordedCommands(at: fixture.recordURL).contains { $0.type == "follow_up" || $0.type == "steer" }, blockingState.rawValue)

            clear(blockingState, on: fixture.session)
            fixture.viewModel.publishRunInteractionStateChange(for: fixture.session, reason: .userInputResponseSubmitted)

            try await waitUntil("pi queued steering delivered for \(blockingState.rawValue)") {
                self.recordedCommands(at: fixture.recordURL).contains { $0.type == "steer" }
            }
            let delivered = recordedCommands(at: fixture.recordURL).filter { $0.type == "steer" || $0.type == "follow_up" }
            XCTAssertEqual(delivered.map(\.type), ["steer"], blockingState.rawValue)
            XCTAssertEqual(delivered.first?.message, "blocked \(blockingState.rawValue)", blockingState.rawValue)
            XCTAssertTrue(fixture.session.pendingPiSteeringInstructions.isEmpty, blockingState.rawValue)
            await fixture.controller.shutdown()
        }
    }

    func testPiAskUserResponseFlushesQueuedSteeringWithoutUnrelatedStateChangeBeforeTerminalCleanup() async throws {
        let fixture = try await makeRunningPiSession()
        defer { Task { await fixture.controller.shutdown() } }
        let interaction = makeAskUserPendingState().interaction
        let responseTask = Task { @MainActor in
            try await fixture.viewModel.askUserInteraction(tabID: fixture.tabID, interaction: interaction)
        }
        try await waitUntil("ask_user pending state installed") {
            fixture.session.pendingAskUser?.interaction.id == interaction.id
        }

        let result = fixture.viewModel.submitUserTurn(text: "queued behind ask_user", tabID: fixture.tabID)
        XCTAssertEqual(result, .submitted)
        XCTAssertEqual(fixture.session.pendingPiSteeringInstructions.count, 1)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(recordedCommands(at: fixture.recordURL).contains { $0.type == "steer" || $0.type == "follow_up" })

        try fixture.viewModel.submitAskUserResponse(
            tabID: fixture.tabID,
            interactionID: interaction.id,
            draftsByQuestionID: ["question": AgentAskUserDraft(selectedOptionLabels: ["Yes"])]
        )
        _ = try await responseTask.value
        XCTAssertNil(fixture.session.pendingAskUser)

        try await waitUntil("pi queued steering delivered after ask_user response") {
            self.recordedCommands(at: fixture.recordURL).contains { $0.type == "steer" }
        }
        let delivered = recordedCommands(at: fixture.recordURL).filter { $0.type == "steer" || $0.type == "follow_up" }
        XCTAssertEqual(delivered.map(\.type), ["steer"])
        XCTAssertEqual(delivered.first?.message, "queued behind ask_user")
        XCTAssertTrue(fixture.session.pendingPiSteeringInstructions.isEmpty)

        let runID = try XCTUnwrap(fixture.session.runID)
        _ = PiRunTerminalCleanup.makeTeardown(
            session: fixture.session,
            controller: fixture.controller,
            runID: runID,
            windowID: 1,
            terminalState: .completed
        )
        XCTAssertTrue(fixture.session.pendingPiSteeringInstructions.isEmpty)
        XCTAssertEqual(recordedCommands(at: fixture.recordURL).count(where: { $0.type == "steer" }), 1)
    }

    func testCancelledPiRunClearsQueuedSteering() async throws {
        let viewModel = makeViewModel(testWorkspacePath: FileManager.default.currentDirectoryPath)
        let tabID = UUID()
        viewModel.ensureSession(for: tabID)
        let session = try XCTUnwrap(viewModel.sessions[tabID])
        session.selectedAgent = .pi
        session.runState = .running
        session.runID = UUID()
        session.beginRunAttempt(source: "test")
        session.pendingPiSteeringInstructions.append(makePiSteeringInstruction(session: session, text: "poison"))

        await viewModel.cancelAgentRun(
            tabID: tabID,
            completion: AgentModeRunService.CancellationCompletion.terminalPublished
        )

        XCTAssertTrue(session.pendingPiSteeringInstructions.isEmpty)
        XCTAssertNil(session.piSteeringFlushTask)
    }

    func testUserStopRestoresQueuedPiSteeringDraftsToComposer() async throws {
        let viewModel = makeViewModel(testWorkspacePath: FileManager.default.currentDirectoryPath)
        let tabID = UUID()
        viewModel.ensureSession(for: tabID)
        let session = try XCTUnwrap(viewModel.sessions[tabID])
        session.selectedAgent = .pi
        session.runState = .running
        session.runID = UUID()
        session.beginRunAttempt(source: "test")
        session.pendingPiSteeringInstructions.append(makePiSteeringInstruction(session: session, text: "first undelivered"))
        session.pendingPiSteeringInstructions.append(makePiSteeringInstruction(session: session, text: "second undelivered"))

        await viewModel.cancelAgentRun(
            tabID: tabID,
            completion: AgentModeRunService.CancellationCompletion.terminalPublished
        )

        XCTAssertEqual(session.draftText, "first undelivered\nsecond undelivered")
        XCTAssertEqual(viewModel.draftRestorationEvent?.tabID, tabID)
        XCTAssertEqual(viewModel.draftRestorationEvent?.text, "first undelivered\nsecond undelivered")
        XCTAssertTrue(session.pendingPiSteeringInstructions.isEmpty)
    }

    func testUserStopRestoresOriginalPiFollowUpDraftInsteadOfBubbleText() async throws {
        let fixture = try await makeRunningPiSession()
        defer { Task { await fixture.controller.shutdown() } }
        fixture.session.pendingAskUser = makeAskUserPendingState()
        fixture.session.selectedWorkflow = AgentWorkflowDefinition(
            customID: UUID(),
            displayName: "/skill:test"
        )

        let result = fixture.viewModel.submitUserTurn(
            text: "/skill:test keep slash prefix",
            tabID: fixture.tabID
        )

        XCTAssertEqual(result, .submitted)
        XCTAssertEqual(fixture.session.items.last?.text, "keep slash prefix")
        XCTAssertEqual(fixture.session.pendingPiSteeringInstructions.first?.draftText, "/skill:test keep slash prefix")

        await fixture.viewModel.cancelAgentRun(
            tabID: fixture.tabID,
            completion: AgentModeRunService.CancellationCompletion.terminalPublished
        )

        XCTAssertEqual(fixture.session.draftText, "/skill:test keep slash prefix")
        XCTAssertEqual(fixture.viewModel.draftRestorationEvent?.text, "/skill:test keep slash prefix")
    }

    func testTerminalCleanupRestoresUndeliveredPiSteeringDrafts() async throws {
        let fixture = try await makeRunningPiSession()
        defer { Task { await fixture.controller.shutdown() } }
        let runID = try XCTUnwrap(fixture.session.runID)
        fixture.session.pendingPiSteeringInstructions.append(makePiSteeringInstruction(session: fixture.session, text: "terminal race draft"))
        var restored: (tabID: UUID, text: String, message: String, strategy: AgentModeRunService.DraftRestorationStrategy)?

        _ = PiRunTerminalCleanup.makeTeardown(
            session: fixture.session,
            controller: fixture.controller,
            runID: runID,
            windowID: 1,
            terminalState: .completed,
            restoreUndeliveredPiSteeringDrafts: { tabID, text, message, strategy in
                restored = (tabID, text, message, strategy)
            }
        )

        XCTAssertTrue(fixture.session.pendingPiSteeringInstructions.isEmpty)
        XCTAssertEqual(restored?.tabID, fixture.tabID)
        XCTAssertEqual(restored?.text, "terminal race draft")
        XCTAssertEqual(restored?.strategy, .prependAlways)
        XCTAssertTrue(restored?.message.contains("run ended before pi accepted") == true)
    }

    func testFailedPiSteeringRestoresDraftAndSurfacesError() async throws {
        let fixture = try await makeRunningPiSession()
        defer { Task { await fixture.controller.shutdown() } }

        let result = fixture.viewModel.submitUserTurn(text: "fail steer", tabID: fixture.tabID)

        XCTAssertEqual(result, .submitted)
        try await waitUntil("failed pi steering surfaces error") {
            fixture.session.items.contains { item in
                item.kind == .error && item.text.contains("pi steer failed")
            }
        }
        XCTAssertEqual(fixture.session.draftText, "fail steer")
        XCTAssertEqual(fixture.viewModel.draftRestorationEvent?.text, "fail steer")
        XCTAssertTrue(fixture.session.pendingPiSteeringInstructions.isEmpty)
    }

    func testManualPiSteeringWaitsForActiveMCPToolsBeforeSending() async throws {
        let window = makeMCPWindow()
        addTeardownBlock { @MainActor in
            await self.tearDownMCPWindow(window)
        }
        let fixture = try await makeRunningPiSession(mcpServer: window.mcpServer)
        defer { Task { await fixture.controller.shutdown() } }
        let runID = try XCTUnwrap(fixture.session.runID)
        let maybeExecutionID = await beginActiveMCPTool(on: window, runID: runID)
        let executionID = try XCTUnwrap(maybeExecutionID)

        let result = fixture.viewModel.submitUserTurn(text: "wait for tool", tabID: fixture.tabID)

        XCTAssertEqual(result, .submitted)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(recordedCommands(at: fixture.recordURL).contains { $0.type == "steer" })

        window.mcpServer.test_endToolExecution(executionID: executionID)
        try await waitUntil("pi steering delivered after MCP tool drained") {
            self.recordedCommands(at: fixture.recordURL).contains { $0.type == "steer" && $0.message == "wait for tool" }
        }
    }

    func testPiFollowUpRevalidatesActiveRunAfterMCPToolDrain() async throws {
        let window = makeMCPWindow()
        addTeardownBlock { @MainActor in
            await self.tearDownMCPWindow(window)
        }
        let fixture = try await makeRunningPiSession(mcpServer: window.mcpServer)
        defer { Task { await fixture.controller.shutdown() } }
        let runID = try XCTUnwrap(fixture.session.runID)
        let maybeExecutionID = await beginActiveMCPTool(on: window, runID: runID)
        let executionID = try XCTUnwrap(maybeExecutionID)
        fixture.session.runState = .waitingForUser

        let result = fixture.viewModel.submitUserTurn(text: "late follow up", tabID: fixture.tabID)

        XCTAssertEqual(result, .submitted)
        fixture.session.runState = .completed
        fixture.session.runID = nil
        window.mcpServer.test_endToolExecution(executionID: executionID)

        try await waitUntil("stale pi follow-up restored instead of sent") {
            fixture.session.items.contains { item in
                item.kind == .error && item.text.contains("native pi session is no longer active")
            }
        }
        let delivered = recordedCommands(at: fixture.recordURL).filter { $0.type == "steer" || $0.type == "follow_up" }
        XCTAssertTrue(delivered.isEmpty)
        XCTAssertEqual(fixture.session.draftText, "late follow up")
        XCTAssertEqual(fixture.viewModel.draftRestorationEvent?.text, "late follow up")
    }

    func testPiFollowUpBlockedDuringMCPDrainQueuesUntilInteractionResolves() async throws {
        let window = makeMCPWindow()
        addTeardownBlock { @MainActor in
            await self.tearDownMCPWindow(window)
        }
        let fixture = try await makeRunningPiSession(mcpServer: window.mcpServer)
        defer { Task { await fixture.controller.shutdown() } }
        let runID = try XCTUnwrap(fixture.session.runID)
        let maybeExecutionID = await beginActiveMCPTool(on: window, runID: runID)
        let executionID = try XCTUnwrap(maybeExecutionID)
        fixture.session.runState = .waitingForUser

        let result = fixture.viewModel.submitUserTurn(text: "blocked during drain", tabID: fixture.tabID)

        XCTAssertEqual(result, .submitted)
        fixture.session.pendingAskUser = makeAskUserPendingState()
        window.mcpServer.test_endToolExecution(executionID: executionID)

        try await waitUntil("pi follow-up queued after blocking interaction appeared during MCP drain") {
            fixture.session.pendingPiSteeringInstructions.count == 1
        }
        XCTAssertFalse(recordedCommands(at: fixture.recordURL).contains { $0.type == "follow_up" || $0.type == "steer" })

        fixture.session.pendingAskUser = nil
        fixture.session.runState = .running
        fixture.viewModel.publishRunInteractionStateChange(for: fixture.session, reason: .userInputResponseSubmitted)

        try await waitUntil("queued pi follow-up delivered after blocking interaction resolved") {
            self.recordedCommands(at: fixture.recordURL).contains { $0.type == "steer" && $0.message == "blocked during drain" }
        }
        let delivered = recordedCommands(at: fixture.recordURL).filter { $0.type == "steer" || $0.type == "follow_up" }
        XCTAssertEqual(delivered.map(\.type), ["steer"])
        XCTAssertTrue(fixture.session.pendingPiSteeringInstructions.isEmpty)
    }

    func testMCPDispatchedPiSteeringWaitsForActiveMCPToolsBeforeSending() async throws {
        let window = makeMCPWindow()
        addTeardownBlock { @MainActor in
            await self.tearDownMCPWindow(window)
        }
        let fixture = try await makeRunningPiSession(mcpServer: window.mcpServer)
        defer { Task { await fixture.controller.shutdown() } }
        let runID = try XCTUnwrap(fixture.session.runID)
        let mcpSessionID = UUID()
        fixture.session.mcpControlContext = makeMCPControlContext(sessionID: mcpSessionID)
        let maybeExecutionID = await beginActiveMCPTool(on: window, runID: runID)
        let executionID = try XCTUnwrap(maybeExecutionID)

        let dispatchTask = Task { @MainActor in
            try await fixture.viewModel.mcpDispatchInstruction(
                sessionID: mcpSessionID,
                text: "mcp wait for tool",
                allowStartingRun: false
            )
        }

        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(recordedCommands(at: fixture.recordURL).contains { $0.type == "steer" })

        window.mcpServer.test_endToolExecution(executionID: executionID)
        let delivery = try await dispatchTask.value
        XCTAssertEqual(delivery, .dispatchedPiSteer)
        try await waitUntil("MCP pi steering delivered after MCP tool drained") {
            self.recordedCommands(at: fixture.recordURL).contains { $0.type == "steer" && $0.message == "mcp wait for tool" }
        }
    }

    func testPiSteeringMCPToolDrainTimeoutProceedsAndClearsFlushTask() async throws {
        let window = makeMCPWindow()
        addTeardownBlock { @MainActor in
            await self.tearDownMCPWindow(window)
        }
        let fixture = try await makeRunningPiSession(mcpServer: window.mcpServer)
        defer { Task { await fixture.controller.shutdown() } }
        let runID = try XCTUnwrap(fixture.session.runID)
        _ = await beginActiveMCPTool(on: window, runID: runID)
        fixture.viewModel.test_setPiSteeringMCPToolDrainTimeout(0.05)

        let result = fixture.viewModel.submitUserTurn(text: "timeout best effort", tabID: fixture.tabID)

        XCTAssertEqual(result, .submitted)
        try await waitUntil("pi steering delivered after MCP drain timeout") {
            self.recordedCommands(at: fixture.recordURL).contains { $0.type == "steer" && $0.message == "timeout best effort" }
        }
        try await waitUntil("pi steering flush task cleared after timeout") {
            fixture.session.piSteeringFlushTask == nil
        }
        XCTAssertTrue(fixture.session.runningStatusText?.contains("Continuing pi steering after waiting") == true)
        XCTAssertTrue(window.mcpServer.hasActiveToolExecutions(runID: runID))
    }

    func testCodexApprovalAndPermissionResolutionFlushQueuedPiSteering() async throws {
        for blockingState in [PiBlockingState.approval, .permissions] {
            let fixture = try await makeRunningPiSession()
            let codexController = PiQueueFakeCodexController()
            fixture.session.codexController = codexController
            switch blockingState {
            case .approval:
                fixture.session.pendingApproval = makeCodexApprovalRequest(id: "approval")
            case .permissions:
                fixture.session.pendingPermissionsRequest = makePermissionsRequest(id: "permissions")
            default:
                XCTFail("Unexpected blocking state")
            }

            let result = fixture.viewModel.submitUserTurn(
                text: "queued behind codex \(blockingState.rawValue)",
                tabID: fixture.tabID
            )

            XCTAssertEqual(result, .submitted, blockingState.rawValue)
            XCTAssertEqual(fixture.session.pendingPiSteeringInstructions.count, 1, blockingState.rawValue)
            try await Task.sleep(nanoseconds: 100_000_000)
            XCTAssertFalse(recordedCommands(at: fixture.recordURL).contains { $0.type == "steer" }, blockingState.rawValue)

            switch blockingState {
            case .approval:
                fixture.viewModel.submitApprovalDecision(tabID: fixture.tabID, decision: .accept)
            case .permissions:
                let request = try XCTUnwrap(fixture.session.pendingPermissionsRequest)
                fixture.viewModel.test_codexCoordinator.submitPermissionsDecision(
                    session: fixture.session,
                    request: request,
                    decision: .accept
                )
            default:
                break
            }

            try await waitUntil("pi steering flushed after codex \(blockingState.rawValue) resolution") {
                self.recordedCommands(at: fixture.recordURL).contains {
                    $0.type == "steer" && $0.message == "queued behind codex \(blockingState.rawValue)"
                }
            }
            XCTAssertTrue(fixture.session.pendingPiSteeringInstructions.isEmpty, blockingState.rawValue)
            XCTAssertEqual(codexController.responseCount(), 1, blockingState.rawValue)
            await fixture.controller.shutdown()
        }
    }

    func testStaleFrontPiSteeringDoesNotBlockCurrentRunSteering() async throws {
        let fixture = try await makeRunningPiSession()
        defer { Task { await fixture.controller.shutdown() } }
        let staleRunID = UUID()
        let staleAttemptID = UUID()
        fixture.session.pendingPiSteeringInstructions.append(
            makePiSteeringInstruction(
                session: fixture.session,
                text: "stale",
                targetRunID: staleRunID,
                targetRunAttemptID: staleAttemptID
            )
        )
        fixture.session.pendingPiSteeringInstructions.append(
            makePiSteeringInstruction(session: fixture.session, text: "current")
        )

        fixture.viewModel.publishRunInteractionStateChange(for: fixture.session, reason: .userInputResponseSubmitted)

        try await waitUntil("current pi steering delivered behind stale front entry") {
            self.recordedCommands(at: fixture.recordURL).contains { $0.type == "steer" && $0.message == "current" }
        }
        let delivered = recordedCommands(at: fixture.recordURL).filter { $0.type == "steer" || $0.type == "follow_up" }
        XCTAssertEqual(delivered.map(\.message), ["current"])
        XCTAssertTrue(fixture.session.pendingPiSteeringInstructions.isEmpty)
    }

    func testPiModelOptionsUseActiveWorkspaceCatalogBeforePiIsSelected() throws {
        AgentPiModelRegistry.shared.test_reset()
        defer { AgentPiModelRegistry.shared.test_reset() }
        let workspaceRoot = try makeTemporaryDirectory().appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceRoot, withIntermediateDirectories: true)
        _ = AgentPiModelRegistry.shared.updateDiscoveredModels(
            Self.piModels(rawValue: "zai/glm-5.2", displayName: "GLM 5.2", thinkingLevels: [.high]),
            workspacePath: workspaceRoot.path
        )
        _ = AgentPiModelRegistry.shared.updateDiscoveredModels(
            Self.piModels(rawValue: "openai-codex/gpt-5.4", displayName: "GPT 5.4", thinkingLevels: [.low]),
            workspacePath: nil
        )
        let viewModel = makeViewModel(testWorkspacePath: workspaceRoot.path)
        viewModel.selectedAgent = .codexExec

        let options = viewModel.modelOptions(for: .pi).map(\.rawValue)

        XCTAssertEqual(options, ["zai/glm-5.2"])
        XCTAssertFalse(options.contains("openai-codex/gpt-5.4"))
        XCTAssertEqual(viewModel.piModelCatalogWorkspacePath(), workspaceRoot.standardizedFileURL.path)
    }

    func testPiModelOptionsUseEffectiveWorktreeWorkspaceForActiveSession() throws {
        AgentPiModelRegistry.shared.test_reset()
        defer { AgentPiModelRegistry.shared.test_reset() }
        let logicalRoot = try makeTemporaryDirectory().appendingPathComponent("logical", isDirectory: true)
        let worktreeRoot = try makeTemporaryDirectory().appendingPathComponent("worktree", isDirectory: true)
        try FileManager.default.createDirectory(at: logicalRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: worktreeRoot, withIntermediateDirectories: true)
        _ = AgentPiModelRegistry.shared.updateDiscoveredModels(
            Self.piModels(rawValue: "openai-codex/gpt-5.4", displayName: "GPT 5.4", thinkingLevels: [.low]),
            workspacePath: logicalRoot.path
        )
        _ = AgentPiModelRegistry.shared.updateDiscoveredModels(
            Self.piModels(rawValue: "deepseek/deepseek-v4-flash", displayName: "DeepSeek V4 Flash", thinkingLevels: [.high]),
            workspacePath: worktreeRoot.path
        )
        let viewModel = makeViewModel(testWorkspacePath: logicalRoot.path)
        let tabID = UUID()
        viewModel.ensureSession(for: tabID)
        viewModel.test_setCurrentTabIDOverride(tabID)
        let session = try XCTUnwrap(viewModel.sessions[tabID])
        session.worktreeBindings = [makeBinding(logicalRoot: logicalRoot, worktreeRoot: worktreeRoot)]
        session.selectedAgent = .pi
        session.selectedModelRaw = "deepseek/deepseek-v4-flash"
        viewModel.selectedAgent = .pi
        viewModel.selectedModelRaw = "deepseek/deepseek-v4-flash"

        let options = viewModel.modelOptions(for: .pi).map(\.rawValue)
        XCTAssertTrue(options.contains("deepseek/deepseek-v4-flash"))
        XCTAssertFalse(options.contains("openai-codex/gpt-5.4"))
        XCTAssertEqual(viewModel.piModelCatalogWorkspacePath(), worktreeRoot.standardizedFileURL.path)
        XCTAssertEqual(viewModel.piThinkingLevelOptionsForCurrentSelection(), [.high])
    }

    func testPiModelPollingStartsForWorkspaceBeforePiIsSelected() async throws {
        let workspacePath = "/tmp/pi-workspace-a"
        let polling = AgentModeFakePiModelPolling()
        let viewModel = makeViewModel(
            testWorkspacePathProvider: { workspacePath },
            piModelPollingService: polling
        )
        viewModel.test_setAgentAvailabilityContextOverride(.init(piAvailable: true))
        viewModel.selectedAgent = .codexExec

        viewModel.test_updateDynamicModelPolling()

        let workspaceA = try XCTUnwrap(AgentPiModelRegistry.canonicalWorkspacePath(workspacePath))
        try await waitUntilAsync("pi model subscription starts for picker workspace before pi selection") {
            await polling.subscriptionWorkspacePaths() == [workspaceA]
        }
        XCTAssertEqual(viewModel.test_piModelsSubscribedWorkspacePath, workspaceA)
    }

    func testPiModelPollingResubscribesWhenWorkspacePathChanges() async throws {
        var workspacePath: String? = "/tmp/pi-workspace-a"
        let polling = AgentModeFakePiModelPolling()
        let viewModel = makeViewModel(
            testWorkspacePathProvider: { workspacePath },
            piModelPollingService: polling
        )
        viewModel.test_setAgentAvailabilityContextOverride(.init(piAvailable: true))
        viewModel.selectedAgent = .codexExec
        viewModel.test_updateDynamicModelPolling()

        let workspaceA = try XCTUnwrap(AgentPiModelRegistry.canonicalWorkspacePath(workspacePath))
        try await waitUntilAsync("initial pi model subscription uses workspace A") {
            await polling.subscriptionWorkspacePaths() == [workspaceA]
        }
        XCTAssertEqual(viewModel.test_piModelsSubscribedWorkspacePath, workspaceA)

        workspacePath = "/tmp/pi-workspace-b"
        let workspaceB = try XCTUnwrap(AgentPiModelRegistry.canonicalWorkspacePath(workspacePath))
        viewModel.test_updateDynamicModelPolling()

        try await waitUntilAsync("pi model subscription resubscribes to workspace B") {
            await polling.subscriptionWorkspacePaths() == [workspaceA, workspaceB]
        }
        XCTAssertEqual(viewModel.test_piModelsSubscribedWorkspacePath, workspaceB)

        viewModel.test_updateDynamicModelPolling()
        try await Task.sleep(nanoseconds: 50_000_000)
        let finalSubscriptionPaths = await polling.subscriptionWorkspacePaths()
        XCTAssertEqual(finalSubscriptionPaths, [workspaceA, workspaceB])
    }

    private func makeRunningPiSession(mcpServer: MCPServerViewModel? = nil) async throws -> PiQueueFixture {
        let directory = try makeTemporaryDirectory()
        let recordURL = directory.appendingPathComponent("commands.jsonl")
        let scriptURL = try makeFakePiControllerScript(recordURL: recordURL)
        let client = PiRPCClient(config: .init(
            commandName: scriptURL.path,
            additionalPathHints: [],
            requestTimeout: 2,
            launchArguments: [],
            environmentOverrides: [:],
            requiresSupportedVersionCheck: false
        ))
        let controller = PiNativeSessionController(client: client)
        _ = try await controller.startOrResume(existing: nil)
        let viewModel = makeViewModel(testWorkspacePath: directory.path, testMCPServer: mcpServer)
        let tabID = UUID()
        viewModel.ensureSession(for: tabID)
        let session = try XCTUnwrap(viewModel.sessions[tabID])
        session.hasLoadedPersistedState = true
        session.hasSentFirstMessage = true
        session.selectedAgent = .pi
        session.runState = .running
        session.runID = UUID()
        session.beginRunAttempt(source: "test")
        session.piController = controller
        return PiQueueFixture(
            viewModel: viewModel,
            tabID: tabID,
            session: session,
            controller: controller,
            recordURL: recordURL
        )
    }

    private func makeViewModel(testWorkspacePath: String, testMCPServer: MCPServerViewModel? = nil) -> AgentModeViewModel {
        makeViewModel(testWorkspacePathProvider: { testWorkspacePath }, testMCPServer: testMCPServer)
    }

    private func makeViewModel(
        testWorkspacePathProvider: @escaping () -> String?,
        piModelPollingService: any PiModelPolling = PiModelPollingService.shared,
        testMCPServer: MCPServerViewModel? = nil
    ) -> AgentModeViewModel {
        let viewModel = AgentModeViewModel(
            testWindowID: 1,
            testWorkspacePathProvider: testWorkspacePathProvider,
            codexControllerFactory: { _, _, _, _, _, _ in
                fatalError("Codex controller should not be requested by pi steering queue tests")
            },
            piModelPollingService: piModelPollingService,
            testMCPServer: testMCPServer
        )
        viewModel.test_setAgentAvailabilityContextOverride(AgentModelCatalog.AvailabilityContext(piAvailable: true))
        return viewModel
    }

    private static func piModels(
        rawValue: String,
        displayName: String,
        thinkingLevels: [PiThinkingLevel]
    ) -> PiDiscoveredModels {
        PiDiscoveredModels(
            options: [
                AgentModelOption(
                    rawValue: rawValue,
                    displayName: displayName,
                    description: nil,
                    isDefault: true,
                    supportedPiThinkingLevels: thinkingLevels
                )
            ],
            currentModelRaw: rawValue
        )
    }

    private func makeMCPWindow() -> WindowState {
        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        let window = WindowState()
        WindowStatesManager.shared.registerWindowState(window)
        GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)
        return window
    }

    private func tearDownMCPWindow(_ window: WindowState) async {
        window.beginClose()
        await window.tearDown()
        WindowStatesManager.shared.unregisterWindowState(window)
    }

    @discardableResult
    private func beginActiveMCPTool(on window: WindowState, runID: UUID) async -> UUID? {
        let connectionID = UUID()
        XCTAssertTrue(window.mcpServer.registerRunIDMapping(connectionID: connectionID, runID: runID, windowID: window.windowID))
        return await window.mcpServer.test_beginResolvedToolExecution(
            metadata: MCPServerViewModel.RequestMetadata(
                connectionID: connectionID,
                clientName: "pi-steering-queue-test",
                windowID: window.windowID
            ),
            resolvedContext: nil,
            toolName: MCPWindowToolName.readFile
        ) {}?.executionID
    }

    private func makeMCPControlContext(sessionID: UUID) -> AgentModeViewModel.AgentMCPControlContext {
        AgentModeViewModel.AgentMCPControlContext(
            sessionID: sessionID,
            activationID: UUID(),
            registration: AgentRunSessionStore.Registration(sessionID: sessionID, generation: 1),
            currentEpoch: nil,
            preparedEpoch: nil,
            pendingEpochTransition: nil,
            originatingConnectionID: nil,
            interactionTransport: .mcp(sessionID: sessionID, originatingConnectionID: nil),
            suppressUserNotifications: true,
            forceAutoEditEnabled: false,
            autoEditEnabledBeforeOverride: false,
            taskLabelKind: nil
        )
    }

    private func makeBinding(logicalRoot: URL, worktreeRoot: URL) -> AgentSessionWorktreeBinding {
        AgentSessionWorktreeBinding(
            id: "bind_test",
            repositoryID: "repo_test",
            repoKey: "repo",
            logicalRootPath: logicalRoot.path,
            logicalRootName: logicalRoot.lastPathComponent,
            worktreeID: "worktree_test",
            worktreeRootPath: worktreeRoot.path,
            worktreeName: worktreeRoot.lastPathComponent,
            branch: "feature/test",
            head: "abcdef",
            visualLabel: "test",
            visualColorHex: "#3366FF",
            boundAt: Date(timeIntervalSinceReferenceDate: 123),
            source: "test"
        )
    }

    private func makePiSteeringInstruction(
        session: AgentModeViewModel.TabSession,
        text: String,
        targetRunID: UUID? = nil,
        targetRunAttemptID: UUID? = nil
    ) -> AgentModeViewModel.TabSession.PiSteeringInstruction {
        AgentModeViewModel.TabSession.PiSteeringInstruction(
            id: UUID(),
            targetRunID: targetRunID ?? session.runID,
            targetRunAttemptID: targetRunAttemptID ?? session.activeRunAttemptID,
            providerText: text,
            attachments: [],
            draftText: text,
            optimisticUserItemID: nil,
            createdAt: Date()
        )
    }

    private func makeAskUserPendingState() -> AgentAskUserPendingState {
        let interaction = AgentAskUserInteraction(
            id: UUID(),
            title: "Question",
            questions: [
                AgentAskUserQuestion(
                    id: "question",
                    question: "Continue?",
                    options: [AgentAskUserOption(label: "Yes")],
                    allowsMultiple: false,
                    allowsCustom: false
                )
            ]
        )
        return AgentAskUserPendingState(
            interaction: interaction,
            draftsByQuestionID: interaction.emptyDrafts(),
            currentQuestionIndex: 0
        )
    }

    private func makeUserInputRequest(id: String) -> AgentRequestUserInputRequest {
        AgentRequestUserInputRequest(
            requestID: .string(id),
            method: "request_user_input",
            threadID: "thread",
            turnID: "turn",
            itemID: id,
            questions: [
                AgentRequestUserInputQuestion(
                    id: "question",
                    header: "Question",
                    question: "Continue?",
                    isOther: false,
                    isSecret: false,
                    options: [AgentRequestUserInputOption(label: "Yes", description: "Continue")]
                )
            ]
        )
    }

    private func makeApprovalRequest(id: String) -> AgentApprovalRequest {
        AgentApprovalRequest(
            requestID: .acp(id),
            method: "approval",
            kind: .commandExecution,
            threadID: "thread",
            turnID: "turn",
            itemID: id,
            command: "echo hi",
            cwd: FileManager.default.currentDirectoryPath
        )
    }

    private func makeCodexApprovalRequest(id: String) -> AgentApprovalRequest {
        AgentApprovalRequest(
            requestID: .codex(.string(id)),
            method: "approval",
            kind: .commandExecution,
            threadID: "thread",
            turnID: "turn",
            itemID: id,
            command: "echo hi",
            cwd: FileManager.default.currentDirectoryPath
        )
    }

    private func makePermissionsRequest(id: String) -> AgentPermissionsRequest {
        AgentPermissionsRequest(
            requestID: .string(id),
            method: "permissions",
            threadID: "thread",
            turnID: "turn",
            itemID: id,
            cwd: FileManager.default.currentDirectoryPath,
            permissionsJSON: "{}"
        )
    }

    private func makeFakePiControllerScript(recordURL: URL) throws -> URL {
        let scriptURL = recordURL.deletingLastPathComponent().appendingPathComponent("fake_pi_queue_rpc.py")
        let recordPath = recordURL.path
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
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

        for line in sys.stdin:
            try:
                request = json.loads(line)
            except Exception:
                continue
            record(request)
            command = request.get("type")
            request_id = request.get("id")
            if command == "steer" and request.get("message") == "fail steer":
                emit({"type": "response", "id": request_id, "command": "steer", "success": False, "error": "synthetic steer failure"})
            elif command == "get_state":
                emit({
                    "type": "response",
                    "id": request_id,
                    "command": "get_state",
                    "success": True,
                    "data": {
                        "sessionId": "pi-session-id",
                        "sessionFile": "/tmp/pi-session.jsonl",
                        "isStreaming": False,
                        "isCompacting": False,
                        "messageCount": 1,
                        "pendingMessageCount": 0,
                        "model": {"provider": "zai", "id": "glm-5.2", "displayName": "GLM 5.2"}
                    }
                })
            else:
                emit({"type": "response", "id": request_id, "command": command, "success": True})
        """#.replacingOccurrences(of: "__RECORD_PATH__", with: recordPath)
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        return scriptURL
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
            return RecordedCommand(type: type, message: object["message"] as? String)
        }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentModePiSteeringQueueTests-")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        temporaryURLs.append(url.deletingLastPathComponent())
        return url
    }

    private func waitUntil(
        _ message: String,
        timeout: TimeInterval = 2,
        condition: @escaping () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for \(message)")
    }

    private func waitUntilAsync(
        _ message: String,
        timeout: TimeInterval = 2,
        condition: @escaping () async -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for \(message)")
    }

    private struct PiQueueFixture {
        let viewModel: AgentModeViewModel
        let tabID: UUID
        let session: AgentModeViewModel.TabSession
        let controller: PiNativeSessionController
        let recordURL: URL
    }

    private struct RecordedCommand {
        let type: String
        let message: String?
    }

    private func install(_ state: PiBlockingState, on session: AgentModeViewModel.TabSession) {
        switch state {
        case .askUser:
            session.pendingAskUser = makeAskUserPendingState()
        case .userInput:
            session.pendingUserInputRequest = makeUserInputRequest(id: state.rawValue)
        case .permissions:
            session.pendingPermissionsRequest = makePermissionsRequest(id: state.rawValue)
        case .approval:
            session.pendingApproval = makeApprovalRequest(id: state.rawValue)
        }
    }

    private func clear(_ state: PiBlockingState, on session: AgentModeViewModel.TabSession) {
        switch state {
        case .askUser:
            session.pendingAskUser = nil
        case .userInput:
            session.pendingUserInputRequest = nil
        case .permissions:
            session.pendingPermissionsRequest = nil
        case .approval:
            session.pendingApproval = nil
        }
        session.runState = .running
    }

    private enum PiBlockingState: String, CaseIterable {
        case askUser
        case userInput
        case permissions
        case approval
    }
}

private final class PiQueueFakeCodexController: CodexSessionControllerTurnDispatchTestDefaults {
    private var serverResponses: [[String: Any]] = []

    var hasActiveThread: Bool {
        true
    }

    var events: AsyncStream<CodexNativeSessionController.Event> {
        AsyncStream { $0.finish() }
    }

    func ensureEventsStreamReady() {}

    func startOrResume(
        existing _: CodexNativeSessionController.SessionRef?,
        baseInstructions _: String
    ) async throws -> CodexNativeSessionController.SessionRef {
        CodexNativeSessionController.SessionRef(conversationID: "pi-queue", rolloutPath: nil, model: nil, reasoningEffort: nil)
    }

    func startOrResume(
        existing _: CodexNativeSessionController.SessionRef?,
        baseInstructions _: String,
        model: String?,
        reasoningEffort: String?
    ) async throws -> CodexNativeSessionController.SessionRef {
        CodexNativeSessionController.SessionRef(conversationID: "pi-queue", rolloutPath: nil, model: model, reasoningEffort: reasoningEffort)
    }

    func startOrResume(
        existing _: CodexNativeSessionController.SessionRef?,
        baseInstructions _: String,
        model: String?,
        reasoningEffort: String?,
        serviceTier _: String?
    ) async throws -> CodexNativeSessionController.SessionRef {
        CodexNativeSessionController.SessionRef(conversationID: "pi-queue", rolloutPath: nil, model: model, reasoningEffort: reasoningEffort)
    }

    func readThreadSnapshot(
        includeTurns _: Bool,
        timeout _: TimeInterval?
    ) async throws -> CodexNativeSessionController.ThreadSnapshot {
        CodexNativeSessionController.ThreadSnapshot(
            conversationID: "pi-queue",
            rolloutPath: nil,
            model: nil,
            reasoningEffort: nil,
            runtimeStatus: .active(activeFlags: []),
            currentTurnID: "turn",
            activeTurnIDs: ["turn"],
            latestTurnStatus: nil
        )
    }

    func setThreadName(_: String, threadID _: String?) async throws {}
    func compactThread() async throws {}
    func getThreadGoal() async throws -> CodexNativeSessionController.ThreadGoal? {
        nil
    }

    func setThreadGoalObjective(_: String) async throws -> CodexNativeSessionController.ThreadGoal {
        throw CancellationError()
    }

    func setThreadGoalStatus(_: CodexNativeSessionController.ThreadGoalStatus) async throws -> CodexNativeSessionController.ThreadGoal {
        throw CancellationError()
    }

    func clearThreadGoal() async throws -> Bool {
        false
    }

    func cancelCurrentTurn() async {}
    func shutdown() async {}

    func respondToServerRequest(id _: CodexAppServerRequestID, result: [String: Any]) async {
        serverResponses.append(result)
    }

    func responseCount() -> Int {
        serverResponses.count
    }
}

private actor AgentModeFakePiModelPolling: PiModelPolling {
    private var workspacePaths: [String?] = []

    func latestSnapshot() async -> PiModelPollingService.Snapshot? {
        nil
    }

    func discoverOnce(workspacePath _: String?) async throws -> PiModelPollingService.Snapshot? {
        nil
    }

    func subscribe(workspacePath: String?) async -> AsyncStream<PiModelPollingService.Event> {
        workspacePaths.append(AgentPiModelRegistry.canonicalWorkspacePath(workspacePath))
        return AsyncStream { _ in }
    }

    func subscriptionWorkspacePaths() -> [String?] {
        workspacePaths
    }
}
