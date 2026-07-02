@testable import RepoPrompt
import XCTest

final class WorkspaceCodemapUIPresentationTests: XCTestCase {
    func testEmptyUIPresentationSnapshotPreservesPresentationCoverage() {
        let snapshot = WorkspaceCodemapUIPresentationSnapshot(.empty)

        XCTAssertTrue(snapshot.orderedEntries.isEmpty)
        XCTAssertTrue(snapshot.entriesByFileID.isEmpty)
        XCTAssertEqual(snapshot.coverage, .complete)
        XCTAssertTrue(snapshot.issues.isEmpty)
    }
}
