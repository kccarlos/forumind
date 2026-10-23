import Foundation

// MARK: - AI data consent (see AIDataConsent.swift)

extension AppModel {
    func aiConsentState(for provider: AIProvider) -> AIConsentState {
        settings.aiConsentState(for: provider)
    }

    /// The role's model can run without anyone answering a consent page:
    /// what work the app starts by itself (the digest, watched-topic
    /// refreshes) needs. Undecided consent waits until the user starts
    /// work or allows it in Settings.
    func canRunUnattended(_ role: ModelRole) -> Bool {
        isProviderReady(for: role) && aiConsentState(for: selection(for: role).provider).permitsRequests
    }

    /// The role's provider still needs the person's answer (the Today page
    /// shows it with an "Allow…" button).
    func providerAwaitingConsent(for role: ModelRole) -> AIProvider? {
        let provider = selection(for: role).provider
        return aiConsentState(for: provider) == .undecided ? provider : nil
    }

    /// Before work sends forum content to `provider`. Allowed (or not
    /// needed) goes on; declined throws. Undecided shows the consent page
    /// when `mayAsk` (work the user started) and waits for the answer,
    /// calling `whileAsking` first; otherwise it throws, and the page never
    /// shows for work the app started by itself.
    func authorizeSending(
        to provider: AIProvider,
        mayAsk: Bool,
        whileAsking: () -> Void = {}
    ) async throws {
        if aiConsentState(for: provider) == .undecided, mayAsk {
            whileAsking()
            await aiConsent.wait(for: provider)
            try Task.checkCancellation()
        }
        // The answer (or no answer: the page was closed) is in the settings.
        try settings.requireAIConsent(for: provider)
    }

    /// Allow or Don't Allow on the consent page. Requests waiting on it go
    /// on (or fail with the blocked state); a second tap changes nothing.
    func answerAIConsent(_ provider: AIProvider, allow: Bool) {
        guard provider.requiresDataConsent else { return }
        switch (allow, aiConsentState(for: provider)) {
        case (true, .allowed), (false, .declined):
            break
        case (true, _):
            settings.aiConsent[provider.rawValue] = .allowed(Date())
        case (false, _):
            settings.aiConsent[provider.rawValue] = .declined(Date())
        }
        aiConsent.resolve(provider)
        save()
    }

    /// Settings › Data & privacy › Withdraw. Future requests are blocked
    /// (the provider stays configured, "Not allowed"); work running on it
    /// now is cancelled rather than left to finish, so nothing more is sent
    /// after the person says stop. The digest stops too; the podcast's next
    /// chapter fails at the backstop.
    func withdrawAIConsent(_ provider: AIProvider) {
        guard provider.requiresDataConsent else { return }
        settings.aiConsent[provider.rawValue] = .declined(Date())
        for record in activities where !record.status.isTerminal && record.provider == provider {
            cancel(record: record)
        }
        if selection(for: .assistant).provider == provider { pauseDigest() }
        save()
    }
}

extension Error {
    /// Waiting for or blocked by AI data consent: shown as the blocked
    /// state in place, never as an alert.
    var isAIConsentError: Bool {
        switch self as? AssistantError {
        case .aiConsentRequired, .aiConsentDeclined: true
        default: false
        }
    }
}
