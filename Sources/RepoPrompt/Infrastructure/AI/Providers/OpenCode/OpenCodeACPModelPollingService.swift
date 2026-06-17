import Foundation

protocol OpenCodeACPModelDiscoveryClient: ACPModelDiscoveryClient {}

struct OpenCodeACPControllerModelDiscoveryClient: OpenCodeACPModelDiscoveryClient {
    typealias ProviderFactory = @Sendable (_ agent: AgentProviderKind, _ modelString: String?) -> (any ACPAgentProvider)?
    typealias ControllerFactory = @Sendable (_ provider: any ACPAgentProvider, _ runRequest: ACPRunRequest) throws -> ACPAgentSessionController

    private let providerFactory: ProviderFactory
    private let controllerFactory: ControllerFactory

    init(
        providerFactory: @escaping ProviderFactory = { agent, modelString in
            if agent == .openCode {
                return OpenCodeACPAgentProvider(
                    config: OpenCodeAgentConfig(
                        modelString: modelString,
                        enableDebugLogging: AgentRuntimeProviderService.enableDebugLogging,
                        includeRepoPromptMCPServer: false,
                        includeManagedConfigOverlay: true,
                        cleanupLegacyPersistentConfig: true,
                        toolProfile: .noTools
                    )
                )
            }
            return ACPAgentProviderFactory.makeProvider(for: agent, modelString: modelString)
        },
        controllerFactory: @escaping ControllerFactory = { provider, runRequest in
            try ACPAgentSessionController(provider: provider, runRequest: runRequest)
        }
    ) {
        self.providerFactory = providerFactory
        self.controllerFactory = controllerFactory
    }

    func discoverModels(workspacePath: String?) async throws -> ACPDiscoveredSessionModels? {
        let request = ACPRunRequest(
            agentKind: .openCode,
            modelString: nil,
            workspacePath: workspacePath,
            resumeSessionID: nil,
            attachments: [],
            taskLabelKind: nil
        )
        guard let provider = providerFactory(.openCode, nil) else { return nil }
        let support = try await provider.support(for: request)
        guard support == .supported else {
            throw AIProviderError.invalidConfiguration(
                detail: support.reason ?? "OpenCode ACP is not available."
            )
        }

        let controller = try controllerFactory(provider, request)
        do {
            _ = try await controller.bootstrap()
            let snapshot = AgentACPModelRegistry.shared.currentSnapshot(for: .openCode)
            await controller.shutdown()
            return snapshot
        } catch {
            await controller.shutdown()
            throw error
        }
    }
}

// SEARCH-HELPER: OpenCode ACP model polling, dynamic discovery, subscribe, registry refresh
/// Centralized polling service for OpenCode ACP dynamic model options.
///
/// OpenCode exposes model metadata through ACP session bootstrap responses. This service owns
/// the lightweight discovery loop and writes normalized options through `AgentACPModelRegistry`,
/// keeping Agent Mode and Discover UI paths as registry consumers rather than duplicate parsers.
actor OpenCodeACPModelPollingService {
    static let shared = OpenCodeACPModelPollingService(
        client: OpenCodeACPControllerModelDiscoveryClient()
    )

    typealias Snapshot = ACPModelPollingSnapshot

    private let core: ACPModelPollingServiceCore

    init(
        client: any OpenCodeACPModelDiscoveryClient,
        intervalNanos: UInt64 = 300_000_000_000
    ) {
        core = ACPModelPollingServiceCore(
            client: client,
            configuration: .openCode,
            intervalNanos: intervalNanos
        )
    }

    func latestSnapshot() async -> Snapshot? {
        await core.latestSnapshot()
    }

    /// Force a foreground OpenCode ACP model discovery and return the normalized snapshot.
    ///
    /// Settings uses this for connection/preflight so model options are written to
    /// `AgentACPModelRegistry` before the first agent session starts. Unlike the
    /// background polling loop, errors are surfaced to the caller for user-facing state.
    func discoverOnce(workspacePath: String?) async throws -> Snapshot? {
        try await core.discoverOnce(workspacePath: workspacePath)
    }

    func subscribe(workspacePath: String?) async -> AsyncStream<Snapshot> {
        await core.subscribe(workspacePath: workspacePath)
    }

    @discardableResult
    func refreshNow(workspacePath: String?) async -> Bool {
        await core.refreshNow(workspacePath: workspacePath)
    }

    func shutdown(finishSubscribers: Bool = true) async {
        await core.shutdown(finishSubscribers: finishSubscribers)
    }
}
