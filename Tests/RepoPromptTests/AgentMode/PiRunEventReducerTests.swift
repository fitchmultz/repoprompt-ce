@testable import RepoPrompt
import XCTest

final class PiRunEventReducerTests: XCTestCase {
    func testPendingMessageGateDefersCompletedTerminalStateUntilPendingQueueDrains() {
        var gate = PiRunCompletionGate()
        gate.recordSessionState(sessionState(pendingMessageCount: 2))

        XCTAssertNil(gate.terminalState(for: .completed))
        XCTAssertEqual(gate.latestPendingMessageCount, 1)
        XCTAssertNil(gate.terminalState(for: .completed))
        XCTAssertEqual(gate.latestPendingMessageCount, 0)
        XCTAssertEqual(gate.terminalState(for: .completed), .completed)
    }

    func testPendingMessageGateDoesNotDeferFailedOrCancelledTerminalStates() {
        var failedGate = PiRunCompletionGate()
        failedGate.recordSessionState(sessionState(pendingMessageCount: 2))
        XCTAssertEqual(failedGate.terminalState(for: .failed), .failed)

        var cancelledGate = PiRunCompletionGate()
        cancelledGate.recordSessionState(sessionState(pendingMessageCount: 2))
        XCTAssertEqual(cancelledGate.terminalState(for: .cancelled), .cancelled)
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
            "pi accepted the prompt but did not produce any response events within 60 seconds."
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
                id: "glm-5.1",
                displayName: "GLM 5.1",
                description: nil,
                raw: [:]
            )
        ), to: session)

        XCTAssertEqual(session.providerSessionID, "pi-session-updated")
        XCTAssertEqual(session.piSessionFile, "/tmp/pi-session-updated.jsonl")
        XCTAssertEqual(session.selectedModelRaw, "zai/glm-5.1")
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
