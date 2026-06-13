import Foundation

final class PiHeadlessAgentProvider: HeadlessAgentProvider {
    typealias BridgeInstaller = (_ windowID: Int) throws -> URL
    typealias ControllerFactory = (
        _ workspacePath: String?,
        _ modelString: String?,
        _ enableDebugLogging: Bool,
        _ bridgeExtensionURL: URL
    ) -> PiNativeSessionController

    private let modelString: String?
    private let workspacePath: String?
    private let windowID: Int
    private let enableDebugLogging: Bool
    private let bridgeInstaller: BridgeInstaller
    private let controllerFactory: ControllerFactory

    private var streamTask: Task<Void, Never>?
    private var controller: PiNativeSessionController?

    init(
        modelString: String?,
        workspacePath: String?,
        windowID: Int,
        enableDebugLogging: Bool = false,
        bridgeInstaller: @escaping BridgeInstaller = { try PiRepoPromptBridgeExtensionInstaller.install(windowID: $0) },
        controllerFactory: @escaping ControllerFactory = { workspacePath, modelString, enableDebugLogging, bridgeExtensionURL in
            PiNativeSessionController(
                workspacePath: workspacePath,
                options: .init(
                    modelRaw: modelString,
                    enableDebugLogging: enableDebugLogging,
                    launchArguments: PiIntegrationConfiguration.managedRPCLaunchArguments(
                        bridgeExtensionPath: bridgeExtensionURL.path
                    )
                )
            )
        }
    ) {
        self.modelString = modelString
        self.workspacePath = workspacePath
        self.windowID = windowID
        self.enableDebugLogging = enableDebugLogging
        self.bridgeInstaller = bridgeInstaller
        self.controllerFactory = controllerFactory
    }

    func streamAgentMessage(
        _ message: AgentMessage,
        runID: UUID?
    ) async throws -> AsyncThrowingStream<AIStreamResult, Error> {
        let actualRunID = runID ?? UUID()
        let bridgeExtensionURL = try bridgeInstaller(windowID)
        let controller = controllerFactory(workspacePath, modelString, enableDebugLogging, bridgeExtensionURL)
        self.controller = controller

        return AsyncThrowingStream { continuation in
            self.streamTask?.cancel()
            self.streamTask = Task { [weak self, controller] in
                guard let self else {
                    continuation.finish(throwing: AIProviderError.invalidConfiguration(detail: "pi provider was released before streaming started."))
                    return
                }

                await controller.setExpectedAgentPIDRegistration(
                    clientName: AgentProviderKind.pi.mcpClientNameHint,
                    runID: actualRunID
                )

                do {
                    try await controller.startOrResume(existing: nil, model: modelString)
                    let events = await controller.events
                    let collector = Task { () -> (PiNativeSessionController.TurnStatus, Bool) in
                        var sawMessageStop = false
                        for await event in events {
                            switch event {
                            case let .stream(result):
                                if result.type == "message_stop" {
                                    sawMessageStop = true
                                    if result.providerSessionID == nil,
                                       let ref = await controller.currentSessionRef()
                                    {
                                        continuation.yield(Self.streamResult(result, providerSessionID: ref.sessionID))
                                    } else {
                                        continuation.yield(result)
                                    }
                                } else {
                                    continuation.yield(result)
                                }
                            case let .turnCompleted(_, status):
                                return (status, sawMessageStop)
                            case let .extensionUIRequest(request):
                                if request.requiresResponse {
                                    try? await controller.respondToExtensionUIRequest(.cancelled(id: request.id))
                                }
                            case let .error(message):
                                continuation.finish(throwing: AIProviderError.invalidConfiguration(detail: message))
                                return (.failed, sawMessageStop)
                            case .sessionState, .diagnostic:
                                break
                            }
                        }
                        return (.failed, sawMessageStop)
                    }

                    _ = try await controller.sendUserMessage(Self.promptText(from: message))
                    let (status, sawMessageStop) = await collector.value
                    switch status {
                    case .completed:
                        if !sawMessageStop,
                           let ref = await controller.currentSessionRef()
                        {
                            continuation.yield(AIStreamResult(
                                type: "message_stop",
                                text: nil,
                                providerSessionID: ref.sessionID,
                                stopReason: "completed"
                            ))
                        }
                        continuation.finish()
                    case .cancelled:
                        continuation.finish(throwing: CancellationError())
                    case .failed:
                        continuation.finish(throwing: AIProviderError.invalidResponse(detail: "pi Context Builder run failed."))
                    }
                } catch is CancellationError {
                    _ = await controller.interruptTurn(reason: "cancel")
                    continuation.finish(throwing: CancellationError())
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { @Sendable _ in
                Task { [weak self] in
                    await self?.dispose()
                }
            }
        }
    }

    func dispose() async {
        streamTask?.cancel()
        streamTask = nil
        if let controller {
            _ = await controller.interruptTurn(reason: "cancel")
            await controller.shutdown()
        }
        controller = nil
    }

    private static func streamResult(_ result: AIStreamResult, providerSessionID: String) -> AIStreamResult {
        AIStreamResult(
            type: result.type,
            text: result.text,
            reasoning: result.reasoning,
            promptTokens: result.promptTokens,
            completionTokens: result.completionTokens,
            cost: result.cost,
            toolName: result.toolName,
            toolArgs: result.toolArgs,
            toolOutput: result.toolOutput,
            toolInvocationID: result.toolInvocationID,
            toolResultJSON: result.toolResultJSON,
            toolArgsJSON: result.toolArgsJSON,
            toolIsError: result.toolIsError,
            providerSessionID: providerSessionID,
            stopReason: result.stopReason,
            modelContextWindow: result.modelContextWindow,
            contextUsedTokens: result.contextUsedTokens,
            contentMessageID: result.contentMessageID
        )
    }

    private static func promptText(from message: AgentMessage) -> String {
        let systemPrompt = message.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let userMessage = message.userMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !systemPrompt.isEmpty else { return userMessage }
        return """
        <system_instructions>
        \(systemPrompt)
        </system_instructions>

        <user_instructions>
        \(userMessage)
        </user_instructions>
        """
    }
}
