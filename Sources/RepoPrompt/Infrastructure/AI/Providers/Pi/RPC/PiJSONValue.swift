import Foundation

enum PiJSONValue: Hashable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: PiJSONValue])
    case array([PiJSONValue])
    case null

    var stringValue: String? {
        if case let .string(value) = self { return value }
        return nil
    }

    var boolValue: Bool? {
        if case let .bool(value) = self { return value }
        return nil
    }

    var intValue: Int? {
        switch self {
        case let .number(value): Int(value)
        case let .string(value): Int(value)
        default: nil
        }
    }

    var objectValue: [String: PiJSONValue]? {
        if case let .object(value) = self { return value }
        return nil
    }

    var arrayValue: [PiJSONValue]? {
        if case let .array(value) = self { return value }
        return nil
    }

    func toAny() -> Any {
        switch self {
        case let .string(value): value
        case let .number(value): value
        case let .bool(value): value
        case let .object(value): value.mapValues { $0.toAny() }
        case let .array(value): value.map { $0.toAny() }
        case .null: NSNull()
        }
    }

    static func decodeObject(from data: Data) throws -> [String: PiJSONValue]? {
        let raw = try JSONSerialization.jsonObject(with: data, options: [])
        guard let object = raw as? [String: Any] else { return nil }
        return object.compactMapValues(Self.fromAny)
    }

    static func fromAny(_ value: Any) -> PiJSONValue? {
        switch value {
        case let string as String:
            return .string(string)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return .bool(number.boolValue)
            }
            return .number(number.doubleValue)
        case let object as [String: Any]:
            return .object(object.compactMapValues(Self.fromAny))
        case let array as [Any]:
            return .array(array.compactMap(Self.fromAny))
        case _ as NSNull:
            return .null
        default:
            return nil
        }
    }
}
