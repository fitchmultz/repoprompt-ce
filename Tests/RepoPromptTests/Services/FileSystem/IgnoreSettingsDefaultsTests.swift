@testable import RepoPrompt
import XCTest

final class IgnoreSettingsDefaultsTests: XCTestCase {
    func testFreshDefaultsUseShortCanonicalPatterns() {
        let defaults = makeDefaults()
        defer { removeDefaults(defaults) }

        let resolved = IgnoreSettingsDefaults.resolvedGlobalIgnoreDefaults(defaults: defaults)

        XCTAssertEqual(resolved, IgnoreSettingsDefaults.canonicalGlobalIgnoreDefaults)
        XCTAssertEqual(defaults.integer(forKey: IgnoreSettingsDefaults.globalIgnoreDefaultsVersionKey), 3)
        XCTAssertTrue(resolved.contains("node_modules/"))
        XCTAssertTrue(resolved.contains("*.tmp"))
        XCTAssertFalse(resolved.contains("**/node_modules/"))
        XCTAssertFalse(resolved.contains("**/*.tmp"))
    }

    func testV2DefaultsMigrateKnownLegacyPatternsAndPreserveCustomLines() {
        let defaults = makeDefaults()
        defer { removeDefaults(defaults) }
        defaults.set("""
        # RepoPrompt global ignore defaults (v2)
        **/node_modules/
        node_modules/
        # custom comment
        **/custom-cache/
        **/*.tmp
        *.tmp
        custom.log
        """, forKey: IgnoreSettingsDefaults.globalIgnoreDefaultsKey)
        defaults.set(2, forKey: IgnoreSettingsDefaults.globalIgnoreDefaultsVersionKey)

        let resolved = IgnoreSettingsDefaults.resolvedGlobalIgnoreDefaults(defaults: defaults)

        XCTAssertTrue(resolved.contains("# RepoPrompt global ignore defaults (v3)"))
        XCTAssertEqual(patternCount("node_modules/", in: resolved), 1)
        XCTAssertEqual(patternCount("*.tmp", in: resolved), 1)
        XCTAssertFalse(resolved.contains("**/node_modules/"))
        XCTAssertFalse(resolved.contains("**/*.tmp"))
        XCTAssertTrue(resolved.contains("# custom comment"))
        XCTAssertTrue(resolved.contains("**/custom-cache/"))
        XCTAssertTrue(resolved.contains("custom.log"))
        XCTAssertEqual(defaults.integer(forKey: IgnoreSettingsDefaults.globalIgnoreDefaultsVersionKey), 3)
        XCTAssertEqual(defaults.string(forKey: IgnoreSettingsDefaults.globalIgnoreDefaultsKey), resolved)
    }

    func testCurrentVersionDefaultsAreLeftUntouched() {
        let defaults = makeDefaults()
        defer { removeDefaults(defaults) }
        let custom = """
        # Custom current settings
        **/node_modules/
        custom.log
        """
        defaults.set(custom, forKey: IgnoreSettingsDefaults.globalIgnoreDefaultsKey)
        defaults.set(3, forKey: IgnoreSettingsDefaults.globalIgnoreDefaultsVersionKey)

        XCTAssertEqual(IgnoreSettingsDefaults.resolvedGlobalIgnoreDefaults(defaults: defaults), custom)
    }

    func testEmptyStoredDefaultsResetToCanonicalDefaults() {
        let defaults = makeDefaults()
        defer { removeDefaults(defaults) }
        defaults.set(" \n\t", forKey: IgnoreSettingsDefaults.globalIgnoreDefaultsKey)
        defaults.set(2, forKey: IgnoreSettingsDefaults.globalIgnoreDefaultsVersionKey)

        let resolved = IgnoreSettingsDefaults.resolvedGlobalIgnoreDefaults(defaults: defaults)

        XCTAssertEqual(resolved, IgnoreSettingsDefaults.canonicalGlobalIgnoreDefaults)
        XCTAssertEqual(defaults.integer(forKey: IgnoreSettingsDefaults.globalIgnoreDefaultsVersionKey), 3)
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "IgnoreSettingsDefaultsTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated defaults suite")
            return .standard
        }
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(suiteName, forKey: "suiteName")
        return defaults
    }

    private func removeDefaults(_ defaults: UserDefaults) {
        guard let suiteName = defaults.string(forKey: "suiteName") else { return }
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func patternCount(_ pattern: String, in text: String) -> Int {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .count(where: { $0 == pattern })
    }
}
