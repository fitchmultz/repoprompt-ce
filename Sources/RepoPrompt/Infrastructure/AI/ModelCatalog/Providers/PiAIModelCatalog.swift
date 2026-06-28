import CryptoKit
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

final class AgentPiModelRegistry {
    static let shared = AgentPiModelRegistry()

    private let lock = NSLock()
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
        finishPersistentRemove(scope: scope)
        restorePersistedSnapshotFromMemory(scope: scope)
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
        PiDynamicModelStore.load(workspacePath: workspacePath)
    }

    private func persistSnapshotIfCurrent(
        _ snapshot: PiDiscoveredModels,
        record: PiDynamicModelSnapshotRecord,
        scope: PiModelWorkspaceScope,
        generation: UInt64
    ) {
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
            if let currentRecord,
               let currentSnapshot
            {
                PiDynamicModelStore.save(currentSnapshot, workspacePath: scope.workspacePath)
                lock.lock()
                let isStillCurrent = liveSignatures[scope] == currentRecord
                    && liveSnapshots[scope] == currentSnapshot
                    && persistenceGeneration == currentGeneration
                lock.unlock()
                if !isStillCurrent {
                    PiDynamicModelStore.remove(workspacePath: scope.workspacePath)
                    restorePersistedSnapshotFromMemory(scope: scope)
                }
            } else {
                PiDynamicModelStore.remove(workspacePath: scope.workspacePath)
                restorePersistedSnapshotFromMemory(scope: scope)
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
        restorePersistedSnapshotsFromMemory()
    }

    private func finishPersistentRemove(scope: PiModelWorkspaceScope) {
        lock.lock()
        standardStoreWarmGeneration &+= 1
        if liveSignatures[scope] == nil {
            persistedSnapshots.removeValue(forKey: scope)
        }
        lock.unlock()
    }

    private func restorePersistedSnapshotFromMemory(scope: PiModelWorkspaceScope) {
        lock.lock()
        let snapshot = liveSnapshots[scope]
        let signature = liveSignatures[scope]
        lock.unlock()
        guard let snapshot, signature != nil else { return }
        PiDynamicModelStore.save(snapshot, workspacePath: scope.workspacePath)
    }

    private func restorePersistedSnapshotsFromMemory() {
        lock.lock()
        let snapshots = liveSnapshots
        lock.unlock()
        for (scope, snapshot) in snapshots {
            PiDynamicModelStore.save(snapshot, workspacePath: scope.workspacePath)
        }
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
