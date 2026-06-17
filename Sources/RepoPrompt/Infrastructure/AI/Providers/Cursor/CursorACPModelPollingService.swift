import Foundation

protocol CursorACPModelDiscoveryClient: ACPModelDiscoveryClient {}

struct CursorACPControllerModelDiscoveryClient: CursorACPModelDiscoveryClient {
    typealias ProviderFactory = @Sendable (_ agent: AgentProviderKind, _ modelString: String?) -> (any ACPAgentProvider)?
    typealias ControllerFactory = @Sendable (_ provider: any ACPAgentProvider, _ runRequest: ACPRunRequest) throws -> ACPAgentSessionController

    private let providerFactory: ProviderFactory
    private let controllerFactory: ControllerFactory

    init(
        providerFactory: @escaping ProviderFactory = { agent, modelString in
            if agent == .cursor {
                return CursorACPAgentProvider(
                    config: CursorAgentConfig(
                        enableDebugLogging: AgentRuntimeProviderService.enableDebugLogging,
                        modelString: modelString,
                        includeRepoPromptMCPServer: false,
                        cleanupProjectMCPApproval: false
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
        let preferredModel = AgentModel.cursorAuto.rawValue
        let request = ACPRunRequest(
            agentKind: .cursor,
            modelString: preferredModel,
            workspacePath: workspacePath,
            resumeSessionID: nil,
            attachments: [],
            taskLabelKind: nil
        )
        guard let provider = providerFactory(.cursor, preferredModel) else { return nil }
        let support = try await provider.support(for: request)
        guard support == .supported else {
            throw AIProviderError.invalidConfiguration(
                detail: support.reason ?? "Cursor ACP is not available."
            )
        }

        let controller = try controllerFactory(provider, request)
        do {
            _ = try await controller.bootstrap()
            try? await controller.setSessionModel(preferredModel)
            let snapshot = AgentACPModelRegistry.shared.currentSnapshot(for: .cursor)
            await controller.shutdown()
            return snapshot
        } catch {
            await controller.shutdown()
            throw error
        }
    }
}

// SEARCH-HELPER: Cursor ACP model polling, dynamic discovery, subscribe, registry refresh
/// Centralized polling service for Cursor ACP dynamic model options.
///
/// Cursor can expose model metadata through ACP session bootstrap responses. This mirrors the
/// OpenCode model discovery path while preserving Cursor's static Auto fallback when no
/// dynamic model metadata is available yet.
actor CursorACPModelPollingService {
    static let shared = CursorACPModelPollingService(
        client: CursorACPControllerModelDiscoveryClient()
    )

    typealias Snapshot = ACPModelPollingSnapshot

    private let core: ACPModelPollingServiceCore

    init(
        client: any CursorACPModelDiscoveryClient,
        intervalNanos: UInt64 = 300_000_000_000
    ) {
        core = ACPModelPollingServiceCore(
            client: client,
            configuration: .cursor,
            intervalNanos: intervalNanos
        )
    }

    func latestSnapshot() async -> Snapshot? {
        await core.latestSnapshot()
    }

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
