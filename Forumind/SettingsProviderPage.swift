import SwiftUI

/// Settings › AI models (ModelSettings): the model for each role (Summaries
/// & chat, Ask the forum), favorite models, and each provider's key and
/// address with its state.
struct SettingsProviderPage: View {
    @ObservedObject var app: AppModel

    var body: some View {
        Form {
            Section {
                ForEach(ModelRole.allCases) { role in
                    NavigationLink {
                        ModelRolePage(app: app, role: role)
                    } label: {
                        ModelRoleRow(app: app, role: role)
                    }
                    .accessibilityIdentifier("modelRole-\(role.rawValue)")
                }
                if !app.rolesShareModel {
                    // One button per direction: "Use X for both".
                    ForEach(ModelRole.allCases) { role in
                        Button {
                            DCHaptics.tap()
                            app.useSameModel(as: role)
                        } label: {
                            Label(
                                String(
                                    localized: "Use \(app.providerSummary(for: role)) for both",
                                    comment: "Settings › AI models: gives both roles this model. The placeholder is a provider and model, e.g. OpenRouter · kimi-k2."
                                ),
                                systemImage: "arrow.left.arrow.right"
                            )
                        }
                        .accessibilityIdentifier("useSameModel-\(role.rawValue)")
                    }
                }
            } header: {
                Text("Models")
            } footer: {
                Text("Use a fast, low-cost model for summaries and chat, and a stronger reasoning model for Ask the forum.")
            }

            FavoriteModelsSection(app: app)

            Section {
                ForEach(providers) { provider in
                    NavigationLink {
                        ProviderSettingsPage(app: app, provider: provider)
                    } label: {
                        ProviderRow(app: app, provider: provider)
                    }
                    .accessibilityIdentifier("providerRow-\(provider.rawValue)")
                }
            } header: {
                Text("Providers")
            } footer: {
                Text("Keys and server addresses belong to a provider; both models use them.")
            }
        }
        .formStyle(.grouped)
        .accessibilityIdentifier("aiModelsPage")
        .onDisappear {
            app.saveSettings()
        }
    }

    /// Providers a role uses first, then the rest in the usual order.
    private var providers: [AIProvider] {
        let used = AIProvider.allCases.filter { !app.settings.roles(using: $0).isEmpty }
        return used + AIProvider.allCases.filter { !used.contains($0) }
    }
}

/// A role's row: its name, provider · model, and whether it can run.
struct ModelRoleRow: View {
    @ObservedObject var app: AppModel
    let role: ModelRole

    var body: some View {
        HStack(spacing: DCTheme.spacingM) {
            SettingsIcon(symbol: role.systemImage, tint: role == .agent ? DCTheme.agentTint : DCTheme.summaryTint)
            VStack(alignment: .leading, spacing: 2) {
                Text(role.title)
                Text(app.providerSummary(for: role))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: DCTheme.spacingS)
            SettingsStatusPill(ready: app.isProviderReady(for: role))
        }
        .accessibilityElement(children: .combine)
    }
}

/// A provider's row: which roles use it, and its state (Built in, Key
/// added, No key, On your computer).
private struct ProviderRow: View {
    @ObservedObject var app: AppModel
    let provider: AIProvider

    var body: some View {
        HStack(spacing: DCTheme.spacingM) {
            ProviderBadge(provider: provider, size: 29)
            VStack(alignment: .leading, spacing: 2) {
                Text(provider.displayName)
                let roles = app.settings.roles(using: provider)
                if !roles.isEmpty {
                    Text(roles.map(\.title).joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: DCTheme.spacingS)
            Text(state.text)
                .font(.footnote.weight(state.tint == nil ? .regular : .semibold))
                .foregroundStyle(state.tint ?? .secondary)
                .multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
    }

    private var state: (text: String, tint: Color?) {
        if provider.isAppleIntelligence {
            // A device without Apple Intelligence says why.
            if let reason = app.appleIntelligenceStatus.reason {
                return (reason.title, ModelFavorites.hidesAppleIntelligence(app.appleIntelligenceStatus) ? nil : DCTheme.warning)
            }
            return (String(localized: "Built in", comment: "Settings › AI models, provider row: Apple Intelligence is part of the system"), nil)
        }
        if provider.requiresAPIKey {
            return app.settings.configuration(for: provider).apiKey.isEmpty
                ? (String(localized: "No key", comment: "Settings › AI models, provider row: no key saved for this provider"), DCTheme.warning)
                : (String(localized: "Key added", comment: "Settings › AI models, provider row: a key is saved for this provider"), DCTheme.success)
        }
        return (String(localized: "On your computer", comment: "Settings › AI models, provider row: a model server on the user's own computer"), nil)
    }
}

/// Favorites are provider + model pairs, shared by both roles, in the
/// user's order (Apple Intelligence like any other). Tap one to pick the
/// role to use it for, hold to use it for both, swipe to remove; removing
/// one leaves the roles as they are.
private struct FavoriteModelsSection: View {
    @ObservedObject var app: AppModel
    @State private var choosing: FavoriteModel?

    /// Roles whose model isn't starred yet, one button per distinct model.
    private var unstarred: [ModelRole] {
        var seen: [ModelSelection] = []
        return ModelRole.allCases.filter { role in
            let selection = app.selection(for: role)
            guard FavoriteModel(selection: selection) != nil, !app.isFavorite(selection),
                  !seen.contains(selection) else { return false }
            seen.append(selection)
            return true
        }
    }

    var body: some View {
        Section {
            if app.settings.favoriteModels.isEmpty {
                Text("Star a model to switch to it quickly here and in the assistant.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            ForEach(app.settings.favoriteModels) { favorite in
                row(favorite)
            }
            ForEach(unstarred) { role in
                Button {
                    DCHaptics.tap()
                    app.addCurrentFavorite(for: role)
                } label: {
                    Label(
                        String(
                            localized: "Star \(ModelPill.label(for: app.selection(for: role)))",
                            comment: "Settings › AI models: adds a role's current model to the favorites. The placeholder is a model name."
                        ),
                        systemImage: "star"
                    )
                }
                .accessibilityIdentifier("starCurrentModel-\(role.rawValue)")
            }
        } header: {
            Text("Favorite models")
        } footer: {
            if !app.settings.favoriteModels.isEmpty {
                Text("Tap to use for one model, or hold to use for both. Swipe left to remove.")
            }
        }
        .confirmationDialog(
            choosing?.title ?? "",
            isPresented: Binding(get: { choosing != nil }, set: { if !$0 { choosing = nil } }),
            titleVisibility: .visible,
            presenting: choosing
        ) { favorite in
            ForEach(ModelRole.allCases) { role in
                Button(String(localized: "Use for \(role.title)", comment: "Favorite model menu: use it for a role. The placeholder is Summaries & chat, or Ask the forum.")) {
                    DCHaptics.tap()
                    app.activateFavorite(favorite, for: role)
                }
            }
            Button("Use for both") { useForBoth(favorite) }
            Button("Remove from favorites", role: .destructive) { app.removeFavorite(favorite) }
        }
    }

    @ViewBuilder
    private func row(_ favorite: FavoriteModel) -> some View {
        let hidden = favorite.provider.isAppleIntelligence && ModelFavorites.hidesAppleIntelligence(app.appleIntelligenceStatus)
        FavoriteModelRow(app: app, favorite: favorite, hidden: hidden)
            .contentShape(Rectangle())
            .onTapGesture { if !hidden { choosing = favorite } }
            .onLongPressGesture { if !hidden { useForBoth(favorite) } }
            .accessibilityAddTraits(hidden ? [] : .isButton)
            .accessibilityAction { if !hidden { choosing = favorite } }
            .accessibilityAction(named: Text("Use for both")) { if !hidden { useForBoth(favorite) } }
            .swipeActions {
                Button("Remove", role: .destructive) { app.removeFavorite(favorite) }
            }
            .accessibilityIdentifier("favoriteModel-\(favorite.id)")
    }

    private func useForBoth(_ favorite: FavoriteModel) {
        DCHaptics.tap()
        app.selectModel(favorite.selection, for: .both)
    }
}

private struct FavoriteModelRow: View {
    @ObservedObject var app: AppModel
    let favorite: FavoriteModel
    /// Apple Intelligence on a device that can't run it: kept (favorites
    /// sync) but greyed out with the reason.
    var hidden = false

    private var roles: [ModelRole] {
        ModelRole.allCases.filter { favorite.matches(app.selection(for: $0)) }
    }

    private var readiness: ModelReadiness { app.readiness(of: favorite.selection) }

    var body: some View {
        HStack(spacing: DCTheme.spacingM) {
            Image(systemName: "star.fill")
                .foregroundStyle(DCTheme.warning)
                .imageScale(.small)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(favorite.title)
                    .foregroundStyle(hidden ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if hidden, let reason = app.appleIntelligenceStatus.reason {
                    Text(String(localized: "Hidden on this device: \(reason.title)", comment: "Settings › AI models: the Apple Intelligence favorite isn't offered on this device. The placeholder is the reason, e.g. Device not supported."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if !roles.isEmpty {
                    Text(roles.map(\.title).joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: DCTheme.spacingS)
            if !hidden {
                Text(readiness.title)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(readiness == .ready ? DCTheme.success : DCTheme.warning)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - One role

/// Picks one role's provider and model: provider, key when missing, the
/// model (typed, from the provider's list, or a favorite), and a test.
struct ModelRolePage: View {
    @ObservedObject var app: AppModel
    let role: ModelRole
    @State private var testState: ProviderTestState = .idle

    private var scope: ModelScope { .role(role) }
    private var selection: ModelSelection { app.selection(for: role) }
    private var provider: AIProvider { selection.provider }
    private var guide: ProviderGuide { ProviderGuide.guide(for: provider) }
    private var providerBinding: Binding<AIProvider> {
        let app = app
        let role = role
        return Binding(get: { app.selection(for: role).provider }, set: { app.selectProvider($0, for: .role(role)) })
    }

    var body: some View {
        Form {
            Section {
                header
            } footer: {
                Text(role.hint)
            }

            Section {
                Picker("Provider", selection: providerBinding) {
                    ForEach(AIProvider.allCases) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("providerPicker")
                NavigationLink {
                    ProviderSettingsPage(app: app, provider: provider)
                } label: {
                    Label(
                        String(localized: "\(provider.displayName) settings", comment: "Link to a provider's key and address. The placeholder is the provider's name."),
                        systemImage: provider.isAppleIntelligence ? "info.circle" : "key.horizontal"
                    )
                }
                .accessibilityIdentifier("providerSettingsLink")
            } header: {
                Text("Provider")
            } footer: {
                Text(guide.blurb)
            }

            if provider.requiresAPIKey, app.settings.configuration(for: provider).apiKey.isEmpty {
                Section {
                    APIKeyField(app: app, provider: provider)
                } header: {
                    Text("API key")
                } footer: {
                    Text("Sent only to \(provider.displayName). Both models use this key.")
                }
            }

            Section {
                if provider.isAppleIntelligence {
                    AppleIntelligenceStatusView(app: app)
                } else {
                    ModelField(app: app, scope: scope)
                }
                // Apple Intelligence is starred like any other provider.
                Button {
                    DCHaptics.tap()
                    if app.isFavorite(selection) {
                        app.removeFavorite(matching: selection)
                    } else {
                        app.addCurrentFavorite(for: role)
                    }
                } label: {
                    Label(app.isFavorite(selection) ? "Remove from favorites" : "Add to favorites", systemImage: app.isFavorite(selection) ? "star.fill" : "star")
                }
                .disabled(FavoriteModel(selection: selection) == nil)
                .accessibilityIdentifier("toggleFavoriteModel")
            } header: {
                Text("Model")
            } footer: {
                if provider.isAppleIntelligence {
                    Text("Uses Private Cloud Compute when this build and device support it, otherwise the on-device model. \(guide.note ?? "")")
                } else {
                    Text("Default: \(provider.defaultModel). Tap the list button to load every model \(provider.displayName) offers.")
                }
            }

            if !app.settings.favoriteModels.isEmpty {
                Section {
                    ForEach(app.visibleFavorites) { favorite in
                        Button {
                            DCHaptics.tap()
                            app.activateFavorite(favorite, for: role)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(ModelPill.label(for: favorite.selection))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Text(favorite.provider.displayName)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if favorite.matches(selection) {
                                    Image(systemName: "checkmark").foregroundStyle(DCTheme.brandBlue)
                                }
                            }
                        }
                        .accessibilityHint("Switches to this model")
                    }
                } header: {
                    Text("Favorite models")
                }
            }

            Section {
                Button {
                    Task {
                        testState = .testing
                        testState = await app.testAndSaveProvider(scope: scope)
                    }
                } label: {
                    HStack {
                        Label("Test & save", systemImage: "bolt.horizontal.circle")
                        Spacer()
                        if testState == .testing { ProgressView() }
                    }
                }
                .disabled(testState == .testing)
                .accessibilityIdentifier("testAndSaveProvider")
                if testState != .idle && testState != .testing {
                    ProviderTestStatusView(state: testState)
                }
            }
        }
        .formStyle(.grouped)
        .animation(DCMotion.quick, value: testState)
        .navigationTitle(role.title)
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: selection) { testState = .idle }
        .onDisappear { app.saveSettings() }
    }

    private var header: some View {
        HStack(spacing: DCTheme.spacingM) {
            ProviderBadge(provider: provider, size: 48)
            VStack(alignment: .leading, spacing: 3) {
                Text(provider.displayName).font(.headline)
                Text(modelSummary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: DCTheme.spacingS)
            SettingsStatusPill(ready: app.isProviderReady(for: role))
        }
        .padding(.vertical, DCTheme.spacingXS)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("modelRoleHeader-\(role.rawValue)")
    }

    private var modelSummary: String {
        if provider.isAppleIntelligence {
            return app.appleIntelligenceStatus.backend?.displayName
                ?? String(localized: "Not available", comment: "Settings › AI models header: Apple Intelligence can’t be used on this device")
        }
        return selection.model.isEmpty ? String(localized: "No model chosen") : selection.model
    }
}

// MARK: - One provider

/// A provider's key, server address, and connection test. Both roles use
/// these.
struct ProviderSettingsPage: View {
    @ObservedObject var app: AppModel
    let provider: AIProvider
    @State private var testState: ProviderTestState = .idle

    private var bindings: ProviderBindings { ProviderBindings(app: app, provider: provider) }
    private var guide: ProviderGuide { ProviderGuide.guide(for: provider) }
    private var usage: String {
        let roles = app.settings.roles(using: provider)
        guard !roles.isEmpty else {
            return String(localized: "Not used by either model", comment: "Provider settings: neither the Summaries & chat nor the Ask the forum model uses this provider")
        }
        return String(localized: "Used for \(roles.map(\.title).joined(separator: ", "))", comment: "Provider settings: the model roles that use this provider, e.g. Summaries & chat, Ask the forum")
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: DCTheme.spacingM) {
                    ProviderBadge(provider: provider, size: 48)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(provider.displayName).font(.headline)
                        Text(usage)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, DCTheme.spacingXS)
                .accessibilityElement(children: .combine)
                Link(destination: guide.link) {
                    Label(guide.linkTitle, systemImage: provider.isAppleIntelligence ? "info.circle" : guide.isLocal ? "arrow.down.circle" : "key.horizontal")
                }
            } footer: {
                Text(guide.blurb)
            }

            if provider.isAppleIntelligence {
                Section {
                    AppleIntelligenceStatusView(app: app)
                }
            }

            if provider.requiresAPIKey {
                Section {
                    APIKeyField(app: app, provider: provider)
                } header: {
                    Text("API key")
                } footer: {
                    Text(app.settings.syncAPIKeys
                        ? "Sent only to \(provider.displayName). Stored in iCloud Keychain, so your other devices have it too; deleting it here deletes it there as well."
                        : "Sent only to \(provider.displayName). Stored in the Keychain on this device.")
                }
            }

            if !provider.isAppleIntelligence {
                Section {
                    TextField(provider.defaultBaseURL, text: bindings.binding(\.baseURL))
                        .textContentType(.URL)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .accessibilityIdentifier("baseURLField")
                    if bindings.configuration.baseURL != provider.defaultBaseURL {
                        Button("Use default address") {
                            bindings.binding(\.baseURL).wrappedValue = provider.defaultBaseURL
                        }
                    }
                } header: {
                    Text(provider.requiresAPIKey ? "Base URL" : "Server address")
                } footer: {
                    Text(guide.note ?? String(localized: "Leave this as is unless you use a proxy or a compatible gateway."))
                }

                Section {
                    Button {
                        Task {
                            testState = .testing
                            testState = await app.testAndSaveProvider(provider)
                        }
                    } label: {
                        HStack {
                            Label("Test & save", systemImage: "bolt.horizontal.circle")
                            Spacer()
                            if testState == .testing { ProgressView() }
                        }
                    }
                    .disabled(testState == .testing)
                    .accessibilityIdentifier("testProvider")
                    if testState != .idle && testState != .testing {
                        ProviderTestStatusView(state: testState)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .animation(DCMotion.quick, value: testState)
        .navigationTitle(provider.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: bindings.configuration) { testState = .idle }
        .onDisappear { app.saveSettings() }
    }
}
