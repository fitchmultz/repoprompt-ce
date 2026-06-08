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
            ("current-explicit-all-except-pi", ["claudeCode", "codex", "cursor", "openAI"], [.claudeCode, .codex, .cursor, .openAI]),
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
}
