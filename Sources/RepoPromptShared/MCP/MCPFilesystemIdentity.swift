import Darwin
import Foundation

/// Shared filesystem and stable-name authority for RepoPrompt MCP products.
///
/// Callers select their build flavor locally and pass it explicitly so this
/// shared target never depends on compile-configuration conditionals.
public struct MCPFilesystemIdentity: Equatable, Sendable {
    public enum Product: String, Sendable {
        case repoPromptCE
    }

    public enum BuildFlavor: String, Sendable {
        case debug
        case release
    }

    public struct FilesystemNamespace: Equatable, Sendable {
        public static let infoPlistKey = "RepoPromptApplicationSupportDirectoryName"
        public static let canonical = FilesystemNamespace(applicationSupportDirectoryName: "RepoPrompt CE")

        public let applicationSupportDirectoryName: String

        public init(applicationSupportDirectoryName: String) {
            let trimmed = applicationSupportDirectoryName.trimmingCharacters(in: .whitespacesAndNewlines)
            self.applicationSupportDirectoryName = trimmed.isEmpty || trimmed.contains("/") ? Self.canonical.applicationSupportDirectoryName : trimmed
        }

        public static func fromInfoPlist(bundle: Bundle = .main) -> Self {
            if let value = bundle.object(forInfoDictionaryKey: infoPlistKey) as? String {
                return FilesystemNamespace(applicationSupportDirectoryName: value)
            }
            if let value = containingAppInfoValue(forKey: infoPlistKey) {
                return FilesystemNamespace(applicationSupportDirectoryName: value)
            }
            return .canonical
        }

        var isCanonical: Bool {
            applicationSupportDirectoryName == Self.canonical.applicationSupportDirectoryName
        }

        var slug: String {
            var output = ""
            var lastWasDash = false
            for scalar in applicationSupportDirectoryName.lowercased().unicodeScalars {
                switch scalar.value {
                case 48 ... 57, 97 ... 122:
                    output.unicodeScalars.append(scalar)
                    lastWasDash = false
                default:
                    if !lastWasDash {
                        output.append("-")
                        lastWasDash = true
                    }
                }
            }
            let trimmed = output.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            return trimmed.isEmpty ? "repoprompt-ce" : trimmed
        }

        var underscoreSlug: String {
            slug.replacingOccurrences(of: "-", with: "_")
        }

        private static func containingAppInfoValue(forKey key: String) -> String? {
            let argumentURL = CommandLine.arguments.first.map { URL(fileURLWithPath: $0) }
            for candidate in [Bundle.main.bundleURL, Bundle.main.executableURL, argumentURL].compactMap(\.self) {
                if let value = containingAppInfoValue(forKey: key, startingAt: candidate) {
                    return value
                }
            }
            return nil
        }

        private static func containingAppInfoValue(forKey key: String, startingAt url: URL) -> String? {
            var current = url.resolvingSymlinksInPath()
            for _ in 0 ..< 10 {
                if current.pathExtension == "app" {
                    let infoURL = current.appendingPathComponent("Contents/Info.plist", isDirectory: false)
                    if let dictionary = NSDictionary(contentsOf: infoURL), let value = dictionary[key] as? String {
                        return value
                    }
                }
                let parent = current.deletingLastPathComponent()
                if parent.path == current.path { break }
                current = parent
            }
            return nil
        }
    }

    public static let currentProtocolVersion = 7

    public let product: Product
    public let buildFlavor: BuildFlavor
    public let protocolVersion: Int
    public let filesystemNamespace: FilesystemNamespace

    public init(
        product: Product,
        buildFlavor: BuildFlavor,
        protocolVersion: Int = Self.currentProtocolVersion,
        filesystemNamespace: FilesystemNamespace = .canonical
    ) {
        self.product = product
        self.buildFlavor = buildFlavor
        self.protocolVersion = protocolVersion
        self.filesystemNamespace = filesystemNamespace
    }

    public static func repoPromptCE(
        _ buildFlavor: BuildFlavor,
        filesystemNamespace: FilesystemNamespace = .canonical
    ) -> Self {
        Self(product: .repoPromptCE, buildFlavor: buildFlavor, filesystemNamespace: filesystemNamespace)
    }

    public static func currentRepoPromptCE(_ buildFlavor: BuildFlavor, bundle: Bundle = .main) -> Self {
        repoPromptCE(buildFlavor, filesystemNamespace: .fromInfoPlist(bundle: bundle))
    }

    public var socketDirectoryName: String {
        switch product {
        case .repoPromptCE:
            filesystemNamespace.isCanonical ? "repoprompt-ce-mcp" : "\(filesystemNamespace.slug)-mcp"
        }
    }

    public var bootstrapSocketName: String {
        switch (product, buildFlavor) {
        case (.repoPromptCE, .debug):
            filesystemNamespace.isCanonical ? "repoprompt-ce-D-\(protocolVersion).sock" : "\(filesystemNamespace.slug)-D-\(protocolVersion).sock"
        case (.repoPromptCE, .release):
            filesystemNamespace.isCanonical ? "repoprompt-ce-\(protocolVersion).sock" : "\(filesystemNamespace.slug)-\(protocolVersion).sock"
        }
    }

    public var externalEventsDirectoryName: String {
        switch (product, buildFlavor) {
        case (.repoPromptCE, .debug):
            filesystemNamespace.isCanonical ? "MCPEvents-CE-D-\(protocolVersion)" : "MCPEvents-\(filesystemNamespace.slug)-D-\(protocolVersion)"
        case (.repoPromptCE, .release):
            filesystemNamespace.isCanonical ? "MCPEvents-CE-\(protocolVersion)" : "MCPEvents-\(filesystemNamespace.slug)-\(protocolVersion)"
        }
    }

    public var applicationSupportDirectoryName: String {
        switch product {
        case .repoPromptCE:
            filesystemNamespace.applicationSupportDirectoryName
        }
    }

    public var killSignalsDirectoryName: String {
        switch (product, buildFlavor) {
        case (.repoPromptCE, .debug):
            filesystemNamespace.isCanonical ? "MCPKillSignals-CE-D-\(protocolVersion)" : "MCPKillSignals-\(filesystemNamespace.slug)-D-\(protocolVersion)"
        case (.repoPromptCE, .release):
            filesystemNamespace.isCanonical ? "MCPKillSignals-CE-\(protocolVersion)" : "MCPKillSignals-\(filesystemNamespace.slug)-\(protocolVersion)"
        }
    }

    public var stableWrapperConfigFileName: String {
        switch buildFlavor {
        case .debug: "discovery_debug.json"
        case .release: "discovery.json"
        }
    }

    public var networkConfigFileName: String {
        switch buildFlavor {
        case .debug: "mcp-config_debug.json"
        case .release: "mcp-config.json"
        }
    }

    public var routingStateFileName: String {
        switch buildFlavor {
        case .debug: "mcp-routing_debug.json"
        case .release: "mcp-routing.json"
        }
    }

    public var userSpaceCLIFileName: String {
        if !filesystemNamespace.isCanonical {
            return buildFlavor == .debug ? "\(filesystemNamespace.underscoreSlug)_cli_debug" : "\(filesystemNamespace.underscoreSlug)_cli"
        }
        switch buildFlavor {
        case .debug: return "repoprompt_ce_cli_debug"
        case .release: return "repoprompt_ce_cli"
        }
    }

    public var pathCLICommandName: String {
        if !filesystemNamespace.isCanonical {
            return buildFlavor == .debug ? "\(filesystemNamespace.slug)-cli-debug" : "\(filesystemNamespace.slug)-cli"
        }
        switch buildFlavor {
        case .debug: return "rpce-cli-debug"
        case .release: return "rpce-cli"
        }
    }

    public var claudeWrapperCommandName: String {
        if !filesystemNamespace.isCanonical {
            return buildFlavor == .debug ? "claude-\(filesystemNamespace.slug)-debug" : "claude-\(filesystemNamespace.slug)"
        }
        switch buildFlavor {
        case .debug: return "claude-rpce-debug"
        case .release: return "claude-rpce"
        }
    }

    public func socketDirectoryURL(userID: uid_t = getuid()) -> URL {
        URL(fileURLWithPath: "/tmp/\(socketDirectoryName)-\(userID)", isDirectory: true)
    }

    public func bootstrapSocketURL(userID: uid_t = getuid()) -> URL {
        socketDirectoryURL(userID: userID).appendingPathComponent(bootstrapSocketName, isDirectory: false)
    }

    public func applicationSupportRootURL(fileManager: FileManager = .default) -> URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(applicationSupportDirectoryName, isDirectory: true)
    }

    public func temporaryRootURL(fileManager: FileManager = .default) -> URL {
        fileManager.temporaryDirectory
            .appendingPathComponent(applicationSupportDirectoryName, isDirectory: true)
    }

    public func configDirectoryURL(fileManager: FileManager = .default) -> URL {
        applicationSupportRootURL(fileManager: fileManager)
            .appendingPathComponent("MCP", isDirectory: true)
    }

    public func stableWrapperConfigURL(fileManager: FileManager = .default) -> URL {
        configDirectoryURL(fileManager: fileManager)
            .appendingPathComponent(stableWrapperConfigFileName, isDirectory: false)
    }

    public func launchConfigDirectoryURL(fileManager: FileManager = .default) -> URL {
        configDirectoryURL(fileManager: fileManager)
            .appendingPathComponent("LaunchConfigs", isDirectory: true)
    }

    public func externalEventsDirectoryURL(fileManager: FileManager = .default) -> URL {
        applicationSupportRootURL(fileManager: fileManager)
            .appendingPathComponent(externalEventsDirectoryName, isDirectory: true)
    }

    public func killSignalsDirectoryURL(fileManager: FileManager = .default) -> URL {
        applicationSupportRootURL(fileManager: fileManager)
            .appendingPathComponent(killSignalsDirectoryName, isDirectory: true)
    }

    public func networkConfigURL(fileManager: FileManager = .default) -> URL {
        configDirectoryURL(fileManager: fileManager)
            .appendingPathComponent(networkConfigFileName, isDirectory: false)
    }

    public func routingStateURL(fileManager: FileManager = .default) -> URL {
        configDirectoryURL(fileManager: fileManager)
            .appendingPathComponent(routingStateFileName, isDirectory: false)
    }

    public func userSpaceCLIURL(fileManager: FileManager = .default) -> URL {
        applicationSupportRootURL(fileManager: fileManager)
            .appendingPathComponent(userSpaceCLIFileName, isDirectory: false)
    }
}
