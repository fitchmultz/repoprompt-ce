import Foundation

struct PiExtensionUIResponse: Equatable {
    var id: String
    var value: String?
    var confirmed: Bool?
    var cancelled: Bool

    static func value(id: String, _ value: String) -> PiExtensionUIResponse {
        PiExtensionUIResponse(id: id, value: value, confirmed: nil, cancelled: false)
    }

    static func confirmed(id: String, _ confirmed: Bool) -> PiExtensionUIResponse {
        PiExtensionUIResponse(id: id, value: nil, confirmed: confirmed, cancelled: false)
    }

    static func cancelled(id: String) -> PiExtensionUIResponse {
        PiExtensionUIResponse(id: id, value: nil, confirmed: nil, cancelled: true)
    }

    var commandPayload: [String: PiJSONValue] {
        var payload: [String: PiJSONValue] = [
            "type": .string("extension_ui_response"),
            "id": .string(id)
        ]
        if let value {
            payload["value"] = .string(value)
        }
        if let confirmed {
            payload["confirmed"] = .bool(confirmed)
        }
        if cancelled {
            payload["cancelled"] = .bool(true)
        }
        return payload
    }
}

enum PiRPCLineData {
    static func trimmingASCIIWhitespaceAndNewlines(_ data: Data) -> Data {
        var start = data.startIndex
        var end = data.endIndex
        while start < end, isASCIIWhitespaceOrNewline(data[start]) {
            start = data.index(after: start)
        }
        while end > start {
            let beforeEnd = data.index(before: end)
            guard isASCIIWhitespaceOrNewline(data[beforeEnd]) else { break }
            end = beforeEnd
        }
        return data.subdata(in: start ..< end)
    }

    private static func isASCIIWhitespaceOrNewline(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }
}
