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
                .init(provider: "anthropic", id: "claude-opus-4-6", displayName: "Claude Opus 4.6", description: nil, raw: ["reasoning": .bool(false)]),
                .init(provider: nil, id: "deepseek/deepseek-v4-pro", displayName: "DeepSeek V4 Pro", description: nil, raw: ["reasoning": .bool(true)]),
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

        XCTAssertEqual(options.map(\.rawValue), ["deepseek/deepseek-v4-pro", "openai-codex/gpt-5.5", "zai/glm-5.1"])
        XCTAssertFalse(options.contains { $0.rawValue == "anthropic/claude-opus-4-6" })
        XCTAssertFalse(options.contains(where: \.isPlaceholderDefault))
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

    func testUnsupportedProviderRefreshClearsStalePiModels() {
        let supportedSnapshot = Self.snapshot(rawValue: "openai-codex/gpt-5.5", displayName: "GPT 5.5")
        XCTAssertTrue(AgentPiModelRegistry.shared.updateDiscoveredModels(supportedSnapshot))
        XCTAssertEqual(
            AgentModelCatalog.options(for: .pi, availability: .init(piAvailable: true)).map(\.rawValue),
            ["openai-codex/gpt-5.5"]
        )

        let unsupportedSnapshot = PiDiscoveredModels(
            options: [
                AgentModelOption(
                    rawValue: "anthropic/claude-opus-4-6",
                    displayName: "Claude Opus 4.6",
                    description: nil,
                    isDefault: true
                )
            ],
            currentModelRaw: "anthropic/claude-opus-4-6"
        )
        XCTAssertTrue(AgentPiModelRegistry.shared.updateDiscoveredModels(unsupportedSnapshot))
        XCTAssertEqual(AgentModelCatalog.options(for: .pi, availability: .init(piAvailable: true)), [])
        XCTAssertNil(AgentPiModelRegistry.shared.resolvedSnapshot())
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
            ["openai-codex/gpt-5.5"]
        )
    }

    func testPiModelSpecifierUsesStrictCanonicalThinkingSuffixesAndKnownModelPrecedence() throws {
        let rawModel = "openai-codex/gpt-5.5"
        let snapshot = AgentPiModelRegistry.discoveredModels(
            from: [
                .init(provider: "openai-codex", id: "gpt-5.5", displayName: "GPT 5.5", description: nil, raw: [
                    "reasoning": .bool(true),
                    "thinkingLevelMap": .object(["minimal": .null, "xhigh": .string("xhigh")])
                ])
            ],
            currentModel: nil
        )

        XCTAssertNotNil(snapshot)
        XCTAssertTrue(try AgentPiModelRegistry.shared.updateDiscoveredModels(XCTUnwrap(snapshot)))
        let availability = AgentModelCatalog.AvailabilityContext(piAvailable: true)

        XCTAssertTrue(AgentModelCatalog.isValid(rawModel: rawModel, for: .pi, availability: availability))
        XCTAssertTrue(AgentModelCatalog.isValid(rawModel: "openai-codex/gpt-5.5:high", for: .pi, availability: availability))
        XCTAssertFalse(AgentModelCatalog.isValid(
            rawModel: "openai-codex/gpt-5.5:none",
            for: .pi,
            availability: availability
        ))
        XCTAssertFalse(AgentModelCatalog.isValid(
            rawModel: "openai-codex/gpt-5.5:x-high",
            for: .pi,
            availability: availability
        ))
        XCTAssertFalse(AgentModelCatalog.isValid(
            rawModel: "deepseek/deepseek-v4-flash:high",
            for: .pi,
            availability: availability
        ))
        XCTAssertEqual(AgentModelCatalog.piThinkingLevelOptions(for: rawModel), [.off, .low, .medium, .high, .xhigh])
    }

    func testKnownSupportedPiModelResolvesAcrossPickerMenuAndDisplayPaths() throws {
        let workspace = "/tmp/pi-known-supported-workspace"
        let rawModel = "deepseek/deepseek-v4-flash"
        let snapshot = Self.snapshot(
            rawValue: rawModel,
            displayName: "DeepSeek V4 Flash",
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
            "DeepSeek V4 Flash"
        )
        XCTAssertEqual(
            AgentModelCatalog.qualifiedDisplayName(for: rawModel, agentKind: .pi, availability: availability),
            "pi · DeepSeek · DeepSeek V4 Flash"
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
        let specifier = try XCTUnwrap(PiModelSpecifier(raw: "deepseek/deepseek-v4-flash:high", knownModelIDs: []))

        XCTAssertEqual(specifier.providerQualifiedModelRaw, "deepseek/deepseek-v4-flash")
        XCTAssertEqual(specifier.thinkingLevel, "high")
    }

    func testSupportedPiModelSupportsThinkingVariants() throws {
        let rawModel = "deepseek/deepseek-v4-pro"
        let snapshot = AgentPiModelRegistry.discoveredModels(
            from: [
                .init(
                    provider: "deepseek",
                    id: "deepseek-v4-pro",
                    displayName: "DeepSeek V4 Pro",
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
            "DeepSeek V4 Pro High"
        )

        let menu = AgentModelCatalog.piMenu(
            for: AgentModelCatalog.options(for: .pi, availability: availability),
            includeThinkingLevelOptions: true
        )
        let group = try XCTUnwrap(menu.providerGroups.first?.groups.first)
        XCTAssertEqual(group.displayName, "DeepSeek V4 Pro")
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
            AgentModelOption(rawValue: "zai/glm-5.1", displayName: "GLM 5.1", description: nil, isDefault: true),
            AgentModelOption(rawValue: "deepseek/deepseek-v4-flash", displayName: "DeepSeek V4 Flash", description: nil, isDefault: false),
            AgentModelOption(rawValue: "openai-codex/gpt-5.5", displayName: "GPT 5.5", description: nil, isDefault: false)
        ])

        XCTAssertNil(menu.defaultOption)
        XCTAssertEqual(menu.providerGroups.map(\.providerID), ["deepseek", "openai-codex", "zai"])
        XCTAssertEqual(menu.providerGroups.map(\.displayName), ["DeepSeek", "OpenAI Codex", "Z.ai"])
        XCTAssertEqual(menu.providerGroups[0].options.first?.displayName, "DeepSeek V4 Flash")
        XCTAssertEqual(menu.providerGroups[1].options.first?.displayName, "GPT 5.5")
        XCTAssertEqual(menu.providerGroups[2].options.first?.displayName, "GLM 5.1")
    }

    func testPiMenuStripsProviderPrefixFromRawQualifiedDisplayNames() {
        let menu = AgentModelCatalog.piMenu(for: [
            AgentModelOption(rawValue: "deepseek/deepseek-v4-flash", displayName: "deepseek/deepseek-v4-flash", description: nil, isDefault: false),
            AgentModelOption(rawValue: "openai-codex/gpt-5.5", displayName: "openai-codex/gpt-5.5", description: nil, isDefault: false)
        ])

        XCTAssertEqual(menu.providerGroups.map(\.displayName), ["DeepSeek", "OpenAI Codex"])
        XCTAssertEqual(menu.providerGroups[0].options.map(\.displayName), ["DeepSeek V4 Flash"])
        XCTAssertEqual(menu.providerGroups[1].options.map(\.displayName), ["GPT 5.5"])
    }

    func testPiMenuGroupsThinkingVariantsUnderBaseModel() {
        let menu = AgentModelCatalog.piMenu(for: [
            AgentModelOption(rawValue: "openai-codex/gpt-5.5", displayName: "openai-codex/gpt-5.5", description: nil, isDefault: false),
            AgentModelOption(rawValue: "openai-codex/gpt-5.5:low", displayName: "openai-codex/gpt-5.5:low", description: nil, isDefault: false),
            AgentModelOption(rawValue: "openai-codex/gpt-5.5:high", displayName: "openai-codex/gpt-5.5:high", description: nil, isDefault: false),
            AgentModelOption(rawValue: "zai/glm-5.1:medium", displayName: "GLM 5.1 Medium", description: nil, isDefault: false)
        ])

        XCTAssertEqual(menu.providerGroups.map(\.displayName), ["OpenAI Codex", "Z.ai"])
        XCTAssertEqual(menu.providerGroups[0].groups.map(\.displayName), ["GPT 5.5"])
        XCTAssertTrue(menu.providerGroups[0].groups[0].rendersAsSubmenu)
        XCTAssertEqual(menu.providerGroups[0].groups[0].options.map(\.displayName), ["Model Default", "Low", "High"])
        XCTAssertEqual(menu.providerGroups[1].groups.map(\.displayName), ["GLM 5.1"])
        XCTAssertEqual(menu.providerGroups[1].groups[0].options.map(\.displayName), ["Medium"])
    }

    func testPiMenuSynthesizesThinkingVariantsOnlyWhenRequested() throws {
        let options = [
            AgentModelOption(
                rawValue: "openai-codex/gpt-5.5",
                displayName: "GPT 5.5",
                description: nil,
                isDefault: false,
                supportedPiThinkingLevels: [.off, .low, .high]
            ),
            AgentModelOption(
                rawValue: "zai/glm-5.1",
                displayName: "GLM 5.1",
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
        XCTAssertNil(combinedMenu.defaultOption)
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

        let zaiGroup = combinedMenu.providerGroups
            .first { $0.displayName == "Z.ai" }?
            .groups.first
        XCTAssertEqual(zaiGroup?.options.map(\.option.rawValue), ["zai/glm-5.1"])
        XCTAssertFalse(zaiGroup?.rendersAsSubmenu ?? true)
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
        let snapshotA = Self.snapshot(rawValue: "openai-codex/gpt-5.4", displayName: "GPT 5.4")
        let snapshotB = Self.snapshot(rawValue: "deepseek/deepseek-v4-flash", displayName: "DeepSeek V4 Flash")

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

        XCTAssertEqual(optionsA.map(\.rawValue), ["openai-codex/gpt-5.4"])
        XCTAssertEqual(optionsB.map(\.rawValue), ["deepseek/deepseek-v4-flash"])
        XCTAssertEqual(
            AgentModelCatalog.piThinkingLevelOptions(for: "openai-codex/gpt-5.4", workspacePath: workspaceB),
            []
        )
    }

    func testWorkspaceScopedPiModelResolutionUsesAvailabilityWorkspacePath() {
        let workspaceA = "/tmp/pi-model-resolution-workspace-a"
        let workspaceB = "/tmp/pi-model-resolution-workspace-b"
        let snapshotA = Self.snapshot(
            rawValue: "openai-codex/gpt-5.4",
            displayName: "GPT 5.4",
            thinkingLevels: [.off, .low]
        )
        let snapshotB = Self.snapshot(
            rawValue: "deepseek/deepseek-v4-flash",
            displayName: "DeepSeek V4 Flash",
            thinkingLevels: [.off, .high]
        )
        XCTAssertTrue(AgentPiModelRegistry.shared.updateDiscoveredModels(snapshotA, workspacePath: workspaceA))
        XCTAssertTrue(AgentPiModelRegistry.shared.updateDiscoveredModels(snapshotB, workspacePath: workspaceB))
        let availabilityA = AgentModelCatalog.AvailabilityContext(piAvailable: true, piWorkspacePath: workspaceA)
        let availabilityB = AgentModelCatalog.AvailabilityContext(piAvailable: true, piWorkspacePath: workspaceB)

        XCTAssertEqual(
            AgentModelCatalog.modelOption(matching: "openai-codex/gpt-5.4", for: .pi, availability: availabilityA)?.displayName,
            "GPT 5.4"
        )
        XCTAssertNil(AgentModelCatalog.modelOption(matching: "openai-codex/gpt-5.4", for: .pi, availability: availabilityB))
        XCTAssertTrue(AgentModelCatalog.isValid(rawModel: "deepseek/deepseek-v4-flash:high", for: .pi, availability: availabilityB))
        XCTAssertFalse(AgentModelCatalog.isValid(rawModel: "deepseek/deepseek-v4-flash:high", for: .pi, availability: availabilityA))
        XCTAssertEqual(
            AgentModelCatalog.displayName(for: "deepseek/deepseek-v4-flash:high", agentKind: .pi, availability: availabilityB),
            "DeepSeek V4 Flash High"
        )
        XCTAssertEqual(
            AgentModelCatalog.resolveSelectionID("pi:deepseek/deepseek-v4-flash:high", availability: availabilityB)?.modelRaw,
            "deepseek/deepseek-v4-flash:high"
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
        XCTAssertEqual(loaded?.options.map(\.rawValue), ["zai/glm-5.1"])
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
        let globalSnapshot = Self.snapshot(rawValue: "openai-codex/gpt-5.4-mini", displayName: "GPT 5.4 Mini")
        let snapshotA = Self.snapshot(rawValue: "openai-codex/gpt-5.4", displayName: "GPT 5.4")
        let snapshotB = Self.snapshot(rawValue: "deepseek/deepseek-v4-flash", displayName: "DeepSeek V4 Flash")

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
        let modelIDs = [
            "openai-codex/gpt-5.4",
            "openai-codex/gpt-5.4-mini",
            "openai-codex/gpt-5.5",
            "zai/glm-5.1",
            "deepseek/deepseek-v4-flash",
            "deepseek/deepseek-v4-pro"
        ]
        let workspaceCount = 64

        DispatchQueue.concurrentPerform(iterations: workspaceCount) { index in
            let workspacePath = "/tmp/pi-concurrent-cache/workspace-\(index)"
            let rawValue = modelIDs[index % modelIDs.count]
            let snapshot = Self.snapshot(
                rawValue: rawValue,
                displayName: "Concurrent Model \(index)"
            )
            PiDynamicModelStore.save(snapshot, workspacePath: workspacePath, defaults: defaults)
        }

        for index in 0 ..< workspaceCount {
            let workspacePath = "/tmp/pi-concurrent-cache/workspace-\(index)"
            let rawValue = modelIDs[index % modelIDs.count]
            let loaded = PiDynamicModelStore.load(workspacePath: workspacePath, defaults: defaults)
            XCTAssertEqual(loaded?.currentModelRaw, rawValue)
            XCTAssertEqual(loaded?.options.map(\.rawValue), [rawValue])
            XCTAssertEqual(loaded?.options.last?.displayName, "Concurrent Model \(index)")
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
