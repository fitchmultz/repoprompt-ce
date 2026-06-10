import Foundation

enum PiThinkingLevel: String, CaseIterable, Hashable, Codable {
    case off
    case minimal
    case low
    case medium
    case high
    case xhigh

    static let displayOrder: [PiThinkingLevel] = [.off, .minimal, .low, .medium, .high, .xhigh]
    static let standardModelOrder: [PiThinkingLevel] = [.off, .minimal, .low, .medium, .high]
    static let noOverrideDisplayName = "No Override"

    static func parse(_ raw: String?) -> PiThinkingLevel? {
        let normalized = raw?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
        guard let normalized, !normalized.isEmpty else { return nil }
        switch normalized {
        case "off", "none":
            return .off
        case "minimal":
            return .minimal
        case "low":
            return .low
        case "medium":
            return .medium
        case "high":
            return .high
        case "xhigh", "x-high", "extra-high", "extra high":
            return .xhigh
        default:
            return nil
        }
    }

    var displayName: String {
        switch self {
        case .off: "Off"
        case .minimal: "Minimal"
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        case .xhigh: "XHigh"
        }
    }
}
