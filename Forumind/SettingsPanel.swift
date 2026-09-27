import SwiftUI

/// Settings as shown inside the assistant panel. The panel host draws the
/// "Settings" header and back button, so the root hides its navigation bar;
/// sub-pages push with a standard bar. Inside an existing NavigationStack
/// (e.g. a full-screen sheet), use `SettingsRootView` directly.
struct SettingsPanel: View {
    @ObservedObject var app: AppModel
    /// When set (Settings hosted in the assistant panel), the root shows a
    /// navigation bar whose leading button returns to the assistant, so a
    /// pushed sub-page gets one bar instead of two stacked headers.
    var onClose: (() -> Void)?

    /// DEBUG: `-dc-panel-settings <page>` opens that sub-page in the panel.
    private static var debugInitialPage: SettingsPage? {
        #if DEBUG
        OnboardingDebug.value(after: "-dc-panel-settings").flatMap(SettingsPage.parse)
        #else
        nil
        #endif
    }

    /// Tracks pushed sub-pages so Esc can step back one page at a time.
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            SettingsRootView(app: app, initialPage: Self.debugInitialPage)
                .navigationTitle("Settings")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    if let onClose {
                        ToolbarItem(placement: .topBarLeading) {
                            Button(action: onClose) {
                                // Chevron + text (a toolbar Label collapses to
                                // the icon), matching Manage's "‹ Assistant".
                                HStack(spacing: 4) {
                                    Image(systemName: "chevron.left")
                                        .fontWeight(.semibold)
                                    Text("Assistant")
                                }
                            }
                            .accessibilityLabel("Back to assistant")
                            .accessibilityIdentifier("backToTopic")
                        }
                    }
                }
                .toolbar(onClose == nil ? .hidden : .visible, for: .navigationBar)
        }
        .background {
            // Esc (hardware keyboard): back one page, then back to the
            // assistant. Toolbar buttons don't carry keyboard shortcuts.
            if let onClose {
                Button("Back") {
                    if path.isEmpty { onClose() } else { path.removeLast() }
                }
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
    }
}

/// Grouped Settings root, iOS Settings style. Registers the sub-page
/// destinations, so it must sit inside a NavigationStack.
struct SettingsRootView: View {
    @ObservedObject var app: AppModel
    @State private var pushed: SettingsPage?

    init(app: AppModel, initialPage: SettingsPage? = nil) {
        self.app = app
        _pushed = State(initialValue: initialPage)
    }

    var body: some View {
        Form {
            Section {
                NavigationLink(value: SettingsPage.provider) {
                    providerRow
                }
                .accessibilityIdentifier("settingsRow-provider")
                SettingsSyncRow(app: app)
            }

            Section {
                row(.forums, value: forumsValue)
            }

            Section("Assistant") {
                row(.summaries)
                row(.agent)
                row(.watched, value: app.watchedTopics.isEmpty ? nil : "\(app.watchedTopics.count)")
            }

            Section("App") {
                row(.browser, value: app.settings.browserBarPosition.displayName)
                row(.data)
            }

            Section {
                row(.help)
            } footer: {
                Text("Forumind \(AppVersion.text())")
                    .frame(maxWidth: .infinity)
                    .padding(.top, DCTheme.spacingS)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .navigationDestination(for: SettingsPage.self) { page in
            SettingsDestination(app: app, page: page)
        }
        .navigationDestination(item: $pushed) { page in
            SettingsDestination(app: app, page: page)
        }
        .accessibilityIdentifier("settingsRoot")
    }

    private var forumsValue: String? {
        let pinned = app.pinnedForums.count
        if pinned > 0 { return "\(pinned) pinned" }
        return app.forums.isEmpty ? nil : "\(app.forums.count)"
    }

    private var providerRow: some View {
        HStack(spacing: DCTheme.spacingM) {
            SettingsIcon(page: .provider)
            VStack(alignment: .leading, spacing: 2) {
                Text("AI provider")
                Text(providerSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: DCTheme.spacingS)
            SettingsStatusPill(ready: app.isProviderReady)
        }
    }

    private var providerSummary: String { app.providerSummary }

    private func row(_ page: SettingsPage, value: String? = nil) -> some View {
        NavigationLink(value: page) {
            SettingsRowLabel(page: page, value: value)
        }
        .accessibilityIdentifier("settingsRow-\(page.rawValue)")
    }
}

/// Routes a page value to its view.
struct SettingsDestination: View {
    @ObservedObject var app: AppModel
    let page: SettingsPage

    var body: some View {
        Group {
            switch page {
            case .provider: SettingsProviderPage(app: app)
            case .sync: SettingsSyncPage(app: app)
            case .forums: SettingsForumsPage(app: app)
            case .summaries: SettingsSummariesPage(app: app)
            case .agent: SettingsAgentPage(app: app)
            case .watched: SettingsWatchedPage(app: app)
            case .browser: SettingsBrowserPage(app: app)
            case .data: SettingsDataPage(app: app)
            case .help: SettingsHelpPage(app: app)
            case .sharing: SettingsSharingPage()
            case .about: SettingsAboutPage()
            case .acknowledgements: SettingsAcknowledgementsPage(app: app)
            }
        }
        .navigationTitle(page.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
    }
}

/// White glyph in a colored rounded square, like iOS Settings.
struct SettingsIcon: View {
    let symbol: String
    let tint: Color

    init(page: SettingsPage) {
        symbol = page.systemImage
        tint = page.tint
    }

    init(symbol: String, tint: Color) {
        self.symbol = symbol
        self.tint = tint
    }

    @ScaledMetric(relativeTo: .body) private var size: CGFloat = 29

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
            .fill(tint.gradient)
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.52, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .accessibilityHidden(true)
    }
}

struct SettingsRowLabel: View {
    let page: SettingsPage
    var title: String?
    var value: String?

    var body: some View {
        HStack(spacing: DCTheme.spacingM) {
            SettingsIcon(page: page)
            Text(title ?? page.title)
            Spacer(minLength: DCTheme.spacingS)
            if let value {
                Text(value)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

struct SettingsStatusPill: View {
    let ready: Bool

    var body: some View {
        DCPill(
            text: ready ? "Ready" : "Set up",
            systemImage: ready ? "checkmark.circle.fill" : "exclamationmark.circle.fill",
            tint: ready ? DCTheme.success : DCTheme.warning
        )
        .accessibilityLabel(ready ? "Provider ready" : "Provider needs setup")
    }
}
