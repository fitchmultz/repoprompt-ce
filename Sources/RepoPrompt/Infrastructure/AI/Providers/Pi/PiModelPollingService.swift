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
                launchArguments: PiIntegrationConfiguration.managedRPCLaunchArguments()
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

    private let client: any PiModelDiscoveryClient
    private let intervalNanos: UInt64
    private let startsPollingOnSubscribe: Bool

    private var pollingTask: Task<Void, Never>?
    private var inFlightRefresh: Task<Void, Never>?
    private var continuations: [UUID: AsyncStream<Event>.Continuation] = [:]
    private var latest: Snapshot?
    private var shouldPublishNextSuccessfulRefresh = false
    private var preferredWorkspacePath: String?
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
        if let latest { return latest }
        return await registrySnapshotAfterWarmingStore()
    }

    /// Force a foreground pi RPC model discovery and return the normalized snapshot.
    func discoverOnce(workspacePath: String?) async throws -> Snapshot? {
        guard !isShutdown else { return nil }
        preferredWorkspacePath = normalizedWorkspacePath(workspacePath)
        if let existing = inFlightRefresh {
            await existing.value
            return await latestSnapshot()
        }
        guard let discovered = try await client.discoverModels(workspacePath: preferredWorkspacePath) else {
            return nil
        }
        applyRefreshResult(discovered)
        return await latestSnapshot()
    }

    func subscribe(workspacePath: String?) async -> AsyncStream<Event> {
        guard !isShutdown else {
            return AsyncStream { continuation in
                continuation.finish()
            }
        }

        preferredWorkspacePath = normalizedWorkspacePath(workspacePath)
        let id = UUID()
        let (stream, continuation) = AsyncStream<Event>.makeStream(bufferingPolicy: .bufferingNewest(1))
        continuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSubscriber(id) }
        }

        if latest == nil, let cached = await registrySnapshotAfterWarmingStore() {
            guard !isShutdown else {
                continuation.finish()
                return stream
            }
            if latest == nil {
                latest = cached
            }
        }
        if let latest {
            continuation.yield(.snapshot(latest))
        }

        guard !isShutdown else { return stream }
        if startsPollingOnSubscribe {
            startPollingIfNeeded()
        }
        return stream
    }

    func refreshNow(workspacePath: String?) async {
        guard !isShutdown else { return }
        preferredWorkspacePath = normalizedWorkspacePath(workspacePath)
        if let existing = inFlightRefresh {
            await existing.value
            return
        }
        await performRefresh()
    }

    func shutdown(finishSubscribers: Bool = true) async {
        isShutdown = true
        pollingTask?.cancel()
        pollingTask = nil
        inFlightRefresh?.cancel()
        inFlightRefresh = nil
        if finishSubscribers {
            let activeContinuations = continuations
            continuations.removeAll()
            for continuation in activeContinuations.values {
                continuation.finish()
            }
        }
    }

    private func startPollingIfNeeded() {
        guard !isShutdown else { return }
        guard pollingTask == nil else { return }
        pollingTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await performRefresh()
                do {
                    try await Task.sleep(nanoseconds: intervalNanos)
                } catch {
                    break
                }
            }
        }
    }

    private func stopPollingIfIdle() {
        guard continuations.isEmpty else { return }
        pollingTask?.cancel()
        pollingTask = nil
    }

    private func removeSubscriber(_ id: UUID) {
        continuations.removeValue(forKey: id)
        stopPollingIfIdle()
    }

    private func performRefresh() async {
        guard !isShutdown else { return }
        if let existing = inFlightRefresh {
            await existing.value
            return
        }

        let workspacePath = preferredWorkspacePath
        let task = Task { [weak self, workspacePath] in
            guard let self else { return }
            do {
                guard let discovered = try await client.discoverModels(workspacePath: workspacePath) else { return }
                guard !Task.isCancelled else { return }
                await applyRefreshResult(discovered)
            } catch {
                await publishFailure(Failure(message: error.localizedDescription))
            }
        }
        inFlightRefresh = task
        defer { inFlightRefresh = nil }
        await task.value
    }

    private func applyRefreshResult(_ discovered: PiDiscoveredModels) {
        guard !isShutdown else { return }
        _ = AgentPiModelRegistry.shared.updateDiscoveredModels(discovered)
        guard let normalized = AgentPiModelRegistry.shared.resolvedSnapshot() else { return }
        let snapshot = Snapshot(models: normalized, fetchedAt: Date())
        guard shouldPublishNextSuccessfulRefresh || latest?.models != snapshot.models else { return }
        shouldPublishNextSuccessfulRefresh = false
        latest = snapshot
        for continuation in continuations.values {
            continuation.yield(.snapshot(snapshot))
        }
    }

    private func publishFailure(_ failure: Failure) {
        guard !isShutdown else { return }
        shouldPublishNextSuccessfulRefresh = true
        for continuation in continuations.values {
            continuation.yield(.failure(failure))
        }
    }

    private func registrySnapshotAfterWarmingStore() async -> Snapshot? {
        guard let models = await AgentPiModelRegistry.shared.resolvedSnapshotAfterWarmingStandardStore() else {
            return nil
        }
        let snapshot = Snapshot(models: models, fetchedAt: Date())
        latest = snapshot
        return snapshot
    }

    private func normalizedWorkspacePath(_ workspacePath: String?) -> String? {
        guard let trimmed = workspacePath?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
