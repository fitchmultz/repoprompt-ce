@testable import RepoPrompt
import XCTest

final class IgnoreRulesRecoveryTests: XCTestCase {
    override func tearDown() {
        IgnoreDebugMetricsRecorder.resetRecordingEnabledForTesting()
        super.tearDown()
    }

    func testSimplePatternFastPathPreservesGitignoreSemantics() {
        IgnoreDebugMetricsRecorder.setRecordingEnabledForTesting(true)
        let compiled = GitignoreCompiler.compile(content: """
        node_modules/
        *.tmp
        /config/local.json
        docs/cache/
        !important.tmp
        """)
        IgnoreDebugMetricsRecorder.reset()

        XCTAssertEqual(compiled.outcome(for: "node_modules", isDirectory: true), .ignore)
        XCTAssertEqual(compiled.outcome(for: "src/node_modules/pkg/index.js", isDirectory: false), .ignore)
        XCTAssertEqual(compiled.outcome(for: "node_modules.txt", isDirectory: false), .noMatch)
        XCTAssertEqual(compiled.outcome(for: "scratch.tmp", isDirectory: false), .ignore)
        XCTAssertEqual(compiled.outcome(for: "build/scratch.tmp", isDirectory: false), .ignore)
        XCTAssertEqual(compiled.outcome(for: "important.tmp", isDirectory: false), .allow)
        XCTAssertEqual(compiled.outcome(for: "config/local.json", isDirectory: false), .ignore)
        XCTAssertEqual(compiled.outcome(for: "src/config/local.json", isDirectory: false), .noMatch)
        XCTAssertEqual(compiled.outcome(for: "docs/cache/blob.bin", isDirectory: false), .ignore)
        XCTAssertEqual(compiled.outcome(for: "src/docs/cache/blob.bin", isDirectory: false), .noMatch)

        let metrics = IgnoreDebugMetricsRecorder.snapshot()
        XCTAssertLessThanOrEqual(metrics.maxPatternAttemptsPerOutcome, 1)
    }

    func testCompilerDistinguishesAnchoredDirectoryAndNegationPrecedence() {
        let compiled = GitignoreCompiler.compile(content: """
        /build/
        logs/
        !logs/keep.log
        """)

        XCTAssertEqual(compiled.outcome(for: "build", isDirectory: true), .ignore)
        XCTAssertEqual(compiled.outcome(for: "build/output.txt", isDirectory: false), .ignore)
        XCTAssertEqual(compiled.outcome(for: "src/build", isDirectory: true), .noMatch)

        XCTAssertEqual(compiled.outcome(for: "logs", isDirectory: true), .ignore)
        XCTAssertEqual(compiled.outcome(for: "src/logs/debug.log", isDirectory: false), .ignore)
        XCTAssertEqual(compiled.outcome(for: "logs/keep.log", isDirectory: false), .allow)
        XCTAssertTrue(compiled.requiresTraversal(for: "logs"))
    }
}
