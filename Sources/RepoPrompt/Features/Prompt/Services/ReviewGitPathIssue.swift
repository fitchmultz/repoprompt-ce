import Foundation

struct WorkspaceSelectedGitPathResolution: Equatable {
    let paths: [String]
    let unresolvedCandidates: [String]
}

enum ReviewGitPathIssue: Equatable {
    case unresolvedSelection(displayPath: String)
    case noRepository(displayPath: String)
    case unsupportedBackend(displayPath: String, backendKind: VCSBackendKind)
    case invalidGitLayout(displayPath: String)
}

extension ReviewGitDisplayContext {
    func checkoutLabel(for checkoutRootPath: String) -> String {
        guard let root = longestMatchingRoot(for: checkoutRootPath) else { return "Checkout" }
        let relative = relativePath(checkoutRootPath, under: root.physicalRootPath)
        let base = sanitizedLabel(root.logicalRootName, fallback: "Workspace")
        return relative.isEmpty ? base : "\(base)/\(relative)"
    }

    func displayPath(for path: String, fallbackIndex: Int) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else {
            return sanitizedLabel(trimmed, fallback: "Selected path \(fallbackIndex)")
        }
        let standardized = StandardizedPath.absolute(trimmed)
        guard let root = longestMatchingRoot(for: standardized) else {
            return "Selected path \(fallbackIndex)"
        }
        let base = sanitizedLabel(root.logicalRootName, fallback: "Workspace")
        let relative = relativePath(standardized, under: root.physicalRootPath)
        return relative.isEmpty ? base : "\(base)/\(relative)"
    }

    private func longestMatchingRoot(for path: String) -> ReviewGitDisplayRoot? {
        let standardized = StandardizedPath.absolute(path)
        return roots
            .filter { StandardizedPath.isDescendant(standardized, of: $0.physicalRootPath) }
            .max { $0.physicalRootPath.count < $1.physicalRootPath.count }
    }

    private func relativePath(_ path: String, under rootPath: String) -> String {
        guard path != rootPath, path.hasPrefix(rootPath + "/") else { return "" }
        return String(path.dropFirst(rootPath.count + 1))
    }

    private func sanitizedLabel(_ label: String, fallback: String) -> String {
        let collapsed = label
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return collapsed.isEmpty ? fallback : collapsed
    }
}
