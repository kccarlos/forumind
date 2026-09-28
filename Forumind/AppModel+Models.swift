import Foundation

// MARK: - Model roles
//
// Two defaults, each a provider and a model (`AppSettings`):
// - `assistantModel`: summaries, chat, watched-topic refreshes, and the
//   agent's `summarize_topic` tool (bulk summarizing on the low-cost model).
// - `agentModel`: Ask the forum planning, answers, and follow-ups.
//
// They are separate top-level settings, so iCloud sync merges them one by
// one: two devices that change different roles both keep their change.
// Credentials and the base URL stay per provider (`configurations`), shared
// by both roles. Favorites are provider + model pairs, shared too.
//
// Builds from before roles read `selectedProvider` and
// `configurations[selectedProvider].model`. Both stay equal to the assistant
// role (`reconcileModelRoles`), and a change an older build makes to them is
// taken into the assistant role.

extension ModelRole {
    /// Summary and Chat share the assistant model; Ask the forum has its own.
    init(mode: AssistantMode) {
        self = mode == .agent ? .agent : .assistant
    }

    var other: ModelRole { self == .assistant ? .agent : .assistant }

    /// The role's name in Settings and the model picker.
    var title: String {
        switch self {
        case .assistant: String(localized: "Summaries & chat", comment: "AI model role: the model used for summaries and chat")
        case .agent: String(localized: "Ask the forum", comment: "AI model role: the model used by Ask the forum (the research agent)")
        }
    }

    /// Title of the assistant header's model switcher.
    var switcherTitle: String {
        switch self {
        case .assistant: String(localized: "Summaries & chat model", comment: "Assistant menu: switches the model used for summaries and chat")
        case .agent: String(localized: "Ask the forum model", comment: "Assistant menu: switches the model used by Ask the forum")
        }
    }

    /// What the role does and which kind of model suits it.
    var hint: String {
        switch self {
        case .assistant: String(localized: "Every summary and chat answer, and summaries Ask the forum writes along the way. A fast, low-cost model works well.", comment: "Settings › AI models: what the summaries & chat model is used for")
        case .agent: String(localized: "Plans searches, reads topics, and writes answers. A stronger reasoning model works best.", comment: "Settings › AI models: what the Ask the forum model is used for")
        }
    }

    var systemImage: String {
        switch self {
        case .assistant: "text.bubble"
        case .agent: "sparkle.magnifyingglass"
        }
    }
}

/// Which roles a model choice applies to. Onboarding sets both; Settings
/// picks one role at a time.
enum ModelScope: Hashable {
    case role(ModelRole)
    case both

    var roles: [ModelRole] {
        switch self {
        case .role(let role): [role]
        case .both: ModelRole.allCases
        }
    }

    /// The role whose selection the scope's controls show.
    var primaryRole: ModelRole {
        switch self {
        case .role(let role): role
        case .both: .assistant
        }
    }
}

extension AppSettings {
    func model(for role: ModelRole) -> ModelSelection {
        switch role {
        case .assistant: assistantModel
        case .agent: agentModel
        }
    }

    /// The roles that run on `provider`.
    func roles(using provider: AIProvider) -> [ModelRole] {
        ModelRole.allCases.filter { model(for: $0).provider == provider }
    }

    /// The provider's settings (key, base URL) with the role's model.
    func configuration(for role: ModelRole) -> ProviderConfiguration {
        let selection = model(for: role)
        var configuration = configuration(for: selection.provider)
        configuration.model = selection.model
        return configuration
    }

    mutating func setModel(_ selection: ModelSelection, for role: ModelRole) {
        let old = self
        switch role {
        case .assistant: assistantModel = selection
        case .agent: agentModel = selection
        }
        reconcileModelRoles(from: old)
    }

    /// Keeps the settings older builds read (`selectedProvider` and that
    /// provider's configured model) equal to the assistant role:
    /// - the assistant role changed: they follow it;
    /// - otherwise `selectedProvider` changed (an older build, or a synced
    ///   edit from one): the assistant role takes that provider and its model;
    /// - otherwise that provider's model changed (same): the assistant role
    ///   takes the model.
    /// The agent role is never touched, and never writes a configuration's
    /// model, so the slot older builds read always holds the assistant model.
    mutating func reconcileModelRoles(from old: AppSettings) {
        if assistantModel != old.assistantModel {
            selectedProvider = assistantModel.provider
            var configuration = configuration(for: assistantModel.provider)
            if configuration.model != assistantModel.model {
                configuration.model = assistantModel.model
                setConfiguration(configuration, for: assistantModel.provider)
            }
        } else if selectedProvider != old.selectedProvider {
            assistantModel = ModelSelection(
                provider: selectedProvider,
                model: configuration(for: selectedProvider).model
            )
        } else {
            let model = configuration(for: selectedProvider).model
            if model != old.configuration(for: selectedProvider).model, model != assistantModel.model {
                assistantModel.model = model
            }
        }
    }
}

extension AppModel {
    /// The role of the Assistant's current mode.
    var currentRole: ModelRole { ModelRole(mode: assistantMode) }

    func selection(for role: ModelRole) -> ModelSelection {
        settings.model(for: role)
    }

    /// The role's provider has what it needs to run: a model, and a key
    /// unless it needs none; Apple Intelligence must be available now.
    func isProviderReady(for role: ModelRole) -> Bool {
        let selection = selection(for: role)
        if selection.provider.isAppleIntelligence { return appleIntelligenceStatus.isAvailable }
        let configuration = settings.configuration(for: role)
        let hasModel = !configuration.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasKey = !selection.provider.requiresAPIKey
            || !configuration.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return hasModel && hasKey
    }

    /// Both roles can run.
    var isProviderReady: Bool {
        ModelRole.allCases.allSatisfy { isProviderReady(for: $0) }
    }

    /// The model name to show: Apple Intelligence shows its live backend
    /// ("On-device") instead of the stored placeholder.
    func modelLabel(for role: ModelRole) -> String {
        let selection = selection(for: role)
        return selection.provider.isAppleIntelligence
            ? (appleIntelligenceStatus.backend?.displayName ?? "")
            : selection.model
    }

    /// "Provider · model" for headers and Settings.
    func providerSummary(for role: ModelRole) -> String {
        let provider = selection(for: role).provider
        let model = modelLabel(for: role)
        return model.isEmpty ? provider.displayName : "\(provider.displayName) · \(model)"
    }

    /// The current mode's model, for the Assistant header.
    var providerSummary: String { providerSummary(for: currentRole) }

    /// Both roles use the same provider and model.
    var rolesShareModel: Bool { settings.assistantModel == settings.agentModel }

    /// Sets the model for every role in `scope`.
    func selectModel(_ selection: ModelSelection, for scope: ModelScope) {
        var updated = settings
        for role in scope.roles { updated.setModel(selection, for: role) }
        if updated != settings { settings = updated }
        saveSettings()
    }

    /// Switches the scope to `provider` with its suggested model.
    func selectProvider(_ provider: AIProvider, for scope: ModelScope) {
        // With `.both`, a role still on another provider moves too.
        guard scope.roles.contains(where: { selection(for: $0).provider != provider }) else { return }
        selectModel(
            ModelSelection(provider: provider, model: suggestedModel(for: provider, role: scope.primaryRole)),
            for: scope
        )
    }

    /// The model to preselect when a role switches to `provider`: what the
    /// other role uses there, else the provider's last used model (kept in
    /// its configuration), else its default.
    func suggestedModel(for provider: AIProvider, role: ModelRole) -> String {
        if provider.isAppleIntelligence { return provider.defaultModel }
        let other = selection(for: role.other)
        if other.provider == provider, !other.model.isEmpty { return other.model }
        let configured = settings.configuration(for: provider).model
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return configured.isEmpty ? provider.defaultModel : configured
    }

    /// Switches one role to a favorite; the other role is left as it is.
    func activateFavorite(_ favorite: FavoriteModel, for role: ModelRole) {
        selectModel(ModelSelection(provider: favorite.provider, model: favorite.model), for: .role(role))
    }

    func isFavorite(_ selection: ModelSelection) -> Bool {
        settings.favoriteModels.contains(FavoriteModel(provider: selection.provider, model: selection.model))
    }

    /// Stars the role's current model (up to 30 favorites).
    func addCurrentFavorite(for role: ModelRole) {
        let selection = selection(for: role)
        let model = selection.model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty, !selection.provider.isAppleIntelligence else { return }
        let favorite = FavoriteModel(provider: selection.provider, model: model)
        guard !settings.favoriteModels.contains(favorite) else { return }
        settings.favoriteModels.append(favorite)
        settings.favoriteModels = Array(settings.favoriteModels.prefix(30))
        saveSettings()
    }

    /// Removes a favorite. A role that uses it keeps its model.
    func removeFavorite(_ favorite: FavoriteModel) {
        settings.favoriteModels.removeAll { $0 == favorite }
        saveSettings()
    }

    /// Gives `role.other` the same provider and model as `role`.
    func useSameModel(as role: ModelRole) {
        selectModel(selection(for: role), for: .role(role.other))
    }
}
