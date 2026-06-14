@_spi(TestSupport) @testable import RepoPrompt
import XCTest

@MainActor
final class AgentModePiModelPickerMenuTests: XCTestCase {
    func testInputBarPiMenuGroupsProviderThenModelWithoutThinkingLevelVariants() throws {
        let items = AgentModelStableMenuItems.modelItems(
            agentKind: .pi,
            options: [
                AgentModelOption(
                    rawValue: "zai/glm-5.2",
                    displayName: "GLM 5.2",
                    description: nil,
                    isDefault: false,
                    supportedPiThinkingLevels: [.off, .low, .medium, .high]
                ),
                AgentModelOption(
                    rawValue: "deepseek/deepseek-v4-pro",
                    displayName: "DeepSeek V4 Pro",
                    description: nil,
                    isDefault: false,
                    supportedPiThinkingLevels: [.off, .high]
                )
            ],
            selectedAgent: .claudeCode,
            selectedModelRaw: AgentModel.claudeOpus.rawValue,
            includePlaceholderDefault: false,
            includePiThinkingLevelOptions: false
        ) { _, _ in }

        XCTAssertEqual(items.map(\.title), ["DeepSeek", "Z.ai"])

        let deepSeekModels = try XCTUnwrap(items.first { $0.title == "DeepSeek" }?.testSubmenuItems)
        XCTAssertEqual(deepSeekModels.map(\.title), ["DeepSeek V4 Pro"])
        XCTAssertTrue(try XCTUnwrap(deepSeekModels.first).testIsAction)

        let zaiModels = try XCTUnwrap(items.first { $0.title == "Z.ai" }?.testSubmenuItems)
        XCTAssertEqual(zaiModels.map(\.title), ["GLM 5.2"])
        XCTAssertTrue(try XCTUnwrap(zaiModels.first).testIsAction)

        let flattenedTitles = flattenTitles(items)
        XCTAssertFalse(flattenedTitles.contains("Model Default"))
        XCTAssertFalse(flattenedTitles.contains("Off"))
        XCTAssertFalse(flattenedTitles.contains("Low"))
        XCTAssertFalse(flattenedTitles.contains("Medium"))
        XCTAssertFalse(flattenedTitles.contains("High"))
    }

    private func flattenTitles(_ items: [StableMenuItem]) -> [String] {
        items.flatMap { item -> [String] in
            [item.title] + flattenTitles(item.testSubmenuItems ?? [])
        }
    }
}
