import Foundation

let workspaceCodemapProductionDemandWaitMilliseconds = 10000

struct WorkspaceCodemapPresentationRequestPolicy: Equatable {
    static let `default` = Self()

    let maximumReadinessRounds: Int
    let initialBackoffMilliseconds: Int
    let maximumBackoffMilliseconds: Int
    let maximumTotalWait: Duration
    let maximumStructureSeedCountPerRoot: Int
    let maximumCandidateDemandCount: Int
    let maximumStructurePublicationAttempts: Int

    init(
        maximumReadinessRounds: Int = 4096,
        initialBackoffMilliseconds: Int = 25,
        maximumBackoffMilliseconds: Int = 250,
        maximumTotalWait: Duration = .milliseconds(workspaceCodemapProductionDemandWaitMilliseconds),
        maximumStructureSeedCountPerRoot: Int = 8192,
        maximumCandidateDemandCount: Int = 1024,
        maximumStructurePublicationAttempts: Int = 4
    ) {
        self.maximumReadinessRounds = maximumReadinessRounds
        self.initialBackoffMilliseconds = initialBackoffMilliseconds
        self.maximumBackoffMilliseconds = maximumBackoffMilliseconds
        self.maximumTotalWait = maximumTotalWait
        self.maximumStructureSeedCountPerRoot = maximumStructureSeedCountPerRoot
        self.maximumCandidateDemandCount = maximumCandidateDemandCount
        self.maximumStructurePublicationAttempts = maximumStructurePublicationAttempts
    }
}

struct WorkspaceCodemapPresentationWaiter {
    let sleep: @Sendable (Duration) async throws -> Void

    static let production = Self { duration in
        try await Task.sleep(for: duration)
    }
}

struct WorkspaceCodemapPresentationCoordinator {
    let store: WorkspaceFileContextStore
    let policy: WorkspaceCodemapPresentationRequestPolicy
    let waiter: WorkspaceCodemapPresentationWaiter

    init(
        store: WorkspaceFileContextStore,
        policy: WorkspaceCodemapPresentationRequestPolicy = .default,
        waiter: WorkspaceCodemapPresentationWaiter = .production,
        beforePublicationRevalidation: @escaping @Sendable (WorkspaceCodemapOperationPresentationPublicationReceipt) async -> Void = { _ in },
        afterAutomaticCandidateReconstruction: @escaping @Sendable (WorkspaceCodemapAutomaticSelectionPublicationReceipt) async throws -> Void = { _ in },
        structureAttemptDidBegin: @escaping @Sendable (Int) -> Void = { _ in }
    ) {
        self.store = store
        self.policy = policy
        self.waiter = waiter
    }

    func presentation(
        for intent: WorkspaceCodemapOperationPresentationIntent,
        rootScope: WorkspaceLookupRootScope = .visibleWorkspace,
        logicalRootDisplayNamesByRootID: [UUID: String] = [:]
    ) async throws -> WorkspaceCodemapOperationPresentation {
        try await withPresentation(for: intent, rootScope: rootScope, logicalRootDisplayNamesByRootID: logicalRootDisplayNamesByRootID) { $0 }
    }

    func withPresentation<Value>(
        for intent: WorkspaceCodemapOperationPresentationIntent,
        rootScope: WorkspaceLookupRootScope = .visibleWorkspace,
        logicalRootDisplayNamesByRootID: [UUID: String] = [:],
        operation: (WorkspaceCodemapOperationPresentation) async throws -> Value
    ) async throws -> Value {
        try Task.checkCancellation()
        return try await operation(.empty)
    }

    func structurePresentation(
        seedFileIDs: [UUID],
        direction: WorkspaceCodemapStructureTraversalDirection?,
        traversalLimits: WorkspaceCodemapStructureTraversalLimits,
        outputLimits: WorkspaceCodemapStructureOutputLimits,
        rootScope: WorkspaceLookupRootScope = .visibleWorkspace,
        logicalRootDisplayNamesByRootID: [UUID: String] = [:]
    ) async throws -> WorkspaceCodemapStructurePresentation {
        try Task.checkCancellation()
        let requestedSeedCount = seedFileIDs.count
        guard !seedFileIDs.isEmpty else {
            return WorkspaceCodemapStructurePresentation(
                outcome: .unavailable,
                entries: [],
                issues: [],
                requestedSeedCount: requestedSeedCount,
                resolvedSeedCount: 0,
                examinedEdgeCount: 0,
                codemapTokenCount: 0
            )
        }

        let roots = await store.rootRefs(scope: rootScope)
        var filePairs: [(UUID, (WorkspaceRootRef, WorkspaceFileRecord))] = []
        for root in roots {
            let files = await store.files(inRoot: root.id)
            filePairs.append(contentsOf: files.map { ($0.id, (root, $0)) })
        }
        let filesByID = Dictionary(uniqueKeysWithValues: filePairs)
        var entries: [WorkspaceCodemapStructureRenderedEntry] = []
        var issues: [WorkspaceCodemapStructureIssue] = []
        var tokenCount = 0

        for fileID in seedFileIDs.prefix(outputLimits.maximumFileCount) {
            try Task.checkCancellation()
            guard let (root, file) = filesByID[fileID] else {
                issues.append(.candidate(.fileNotCataloged(fileID)))
                continue
            }
            let demand = await store.requestCodemapArtifact(forFileID: fileID)
            guard case let .ready(ready) = demand else {
                switch demand {
                case let .pending(ticket): issues.append(.artifactPending(fileID: fileID, ticket: ticket))
                case let .unavailable(reason): issues.append(.artifactUnavailable(fileID: fileID, reason: reason))
                case .ready: break
                }
                continue
            }
            guard let api = await store.codemapSnapshot(fileID: fileID)?.fileAPI else {
                issues.append(.artifactUnavailable(fileID: fileID, reason: .staleCurrentness))
                continue
            }
            let rootName = logicalRootDisplayNamesByRootID[root.id]
                ?? URL(fileURLWithPath: root.standardizedFullPath).lastPathComponent
            guard let logicalPath = WorkspaceCodemapLogicalPresentationPath(
                rootDisplayName: rootName,
                standardizedRelativePath: file.standardizedRelativePath
            ) else {
                issues.append(.candidate(.logicalPathUnavailable(fileID)))
                continue
            }
            let text = api.getFullAPIDescription(displayPath: logicalPath.displayPath)
            let tokens = TokenCalculationService.estimateTokens(for: text)
            if tokenCount + tokens > outputLimits.maximumCodemapTokenCount {
                issues.append(.tokenLimit(path: logicalPath.displayPath, attempted: tokenCount + tokens, limit: outputLimits.maximumCodemapTokenCount))
                break
            }
            tokenCount += tokens
            let rendered = WorkspaceCodemapOperationRenderedEntry(
                bundleID: WorkspaceCodemapFrozenPresentationBundleID(),
                fileID: fileID,
                rootEpoch: ready.snapshot.rootEpoch,
                artifactKey: ready.snapshot.artifactKey,
                logicalPath: logicalPath,
                text: text,
                tokenCount: tokens
            )
            entries.append(WorkspaceCodemapStructureRenderedEntry(
                entry: rendered,
                isSeed: true,
                depth: 0,
                reachedBy: []
            ))
        }

        if seedFileIDs.count > outputLimits.maximumFileCount {
            issues.append(.fileLimit(attempted: seedFileIDs.count, limit: outputLimits.maximumFileCount))
        }
        let outcome: WorkspaceCodemapStructureOutcome = if !entries.isEmpty, issues.contains(where: { issue in
            if case .fileLimit = issue { return true }
            if case .tokenLimit = issue { return true }
            return false
        }) {
            .budget
        } else if issues.contains(where: { issue in
            if case .artifactPending = issue { return true }
            return false
        }) {
            .timeout
        } else if entries.isEmpty {
            .unavailable
        } else {
            .ready
        }
        return WorkspaceCodemapStructurePresentation(
            outcome: outcome,
            entries: entries,
            issues: issues,
            requestedSeedCount: requestedSeedCount,
            resolvedSeedCount: entries.count,
            examinedEdgeCount: 0,
            codemapTokenCount: tokenCount
        )
    }
}
