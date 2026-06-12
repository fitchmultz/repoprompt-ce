import Foundation
import SwiftUI

enum UnknownToolResultPresentation {
    static func subtitle(for item: AgentChatItem) -> String? {
        if let subtitle = StoredToolCardPresentation.fromSummaryOnly(raw: item.toolResultJSON)?.inlineSubtitle {
            return subtitle
        }
        if item.toolName?.caseInsensitiveCompare("subagent") == .orderedSame,
           let subtitle = SubagentToolPresentation.resultSubtitle(resultJSON: item.toolResultJSON)
        {
            return subtitle
        }
        let argsSubtitle = ToolCardRouter.callSubtitle(for: item.toolName, argsJSON: item.toolArgsJSON)
        guard let obj = ToolRawJSON.object(from: item.toolResultJSON) else { return argsSubtitle }
        if let status = ToolRawJSON.string(obj, key: "status"), !status.isEmpty {
            return inlineToolCardSummary(argsSubtitle, status)
        }
        if let error = ToolRawJSON.string(obj, key: "error"), !error.isEmpty {
            return inlineToolCardSummary(argsSubtitle, "error")
        }
        if item.toolIsError == true {
            return inlineToolCardSummary(argsSubtitle, "failed")
        }
        if item.toolIsError == false {
            return inlineToolCardSummary(argsSubtitle, "success")
        }
        return argsSubtitle
    }
}

struct UnknownToolResultCard: View {
    let item: AgentChatItem
    let title: String
    @State private var isExpanded = false

    private var status: ToolCardStatus {
        if item.toolName?.caseInsensitiveCompare("subagent") == .orderedSame {
            return SubagentToolPresentation.resultStatus(toolIsError: item.toolIsError, resultJSON: item.toolResultJSON)
        }
        return ToolResultStatusResolver.resolve(toolIsError: item.toolIsError, raw: item.toolResultJSON, fallback: .neutral)
    }

    private var subtitle: String? {
        UnknownToolResultPresentation.subtitle(for: item)
    }

    var body: some View {
        ToolCardContainer(
            iconName: toolIcon(for: item.toolName),
            iconColor: ToolCardAccentResolver.color(for: item.toolName),
            title: title,
            subtitle: subtitle,
            status: status,
            timestamp: item.timestamp,
            isExpandable: toolResultHasPayload(item),
            isExpanded: $isExpanded
        ) {
            ToolMarkdownExpandedContent(item: item)
        }
    }
}
