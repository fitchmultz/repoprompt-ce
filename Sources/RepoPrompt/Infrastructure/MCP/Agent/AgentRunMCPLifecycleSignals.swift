import Foundation
import MCP

@MainActor
enum AgentRunMCPLifecycleSignals {
    struct RunProgress: Equatable {
        let statusText: String?
        let lastToolName: String?
        let toolCallCount: Int
        let turnElapsedSeconds: Double?
        let lastActivityElapsedSeconds: Double?

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
            if let lastActivityElapsedSeconds {
                object["last_activity_elapsed_seconds"] = .double(lastActivityElapsedSeconds)
            }
            return object
        }
    }

    enum TerminalCompletionReason: String, Equatable {
        case completed
        case awaitingInput = "awaiting_input"
        case error
        case cancelled
        case incomplete
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
        let activities = transcriptActivities(in: session)
        let toolCalls = toolCallActivities(in: activities)
        let lastToolName = toolCalls.last?.toolExecution?.toolName
        let now = Date()
        let turnElapsedSeconds: Double? = {
            guard let lastTurn = session.transcript.turns.last, !lastTurn.isCompleted else { return nil }
            return now.timeIntervalSince(lastTurn.startedAt)
        }()
        let lastActivityElapsedSeconds = activities.map(\.timestamp).max().map { now.timeIntervalSince($0) }
        let statusText = session.runningStatusText?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedStatusText = (statusText?.isEmpty == false) ? statusText : nil
        return RunProgress(
            statusText: normalizedStatusText,
            lastToolName: lastToolName,
            toolCallCount: toolCalls.count,
            turnElapsedSeconds: turnElapsedSeconds,
            lastActivityElapsedSeconds: lastActivityElapsedSeconds
        )
    }

    static func terminalCompletionReason(
        status: AgentRunMCPSnapshot.Status,
        signals: CompletionSignals?
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
            guard let signals else { return .completed }
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
        let inFlight = hasInFlightToolWork(in: session.transcript)
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
            if transcriptHasStreamingAssistant(in: session.transcript) {
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

    static func hasInFlightToolWork(in transcript: AgentTranscript) -> Bool {
        var pendingInvocationIDs = Set<UUID>()
        for turn in transcript.turns {
            for activity in turn.allActivities {
                switch activity.itemKind {
                case .toolCall:
                    if let invocationID = activity.toolExecution?.invocationID {
                        pendingInvocationIDs.insert(invocationID)
                    }
                case .toolResult:
                    if let invocationID = activity.toolExecution?.invocationID {
                        pendingInvocationIDs.remove(invocationID)
                    }
                default:
                    break
                }
            }
        }
        if !pendingInvocationIDs.isEmpty {
            return true
        }
        return false
    }

    private static func transcriptActivities(in session: AgentModeViewModel.TabSession) -> [AgentTranscriptActivity] {
        session.transcript.turns.flatMap(\.allActivities)
    }

    private static func toolCallActivities(in activities: [AgentTranscriptActivity]) -> [AgentTranscriptActivity] {
        activities.filter { $0.itemKind == .toolCall }
    }

    private static func transcriptHasStreamingAssistant(in transcript: AgentTranscript) -> Bool {
        for turn in transcript.turns {
            for activity in turn.allActivities where activity.isStreaming {
                switch activity.itemKind {
                case .assistant, .assistantInline:
                    return true
                default:
                    continue
                }
            }
        }
        return false
    }
}
