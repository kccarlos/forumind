import Foundation

// MARK: - AI data consent (App Review 5.1.2(i))
//
// Before the first request that sends forum content to a third-party AI
// provider, the person agrees to it on a full-screen page, once per provider
// (`AIDataConsentPage`). Apple Intelligence (on device / Private Cloud
// Compute) and model servers on the user's own computer (Ollama, LM Studio)
// need no consent. Voice and the podcast's Google voices keep their own
// consent pages.
//
// - `AppSettings.aiConsent`   the decisions, per provider; the only record.
//                             Synced like the other settings, one unit per
//                             provider (a person's choice about their data,
//                             like the provider setup it goes with).
//                             Withdrawing writes `.declined`, never removes
//                             the entry, so an older "allowed" on another
//                             device can't win the merge.
// - `AIConsentGate`           who is waiting for an answer (not saved: a
//                             job restored after a relaunch asks again).
// - `AppModel.authorizeSending(to:mayAsk:)`
//                             the interactive check at the start of a job;
//                             work the user started waits for the page.
// - `AIService.consentCheck`  the backstop before every third-party request
//                             (it never asks), so no path can bypass it.

/// What the person decided for one provider.
enum AIConsentDecision: Codable, Equatable {
    case allowed(Date)
    case declined(Date)

    var date: Date {
        switch self {
        case .allowed(let date), .declined(let date): date
        }
    }
}

/// Whether forum content may go to a provider now.
enum AIConsentState: Equatable {
    /// On this device or the user's own computer: nothing to agree to.
    case notNeeded
    /// Never asked: work the user starts shows the consent page first;
    /// automatic work waits.
    case undecided
    case allowed(Date)
    case declined(Date)

    /// Requests may go out.
    var permitsRequests: Bool {
        switch self {
        case .notNeeded, .allowed: true
        case .undecided, .declined: false
        }
    }
}

extension AIProvider {
    /// Sends forum content to a third party (not Apple Intelligence, not a
    /// server on the user's own computer).
    var requiresDataConsent: Bool { !isAppleIntelligence && !isLocalServer }
}

extension AppSettings {
    func aiConsentState(for provider: AIProvider) -> AIConsentState {
        guard provider.requiresDataConsent else { return .notNeeded }
        switch aiConsent[provider.rawValue] {
        case nil: return .undecided
        case .allowed(let date): return .allowed(date)
        case .declined(let date): return .declined(date)
        }
    }

    /// The backstop's check: throws unless requests to `provider` may go.
    func requireAIConsent(for provider: AIProvider) throws {
        switch aiConsentState(for: provider) {
        case .notNeeded, .allowed: return
        case .undecided: throw AssistantError.aiConsentRequired(provider)
        case .declined: throw AssistantError.aiConsentDeclined(provider)
        }
    }
}

/// Each provider's terms and privacy policy, and what the consent page says
/// about how it may use what it receives. One table for every link.
struct AIProviderPolicy: Equatable {
    var termsURL: URL
    var privacyURL: URL
    /// Provider-specific data use, when there is something to say.
    var note: String?

    /// Nil for providers that need no consent.
    static func policy(for provider: AIProvider) -> AIProviderPolicy? {
        func make(_ terms: String, _ privacy: String, note: String? = nil) -> AIProviderPolicy {
            AIProviderPolicy(termsURL: URL(string: terms)!, privacyURL: URL(string: privacy)!, note: note)
        }
        switch provider {
        case .appleIntelligence, .ollama, .lmStudio:
            return nil
        case .openRouter:
            return make(
                "https://openrouter.ai/terms", "https://openrouter.ai/privacy",
                note: String(localized: "OpenRouter passes each request to the company that runs the model you chose, under that company’s own terms.", comment: "AI data consent: OpenRouter's data use")
            )
        case .openAI:
            return make("https://openai.com/policies/services-agreement/", "https://openai.com/policies/privacy-policy/")
        case .anthropic:
            return make("https://www.anthropic.com/legal/commercial-terms", "https://www.anthropic.com/legal/privacy")
        case .groq:
            return make("https://groq.com/terms-of-use", "https://groq.com/privacy-policy")
        case .gemini:
            return make(
                "https://ai.google.dev/gemini-api/terms", "https://policies.google.com/privacy",
                note: String(localized: "On Google AI Studio’s free tier, Google may use what you send to improve its products, and people may review it. A paid key or Vertex AI doesn’t allow this.", comment: "AI data consent: Google Gemini's free-tier data use")
            )
        case .vertexAI:
            return make(
                "https://cloud.google.com/terms", "https://cloud.google.com/terms/cloud-privacy-notice",
                note: String(localized: "On Vertex AI, your Google Cloud agreement decides how Google may use what you send.", comment: "Voice consent: data use on Vertex AI")
            )
        case .xAI:
            return make("https://x.ai/legal/terms-of-service-enterprise", "https://x.ai/legal/privacy-policy")
        case .deepSeek:
            return make(
                "https://cdn.deepseek.com/policies/en-US/deepseek-open-platform-terms-of-service.html",
                "https://cdn.deepseek.com/policies/en-US/deepseek-privacy-policy.html"
            )
        case .nvidia:
            return make("https://www.nvidia.com/en-us/about-nvidia/terms-of-service/", "https://www.nvidia.com/en-us/about-nvidia/privacy-policy/")
        }
    }
}

/// Who is waiting for an answer on the consent page. The first provider in
/// `queue` has the page; several requests for the same provider share one
/// page, and a second provider is asked after the first is answered.
@MainActor
final class AIConsentGate: ObservableObject {
    /// Providers waiting for an answer, in the order they were asked.
    @Published private(set) var queue: [AIProvider] = []
    private var waiters: [UUID: (provider: AIProvider, continuation: CheckedContinuation<Void, Never>)] = [:]

    /// The provider whose page is up.
    var asking: AIProvider? { queue.first }

    /// Shows the page for `provider` (an "Allow…" button); asking again
    /// while it is queued does nothing.
    func ask(_ provider: AIProvider) {
        if !queue.contains(provider) { queue.append(provider) }
    }

    /// Asks and returns once the page for `provider` is answered or closed,
    /// or the waiting task is cancelled. The caller reads the decision from
    /// the settings.
    func wait(for provider: AIProvider) async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume()
                    return
                }
                waiters[id] = (provider, continuation)
                ask(provider)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.release(id) }
        }
    }

    /// The page for `provider` was answered or closed: every request
    /// waiting on it goes on. A second answer finds nothing to do.
    func resolve(_ provider: AIProvider) {
        queue.removeAll { $0 == provider }
        for (id, waiter) in waiters where waiter.provider == provider {
            waiters.removeValue(forKey: id)
            waiter.continuation.resume()
        }
    }

    private func release(_ id: UUID) {
        waiters.removeValue(forKey: id)?.continuation.resume()
    }
}
