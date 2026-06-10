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
        XCTAssertTrue(AgentModelCatalog.modelOptionIsSelected(
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

    func testPiDynamicModelStorePersistsSnapshot() throws {
        let suiteName = "PiModelCatalogTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let snapshot = PiDiscoveredModels(
            options: [
                AgentModelOption(rawValue: "default", displayName: "Default", description: nil, isDefault: true),
                AgentModelOption(
                    rawValue: "zai/glm-5.1",
                    displayName: "GLM 5.1",
                    description: "Strong GLM",
                    isDefault: true,
                    supportedPiThinkingLevels: [.off, .low, .high]
                )
            ],
            currentModelRaw: "zai/glm-5.1"
        )

        PiDynamicModelStore.save(snapshot, defaults: defaults)
        let loaded = PiDynamicModelStore.load(defaults: defaults)

        XCTAssertEqual(loaded?.currentModelRaw, "zai/glm-5.1")
        XCTAssertEqual(loaded?.options.map(\.rawValue), ["default", "zai/glm-5.1"])
        XCTAssertEqual(loaded?.options.last?.description, "Strong GLM")
        XCTAssertEqual(loaded?.options.last?.supportedPiThinkingLevels, [.off, .low, .high])
    }
}
