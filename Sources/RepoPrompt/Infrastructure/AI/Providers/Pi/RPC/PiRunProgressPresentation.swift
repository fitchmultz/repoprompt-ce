import Foundation

enum PiRunProgressPresentation {
    static func toolStartStatus(toolName: String, args: [String: PiJSONValue]) -> String? {
        guard normalized(toolName) == "subagent" else { return nil }
        return "Subagent \(subagentTarget(from: args) ?? "run") started"
    }

    static func toolUpdateStatus(toolName: String, partialResult: PiJSONValue?) -> String? {
        guard normalized(toolName) == "subagent" else { return nil }
        if let details = partialResult?.objectValue?["details"]?.objectValue,
           let status = subagentStatus(fromDetails: details)
        {
            return status
        }
        return nil
    }

    static func toolEndStatus(toolName: String, result: PiJSONValue?, isError: Bool) -> String? {
        guard normalized(toolName) == "subagent" else { return nil }
        let prefix = "Subagent"
        guard let object = result?.objectValue else { return isError ? "\(prefix) failed" : "\(prefix) completed" }
        if let details = object["details"]?.objectValue,
           let status = subagentStatus(fromDetails: details)
        {
            return status
        }
        if isError {
            return "\(prefix) failed"
        }
        if isNonTerminalSubagentPlaceholder(object) {
            return "\(prefix) running"
        }
        if let text = firstContentLine(from: object), !text.isEmpty {
            return abbreviated(text, maxLength: 140)
        }
        return "\(prefix) completed"
    }

    static func customMessageStatus(_ message: PiRPCClient.PiCustomMessage) -> String? {
        guard message.display else { return nil }
        if message.customType == "subagent_control_notice",
           let details = message.details,
           let event = details["event"]?.objectValue
        {
            let agent = trimmed(event["agent"]?.stringValue)
            let messageText = trimmed(event["message"]?.stringValue)
            let currentTool = trimmed(event["currentTool"]?.stringValue)
            var parts: [String] = []
            if let agent {
                parts.append("Subagent \(agent) needs attention")
            } else {
                parts.append("Subagent needs attention")
            }
            if let messageText {
                parts.append(messageText)
            }
            if let currentTool {
                parts.append("tool: \(currentTool)")
            }
            return abbreviated(parts.joined(separator: " • "), maxLength: 180)
        }
        if let content = trimmed(message.content) {
            return abbreviated(firstLine(content), maxLength: 180)
        }
        return nil
    }

    private static func subagentStatus(fromDetails details: [String: PiJSONValue]) -> String? {
        let runID = trimmed(details["runId"]?.stringValue)
        let mode = trimmed(details["mode"]?.stringValue)
        let results = details["results"]?.arrayValue?.compactMap(\.objectValue) ?? []
        let firstResult = results.first
        let agent = trimmed(firstResult?["agent"]?.stringValue)
        let target = agent.map { "Subagent \($0)" } ?? "Subagent"
        var parts: [String] = [target]
        if let lifecycle = lifecycleStatus(from: results) {
            parts.append(lifecycle)
        } else if let mode {
            parts.append(mode)
        }
        if let runID {
            parts.append("run \(runID)")
        }
        return parts.joined(separator: " • ")
    }

    private static func lifecycleStatus(from results: [[String: PiJSONValue]]) -> String? {
        guard !results.isEmpty else { return nil }
        if results.contains(where: { $0["timedOut"]?.boolValue == true }) {
            return "timed out"
        }
        if results.contains(where: { $0["interrupted"]?.boolValue == true }) {
            return "interrupted"
        }
        if results.contains(where: { $0["resourceLimitExceeded"]?.objectValue != nil }) {
            return "resource limit"
        }
        if results.contains(where: { trimmed($0["error"]?.stringValue) != nil }) {
            return "failed"
        }
        let exitCodes = results.compactMap { $0["exitCode"]?.intValue }
        if exitCodes.contains(where: { $0 > 0 }) {
            return "failed"
        }
        if results.contains(where: { $0["detached"]?.boolValue == true }) {
            return "detached"
        }
        if exitCodes.contains(-1) {
            return "running"
        }
        if !exitCodes.isEmpty, exitCodes.allSatisfy({ $0 == 0 }) {
            return "completed"
        }
        return nil
    }

    private static func isNonTerminalSubagentPlaceholder(_ object: [String: PiJSONValue]) -> Bool {
        guard let status = trimmed(object["status"]?.stringValue)?.lowercased() else { return false }
        return ["unknown", "pending", "running", "in_progress", "active"].contains(status)
    }

    private static func subagentTarget(from args: [String: PiJSONValue]) -> String? {
        if let agent = trimmed(args["agent"]?.stringValue) {
            return agent
        }
        if let tasks = args["tasks"]?.arrayValue, !tasks.isEmpty {
            return "\(tasks.count) task\(tasks.count == 1 ? "" : "s")"
        }
        if let chain = args["chain"]?.arrayValue, !chain.isEmpty {
            return "chain"
        }
        return nil
    }

    private static func firstContentLine(from object: [String: PiJSONValue]) -> String? {
        guard let content = object["content"]?.arrayValue else { return nil }
        for entry in content {
            guard let text = trimmed(entry.objectValue?["text"]?.stringValue) else { continue }
            return firstLine(text)
        }
        return nil
    }

    private static func normalized(_ toolName: String) -> String {
        toolName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func trimmed(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private static func firstLine(_ value: String) -> String {
        value.split(whereSeparator: \.isNewline).first.map(String.init) ?? value
    }

    private static func abbreviated(_ value: String, maxLength: Int) -> String {
        guard value.count > maxLength else { return value }
        return String(value.prefix(maxLength - 1)) + "…"
    }
}
