import Foundation
@testable import RepoPrompt
import XCTest

final class WorkspaceCodemapBindingEngineTests: XCTestCase {
    func testDemandFailsClosedWhenRootIsNotRegistered() async throws {
        let runtime = try CodeMapArtifactRuntime(rootURL: temporaryDirectory())
        let engine = WorkspaceCodemapBindingEngine(
            runtime: runtime,
            capabilityService: WorkspaceCodemapGitCapabilityService(namespaceSalt: Data(repeating: 7, count: 32)),
            sourceReader: WorkspaceCodemapValidatedSourceReaderClient { _, _, _, _ in
                throw FileSystemError.fileNotFound
            }
        )
        let rootID = UUID()
        let fileID = UUID()
        let identity = try XCTUnwrap(WorkspaceCodemapArtifactBindingIdentity(
            rootID: rootID,
            rootLifetimeID: UUID(),
            fileID: fileID,
            standardizedRootPath: "/tmp/root",
            standardizedRelativePath: "Sources/App.swift",
            standardizedFullPath: "/tmp/root/Sources/App.swift"
        ))

        let result = await engine.demand(WorkspaceCodemapBindingDemand(
            owner: WorkspaceCodemapLiveDemandOwner(),
            identity: identity,
            requestGeneration: 1,
            catalogGeneration: 1,
            pathGeneration: 1,
            ingressGeneration: 1,
            priority: .demand,
            language: .swift
        ))

        guard case .rejected(.rootNotRegistered) = result else {
            return XCTFail("expected rootNotRegistered, got \(result)")
        }
    }

    private func temporaryDirectory() throws -> URL {
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/test-artifacts/WorkspaceCodemapBindingEngineTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }
}
