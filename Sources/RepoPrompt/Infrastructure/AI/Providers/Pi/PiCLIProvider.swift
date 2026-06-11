import Foundation

/// pi provider for built-in chat/Oracle use.
/// Runs a fresh prompt-only pi RPC session per request. RepoPrompt does not inject
/// bridge tools here; Oracle should reason over supplied context, not edit files or
/// call RepoPrompt tools.
final class PiCLIProvider: AIProvider {
    typealias ControllerFactory = (_ modelString: String?) -> PiNativeSessionController

    private let activeControllers = ActiveOpenCodeCLIProviderStore<PiNativeSessionController>()
    private let controllerFactory: ControllerFactory

    init(
        controllerFactory: @escaping ControllerFactory = { modelString in
            PiNativeSessionController(
                workspacePath: nil,
                options: .init(
                    modelRaw: modelString,
                    launchArguments: PiIntegrationConfiguration.managedRPCPromptOnlyLaunchArguments()
                )
            )
        }
    ) {
        self.controllerFactory = controllerFactory
    }

    func streamMessage(_ aiMessage: AIMessage, model: AIModel, maxTokens _: Int? = nil) async throws -> AsyncThrowingStream<AIStreamResult, Error> {
        let modelName = piModelName(for: model)
        let controller = controllerFactory(modelName)
        if let replacedController = activeControllers.replace(controller) {
            await replacedController.shutdown()
        }

        return AsyncThrowingStream { continuation in
            let bridgeTask = Task { [weak self, controller] in
                guard let self else {
                    continuation.finish(throwing: AIProviderError.invalidConfiguration(detail: "pi provider was released before streaming started."))
                    return
                }
                do {
                    try await controller.startOrResume(existing: nil, model: modelName)
                    let events = await controller.events
                    let collector = Task { () -> PiNativeSessionController.TurnStatus in
                        for await event in events {
                            switch event {
                            case let .stream(result):
                                continuation.yield(result)
                            case let .turnCompleted(_, status):
                                return status
                            case let .extensionUIRequest(request):
                                if request.requiresResponse {
                                    try? await controller.respondToExtensionUIRequest(.cancelled(id: request.id))
                                }
                            case let .error(message):
                                continuation.finish(throwing: AIProviderError.invalidConfiguration(detail: message))
                                return .failed
                            case .sessionState, .diagnostic:
                                break
                            }
                        }
                        return .failed
                    }

                    _ = try await controller.sendUserMessage(makePrompt(from: aiMessage))
                    let status = await collector.value
                    switch status {
                    case .completed:
                        continuation.yield(AIStreamResult(type: "message_stop", text: nil, stopReason: "completed"))
                        continuation.finish()
                    case .cancelled:
                        continuation.finish(throwing: CancellationError())
                    case .failed:
                        continuation.finish(throwing: AIProviderError.invalidResponse(detail: "pi Oracle run failed."))
                    }
                } catch is CancellationError {
                    _ = await controller.interruptTurn(reason: "cancel")
                    continuation.finish(throwing: CancellationError())
                } catch {
                    continuation.finish(throwing: error)
                }

                if activeControllers.remove(controller) {
                    await controller.shutdown()
                }
            }

            continuation.onTermination = { [activeControllers] termination in
                bridgeTask.cancel()
                guard case .cancelled = termination else { return }
                Task {
                    if activeControllers.remove(controller) {
                        _ = await controller.interruptTurn(reason: "cancel")
                        await controller.shutdown()
                    }
                }
            }
        }
    }

    func completeMessage(_ aiMessage: AIMessage, model: AIModel, maxTokens: Int? = nil) async throws -> AICompletionResult {
        let stream = try await streamMessage(aiMessage, model: model, maxTokens: maxTokens)
        var textParts: [String] = []
        var finalContent: String?
        var promptTokens: Int?
        var completionTokens: Int?
        var cost: Double?
        var sawMessageStop = false

        for try await result in stream {
            switch result.type {
            case "content":
                if let text = result.text, !text.isEmpty {
                    textParts.append(text)
                }
            case "final_content":
                if let text = result.text, !text.isEmpty {
                    finalContent = text
                }
            case "message_stop":
                sawMessageStop = true
                if let value = result.promptTokens { promptTokens = value }
                if let value = result.completionTokens { completionTokens = value }
                if let value = result.cost { cost = value }
            case "error":
                throw AIProviderError.invalidConfiguration(detail: result.text ?? "pi RPC reported an error")
            default:
                continue
            }
        }

        let text = textParts.isEmpty ? (finalContent ?? "") : textParts.joined()
        guard sawMessageStop || !text.isEmpty else {
            throw AIProviderError.invalidResponse(detail: "pi returned no completion")
        }

        return AICompletionResult(
            text: text,
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            cost: cost
        )
    }

    func dispose() async {
        let controllers = activeControllers.removeAll()
        for controller in controllers {
            _ = await controller.interruptTurn(reason: "cancel")
            await controller.shutdown()
        }
    }

    private func makePrompt(from aiMessage: AIMessage) -> String {
        let tail = aiMessage.buildTail(embedSystemPrompt: false)
        var conversation = ""
        let lastUserIndex = aiMessage.conversationMessages.lastIndex { $0.role == .user }
        for (index, message) in aiMessage.conversationMessages.enumerated() {
            var text = message.content
            if message.role == .user,
               index == lastUserIndex,
               !tail.isEmpty
            {
                text = tail + "\n\n" + text
            }
            let prefix = message.role == .user ? "User" : "Assistant"
            if !conversation.isEmpty {
                conversation += "\n\n"
            }
            conversation += "\(prefix): \(text)"
        }
        if aiMessage.conversationMessages.isEmpty, !tail.isEmpty {
            conversation = "User: \(tail)"
        }

        let systemPrompt = aiMessage.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !systemPrompt.isEmpty else { return conversation }
        return """
        <system_instructions>
        \(systemPrompt)
        </system_instructions>

        <user_instructions>
        \(conversation)
        </user_instructions>
        """
    }

    private func piModelName(for model: AIModel) -> String? {
        guard model.providerType == .pi else { return nil }
        let trimmed = model.modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed == AgentModel.defaultModel.rawValue ? nil : trimmed
    }
}
