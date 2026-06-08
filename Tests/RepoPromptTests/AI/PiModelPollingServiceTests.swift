@testable import RepoPrompt
import XCTest

final class PiModelPollingServiceTests: XCTestCase {
    override func tearDown() {
        AgentPiModelRegistry.shared.test_reset()
        super.tearDown()
    }

    func testSuccessfulRefreshAfterFailurePublishesSameModelSnapshot() async throws {
        let models = Self.models()
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

    private static func models() -> PiDiscoveredModels {
        PiDiscoveredModels(
            options: [
                AgentModelOption(
                    rawValue: AgentModel.defaultModel.rawValue,
                    displayName: "Default",
                    description: "Use pi's configured default model.",
                    isDefault: true
                ),
                AgentModelOption(
                    rawValue: "zai/glm-5.1",
                    displayName: "GLM 5.1",
                    description: nil,
                    isDefault: true
                )
            ],
            currentModelRaw: "zai/glm-5.1"
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

private struct PollingError: Error, LocalizedError {
    let message: String

    var errorDescription: String? {
        message
    }
}
