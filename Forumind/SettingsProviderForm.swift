import SwiftUI

// Shared pieces of AI model and provider setup, used by onboarding step 3,
// the "Connect an AI provider" sheet, and Settings › AI models. Each piece
// works on a `ModelScope` (one role, or both during onboarding) or on one
// provider's credentials.

/// Result of "Test & save".
enum ProviderTestState: Equatable {
    case idle
    case testing
    case success
    case failure(String)
}

/// Bindings into one provider's key and address.
@MainActor
struct ProviderBindings {
    let app: AppModel
    let provider: AIProvider

    var configuration: ProviderConfiguration { app.configurationBinding(for: provider) }

    func binding(_ keyPath: WritableKeyPath<ProviderConfiguration, String>) -> Binding<String> {
        let app = app
        let provider = provider
        return Binding(
            get: { app.configurationBinding(for: provider)[keyPath: keyPath] },
            set: { value in
                var updated = app.configurationBinding(for: provider)
                updated[keyPath: keyPath] = value
                app.setConfiguration(updated, for: provider)
            }
        )
    }
}

/// Bindings into the model a scope (one role, or both) runs with.
@MainActor
struct ModelScopeBindings {
    let app: AppModel
    let scope: ModelScope

    var selection: ModelSelection { app.selection(for: scope.primaryRole) }
    var provider: AIProvider { selection.provider }
    var providerBindings: ProviderBindings { ProviderBindings(app: app, provider: provider) }

    /// The model name; typing sets it for every role in the scope.
    var model: Binding<String> {
        let app = app
        let scope = scope
        return Binding(
            get: { app.selection(for: scope.primaryRole).model },
            set: { value in
                let provider = app.selection(for: scope.primaryRole).provider
                app.selectModel(ModelSelection(provider: provider, model: value), for: scope)
            }
        )
    }
}

/// Monogram tile for a provider (no brand artwork).
struct ProviderBadge: View {
    let provider: AIProvider
    var size: CGFloat = 36

    var body: some View {
        let local = provider.isLocalServer
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            .fill(local ? AnyShapeStyle(DCTheme.chatTint) : AnyShapeStyle(DCTheme.brandGradient))
            .frame(width: size, height: size)
            .overlay {
                if provider.isAppleIntelligence {
                    Image(systemName: "sparkles")
                        .font(.system(size: size * 0.46, weight: .semibold))
                        .foregroundStyle(.white)
                } else if local {
                    Image(systemName: "desktopcomputer")
                        .font(.system(size: size * 0.44, weight: .semibold))
                        .foregroundStyle(.white)
                } else {
                    Text(String(provider.displayName.prefix(1)))
                        .font(.system(size: size * 0.48, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                }
            }
            .accessibilityHidden(true)
    }
}

/// Menu that picks the provider for a scope's roles, with a "good to know"
/// per item.
struct ProviderMenu<Label: View>: View {
    @ObservedObject var app: AppModel
    let scope: ModelScope
    @ViewBuilder var label: () -> Label

    var body: some View {
        Menu {
            Section("Built in — no key") {
                item(.appleIntelligence)
            }
            Section("Hosted — needs an API key") {
                ForEach(AIProvider.allCases.filter(\.requiresAPIKey)) { item($0) }
            }
            Section("On your computer — no key") {
                ForEach(AIProvider.allCases.filter(\.isLocalServer)) { item($0) }
            }
        } label: {
            label()
        }
        .accessibilityIdentifier("providerMenu")
    }

    private func item(_ provider: AIProvider) -> some View {
        Button {
            DCHaptics.tap()
            app.selectProvider(provider, for: scope)
        } label: {
            if provider == app.selection(for: scope.primaryRole).provider {
                SwiftUI.Label {
                    Text(provider.displayName)
                    Text(subtitle(provider))
                } icon: {
                    Image(systemName: "checkmark")
                }
            } else {
                Text(provider.displayName)
                Text(subtitle(provider))
            }
        }
    }

    /// Apple Intelligence shows its live status; others their "good to know".
    private func subtitle(_ provider: AIProvider) -> String {
        guard provider.isAppleIntelligence else { return ProviderGuide.guide(for: provider).blurb }
        return String(
            localized: "\(app.appleIntelligenceStatus.title) · No API key needed · Private",
            comment: "Provider menu subtitle for Apple Intelligence: its status, then two short facts"
        )
    }
}

/// API key field with a Paste button and a Keychain status line.
struct APIKeyField: View {
    @ObservedObject var app: AppModel
    let provider: AIProvider
    var showsStatus = true
    /// Draws the rounded field surface around the text field only.
    var carded = false

    private var bindings: ProviderBindings { ProviderBindings(app: app, provider: provider) }

    var body: some View {
        VStack(alignment: .leading, spacing: carded ? DCTheme.spacingS : 6) {
            if carded { field.fieldCard() } else { field }
            if showsStatus {
                let empty = bindings.configuration.apiKey.isEmpty
                SwiftUI.Label(
                    empty ? "No API key saved" : (app.settings.syncAPIKeys ? "Stored securely in iCloud Keychain" : "Stored securely in the iOS Keychain"),
                    systemImage: empty ? "key.slash" : "lock.shield.fill"
                )
                .font(.caption)
                .foregroundStyle(empty ? Color.secondary : DCTheme.success)
            }
        }
    }

    private var field: some View {
            HStack(spacing: DCTheme.spacingS) {
                SecureField("Paste your API key", text: bindings.binding(\.apiKey))
                    .textContentType(.password)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .submitLabel(.done)
                    .accessibilityIdentifier("apiKeyField")
                PasteButton(payloadType: String.self) { strings in
                    guard let first = strings.first else { return }
                    let key = first.trimmingCharacters(in: .whitespacesAndNewlines)
                    Task { @MainActor in bindings.binding(\.apiKey).wrappedValue = key }
                }
                .labelStyle(.iconOnly)
                .buttonBorderShape(.roundedRectangle)
                .controlSize(.small)
                .tint(DCTheme.brandBlue)
                .accessibilityIdentifier("pasteAPIKey")
            }
    }
}

/// Text field for a scope's model, with "Choose from list" backed by model
/// discovery.
struct ModelField: View {
    @ObservedObject var app: AppModel
    let scope: ModelScope
    @State private var showingList = false

    private var bindings: ModelScopeBindings { ModelScopeBindings(app: app, scope: scope) }

    var body: some View {
        HStack(spacing: DCTheme.spacingS) {
            TextField(bindings.provider.defaultModel, text: bindings.model)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.done)
                .accessibilityIdentifier("modelField")
            Button {
                showingList = true
            } label: {
                Image(systemName: "list.bullet")
                    .font(.body.weight(.semibold))
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.roundedRectangle)
            .controlSize(.small)
            .tint(DCTheme.brandBlue)
            .accessibilityLabel("Choose from list")
            .accessibilityIdentifier("chooseModel")
        }
        .sheet(isPresented: $showingList) {
            ModelListSheet(app: app, scope: scope)
        }
    }
}

/// Searchable list of the provider's models (discovered on open), plus
/// favorites, the other role's model, and the default.
struct ModelListSheet: View {
    @ObservedObject var app: AppModel
    let scope: ModelScope
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var loading = false
    @State private var error: String?

    private var bindings: ModelScopeBindings { ModelScopeBindings(app: app, scope: scope) }
    private var discovered: [String] { app.discoveredModels[bindings.provider] ?? [] }

    private var suggestions: [String] {
        let provider = bindings.provider
        var models = [provider.defaultModel]
        let configured = app.settings.configuration(for: provider).model
        for role in ModelRole.allCases where app.selection(for: role).provider == provider {
            models.append(app.selection(for: role).model)
        }
        models.append(configured)
        for favorite in app.settings.favoriteModels where favorite.provider == provider {
            models.append(favorite.model)
        }
        var seen = Set<String>()
        return models.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private var filtered: [String] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return discovered }
        return discovered.filter { $0.localizedCaseInsensitiveContains(trimmed) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Suggested") {
                    ForEach(suggestions, id: \.self) { row($0) }
                }
                Section {
                    if loading {
                        HStack(spacing: DCTheme.spacingS) {
                            ProgressView()
                            Text("Loading models…").foregroundStyle(.secondary)
                        }
                    } else if let error {
                        VStack(alignment: .leading, spacing: 6) {
                            SwiftUI.Label("Couldn’t load models", systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(DCTheme.warning)
                            Text(error).font(.footnote).foregroundStyle(.secondary)
                            Button("Try again") { Task { await load() } }
                        }
                    } else if filtered.isEmpty {
                        Text(query.isEmpty ? "No models found." : "No models match “\(query)”.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(filtered, id: \.self) { row($0) }
                    }
                } header: {
                    Text("Available from \(bindings.provider.displayName)")
                } footer: {
                    if bindings.provider.requiresAPIKey && bindings.providerBindings.configuration.apiKey.isEmpty {
                        Text("Add your API key to see every model.")
                    }
                }
            }
            .searchable(text: $query, prompt: "Search models")
            .navigationTitle("Choose a model")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
            }
            .task {
                if discovered.isEmpty { await load() }
            }
        }
        .presentationDetents([.medium, .large])
        .dcFormSheet()
    }

    private func row(_ model: String) -> some View {
        Button {
            DCHaptics.tap()
            bindings.model.wrappedValue = model
            dismiss()
        } label: {
            HStack {
                Text(model)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                Spacer()
                if model == bindings.selection.model {
                    Image(systemName: "checkmark").foregroundStyle(DCTheme.brandBlue)
                }
            }
        }
    }

    private func load() async {
        loading = true
        error = nil
        error = await app.loadModelsInline(provider: bindings.provider)
        loading = false
    }
}

/// Inline result line for "Test & save".
struct ProviderTestStatusView: View {
    let state: ProviderTestState

    var body: some View {
        switch state {
        case .idle:
            EmptyView()
        case .testing:
            HStack(spacing: DCTheme.spacingS) {
                ProgressView().controlSize(.small)
                Text("Testing connection…")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        case .success:
            SwiftUI.Label("Connected — you’re ready to go.", systemImage: "checkmark.circle.fill")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(DCTheme.success)
                .accessibilityIdentifier("providerTestSuccess")
        case .failure(let message):
            VStack(alignment: .leading, spacing: 2) {
                SwiftUI.Label("Couldn’t connect", systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(DCTheme.danger)
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("providerTestFailure")
        }
    }
}

extension AppModel {
    /// Saves a scope's model and its provider's settings (Keychain for
    /// keys), then tests the provider.
    func testAndSaveProvider(scope: ModelScope = .role(.assistant)) async -> ProviderTestState {
        let role = scope.primaryRole
        let selection = selection(for: role)
        let provider = selection.provider
        var model = selection.model.trimmingCharacters(in: .whitespacesAndNewlines)
        if model.isEmpty { model = provider.defaultModel }
        if model != selection.model { selectModel(ModelSelection(provider: provider, model: model), for: scope) }
        return await testAndSaveProvider(provider, role: role)
    }

    /// Saves a provider's key and address (trimmed), then tests them. With
    /// `role`, the result is stale when that role switches provider meanwhile.
    func testAndSaveProvider(_ provider: AIProvider, role: ModelRole? = nil) async -> ProviderTestState {
        var configuration = settings.configuration(for: provider)
        configuration.apiKey = configuration.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        configuration.baseURL = configuration.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if configuration.baseURL.isEmpty { configuration.baseURL = provider.defaultBaseURL }
        if configuration != settings.configuration(for: provider) { setConfiguration(configuration, for: provider) }
        if provider.requiresAPIKey && configuration.apiKey.isEmpty {
            return .failure(String(localized: "Paste your \(provider.displayName) API key first.", comment: "Test & save without a key; the argument is the provider name"))
        }
        saveSettings()
        flushPendingSaves()
        let result = if let role { await testConnection(for: role) } else { await testConnection(provider: provider) }
        switch result {
        case .success:
            DCHaptics.success()
            return .success
        case .failure(let message):
            DCHaptics.warning()
            return .failure(message)
        case .stale:
            // The provider, key, or address changed while testing.
            return .idle
        }
    }
}

/// Card-style provider setup (onboarding and the "Connect an AI provider" sheet).
struct ProviderSetupForm: View {
    @ObservedObject var app: AppModel
    /// Onboarding sets both roles; the setup sheet the role(s) not ready.
    let scope: ModelScope
    @Binding var state: ProviderTestState
    @State private var showingAdvanced = false

    private var scopeBindings: ModelScopeBindings { ModelScopeBindings(app: app, scope: scope) }
    private var bindings: ProviderBindings { scopeBindings.providerBindings }
    private var provider: AIProvider { scopeBindings.provider }
    private var guide: ProviderGuide { ProviderGuide.guide(for: provider) }

    var body: some View {
        VStack(alignment: .leading, spacing: DCTheme.spacingL) {
            providerPicker
            credentials
            if !provider.isAppleIntelligence { modelSection }
            testSection
        }
        .onChange(of: provider) {
            state = .idle
            showingAdvanced = false
        }
        .onAppear {
            // New users get Apple Intelligence when it's usable (once).
            app.applyAppleIntelligenceDefaultIfNeeded()
        }
    }

    private var providerPicker: some View {
        VStack(alignment: .leading, spacing: DCTheme.spacingS) {
            fieldLabel("Provider")
            ProviderMenu(app: app, scope: scope) {
                HStack(spacing: DCTheme.spacingM) {
                    ProviderBadge(provider: provider)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(provider.displayName)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text(guide.blurb)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
                .dcCard()
            }
            .buttonStyle(.plain)
            Text(app.appleIntelligenceStatus.isAvailable
                ? "Not sure? Apple Intelligence works right away. If you already pay for a provider, you can use it instead."
                : "Not sure? If you already pay for one, use it. OpenRouter is an easy start.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var credentials: some View {
        if provider.isAppleIntelligence {
            AppleIntelligenceStatusView(app: app, carded: true)
        } else if provider.requiresAPIKey {
            VStack(alignment: .leading, spacing: DCTheme.spacingS) {
                HStack {
                    fieldLabel("API key")
                    Spacer()
                    Link(destination: guide.link) {
                        SwiftUI.Label("Get a key", systemImage: "arrow.up.right.square")
                            .font(.footnote.weight(.semibold))
                    }
                    .accessibilityHint(guide.linkTitle)
                    .accessibilityIdentifier("getAPIKeyLink")
                }
                APIKeyField(app: app, provider: provider, carded: true)
                DisclosureGroup(isExpanded: $showingAdvanced) {
                    baseURLField.fieldCard().padding(.top, DCTheme.spacingS)
                } label: {
                    Text("Advanced: custom base URL")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .tint(.secondary)
            }
        } else {
            VStack(alignment: .leading, spacing: DCTheme.spacingS) {
                HStack {
                    fieldLabel("Server address")
                    Spacer()
                    Link(destination: guide.link) {
                        SwiftUI.Label(guide.linkTitle, systemImage: "arrow.down.circle")
                            .font(.footnote.weight(.semibold))
                    }
                }
                baseURLField.fieldCard()
                if let note = guide.note {
                    SwiftUI.Label(note, systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var baseURLField: some View {
        TextField(provider.defaultBaseURL, text: bindings.binding(\.baseURL))
            .textContentType(.URL)
            .keyboardType(.URL)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .submitLabel(.done)
            .accessibilityIdentifier("baseURLField")
    }

    private var modelSection: some View {
        VStack(alignment: .leading, spacing: DCTheme.spacingS) {
            fieldLabel("Model")
            ModelField(app: app, scope: scope).fieldCard()
            Text("A good default is filled in. Tap the list button to see every model.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var testSection: some View {
        VStack(alignment: .leading, spacing: DCTheme.spacingS) {
            Button {
                Task {
                    state = .testing
                    state = await app.testAndSaveProvider(scope: scope)
                }
            } label: {
                HStack(spacing: DCTheme.spacingS) {
                    if state == .testing {
                        ProgressView().tint(DCTheme.brandBlue)
                    } else {
                        Image(systemName: state == .success ? "checkmark.circle.fill" : "bolt.horizontal.circle")
                    }
                    Text(state == .success ? "Saved" : "Test & save")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(DCActionButtonStyle(prominent: false))
            .disabled(state == .testing)
            .accessibilityIdentifier("testAndSaveProvider")
            ProviderTestStatusView(state: state)
                .animation(DCMotion.quick, value: state)
        }
    }

    private func fieldLabel(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.primary)
    }
}

private struct FieldCardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, DCTheme.spacingM)
            .frame(minHeight: DCTheme.controlHeight + 4)
            .background(
                DCTheme.surface,
                in: RoundedRectangle(cornerRadius: DCTheme.controlCornerRadius, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: DCTheme.controlCornerRadius, style: .continuous)
                    .stroke(DCTheme.border)
            }
    }
}

extension View {
    /// Rounded surface around a text field (onboarding and cards).
    func fieldCard() -> some View {
        modifier(FieldCardModifier())
    }
}

/// Sheet shown when a shared link needs an AI provider first. It sets up
/// the role the link needs, or both roles when neither is ready.
struct ProviderSetupSheet: View {
    @ObservedObject var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var state: ProviderTestState = .idle
    /// Fixed when the sheet opens, so it doesn't change while the user types.
    @State private var scope: ModelScope

    init(app: AppModel, role: ModelRole) {
        self.app = app
        _scope = State(initialValue: app.isProviderReady(for: role.other) ? .role(role) : .both)
    }

    private var intro: String {
        switch scope {
        case .both:
            String(localized: "Forumind uses an AI provider you choose to summarize and answer. Connect one to continue.")
        case .role(let role):
            String(localized: "\(role.title) uses its own model. Choose one to continue; you can change it in Settings › AI models.", comment: "Setup sheet for one model role. The placeholder is the role's name: Summaries & chat, or Ask the forum.")
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DCTheme.spacingL) {
                    Text(intro)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    ProviderSetupForm(app: app, scope: scope, state: $state)
                }
                .padding(DCTheme.spacingL)
                .frame(maxWidth: DCTheme.contentMaxWidth)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(DCTheme.pageBackground)
            .navigationTitle("Connect an AI provider")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Later") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                        .disabled(!scope.roles.allSatisfy { app.isProviderReady(for: $0) })
                }
            }
        }
        .onChange(of: state) {
            if state == .success {
                Task {
                    try? await Task.sleep(for: .milliseconds(700))
                    dismiss()
                }
            }
        }
        .dcFormSheet()
    }
}
