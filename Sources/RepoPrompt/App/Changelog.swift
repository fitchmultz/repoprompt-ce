//
//  Changelog.swift
import Foundation
import SwiftUI

struct Version {
    let id: String
    let buildNumber: Int
    let date: Date
}

enum Changelog {
    static let current = Version(
        id: "2.1.24",
        buildNumber: 326,
        date: ISO8601DateFormatter().date(from: "2026-05-09T00:00:00Z") ?? Date()
    )

    static var currentVersionString: String {
        current.buildNumber == 1 ? current.id : "\(current.id) (\(current.buildNumber))"
    }

    static var currentVersionStringLabel: String {
        current.id
    }

    static var fullChangelog: String {
        guard let url = Bundle.module.url(forResource: "CHANGELOG", withExtension: "md"),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else {
            assertionFailure("Missing bundled CHANGELOG.md resource")
            return ""
        }
        return text
    }
}

class VersionManager: ObservableObject {
    @Published var shouldShowVersionPopup = false
    @Published var shouldShowWelcomeView = false
    @Published var shouldShowVersionButton = false

    func showChangelog() {
        shouldShowVersionPopup = true
    }

    func dismissVersionButton() {
        shouldShowVersionButton = false
        // Store that we've dismissed the button for this version
        UserDefaults.standard.set(Self.currentBuildNumber, forKey: "versionButtonDismissedForBuild")
        UserDefaults.standard.set(Self.currentVersionID, forKey: "versionButtonDismissedForVersion")
    }

    static var currentVersion: String {
        Changelog.currentVersionString
    }

    static var currentBuildNumber: Int {
        Changelog.current.buildNumber
    }

    static var currentVersionID: Double {
        // Convert version ID string to double for comparison (e.g., "0.9" -> 0.9)
        Double(Changelog.current.id) ?? 0.0
    }

    init() {
        checkWelcomeAndVersion()
    }

    private func checkWelcomeAndVersion() {
        // Check if welcome view has been shown before
        let hasShownWelcome = true || UserDefaults.standard.bool(forKey: "hasShownWelcomeViewV3")

        if !hasShownWelcome {
            // If welcome hasn't been shown, show it and mark as shown
            shouldShowWelcomeView = true
            shouldShowVersionPopup = false
            shouldShowVersionButton = false
            // We'll update the flag when the welcome view is dismissed
        } else {
            // If welcome was already shown, check regular version logic
            checkVersion()
        }
    }

    private func checkVersion() {
        let lastBuildNumber = UserDefaults.standard.integer(forKey: "lastSeenBuildNumber")
        let lastVersionID = UserDefaults.standard.double(forKey: "lastSeenVersionID")

        // Check if the button was dismissed for this version
        let dismissedForBuild = UserDefaults.standard.integer(forKey: "versionButtonDismissedForBuild")
        let dismissedForVersion = UserDefaults.standard.double(forKey: "versionButtonDismissedForVersion")

        // Show button if either build number or version ID increased
        if lastBuildNumber < Self.currentBuildNumber || lastVersionID < Self.currentVersionID {
            // Only show the button if it hasn't been dismissed for this version
            if dismissedForBuild < Self.currentBuildNumber || dismissedForVersion < Self.currentVersionID {
                shouldShowVersionButton = true
            }
            shouldShowVersionPopup = false

            // Update stored values
            UserDefaults.standard.set(Self.currentBuildNumber, forKey: "lastSeenBuildNumber")
            UserDefaults.standard.set(Self.currentVersionID, forKey: "lastSeenVersionID")
        } else {
            shouldShowVersionPopup = false
            shouldShowVersionButton = false
        }
    }

    /// Call this when welcome view is dismissed
    func markWelcomeAsShown() {
        UserDefaults.standard.set(true, forKey: "hasShownWelcomeViewV3")
        shouldShowWelcomeView = false

        // Also update version information
        UserDefaults.standard.set(Self.currentBuildNumber, forKey: "lastSeenBuildNumber")
        UserDefaults.standard.set(Self.currentVersionID, forKey: "lastSeenVersionID")
    }
}

struct VersionPopupView: View {
    @Binding var isPresented: Bool
    @ObservedObject private var fontScale = FontScaleManager.shared
    private var fontPreset: FontScalePreset {
        fontScale.preset
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 15) { // Adjusted spacing
            // Header
            HStack {
                Text("Welcome to Repo Prompt Version \(Changelog.currentVersionStringLabel)")
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 22, weight: .semibold)) // Slightly smaller title
                Spacer()
                Button { isPresented = false } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle()) // Ensure the whole area is clickable
            }
            .padding(.horizontal) // Add horizontal padding to header
            .padding(.top) // Add top padding

            // Changelog Content Area
            GroupBox { // Wrap ScrollView in GroupBox
                ScrollView {
                    MarkdownTextView(
                        text: Changelog.fullChangelog,
                        isMarkdown: true,
                        allowInteraction: true,
                        renderCadence: .immediate,
                        allowsStreamingSegmentation: false
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(EdgeInsets(top: 5, leading: 10, bottom: 10, trailing: 10)) // Adjust padding inside ScrollView
                }
            }
            .padding(.horizontal) // Add horizontal padding to GroupBox

            // Footer Links
            HStack(spacing: 16) {
                Spacer()
                Link("Getting Started", destination: URL(string: "https://youtube.com/playlist?list=PLFg9suyZ1OnIKYyoCbAGBaFB-QOAk1nSq&si=hiUSja9eTRWeB26j")!)
                    .buttonStyle(CustomButtonStyle())
                Link("Join Discord", destination: URL(string: "https://discord.gg/NtbFDAJPGM")!)
                    .buttonStyle(CustomButtonStyle())
                Link("Visit Website", destination: URL(string: "https://repoprompt.com")!)
                    .buttonStyle(CustomButtonStyle())
                Spacer()
            }
            .padding(.bottom) // Add bottom padding
            .padding(.horizontal) // Add horizontal padding to footer
        }
        .padding(.vertical, 5) // Reduce overall vertical padding slightly if needed
        .frame(width: fontPreset.scaledClamped(550, max: 700), height: fontPreset.scaledClamped(600, max: 760)) // Adjusted width slightly
    }
}

struct WelcomeView: View {
    @Binding var isPresented: Bool
    @ObservedObject var versionManager: VersionManager
    @ObservedObject private var fontScale = FontScaleManager.shared
    private var fontPreset: FontScalePreset {
        fontScale.preset
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            // Header with icon and close button
            HStack {
                Image(systemName: "star.circle.fill")
                    .font(.system(size: 32))
                    .foregroundColor(.blue)
                    .symbolRenderingMode(.hierarchical)

                Text("Welcome to Repo Prompt 1.0!")
                    .font(fontPreset.titleFont)
                    .fontWeight(.bold)

                Spacer()

                Button(action: {
                    isPresented = false
                    versionManager.markWelcomeAsShown()
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 24))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(PlainButtonStyle())
            }
            .padding()

            ScrollView {
                VStack(spacing: 28) {
                    // Thank you section
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Thank you for your support!")
                            .font(fontPreset.headlineFont)
                            .fontWeight(.bold)

                        Text("If you've been using the beta for a while, thank you so much for engaging with the app and helping shape it into what it is today. While the beta is over, this is a new beginning for the app and this community.")
                            .lineSpacing(4)
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.15))
                    .cornerRadius(12)
                    .padding(.horizontal)

                    // Migration note section
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Important Migration Note")
                            .font(fontPreset.headlineFont)
                            .fontWeight(.bold)

                        Text("By installing this version, the app has been upgraded to no longer use the sandbox. I have made some best efforts to migrate workspaces and prompts, but some data like API settings will need to be re-entered. This migration has happened to better serve you all, with eventual automated terminal commands, among other things.")
                            .lineSpacing(4)
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.15))
                    .cornerRadius(12)
                    .padding(.horizontal)

                    // Features section
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Community Edition Features")
                            .font(fontPreset.headlineFont)
                            .fontWeight(.bold)

                        Text("RepoPrompt CE makes the core feature set available without paid license gates:")
                            .lineSpacing(4)

                        VStack(alignment: .leading, spacing: 12) {
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: "infinity.circle.fill")
                                    .font(fontPreset.swiftUIFont(sizeAtNormal: 20))
                                    .foregroundColor(.blue)
                                    .frame(width: fontPreset.scaledMetric(24))

                                Text("Prompt, copy, and chat workflows are available without edition token limits")
                                    .font(fontPreset.standardFont)
                            }

                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: "gearshape.fill")
                                    .font(fontPreset.swiftUIFont(sizeAtNormal: 20))
                                    .foregroundColor(.blue)
                                    .frame(width: fontPreset.scaledMetric(24))

                                Text("CodeMaps, agent workflows, and custom providers are available in CE")
                                    .font(fontPreset.standardFont)
                            }
                        }
                        .padding(.top, 4)
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.15))
                    .cornerRadius(12)
                    .padding(.horizontal)

                    // License information section
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Community Edition")
                            .font(fontPreset.headlineFont)
                            .fontWeight(.bold)

                        Text("This build removes paid activation flows and subscription prompts.")
                            .lineSpacing(4)

                        HStack {
                            Spacer()
                            // Monthly subscription option
                            VStack(spacing: 12) {
                                Text("FOSS Build")
                                    .font(fontPreset.subheadlineFont)
                                    .fontWeight(.medium)

                                Text("No license required")
                                    .font(fontPreset.headlineFont)

                                Text("All CE features are enabled by default.")
                                    .fontWeight(.medium)
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 8)
                                    .background(Color.blue.opacity(0.12))
                                    .foregroundColor(.blue)
                                    .cornerRadius(8)

                                Text("Fork, build, and use without activation")
                                    .font(fontPreset.subheadlineFont)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                        }
                        .padding(.top, 8)
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.15))
                    .cornerRadius(12)
                    .padding(.horizontal)
                }
            }
            .padding(.vertical)

            // Footer with links
            HStack(spacing: 16) {
                Spacer()

                Button(action: {
                    NSWorkspace.shared.open(URL(string: "https://youtu.be/-J3CwrTrAlE?si=00Ig2DePtMyD_s03")!)
                }) {
                    Text("Getting Started")
                        .fontWeight(.medium)
                }
                .buttonStyle(CustomButtonStyle())

                Button(action: {
                    NSWorkspace.shared.open(URL(string: "https://discord.gg/NtbFDAJPGM")!)
                }) {
                    Text("Join Discord")
                        .fontWeight(.medium)
                }
                .buttonStyle(CustomButtonStyle())

                Button(action: {
                    NSWorkspace.shared.open(URL(string: "https://repoprompt.com")!)
                }) {
                    Text("Visit Website")
                        .fontWeight(.medium)
                }
                .buttonStyle(CustomButtonStyle())

                // Roadmap link
                Button(action: {
                    NSWorkspace.shared.open(URL(string: "https://repoprompt.com/roadmap")!)
                }) {
                    Text("View Our New Roadmap")
                        .fontWeight(.medium)
                }
                .buttonStyle(CustomButtonStyle())

                Spacer()
            }
            .padding(.bottom)
            .padding(.horizontal)
        }
        .frame(width: fontPreset.scaledClamped(650, max: 820), height: fontPreset.scaledClamped(720, max: 860))
        .background(Color(NSColor.windowBackgroundColor))
    }
}
