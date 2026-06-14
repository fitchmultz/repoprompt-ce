@testable import RepoPrompt
import XCTest

final class PiModelCatalogTests: XCTestCase {
    override func tearDown() {
        AgentPiModelRegistry.shared.test_reset()
        super.tearDown()
    }

    func testRemoteModelsNormalizeToProviderQualifiedOptionsAndCatalogValidity() throws {
        AgentPiModelRegistry.shared.test_reset()
        let snapshot = AgentPiModelRegistry.discoveredModels(
            from: [
                .init(provider: "zai", id: "glm-5.1", displayName: "GLM 5.1", description: "Strong GLM", raw: ["reasoning": .bool(true)]),
                .init(provider: "cursor", id: "composer-2-5", displayName: "Composer 2.5", description: nil, raw: ["reasoning": .bool(false)]),
                .init(provider: "openai-codex", id: "gpt-5.5", displayName: "GPT 5.5", description: "Codex model", raw: [
                    "reasoning": .bool(true),
                    "thinkingLevelMap": .object(["minimal": .null, "xhigh": .string("xhigh")])
                ])
            ],
            currentModel: .init(provider: "zai", id: "glm-5.1", displayName: "GLM 5.1", description: nil, raw: [:])
        )

        XCTAssertNotNil(snapshot)
        XCTAssertTrue(try AgentPiModelRegistry.shared.updateDiscoveredModels(XCTUnwrap(snapshot)))
        let availability = AgentModelCatalog.AvailabilityContext(piAvailable: true)
        let options = AgentModelCatalog.options(for: .pi, availability: availability)

        XCTAssertEqual(options.map(\.rawValue), ["default", "cursor/composer-2-5", "openai-codex/gpt-5.5", "zai/glm-5.1"])
        XCTAssertTrue(options[0].isPlaceholderDefault)
        let zaiOption = try XCTUnwrap(options.first { $0.rawValue == "zai/glm-5.1" })
        XCTAssertTrue(zaiOption.isProviderDefault)
        XCTAssertEqual(zaiOption.displayName, "GLM 5.1")
        XCTAssertEqual(zaiOption.description, "GLM 5.1 — Strong GLM")
        XCTAssertEqual(zaiOption.supportedPiThinkingLevels, [.off, .minimal, .low, .medium, .high])
        XCTAssertEqual(AgentModelCatalog.displayName(for: "zai/glm-5.1", agentKind: .pi, availability: availability), "GLM 5.1")
        XCTAssertEqual(AgentModelCatalog.displayName(for: "openai-codex/gpt-5.5:low", agentKind: .pi, availability: availability), "GPT 5.5 Low")
        XCTAssertTrue(AgentModelCatalog.isValid(rawModel: "zai/glm-5.1", for: .pi, availability: availability))
        XCTAssertTrue(AgentModelCatalog.isValid(rawModel: "openai-codex/gpt-5.5:low", for: .pi, availability: availability))
        XCTAssertTrue(AgentModelCatalog.isValid(rawModel: "openai-codex/gpt-5.5:xhigh", for: .pi, availability: availability))
        XCTAssertFalse(AgentModelCatalog.isValid(rawModel: "openai-codex/gpt-5.5:minimal", for: .pi, availability: availability))
        XCTAssertFalse(AgentModelCatalog.isValid(rawModel: "openai-codex/gpt-5.5:bananas", for: .pi, availability: availability))
        XCTAssertEqual(AgentModelCatalog.piThinkingLevelOptions(for: "openai-codex/gpt-5.5"), [.off, .low, .medium, .high, .xhigh])
        XCTAssertFalse(AgentModelCatalog.modelOptionIsSelected(
            optionRaw: "openai-codex/gpt-5.5",
            selectedRaw: "openai-codex/gpt-5.5:low",
            agentKind: .pi
        ))
        XCTAssertTrue(AgentModelCatalog.modelOptionIsSelected(
            optionRaw: "openai-codex/gpt-5.5:low",
            selectedRaw: "openai-codex/gpt-5.5:low",
            agentKind: .pi
        ))
        XCTAssertFalse(AgentModelCatalog.modelOptionIsSelected(
            optionRaw: "openai-codex/gpt-5.5:high",
            selectedRaw: "openai-codex/gpt-5.5:low",
            agentKind: .pi
        ))
        XCTAssertFalse(AgentModelCatalog.isValid(rawModel: "missing/model", for: .pi, availability: availability))
        XCTAssertFalse(AgentModelCatalog.isValid(rawModel: "missing/gpt-5.5:low", for: .pi, availability: availability))
    }

    func testCurrentAvailabilitySurfacesConnectedPiRuntimeModelsForMCPOptions() throws {
        UserDefaults.standard.set(true, forKey: "PiCLIConnected")
        defer { UserDefaults.standard.removeObject(forKey: "PiCLIConnected") }
        let snapshot = Self.snapshot(
            rawValue: "openai-codex/gpt-5.5",
            displayName: "GPT 5.5",
            thinkingLevels: [.low, .medium, .high]
        )
        XCTAssertTrue(AgentPiModelRegistry.shared.updateDiscoveredModels(snapshot))

        let piAgent = try XCTUnwrap(
            AgentModelCatalog.discoveryAgents(availability: .current)
                .first { $0.agent == .pi }
        )

        XCTAssertTrue(piAgent.available)
        XCTAssertEqual(
            piAgent.models.flatMap(\.startTargets).map(\.modelRaw),
            ["default", "openai-codex/gpt-5.5"]
        )
    }

    func testPiModelSpecifierUsesStrictCanonicalThinkingSuffixesAndKnownModelPrecedence() throws {
        let rawModel = "custom/provider-model:high"
        let snapshot = AgentPiModelRegistry.discoveredModels(
            from: [
                .init(
                    provider: "custom",
                    id: "provider-model:high",
                    displayName: "Provider Model High",
                    description: nil,
                    raw: ["reasoning": .bool(false)]
                )
            ],
            currentModel: nil
        )

        XCTAssertNotNil(snapshot)
        XCTAssertTrue(try AgentPiModelRegistry.shared.updateDiscoveredModels(XCTUnwrap(snapshot)))
        let availability = AgentModelCatalog.AvailabilityContext(piAvailable: true)

        XCTAssertTrue(AgentModelCatalog.isValid(rawModel: rawModel, for: .pi, availability: availability))
        XCTAssertFalse(AgentModelCatalog.isValid(
            rawModel: "provider/model:none",
            for: .pi,
            availability: availability
        ))
        XCTAssertFalse(AgentModelCatalog.isValid(
            rawModel: "provider/model:x-high",
            for: .pi,
            availability: availability
        ))
        XCTAssertFalse(AgentModelCatalog.isValid(
            rawModel: "provider/model:high",
            for: .pi,
            availability: availability
        ))
        XCTAssertEqual(AgentModelCatalog.piThinkingLevelOptions(for: rawModel), [])
    }

    func testColonBearingKnownPiModelResolvesAcrossPickerMenuAndDisplayPaths() throws {
        let workspace = "/tmp/pi-known-colon-workspace"
        let rawModel = "custom/provider-model:high"
        let snapshot = Self.snapshot(
            rawValue: rawModel,
            displayName: "Provider Model High",
            thinkingLevels: []
        )
        XCTAssertTrue(AgentPiModelRegistry.shared.updateDiscoveredModels(snapshot, workspacePath: workspace))
        let availability = AgentModelCatalog.AvailabilityContext(piAvailable: true, piWorkspacePath: workspace)
        let options = AgentModelCatalog.options(for: .pi, availability: availability)
        let knownModelIDs = AgentModelCatalog.piKnownModelIDs(workspacePath: workspace)

        let specifier = try XCTUnwrap(AgentModelCatalog.piModelSpecifier(raw: rawModel, workspacePath: workspace))
        XCTAssertEqual(specifier.providerQualifiedModelRaw, rawModel)
        XCTAssertNil(specifier.thinkingLevel)
        XCTAssertEqual(
            AgentModelCatalog.displayName(for: rawModel, agentKind: .pi, availability: availability),
            "Provider Model High"
        )
        XCTAssertEqual(
            AgentModelCatalog.qualifiedDisplayName(for: rawModel, agentKind: .pi, availability: availability),
            "pi · Custom · Provider Model High"
        )
        XCTAssertTrue(AgentModelCatalog.modelOptionIsSelected(
            optionRaw: rawModel,
            selectedRaw: rawModel,
            agentKind: .pi,
            knownModelIDs: knownModelIDs
        ))

        let menu = AgentModelCatalog.piMenu(for: options, includeThinkingLevelOptions: true, knownModelIDs: knownModelIDs)
        let group = try XCTUnwrap(menu.providerGroups.first?.groups.first)
        XCTAssertEqual(group.baseModelRaw, rawModel)
        XCTAssertEqual(group.options.map(\.option.rawValue), [rawModel])
        XCTAssertEqual(group.options.map(\.thinkingLevel), [nil])
    }

    func testUnknownPiModelWithCanonicalThinkingSuffixStillSplits() throws {
        let specifier = try XCTUnwrap(PiModelSpecifier(raw: "custom/provider-model:high", knownModelIDs: []))

        XCTAssertEqual(specifier.providerQualifiedModelRaw, "custom/provider-model")
        XCTAssertEqual(specifier.thinkingLevel, "high")
    }

    func testColonBearingPiModelIDsRemainSelectableAndSupportThinkingVariants() throws {
        let rawModel = "amazon-bedrock/amazon.nova-2-lite-v1:0"
        let snapshot = AgentPiModelRegistry.discoveredModels(
            from: [
                .init(
                    provider: "amazon-bedrock",
                    id: "amazon.nova-2-lite-v1:0",
                    displayName: "Nova 2 Lite",
                    description: nil,
                    raw: ["reasoning": .bool(true)]
                )
            ],
            currentModel: nil
        )

        XCTAssertNotNil(snapshot)
        XCTAssertTrue(try AgentPiModelRegistry.shared.updateDiscoveredModels(XCTUnwrap(snapshot)))
        let availability = AgentModelCatalog.AvailabilityContext(piAvailable: true)

        XCTAssertTrue(AgentModelCatalog.isValid(rawModel: rawModel, for: .pi, availability: availability))
        XCTAssertTrue(AgentModelCatalog.isValid(rawModel: "\(rawModel):high", for: .pi, availability: availability))
        XCTAssertEqual(
            AgentModelCatalog.displayName(for: "\(rawModel):high", agentKind: .pi, availability: availability),
            "Nova 2 Lite High"
        )

        let menu = AgentModelCatalog.piMenu(
            for: AgentModelCatalog.options(for: .pi, availability: availability),
            includeThinkingLevelOptions: true
        )
        let group = try XCTUnwrap(menu.providerGroups.first?.groups.first)
        XCTAssertEqual(group.displayName, "Nova 2 Lite")
        XCTAssertEqual(group.options.map(\.option.rawValue), [
            rawModel,
            "\(rawModel):off",
            "\(rawModel):minimal",
            "\(rawModel):low",
            "\(rawModel):medium",
            "\(rawModel):high"
        ])
    }

    func testPiDefaultThinkingOptionsFollowCurrentDiscoveredModel() {
        let snapshot = PiDiscoveredModels(
            options: [
                AgentModelOption(rawValue: "default", displayName: "Default", description: nil, isDefault: true),
                AgentModelOption(
                    rawValue: "openai-codex/gpt-5.5",
                    displayName: "GPT 5.5",
                    description: nil,
                    isDefault: true,
                    supportedPiThinkingLevels: [.off, .low, .medium, .high, .xhigh]
                )
            ],
            currentModelRaw: "openai-codex/gpt-5.5"
        )
        XCTAssertTrue(AgentPiModelRegistry.shared.updateDiscoveredModels(snapshot))

        XCTAssertEqual(AgentModelCatalog.piThinkingLevelOptions(for: "default"), [.off, .low, .medium, .high, .xhigh])
    }

    func testPiMenuGroupsDiscoveredModelsByProviderAlphabetically() {
        let menu = AgentModelCatalog.piMenu(for: [
            AgentModelOption(rawValue: "default", displayName: "Default", description: nil, isDefault: true),
            AgentModelOption(rawValue: "zai/glm-5.1", displayName: "GLM 5.1", description: nil, isDefault: true),
            AgentModelOption(rawValue: "cursor/composer-2-5", displayName: "Composer 2.5", description: nil, isDefault: false),
            AgentModelOption(rawValue: "openai-codex/gpt-5.5", displayName: "GPT 5.5", description: nil, isDefault: false)
        ])

        XCTAssertEqual(menu.defaultOption?.rawValue, "default")
        XCTAssertEqual(menu.providerGroups.map(\.providerID), ["cursor", "openai-codex", "zai"])
        XCTAssertEqual(menu.providerGroups.map(\.displayName), ["Cursor", "OpenAI Codex", "Z.ai"])
        XCTAssertEqual(menu.providerGroups[0].options.first?.displayName, "Composer 2.5")
        XCTAssertEqual(menu.providerGroups[1].options.first?.displayName, "GPT 5.5")
        XCTAssertEqual(menu.providerGroups[2].options.first?.displayName, "GLM 5.1")
    }

    func testPiMenuStripsProviderPrefixFromRawQualifiedDisplayNames() {
        let menu = AgentModelCatalog.piMenu(for: [
            AgentModelOption(rawValue: "anthropic/claude-opus-4-5", displayName: "anthropic/claude-opus-4-5", description: nil, isDefault: false),
            AgentModelOption(rawValue: "openai-codex/gpt-5.5", displayName: "openai-codex/gpt-5.5", description: nil, isDefault: false)
        ])

        XCTAssertEqual(menu.providerGroups.map(\.displayName), ["Anthropic", "OpenAI Codex"])
        XCTAssertEqual(menu.providerGroups[0].options.map(\.displayName), ["Claude Opus 4 5"])
        XCTAssertEqual(menu.providerGroups[1].options.map(\.displayName), ["GPT 5.5"])
    }

    func testPiMenuGroupsThinkingVariantsUnderBaseModel() {
        let menu = AgentModelCatalog.piMenu(for: [
            AgentModelOption(rawValue: "openai-codex/gpt-5.5", displayName: "openai-codex/gpt-5.5", description: nil, isDefault: false),
            AgentModelOption(rawValue: "openai-codex/gpt-5.5:low", displayName: "openai-codex/gpt-5.5:low", description: nil, isDefault: false),
            AgentModelOption(rawValue: "openai-codex/gpt-5.5:high", displayName: "openai-codex/gpt-5.5:high", description: nil, isDefault: false),
            AgentModelOption(rawValue: "anthropic/claude-opus-4-5:medium", displayName: "Claude Opus 4.5 Medium", description: nil, isDefault: false)
        ])

        XCTAssertEqual(menu.providerGroups.map(\.displayName), ["Anthropic", "OpenAI Codex"])
        XCTAssertEqual(menu.providerGroups[0].groups.map(\.displayName), ["Claude Opus 4.5"])
        XCTAssertEqual(menu.providerGroups[0].groups[0].options.map(\.displayName), ["Medium"])
        XCTAssertEqual(menu.providerGroups[1].groups.map(\.displayName), ["GPT 5.5"])
        XCTAssertTrue(menu.providerGroups[1].groups[0].rendersAsSubmenu)
        XCTAssertEqual(menu.providerGroups[1].groups[0].options.map(\.displayName), ["Model Default", "Low", "High"])
    }

    func testPiMenuSynthesizesThinkingVariantsOnlyWhenRequested() throws {
        let options = [
            AgentModelOption(rawValue: "default", displayName: "Default", description: nil, isDefault: true),
            AgentModelOption(
                rawValue: "openai-codex/gpt-5.5",
                displayName: "GPT 5.5",
                description: nil,
                isDefault: false,
                supportedPiThinkingLevels: [.off, .low, .high]
            ),
            AgentModelOption(
                rawValue: "cursor/composer-2-5",
                displayName: "Composer 2.5",
                description: nil,
                isDefault: false
            )
        ]

        let modelOnlyMenu = AgentModelCatalog.piMenu(for: options)
        let modelOnlyCodexGroup = modelOnlyMenu.providerGroups
            .first { $0.displayName == "OpenAI Codex" }?
            .groups.first
        XCTAssertEqual(modelOnlyCodexGroup?.displayName, "GPT 5.5")
        XCTAssertEqual(modelOnlyCodexGroup?.options.map(\.option.rawValue), ["openai-codex/gpt-5.5"])
        XCTAssertFalse(modelOnlyCodexGroup?.rendersAsSubmenu ?? true)

        let combinedMenu = AgentModelCatalog.piMenu(for: options, includeThinkingLevelOptions: true)
        XCTAssertEqual(combinedMenu.defaultOption?.rawValue, "default")
        let codexGroup = try XCTUnwrap(
            combinedMenu.providerGroups
                .first { $0.displayName == "OpenAI Codex" }?
                .groups.first
        )
        XCTAssertEqual(codexGroup.displayName, "GPT 5.5")
        XCTAssertTrue(codexGroup.rendersAsSubmenu)
        XCTAssertEqual(codexGroup.options.map(\.displayName), ["Model Default", "Off", "Low", "High"])
        XCTAssertEqual(codexGroup.options.map(\.option.rawValue), [
            "openai-codex/gpt-5.5",
            "openai-codex/gpt-5.5:off",
            "openai-codex/gpt-5.5:low",
            "openai-codex/gpt-5.5:high"
        ])

        let cursorGroup = combinedMenu.providerGroups
            .first { $0.displayName == "Cursor" }?
            .groups.first
        XCTAssertEqual(cursorGroup?.options.map(\.option.rawValue), ["cursor/composer-2-5"])
        XCTAssertFalse(cursorGroup?.rendersAsSubmenu ?? true)
    }

    func testPiDynamicModelRecordBackfillsLegacySnapshotsWithStandardThinkingLevels() throws {
        let json = #"""
        {
          "currentModelRaw": "zai/glm-5.1",
          "options": [
            {
              "rawValue": "zai/glm-5.1",
              "displayName": "GLM 5.1",
              "isPlaceholderDefault": false,
              "isProviderDefault": true
            },
            {
              "rawValue": "openai-codex/gpt-5.5",
              "displayName": "GPT-5.5",
              "isPlaceholderDefault": false,
              "isProviderDefault": false
            }
          ]
        }
        """#.data(using: .utf8)!

        let record = try JSONDecoder().decode(PiDynamicModelSnapshotRecord.self, from: json)
        let snapshot = try XCTUnwrap(PiDynamicModelStore.snapshot(from: record))

        XCTAssertEqual(snapshot.option(matching: "zai/glm-5.1")?.supportedPiThinkingLevels, PiThinkingLevel.standardModelOrder)
        XCTAssertEqual(snapshot.option(matching: "openai-codex/gpt-5.5")?.supportedPiThinkingLevels, [.off, .low, .medium, .high, .xhigh])
    }

    func testPiModelCatalogResolvesDiscoveredModelsByWorkspaceAvailability() {
        let workspaceA = "/tmp/pi-model-catalog-workspace-a"
        let workspaceB = "/tmp/pi-model-catalog-workspace-b"
        let snapshotA = Self.snapshot(rawValue: "workspace-a/model", displayName: "Workspace A Model")
        let snapshotB = Self.snapshot(rawValue: "workspace-b/model", displayName: "Workspace B Model")

        XCTAssertTrue(AgentPiModelRegistry.shared.updateDiscoveredModels(snapshotA, workspacePath: workspaceA))
        XCTAssertTrue(AgentPiModelRegistry.shared.updateDiscoveredModels(snapshotB, workspacePath: workspaceB))

        let optionsA = AgentModelCatalog.options(
            for: .pi,
            availability: .init(piAvailable: true, piWorkspacePath: workspaceA)
        )
        let optionsB = AgentModelCatalog.options(
            for: .pi,
            availability: .init(piAvailable: true, piWorkspacePath: workspaceB)
        )

        XCTAssertEqual(optionsA.map(\.rawValue), ["default", "workspace-a/model"])
        XCTAssertEqual(optionsB.map(\.rawValue), ["default", "workspace-b/model"])
        XCTAssertEqual(
            AgentModelCatalog.piThinkingLevelOptions(for: "workspace-a/model", workspacePath: workspaceB),
            []
        )
    }

    func testWorkspaceScopedPiModelResolutionUsesAvailabilityWorkspacePath() {
        let workspaceA = "/tmp/pi-model-resolution-workspace-a"
        let workspaceB = "/tmp/pi-model-resolution-workspace-b"
        let snapshotA = Self.snapshot(
            rawValue: "workspace-a/model",
            displayName: "Workspace A Model",
            thinkingLevels: [.off, .low]
        )
        let snapshotB = Self.snapshot(
            rawValue: "workspace-b/model",
            displayName: "Workspace B Model",
            thinkingLevels: [.off, .high]
        )
        XCTAssertTrue(AgentPiModelRegistry.shared.updateDiscoveredModels(snapshotA, workspacePath: workspaceA))
        XCTAssertTrue(AgentPiModelRegistry.shared.updateDiscoveredModels(snapshotB, workspacePath: workspaceB))
        let availabilityA = AgentModelCatalog.AvailabilityContext(piAvailable: true, piWorkspacePath: workspaceA)
        let availabilityB = AgentModelCatalog.AvailabilityContext(piAvailable: true, piWorkspacePath: workspaceB)

        XCTAssertEqual(
            AgentModelCatalog.modelOption(matching: "workspace-a/model", for: .pi, availability: availabilityA)?.displayName,
            "Workspace A Model"
        )
        XCTAssertNil(AgentModelCatalog.modelOption(matching: "workspace-a/model", for: .pi, availability: availabilityB))
        XCTAssertTrue(AgentModelCatalog.isValid(rawModel: "workspace-b/model:high", for: .pi, availability: availabilityB))
        XCTAssertFalse(AgentModelCatalog.isValid(rawModel: "workspace-b/model:high", for: .pi, availability: availabilityA))
        XCTAssertEqual(
            AgentModelCatalog.displayName(for: "workspace-b/model:high", agentKind: .pi, availability: availabilityB),
            "Workspace B Model High"
        )
        XCTAssertEqual(
            AgentModelCatalog.resolveSelectionID("pi:workspace-b/model:high", availability: availabilityB)?.modelRaw,
            "workspace-b/model:high"
        )
    }

    func testPiDynamicModelStorePersistsSnapshot() throws {
        let suiteName = "PiModelCatalogTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let snapshot = Self.snapshot(
            rawValue: "zai/glm-5.1",
            displayName: "GLM 5.1",
            description: "Strong GLM",
            thinkingLevels: [.off, .low, .high]
        )

        PiDynamicModelStore.save(snapshot, defaults: defaults)
        let loaded = PiDynamicModelStore.load(defaults: defaults)

        XCTAssertEqual(loaded?.currentModelRaw, "zai/glm-5.1")
        XCTAssertEqual(loaded?.options.map(\.rawValue), ["default", "zai/glm-5.1"])
        XCTAssertEqual(loaded?.options.last?.description, "Strong GLM")
        XCTAssertEqual(loaded?.options.last?.supportedPiThinkingLevels, [.off, .low, .high])
    }

    func testPiDynamicModelStorePersistsWorkspaceSnapshotsWithoutGlobalFallback() throws {
        let suiteName = "PiModelCatalogTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let workspaceA = "/tmp/pi-cache-root/../pi-cache-root/workspace-a"
        let canonicalWorkspaceA = try XCTUnwrap(AgentPiModelRegistry.canonicalWorkspacePath(workspaceA))
        let workspaceB = "/tmp/pi-cache-root/workspace-b"
        let globalSnapshot = Self.snapshot(rawValue: "global/model", displayName: "Global Model")
        let snapshotA = Self.snapshot(rawValue: "workspace-a/model", displayName: "Workspace A Model")
        let snapshotB = Self.snapshot(rawValue: "workspace-b/model", displayName: "Workspace B Model")

        PiDynamicModelStore.save(globalSnapshot, defaults: defaults)
        PiDynamicModelStore.save(snapshotA, workspacePath: workspaceA, defaults: defaults)
        PiDynamicModelStore.save(snapshotB, workspacePath: workspaceB, defaults: defaults)

        XCTAssertEqual(PiDynamicModelStore.load(defaults: defaults), globalSnapshot)
        XCTAssertEqual(PiDynamicModelStore.load(workspacePath: canonicalWorkspaceA, defaults: defaults), snapshotA)
        XCTAssertEqual(PiDynamicModelStore.load(workspacePath: workspaceB, defaults: defaults), snapshotB)
        XCTAssertNil(PiDynamicModelStore.load(workspacePath: "/tmp/pi-cache-root/missing", defaults: defaults))
    }

    func testPiDynamicModelStoreConcurrentWorkspaceSavesPreserveSnapshots() throws {
        let suiteName = "PiModelCatalogTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let workspaceCount = 64

        DispatchQueue.concurrentPerform(iterations: workspaceCount) { index in
            let workspacePath = "/tmp/pi-concurrent-cache/workspace-\(index)"
            let snapshot = Self.snapshot(
                rawValue: "workspace-\(index)/model",
                displayName: "Workspace \(index) Model"
            )
            PiDynamicModelStore.save(snapshot, workspacePath: workspacePath, defaults: defaults)
        }

        for index in 0 ..< workspaceCount {
            let workspacePath = "/tmp/pi-concurrent-cache/workspace-\(index)"
            let loaded = PiDynamicModelStore.load(workspacePath: workspacePath, defaults: defaults)
            XCTAssertEqual(loaded?.currentModelRaw, "workspace-\(index)/model")
            XCTAssertEqual(loaded?.options.map(\.rawValue), ["default", "workspace-\(index)/model"])
        }
    }

    private static func snapshot(
        rawValue: String,
        displayName: String,
        description: String? = nil,
        thinkingLevels: [PiThinkingLevel] = []
    ) -> PiDiscoveredModels {
        PiDiscoveredModels(
            options: [
                AgentModelOption(rawValue: "default", displayName: "Default", description: nil, isDefault: true),
                AgentModelOption(
                    rawValue: rawValue,
                    displayName: displayName,
                    description: description,
                    isDefault: true,
                    supportedPiThinkingLevels: thinkingLevels
                )
            ],
            currentModelRaw: rawValue
        )
    }
}
