import Foundation
import UniformTypeIdentifiers

enum PiRPCImageContentBuilder {
    enum Error: LocalizedError, Equatable {
        case unreadableLocalImage(String)

        var errorDescription: String? {
            switch self {
            case let .unreadableLocalImage(path):
                "Unable to read image attachment at \(path)."
            }
        }
    }

    static func images(from attachments: [AgentImageAttachment]) throws -> [PiRPCClient.ImageContent] {
        try attachments.compactMap(image(from:))
    }

    private static func image(from attachment: AgentImageAttachment) throws -> PiRPCClient.ImageContent? {
        switch attachment.source {
        case let .localFile(rawPath):
            let path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty else { return nil }
            let url = URL(fileURLWithPath: path).standardizedFileURL
            return try image(fromLocalURL: url, fallbackTitle: attachment.title)
        case let .url(rawURL):
            let urlString = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !urlString.isEmpty,
                  let url = URL(string: urlString),
                  url.isFileURL
            else {
                return nil
            }
            return try image(fromLocalURL: url.standardizedFileURL, fallbackTitle: attachment.title)
        }
    }

    private static func image(fromLocalURL url: URL, fallbackTitle: String?) throws -> PiRPCClient.ImageContent {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw Error.unreadableLocalImage(url.path)
        }
        return PiRPCClient.ImageContent(
            data: data.base64EncodedString(),
            mimeType: mimeType(forPathExtension: url.pathExtension, fallbackTitle: fallbackTitle)
        )
    }

    private static func mimeType(forPathExtension pathExtension: String?, fallbackTitle: String?) -> String {
        let candidates = [pathExtension, fallbackTitle.flatMap { URL(fileURLWithPath: $0).pathExtension }]
        for candidate in candidates {
            let ext = candidate?.trimmingCharacters(in: CharacterSet(charactersIn: ".").union(.whitespacesAndNewlines)) ?? ""
            guard !ext.isEmpty else { continue }
            if let mimeType = UTType(filenameExtension: ext)?.preferredMIMEType,
               mimeType.lowercased().hasPrefix("image/")
            {
                return mimeType
            }
        }
        return "image/png"
    }
}
