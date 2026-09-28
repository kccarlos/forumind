import SwiftUI

/// Settings › AI models: the model for each role (Summaries & chat, Ask the
/// forum), each provider's key and address, and favorite models.
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
                    Menu {
                        ForEach(ModelRole.allCases) { role in
                            Button(String(
                                localized: "Use \(app.providerSummary(for: role)) for both",
                                comment: "Settings › AI models: gives both roles this model. The placeholder is a provider and model, e.g. OpenRouter · kimi-k2."
                            )) {
                                DCHaptics.tap()
                                app.useSameModel(as: role)
                            }
                        }
                    } label: {
                        Label("Use the same model for both", systemImage: "equal.circle")
                    }
                    .accessibilityIdentifier("useSameModel")
                }
            } header: {
                Text("Models")
            } footer: {
                Text("Use a fast, low-cost model for summaries and chat, and a stronger reasoning model for Ask the forum.")
            }

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

            FavoriteModelsSection(app: app)
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

/// A provider's row: which roles use it and whether it has a key.
private struct ProviderRow: View {
    @ObservedObject var app: AppModel
    let provider: AIProvider

    var body: some View {
        HStack(spacing: DCTheme.spacingM) {
            ProviderBadge(provider: provider, size: 29)
            VStack(alignment: .leading, spacing: 2) {
                Text(provider.displayName)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var detail: String {
        var parts = app.settings.roles(using: provider).map(\.title)
        if provider.isAppleIntelligence {
            parts.append(app.appleIntelligenceStatus.title)
        } else if provider.requiresAPIKey {
            parts.append(app.settings.configuration(for: provider).apiKey.isEmpty
                ? String(localized: "No API key", comment: "Settings › AI models, provider row: no key saved for this provider")
                : String(localized: "Key saved", comment: "Settings › AI models, provider row: a key is saved for this provider"))
        } else {
            parts.append(String(localized: "On your computer", comment: "Settings › AI models, provider row: a model server on the user's own computer"))
        }
        return parts.joined(separator: " · ")
    }
}

/// Favorites are provider + model pairs, shared by both roles. Tapping one
/// offers the role(s) to use it for; removing one leaves the roles as they are.
private struct FavoriteModelsSection: View {
    @ObservedObject var app: AppModel

    var body: some View {
        Section {
            if app.settings.favoriteModels.isEmpty {
                Text("Star a model on a role’s page to switch to it quickly here and in the assistant.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(app.settings.favoriteModels) { favorite in
                    Menu {
                        ForEach(ModelRole.allCases) { role in
                            Button {
                                DCHaptics.tap()
                                app.activateFavorite(favorite, for: role)
                            } label: {
                                Text(String(localized: "Use for \(role.title)", comment: "Favorite model menu: use it for a role. The placeholder is Summaries & chat, or Ask the forum."))
                            }
                        }
                        Button {
                            DCHaptics.tap()
                            app.selectModel(ModelSelection(provider: favorite.provider, model: favorite.model), for: .both)
                        } label: {
                            Text("Use for both")
                        }
                        Button(role: .destructive) {
                            app.removeFavorite(favorite)
                        } label: {
                            Label("Remove from favorites", systemImage: "star.slash")
                        }
                    } label: {
                        FavoriteModelRow(app: app, favorite: favorite)
                    }
                    .swipeActions {
                        Button("Remove", role: .destructive) { app.removeFavorite(favorite) }
                    }
                }
            }
        } header: {
            Text("Favorite models")
        } footer: {
            if !app.settings.favoriteModels.isEmpty {
                Text("Tap to use a favorite. Swipe left to remove.")
            }
        }
    }
}

private struct FavoriteModelRow: View {
    @ObservedObject var app: AppModel
    let favorite: FavoriteModel

    private var roles: [ModelRole] {
        ModelRole.allCases.filter {
            app.selection(for: $0) == ModelSelection(provider: favorite.provider, model: favorite.model)
        }
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(favorite.model)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(([favorite.provider.displayName] + roles.map(\.title)).joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if !roles.isEmpty {
                Image(systemName: "checkmark").foregroundStyle(DCTheme.brandBlue)
            }
        }
        .contentShape(Rectangle())
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
                    Button {
                        DCHaptics.tap()
                        if app.isFavorite(selection) {
                            app.removeFavorite(FavoriteModel(provider: provider, model: selection.model))
                        } else {
                            app.addCurrentFavorite(for: role)
                        }
                    } label: {
                        Label(app.isFavorite(selection) ? "Remove from favorites" : "Add to favorites", systemImage: app.isFavorite(selection) ? "star.fill" : "star")
                    }
                    .disabled(selection.model.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityIdentifier("toggleFavoriteModel")
                }
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
                    ForEach(app.settings.favoriteModels) { favorite in
                        Button {
                            DCHaptics.tap()
                            app.activateFavorite(favorite, for: role)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(favorite.model)
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Text(favorite.provider.displayName)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if ModelSelection(provider: favorite.provider, model: favorite.model) == selection {
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
