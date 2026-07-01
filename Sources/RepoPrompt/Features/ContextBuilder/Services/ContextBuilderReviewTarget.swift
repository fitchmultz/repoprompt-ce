import Foundation

enum ContextBuilderReviewTargetUnavailableReason: LocalizedError, Equatable {
    case missingFrozenTarget
    case checkoutIdentityChanged
    case workspaceOrTabMismatch
    case staleWorkspaceRoot

    var errorDescription: String? {
        localizedDescription
    }

    var localizedDescription: String {
        switch self {
        case .missingFrozenTarget: "Context Builder review target is unavailable."
        case .checkoutIdentityChanged: "Context Builder review checkout identity changed."
        case .workspaceOrTabMismatch: "Context Builder review workspace or tab changed."
        case .staleWorkspaceRoot: "Context Builder review workspace root is stale."
        }
    }
}

struct ContextBuilderReviewCheckoutTarget: Equatable, Hashable {
    let checkoutRootPath: String
    let displayLabel: String
    let selectedPaths: [String]
    let repositoryID: String
    let repoKey: String
    let worktreeID: String
    let kind: FrozenVisibleGitCheckoutKind
    let sessionRootAuthorization: WorkspaceSessionRootAuthorization?

    var identityKey: String {
        "\(repositoryID)|\(worktreeID)|\(checkoutRootPath)"
    }

    func matches(_ repo: GitRepoDescriptor) -> Bool {
        repo.repoKey == repoKey
    }

    func matches(_ manifest: GitDiffSnapshotManifest) -> Bool {
        guard let repoRoot = manifest.repoRoot else { return false }
        return GitRepoRootAuthorization.canonicalPath(repoRoot) == GitRepoRootAuthorization.canonicalPath(checkoutRootPath)
    }
}

struct ContextBuilderReviewTarget: Equatable {
    let workspaceID: UUID
    let tabID: UUID
    let selectionRevision: UInt64
    let selection: StoredSelection
    let lookupContext: WorkspaceLookupContext
    let primaryCheckout: ContextBuilderReviewCheckoutTarget
    let checkouts: [ContextBuilderReviewCheckoutTarget]
    let pathIssues: [ReviewGitPathIssue]
    let artifactCapability: SelectedGitArtifactCapability?
    let displayContext: ReviewGitDisplayContext

    func repositories(from allRepositories: [GitRepoDescriptor]) -> [GitRepoDescriptor]? {
        let keys = Set(checkouts.map(\.repoKey))
        return allRepositories.filter { keys.contains($0.repoKey) }
    }

    func contains(_ repo: GitRepoDescriptor) -> Bool {
        checkouts.contains { $0.matches(repo) }
    }

    func checkout(matching repo: GitRepoDescriptor) -> ContextBuilderReviewCheckoutTarget? {
        checkouts.first { $0.matches(repo) }
    }
}

enum ContextBuilderReviewTargetResolution: Equatable {
    case available(ContextBuilderReviewTarget)
    case deferred
    case unavailable(ContextBuilderReviewTargetUnavailableReason)
}

struct ContextBuilderFinalReviewAuthorization: Equatable {
    let target: ContextBuilderReviewTarget
}

struct ContextBuilderReviewTargetInput {
    let workspaceID: UUID
    let tabID: UUID
    let selectionRevision: UInt64
    let selection: StoredSelection
    let lookupContext: WorkspaceLookupContext
    let reviewGitContext: FrozenPromptGitReviewContext
}

struct ContextBuilderReviewTargetResolver {
    func revalidate(
        _ target: ContextBuilderReviewTarget,
        store _: WorkspaceFileContextStore
    ) async -> ContextBuilderReviewTargetUnavailableReason? {
        target.artifactCapability == nil ? .missingFrozenTarget : nil
    }

    func finalizeSelection(
        input _: ContextBuilderReviewTargetInput,
        initialResolution: ContextBuilderReviewTargetResolution,
        store _: WorkspaceFileContextStore
    ) async throws -> ContextBuilderReviewTargetResolution {
        initialResolution
    }
}
