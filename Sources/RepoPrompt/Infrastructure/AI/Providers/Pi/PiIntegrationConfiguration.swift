import Foundation
import RepoPromptShared

enum PiModelSelectionContract {
    static func selectableRawValue(provider rawProvider: String?, id rawID: String) -> String? {
        let id = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return nil }
        guard let provider = normalizedNonEmpty(rawProvider) else {
            return isSelectableRawValue(id) ? id : nil
        }
        if id.hasPrefix("\(provider)/") {
            return isSelectableRawValue(id) ? id : nil
        }
        return selectableRawValue("\(provider)/\(id)")
    }

    static func selectableRawValue(_ rawModel: String) -> String? {
        let trimmed = rawModel.trimmingCharacters(in: .whitespacesAndNewlines)
        return isSelectableRawValue(trimmed) ? trimmed : nil
    }

    static func isSelectableRawValue(_ rawModel: String) -> Bool {
        let trimmed = rawModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let components = trimmed.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard components.count == 2 else { return false }
        return !components[0].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !components[1].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func normalizedNonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}

enum PiManagedRunLaunchPolicy: Equatable {
    /// Add `--no-extensions` while still allowing RepoPrompt's explicit `--extension <bridge>` path.
    case disableDiscoveredExtensions
    /// Preserve pi's default extension discovery for compatibility with extension-provided providers/models/tools.
    case allowDiscoveredExtensions

    static let defaultPolicy: Self = .allowDiscoveredExtensions

    var allowsDiscoveredExtensions: Bool {
        self == .allowDiscoveredExtensions
    }
}

enum PiIntegrationConfiguration {
    struct Availability: Equatable {
        enum FailureKind: Equatable {
            case timedOut
            case exitStatus(Int32)
            case thrown(String)
            case unsupportedVersion
        }

        var isAvailable: Bool
        var commandPath: String?
        var version: String?
        var diagnostic: String?
        var failureKind: FailureKind?
        var usedCachedSupportedVersion: Bool

        init(
            isAvailable: Bool,
            commandPath: String?,
            version: String?,
            diagnostic: String?,
            failureKind: FailureKind? = nil,
            usedCachedSupportedVersion: Bool = false
        ) {
            self.isAvailable = isAvailable
            self.commandPath = commandPath
            self.version = version
            self.diagnostic = diagnostic
            self.failureKind = failureKind
            self.usedCachedSupportedVersion = usedCachedSupportedVersion
        }
    }

    private struct SupportedVersionCacheEntry: Equatable {
        var commandPath: String
        var version: String
        var verifiedAt: Date
    }

    private actor SupportedVersionCache {
        private var entries: [String: SupportedVersionCacheEntry] = [:]

        func record(commandPath: String, version: String, verifiedAt: Date = Date()) {
            entries[commandPath] = SupportedVersionCacheEntry(
                commandPath: commandPath,
                version: version,
                verifiedAt: verifiedAt
            )
        }

        func entry(for commandPath: String, now: Date = Date(), maxAge: TimeInterval) -> SupportedVersionCacheEntry? {
            guard let entry = entries[commandPath], now.timeIntervalSince(entry.verifiedAt) <= maxAge else { return nil }
            return entry
        }

        func reset() {
            entries.removeAll()
        }
    }

    static let providerDisplayName = "pi"
    static let minimumSupportedVersion = "0.79.0"
    static let managedRPCVersionProbeTimeout: TimeInterval = 15
    static let managedRPCColdStartRetryTimeout: TimeInterval = 30
    private static let supportedVersionCacheMaxAge: TimeInterval = 6 * 60 * 60
    private static let supportedVersionCache = SupportedVersionCache()
    static let managedRunEnvironmentKey = "REPOPROMPT_PI_MANAGED_RUN"
    static let managedRunEnvironmentValue = "1"
    static let permissionLevelEnvironmentKey = "REPOPROMPT_PI_PERMISSION_LEVEL"
    static let approvalTimeoutMillisecondsEnvironmentKey = "REPOPROMPT_PI_APPROVAL_TIMEOUT_MS"
    static let inheritedSubagentExtensionsEnvironmentKey = "PI_SUBAGENT_INHERITED_EXTENSIONS_JSON"
    static let agentDirectoryEnvironmentKey = "PI_CODING_AGENT_DIR"

    /// A pi model is eligible for RepoPrompt when pi reports a non-empty model
    /// identifier that can be selected by pi's RPC `set_model` contract. RepoPrompt
    /// must not maintain its own provider allowlist, but concrete pi model selections
    /// need a provider-qualified raw value (`provider/model`). Providerless no-slash
    /// IDs are hidden rather than exposed as broken menu choices.
    static func isExposableModelProviderID(_ rawProvider: String?) -> Bool {
        guard let rawProvider else { return false }
        return !rawProvider.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func isExposableModelRaw(_ rawModel: String) -> Bool {
        PiModelSelectionContract.isSelectableRawValue(rawModel)
    }

    /// RepoPrompt-managed pi RPC runs are explicit user actions for the selected workspace.
    /// pi 0.79+ otherwise ignores project-local trust-gated inputs in non-interactive RPC mode.
    static func managedRPCLaunchArguments(
        bridgeExtensionPath: String? = nil,
        launchPolicy: PiManagedRunLaunchPolicy
    ) -> [String] {
        var arguments = ["--mode", "rpc", "--approve"]
        if !launchPolicy.allowsDiscoveredExtensions {
            arguments.append("--no-extensions")
        }
        if let bridgeExtensionPath {
            arguments.append(contentsOf: ["--extension", bridgeExtensionPath])
        }
        return arguments
    }

    static func managedRPCModelDiscoveryLaunchArguments(launchPolicy: PiManagedRunLaunchPolicy) -> [String] {
        managedRPCLaunchArguments(launchPolicy: launchPolicy) + ["--no-session", "--no-tools"]
    }

    static func managedRPCPromptOnlyLaunchArguments(launchPolicy: PiManagedRunLaunchPolicy) -> [String] {
        managedRPCLaunchArguments(launchPolicy: launchPolicy) + ["--no-session", "--no-tools"]
    }

    static func managedRunEnvironment(
        permissionLevel: PiAgentToolPreferences.PermissionLevel? = nil,
        bridgeExtensionPath: String? = nil
    ) -> [String: String] {
        var environment = [
            managedRunEnvironmentKey: managedRunEnvironmentValue,
            approvalTimeoutMillisecondsEnvironmentKey: String(Int(MCPTimeoutPolicy.askUserDefaultTimeoutSeconds * 1000))
        ]
        if let permissionLevel {
            environment[permissionLevelEnvironmentKey] = permissionLevel.rawValue
        }
        if let bridgeExtensionPath,
           !bridgeExtensionPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let encoded = try? JSONEncoder().encode([bridgeExtensionPath]),
           let json = String(data: encoded, encoding: .utf8)
        {
            environment[inheritedSubagentExtensionsEnvironmentKey] = json
        }
        return environment
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
                    commandPath: commandName,
                    version: nil,
                    diagnostic: "pi --version timed out after \(timeout) seconds for \(commandName).",
                    failureKind: .timedOut
                )
            }
            guard result.status == 0 else {
                let detail = stderr.isEmpty ? stdout : stderr
                let diagnostic = if detail.isEmpty {
                    "pi --version at \(commandName) exited with status \(result.status)."
                } else {
                    "pi --version at \(commandName) exited with status \(result.status): \(detail)"
                }
                return Availability(
                    isAvailable: false,
                    commandPath: commandName,
                    version: nil,
                    diagnostic: diagnostic,
                    failureKind: .exitStatus(result.status)
                )
            }
            let version = parseVersion(from: stdout.isEmpty ? stderr : stdout)
            return Availability(
                isAvailable: true,
                commandPath: commandName,
                version: version,
                diagnostic: nil
            )
        } catch {
            return Availability(
                isAvailable: false,
                commandPath: commandName,
                version: nil,
                diagnostic: "pi --version at \(commandName) failed: \(error.localizedDescription)",
                failureKind: .thrown(error.localizedDescription)
            )
        }
    }

    static func checkManagedRPCAvailability(
        commandName: String = CLILaunchProfiles.pi.commandName,
        workingDirectory: String? = nil,
        timeout: TimeInterval = managedRPCVersionProbeTimeout,
        enableDebugLogging: Bool = false,
        allowCachedSupportedVersionOnTimeout: Bool = false,
        firstTimeoutRetryTimeout: TimeInterval? = managedRPCColdStartRetryTimeout
    ) async -> Availability {
        let availability = await checkAvailability(
            commandName: commandName,
            workingDirectory: workingDirectory,
            timeout: timeout,
            enableDebugLogging: enableDebugLogging
        )
        guard availability.isAvailable else {
            if availability.failureKind == .timedOut {
                if allowCachedSupportedVersionOnTimeout,
                   let cached = await supportedVersionCache.entry(
                       for: commandName,
                       maxAge: supportedVersionCacheMaxAge
                   )
                {
                    return Availability(
                        isAvailable: true,
                        commandPath: cached.commandPath,
                        version: cached.version,
                        diagnostic: "Using last verified supported pi \(cached.version) at \(cached.commandPath) because fresh pi --version timed out after \(timeout) seconds.",
                        failureKind: nil,
                        usedCachedSupportedVersion: true
                    )
                }
                if let firstTimeoutRetryTimeout,
                   firstTimeoutRetryTimeout > timeout
                {
                    return await checkManagedRPCAvailability(
                        commandName: commandName,
                        workingDirectory: workingDirectory,
                        timeout: firstTimeoutRetryTimeout,
                        enableDebugLogging: enableDebugLogging,
                        allowCachedSupportedVersionOnTimeout: false,
                        firstTimeoutRetryTimeout: nil
                    )
                }
            }
            return availability
        }
        guard isSupportedVersion(availability.version) else {
            return Availability(
                isAvailable: false,
                commandPath: availability.commandPath,
                version: availability.version,
                diagnostic: unsupportedVersionDiagnostic(availability.version, commandPath: availability.commandPath),
                failureKind: .unsupportedVersion
            )
        }
        if let version = availability.version, let commandPath = availability.commandPath {
            await supportedVersionCache.record(commandPath: commandPath, version: version)
        }
        return availability
    }

    static func resetSupportedVersionCacheForTests() async {
        await supportedVersionCache.reset()
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

    private static func unsupportedVersionDiagnostic(_ version: String?, commandPath: String?) -> String {
        let foundVersion = version ?? "an unrecognized version"
        let pathSuffix = commandPath.map { " at \($0)" } ?? ""
        return "RepoPrompt requires pi \(minimumSupportedVersion) or newer for managed RPC project trust; found \(foundVersion)\(pathSuffix). Update pi and try again."
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
