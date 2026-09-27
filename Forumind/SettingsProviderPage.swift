import SwiftUI

/// Settings › AI provider: provider, key, base URL, model (with discovery),
/// Test & save, and favorite models.
struct SettingsProviderPage: View {
    @ObservedObject var app: AppModel
    @State private var testState: ProviderTestState = .idle

    private var bindings: ProviderBindings { ProviderBindings(app: app) }
    private var provider: AIProvider { app.settings.selectedProvider }
    private var guide: ProviderGuide { ProviderGuide.guide(for: provider) }

    private var isFavorite: Bool {
        let model = bindings.configuration.model.trimmingCharacters(in: .whitespaces)
        return app.settings.favoriteModels.contains(FavoriteModel(provider: provider, model: model))
    }

    var body: some View {
        Form {
            Section {
                statusHeader
            }

            Section {
                Picker("Provider", selection: $app.settings.selectedProvider) {
                    ForEach(AIProvider.allCases) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("providerPicker")
                Link(destination: guide.link) {
                    Label(guide.linkTitle, systemImage: provider.isAppleIntelligence ? "info.circle" : guide.isLocal ? "arrow.down.circle" : "key.horizontal")
                }
            } header: {
                Text("Service")
            } footer: {
                Text(guide.blurb)
            }

            if provider.requiresAPIKey {
                Section {
                    APIKeyField(app: app)
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
                    Text(guide.note ?? "Leave this as is unless you use a proxy or a compatible gateway.")
                }
            }

            Section {
                if provider.isAppleIntelligence {
                    AppleIntelligenceStatusView(app: app)
                } else {
                    ModelField(app: app)
                }
                Button {
                    DCHaptics.tap()
                    if isFavorite {
                        let model = bindings.configuration.model.trimmingCharacters(in: .whitespaces)
                        app.removeFavorite(FavoriteModel(provider: provider, model: model))
                    } else {
                        app.addCurrentFavorite()
                    }
                } label: {
                    Label(isFavorite ? "Remove from favorites" : "Add to favorites", systemImage: isFavorite ? "star.fill" : "star")
                }
                .disabled(bindings.configuration.model.trimmingCharacters(in: .whitespaces).isEmpty)
            } header: {
                Text("Model")
            } footer: {
                if provider.isAppleIntelligence {
                    Text("Uses Private Cloud Compute when this build and device support it, otherwise the on-device model. \(guide.note ?? "")")
                } else {
                    Text("Default: \(provider.defaultModel). Tap the list button to load every model \(provider.displayName) offers.")
                }
            }

            Section {
                Button {
                    Task {
                        testState = .testing
                        testState = await app.testAndSaveProvider()
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

            favoritesSection
        }
        .formStyle(.grouped)
        .animation(DCMotion.quick, value: testState)
        .onChange(of: app.settings.selectedProvider) {
            app.discoveredModels = []
            testState = .idle
            app.saveSettings()
        }
        .onDisappear {
            app.saveSettings()
        }
    }

    private var modelSummary: String {
        if provider.isAppleIntelligence { return app.appleIntelligenceStatus.backend?.label ?? "Not available" }
        return bindings.configuration.model.isEmpty ? "No model chosen" : bindings.configuration.model
    }

    private var statusHeader: some View {
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
            SettingsStatusPill(ready: app.isProviderReady)
        }
        .padding(.vertical, DCTheme.spacingXS)
        .accessibilityElement(children: .combine)
    }

    private var favoritesSection: some View {
        Section {
            if app.settings.favoriteModels.isEmpty {
                Text("Star a model to switch to it quickly here and in the assistant.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(app.settings.favoriteModels) { favorite in
                    Button {
                        DCHaptics.tap()
                        app.activateFavorite(favorite)
                        testState = .idle
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
                            if favorite.provider == provider && favorite.model == bindings.configuration.model {
                                Image(systemName: "checkmark").foregroundStyle(DCTheme.brandBlue)
                            }
                        }
                    }
                    .swipeActions {
                        Button("Remove", role: .destructive) { app.removeFavorite(favorite) }
                    }
                    .accessibilityHint("Switches to this model")
                }
            }
        } header: {
            Text("Favorite models")
        } footer: {
            if !app.settings.favoriteModels.isEmpty {
                Text("Tap to switch. Swipe left to remove.")
            }
        }
    }
}
