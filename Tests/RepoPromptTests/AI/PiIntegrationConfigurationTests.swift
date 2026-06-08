@testable import RepoPrompt
import XCTest

final class PiIntegrationConfigurationTests: XCTestCase {
    private var temporaryURLs: [URL] = []

    override func tearDown() {
        for url in temporaryURLs {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryURLs.removeAll()
        super.tearDown()
    }

    func testParseVersionDoesNotImposeMinimum() {
        XCTAssertEqual(PiIntegrationConfiguration.parseVersion(from: "pi 0.78.1"), "0.78.1")
        XCTAssertEqual(PiIntegrationConfiguration.parseVersion(from: "0.79.0-beta.1"), "0.79.0-beta.1")
        XCTAssertNil(PiIntegrationConfiguration.parseVersion(from: "pi dev build"))
    }

    func testAvailabilityProbeAcceptsVersionOutput() async throws {
        let scriptURL = try makeFakePiVersionScript(exitCode: 0, stdout: "pi 0.78.1")

        let availability = await PiIntegrationConfiguration.checkAvailability(
            commandName: scriptURL.path,
            timeout: 2
        )

        XCTAssertTrue(availability.isAvailable)
        XCTAssertEqual(availability.version, "0.78.1")
        XCTAssertNil(availability.diagnostic)
    }

    func testAvailabilityProbeReportsFailureWithoutFallback() async throws {
        let scriptURL = try makeFakePiVersionScript(exitCode: 2, stderr: "pi unavailable")

        let availability = await PiIntegrationConfiguration.checkAvailability(
            commandName: scriptURL.path,
            timeout: 2
        )

        XCTAssertFalse(availability.isAvailable)
        XCTAssertNil(availability.version)
        XCTAssertEqual(availability.diagnostic, "pi unavailable")
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PiIntegrationConfigurationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        temporaryURLs.append(url)
        return url
    }

    private func makeFakePiVersionScript(exitCode: Int32, stdout: String = "", stderr: String = "") throws -> URL {
        let directory = try makeTemporaryDirectory()
        let scriptURL = directory.appendingPathComponent("fake_pi_version.py")
        let script = #"""
        #!/usr/bin/env python3
        import sys
        sys.stdout.write("__STDOUT__")
        sys.stderr.write("__STDERR__")
        sys.exit(__EXIT_CODE__)
        """#
        .replacingOccurrences(of: "__STDOUT__", with: escapedPythonString(stdout))
        .replacingOccurrences(of: "__STDERR__", with: escapedPythonString(stderr))
        .replacingOccurrences(of: "__EXIT_CODE__", with: String(exitCode))
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        return scriptURL
    }

    private func escapedPythonString(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
    }
}
