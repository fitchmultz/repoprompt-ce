import Foundation

struct PiDiscoveredModels: Equatable {
    let options: [AgentModelOption]
    let currentModelRaw: String?

    var preferredModelRaw: String? {
        option(matching: currentModelRaw)?.rawValue
            ?? options.first(where: \.isProviderDefault)?.rawValue
            ?? options.first(where: { !$0.isPlaceholderDefault })?.rawValue
            ?? options.first?.rawValue
    }

    func option(matching raw: String?) -> AgentModelOption? {
        guard let normalized = Self.normalizedRawModel(raw) else { return nil }
        if let exact = options.first(where: { Self.normalizedRawModel($0.rawValue) == normalized }) {
            return exact
        }
        guard let specifier = PiModelSpecifier(raw: raw, knownModelIDs: knownModelIDs) else { return nil }
        let baseNormalized = Self.normalizedRawModel(specifier.providerQualifiedModelRaw)
        return options.first {
            Self.normalizedRawModel($0.rawValue) == baseNormalized
        }
    }

    var knownModelIDs: Set<String> {
        Set(options.compactMap { option in
            guard !option.isPlaceholderDefault else { return nil }
            return option.rawValue
        })
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

    func retainingPiReportedModelOptions() -> PiDiscoveredModels? {
        let piModelOptions = options.filter { option in
            !option.isPlaceholderDefault && PiIntegrationConfiguration.isExposableModelRaw(option.rawValue)
        }
        guard !piModelOptions.isEmpty else { return nil }
        let current = Self.normalizedRawModel(currentModelRaw).flatMap { normalized in
            piModelOptions.first { $0.rawValue.lowercased() == normalized }?.rawValue
        }
        return PiDiscoveredModels(options: piModelOptions, currentModelRaw: current ?? piModelOptions.first(where: \.isProviderDefault)?.rawValue)
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

struct PiDynamicModelSnapshotCollectionRecord: Codable, Hashable {
    var snapshotsByWorkspacePath: [String: PiDynamicModelSnapshotRecord]
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
        return URL(fileURLWithPath: expanded).standardizedFileURL.path
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
    private static let storageKey = "PiDynamicModelSnapshot"
    private static let workspaceStorageKey = "PiDynamicModelSnapshotsByWorkspace"
    private static let lock = NSLock()

    static func save(
        _ snapshot: PiDiscoveredModels,
        workspacePath: String? = nil,
        defaults: UserDefaults = .standard
    ) {
        let scope = PiModelWorkspaceScope(workspacePath: workspacePath)
        lock.lock()
        defer { lock.unlock() }
        guard let record = snapshotRecord(from: snapshot) else {
            remove(scope: scope, defaults: defaults)
            return
        }
        switch scope {
        case .global:
            guard let data = try? JSONEncoder().encode(record) else { return }
            defaults.set(data, forKey: storageKey)
        case let .workspace(path):
            var collection = loadCollection(defaults: defaults)
            collection.snapshotsByWorkspacePath[path] = record
            saveCollection(collection, defaults: defaults)
        }
    }

    static func load(workspacePath: String? = nil, defaults: UserDefaults = .standard) -> PiDiscoveredModels? {
        lock.lock()
        defer { lock.unlock() }
        switch PiModelWorkspaceScope(workspacePath: workspacePath) {
        case .global:
            guard let data = defaults.data(forKey: storageKey),
                  let record = try? JSONDecoder().decode(PiDynamicModelSnapshotRecord.self, from: data)
            else {
                return nil
            }
            return snapshot(from: record)
        case let .workspace(path):
            guard let record = loadCollection(defaults: defaults).snapshotsByWorkspacePath[path] else { return nil }
            return snapshot(from: record)
        }
    }

    static func remove(defaults: UserDefaults = .standard) {
        lock.lock()
        defer { lock.unlock() }
        defaults.removeObject(forKey: storageKey)
        defaults.removeObject(forKey: workspaceStorageKey)
    }

    static func remove(workspacePath: String?, defaults: UserDefaults = .standard) {
        lock.lock()
        defer { lock.unlock() }
        remove(scope: PiModelWorkspaceScope(workspacePath: workspacePath), defaults: defaults)
    }

    private static func remove(scope: PiModelWorkspaceScope, defaults: UserDefaults) {
        switch scope {
        case .global:
            defaults.removeObject(forKey: storageKey)
        case let .workspace(path):
            var collection = loadCollection(defaults: defaults)
            collection.snapshotsByWorkspacePath.removeValue(forKey: path)
            saveCollection(collection, defaults: defaults)
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

    private static func loadCollection(defaults: UserDefaults) -> PiDynamicModelSnapshotCollectionRecord {
        guard let data = defaults.data(forKey: workspaceStorageKey),
              let collection = try? JSONDecoder().decode(PiDynamicModelSnapshotCollectionRecord.self, from: data)
        else {
            return PiDynamicModelSnapshotCollectionRecord(snapshotsByWorkspacePath: [:])
        }
        return collection
    }

    private static func saveCollection(_ collection: PiDynamicModelSnapshotCollectionRecord, defaults: UserDefaults) {
        guard !collection.snapshotsByWorkspacePath.isEmpty else {
            defaults.removeObject(forKey: workspaceStorageKey)
            return
        }
        guard let data = try? JSONEncoder().encode(collection) else { return }
        defaults.set(data, forKey: workspaceStorageKey)
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
    private let persistenceLock = NSLock()
    private var liveSnapshots: [PiModelWorkspaceScope: PiDiscoveredModels] = [:]
    private var liveSignatures: [PiModelWorkspaceScope: PiDynamicModelSnapshotRecord] = [:]
    private var persistedSnapshots: [PiModelWorkspaceScope: PiDiscoveredModels] = [:]
    private var refreshInFlightScopes: Set<PiModelWorkspaceScope> = []
    private var settledScopes: Set<PiModelWorkspaceScope> = []
    private var standardStoreWarmTasks: [PiModelWorkspaceScope: Task<PiDiscoveredModels?, Never>] = [:]
    private var warmedStandardStoreScopes: Set<PiModelWorkspaceScope> = []
    private var standardStoreWarmGeneration: UInt64 = 0
    private var persistenceGeneration: UInt64 = 0
    #if DEBUG
        private var beforePersistDiscoveredModelsHook: ((String?) -> Void)?
        private var beforeApplyPersistedWarmHook: ((String?) -> Void)?
        private var beforeRemovePersistedModelsHook: ((String?) -> Void)?
    #endif

    private init() {}

    static func canonicalWorkspacePath(_ workspacePath: String?) -> String? {
        PiModelWorkspaceScope.canonicalWorkspacePath(workspacePath)
    }

    @discardableResult
    func updateDiscoveredModels(_ snapshot: PiDiscoveredModels, workspacePath: String? = nil) -> Bool {
        let scope = PiModelWorkspaceScope(workspacePath: workspacePath)
        let piModelSnapshot = snapshot.retainingPiReportedModelOptions()
        guard let piModelSnapshot,
              let record = PiDynamicModelStore.snapshotRecord(from: piModelSnapshot),
              let normalizedSnapshot = PiDynamicModelStore.snapshot(from: record)
        else {
            return clearDiscoveredModels(workspacePath: scope.workspacePath)
        }

        lock.lock()
        let didChange = liveSignatures[scope] != record
        if didChange {
            liveSnapshots[scope] = normalizedSnapshot
            liveSignatures[scope] = record
        }
        persistedSnapshots[scope] = normalizedSnapshot
        let generation = persistenceGeneration
        #if DEBUG
            let beforePersistHook = beforePersistDiscoveredModelsHook
        #endif
        lock.unlock()

        if didChange {
            #if DEBUG
                beforePersistHook?(scope.workspacePath)
            #endif
            persistSnapshotIfCurrent(normalizedSnapshot, record: record, scope: scope, generation: generation)
        }

        return didChange
    }

    @discardableResult
    func clearDiscoveredModels(workspacePath: String? = nil) -> Bool {
        let scope = PiModelWorkspaceScope(workspacePath: workspacePath)
        persistenceLock.lock()
        lock.lock()
        let removedLiveSnapshot = liveSnapshots.removeValue(forKey: scope) != nil
        let removedPersistedSnapshot = persistedSnapshots.removeValue(forKey: scope) != nil
        let removedSignature = liveSignatures.removeValue(forKey: scope) != nil
        let hadSnapshot = removedLiveSnapshot || removedPersistedSnapshot || removedSignature
        refreshInFlightScopes.remove(scope)
        settledScopes.remove(scope)
        warmedStandardStoreScopes.remove(scope)
        standardStoreWarmTasks.removeValue(forKey: scope)?.cancel()
        standardStoreWarmGeneration &+= 1
        persistenceGeneration &+= 1
        #if DEBUG
            let beforeRemoveHook = beforeRemovePersistedModelsHook
        #endif
        lock.unlock()
        #if DEBUG
            beforeRemoveHook?(scope.workspacePath)
        #endif
        PiDynamicModelStore.remove(workspacePath: scope.workspacePath)
        persistenceLock.unlock()
        return hadSnapshot
    }

    func currentSnapshot(workspacePath: String? = nil) -> PiDiscoveredModels? {
        let scope = PiModelWorkspaceScope(workspacePath: workspacePath)
        lock.lock()
        defer { lock.unlock() }
        return liveSnapshots[scope]
    }

    func resolvedSnapshot(workspacePath: String? = nil) -> PiDiscoveredModels? {
        snapshotAfterSynchronousWarmIfNeeded(scope: PiModelWorkspaceScope(workspacePath: workspacePath))
    }

    func cachedSnapshot(workspacePath: String? = nil) -> PiDiscoveredModels? {
        snapshotFromMemory(scope: PiModelWorkspaceScope(workspacePath: workspacePath))
    }

    func catalogState(workspacePath: String? = nil) -> PiModelCatalogState {
        let scope = PiModelWorkspaceScope(workspacePath: workspacePath)
        if let snapshot = snapshotAfterSynchronousWarmIfNeeded(scope: scope) {
            return .loaded(snapshot)
        }
        lock.lock()
        let isLoading = refreshInFlightScopes.contains(scope) || !settledScopes.contains(scope)
        lock.unlock()
        return isLoading ? .loading : .unavailable
    }

    func setRefreshInFlight(_ inFlight: Bool, workspacePath: String? = nil) {
        let scope = PiModelWorkspaceScope(workspacePath: workspacePath)
        lock.lock()
        if inFlight {
            refreshInFlightScopes.insert(scope)
        } else {
            refreshInFlightScopes.remove(scope)
        }
        lock.unlock()
    }

    func markRefreshSettled(workspacePath: String? = nil) {
        let scope = PiModelWorkspaceScope(workspacePath: workspacePath)
        lock.lock()
        settledScopes.insert(scope)
        lock.unlock()
    }

    func resolvedSnapshotAfterWarmingStandardStore(workspacePath: String? = nil) async -> PiDiscoveredModels? {
        let scope = PiModelWorkspaceScope(workspacePath: workspacePath)
        if let snapshot = snapshotFromMemory(scope: scope) {
            return snapshot
        }
        await warmStandardStoreIfNeeded(workspacePath: scope.workspacePath)
        return snapshotFromMemory(scope: scope)
    }

    func warmStandardStoreIfNeeded(workspacePath: String? = nil) async {
        let scope = PiModelWorkspaceScope(workspacePath: workspacePath)
        guard let plan = standardStoreWarmPlan(scope: scope) else { return }

        let loadedSnapshot = await plan.task.value
        #if DEBUG
            beforeApplyPersistedWarmHookSnapshot()?(scope.workspacePath)
        #endif
        applyStandardStoreWarmResult(loadedSnapshot, scope: scope, generation: plan.generation)
    }

    private struct StandardStoreWarmPlan {
        let task: Task<PiDiscoveredModels?, Never>
        let generation: UInt64
    }

    private func standardStoreWarmPlan(scope: PiModelWorkspaceScope) -> StandardStoreWarmPlan? {
        lock.lock()
        defer { lock.unlock() }
        guard !warmedStandardStoreScopes.contains(scope) else { return nil }

        let generation = standardStoreWarmGeneration
        if let existing = standardStoreWarmTasks[scope] {
            return StandardStoreWarmPlan(task: existing, generation: generation)
        }

        let workspacePath = scope.workspacePath
        let task = Task.detached(priority: .utility) { [weak self] in
            self?.loadPersistedSnapshot(workspacePath: workspacePath)
        }
        standardStoreWarmTasks[scope] = task
        return StandardStoreWarmPlan(task: task, generation: generation)
    }

    #if DEBUG
        private func beforeApplyPersistedWarmHookSnapshot() -> ((String?) -> Void)? {
            lock.lock()
            defer { lock.unlock() }
            return beforeApplyPersistedWarmHook
        }
    #endif

    private func applyStandardStoreWarmResult(_ loadedSnapshot: PiDiscoveredModels?, scope: PiModelWorkspaceScope, generation: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        guard generation == standardStoreWarmGeneration else { return }

        if let loadedSnapshot {
            persistedSnapshots[scope] = loadedSnapshot
        } else {
            persistedSnapshots.removeValue(forKey: scope)
        }
        warmedStandardStoreScopes.insert(scope)
        standardStoreWarmTasks.removeValue(forKey: scope)
    }

    static func discoveredModels(from remoteModels: [PiRPCClient.RemoteModel], currentModel: PiRPCClient.RemoteModel?) -> PiDiscoveredModels? {
        var options: [AgentModelOption] = []
        let currentRaw = currentModel.flatMap(rawModel).flatMap { raw in
            PiIntegrationConfiguration.isExposableModelRaw(raw) ? raw : nil
        }
        var seen = Set<String>()
        var malformedRemoteModels = 0
        var duplicateRawModels: [String] = []
        for model in remoteModels {
            guard let raw = rawModel(model) else {
                malformedRemoteModels += 1
                continue
            }
            let key = raw.lowercased()
            guard !seen.contains(key) else {
                duplicateRawModels.append(raw)
                continue
            }
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
        _ = malformedRemoteModels
        _ = duplicateRawModels
        guard !options.isEmpty else { return nil }
        return PiDiscoveredModels(options: options, currentModelRaw: currentRaw)
    }

    static func rawModel(_ model: PiRPCClient.RemoteModel) -> String? {
        PiModelSelectionContract.selectableRawValue(provider: model.provider, id: model.id)
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

    private func snapshotFromMemory(scope: PiModelWorkspaceScope) -> PiDiscoveredModels? {
        lock.lock()
        defer { lock.unlock() }
        return (liveSnapshots[scope] ?? persistedSnapshots[scope])?.retainingPiReportedModelOptions()
    }

    private func loadPersistedSnapshot(workspacePath: String?) -> PiDiscoveredModels? {
        persistenceLock.lock()
        defer { persistenceLock.unlock() }
        return PiDynamicModelStore.load(workspacePath: workspacePath)
    }

    private func persistSnapshotIfCurrent(
        _ snapshot: PiDiscoveredModels,
        record: PiDynamicModelSnapshotRecord,
        scope: PiModelWorkspaceScope,
        generation: UInt64
    ) {
        persistenceLock.lock()
        defer { persistenceLock.unlock() }

        lock.lock()
        let currentRecordBeforeSave = liveSignatures[scope]
        let generationBeforeSave = persistenceGeneration
        lock.unlock()

        guard generationBeforeSave == generation,
              currentRecordBeforeSave == record
        else {
            reconcilePersistedSnapshot(scope: scope, savedRecord: record, savedGeneration: generation)
            return
        }

        PiDynamicModelStore.save(snapshot, workspacePath: scope.workspacePath)
        reconcilePersistedSnapshot(scope: scope, savedRecord: record, savedGeneration: generation)
    }

    private func reconcilePersistedSnapshot(
        scope: PiModelWorkspaceScope,
        savedRecord: PiDynamicModelSnapshotRecord,
        savedGeneration: UInt64
    ) {
        lock.lock()
        let currentRecord = liveSignatures[scope]
        let currentSnapshot = liveSnapshots[scope]
        let currentGeneration = persistenceGeneration
        lock.unlock()

        guard currentGeneration == savedGeneration,
              currentRecord == savedRecord
        else {
            if currentRecord != nil,
               let currentSnapshot
            {
                PiDynamicModelStore.save(currentSnapshot, workspacePath: scope.workspacePath)
            } else {
                PiDynamicModelStore.remove(workspacePath: scope.workspacePath)
            }
            return
        }
    }

    private func snapshotAfterSynchronousWarmIfNeeded(scope: PiModelWorkspaceScope) -> PiDiscoveredModels? {
        lock.lock()
        if let snapshot = (liveSnapshots[scope] ?? persistedSnapshots[scope])?.retainingPiReportedModelOptions() {
            lock.unlock()
            return snapshot
        }
        if warmedStandardStoreScopes.contains(scope) {
            lock.unlock()
            return nil
        }
        let generation = standardStoreWarmGeneration
        let workspacePath = scope.workspacePath
        lock.unlock()

        let loadedSnapshot = loadPersistedSnapshot(workspacePath: workspacePath)
        #if DEBUG
            let beforeApplyWarmHook: ((String?) -> Void)? = {
                lock.lock()
                defer { lock.unlock() }
                return beforeApplyPersistedWarmHook
            }()
            beforeApplyWarmHook?(scope.workspacePath)
        #endif

        lock.lock()
        guard generation == standardStoreWarmGeneration else {
            let snapshot = (liveSnapshots[scope] ?? persistedSnapshots[scope])?.retainingPiReportedModelOptions()
            lock.unlock()
            return snapshot
        }
        if let loadedSnapshot {
            persistedSnapshots[scope] = loadedSnapshot
        } else {
            persistedSnapshots.removeValue(forKey: scope)
        }
        warmedStandardStoreScopes.insert(scope)
        let snapshot = (liveSnapshots[scope] ?? persistedSnapshots[scope])?.retainingPiReportedModelOptions()
        lock.unlock()
        return snapshot
    }

    func clearAllDiscoveredModels() {
        persistenceLock.lock()
        lock.lock()
        liveSnapshots.removeAll()
        liveSignatures.removeAll()
        persistedSnapshots.removeAll()
        refreshInFlightScopes.removeAll()
        settledScopes.removeAll()
        for task in standardStoreWarmTasks.values {
            task.cancel()
        }
        standardStoreWarmTasks.removeAll()
        warmedStandardStoreScopes.removeAll()
        standardStoreWarmGeneration &+= 1
        persistenceGeneration &+= 1
        lock.unlock()
        PiDynamicModelStore.remove()
        persistenceLock.unlock()
    }

    private static func normalizedOptionalString(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    #if DEBUG
        func test_reset() {
            persistenceLock.lock()
            lock.lock()
            liveSnapshots.removeAll()
            liveSignatures.removeAll()
            persistedSnapshots.removeAll()
            refreshInFlightScopes.removeAll()
            settledScopes.removeAll()
            for task in standardStoreWarmTasks.values {
                task.cancel()
            }
            standardStoreWarmTasks.removeAll()
            warmedStandardStoreScopes.removeAll()
            standardStoreWarmGeneration &+= 1
            persistenceGeneration &+= 1
            beforePersistDiscoveredModelsHook = nil
            beforeApplyPersistedWarmHook = nil
            beforeRemovePersistedModelsHook = nil
            lock.unlock()
            PiDynamicModelStore.remove()
            persistenceLock.unlock()
        }

        func test_clearMemoryPreservingStore() {
            lock.lock()
            liveSnapshots.removeAll()
            liveSignatures.removeAll()
            persistedSnapshots.removeAll()
            refreshInFlightScopes.removeAll()
            settledScopes.removeAll()
            for task in standardStoreWarmTasks.values {
                task.cancel()
            }
            standardStoreWarmTasks.removeAll()
            warmedStandardStoreScopes.removeAll()
            standardStoreWarmGeneration &+= 1
            lock.unlock()
        }

        func test_setBeforePersistDiscoveredModelsHook(_ hook: ((String?) -> Void)?) {
            lock.lock()
            beforePersistDiscoveredModelsHook = hook
            lock.unlock()
        }

        func test_setBeforeApplyPersistedWarmHook(_ hook: ((String?) -> Void)?) {
            lock.lock()
            beforeApplyPersistedWarmHook = hook
            lock.unlock()
        }

        func test_setBeforeRemovePersistedModelsHook(_ hook: ((String?) -> Void)?) {
            lock.lock()
            beforeRemovePersistedModelsHook = hook
            lock.unlock()
        }
    #endif
}
