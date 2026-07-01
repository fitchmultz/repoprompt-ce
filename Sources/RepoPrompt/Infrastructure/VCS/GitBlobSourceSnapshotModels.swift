import Foundation

struct ValidatedGitBlobSourceSnapshot {
    let rawBytes: Data
    let repositoryNamespace: GitBlobRepositoryNamespace
    let blobOID: GitBlobOID

    init(
        rawBytes: Data,
        repositoryNamespace: GitBlobRepositoryNamespace,
        blobOID: GitBlobOID
    ) {
        precondition(
            GitBlobOID.blob(bytes: rawBytes, objectFormat: blobOID.objectFormat) == blobOID,
            "Validated Git blob bytes must match their object ID."
        )
        self.rawBytes = rawBytes
        self.repositoryNamespace = repositoryNamespace
        self.blobOID = blobOID
    }
}
