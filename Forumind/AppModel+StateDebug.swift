import Foundation

#if DEBUG
/// Scripted mid-use changes for screenshots and QA of state transitions:
///
///     -dc-script <action>-after:<seconds>
///
/// Actions (combine with `-dc-sample` and its flags, e.g. `-dc-summary-running`):
/// - `switch-provider`   switches the current mode's model to OpenAI · gpt-5-mini (placeholder key, in memory)
/// - `delete-key`        deletes the key of the current mode's provider (in memory)
/// - `remove-forum`      removes the open topic's forum and its data
/// - `unpin-forum`       unpins the open topic's forum
/// - `clear-all`         clears all saved data
/// - `reset-settings`    resets settings to defaults
enum StateDebugScript {
    static var value: String? { AssistantDebug.value("-dc-script") }

    /// ("switch-provider", 2) from "switch-provider-after:2".
    static func parse(_ value: String) -> (action: String, delay: Double)? {
        let parts = value.components(separatedBy: "-after:")
        guard parts.count == 2, let delay = Double(parts[1]), !parts[0].isEmpty else { return nil }
        return (parts[0], delay)
    }
}

extension AppModel {
    func applyStateDebugScript() {
        guard let value = StateDebugScript.value, let script = StateDebugScript.parse(value) else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(script.delay))
            self?.runStateDebugAction(script.action)
        }
    }

    private func runStateDebugAction(_ action: String) {
        let siteURL = currentTopic?.siteURL ?? currentForum?.siteURL
        switch action {
        case "switch-provider":
            var configuration = settings.configuration(for: .openAI)
            configuration.apiKey = "sample-key"
            settings.setConfiguration(configuration, for: .openAI)
            activateFavorite(FavoriteModel(provider: .openAI, model: "gpt-5-mini"), for: currentRole)
        case "delete-key":
            let provider = selection(for: currentRole).provider
            var configuration = settings.configuration(for: provider)
            configuration.apiKey = ""
            setConfiguration(configuration, for: provider)
        case "remove-forum":
            if let forum = siteURL.flatMap(forum(for:)) { removeForum(forum, deleteData: true) }
        case "unpin-forum":
            if let forum = siteURL.flatMap(forum(for:)) { unpin(forum) }
        case "clear-all":
            clearAllSavedData()
        case "reset-settings":
            resetSettings()
        default:
            break
        }
    }
}
#endif
