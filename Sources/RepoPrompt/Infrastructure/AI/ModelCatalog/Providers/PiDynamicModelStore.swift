import CryptoKit
import Foundation

struct PiDynamicModelRecord: Codable, Hashable {
    let rawValue: String
    let displayName: String
    let description: String?
    let isPlaceholderDefault: Bool
    let isProviderDefault: Bool
    let supportedThinkingLevels: [PiThinkingLevel]

    init(
        rawValue: String,
        displayName: String,
        description: String?,
        isPlaceholderDefault: Bool,
        isProviderDefault: Bool,
        supportedThinkingLevels: [PiThinkingLevel] = []
    ) {
        self.rawValue = rawValue
        self.displayName = displayName
        self.description = description
        self.isPlaceholderDefault = isPlaceholderDefault
        self.isProviderDefault = isProviderDefault
        self.supportedThinkingLevels = supportedThinkingLevels
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rawValue = try container.decode(String.self, forKey: .rawValue)
        displayName = try container.decode(String.self, forKey: .displayName)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        isPlaceholderDefault = try container.decode(Bool.self, forKey: .isPlaceholderDefault)
        isProviderDefault = try container.decode(Bool.self, forKey: .isProviderDefault)
        supportedThinkingLevels = if container.contains(.supportedThinkingLevels) {
            try container.decodeIfPresent([PiThinkingLevel].self, forKey: .supportedThinkingLevels) ?? []
        } else {
            Self.legacySupportedThinkingLevels(rawValue: rawValue, displayName: displayName)
        }
    }

    private static func legacySupportedThinkingLevels(rawValue: String, displayName: String) -> [PiThinkingLevel] {
        let normalized = "\(rawValue) \(displayName)"
            .replacingOccurrences(of: "_", with: "-")
            .lowercased()
        if normalized.contains("gpt-5.6") || normalized.contains("gpt 5.6") || normalized.contains("gpt-5-6") {
            return PiThinkingLevel.displayOrder
        }
        if normalized.contains("kimi-coding/k3") || normalized.contains("kimi k3") {
            return [.max]
        }
        if normalized.contains("gpt-5.5-pro") || normalized.contains("gpt 5.5 pro") || normalized.contains("gpt-5-5-pro") {
            return [.medium, .high, .xhigh]
        }
        if normalized.contains("gpt-5.5") || normalized.contains("gpt 5.5") || normalized.contains("gpt-5-5") {
            return [.off, .low, .medium, .high, .xhigh]
        }
        if normalized.contains("fable-5") || normalized.contains("fable 5") {
            return PiThinkingLevel.displayOrder
        }
        return PiThinkingLevel.standardModelOrder
    }
}

struct PiDynamicModelSnapshotRecord: Codable, Hashable {
    let currentModelRaw: String?
    let options: [PiDynamicModelRecord]
}

struct PiDynamicModelSnapshotCollectionRecord: Codable, Hashable {
    var snapshotsByWorkspacePath: [String: PiDynamicModelSnapshotRecord]
}

struct PiWorkspaceDynamicModelSnapshotRecord: Codable, Hashable {
    var workspacePath: String
    var savedAt: Date
    var snapshot: PiDynamicModelSnapshotRecord
}

enum PiModelWorkspaceScope: Hashable {
    case global
    case workspace(String)

    init(workspacePath: String?) {
        guard let canonicalPath = Self.canonicalWorkspacePath(workspacePath) else {
            self = .global
            return
        }
        self = .workspace(canonicalPath)
    }

    var workspacePath: String? {
        switch self {
        case .global:
            nil
        case let .workspace(path):
            path
        }
    }

    static func canonicalWorkspacePath(_ workspacePath: String?) -> String? {
        guard let trimmed = workspacePath?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        let expanded = (trimmed as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded).resolvingSymlinksInPath().standardizedFileURL.path
    }
}

enum PiModelCatalogState: Equatable {
    case loading
    case loaded(PiDiscoveredModels)
    case unavailable

    var models: PiDiscoveredModels? {
        if case let .loaded(models) = self { return models }
        return nil
    }
}

enum PiDynamicModelStore {
    private static let legacyStorageKey = "PiDynamicModelSnapshot"
    private static let legacyWorkspaceStorageKey = "PiDynamicModelSnapshotsByWorkspace"
    private static let legacyWorkspaceIndexKey = "PiDynamicModelSnapshotWorkspaceIndex"
    private static let legacyWorkspaceRecordKeyPrefix = "PiDynamicModelSnapshotWorkspace."
    private static let legacyWorkspaceFallbackRecordKeyPrefix = "PiDynamicModelSnapshotWorkspaceLegacy."
    private static var appSupportDirectoryName: String {
        MCPFilesystemConstants.identity.applicationSupportDirectoryName
    }

    private static let cacheDirectoryName = "PiModelSnapshots"
    private static let workspacesDirectoryName = "Workspaces"
    private static let globalFileName = "global.json"
    private static let maxWorkspaceSnapshots = 64
    private static let legacyMigrationLock = NSLock()
    private static var didMigrateStandardDefaults = false
    #if DEBUG
        private static var beforeWorkspaceRecordSaveHook: (() -> Void)?
        private static var storeDirectoryOverride: URL?
    #endif

    static func save(
        _ snapshot: PiDiscoveredModels,
        workspacePath: String? = nil,
        defaults: UserDefaults = .standard
    ) {
        let scope = PiModelWorkspaceScope(workspacePath: workspacePath)
        guard let record = snapshotRecord(from: snapshot) else {
            remove(scope: scope, defaults: defaults)
            return
        }
        migrateLegacyDefaultsIfNeeded(defaults: defaults)
        switch scope {
        case .global:
            writeRecord(record, to: globalRecordURL())
        case let .workspace(path):
            writeWorkspaceRecord(record, workspacePath: path)
            pruneWorkspaceFiles(keeping: workspaceRecordURL(for: path))
        }
    }

    static func load(workspacePath: String? = nil, defaults: UserDefaults = .standard) -> PiDiscoveredModels? {
        migrateLegacyDefaultsIfNeeded(defaults: defaults)
        switch PiModelWorkspaceScope(workspacePath: workspacePath) {
        case .global:
            guard let record: PiDynamicModelSnapshotRecord = readRecord(from: globalRecordURL()) else { return nil }
            return snapshot(from: record)
        case let .workspace(path):
            guard let record = readWorkspaceRecord(workspacePath: path) else { return nil }
            return snapshot(from: record)
        }
    }

    static func remove(defaults: UserDefaults = .standard) {
        removeFile(globalRecordURL())
        removeFile(workspaceRecordsDirectory())
        removeLegacyDefaults(defaults: defaults)
    }

    static func remove(workspacePath: String?, defaults: UserDefaults = .standard) {
        migrateLegacyDefaultsIfNeeded(defaults: defaults)
        remove(scope: PiModelWorkspaceScope(workspacePath: workspacePath), defaults: defaults)
    }

    private static func remove(scope: PiModelWorkspaceScope, defaults: UserDefaults) {
        switch scope {
        case .global:
            removeFile(globalRecordURL())
            defaults.removeObject(forKey: legacyStorageKey)
        case let .workspace(path):
            removeFile(workspaceRecordURL(for: path))
        }
    }

    static func snapshotRecord(from snapshot: PiDiscoveredModels) -> PiDynamicModelSnapshotRecord? {
        let options = canonicalModelRecords(from: snapshot.options)
        guard !options.isEmpty else { return nil }
        return PiDynamicModelSnapshotRecord(
            currentModelRaw: normalizedCurrentModelRaw(snapshot.currentModelRaw, options: options),
            options: options
        )
    }

    static func snapshot(from record: PiDynamicModelSnapshotRecord) -> PiDiscoveredModels? {
        let options = record.options.compactMap(modelOption(from:))
        guard !options.isEmpty else { return nil }
        let currentModelRaw = normalizedCurrentModelRaw(record.currentModelRaw, options: record.options)
        return PiDiscoveredModels(options: options, currentModelRaw: currentModelRaw)
    }

    private static func canonicalModelRecords(from options: [AgentModelOption]) -> [PiDynamicModelRecord] {
        var recordsByRaw: [String: PiDynamicModelRecord] = [:]
        for option in options {
            guard let record = modelRecord(from: option) else { continue }
            let key = record.rawValue.lowercased()
            if let existing = recordsByRaw[key] {
                recordsByRaw[key] = mergedCanonicalModelRecord(existing, record)
            } else {
                recordsByRaw[key] = record
            }
        }
        return recordsByRaw.values.sorted(by: canonicalModelRecordSort)
    }

    private static func modelRecord(from option: AgentModelOption) -> PiDynamicModelRecord? {
        let rawValue = option.rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawValue.isEmpty else { return nil }
        let displayName = option.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return PiDynamicModelRecord(
            rawValue: rawValue,
            displayName: displayName.isEmpty ? rawValue : displayName,
            description: normalizedOptionalString(option.description),
            isPlaceholderDefault: option.isPlaceholderDefault,
            isProviderDefault: option.isProviderDefault,
            supportedThinkingLevels: option.supportedPiThinkingLevels
        )
    }

    private static func modelOption(from record: PiDynamicModelRecord) -> AgentModelOption? {
        let rawValue = record.rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawValue.isEmpty else { return nil }
        let displayName = record.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return AgentModelOption(
            rawValue: rawValue,
            displayName: displayName.isEmpty ? rawValue : displayName,
            description: normalizedOptionalString(record.description),
            isPlaceholderDefault: record.isPlaceholderDefault,
            isProviderDefault: record.isProviderDefault,
            supportedPiThinkingLevels: record.supportedThinkingLevels
        )
    }

    private static func canonicalModelRecordSort(_ lhs: PiDynamicModelRecord, _ rhs: PiDynamicModelRecord) -> Bool {
        if lhs.isPlaceholderDefault != rhs.isPlaceholderDefault {
            return lhs.isPlaceholderDefault && !rhs.isPlaceholderDefault
        }
        let lhsProvider = providerID(from: lhs.rawValue) ?? ""
        let rhsProvider = providerID(from: rhs.rawValue) ?? ""
        if lhsProvider != rhsProvider {
            return lhsProvider.localizedCaseInsensitiveCompare(rhsProvider) == .orderedAscending
        }
        let displayNameOrder = lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
        if displayNameOrder != .orderedSame {
            return displayNameOrder == .orderedAscending
        }
        return lhs.rawValue.localizedCaseInsensitiveCompare(rhs.rawValue) == .orderedAscending
    }

    private static func mergedCanonicalModelRecord(
        _ existing: PiDynamicModelRecord,
        _ candidate: PiDynamicModelRecord
    ) -> PiDynamicModelRecord {
        let preferred = preferredMetadataRecord(existing, candidate)
        let fallback = preferred == existing ? candidate : existing
        return PiDynamicModelRecord(
            rawValue: preferredRawValue(existing.rawValue, candidate.rawValue),
            displayName: preferred.displayName,
            description: preferred.description ?? fallback.description,
            isPlaceholderDefault: existing.isPlaceholderDefault || candidate.isPlaceholderDefault,
            isProviderDefault: existing.isProviderDefault || candidate.isProviderDefault,
            supportedThinkingLevels: preferredThinkingLevels(existing.supportedThinkingLevels, candidate.supportedThinkingLevels)
        )
    }

    private static func preferredMetadataRecord(_ lhs: PiDynamicModelRecord, _ rhs: PiDynamicModelRecord) -> PiDynamicModelRecord {
        if lhs.isProviderDefault != rhs.isProviderDefault {
            return lhs.isProviderDefault ? lhs : rhs
        }
        if lhs.isPlaceholderDefault != rhs.isPlaceholderDefault {
            return lhs.isPlaceholderDefault ? lhs : rhs
        }
        let lhsDescription = lhs.description ?? ""
        let rhsDescription = rhs.description ?? ""
        if lhsDescription.isEmpty != rhsDescription.isEmpty {
            return lhsDescription.isEmpty ? rhs : lhs
        }
        let displayNameOrder = lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
        if displayNameOrder != .orderedSame {
            return displayNameOrder == .orderedAscending ? lhs : rhs
        }
        return preferredRawValue(lhs.rawValue, rhs.rawValue) == lhs.rawValue ? lhs : rhs
    }

    private static func preferredRawValue(_ lhs: String, _ rhs: String) -> String {
        let lhsTrimmed = lhs.trimmingCharacters(in: .whitespacesAndNewlines)
        let rhsTrimmed = rhs.trimmingCharacters(in: .whitespacesAndNewlines)
        let caseInsensitiveOrder = lhsTrimmed.localizedCaseInsensitiveCompare(rhsTrimmed)
        if caseInsensitiveOrder != .orderedSame {
            return caseInsensitiveOrder == .orderedAscending ? lhsTrimmed : rhsTrimmed
        }
        return lhsTrimmed <= rhsTrimmed ? lhsTrimmed : rhsTrimmed
    }

    private static func preferredThinkingLevels(_ lhs: [PiThinkingLevel], _ rhs: [PiThinkingLevel]) -> [PiThinkingLevel] {
        let merged = Set(lhs).union(rhs)
        return PiThinkingLevel.displayOrder.filter { merged.contains($0) }
    }

    private static func normalizedCurrentModelRaw(_ raw: String?, options: [PiDynamicModelRecord]) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        if let matched = options.first(where: { $0.rawValue.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return matched.rawValue
        }
        let knownModelIDs = Set(options.map(\.rawValue))
        guard let specifier = PiModelSpecifier(raw: trimmed, knownModelIDs: knownModelIDs) else { return nil }
        return options.first {
            $0.rawValue.caseInsensitiveCompare(specifier.providerQualifiedModelRaw) == .orderedSame
        }?.rawValue
    }

    private static func normalizedOptionalString(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func readWorkspaceRecord(workspacePath: String) -> PiDynamicModelSnapshotRecord? {
        guard let wrapper = readRecord(from: workspaceRecordURL(for: workspacePath), as: PiWorkspaceDynamicModelSnapshotRecord.self),
              AgentPiModelRegistry.canonicalWorkspacePath(wrapper.workspacePath) == AgentPiModelRegistry.canonicalWorkspacePath(workspacePath)
        else {
            return nil
        }
        return wrapper.snapshot
    }

    @discardableResult
    private static func writeWorkspaceRecord(_ record: PiDynamicModelSnapshotRecord, workspacePath: String) -> Bool {
        let wrapper = PiWorkspaceDynamicModelSnapshotRecord(
            workspacePath: workspacePath,
            savedAt: Date(),
            snapshot: record
        )
        #if DEBUG
            beforeWorkspaceRecordSaveHook?()
        #endif
        return writeRecord(wrapper, to: workspaceRecordURL(for: workspacePath))
    }

    private static func migrateLegacyDefaultsIfNeeded(defaults: UserDefaults) {
        if defaults === UserDefaults.standard {
            legacyMigrationLock.lock()
            let alreadyMigrated = didMigrateStandardDefaults
            legacyMigrationLock.unlock()
            guard !alreadyMigrated else { return }
        }

        let migrated = migrateLegacyDefaults(defaults: defaults)
        guard defaults === UserDefaults.standard, migrated else { return }
        legacyMigrationLock.lock()
        didMigrateStandardDefaults = true
        legacyMigrationLock.unlock()
    }

    @discardableResult
    private static func migrateLegacyDefaults(defaults: UserDefaults) -> Bool {
        var didFail = false
        if let data = defaults.data(forKey: legacyStorageKey) {
            if let record = try? JSONDecoder().decode(PiDynamicModelSnapshotRecord.self, from: data) {
                if readRecord(from: globalRecordURL(), as: PiDynamicModelSnapshotRecord.self) == nil {
                    didFail = !writeRecord(record, to: globalRecordURL()) || didFail
                }
            } else {
                didFail = true
            }
        }
        if let data = defaults.data(forKey: legacyWorkspaceStorageKey) {
            if let collection = try? JSONDecoder().decode(PiDynamicModelSnapshotCollectionRecord.self, from: data) {
                for (workspacePath, record) in collection.snapshotsByWorkspacePath {
                    guard let canonicalWorkspacePath = AgentPiModelRegistry.canonicalWorkspacePath(workspacePath) else {
                        didFail = true
                        continue
                    }
                    guard readWorkspaceRecord(workspacePath: canonicalWorkspacePath) == nil else { continue }
                    didFail = !writeWorkspaceRecord(record, workspacePath: canonicalWorkspacePath) || didFail
                }
            } else {
                didFail = true
            }
        }
        for key in defaults.dictionaryRepresentation().keys {
            didFail = !migrateLegacyPerWorkspaceKey(key, defaults: defaults) || didFail
        }
        guard !didFail else { return false }
        removeLegacyDefaults(defaults: defaults)
        return true
    }

    @discardableResult
    private static func migrateLegacyPerWorkspaceKey(_ key: String, defaults: UserDefaults) -> Bool {
        guard key.hasPrefix(legacyWorkspaceRecordKeyPrefix) || key.hasPrefix(legacyWorkspaceFallbackRecordKeyPrefix),
              let data = defaults.data(forKey: key)
        else {
            return true
        }
        guard let wrapper = try? JSONDecoder().decode(PiWorkspaceDynamicModelSnapshotRecord.self, from: data) else {
            return false
        }
        guard let canonicalWorkspacePath = AgentPiModelRegistry.canonicalWorkspacePath(wrapper.workspacePath) else { return false }
        guard readWorkspaceRecord(workspacePath: canonicalWorkspacePath) == nil else { return true }
        return writeWorkspaceRecord(wrapper.snapshot, workspacePath: canonicalWorkspacePath)
    }

    private static func removeLegacyDefaults(defaults: UserDefaults) {
        defaults.removeObject(forKey: legacyStorageKey)
        defaults.removeObject(forKey: legacyWorkspaceStorageKey)
        defaults.removeObject(forKey: legacyWorkspaceIndexKey)
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(legacyWorkspaceRecordKeyPrefix) || key.hasPrefix(legacyWorkspaceFallbackRecordKeyPrefix) {
            defaults.removeObject(forKey: key)
        }
    }

    private static func pruneWorkspaceFiles(keeping keptURL: URL?) {
        let directory = workspaceRecordsDirectory()
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ), files.count > maxWorkspaceSnapshots else { return }
        let keptPath = keptURL?.standardizedFileURL.path
        let sorted = files.sorted { lhs, rhs in
            let leftDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let rightDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return leftDate > rightDate
        }
        var retained: Set<String> = []
        if let keptPath {
            retained.insert(keptPath)
        }
        for file in sorted where retained.count < maxWorkspaceSnapshots {
            retained.insert(file.standardizedFileURL.path)
        }
        for file in files where !retained.contains(file.standardizedFileURL.path) {
            removeFile(file)
        }
    }

    private static func readRecord<T: Decodable>(from url: URL, as type: T.Type = T.self) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    @discardableResult
    private static func writeRecord(_ record: some Encodable, to url: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(record)
            try data.write(to: url, options: [.atomic])
            return true
        } catch {
            return false
        }
    }

    private static func removeFile(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private static func globalRecordURL() -> URL {
        storeDirectory().appendingPathComponent(globalFileName, isDirectory: false)
    }

    private static func workspaceRecordURL(for path: String) -> URL {
        workspaceRecordsDirectory()
            .appendingPathComponent(workspaceRecordKeyDigest(for: path), isDirectory: false)
            .appendingPathExtension("json")
    }

    private static func workspaceRecordsDirectory() -> URL {
        storeDirectory().appendingPathComponent(workspacesDirectoryName, isDirectory: true)
    }

    private static func storeDirectory() -> URL {
        #if DEBUG
            if let storeDirectoryOverride { return storeDirectoryOverride }
        #endif
        return MCPFilesystemConstants.identity.applicationSupportRootURL()
            .appendingPathComponent(cacheDirectoryName, isDirectory: true)
    }

    private static func workspaceRecordKeyDigest(for path: String) -> String {
        SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    #if DEBUG
        static func test_setBeforeWorkspaceRecordSaveHook(_ hook: (() -> Void)?) {
            beforeWorkspaceRecordSaveHook = hook
        }

        static func test_setStoreDirectoryOverride(_ directory: URL?) {
            storeDirectoryOverride = directory
            legacyMigrationLock.lock()
            didMigrateStandardDefaults = false
            legacyMigrationLock.unlock()
        }
    #endif

    private static func providerID(from rawValue: String) -> String? {
        let parts = rawValue.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2, !parts[0].isEmpty else { return nil }
        return parts[0].lowercased()
    }
}
