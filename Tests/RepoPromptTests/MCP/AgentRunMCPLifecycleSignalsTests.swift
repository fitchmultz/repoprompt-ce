@testable import RepoPrompt
import XCTest

@MainActor
final class AgentRunMCPLifecycleSignalsTests: XCTestCase {
    func testHasInFlightToolWorkDetectsUnresolvedInvocation() {
        let invocationID = UUID()
        let items: [AgentChatItem] = [
            AgentChatItem(kind: .toolCall, text: "", toolName: "bash", toolInvocationID: invocationID)
        ]
        let transcript = AgentTranscriptIO.importLegacyItems(items)
        XCTAssertTrue(AgentRunMCPLifecycleSignals.hasInFlightToolWork(in: transcript))
    }

    func testHasInFlightToolWorkClearsAfterMatchingResult() {
        let invocationID = UUID()
        let items: [AgentChatItem] = [
            AgentChatItem(kind: .toolCall, text: "", toolName: "bash", toolInvocationID: invocationID),
            AgentChatItem(kind: .toolResult, text: "ok", toolName: "bash", toolInvocationID: invocationID)
        ]
        let transcript = AgentTranscriptIO.importLegacyItems(items)
        XCTAssertFalse(AgentRunMCPLifecycleSignals.hasInFlightToolWork(in: transcript))
    }

    func testCompletionSignalsFlagsIncompleteCompletedRunWithOpenTool() {
        let invocationID = UUID()
        var session = AgentModeViewModel.TabSession(tabID: UUID())
        session.transcript = AgentTranscriptIO.importLegacyItems([
            AgentChatItem(kind: .toolCall, text: "", toolName: "edit", toolInvocationID: invocationID)
        ])
        session.runState = .completed

        let signals = AgentRunMCPLifecycleSignals.completionSignals(status: .completed, session: session)
        XCTAssertTrue(signals.mayBeIncomplete)
        XCTAssertTrue(signals.hasInFlightToolWork)
        XCTAssertEqual(
            AgentRunMCPLifecycleSignals.terminalCompletionReason(status: .completed, signals: signals),
            .incomplete
        )
    }

    func testRunProgressIncludesStatusTextAndToolMetadata() {
        var session = AgentModeViewModel.TabSession(tabID: UUID())
        session.runningStatusText = "Editing agent_runtime.rs"
        session.transcript = AgentTranscriptIO.importLegacyItems(
            [AgentChatItem(kind: .toolCall, text: "", toolName: "edit", toolInvocationID: UUID())],
            terminalState: .running
        )

        let progress = AgentRunMCPLifecycleSignals.runProgress(for: session, status: .running)
        XCTAssertEqual(progress?.statusText, "Editing agent_runtime.rs")
        XCTAssertEqual(progress?.lastToolName, "edit")
        XCTAssertEqual(progress?.toolCallCount, 1)
        XCTAssertNotNil(progress?.turnElapsedSeconds)
    }

    func testSnapshotObjectIncludesRoleProgressAndTerminalReason() {
        let snapshot = AgentRunMCPSnapshot(
            sessionID: UUID(),
            tabID: UUID(),
            sessionName: "pair slice",
            agentRaw: "pi",
            agentDisplayName: "pi",
            modelRaw: "openai-codex/gpt-5.5",
            reasoningEffortRaw: nil,
            status: .completed,
            statusText: nil,
            latestAssistantPreview: "Done.",
            interaction: nil,
            transcriptItemCount: 3,
            updatedAt: Date(),
            parentSessionID: nil,
            failureReason: nil,
            taskLabelRaw: "pair",
            runProgress: nil,
            terminalCompletionReason: .incomplete,
            completionSignals: .init(
                mayBeIncomplete: true,
                hasInFlightToolWork: true,
                warnings: ["One or more tool calls have no matching result yet."]
            ),
            worktreeBindings: [],
            activeWorktreeMerges: []
        )

        let object = snapshot.asObject()
        XCTAssertEqual(object["role"]?.stringValue, "pair")
        XCTAssertEqual(object["terminal_completion_reason"]?.stringValue, "incomplete")
        XCTAssertEqual(object["completion_signals"]?.objectValue?["may_be_incomplete"]?.boolValue, true)
        XCTAssertEqual(object["agent"]?.objectValue?["role"]?.stringValue, "pair")
        XCTAssertEqual(object["agent"]?.objectValue?["harness"]?.stringValue, "pi")
    }

    func testBuildTailAssistantOnlyLogXMLReturnsLatestAssistant() {
        let items: [AgentChatItem] = [
            .assistant("intermediate note", sequenceIndex: 0),
            .assistant("Final report with commit SHA abc123", sequenceIndex: 1)
        ]
        let transcript = AgentTranscriptIO.importLegacyItems(items)
        let xml = AgentTranscriptIO.buildTailAssistantOnlyLogXML(from: transcript)
        XCTAssertTrue(xml.contains("Final report with commit SHA abc123"))
        XCTAssertFalse(xml.contains("intermediate note"))
        XCTAssertFalse(xml.contains("tool_call"))
    }
}
