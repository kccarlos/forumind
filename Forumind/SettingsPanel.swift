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
                summaryRow(.assistant)
                summaryRow(.agent)
                NavigationLink(value: SettingsPage.voice) {
                    Label(SettingsRootSummary.voiceToday(
                        seconds: VoiceUsageStore().seconds(on: Date()),
                        dailyLimitMinutes: app.settings.voice.dailyLimitMinutes
                    ), systemImage: "waveform")
                    .foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("settingsSummary-voice")
            }

            Section("AI") {
                NavigationLink(value: SettingsPage.provider) {
                    providerRow
                }
                .accessibilityIdentifier("settingsRow-provider")
                row(.voice, value: app.settings.voiceEnabled ? String(localized: "On") : String(localized: "Off"))
            }

            Section("Reading") {
                row(.summaries)
                row(.agent)
                ReadingLanguagePicker(app: app)
                row(.browser, value: String(localized: "Bar: \(app.settings.browserBarPosition.displayName)", comment: "Settings root, Browser row: the address bar position, e.g. Automatic"))
            }

            Section("Today & following") {
                row(.digest, value: app.settings.dailyDigestEnabled ? String(localized: "On") : String(localized: "Off"))
                row(.watched, value: app.watchedTopics.isEmpty ? nil : "\(app.watchedTopics.count)")
            }

            Section("Forums, sync & privacy") {
                row(.forums, value: forumsValue)
                SettingsSyncRow(app: app)
                row(.data)
            }

            Section {
                NavigationLink(value: SettingsPage.sharing) {
                    SettingsRowLabel(page: .sharing, title: String(localized: "Open pages from Safari or Chrome"))
                }
                .accessibilityIdentifier("settingsRow-sharing")
                row(.help)
                languageRow
            } header: {
                Text("Help")
            } footer: {
                Text("iOS manages the app language. Change it in Settings › Forumind › Language.")
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

    /// A header line: the role's name and its current model.
    private func summaryRow(_ role: ModelRole) -> some View {
        let model = app.modelLabel(for: role)
        return NavigationLink(value: SettingsPage.provider) {
            LabeledContent {
                Text(model.isEmpty ? app.selection(for: role).provider.displayName : model)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } label: {
                Text(role == .assistant ? "Summaries & chat model" : "Ask the forum model")
            }
        }
        .accessibilityIdentifier("settingsSummary-\(role.rawValue)")
    }

    private var forumsValue: String? {
        let pinned = app.pinnedForums.count
        if pinned > 0 { return String(localized: "\(pinned) pinned", comment: "Settings root, Forums row: number of pinned forums") }
        return app.forums.isEmpty ? nil : "\(app.forums.count)"
    }

    private var providerRow: some View {
        HStack(spacing: DCTheme.spacingM) {
            SettingsIcon(page: .provider)
            VStack(alignment: .leading, spacing: 2) {
                Text("AI models")
                Text(providerSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: DCTheme.spacingS)
            SettingsStatusPill(ready: app.isProviderReady)
        }
    }

    /// One "provider · model" when both roles share it, else both models.
    private var providerSummary: String {
        guard !app.rolesShareModel else { return app.providerSummary(for: .assistant) }
        return ModelRole.allCases.map { role in
            let model = app.modelLabel(for: role)
            return model.isEmpty ? app.selection(for: role).provider.displayName : model
        }.joined(separator: " · ")
    }

    /// Opens Forumind's page in the Settings app, where iOS shows the
    /// per-app Language picker (the bundle has more than one localization).
    private var languageRow: some View {
        Button {
            DCHaptics.tap()
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }
        } label: {
            HStack(spacing: DCTheme.spacingM) {
                SettingsIcon(symbol: "globe", tint: Color(light: 0x1C7CD6, dark: 0x4AA3FF))
                // Explicit colors: a Form button would tint `.primary`.
                Text("Language")
                    .foregroundStyle(Color.primary)
                Spacer(minLength: DCTheme.spacingS)
                Text(AppLanguage.displayName)
                    .foregroundStyle(Color.secondary)
                    .lineLimit(1)
                Image(systemName: "arrow.up.forward")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color(uiColor: .tertiaryLabel))
            }
            .contentShape(Rectangle())
        }
        .accessibilityHint("Opens Forumind in the Settings app")
        .accessibilityIdentifier("settingsRow-language")
    }

    private func row(_ page: SettingsPage, value: String? = nil) -> some View {
        NavigationLink(value: page) {
            SettingsRowLabel(page: page, value: value)
        }
        .accessibilityIdentifier("settingsRow-\(page.rawValue)")
    }
}

/// Settings › Reading language: the app's language, or one of
/// `ReadingLanguage.choices` (names from the system).
struct ReadingLanguagePicker: View {
    @ObservedObject var app: AppModel

    var body: some View {
        Picker(selection: $app.settings.readingLanguage) {
            Text("App language (\(AppLanguage.displayName))", comment: "Reading language option; the placeholder is the app's language name").tag("")
            ForEach(ReadingLanguage.choices, id: \.self) { code in
                Text(verbatim: ReadingLanguage.displayName(code)).tag(code)
            }
        } label: {
            HStack(spacing: DCTheme.spacingM) {
                SettingsIcon(symbol: "translate", tint: Color(light: 0x2F9E6B, dark: 0x4CC38A))
                Text("Reading language")
            }
        }
        .accessibilityIdentifier("settingsRow-readingLanguage")
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
            case .digest: SettingsDigestPage(app: app)
            case .voice: SettingsVoicePage(app: app, voice: app.voice)
            case .browser: SettingsBrowserPage(app: app)
            case .data: SettingsDataPage(app: app)
            case .help: SettingsHelpPage(app: app)
            case .sharing: SettingsSharingPage()
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
            text: ready ? String(localized: "Ready", comment: "AI provider status pill") : String(localized: "Set up", comment: "AI provider status pill: needs setup"),
            systemImage: ready ? "checkmark.circle.fill" : "exclamationmark.circle.fill",
            tint: ready ? DCTheme.success : DCTheme.warning
        )
        .accessibilityLabel(ready ? "Provider ready" : "Provider needs setup")
    }
}

/// Derived text for the Settings root header.
enum SettingsRootSummary {
    /// "Voice today 4 of 30 min"; without a daily limit (0) just the minutes.
    static func voiceToday(seconds: TimeInterval, dailyLimitMinutes: Int) -> String {
        let used = Int(seconds / 60)
        if dailyLimitMinutes > 0 {
            return String(localized: "Voice today \(used) of \(dailyLimitMinutes) min", comment: "Settings header: voice minutes used today of the daily limit")
        }
        return String(localized: "Voice today \(used) min", comment: "Settings header: voice minutes used today, no daily limit")
    }
}
