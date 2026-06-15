import Foundation

final class PiHeadlessAgentProvider: HeadlessAgentProvider {
    typealias BridgeInstaller = (_ windowID: Int) throws -> URL
    typealias ControllerFactory = (
        _ workspacePath: String?,
        _ modelString: String?,
        _ enableDebugLogging: Bool,
        _ bridgeExtensionURL: URL,
        _ permissionLevel: PiAgentToolPreferences.PermissionLevel,
        _ launchPolicy: PiManagedRunLaunchPolicy
    ) -> PiNativeSessionController

    private let modelString: String?
    private let workspacePath: String?
    private let windowID: Int
    private let enableDebugLogging: Bool
    private let launchPolicy: PiManagedRunLaunchPolicy
    private let bridgeInstaller: BridgeInstaller
    private let controllerFactory: ControllerFactory
    let permissionLevel: PiAgentToolPreferences.PermissionLevel

    private let lifecycle = StreamLifecycle()

    init(
        modelString: String?,
        workspacePath: String?,
        windowID: Int,
        enableDebugLogging: Bool = false,
        permissionLevel: PiAgentToolPreferences.PermissionLevel = .managedDefault,
        launchPolicy: PiManagedRunLaunchPolicy = .defaultPolicy,
        bridgeInstaller: @escaping BridgeInstaller = { try PiRepoPromptBridgeExtensionInstaller.install(windowID: $0) },
        controllerFactory: @escaping ControllerFactory = { workspacePath, modelString, enableDebugLogging, bridgeExtensionURL, permissionLevel, launchPolicy in
            PiNativeSessionController(
                workspacePath: workspacePath,
                options: .init(
                    modelRaw: modelString,
                    enableDebugLogging: enableDebugLogging,
                    launchArguments: PiIntegrationConfiguration.managedRPCLaunchArguments(
                        bridgeExtensionPath: bridgeExtensionURL.path,
                        launchPolicy: launchPolicy
                    ),
                    environmentOverrides: PiIntegrationConfiguration.managedRunEnvironment(permissionLevel: permissionLevel)
                )
            )
        }
    ) {
        self.modelString = modelString
        self.workspacePath = workspacePath
        self.windowID = windowID
        self.enableDebugLogging = enableDebugLogging
        self.launchPolicy = launchPolicy
        self.permissionLevel = permissionLevel
        self.bridgeInstaller = bridgeInstaller
        self.controllerFactory = controllerFactory
    }

    func streamAgentMessage(
        _ message: AgentMessage,
        runID: UUID?
    ) async throws -> AsyncThrowingStream<AIStreamResult, Error> {
        let actualRunID = runID ?? UUID()
        let bridgeExtensionURL = try bridgeInstaller(windowID)
        let controller = controllerFactory(workspacePath, modelString, enableDebugLogging, bridgeExtensionURL, permissionLevel, launchPolicy)
        let lifecycle = lifecycle
        let streamRunID = await lifecycle.install(controller: controller)

        return AsyncThrowingStream { continuation in
            let task = Task { [weak self, controller, lifecycle] in
                guard let self else {
                    continuation.finish(throwing: AIProviderError.invalidConfiguration(detail: "pi provider was released before streaming started."))
                    return
                }

                await controller.setExpectedAgentPIDRegistration(
                    clientName: AgentProviderKind.pi.mcpClientNameHint,
                    runID: actualRunID
                )

                do {
                    _ = try await controller.startOrResume(existing: nil, model: modelString)
                    let events = await controller.events
                    let collector = Task { () -> (PiNativeSessionController.TurnStatus, Bool, Error?) in
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
                                return (status, sawMessageStop, nil)
                            case let .extensionUIRequest(request):
                                if request.requiresResponse {
                                    try? await controller.respondToExtensionUIRequest(.cancelled(id: request.id))
                                }
                            case let .error(message):
                                return (.failed, sawMessageStop, AIProviderError.invalidConfiguration(detail: message))
                            case .sessionState, .diagnostic:
                                break
                            }
                        }
                        return (.failed, sawMessageStop, nil)
                    }

                    _ = try await controller.sendUserMessage(Self.promptText(from: message))
                    let (status, sawMessageStop, terminalError) = await collector.value
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
                        await lifecycle.finish(runID: streamRunID, controller: controller, continuation: continuation)
                    case .cancelled:
                        await lifecycle.finish(runID: streamRunID, controller: controller, continuation: continuation, throwing: CancellationError())
                    case .failed:
                        await lifecycle.finish(
                            runID: streamRunID,
                            controller: controller,
                            continuation: continuation,
                            throwing: terminalError ?? AIProviderError.invalidResponse(detail: "pi Context Builder run failed.")
                        )
                    }
                } catch is CancellationError {
                    _ = await controller.interruptTurn(reason: "cancel")
                    await lifecycle.finish(runID: streamRunID, controller: controller, continuation: continuation, throwing: CancellationError())
                } catch {
                    await lifecycle.finish(runID: streamRunID, controller: controller, continuation: continuation, throwing: error)
                }
            }

            Task { await lifecycle.setTask(task, continuation: continuation, runID: streamRunID) }

            continuation.onTermination = { @Sendable _ in
                Task { [lifecycle] in
                    await lifecycle.dispose(runID: streamRunID)
                }
            }
        }
    }

    func dispose() async {
        await lifecycle.disposeAll()
    }

    private actor StreamLifecycle {
        private struct Run {
            let id: UUID
            let controller: PiNativeSessionController
            var task: Task<Void, Never>?
            var continuation: AsyncThrowingStream<AIStreamResult, Error>.Continuation?
        }

        private var currentRun: Run?
        private var terminalRunIDs = Set<UUID>()

        func install(controller: PiNativeSessionController) async -> UUID {
            if let previousRun = currentRun {
                currentRun = nil
                await terminate(previousRun, throwing: CancellationError())
            }

            let id = UUID()
            currentRun = Run(id: id, controller: controller, task: nil, continuation: nil)
            return id
        }

        func setTask(
            _ task: Task<Void, Never>,
            continuation: AsyncThrowingStream<AIStreamResult, Error>.Continuation,
            runID: UUID
        ) {
            guard var run = currentRun, run.id == runID else {
                task.cancel()
                continuation.finish(throwing: CancellationError())
                return
            }
            run.task = task
            run.continuation = continuation
            currentRun = run
        }

        func finish(
            runID: UUID,
            controller: PiNativeSessionController,
            continuation: AsyncThrowingStream<AIStreamResult, Error>.Continuation,
            throwing error: Error? = nil
        ) async {
            guard terminalRunIDs.insert(runID).inserted else { return }
            if currentRun?.id == runID {
                currentRun = nil
            }
            await controller.shutdown()
            if let error {
                continuation.finish(throwing: error)
            } else {
                continuation.finish()
            }
        }

        func dispose(runID: UUID) async {
            guard let run = currentRun, run.id == runID else { return }
            currentRun = nil
            await terminate(run, throwing: CancellationError())
        }

        func disposeAll() async {
            guard let run = currentRun else { return }
            currentRun = nil
            await terminate(run, throwing: CancellationError())
        }

        private func terminate(_ run: Run, throwing error: Error?) async {
            guard terminalRunIDs.insert(run.id).inserted else { return }
            run.task?.cancel()
            _ = await run.controller.interruptTurn(reason: "cancel")
            await run.controller.shutdown()
            if let error {
                run.continuation?.finish(throwing: error)
            } else {
                run.continuation?.finish()
            }
        }
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
