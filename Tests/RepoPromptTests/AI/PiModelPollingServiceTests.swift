@testable import RepoPrompt
import XCTest

final class PiModelPollingServiceTests: XCTestCase {
    override func tearDown() {
        AgentPiModelRegistry.shared.test_reset()
        super.tearDown()
    }

    func testSuccessfulRefreshAfterFailurePublishesSameModelSnapshot() async throws {
        let models = Self.models(rawValue: "zai/glm-5.1", displayName: "GLM 5.1")
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

    func testWorkspaceScopedPollingDoesNotCrossContaminateSubscribersOrRegistry() async throws {
        let workspaceA = "/tmp/pi-model-polling-a"
        let workspaceB = "/tmp/pi-model-polling-b"
        let modelsA = Self.models(rawValue: "workspace-a/model", displayName: "Workspace A Model")
        let modelsB = Self.models(rawValue: "workspace-b/model", displayName: "Workspace B Model")
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
                    rawValue: AgentModel.defaultModel.rawValue,
                    displayName: "Default",
                    description: "Use pi's configured default model.",
                    isDefault: true
                ),
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
