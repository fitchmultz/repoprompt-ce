@testable import RepoPrompt
import XCTest

final class PiModelPollingServiceTests: XCTestCase {
    override func tearDown() {
        AgentPiModelRegistry.shared.test_reset()
        super.tearDown()
    }

    func testSuccessfulRefreshAfterFailurePublishesSameModelSnapshot() async throws {
        let models = Self.models(rawValue: "zai/glm-5.2", displayName: "GLM 5.2")
        let client = SequencedPiModelDiscoveryClient(results: [
            .success(models),
            .failure(PollingError(message: "pi RPC temporarily failed")),
            .success(models)
        ])
        let service = PiModelPollingService(
            client: client,
            intervalNanos: 3_600_000_000_000,
            startsPollingOnSubscribe: false
        )
        let recorder = PiPollingEventRecorder()

        _ = try await service.discoverOnce(workspacePath: nil)
        let stream = await service.subscribe(workspacePath: nil)
        let collector = Task {
            for await event in stream {
                await recorder.append(event)
            }
        }
        defer {
            collector.cancel()
            Task { await service.shutdown() }
        }

        let initial = try await nextEvent(from: recorder)
        guard case let .snapshot(initialSnapshot) = initial else {
            XCTFail("expected initial snapshot, got \(initial)")
            return
        }
        XCTAssertEqual(initialSnapshot.models, models)

        await service.refreshNow(workspacePath: nil)

        let failure = try await nextEvent(from: recorder)
        guard case let .failure(failurePayload) = failure else {
            XCTFail("expected failure, got \(failure)")
            return
        }
        XCTAssertEqual(failurePayload.message, "pi RPC temporarily failed")

        await service.refreshNow(workspacePath: nil)

        let recovered = try await nextEvent(from: recorder)
        guard case let .snapshot(recoveredSnapshot) = recovered else {
            XCTFail("expected recovery snapshot, got \(recovered)")
            return
        }
        XCTAssertEqual(recoveredSnapshot.models, models)
        await service.shutdown()
        await collector.value
    }

    func testConcurrentDiscoverOnceCallsShareSingleInFlightPiProcessPerWorkspace() async throws {
        let models = Self.models(rawValue: "zai/glm-5.2", displayName: "GLM 5.2")
        let client = DelayedCountingPiModelDiscoveryClient(models: models, delayNanoseconds: 150_000_000)
        let service = PiModelPollingService(
            client: client,
            intervalNanos: 3_600_000_000_000,
            startsPollingOnSubscribe: false
        )
        defer { Task { await service.shutdown() } }

        try await withThrowingTaskGroup(of: PiModelPollingService.Snapshot?.self) { group in
            for _ in 0 ..< 20 {
                group.addTask {
                    try await service.discoverOnce(workspacePath: nil)
                }
            }
            for try await snapshot in group {
                XCTAssertEqual(snapshot?.models, models)
            }
        }

        let callCount = await client.callCount()
        XCTAssertEqual(callCount, 1)
    }

    func testLaunchPolicyResetCancelsInFlightRefreshAndForcesFreshDiscovery() async throws {
        let oldModels = Self.models(rawValue: "extension-provider/old-model", displayName: "Old Extension Model")
        let newModels = Self.models(rawValue: "zai/glm-5.2", displayName: "GLM 5.2")
        let client = SuspendedPiModelDiscoveryClient()
        let service = PiModelPollingService(
            client: client,
            intervalNanos: 3_600_000_000_000,
            startsPollingOnSubscribe: false
        )
        defer { Task { await service.shutdown() } }

        let firstDiscovery = Task { try await service.discoverOnce(workspacePath: nil) }
        guard await client.waitUntilCallCount(1) else {
            firstDiscovery.cancel()
            XCTFail("Expected first pi model discovery to start.")
            return
        }
        XCTAssertEqual(AgentPiModelRegistry.shared.catalogState(), .loading)

        await service.resetModelDiscoveryStateForLaunchPolicyChange()
        let secondDiscovery = Task { try await service.discoverOnce(workspacePath: nil) }
        guard await client.waitUntilCallCount(2) else {
            firstDiscovery.cancel()
            secondDiscovery.cancel()
            XCTFail("Expected launch-policy reset to force a fresh pi model discovery instead of awaiting the old in-flight refresh.")
            return
        }

        await client.resumeCall(index: 0, with: .success(oldModels))
        let firstSnapshot = try await firstDiscovery.value
        XCTAssertNil(firstSnapshot, "Cancelled pre-policy-change discovery must not apply or return stale models.")
        XCTAssertNil(AgentPiModelRegistry.shared.resolvedSnapshot())

        await client.resumeCall(index: 1, with: .success(newModels))
        let secondSnapshot = try await secondDiscovery.value
        XCTAssertEqual(secondSnapshot?.models, newModels)
        XCTAssertEqual(AgentPiModelRegistry.shared.resolvedSnapshot(), newModels)
    }

    func testLaunchPolicyResetSuppressesStaleApplyAlreadyQueuedBeforeReset() async throws {
        let oldModels = Self.models(rawValue: "extension-provider/old-model", displayName: "Old Extension Model")
        let newModels = Self.models(rawValue: "zai/glm-5.2", displayName: "GLM 5.2")
        let client = SuspendedPiModelDiscoveryClient()
        let service = PiModelPollingService(
            client: client,
            intervalNanos: 3_600_000_000_000,
            startsPollingOnSubscribe: false
        )
        let recorder = PiPollingEventRecorder()
        let gate = ApplyPauseGate()
        await service.test_setBeforeApplyRefreshResultHook { _, _ in
            await gate.pauseFirstApply()
        }
        let stream = await service.subscribe(workspacePath: nil)
        let collector = Task {
            for await event in stream {
                await recorder.append(event)
            }
        }
        defer {
            collector.cancel()
            Task {
                await service.test_setBeforeApplyRefreshResultHook(nil)
                await service.shutdown()
            }
        }

        let firstDiscovery = Task { try await service.discoverOnce(workspacePath: nil) }
        guard await client.waitUntilCallCount(1) else {
            firstDiscovery.cancel()
            XCTFail("Expected first pi model discovery to start.")
            return
        }
        await client.resumeCall(index: 0, with: .success(oldModels))
        guard await gate.waitUntilPaused() else {
            firstDiscovery.cancel()
            XCTFail("Expected first discovery to pause after discovery returned but before apply.")
            return
        }

        await service.resetModelDiscoveryStateForLaunchPolicyChange()
        let secondDiscovery = Task { try await service.discoverOnce(workspacePath: nil) }
        guard await client.waitUntilCallCount(2) else {
            firstDiscovery.cancel()
            secondDiscovery.cancel()
            XCTFail("Expected reset to force a fresh discovery while old apply is paused.")
            return
        }
        await client.resumeCall(index: 1, with: .success(newModels))

        let event = try await nextEvent(from: recorder)
        guard case let .snapshot(publishedSnapshot) = event else {
            XCTFail("Expected fresh post-reset snapshot, got \(event)")
            return
        }
        XCTAssertEqual(publishedSnapshot.models, newModels)
        let secondSnapshot = try await secondDiscovery.value
        XCTAssertEqual(secondSnapshot?.models, newModels)

        await gate.release()
        let firstSnapshot = try await firstDiscovery.value
        XCTAssertEqual(firstSnapshot?.models, newModels)
        XCTAssertEqual(AgentPiModelRegistry.shared.resolvedSnapshot(), newModels)
        let didSuppressStaleApply = await recorder.isEmpty()
        XCTAssertTrue(didSuppressStaleApply, "Queued pre-policy-change apply must not publish stale models after reset.")
    }

    func testLaunchPolicyResetSuppressesStalePollingRefreshFailure() async {
        let client = SuspendedPiModelDiscoveryClient()
        let service = PiModelPollingService(
            client: client,
            intervalNanos: 3_600_000_000_000,
            startsPollingOnSubscribe: false
        )
        let recorder = PiPollingEventRecorder()
        let stream = await service.subscribe(workspacePath: nil)
        let collector = Task {
            for await event in stream {
                await recorder.append(event)
            }
        }
        defer {
            collector.cancel()
            Task { await service.shutdown() }
        }

        let staleRefresh = Task { await service.refreshNow(workspacePath: nil) }
        guard await client.waitUntilCallCount(1) else {
            staleRefresh.cancel()
            XCTFail("Expected first pi model refresh to start.")
            return
        }

        await service.resetModelDiscoveryStateForLaunchPolicyChange()
        await client.resumeCall(index: 0, with: .failure(PollingError(message: "old policy polling refresh failed")))
        await staleRefresh.value

        XCTAssertNil(AgentPiModelRegistry.shared.resolvedSnapshot())
        let didSuppressStaleFailure = await recorder.isEmpty()
        XCTAssertTrue(didSuppressStaleFailure, "Canceled pre-policy-change polling failures must not publish stale failure events.")
    }

    func testLaunchPolicyResetSuppressesStaleInFlightFailure() async throws {
        let newModels = Self.models(rawValue: "zai/glm-5.2", displayName: "GLM 5.2")
        let client = SuspendedPiModelDiscoveryClient()
        let service = PiModelPollingService(
            client: client,
            intervalNanos: 3_600_000_000_000,
            startsPollingOnSubscribe: false
        )
        let recorder = PiPollingEventRecorder()
        let stream = await service.subscribe(workspacePath: nil)
        let collector = Task {
            for await event in stream {
                await recorder.append(event)
            }
        }
        defer {
            collector.cancel()
            Task { await service.shutdown() }
        }

        let firstDiscovery = Task { try await service.discoverOnce(workspacePath: nil) }
        guard await client.waitUntilCallCount(1) else {
            firstDiscovery.cancel()
            XCTFail("Expected first pi model discovery to start.")
            return
        }

        await service.resetModelDiscoveryStateForLaunchPolicyChange()
        let secondDiscovery = Task { try await service.discoverOnce(workspacePath: nil) }
        guard await client.waitUntilCallCount(2) else {
            firstDiscovery.cancel()
            secondDiscovery.cancel()
            XCTFail("Expected reset to force a new discovery before old failure resolves.")
            return
        }

        await client.resumeCall(index: 1, with: .success(newModels))
        let secondSnapshot = try await secondDiscovery.value
        XCTAssertEqual(secondSnapshot?.models, newModels)
        let event = try await nextEvent(from: recorder)
        guard case let .snapshot(publishedSnapshot) = event else {
            XCTFail("Expected fresh post-reset snapshot, got \(event)")
            return
        }
        XCTAssertEqual(publishedSnapshot.models, newModels)

        await client.resumeCall(index: 0, with: .failure(PollingError(message: "old policy discovery failed")))
        let staleResult = try await firstDiscovery.value
        XCTAssertEqual(staleResult?.models, newModels)
        XCTAssertEqual(AgentPiModelRegistry.shared.resolvedSnapshot(), newModels)
        let didSuppressStaleFailure = await recorder.isEmpty()
        XCTAssertTrue(didSuppressStaleFailure, "Canceled pre-policy-change failures must not publish stale failure events.")
    }

    func testRefreshRecordsRegistryLoadingAndUnavailableStates() async throws {
        let workspace = "/tmp/pi-model-polling-state"
        let client = DelayedNilPiModelDiscoveryClient(delayNanoseconds: 150_000_000)
        let service = PiModelPollingService(
            client: client,
            intervalNanos: 3_600_000_000_000,
            startsPollingOnSubscribe: false
        )
        defer { Task { await service.shutdown() } }

        let refresh = Task { try await service.discoverOnce(workspacePath: workspace) }
        await client.waitUntilCalled()
        XCTAssertEqual(AgentPiModelRegistry.shared.catalogState(workspacePath: workspace), .loading)

        let snapshot = try await refresh.value
        XCTAssertNil(snapshot)
        XCTAssertEqual(AgentPiModelRegistry.shared.catalogState(workspacePath: workspace), .unavailable)
    }

    func testWorkspaceScopedPollingDoesNotCrossContaminateSubscribersOrRegistry() async throws {
        let workspaceA = "/tmp/pi-model-polling-a"
        let workspaceB = "/tmp/pi-model-polling-b"
        let modelsA = Self.models(rawValue: "openai-codex/gpt-5.4", displayName: "GPT 5.4")
        let modelsB = Self.models(rawValue: "deepseek/deepseek-v4-flash", displayName: "DeepSeek V4 Flash")
        let client = WorkspaceSequencedPiModelDiscoveryClient(resultsByWorkspacePath: [
            workspaceA: [.success(modelsA)],
            workspaceB: [.success(modelsB)]
        ])
        let service = PiModelPollingService(
            client: client,
            intervalNanos: 3_600_000_000_000,
            startsPollingOnSubscribe: false
        )
        let recorderA = PiPollingEventRecorder()
        let recorderB = PiPollingEventRecorder()

        let discoveredA = try await service.discoverOnce(workspacePath: workspaceA)
        XCTAssertEqual(discoveredA?.models, modelsA)
        XCTAssertEqual(AgentPiModelRegistry.shared.resolvedSnapshot(workspacePath: workspaceA), modelsA)
        XCTAssertNil(AgentPiModelRegistry.shared.resolvedSnapshot(workspacePath: workspaceB))

        let streamA = await service.subscribe(workspacePath: workspaceA)
        let collectorA = Task {
            for await event in streamA {
                await recorderA.append(event)
            }
        }
        let streamB = await service.subscribe(workspacePath: workspaceB)
        let collectorB = Task {
            for await event in streamB {
                await recorderB.append(event)
            }
        }
        defer {
            collectorA.cancel()
            collectorB.cancel()
            Task { await service.shutdown() }
        }

        let initialA = try await nextEvent(from: recorderA)
        guard case let .snapshot(initialSnapshotA) = initialA else {
            XCTFail("expected workspace A snapshot, got \(initialA)")
            return
        }
        XCTAssertEqual(initialSnapshotA.models, modelsA)
        let eventCountBBeforeRefresh = await service.test_publishedEventCount(workspacePath: workspaceB)
        XCTAssertEqual(eventCountBBeforeRefresh, 0, "Workspace B subscription must not receive workspace A's cached snapshot")

        await service.refreshNow(workspacePath: workspaceB)

        let initialB = try await nextEvent(from: recorderB)
        guard case let .snapshot(initialSnapshotB) = initialB else {
            XCTFail("expected workspace B snapshot, got \(initialB)")
            return
        }
        XCTAssertEqual(initialSnapshotB.models, modelsB)
        let eventCountAAfterRefreshB = await service.test_publishedEventCount(workspacePath: workspaceA)
        XCTAssertEqual(eventCountAAfterRefreshB, 1, "Workspace A subscription must not receive workspace B's refresh")
        let latestA = await service.latestSnapshot(workspacePath: workspaceA)?.models
        let latestB = await service.latestSnapshot(workspacePath: workspaceB)?.models
        XCTAssertEqual(latestA, modelsA)
        XCTAssertEqual(latestB, modelsB)
        XCTAssertEqual(AgentPiModelRegistry.shared.resolvedSnapshot(workspacePath: workspaceA), modelsA)
        XCTAssertEqual(AgentPiModelRegistry.shared.resolvedSnapshot(workspacePath: workspaceB), modelsB)

        await service.shutdown()
        await collectorA.value
        await collectorB.value
    }

    private static func models(rawValue: String, displayName: String) -> PiDiscoveredModels {
        PiDiscoveredModels(
            options: [
                AgentModelOption(
                    rawValue: rawValue,
                    displayName: displayName,
                    description: nil,
                    isDefault: true
                )
            ],
            currentModelRaw: rawValue
        )
    }

    private func nextEvent(
        from recorder: PiPollingEventRecorder,
        timeoutSeconds: Double = 2
    ) async throws -> PiModelPollingService.Event {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if let event = await recorder.removeFirst() {
                return event
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw PollingError(message: "timed out waiting for pi polling event")
    }
}

private actor PiPollingEventRecorder {
    private var events: [PiModelPollingService.Event] = []

    func append(_ event: PiModelPollingService.Event) {
        events.append(event)
    }

    func removeFirst() -> PiModelPollingService.Event? {
        guard !events.isEmpty else { return nil }
        return events.removeFirst()
    }

    func isEmpty() -> Bool {
        events.isEmpty
    }
}

private actor ApplyPauseGate {
    private var didPause = false
    private var isReleased = false

    func pauseFirstApply() async {
        guard !didPause else { return }
        didPause = true
        while !isReleased {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    func waitUntilPaused() async -> Bool {
        let deadline = Date().addingTimeInterval(2)
        while !didPause, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return didPause
    }

    func release() {
        isReleased = true
    }
}

private actor SuspendedPiModelDiscoveryClient: PiModelDiscoveryClient {
    private var continuations: [CheckedContinuation<PiDiscoveredModels?, Error>] = []

    func discoverModels(workspacePath: String?) async throws -> PiDiscoveredModels? {
        _ = workspacePath
        return try await withCheckedThrowingContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func waitUntilCallCount(_ expectedCount: Int) async -> Bool {
        let deadline = Date().addingTimeInterval(2)
        while continuations.count < expectedCount, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return continuations.count >= expectedCount
    }

    func resumeCall(index: Int, with result: Result<PiDiscoveredModels?, Error>) {
        guard continuations.indices.contains(index) else { return }
        let continuation = continuations[index]
        switch result {
        case let .success(models):
            continuation.resume(returning: models)
        case let .failure(error):
            continuation.resume(throwing: error)
        }
    }
}

private actor DelayedCountingPiModelDiscoveryClient: PiModelDiscoveryClient {
    private let models: PiDiscoveredModels
    private let delayNanoseconds: UInt64
    private var calls = 0

    init(models: PiDiscoveredModels, delayNanoseconds: UInt64) {
        self.models = models
        self.delayNanoseconds = delayNanoseconds
    }

    func discoverModels(workspacePath: String?) async throws -> PiDiscoveredModels? {
        _ = workspacePath
        calls += 1
        try await Task.sleep(nanoseconds: delayNanoseconds)
        return models
    }

    func callCount() -> Int {
        calls
    }
}

private actor DelayedNilPiModelDiscoveryClient: PiModelDiscoveryClient {
    private let delayNanoseconds: UInt64
    private var calls = 0

    init(delayNanoseconds: UInt64) {
        self.delayNanoseconds = delayNanoseconds
    }

    func discoverModels(workspacePath: String?) async throws -> PiDiscoveredModels? {
        _ = workspacePath
        calls += 1
        try await Task.sleep(nanoseconds: delayNanoseconds)
        return nil
    }

    func waitUntilCalled() async {
        while calls == 0 {
            await Task.yield()
        }
    }
}

private actor SequencedPiModelDiscoveryClient: PiModelDiscoveryClient {
    private var results: [Result<PiDiscoveredModels, Error>]

    init(results: [Result<PiDiscoveredModels, Error>]) {
        self.results = results
    }

    func discoverModels(workspacePath: String?) async throws -> PiDiscoveredModels? {
        _ = workspacePath
        guard !results.isEmpty else { return nil }
        let result = results.removeFirst()
        switch result {
        case let .success(models):
            return models
        case let .failure(error):
            throw error
        }
    }
}

private actor WorkspaceSequencedPiModelDiscoveryClient: PiModelDiscoveryClient {
    private var resultsByWorkspacePath: [String: [Result<PiDiscoveredModels, Error>]]

    init(resultsByWorkspacePath: [String: [Result<PiDiscoveredModels, Error>]]) {
        var canonicalResults: [String: [Result<PiDiscoveredModels, Error>]] = [:]
        for (workspacePath, results) in resultsByWorkspacePath {
            let key = AgentPiModelRegistry.canonicalWorkspacePath(workspacePath) ?? ""
            canonicalResults[key] = results
        }
        self.resultsByWorkspacePath = canonicalResults
    }

    func discoverModels(workspacePath: String?) async throws -> PiDiscoveredModels? {
        let key = AgentPiModelRegistry.canonicalWorkspacePath(workspacePath) ?? ""
        guard var results = resultsByWorkspacePath[key], !results.isEmpty else { return nil }
        let result = results.removeFirst()
        resultsByWorkspacePath[key] = results
        switch result {
        case let .success(models):
            return models
        case let .failure(error):
            throw error
        }
    }
}

private struct PollingError: Error, LocalizedError {
    let message: String

    var errorDescription: String? {
        message
    }
}
