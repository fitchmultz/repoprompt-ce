import Foundation
@testable import RepoPrompt
import XCTest

@MainActor
final class WorkspaceCheckoutRefreshServiceTests: XCTestCase {
    private var temporaryRoots: [URL] = []

    override func tearDownWithError() throws {
        for url in temporaryRoots {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryRoots.removeAll()
        try super.tearDownWithError()
    }

    func testCodemapStaleSnapshotsAreRemovedBeforeFreshScanCompletes() async throws {
        let root = try makeTemporaryRoot(name: "CheckoutRefreshCodemap")
        let file = root.appendingPathComponent("Sources/App.swift")
        try write("func branchASymbol() {}\n", to: file)

        let previousCodeMapsDisabled = GlobalSettingsStore.shared.globalCodeMapsDisabled()
        GlobalSettingsStore.shared.setCodeMapsGloballyDisabled(false, commit: false)
        defer { GlobalSettingsStore.shared.setCodeMapsGloballyDisabled(previousCodeMapsDisabled, commit: false) }

        let store = makeStore()
        let record = try await store.loadRoot(path: root.path)
        let repairResult = try await repairCodemapArtifactsForTesting(store, paths: [file.path])
        let resolvedFileIDBeforeRefresh = await storeFileID(in: record.id, relativePath: "Sources/App.swift", store: store)
        let fileIDBeforeRefresh = try XCTUnwrap(resolvedFileIDBeforeRefresh)
        XCTAssertNotNil(repairResult.snapshotsByFileID[fileIDBeforeRefresh])

        try write("func branchBSymbol() {}\n", to: file)
        let service = makeService(store: store, searchService: makeSearchService())
        let result = await service.refreshAfterCheckoutMutation(rootPath: root.path)

        let resolvedFileID = await storeFileID(in: record.id, relativePath: "Sources/App.swift", store: store)
        let fileID = try XCTUnwrap(resolvedFileID)
        XCTAssertTrue(result.didRefreshLoadedRoot)
        XCTAssertEqual(result.refreshedRootIDs, [record.id])
        XCTAssertTrue(result.removedStaleCodemapFileIDs.contains(fileID))
        let snapshotsAfterRefresh = try await currentCodemapArtifactSnapshotsForTesting(store)
        XCTAssertNil(snapshotsAfterRefresh[fileID])
        XCTAssertFalse(snapshotsAfterRefresh.values.contains { snapshot in
            snapshot.fileAPI?.apiDescription.contains("branchASymbol") == true
        })
    }

    func testRefreshAfterCheckoutMutationRebuildsVisibleSearchIndexFromFreshCatalogSnapshot() async throws {
        let root = try makeTemporaryRoot(name: "CheckoutRefreshSearch")
        try write("let seed = true\n", to: root.appendingPathComponent("Seed.swift"))

        let store = makeStore()
        let record = try await store.loadRoot(path: root.path)
        let searchService = makeSearchService()
        let initialSnapshot = await store.searchCatalogSnapshot(rootScope: .visibleWorkspace)
        await searchService.rebuildIndex(from: initialSnapshot)

        try write("let branchOnly = true\n", to: root.appendingPathComponent("Sources/BranchOnly.swift"))
        await store.replayObservedFileSystemDeltas(rootID: record.id, deltas: [.fileAdded("Sources/BranchOnly.swift")])

        let service = makeService(store: store, searchService: searchService)
        let result = await service.refreshAfterCheckoutMutation(rootPath: root.path)
        let expectedGeneration = await store.catalogGeneration(rootScope: .visibleWorkspace)
        let searchResult = await searchService.search("BranchOnly", limit: 10)

        XCTAssertEqual(result.searchIndexedGeneration, expectedGeneration)
        XCTAssertEqual(result.searchIndexRefreshBehavior, .rebuiltSharedVisibleWorkspace)
        XCTAssertNotNil(result.pathLookupGeneration)
        XCTAssertFalse(searchResult.isStale)
        XCTAssertEqual(searchResult.indexedGeneration, expectedGeneration)
        XCTAssertEqual(searchResult.results.map(\.standardizedRelativePath), ["Sources/BranchOnly.swift"])
    }

    func testRefreshAfterCheckoutMutationUsesFreshCatalogBeforeWarmingIndexes() async throws {
        let root = try makeTemporaryRoot(name: "CheckoutRefreshDiskReconcile")
        let seed = root.appendingPathComponent("Sources/Seed.swift")
        let branchOnly = root.appendingPathComponent("Sources/BranchOnly.swift")
        try write("let seed = true\n", to: seed)

        let store = makeStore()
        let record = try await store.loadRoot(path: root.path)
        let searchService = makeSearchService()
        let initialSnapshot = await store.searchCatalogSnapshot(rootScope: .visibleWorkspace)
        await searchService.rebuildIndex(from: initialSnapshot)

        try FileManager.default.removeItem(at: seed)
        try write("let branchOnly = true\n", to: branchOnly)
        await store.replayObservedFileSystemDeltas(rootID: record.id, deltas: [
            .fileRemoved("Sources/Seed.swift"),
            .fileAdded("Sources/BranchOnly.swift")
        ])

        let service = makeService(store: store, searchService: searchService)
        let result = await service.refreshAfterCheckoutMutation(rootPath: root.path)
        let expectedGeneration = await store.catalogGeneration(rootScope: .visibleWorkspace)
        let branchLookup = await store.lookupPath("Sources/BranchOnly.swift", profile: .uiAssisted, rootScope: .visibleWorkspace)
        let seedLookup = await store.lookupPath("Sources/Seed.swift", profile: .uiAssisted, rootScope: .visibleWorkspace)
        let searchResult = await searchService.search("BranchOnly", limit: 10)

        XCTAssertEqual(result.searchIndexRefreshBehavior, .rebuiltSharedVisibleWorkspace)
        XCTAssertEqual(result.searchIndexedGeneration, expectedGeneration)
        XCTAssertNotNil(result.pathLookupGeneration)
        XCTAssertNotNil(branchLookup?.file)
        XCTAssertNil(seedLookup?.file)
        XCTAssertFalse(searchResult.isStale)
        XCTAssertEqual(searchResult.indexedGeneration, expectedGeneration)
        XCTAssertEqual(searchResult.results.map(\.standardizedRelativePath), ["Sources/BranchOnly.swift"])
    }

    func testRefreshAfterCheckoutMutationDoesNotOverwriteVisibleSearchIndexForSessionWorktreeRoot() async throws {
        let visibleRoot = try makeTemporaryRoot(name: "CheckoutRefreshVisibleRoot")
        let worktreeRoot = try makeTemporaryRoot(name: "CheckoutRefreshSessionWorktree")
        try write("let baseOnly = true\n", to: visibleRoot.appendingPathComponent("Sources/BaseOnly.swift"))
        try write("let branchOnly = true\n", to: worktreeRoot.appendingPathComponent("Sources/BranchOnly.swift"))

        let store = makeStore()
        let visibleRecord = try await store.loadRoot(path: visibleRoot.path)
        let worktreeRecord = try await store.loadRoot(path: worktreeRoot.path, kind: .sessionWorktree)
        let searchService = makeSearchService()
        let initialVisibleSnapshot = await store.searchCatalogSnapshot(rootScope: .visibleWorkspace)
        let initialVisibleGeneration = await searchService.rebuildIndex(from: initialVisibleSnapshot)

        let service = makeService(store: store, searchService: searchService)
        let result = await service.refreshAfterCheckoutMutation(rootPath: worktreeRoot.path)
        let baseSearch = await searchService.search("BaseOnly", limit: 10)
        let branchSearch = await searchService.search("BranchOnly", limit: 10)

        XCTAssertEqual(result.searchIndexRefreshBehavior, .skippedSharedVisibleWorkspaceForSessionWorktree)
        XCTAssertNil(result.searchIndexedGeneration)
        XCTAssertEqual(baseSearch.indexedGeneration, initialVisibleGeneration)
        XCTAssertEqual(baseSearch.results.map(\.standardizedRelativePath), ["Sources/BaseOnly.swift"])
        XCTAssertEqual(branchSearch.indexedGeneration, initialVisibleGeneration)
        XCTAssertTrue(branchSearch.results.isEmpty)
    }

    private func makeStore() -> WorkspaceFileContextStore {
        WorkspaceFileContextStore(unloadTerminationPolicy: WorkspaceRootUnloadTerminationPolicy(
            publisherIngressGraceNanoseconds: 1,
            watcherStopGraceNanoseconds: 1,
            sleep: { _ in }
        ))
    }

    private func makeSearchService() -> WorkspaceSearchService {
        WorkspaceSearchService()
    }

    private func makeService(
        store: WorkspaceFileContextStore,
        searchService: WorkspaceSearchService
    ) -> WorkspaceCheckoutRefreshService {
        WorkspaceCheckoutRefreshService(
            store: store,
            searchService: searchService,
            drainsPreReconcileIngress: false,
            scheduleCodemapRescans: { _, _ in }
        )
    }

    private func storeFileID(in rootID: UUID, relativePath: String, store: WorkspaceFileContextStore) async -> UUID? {
        await store.file(rootID: rootID, relativePath: relativePath)?.id
    }

    private func makeTemporaryRoot(name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepoPromptTests", isDirectory: true)
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        temporaryRoots.append(url)
        return url
    }

    private func write(_ content: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    private func makeFileAPI(path: String, symbolName: String) -> FileAPI {
        FileAPI(
            filePath: path,
            imports: [],
            classes: [],
            functions: [
                FunctionInfo(
                    name: symbolName,
                    parameters: [],
                    returnType: nil,
                    definitionLine: "func \(symbolName)()",
                    lineNumber: 1
                )
            ],
            enums: [],
            globalVars: [],
            macros: [],
            referencedTypes: []
        )
    }
}
