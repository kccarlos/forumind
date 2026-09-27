import SwiftUI

// Settings › iCloud Sync, and the status text shared by Settings and the
// onboarding sync step. The engine is `CloudSyncController`
// (`app.cloudSync`); see docs/SYNC.md.

/// What the UI says about a sync status (pure; unit-tested).
struct SyncStatusPresentation: Equatable {
    enum Action: Equatable {
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

    init(_ status: CloudSyncController.Status) {
        switch status {
        case .off:
            self.init(
                title: "Sync is off",
                detail: "Turn on Sync with iCloud to keep your forums, summaries and chats on your iPhone and iPad.",
                symbol: "icloud.slash",
                tint: .secondary,
                shortLabel: "Off"
            )
        case .noAccount:
            self.init(
                title: "Not signed in to iCloud",
                detail: "Sign in to iCloud in the Settings app to sync across your devices.",
                symbol: "person.crop.circle.badge.exclamationmark",
                tint: DCTheme.warning,
                shortLabel: "Not signed in"
            )
        case .restricted:
            self.init(
                title: "iCloud isn’t available to Forumind",
                detail: "iCloud is turned off for Forumind in Settings › [your name] › iCloud.",
                symbol: "exclamationmark.icloud",
                tint: DCTheme.warning,
                shortLabel: "Unavailable"
            )
        case .unavailable(let reason):
            self.init(
                title: "iCloud is unavailable",
                detail: reason,
                symbol: "icloud.slash",
                tint: DCTheme.warning,
                shortLabel: "Unavailable"
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

// MARK: - Settings root row

/// Settings root row with the sync status as its value.
struct SettingsSyncRow: View {
    @ObservedObject private var sync: CloudSyncController

    init(app: AppModel) {
        self.sync = app.cloudSync
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
    @ObservedObject private var sync: CloudSyncController
    @State private var confirmingDelete = false
    @State private var deleteError: String?
    @State private var deleting = false

    init(app: AppModel) {
        self.app = app
        self.sync = app.cloudSync
    }

    private var status: CloudSyncController.Status { SyncDebug.status(actual: sync.status) }
    private var isEnabled: Bool { SyncDebug.isEnabled(actual: sync.isEnabled) }
    private var presentation: SyncStatusPresentation { SyncStatusPresentation(status) }
    private var lastSyncedAt: Date? { SyncDebug.lastSyncedAt(actual: sync.lastSyncedAt) }
    /// On, with an account that can sync (Last synced and Sync now apply).
    private var canSync: Bool {
        switch status {
        case .syncing, .upToDate, .error: isEnabled
        case .off, .noAccount, .restricted, .unavailable: false
        }
    }

    var body: some View {
        Form {
            Section {
                SyncStatusSummary(presentation: presentation) { sync.syncNow() }
                Toggle("Sync with iCloud", isOn: Binding(
                    get: { isEnabled },
                    set: { sync.setEnabled($0) }
                ))
                .accessibilityIdentifier("syncEnabled")
            } footer: {
                Text("Your forums, summaries and chats sync across your iPhone and iPad through your own iCloud account, end-to-end encrypted.")
            }

            if canSync {
                Section {
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
                }
            }

            Section {
                Toggle("Sync API keys", isOn: syncAPIKeysBinding)
                    .accessibilityIdentifier("syncAPIKeys")
            } header: {
                Text("API keys")
            } footer: {
                Text(app.settings.syncAPIKeys
                    ? "Keys are stored in iCloud Keychain, so every device signed in to your Apple Account has them. Deleting a key in the app deletes it on your other devices too."
                    : "Keys stay in this device’s Keychain. Keys already in iCloud Keychain are left there for your other devices; turning this off doesn’t delete them.")
            }

            Section {
                SyncExplainer()
            }

            Section {
                Button(role: .destructive) {
                    confirmingDelete = true
                } label: {
                    HStack {
                        Label("Delete iCloud data", systemImage: "trash")
                        if deleting {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(deleting)
                .accessibilityIdentifier("syncDeleteCloudData")
            } footer: {
                Text("Removes Forumind’s data from iCloud on all your devices. Data on this device is kept.")
            }
        }
        .formStyle(.grouped)
        .accessibilityIdentifier("syncPage")
        .confirmationDialog(
            "Delete iCloud data?",
            isPresented: $confirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete iCloud data", role: .destructive) {
                deleting = true
                Task {
                    do {
                        try await sync.deleteCloudData()
                        DCHaptics.success()
                    } catch {
                        deleteError = error.localizedDescription
                    }
                    deleting = false
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes Forumind’s data from iCloud on all your devices. Data on this device is kept, and sync turns off here.")
        }
        .alert(
            "Couldn’t delete iCloud data",
            isPresented: Binding(get: { deleteError != nil }, set: { if !$0 { deleteError = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(deleteError ?? "")
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
}

/// Icon, title and fix for a sync status, with "Sync now" after an error.
struct SyncStatusSummary: View {
    let presentation: SyncStatusPresentation
    var iconSize: CGFloat = 40
    let perform: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DCTheme.spacingM) {
            HStack(alignment: .top, spacing: DCTheme.spacingM) {
                Group {
                    if presentation.isBusy {
                        ProgressView()
                            .frame(width: iconSize, height: iconSize)
                            .background(presentation.tint.opacity(0.14), in: RoundedRectangle(cornerRadius: iconSize * 0.28, style: .continuous))
                    } else {
                        OnboardingIconTile(symbol: presentation.symbol, tint: presentation.tint, size: iconSize)
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
                    }
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("syncStatus")
            if presentation.action != nil, let title = presentation.actionTitle {
                Button(title, action: perform)
                    .buttonStyle(DCActionButtonStyle(prominent: false))
                    .accessibilityIdentifier("syncStatusAction")
            }
        }
        .padding(.vertical, DCTheme.spacingXS)
    }
}

/// "What syncs": what syncs, what stays, and privacy.
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
                    detail: "The work queue and activity log, cached forum pages, the browser bar position, and whether sync is on here."
                )
                OnboardingFeatureRow(
                    symbol: "lock.fill",
                    tint: DCTheme.brandPurple,
                    title: "End-to-end encrypted",
                    detail: "Your data is stored in your own iCloud account and encrypted with keys only your devices have. Neither Apple nor the developer can read it."
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
            Label("What syncs", systemImage: "info.circle")
        }
        .accessibilityIdentifier("syncHowItWorks")
    }
}

// MARK: - DEBUG screenshots

/// DEBUG `-dc-sync-status <off|noAccount|restricted|unavailable|syncing|upToDate|error>`
/// overrides the status shown by the sync UI (screenshots only; the engine
/// is untouched). The toggle and a last-synced time follow it.
enum SyncDebug {
    private static var override: CloudSyncController.Status? {
        #if DEBUG
        if let value = OnboardingDebug.value(after: "-dc-sync-status") { return parse(value) }
        #endif
        return nil
    }

    static func status(actual: CloudSyncController.Status) -> CloudSyncController.Status {
        override ?? actual
    }

    static func isEnabled(actual: Bool) -> Bool {
        guard let override else { return actual }
        return override != .off
    }

    static func lastSyncedAt(actual: Date?) -> Date? {
        guard let override else { return actual }
        switch override {
        case .upToDate, .syncing, .error: return Date().addingTimeInterval(-4 * 60)
        default: return nil
        }
    }

    static func parse(_ value: String) -> CloudSyncController.Status? {
        switch value.lowercased().replacingOccurrences(of: "-", with: "") {
        case "off": .off
        case "noaccount": .noAccount
        case "restricted": .restricted
        case "unavailable": .unavailable("iCloud is temporarily unavailable. Forumind will try again automatically.")
        case "syncing": .syncing
        case "uptodate", "on": .upToDate
        case "error": .error("Couldn’t reach iCloud. Check your connection and try again.")
        default: nil
        }
    }
}
