@testable import RepoPrompt
import XCTest

final class SubagentToolCardTests: XCTestCase {
    func testSubagentCallSubtitleShowsAgentName() {
        XCTAssertEqual(
            SubagentToolPresentation.callSubtitle(argsJSON: #"{"agent":"worker","task":"Implement"}"#),
            "worker"
        )
    }

    func testSubagentResultSubtitleShowsDetachedRunDetails() {
        let raw = #"""
        {
          "content": [{"type":"text","text":"Detached for intercom coordination: worker."}],
          "details": {
            "mode": "single",
            "runId": "7bee22c2",
            "results": [{"agent":"worker","exitCode":0,"detached":true}]
          }
        }
        """#

        XCTAssertEqual(
            SubagentToolPresentation.resultSubtitle(resultJSON: raw),
            "worker • detached • 7bee22c2"
        )
        XCTAssertEqual(
            SubagentToolPresentation.resultStatus(toolIsError: false, resultJSON: raw),
            .running
        )
    }

    func testSubagentResultSubtitleDerivesLifecycleFromExitCode() {
        let raw = #"""
        {
          "details": {
            "mode": "single",
            "runId": "d2dae90b",
            "results": [{"agent":"planner","exitCode":0}]
          }
        }
        """#

        XCTAssertEqual(
            SubagentToolPresentation.resultSubtitle(resultJSON: raw),
            "planner • completed • d2dae90b"
        )
    }

    func testSubagentResultSubtitleDerivesFailureLifecycle() {
        let raw = #"""
        {
          "details": {
            "mode": "single",
            "runId": "badc0de",
            "results": [{"agent":"worker","exitCode":1}]
          }
        }
        """#

        XCTAssertEqual(
            SubagentToolPresentation.resultSubtitle(resultJSON: raw),
            "worker • failed • badc0de"
        )
        XCTAssertEqual(
            SubagentToolPresentation.resultStatus(toolIsError: false, resultJSON: raw),
            .failure
        )
    }

    func testSubagentResultSubtitleTreatsExitCodeMinusOneAsRunning() {
        let raw = #"""
        {
          "details": {
            "mode": "parallel",
            "runId": "1234abcd",
            "results": [
              {"agent":"worker","exitCode":0},
              {"agent":"reviewer","exitCode":-1}
            ]
          }
        }
        """#

        XCTAssertEqual(
            SubagentToolPresentation.resultSubtitle(resultJSON: raw),
            "worker • running • 1234abcd"
        )
        XCTAssertEqual(
            SubagentToolPresentation.resultStatus(toolIsError: false, resultJSON: raw),
            .running
        )
    }
}
