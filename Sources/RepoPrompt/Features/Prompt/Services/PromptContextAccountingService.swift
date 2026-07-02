import Foundation

/// Dormant value-based orchestration for resolving persisted workspace selections into prompt-entry
/// snapshots and token-accounting inputs. This service intentionally has no PromptViewModel or
/// TokenCountingViewModel dependencies so callers can opt in incrementally.
struct PromptContextAccountingRequest {
    let selection: StoredSelection
    let promptText: String
    let selectedInstructionsText: String
    let duplicateUserInstructionsAtTop: Bool
    let fileTree: TokenCalculationFileTreeInput
    let codeMapUsage: CodeMapUsage
    let filePathDisplay: FilePathDisplay
    let rootScope: WorkspaceLookupRootScope
    let pathLocateProfile: PathLocateProfile

    init(
        selection: StoredSelection,
        promptText: String = "",
        selectedInstructionsText: String = "",
        duplicateUserInstructionsAtTop: Bool = false,
        fileTree: TokenCalculationFileTreeInput = .none,
        codeMapUsage: CodeMapUsage = .auto,
        filePathDisplay: FilePathDisplay = .relative,
        rootScope: WorkspaceLookupRootScope = .allLoaded,
        pathLocateProfile: PathLocateProfile = .uiAssisted
    ) {
        self.selection = selection
        self.promptText = promptText
        self.selectedInstructionsText = selectedInstructionsText
        self.duplicateUserInstructionsAtTop = duplicateUserInstructionsAtTop
        self.fileTree = fileTree
        self.codeMapUsage = codeMapUsage
        self.filePathDisplay = filePathDisplay
        self.rootScope = rootScope
        self.pathLocateProfile = pathLocateProfile
    }

    func withFileTree(_ fileTree: TokenCalculationFileTreeInput) -> PromptContextAccountingRequest {
        PromptContextAccountingRequest(
            selection: selection,
            promptText: promptText,
            selectedInstructionsText: selectedInstructionsText,
            duplicateUserInstructionsAtTop: duplicateUserInstructionsAtTop,
            fileTree: fileTree,
            codeMapUsage: codeMapUsage,
            filePathDisplay: filePathDisplay,
            rootScope: rootScope,
            pathLocateProfile: pathLocateProfile
        )
    }
}

struct PromptContextAccountingResult {
    let tokenResult: TokenCalculationResult
    let resolvedEntries: [ResolvedPromptFileEntry]
    let promptFileEntrySnapshots: [PromptFileEntrySnapshot]
    let tokenCalculationSnapshot: TokenCalculationSnapshot
    let missingPaths: [String]
    let invalidPaths: [String]
    let codemapPresentation: WorkspaceCodemapOperationPresentation
    let codemapFileIDsUsed: Set<UUID>
}

struct PromptContextEntryResolution {
    let entries: [ResolvedPromptFileEntry]
    let missingPaths: [String]
    let invalidPaths: [String]
    let codemapPresentation: WorkspaceCodemapOperationPresentation
}

enum PromptContextAccountingContentPolicy {
    case loadContent
    case cachedOnly
}

private struct SelectedFileAccountingReadRequest {
    let selectedPathIndex: Int
    let selectedPath: String
    let file: WorkspaceFileRecord
}

private struct SelectedFileAccountingReadResult {
    let selectedPathIndex: Int
    let content: String?
    let errorDescription: String?
}

actor PromptContextAccountingService {
    private static let selectedFileAccountingReadConcurrencyLimit = 4

    private let tokenCalculationService: TokenCalculationService

    init(tokenCalculationService: TokenCalculationService = TokenCalculationService()) {
        self.tokenCalculationService = tokenCalculationService
    }

    func withPromptStats<Value>(
        request: PromptContextAccountingRequest,
        store: WorkspaceFileContextStore,
        lookupContext: WorkspaceLookupContext,
        fileTreeSnapshotRequest: WorkspaceFileTreeSnapshotRequest? = nil,
        codemapDisplayPathResolver: ((ResolvedPromptFileEntry) -> String?)? = nil,
        operation: (PromptContextAccountingResult) async throws -> Value
    ) async throws -> Value {
        let plan = await WorkspaceCodemapPresentationIntentResolver.plan(
            codeMapUsage: request.codeMapUsage,
            selection: request.selection,
            store: store,
            rootScope: request.rootScope,
            profile: request.pathLocateProfile
        )
        let rootDisplayNames = await logicalRootDisplayNamesByRootID(
            store: store,
            rootScope: request.rootScope
        )
        return try await WorkspaceCodemapPresentationCoordinator(store: store).withPresentation(
            for: plan.intent,
            rootScope: request.rootScope,
            logicalRootDisplayNamesByRootID: rootDisplayNames
        ) { presentation in
            let merged = WorkspaceCodemapPresentationIntentResolver.merging(
                presentation,
                preflightIssues: plan.preflightIssues
            )
            let effectiveRequest: PromptContextAccountingRequest
            if let fileTreeSnapshotRequest {
                let snapshot = await store.makeFileTreeSelectionSnapshot(
                    selection: request.selection,
                    request: fileTreeSnapshotRequest,
                    codemapPresentation: merged,
                    profile: request.pathLocateProfile
                )
                effectiveRequest = request.withFileTree(.snapshot(snapshot))
            } else {
                effectiveRequest = request
            }
            let result = await calculatePromptStats(
                request: effectiveRequest,
                store: store,
                codemapPresentation: merged,
                codemapDisplayPathResolver: codemapDisplayPathResolver
            )
            try Task.checkCancellation()
            return try await operation(result)
        }
    }

    func calculatePromptStats(
        request: PromptContextAccountingRequest,
        store: WorkspaceFileContextStore,
        codemapPresentation frozenPresentation: WorkspaceCodemapOperationPresentation? = nil,
        codemapDisplayPathResolver: ((ResolvedPromptFileEntry) -> String?)? = nil
    ) async -> PromptContextAccountingResult {
        #if DEBUG
            let calculateStartMS = PromptTokenRecountDiagnostics.start()
            var calculateBeginFields = PromptTokenRecountDiagnostics.selectionFields(request.selection)
            calculateBeginFields["codeMapUsage"] = "\(request.codeMapUsage)"
            calculateBeginFields["rootScope"] = "\(request.rootScope)"
            PromptTokenRecountDiagnostics.event(
                "tokenRecount.accounting.calculate.begin",
                fields: calculateBeginFields
            )
            let codemapStartMS = PromptTokenRecountDiagnostics.start()
        #endif
        let codemapPresentation: WorkspaceCodemapOperationPresentation = if let frozenPresentation {
            frozenPresentation
        } else {
            await resolveCodemapPresentation(request: request, store: store, logicalRootDisplayNamesByRootID: [:])
        }
        let codemapEntries = codemapPresentation.renderedEntriesByFileID
        #if DEBUG
            PromptTokenRecountDiagnostics.event(
                "tokenRecount.accounting.codemapPresentation.end",
                fields: [
                    "codemapEntries": "\(codemapEntries.count)",
                    "duration": codemapStartMS.map { PromptTokenRecountDiagnostics.formatElapsedMS(since: $0) } ?? "notMeasured"
                ]
            )
            let resolveStartMS = PromptTokenRecountDiagnostics.start()
        #endif
        let resolution = await resolveEntries(
            selection: request.selection,
            store: store,
            rootScope: request.rootScope,
            profile: request.pathLocateProfile,
            codeMapUsage: request.codeMapUsage,
            codemapPresentation: codemapPresentation,
            contentPolicy: .loadContent
        )
        #if DEBUG
            PromptTokenRecountDiagnostics.event(
                "tokenRecount.accounting.resolveEntries.end",
                fields: [
                    "entries": "\(resolution.entries.count)",
                    "missingPaths": "\(resolution.missingPaths.count)",
                    "invalidPaths": "\(resolution.invalidPaths.count)",
                    "duration": resolveStartMS.map { PromptTokenRecountDiagnostics.formatElapsedMS(since: $0) } ?? "notMeasured"
                ]
            )
            let snapshotStartMS = PromptTokenRecountDiagnostics.start()
        #endif
        let snapshots = makePromptFileEntrySnapshots(
            from: resolution.entries,
            codemapPresentation: codemapPresentation,
            filePathDisplay: request.filePathDisplay,
            displayPathResolver: codemapDisplayPathResolver
        )
        #if DEBUG
            PromptTokenRecountDiagnostics.event(
                "tokenRecount.accounting.promptSnapshots.end",
                fields: [
                    "promptEntries": "\(snapshots.count)",
                    "duration": snapshotStartMS.map { PromptTokenRecountDiagnostics.formatElapsedMS(since: $0) } ?? "notMeasured"
                ]
            )
        #endif
        let calculationSnapshot = TokenCalculationSnapshot(
            promptText: request.promptText,
            selectedInstructionsText: request.selectedInstructionsText,
            duplicateUserInstructionsAtTop: request.duplicateUserInstructionsAtTop,
            promptEntries: snapshots,
            fileTree: request.fileTree
        )
        #if DEBUG
            let tokenServiceStartMS = PromptTokenRecountDiagnostics.start()
            PromptTokenRecountDiagnostics.event(
                "tokenRecount.accounting.tokenService.begin",
                fields: ["promptEntries": "\(calculationSnapshot.promptEntries.count)"]
            )
        #endif
        let tokenResult = await tokenCalculationService.calculatePromptStats(snapshot: calculationSnapshot)
        #if DEBUG
            PromptTokenRecountDiagnostics.event(
                "tokenRecount.accounting.tokenService.end",
                fields: [
                    "totalTokens": "\(tokenResult.totalTokenCount)",
                    "fileTokens": "\(tokenResult.totalTokenCountFilesOnly)",
                    "duration": tokenServiceStartMS.map { PromptTokenRecountDiagnostics.formatElapsedMS(since: $0) } ?? "notMeasured"
                ]
            )
        #endif
        let usedCodemaps = Set(snapshots.compactMap { snapshot in
            snapshot.isCodemapRequested && snapshot.codeMapContent != nil ? snapshot.fileID : nil
        })
        #if DEBUG
            PromptTokenRecountDiagnostics.event(
                "tokenRecount.accounting.calculate.end",
                fields: [
                    "usedCodemaps": "\(usedCodemaps.count)",
                    "duration": calculateStartMS.map { PromptTokenRecountDiagnostics.formatElapsedMS(since: $0) } ?? "notMeasured"
                ]
            )
        #endif
        return PromptContextAccountingResult(
            tokenResult: tokenResult,
            resolvedEntries: resolution.entries,
            promptFileEntrySnapshots: snapshots,
            tokenCalculationSnapshot: calculationSnapshot,
            missingPaths: resolution.missingPaths,
            invalidPaths: resolution.invalidPaths,
            codemapPresentation: codemapPresentation,
            codemapFileIDsUsed: usedCodemaps
        )
    }

    func resolveEntries(
        selection: StoredSelection,
        store: WorkspaceFileContextStore,
        rootScope: WorkspaceLookupRootScope = .allLoaded,
        profile: PathLocateProfile = .uiAssisted,
        codeMapUsage: CodeMapUsage = .auto,
        codemapPresentation frozenPresentation: WorkspaceCodemapOperationPresentation? = nil,
        contentPolicy: PromptContextAccountingContentPolicy = .loadContent,
        codemapLogicalRootDisplayNamesByRootID: [UUID: String] = [:]
    ) async -> PromptContextEntryResolution {
        let codemapPresentation: WorkspaceCodemapOperationPresentation = if let frozenPresentation {
            frozenPresentation
        } else {
            await resolveCodemapPresentation(
                request: PromptContextAccountingRequest(selection: selection, codeMapUsage: codeMapUsage, rootScope: rootScope, pathLocateProfile: profile),
                store: store,
                logicalRootDisplayNamesByRootID: codemapLogicalRootDisplayNamesByRootID
            )
        }
        return await resolveEntries(
            selection: selection,
            store: store,
            rootScope: rootScope,
            profile: profile,
            codeMapUsage: codeMapUsage,
            codemapPresentation: codemapPresentation,
            contentPolicy: contentPolicy
        )
    }

    private func resolveEntries(
        selection: StoredSelection,
        store: WorkspaceFileContextStore,
        rootScope: WorkspaceLookupRootScope,
        profile: PathLocateProfile,
        codeMapUsage: CodeMapUsage,
        codemapPresentation: WorkspaceCodemapOperationPresentation,
        contentPolicy: PromptContextAccountingContentPolicy
    ) async -> PromptContextEntryResolution {
        #if DEBUG
            let resolveStartMS = PromptTokenRecountDiagnostics.start()
            var resolveBeginFields = PromptTokenRecountDiagnostics.selectionFields(selection)
            resolveBeginFields["codemapEntries"] = "\(codemapPresentation.orderedEntries.count)"
            resolveBeginFields["codeMapUsage"] = "\(codeMapUsage)"
            PromptTokenRecountDiagnostics.event(
                "tokenRecount.accounting.resolveEntries.begin",
                fields: resolveBeginFields
            )
        #endif
        var entries: [ResolvedPromptFileEntry] = []
        var missingPaths: [String] = []
        var invalidPaths: [String] = []
        var seenIDs = Set<ResolvedPromptFileEntryID>()
        var selectedFileIDs = Set<UUID>()

        #if DEBUG
            let selectedPathsStartMS = PromptTokenRecountDiagnostics.start()
            let selectedPathsDebugState = PromptTokenRecountDiagnostics.SelectedPathsState(selectedPathCount: selection.selectedPaths.count)
            let selectedPathsWatchdog = Task {
                try? await Task.sleep(nanoseconds: 12_000_000_000)
                let snapshot = selectedPathsDebugState.snapshot()
                guard snapshot["finished"] != "true" else { return }
                PromptTokenRecountDiagnostics.event(
                    "tokenRecount.accounting.resolveEntries.selectedPaths.watchdog",
                    fields: snapshot
                )
            }
            PromptTokenRecountDiagnostics.event(
                "tokenRecount.accounting.resolveEntries.selectedPaths.begin",
                fields: PromptTokenRecountDiagnostics.selectionFields(selection)
            )
        #endif
        #if DEBUG
            selectedPathsDebugState.beginLookupBatch()
            let selectedPathLookupBatchStartMS = PromptTokenRecountDiagnostics.start()
            PromptTokenRecountDiagnostics.event(
                "tokenRecount.accounting.resolveEntries.selectedPaths.lookupBatch.begin",
                fields: [
                    "selectedPaths": "\(selection.selectedPaths.count)",
                    "rootScope": "\(rootScope)",
                    "profile": "\(profile)"
                ]
            )
        #endif
        let selectedPathLookupRequests = selection.selectedPaths.map {
            WorkspacePathLookupRequest(userPath: $0, profile: profile, rootScope: rootScope)
        }
        let selectedPathLookupResults = await store.lookupPaths(selectedPathLookupRequests)
        guard !Task.isCancelled else {
            return PromptContextEntryResolution(entries: entries, missingPaths: missingPaths, invalidPaths: invalidPaths, codemapPresentation: codemapPresentation)
        }
        #if DEBUG
            selectedPathsDebugState.finishLookupBatch()
            let lookupResolvedFiles = selection.selectedPaths.reduce(into: 0) { count, path in
                if selectedPathLookupResults[path]?.file != nil {
                    count += 1
                }
            }
            let lookupResolvedFolders = selection.selectedPaths.reduce(into: 0) { count, path in
                if selectedPathLookupResults[path]?.folder != nil {
                    count += 1
                }
            }
            let lookupMissingResults = selection.selectedPaths.reduce(into: 0) { count, path in
                if selectedPathLookupResults[path] == nil {
                    count += 1
                }
            }
            PromptTokenRecountDiagnostics.event(
                "tokenRecount.accounting.resolveEntries.selectedPaths.lookupBatch.end",
                fields: selectedPathsDebugState.snapshot().merging([
                    "selectedPaths": "\(selection.selectedPaths.count)",
                    "requests": "\(selectedPathLookupRequests.count)",
                    "results": "\(selectedPathLookupResults.count)",
                    "resolvedFiles": "\(lookupResolvedFiles)",
                    "resolvedFolders": "\(lookupResolvedFolders)",
                    "missingLookupResults": "\(lookupMissingResults)",
                    "duration": selectedPathLookupBatchStartMS.map { PromptTokenRecountDiagnostics.formatElapsedMS(since: $0) } ?? "notMeasured"
                ]) { current, _ in current }
            )
        #endif
        var selectedPathResultsByIndex: [Int: WorkspacePathLookupResult] = [:]
        var selectedPathFallbackLookups = 0
        for (selectedPathIndex, path) in selection.selectedPaths.enumerated() {
            guard !Task.isCancelled else {
                return PromptContextEntryResolution(entries: entries, missingPaths: missingPaths, invalidPaths: invalidPaths, codemapPresentation: codemapPresentation)
            }
            if let result = selectedPathLookupResults[path] {
                selectedPathResultsByIndex[selectedPathIndex] = result
            } else if let result = await store.lookupPath(path, profile: profile, rootScope: rootScope) {
                selectedPathResultsByIndex[selectedPathIndex] = result
                selectedPathFallbackLookups += 1
            }
        }
        #if DEBUG
            if selectedPathFallbackLookups > 0 {
                PromptTokenRecountDiagnostics.event(
                    "tokenRecount.accounting.resolveEntries.selectedPaths.lookupBatch.fallback",
                    fields: selectedPathsDebugState.snapshot().merging([
                        "fallbackLookups": "\(selectedPathFallbackLookups)",
                        "selectedPaths": "\(selection.selectedPaths.count)"
                    ]) { current, _ in current }
                )
            }
        #endif

        var selectedFileReadRequests: [SelectedFileAccountingReadRequest] = []
        var selectedCodemapReadSkips = 0
        for (selectedPathIndex, path) in selection.selectedPaths.enumerated() {
            guard !Task.isCancelled else {
                return PromptContextEntryResolution(entries: entries, missingPaths: missingPaths, invalidPaths: invalidPaths, codemapPresentation: codemapPresentation)
            }
            #if DEBUG
                selectedPathsDebugState.beginPath(index: selectedPathIndex, path: path)
                PromptTokenRecountDiagnostics.event(
                    "tokenRecount.accounting.resolveEntries.selectedPath.begin",
                    fields: selectedPathsDebugState.snapshot()
                )
            #endif
            guard let result = selectedPathResultsByIndex[selectedPathIndex] else {
                #if DEBUG
                    let issue = await store.exactPathResolutionIssue(for: path, kind: .either, rootScope: rootScope)
                    selectedPathsDebugState.resolutionEnd(resolvedKind: PromptTokenRecountDiagnostics.SelectedPathsState.resolvedKind(for: issue))
                    PromptTokenRecountDiagnostics.event(
                        "tokenRecount.accounting.resolveEntries.selectedPath.resolution.end",
                        fields: selectedPathsDebugState.snapshot()
                    )
                #endif
                continue
            }
            #if DEBUG
                let resolvedKind = result.file != nil ? "file" : (result.folder != nil ? "folder" : "unresolved")
                selectedPathsDebugState.resolutionEnd(resolvedKind: resolvedKind)
                PromptTokenRecountDiagnostics.event(
                    "tokenRecount.accounting.resolveEntries.selectedPath.resolution.end",
                    fields: selectedPathsDebugState.snapshot()
                )
            #endif
            if let file = result.file {
                let useSelectedCodemap = codeMapUsage == .selected && codemapPresentation.renderedEntriesByFileID[file.id] != nil
                if useSelectedCodemap {
                    selectedCodemapReadSkips += 1
                } else {
                    selectedFileReadRequests.append(
                        SelectedFileAccountingReadRequest(
                            selectedPathIndex: selectedPathIndex,
                            selectedPath: path,
                            file: file
                        )
                    )
                }
            }
        }

        #if DEBUG
            let selectedFileReadBatchStartMS = PromptTokenRecountDiagnostics.start()
            selectedPathsDebugState.beginReadBatch(
                scheduled: selectedFileReadRequests.count,
                limit: Self.selectedFileAccountingReadConcurrencyLimit
            )
            PromptTokenRecountDiagnostics.event(
                "tokenRecount.accounting.resolveEntries.selectedPaths.readBatch.begin",
                fields: selectedPathsDebugState.snapshot().merging([
                    "scheduledReads": "\(selectedFileReadRequests.count)",
                    "concurrencyLimit": "\(Self.selectedFileAccountingReadConcurrencyLimit)",
                    "selectedFileResults": "\(selectedFileReadRequests.count + selectedCodemapReadSkips)",
                    "skippedCodemapReads": "\(selectedCodemapReadSkips)"
                ]) { current, _ in current }
            )
        #endif
        let selectedFileReadResults = await withTaskGroup(
            of: SelectedFileAccountingReadResult.self,
            returning: [Int: SelectedFileAccountingReadResult].self
        ) { group in
            let concurrencyLimit = Self.selectedFileAccountingReadConcurrencyLimit
            var iterator = selectedFileReadRequests.makeIterator()
            var activeReads = 0
            var results: [Int: SelectedFileAccountingReadResult] = [:]

            func enqueueNextReadIfAvailable() {
                guard !Task.isCancelled,
                      activeReads < concurrencyLimit,
                      let request = iterator.next()
                else {
                    return
                }
                activeReads += 1
                group.addTask {
                    guard !Task.isCancelled else {
                        return SelectedFileAccountingReadResult(
                            selectedPathIndex: request.selectedPathIndex,
                            content: nil,
                            errorDescription: "cancelled"
                        )
                    }
                    #if DEBUG
                        selectedPathsDebugState.beginBatchRead(index: request.selectedPathIndex, path: request.selectedPath, file: request.file)
                    #endif
                    let content: String?
                    let errorDescription: String?
                    switch contentPolicy {
                    case .loadContent:
                        do {
                            content = try await store.readContent(
                                rootID: request.file.rootID,
                                relativePath: request.file.standardizedRelativePath,
                                workloadClass: .promptAccounting
                            )
                            errorDescription = nil
                        } catch {
                            content = nil
                            errorDescription = String(String(describing: error).prefix(120))
                        }
                    case .cachedOnly:
                        content = await store.cachedSearchContentSnapshot(for: request.file).content
                        errorDescription = nil
                    }
                    #if DEBUG
                        selectedPathsDebugState.finishBatchRead(errorDescription: errorDescription)
                        if let errorDescription {
                            PromptTokenRecountDiagnostics.event(
                                "tokenRecount.accounting.resolveEntries.selectedPath.read.error",
                                fields: selectedPathsDebugState.snapshot().merging([
                                    "batch": "true",
                                    "error": errorDescription
                                ]) { current, _ in current }
                            )
                        }
                        if selectedPathsDebugState.shouldLogReadProgress() {
                            PromptTokenRecountDiagnostics.event(
                                "tokenRecount.accounting.resolveEntries.selectedPaths.read.progress",
                                fields: selectedPathsDebugState.snapshot().merging(["batch": "true"]) { current, _ in current }
                            )
                        }
                    #endif
                    return SelectedFileAccountingReadResult(
                        selectedPathIndex: request.selectedPathIndex,
                        content: content,
                        errorDescription: errorDescription
                    )
                }
            }

            for _ in 0 ..< concurrencyLimit {
                enqueueNextReadIfAvailable()
            }

            while let result = await group.next() {
                activeReads -= 1
                results[result.selectedPathIndex] = result
                if Task.isCancelled {
                    group.cancelAll()
                    break
                }
                enqueueNextReadIfAvailable()
            }

            return results
        }
        guard !Task.isCancelled else {
            return PromptContextEntryResolution(entries: entries, missingPaths: missingPaths, invalidPaths: invalidPaths, codemapPresentation: codemapPresentation)
        }
        #if DEBUG
            let readBatchErrors = selectedFileReadResults.values.reduce(into: 0) { count, result in
                if result.errorDescription != nil {
                    count += 1
                }
            }
            PromptTokenRecountDiagnostics.event(
                "tokenRecount.accounting.resolveEntries.selectedPaths.readBatch.end",
                fields: selectedPathsDebugState.snapshot().merging([
                    "scheduledReads": "\(selectedFileReadRequests.count)",
                    "completedReads": "\(selectedFileReadResults.count)",
                    "errorReads": "\(readBatchErrors)",
                    "concurrencyLimit": "\(Self.selectedFileAccountingReadConcurrencyLimit)",
                    "duration": selectedFileReadBatchStartMS.map { PromptTokenRecountDiagnostics.formatElapsedMS(since: $0) } ?? "notMeasured"
                ]) { current, _ in current }
            )
        #endif

        for (selectedPathIndex, path) in selection.selectedPaths.enumerated() {
            guard !Task.isCancelled else {
                return PromptContextEntryResolution(entries: entries, missingPaths: missingPaths, invalidPaths: invalidPaths, codemapPresentation: codemapPresentation)
            }
            guard let result = selectedPathResultsByIndex[selectedPathIndex] else {
                #if DEBUG
                    selectedPathsDebugState.beginAssembly(index: selectedPathIndex, path: path, resolvedKind: "missing")
                #endif
                missingPaths.append(path)
                #if DEBUG
                    PromptTokenRecountDiagnostics.event(
                        "tokenRecount.accounting.resolveEntries.selectedPath.end",
                        fields: selectedPathsDebugState.snapshot().merging(["outcome": "missing"]) { current, _ in current }
                    )
                #endif
                continue
            }

            if let file = result.file {
                #if DEBUG
                    selectedPathsDebugState.beginAssembly(index: selectedPathIndex, path: path, resolvedKind: "file")
                #endif
                selectedFileIDs.insert(file.id)
                let ranges = sliceRanges(for: path, file: file, location: result.location, in: selection.slices)
                let useSelectedCodemap = codeMapUsage == .selected && codemapPresentation.renderedEntriesByFileID[file.id] != nil
                let content = useSelectedCodemap ? nil : selectedFileReadResults[selectedPathIndex]?.content
                let entry = ResolvedPromptFileEntry(
                    file: file,
                    isCodemap: useSelectedCodemap,
                    lineRanges: useSelectedCodemap ? nil : ranges,
                    mode: useSelectedCodemap ? .codemap : ((ranges?.isEmpty == false) ? .sliced : .fullFile),
                    loadedContent: content ?? nil,
                    rootFolderPath: result.location.rootPath
                )
                append(entry, to: &entries, seenIDs: &seenIDs)
                #if DEBUG
                    PromptTokenRecountDiagnostics.event(
                        "tokenRecount.accounting.resolveEntries.selectedPath.end",
                        fields: selectedPathsDebugState.snapshot().merging(["outcome": "file"]) { current, _ in current }
                    )
                #endif
            } else if let folder = result.folder {
                #if DEBUG
                    selectedPathsDebugState.beginAssembly(index: selectedPathIndex, path: path, resolvedKind: "folder")
                    selectedPathsDebugState.setPhase("folderList")
                #endif
                let files = await store.files(inRoot: folder.rootID)
                let prefix = folder.standardizedRelativePath
                #if DEBUG
                    let descendantCount = files.reduce(into: 0) { count, file in
                        if prefix.isEmpty || file.standardizedRelativePath == prefix || file.standardizedRelativePath.hasPrefix(prefix + "/") {
                            count += 1
                        }
                    }
                    selectedPathsDebugState.folderExpansionEnd(descendantCount: descendantCount)
                    PromptTokenRecountDiagnostics.event(
                        "tokenRecount.accounting.resolveEntries.selectedPath.folderExpansion.end",
                        fields: selectedPathsDebugState.snapshot().merging(["descendantCount": "\(descendantCount)"]) { current, _ in current }
                    )
                #endif
                for file in files where prefix.isEmpty || file.standardizedRelativePath == prefix || file.standardizedRelativePath.hasPrefix(prefix + "/") {
                    guard !Task.isCancelled else {
                        return PromptContextEntryResolution(entries: entries, missingPaths: missingPaths, invalidPaths: invalidPaths, codemapPresentation: codemapPresentation)
                    }
                    selectedFileIDs.insert(file.id)
                    let useSelectedCodemap = codeMapUsage == .selected && codemapPresentation.renderedEntriesByFileID[file.id] != nil
                    let content: String?
                    if useSelectedCodemap {
                        content = nil
                    } else {
                        #if DEBUG
                            selectedPathsDebugState.beginRead(file: file)
                        #endif
                        do {
                            content = switch contentPolicy {
                            case .loadContent:
                                try await store.readContent(
                                    rootID: file.rootID,
                                    relativePath: file.standardizedRelativePath,
                                    workloadClass: .promptAccounting
                                )
                            case .cachedOnly:
                                await store.cachedSearchContentSnapshot(for: file).content
                            }
                        } catch {
                            content = nil
                            #if DEBUG
                                PromptTokenRecountDiagnostics.event(
                                    "tokenRecount.accounting.resolveEntries.selectedPath.read.error",
                                    fields: selectedPathsDebugState.snapshot().merging(["error": String(String(describing: error).prefix(120))]) { current, _ in current }
                                )
                            #endif
                        }
                        #if DEBUG
                            selectedPathsDebugState.finishRead()
                            if selectedPathsDebugState.shouldLogReadProgress() {
                                PromptTokenRecountDiagnostics.event(
                                    "tokenRecount.accounting.resolveEntries.selectedPaths.read.progress",
                                    fields: selectedPathsDebugState.snapshot()
                                )
                            }
                        #endif
                    }
                    let entry = ResolvedPromptFileEntry(
                        file: file,
                        isCodemap: useSelectedCodemap,
                        mode: useSelectedCodemap ? .codemap : .fullFile,
                        loadedContent: content ?? nil,
                        rootFolderPath: result.location.rootPath
                    )
                    append(entry, to: &entries, seenIDs: &seenIDs)
                }
                #if DEBUG
                    PromptTokenRecountDiagnostics.event(
                        "tokenRecount.accounting.resolveEntries.selectedPath.end",
                        fields: selectedPathsDebugState.snapshot().merging(["outcome": "folder"]) { current, _ in current }
                    )
                #endif
            } else {
                #if DEBUG
                    selectedPathsDebugState.beginAssembly(index: selectedPathIndex, path: path, resolvedKind: "unresolved")
                #endif
                invalidPaths.append(path)
                #if DEBUG
                    PromptTokenRecountDiagnostics.event(
                        "tokenRecount.accounting.resolveEntries.selectedPath.end",
                        fields: selectedPathsDebugState.snapshot().merging(["outcome": "invalid"]) { current, _ in current }
                    )
                #endif
            }
        }

        #if DEBUG
            selectedPathsDebugState.finish()
            selectedPathsWatchdog.cancel()
            var selectedPathsEndFields = selectedPathsDebugState.snapshot()
            selectedPathsEndFields.merge(PromptTokenRecountDiagnostics.selectionFields(selection)) { current, _ in current }
            selectedPathsEndFields.merge([
                "entries": "\(entries.count)",
                "selectedFileIDs": "\(selectedFileIDs.count)",
                "missingPaths": "\(missingPaths.count)",
                "invalidPaths": "\(invalidPaths.count)",
                "duration": selectedPathsStartMS.map { PromptTokenRecountDiagnostics.formatElapsedMS(since: $0) } ?? "notMeasured"
            ]) { current, _ in current }
            PromptTokenRecountDiagnostics.event(
                "tokenRecount.accounting.resolveEntries.selectedPaths.end",
                fields: selectedPathsEndFields
            )
            let slicesStartMS = PromptTokenRecountDiagnostics.start()
            PromptTokenRecountDiagnostics.event(
                "tokenRecount.accounting.resolveEntries.slices.begin",
                fields: ["sliceFiles": "\(selection.slices.count)"]
            )
        #endif
        for (path, ranges) in selection.slices {
            guard !Task.isCancelled else {
                return PromptContextEntryResolution(entries: entries, missingPaths: missingPaths, invalidPaths: invalidPaths, codemapPresentation: codemapPresentation)
            }
            guard let result = await store.lookupPath(path, profile: profile, rootScope: rootScope) else {
                missingPaths.append(path)
                continue
            }
            guard let file = result.file else {
                invalidPaths.append(path)
                continue
            }
            guard !selectedFileIDs.contains(file.id) else { continue }
            selectedFileIDs.insert(file.id)
            let content: String? = switch contentPolicy {
            case .loadContent:
                try? await store.readContent(
                    rootID: file.rootID,
                    relativePath: file.standardizedRelativePath,
                    workloadClass: .promptAccounting
                )
            case .cachedOnly:
                await store.cachedSearchContentSnapshot(for: file).content
            }
            let entry = ResolvedPromptFileEntry(file: file, lineRanges: ranges, mode: .sliced, loadedContent: content ?? nil, rootFolderPath: result.location.rootPath)
            append(entry, to: &entries, seenIDs: &seenIDs)
        }

        #if DEBUG
            PromptTokenRecountDiagnostics.event(
                "tokenRecount.accounting.resolveEntries.slices.end",
                fields: [
                    "entries": "\(entries.count)",
                    "selectedFileIDs": "\(selectedFileIDs.count)",
                    "missingPaths": "\(missingPaths.count)",
                    "invalidPaths": "\(invalidPaths.count)",
                    "duration": slicesStartMS.map { PromptTokenRecountDiagnostics.formatElapsedMS(since: $0) } ?? "notMeasured"
                ]
            )
        #endif
        #if DEBUG
            let codemapPathsStartMS = PromptTokenRecountDiagnostics.start()
            PromptTokenRecountDiagnostics.event(
                "tokenRecount.accounting.resolveEntries.codemapPaths.begin",
                fields: ["codemapEntries": "\(codemapPresentation.orderedEntries.count)"]
            )
        #endif
        if codeMapUsage == .auto || codeMapUsage == .complete {
            let rootsByID = await Dictionary(uniqueKeysWithValues: store.rootRefs(scope: rootScope).map { ($0.id, $0) })
            for rendered in codemapPresentation.orderedEntries {
                guard !Task.isCancelled else {
                    return PromptContextEntryResolution(entries: entries, missingPaths: missingPaths, invalidPaths: invalidPaths, codemapPresentation: codemapPresentation)
                }
                guard !selectedFileIDs.contains(rendered.fileID),
                      let file = await store.file(
                          rootID: rendered.rootEpoch.rootID,
                          relativePath: rendered.logicalPath.standardizedRelativePath
                      ),
                      file.id == rendered.fileID,
                      let root = rootsByID[file.rootID]
                else { continue }
                let entry = ResolvedPromptFileEntry(
                    file: file,
                    isCodemap: true,
                    mode: .codemap,
                    loadedContent: nil,
                    rootFolderPath: root.standardizedFullPath
                )
                append(entry, to: &entries, seenIDs: &seenIDs)
            }
        }

        #if DEBUG
            PromptTokenRecountDiagnostics.event(
                "tokenRecount.accounting.resolveEntries.codemapPaths.end",
                fields: [
                    "entries": "\(entries.count)",
                    "selectedFileIDs": "\(selectedFileIDs.count)",
                    "missingPaths": "\(missingPaths.count)",
                    "invalidPaths": "\(invalidPaths.count)",
                    "duration": codemapPathsStartMS.map { PromptTokenRecountDiagnostics.formatElapsedMS(since: $0) } ?? "notMeasured"
                ]
            )
        #endif
        let uniqueMissingPaths = Array(Set(missingPaths)).sorted()
        let uniqueInvalidPaths = Array(Set(invalidPaths)).sorted()
        #if DEBUG
            PromptTokenRecountDiagnostics.event(
                "tokenRecount.accounting.resolveEntries.finish",
                fields: [
                    "entries": "\(entries.count)",
                    "selectedFileIDs": "\(selectedFileIDs.count)",
                    "missingPaths": "\(uniqueMissingPaths.count)",
                    "invalidPaths": "\(uniqueInvalidPaths.count)",
                    "duration": resolveStartMS.map { PromptTokenRecountDiagnostics.formatElapsedMS(since: $0) } ?? "notMeasured"
                ]
            )
        #endif
        return PromptContextEntryResolution(entries: entries, missingPaths: uniqueMissingPaths, invalidPaths: uniqueInvalidPaths, codemapPresentation: codemapPresentation)
    }

    func makePromptFileEntrySnapshots(
        from entries: [ResolvedPromptFileEntry],
        codemapPresentation: WorkspaceCodemapOperationPresentation,
        filePathDisplay: FilePathDisplay = .relative,
        displayPathResolver: ((ResolvedPromptFileEntry) -> String?)? = nil
    ) -> [PromptFileEntrySnapshot] {
        let hasMultipleRoots = Set(entries.map(\.file.rootID)).count > 1
        return entries.map { entry in
            let codeMapContent: String?
            let availableCodeMapTokenCount: Int
            let displayPath = displayPathResolver?(entry)
                ?? Self.selectedPath(for: entry, filePathDisplay: filePathDisplay, hasMultipleRoots: hasMultipleRoots)
            if let rendered = codemapPresentation.renderedEntriesByFileID[entry.file.id] {
                availableCodeMapTokenCount = rendered.tokenCount
                codeMapContent = entry.isCodemap ? rendered.text : nil
            } else {
                availableCodeMapTokenCount = 0
                codeMapContent = nil
            }
            let cachedFullTokenCount = entry.loadedContent.map(TokenCalculationService.estimateTokens(for:))
            return PromptFileEntrySnapshot(
                fileID: entry.file.id,
                relativePath: entry.file.relativePath,
                isCodemapRequested: entry.isCodemap,
                ranges: entry.lineRanges,
                cachedFullTokenCount: cachedFullTokenCount,
                loadedContent: entry.loadedContent,
                codeMapContent: codeMapContent,
                availableCodeMapTokenCount: availableCodeMapTokenCount
            )
        }
    }

    private nonisolated static func selectedPath(for entry: ResolvedPromptFileEntry, filePathDisplay: FilePathDisplay, hasMultipleRoots: Bool) -> String {
        if filePathDisplay == .relative {
            if hasMultipleRoots, let rootFolderPath = entry.rootFolderPath, !rootFolderPath.isEmpty {
                let rootFolderName = (StandardizedPath.absolute(rootFolderPath) as NSString).lastPathComponent
                return rootFolderName.isEmpty ? entry.file.relativePath : "\(rootFolderName)/\(entry.file.relativePath)"
            }
            return entry.file.relativePath
        }
        return entry.file.fullPath
    }

    private nonisolated func sliceRanges(for path: String, file: WorkspaceFileRecord, location: WorkspacePathLocation, in slices: [String: [LineRange]]) -> [LineRange]? {
        let candidateKeys = [
            path,
            StandardizedPath.absolute(path),
            file.relativePath,
            file.standardizedRelativePath,
            file.fullPath,
            file.standardizedFullPath,
            location.absolutePath
        ]
        for key in candidateKeys {
            if let ranges = slices[key] { return ranges }
        }
        return nil
    }

    private func logicalRootDisplayNamesByRootID(
        store: WorkspaceFileContextStore,
        rootScope: WorkspaceLookupRootScope
    ) async -> [UUID: String] {
        let roots = await store.rootRefs(scope: rootScope)
        return Dictionary(uniqueKeysWithValues: roots.map { ($0.id, $0.name) })
    }

    private func resolveCodemapPresentation(
        request: PromptContextAccountingRequest,
        store: WorkspaceFileContextStore,
        logicalRootDisplayNamesByRootID: [UUID: String]
    ) async -> WorkspaceCodemapOperationPresentation {
        let plan = await WorkspaceCodemapPresentationIntentResolver.plan(
            codeMapUsage: request.codeMapUsage,
            selection: request.selection,
            store: store,
            rootScope: request.rootScope,
            profile: request.pathLocateProfile
        )
        do {
            let presentation = try await WorkspaceCodemapPresentationCoordinator(store: store).presentation(
                for: plan.intent,
                rootScope: request.rootScope,
                logicalRootDisplayNamesByRootID: logicalRootDisplayNamesByRootID
            )
            return WorkspaceCodemapPresentationIntentResolver.merging(
                presentation,
                preflightIssues: plan.preflightIssues
            )
        } catch {
            let issue: WorkspaceCodemapOperationIssue = (Task.isCancelled || error is CancellationError)
                ? .cancelled
                : .coordinationUnavailable
            return WorkspaceCodemapOperationPresentation(
                orderedEntries: [],
                coverage: .unavailable([issue]),
                issues: [issue],
                publicationReceipt: nil
            )
        }
    }

    private func append(_ entry: ResolvedPromptFileEntry, to entries: inout [ResolvedPromptFileEntry], seenIDs: inout Set<ResolvedPromptFileEntryID>) {
        guard seenIDs.insert(entry.id).inserted else { return }
        entries.append(entry)
    }
}
