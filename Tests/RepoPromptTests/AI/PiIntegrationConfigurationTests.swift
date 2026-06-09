@testable import RepoPrompt
import XCTest

final class PiIntegrationConfigurationTests: XCTestCase {
    func testPiAgentModeRunnerHasFirstEventWatchdog() throws {
        let repoRoot = try RepoRoot.url(filePath: #filePath)
        let sourcePath = "Sources/RepoPrompt/Features/AgentMode/Runtime/Runners/PiIntegratedAgentModeRunner.swift"
        let contents = try String(contentsOf: repoRoot.appendingPathComponent(sourcePath), encoding: .utf8)

        XCTAssertTrue(contents.contains("firstProviderEventTimeoutNanoseconds"), sourcePath)
        XCTAssertTrue(contents.contains("first provider event timeout"), sourcePath)
        XCTAssertTrue(contents.contains("pi.firstProviderEventTimeout"), sourcePath)
        XCTAssertTrue(contents.contains("didReceivePostPromptProviderEvent = true"), sourcePath)
        XCTAssertTrue(contents.contains("case let .sessionState(state):\n                        applySessionState(state, to: session)"), sourcePath)
        XCTAssertTrue(contents.contains("pi accepted the prompt but did not produce any response events within 60 seconds."), sourcePath)
    }

    func testPiAgentModeRunnerPersistsProviderModelIdentityFromSessionState() throws {
        let repoRoot = try RepoRoot.url(filePath: #filePath)
        let sourcePath = "Sources/RepoPrompt/Features/AgentMode/Runtime/Runners/PiIntegratedAgentModeRunner.swift"
        let contents = try String(contentsOf: repoRoot.appendingPathComponent(sourcePath), encoding: .utf8)

        XCTAssertTrue(contents.contains("state.model.flatMap(AgentPiModelRegistry.rawModel)"), sourcePath)
        XCTAssertTrue(contents.contains("session.selectedModelRaw = modelRaw"), sourcePath)
    }

    private var temporaryURLs: [URL] = []

    override func tearDown() {
        for url in temporaryURLs {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryURLs.removeAll()
        super.tearDown()
    }

    func testParseVersionExtractsSemanticVersion() {
        XCTAssertEqual(PiIntegrationConfiguration.parseVersion(from: "pi 0.78.1"), "0.78.1")
        XCTAssertEqual(PiIntegrationConfiguration.parseVersion(from: "0.79.0-beta.1"), "0.79.0-beta.1")
        XCTAssertNil(PiIntegrationConfiguration.parseVersion(from: "pi dev build"))
    }

    func testSupportedVersionRequiresStablePi079OrNewer() {
        XCTAssertFalse(PiIntegrationConfiguration.isSupportedVersion(nil))
        XCTAssertFalse(PiIntegrationConfiguration.isSupportedVersion("0.78.9"))
        XCTAssertFalse(PiIntegrationConfiguration.isSupportedVersion("0.79.0-beta.1"))
        XCTAssertTrue(PiIntegrationConfiguration.isSupportedVersion("0.79.0"))
        XCTAssertTrue(PiIntegrationConfiguration.isSupportedVersion("0.80.0-beta.1"))
        XCTAssertTrue(PiIntegrationConfiguration.isSupportedVersion("0.80.0"))
    }

    func testManagedRPCLaunchArgumentsApproveProjectInputs() {
        XCTAssertEqual(
            PiIntegrationConfiguration.managedRPCLaunchArguments(),
            ["--mode", "rpc", "--approve"]
        )
    }

    func testManagedRPCLaunchArgumentsIncludeBridgeExtensionAfterApproval() {
        XCTAssertEqual(
            PiIntegrationConfiguration.managedRPCLaunchArguments(
                bridgeExtensionPath: "/tmp/repoprompt-bridge.ts"
            ),
            ["--mode", "rpc", "--approve", "--extension", "/tmp/repoprompt-bridge.ts"]
        )
    }

    func testPiRPCDefaultsUseManagedLaunchArguments() {
        XCTAssertEqual(
            PiRPCClient.Config().launchArguments,
            PiIntegrationConfiguration.managedRPCLaunchArguments()
        )
        XCTAssertEqual(
            PiRPCClient.Config().environmentOverrides,
            PiIntegrationConfiguration.managedRunEnvironment()
        )
        XCTAssertEqual(
            PiNativeSessionController.Options().launchArguments,
            PiIntegrationConfiguration.managedRPCLaunchArguments()
        )
    }

    func testAvailabilityProbeAcceptsSupportedVersionOutput() async throws {
        let scriptURL = try makeFakePiVersionScript(exitCode: 0, stdout: "pi 0.79.0")

        let availability = await PiIntegrationConfiguration.checkAvailability(
            commandName: scriptURL.path,
            timeout: 2
        )

        XCTAssertTrue(availability.isAvailable)
        XCTAssertEqual(availability.version, "0.79.0")
        XCTAssertNil(availability.diagnostic)
    }

    func testAvailabilityProbeReportsExecutableVersionWithoutManagedGate() async throws {
        let scriptURL = try makeFakePiVersionScript(exitCode: 0, stdout: "pi 0.78.1")

        let availability = await PiIntegrationConfiguration.checkAvailability(
            commandName: scriptURL.path,
            timeout: 2
        )

        XCTAssertTrue(availability.isAvailable)
        XCTAssertEqual(availability.version, "0.78.1")
        XCTAssertNil(availability.diagnostic)
    }

    func testManagedRPCAvailabilityProbeRejectsUnsupportedVersionOutput() async throws {
        let scriptURL = try makeFakePiVersionScript(exitCode: 0, stdout: "pi 0.78.1")

        let availability = await PiIntegrationConfiguration.checkManagedRPCAvailability(
            commandName: scriptURL.path,
            timeout: 2
        )

        XCTAssertFalse(availability.isAvailable)
        XCTAssertEqual(availability.version, "0.78.1")
        XCTAssertEqual(
            availability.diagnostic,
            "RepoPrompt requires pi 0.79.0 or newer for managed RPC project trust; found 0.78.1. Update pi and try again."
        )
    }

    func testAvailabilityProbeReportsFailureWithoutFallback() async throws {
        let scriptURL = try makeFakePiVersionScript(exitCode: 2, stdout: "pi unavailable", stderr: "pi unavailable")

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
        sys.stdout.flush()
        sys.stderr.write("__STDERR__")
        sys.stderr.flush()
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
