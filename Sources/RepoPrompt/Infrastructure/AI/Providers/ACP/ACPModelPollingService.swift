import Foundation

protocol ACPModelDiscoveryClient: Sendable {
    func discoverModels(workspacePath: String?) async throws -> ACPDiscoveredSessionModels?
}

struct ACPModelPollingConfiguration {
    let providerID: ACPProviderID
    let publishLiveReadinessWhenDiscoveryReturnsNil: Bool
    let discoverOnceWaitsForInFlightRefresh: Bool

    static let cursor = ACPModelPollingConfiguration(
        providerID: .cursor,
        publishLiveReadinessWhenDiscoveryReturnsNil: true,
        discoverOnceWaitsForInFlightRefresh: false
    )

    static let openCode = ACPModelPollingConfiguration(
        providerID: .openCode,
        publishLiveReadinessWhenDiscoveryReturnsNil: false,
        discoverOnceWaitsForInFlightRefresh: true
    )
}

struct ACPModelPollingSnapshot: Equatable {
    let models: ACPDiscoveredSessionModels
    let fetchedAt: Date
    let isLiveDiscovery: Bool
}

// SEARCH-HELPER: ACP model polling, dynamic discovery, subscribe, registry refresh
actor ACPModelPollingServiceCore {
    private let client: any ACPModelDiscoveryClient
    private let configuration: ACPModelPollingConfiguration
    private let intervalNanos: UInt64

    private var pollingTask: Task<Void, Never>?
    private var inFlightRefresh: Task<Bool, Never>?
    private var continuations: [UUID: AsyncStream<ACPModelPollingSnapshot>.Continuation] = [:]
    private var latest: ACPModelPollingSnapshot?
    private var preferredWorkspacePath: String?
    private var isShutdown = false

    init(
        client: any ACPModelDiscoveryClient,
        configuration: ACPModelPollingConfiguration,
        intervalNanos: UInt64 = 300_000_000_000
    ) {
        self.client = client
        self.configuration = configuration
        self.intervalNanos = intervalNanos
    }

    func latestSnapshot() async -> ACPModelPollingSnapshot? {
        if let latest { return latest }
        return await registrySnapshotAfterWarmingStore()
    }

    func discoverOnce(workspacePath: String?) async throws -> ACPModelPollingSnapshot? {
        guard !isShutdown else { return nil }
        preferredWorkspacePath = normalizedWorkspacePath(workspacePath)
        if configuration.discoverOnceWaitsForInFlightRefresh, let existing = inFlightRefresh {
            await existing.value
            return await latestSnapshot()
        }
        guard let discovered = try await client.discoverModels(workspacePath: preferredWorkspacePath) else {
            return nil
        }
        applyRefreshResult(discovered)
        return await latestSnapshot()
    }

    func subscribe(workspacePath: String?) async -> AsyncStream<ACPModelPollingSnapshot> {
        guard !isShutdown else {
            return AsyncStream { continuation in
                continuation.finish()
            }
        }

        preferredWorkspacePath = normalizedWorkspacePath(workspacePath)
        let id = UUID()
        let (stream, continuation) = AsyncStream<ACPModelPollingSnapshot>.makeStream(bufferingPolicy: .bufferingNewest(1))
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
            continuation.yield(latest)
        }

        guard !isShutdown else { return stream }
        startPollingIfNeeded()
        return stream
    }

    @discardableResult
    func refreshNow(workspacePath: String?) async -> Bool {
        guard !isShutdown else { return false }
        preferredWorkspacePath = normalizedWorkspacePath(workspacePath)
        if let existing = inFlightRefresh {
            return await existing.value
        }
        return await performRefresh()
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
                _ = await performRefresh()
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

    private func performRefresh() async -> Bool {
        guard !isShutdown else { return false }
        if let existing = inFlightRefresh {
            return await existing.value
        }

        let workspacePath = preferredWorkspacePath
        let task = Task<Bool, Never> { [weak self, workspacePath] in
            guard let self else { return false }
            do {
                let discovered = try await client.discoverModels(workspacePath: workspacePath)
                guard !Task.isCancelled else { return false }
                if let discovered {
                    await applyRefreshResult(discovered)
                } else if configuration.publishLiveReadinessWhenDiscoveryReturnsNil {
                    await publishLiveReadinessWithoutModels()
                } else {
                    return false
                }
                return true
            } catch {
                // Keep the last registry/cache snapshot when preflight or ACP discovery fails.
                return false
            }
        }
        inFlightRefresh = task
        defer { inFlightRefresh = nil }
        return await task.value
    }

    private func publishLiveReadinessWithoutModels() {
        guard !isShutdown else { return }
        let providerID = configuration.providerID
        let models = latest?.models
            ?? AgentACPModelRegistry.shared.resolvedSnapshot(for: providerID)
            ?? ACPDiscoveredSessionModels(options: [], currentModelRaw: nil)
        let snapshot = ACPModelPollingSnapshot(models: models, fetchedAt: Date(), isLiveDiscovery: true)
        guard latest?.models != snapshot.models || latest?.isLiveDiscovery == false else { return }
        latest = snapshot
        for continuation in continuations.values {
            continuation.yield(snapshot)
        }
    }

    private func applyRefreshResult(_ discovered: ACPDiscoveredSessionModels) {
        guard !isShutdown else { return }
        let providerID = configuration.providerID
        _ = AgentACPModelRegistry.shared.updateDiscoveredModels(discovered, for: providerID)
        guard let normalized = AgentACPModelRegistry.shared.resolvedSnapshot(for: providerID) else { return }
        let snapshot = ACPModelPollingSnapshot(models: normalized, fetchedAt: Date(), isLiveDiscovery: true)
        guard latest?.models != snapshot.models || latest?.isLiveDiscovery == false else { return }
        latest = snapshot
        for continuation in continuations.values {
            continuation.yield(snapshot)
        }
    }

    private func registrySnapshotAfterWarmingStore() async -> ACPModelPollingSnapshot? {
        guard let models = await AgentACPModelRegistry.shared.resolvedSnapshotAfterWarmingStandardStore(
            for: configuration.providerID
        ) else {
            return nil
        }
        return ACPModelPollingSnapshot(models: models, fetchedAt: Date(), isLiveDiscovery: false)
    }

    private func normalizedWorkspacePath(_ path: String?) -> String? {
        guard let trimmed = path?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: trimmed).standardizedFileURL.path
    }
}
