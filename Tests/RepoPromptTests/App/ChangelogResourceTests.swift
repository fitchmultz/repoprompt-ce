import Foundation
@testable import RepoPrompt
import XCTest

final class ChangelogResourceTests: XCTestCase {
    func testBundledChangelogLoadsAsMarkdown() {
        let changelog = Changelog.fullChangelog
        XCTAssertFalse(changelog.isEmpty)
        XCTAssertTrue(changelog.hasPrefix("## [\(Changelog.current.id)]"))
        XCTAssertFalse(changelog.hasPrefix("    "))
        XCTAssertFalse(changelog.contains("\n            ## ["))
        XCTAssertTrue(changelog.contains("\n---\n## Version "))
    }
}
