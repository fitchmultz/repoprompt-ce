import Foundation

extension PiNativeSessionController {
    struct PiUsage: Equatable {
        var promptTokens: Int
        var completionTokens: Int
        var contextUsedTokens: Int?
        var cost: Double?

        func streamResult(type: String, stopReason: String?) -> AIStreamResult {
            AIStreamResult(
                type: type,
                text: nil,
                promptTokens: promptTokens,
                completionTokens: completionTokens,
                cost: cost,
                stopReason: stopReason,
                contextUsedTokens: contextUsedTokens
            )
        }
    }

    static func streamResults(from event: PiRPCClient.PiAssistantMessageEvent) -> [AIStreamResult] {
        switch event.type {
        case "text_delta":
            guard let delta = event.delta, !delta.isEmpty else { return [] }
            return [AIStreamResult(type: "content", text: delta)]
        case "thinking_delta":
            guard let delta = event.delta, !delta.isEmpty else { return [] }
            return [AIStreamResult(type: "content", text: nil, reasoning: delta)]
        case "done":
            // pi finalizes assistant messages through message_end/turn_end. The
            // lower-level done delta can arrive before finalized usage, so do not
            // emit a RepoPrompt message_stop here.
            return []
        case "error":
            return [AIStreamResult(type: "error", text: event.reason ?? "pi message stream failed")]
        default:
            return []
        }
    }

    static func usage(from message: [String: PiJSONValue]?) -> PiUsage? {
        guard let message else { return nil }
        if let role = message["role"]?.stringValue,
           role != "assistant"
        {
            return nil
        }
        if let usageObject = message["usage"]?.objectValue {
            return usage(fromUsageObject: usageObject)
        }
        return usage(fromUsageObject: message)
    }

    static func latestUsage(from messages: [[String: PiJSONValue]]) -> PiUsage? {
        for message in messages.reversed() {
            if let usage = usage(from: message) {
                return usage
            }
        }
        return nil
    }

    static func usage(fromUsageObject usage: [String: PiJSONValue]) -> PiUsage? {
        let input = intValue(usage, keys: ["input", "inputTokens", "promptTokens"])
        let cacheRead = intValue(usage, keys: ["cacheRead", "cacheReadTokens"])
        let cacheWrite = intValue(usage, keys: ["cacheWrite", "cacheWriteTokens"])
        let output = intValue(usage, keys: ["output", "outputTokens", "completionTokens"])
        let total = intValue(usage, keys: ["totalTokens", "total"])
        let prompt = max(0, input ?? 0) + max(0, cacheRead ?? 0) + max(0, cacheWrite ?? 0)
        let completion = max(0, output ?? 0)
        let contextUsed = max(0, total ?? (prompt + completion))
        let cost = costValue(usage["cost"])
        guard prompt > 0 || completion > 0 || contextUsed > 0 || cost != nil else { return nil }
        return PiUsage(
            promptTokens: prompt,
            completionTokens: completion,
            contextUsedTokens: contextUsed > 0 ? contextUsed : nil,
            cost: cost
        )
    }

    static func intValue(_ object: [String: PiJSONValue], keys: [String]) -> Int? {
        for key in keys {
            if let value = object[key]?.intValue {
                return value
            }
        }
        return nil
    }

    static func costValue(_ value: PiJSONValue?) -> Double? {
        guard let value else { return nil }
        if let object = value.objectValue {
            return doubleValue(object["total"])
        }
        return doubleValue(value)
    }

    static func doubleValue(_ value: PiJSONValue?) -> Double? {
        guard let value else { return nil }
        switch value {
        case let .number(number):
            return number
        case let .string(string):
            return Double(string)
        default:
            return nil
        }
    }

    static func toolOutputText(from value: PiJSONValue?) -> String? {
        guard let value else { return nil }
        if let text = value.stringValue {
            return text
        }
        if let text = value.objectValue?["text"]?.stringValue {
            return text
        }
        if let content = value.objectValue?["content"]?.arrayValue {
            let parts = content.compactMap { entry -> String? in
                guard let object = entry.objectValue else { return nil }
                return object["text"]?.stringValue
            }
            if !parts.isEmpty {
                return parts.joined(separator: "\n")
            }
        }
        return jsonString(from: value)
    }

    static func toolResultJSON(from value: PiJSONValue?) -> String? {
        guard let value else { return nil }
        if let bridgePayload = bridgeToolResultPayload(from: value) {
            return bridgePayload
        }
        return jsonString(from: value)
    }

    static func bridgeToolResultPayload(from value: PiJSONValue) -> String? {
        guard let object = value.objectValue,
              let details = object["details"]?.objectValue,
              details["bridgeVersion"]?.stringValue != nil,
              let output = toolOutputText(from: value)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !output.isEmpty,
              let data = output.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data)) != nil
        else { return nil }
        return output
    }

    static func jsonString(from value: PiJSONValue) -> String? {
        guard JSONSerialization.isValidJSONObject(value.toAny()),
              let data = try? JSONSerialization.data(withJSONObject: value.toAny(), options: [.sortedKeys])
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func modelDisplayRaw(_ model: PiRPCClient.RemoteModel) -> String {
        if let provider = normalized(model.provider) {
            return "\(provider)/\(model.id)"
        }
        return model.id
    }

    func normalized(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else { return nil }
        guard trimmed.caseInsensitiveCompare(AgentModel.defaultModel.rawValue) != .orderedSame else { return nil }
        return trimmed
    }
}
