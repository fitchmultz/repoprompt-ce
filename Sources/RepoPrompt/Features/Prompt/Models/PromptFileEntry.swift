import Foundation

struct PromptFileEntry {
    let file: FileViewModel
    let codemap: WorkspaceCodemapUIPresentationEntry?
    let ranges: [LineRange]?
    private let legacyCodemapRequest: Bool

    var isCodemap: Bool {
        codemap != nil || legacyCodemapRequest
    }

    init(
        file: FileViewModel,
        codemap: WorkspaceCodemapUIPresentationEntry? = nil,
        ranges: [LineRange]? = nil
    ) {
        self.file = file
        self.codemap = codemap
        self.ranges = ranges
        legacyCodemapRequest = false
    }

    init(
        file: FileViewModel,
        isCodemap: Bool,
        ranges: [LineRange]? = nil
    ) {
        self.file = file
        codemap = nil
        self.ranges = ranges
        legacyCodemapRequest = isCodemap
    }
}
