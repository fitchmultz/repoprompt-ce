import Foundation
@testable import RepoPrompt
import XCTest

final class WorkspaceFileContextStoreCodemapSeamTests: XCTestCase {
    func testCodemapArtifactDemandFailsClosedForUncatalogedFile() async {
        let store = WorkspaceFileContextStore()
        let result = await store.requestCodemapArtifact(forFileID: UUID())
        guard case .unavailable(.fileNotCataloged) = result else {
            return XCTFail("expected fileNotCataloged, got \(result)")
        }
    }

    func testCodemapArtifactDemandRejectsUnsupportedCatalogedFile() async throws {
        let root = try temporaryDirectory()
        try "plain text".write(
            to: root.appendingPathComponent("notes.txt"),
            atomically: true,
            encoding: .utf8
        )
        let store = WorkspaceFileContextStore()
        let record = try await store.loadRoot(path: root.path)
        let catalogedFile = await store.file(rootID: record.id, relativePath: "notes.txt")
        let file = try XCTUnwrap(catalogedFile)

        let result = await store.requestCodemapArtifact(forFileID: file.id)
        guard case .unavailable(.unsupportedFileType) = result else {
            return XCTFail("expected unsupportedFileType, got \(result)")
        }
    }

    func testCheckoutMutationClearsPendingCodemapRepairsForUnsnapshottedFiles() async throws {
        let root = try temporaryDirectory()
        let sourceURL = root.appendingPathComponent("App.swift")
        try "struct App { func run() {} }".write(
            to: sourceURL,
            atomically: true,
            encoding: .utf8
        )
        let store = WorkspaceFileContextStore()
        let gate = CodemapScanStartGate()
        await store.setCodemapScanWillStartHandlerForTesting { _ in
            await gate.markStartedAndWaitForRelease()
        }
        let record = try await store.loadRoot(path: root.path)
        let catalogedFile = await store.file(rootID: record.id, relativePath: "App.swift")
        let file = try XCTUnwrap(catalogedFile)

        let repair = await store.enqueueMissingCodemapSnapshotRepairs(for: [file])
        XCTAssertEqual(repair.pendingFileIDs, [file.id])
        try await gate.waitUntilStarted()
        let pendingBeforeCancel = await store.codemapMemoryCounters().pendingRepairFileCount
        XCTAssertEqual(pendingBeforeCancel, 1)

        let cancellation = Task { await store.cancelCodemapScansForCheckoutMutation(rootIDs: [record.id]) }
        try await waitForPendingRepairCount(0, in: store)
        await gate.release()
        await cancellation.value
        await store.setCodemapScanWillStartHandlerForTesting(nil)

        let pendingAfterCancel = await store.codemapMemoryCounters().pendingRepairFileCount
        XCTAssertEqual(pendingAfterCancel, 0)
    }

    func testDuplicateCodemapArtifactDemandRetainsIndependentOwnership() async throws {
        let root = try temporaryDirectory()
        let sourceURL = root.appendingPathComponent("App.swift")
        try "struct App { func run() {} }".write(
            to: sourceURL,
            atomically: true,
            encoding: .utf8
        )
        let store = WorkspaceFileContextStore()
        let record = try await store.loadRoot(path: root.path)
        let loadedFile = await store.file(rootID: record.id, relativePath: "App.swift")
        let file = try XCTUnwrap(loadedFile)

        let first = await store.requestCodemapArtifactWithOwnership(forFileID: file.id)
        let second = await store.requestCodemapArtifactWithOwnership(forFileID: file.id)

        guard case let .created(firstTicket) = first.ownership else {
            return XCTFail("expected first request to create ownership, got \(first.ownership)")
        }
        guard case let .joined(secondTicket) = second.ownership else {
            return XCTFail("expected second request to join ownership, got \(second.ownership)")
        }
        XCTAssertEqual(firstTicket.requestID, secondTicket.requestID)
        XCTAssertNotEqual(firstTicket.retainID, secondTicket.retainID)

        let didCancelSecondRetain = await store.cancelCodemapArtifactDemand(secondTicket)
        XCTAssertTrue(didCancelSecondRetain)
        let firstStatus = await store.codemapArtifactDemandStatus(firstTicket)
        if case .unavailable(.staleCurrentness) = firstStatus {
            XCTFail("cancelling one retain must not invalidate the shared demand")
        }

        let didCancelFirstRetain = await store.cancelCodemapArtifactDemand(firstTicket)
        XCTAssertTrue(didCancelFirstRetain)
        guard case .unavailable(.staleCurrentness) = await store.codemapArtifactDemandStatus(firstTicket) else {
            return XCTFail("expected final retain cancellation to remove the demand record")
        }
    }

    private func waitForPendingRepairCount(
        _ expected: Int,
        in store: WorkspaceFileContextStore,
        timeout: Duration = .seconds(2)
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await store.codemapMemoryCounters().pendingRepairFileCount == expected {
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        let pendingCount = await store.codemapMemoryCounters().pendingRepairFileCount
        XCTAssertEqual(pendingCount, expected)
    }

    private func temporaryDirectory() throws -> URL {
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/test-artifacts/WorkspaceFileContextStoreCodemapSeamTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }
}

private actor CodemapScanStartGate {
    private var didStart = false
    private var isReleased = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func markStartedAndWaitForRelease() async {
        didStart = true
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        if isReleased { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func waitUntilStarted() async throws {
        if didStart { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func release() {
        isReleased = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }
}
