import Foundation
import XCTest
@_spi(TestSupport) @testable import RepoPrompt

@MainActor
final class PiReasoningTranscriptTests: XCTestCase {
    func testPiReasoningDeltasBecomePersistedThinkingItems() async {
        let viewModel = AgentModeViewModel(
            codexControllerFactory: { _, _, _, _, _, _ in PiReasoningNoopCodexController() }
        )
        let tabID = UUID()
        let session = await viewModel.ensureSessionReady(tabID: tabID)
        let runID = UUID()
        let runAttemptID = UUID()
        session.selectedAgent = .pi
        session.runID = runID
        session.beginRunAttempt(source: "test.piReasoning", attemptID: runAttemptID)

        await viewModel.test_handleStreamResult(
            AIStreamResult(type: "content", text: nil, reasoning: "thinking "),
            session: session,
            runID: runID,
            runAttemptID: runAttemptID
        )
        await viewModel.test_handleStreamResult(
            AIStreamResult(type: "content", text: nil, reasoning: "through it"),
            session: session,
            runID: runID,
            runAttemptID: runAttemptID
        )

        XCTAssertEqual(session.items.map(\.kind), [.thinking])
        XCTAssertEqual(session.items.first?.text, "thinking through it")
        XCTAssertEqual(session.items.first?.isStreaming, true)

        await viewModel.test_handleStreamResult(
            AIStreamResult(type: "content", text: "final answer"),
            session: session,
            runID: runID,
            runAttemptID: runAttemptID
        )
        await viewModel.test_handleStreamResult(
            AIStreamResult(type: "message_stop", text: nil),
            session: session,
            runID: runID,
            runAttemptID: runAttemptID
        )

        XCTAssertEqual(session.items.map(\.kind), [.thinking, .assistant])
        XCTAssertEqual(session.items[0].text, "thinking through it")
        XCTAssertEqual(session.items[0].isStreaming, false)
        XCTAssertEqual(session.items[1].text, "final answer")
        XCTAssertEqual(session.items[1].isStreaming, false)
    }
}

private final class PiReasoningNoopCodexController: CodexSessionControlling {
    var hasActiveThread: Bool {
        false
    }

    var events: AsyncStream<CodexNativeSessionController.Event> {
        AsyncStream { continuation in continuation.finish() }
    }

    func ensureEventsStreamReady() {}

    func startOrResume(existing _: CodexNativeSessionController.SessionRef?, baseInstructions _: String) async throws -> CodexNativeSessionController.SessionRef {
        CodexNativeSessionController.SessionRef(conversationID: "fake", rolloutPath: nil, model: nil, reasoningEffort: nil)
    }

    func startOrResume(
        existing _: CodexNativeSessionController.SessionRef?,
        baseInstructions _: String,
        model: String?,
        reasoningEffort: String?
    ) async throws -> CodexNativeSessionController.SessionRef {
        CodexNativeSessionController.SessionRef(conversationID: "fake", rolloutPath: nil, model: model, reasoningEffort: reasoningEffort)
    }

    func startOrResume(
        existing _: CodexNativeSessionController.SessionRef?,
        baseInstructions _: String,
        model: String?,
        reasoningEffort: String?,
        serviceTier _: String?
    ) async throws -> CodexNativeSessionController.SessionRef {
        CodexNativeSessionController.SessionRef(conversationID: "fake", rolloutPath: nil, model: model, reasoningEffort: reasoningEffort)
    }

    func readThreadSnapshot(includeTurns _: Bool, timeout _: TimeInterval?) async throws -> CodexNativeSessionController.ThreadSnapshot {
        CodexNativeSessionController.ThreadSnapshot(
            conversationID: "fake",
            rolloutPath: nil,
            model: nil,
            reasoningEffort: nil,
            runtimeStatus: .idle,
            currentTurnID: nil,
            activeTurnIDs: [],
            latestTurnStatus: nil
        )
    }

    func setThreadName(_: String, threadID _: String?) async throws {}

    func startUserTurn(
        text _: String,
        images _: [AgentImageAttachment],
        model _: String?,
        reasoningEffort _: String?,
        serviceTier _: String?
    ) async throws -> CodexTurnStartReceipt {
        CodexTurnStartReceipt(provisionalSubmissionID: "fake-turn")
    }

    func steerUserTurn(
        text _: String,
        images _: [AgentImageAttachment],
        expectedTurnID: String
    ) async throws -> CodexTurnSteerReceipt {
        CodexTurnSteerReceipt(acceptedTurnID: expectedTurnID)
    }

    func prepareLifecycleAuthorityReconciliationAfterAcceptedMismatch(
        expectedCurrentTurnID _: String,
        acceptedDispatchTurnID _: String
    ) async -> Bool {
        false
    }

    func interruptUserTurn(expectedTurnID: String) async throws -> CodexTurnInterruptReceipt {
        CodexTurnInterruptReceipt(interruptedTurnID: expectedTurnID)
    }

    func reconcileAndInterruptCurrentTurn() async throws -> CodexTurnInterruptReceipt {
        CodexTurnInterruptReceipt(interruptedTurnID: "fake-turn")
    }

    func sendUserMessage(_: String) async throws {}
    func sendUserTurn(text _: String, images _: [AgentImageAttachment]) async throws {}
    func sendUserTurn(text _: String, images _: [AgentImageAttachment], model _: String?, reasoningEffort _: String?) async throws {}
    func sendUserTurn(text _: String, images _: [AgentImageAttachment], model _: String?, reasoningEffort _: String?, serviceTier _: String?) async throws {}
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
    func respondToServerRequest(id _: CodexAppServerRequestID, result _: [String: Any]) async {}
}
