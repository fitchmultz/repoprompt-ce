@testable import RepoPrompt
import XCTest

@MainActor
final class RecommendationProviderFilterNormalizationTests: XCTestCase {
    func testRecommendationProviderFilterNormalizationMatrix() {
        let currentAllProviders = Set(RecommendationProviderKind.allCases)
        XCTAssertTrue(currentAllProviders.contains(.pi))
        let rows: [(label: String, raw: [String], expected: Set<RecommendationProviderKind>)] = [
            ("removed-only", ["geminiCLI"], currentAllProviders),
            ("explicit-empty", [], []),
            ("legacy-all-providers", ["claudeCode", "codex", "openAI", "anthropic", "geminiCLI"], currentAllProviders),
            ("current-explicit-all-except-opencode", ["claudeCode", "codex", "cursor", "pi", "openAI"], [.claudeCode, .codex, .cursor, .pi, .openAI]),
            ("current-explicit-all-except-pi-opencode", ["claudeCode", "codex", "cursor", "openAI"], [.claudeCode, .codex, .cursor, .openAI]),
            ("pi-only", ["pi"], [.pi])
        ]

        for row in rows {
            XCTAssertEqual(
                GlobalSettingsStore.normalizedRecommendationProviderFilter(raw: row.raw),
                row.expected,
                row.label
            )
        }
    }

    func testPreOpenCodeAllProviderShapeMigratesOnlyAcrossSchemaUpdate() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecommendationProviderFilterNormalizationTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let fileURL = temp.appendingPathComponent("Settings/globalSettings.json")
        let fileStore = GlobalSettingsFileStore(fileURL: fileURL)
        let suiteName = "RecommendationProviderFilterNormalizationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var globalDefaults = GlobalDefaults(discoverAgentRaw: nil, discoverModelsByAgent: nil)
        globalDefaults.recommendationSchemaVersion = BestPracticeProfiles.versionCode - 1
        globalDefaults.recommendationProviderFilterRaw = ["claudeCode", "codex", "cursor", "pi", "openAI"]
        try fileStore.save(GlobalSettingsDocument(globalDefaults: globalDefaults))

        let store = GlobalSettingsStore(defaults: defaults, fileStore: fileStore)

        XCTAssertEqual(store.globalRecommendationProviderFilter(), Set(RecommendationProviderKind.allCases))
        XCTAssertNil(try fileStore.load().globalDefaults.recommendationProviderFilterRaw)
    }
}
