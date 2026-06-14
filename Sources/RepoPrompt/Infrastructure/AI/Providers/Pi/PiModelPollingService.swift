import Foundation

protocol PiModelDiscoveryClient: Sendable {
    func discoverModels(workspacePath: String?) async throws -> PiDiscoveredModels?
}

protocol PiModelPolling: Sendable {
    func latestSnapshot() async -> PiModelPollingService.Snapshot?
    func discoverOnce(workspacePath: String?) async throws -> PiModelPollingService.Snapshot?
    func subscribe(workspacePath: String?) async -> AsyncStream<PiModelPollingService.Event>
}

struct PiRPCModelDiscoveryClient: PiModelDiscoveryClient {
    typealias ClientFactory = @Sendable (_ workspacePath: String?) -> PiRPCClient

    private let clientFactory: ClientFactory

    init(
        clientFactory: @escaping ClientFactory = { workspacePath in
            PiRPCClient(config: .init(
                workingDirectory: workspacePath,
                launchArguments: PiIntegrationConfiguration.managedRPCModelDiscoveryLaunchArguments()
            ))
        }
    ) {
        self.clientFactory = clientFactory
    }

    func discoverModels(workspacePath: String?) async throws -> PiDiscoveredModels? {
        let client = clientFactory(workspacePath)
        do {
            try await client.startIfNeeded()
            let state = try? await client.getState()
            let remoteModels = try await client.getAvailableModels()
            await client.shutdown()
            return AgentPiModelRegistry.discoveredModels(from: remoteModels, currentModel: state?.model)
        } catch {
            await client.shutdown()
            throw error
        }
    }
}

// SEARCH-HELPER: pi RPC model polling, dynamic model discovery, get_available_models cache
/// Centralized polling service for pi RPC dynamic model options.
///
/// pi owns provider/model configuration. RepoPrompt only asks pi for its current model list,
/// caches the result for picker/settings surfaces, and keeps the plain `default` option so a
/// managed run can preserve pi's configured default model without sending `set_model`.
actor PiModelPollingService: PiModelPolling {
    static let shared = PiModelPollingService(client: PiRPCModelDiscoveryClient())

    struct Snapshot: Equatable {
        let models: PiDiscoveredModels
        let fetchedAt: Date
    }

    struct Failure: Equatable {
        let message: String
    }

    enum Event: Equatable {
        case snapshot(Snapshot)
        case failure(Failure)
    }

    private struct InFlightRefresh {
        let id: UUID
        let task: Task<Result<Void, Error>, Never>
    }

    private struct WorkspacePollingContext {
        var pollingTask: Task<Void, Never>?
        var inFlightRefresh: InFlightRefresh?
        var continuations: [UUID: AsyncStream<Event>.Continuation] = [:]
        var latest: Snapshot?
        var shouldPublishNextSuccessfulRefresh = false
        #if DEBUG
            var publishedEventCount = 0
        #endif
    }

    private let client: any PiModelDiscoveryClient
    private let intervalNanos: UInt64
    private let startsPollingOnSubscribe: Bool

    private var contexts: [PiModelWorkspaceScope: WorkspacePollingContext] = [:]
    private var isShutdown = false

    init(
        client: any PiModelDiscoveryClient,
        intervalNanos: UInt64 = 300_000_000_000,
        startsPollingOnSubscribe: Bool = true
    ) {
        self.client = client
        self.intervalNanos = intervalNanos
        self.startsPollingOnSubscribe = startsPollingOnSubscribe
    }

    func latestSnapshot() async -> Snapshot? {
        await latestSnapshot(workspacePath: nil)
    }

    func latestSnapshot(workspacePath: String?) async -> Snapshot? {
        let scope = PiModelWorkspaceScope(workspacePath: workspacePath)
        if let latest = contexts[scope]?.latest { return latest }
        return await registrySnapshotAfterWarmingStore(scope: scope)
    }

    /// Force a foreground pi RPC model discovery and return the normalized snapshot.
    func discoverOnce(workspacePath: String?) async throws -> Snapshot? {
        guard !isShutdown else { return nil }
        let scope = PiModelWorkspaceScope(workspacePath: workspacePath)
        let refresh = startRefreshIfNeeded(scope: scope)
        let result = await refresh.task.value
        clearInFlightRefresh(refresh, scope: scope)
        switch result {
        case .success:
            return await latestSnapshot(workspacePath: scope.workspacePath)
        case let .failure(error):
            throw error
        }
    }

    func subscribe(workspacePath: String?) async -> AsyncStream<Event> {
        guard !isShutdown else {
            return AsyncStream { continuation in
                continuation.finish()
            }
        }

        let scope = PiModelWorkspaceScope(workspacePath: workspacePath)
        let id = UUID()
        let (stream, continuation) = AsyncStream<Event>.makeStream(bufferingPolicy: .bufferingNewest(1))
        var context = contexts[scope] ?? WorkspacePollingContext()
        context.continuations[id] = continuation
        contexts[scope] = context
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSubscriber(id, scope: scope) }
        }

        if contexts[scope]?.latest == nil, let cached = await registrySnapshotAfterWarmingStore(scope: scope) {
            guard !isShutdown else {
                continuation.finish()
                return stream
            }
            if contexts[scope]?.latest == nil {
                var refreshedContext = contexts[scope] ?? WorkspacePollingContext()
                refreshedContext.latest = cached
                contexts[scope] = refreshedContext
            }
        }
        if let latest = contexts[scope]?.latest {
            continuation.yield(.snapshot(latest))
            #if DEBUG
                contexts[scope]?.publishedEventCount += 1
            #endif
        }

        guard !isShutdown else { return stream }
        if startsPollingOnSubscribe {
            startPollingIfNeeded(scope: scope)
        }
        return stream
    }

    func refreshNow(workspacePath: String?) async {
        guard !isShutdown else { return }
        let scope = PiModelWorkspaceScope(workspacePath: workspacePath)
        if let existing = contexts[scope]?.inFlightRefresh {
            _ = await existing.task.value
            return
        }
        await performRefresh(scope: scope)
    }

    func shutdown(finishSubscribers: Bool = true) async {
        isShutdown = true
        for scope in contexts.keys {
            contexts[scope]?.pollingTask?.cancel()
            contexts[scope]?.inFlightRefresh?.task.cancel()
        }
        if finishSubscribers {
            let activeContinuations = contexts.values.flatMap(\.continuations.values)
            contexts.removeAll()
            for continuation in activeContinuations {
                continuation.finish()
            }
        } else {
            for scope in contexts.keys {
                contexts[scope]?.pollingTask = nil
                contexts[scope]?.inFlightRefresh = nil
            }
        }
    }

    private func startPollingIfNeeded(scope: PiModelWorkspaceScope) {
        guard !isShutdown else { return }
        guard contexts[scope]?.pollingTask == nil else { return }
        let task = Task { [weak self, scope] in
            guard let self else { return }
            while !Task.isCancelled {
                await performRefresh(scope: scope)
                do {
                    try await Task.sleep(nanoseconds: intervalNanos)
                } catch {
                    break
                }
            }
        }
        var context = contexts[scope] ?? WorkspacePollingContext()
        context.pollingTask = task
        contexts[scope] = context
    }

    private func stopPollingIfIdle(scope: PiModelWorkspaceScope) {
        guard contexts[scope]?.continuations.isEmpty ?? true else { return }
        contexts[scope]?.pollingTask?.cancel()
        contexts[scope]?.pollingTask = nil
    }

    private func removeSubscriber(_ id: UUID, scope: PiModelWorkspaceScope) {
        contexts[scope]?.continuations.removeValue(forKey: id)
        stopPollingIfIdle(scope: scope)
    }

    private func performRefresh(scope: PiModelWorkspaceScope) async {
        guard !isShutdown else { return }
        let refresh = startRefreshIfNeeded(scope: scope)
        let result = await refresh.task.value
        clearInFlightRefresh(refresh, scope: scope)
        if case let .failure(error) = result {
            await publishFailure(Failure(message: error.localizedDescription), scope: scope)
        }
    }

    private func startRefreshIfNeeded(scope: PiModelWorkspaceScope) -> InFlightRefresh {
        if let existing = contexts[scope]?.inFlightRefresh {
            return existing
        }

        let workspacePath = scope.workspacePath
        let task = Task<Result<Void, Error>, Never> { [weak self, scope, workspacePath] in
            guard let self else { return .success(()) }
            do {
                guard let discovered = try await client.discoverModels(workspacePath: workspacePath) else { return .success(()) }
                guard !Task.isCancelled else { return .success(()) }
                await applyRefreshResult(discovered, scope: scope)
                return .success(())
            } catch {
                return .failure(error)
            }
        }
        let refresh = InFlightRefresh(id: UUID(), task: task)
        var context = contexts[scope] ?? WorkspacePollingContext()
        context.inFlightRefresh = refresh
        contexts[scope] = context
        return refresh
    }

    private func clearInFlightRefresh(_ refresh: InFlightRefresh, scope: PiModelWorkspaceScope) {
        guard contexts[scope]?.inFlightRefresh?.id == refresh.id else { return }
        contexts[scope]?.inFlightRefresh = nil
    }

    private func applyRefreshResult(_ discovered: PiDiscoveredModels, scope: PiModelWorkspaceScope) {
        guard !isShutdown else { return }
        _ = AgentPiModelRegistry.shared.updateDiscoveredModels(discovered, workspacePath: scope.workspacePath)
        guard let normalized = AgentPiModelRegistry.shared.resolvedSnapshot(workspacePath: scope.workspacePath) else { return }
        let snapshot = Snapshot(models: normalized, fetchedAt: Date())
        var context = contexts[scope] ?? WorkspacePollingContext()
        guard context.shouldPublishNextSuccessfulRefresh || context.latest?.models != snapshot.models else {
            contexts[scope] = context
            return
        }
        context.shouldPublishNextSuccessfulRefresh = false
        context.latest = snapshot
        let continuations = context.continuations.values
        contexts[scope] = context
        for continuation in continuations {
            continuation.yield(.snapshot(snapshot))
        }
        #if DEBUG
            contexts[scope]?.publishedEventCount += continuations.count
        #endif
    }

    private func publishFailure(_ failure: Failure, scope: PiModelWorkspaceScope) {
        guard !isShutdown else { return }
        var context = contexts[scope] ?? WorkspacePollingContext()
        context.shouldPublishNextSuccessfulRefresh = true
        let continuations = context.continuations.values
        contexts[scope] = context
        for continuation in continuations {
            continuation.yield(.failure(failure))
        }
        #if DEBUG
            contexts[scope]?.publishedEventCount += continuations.count
        #endif
    }

    #if DEBUG
        func test_publishedEventCount(workspacePath: String?) -> Int {
            let scope = PiModelWorkspaceScope(workspacePath: workspacePath)
            return contexts[scope]?.publishedEventCount ?? 0
        }
    #endif

    private func registrySnapshotAfterWarmingStore(scope: PiModelWorkspaceScope) async -> Snapshot? {
        guard let models = await AgentPiModelRegistry.shared.resolvedSnapshotAfterWarmingStandardStore(
            workspacePath: scope.workspacePath
        ) else {
            return nil
        }
        let snapshot = Snapshot(models: models, fetchedAt: Date())
        var context = contexts[scope] ?? WorkspacePollingContext()
        context.latest = snapshot
        contexts[scope] = context
        return snapshot
    }
}
