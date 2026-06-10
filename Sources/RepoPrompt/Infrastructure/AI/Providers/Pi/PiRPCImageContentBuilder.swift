import Foundation
import UniformTypeIdentifiers

enum PiRPCImageContentBuilder {
    static let maxImageBytes = 10 * 1024 * 1024

    enum Error: LocalizedError, Equatable {
        case unsupportedRemoteImageURL(String)
        case unreadableLocalImage(String)
        case localImageTooLarge(path: String, byteCount: Int, maxBytes: Int)

        var errorDescription: String? {
            switch self {
            case let .unsupportedRemoteImageURL(url):
                "pi RPC image attachments must be local files; remote image URLs are not sent silently. Save the image locally and attach it again: \(url)"
            case let .unreadableLocalImage(path):
                "Unable to read image attachment at \(path)."
            case let .localImageTooLarge(path, byteCount, maxBytes):
                "Image attachment at \(path) is too large for pi RPC (\(PiRPCImageContentBuilder.byteCountFormatter.string(fromByteCount: Int64(byteCount))) > \(PiRPCImageContentBuilder.byteCountFormatter.string(fromByteCount: Int64(maxBytes))))."
            }
        }
    }

    private static let byteCountFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    static func images(from attachments: [AgentImageAttachment]) throws -> [PiRPCClient.ImageContent] {
        try attachments.compactMap(image(from:))
    }

    private static func image(from attachment: AgentImageAttachment) throws -> PiRPCClient.ImageContent? {
        switch attachment.source {
        case let .localFile(rawPath):
            let path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty else { return nil }
            let url = URL(fileURLWithPath: path).standardizedFileURL
            return try image(fromLocalURL: url, attachmentTitle: attachment.title)
        case let .url(rawURL):
            let urlString = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !urlString.isEmpty else { return nil }
            guard let url = URL(string: urlString), url.isFileURL else {
                throw Error.unsupportedRemoteImageURL(urlString)
            }
            return try image(fromLocalURL: url.standardizedFileURL, attachmentTitle: attachment.title)
        }
    }

    private static func image(fromLocalURL url: URL, attachmentTitle: String?) throws -> PiRPCClient.ImageContent {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw Error.unreadableLocalImage(url.path)
        }
        guard data.count <= maxImageBytes else {
            throw Error.localImageTooLarge(path: url.path, byteCount: data.count, maxBytes: maxImageBytes)
        }
        return PiRPCClient.ImageContent(
            data: data.base64EncodedString(),
            mimeType: mimeType(forPathExtension: url.pathExtension, attachmentTitle: attachmentTitle)
        )
    }

    private static func mimeType(forPathExtension pathExtension: String?, attachmentTitle: String?) -> String {
        let candidates = [pathExtension, attachmentTitle.flatMap { URL(fileURLWithPath: $0).pathExtension }]
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
