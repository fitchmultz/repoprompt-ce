import Foundation

enum SelectedGitDiffArtifactPolicy {
    case includeBeforeGitInclusion
    case respectGitInclusion
}

struct PromptContextPreAssemblyRequest {
    let cfg: PromptContextResolved
    let selection: StoredSelection
    let store: WorkspaceFileContextStore
    let lookupContext: WorkspaceLookupContext
    let filePathDisplay: FilePathDisplay
    let onlyIncludeRootsWithSelectedFiles: Bool
    let includeFileTreeLegend: Bool
    let showCodeMapMarkers: Bool
    let codeMapUsage: CodeMapUsage
    let entryResolutionProfile: PathLocateProfile
    let selectedGitDiffFolderPolicy: SelectedGitDiffFolderPolicy
    let selectedGitDiffLookupProfile: PathLocateProfile
    /// Compatibility input retained for callers that previously requested hidden local-definition discovery.
    /// Canonical codemap inclusion is now controlled exclusively by `selection.autoCodemapPaths`.
    let includeLocalDefinitionsInFileTree: Bool
    let selectedGitDiffArtifactPolicy: SelectedGitDiffArtifactPolicy
    let selectedGitDiffProvider: ([String]) async -> String?
    let completeGitDiffProvider: () async -> String?

    init(
        cfg: PromptContextResolved,
        selection: StoredSelection,
        store: WorkspaceFileContextStore,
        lookupContext: WorkspaceLookupContext,
        filePathDisplay: FilePathDisplay,
        onlyIncludeRootsWithSelectedFiles: Bool,
        includeFileTreeLegend: Bool = true,
        showCodeMapMarkers: Bool,
        codeMapUsage: CodeMapUsage? = nil,
        entryResolutionProfile: PathLocateProfile = .uiAssisted,
        selectedGitDiffFolderPolicy: SelectedGitDiffFolderPolicy,
        selectedGitDiffLookupProfile: PathLocateProfile? = nil,
        includeLocalDefinitionsInFileTree: Bool = false,
        selectedGitDiffArtifactPolicy: SelectedGitDiffArtifactPolicy = .includeBeforeGitInclusion,
        selectedGitDiffProvider: @escaping ([String]) async -> String?,
        completeGitDiffProvider: @escaping () async -> String?
    ) {
        self.cfg = cfg
        self.selection = selection
        self.store = store
        self.lookupContext = lookupContext
        self.filePathDisplay = filePathDisplay
        self.onlyIncludeRootsWithSelectedFiles = onlyIncludeRootsWithSelectedFiles
        self.includeFileTreeLegend = includeFileTreeLegend
        self.showCodeMapMarkers = showCodeMapMarkers
        self.codeMapUsage = codeMapUsage ?? cfg.codeMapUsage
        self.entryResolutionProfile = entryResolutionProfile
        self.selectedGitDiffFolderPolicy = selectedGitDiffFolderPolicy
        self.selectedGitDiffLookupProfile = selectedGitDiffLookupProfile ?? entryResolutionProfile
        self.includeLocalDefinitionsInFileTree = includeLocalDefinitionsInFileTree
        self.selectedGitDiffArtifactPolicy = selectedGitDiffArtifactPolicy
        self.selectedGitDiffProvider = selectedGitDiffProvider
        self.completeGitDiffProvider = completeGitDiffProvider
    }
}

struct PromptContextPreAssemblyResult {
    let physicalSelection: StoredSelection
    let entries: [ResolvedPromptFileEntry]
    let missingPaths: [String]
    let invalidPaths: [String]
    let codemapPresentation: WorkspaceCodemapOperationPresentation
    let fileTreeContent: String?
    let gitDiff: String?
    let lookupContext: WorkspaceLookupContext
    let filePathDisplay: FilePathDisplay

    func displayPath(for entry: ResolvedPromptFileEntry) -> String? {
        lookupContext.bindingProjection?.projectedLogicalDisplayPath(
            forPhysicalPath: entry.file.standardizedFullPath,
            display: filePathDisplay
        )
    }
}

enum PromptContextPreAssemblyService {
    static func resolve(_ request: PromptContextPreAssemblyRequest) async -> PromptContextPreAssemblyResult {
        do {
            return try await withResolved(request) { $0 }
        } catch {
            let issue: WorkspaceCodemapOperationIssue = (Task.isCancelled || error is CancellationError)
                ? .cancelled
                : .coordinationUnavailable
            return await buildResult(
                request: request,
                physicalSelection: request.lookupContext.physicalizeSelection(request.selection),
                rootDisplayNames: logicalRootDisplayNamesByRootID(
                    store: request.store,
                    rootScope: request.lookupContext.rootScope
                ),
                codemapPresentation: WorkspaceCodemapOperationPresentation(
                    orderedEntries: [],
                    coverage: .unavailable([issue]),
                    issues: [issue],
                    publicationReceipt: nil
                ),
                accountingService: PromptContextAccountingService()
            )
        }
    }

    static func withResolved<Value>(
        _ request: PromptContextPreAssemblyRequest,
        accountingService: PromptContextAccountingService = PromptContextAccountingService(),
        codemapPresentation: WorkspaceCodemapOperationPresentation? = nil,
        presentationCoordinator: WorkspaceCodemapPresentationCoordinator? = nil,
        operation: (PromptContextPreAssemblyResult) async throws -> Value
    ) async throws -> Value {
        let physicalSelection = request.lookupContext.physicalizeSelection(request.selection)
        let rootDisplayNames = await logicalRootDisplayNamesByRootID(
            store: request.store,
            rootScope: request.lookupContext.rootScope
        )
        if let codemapPresentation {
            let result = await buildResult(
                request: request,
                physicalSelection: physicalSelection,
                rootDisplayNames: rootDisplayNames,
                codemapPresentation: codemapPresentation,
                accountingService: accountingService
            )
            try Task.checkCancellation()
            return try await operation(result)
        }
        let plan = await WorkspaceCodemapPresentationIntentResolver.plan(
            codeMapUsage: request.codeMapUsage,
            selection: physicalSelection,
            store: request.store,
            rootScope: request.lookupContext.rootScope,
            profile: request.entryResolutionProfile
        )
        let coordinator = presentationCoordinator ?? WorkspaceCodemapPresentationCoordinator(store: request.store)
        return try await coordinator.withPresentation(
            for: plan.intent,
            rootScope: request.lookupContext.rootScope,
            logicalRootDisplayNamesByRootID: rootDisplayNames
        ) { presentation in
            let result = await buildResult(
                request: request,
                physicalSelection: physicalSelection,
                rootDisplayNames: rootDisplayNames,
                codemapPresentation: WorkspaceCodemapPresentationIntentResolver.merging(
                    presentation,
                    preflightIssues: plan.preflightIssues
                ),
                accountingService: accountingService
            )
            try Task.checkCancellation()
            return try await operation(result)
        }
    }

    private static func buildResult(
        request: PromptContextPreAssemblyRequest,
        physicalSelection: StoredSelection,
        rootDisplayNames: [UUID: String],
        codemapPresentation: WorkspaceCodemapOperationPresentation,
        accountingService: PromptContextAccountingService
    ) async -> PromptContextPreAssemblyResult {
        let resolution = await accountingService.resolveEntries(
            selection: physicalSelection,
            store: request.store,
            rootScope: request.lookupContext.rootScope,
            profile: request.entryResolutionProfile,
            codeMapUsage: request.codeMapUsage,
            codemapPresentation: codemapPresentation,
            codemapLogicalRootDisplayNamesByRootID: rootDisplayNames
        )
        let fileTreeContent = await resolveFileTreeContent(
            request: request,
            physicalSelection: physicalSelection,
            entries: resolution.entries,
            codemapPresentation: codemapPresentation
        )
        let gitDiff = await resolveGitDiff(request: request, physicalSelection: physicalSelection, entries: resolution.entries)
        let packagingEntries = entriesForPackaging(request: request, entries: resolution.entries)

        return PromptContextPreAssemblyResult(
            physicalSelection: physicalSelection,
            entries: packagingEntries,
            missingPaths: resolution.missingPaths,
            invalidPaths: resolution.invalidPaths,
            codemapPresentation: codemapPresentation,
            fileTreeContent: fileTreeContent,
            gitDiff: gitDiff,
            lookupContext: request.lookupContext,
            filePathDisplay: request.filePathDisplay
        )
    }

    private static func resolveFileTreeContent(
        request: PromptContextPreAssemblyRequest,
        physicalSelection: StoredSelection,
        entries: [ResolvedPromptFileEntry],
        codemapPresentation: WorkspaceCodemapOperationPresentation
    ) async -> String? {
        guard request.cfg.rendersFileTree else { return nil }
        let hasFileTreeInputs = !physicalSelection.selectedPaths.isEmpty
            || !physicalSelection.slices.isEmpty
            || (physicalSelection.codemapAutoEnabled && !physicalSelection.autoCodemapPaths.isEmpty)
            || !entries.isEmpty
        guard request.cfg.effectiveFileTreeMode != .auto || hasFileTreeInputs else { return nil }

        let rawFileTreeSnapshot = await request.store.makeFileTreeSelectionSnapshot(
            selection: physicalSelection,
            request: WorkspaceFileTreeSnapshotRequest(
                mode: WorkspaceFileTreeSnapshotMode(fileTreeOption: request.cfg.effectiveFileTreeMode),
                filePathDisplay: request.filePathDisplay,
                onlyIncludeRootsWithSelectedFiles: request.onlyIncludeRootsWithSelectedFiles,
                includeLegend: request.includeFileTreeLegend,
                showCodeMapMarkers: request.showCodeMapMarkers,
                rootScope: request.lookupContext.rootScope
            ),
            codemapPresentation: codemapPresentation,
            profile: request.entryResolutionProfile
        )
        let fileTreeSnapshot = request.lookupContext.bindingProjection?.logicalizeFileTreeSnapshot(rawFileTreeSnapshot) ?? rawFileTreeSnapshot
        let tree = CodeMapExtractor.generateFileTree(using: fileTreeSnapshot)
        return tree.isEmpty ? nil : tree
    }

    private static func logicalRootDisplayNamesByRootID(
        store: WorkspaceFileContextStore,
        rootScope: WorkspaceLookupRootScope
    ) async -> [UUID: String] {
        let roots = await store.rootRefs(scope: rootScope)
        return Dictionary(uniqueKeysWithValues: roots.map { ($0.id, $0.name) })
    }

    private static func entriesForPackaging(
        request: PromptContextPreAssemblyRequest,
        entries: [ResolvedPromptFileEntry]
    ) -> [ResolvedPromptFileEntry] {
        guard request.selectedGitDiffArtifactPolicy == .respectGitInclusion,
              request.cfg.gitInclusion == .none
        else { return entries }
        let (_, codeEntries) = PromptPackagingService.partitionPromptEntriesForGitDiff(entries)
        return codeEntries
    }

    private static func resolveGitDiff(
        request: PromptContextPreAssemblyRequest,
        physicalSelection: StoredSelection,
        entries: [ResolvedPromptFileEntry]
    ) async -> String? {
        let (diffEntries, _) = PromptPackagingService.partitionPromptEntriesForGitDiff(entries)
        if request.selectedGitDiffArtifactPolicy == .respectGitInclusion,
           request.cfg.gitInclusion == .none
        {
            return nil
        }

        return await PromptPackagingService.resolveGitDiff(fromDiffEntries: diffEntries) {
            switch request.cfg.gitInclusion {
            case .none:
                return nil
            case .selected:
                let selectedPaths = await WorkspaceGitDiffSelectionResolver.selectedGitDiffPaths(
                    for: physicalSelection,
                    store: request.store,
                    rootScope: request.lookupContext.rootScope,
                    folderPolicy: request.selectedGitDiffFolderPolicy,
                    profile: request.selectedGitDiffLookupProfile,
                    allowFilesystemFallback: request.lookupContext.rootScope.allowsSelectedGitDiffFilesystemFallback
                )
                return await request.selectedGitDiffProvider(selectedPaths)
            case .complete:
                if request.lookupContext.bindingProjection != nil {
                    return PromptContextGitDiffPolicy.deferredCompleteWorktreeGitDiffMessage
                }
                return await request.completeGitDiffProvider()
            }
        }
    }
}
