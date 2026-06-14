import Foundation

/// DEBUG_PROBE_HELPER_dbg-ce6c7bad-066c-4e29-b1c3-771083731d3b — temporary Debug Mode helper. Remove in cleanup.
enum DebugModeProbe {
    static let sessionId = "dbg-ce6c7bad-066c-4e29-b1c3-771083731d3b"
    private static let logPath = "/Users/mitchfultz/Projects/AI/repoprompt/repoprompt-ce-pi/.debug/dbg-ce6c7bad-066c-4e29-b1c3-771083731d3b.jsonl"
    private static let lock = NSLock()

    static func log(
        hypothesisId: String,
        location: String,
        message: String,
        data: [String: Any?] = [:]
    ) {
        var payload: [String: Any] = [
            "sessionId": sessionId,
            "hypothesisId": hypothesisId,
            "location": location,
            "timestamp": Int(Date().timeIntervalSince1970 * 1000),
            "level": "debug",
            "message": message
        ]
        if !data.isEmpty {
            payload["data"] = sanitize(data)
        }
        guard JSONSerialization.isValidJSONObject(payload),
              let encoded = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let line = String(data: encoded, encoding: .utf8)
        else {
            return
        }

        lock.lock()
        defer { lock.unlock() }
        let url = URL(fileURLWithPath: logPath)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: url.path), let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            try? handle.seekToEnd()
            try? handle.write(contentsOf: Data((line + "\n").utf8))
        } else {
            try? (line + "\n").write(to: url, atomically: true, encoding: .utf8)
        }
    }

    static func providerHistogram(rawModels: [String]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for rawModel in rawModels {
            let provider = rawModel.split(separator: "/", maxSplits: 1).first.map(String.init) ?? "<none>"
            counts[provider, default: 0] += 1
        }
        return counts
    }

    static func providerHistogram(remoteModels: [PiRPCClient.RemoteModel]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for model in remoteModels {
            let provider = model.provider?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                ? model.provider ?? "<none>"
                : model.id.split(separator: "/", maxSplits: 1).first.map(String.init) ?? "<none>"
            counts[provider, default: 0] += 1
        }
        return counts
    }

    static func optionSummary(_ options: [AgentModelOption]) -> [String: Any] {
        let raws = options.map(\.rawValue)
        return [
            "count": options.count,
            "providers": providerHistogram(rawModels: raws),
            "sample": Array(raws.prefix(8))
        ]
    }

    static func workspaceLabel(_ path: String?) -> String {
        guard let path, !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "<global>" }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    private static func sanitize(_ value: Any?) -> Any {
        guard let value else { return NSNull() }
        switch value {
        case let value as String:
            return value
        case let value as Bool:
            return value
        case let value as Int:
            return value
        case let value as Int64:
            return value
        case let value as Double:
            return value.isFinite ? value : String(describing: value)
        case let value as Float:
            return value.isFinite ? Double(value) : String(describing: value)
        case let value as [String: Any?]:
            return value.mapValues { sanitize($0) }
        case let value as [String: Any]:
            return value.mapValues { sanitize($0) }
        case let value as [Any?]:
            return value.map { sanitize($0) }
        case let value as [Any]:
            return value.map { sanitize($0) }
        default:
            return String(describing: value)
        }
    }
}
