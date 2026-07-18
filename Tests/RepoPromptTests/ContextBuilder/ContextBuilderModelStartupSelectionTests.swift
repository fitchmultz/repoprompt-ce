import Foundation
import XCTest
@_spi(TestSupport) @testable import RepoPrompt

@MainActor
final class ContextBuilderModelStartupSelectionTests: XCTestCase {
    func testValidPersistedSelectionSurvivesStoreReloadAndStartupResolution() throws {
        let fixture = try makeStoreFixture()
        fixture.store.setGlobalContextBuilderAgentSelection(
            agentRaw: AgentProviderKind.codexExec.rawValue,
            modelRaw: AgentModel.gpt55CodexLow.rawValue,
            markUserDefined: true
        )

        let reloadedStore = GlobalSettingsStore(defaults: fixture.defaults, fileStore: fixture.fileStore)
        let persisted = reloadedStore.persistedGlobalContextBuilderAgentSelection()
        let resolved = try XCTUnwrap(AutoRecommendationEngine.resolveContextBuilderSelection(
            persistedAgentRaw: persisted.agentRaw,
            persistedModelRaw: persisted.modelRaw,
            availability: .init(
                claudeCodeAvailable: false,
                codexAvailable: true,
                openCodeAvailable: false,
                cursorAvailable: false
            )
        ))

        XCTAssertEqual(resolved.agent, .codexExec)
        XCTAssertEqual(resolved.modelRaw, AgentModel.gpt55CodexLow.rawValue)
    }

    func testLegacyWorkspaceContextBuilderSelectionPromotesOverHistoricalGlobalDefault() throws {
        AgentPiModelRegistry.shared.test_reset()
        addTeardownBlock {
            AgentPiModelRegistry.shared.test_reset()
        }
        let piModelRaw = "openai-codex/gpt-5.5"
        XCTAssertTrue(AgentPiModelRegistry.shared.updateDiscoveredModels(PiDiscoveredModels(
            options: [AgentModelOption(
                rawValue: piModelRaw,
                displayName: "GPT-5.5",
                description: nil,
                isDefault: true,
                supportedPiThinkingLevels: PiThinkingLevel.standardModelOrder
            )],
            currentModelRaw: piModelRaw
        )))

        let fixture = try makeStoreFixture()
        try fixture.fileStore.save(GlobalSettingsDocument(
            chatSettings: [:],
            globalDefaults: GlobalDefaults(
                discoverAgentRaw: AgentProviderKind.claudeCode.rawValue,
                discoverModelsByAgent: [AgentProviderKind.claudeCode.rawValue: AgentModel.claudeOpus.rawValue],
                didUserSetDiscoverAgentDefaults: true
            )
        ))
        fixture.store.reloadFromDisk()
        let workspaceID = UUID()
        var settings = fixture.store.chatSettings(for: workspaceID)
        settings.contextBuilderAgentRaw = AgentProviderKind.pi.rawValue
        settings.contextBuilderAgentModelRaw = "\(piModelRaw):medium"
        settings.didUserSetContextBuilderDefaults = true
        fixture.store.updateChatSettings(settings)

        let promoted = try XCTUnwrap(fixture.store.promoteLegacyWorkspaceContextBuilderSelectionIfNeeded(
            workspaceID: workspaceID,
            availability: .init(
                claudeCodeAvailable: true,
                codexAvailable: true,
                openCodeAvailable: false,
                cursorAvailable: false,
                piAvailable: true
            ),
            enabledRecommendationProviders: Set(RecommendationProviderKind.allCases)
        ))

        XCTAssertEqual(promoted.agentRaw, AgentProviderKind.pi.rawValue)
        XCTAssertEqual(promoted.modelRaw, "\(piModelRaw):medium")
        let persisted = fixture.store.persistedGlobalContextBuilderAgentSelection()
        XCTAssertEqual(persisted.agentRaw, AgentProviderKind.pi.rawValue)
        XCTAssertEqual(persisted.modelRaw, "\(piModelRaw):medium")
        XCTAssertNil(fixture.store.promoteLegacyWorkspaceContextBuilderSelectionIfNeeded(
            workspaceID: workspaceID,
            availability: .init(piAvailable: true),
            enabledRecommendationProviders: Set(RecommendationProviderKind.allCases)
        ))
    }

    func testGlobalContextBuilderSelectionPreservesPiThinkingModelWithoutCatalog() throws {
        AgentPiModelRegistry.shared.test_reset()
        addTeardownBlock {
            AgentPiModelRegistry.shared.test_reset()
        }
        let fixture = try makeStoreFixture()
        let modelRaw = "openai-codex/gpt-5.5:medium"

        fixture.store.setGlobalContextBuilderAgentSelection(
            agentRaw: AgentProviderKind.pi.rawValue,
            modelRaw: modelRaw,
            markUserDefined: true
        )

        let persisted = fixture.store.persistedGlobalContextBuilderAgentSelection()
        XCTAssertEqual(persisted.agentRaw, AgentProviderKind.pi.rawValue)
        XCTAssertEqual(persisted.modelRaw, modelRaw)
        XCTAssertEqual(
            fixture.store.globalContextBuilderRememberedModelRaw(for: AgentProviderKind.pi.rawValue),
            modelRaw
        )

        let reloadedStore = GlobalSettingsStore(defaults: fixture.defaults, fileStore: fixture.fileStore)
        let reloaded = reloadedStore.persistedGlobalContextBuilderAgentSelection()
        XCTAssertEqual(reloaded.agentRaw, AgentProviderKind.pi.rawValue)
        XCTAssertEqual(reloaded.modelRaw, modelRaw)
    }

    func testExplicitWorkspaceSelectionPromotesAfterPreviousLegacyPromotionVersionWasRecorded() throws {
        AgentPiModelRegistry.shared.test_reset()
        addTeardownBlock {
            AgentPiModelRegistry.shared.test_reset()
        }
        let piModelRaw = "openai-codex/gpt-5.5"
        let selectedModelRaw = "\(piModelRaw):medium"
        XCTAssertTrue(AgentPiModelRegistry.shared.updateDiscoveredModels(PiDiscoveredModels(
            options: [AgentModelOption(
                rawValue: piModelRaw,
                displayName: "GPT-5.5",
                description: nil,
                isDefault: true,
                supportedPiThinkingLevels: PiThinkingLevel.standardModelOrder
            )],
            currentModelRaw: piModelRaw
        )))

        let fixture = try makeStoreFixture()
        let workspaceID = UUID()
        var workspaceSettings = ChatGlobalSettings(workspaceID: workspaceID)
        workspaceSettings.contextBuilderAgentRaw = AgentProviderKind.pi.rawValue
        workspaceSettings.contextBuilderAgentModelRaw = selectedModelRaw
        workspaceSettings.didUserSetContextBuilderDefaults = true

        var globalDefaults = GlobalDefaults(
            discoverAgentRaw: AgentProviderKind.claudeCode.rawValue,
            discoverModelsByAgent: [
                AgentProviderKind.claudeCode.rawValue: AgentModel.claudeOpus.rawValue,
                AgentProviderKind.pi.rawValue: selectedModelRaw
            ]
        )
        globalDefaults.didUserSetDiscoverAgentDefaults = true
        globalDefaults.contextBuilderLegacyWorkspacePromotionVersion = 1
        try fixture.fileStore.save(GlobalSettingsDocument(
            chatSettings: [workspaceID: workspaceSettings],
            globalDefaults: globalDefaults
        ))
        let store = GlobalSettingsStore(defaults: fixture.defaults, fileStore: fixture.fileStore)

        let promoted = try XCTUnwrap(store.promoteLegacyWorkspaceContextBuilderSelectionIfNeeded(
            workspaceID: workspaceID,
            availability: .init(
                claudeCodeAvailable: true,
                codexAvailable: true,
                openCodeAvailable: false,
                cursorAvailable: false,
                piAvailable: true
            ),
            enabledRecommendationProviders: Set(RecommendationProviderKind.allCases)
        ))

        XCTAssertEqual(promoted.agentRaw, AgentProviderKind.pi.rawValue)
        XCTAssertEqual(promoted.modelRaw, selectedModelRaw)
        let persisted = store.persistedGlobalContextBuilderAgentSelection()
        XCTAssertEqual(persisted.agentRaw, AgentProviderKind.pi.rawValue)
        XCTAssertEqual(persisted.modelRaw, selectedModelRaw)
    }

    func testCurrentPromotionVersionDoesNotOverwriteExplicitClaudeOpusGlobalSelection() throws {
        AgentPiModelRegistry.shared.test_reset()
        addTeardownBlock {
            AgentPiModelRegistry.shared.test_reset()
        }
        let piModelRaw = "openai-codex/gpt-5.5"
        let selectedModelRaw = "\(piModelRaw):medium"
        XCTAssertTrue(AgentPiModelRegistry.shared.updateDiscoveredModels(PiDiscoveredModels(
            options: [AgentModelOption(
                rawValue: piModelRaw,
                displayName: "GPT-5.5",
                description: nil,
                isDefault: true,
                supportedPiThinkingLevels: PiThinkingLevel.standardModelOrder
            )],
            currentModelRaw: piModelRaw
        )))

        let fixture = try makeStoreFixture()
        let workspaceID = UUID()
        var workspaceSettings = ChatGlobalSettings(workspaceID: workspaceID)
        workspaceSettings.contextBuilderAgentRaw = AgentProviderKind.pi.rawValue
        workspaceSettings.contextBuilderAgentModelRaw = selectedModelRaw
        workspaceSettings.didUserSetContextBuilderDefaults = true

        var globalDefaults = GlobalDefaults(
            discoverAgentRaw: AgentProviderKind.claudeCode.rawValue,
            discoverModelsByAgent: [
                AgentProviderKind.claudeCode.rawValue: AgentModel.claudeOpus.rawValue,
                AgentProviderKind.pi.rawValue: selectedModelRaw
            ],
            contextBuilderAgentRaw: AgentProviderKind.claudeCode.rawValue,
            contextBuilderModelRaw: AgentModel.claudeOpus.rawValue
        )
        globalDefaults.didUserSetDiscoverAgentDefaults = true
        globalDefaults.contextBuilderLegacyWorkspacePromotionVersion = 2
        try fixture.fileStore.save(GlobalSettingsDocument(
            chatSettings: [workspaceID: workspaceSettings],
            globalDefaults: globalDefaults
        ))
        let store = GlobalSettingsStore(defaults: fixture.defaults, fileStore: fixture.fileStore)

        XCTAssertNil(store.promoteLegacyWorkspaceContextBuilderSelectionIfNeeded(
            workspaceID: workspaceID,
            availability: .init(
                claudeCodeAvailable: true,
                codexAvailable: true,
                openCodeAvailable: false,
                cursorAvailable: false,
                piAvailable: true
            ),
            enabledRecommendationProviders: Set(RecommendationProviderKind.allCases)
        ))

        let persisted = store.persistedGlobalContextBuilderAgentSelection()
        XCTAssertEqual(persisted.agentRaw, AgentProviderKind.claudeCode.rawValue)
        XCTAssertEqual(persisted.modelRaw, AgentModel.claudeOpus.rawValue)
    }

    func testNewWorkspaceLegacyFieldsDoNotInventClaudeOpusDefaults() throws {
        let fixture = try makeStoreFixture()
        let unsetSettings = fixture.store.chatSettings(for: UUID())
        XCTAssertNil(unsetSettings.contextBuilderAgentRaw)
        XCTAssertNil(unsetSettings.contextBuilderAgentModelRaw)
        XCTAssertNil(unsetSettings.lastUsedDiscoverAgentRaw)
        XCTAssertNil(unsetSettings.lastUsedDiscoverModelsByAgent)

        let modelRaw = "openai-codex/gpt-5.5:medium"
        fixture.store.setGlobalContextBuilderAgentSelection(
            agentRaw: AgentProviderKind.pi.rawValue,
            modelRaw: modelRaw,
            markUserDefined: true
        )
        let seededSettings = fixture.store.chatSettings(for: UUID())
        XCTAssertEqual(seededSettings.contextBuilderAgentRaw, AgentProviderKind.pi.rawValue)
        XCTAssertEqual(seededSettings.contextBuilderAgentModelRaw, modelRaw)
        XCTAssertEqual(seededSettings.lastUsedDiscoverAgentRaw, AgentProviderKind.pi.rawValue)
        XCTAssertEqual(seededSettings.lastUsedDiscoverModelsByAgent?[AgentProviderKind.pi.rawValue], modelRaw)
    }

    func testLegacyDiscoverClaudeOpusDoesNotSeedContextBuilderForNewWorkspace() throws {
        let fixture = try makeStoreFixture()
        try fixture.fileStore.save(GlobalSettingsDocument(
            chatSettings: [:],
            globalDefaults: GlobalDefaults(
                discoverAgentRaw: AgentProviderKind.claudeCode.rawValue,
                discoverModelsByAgent: [AgentProviderKind.claudeCode.rawValue: AgentModel.claudeOpus.rawValue],
                didUserSetDiscoverAgentDefaults: true
            )
        ))
        fixture.store.reloadFromDisk()

        let settings = fixture.store.chatSettings(for: UUID())

        XCTAssertNil(settings.contextBuilderAgentRaw)
        XCTAssertNil(settings.contextBuilderAgentModelRaw)
        XCTAssertNil(fixture.store.persistedGlobalContextBuilderAgentSelection().agentRaw)
        XCTAssertFalse(fixture.store.hasUserSetGlobalContextBuilderAgentDefaults)
    }

    func testContextBuilderStartupSelectsPiGpt56SolLowAheadOfOtherProviders() throws {
        AgentPiModelRegistry.shared.test_reset()
        addTeardownBlock { AgentPiModelRegistry.shared.test_reset() }
        let piModelRaw = AgentModelCatalog.preferredPiModelBaseRaw
        XCTAssertTrue(AgentPiModelRegistry.shared.updateDiscoveredModels(PiDiscoveredModels(
            options: [AgentModelOption(
                rawValue: piModelRaw,
                displayName: "GPT-5.6 Sol",
                description: nil,
                isDefault: true,
                supportedPiThinkingLevels: [.low, .medium, .high, .xhigh, .max]
            )],
            currentModelRaw: piModelRaw
        )))

        let resolved = try XCTUnwrap(AutoRecommendationEngine.resolveContextBuilderSelection(
            persistedAgentRaw: nil,
            persistedModelRaw: nil,
            availability: .init(
                claudeCodeAvailable: true,
                codexAvailable: true,
                openCodeAvailable: true,
                cursorAvailable: true,
                piAvailable: true
            )
        ))

        XCTAssertEqual(resolved.agent, .pi)
        XCTAssertEqual(resolved.modelRaw, AgentModelCatalog.preferredPiModelRaw(thinkingLevel: .low))
        let recommendation = try XCTUnwrap(AutoRecommendationEngine.contextBuilderRecommendation(
            status: ProviderStatusSnapshot(
                claudeCodeCLI: .ready,
                codexCLI: .ready,
                cursorCLI: .ready,
                piCLI: .ready,
                openCodeCLI: .ready,
                openAI: .notConfigured
            ),
            preferredPiModelAvailable: true
        ))
        XCTAssertEqual(recommendation.recommendedAgent, .pi)
        XCTAssertEqual(recommendation.recommendedModelRaw, AgentModelCatalog.preferredPiModelRaw(thinkingLevel: .low))
    }

    func testOracleRecommendationPersistsPiGpt56SolXHighAndKeepsRoleDiscoveryUnrestricted() throws {
        let fixture = try makeStoreFixture()
        let keyManager = KeyManager(secureService: SecureKeysService(secureStorage: TestSecureStorageBackend()))
        let apiSettings = APISettingsViewModel(
            aiQueriesService: AIQueriesService(keyManager: keyManager),
            keyManager: keyManager,
            loadStoredDataOnInit: false
        )
        apiSettings.isPiConnected = true
        apiSettings.availablePiModelOptions = [AgentModelOption(
            rawValue: AgentModelCatalog.preferredPiModelBaseRaw,
            displayName: "GPT-5.6 Sol",
            description: nil,
            isDefault: true,
            supportedPiThinkingLevels: [.low, .medium, .high, .xhigh, .max]
        )]
        apiSettings.test_completeContextBuilderProviderValidation(verifiedProviders: [.pi])
        let engine = AutoRecommendationEngine(settingsStore: fixture.store, apiSettingsViewModel: apiSettings)
        let workspaceID = UUID()

        let recommendation = try XCTUnwrap(engine.computeRecommendations(for: workspaceID).chatModel)
        let expectedModel = AIModel.piCustom(
            name: AgentModelCatalog.preferredPiModelRaw(thinkingLevel: .xhigh)
        ).rawValue
        XCTAssertEqual(recommendation.defaultBackend, .pi)
        XCTAssertEqual(recommendation.piOption?.modelString, expectedModel)
        XCTAssertEqual(recommendation.piOption?.displayName, "pi (Recommended)")

        engine.applyChatModelRecommendation(recommendation, backend: recommendation.defaultBackend, workspaceID: workspaceID)

        XCTAssertEqual(fixture.store.planningModelRaw(), expectedModel)
        XCTAssertEqual(fixture.store.preferredComposeModelRaw(), expectedModel)
        XCTAssertFalse(fixture.store.restrictMCPAgentDiscoveryToRoleLabels())
    }

    func testContextBuilderStartupSkipsReadyPiWithoutUsableModelCatalog() throws {
        AgentPiModelRegistry.shared.test_reset()
        addTeardownBlock { AgentPiModelRegistry.shared.test_reset() }

        let resolved = try XCTUnwrap(AutoRecommendationEngine.resolveContextBuilderSelection(
            persistedAgentRaw: nil,
            persistedModelRaw: nil,
            availability: .init(
                claudeCodeAvailable: false,
                codexAvailable: false,
                openCodeAvailable: true,
                cursorAvailable: true,
                piAvailable: true
            )
        ))

        XCTAssertNotEqual(resolved.agent, .pi)
        XCTAssertTrue([AgentProviderKind.openCode, .cursor].contains(resolved.agent))
    }

    func testPersistedPiSelectionRestoresFromWorkspaceScopedCatalogOnly() throws {
        AgentPiModelRegistry.shared.test_reset()
        addTeardownBlock { AgentPiModelRegistry.shared.test_reset() }

        let workspacePath = "/tmp/context-builder-pi-workspace-\(UUID().uuidString)"
        let piModelRaw = "openai-codex/gpt-5.5"
        XCTAssertTrue(AgentPiModelRegistry.shared.updateDiscoveredModels(
            PiDiscoveredModels(
                options: [AgentModelOption(rawValue: piModelRaw, displayName: "GPT 5.5", description: nil, isDefault: true)],
                currentModelRaw: piModelRaw
            ),
            workspacePath: workspacePath
        ))

        let unscopedFallback = try XCTUnwrap(AutoRecommendationEngine.resolveContextBuilderSelection(
            persistedAgentRaw: AgentProviderKind.pi.rawValue,
            persistedModelRaw: piModelRaw,
            availability: .init(
                claudeCodeAvailable: false,
                codexAvailable: true,
                openCodeAvailable: false,
                cursorAvailable: false,
                piAvailable: true
            )
        ))
        XCTAssertNotEqual(unscopedFallback.agent, .pi)

        let scopedRestoration = try XCTUnwrap(AutoRecommendationEngine.resolveContextBuilderSelection(
            persistedAgentRaw: AgentProviderKind.pi.rawValue,
            persistedModelRaw: piModelRaw,
            availability: AgentModelCatalog.AvailabilityContext(
                claudeCodeAvailable: false,
                codexAvailable: true,
                openCodeAvailable: false,
                cursorAvailable: false,
                piAvailable: true
            ).withPiWorkspacePath(workspacePath)
        ))
        XCTAssertEqual(scopedRestoration.agent, .pi)
        XCTAssertEqual(scopedRestoration.modelRaw, piModelRaw)
    }

    func testContextBuilderStartsPiPollingBeforePiIsSelected() async throws {
        AgentPiModelRegistry.shared.test_reset()
        addTeardownBlock { AgentPiModelRegistry.shared.test_reset() }
        let polling = RecordingPiModelPollingService()
        let composition = WindowStateCompositionFactory.make(
            windowID: -812,
            deferredInitialAgentSystemWorkspaceRefresh: true,
            sharedMCPService: MCPService(),
            contextBuilderPiModelPollingService: polling
        )
        await composition.workspaceManager.awaitInitialized()

        let workspaceRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ContextBuilderPiPolling-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workspaceRoot, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: workspaceRoot)
        }
        let workspace = composition.workspaceManager.createWorkspace(
            name: "Context Builder pi polling",
            repoPaths: [workspaceRoot.path],
            ephemeral: true
        )
        _ = await composition.workspaceManager.switchWorkspace(
            to: workspace,
            saveState: false,
            reason: "ContextBuilderPiPollingTest"
        )
        composition.apiSettingsViewModel.isPiConnected = true

        let subscribedWorkspacePath = try await polling.waitForSubscription(matching: workspaceRoot.path)
        XCTAssertEqual(subscribedWorkspacePath, AgentPiModelRegistry.canonicalWorkspacePath(workspaceRoot.path))
        XCTAssertEqual(
            composition.contextBuilderAgentViewModel.test_piModelsSubscribedWorkspacePath(),
            AgentPiModelRegistry.canonicalWorkspacePath(workspaceRoot.path)
        )
        XCTAssertEqual(composition.contextBuilderAgentViewModel.piCatalogStateForCurrentWorkspace(), .loading)
        XCTAssertNotEqual(composition.contextBuilderAgentViewModel.selectedAgent, .pi)
    }

    func testPromptViewModelRestoresPersistedPiContextBuilderSelectionFromWorkspaceCatalog() async throws {
        AgentPiModelRegistry.shared.test_reset()
        addTeardownBlock { AgentPiModelRegistry.shared.test_reset() }
        let settingsFixture = try makeStoreFixture()

        let workspaceRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("PromptPiContextBuilderRestore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workspaceRoot, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: workspaceRoot)
        }
        let piModelRaw = "openai-codex/gpt-5.5"
        XCTAssertTrue(AgentPiModelRegistry.shared.updateDiscoveredModels(
            PiDiscoveredModels(
                options: [AgentModelOption(rawValue: piModelRaw, displayName: "GPT 5.5", description: nil, isDefault: true)],
                currentModelRaw: piModelRaw
            ),
            workspacePath: workspaceRoot.path
        ))
        settingsFixture.store.setGlobalContextBuilderAgentSelection(
            agentRaw: AgentProviderKind.pi.rawValue,
            modelRaw: piModelRaw,
            markUserDefined: true
        )

        let composition = WindowStateCompositionFactory.make(
            windowID: -813,
            deferredInitialAgentSystemWorkspaceRefresh: true,
            sharedMCPService: MCPService(),
            settingsStore: settingsFixture.store,
            contextBuilderPiModelPollingService: RecordingPiModelPollingService()
        )
        await composition.workspaceManager.awaitInitialized()
        let workspace = composition.workspaceManager.createWorkspace(
            name: "Prompt pi Context Builder restore",
            repoPaths: [workspaceRoot.path],
            ephemeral: true
        )
        _ = await composition.workspaceManager.switchWorkspace(
            to: workspace,
            saveState: false,
            reason: "PromptPiContextBuilderRestoreTest"
        )
        composition.apiSettingsViewModel.isPiConnected = true
        composition.apiSettingsViewModel.test_completeContextBuilderProviderValidation(verifiedProviders: [.pi])

        let didRestore = await eventually {
            composition.promptManager.contextBuilderAgent == .pi
                && composition.promptManager.contextBuilderAgentModelRaw == piModelRaw
        }
        XCTAssertTrue(didRestore)
    }

    func testDriftResolutionUsingWorkspaceDoesNotRecommitStalePromptSelection() async throws {
        AgentPiModelRegistry.shared.test_reset()
        addTeardownBlock { AgentPiModelRegistry.shared.test_reset() }
        let settingsFixture = try makeStoreFixture()

        let workspaceRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("PromptPiContextBuilderDrift-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workspaceRoot, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: workspaceRoot)
        }

        let piModelRaw = "openai-codex/gpt-5.5:medium"
        XCTAssertTrue(AgentPiModelRegistry.shared.updateDiscoveredModels(
            PiDiscoveredModels(
                options: [AgentModelOption(rawValue: piModelRaw, displayName: "GPT 5.5 Medium", description: nil, isDefault: true)],
                currentModelRaw: piModelRaw
            ),
            workspacePath: workspaceRoot.path
        ))
        settingsFixture.store.setGlobalContextBuilderAgentSelection(
            agentRaw: AgentProviderKind.claudeCode.rawValue,
            modelRaw: AgentModel.claudeOpus.rawValue,
            markUserDefined: true
        )

        let composition = WindowStateCompositionFactory.make(
            windowID: -814,
            deferredInitialAgentSystemWorkspaceRefresh: true,
            sharedMCPService: MCPService(),
            settingsStore: settingsFixture.store,
            contextBuilderPiModelPollingService: RecordingPiModelPollingService()
        )
        await composition.workspaceManager.awaitInitialized()
        let workspace = composition.workspaceManager.createWorkspace(
            name: "Prompt pi Context Builder drift",
            repoPaths: [workspaceRoot.path],
            ephemeral: true
        )
        _ = await composition.workspaceManager.switchWorkspace(
            to: workspace,
            saveState: false,
            reason: "PromptPiContextBuilderDriftTest"
        )

        var workspaceSettings = settingsFixture.store.chatSettings(for: workspace.id)
        workspaceSettings.contextBuilderAgentRaw = AgentProviderKind.pi.rawValue
        workspaceSettings.contextBuilderAgentModelRaw = piModelRaw
        workspaceSettings.didUserSetContextBuilderDefaults = true
        settingsFixture.store.updateChatSettings(workspaceSettings, commit: true)

        composition.apiSettingsViewModel.isPiConnected = true
        composition.apiSettingsViewModel.test_completeContextBuilderProviderValidation(verifiedProviders: [.pi])

        let viewModel = AgentModelsSettingsViewModel(
            promptVM: composition.promptManager,
            contextBuilderVM: composition.contextBuilderAgentViewModel,
            apiSettingsVM: composition.apiSettingsViewModel,
            settingsStore: settingsFixture.store
        )
        viewModel.refresh()
        XCTAssertNotNil(viewModel.contextBuilderDrift)

        viewModel.resolveContextBuilderDriftUsingWorkspace()

        let persisted = settingsFixture.store.persistedGlobalContextBuilderAgentSelection()
        XCTAssertEqual(persisted.agentRaw, AgentProviderKind.pi.rawValue)
        XCTAssertEqual(persisted.modelRaw, piModelRaw)

        let promptSynced = await eventually {
            composition.promptManager.contextBuilderAgent == .pi
                && composition.promptManager.contextBuilderAgentModelRaw == piModelRaw
        }
        XCTAssertTrue(promptSynced)
    }

    func testAutoSeededLegacyWorkspaceContextBuilderMismatchDoesNotShowDrift() async throws {
        AgentPiModelRegistry.shared.test_reset()
        addTeardownBlock { AgentPiModelRegistry.shared.test_reset() }
        let settingsFixture = try makeStoreFixture()

        let workspaceRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("PromptPiContextBuilderNoDrift-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workspaceRoot, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: workspaceRoot)
        }

        let piModelRaw = "openai-codex/gpt-5.5:medium"
        XCTAssertTrue(AgentPiModelRegistry.shared.updateDiscoveredModels(
            PiDiscoveredModels(
                options: [AgentModelOption(rawValue: piModelRaw, displayName: "GPT 5.5 Medium", description: nil, isDefault: true)],
                currentModelRaw: piModelRaw
            ),
            workspacePath: workspaceRoot.path
        ))
        settingsFixture.store.setGlobalContextBuilderAgentSelection(
            agentRaw: AgentProviderKind.pi.rawValue,
            modelRaw: piModelRaw,
            markUserDefined: true
        )

        let composition = WindowStateCompositionFactory.make(
            windowID: -815,
            deferredInitialAgentSystemWorkspaceRefresh: true,
            sharedMCPService: MCPService(),
            settingsStore: settingsFixture.store,
            contextBuilderPiModelPollingService: RecordingPiModelPollingService()
        )
        await composition.workspaceManager.awaitInitialized()
        let workspace = composition.workspaceManager.createWorkspace(
            name: "Prompt pi Context Builder auto seeded legacy",
            repoPaths: [workspaceRoot.path],
            ephemeral: true
        )
        _ = await composition.workspaceManager.switchWorkspace(
            to: workspace,
            saveState: false,
            reason: "PromptPiContextBuilderNoDriftTest"
        )

        var workspaceSettings = settingsFixture.store.chatSettings(for: workspace.id)
        workspaceSettings.contextBuilderAgentRaw = AgentProviderKind.claudeCode.rawValue
        workspaceSettings.contextBuilderAgentModelRaw = AgentModel.claudeOpus.rawValue
        workspaceSettings.didUserSetContextBuilderDefaults = false
        settingsFixture.store.updateChatSettings(workspaceSettings, commit: true)

        let viewModel = AgentModelsSettingsViewModel(
            promptVM: composition.promptManager,
            contextBuilderVM: composition.contextBuilderAgentViewModel,
            apiSettingsVM: composition.apiSettingsViewModel,
            settingsStore: settingsFixture.store
        )
        viewModel.refresh()

        XCTAssertNil(viewModel.contextBuilderDrift)
    }

    func testUnavailablePersistedSelectionFallsBackToRecommendedAvailableProvider() throws {
        let resolved = try XCTUnwrap(AutoRecommendationEngine.resolveContextBuilderSelection(
            persistedAgentRaw: AgentProviderKind.claudeCode.rawValue,
            persistedModelRaw: AgentModel.claudeOpus.rawValue,
            availability: .init(
                claudeCodeAvailable: false,
                codexAvailable: true,
                openCodeAvailable: true,
                cursorAvailable: true
            )
        ))

        XCTAssertEqual(resolved.agent, .codexExec)
        XCTAssertEqual(resolved.modelRaw, AgentModel.gpt55CodexLow.rawValue)
    }

    func testUnconfiguredClaudeCodeCannotBecomeEffectiveStartupSelection() throws {
        let resolved = try XCTUnwrap(AutoRecommendationEngine.resolveContextBuilderSelection(
            persistedAgentRaw: nil,
            persistedModelRaw: nil,
            availability: .init(
                claudeCodeAvailable: false,
                codexAvailable: true,
                openCodeAvailable: false,
                cursorAvailable: false
            )
        ))

        XCTAssertNotEqual(resolved.agent, .claudeCode)
        XCTAssertNotEqual(resolved.modelRaw, AgentModel.claudeOpus.rawValue)
        XCTAssertTrue(AgentModelCatalog.isValid(
            rawModel: resolved.modelRaw,
            for: resolved.agent,
            availability: .init(
                claudeCodeAvailable: false,
                codexAvailable: true,
                openCodeAvailable: false,
                cursorAvailable: false
            )
        ))
    }

    func testFallbackUsesWizardRecommendationProviderFilter() throws {
        let resolved = try XCTUnwrap(AutoRecommendationEngine.resolveContextBuilderSelection(
            persistedAgentRaw: AgentProviderKind.openCode.rawValue,
            persistedModelRaw: "removed/model",
            availability: .init(
                claudeCodeAvailable: true,
                codexAvailable: true,
                openCodeAvailable: false,
                cursorAvailable: false
            ),
            enabledRecommendationProviders: [.claudeCode]
        ))

        XCTAssertEqual(resolved.agent, .claudeCode)
        XCTAssertEqual(resolved.modelRaw, AgentModel.claudeSonnet.rawValue)
    }

    func testFilteredRecommendationProvidersDoNotReappearThroughGenericFallback() throws {
        let resolved = try XCTUnwrap(AutoRecommendationEngine.resolveContextBuilderSelection(
            persistedAgentRaw: nil,
            persistedModelRaw: nil,
            availability: .init(
                claudeCodeAvailable: false,
                codexAvailable: true,
                openCodeAvailable: true,
                cursorAvailable: false
            ),
            enabledRecommendationProviders: [.claudeCode]
        ))

        XCTAssertEqual(resolved.agent, .openCode)
        XCTAssertEqual(resolved.modelRaw, AgentModel.defaultModel.rawValue)
    }

    func testStaticOpenCodeDefaultSurvivesAfterACPDiscovery() throws {
        let providerID = ACPProviderID.openCode
        AgentACPModelRegistry.shared.test_reset(providerID: providerID)
        addTeardownBlock {
            AgentACPModelRegistry.shared.test_reset(providerID: providerID)
        }

        let preferredModelRaw = "openai/gpt-dynamic"
        XCTAssertTrue(AgentACPModelRegistry.shared.updateDiscoveredModels(
            ACPDiscoveredSessionModels(
                options: [AgentModelOption(
                    rawValue: preferredModelRaw,
                    displayName: "GPT Dynamic",
                    description: nil,
                    isPlaceholderDefault: false,
                    isProviderDefault: true
                )],
                currentModelRaw: preferredModelRaw
            ),
            for: providerID
        ))

        let resolved = try XCTUnwrap(AutoRecommendationEngine.resolveContextBuilderSelection(
            persistedAgentRaw: AgentProviderKind.openCode.rawValue,
            persistedModelRaw: AgentModel.defaultModel.rawValue,
            availability: .init(
                claudeCodeAvailable: false,
                codexAvailable: true,
                openCodeAvailable: true,
                cursorAvailable: false
            )
        ))

        XCTAssertEqual(resolved.agent, .openCode)
        XCTAssertEqual(resolved.modelRaw, preferredModelRaw)
    }

    func testDynamicPersistedSelectionSurvivesAfterACPDiscovery() throws {
        let providerID = ACPProviderID.openCode
        AgentACPModelRegistry.shared.test_reset(providerID: providerID)
        addTeardownBlock {
            AgentACPModelRegistry.shared.test_reset(providerID: providerID)
        }

        let dynamicModelRaw = "openai/gpt-dynamic"
        XCTAssertTrue(AgentACPModelRegistry.shared.updateDiscoveredModels(
            ACPDiscoveredSessionModels(
                options: [AgentModelOption(
                    rawValue: dynamicModelRaw,
                    displayName: "GPT Dynamic",
                    description: nil,
                    isPlaceholderDefault: false,
                    isProviderDefault: true
                )],
                currentModelRaw: dynamicModelRaw
            ),
            for: providerID
        ))

        let resolved = try XCTUnwrap(AutoRecommendationEngine.resolveContextBuilderSelection(
            persistedAgentRaw: AgentProviderKind.openCode.rawValue,
            persistedModelRaw: dynamicModelRaw,
            availability: .init(
                claudeCodeAvailable: false,
                codexAvailable: true,
                openCodeAvailable: true,
                cursorAvailable: false
            )
        ))

        XCTAssertEqual(resolved.agent, .openCode)
        XCTAssertEqual(resolved.modelRaw, dynamicModelRaw)
    }

    func testPersistedDynamicSelectionSurvivesStandardCatalogWarmup() async throws {
        let providerID = ACPProviderID.openCode
        AgentACPModelRegistry.shared.test_reset(providerID: providerID)
        addTeardownBlock {
            AgentACPModelRegistry.shared.test_reset(providerID: providerID)
        }

        let dynamicModelRaw = "openai/gpt-persisted"
        XCTAssertTrue(AgentACPModelRegistry.shared.updateDiscoveredModels(
            ACPDiscoveredSessionModels(
                options: [AgentModelOption(
                    rawValue: dynamicModelRaw,
                    displayName: "GPT Persisted",
                    description: nil,
                    isPlaceholderDefault: false,
                    isProviderDefault: true
                )],
                currentModelRaw: dynamicModelRaw
            ),
            for: providerID
        ))
        AgentACPModelRegistry.shared.test_clearMemoryPreservingStore(providerID: providerID)
        XCTAssertNil(AgentACPModelRegistry.shared.test_snapshot(providerID: providerID))

        await AgentACPModelRegistry.shared.test_warmStandardStore()

        let resolved = try XCTUnwrap(AutoRecommendationEngine.resolveContextBuilderSelection(
            persistedAgentRaw: AgentProviderKind.openCode.rawValue,
            persistedModelRaw: dynamicModelRaw,
            availability: .init(
                claudeCodeAvailable: false,
                codexAvailable: false,
                openCodeAvailable: true,
                cursorAvailable: false
            )
        ))
        XCTAssertEqual(resolved.agent, .openCode)
        XCTAssertEqual(resolved.modelRaw, dynamicModelRaw)
    }

    func testOpenCodeStartupReadinessJoinsRunningPollAndEmitsLiveSnapshot() async throws {
        let providerID = ACPProviderID.openCode
        AgentACPModelRegistry.shared.test_reset(providerID: providerID)
        addTeardownBlock {
            AgentACPModelRegistry.shared.test_reset(providerID: providerID)
        }

        let dynamicModelRaw = "openai/gpt-live"
        let discovered = ACPDiscoveredSessionModels(
            options: [AgentModelOption(
                rawValue: dynamicModelRaw,
                displayName: "GPT Live",
                description: nil,
                isPlaceholderDefault: false,
                isProviderDefault: true
            )],
            currentModelRaw: dynamicModelRaw
        )
        let client = DelayedOpenCodeDiscoveryClient(result: discovered)
        let service = OpenCodeACPModelPollingService(client: client, intervalNanos: 60_000_000_000)
        let stream = await service.subscribe(workspacePath: nil)
        await client.waitUntilCalled()

        async let readiness = service.refreshNow(workspacePath: nil)
        var iterator = stream.makeAsyncIterator()
        let emittedSnapshot = await iterator.next()
        let snapshot = try XCTUnwrap(emittedSnapshot)
        let isReady = await readiness
        let discoveryCallCount = await client.callCount()

        XCTAssertTrue(isReady)
        XCTAssertTrue(snapshot.isLiveDiscovery)
        XCTAssertEqual(snapshot.models.currentModelRaw, dynamicModelRaw)
        XCTAssertEqual(discoveryCallCount, 1)
        await service.shutdown()
    }

    func testCursorStartupReadinessJoinsRunningPollWithoutDynamicMetadata() async {
        let client = DelayedCursorDiscoveryClient(result: nil)
        let service = CursorACPModelPollingService(client: client, intervalNanos: 60_000_000_000)
        let stream = await service.subscribe(workspacePath: nil)
        await client.waitUntilCalled()

        async let readiness = service.refreshNow(workspacePath: nil)
        var iterator = stream.makeAsyncIterator()
        var liveSnapshot: CursorACPModelPollingService.Snapshot?
        while liveSnapshot == nil, let snapshot = await iterator.next() {
            if snapshot.isLiveDiscovery {
                liveSnapshot = snapshot
            }
        }
        let isReady = await readiness
        let discoveryCallCount = await client.callCount()

        XCTAssertTrue(isReady)
        XCTAssertEqual(liveSnapshot?.isLiveDiscovery, true)
        XCTAssertEqual(discoveryCallCount, 1)
        await service.shutdown()
    }

    func testTransientFallbackResolutionDoesNotMutatePersistedSelection() throws {
        let fixture = try makeStoreFixture()
        fixture.store.setGlobalContextBuilderAgentSelection(
            agentRaw: AgentProviderKind.openCode.rawValue,
            modelRaw: "openai/gpt-dynamic",
            markUserDefined: true
        )
        let before = fixture.store.persistedGlobalContextBuilderAgentSelection()

        let fallback = try XCTUnwrap(AutoRecommendationEngine.resolveContextBuilderSelection(
            persistedAgentRaw: before.agentRaw,
            persistedModelRaw: before.modelRaw,
            availability: .init(
                claudeCodeAvailable: false,
                codexAvailable: true,
                openCodeAvailable: false,
                cursorAvailable: false
            )
        ))

        XCTAssertEqual(fallback.agent, .codexExec)
        XCTAssertEqual(fixture.store.persistedGlobalContextBuilderAgentSelection().agentRaw, before.agentRaw)
        XCTAssertEqual(fixture.store.persistedGlobalContextBuilderAgentSelection().modelRaw, before.modelRaw)
    }

    func testCachedCLIFlagIsNotReadyUntilCurrentProcessVerification() {
        let keys = ["ClaudeCodeConnected", "CodexCLIConnected", "OpenCodeCLIConnected", "CursorCLIConnected"]
        let previous = Dictionary(uniqueKeysWithValues: keys.map { ($0, UserDefaults.standard.object(forKey: $0)) })
        defer {
            for (key, value) in previous {
                if let value {
                    UserDefaults.standard.set(value, forKey: key)
                } else {
                    UserDefaults.standard.removeObject(forKey: key)
                }
            }
        }

        UserDefaults.standard.set(true, forKey: "ClaudeCodeConnected")
        UserDefaults.standard.set(false, forKey: "CodexCLIConnected")
        UserDefaults.standard.set(false, forKey: "OpenCodeCLIConnected")
        UserDefaults.standard.set(false, forKey: "CursorCLIConnected")

        let keyManager = KeyManager(secureService: SecureKeysService(secureStorage: TestSecureStorageBackend()))
        let viewModel = APISettingsViewModel(
            aiQueriesService: AIQueriesService(keyManager: keyManager),
            keyManager: keyManager,
            loadStoredDataOnInit: false
        )

        XCTAssertEqual(viewModel.recommendationProviderStatusSnapshot.claudeCodeCLI, .configured)
        XCTAssertFalse(viewModel.contextBuilderRestorationAvailabilityContext.claudeCodeAvailable)

        viewModel.test_completeContextBuilderProviderValidation(verifiedProviders: [])
        XCTAssertEqual(viewModel.recommendationProviderStatusSnapshot.claudeCodeCLI, .notConfigured)
        XCTAssertTrue(UserDefaults.standard.bool(forKey: "ClaudeCodeConnected"))

        viewModel.test_completeContextBuilderProviderValidation(verifiedProviders: [.claudeCode])
        XCTAssertEqual(viewModel.recommendationProviderStatusSnapshot.claudeCodeCLI, .ready)
        XCTAssertTrue(viewModel.contextBuilderRestorationAvailabilityContext.claudeCodeAvailable)
    }

    private func eventually(
        timeout: TimeInterval = 1,
        condition: @MainActor @escaping () async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() {
                return true
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return await condition()
    }

    private func makeStoreFixture() throws -> (
        store: GlobalSettingsStore,
        defaults: UserDefaults,
        fileStore: GlobalSettingsFileStore
    ) {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ContextBuilderModelStartupSelectionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: temp)
        }

        let suiteName = "ContextBuilderModelStartupSelectionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let fileStore = GlobalSettingsFileStore(
            fileURL: temp.appendingPathComponent("Settings/globalSettings.json")
        )
        return (GlobalSettingsStore(defaults: defaults, fileStore: fileStore), defaults, fileStore)
    }
}

private actor RecordingPiModelPollingService: PiModelPolling {
    private var subscriptions: [String?] = []

    func latestSnapshot() async -> PiModelPollingService.Snapshot? {
        nil
    }

    func discoverOnce(workspacePath _: String?) async throws -> PiModelPollingService.Snapshot? {
        nil
    }

    func subscribe(workspacePath: String?) async -> AsyncStream<PiModelPollingService.Event> {
        subscriptions.append(workspacePath)
        if let workspacePath {
            AgentPiModelRegistry.shared.setRefreshInFlight(true, workspacePath: workspacePath)
        }
        return AsyncStream { _ in }
    }

    func waitForSubscription(matching workspacePath: String, timeout: TimeInterval = 2) async throws -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        let canonicalWorkspacePath = AgentPiModelRegistry.canonicalWorkspacePath(workspacePath) ?? workspacePath
        while Date() < deadline {
            if let match = subscriptions.last(where: { $0 == canonicalWorkspacePath }) {
                return match
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for pi model subscription for \(canonicalWorkspacePath)")
        return nil
    }
}

private actor DelayedOpenCodeDiscoveryClient: OpenCodeACPModelDiscoveryClient {
    private let result: ACPDiscoveredSessionModels?
    private var calls = 0

    init(result: ACPDiscoveredSessionModels?) {
        self.result = result
    }

    func discoverModels(workspacePath _: String?) async throws -> ACPDiscoveredSessionModels? {
        calls += 1
        try await Task.sleep(nanoseconds: 100_000_000)
        return result
    }

    func waitUntilCalled() async {
        while calls == 0 {
            await Task.yield()
        }
    }

    func callCount() -> Int {
        calls
    }
}

private actor DelayedCursorDiscoveryClient: CursorACPModelDiscoveryClient {
    private let result: ACPDiscoveredSessionModels?
    private var calls = 0

    init(result: ACPDiscoveredSessionModels?) {
        self.result = result
    }

    func discoverModels(workspacePath _: String?) async throws -> ACPDiscoveredSessionModels? {
        calls += 1
        try await Task.sleep(nanoseconds: 100_000_000)
        return result
    }

    func waitUntilCalled() async {
        while calls == 0 {
            await Task.yield()
        }
    }

    func callCount() -> Int {
        calls
    }
}
