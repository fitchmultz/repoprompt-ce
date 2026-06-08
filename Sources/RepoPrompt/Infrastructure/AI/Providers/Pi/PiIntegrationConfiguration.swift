import Foundation

enum PiIntegrationConfiguration {
    struct Availability: Equatable {
        var isAvailable: Bool
        var commandPath: String?
        var version: String?
        var diagnostic: String?
    }

    static let providerDisplayName = "pi"

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
        timeout: TimeInterval = 5,
        enableDebugLogging: Bool = false
    ) async -> Availability {
        let configuration = processConfiguration(
            commandName: commandName,
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
            return Availability(
                isAvailable: true,
                commandPath: nil,
                version: parseVersion(from: stdout.isEmpty ? stderr : stdout),
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

    static func parseVersion(from output: String) -> String? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let match = trimmed.range(of: #"\d+(?:\.\d+){1,3}(?:[-+][A-Za-z0-9._-]+)?"#, options: .regularExpression) {
            return String(trimmed[match])
        }
        return nil
    }
}
