import Foundation
@testable import RepoPrompt
import XCTest

final class CommandPathResolverTests: XCTestCase {
    private var temporaryURLs: [URL] = []

    override func tearDown() {
        for url in temporaryURLs {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryURLs.removeAll()
        super.tearDown()
    }

    func testInteractiveShellLookupTimeoutFallsBackWithoutHanging() throws {
        let directory = try makeTemporaryDirectory()
        let shell = directory.appendingPathComponent("hanging-shell")
        let marker = directory.appendingPathComponent("shell-was-invoked")
        try "#!/bin/sh\nprintf x >> '\(marker.path)'\nsleep 30\n".write(to: shell, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shell.path)

        var environment = ProcessInfo.processInfo.environment
        environment["SHELL"] = shell.path
        environment["PATH"] = directory.path
        environment["REPOPROMPT_SHELL_LOOKUP_TIMEOUT_SECONDS"] = "0.05"
        environment["REPOPROMPT_SHELL_LOOKUP_TERMINATION_GRACE_SECONDS"] = "0.05"
        environment["REPOPROMPT_SHELL_LOOKUP_PIPE_DRAIN_GRACE_SECONDS"] = "0.05"

        let started = Date()
        let resolved = CommandPathResolver.resolve(
            "rp-hanging-shell-target",
            environment: environment,
            additionalPaths: []
        )
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertEqual(resolved, "rp-hanging-shell-target")
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertLessThan(elapsed, 2)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CommandPathResolverTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        temporaryURLs.append(url)
        return url
    }
}
