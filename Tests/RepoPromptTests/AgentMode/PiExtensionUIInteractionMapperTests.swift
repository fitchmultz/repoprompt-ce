@testable import RepoPrompt
import XCTest

@MainActor
final class PiExtensionUIInteractionMapperTests: XCTestCase {
    func testSelectRequestMapsOptionsTimeoutAndContext() throws {
        let request = uiRequest(
            method: "select",
            title: "Choose",
            message: "Pick one",
            statusText: "Waiting",
            raw: [
                "timeout": .number(2500),
                "options": .array([
                    .string("Alpha"),
                    .object(["label": .string("Beta")]),
                    .object(["value": .string("Gamma")]),
                    .object(["title": .string("Delta")])
                ])
            ]
        )

        let interaction = try XCTUnwrap(PiExtensionUIInteractionMapper.interaction(from: request))

        XCTAssertEqual(interaction.title, "Choose")
        XCTAssertEqual(interaction.timeoutSeconds, 2.5)
        XCTAssertEqual(interaction.context, "Pick one\n\nWaiting\n\nRequested by pi extension UI method: select.")
        XCTAssertEqual(interaction.questions.first?.id, "value")
        XCTAssertEqual(interaction.questions.first?.question, "Pick one")
        XCTAssertEqual(interaction.questions.first?.options.map(\.label), ["Alpha", "Beta", "Gamma", "Delta"])
        XCTAssertEqual(interaction.questions.first?.allowsCustom, false)
    }

    func testInputRequestMapsPrefillAndCustomAnswer() throws {
        let request = uiRequest(
            method: "editor",
            title: "Edit",
            raw: [
                "placeholder": .string("Describe"),
                "prefill": .string("existing text")
            ]
        )

        let interaction = try XCTUnwrap(PiExtensionUIInteractionMapper.interaction(from: request))

        XCTAssertEqual(interaction.questions.first?.question, "Describe")
        XCTAssertEqual(interaction.questions.first?.context, "Prefill from pi:\nexisting text")
        XCTAssertEqual(interaction.questions.first?.allowsCustom, true)
    }

    func testResponsesMapConfirmValuesAndCancellation() {
        let confirmRequest = uiRequest(method: "confirm")
        XCTAssertEqual(
            PiExtensionUIInteractionMapper.response(
                for: confirmRequest,
                from: AgentAskUserResponse(
                    answersByQuestionID: ["confirmed": answer("Yes")],
                    timedOut: false,
                    skipped: false,
                    elapsedSeconds: 1
                )
            ),
            .confirmed(id: "ui-1", true)
        )

        let valueRequest = uiRequest(method: "input")
        XCTAssertEqual(
            PiExtensionUIInteractionMapper.response(
                for: valueRequest,
                from: AgentAskUserResponse(
                    answersByQuestionID: ["value": answer("  accepted  ")],
                    timedOut: false,
                    skipped: false,
                    elapsedSeconds: 1
                )
            ),
            .value(id: "ui-1", "accepted")
        )

        XCTAssertEqual(
            PiExtensionUIInteractionMapper.response(
                for: valueRequest,
                from: AgentAskUserResponse(answersByQuestionID: [:], timedOut: true, skipped: false, elapsedSeconds: 5)
            ),
            .cancelled(id: "ui-1")
        )
    }

    private func answer(_ value: String) -> AgentAskUserAnswer {
        AgentAskUserAnswer(
            answers: [value],
            selectedOptions: [value],
            customResponse: nil,
            skipped: false
        )
    }

    private func uiRequest(
        method: String,
        title: String? = nil,
        message: String? = nil,
        statusText: String? = nil,
        raw: [String: PiJSONValue] = [:]
    ) -> PiRPCClient.PiExtensionUIRequest {
        var requestRaw = raw
        requestRaw["id"] = .string("ui-1")
        requestRaw["method"] = .string(method)
        if let title { requestRaw["title"] = .string(title) }
        if let message { requestRaw["message"] = .string(message) }
        if let statusText { requestRaw["statusText"] = .string(statusText) }
        return PiRPCClient.PiExtensionUIRequest(
            id: "ui-1",
            method: method,
            title: title,
            message: message,
            statusKey: nil,
            statusText: statusText,
            raw: requestRaw
        )
    }
}
