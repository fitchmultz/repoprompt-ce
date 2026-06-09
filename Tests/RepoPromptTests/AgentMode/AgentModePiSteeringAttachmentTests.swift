@testable import RepoPrompt
import XCTest

final class AgentModePiSteeringAttachmentTests: XCTestCase {
    func testPiActiveSteeringAcceptsAndCarriesImageAttachments() throws {
        let viewModelURL = try RepoRoot.url()
            .appendingPathComponent("Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel.swift")
        let viewModelSource = try String(contentsOf: viewModelURL, encoding: .utf8)
        let availabilityBody = try sourceBody(
            named: "private func activePiSteerIsAvailable",
            in: viewModelSource
        )

        XCTAssertFalse(
            availabilityBody.contains("attachments.isEmpty"),
            "pi native steering must not reject image attachments once pi RPC image payloads are wired."
        )
        XCTAssertTrue(
            viewModelSource.contains("try await controller.steer(steering.providerText, images: images)"),
            "pi steering must forward converted image payloads to pi RPC."
        )

        let runnerURL = try RepoRoot.url()
            .appendingPathComponent("Sources/RepoPrompt/Features/AgentMode/Runtime/Runners/PiIntegratedAgentModeRunner.swift")
        let runnerSource = try String(contentsOf: runnerURL, encoding: .utf8)
        XCTAssertTrue(runnerSource.contains("PiRPCImageContentBuilder.images(from: attachments)"))
        XCTAssertTrue(runnerSource.contains("controller.sendUserMessage(initialMessageForRun, images: images)"))

        let sessionURL = try RepoRoot.url()
            .appendingPathComponent("Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel+TabSession.swift")
        let sessionSource = try String(contentsOf: sessionURL, encoding: .utf8)
        let instructionBody = try sourceBody(
            named: "struct PiSteeringInstruction",
            in: sessionSource
        )
        XCTAssertTrue(instructionBody.contains("let attachments: [AgentImageAttachment]"))
    }

    private func sourceBody(named marker: String, in source: String) throws -> String {
        let start = try XCTUnwrap(source.range(of: marker)?.lowerBound)
        var depth = 0
        var didEnterBody = false
        var index = start
        while index < source.endIndex {
            let character = source[index]
            if character == "{" {
                depth += 1
                didEnterBody = true
            } else if character == "}" {
                depth -= 1
                if didEnterBody, depth == 0 {
                    return String(source[start ... index])
                }
            }
            index = source.index(after: index)
        }
        XCTFail("Could not find source body for \(marker).")
        return ""
    }
}
