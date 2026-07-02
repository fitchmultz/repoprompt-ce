import Foundation

struct WorkspaceCodemapUIPresentationEntry: Equatable {
    let presentationID: UUID
    let fileID: UUID
    let rootEpoch: WorkspaceCodemapRootEpoch
    let logicalPath: WorkspaceCodemapLogicalPresentationPath
    let text: String
    let tokenCount: Int

    init(presentationID: UUID, renderedEntry: WorkspaceCodemapOperationRenderedEntry) {
        self.presentationID = presentationID
        fileID = renderedEntry.fileID
        rootEpoch = renderedEntry.rootEpoch
        logicalPath = renderedEntry.logicalPath
        text = renderedEntry.text
        tokenCount = renderedEntry.tokenCount
    }
}

struct WorkspaceCodemapUIPresentationSnapshot: Equatable {
    static let empty = WorkspaceCodemapUIPresentationSnapshot(.empty)

    let presentationID: UUID
    let orderedEntries: [WorkspaceCodemapUIPresentationEntry]
    let entriesByFileID: [UUID: WorkspaceCodemapUIPresentationEntry]
    let coverage: WorkspaceCodemapOperationPresentationCoverage
    let issues: [WorkspaceCodemapOperationIssue]

    init(_ presentation: WorkspaceCodemapOperationPresentation) {
        presentationID = presentation.id
        orderedEntries = presentation.orderedEntries.map {
            WorkspaceCodemapUIPresentationEntry(presentationID: presentation.id, renderedEntry: $0)
        }
        entriesByFileID = Dictionary(uniqueKeysWithValues: orderedEntries.map { ($0.fileID, $0) })
        coverage = presentation.coverage
        issues = presentation.issues
    }
}

enum WorkspaceCodemapUIPreviewDisposition: Equatable {
    case ready(WorkspaceCodemapUIPresentationEntry)
    case unavailable(coverage: WorkspaceCodemapOperationPresentationCoverage, issues: [WorkspaceCodemapOperationIssue])
    case revoked
}
