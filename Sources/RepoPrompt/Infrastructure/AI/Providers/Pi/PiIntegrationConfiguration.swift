import Foundation

enum PiIntegrationConfiguration {
    struct Availability: Equatable {
        var isAvailable: Bool
        var commandPath: String?
        var version: String?
        var diagnostic: String?
    }

    static let providerDisplayName = "pi"
    static let minimumSupportedVersion = "0.79.0"
    static let managedRunEnvironmentKey = "REPOPROMPT_PI_MANAGED_RUN"
    static let managedRunEnvironmentValue = "1"

    /// RepoPrompt-managed pi RPC runs are explicit user actions for the selected workspace.
    /// pi 0.79+ otherwise ignores project-local AGENTS.md/.pi inputs in non-interactive RPC mode.
    static func managedRPCLaunchArguments(bridgeExtensionPath: String? = nil) -> [String] {
        var arguments = ["--mode", "rpc", "--approve"]
        if let bridgeExtensionPath {
            arguments.append(contentsOf: ["--extension", bridgeExtensionPath])
        }
        return arguments
    }

    static func managedRPCPromptOnlyLaunchArguments() -> [String] {
        managedRPCLaunchArguments() + ["--no-tools"]
    }

    static func managedRunEnvironment() -> [String: String] {
        [managedRunEnvironmentKey: managedRunEnvironmentValue]
    }

    static func processConfiguration(
        commandName: String = CLILaunchProfiles.pi.commandName,
        workingDirectory: String? = nil,
        enableDebugLogging: Bool = false,
        logCollector: CLIProcessLogCollector? = nil
    ) -> CLIProcessConfiguration {
        CLIProcessConfiguration(
            command: commandName,
            workingDirectory: workingDirectory,
            additionalPaths: CLILaunchProfiles.pi.supplementalSearchPaths,
            enableDebugLogging: enableDebugLogging,
            logCollector: logCollector,
            resolveCandidates: CLILaunchProfiles.pi.preferredBasenames,
            captureStdoutTailBytes: 16 * 1024,
            captureStderrTailBytes: 64 * 1024,
            logStdinSampleBytes: 0
        )
    }

    static func checkAvailability(
        commandName: String = CLILaunchProfiles.pi.commandName,
        workingDirectory: String? = nil,
        timeout: TimeInterval = 5,
        enableDebugLogging: Bool = false
    ) async -> Availability {
        let configuration = processConfiguration(
            commandName: commandName,
            workingDirectory: workingDirectory,
            enableDebugLogging: enableDebugLogging
        )
        let runner = CLIProcessRunner(config: configuration)
        do {
            let result = try await runner.run(
                args: ["--version"],
                stdin: nil,
                outputMode: .none,
                timeout: timeout
            )
            let stdout = String(data: result.stdout, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let stderr = String(data: result.stderr, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !result.timedOut else {
                return Availability(
                    isAvailable: false,
                    commandPath: nil,
                    version: nil,
                    diagnostic: "pi --version timed out after \(timeout) seconds."
                )
            }
            guard result.status == 0 else {
                let detail = stderr.isEmpty ? stdout : stderr
                return Availability(
                    isAvailable: false,
                    commandPath: nil,
                    version: nil,
                    diagnostic: detail.isEmpty ? "pi --version exited with status \(result.status)." : detail
                )
            }
            let version = parseVersion(from: stdout.isEmpty ? stderr : stdout)
            return Availability(
                isAvailable: true,
                commandPath: nil,
                version: version,
                diagnostic: nil
            )
        } catch {
            return Availability(
                isAvailable: false,
                commandPath: nil,
                version: nil,
                diagnostic: error.localizedDescription
            )
        }
    }

    static func checkManagedRPCAvailability(
        commandName: String = CLILaunchProfiles.pi.commandName,
        workingDirectory: String? = nil,
        timeout: TimeInterval = 5,
        enableDebugLogging: Bool = false
    ) async -> Availability {
        let availability = await checkAvailability(
            commandName: commandName,
            workingDirectory: workingDirectory,
            timeout: timeout,
            enableDebugLogging: enableDebugLogging
        )
        guard availability.isAvailable else { return availability }
        guard isSupportedVersion(availability.version) else {
            return Availability(
                isAvailable: false,
                commandPath: availability.commandPath,
                version: availability.version,
                diagnostic: unsupportedVersionDiagnostic(availability.version)
            )
        }
        return availability
    }

    static func parseVersion(from output: String) -> String? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let match = trimmed.range(of: #"\d+(?:\.\d+){1,3}(?:[-+][A-Za-z0-9._-]+)?"#, options: .regularExpression) {
            return String(trimmed[match])
        }
        return nil
    }

    static func isSupportedVersion(_ version: String?) -> Bool {
        guard let version else { return false }
        let comparison = compareVersion(version, minimumSupportedVersion)
        guard comparison != .orderedAscending else { return false }
        return !(comparison == .orderedSame && isPreRelease(version))
    }

    private static func unsupportedVersionDiagnostic(_ version: String?) -> String {
        let foundVersion = version ?? "an unrecognized version"
        return "RepoPrompt requires pi \(minimumSupportedVersion) or newer for managed RPC project trust; found \(foundVersion). Update pi and try again."
    }

    private static func compareVersion(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let lhsComponents = numericVersionComponents(lhs)
        let rhsComponents = numericVersionComponents(rhs)
        for index in 0 ..< max(lhsComponents.count, rhsComponents.count) {
            let lhsValue = index < lhsComponents.count ? lhsComponents[index] : 0
            let rhsValue = index < rhsComponents.count ? rhsComponents[index] : 0
            if lhsValue < rhsValue { return .orderedAscending }
            if lhsValue > rhsValue { return .orderedDescending }
        }
        return .orderedSame
    }

    private static func numericVersionComponents(_ version: String) -> [Int] {
        versionCore(version)
            .split(separator: ".")
            .map { component in
                let numericPrefix = component.prefix { $0.isNumber }
                return Int(numericPrefix) ?? 0
            }
    }

    private static func isPreRelease(_ version: String) -> Bool {
        versionCoreAndSuffix(version).suffix?.starts(with: "-") ?? false
    }

    private static func versionCore(_ version: String) -> Substring {
        versionCoreAndSuffix(version).core
    }

    private static func versionCoreAndSuffix(_ version: String) -> (core: Substring, suffix: Substring?) {
        let parsed = version.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false)[0]
        let parts = parsed.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count > 1, let hyphenIndex = parsed.firstIndex(of: "-") else { return (parsed, nil) }
        return (parts[0], parsed[hyphenIndex...])
    }
}
