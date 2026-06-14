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

    func testModelDiscoveryLaunchArgumentsAreEphemeralAndToolless() {
        XCTAssertEqual(
            PiIntegrationConfiguration.managedRPCModelDiscoveryLaunchArguments(),
            ["--mode", "rpc", "--approve", "--no-session", "--no-tools"]
        )
    }

    func testSupportedPiModelProvidersAreLimitedToRepoPromptSupportedSet() {
        XCTAssertTrue(PiIntegrationConfiguration.isSupportedModelRaw("openai-codex/gpt-5.5"))
        XCTAssertTrue(PiIntegrationConfiguration.isSupportedModelRaw("zai/glm-5.1"))
        XCTAssertTrue(PiIntegrationConfiguration.isSupportedModelRaw("z-ai/glm-5.1"))
        XCTAssertTrue(PiIntegrationConfiguration.isSupportedModelRaw("deepseek/deepseek-v4-flash"))
        XCTAssertFalse(PiIntegrationConfiguration.isSupportedModelRaw("anthropic/claude-opus-4-6"))
        XCTAssertFalse(PiIntegrationConfiguration.isSupportedModelRaw("openrouter/z-ai/glm-5.1"))
        XCTAssertFalse(PiIntegrationConfiguration.isSupportedModelRaw("default"))
    }

    func testPromptOnlyLaunchArgumentsAreEphemeralAndToolless() {
        XCTAssertEqual(
            PiIntegrationConfiguration.managedRPCPromptOnlyLaunchArguments(),
            ["--mode", "rpc", "--approve", "--no-session", "--no-tools"]
        )
    }

    func testManagedRPCLaunchArgumentsIncludeBridgeExtensionAfterApproval() {
        let arguments = PiIntegrationConfiguration.managedRPCLaunchArguments(
            bridgeExtensionPath: "/tmp/repoprompt-bridge.ts"
        )
        XCTAssertEqual(
            arguments,
            ["--mode", "rpc", "--approve", "--extension", "/tmp/repoprompt-bridge.ts"]
        )
        XCTAssertFalse(arguments.contains("--no-extensions"))
        XCTAssertFalse(arguments.contains("--no-builtin-tools"))
    }

    func testManagedRPCAvailabilityUsesColdStartTolerantProbeTimeouts() {
        XCTAssertGreaterThan(PiIntegrationConfiguration.managedRPCVersionProbeTimeout, 5)
        XCTAssertGreaterThan(
            PiIntegrationConfiguration.managedRPCColdStartRetryTimeout,
            PiIntegrationConfiguration.managedRPCVersionProbeTimeout
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

    func testPiModelPollingUsesEphemeralDiscoveryLaunchProfile() throws {
        let repoRoot = try RepoRoot.url(filePath: #filePath)
        let sourcePath = "Sources/RepoPrompt/Infrastructure/AI/Providers/Pi/PiModelPollingService.swift"
        let contents = try String(contentsOf: repoRoot.appendingPathComponent(sourcePath), encoding: .utf8)
        XCTAssertTrue(contents.contains("managedRPCModelDiscoveryLaunchArguments()"), sourcePath)
        XCTAssertFalse(contents.contains("managedRPCLaunchArguments()"), sourcePath)
    }

    func testAvailabilityProbeAcceptsSupportedVersionOutput() async throws {
        let scriptURL = try makeFakePiVersionScript(exitCode: 0, stdout: "pi 0.79.0\n")

        let availability = await PiIntegrationConfiguration.checkAvailability(
            commandName: scriptURL.path,
            timeout: 2
        )

        XCTAssertTrue(availability.isAvailable)
        XCTAssertEqual(availability.version, "0.79.0")
        XCTAssertNil(availability.diagnostic)
    }

    func testAvailabilityProbeReportsExecutableVersionWithoutManagedGate() async throws {
        let scriptURL = try makeFakePiVersionScript(exitCode: 0, stdout: "pi 0.78.1\n")

        let availability = await PiIntegrationConfiguration.checkAvailability(
            commandName: scriptURL.path,
            timeout: 2
        )

        XCTAssertTrue(availability.isAvailable)
        XCTAssertEqual(availability.version, "0.78.1")
        XCTAssertNil(availability.diagnostic)
    }

    func testManagedRPCAvailabilityProbeRejectsUnsupportedVersionOutput() async throws {
        await PiIntegrationConfiguration.resetSupportedVersionCacheForTests()
        let scriptURL = try makeFakePiVersionScript(exitCode: 0, stdout: "pi 0.78.1\n")

        let availability = await PiIntegrationConfiguration.checkManagedRPCAvailability(
            commandName: scriptURL.path,
            timeout: 2
        )

        XCTAssertFalse(availability.isAvailable)
        XCTAssertEqual(availability.version, "0.78.1")
        XCTAssertEqual(availability.failureKind, .unsupportedVersion)
        XCTAssertEqual(
            availability.diagnostic,
            "RepoPrompt requires pi 0.79.0 or newer for managed RPC project trust; found 0.78.1 at \(scriptURL.path). Update pi and try again."
        )
        await PiIntegrationConfiguration.resetSupportedVersionCacheForTests()
    }

    func testManagedRPCAvailabilityUsesLastSupportedVersionWhenFreshProbeTimesOut() async throws {
        await PiIntegrationConfiguration.resetSupportedVersionCacheForTests()
        let scriptURL = try makeFakePiVersionScript(exitCode: 0, stdout: "pi 0.79.1\n")

        let initialAvailability = await PiIntegrationConfiguration.checkManagedRPCAvailability(
            commandName: scriptURL.path,
            timeout: 2,
            allowCachedSupportedVersionOnTimeout: true
        )
        XCTAssertTrue(initialAvailability.isAvailable)
        XCTAssertFalse(initialAvailability.usedCachedSupportedVersion)

        try writeFakePiVersionScript(at: scriptURL, exitCode: 0, stdout: "pi 0.79.1\n", sleepSeconds: 2)
        let timeoutFallback = await PiIntegrationConfiguration.checkManagedRPCAvailability(
            commandName: scriptURL.path,
            timeout: 0.1,
            allowCachedSupportedVersionOnTimeout: true
        )

        XCTAssertTrue(timeoutFallback.isAvailable)
        XCTAssertEqual(timeoutFallback.version, "0.79.1")
        XCTAssertTrue(timeoutFallback.usedCachedSupportedVersion)
        XCTAssertEqual(timeoutFallback.commandPath, scriptURL.path)
        XCTAssertTrue(timeoutFallback.diagnostic?.contains("fresh pi --version timed out") ?? false)
        await PiIntegrationConfiguration.resetSupportedVersionCacheForTests()
    }

    func testManagedRPCAvailabilityDoesNotUseCacheWhenFreshProbeFindsUnsupportedVersion() async throws {
        await PiIntegrationConfiguration.resetSupportedVersionCacheForTests()
        let scriptURL = try makeFakePiVersionScript(exitCode: 0, stdout: "pi 0.79.1\n")
        _ = await PiIntegrationConfiguration.checkManagedRPCAvailability(
            commandName: scriptURL.path,
            timeout: 2,
            allowCachedSupportedVersionOnTimeout: true
        )

        try writeFakePiVersionScript(at: scriptURL, exitCode: 0, stdout: "pi 0.78.1\n")
        let unsupported = await PiIntegrationConfiguration.checkManagedRPCAvailability(
            commandName: scriptURL.path,
            timeout: 2,
            allowCachedSupportedVersionOnTimeout: true
        )

        XCTAssertFalse(unsupported.isAvailable)
        XCTAssertEqual(unsupported.version, "0.78.1")
        XCTAssertEqual(unsupported.failureKind, .unsupportedVersion)
        XCTAssertFalse(unsupported.usedCachedSupportedVersion)
        await PiIntegrationConfiguration.resetSupportedVersionCacheForTests()
    }

    func testManagedRPCAvailabilityRetriesFirstTimeoutBeforeFailingSetup() async throws {
        await PiIntegrationConfiguration.resetSupportedVersionCacheForTests()
        let scriptURL = try makeFakePiVersionScript(exitCode: 0, stdout: "pi 0.79.1\n", sleepSeconds: 0.2)

        let availability = await PiIntegrationConfiguration.checkManagedRPCAvailability(
            commandName: scriptURL.path,
            timeout: 0.05,
            allowCachedSupportedVersionOnTimeout: true,
            firstTimeoutRetryTimeout: 2
        )

        XCTAssertTrue(availability.isAvailable)
        XCTAssertEqual(availability.version, "0.79.1")
        XCTAssertNil(availability.failureKind)
        XCTAssertFalse(availability.usedCachedSupportedVersion)
        await PiIntegrationConfiguration.resetSupportedVersionCacheForTests()
    }

    func testAvailabilityProbeReportsFailureWithoutFallback() async throws {
        let scriptURL = try makeFakePiVersionScript(exitCode: 2, stdout: "pi unavailable", stderr: "pi unavailable")

        let availability = await PiIntegrationConfiguration.checkAvailability(
            commandName: scriptURL.path,
            timeout: 2
        )

        XCTAssertFalse(availability.isAvailable)
        XCTAssertNil(availability.version)
        XCTAssertNotNil(availability.diagnostic)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PiIntegrationConfigurationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        temporaryURLs.append(url)
        return url
    }

    private func makeFakePiVersionScript(
        exitCode: Int32,
        stdout: String = "",
        stderr: String = "",
        sleepSeconds: TimeInterval = 0
    ) throws -> URL {
        let directory = try makeTemporaryDirectory()
        let scriptURL = directory.appendingPathComponent("fake_pi_version.py")
        try writeFakePiVersionScript(
            at: scriptURL,
            exitCode: exitCode,
            stdout: stdout,
            stderr: stderr,
            sleepSeconds: sleepSeconds
        )
        return scriptURL
    }

    private func writeFakePiVersionScript(
        at scriptURL: URL,
        exitCode: Int32,
        stdout: String = "",
        stderr: String = "",
        sleepSeconds: TimeInterval = 0
    ) throws {
        let script = #"""
        #!/usr/bin/env python3
        import sys
        import time
        time.sleep(__SLEEP_SECONDS__)
        sys.stdout.write("__STDOUT__")
        sys.stdout.flush()
        sys.stderr.write("__STDERR__")
        sys.stderr.flush()
        sys.exit(__EXIT_CODE__)
        """#
        .replacingOccurrences(of: "__SLEEP_SECONDS__", with: String(sleepSeconds))
        .replacingOccurrences(of: "__STDOUT__", with: escapedPythonString(stdout))
        .replacingOccurrences(of: "__STDERR__", with: escapedPythonString(stderr))
        .replacingOccurrences(of: "__EXIT_CODE__", with: String(exitCode))
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
    }

    private func escapedPythonString(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
    }
}
