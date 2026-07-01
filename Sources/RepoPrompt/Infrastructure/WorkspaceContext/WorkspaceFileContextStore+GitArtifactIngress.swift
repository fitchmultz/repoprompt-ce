import Foundation

extension WorkspaceFileContextStore {
    func exactRootRef(path: String, kind _: WorkspaceRootKind) -> WorkspaceRootRef? {
        let standardizedPath = StandardizedPath.absolute(path)
        return rootRefs(scope: .allLoaded).first { $0.standardizedFullPath == standardizedPath }
    }

    func exactCatalogFile(
        absolutePath: String,
        expectedRoot: WorkspaceRootRef,
        expectedKind _: WorkspaceRootKind
    ) async -> WorkspaceFileRecord? {
        let standardized = StandardizedPath.absolute(absolutePath)
        guard standardized != expectedRoot.standardizedFullPath,
              StandardizedPath.isDescendant(standardized, of: expectedRoot.standardizedFullPath)
        else { return nil }
        return await lookupPath(
            WorkspacePathLookupRequest(userPath: standardized, profile: .uiAssisted, rootScope: .allLoaded),
            rootRefs: [expectedRoot]
        )?.file
    }

    func readExactCatalogFile(
        _ file: WorkspaceFileRecord,
        expectedRoot: WorkspaceRootRef
    ) async -> String? {
        guard StandardizedPath.isDescendant(file.standardizedFullPath, of: expectedRoot.standardizedFullPath),
              let data = FileManager.default.contents(atPath: file.standardizedFullPath)
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func ingressPublishedGitArtifacts(
        _ request: WorkspacePublishedGitArtifactIngressRequest
    ) async -> WorkspacePublishedGitArtifactIngressResult {
        var outcomes: [WorkspacePublishedGitArtifactIngressOutcome] = []
        var seen = Set<String>()
        for artifact in request.artifacts {
            let relativePath = artifact.gitDataRelativePath
            guard GitDiffArtifactPathPolicy.isSafeRelativeArtifactPath(relativePath) else {
                outcomes.append(.init(artifact: artifact, status: .invalidRelativePath))
                continue
            }
            let absolutePath = artifact.absolutePath
            guard absolutePath == StandardizedPath.join(
                standardizedRoot: request.root.standardizedFullPath,
                standardizedRelativePath: relativePath
            ) else {
                outcomes.append(.init(artifact: artifact, status: .outsideExpectedRoot))
                continue
            }
            guard seen.insert(absolutePath).inserted else {
                outcomes.append(.init(artifact: artifact, status: .duplicateOf(path: absolutePath)))
                continue
            }
            guard FileManager.default.fileExists(atPath: absolutePath) else {
                outcomes.append(.init(artifact: artifact, status: .missingOnDisk))
                continue
            }
            if let record = await exactCatalogFile(
                absolutePath: absolutePath,
                expectedRoot: request.root,
                expectedKind: .workspaceGitData
            ) {
                outcomes.append(.init(artifact: artifact, status: .cataloged(record: record)))
            } else {
                outcomes.append(.init(artifact: artifact, status: .materializationFailed(reason: "artifact is not cataloged")))
            }
        }
        return WorkspacePublishedGitArtifactIngressResult(outcomes: outcomes)
    }
}
