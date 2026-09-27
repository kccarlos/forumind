import SwiftUI

// Settings › iCloud Sync, the one-time sync prompt card, and the status text
// shared by Settings, the prompt, and the onboarding step. The engine is
// `FolderSyncController` (`app.folderSync`); see docs/ICLOUD_SYNC_PLAN.md.

/// What the UI says about a sync status (pure; unit-tested).
struct SyncStatusPresentation: Equatable {
    enum Action: Equatable {
        case chooseFolder
        case chooseFolderAgain
        case chooseAnotherFolder
        case checkAgain
        case syncNow
    }

    var title: String
    var detail: String?
    var symbol: String
    var tint: Color
    var action: Action?
    /// Short value for the Settings root row.
    var shortLabel: String
    var isBusy = false

    var actionTitle: String? {
        switch action {
        case .chooseFolder: "Choose folder…"
        case .chooseFolderAgain: "Choose the folder again…"
        case .chooseAnotherFolder: "Choose another folder…"
        case .checkAgain: "Check again"
        case .syncNow: "Sync now"
        case nil: nil
        }
    }

    init(
        title: String,
        detail: String? = nil,
        symbol: String,
        tint: Color,
        action: Action? = nil,
        shortLabel: String,
        isBusy: Bool = false
    ) {
        self.title = title
        self.detail = detail
        self.symbol = symbol
        self.tint = tint
        self.action = action
        self.shortLabel = shortLabel
        self.isBusy = isBusy
    }

    init(_ status: FolderSyncController.Status) {
        switch status {
        case .off:
            self.init(
                title: "Sync is off",
                detail: "Choose a folder in iCloud Drive to sync your forums, summaries, chats and agent runs across devices.",
                symbol: "icloud.slash",
                tint: .secondary,
                action: .chooseFolder,
                shortLabel: "Off"
            )
        case .needsFolderAccess:
            self.init(
                title: "Choose the folder again",
                detail: "This device lost access to the sync folder. Choose the same folder in iCloud Drive to carry on.",
                symbol: "folder.badge.questionmark",
                tint: DCTheme.warning,
                action: .chooseFolderAgain,
                shortLabel: "Needs folder"
            )
        case .notInICloud:
            self.init(
                title: "Not in iCloud Drive",
                detail: "This folder isn't in iCloud Drive, so other devices can't see it. Choose a folder inside iCloud Drive.",
                symbol: "exclamationmark.icloud",
                tint: DCTheme.warning,
                action: .chooseAnotherFolder,
                shortLabel: "Not in iCloud"
            )
        case .waitingForKey:
            self.init(
                title: "Waiting for iCloud Keychain…",
                detail: "Synced data is encrypted with a key kept in iCloud Keychain. Turn on Settings › [your name] › iCloud › Passwords and Keychain, then check again.",
                symbol: "key.icloud",
                tint: DCTheme.warning,
                action: .checkAgain,
                shortLabel: "Waiting"
            )
        case .syncing:
            self.init(
                title: "Syncing…",
                symbol: "arrow.triangle.2.circlepath.icloud",
                tint: DCTheme.brandBlue,
                shortLabel: "Syncing",
                isBusy: true
            )
        case .upToDate:
            self.init(
                title: "Up to date",
                symbol: "checkmark.icloud.fill",
                tint: DCTheme.success,
                action: .syncNow,
                shortLabel: "On"
            )
        case .error(let message):
            self.init(
                title: "Sync didn’t finish",
                detail: message,
                symbol: "xmark.icloud",
                tint: DCTheme.danger,
                action: .syncNow,
                shortLabel: "Error"
            )
        }
    }
}

// MARK: - One-time prompt

/// Remembers (on this device only) that the sync prompt was dismissed or
/// acted on, so it is shown once.
enum SyncPrompt {
    static let defaultsKey = "dc.syncPromptHandled"

    static var isHandled: Bool {
        #if DEBUG
        if OnboardingDebug.arguments.contains("-dc-sync-prompt") { return false }
        #endif
        return UserDefaults.standard.bool(forKey: defaultsKey)
    }

    static func markHandled() {
        UserDefaults.standard.set(true, forKey: defaultsKey)
    }

    /// UI tests (`-dc-no-sync-prompt`) keep Forums home as their flows expect.
    static var isHiddenOnForumsHome: Bool {
        #if DEBUG
        return OnboardingDebug.arguments.contains("-dc-no-sync-prompt")
        #else
        return false
        #endif
    }
}

/// The prompt as the first Settings root section, while sync is off and
/// the prompt hasn't been dismissed or acted on (once per device).
struct SyncPromptSection: View {
    @ObservedObject var app: AppModel
    @ObservedObject private var sync: FolderSyncController
    @State private var handled = SyncPrompt.isHandled

    init(app: AppModel) {
        self.app = app
        self.sync = app.folderSync
    }

    var body: some View {
        if !handled, SyncDebug.status(actual: sync.status) == .off {
            Section {
                SyncPromptCard(app: app) {
                    withAnimation(DCMotion.quick) { handled = true }
                }
            }
        }
    }
}

/// "Sync across your devices" card for people who haven't chosen a folder.
/// "Not now" and choosing a folder both retire it (`SyncPrompt`).
struct SyncPromptCard: View {
    @ObservedObject var app: AppModel
    var onHandled: () -> Void = {}
    @State private var picking = false

    var body: some View {
        VStack(alignment: .leading, spacing: DCTheme.spacingM) {
            HStack(alignment: .top, spacing: DCTheme.spacingM) {
                OnboardingIconTile(symbol: "icloud.fill", tint: SettingsPage.sync.tint, size: 40, filled: true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Sync across your devices")
                        .font(.headline)
                    Text("Keep your forums, summaries, chats and agent runs on your iPhone and iPad, through a folder in your iCloud Drive."
                        + (app.settings.syncAPIKeys ? " Your API keys already sync with iCloud Keychain." : ""))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: DCTheme.spacingS) {
                Button("Choose folder…") { picking = true }
                    .buttonStyle(DCActionButtonStyle(prominent: true))
                    .accessibilityIdentifier("syncPromptChooseFolder")
                Button("Not now") {
                    SyncPrompt.markHandled()
                    onHandled()
                }
                .buttonStyle(DCActionButtonStyle(prominent: false))
                .accessibilityIdentifier("syncPromptDismiss")
            }
        }
        .padding(.vertical, DCTheme.spacingXS)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("syncPromptCard")
        .syncFolderPicker(isPresented: $picking, app: app, onChosen: onHandled)
    }
}

// MARK: - Settings root row

/// Settings root row with the sync status as its value.
struct SettingsSyncRow: View {
    @ObservedObject private var sync: FolderSyncController

    init(app: AppModel) {
        self.sync = app.folderSync
    }

    var body: some View {
        NavigationLink(value: SettingsPage.sync) {
            SettingsRowLabel(
                page: .sync,
                value: SyncStatusPresentation(SyncDebug.status(actual: sync.status)).shortLabel
            )
        }
        .accessibilityIdentifier("settingsRow-sync")
    }
}

// MARK: - Settings › iCloud Sync

struct SettingsSyncPage: View {
    @ObservedObject var app: AppModel
    @ObservedObject private var sync: FolderSyncController
    @State private var picking = false
    @State private var confirmingStop = false
    @State private var confirmingReset = false
    @State private var resetError: String?
    @State private var resetting = false

    init(app: AppModel) {
        self.app = app
        self.sync = app.folderSync
    }

    private var status: FolderSyncController.Status { SyncDebug.status(actual: sync.status) }
    private var presentation: SyncStatusPresentation { SyncStatusPresentation(status) }
    private var folderName: String? { SyncDebug.folderName(actual: sync.folderName, status: status) }
    private var lastSyncedAt: Date? { SyncDebug.lastSyncedAt(actual: sync.lastSyncedAt, status: status) }
    private var hasFolder: Bool { status != .off }

    var body: some View {
        Form {
            Section {
                syncStatusView
            } footer: {
                if !hasFolder { Text(FolderPicker.tip) }
            }

            if hasFolder {
                folderSection
            }

            Section {
                Toggle("Sync API keys", isOn: syncAPIKeysBinding)
                    .accessibilityIdentifier("syncAPIKeys")
            } header: {
                Text("API keys")
            } footer: {
                Text(app.settings.syncAPIKeys
                    ? "Keys are stored in iCloud Keychain, so every device signed in to your Apple Account has them. Deleting a key in the app deletes it on your other devices too. Works without a sync folder."
                    : "Keys stay in this device’s Keychain. Keys already in iCloud Keychain are left there for your other devices; turning this off doesn’t delete them.")
            }

            Section {
                SyncExplainer()
            }

            if hasFolder {
                Section {
                    Button(role: .destructive) {
                        confirmingStop = true
                    } label: {
                        Label("Stop syncing on this device", systemImage: "icloud.slash")
                    }
                    .accessibilityIdentifier("syncStop")
                    Button(role: .destructive) {
                        confirmingReset = true
                    } label: {
                        HStack {
                            Label("Reset sync data", systemImage: "arrow.counterclockwise.icloud")
                            if resetting {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(resetting)
                    .accessibilityIdentifier("syncReset")
                } footer: {
                    Text("Stopping keeps everything on this device and in the folder. Reset only if synced data can’t be read.")
                }
            }
        }
        .formStyle(.grouped)
        .accessibilityIdentifier("syncPage")
        .syncFolderPicker(isPresented: $picking, app: app)
        #if DEBUG
        // `-dc-sync-picker`: opens the folder picker (screenshots).
        .task {
            if OnboardingDebug.arguments.contains("-dc-sync-picker") {
                try? await Task.sleep(for: .seconds(1))
                picking = true
            }
        }
        #endif
        .confirmationDialog(
            "Stop syncing on this device?",
            isPresented: $confirmingStop,
            titleVisibility: .visible
        ) {
            Button("Stop syncing", role: .destructive) {
                sync.stop()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your data stays on this device and in the sync folder. Other devices keep syncing. Choose the folder again to resume.")
        }
        .confirmationDialog(
            "Reset sync data?",
            isPresented: $confirmingReset,
            titleVisibility: .visible
        ) {
            Button("Reset sync data", role: .destructive) {
                resetting = true
                Task {
                    do {
                        try await sync.resetSyncData()
                        DCHaptics.success()
                    } catch {
                        resetError = error.localizedDescription
                    }
                    resetting = false
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Replaces the synced copy with this device's data and starts a new encryption key. Other devices will need iCloud Keychain to read it.")
        }
        .alert(
            "Couldn’t reset sync data",
            isPresented: Binding(get: { resetError != nil }, set: { if !$0 { resetError = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(resetError ?? "")
        }
    }

    private var folderSection: some View {
        Section {
            if let folderName {
                LabeledContent {
                    Button("Change…") { picking = true }
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier("syncChangeFolder")
                } label: {
                    Label {
                        Text(folderName).lineLimit(1)
                    } icon: {
                        Image(systemName: "folder.fill").foregroundStyle(SettingsPage.sync.tint)
                    }
                    .accessibilityLabel("Folder: \(folderName)")
                }
            } else {
                Button {
                    picking = true
                } label: {
                    Label("Choose folder…", systemImage: "folder.badge.plus")
                }
                .accessibilityIdentifier("syncChooseFolder")
            }
            LabeledContent("Last synced") {
                if let lastSyncedAt {
                    TimelineView(.periodic(from: .now, by: 30)) { _ in
                        Text(lastSyncedAt, format: .relative(presentation: .named))
                    }
                } else {
                    Text("Not yet")
                }
            }
            .accessibilityIdentifier("syncLastSynced")
            Button {
                sync.syncNow()
            } label: {
                Label(status == .syncing ? "Syncing…" : "Sync now", systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(status == .syncing)
            .accessibilityIdentifier("syncNow")
        } header: {
            Text("Sync folder")
        } footer: {
            Text(FolderPicker.tip)
        }
    }

    private var syncAPIKeysBinding: Binding<Bool> {
        Binding(
            get: { app.settings.syncAPIKeys },
            set: { on in
                // The key store follows through `RootView`'s onChange.
                app.settings.syncAPIKeys = on
                app.saveSettings()
            }
        )
    }

    private var syncStatusView: some View {
        VStack(alignment: .leading, spacing: DCTheme.spacingM) {
            HStack(alignment: .top, spacing: DCTheme.spacingM) {
                Group {
                    if presentation.isBusy {
                        ProgressView()
                            .frame(width: 40, height: 40)
                            .background(presentation.tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    } else {
                        OnboardingIconTile(symbol: presentation.symbol, tint: presentation.tint, size: 40)
                    }
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(presentation.title)
                        .font(.headline)
                        .foregroundStyle(presentation.tint == .secondary ? Color.primary : presentation.tint)
                    if let detail = presentation.detail {
                        Text(detail)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if let folderName {
                        Text("Syncing with “\(folderName)” in iCloud Drive.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("syncStatus")
            if let action = presentation.action, action != .syncNow || status != .upToDate,
               let title = presentation.actionTitle {
                Button(title) { perform(action) }
                    .buttonStyle(DCActionButtonStyle(prominent: action == .chooseFolder || action == .chooseFolderAgain))
                    .accessibilityIdentifier("syncStatusAction")
            }
        }
        .padding(.vertical, DCTheme.spacingXS)
    }

    private func perform(_ action: SyncStatusPresentation.Action) {
        switch action {
        case .chooseFolder, .chooseFolderAgain, .chooseAnotherFolder: picking = true
        case .checkAgain, .syncNow: sync.syncNow()
        }
    }
}

/// "How sync works": what syncs, what stays, and privacy.
struct SyncExplainer: View {
    /// DEBUG `-dc-sync-explain` starts expanded (screenshots).
    @State private var expanded: Bool = {
        #if DEBUG
        OnboardingDebug.arguments.contains("-dc-sync-explain")
        #else
        false
        #endif
    }()

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: DCTheme.spacingL) {
                OnboardingFeatureRow(
                    symbol: "arrow.triangle.2.circlepath",
                    tint: DCTheme.brandBlue,
                    title: "What syncs",
                    detail: "Your forums, summaries and chats (with their instructions and kept items), Ask the forum runs, watched topics, and settings. API keys sync through iCloud Keychain."
                )
                OnboardingFeatureRow(
                    symbol: "iphone",
                    tint: DCTheme.chatTint,
                    title: "What stays on this device",
                    detail: "The work queue and activity log, cached forum pages, the browser bar position, and which folder this device syncs with."
                )
                OnboardingFeatureRow(
                    symbol: "lock.fill",
                    tint: DCTheme.brandPurple,
                    title: "Encrypted",
                    detail: "Files are encrypted on your device with a key kept in iCloud Keychain, so iCloud Drive only stores encrypted files. There’s no server of ours in between."
                )
                OnboardingFeatureRow(
                    symbol: "arrow.left.arrow.right",
                    tint: DCTheme.success,
                    title: "Newest change wins",
                    detail: "Each item keeps its most recent edit. A chat you cleared on one device stays cleared on the others."
                )
            }
            .padding(.vertical, DCTheme.spacingS)
        } label: {
            Label("How sync works", systemImage: "info.circle")
        }
        .accessibilityIdentifier("syncHowItWorks")
    }
}

// MARK: - DEBUG screenshots

/// DEBUG `-dc-sync-status <off|needsFolderAccess|notInICloud|waitingForKey|syncing|upToDate|error>`
/// overrides the status shown by the sync UI (screenshots only; the engine
/// is untouched). A fake folder name and last-synced time come with it.
enum SyncDebug {
    static func status(actual: FolderSyncController.Status) -> FolderSyncController.Status {
        #if DEBUG
        if let value = OnboardingDebug.value(after: "-dc-sync-status"), let parsed = parse(value) { return parsed }
        #endif
        return actual
    }

    static func folderName(actual: String?, status: FolderSyncController.Status) -> String? {
        #if DEBUG
        if OnboardingDebug.value(after: "-dc-sync-status") != nil {
            return status == .off ? nil : "Forumind"
        }
        #endif
        return actual
    }

    static func lastSyncedAt(actual: Date?, status: FolderSyncController.Status) -> Date? {
        #if DEBUG
        if OnboardingDebug.value(after: "-dc-sync-status") != nil {
            return status == .off || status == .needsFolderAccess ? nil : Date().addingTimeInterval(-4 * 60)
        }
        #endif
        return actual
    }

    static func parse(_ value: String) -> FolderSyncController.Status? {
        switch value.lowercased().replacingOccurrences(of: "-", with: "") {
        case "off": .off
        case "needsfolderaccess", "access": .needsFolderAccess
        case "notinicloud": .notInICloud
        case "waitingforkey", "key": .waitingForKey
        case "syncing": .syncing
        case "uptodate", "on": .upToDate
        case "error": .error("The sync folder couldn’t be read. Check that iCloud Drive is on and try again.")
        default: nil
        }
    }
}
