import Foundation

enum WorkspaceCodemapPresentationIntentResolver {
    static func plan(
        codeMapUsage: CodeMapUsage,
        selection: StoredSelection,
        store: WorkspaceFileContextStore,
        rootScope: WorkspaceLookupRootScope,
        profile: PathLocateProfile
    ) async -> WorkspaceCodemapOperationPresentationPlan {
        guard codeMapUsage != .none else {
            return WorkspaceCodemapOperationPresentationPlan(intent: .none, preflightIssues: [])
        }
        let results = await store.lookupPaths(selection.selectedPaths.map {
            WorkspacePathLookupRequest(userPath: $0, profile: profile, rootScope: rootScope)
        })
        let fileIDs = selection.selectedPaths.compactMap { results[$0]?.file?.id }
        return WorkspaceCodemapOperationPresentationPlan(
            intent: fileIDs.isEmpty ? .none : .exact(fileIDs: fileIDs, completeRootSet: false),
            preflightIssues: []
        )
    }

    static func merging(
        _ presentation: WorkspaceCodemapOperationPresentation,
        preflightIssues: [WorkspaceCodemapOperationIssue]
    ) -> WorkspaceCodemapOperationPresentation {
        guard !preflightIssues.isEmpty else { return presentation }
        return WorkspaceCodemapOperationPresentation(
            id: presentation.id,
            orderedEntries: presentation.orderedEntries,
            coverage: .partial(presentation.issues + preflightIssues),
            issues: presentation.issues + preflightIssues,
            publicationReceipt: presentation.publicationReceipt
        )
    }
}
