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
    let beforePublicationRevalidation: @Sendable (WorkspaceCodemapOperationPresentationPublicationReceipt) async -> Void
    let afterAutomaticCandidateReconstruction: @Sendable (WorkspaceCodemapAutomaticSelectionPublicationReceipt) async throws -> Void
    let structureAttemptDidBegin: @Sendable (Int) -> Void

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
        self.beforePublicationRevalidation = beforePublicationRevalidation
        self.afterAutomaticCandidateReconstruction = afterAutomaticCandidateReconstruction
        self.structureAttemptDidBegin = structureAttemptDidBegin
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
        let result = try await makePresentation(
            for: intent,
            rootScope: rootScope,
            logicalRootDisplayNamesByRootID: logicalRootDisplayNamesByRootID
        )
        if let receipt = result.presentation.publicationReceipt {
            await beforePublicationRevalidation(receipt)
            let staleIssues = await publicationStaleIssues(receipt)
            if !staleIssues.isEmpty {
                let stalePresentation = presentation(
                    from: result.presentation,
                    adding: staleIssues,
                    forceUnavailableWhenEmpty: true
                )
                await release(tickets: result.ownedTickets)
                return try await operation(stalePresentation)
            }
        }
        do {
            let value = try await operation(result.presentation)
            if let receipt = result.presentation.publicationReceipt {
                await beforePublicationRevalidation(receipt)
                let staleIssues = await publicationStaleIssues(receipt)
                if !staleIssues.isEmpty {
                    let stalePresentation = presentation(
                        from: result.presentation,
                        adding: staleIssues,
                        forceUnavailableWhenEmpty: true
                    )
                    await release(tickets: result.ownedTickets)
                    return try await operation(stalePresentation)
                }
            }
            await release(tickets: result.ownedTickets)
            return value
        } catch {
            await release(tickets: result.ownedTickets)
            throw error
        }
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

        structureAttemptDidBegin(1)
        let intent = WorkspaceCodemapOperationPresentationIntent.exact(
            fileIDs: Array(seedFileIDs.prefix(policy.maximumStructureSeedCountPerRoot)),
            completeRootSet: false
        )
        let operation = try await presentation(
            for: intent,
            rootScope: rootScope,
            logicalRootDisplayNamesByRootID: logicalRootDisplayNamesByRootID
        )

        var entries = operation.orderedEntries.prefix(outputLimits.maximumFileCount).map {
            WorkspaceCodemapStructureRenderedEntry(entry: $0, isSeed: seedFileIDs.contains($0.fileID), depth: 0, reachedBy: [])
        }
        var issues = operation.issues.map(WorkspaceCodemapStructureIssue.operation)
        if operation.orderedEntries.count > outputLimits.maximumFileCount {
            issues.append(.fileLimit(attempted: operation.orderedEntries.count, limit: outputLimits.maximumFileCount))
        }

        var tokenCount = 0
        var limitedEntries: [WorkspaceCodemapStructureRenderedEntry] = []
        for entry in entries {
            let next = tokenCount + entry.entry.tokenCount
            if next > outputLimits.maximumCodemapTokenCount {
                issues.append(.tokenLimit(path: entry.entry.logicalPath.displayPath, attempted: next, limit: outputLimits.maximumCodemapTokenCount))
                break
            }
            limitedEntries.append(entry)
            tokenCount = next
        }
        entries = limitedEntries

        let outcome: WorkspaceCodemapStructureOutcome = switch operation.coverage {
        case .complete where !entries.isEmpty && issues.isEmpty:
            .ready
        case .complete:
            .partial
        case .partial where !entries.isEmpty:
            .partial
        case .partial:
            .unavailable
        case .pending:
            entries.isEmpty ? .timeout : .partial
        case .unavailable:
            .unavailable
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

private extension WorkspaceCodemapPresentationCoordinator {
    struct PresentationBuildResult {
        let presentation: WorkspaceCodemapOperationPresentation
        let ownedTickets: [WorkspaceCodemapArtifactDemandTicket]
    }

    struct DemandRecord {
        let fileID: UUID
        let logicalPath: WorkspaceCodemapLogicalPresentationPath
        let result: WorkspaceCodemapArtifactDemandResult
    }

    func makePresentation(
        for intent: WorkspaceCodemapOperationPresentationIntent,
        rootScope: WorkspaceLookupRootScope,
        logicalRootDisplayNamesByRootID: [UUID: String]
    ) async throws -> PresentationBuildResult {
        try Task.checkCancellation()
        switch intent {
        case .none:
            return PresentationBuildResult(presentation: .empty, ownedTickets: [])
        case let .exact(fileIDs, completeRootSet):
            return try await makeExactPresentation(
                fileIDs: fileIDs,
                completeRootSet: completeRootSet,
                automaticIssue: nil,
                automaticReceipt: nil,
                rootScope: rootScope,
                logicalRootDisplayNamesByRootID: logicalRootDisplayNamesByRootID
            )
        case let .automatic(sourceFileIDs):
            return try await makeAutomaticPresentation(
                sourceFileIDs: sourceFileIDs,
                rootScope: rootScope,
                logicalRootDisplayNamesByRootID: logicalRootDisplayNamesByRootID
            )
        }
    }

    func makeAutomaticPresentation(
        sourceFileIDs: [UUID],
        rootScope: WorkspaceLookupRootScope,
        logicalRootDisplayNamesByRootID: [UUID: String]
    ) async throws -> PresentationBuildResult {
        let sourceCollection = await store.codemapOperationPresentationCandidates(
            forFileIDs: sourceFileIDs,
            rootScope: rootScope,
            logicalRootDisplayNamesByRootID: logicalRootDisplayNamesByRootID
        )
        var issues = sourceCollection.issues.map(WorkspaceCodemapOperationIssue.candidate)
        guard !sourceCollection.candidates.isEmpty else {
            let coverage = WorkspaceCodemapAutomaticSelectionAggregateCoverage.unavailable(.noReadySources)
            issues.append(.automatic(coverage))
            return PresentationBuildResult(
                presentation: WorkspaceCodemapOperationPresentation(
                    orderedEntries: [],
                    coverage: .unavailable(issues),
                    issues: issues,
                    publicationReceipt: nil
                ),
                ownedTickets: []
            )
        }

        let sourceLimit = await store.automaticCodemapSelectionSourceDemandLimit()
        guard sourceCollection.candidates.count <= sourceLimit else {
            let coverage = WorkspaceCodemapAutomaticSelectionAggregateCoverage.budget(.sourceLimit(
                attempted: sourceCollection.candidates.count,
                limit: sourceLimit
            ))
            issues.append(.automatic(coverage))
            return PresentationBuildResult(
                presentation: WorkspaceCodemapOperationPresentation(
                    orderedEntries: [],
                    coverage: .unavailable(issues),
                    issues: issues,
                    publicationReceipt: nil
                ),
                ownedTickets: []
            )
        }

        var sourceTickets: [WorkspaceCodemapArtifactDemandTicket] = []
        var readySources: [WorkspaceCodemapAutomaticSelectionSourceIdentity] = []
        var ownedTickets: [WorkspaceCodemapArtifactDemandTicket] = []
        var pendingReasons: [WorkspaceCodemapAutomaticSelectionPendingReason] = []
        for candidate in sourceCollection.candidates {
            let owned = await store.requestCodemapArtifactWithOwnership(forFileID: candidate.fileID)
            if case let .created(ticket) = owned.ownership { ownedTickets.append(ticket) }
            if case let .joined(ticket) = owned.ownership { ownedTickets.append(ticket) }
            let result = try await waitForReadiness(owned.result)
            switch result {
            case let .ready(ready):
                sourceTickets.append(ready.ticket)
                readySources.append(WorkspaceCodemapAutomaticSelectionSourceIdentity(
                    rootEpoch: ready.ticket.rootEpoch,
                    fileID: ready.ticket.fileID,
                    catalogGeneration: ready.ticket.catalogGeneration
                ))
            case let .pending(ticket):
                pendingReasons.append(.sourceDemand(
                    WorkspaceCodemapAutomaticSelectionSourceIdentity(
                        rootEpoch: ticket.rootEpoch,
                        fileID: ticket.fileID,
                        catalogGeneration: ticket.catalogGeneration
                    ),
                    ticket
                ))
            case .unavailable:
                break
            }
        }
        guard !readySources.isEmpty else {
            let coverage: WorkspaceCodemapAutomaticSelectionAggregateCoverage = pendingReasons.isEmpty
                ? .unavailable(.noReadySources)
                : .pending(pendingReasons)
            issues.append(.automatic(coverage))
            return PresentationBuildResult(
                presentation: WorkspaceCodemapOperationPresentation(
                    orderedEntries: [],
                    coverage: pendingReasons.isEmpty ? .unavailable(issues) : .pending(issues),
                    issues: issues,
                    publicationReceipt: nil
                ),
                ownedTickets: ownedTickets
            )
        }

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: policy.maximumTotalWait)
        let projectionDeadline = projectionDeadlineUptimeNanoseconds(clock: clock, deadline: deadline)
        for rootEpoch in Set(sourceTickets.map(\.rootEpoch)).sorted(by: workspaceCodemapRootEpochPrecedes) {
            let tickets = sourceTickets.filter { $0.rootEpoch == rootEpoch }
            let acquisition = await store.acquireCodemapProjectionDemand(
                sourceTickets: tickets,
                deadlineUptimeNanoseconds: projectionDeadline
            )
            guard case let .acquired(projectionTicket, _) = acquisition else {
                let coverage = WorkspaceCodemapAutomaticSelectionAggregateCoverage.pending([.graphRebuild(rootEpoch: rootEpoch)])
                issues.append(.automatic(coverage))
                return PresentationBuildResult(
                    presentation: WorkspaceCodemapOperationPresentation(
                        orderedEntries: [],
                        coverage: .pending(issues),
                        issues: issues,
                        publicationReceipt: nil
                    ),
                    ownedTickets: ownedTickets
                )
            }
            let published = await store.waitForCodemapGraphPublication(projectionTicket, deadline: deadline)
            _ = await store.releaseCodemapProjectionDemand(projectionTicket)
            guard published else {
                let coverage = WorkspaceCodemapAutomaticSelectionAggregateCoverage.pending([.graphRebuild(rootEpoch: rootEpoch)])
                issues.append(.automatic(coverage))
                return PresentationBuildResult(
                    presentation: WorkspaceCodemapOperationPresentation(
                        orderedEntries: [],
                        coverage: .pending(issues),
                        issues: issues,
                        publicationReceipt: nil
                    ),
                    ownedTickets: ownedTickets
                )
            }
        }

        let planDisposition = await store.planAutomaticCodemapSelectionCandidates(
            sources: readySources,
            rootScope: rootScope,
            maximumCandidateDemandCount: policy.maximumCandidateDemandCount
        )
        let plan: WorkspaceCodemapAutomaticSelectionCandidatePlan
        switch planDisposition {
        case let .ready(value):
            plan = value
        case let .pending(reasons):
            let coverage = WorkspaceCodemapAutomaticSelectionAggregateCoverage.pending(reasons)
            issues.append(.automatic(coverage))
            return PresentationBuildResult(
                presentation: WorkspaceCodemapOperationPresentation(
                    orderedEntries: [],
                    coverage: .pending(issues),
                    issues: issues,
                    publicationReceipt: nil
                ),
                ownedTickets: ownedTickets
            )
        case let .unavailable(reason):
            let coverage = WorkspaceCodemapAutomaticSelectionAggregateCoverage.unavailable(reason)
            issues.append(.automatic(coverage))
            return PresentationBuildResult(
                presentation: WorkspaceCodemapOperationPresentation(
                    orderedEntries: [],
                    coverage: .unavailable(issues),
                    issues: issues,
                    publicationReceipt: nil
                ),
                ownedTickets: ownedTickets
            )
        case let .stale(reason):
            let coverage = WorkspaceCodemapAutomaticSelectionAggregateCoverage.stale(reason)
            issues.append(.automatic(coverage))
            return PresentationBuildResult(
                presentation: WorkspaceCodemapOperationPresentation(
                    orderedEntries: [],
                    coverage: .unavailable(issues),
                    issues: issues,
                    publicationReceipt: nil
                ),
                ownedTickets: ownedTickets
            )
        case let .budget(reason):
            let coverage = WorkspaceCodemapAutomaticSelectionAggregateCoverage.budget(reason)
            issues.append(.automatic(coverage))
            return PresentationBuildResult(
                presentation: WorkspaceCodemapOperationPresentation(
                    orderedEntries: [],
                    coverage: .unavailable(issues),
                    issues: issues,
                    publicationReceipt: nil
                ),
                ownedTickets: ownedTickets
            )
        case let .provisional(provisional):
            let coverage = WorkspaceCodemapAutomaticSelectionAggregateCoverage.provisional(
                incomplete: provisional.incompleteReasons,
                pending: [],
                partial: []
            )
            issues.append(.automatic(coverage))
            return PresentationBuildResult(
                presentation: WorkspaceCodemapOperationPresentation(
                    orderedEntries: [],
                    coverage: .pending(issues),
                    issues: issues,
                    publicationReceipt: nil
                ),
                ownedTickets: ownedTickets
            )
        case let .incomplete(reasons):
            let coverage = WorkspaceCodemapAutomaticSelectionAggregateCoverage.incomplete(reasons)
            issues.append(.automatic(coverage))
            return PresentationBuildResult(
                presentation: WorkspaceCodemapOperationPresentation(
                    orderedEntries: [],
                    coverage: .pending(issues),
                    issues: issues,
                    publicationReceipt: nil
                ),
                ownedTickets: ownedTickets
            )
        case let .busy(reason):
            let coverage = WorkspaceCodemapAutomaticSelectionAggregateCoverage.busy(reason)
            issues.append(.automatic(coverage))
            return PresentationBuildResult(
                presentation: WorkspaceCodemapOperationPresentation(
                    orderedEntries: [],
                    coverage: .pending(issues),
                    issues: issues,
                    publicationReceipt: nil
                ),
                ownedTickets: ownedTickets
            )
        }

        let targets = plan.candidates.compactMap { candidate -> WorkspaceCodemapAutomaticSelectionTarget? in
            let rootName = logicalRootDisplayNamesByRootID[candidate.identity.rootID]
                ?? URL(fileURLWithPath: candidate.identity.standardizedRootPath).lastPathComponent
            guard let logicalPath = WorkspaceCodemapLogicalPresentationPath(
                rootDisplayName: rootName,
                standardizedRelativePath: candidate.identity.standardizedRelativePath
            ) else { return nil }
            return WorkspaceCodemapAutomaticSelectionTarget(
                rootEpoch: candidate.rootEpoch,
                fileID: candidate.identity.fileID,
                catalogGeneration: candidate.catalogGeneration,
                requestGeneration: candidate.requestGeneration,
                logicalPath: logicalPath
            )
        }
        let receipt = WorkspaceCodemapAutomaticSelectionPublicationReceipt(
            requestID: UUID(),
            rootScope: rootScope,
            rootScopeEpochs: plan.rootScopeEpochs,
            sourceTickets: sourceTickets,
            graphKeys: plan.coverageProofs.map { WorkspaceCodemapSelectionGraphRuntimeKey(generation: $0.generation) },
            coverageProofs: plan.coverageProofs,
            targets: targets,
            publicationPermit: WorkspaceCodemapAutomaticSelectionPublicationPermit()
        )
        var result = try await makeExactPresentation(
            fileIDs: targets.map(\.fileID),
            completeRootSet: false,
            automaticIssue: nil,
            automaticReceipt: receipt,
            rootScope: rootScope,
            logicalRootDisplayNamesByRootID: logicalRootDisplayNamesByRootID
        )
        result = PresentationBuildResult(
            presentation: WorkspaceCodemapOperationPresentation(
                orderedEntries: result.presentation.orderedEntries,
                coverage: issues.isEmpty ? result.presentation.coverage : .partial(issues),
                issues: issues + result.presentation.issues,
                publicationReceipt: result.presentation.publicationReceipt
            ),
            ownedTickets: ownedTickets + result.ownedTickets
        )
        return result
    }

    func makeExactPresentation(
        fileIDs: [UUID],
        completeRootSet: Bool,
        automaticIssue: WorkspaceCodemapOperationIssue?,
        automaticReceipt: WorkspaceCodemapAutomaticSelectionPublicationReceipt?,
        rootScope: WorkspaceLookupRootScope,
        logicalRootDisplayNamesByRootID: [UUID: String]
    ) async throws -> PresentationBuildResult {
        try Task.checkCancellation()
        guard !fileIDs.isEmpty else {
            let issues = [automaticIssue].compactMap(\.self)
            let receipt: WorkspaceCodemapOperationPresentationPublicationReceipt? = automaticReceipt.map {
                WorkspaceCodemapOperationPresentationPublicationReceipt(
                    requestID: UUID(),
                    rootScope: rootScope,
                    logicalRootDisplayNamesByRootID: [:],
                    completeRootSet: completeRootSet,
                    completeRootCatalogs: [],
                    candidates: [],
                    demandTickets: [],
                    bundles: [],
                    automaticReceipt: $0
                )
            }
            return PresentationBuildResult(
                presentation: WorkspaceCodemapOperationPresentation(
                    orderedEntries: [],
                    coverage: issues.isEmpty ? .complete : .unavailable(issues),
                    issues: issues,
                    publicationReceipt: receipt
                ),
                ownedTickets: []
            )
        }

        let roots = await store.rootRefs(scope: rootScope)
        let rootsByID = Dictionary(uniqueKeysWithValues: roots.map { ($0.id, $0) })
        var filesByID: [UUID: WorkspaceFileRecord] = [:]
        for root in roots {
            for file in await store.files(inRoot: root.id) {
                filesByID[file.id] = file
            }
        }

        var issues = [automaticIssue].compactMap(\.self)
        var records: [DemandRecord] = []
        var ownedTickets: [WorkspaceCodemapArtifactDemandTicket] = []
        var seenFileIDs = Set<UUID>()
        for fileID in fileIDs.prefix(policy.maximumCandidateDemandCount) {
            try Task.checkCancellation()
            guard seenFileIDs.insert(fileID).inserted else { continue }
            guard let file = filesByID[fileID] else {
                issues.append(.candidate(.fileOutsideRootScope(fileID)))
                continue
            }
            guard let root = rootsByID[file.rootID] else {
                issues.append(.candidate(.fileOutsideRootScope(fileID)))
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

            let owned = await store.requestCodemapArtifactWithOwnership(forFileID: fileID)
            if case let .created(ticket) = owned.ownership { ownedTickets.append(ticket) }
            if case let .joined(ticket) = owned.ownership { ownedTickets.append(ticket) }
            let result = try await waitForReadiness(owned.result)
            records.append(DemandRecord(fileID: fileID, logicalPath: logicalPath, result: result))
        }
        if fileIDs.count > policy.maximumCandidateDemandCount {
            issues.append(.candidate(.incompleteRootSet(missingFileIDs: Array(fileIDs.dropFirst(policy.maximumCandidateDemandCount)))))
        }

        let rendered = render(records: records, issues: &issues)
        let recordsByRenderedFileID = Dictionary(
            uniqueKeysWithValues: records.compactMap { record -> (UUID, DemandRecord)? in
                guard rendered.contains(where: { $0.fileID == record.fileID }) else { return nil }
                return (record.fileID, record)
            }
        )
        let candidates = rendered.compactMap { entry -> WorkspaceCodemapOperationPresentationCandidate? in
            guard let record = recordsByRenderedFileID[entry.fileID],
                  case let .ready(ready) = record.result
            else { return nil }
            return WorkspaceCodemapOperationPresentationCandidate(
                fileID: entry.fileID,
                rootEpoch: entry.rootEpoch,
                catalogGeneration: ready.ticket.catalogGeneration,
                logicalPath: entry.logicalPath
            )
        }
        let bundles = bundleReceipts(from: recordsByRenderedFileID, renderedEntries: rendered)
        let readyTickets = bundles.flatMap(\.entries).map(\.ticket)
        let receipt: WorkspaceCodemapOperationPresentationPublicationReceipt? = if rendered.isEmpty {
            nil
        } else {
            WorkspaceCodemapOperationPresentationPublicationReceipt(
                requestID: UUID(),
                rootScope: rootScope,
                logicalRootDisplayNamesByRootID: Dictionary(
                    rendered.map { ($0.rootEpoch.rootID, $0.logicalPath.rootDisplayName) },
                    uniquingKeysWith: { current, _ in current }
                ),
                completeRootSet: completeRootSet,
                completeRootCatalogs: [],
                candidates: candidates,
                demandTickets: readyTickets,
                bundles: bundles,
                automaticReceipt: automaticReceipt
            )
        }
        let coverage = coverage(entryCount: rendered.count, requestedCount: fileIDs.count, issues: issues)
        let presentation = WorkspaceCodemapOperationPresentation(
            orderedEntries: rendered,
            coverage: coverage,
            issues: issues,
            publicationReceipt: receipt
        )
        return PresentationBuildResult(presentation: presentation, ownedTickets: ownedTickets)
    }

    func projectionDeadlineUptimeNanoseconds(
        clock: ContinuousClock,
        deadline: ContinuousClock.Instant
    ) -> UInt64 {
        let remaining = clock.now.duration(to: deadline)
        guard remaining > .zero else { return DispatchTime.now().uptimeNanoseconds }
        let components = remaining.components
        guard components.seconds >= 0, components.attoseconds >= 0 else {
            return DispatchTime.now().uptimeNanoseconds
        }
        let seconds = UInt64(components.seconds)
        let attoseconds = UInt64(components.attoseconds)
        let (secondNanoseconds, secondsOverflow) = seconds.multipliedReportingOverflow(by: 1_000_000_000)
        let (combinedNanoseconds, combinedOverflow) = secondNanoseconds.addingReportingOverflow(
            attoseconds / 1_000_000_000
        )
        let remainingNanoseconds = secondsOverflow || combinedOverflow
            ? UInt64.max
            : combinedNanoseconds
        let now = DispatchTime.now().uptimeNanoseconds
        let (value, overflow) = now.addingReportingOverflow(remainingNanoseconds)
        return overflow ? UInt64.max : value
    }

    func waitForReadiness(
        _ initial: WorkspaceCodemapArtifactDemandResult
    ) async throws -> WorkspaceCodemapArtifactDemandResult {
        var result = initial
        var round = 0
        var backoff = max(0, policy.initialBackoffMilliseconds)
        let clock = ContinuousClock()
        let start = clock.now
        while case let .pending(ticket) = result {
            try Task.checkCancellation()
            if round >= policy.maximumReadinessRounds || clock.now - start >= policy.maximumTotalWait {
                return .pending(ticket)
            }
            if backoff > 0 {
                try await waiter.sleep(.milliseconds(backoff))
            }
            result = await store.codemapArtifactDemandStatus(ticket)
            round += 1
            backoff = min(max(backoff * 2, policy.initialBackoffMilliseconds), policy.maximumBackoffMilliseconds)
        }
        return result
    }

    func render(
        records: [DemandRecord],
        issues: inout [WorkspaceCodemapOperationIssue]
    ) -> [WorkspaceCodemapOperationRenderedEntry] {
        var bundleIDsByRootEpoch: [WorkspaceCodemapRootEpoch: WorkspaceCodemapFrozenPresentationBundleID] = [:]
        var entries: [WorkspaceCodemapOperationRenderedEntry] = []
        for record in records {
            switch record.result {
            case let .ready(ready):
                let bundleID = bundleIDsByRootEpoch[ready.ticket.rootEpoch, default: WorkspaceCodemapFrozenPresentationBundleID()]
                bundleIDsByRootEpoch[ready.ticket.rootEpoch] = bundleID
                do {
                    guard let rendered = try ready.handle.renderedCodemap(displayPath: record.logicalPath.displayPath) else {
                        issues.append(.renderUnavailable(rootEpoch: ready.ticket.rootEpoch, reason: .noRenderableCodemap(record.fileID)))
                        continue
                    }
                    entries.append(WorkspaceCodemapOperationRenderedEntry(
                        bundleID: bundleID,
                        fileID: record.fileID,
                        rootEpoch: ready.ticket.rootEpoch,
                        artifactKey: ready.snapshot.artifactKey,
                        logicalPath: record.logicalPath,
                        text: rendered.text,
                        tokenCount: rendered.tokenCount
                    ))
                } catch {
                    issues.append(.renderUnavailable(rootEpoch: ready.ticket.rootEpoch, reason: .handleRevoked(record.fileID)))
                }
            case let .pending(ticket):
                issues.append(.pending(fileID: record.fileID, ticket: ticket))
            case let .unavailable(reason):
                issues.append(.unavailable(fileID: record.fileID, reason: reason))
            }
        }
        return entries
    }

    func bundleReceipts(
        from recordsByRenderedFileID: [UUID: DemandRecord],
        renderedEntries: [WorkspaceCodemapOperationRenderedEntry]
    ) -> [WorkspaceCodemapOperationPresentationBundleReceipt] {
        var grouped: [WorkspaceCodemapRootEpoch: [WorkspaceCodemapFrozenPresentationEntry]] = [:]
        var bundleIDsByRootEpoch: [WorkspaceCodemapRootEpoch: WorkspaceCodemapFrozenPresentationBundleID] = [:]
        for entry in renderedEntries {
            guard let record = recordsByRenderedFileID[entry.fileID],
                  case let .ready(ready) = record.result
            else { continue }
            bundleIDsByRootEpoch[entry.rootEpoch] = entry.bundleID
            let outcome = (try? ready.handle.outcome()) ?? WorkspaceCodemapLiveArtifactOutcome.decodeFailed
            grouped[entry.rootEpoch, default: []].append(WorkspaceCodemapFrozenPresentationEntry(
                ticket: ready.ticket,
                logicalPath: entry.logicalPath,
                artifactKey: entry.artifactKey,
                outcome: outcome
            ))
        }
        return grouped.keys.sorted(by: workspaceCodemapRootEpochPrecedes).map { rootEpoch in
            WorkspaceCodemapOperationPresentationBundleReceipt(
                bundleID: bundleIDsByRootEpoch[rootEpoch] ?? WorkspaceCodemapFrozenPresentationBundleID(),
                rootEpoch: rootEpoch,
                entries: grouped[rootEpoch] ?? []
            )
        }
    }

    func coverage(
        entryCount: Int,
        requestedCount: Int,
        issues: [WorkspaceCodemapOperationIssue]
    ) -> WorkspaceCodemapOperationPresentationCoverage {
        if issues.isEmpty { return .complete }
        if issues.contains(where: { issue in
            if case .pending = issue { return true }
            return false
        }) {
            return entryCount > 0 ? .partial(issues) : .pending(issues)
        }
        return entryCount > 0 ? .partial(issues) : .unavailable(issues)
    }

    func publicationStaleIssues(
        _ receipt: WorkspaceCodemapOperationPresentationPublicationReceipt
    ) async -> [WorkspaceCodemapOperationIssue] {
        var issues: [WorkspaceCodemapOperationIssue] = []
        for ticket in receipt.demandTickets {
            switch await store.codemapArtifactDemandStatus(ticket) {
            case .ready:
                continue
            case .pending:
                issues.append(.publicationStale(.demand(ticket)))
            case .unavailable:
                issues.append(.publicationStale(.demand(ticket)))
            }
        }
        if let automaticReceipt = receipt.automaticReceipt {
            switch await store.revalidateAutomaticCodemapSelectionForPublication(
                automaticReceipt,
                rootScope: receipt.rootScope
            ) {
            case .current:
                break
            case let .stale(reason):
                issues.append(.publicationStale(.automatic(reason)))
            }
        }
        return issues
    }

    func presentation(
        from presentation: WorkspaceCodemapOperationPresentation,
        adding newIssues: [WorkspaceCodemapOperationIssue],
        forceUnavailableWhenEmpty: Bool
    ) -> WorkspaceCodemapOperationPresentation {
        let issues = presentation.issues + newIssues
        if forceUnavailableWhenEmpty {
            return WorkspaceCodemapOperationPresentation(
                id: presentation.id,
                orderedEntries: [],
                coverage: .unavailable(issues),
                issues: issues,
                publicationReceipt: nil
            )
        }
        let coverage: WorkspaceCodemapOperationPresentationCoverage = if presentation.orderedEntries.isEmpty {
            .unavailable(issues)
        } else {
            .partial(issues)
        }
        return WorkspaceCodemapOperationPresentation(
            id: presentation.id,
            orderedEntries: presentation.orderedEntries,
            coverage: coverage,
            issues: issues,
            publicationReceipt: presentation.publicationReceipt
        )
    }

    func release(tickets: [WorkspaceCodemapArtifactDemandTicket]) async {
        for ticket in tickets {
            _ = await store.cancelCodemapArtifactDemand(ticket)
        }
    }
}

private extension WorkspaceCodemapStructureIssue {
    static func operation(_ issue: WorkspaceCodemapOperationIssue) -> WorkspaceCodemapStructureIssue {
        switch issue {
        case .coordinationUnavailable:
            .traversalUnavailable(.emptySeeds)
        case .cancelled:
            .traversalUnavailable(.emptySeeds)
        case let .candidate(candidate):
            .candidate(candidate)
        case let .pending(fileID, ticket):
            .artifactPending(fileID: fileID, ticket: ticket)
        case let .unavailable(fileID, reason):
            .artifactUnavailable(fileID: fileID, reason: reason)
        case let .freezeUnavailable(rootEpoch, reason):
            .freezeUnavailable(rootEpoch: rootEpoch, reason: reason)
        case let .renderUnavailable(rootEpoch, reason):
            .renderUnavailable(rootEpoch: rootEpoch, reason: reason)
        case let .publicationStale(reason):
            .publicationStale(.presentation(reason))
        case .automatic:
            .traversalUnavailable(.emptySeeds)
        }
    }
}
