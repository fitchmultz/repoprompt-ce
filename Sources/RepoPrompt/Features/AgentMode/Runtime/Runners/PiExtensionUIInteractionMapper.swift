import Foundation

@MainActor
enum PiExtensionUIInteractionMapper {
    static func interaction(from request: PiRPCClient.PiExtensionUIRequest) -> AgentAskUserInteraction? {
        let timeoutSeconds = timeoutSeconds(from: request)
        let context = context(from: request)
        let title = request.title?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? "pi Extension Request"

        switch request.method {
        case "select":
            let options = options(from: request)
            guard !options.isEmpty else { return nil }
            return AgentAskUserInteraction(
                title: title,
                context: context,
                timeoutSeconds: timeoutSeconds,
                questions: [
                    AgentAskUserQuestion(
                        id: "value",
                        question: request.message?.nonEmpty ?? title,
                        options: options.map { AgentAskUserOption(label: $0) },
                        allowsMultiple: false,
                        allowsCustom: false
                    )
                ]
            )
        case "confirm":
            return AgentAskUserInteraction(
                title: title,
                context: context,
                timeoutSeconds: timeoutSeconds,
                questions: [
                    AgentAskUserQuestion(
                        id: "confirmed",
                        question: request.message?.nonEmpty ?? title,
                        options: [
                            AgentAskUserOption(label: "Yes"),
                            AgentAskUserOption(label: "No")
                        ],
                        allowsMultiple: false,
                        allowsCustom: false
                    )
                ]
            )
        case "input", "editor":
            let prompt = request.message?.nonEmpty ?? request.raw["placeholder"]?.stringValue?.nonEmpty ?? title
            return AgentAskUserInteraction(
                title: title,
                context: context,
                timeoutSeconds: timeoutSeconds,
                questions: [
                    AgentAskUserQuestion(
                        id: "value",
                        question: prompt,
                        context: prefillContext(from: request),
                        options: [],
                        allowsMultiple: false,
                        allowsCustom: true
                    )
                ]
            )
        default:
            return nil
        }
    }

    static func response(
        for request: PiRPCClient.PiExtensionUIRequest,
        from response: AgentAskUserResponse
    ) -> PiExtensionUIResponse {
        if response.timedOut || response.skipped {
            return .cancelled(id: request.id)
        }
        switch request.method {
        case "confirm":
            let answer = response.answersByQuestionID["confirmed"]?.answers.first?.lowercased()
            guard let answer else { return .cancelled(id: request.id) }
            return .confirmed(id: request.id, answer == "yes" || answer == "true" || answer == "allow")
        case "select", "input", "editor":
            guard let value = response.answersByQuestionID["value"]?.answers.first?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty
            else {
                return .cancelled(id: request.id)
            }
            return .value(id: request.id, value)
        default:
            return .cancelled(id: request.id)
        }
    }

    static func fireAndForgetStatusText(from request: PiRPCClient.PiExtensionUIRequest) -> String? {
        guard !request.requiresResponse else { return nil }
        switch request.method {
        case "notify":
            return request.message?.nonEmpty.map { "pi: \($0)" }
        case "setStatus":
            guard let statusText = request.statusText?.nonEmpty else { return nil }
            if let statusKey = request.statusKey?.nonEmpty {
                return "pi \(statusKey): \(statusText)"
            }
            return "pi: \(statusText)"
        case "setWidget":
            let lines = request.raw["widgetLines"]?.arrayValue?.compactMap(\.stringValue) ?? []
            return lines.first?.nonEmpty.map { "pi: \($0)" }
        default:
            return nil
        }
    }

    static func timeoutSeconds(from request: PiRPCClient.PiExtensionUIRequest) -> TimeInterval {
        guard let timeoutMS = request.raw["timeout"]?.intValue, timeoutMS > 0 else {
            return ContextBuilderDefaults.questionTimeoutSeconds
        }
        return max(1, TimeInterval(timeoutMS) / 1000.0)
    }

    static func options(from request: PiRPCClient.PiExtensionUIRequest) -> [String] {
        request.raw["options"]?.arrayValue?.compactMap { value in
            if let string = value.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !string.isEmpty {
                return string
            }
            if let object = value.objectValue {
                return object["label"]?.stringValue?.nonEmpty
                    ?? object["value"]?.stringValue?.nonEmpty
                    ?? object["title"]?.stringValue?.nonEmpty
            }
            return nil
        } ?? []
    }

    static func context(from request: PiRPCClient.PiExtensionUIRequest) -> String? {
        var lines: [String] = []
        if let message = request.message?.nonEmpty, message != request.title {
            lines.append(message)
        }
        if let statusText = request.statusText?.nonEmpty {
            lines.append(statusText)
        }
        lines.append("Requested by pi extension UI method: \(request.method).")
        return lines.joined(separator: "\n\n")
    }

    static func prefillContext(from request: PiRPCClient.PiExtensionUIRequest) -> String? {
        guard let prefill = request.raw["prefill"]?.stringValue?.nonEmpty else { return nil }
        return "Prefill from pi:\n\(prefill)"
    }
}

private extension String {
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
