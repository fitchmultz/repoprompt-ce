import Foundation
@testable import RepoPrompt
import XCTest

final class GitBlobArtifactAuthorityTests: XCTestCase {
    private var temporaryRoots: [URL] = []

    override func tearDown() {
        for root in temporaryRoots {
            try? FileManager.default.removeItem(at: root)
        }
        temporaryRoots.removeAll()
        super.tearDown()
    }

    func testAuthorityMaterializesCommittedBlobAfterWorktreeFileIsRemoved() async throws {
        let root = try makeRepository()
        try write("Sources/ObjectOnly.swift", "struct ObjectOnly {}\n", in: root)
        try runGit(["add", "Sources/ObjectOnly.swift"], cwd: root)
        try runGit(["commit", "-m", "Initial"], cwd: root)

        let oidText = try runGitCapture(["rev-parse", "HEAD:Sources/ObjectOnly.swift"], cwd: root)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let service = WorkspaceCodemapGitCapabilityService(
            namespaceSalt: Data(repeating: 0x42, count: GitBlobRepositoryNamespace.saltByteCount)
        )
        let request = WorkspaceCodemapGitCapabilityRequest(
            rootID: UUID(),
            rootLifetimeID: UUID(),
            loadedRootURL: root
        )
        let state = await service.resolve(root: request)
        guard case let .eligible(capability) = state else {
            return XCTFail("Expected eligible authority, got \(state)")
        }
        let oid = try GitBlobOID(objectFormat: capability.objectFormat, lowercaseHex: oidText)

        try FileManager.default.removeItem(at: root.appendingPathComponent("Sources/ObjectOnly.swift"))
        let snapshot = try await GitBlobSourceMaterializationService().materialize(
            capability: capability,
            blobOID: oid
        )

        XCTAssertEqual(snapshot.rawBytes, Data("struct ObjectOnly {}\n".utf8))
        XCTAssertEqual(snapshot.repositoryNamespace, capability.repositoryNamespace)
        XCTAssertEqual(snapshot.blobOID, oid)
        await service.release(rootEpoch: request.rootEpoch)
    }

    func testCapabilityReloadChangesAuthorityAfterAttributesChange() async throws {
        let root = try makeRepository()
        try write("Sources/File.swift", "struct File {}\n", in: root)
        try runGit(["add", "Sources/File.swift"], cwd: root)
        try runGit(["commit", "-m", "Initial"], cwd: root)

        let service = WorkspaceCodemapGitCapabilityService(
            namespaceSalt: Data(repeating: 0x24, count: GitBlobRepositoryNamespace.saltByteCount)
        )
        let request = WorkspaceCodemapGitCapabilityRequest(
            rootID: UUID(),
            rootLifetimeID: UUID(),
            loadedRootURL: root
        )
        guard case let .eligible(first) = await service.resolve(root: request) else {
            return XCTFail("Expected initial eligible authority")
        }

        try write(".gitattributes", "*.swift text eol=lf\n", in: root)
        guard case let .eligible(second) = await service.reload(root: request) else {
            return XCTFail("Expected eligible authority after attributes change")
        }

        XCTAssertEqual(second.repositoryNamespace, first.repositoryNamespace)
        XCTAssertNotEqual(second.repositoryAuthority.attributeGeneration, first.repositoryAuthority.attributeGeneration)
        XCTAssertGreaterThan(
            second.repositoryAuthority.authorityGeneration,
            first.repositoryAuthority.authorityGeneration
        )
        await service.release(rootEpoch: request.rootEpoch)
    }

    func testPublishedDiffArtifactsRejectUnsafeManifestPatchPaths() throws {
        let snapshotRef = GitDiffSnapshotStore.GitDiffSnapshotRef(repoKey: "repo", snapshotID: "snapshot")
        let manifest = GitDiffSnapshotManifest(
            snapshotID: "snapshot",
            generatedAt: Date(timeIntervalSince1970: 0),
            mode: .standard,
            compare: "HEAD",
            compareInput: nil,
            scope: .all,
            requestedPaths: nil,
            fingerprint: GitDiffFingerprint(
                headSHA: "abc",
                baseRef: "HEAD",
                statusHash: "status",
                generatedAt: Date(timeIntervalSince1970: 0)
            ),
            contextLines: 3,
            detectRenames: true,
            summary: GitDiffSnapshotManifest.Summary(files: 1, insertions: 1, deletions: 0),
            files: [GitDiffSnapshotManifest.FileEntry(
                gitPath: "A.swift",
                status: "M",
                additions: 1,
                deletions: 0,
                patchPath: "../escape.patch",
                bytes: nil,
                lines: nil,
                hunks: nil
            )],
            repoKey: "repo",
            repoRoot: "/tmp/repo"
        )

        XCTAssertThrowsError(try GitDiffPublishedArtifactSet(
            snapshotDirectoryURL: URL(fileURLWithPath: "/tmp/git-data/repos/repo/snapshot"),
            snapshotRef: snapshotRef,
            manifest: manifest,
            allPatchRelativePath: nil
        )) { error in
            XCTAssertEqual(error as? GitDiffPublishedArtifactError, .unsafeRelativePath("../escape.patch"))
        }
    }

    private func makeRepository() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepoPromptGitBlobArtifactAuthorityTests-")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        temporaryRoots.append(root.deletingLastPathComponent())
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try runGit(["init"], cwd: root)
        try runGit(["config", "user.email", "test@example.com"], cwd: root)
        try runGit(["config", "user.name", "Test User"], cwd: root)
        try runGit(["config", "commit.gpgSign", "false"], cwd: root)
        return root
    }

    private func write(_ relativePath: String, _ contents: String, in root: URL) throws {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    private func runGit(_ arguments: [String], cwd: URL) throws {
        _ = try runGitCapture(arguments, cwd: cwd)
    }

    private func runGitCapture(_ arguments: [String], cwd: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = cwd
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        try process.run()
        process.waitUntilExit()
        let stdout = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            let stderr = String(data: error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw NSError(domain: "GitBlobArtifactAuthorityTests", code: Int(process.terminationStatus), userInfo: [
                NSLocalizedDescriptionKey: "git \(arguments.joined(separator: " ")) failed: \(stderr)"
            ])
        }
        return stdout
    }
}
