import Darwin
import Foundation

extension PiRPCClient {
    struct Config: Equatable {
        var commandName: String
        var additionalPathHints: [String]
        var enableDebugLogging: Bool
        var requestTimeout: TimeInterval?
        var promptRequestTimeout: TimeInterval?
        var workingDirectory: String?
        var launchArguments: [String]
        var environmentOverrides: [String: String]
        var requiresSupportedVersionCheck: Bool

        init(
            commandName: String = CLILaunchProfiles.pi.commandName,
            additionalPathHints: [String] = CLILaunchProfiles.pi.supplementalSearchPaths,
            enableDebugLogging: Bool = false,
            requestTimeout: TimeInterval? = 30,
            promptRequestTimeout: TimeInterval? = 300,
            workingDirectory: String? = nil,
            launchArguments: [String] = PiIntegrationConfiguration.managedRPCLaunchArguments(launchPolicy: .defaultPolicy),
            environmentOverrides: [String: String] = PiIntegrationConfiguration.managedRunEnvironment(),
            requiresSupportedVersionCheck: Bool = true
        ) {
            self.commandName = commandName
            self.additionalPathHints = additionalPathHints
            self.enableDebugLogging = enableDebugLogging
            self.requestTimeout = requestTimeout
            self.promptRequestTimeout = promptRequestTimeout
            self.workingDirectory = workingDirectory
            self.launchArguments = launchArguments
            self.environmentOverrides = environmentOverrides
            self.requiresSupportedVersionCheck = requiresSupportedVersionCheck
        }
    }

    struct SessionState: Equatable {
        var sessionID: String
        var sessionFile: String?
        var sessionName: String?
        var thinkingLevel: String?
        var isStreaming: Bool
        var isCompacting: Bool
        var messageCount: Int?
        var pendingMessageCount: Int?
        var model: RemoteModel?
    }

    struct SessionMutationResult: Equatable {
        var cancelled: Bool
    }

    struct RemoteModel: Hashable {
        var provider: String?
        var id: String
        var displayName: String
        var description: String?
        var raw: [String: PiJSONValue]
    }

    struct SlashCommand: Hashable {
        var name: String
        var description: String?
        var source: String?
        var raw: [String: PiJSONValue]
    }

    struct ImageContent: Equatable, Hashable {
        var data: String
        var mimeType: String

        var jsonValue: PiJSONValue {
            .object([
                "type": .string("image"),
                "data": .string(data),
                "mimeType": .string(mimeType)
            ])
        }
    }

    struct ProtocolDiagnostic: Equatable {
        enum Kind: String, Equatable {
            case malformedJSON
            case missingEventType
            case unknownEventType
            case malformedEventPayload
            case lateResponse
            case pendingMessageStopRecovery
            case lateEventAfterTerminalRecovery
        }

        var kind: Kind
        var eventType: String?
        var message: String
        var payloadPreview: String?
        var occurrence: Int
    }

    enum Event: Equatable {
        case agentStart
        case agentEnd(messages: [[String: PiJSONValue]], willRetry: Bool)
        case agentSettled
        case turnStart
        case turnEnd(message: [String: PiJSONValue]?, toolResults: [[String: PiJSONValue]])
        case messageStart(message: [String: PiJSONValue]?)
        case messageUpdate(PiAssistantMessageEvent)
        case messageEnd(message: [String: PiJSONValue]?)
        case toolExecutionStart(toolCallID: String, toolName: String, args: [String: PiJSONValue])
        case toolExecutionUpdate(toolCallID: String, toolName: String, partialResult: PiJSONValue?)
        case toolExecutionEnd(toolCallID: String, toolName: String, result: PiJSONValue?, isError: Bool)
        case queueUpdate(steering: [String], followUp: [String])
        case compactionStart(reason: String?)
        case compactionEnd(reason: String?, result: PiJSONValue?, aborted: Bool, willRetry: Bool, errorMessage: String?)
        case autoRetryStart(attempt: Int, maxAttempts: Int, delayMs: Int, errorMessage: String)
        case autoRetryEnd(success: Bool, attempt: Int, finalError: String?)
        case sessionInfoChanged(name: String?)
        case thinkingLevelChanged(level: String)
        case extensionUIRequest(PiExtensionUIRequest)
        case extensionError(String)
        case customMessage(PiCustomMessage)
        case transportClosed(reason: String)
        case protocolDiagnostic(ProtocolDiagnostic)
        case unhandled(type: String, payload: [String: PiJSONValue])
    }

    struct PiAssistantMessageEvent: Equatable {
        var type: String
        var contentIndex: Int?
        var delta: String?
        var content: String?
        var reason: String?
        var toolCall: PiJSONValue?
        var partial: PiJSONValue?
        var raw: [String: PiJSONValue]
    }

    struct PiExtensionUIRequest: Equatable {
        var id: String
        var method: String
        var title: String?
        var message: String?
        var statusKey: String?
        var statusText: String?
        var raw: [String: PiJSONValue]

        var requiresResponse: Bool {
            switch method {
            case "select", "confirm", "input", "editor": true
            default: false
            }
        }
    }

    struct PiCustomMessage: Equatable {
        var customType: String?
        var content: String?
        var display: Bool
        var details: [String: PiJSONValue]?
        var raw: [String: PiJSONValue]
    }

    struct ExpectedAgentPIDRegistration: Equatable {
        let clientName: String
        let runID: UUID
    }

    struct ExpectedAgentPIDRegistrar {
        let register: @Sendable (_ pid: pid_t, _ clientName: String, _ runID: UUID) async -> Void
        let clear: @Sendable (_ pid: pid_t, _ clientName: String, _ runID: UUID) async -> Void

        static let serverNetworkManager = ExpectedAgentPIDRegistrar(
            register: { pid, clientName, runID in
                await ServerNetworkManager.shared.registerExpectedAgentPID(pid, for: clientName, runID: runID)
            },
            clear: { pid, clientName, runID in
                await ServerNetworkManager.shared.clearExpectedAgentPID(pid, for: clientName, runID: runID)
            }
        )
    }
}
