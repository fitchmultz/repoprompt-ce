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
                .init(provider: "zai", id: "glm-5.1", displayName: "GLM 5.1", description: "Strong GLM", raw: [:]),
                .init(provider: "cursor", id: "composer-2-5", displayName: "Composer 2.5", description: nil, raw: [:])
            ],
            currentModel: .init(provider: "zai", id: "glm-5.1", displayName: "GLM 5.1", description: nil, raw: [:])
        )

        XCTAssertNotNil(snapshot)
        XCTAssertTrue(try AgentPiModelRegistry.shared.updateDiscoveredModels(XCTUnwrap(snapshot)))
        let availability = AgentModelCatalog.AvailabilityContext(piAvailable: true)
        let options = AgentModelCatalog.options(for: .pi, availability: availability)

        XCTAssertEqual(options.map(\.rawValue), ["default", "zai/glm-5.1", "cursor/composer-2-5"])
        XCTAssertTrue(options[0].isPlaceholderDefault)
        XCTAssertTrue(options[1].isProviderDefault)
        XCTAssertEqual(AgentModelCatalog.displayName(for: "zai/glm-5.1", agentKind: .pi, availability: availability), "GLM 5.1")
        XCTAssertTrue(AgentModelCatalog.isValid(rawModel: "zai/glm-5.1", for: .pi, availability: availability))
        XCTAssertFalse(AgentModelCatalog.isValid(rawModel: "missing/model", for: .pi, availability: availability))
    }

    func testPiMenuGroupsDiscoveredModelsByProvider() {
        let menu = AgentModelCatalog.piMenu(for: [
            AgentModelOption(rawValue: "default", displayName: "Default", description: nil, isDefault: true),
            AgentModelOption(rawValue: "zai/glm-5.1", displayName: "GLM 5.1", description: nil, isDefault: true),
            AgentModelOption(rawValue: "cursor/composer-2-5", displayName: "Composer 2.5", description: nil, isDefault: false),
            AgentModelOption(rawValue: "openai/gpt-5.2", displayName: "GPT 5.2", description: nil, isDefault: false)
        ])

        XCTAssertEqual(menu.defaultOption?.rawValue, "default")
        XCTAssertEqual(menu.providerGroups.map(\.providerID), ["zai", "cursor", "openai"])
        XCTAssertEqual(menu.providerGroups.map(\.displayName), ["Z.ai", "Cursor", "OpenAI"])
        XCTAssertEqual(menu.providerGroups.first?.options.first?.displayName, "GLM 5.1")
    }

    func testPiDynamicModelStorePersistsSnapshot() throws {
        let suiteName = "PiModelCatalogTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let snapshot = PiDiscoveredModels(
            options: [
                AgentModelOption(rawValue: "default", displayName: "Default", description: nil, isDefault: true),
                AgentModelOption(rawValue: "zai/glm-5.1", displayName: "GLM 5.1", description: "Strong GLM", isDefault: true)
            ],
            currentModelRaw: "zai/glm-5.1"
        )

        PiDynamicModelStore.save(snapshot, defaults: defaults)
        let loaded = PiDynamicModelStore.load(defaults: defaults)

        XCTAssertEqual(loaded?.currentModelRaw, "zai/glm-5.1")
        XCTAssertEqual(loaded?.options.map(\.rawValue), ["default", "zai/glm-5.1"])
        XCTAssertEqual(loaded?.options.last?.description, "Strong GLM")
    }
}
