@testable import RepoPrompt
import XCTest

@MainActor
final class PiAPISettingsViewModelTests: XCTestCase {
    override func tearDown() {
        AgentPiModelRegistry.shared.test_reset()
        super.tearDown()
    }

    func testPiConnectionUsesRPCModelDiscoveryForAvailabilityContext() async throws {
        let polling = FakePiModelPolling(snapshot: Self.piSnapshot())
        let viewModel = makeViewModel(polling: polling)

        XCTAssertFalse(viewModel.isPiConnected)
        XCTAssertFalse(viewModel.agentModeAvailabilityContext.piAvailable)

        let didConnect = try await viewModel.testPiConnection()

        XCTAssertTrue(didConnect)
        XCTAssertTrue(viewModel.isPiConnected)
        XCTAssertTrue(viewModel.agentModeAvailabilityContext.piAvailable)
        XCTAssertNil(viewModel.piError)
        XCTAssertEqual(viewModel.availablePiModelOptions.map(\.rawValue), ["default", "zai/glm-5.1"])
        XCTAssertEqual(
            AgentModelCatalog.options(for: .pi, availability: viewModel.agentModeAvailabilityContext).map(\.rawValue),
            ["default", "zai/glm-5.1"]
        )
        let discoveryCount = await polling.discoveryCount()
        XCTAssertEqual(discoveryCount, 1)
    }

    func testPiConnectionFailureKeepsPiUnavailable() async throws {
        let polling = FakePiModelPolling(error: PiRPCClient.ClientError.executableUnavailable("pi executable was not found."))
        let viewModel = makeViewModel(polling: polling)

        do {
            _ = try await viewModel.testPiConnection()
            XCTFail("Expected pi connection test to throw")
        } catch {
            // Expected.
        }

        XCTAssertFalse(viewModel.isPiConnected)
        XCTAssertFalse(viewModel.agentModeAvailabilityContext.piAvailable)
        XCTAssertEqual(viewModel.availablePiModelOptions, [])
        XCTAssertEqual(viewModel.piError, "pi executable was not found.")
        let discoveryCount = await polling.discoveryCount()
        XCTAssertEqual(discoveryCount, 1)
    }

    func testPiAvailabilityPreflightStartsSubscriptionAfterSuccessfulDiscovery() async {
        let polling = FakePiModelPolling(snapshot: Self.piSnapshot())
        let viewModel = makeViewModel(polling: polling)

        viewModel.test_startPiAvailabilityPreflightIfNeeded()

        let didConnect = await eventually { viewModel.isPiConnected }

        XCTAssertTrue(didConnect)
        XCTAssertTrue(viewModel.agentModeAvailabilityContext.piAvailable)
        XCTAssertEqual(viewModel.availablePiModelOptions.map(\.rawValue), ["default", "zai/glm-5.1"])
        let discoveryCount = await polling.discoveryCount()
        let subscriptionCount = await polling.subscriptionCount()
        XCTAssertEqual(discoveryCount, 1)
        XCTAssertEqual(subscriptionCount, 1)
    }

    func testPiAvailabilityPreflightDoesNotUseCachedModelsWhenDiscoveryFails() async {
        let cached = Self.piSnapshot()
        XCTAssertTrue(AgentPiModelRegistry.shared.updateDiscoveredModels(cached.models))
        let polling = FakePiModelPolling(error: PiRPCClient.ClientError.requestTimedOut(id: "1", command: "get_available_models"))
        let viewModel = makeViewModel(polling: polling)

        viewModel.test_startPiAvailabilityPreflightIfNeeded()

        let didDiscover = await eventually { await polling.discoveryCount() == 1 }

        XCTAssertTrue(didDiscover)
        XCTAssertFalse(viewModel.isPiConnected)
        XCTAssertFalse(viewModel.agentModeAvailabilityContext.piAvailable)
        XCTAssertEqual(viewModel.availablePiModelOptions, [])
        let subscriptionCount = await polling.subscriptionCount()
        XCTAssertEqual(subscriptionCount, 0)
    }

    private func makeViewModel(polling: FakePiModelPolling) -> APISettingsViewModel {
        let keyManager = KeyManager()
        return APISettingsViewModel(
            aiQueriesService: AIQueriesService(keyManager: keyManager),
            keyManager: keyManager,
            loadStoredDataOnInit: false,
            piModelPollingService: polling
        )
    }

    private static func piSnapshot() -> PiModelPollingService.Snapshot {
        PiModelPollingService.Snapshot(
            models: PiDiscoveredModels(
                options: [
                    AgentModelOption(
                        rawValue: "default",
                        displayName: "Default",
                        description: "Use pi's configured default model.",
                        isDefault: true
                    ),
                    AgentModelOption(
                        rawValue: "zai/glm-5.1",
                        displayName: "GLM 5.1",
                        description: "Strong GLM",
                        isDefault: true
                    )
                ],
                currentModelRaw: "zai/glm-5.1"
            ),
            fetchedAt: Date()
        )
    }

    private func eventually(
        timeout: TimeInterval = 1,
        condition: @MainActor @escaping () async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() {
                return true
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return await condition()
    }
}

private actor FakePiModelPolling: PiModelPolling {
    private let snapshot: PiModelPollingService.Snapshot?
    private let error: Error?
    private(set) var discoverCallCount = 0
    private(set) var subscribeCallCount = 0

    init(snapshot: PiModelPollingService.Snapshot? = nil, error: Error? = nil) {
        self.snapshot = snapshot
        self.error = error
    }

    func latestSnapshot() async -> PiModelPollingService.Snapshot? {
        snapshot
    }

    func discoverOnce(workspacePath: String?) async throws -> PiModelPollingService.Snapshot? {
        discoverCallCount += 1
        if let error {
            throw error
        }
        if let snapshot {
            _ = AgentPiModelRegistry.shared.updateDiscoveredModels(snapshot.models)
        }
        return snapshot
    }

    func subscribe(workspacePath: String?) async -> AsyncStream<PiModelPollingService.Snapshot> {
        subscribeCallCount += 1
        let snapshot = snapshot
        return AsyncStream { continuation in
            if let snapshot {
                continuation.yield(snapshot)
            }
        }
    }

    func discoveryCount() -> Int {
        discoverCallCount
    }

    func subscriptionCount() -> Int {
        subscribeCallCount
    }
}
