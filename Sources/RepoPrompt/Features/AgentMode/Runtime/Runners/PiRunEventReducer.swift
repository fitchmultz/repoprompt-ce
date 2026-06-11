import Foundation

struct PiRunCompletionGate: Equatable {
    private(set) var latestPendingMessageCount = 0

    mutating func recordSessionState(_ state: PiRPCClient.SessionState) {
        latestPendingMessageCount = state.pendingMessageCount ?? 0
    }

    mutating func terminalState(for status: PiNativeSessionController.TurnStatus) -> AgentSessionRunState? {
        if status == .completed, latestPendingMessageCount > 0 {
            latestPendingMessageCount -= 1
            return nil
        }
        return switch status {
        case .completed: .completed
        case .cancelled: .cancelled
        case .failed: .failed
        }
    }
}

enum PiFirstProviderEventWatchdog {
    static let timeoutNanoseconds: UInt64 = 60 * 1_000_000_000
    static let source = "pi.firstProviderEventTimeout"
    static let errorText = "pi accepted the prompt but did not produce any response events within 60 seconds."

    static func shouldFire(
        didReceivePostPromptProviderEvent: Bool,
        didCommitTerminal: Bool,
        isCurrentRunAttempt: Bool
    ) -> Bool {
        !didReceivePostPromptProviderEvent && !didCommitTerminal && isCurrentRunAttempt
    }
}

@MainActor
enum PiRunSessionStateMapper {
    static func applySessionState(
        _ state: PiRPCClient.SessionState,
        to session: AgentModeViewModel.TabSession
    ) {
        session.providerSessionID = state.sessionID
        session.piSessionFile = state.sessionFile
        if let modelRaw = modelRaw(from: state) {
            session.selectedModelRaw = modelRaw
        }
        session.selectedReasoningEffortRaw = state.thinkingLevel
        session.isDirty = true
    }

    static func applySessionRef(
        _ ref: PiNativeSessionController.SessionRef,
        to session: AgentModeViewModel.TabSession
    ) {
        session.providerSessionID = ref.sessionID
        session.piSessionFile = ref.sessionFile
        if let modelRaw = ref.model?.trimmingCharacters(in: .whitespacesAndNewlines), !modelRaw.isEmpty {
            session.selectedModelRaw = modelRaw
        }
        session.selectedReasoningEffortRaw = ref.thinkingLevel
        session.isDirty = true
    }

    static func modelRaw(from state: PiRPCClient.SessionState) -> String? {
        state.model.flatMap(AgentPiModelRegistry.rawModel)
    }
}
