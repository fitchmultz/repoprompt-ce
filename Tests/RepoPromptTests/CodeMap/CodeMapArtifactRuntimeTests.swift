import Darwin
import Foundation
@testable import RepoPrompt
import RepoPromptShared
import XCTest

final class CodeMapArtifactRuntimeTests: XCTestCase {
    func testPostSuccessfulInitializationIsLazyAndInvokedOnceAfterRuntimeConstruction() throws {
        let applicationSupportRoot = try makeSecureRoot()
        defer { try? FileManager.default.removeItem(at: applicationSupportRoot) }
        let callbackCount = RuntimeProviderTestCounter()
        let runtimeRoot = CodeMapArtifactRuntime.processWideRootURL(
            applicationSupportRootURL: applicationSupportRoot,
            buildFlavor: .debug
        )
        let saltProviderCount = RuntimeProviderTestCounter()
        let provider = CodeMapArtifactRuntime.makeProcessWideProvider(
            identity: .repoPromptCE(.debug),
            applicationSupportRootURL: applicationSupportRoot,
            namespaceSaltProvider: { rootURL, identity in
                XCTAssertEqual(rootURL, runtimeRoot)
                XCTAssertEqual(identity.product, MCPFilesystemIdentity.repoPromptCE(.debug).product)
                XCTAssertEqual(identity.buildFlavor, .debug)
                saltProviderCount.increment()
                return Data(repeating: 0x42, count: GitBlobRepositoryNamespace.saltByteCount)
            },
            postSuccessfulInitialization: { callbackCount.increment() }
        )

        XCTAssertEqual(callbackCount.value, 0)
        XCTAssertEqual(saltProviderCount.value, 0)
        let first = try provider.runtime()
        XCTAssertTrue(FileManager.default.fileExists(atPath: runtimeRoot.path))
        XCTAssertEqual(saltProviderCount.value, 1)
        XCTAssertEqual(callbackCount.value, 1)
        XCTAssertTrue(try provider.runtime() === first)
        XCTAssertEqual(callbackCount.value, 1)
    }

    func testNamespaceSaltProviderFailurePreventsInitializationAndPostCallback() throws {
        struct SentinelError: Error {}

        let applicationSupportRoot = try makeSecureRoot()
        defer { try? FileManager.default.removeItem(at: applicationSupportRoot) }
        let callbackCount = RuntimeProviderTestCounter()
        let provider = CodeMapArtifactRuntime.makeProcessWideProvider(
            identity: .repoPromptCE(.debug),
            applicationSupportRootURL: applicationSupportRoot,
            namespaceSaltProvider: { _, _ in throw SentinelError() },
            postSuccessfulInitialization: { callbackCount.increment() }
        )

        XCTAssertThrowsError(try provider.runtime()) { error in
            XCTAssertTrue(error is SentinelError)
        }
        XCTAssertEqual(callbackCount.value, 0)
    }

    func testRuntimeProviderLazilyMemoizesOneInstanceAcrossConcurrentCallers() throws {
        let root = try makeSecureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let callerCount = 16
        let factoryCount = RuntimeProviderTestCounter()
        let results = RuntimeProviderTestResults()
        let overlapGate = RuntimeProviderOverlapGate(expectedCallerCount: callerCount)
        let provider = CodeMapArtifactRuntimeProvider {
            factoryCount.increment()
            overlapGate.factoryEnteredAndWaitForRelease()
            return try CodeMapArtifactRuntime(
                rootURL: root,
                builder: CodeMapArtifactBuilderClient(build: { _, _, _ in .readyNoSymbols })
            )
        }

        let callers = startProviderCallers(
            count: callerCount,
            provider: provider,
            overlapGate: overlapGate,
            results: results
        )
        XCTAssertTrue(overlapGate.waitForDeterministicOverlap())
        overlapGate.releaseFactory()
        XCTAssertEqual(callers.wait(timeout: .now() + 10), .success)

        let snapshot = results.snapshot()
        XCTAssertEqual(factoryCount.value, 1)
        XCTAssertEqual(snapshot.runtimes.count, callerCount)
        XCTAssertTrue(snapshot.errors.isEmpty)
        let first = try XCTUnwrap(snapshot.runtimes.first)
        XCTAssertTrue(snapshot.runtimes.allSatisfy { $0 === first })
        XCTAssertTrue(try provider.runtime() === first)
    }

    func testProcessWideRootDerivationSeparatesFlavorsAndReservedNamespaces() {
        let applicationSupportRoot = URL(
            fileURLWithPath: "/synthetic/Library/Application Support/RepoPrompt CE",
            isDirectory: true
        )
        let debugRoot = CodeMapArtifactRuntime.processWideRootURL(
            applicationSupportRootURL: applicationSupportRoot,
            buildFlavor: .debug
        )
        let releaseRoot = CodeMapArtifactRuntime.processWideRootURL(
            applicationSupportRootURL: applicationSupportRoot,
            buildFlavor: .release
        )

        XCTAssertEqual(
            debugRoot,
            applicationSupportRoot.appendingPathComponent("CodeMapArtifactRuntime-debug", isDirectory: true)
        )
        XCTAssertEqual(
            releaseRoot,
            applicationSupportRoot.appendingPathComponent("CodeMapArtifactRuntime-release", isDirectory: true)
        )
        XCTAssertNotEqual(debugRoot, releaseRoot)
    }

    func testRuntimeOwnsExactInertRootManifestStore() async throws {
        let root = try makeSecureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = try CodeMapArtifactRuntime(
            rootURL: root,
            builder: CodeMapArtifactBuilderClient(build: { _, _, _ in .readyNoSymbols })
        )
        let manifestStore = runtime.manifestStore

        XCTAssertTrue(runtime.manifestStore === manifestStore)
        let accounting = try await manifestStore.accounting()
        XCTAssertEqual(accounting.manifestCount, 0)
        XCTAssertEqual(accounting.recordCount, 0)
        XCTAssertEqual(accounting.manifestByteCount, 0)
    }

    private func makeSecureRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodeMapRuntimeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let resolvedPath = try XCTUnwrap(root.path.withCString { pointer -> String? in
            guard let resolved = realpath(pointer, nil) else { return nil }
            defer { free(resolved) }
            return String(cString: resolved)
        })
        let resolved = URL(fileURLWithPath: resolvedPath, isDirectory: true)
        XCTAssertEqual(chmod(resolved.path, 0o700), 0)
        return resolved
    }
}

private final class RuntimeProviderTestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}

private final class RuntimeProviderTestResults: @unchecked Sendable {
    struct Snapshot {
        let runtimes: [CodeMapArtifactRuntime]
        let errors: [Error]
    }

    private let lock = NSLock()
    private var runtimes: [CodeMapArtifactRuntime] = []
    private var errors: [Error] = []

    func record(runtime: CodeMapArtifactRuntime) {
        lock.lock()
        runtimes.append(runtime)
        lock.unlock()
    }

    func record(error: Error) {
        lock.lock()
        errors.append(error)
        lock.unlock()
    }

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(runtimes: runtimes, errors: errors)
    }
}

private final class RuntimeProviderOverlapGate: @unchecked Sendable {
    private let condition = NSCondition()
    private let expectedCallerCount: Int
    private var callerCount = 0
    private var factoryEntryCount = 0
    private var released = false

    init(expectedCallerCount: Int) {
        self.expectedCallerCount = expectedCallerCount
    }

    func factoryEnteredAndWaitForRelease() {
        condition.lock()
        factoryEntryCount += 1
        while !released {
            condition.wait()
        }
        condition.unlock()
    }

    func waitForDeterministicOverlap() -> Bool {
        let deadline = Date().addingTimeInterval(10)
        condition.lock()
        defer { condition.unlock() }
        while callerCount < expectedCallerCount, Date() < deadline {
            condition.wait(until: Date().addingTimeInterval(0.01))
        }
        return callerCount == expectedCallerCount && factoryEntryCount == 1
    }

    func releaseFactory() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }

    func callerArrived() {
        condition.lock()
        callerCount += 1
        condition.broadcast()
        condition.unlock()
    }
}

private func startProviderCallers(
    count: Int,
    provider: CodeMapArtifactRuntimeProvider,
    overlapGate: RuntimeProviderOverlapGate,
    results: RuntimeProviderTestResults
) -> DispatchGroup {
    let group = DispatchGroup()
    for _ in 0 ..< count {
        group.enter()
        Thread.detachNewThread {
            defer { group.leave() }
            overlapGate.callerArrived()
            do {
                try results.record(runtime: provider.runtime())
            } catch {
                results.record(error: error)
            }
        }
    }
    return group
}
