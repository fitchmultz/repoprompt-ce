import Foundation

enum CursorACPLaunchCandidate: CaseIterable, Equatable {
    case cursorAgentACP
    case cursorAgentSubcommand

    var command: String {
        switch self {
        case .cursorAgentACP:
            CLILaunchProfiles.cursor.commandName
        case .cursorAgentSubcommand:
            "cursor"
        }
    }

    var launchArguments: [String] {
        switch self {
        case .cursorAgentACP:
            ["--approve-mcps", "acp"]
        case .cursorAgentSubcommand:
            ["agent", "--approve-mcps", "acp"]
        }
    }

    var helpArguments: [String] {
        switch self {
        case .cursorAgentACP:
            ["acp", "--help"]
        case .cursorAgentSubcommand:
            ["agent", "acp", "--help"]
        }
    }
}

struct CursorACPResolvedLaunch: Equatable {
    let command: String
    let arguments: [String]
    let additionalPathHints: [String]
    let environment: [String: String]
    let executableIdentity: ExecutableFileIdentity
    let candidate: CursorACPLaunchCandidate
}

enum CursorACPLaunchResolutionError: Error, Equatable, LocalizedError {
    case missingConfiguredCommand
    case unsafeConfiguredCommand(String)
    case exactPathNotFound(String)
    case environmentDiscoveryRequired(String)
    case unsafeApplicationPath(String)
    case unsafeCanonicalBasename(String)

    var errorDescription: String? {
        switch self {
        case .missingConfiguredCommand:
            "Cursor Agent CLI launch requires an exact `cursor-agent` command or absolute path."
        case let .unsafeConfiguredCommand(command):
            "Refusing unsafe Cursor ACP command `\(command)`. Configure the CLI-only `cursor-agent` executable."
        case let .exactPathNotFound(command):
            "Cursor Agent CLI was not found as a valid executable regular file for `\(command)`. Install `cursor-agent` or configure its absolute path."
        case let .environmentDiscoveryRequired(command):
            "Cursor Agent CLI path discovery has not completed for `\(command)`. Run the Cursor ACP support preflight or configure an absolute `cursor-agent` path."
        case let .unsafeApplicationPath(path):
            "Refusing Cursor ACP executable inside an application bundle: \(path)"
        case let .unsafeCanonicalBasename(path):
            "Refusing Cursor ACP executable whose canonical basename is `cursor`: \(path)"
        }
    }
}

final class CursorACPLaunchResolver: @unchecked Sendable {
    typealias EnvironmentProvider = @Sendable (_ enableDebugLogging: Bool) async -> [String: String]

    private let environmentProvider: EnvironmentProvider
    private let probeMutex = AsyncMutex()
    private let lock = NSLock()
    private var cachedLaunchByKey: [String: CursorACPResolvedLaunch] = [:]

    init(
        environmentProvider: @escaping EnvironmentProvider = { enableDebugLogging in
            let result = await ProcessEnvironmentBuilder.build(
                ProcessEnvironmentRequest(
                    purpose: .acpAgent(providerID: ACPProviderID.cursor.rawValue),
                    enableDebugLogging: enableDebugLogging
                )
            )
            return result.environment
        }
    ) {
        self.environmentProvider = environmentProvider
    }

    func resolvedLaunch(for config: CursorAgentConfig) throws -> CursorACPResolvedLaunch {
        let key = cacheKey(for: config)
        if let cached = cachedLaunch(forKey: key) {
            do {
                try cached.executableIdentity.validateForTrustedPathLaunch(atPath: cached.command)
                return cached
            } catch {
                invalidate(key: key)
                throw error
            }
        }

        let launch = try resolveExplicitLaunch(for: config)
        cache(launch, key: key)
        return launch
    }

    func probeSupport(for config: CursorAgentConfig) async throws -> ACPSupportResult {
        try await probeMutex.withLock { [self] in
            try await probeSupportSerially(for: config)
        }
    }

    private func probeSupportSerially(for config: CursorAgentConfig) async throws -> ACPSupportResult {
        let key = cacheKey(for: config)
        invalidate(key: key)
        var failureMessages: [String] = []
        do {
            // Resolve from the current effective environment on every support check. The cache only
            // bridges this successful probe to the immediately following launch configuration.
            let launches = try await resolveLaunchesForProbe(for: config)
            for launch in launches {
                let candidate = launch.candidate
                let processConfig = CLIProcessConfiguration(
                    command: launch.command,
                    additionalPaths: [],
                    enableDebugLogging: config.enableDebugLogging
                )
                let result = try await CLIProcessRunner(config: processConfig).run(
                    args: candidate.helpArguments,
                    stdin: nil,
                    outputMode: .none,
                    timeout: 10,
                    cancelChildOnTaskCancellation: true
                )
                guard result.status == 0 else {
                    failureMessages.append("`\(candidate.command) \(candidate.helpArguments.joined(separator: " "))` exited with status \(result.status).")
                    continue
                }

                let stdout = String(data: result.stdout, encoding: .utf8) ?? ""
                let stderr = String(data: result.stderr, encoding: .utf8) ?? ""
                let combined = "\(stdout)\n\(stderr)"
                guard combined.localizedCaseInsensitiveContains("acp")
                    || combined.localizedCaseInsensitiveContains("agent client protocol")
                else {
                    failureMessages.append("`\(candidate.command) \(candidate.helpArguments.joined(separator: " "))` did not advertise ACP support.")
                    continue
                }

                try launch.executableIdentity.validateForTrustedPathLaunch(atPath: launch.command)
                cache(launch, key: key)
                return .supported
            }
            let detail = failureMessages.isEmpty ? "Tried `cursor-agent acp` and `cursor agent acp`." : failureMessages.joined(separator: " ")
            return .unsupported(reason: "Cursor ACP preflight failed before startup. \(detail)")
        } catch is CancellationError {
            invalidate(key: key)
            throw CancellationError()
        } catch {
            invalidate(key: key)
            return .unsupported(reason: error.localizedDescription)
        }
    }

    private func resolveLaunchesForProbe(for config: CursorAgentConfig) async throws -> [CursorACPResolvedLaunch] {
        let configuredCommand = try validatedConfiguredCommand(config)
        let environment = await environmentProvider(config.enableDebugLogging)
        try Task.checkCancellation()
        if configuredCommand.contains("/") {
            return try [resolveExplicitLaunch(for: config, environment: environment)]
        }

        let effectiveHints = CLIPathHints.nativeDefaultsSupplemented(with: config.additionalPathHints)
        var launches: [CursorACPResolvedLaunch] = []
        for candidate in orderedCandidates(configuredCommand: configuredCommand) {
            let resolved = CommandPathResolver.resolve(
                candidate.command,
                environment: environment,
                additionalPaths: effectiveHints,
                preferredBasenames: candidate == .cursorAgentACP ? CLILaunchProfiles.cursor.preferredBasenames : [candidate.command]
            )
            do {
                try launches.append(validatedLaunch(
                    entryPath: resolved,
                    configuredCommand: configuredCommand,
                    candidate: candidate,
                    additionalPathHints: effectiveHints,
                    environment: environment
                ))
            } catch CursorACPLaunchResolutionError.exactPathNotFound {
                continue
            }
        }
        if launches.isEmpty {
            throw CursorACPLaunchResolutionError.exactPathNotFound(configuredCommand)
        }
        return launches
    }

    private func resolveExplicitLaunch(
        for config: CursorAgentConfig,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> CursorACPResolvedLaunch {
        let configuredCommand = try validatedConfiguredCommand(config)
        guard configuredCommand.contains("/") else {
            throw CursorACPLaunchResolutionError.environmentDiscoveryRequired(configuredCommand)
        }
        let effectiveHints = CLIPathHints.nativeDefaultsSupplemented(with: config.additionalPathHints)
        let expanded = CommandPathResolver.expandPath(configuredCommand, environment: environment)
        let candidate = candidate(forConfiguredCommand: configuredCommand)
        return try validatedLaunch(
            entryPath: expanded,
            configuredCommand: configuredCommand,
            candidate: candidate,
            additionalPathHints: effectiveHints,
            environment: environment
        )
    }

    private func validatedConfiguredCommand(_ config: CursorAgentConfig) throws -> String {
        let configuredCommand = config.commandName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !configuredCommand.isEmpty else {
            throw CursorACPLaunchResolutionError.missingConfiguredCommand
        }
        if configuredCommand.contains("/") {
            let basename = URL(fileURLWithPath: configuredCommand).lastPathComponent
            guard CursorACPLaunchCandidate.allCases.contains(where: { basename.caseInsensitiveCompare($0.command) == .orderedSame }) else {
                throw CursorACPLaunchResolutionError.unsafeConfiguredCommand(configuredCommand)
            }
        } else if !CursorACPLaunchCandidate.allCases.contains(where: { configuredCommand.caseInsensitiveCompare($0.command) == .orderedSame }) {
            throw CursorACPLaunchResolutionError.unsafeConfiguredCommand(configuredCommand)
        }
        return configuredCommand
    }

    private func orderedCandidates(configuredCommand: String) -> [CursorACPLaunchCandidate] {
        if candidate(forConfiguredCommand: configuredCommand) == .cursorAgentSubcommand {
            return [.cursorAgentSubcommand, .cursorAgentACP]
        }
        return [.cursorAgentACP, .cursorAgentSubcommand]
    }

    private func candidate(forConfiguredCommand configuredCommand: String) -> CursorACPLaunchCandidate {
        let basename = configuredCommand.contains("/") ? URL(fileURLWithPath: configuredCommand).lastPathComponent : configuredCommand
        if basename.caseInsensitiveCompare(CursorACPLaunchCandidate.cursorAgentSubcommand.command) == .orderedSame {
            return .cursorAgentSubcommand
        }
        return .cursorAgentACP
    }

    private func validatedLaunch(
        entryPath: String,
        configuredCommand: String,
        candidate: CursorACPLaunchCandidate,
        additionalPathHints: [String],
        environment: [String: String]
    ) throws -> CursorACPResolvedLaunch {
        guard entryPath.hasPrefix("/"),
              URL(fileURLWithPath: entryPath).lastPathComponent.caseInsensitiveCompare(candidate.command) == .orderedSame
        else {
            throw CursorACPLaunchResolutionError.exactPathNotFound(configuredCommand)
        }

        let identity: ExecutableFileIdentity
        do {
            identity = try ExecutableFileIdentity.captureForTrustedPathLaunch(atPath: entryPath)
        } catch {
            throw CursorACPLaunchResolutionError.exactPathNotFound(configuredCommand)
        }

        let canonicalURL = URL(fileURLWithPath: identity.canonicalPath)
        if candidate == .cursorAgentACP,
           canonicalURL.pathComponents.contains(where: { $0.lowercased().hasSuffix(".app") })
        {
            throw CursorACPLaunchResolutionError.unsafeApplicationPath(identity.canonicalPath)
        }
        if candidate == .cursorAgentACP,
           canonicalURL.lastPathComponent.caseInsensitiveCompare("cursor") == .orderedSame
        {
            throw CursorACPLaunchResolutionError.unsafeCanonicalBasename(identity.canonicalPath)
        }

        return CursorACPResolvedLaunch(
            command: identity.canonicalPath,
            arguments: candidate.launchArguments,
            additionalPathHints: additionalPathHints,
            environment: environment,
            executableIdentity: identity,
            candidate: candidate
        )
    }

    private func cachedLaunch(forKey key: String) -> CursorACPResolvedLaunch? {
        lock.lock()
        defer { lock.unlock() }
        return cachedLaunchByKey[key]
    }

    private func cache(_ launch: CursorACPResolvedLaunch, key: String) {
        lock.lock()
        cachedLaunchByKey[key] = launch
        lock.unlock()
    }

    private func invalidate(key: String) {
        lock.lock()
        cachedLaunchByKey.removeValue(forKey: key)
        lock.unlock()
    }

    private func cacheKey(for config: CursorAgentConfig) -> String {
        ([config.commandName] + config.additionalPathHints).joined(separator: "\u{1F}")
    }
}
