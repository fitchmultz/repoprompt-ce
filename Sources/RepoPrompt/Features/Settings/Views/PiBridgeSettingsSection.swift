import SwiftUI

struct PiBridgeSettingsSection: View {
    let status: PiRepoPromptBridgeExtensionInstaller.GlobalInstallationStatus
    let install: () -> Void
    let uninstall: () -> Void

    @ObservedObject private var fontScale = FontScaleManager.shared
    private var fontPreset: FontScalePreset {
        fontScale.preset
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("pi Bridge Extension")
                .font(fontPreset.subHeadlineBoldFont)

            HStack(alignment: .top, spacing: 10) {
                statusIcon
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 2) {
                    Text("~/.pi/agent/extensions/repoprompt-bridge.ts")
                        .font(.system(size: fontPreset.rawValue, design: .monospaced))
                        .fontWeight(.medium)
                    Text(statusText)
                        .font(fontPreset.captionFont)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)
                actionButton
            }

            Text("Optional for pi chats started outside RepoPrompt. RepoPrompt-managed Agent Mode runs inject a window-scoped bridge automatically; those managed runs expose RepoPrompt MCP tools and apply RepoPrompt's pi built-in preflight policy gate. The gate is not an OS sandbox.")
                .font(fontPreset.captionFont)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch status {
        case .installed:
            Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
        case .installedButStale:
            Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
        case .notInstalled:
            Image(systemName: "circle").foregroundColor(.secondary)
        case .installedByOther:
            Image(systemName: "xmark.circle.fill").foregroundColor(.red)
        }
    }

    private var statusText: String {
        switch status {
        case .installed:
            "Installed globally for pi"
        case .installedButStale:
            "Needs update"
        case .notInstalled:
            "Not installed"
        case .installedByOther:
            "A pi extension with the same name exists but is not managed by RepoPrompt"
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        switch status {
        case .notInstalled:
            Button("Install") { install() }.buttonStyle(CustomButtonStyle())
        case .installed:
            Button("Uninstall") { uninstall() }.buttonStyle(CustomButtonStyle())
        case .installedButStale:
            HStack(spacing: 6) {
                Button("Update") { install() }.buttonStyle(CustomButtonStyle())
                Button("Uninstall") { uninstall() }.buttonStyle(CustomButtonStyle())
            }
        case .installedByOther:
            EmptyView()
        }
    }
}
