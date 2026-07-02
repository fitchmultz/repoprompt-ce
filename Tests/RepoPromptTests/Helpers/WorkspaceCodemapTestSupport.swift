import Foundation
@testable import RepoPrompt
import XCTest

@MainActor
@discardableResult
func repairCodemapArtifactsForTesting(
    _ store: WorkspaceFileContextStore,
    paths: [String],
    timeout: Duration = .seconds(5),
    file: StaticString = #filePath,
    line: UInt = #line
) async throws -> WorkspaceCodemapRepairResult {
    let requested = Set(paths.map(StandardizedPath.absolute))
    let roots = await store.rootRefs(scope: .allLoaded)
    var allFiles: [WorkspaceFileRecord] = []
    for root in roots {
        await allFiles.append(contentsOf: store.files(inRoot: root.id))
    }
    let files = allFiles.filter { requested.contains($0.standardizedFullPath) }
    XCTAssertEqual(files.count, requested.count, "Expected every requested path to be loaded", file: file, line: line)
    return try await store.repairCodemapArtifacts(
        for: files,
        timeout: timeout,
        pollInterval: .milliseconds(25)
    )
}

@MainActor
func buildCodemapPresentationForTesting(
    _ store: WorkspaceFileContextStore,
    paths: [String],
    rootScope: WorkspaceLookupRootScope = .allLoaded,
    timeout: Duration = .seconds(5),
    file: StaticString = #filePath,
    line: UInt = #line
) async throws -> WorkspaceCodemapOperationPresentation {
    let requested = Set(paths.map(StandardizedPath.absolute))
    let roots = await store.rootRefs(scope: .allLoaded)
    var allFiles: [WorkspaceFileRecord] = []
    for root in roots {
        await allFiles.append(contentsOf: store.files(inRoot: root.id))
    }
    let files = allFiles.filter { requested.contains($0.standardizedFullPath) }
    XCTAssertEqual(files.count, requested.count, "Expected every requested path to be loaded", file: file, line: line)
    _ = try await store.repairCodemapArtifacts(
        for: files,
        timeout: timeout,
        pollInterval: .milliseconds(25)
    )
    return try await WorkspaceCodemapPresentationCoordinator(
        store: store,
        policy: WorkspaceCodemapPresentationRequestPolicy(maximumTotalWait: timeout)
    ).presentation(
        for: .exact(fileIDs: files.map(\.id), completeRootSet: false),
        rootScope: rootScope
    )
}

@MainActor
func currentCodemapArtifactSnapshotsForTesting(
    _ store: WorkspaceFileContextStore
) async throws -> [UUID: WorkspaceCodemapSnapshot] {
    try await store.repairCodemapArtifacts(for: [], timeout: .zero).snapshotsByFileID
}

private var observedCodemapResultsByStoreID: [ObjectIdentifier: [String: WorkspaceCodemapFixtureResult]] = [:]

struct WorkspaceCodemapFixtureResult: @unchecked Sendable {
    let fullPath: String
    let modificationDate: Date
    let fileAPI: FileAPI?

    init(fullPath: String, modificationDate: Date, fileAPI: FileAPI?) {
        self.fullPath = StandardizedPath.absolute(fullPath)
        self.modificationDate = modificationDate
        self.fileAPI = fileAPI
    }
}

extension WorkspaceFileContextStore {
    func codemapPresentationFixtureForTesting(
        rootScope: WorkspaceLookupRootScope = .allLoaded
    ) async -> WorkspaceCodemapOperationPresentation {
        let observedEntries = observedCodemapRenderedEntriesForTesting(rootScope: rootScope)
        if !observedEntries.isEmpty {
            return WorkspaceCodemapOperationPresentation(
                orderedEntries: observedEntries,
                coverage: .complete,
                issues: [],
                publicationReceipt: nil
            )
        }
        let roots = rootRefs(scope: rootScope)
        var files: [WorkspaceFileRecord] = []
        for root in roots {
            files.append(contentsOf: self.files(inRoot: root.id))
        }
        do {
            return try await WorkspaceCodemapPresentationCoordinator(
                store: self,
                policy: WorkspaceCodemapPresentationRequestPolicy(maximumTotalWait: .seconds(5))
            ).presentation(
                for: .exact(fileIDs: files.map(\.id), completeRootSet: false),
                rootScope: rootScope
            )
        } catch {
            XCTFail("Failed to build codemap presentation from artifacts: \(error)")
            return .empty
        }
    }

    func codemapSnapshotsForTesting(inRoot rootID: UUID) async -> [WorkspaceCodemapSnapshot] {
        let observed = observedCodemapSnapshotsForTesting(rootID: rootID)
        if !observed.isEmpty { return observed }
        do {
            let snapshots = try await currentCodemapArtifactSnapshotsForTesting(self)
            let fileIDs = Set(files(inRoot: rootID).map(\.id))
            return snapshots.values
                .filter { fileIDs.contains($0.fileID) }
                .sorted { $0.relativePath < $1.relativePath }
        } catch {
            XCTFail("Failed to read codemap artifacts: \(error)")
            return []
        }
    }

    func codemapSnapshotForTesting(fileID: UUID) async -> WorkspaceCodemapSnapshot? {
        if let observed = observedCodemapSnapshotForTesting(fileID: fileID) { return observed }
        do {
            return try await currentCodemapArtifactSnapshotsForTesting(self)[fileID]
        } catch {
            XCTFail("Failed to read codemap artifacts: \(error)")
            return nil
        }
    }

    func codemapSnapshotForTesting(rootID: UUID, relativePath: String) async -> WorkspaceCodemapSnapshot? {
        guard let file = file(rootID: rootID, relativePath: relativePath) else { return nil }
        return await codemapSnapshotForTesting(fileID: file.id)
    }

    @discardableResult
    func applyCodemapFixturesForTesting(_ results: [WorkspaceCodemapFixtureResult]) async -> [String] {
        let id = ObjectIdentifier(self)
        var dropped: [String] = []
        var stored = observedCodemapResultsByStoreID[id] ?? [:]
        for result in results {
            if await lookupPath(result.fullPath, rootScope: .allLoaded)?.file == nil {
                dropped.append(result.fullPath)
                continue
            }
            stored[result.fullPath] = result
        }
        observedCodemapResultsByStoreID[id] = stored
        return dropped.sorted()
    }

    private func observedCodemapRenderedEntriesForTesting(
        rootScope: WorkspaceLookupRootScope
    ) -> [WorkspaceCodemapOperationRenderedEntry] {
        let key = testingCodemapArtifactKey()
        return observedCodemapSnapshotsForTesting(rootScope: rootScope).compactMap { snapshot in
            guard let api = snapshot.fileAPI else { return nil }
            let rootName = (StandardizedPath.absolute(snapshot.rootPath) as NSString).lastPathComponent
            guard let logicalPath = WorkspaceCodemapLogicalPresentationPath(
                rootDisplayName: rootName.isEmpty ? "Root" : rootName,
                standardizedRelativePath: StandardizedPath.relative(snapshot.relativePath)
            ) else { return nil }
            let text = api.getFullAPIDescription(displayPath: snapshot.relativePath)
            guard !text.isEmpty else { return nil }
            return WorkspaceCodemapOperationRenderedEntry(
                bundleID: WorkspaceCodemapFrozenPresentationBundleID(),
                fileID: snapshot.fileID,
                rootEpoch: WorkspaceCodemapRootEpoch(rootID: snapshot.rootID, rootLifetimeID: snapshot.rootID),
                artifactKey: key,
                logicalPath: logicalPath,
                text: text,
                tokenCount: TokenCalculationService.estimateTokens(for: text)
            )
        }.sorted { lhs, rhs in
            if lhs.logicalPath.displayPath != rhs.logicalPath.displayPath { return lhs.logicalPath.displayPath < rhs.logicalPath.displayPath }
            return lhs.fileID.uuidString < rhs.fileID.uuidString
        }
    }

    private func observedCodemapSnapshotsForTesting(
        rootScope: WorkspaceLookupRootScope
    ) -> [WorkspaceCodemapSnapshot] {
        let allowedRootIDs = Set(rootRefs(scope: rootScope).map(\.id))
        var snapshots: [WorkspaceCodemapSnapshot] = []
        for rootID in allowedRootIDs {
            snapshots.append(contentsOf: observedCodemapSnapshotsForTesting(rootID: rootID))
        }
        return snapshots
    }

    private func observedCodemapSnapshotsForTesting(rootID: UUID) -> [WorkspaceCodemapSnapshot] {
        var snapshots: [WorkspaceCodemapSnapshot] = []
        for file in files(inRoot: rootID) {
            if let snapshot = observedCodemapSnapshotForTesting(fileID: file.id) {
                snapshots.append(snapshot)
            }
        }
        return snapshots.sorted { $0.relativePath < $1.relativePath }
    }

    private func observedCodemapSnapshotForTesting(fileID: UUID) -> WorkspaceCodemapSnapshot? {
        for root in rootRefs(scope: .allLoaded) {
            if let file = files(inRoot: root.id).first(where: { $0.id == fileID }) {
                return observedCodemapSnapshotForTesting(file: file)
            }
        }
        return nil
    }

    private func observedCodemapSnapshotForTesting(file: WorkspaceFileRecord) -> WorkspaceCodemapSnapshot? {
        let id = ObjectIdentifier(self)
        guard let result = observedCodemapResultsByStoreID[id]?[file.standardizedFullPath] else { return nil }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: file.standardizedFullPath),
              let currentModificationDate = attrs[.modificationDate] as? Date,
              abs(currentModificationDate.timeIntervalSince(result.modificationDate)) < 1
        else { return nil }
        let root = rootRefs(scope: .allLoaded).first { $0.id == file.rootID }
        return WorkspaceCodemapSnapshot(
            fileID: file.id,
            rootID: file.rootID,
            rootPath: root?.standardizedFullPath ?? (file.standardizedFullPath as NSString).deletingLastPathComponent,
            relativePath: file.standardizedRelativePath,
            fullPath: file.standardizedFullPath,
            modificationDate: result.modificationDate,
            fileAPI: result.fileAPI
        )
    }
}

private func testingCodemapArtifactKey() -> CodeMapArtifactKey {
    let zeroDigest = try! CodeMapSHA256Digest(bytes: Data(repeating: 0, count: CodeMapSHA256Digest.byteCount))
    let pipeline = try! CodeMapPipelineIdentity(
        languageID: .swift,
        decoderPolicy: .workspaceAutomaticV1,
        grammarRevision: String(repeating: "0", count: 40),
        treeSitterABIVersion: 14,
        codeMapQuerySHA256: zeroDigest,
        extractorVersion: CodeMapSemanticVersion(major: 1, minor: 0, patch: 0),
        generatorVersion: CodeMapSemanticVersion(major: 1, minor: 0, patch: 0),
        artifactSchemaVersion: 1,
        oversizeParsePolicyVersion: 1,
        limits: CodeMapPipelineIdentity.requiredLimitNames.map { CodeMapPipelineNamedLimit(name: $0, value: 0) },
        flags: CodeMapPipelineIdentity.requiredFlagNames.map { CodeMapPipelineNamedFlag(name: $0, enabled: false) }
    )
    return CodeMapArtifactKey(
        rawSHA256: CodeMapRawSourceDigest(bytes: zeroDigest.bytes),
        rawByteCount: 0,
        pipelineIdentity: pipeline
    )
}
