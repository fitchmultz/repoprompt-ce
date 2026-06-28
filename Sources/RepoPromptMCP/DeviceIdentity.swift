import Foundation

struct DeviceIdentity {
    static let shared = DeviceIdentity()
    let id: String

    private init() {
        let fm = FileManager.default
        let baseDir = MCPFilesystemConstants.identity.applicationSupportRootURL(fileManager: fm)
        let fileURL = baseDir.appendingPathComponent("device-id")
        let legacyFileURL = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.repoprompt", isDirectory: true)
            .appendingPathComponent("device-id")

        #if DEBUG
            fputs("CLI DeviceIdentity: Looking for device ID at: \(fileURL.path)\n", stderr)
        #endif

        try? fm.createDirectory(
            at: baseDir,
            withIntermediateDirectories: true
        )

        let readURL = fm.fileExists(atPath: fileURL.path) ? fileURL : legacyFileURL
        if let data = try? Data(contentsOf: readURL),
           let str = String(data: data, encoding: .utf8)?
           .trimmingCharacters(in: .whitespacesAndNewlines),
           !str.isEmpty
        {
            if readURL != fileURL, !fm.fileExists(atPath: fileURL.path) {
                try? data.write(to: fileURL, options: [.atomic])
            }
            id = str
            #if DEBUG
                fputs("CLI DeviceIdentity: Loaded existing device ID: \(str)\n", stderr)
            #endif
        } else {
            let newID = UUID().uuidString
            try? newID.data(using: .utf8)?
                .write(to: fileURL, options: [.atomic])
            id = newID
            #if DEBUG
                fputs("CLI DeviceIdentity: Created new device ID: \(newID)\n", stderr)
            #endif
        }
    }
}
