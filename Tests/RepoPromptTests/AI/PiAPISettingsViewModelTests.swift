@testable import RepoPrompt
import XCTest

@MainActor
final class PiAPISettingsViewModelTests: XCTestCase {
    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "PiCLIConnected")
    }

    override func tearDown() {
        AgentPiModelRegistry.shared.test_reset()
        UserDefaults.standard.removeObject(forKey: "PiCLIConnected")
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
        XCTAssertEqual(viewModel.availablePiModelOptions.map(\.rawValue), ["zai/glm-5.2"])
        XCTAssertEqual(
            AgentModelCatalog.options(for: .pi, availability: viewModel.agentModeAvailabilityContext).map(\.rawValue),
            ["zai/glm-5.2"]
        )
        let didPublishOracleModels = await eventually {
            viewModel.availableModels.filter { $0.providerType == .pi }.map(\.rawValue) == ["pi_custom_zai/glm-5.2"]
        }
        XCTAssertTrue(didPublishOracleModels)
        let discoveryCount = await polling.discoveryCount()
        XCTAssertEqual(discoveryCount, 1)
        XCTAssertTrue(UserDefaults.standard.bool(forKey: "PiCLIConnected"))
    }

    func testLoadAllKeysDoesNotAutoProbePiBeforeUserConnects() async {
        let polling = FakePiModelPolling(snapshot: Self.piSnapshot())
        let viewModel = makeViewModel(polling: polling)

        await viewModel.loadAllKeys()
        let stayedIdle = await remainsTrue {
            let discoveryCount = await polling.discoveryCount()
            let subscriptionCount = await polling.subscriptionCount()
            return discoveryCount == 0 && subscriptionCount == 0
        }

        XCTAssertTrue(stayedIdle)
        XCTAssertFalse(viewModel.isPiConnected)
        XCTAssertFalse(viewModel.agentModeAvailabilityContext.piAvailable)
        XCTAssertEqual(viewModel.availablePiModelOptions, [])
        let discoveryCount = await polling.discoveryCount()
        let subscriptionCount = await polling.subscriptionCount()
        XCTAssertEqual(discoveryCount, 0)
        XCTAssertEqual(subscriptionCount, 0)
    }

    func testLoadAllKeysRefreshesPiOnlyAfterUserConnected() async {
        UserDefaults.standard.set(true, forKey: "PiCLIConnected")
        let polling = FakePiModelPolling(snapshot: Self.piSnapshot())
        let viewModel = makeViewModel(polling: polling)

        await viewModel.loadAllKeys()
        let didConnect = await eventually { !viewModel.availablePiModelOptions.isEmpty }

        XCTAssertTrue(didConnect)
        XCTAssertTrue(viewModel.agentModeAvailabilityContext.piAvailable)
        XCTAssertEqual(viewModel.availablePiModelOptions.map(\.rawValue), ["zai/glm-5.2"])
        let discoveryCount = await polling.discoveryCount()
        XCTAssertEqual(discoveryCount, 1)
    }

    func testPiConnectionFlagReloadsExternalDefaultChanges() async {
        let polling = FakePiModelPolling(snapshot: Self.piSnapshot())
        let viewModel = makeViewModel(polling: polling)

        UserDefaults.standard.set(true, forKey: "PiCLIConnected")
        viewModel.test_reloadCLIConnectionFlagsFromDefaults()
        let didConnect = await eventually { !viewModel.availablePiModelOptions.isEmpty }

        XCTAssertTrue(didConnect)
        XCTAssertTrue(viewModel.isPiConnected)
        let discoveryCount = await polling.discoveryCount()
        XCTAssertEqual(discoveryCount, 1)

        UserDefaults.standard.set(false, forKey: "PiCLIConnected")
        viewModel.test_reloadCLIConnectionFlagsFromDefaults()
        let didDisconnect = await eventually { !viewModel.isPiConnected }

        XCTAssertTrue(didDisconnect)
        XCTAssertEqual(viewModel.availablePiModelOptions, [])
    }

    func testDisconnectPiPersistsOptOutAcrossSettingsReload() async throws {
        let polling = FakePiModelPolling(snapshot: Self.piSnapshot())
        let viewModel = makeViewModel(polling: polling)
        _ = try await viewModel.testPiConnection()
        XCTAssertTrue(UserDefaults.standard.bool(forKey: "PiCLIConnected"))

        viewModel.disconnectPi()
        let reloadedViewModel = makeViewModel(polling: polling)
        await reloadedViewModel.loadAllKeys()
        let stayedIdle = await remainsTrue {
            let discoveryCount = await polling.discoveryCount()
            let subscriptionCount = await polling.subscriptionCount()
            return discoveryCount == 1 && subscriptionCount == 1
        }

        XCTAssertTrue(stayedIdle)
        XCTAssertFalse(reloadedViewModel.isPiConnected)
        XCTAssertFalse(UserDefaults.standard.bool(forKey: "PiCLIConnected"))
        XCTAssertEqual(reloadedViewModel.availablePiModelOptions, [])
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
        let didClearOracleModels = await eventually { viewModel.availableModels.filter { $0.providerType == .pi }.isEmpty }
        XCTAssertTrue(didClearOracleModels)
        XCTAssertEqual(viewModel.piError, "pi executable was not found.")
        let discoveryCount = await polling.discoveryCount()
        XCTAssertEqual(discoveryCount, 1)
    }

    func testContextBuilderStartupValidationVerifiesPersistedPiConnectionAndStartsPolling() async {
        UserDefaults.standard.set(true, forKey: "PiCLIConnected")
        let polling = FakePiModelPolling(snapshot: Self.piSnapshot())
        let viewModel = makeViewModel(polling: polling)

        XCTAssertTrue(viewModel.isPiConnected)
        XCTAssertFalse(viewModel.contextBuilderRestorationAvailabilityContext.piAvailable)

        await viewModel.validateCachedContextBuilderProvidersIfNeeded()

        XCTAssertTrue(viewModel.contextBuilderRestorationAvailabilityContext.piAvailable)
        XCTAssertEqual(viewModel.recommendationProviderStatusSnapshot.piCLI, .ready)
        XCTAssertEqual(viewModel.availablePiModelOptions.map(\.rawValue), ["zai/glm-5.2"])
        let discoveryCount = await polling.discoveryCount()
        let subscriptionCount = await polling.subscriptionCount()
        XCTAssertEqual(discoveryCount, 1)
        XCTAssertEqual(subscriptionCount, 1)
    }

    func testPiAvailabilityPreflightStartsSubscriptionAfterSuccessfulDiscovery() async {
        let polling = FakePiModelPolling(snapshot: Self.piSnapshot())
        let viewModel = makeViewModel(polling: polling)

        viewModel.test_startPiAvailabilityPreflightIfNeeded()

        let didConnect = await eventually { viewModel.isPiConnected }

        XCTAssertTrue(didConnect)
        XCTAssertTrue(viewModel.agentModeAvailabilityContext.piAvailable)
        XCTAssertEqual(viewModel.availablePiModelOptions.map(\.rawValue), ["zai/glm-5.2"])
        let discoveryCount = await polling.discoveryCount()
        let subscriptionCount = await polling.subscriptionCount()
        XCTAssertEqual(discoveryCount, 1)
        XCTAssertEqual(subscriptionCount, 1)
    }

    func testPiModelsSubscriptionResubscribesWhenWorkspacePathChanges() async throws {
        let polling = FakePiModelPolling(snapshot: Self.piSnapshot())
        let viewModel = makeViewModel(polling: polling)
        let workspaceA = "/tmp/pi-settings-workspace-a"
        let workspaceB = "/tmp/pi-settings-workspace-b"
        let canonicalA = try XCTUnwrap(AgentPiModelRegistry.canonicalWorkspacePath(workspaceA))
        let canonicalB = try XCTUnwrap(AgentPiModelRegistry.canonicalWorkspacePath(workspaceB))

        viewModel.test_startPiAvailabilityPreflightIfNeeded(workspacePath: workspaceA)
        let didSubscribeToA = await eventually {
            await polling.subscriptionWorkspacePaths() == [canonicalA]
        }
        XCTAssertTrue(didSubscribeToA)
        XCTAssertEqual(viewModel.test_piModelsSubscribedWorkspacePath, canonicalA)

        viewModel.test_startPiAvailabilityPreflightIfNeeded(workspacePath: workspaceB)
        let didSubscribeToB = await eventually {
            await polling.subscriptionWorkspacePaths() == [canonicalA, canonicalB]
        }
        XCTAssertTrue(didSubscribeToB)
        XCTAssertEqual(viewModel.test_piModelsSubscribedWorkspacePath, canonicalB)

        viewModel.test_startPiAvailabilityPreflightIfNeeded(workspacePath: workspaceB)
        let stayedSingleSubscriptionForB = await remainsTrue {
            await polling.subscriptionWorkspacePaths() == [canonicalA, canonicalB]
        }
        XCTAssertTrue(stayedSingleSubscriptionForB)
    }

    func testPiBackgroundPollingFailureClearsAvailabilityAndStaleModels() async throws {
        let polling = FakePiModelPolling(snapshot: Self.piSnapshot())
        let viewModel = makeViewModel(polling: polling)

        _ = try await viewModel.testPiConnection()
        XCTAssertTrue(viewModel.isPiConnected)
        XCTAssertFalse(viewModel.availablePiModelOptions.isEmpty)

        await polling.emitSubscriptionFailure(message: "pi RPC model refresh failed")
        let didDisconnect = await eventually { !viewModel.isPiConnected }

        XCTAssertTrue(didDisconnect)
        XCTAssertFalse(viewModel.agentModeAvailabilityContext.piAvailable)
        XCTAssertEqual(viewModel.availablePiModelOptions, [])
        let didClearOracleModels = await eventually { viewModel.availableModels.filter { $0.providerType == .pi }.isEmpty }
        XCTAssertTrue(didClearOracleModels)
        XCTAssertEqual(viewModel.piError, "pi RPC model refresh failed")

        await polling.emitSubscriptionSnapshot(Self.piSnapshot())
        let didRecover = await eventually { viewModel.isPiConnected }
        XCTAssertTrue(didRecover)
        XCTAssertTrue(viewModel.agentModeAvailabilityContext.piAvailable)
        XCTAssertEqual(viewModel.availablePiModelOptions.map(\.rawValue), ["zai/glm-5.2"])
        XCTAssertNil(viewModel.piError)
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
                        rawValue: "zai/glm-5.2",
                        displayName: "GLM 5.2",
                        description: "Strong GLM",
                        isDefault: true
                    )
                ],
                currentModelRaw: "zai/glm-5.2"
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

    private func remainsTrue(
        duration: TimeInterval = 0.15,
        condition: @escaping () async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(duration)
        while Date() < deadline {
            guard await condition() else { return false }
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
    private var pendingEvents: [PiModelPollingService.Event] = []
    private var eventContinuations: [AsyncStream<PiModelPollingService.Event>.Continuation] = []
    private var subscriptionPaths: [String?] = []

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
            _ = AgentPiModelRegistry.shared.updateDiscoveredModels(snapshot.models, workspacePath: workspacePath)
        }
        return snapshot
    }

    func subscribe(workspacePath: String?) async -> AsyncStream<PiModelPollingService.Event> {
        subscribeCallCount += 1
        subscriptionPaths.append(AgentPiModelRegistry.canonicalWorkspacePath(workspacePath))
        let snapshot = snapshot
        return AsyncStream { continuation in
            if let snapshot {
                continuation.yield(.snapshot(snapshot))
            }
            for event in pendingEvents {
                continuation.yield(event)
            }
            pendingEvents.removeAll()
            eventContinuations.append(continuation)
        }
    }

    func emitSubscriptionFailure(message: String) {
        emit(.failure(.init(message: message)))
    }

    func emitSubscriptionSnapshot(_ snapshot: PiModelPollingService.Snapshot) {
        emit(.snapshot(snapshot))
    }

    private func emit(_ event: PiModelPollingService.Event) {
        if eventContinuations.isEmpty {
            pendingEvents.append(event)
            return
        }
        for continuation in eventContinuations {
            continuation.yield(event)
        }
    }

    func discoveryCount() -> Int {
        discoverCallCount
    }

    func subscriptionCount() -> Int {
        subscribeCallCount
    }

    func subscriptionWorkspacePaths() -> [String?] {
        subscriptionPaths
    }
}
