import Foundation
import MCP

@MainActor
enum AgentRunMCPLifecycleSignals {
    struct RunProgress: Equatable {
        let statusText: String?
        let lastToolName: String?
        let toolCallCount: Int
        let turnElapsedSeconds: Double?

        func asObject() -> [String: Value] {
            var object: [String: Value] = [
                "tool_call_count": .int(toolCallCount)
            ]
            if let statusText, !statusText.isEmpty {
                object["status_text"] = .string(statusText)
            }
            if let lastToolName, !lastToolName.isEmpty {
                object["last_tool_name"] = .string(lastToolName)
            }
            if let turnElapsedSeconds {
                object["turn_elapsed_seconds"] = .double(turnElapsedSeconds)
            }
            return object
        }
    }

    enum TerminalCompletionReason: String, Equatable {
        case completed
        case stoppedLength = "stopped_length"
        case awaitingInput = "awaiting_input"
        case error
        case cancelled
        case incomplete

        var displayLabel: String {
            switch self {
            case .completed:
                "Completed"
            case .stoppedLength:
                "Stopped (length/turn limit)"
            case .awaitingInput:
                "Awaiting input"
            case .error:
                "Error"
            case .cancelled:
                "Cancelled"
            case .incomplete:
                "Incomplete (may have been cut off)"
            }
        }
    }

    struct CompletionSignals: Equatable {
        let mayBeIncomplete: Bool
        let hasInFlightToolWork: Bool
        let warnings: [String]

        func asObject() -> [String: Value] {
            var object: [String: Value] = [
                "may_be_incomplete": .bool(mayBeIncomplete),
                "has_in_flight_tool_work": .bool(hasInFlightToolWork)
            ]
            if !warnings.isEmpty {
                object["warnings"] = .array(warnings.map { .string($0) })
            }
            return object
        }
    }

    static func runProgress(for session: AgentModeViewModel.TabSession, status: AgentRunMCPSnapshot.Status) -> RunProgress? {
        guard !status.isTerminal else { return nil }
        let toolCalls = session.items.filter { $0.kind == .toolCall }
        let lastToolName = toolCalls.last?.toolName
        let turnElapsedSeconds: Double? = {
            guard let lastTurn = session.transcript.turns.last, !lastTurn.isCompleted else { return nil }
            return Date().timeIntervalSince(lastTurn.startedAt)
        }()
        let statusText = session.runningStatusText?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedStatusText = (statusText?.isEmpty == false) ? statusText : nil
        return RunProgress(
            statusText: normalizedStatusText,
            lastToolName: lastToolName,
            toolCallCount: toolCalls.count,
            turnElapsedSeconds: turnElapsedSeconds
        )
    }

    static func terminalCompletionReason(
        status: AgentRunMCPSnapshot.Status,
        session: AgentModeViewModel.TabSession
    ) -> TerminalCompletionReason? {
        switch status {
        case .running, .expired:
            return nil
        case .waitingForInput:
            return .awaitingInput
        case .failed:
            return .error
        case .cancelled:
            return .cancelled
        case .completed:
            let signals = completionSignals(status: status, session: session)
            if signals.hasInFlightToolWork || signals.mayBeIncomplete {
                return .incomplete
            }
            return .completed
        }
    }

    static func completionSignals(
        status: AgentRunMCPSnapshot.Status,
        session: AgentModeViewModel.TabSession
    ) -> CompletionSignals {
        let inFlight = hasInFlightToolWork(in: session.items)
        var warnings: [String] = []
        var mayBeIncomplete = false

        if status == .completed {
            if inFlight {
                mayBeIncomplete = true
                warnings.append("One or more tool calls have no matching result yet.")
            }
            if let lastTurn = session.transcript.turns.last,
               !lastTurn.isCompleted,
               session.runState == .completed || session.runState == .idle
            {
                mayBeIncomplete = true
                warnings.append("The latest turn did not reach a natural completion boundary.")
            }
            if session.mcpFollowUpRunPending || !session.pendingInstructions.isEmpty {
                mayBeIncomplete = true
                warnings.append("Follow-up work is still queued for this session.")
            }
            if session.items.contains(where: \.isStreaming) {
                mayBeIncomplete = true
                warnings.append("Assistant output is still streaming.")
            }
        }

        return CompletionSignals(
            mayBeIncomplete: mayBeIncomplete,
            hasInFlightToolWork: inFlight,
            warnings: warnings
        )
    }

    static func hasInFlightToolWork(in items: [AgentChatItem]) -> Bool {
        var pendingInvocationIDs = Set<UUID>()
        for item in items {
            switch item.kind {
            case .toolCall:
                if let invocationID = item.toolInvocationID {
                    pendingInvocationIDs.insert(invocationID)
                }
            case .toolResult:
                if let invocationID = item.toolInvocationID {
                    pendingInvocationIDs.remove(invocationID)
                }
            default:
                break
            }
        }
        return !pendingInvocationIDs.isEmpty
    }

    static func resolvedStatusText(
        session: AgentModeViewModel.TabSession,
        status: AgentRunMCPSnapshot.Status,
        existing: String?
    ) -> String? {
        if let existing, !existing.isEmpty {
            return existing
        }
        if status == .running || status == .waitingForInput {
            let progressText = session.runningStatusText?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let progressText, !progressText.isEmpty {
                return progressText
            }
        }
        return nil
    }
}
