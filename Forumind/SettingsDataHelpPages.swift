import SwiftUI

// Settings › Data & privacy, Help, How to share, About, Acknowledgements.

// MARK: Data & privacy

struct SettingsDataPage: View {
    @ObservedObject var app: AppModel
    @State private var clearingSiteURL: String?
    @State private var confirmingClearAll = false
    @State private var confirmingReset = false
    @State private var status: String?

    private var forumsWithData: [String] {
        app.siteURLsWithSavedData.sorted { name(for: $0) < name(for: $1) }
    }

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: DCTheme.spacingL) {
                    PrivacyPoints()
                }
                .padding(.vertical, DCTheme.spacingS)
            } header: {
                Text("Your privacy")
            }

            Section {
                if forumsWithData.isEmpty {
                    Text("Nothing saved yet. Summaries, chats, and answers appear here by forum.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(forumsWithData, id: \.self) { siteURL in
                        HStack(spacing: DCTheme.spacingM) {
                            OnboardingForumIcon(
                                siteURL: siteURL,
                                name: name(for: siteURL),
                                iconURL: app.forum(for: siteURL)?.iconURL,
                                size: 30
                            )
                            VStack(alignment: .leading, spacing: 2) {
                                Text(name(for: siteURL)).lineLimit(1)
                                Text(itemsText(app.savedItemCount(forSiteURL: siteURL)))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: DCTheme.spacingS)
                            Button("Clear", role: .destructive) {
                                clearingSiteURL = siteURL
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Clear saved data for \(name(for: siteURL))")
                        }
                    }
                }
            } header: {
                Text("Saved data by forum")
            } footer: {
                Text("Clearing deletes saved summaries, chats, answers, and watched topics for that forum. The forum stays in your list.")
            }

            Section {
                Button(role: .destructive) {
                    confirmingClearAll = true
                } label: {
                    Label("Clear all saved data", systemImage: "trash")
                }
                .disabled(forumsWithData.isEmpty)
                .accessibilityIdentifier("clearAllData")
                Button(role: .destructive) {
                    confirmingReset = true
                } label: {
                    Label("Reset settings to defaults", systemImage: "arrow.counterclockwise")
                }
                .accessibilityIdentifier("resetSettings")
            } footer: {
                if let status {
                    Text(status)
                } else {
                    Text(app.settings.syncAPIKeys
                        ? "Resetting settings keeps your forums and saved data. API keys are removed, including from iCloud Keychain on your other devices."
                        : "Resetting settings keeps your forums and saved data. API keys are removed from this device.")
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(
            "Clear saved data for \(clearingSiteURL.map(name(for:)) ?? "this forum")?",
            isPresented: Binding(get: { clearingSiteURL != nil }, set: { if !$0 { clearingSiteURL = nil } }),
            titleVisibility: .visible,
            presenting: clearingSiteURL
        ) { siteURL in
            Button("Clear saved data", role: .destructive) {
                withAnimation { app.clearSavedData(forSiteURL: siteURL) }
                status = "Cleared saved data for \(name(for: siteURL))."
                DCHaptics.success()
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Summaries, chats, answers, and watched topics for this forum will be deleted. This can’t be undone.")
        }
        .confirmationDialog(
            "Clear all saved data?",
            isPresented: $confirmingClearAll,
            titleVisibility: .visible
        ) {
            Button("Clear all saved data", role: .destructive) {
                withAnimation { app.clearAllSavedData() }
                status = "All saved data cleared."
                DCHaptics.success()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every saved summary, chat, answer, and watched topic will be deleted. Your forums and settings stay.")
        }
        .confirmationDialog(
            "Reset all settings?",
            isPresented: $confirmingReset,
            titleVisibility: .visible
        ) {
            Button("Reset to defaults", role: .destructive) {
                app.resetSettings()
                status = "Settings reset to defaults."
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Provider settings, API keys, favorite models, and custom instructions will be reset.")
        }
    }

    private func name(for siteURL: String) -> String {
        app.forum(for: siteURL)?.displayName ?? ForumSite.host(of: siteURL)
    }

    private func itemsText(_ count: Int) -> String {
        count == 1 ? "1 saved item" : "\(count) saved items"
    }
}

// MARK: Help

struct SettingsHelpPage: View {
    @ObservedObject var app: AppModel
    @Environment(\.replayOnboarding) private var replayOnboarding
    @Environment(\.openURL) private var openURL

    var body: some View {
        Form {
            Section {
                Button {
                    DCHaptics.tap()
                    replayOnboarding()
                } label: {
                    HStack(spacing: DCTheme.spacingM) {
                        SettingsIcon(symbol: "play.fill", tint: DCTheme.brandPurple)
                        Text("Replay the walkthrough").foregroundStyle(.primary)
                    }
                }
                .accessibilityIdentifier("replayOnboarding")
                NavigationLink(value: SettingsPage.sharing) {
                    SettingsRowLabel(page: .sharing, title: "How to share from Safari or Chrome")
                }
            }

            Section {
                ForEach(AIProvider.allCases) { provider in
                    let guide = ProviderGuide.guide(for: provider)
                    Button {
                        openURL(guide.link)
                    } label: {
                        HStack(spacing: DCTheme.spacingM) {
                            ProviderBadge(provider: provider, size: 29)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(provider.displayName).foregroundStyle(.primary)
                                Text(guide.blurb)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: DCTheme.spacingS)
                            Image(systemName: "arrow.up.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(guide.linkTitle)
                }
            } header: {
                Text("Choosing an AI provider")
            } footer: {
                Text("Not sure? If you already pay for one of these, use it. To try many models with one key, OpenRouter is an easy start.")
            }

            Section {
                NavigationLink(value: SettingsPage.about) {
                    SettingsRowLabel(page: .about, value: AppVersion.text())
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct SettingsSharingPage: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DCTheme.spacingXL) {
                Text("Send any forum page from Safari, Chrome, or another app straight to Forumind.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                ShareHowToGuide()
            }
            .padding(DCTheme.spacingL)
            .frame(maxWidth: DCTheme.contentMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(DCTheme.pageBackground)
    }
}

struct SettingsAboutPage: View {
    var body: some View {
        Form {
            Section {
                VStack(spacing: DCTheme.spacingM) {
                    BrandMark(size: 84)
                        .shadow(color: Color(hex: 0x4A6BFF, opacity: 0.3), radius: 12, y: 6)
                    Text("Forumind").font(.title3.weight(.bold))
                    Text("Summaries, chat, and answers for any Discourse forum.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, DCTheme.spacingM)
            }

            Section {
                LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")
                LabeledContent("Build", value: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—")
                    .accessibilityIdentifier("aboutBuild")
            }

            Section {
                NavigationLink(value: SettingsPage.acknowledgements) {
                    SettingsRowLabel(page: .acknowledgements)
                }
                .accessibilityIdentifier("settingsRow-acknowledgements")
                Link(destination: AppVersion.repositoryURL) {
                    Label("Source code on GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                }
            } footer: {
                Text("Forumind works with Discourse forums. It is an independent app and is not affiliated with or endorsed by Civilized Discourse Construction Kit, Inc. Discourse is a trademark of its respective owner.")
            }
        }
        .formStyle(.grouped)
    }
}

/// Credits for the bundled filter lists: the pipeline's ATTRIBUTION.md when
/// present, otherwise a built-in summary.
struct SettingsAcknowledgementsPage: View {
    @ObservedObject var app: AppModel

    static let easyListURL = URL(string: "https://easylist.to")!
    static let licenseURL = URL(string: "https://creativecommons.org/licenses/by-sa/3.0/")!

    static let builtInText = """
    ## EasyList and EasyPrivacy

    The built-in browser blocks ads and trackers with the EasyList and \
    EasyPrivacy filter lists by The EasyList authors (https://easylist.to), \
    converted to WebKit content-blocking rules.

    The lists are licensed under the Creative Commons Attribution-ShareAlike \
    3.0 Unported license (CC BY-SA 3.0), and may also be used under the GNU \
    General Public License v3 or later.
    """

    static var bundledAttribution: String? {
        guard let url = Bundle.main.url(
            forResource: "ATTRIBUTION",
            withExtension: "md",
            subdirectory: "ContentBlocking"
        ) else {
            return nil
        }
        return (try? String(contentsOf: url, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
    }

    var body: some View {
        Form {
            Section {
                MarkdownView(Self.bundledAttribution ?? Self.builtInText)
                    .textSelection(.enabled)
                    .padding(.vertical, DCTheme.spacingXS)
                    .accessibilityIdentifier("acknowledgementsText")
            } header: {
                Text("Filter lists")
            } footer: {
                if let manifest = app.contentRules.manifest {
                    Text("Lists version \(manifest.version).")
                }
            }

            Section {
                Link(destination: Self.easyListURL) {
                    Label("EasyList website", systemImage: "safari")
                }
                Link(destination: Self.licenseURL) {
                    Label("CC BY-SA 3.0 license", systemImage: "doc.text")
                }
            }
        }
        .formStyle(.grouped)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
