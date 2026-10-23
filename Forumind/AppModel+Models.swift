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

    /// The model menu's line under the role's name.
    var menuExplanation: String {
        switch self {
        case .assistant: String(localized: "Used for this topic. Ask the forum keeps its own model.", comment: "Model menu (summaries & chat): what this model is used for")
        case .agent: String(localized: "Plans searches and writes the answer. Summaries & chat keep their own model.", comment: "Model menu (Ask the forum): what this model is used for")
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
        isReady(selection(for: role))
    }

    /// Whether a provider and model (a role's, or a favorite) can run now.
    func readiness(of selection: ModelSelection) -> ModelReadiness {
        settings.readiness(of: selection, appleIntelligence: appleIntelligenceStatus)
    }

    func isReady(_ selection: ModelSelection) -> Bool {
        readiness(of: selection) == .ready
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
        settings.favoriteModels.contains { $0.matches(selection) }
    }

    /// Stars the role's current model (up to 30 favorites). Apple
    /// Intelligence is starred like any other provider.
    func addCurrentFavorite(for role: ModelRole) {
        guard let favorite = FavoriteModel(selection: selection(for: role)),
              let starred = ModelFavorites.adding(favorite, to: settings.favoriteModels)
        else { return }
        settings.favoriteModels = starred
        saveSettings()
    }

    /// Removes a favorite. A role that uses it keeps its model.
    func removeFavorite(_ favorite: FavoriteModel) {
        settings.favoriteModels.removeAll { $0 == favorite }
        saveSettings()
    }

    /// Unstars whichever favorite stands for `selection`.
    func removeFavorite(matching selection: ModelSelection) {
        settings.favoriteModels.removeAll { $0.matches(selection) }
        saveSettings()
    }

    /// The favorites the model menus offer, in the user's order. Apple
    /// Intelligence is hidden on devices that can't run it (the star stays:
    /// favorites sync to the user's other devices).
    var visibleFavorites: [FavoriteModel] {
        ModelFavorites.visible(settings.favoriteModels, appleIntelligence: appleIntelligenceStatus)
    }

    /// Ready models the not-ready card offers instead of the role's own.
    func readyAlternatives(for role: ModelRole) -> [FavoriteModel] {
        ModelFavorites.readyAlternatives(settings: settings, role: role, appleIntelligence: appleIntelligenceStatus)
    }

    /// "model · Ready" (or why it isn't) under a favorite in the menus.
    func favoriteDetail(_ favorite: FavoriteModel) -> String {
        let model = favorite.provider.isAppleIntelligence
            ? (appleIntelligenceStatus.backend?.displayName ?? "")
            : favorite.model
        let state = readiness(of: favorite.selection).title
        return model.isEmpty ? state : "\(model) · \(state)"
    }

    /// The model an Ask the forum search that is running now keeps, when the
    /// pill's role is the agent's (§6: a change applies to the next question).
    func runningSearchModel(for role: ModelRole) -> String? {
        let running = agentRuns.compactMap { run -> ModelSelection? in
            guard let record = activeRecord(forAgentRun: run.id), record.status == .running else { return nil }
            return ModelSelection(provider: record.provider, model: record.model)
        }
        return ModelPill.runningSearchModel(role: role, running: running)
    }

    /// Gives `role.other` the same provider and model as `role`.
    func useSameModel(as role: ModelRole) {
        selectModel(selection(for: role), for: .role(role.other))
    }
}

// MARK: - Readiness

/// Whether a provider and model can run now, and if not, what's missing.
enum ModelReadiness: Equatable {
    case ready
    case needsKey
    case needsModel
    case appleIntelligence(AppleIntelligenceUnavailableReason)
    /// Don't Allow on the AI data consent page (or withdrawn): configured,
    /// but no forum content goes to the provider.
    case aiConsentDeclined

    /// Short state for menus and Settings rows.
    var title: String {
        switch self {
        case .ready: String(localized: "Ready", comment: "AI provider status pill")
        case .needsKey: String(localized: "Needs a key", comment: "AI model state: the provider's API key is missing")
        case .needsModel, .appleIntelligence: String(localized: "Not ready", comment: "AI model state: the model can't run yet (no model chosen, or Apple Intelligence unavailable)")
        case .aiConsentDeclined: String(localized: "Not allowed", comment: "AI model state: the user chose not to send forum content to this provider")
        }
    }
}

extension AppSettings {
    /// A model, and a key unless the provider needs none; Apple Intelligence
    /// must be available now.
    func readiness(of selection: ModelSelection, appleIntelligence: AppleIntelligenceStatus) -> ModelReadiness {
        if selection.provider.isAppleIntelligence {
            return appleIntelligence.reason.map(ModelReadiness.appleIntelligence) ?? .ready
        }
        if selection.provider.requiresAPIKey,
           configuration(for: selection.provider).apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .needsKey
        }
        if selection.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .needsModel }
        if case .declined = aiConsentState(for: selection.provider) { return .aiConsentDeclined }
        return .ready
    }
}

// MARK: - Favorites

extension FavoriteModel {
    /// The role's model as a favorite; nil without a model. Apple
    /// Intelligence has one entry whatever backend runs it.
    init?(selection: ModelSelection) {
        let model = selection.provider.isAppleIntelligence
            ? selection.provider.defaultModel
            : selection.model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { return nil }
        self.init(provider: selection.provider, model: model)
    }

    var selection: ModelSelection { ModelSelection(provider: provider, model: model) }

    /// Stands for `selection` (any Apple Intelligence selection matches its
    /// one entry).
    func matches(_ selection: ModelSelection) -> Bool {
        provider == selection.provider && (provider.isAppleIntelligence || model == selection.model)
    }

    /// "Provider · model"; Apple Intelligence shows its name only.
    var title: String {
        provider.isAppleIntelligence ? provider.displayName : "\(provider.displayName) · \(model)"
    }
}

/// Favorite models: one list in the user's order, shared by both roles.
/// Apple Intelligence is an ordinary provider here (§6): listed only when
/// starred, never pinned, and hidden only where the device can't run it.
enum ModelFavorites {
    static let limit = 30

    /// The device can never run Apple Intelligence (too old, or not
    /// eligible); other reasons can be fixed, so it shows as not ready.
    static func hidesAppleIntelligence(_ status: AppleIntelligenceStatus) -> Bool {
        status.reason == .requiresNewerOS || status.reason == .deviceNotEligible
    }

    static func visible(_ favorites: [FavoriteModel], appleIntelligence status: AppleIntelligenceStatus) -> [FavoriteModel] {
        guard hidesAppleIntelligence(status) else { return favorites }
        return favorites.filter { !$0.provider.isAppleIntelligence }
    }

    /// The list with `favorite` appended; nil when it is already there or
    /// the list is full.
    static func adding(_ favorite: FavoriteModel, to favorites: [FavoriteModel]) -> [FavoriteModel]? {
        guard !favorites.contains(favorite), favorites.count < limit else { return nil }
        return favorites + [favorite]
    }

    /// Ready favorites other than the role's model, then the other role's
    /// model when it is ready and not starred: the not-ready card's way out.
    static func readyAlternatives(
        settings: AppSettings,
        role: ModelRole,
        appleIntelligence status: AppleIntelligenceStatus
    ) -> [FavoriteModel] {
        let current = settings.model(for: role)
        var candidates = visible(settings.favoriteModels, appleIntelligence: status)
        if let other = FavoriteModel(selection: settings.model(for: role.other)),
           !candidates.contains(where: { $0.matches(other.selection) }) {
            candidates.append(other)
        }
        return candidates.filter {
            !$0.matches(current) && settings.readiness(of: $0.selection, appleIntelligence: status) == .ready
        }
    }

    /// Builds before §6 couldn't star Apple Intelligence, so a user running
    /// a role on it would find it missing from the model menus. Stars it
    /// once (appended, like any new favorite); nil when nothing changes.
    static func starringActiveAppleIntelligence(_ settings: AppSettings) -> AppSettings? {
        guard ModelRole.allCases.contains(where: { settings.model(for: $0).provider.isAppleIntelligence }),
              let favorite = FavoriteModel(selection: ModelSelection(provider: .appleIntelligence, model: "")),
              let starred = adding(favorite, to: settings.favoriteModels)
        else { return nil }
        var updated = settings
        updated.favoriteModels = starred
        return updated
    }
}

extension AppModel {
    /// UserDefaults flag: the one-time Apple Intelligence star ran.
    static let appleIntelligenceFavoriteKey = "favorites.appleIntelligenceStarred"

    /// Once per device, on the first launch with §6: stars Apple Intelligence
    /// when a role uses it. Runs only once, so unstarring it later sticks.
    func starActiveAppleIntelligenceOnce(defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: Self.appleIntelligenceFavoriteKey) else { return }
        defaults.set(true, forKey: Self.appleIntelligenceFavoriteKey)
        guard let updated = ModelFavorites.starringActiveAppleIntelligence(settings) else { return }
        settings = updated
        saveSettings()
    }
}

// MARK: - Model pill and not-ready card

/// The drawer header's model pill (§6).
enum ModelPill {
    /// Summary and This topic use the assistant model; Whole forum the agent's.
    static func role(for mode: AssistantMode) -> ModelRole { ModelRole(mode: mode) }

    /// The model name, or the provider's for Apple Intelligence (its stored
    /// model is a placeholder) and when no model is set.
    static func label(for selection: ModelSelection) -> String {
        let model = selection.model.trimmingCharacters(in: .whitespacesAndNewlines)
        if selection.provider.isAppleIntelligence || model.isEmpty { return selection.provider.displayName }
        return AppleIntelligenceBackend.displayModel(model)
    }

    /// The model a running search keeps, for the agent role's menu footer:
    /// nil for the assistant role or when no search is running.
    static func runningSearchModel(role: ModelRole, running: [ModelSelection]) -> String? {
        guard role == .agent, let first = running.first else { return nil }
        return label(for: first)
    }
}

/// What the not-ready card's main button does (ModelSetup).
enum ModelSetupAction: Equatable {
    /// "Add <provider> Key": the routed provider setup sheet.
    case addKey(AIProvider)
    /// No model chosen: the same sheet picks one.
    case chooseModel
    /// Apple Intelligence can't run: Settings › AI models explains why and
    /// offers the other providers.
    case aiModels
    /// Consent declined: the AI data consent page again.
    case allow(AIProvider)

    init(_ readiness: ModelReadiness, provider: AIProvider) {
        switch readiness {
        case .needsKey: self = .addKey(provider)
        case .needsModel: self = .chooseModel
        case .aiConsentDeclined: self = .allow(provider)
        case .ready, .appleIntelligence: self = .aiModels
        }
    }

    var title: String {
        switch self {
        case .addKey(let provider): String(localized: "Add \(provider.displayName) Key", comment: "Model not ready: opens the API key setup. The placeholder is the provider's name, e.g. Google Gemini.")
        case .chooseModel: String(localized: "Choose a Model", comment: "Model not ready: opens model setup")
        case .aiModels: String(localized: "AI models…")
        case .allow(let provider): String(localized: "Allow \(provider.displayName)…", comment: "Model not ready: shows the AI data consent page again. The placeholder is the provider's name, e.g. Google Gemini.")
        }
    }
}
