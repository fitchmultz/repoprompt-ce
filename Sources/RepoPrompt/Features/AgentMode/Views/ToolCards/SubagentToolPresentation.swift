import Foundation

enum SubagentToolPresentation {
    static func callSubtitle(argsJSON: String?) -> String? {
        guard let object = ToolRawJSON.object(from: argsJSON) else { return nil }
        if let agent = string(object, "agent") {
            return agent
        }
        if let tasks = object["tasks"] as? [Any], !tasks.isEmpty {
            return "\(tasks.count) task\(tasks.count == 1 ? "" : "s")"
        }
        if let chain = object["chain"] as? [Any], !chain.isEmpty {
            return "chain"
        }
        if let mode = string(object, "mode") {
            return mode
        }
        return nil
    }

    static func resultSubtitle(resultJSON: String?) -> String? {
        guard let object = ToolRawJSON.object(from: resultJSON) else { return nil }
        if let details = object["details"] as? [String: Any],
           let subtitle = detailsSubtitle(details)
        {
            return subtitle
        }
        if let content = object["content"] as? [[String: Any]],
           let text = content.compactMap({ string($0, "text") }).first
        {
            return abbreviate(firstLine(text), maxLength: 120)
        }
        if let status = string(object, "status") {
            return status
        }
        return nil
    }

    private static func detailsSubtitle(_ details: [String: Any]) -> String? {
        let runID = string(details, "runId")
        let mode = string(details, "mode")
        let results = details["results"] as? [[String: Any]]
        let first = results?.first
        let agent = first.flatMap { string($0, "agent") }
        let childCount = results?.count ?? 0

        var parts: [String] = []
        if let agent {
            parts.append(agent)
        } else if childCount > 0 {
            parts.append("\(childCount) child\(childCount == 1 ? "" : "ren")")
        }
        if let lifecycle = lifecycleStatus(results ?? []) {
            parts.append(lifecycle)
        } else if let mode {
            parts.append(mode)
        }
        if let runID {
            parts.append(runID)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " • ")
    }

    static func resultStatus(toolIsError: Bool?, resultJSON: String?, fallback: ToolCardStatus = .neutral) -> ToolCardStatus {
        guard let details = ToolRawJSON.object(from: resultJSON)?["details"] as? [String: Any],
              let results = details["results"] as? [[String: Any]],
              !results.isEmpty
        else {
            return ToolResultStatusResolver.resolve(toolIsError: toolIsError, raw: resultJSON, fallback: fallback)
        }
        if results.contains(where: { $0["timedOut"] as? Bool == true })
            || results.contains(where: { $0["interrupted"] as? Bool == true })
            || results.contains(where: { $0["resourceLimitExceeded"] is [String: Any] })
            || results.contains(where: { string($0, "error") != nil })
        {
            return .failure
        }
        let exitCodes = results.compactMap { $0["exitCode"] as? Int }
        if exitCodes.contains(where: { $0 > 0 }) {
            return .failure
        }
        if results.contains(where: { $0["detached"] as? Bool == true }) || exitCodes.contains(-1) {
            return .running
        }
        if !exitCodes.isEmpty, exitCodes.allSatisfy({ $0 == 0 }) {
            return .success
        }
        return ToolResultStatusResolver.resolve(toolIsError: toolIsError, raw: resultJSON, fallback: fallback)
    }

    private static func lifecycleStatus(_ results: [[String: Any]]) -> String? {
        guard !results.isEmpty else { return nil }
        switch resultStatus(toolIsError: nil, resultJSON: wrappedDetailsJSON(results: results), fallback: .neutral) {
        case .failure:
            if results.contains(where: { $0["timedOut"] as? Bool == true }) {
                return "timed out"
            }
            if results.contains(where: { $0["interrupted"] as? Bool == true }) {
                return "interrupted"
            }
            if results.contains(where: { $0["resourceLimitExceeded"] is [String: Any] }) {
                return "resource limit"
            }
            return "failed"
        case .running:
            if results.contains(where: { $0["detached"] as? Bool == true }) {
                return "detached"
            }
            return "running"
        case .success:
            return "completed"
        case .warning, .neutral:
            return nil
        }
    }

    private static func wrappedDetailsJSON(results: [[String: Any]]) -> String? {
        let object: [String: Any] = ["details": ["results": results]]
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object),
              let json = String(data: data, encoding: .utf8)
        else { return nil }
        return json
    }

    private static func string(_ object: [String: Any], _ key: String) -> String? {
        let trimmed = (object[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private static func firstLine(_ value: String) -> String {
        value.split(whereSeparator: \.isNewline).first.map(String.init) ?? value
    }

    private static func abbreviate(_ value: String, maxLength: Int) -> String {
        guard value.count > maxLength else { return value }
        return String(value.prefix(maxLength - 1)) + "…"
    }
}
