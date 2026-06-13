import Foundation

extension PiRPCClient.Event {
    var protocolType: String {
        switch self {
        case .agentStart: "agent_start"
        case .agentEnd: "agent_end"
        case .turnStart: "turn_start"
        case .turnEnd: "turn_end"
        case .messageStart: "message_start"
        case .messageUpdate: "message_update"
        case .messageEnd: "message_end"
        case .toolExecutionStart: "tool_execution_start"
        case .toolExecutionUpdate: "tool_execution_update"
        case .toolExecutionEnd: "tool_execution_end"
        case .queueUpdate: "queue_update"
        case .compactionStart: "compaction_start"
        case .compactionEnd: "compaction_end"
        case .autoRetryStart: "auto_retry_start"
        case .autoRetryEnd: "auto_retry_end"
        case .sessionInfoChanged: "session_info_changed"
        case .thinkingLevelChanged: "thinking_level_changed"
        case .extensionUIRequest: "extension_ui_request"
        case .extensionError: "extension_error"
        case .customMessage: "custom_message"
        case .transportClosed: "transport_closed"
        case .protocolDiagnostic: "protocol_diagnostic"
        case let .unhandled(type, _): type
        }
    }

    var defersPendingMessageStopRecovery: Bool {
        switch self {
        case .agentStart,
             .agentEnd,
             .turnStart,
             .messageStart,
             .messageUpdate,
             .messageEnd,
             .toolExecutionStart,
             .toolExecutionUpdate,
             .toolExecutionEnd,
             .queueUpdate,
             .compactionStart,
             .compactionEnd,
             .autoRetryStart,
             .autoRetryEnd,
             .extensionUIRequest,
             .extensionError,
             .customMessage,
             .unhandled:
            true
        case .turnEnd,
             .sessionInfoChanged,
             .thinkingLevelChanged,
             .transportClosed,
             .protocolDiagnostic:
            false
        }
    }

    var isLifecycleOrActivityEvent: Bool {
        switch self {
        case .agentStart,
             .agentEnd,
             .turnStart,
             .turnEnd,
             .messageStart,
             .messageUpdate,
             .messageEnd,
             .toolExecutionStart,
             .toolExecutionUpdate,
             .toolExecutionEnd,
             .queueUpdate,
             .compactionStart,
             .compactionEnd,
             .autoRetryStart,
             .autoRetryEnd,
             .extensionUIRequest,
             .extensionError,
             .customMessage,
             .transportClosed,
             .sessionInfoChanged,
             .thinkingLevelChanged,
             .unhandled:
            true
        case .protocolDiagnostic:
            false
        }
    }
}
