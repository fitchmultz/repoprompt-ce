import Foundation

struct PiDiscoveredModels: Equatable {
    let options: [AgentModelOption]
    let currentModelRaw: String?

    var preferredModelRaw: String? {
        option(matching: currentModelRaw)?.rawValue
            ?? Self.normalizedRawModel(currentModelRaw)
            ?? options.first(where: \.isProviderDefault)?.rawValue
            ?? options.first(where: { !$0.isPlaceholderDefault })?.rawValue
            ?? options.first?.rawValue
    }

    func option(matching raw: String?) -> AgentModelOption? {
        guard let normalized = Self.normalizedRawModel(raw) else { return nil }
        if let exact = options.first(where: { Self.normalizedRawModel($0.rawValue) == normalized }) {
            return exact
        }
        guard let specifier = PiModelSpecifier(raw: raw) else { return nil }
        let baseNormalized = Self.normalizedRawModel(specifier.providerQualifiedModelRaw)
        return options.first {
            Self.normalizedRawModel($0.rawValue) == baseNormalized
        }
    }

    func contains(rawModel: String?) -> Bool {
        option(matching: rawModel) != nil
    }

    func supportedThinkingLevels(for rawModel: String?) -> [PiThinkingLevel] {
        option(matching: rawModel)?.supportedPiThinkingLevels ?? []
    }

    func supportsThinkingLevel(_ level: PiThinkingLevel, for rawModel: String?) -> Bool {
        supportedThinkingLevels(for: rawModel).contains(level)
    }

    static func normalizedRawModel(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed.lowercased()
    }
}

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

enum PiDynamicModelStore {
    private static let storageKey = "PiDynamicModelSnapshot"

    static func save(_ snapshot: PiDiscoveredModels, defaults: UserDefaults = .standard) {
        guard let record = snapshotRecord(from: snapshot) else {
            remove(defaults: defaults)
            return
        }
        guard let data = try? JSONEncoder().encode(record) else { return }
        defaults.set(data, forKey: storageKey)
    }

    static func load(defaults: UserDefaults = .standard) -> PiDiscoveredModels? {
        guard let data = defaults.data(forKey: storageKey),
              let record = try? JSONDecoder().decode(PiDynamicModelSnapshotRecord.self, from: data)
        else {
            return nil
        }
        return snapshot(from: record)
    }

    static func remove(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: storageKey)
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
        return trimmed
    }

    private static func normalizedOptionalString(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func providerID(from rawValue: String) -> String? {
        let parts = rawValue.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2, !parts[0].isEmpty else { return nil }
        return parts[0].lowercased()
    }
}

final class AgentPiModelRegistry {
    static let shared = AgentPiModelRegistry()

    private let lock = NSLock()
    private var liveSnapshot: PiDiscoveredModels?
    private var liveSignature: PiDynamicModelSnapshotRecord?
    private var persistedSnapshot: PiDiscoveredModels?
    private var standardStoreWarmTask: Task<PiDiscoveredModels?, Never>?
    private var didWarmStandardStore = false
    private var standardStoreWarmGeneration: UInt64 = 0

    private init() {}

    @discardableResult
    func updateDiscoveredModels(_ snapshot: PiDiscoveredModels) -> Bool {
        guard let record = PiDynamicModelStore.snapshotRecord(from: snapshot),
              let normalizedSnapshot = PiDynamicModelStore.snapshot(from: record)
        else {
            return false
        }

        lock.lock()
        let didChange = liveSignature != record
        if didChange {
            liveSnapshot = normalizedSnapshot
            liveSignature = record
        }
        persistedSnapshot = normalizedSnapshot
        lock.unlock()

        guard didChange else { return false }
        PiDynamicModelStore.save(normalizedSnapshot)
        return true
    }

    func currentSnapshot() -> PiDiscoveredModels? {
        lock.lock()
        defer { lock.unlock() }
        return liveSnapshot
    }

    func resolvedSnapshot() -> PiDiscoveredModels? {
        snapshotFromMemory()
    }

    func resolvedSnapshotAfterWarmingStandardStore() async -> PiDiscoveredModels? {
        if let snapshot = snapshotFromMemory() {
            return snapshot
        }
        await warmStandardStoreIfNeeded()
        return snapshotFromMemory()
    }

    func warmStandardStoreIfNeeded() async {
        let task: Task<PiDiscoveredModels?, Never>
        let generation: UInt64

        lock.lock()
        if didWarmStandardStore {
            lock.unlock()
            return
        }
        generation = standardStoreWarmGeneration
        if let existing = standardStoreWarmTask {
            task = existing
        } else {
            let newTask = Task.detached(priority: .utility) {
                PiDynamicModelStore.load()
            }
            standardStoreWarmTask = newTask
            task = newTask
        }
        lock.unlock()

        let loadedSnapshot = await task.value

        lock.lock()
        guard generation == standardStoreWarmGeneration else {
            lock.unlock()
            return
        }
        persistedSnapshot = loadedSnapshot
        didWarmStandardStore = true
        standardStoreWarmTask = nil
        lock.unlock()
    }

    static func discoveredModels(from remoteModels: [PiRPCClient.RemoteModel], currentModel: PiRPCClient.RemoteModel?) -> PiDiscoveredModels? {
        var options: [AgentModelOption] = [
            AgentModelOption(
                rawValue: AgentModel.defaultModel.rawValue,
                displayName: AgentModel.defaultModel.displayName,
                description: "Use pi's configured default model.",
                isDefault: true
            )
        ]
        let currentRaw = currentModel.flatMap(rawModel)
        var seen = Set(options.map { $0.rawValue.lowercased() })
        for model in remoteModels {
            guard let raw = rawModel(model) else { continue }
            let key = raw.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            let displayName = normalizedOptionalString(model.displayName) ?? raw
            options.append(AgentModelOption(
                rawValue: raw,
                displayName: displayName,
                description: providerQualifiedDescription(
                    raw: raw,
                    displayName: displayName,
                    description: model.description
                ),
                isDefault: currentRaw?.caseInsensitiveCompare(raw) == .orderedSame,
                supportedPiThinkingLevels: supportedThinkingLevels(for: model)
            ))
        }
        guard options.count > 1 else { return nil }
        return PiDiscoveredModels(options: options, currentModelRaw: currentRaw)
    }

    static func rawModel(_ model: PiRPCClient.RemoteModel) -> String? {
        let id = model.id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return nil }
        guard let provider = normalizedOptionalString(model.provider) else { return id }
        if id.hasPrefix("\(provider)/") { return id }
        return "\(provider)/\(id)"
    }

    static func supportedThinkingLevels(for model: PiRPCClient.RemoteModel) -> [PiThinkingLevel] {
        guard model.raw["reasoning"]?.boolValue == true else { return [] }
        var supported = Set(PiThinkingLevel.standardModelOrder)
        if let map = model.raw["thinkingLevelMap"]?.objectValue {
            for (rawLevel, value) in map {
                guard let level = PiThinkingLevel.parse(rawLevel) else { continue }
                if case .null = value {
                    supported.remove(level)
                } else {
                    supported.insert(level)
                }
            }
        }
        return PiThinkingLevel.displayOrder.filter { supported.contains($0) }
    }

    private static func providerQualifiedDescription(raw: String, displayName: String, description: String?) -> String? {
        let friendlyName = normalizedOptionalString(displayName).flatMap { name -> String? in
            name.caseInsensitiveCompare(raw) == .orderedSame ? nil : name
        }
        let detail = normalizedOptionalString(description)
        switch (friendlyName, detail) {
        case let (name?, detail?) where name.caseInsensitiveCompare(detail) != .orderedSame:
            return "\(name) — \(detail)"
        case let (name?, _):
            return name
        case let (_, detail?):
            return detail
        default:
            return nil
        }
    }

    private func snapshotFromMemory() -> PiDiscoveredModels? {
        lock.lock()
        defer { lock.unlock() }
        return liveSnapshot ?? persistedSnapshot
    }

    private static func normalizedOptionalString(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    #if DEBUG
        func test_reset() {
            lock.lock()
            liveSnapshot = nil
            liveSignature = nil
            persistedSnapshot = nil
            standardStoreWarmTask?.cancel()
            standardStoreWarmTask = nil
            didWarmStandardStore = false
            standardStoreWarmGeneration &+= 1
            lock.unlock()
            PiDynamicModelStore.remove()
        }

        func test_clearMemoryPreservingStore() {
            lock.lock()
            liveSnapshot = nil
            liveSignature = nil
            persistedSnapshot = nil
            standardStoreWarmTask?.cancel()
            standardStoreWarmTask = nil
            didWarmStandardStore = false
            standardStoreWarmGeneration &+= 1
            lock.unlock()
        }
    #endif
}
