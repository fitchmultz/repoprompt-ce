import Foundation

enum PiRepoPromptBridgeExtensionInstaller {
    enum InstallerError: Error, LocalizedError, Equatable {
        case applicationSupportUnavailable
        case cliHelperUnavailable
        case globalBridgeAlreadyExists(URL)
        case globalBridgeNotManaged(URL)

        var errorDescription: String? {
            switch self {
            case .applicationSupportUnavailable:
                "Application Support is unavailable; cannot prepare RepoPrompt pi bridge extension."
            case .cliHelperUnavailable:
                "RepoPrompt MCP CLI helper is unavailable; cannot prepare RepoPrompt pi bridge extension."
            case let .globalBridgeAlreadyExists(url):
                "A pi extension already exists at \(url.path), but it is not managed by RepoPrompt."
            case let .globalBridgeNotManaged(url):
                "The pi extension at \(url.path) is not managed by RepoPrompt and was not removed."
            }
        }
    }

    enum GlobalInstallationStatus: Equatable {
        case notInstalled
        case installed
        case installedButStale
        case installedByOther
    }

    enum ManagedWindowInstallationStatus: Equatable {
        case installed
        case installedButStale
        case installedByOther
    }

    struct ManagedWindowInstallStatus: Equatable {
        let extensionURL: URL
        let windowID: Int?
        let status: ManagedWindowInstallationStatus
    }

    struct GlobalInstallResult: Equatable {
        let statusBeforeInstall: GlobalInstallationStatus
        let extensionURL: URL

        var wasAlreadyInstalled: Bool {
            statusBeforeInstall == .installed
        }
    }

    static let extensionVersion = "7"
    static let personalBridgeClientName = "repoprompt-pi-bridge"
    static let managedBridgeExecutionClientName = "pi-schema"
    private static let managedMarker = "// RepoPrompt CE managed pi bridge extension"
    private static let globalExtensionFileName = "repoprompt-bridge.ts"
    private static let managedExtensionFilePrefix = "repoprompt-bridge-window-"
    private static let managedExtensionFileExtension = "ts"

    static func install(
        windowID: Int,
        fileManager: FileManager = .default,
        cliPath: String? = Bundle.main.url(forAuxiliaryExecutable: "repoprompt-mcp")?.path
    ) throws -> URL {
        guard let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw InstallerError.applicationSupportUnavailable
        }
        guard let cliPath, !cliPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw InstallerError.cliHelperUnavailable
        }

        let directory = appSupport
            .appendingPathComponent("RepoPrompt CE", isDirectory: true)
            .appendingPathComponent("PiBridge", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try repairStaleManagedWindowExtensions(directory: directory, fileManager: fileManager, cliPath: cliPath)
        let extensionURL = managedExtensionURL(directory: directory, windowID: windowID)
        let source = extensionSource(windowID: windowID, cliPath: cliPath)
        if let existing = try? String(contentsOf: extensionURL, encoding: .utf8), existing == source {
            return extensionURL
        }
        try source.write(to: extensionURL, atomically: true, encoding: .utf8)
        return extensionURL
    }

    static func globalExtensionURL(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        homeDirectory
            .appendingPathComponent(".pi", isDirectory: true)
            .appendingPathComponent("agent", isDirectory: true)
            .appendingPathComponent("extensions", isDirectory: true)
            .appendingPathComponent(globalExtensionFileName, isDirectory: false)
    }

    static func managedWindowInstallStatuses(
        directory: URL,
        fileManager: FileManager = .default,
        cliPath: String
    ) -> [ManagedWindowInstallStatus] {
        let urls = (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []

        return urls
            .filter { isManagedWindowExtensionFileName($0.lastPathComponent) }
            .sorted { $0.path < $1.path }
            .map { url in
                let windowID = managedWindowID(fromFileName: url.lastPathComponent)
                guard let existing = try? String(contentsOf: url, encoding: .utf8),
                      existing.contains(managedMarker)
                else {
                    return ManagedWindowInstallStatus(extensionURL: url, windowID: windowID, status: .installedByOther)
                }
                guard let windowID else {
                    return ManagedWindowInstallStatus(extensionURL: url, windowID: nil, status: .installedButStale)
                }
                let expected = extensionSource(windowID: windowID, cliPath: cliPath)
                let status: ManagedWindowInstallationStatus = existing == expected ? .installed : .installedButStale
                return ManagedWindowInstallStatus(extensionURL: url, windowID: windowID, status: status)
            }
    }

    static func staleManagedWindowExtensionURLs(
        directory: URL,
        fileManager: FileManager = .default,
        cliPath: String
    ) -> [URL] {
        managedWindowInstallStatuses(directory: directory, fileManager: fileManager, cliPath: cliPath)
            .filter { $0.status == .installedButStale }
            .map(\.extensionURL)
    }

    static func repairStaleManagedWindowExtensions(
        directory: URL,
        fileManager: FileManager = .default,
        cliPath: String
    ) throws {
        for status in managedWindowInstallStatuses(directory: directory, fileManager: fileManager, cliPath: cliPath)
            where status.status == .installedButStale
        {
            if let windowID = status.windowID {
                try extensionSource(windowID: windowID, cliPath: cliPath)
                    .write(to: status.extensionURL, atomically: true, encoding: .utf8)
            } else {
                try fileManager.removeItem(at: status.extensionURL)
            }
        }
    }

    static func managedExtensionURL(directory: URL, windowID: Int) -> URL {
        directory.appendingPathComponent(
            "\(managedExtensionFilePrefix)\(windowID).\(managedExtensionFileExtension)",
            isDirectory: false
        )
    }

    static func globalInstallStatus(
        fileManager: FileManager = .default,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        cliPath: String? = Bundle.main.url(forAuxiliaryExecutable: "repoprompt-mcp")?.path
    ) -> GlobalInstallationStatus {
        let extensionURL = globalExtensionURL(homeDirectory: homeDirectory)
        guard fileManager.fileExists(atPath: extensionURL.path),
              let existing = try? String(contentsOf: extensionURL, encoding: .utf8)
        else {
            return .notInstalled
        }
        guard existing.contains(managedMarker) else {
            return .installedByOther
        }
        guard let cliPath, !cliPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .installedButStale
        }
        let expected = extensionSource(windowID: nil, cliPath: cliPath)
        return existing == expected ? .installed : .installedButStale
    }

    @discardableResult
    static func installGlobal(
        fileManager: FileManager = .default,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        cliPath: String? = Bundle.main.url(forAuxiliaryExecutable: "repoprompt-mcp")?.path
    ) throws -> GlobalInstallResult {
        guard let cliPath, !cliPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw InstallerError.cliHelperUnavailable
        }
        let extensionURL = globalExtensionURL(homeDirectory: homeDirectory)
        let status = globalInstallStatus(fileManager: fileManager, homeDirectory: homeDirectory, cliPath: cliPath)
        guard status != .installedByOther else {
            throw InstallerError.globalBridgeAlreadyExists(extensionURL)
        }
        let directory = extensionURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = extensionSource(windowID: nil, cliPath: cliPath)
        if status != .installed {
            try source.write(to: extensionURL, atomically: true, encoding: .utf8)
        }
        return GlobalInstallResult(statusBeforeInstall: status, extensionURL: extensionURL)
    }

    @discardableResult
    static func uninstallGlobal(
        fileManager: FileManager = .default,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        cliPath: String? = Bundle.main.url(forAuxiliaryExecutable: "repoprompt-mcp")?.path
    ) throws -> Bool {
        let extensionURL = globalExtensionURL(homeDirectory: homeDirectory)
        let status = globalInstallStatus(fileManager: fileManager, homeDirectory: homeDirectory, cliPath: cliPath)
        switch status {
        case .notInstalled:
            return false
        case .installed, .installedButStale:
            try fileManager.removeItem(at: extensionURL)
            return true
        case .installedByOther:
            throw InstallerError.globalBridgeNotManaged(extensionURL)
        }
    }

    static func extensionSource(windowID: Int?, cliPath: String) -> String {
        renderExtensionSource(
            template: bridgeTemplateSource(),
            windowID: windowID,
            cliPath: cliPath
        )
    }

    static func renderExtensionSource(
        template: String,
        windowID: Int?,
        cliPath: String
    ) -> String {
        let replacements: [String: String] = [
            "\"__REPOPROMPT_BRIDGE_VERSION__\"": jsonStringLiteral(extensionVersion),
            "\"__REPOPROMPT_CLI__\"": jsonStringLiteral(cliPath),
            "\"__REPOPROMPT_WINDOW_ID__\"": windowID.map { jsonStringLiteral(String($0)) } ?? "undefined",
            "\"__REPOPROMPT_MANAGED_RUN_ENV__\"": jsonStringLiteral(PiIntegrationConfiguration.managedRunEnvironmentKey),
            "\"__REPOPROMPT_SCHEMA_ARGS_JSON__\"": jsonStringLiteral(jsonStringArray(schemaArgs(windowID: windowID))),
            "\"__REPOPROMPT_TOOL_ARGS_PREFIX_JSON__\"": jsonStringLiteral(jsonStringArray(toolArgsPrefix(windowID: windowID)))
        ]
        return replacements.reduce(template) { rendered, replacement in
            rendered.replacingOccurrences(of: replacement.key, with: replacement.value)
        }
    }

    static func schemaArgs(windowID: Int?) -> [String] {
        guard let windowID else {
            return ["--tools-schema", "--compact"]
        }
        return ["--client-name", managedBridgeExecutionClientName, "--tools-schema", "--compact", "-w", String(windowID)]
    }

    static func toolArgsPrefix(windowID: Int?) -> [String] {
        let clientName = windowID == nil ? personalBridgeClientName : managedBridgeExecutionClientName
        var args = ["--client-name", clientName, "--raw-json"]
        if let windowID {
            args.append(contentsOf: ["-w", String(windowID)])
        }
        return args
    }

    static func toolArgs(toolName: String, paramsJSON: String, windowID: Int?) -> [String] {
        toolArgsPrefix(windowID: windowID) + ["-c", toolName, "-j", paramsJSON]
    }

    static func bridgeTemplateSource(
        fileManager: FileManager = .default,
        currentDirectoryPath: String = FileManager.default.currentDirectoryPath,
        sourceFilePath: String = #filePath
    ) -> String {
        if let resourceURL = Bundle.main.resourceURL?
            .appendingPathComponent("PiBridge", isDirectory: true)
            .appendingPathComponent(globalExtensionFileName, isDirectory: false),
            let source = try? String(contentsOf: resourceURL, encoding: .utf8)
        {
            return source
        }

        for baseURL in sourceTreeCandidateBaseURLs(
            currentDirectoryPath: currentDirectoryPath,
            sourceFilePath: sourceFilePath
        ) {
            let sourceTreeURL = baseURL
                .appendingPathComponent("AppResources", isDirectory: true)
                .appendingPathComponent("PiBridge", isDirectory: true)
                .appendingPathComponent(globalExtensionFileName, isDirectory: false)
            if fileManager.fileExists(atPath: sourceTreeURL.path),
               let source = try? String(contentsOf: sourceTreeURL, encoding: .utf8)
            {
                return source
            }
        }

        preconditionFailure("RepoPrompt pi bridge template is missing from AppResources/PiBridge/\(globalExtensionFileName).")
    }

    private static func sourceTreeCandidateBaseURLs(
        currentDirectoryPath: String,
        sourceFilePath: String
    ) -> [URL] {
        var candidates: [URL] = []
        appendCandidate(URL(fileURLWithPath: currentDirectoryPath), to: &candidates)

        var current = URL(fileURLWithPath: sourceFilePath).deletingLastPathComponent()
        for _ in 0 ..< 12 {
            appendCandidate(current, to: &candidates)
            current.deleteLastPathComponent()
        }
        return candidates
    }

    private static func appendCandidate(_ url: URL, to candidates: inout [URL]) {
        let standardized = url.standardizedFileURL
        guard !candidates.contains(standardized) else { return }
        candidates.append(standardized)
    }

    private static func isManagedWindowExtensionFileName(_ name: String) -> Bool {
        name.hasPrefix(managedExtensionFilePrefix) && name.hasSuffix(".\(managedExtensionFileExtension)")
    }

    private static func managedWindowID(fromFileName name: String) -> Int? {
        guard isManagedWindowExtensionFileName(name) else { return nil }
        let suffixLength = managedExtensionFileExtension.count + 1
        let raw = name
            .dropFirst(managedExtensionFilePrefix.count)
            .dropLast(suffixLength)
        return Int(raw)
    }

    private static func jsonStringArray(_ strings: [String]) -> String {
        let data = try! JSONEncoder().encode(strings)
        return String(data: data, encoding: .utf8)!
    }

    private static func jsonStringLiteral(_ string: String) -> String {
        let data = try! JSONEncoder().encode(string)
        return String(data: data, encoding: .utf8)!
    }
}
