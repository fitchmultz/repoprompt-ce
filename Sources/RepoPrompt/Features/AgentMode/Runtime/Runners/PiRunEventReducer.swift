import Foundation

struct PiRunCompletionGate: Equatable {
    private(set) var latestPendingMessageCount = 0

    mutating func recordSessionState(_ state: PiRPCClient.SessionState) {
        latestPendingMessageCount = state.pendingMessageCount ?? 0
    }

    func terminalState(for status: PiNativeSessionController.TurnStatus) -> AgentSessionRunState? {
        switch status {
        case .completed: .completed
        case .cancelled: .cancelled
        case .failed: .failed
        }
    }
}

enum PiRunDiagnosticPresentation {
    static func statusText(from diagnostic: PiRPCClient.ProtocolDiagnostic) -> String {
        var parts = ["pi diagnostic: \(diagnostic.kind.rawValue)"]
        if let eventType = diagnostic.eventType?.trimmingCharacters(in: .whitespacesAndNewlines), !eventType.isEmpty {
            parts.append(eventType)
        }
        let message = diagnostic.message.trimmingCharacters(in: .whitespacesAndNewlines)
        if !message.isEmpty {
            parts.append(message)
        }
        return parts.joined(separator: " • ")
    }
}

enum PiFirstProviderEventWatchdog {
    static let timeoutNanoseconds: UInt64 = 60 * 1_000_000_000
    static let source = "pi.firstProviderEventTimeout"
    static let errorText = "pi accepted the prompt but did not produce any response events within 60 seconds."

    static func countsAsPostPromptProviderEvent(_ event: PiNativeSessionController.Event) -> Bool {
        switch event {
        case .stream, .turnCompleted, .error:
            true
        case let .extensionUIRequest(request):
            request.requiresResponse
        case .sessionState, .diagnostic:
            false
        }
    }

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
