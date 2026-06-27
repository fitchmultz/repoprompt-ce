@testable import RepoPrompt
import XCTest

final class PiRunEventReducerTests: XCTestCase {
    func testPendingMessageGateDoesNotSuppressTerminalStateForStalePendingCount() {
        var gate = PiRunCompletionGate()
        gate.recordSessionState(sessionState(pendingMessageCount: 2))

        XCTAssertEqual(gate.latestPendingMessageCount, 2)
        XCTAssertEqual(gate.terminalState(for: .completed), .completed)
        XCTAssertEqual(gate.latestPendingMessageCount, 2)
    }

    func testPendingMessageGateDoesNotDeferFailedOrCancelledTerminalStates() {
        var failedGate = PiRunCompletionGate()
        failedGate.recordSessionState(sessionState(pendingMessageCount: 2))
        XCTAssertEqual(failedGate.terminalState(for: .failed), .failed)

        var cancelledGate = PiRunCompletionGate()
        cancelledGate.recordSessionState(sessionState(pendingMessageCount: 2))
        XCTAssertEqual(cancelledGate.terminalState(for: .cancelled), .cancelled)
    }

    func testDiagnosticPresentationIncludesKindEventTypeAndMessage() {
        let text = PiRunDiagnosticPresentation.statusText(from: .init(
            kind: .unknownEventType,
            eventType: "future_event",
            message: "Unknown pi event type.",
            payloadPreview: nil,
            occurrence: 1
        ))

        XCTAssertEqual(text, "pi diagnostic: unknownEventType • future_event • Unknown pi event type.")
    }

    func testFirstProviderEventWatchdogCountsOnlyPostPromptBlockingOrTerminalEvents() {
        XCTAssertFalse(PiFirstProviderEventWatchdog.countsAsPostPromptProviderEvent(.sessionState(sessionState())))
        XCTAssertFalse(PiFirstProviderEventWatchdog.countsAsPostPromptProviderEvent(.diagnostic(.init(
            kind: .unknownEventType,
            eventType: "future_event",
            message: "Unknown pi event type.",
            payloadPreview: nil,
            occurrence: 1
        ))))
        XCTAssertFalse(PiFirstProviderEventWatchdog.countsAsPostPromptProviderEvent(.extensionUIRequest(.init(
            id: "status-1",
            method: "setStatus",
            title: nil,
            message: nil,
            statusKey: "example",
            statusText: "ready",
            raw: [:]
        ))))
        XCTAssertTrue(PiFirstProviderEventWatchdog.countsAsPostPromptProviderEvent(.extensionUIRequest(.init(
            id: "select-1",
            method: "select",
            title: nil,
            message: nil,
            statusKey: nil,
            statusText: nil,
            raw: [:]
        ))))
        XCTAssertTrue(PiFirstProviderEventWatchdog.countsAsPostPromptProviderEvent(.stream(AIStreamResult(type: "content", text: "ok"))))
        XCTAssertTrue(PiFirstProviderEventWatchdog.countsAsPostPromptProviderEvent(.turnCompleted(turnID: UUID(), status: .completed)))
        XCTAssertTrue(PiFirstProviderEventWatchdog.countsAsPostPromptProviderEvent(.error("failed")))
    }

    func testFirstProviderEventWatchdogFiresOnlyBeforeProviderEventAndTerminalCommit() {
        XCTAssertTrue(PiFirstProviderEventWatchdog.shouldFire(
            didReceivePostPromptProviderEvent: false,
            didCommitTerminal: false,
            isCurrentRunAttempt: true
        ))
        XCTAssertFalse(PiFirstProviderEventWatchdog.shouldFire(
            didReceivePostPromptProviderEvent: true,
            didCommitTerminal: false,
            isCurrentRunAttempt: true
        ))
        XCTAssertFalse(PiFirstProviderEventWatchdog.shouldFire(
            didReceivePostPromptProviderEvent: false,
            didCommitTerminal: true,
            isCurrentRunAttempt: true
        ))
        XCTAssertFalse(PiFirstProviderEventWatchdog.shouldFire(
            didReceivePostPromptProviderEvent: false,
            didCommitTerminal: false,
            isCurrentRunAttempt: false
        ))
        XCTAssertEqual(PiFirstProviderEventWatchdog.source, "pi.firstProviderEventTimeout")
        XCTAssertEqual(
            PiFirstProviderEventWatchdog.errorText,
            "pi did not produce any response events within 60 seconds after the prompt was sent."
        )
    }

    @MainActor
    func testSessionStateMapperPersistsProviderModelThinkingAndSessionIdentity() {
        let session = AgentModeViewModel.TabSession(tabID: UUID())
        session.selectedModelRaw = AgentModel.defaultModel.rawValue
        session.selectedReasoningEffortRaw = nil
        session.isDirty = false

        PiRunSessionStateMapper.applySessionState(sessionState(
            sessionID: "pi-session-updated",
            sessionFile: "/tmp/pi-session-updated.jsonl",
            thinkingLevel: "high",
            model: .init(
                provider: "zai",
                id: "glm-5.2",
                displayName: "GLM 5.2",
                description: nil,
                raw: [:]
            )
        ), to: session)

        XCTAssertEqual(session.providerSessionID, "pi-session-updated")
        XCTAssertEqual(session.piSessionFile, "/tmp/pi-session-updated.jsonl")
        XCTAssertEqual(session.selectedModelRaw, "zai/glm-5.2")
        XCTAssertEqual(session.selectedReasoningEffortRaw, "high")
        XCTAssertTrue(session.isDirty)
    }

    @MainActor
    func testSessionRefMapperIgnoresEmptyModelButPersistsThinkingAndIdentity() {
        let session = AgentModeViewModel.TabSession(tabID: UUID())
        session.selectedModelRaw = "existing/model"
        session.selectedReasoningEffortRaw = nil
        session.isDirty = false

        PiRunSessionStateMapper.applySessionRef(.init(
            sessionID: "pi-session",
            sessionFile: "/tmp/pi-session.jsonl",
            model: "   ",
            thinkingLevel: "medium"
        ), to: session)

        XCTAssertEqual(session.providerSessionID, "pi-session")
        XCTAssertEqual(session.piSessionFile, "/tmp/pi-session.jsonl")
        XCTAssertEqual(session.selectedModelRaw, "existing/model")
        XCTAssertEqual(session.selectedReasoningEffortRaw, "medium")
        XCTAssertTrue(session.isDirty)
    }

    private func sessionState(
        sessionID: String = "pi-session",
        sessionFile: String? = "/tmp/pi-session.jsonl",
        thinkingLevel: String? = nil,
        pendingMessageCount: Int? = 0,
        model: PiRPCClient.RemoteModel? = nil
    ) -> PiRPCClient.SessionState {
        PiRPCClient.SessionState(
            sessionID: sessionID,
            sessionFile: sessionFile,
            sessionName: nil,
            thinkingLevel: thinkingLevel,
            isStreaming: false,
            isCompacting: false,
            messageCount: nil,
            pendingMessageCount: pendingMessageCount,
            model: model
        )
    }
}
