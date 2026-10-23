import SwiftUI

// The AI data consent page (Onb2b) and Settings › Data & privacy › Where
// your data goes (SetData). See AIDataConsent.swift.

// MARK: - Consent page

/// "Send forum content to <provider>?": what goes, the provider's own note
/// and policies, Allow / Don't Allow. Full screen on iPad, a large sheet on
/// iPhone (`RootPresentation.isFullScreen`); only an answer closes it.
struct AIDataConsentPage: View {
    let provider: AIProvider
    let onAllow: () -> Void
    let onDecline: () -> Void

    private var policy: AIProviderPolicy? { AIProviderPolicy.policy(for: provider) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DCTheme.spacingL) {
                    HStack(spacing: DCTheme.spacingM) {
                        ProviderBadge(provider: provider, size: 44)
                        Image(systemName: "arrow.right")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        Text("Straight from this device. No Forumind server.", comment: "AI data consent: requests go directly to the provider")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Text("Send forum content to \(provider.displayName)?", comment: "AI data consent title; the placeholder is an AI provider's name")
                        .font(.title2.weight(.heavy))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("aiConsentTitle")

                    VStack(alignment: .leading, spacing: DCTheme.spacingS) {
                        Text("What Forumind sends", comment: "AI data consent: heading above the list of what is sent")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                        point(Text("Posts and pages you summarize or ask about, including pages you see while signed in to a forum", comment: "AI data consent: what is sent"))
                        point(Text("Your questions and chat messages", comment: "AI data consent: what is sent"))
                        point(Text("Your API key, only to \(provider.displayName)", comment: "AI data consent: what is sent; the placeholder is an AI provider's name"))
                    }

                    if let note = policy?.note {
                        Text(note)
                            .font(.subheadline)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(DCTheme.spacingM)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(DCTheme.newRepliesBadgeBackground.opacity(0.6), in: RoundedRectangle(cornerRadius: DCTheme.controlCornerRadius, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: DCTheme.controlCornerRadius, style: .continuous)
                                    .stroke(DCTheme.warning.opacity(0.3))
                            }
                            .accessibilityIdentifier("aiConsentNote")
                    }

                    if let policy {
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: DCTheme.spacingL) { links(policy) }
                            VStack(alignment: .leading, spacing: DCTheme.spacingS) { links(policy) }
                        }
                        .font(.subheadline)
                    }

                    Text("Change this any time in Settings › Data & privacy. Voice and the podcast ask separately.", comment: "AI data consent footer; Settings › Data & privacy names the app's own Settings page")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(DCTheme.spacingXL)
                .frame(maxWidth: DCTheme.contentMaxWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: DCTheme.spacingS) {
                    Button(action: onAllow) {
                        Text("Allow", comment: "AI data consent: agree to send forum content to the provider")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(DCPrimaryButtonStyle())
                    .accessibilityIdentifier("aiConsentAllow")
                    Button(action: onDecline) {
                        Text("Don’t Allow", comment: "AI data consent: refuse to send forum content to the provider")
                            .frame(maxWidth: .infinity, minHeight: DCTheme.controlHeight)
                    }
                    .accessibilityIdentifier("aiConsentDecline")
                }
                .padding(.horizontal, DCTheme.spacingXL)
                .padding(.vertical, DCTheme.spacingM)
                .frame(maxWidth: DCTheme.contentMaxWidth)
                .frame(maxWidth: .infinity)
                .background(.bar)
            }
        }
        .presentationDetents([.large])
        .interactiveDismissDisabled()
        .accessibilityIdentifier("aiConsentPage")
    }

    private func point(_ text: Text) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DCTheme.spacingS) {
            Circle()
                .fill(Color.primary)
                .frame(width: 6, height: 6)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                .accessibilityHidden(true)
            text
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func links(_ policy: AIProviderPolicy) -> some View {
        Link(destination: policy.termsURL) {
            Text("\(provider.displayName)’s terms", comment: "AI data consent: link to the provider's terms; the placeholder is an AI provider's name")
        }
        .accessibilityIdentifier("aiConsentTerms")
        Link(destination: policy.privacyURL) {
            Text("\(provider.displayName)’s privacy policy", comment: "AI data consent: link to the provider's privacy policy; the placeholder is an AI provider's name")
        }
        .accessibilityIdentifier("aiConsentPrivacy")
    }
}

// MARK: - Settings › Data & privacy

/// Where your data goes: each feature with the provider it uses and the
/// consent behind it, then each third-party provider with its decision and
/// Withdraw / Allow.
struct AIDataFlowSection: View {
    @ObservedObject var app: AppModel
    @ObservedObject var aiConsent: AIConsentGate
    /// Allow… from here shows the page on this (routed) sheet.
    @State private var allowing: AIProvider?

    init(app: AppModel) {
        self.app = app
        aiConsent = app.aiConsent
    }

    private var assistant: AIProvider { app.selection(for: .assistant).provider }
    private var agent: AIProvider { app.selection(for: .agent).provider }

    /// Third-party providers in use or with a decision, in list order.
    private var providers: [AIProvider] {
        AIProvider.allCases.filter {
            $0.requiresDataConsent && ($0 == assistant || $0 == agent || app.settings.aiConsent[$0.rawValue] != nil)
        }
    }

    var body: some View {
        Section {
            if assistant == agent {
                flowRow(
                    title: String(localized: "Summaries, chat, Ask the forum", comment: "Settings › Data & privacy: the AI features using one provider"),
                    detail: flowDetail(assistant),
                    value: stateText(assistant)
                )
            } else {
                flowRow(
                    title: String(localized: "Summaries, chat, digest", comment: "Settings › Data & privacy: the features that use the assistant model"),
                    detail: flowDetail(assistant),
                    value: stateText(assistant)
                )
                flowRow(
                    title: String(localized: "Ask the forum", comment: "Assistant mode: the research agent that searches the whole forum"),
                    detail: flowDetail(agent),
                    value: stateText(agent)
                )
            }
            flowRow(
                title: String(localized: "Voice", comment: "Settings › Data & privacy: live voice"),
                detail: String(localized: "Your voice and the page → Google Gemini Live", comment: "Settings › Data & privacy: where voice sends data"),
                value: agreedText(VoiceProvider.allCases.compactMap { app.settings.voiceConsent[$0.rawValue] }.max())
            )
            flowRow(
                title: String(localized: "Podcast voices", comment: "Settings › Data & privacy: the podcast's Google voices"),
                detail: String(localized: "The podcast script → Google text-to-speech", comment: "Settings › Data & privacy: where the podcast's voices send data"),
                value: agreedText(VoiceProvider.allCases.compactMap { app.settings.podcastConsent[$0.rawValue] }.max())
            )
            Link(destination: ModerationTerms.privacyURL) {
                Label(String(localized: "Privacy Policy", comment: "Settings › Data & privacy: link to the app's privacy policy"), systemImage: "hand.raised")
            }
        } header: {
            Text("Where your data goes", comment: "Settings › Data & privacy section header")
        } footer: {
            Text("Nothing goes to a Forumind server: there isn’t one. Withdraw consent for voice and podcast voices on the Voice and Daily digest pages.", comment: "Settings › Data & privacy footer")
        }

        if !providers.isEmpty {
            Section {
                ForEach(providers) { provider in
                    providerRow(provider)
                }
            } header: {
                Text("AI providers", comment: "Settings › Data & privacy section header: consent per AI provider")
            } footer: {
                Text("Withdrawing stops what is running on that provider and blocks new requests. It stays set up, so you can allow it again.", comment: "Settings › Data & privacy footer of the AI providers' consent")
            }
            .sheet(item: $allowing) { provider in
                AIDataConsentPage(
                    provider: provider,
                    onAllow: { app.answerAIConsent(provider, allow: true); allowing = nil },
                    onDecline: { app.answerAIConsent(provider, allow: false); allowing = nil }
                )
            }
        }
    }

    private func flowRow(title: String, detail: String, value: String) -> some View {
        HStack(spacing: DCTheme.spacingM) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: DCTheme.spacingS)
            Text(value)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
    }

    private func providerRow(_ provider: AIProvider) -> some View {
        let state = app.aiConsentState(for: provider)
        return HStack(spacing: DCTheme.spacingM) {
            ProviderBadge(provider: provider, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(provider.displayName)
                Text(stateText(provider))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: DCTheme.spacingS)
            switch state {
            case .allowed:
                Button("Withdraw", role: .destructive) { app.withdrawAIConsent(provider) }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(Text("Withdraw consent for \(provider.displayName)", comment: "Settings › Data & privacy; the placeholder is an AI provider's name"))
                    .accessibilityIdentifier("aiConsentWithdraw-\(provider.rawValue)")
            case .declined, .undecided:
                Button(String(localized: "Allow…", comment: "Settings › Data & privacy: shows the AI data consent page")) { allowing = provider }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("aiConsentAllow-\(provider.rawValue)")
            case .notNeeded:
                EmptyView()
            }
        }
    }

    /// "Forum posts you open → Google Gemini", or on this device.
    private func flowDetail(_ provider: AIProvider) -> String {
        if provider.isAppleIntelligence {
            return String(localized: "Stays with Apple Intelligence (on this device or Private Cloud Compute)", comment: "Settings › Data & privacy: Apple Intelligence keeps the data with Apple")
        }
        if provider.isLocalServer {
            return String(localized: "Forum posts you open → \(provider.displayName), on your computer", comment: "Settings › Data & privacy: a local model server; the placeholder is its name")
        }
        return String(localized: "Forum posts you open → \(provider.displayName)", comment: "Settings › Data & privacy: where AI features send data; the placeholder is an AI provider's name")
    }

    private func stateText(_ provider: AIProvider) -> String {
        switch app.aiConsentState(for: provider) {
        case .notNeeded: String(localized: "No consent needed", comment: "Settings › Data & privacy: Apple Intelligence or a local server")
        case .undecided: String(localized: "Asks first", comment: "Settings › Data & privacy: the consent page shows before the first request")
        case .allowed(let date): agreedText(date)
        case .declined: String(localized: "Not allowed", comment: "AI model state: the user chose not to send forum content to this provider")
        }
    }

    private func agreedText(_ date: Date?) -> String {
        guard let date else { return String(localized: "Asks first", comment: "Settings › Data & privacy: the consent page shows before the first request") }
        return String(localized: "Agreed \(date.formatted(.dateTime.month(.abbreviated).day()))", comment: "Settings › Data & privacy: when consent was given; the placeholder is a short date")
    }
}
