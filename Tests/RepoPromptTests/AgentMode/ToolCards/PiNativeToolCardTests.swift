@testable import RepoPrompt
import XCTest

final class PiNativeToolCardTests: XCTestCase {
    func testReadCallSubtitleSupportsSnakeCaseFilePath() {
        XCTAssertEqual(
            ToolCardRouter.callSubtitle(for: "read", argsJSON: #"{"file_path":"Sources/App/Feature.swift"}"#),
            "...App/Feature.swift"
        )
    }

    func testWriteCallSubtitleShowsTargetPath() {
        XCTAssertEqual(
            ToolCardRouter.callSubtitle(for: "write", argsJSON: #"{"path":"crates/cueloop/src/commands/doctor/runner/mod.rs","content":"..."}"#),
            "...runner/mod.rs"
        )
    }

    func testEditCallSubtitleShowsTargetPath() {
        XCTAssertEqual(
            ToolCardRouter.callSubtitle(for: "edit", argsJSON: #"{"path":"crates/cueloop/src/cli/machine/task/followups.rs","edits":[]}"#),
            "...task/followups.rs"
        )
    }

    func testGrepFindAndListCallSubtitlesUsePiArgs() {
        XCTAssertEqual(
            ToolCardRouter.callSubtitle(for: "grep", argsJSON: #"{"pattern":"cursor-agents-context","path":"."}"#),
            #""cursor-agents-context" • ."#
        )
        XCTAssertEqual(
            ToolCardRouter.callSubtitle(for: "find", argsJSON: #"{"pattern":"**/*","path":"node_modules/@cursor/sdk"}"#),
            #""**/*" • ...@cursor/sdk"#
        )
        XCTAssertEqual(
            ToolCardRouter.callSubtitle(for: "ls", argsJSON: #"{"path":"/Users/mitchfultz/Projects/AI/pi-cursor-sdk","limit":5}"#),
            "...AI/pi-cursor-sdk"
        )
    }

    func testNamespacedWriteCallSubtitleShowsTargetPath() {
        XCTAssertEqual(
            ToolCardRouter.callSubtitle(for: "functions.write", argsJSON: #"{"file_path":"Sources/App/Feature.swift","content":"..."}"#),
            "...App/Feature.swift"
        )
    }

    func testUnknownWriteResultSubtitleIncludesPathAndStatus() {
        let item = AgentChatItem(
            kind: .toolResult,
            text: #"{"status":"success"}"#,
            toolName: "write",
            toolArgsJSON: #"{"path":"crates/cueloop/src/commands/doctor/runner/mod.rs","content":"..."}"#,
            toolResultJSON: #"{"status":"success"}"#,
            toolIsError: false
        )

        XCTAssertEqual(UnknownToolResultPresentation.subtitle(for: item), "...runner/mod.rs • success")
    }

    func testPiNativeWriteResultUsesExactSessionContentPayload() {
        let item = AgentChatItem.toolResult(
            name: "write",
            argsJSON: #"{"path":"crates/cueloop/src/commands/doctor/runner/mod.rs","content":"..."}"#,
            resultJSON: #"{"content":[{"type":"text","text":"Successfully wrote 42 bytes to crates/cueloop/src/commands/doctor/runner/mod.rs."}],"isError":false}"#,
            isError: false
        )

        let presentation = NativeToolCardPresentationBuilder.build(item: item, normalizedToolName: "write")

        XCTAssertEqual(presentation?.title, "Write")
        XCTAssertEqual(presentation?.inlineSummaryText, "…/runner/mod.rs • 42 bytes")
        XCTAssertEqual(presentation?.status, .success)
    }

    func testPiNativeGrepFindAndListResultSummariesUseExactSessionEnvelopeShape() {
        let grep = AgentChatItem.toolResult(
            name: "grep",
            argsJSON: #"{"pattern":"cursor-agents-context","path":".","limit":20}"#,
            resultJSON: #"{"content":[{"type":"text","text":"foo.swift:1:cursor-agents-context\nbar.swift:2:cursor-agents-context"}],"isError":false}"#,
            isError: false
        )
        let find = AgentChatItem.toolResult(
            name: "find",
            argsJSON: #"{"pattern":"**/*","path":"node_modules/@cursor/sdk","limit":20}"#,
            resultJSON: #"{"content":[{"type":"text","text":"node_modules/@cursor/sdk/README.md\nnode_modules/@cursor/sdk/package.json"}],"isError":false}"#,
            isError: false
        )
        let list = AgentChatItem.toolResult(
            name: "ls",
            argsJSON: #"{"path":"/Users/mitchfultz/Projects/AI/pi-cursor-sdk","limit":5}"#,
            resultJSON: #"{"content":[{"type":"text","text":"README.md\npackage.json\nsrc"}],"isError":false}"#,
            isError: false
        )

        XCTAssertEqual(
            NativeToolCardPresentationBuilder.build(item: grep, normalizedToolName: "grep")?.inlineSummaryText,
            #""cursor-agents-context" • . • 2 matches"#
        )
        XCTAssertEqual(
            NativeToolCardPresentationBuilder.build(item: find, normalizedToolName: "find")?.inlineSummaryText,
            #""**/*" • …/@cursor/sdk • 2 results"#
        )
        XCTAssertEqual(
            NativeToolCardPresentationBuilder.build(item: list, normalizedToolName: "ls")?.inlineSummaryText,
            "…/AI/pi-cursor-sdk • 3 entries"
        )
    }

    func testPiNativePersistencePreservesWriteAndGrepSummaries() {
        let write = AgentChatItem.toolResult(
            name: "functions.write",
            argsJSON: #"{"path":"crates/cueloop/src/commands/doctor/runner/mod.rs","content":"..."}"#,
            resultJSON: #"{"content":[{"type":"text","text":"Successfully wrote 42 bytes to crates/cueloop/src/commands/doctor/runner/mod.rs."}],"isError":false}"#,
            isError: false
        )
        let grep = AgentChatItem.toolResult(
            name: "grep",
            argsJSON: #"{"pattern":"cursor-agents-context","path":".","limit":20}"#,
            resultJSON: #"{"content":[{"type":"text","text":"foo.swift:1:cursor-agents-context\nbar.swift:2:cursor-agents-context"}],"isError":false}"#,
            isError: false
        )

        let sanitizedWrite = AgentToolResultPersistencePolicy.sanitizeItem(write)
        let sanitizedGrep = AgentToolResultPersistencePolicy.sanitizeItem(grep)

        XCTAssertEqual(
            NativeToolCardPresentationBuilder.build(item: sanitizedWrite, normalizedToolName: "write")?.inlineSummaryText,
            "…/runner/mod.rs • 42 bytes"
        )
        XCTAssertEqual(
            NativeToolCardPresentationBuilder.build(item: sanitizedGrep, normalizedToolName: "grep")?.inlineSummaryText,
            #""cursor-agents-context" • . • 2 matches"#
        )
        XCTAssertTrue(sanitizedWrite.toolResultJSON?.contains("\"tool_name\":\"write\"") == true)
        XCTAssertTrue(sanitizedGrep.toolResultJSON?.contains("\"tool_name\":\"grep\"") == true)

        let persistedGrep = AgentChatItemPersist(from: grep).toItem()
        XCTAssertEqual(
            NativeToolCardPresentationBuilder.build(item: persistedGrep, normalizedToolName: "grep")?.inlineSummaryText,
            #""cursor-agents-context" • . • 2 matches"#
        )
        XCTAssertTrue(persistedGrep.toolResultJSON?.contains("\"tool_name\":\"grep\"") == true)
        XCTAssertFalse(persistedGrep.toolResultJSON?.contains("\"tool_name\":\"file_search\"") == true)
    }

    func testPiNativePersistencePreservesNamespacedEditSummary() {
        let namespaced = AgentChatItem.toolResult(
            name: "functions.edit",
            argsJSON: #"{"path":"crates/cueloop/src/cli/machine/task/followups.rs","edits":[{"oldText":"use crate::queue;\n","newText":"use crate::queue::operations;\n"}]}"#,
            resultJSON: #"{"content":[{"type":"text","text":"Successfully replaced 1 block(s) in crates/cueloop/src/cli/machine/task/followups.rs."}],"details":{"patch":"--- crates/cueloop/src/cli/machine/task/followups.rs\n+++ crates/cueloop/src/cli/machine/task/followups.rs\n@@ -7,7 +7,7 @@\n-use crate::queue;\n+use crate::queue::operations;\n","firstChangedLine":10},"isError":false}"#,
            isError: false
        )

        let sanitized = AgentToolResultPersistencePolicy.sanitizeItem(namespaced)
        let presentation = CursorNativeEditResultPresentation.build(for: sanitized)

        XCTAssertEqual(presentation.summary, "followups.rs • 1 edit • +1 -1 lines")
        XCTAssertEqual(presentation.status, .success)
        XCTAssertEqual(presentation.diffs.count, 1)
    }

    func testPiNativeListSummaryTreatsNumericLimitDetailsAsWarning() {
        let item = AgentChatItem.toolResult(
            name: "ls",
            argsJSON: #"{"path":".","limit":5}"#,
            resultJSON: #"{"content":[{"type":"text","text":".cueloop/\n.cursor/\n\n[5 entries limit reached. Use limit=10 for more]"}],"details":{"entryLimitReached":5},"isError":false}"#,
            isError: false
        )

        let presentation = NativeToolCardPresentationBuilder.build(item: item, normalizedToolName: "ls")

        XCTAssertEqual(presentation?.inlineSummaryText, ". • 2 entries (limited)")
        XCTAssertEqual(presentation?.status, .warning)
    }

    func testPiNativeFindNoFilesFoundCountsAsZeroResults() {
        let item = AgentChatItem.toolResult(
            name: "find",
            argsJSON: #"{"pattern":"*.missing","path":"."}"#,
            resultJSON: #"{"content":[{"type":"text","text":"No files found matching pattern"}],"isError":false}"#,
            isError: false
        )

        XCTAssertEqual(
            NativeToolCardPresentationBuilder.build(item: item, normalizedToolName: "find")?.inlineSummaryText,
            #""*.missing" • . • 0 results"#
        )
    }

    func testPiNativeEditResultUsesExactSessionPatchPayload() {
        let item = piNativeEditItem()

        let presentation = CursorNativeEditResultPresentation.build(for: item)

        XCTAssertEqual(presentation.title, "Edit File")
        XCTAssertEqual(presentation.summary, "followups.rs • 2 edits • +1 -1 lines")
        XCTAssertEqual(presentation.status, .success)
        XCTAssertEqual(presentation.renderMode, .diffPreview)
        XCTAssertEqual(presentation.diffs.count, 1)
        XCTAssertEqual(presentation.diffs.first?.path, "crates/cueloop/src/cli/machine/task/followups.rs")
        XCTAssertTrue(presentation.diffs.first?.diff.contains("--- crates/cueloop/src/cli/machine/task/followups.rs") == true)
        XCTAssertTrue(presentation.diffs.first?.diff.contains("+use crate::queue::operations;") == true)
    }

    func testPiNativeEditSummaryPreservesPathAndPatchForPersistence() {
        let sanitized = AgentToolResultPersistencePolicy.sanitizeItem(piNativeEditItem())
        let presentation = CursorNativeEditResultPresentation.build(for: sanitized)

        XCTAssertEqual(presentation.summary, "followups.rs • 2 edits • +1 -1 lines")
        XCTAssertEqual(presentation.status, .success)
        XCTAssertEqual(presentation.diffs.count, 1)
        XCTAssertTrue(sanitized.toolResultJSON?.contains("\"summary_only\":true") == true)
        XCTAssertTrue(sanitized.toolResultJSON?.contains("\"unified_diff\"") == true)
    }

    func testPiNativeFailedEditResultStillShowsTargetPath() {
        let presentation = CursorNativeEditResultPresentation.build(for: piNativeFailedEditItem())

        XCTAssertEqual(presentation.summary, "lifecycle.rs • 3 edits")
        XCTAssertEqual(presentation.status, .failure)
        XCTAssertTrue(presentation.diffs.isEmpty)
    }

    func testPiNativeFailedEditSummaryPreservesPathForPersistence() {
        let sanitized = AgentToolResultPersistencePolicy.sanitizeItem(piNativeFailedEditItem())
        let presentation = CursorNativeEditResultPresentation.build(for: sanitized)

        XCTAssertEqual(presentation.summary, "lifecycle.rs • 3 edits")
        XCTAssertEqual(presentation.status, .failure)
        XCTAssertTrue(presentation.diffs.isEmpty)
    }

    private func piNativeEditItem() -> AgentChatItem {
        AgentChatItem.toolResult(
            name: "edit",
            argsJSON: #"{"path":"crates/cueloop/src/cli/machine/task/followups.rs","edits":[{"oldText":"use crate::queue;\n","newText":"use crate::queue::operations;\n"},{"oldText":"queue::complete_task(","newText":"operations::complete_active_task_to_archive("}]}"#,
            resultJSON: #"{"content":[{"type":"text","text":"Successfully replaced 2 block(s) in crates/cueloop/src/cli/machine/task/followups.rs."}],"details":{"diff":"     ...\n- 10 use crate::queue;\n+ 10 use crate::queue::operations;\n     ...","patch":"--- crates/cueloop/src/cli/machine/task/followups.rs\n+++ crates/cueloop/src/cli/machine/task/followups.rs\n@@ -7,7 +7,7 @@\n-use crate::queue;\n+use crate::queue::operations;\n","firstChangedLine":10},"isError":false}"#,
            isError: false
        )
    }

    private func piNativeFailedEditItem() -> AgentChatItem {
        AgentChatItem.toolResult(
            name: "edit",
            argsJSON: #"{"path":"crates/cueloop/src/queue/operations/lifecycle.rs","edits":[{"oldText":"old","newText":"new"},{"oldText":"old2","newText":"new2"},{"oldText":"old3","newText":"new3"}]}"#,
            resultJSON: #"{"content":[{"type":"text","text":"Could not find edits[2] in crates/cueloop/src/queue/operations/lifecycle.rs. The oldText must match exactly including all whitespace and newlines."}],"isError":true}"#,
            isError: true
        )
    }
}
