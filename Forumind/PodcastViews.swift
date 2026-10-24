import SwiftUI

// The podcast UI: the Today page's podcast section (Make, Play and the row
// that opens Now Playing, NowPlaying.swift), the consent sheet for Google's voices, the
// read-aloud button, and the podcast part of Settings › Daily digest. The
// logic is in Podcast/PodcastController.swift.

// MARK: - Today page

/// Make / Play before an episode exists; the Now Playing row after.
struct PodcastTodaySection: View {
    @ObservedObject var app: AppModel
    @ObservedObject var podcast: PodcastController
    let digest: DailyDigest

    var body: some View {
        Section {
            if let episode = podcast.episode, episode.digestID == digest.id {
                PodcastNowPlayingRow(app: app, podcast: podcast, episode: episode)
            } else {
                startCard
            }
        }
        .onAppear { podcast.refresh() }
    }

    private var startCard: some View {
        VStack(alignment: .leading, spacing: DCTheme.spacingM) {
            HStack(spacing: DCTheme.spacingS) {
                Image(systemName: "headphones")
                    .font(.headline)
                    .foregroundStyle(DigestStyle.tint)
                    .accessibilityHidden(true)
                Text("Listen to today", comment: "Today page: the podcast section's title")
                    .font(.headline)
            }
            Text("Two hosts talk through today’s topics, one chapter per card. Play starts as soon as the first chapter is ready.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: DCTheme.spacingS) { buttons }
                VStack(spacing: DCTheme.spacingS) { buttons }
            }
            Text(costNote)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, DCTheme.spacingXS)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("podcastStart")
    }

    @ViewBuilder
    private var buttons: some View {
        Button {
            DCHaptics.tap()
            podcast.make(play: true)
        } label: {
            Label("Play", systemImage: "play.fill")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(DCPrimaryButtonStyle())
        .disabled(!podcast.canMake)
        .accessibilityIdentifier("podcastPlay")
        Button {
            DCHaptics.tap()
            podcast.make(play: false)
        } label: {
            Label("Make Podcast", systemImage: "waveform")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(DCActionButtonStyle(prominent: false))
        .disabled(!podcast.canMake)
        .accessibilityIdentifier("makePodcast")
    }

    private var costNote: String {
        if app.digestActivity.isRunning {
            return String(localized: "The podcast can be made once the digest is ready.", comment: "Today page: the podcast waits for the digest")
        }
        let script = String(localized: "Each chapter is one request to your AI provider (\(app.providerSummary(for: .assistant))).", comment: "Today page: what making the podcast's script costs; the placeholder is the provider and model")
        let voices: String
        switch podcast.engineSelection(interactive: true) {
        case .engine(.aiStudio), .engine(.vertex), .needsConsent:
            voices = String(localized: "Google’s voices read it with your key.", comment: "Today page: the podcast is spoken by Gemini text-to-speech, billed to the user's key")
        case .engine(.onDevice), .engine(.fake):
            voices = String(localized: "This device’s voices read it, free and offline.", comment: "Today page: the podcast is spoken by the built-in voices")
        }
        return script + " " + voices
    }
}

/// The episode on the Today page: one row that opens Now Playing, where the
/// controls and the chapters are.
struct PodcastNowPlayingRow: View {
    @ObservedObject var app: AppModel
    @ObservedObject var podcast: PodcastController
    let episode: PodcastEpisode

    var body: some View {
        Button {
            DCHaptics.tap()
            app.router.item = .nowPlaying
        } label: {
            HStack(spacing: DCTheme.spacingS) {
                Image(systemName: "headphones")
                    .foregroundStyle(DigestStyle.tint)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 0) {
                    Text(episode.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    Text(podcast.statusLine(for: episode))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                if podcast.activity.isRunning {
                    ProgressView().controlSize(.small)
                }
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("podcastNowPlayingRow")
    }
}

// MARK: - Read aloud

/// Reads a summary or a digest card aloud with the podcast's engines (one
/// host); tapping again pauses.
struct ReadAloudButton: View {
    @ObservedObject var podcast: PodcastController
    let id: String
    let title: String
    let text: String
    var compact = false

    var body: some View {
        let reading = podcast.isReadingAloud(id)
        Button {
            DCHaptics.tap()
            podcast.readAloud(id: id, title: title, text: text)
        } label: {
            if compact {
                Image(systemName: reading ? "pause.circle" : "speaker.wave.2")
            } else {
                Label(reading ? "Pause" : "Listen", systemImage: reading ? "pause.circle" : "speaker.wave.2")
            }
        }
        .accessibilityLabel(reading ? Text("Pause") : Text("Read aloud", comment: "Button: reads the summary aloud"))
        .accessibilityIdentifier("readAloud-\(id)")
    }
}

// MARK: - Consent (App Review 5.1.2)

/// Asked once per provider before the first Google-voiced episode or
/// read-aloud: the script text (not audio) goes to Google with the user's
/// key.
struct PodcastConsentSheet: View {
    let provider: VoiceProvider
    let onAgree: () -> Void
    let onDeviceVoices: () -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DCTheme.spacingL) {
                    Image(systemName: "headphones.circle.fill")
                        .font(.system(size: 52))
                        .foregroundStyle(DigestStyle.tint.gradient)
                        .accessibilityHidden(true)
                    Text("The podcast uses Google’s voices")
                        .font(.title2.weight(.bold))
                    PodcastDisclosure(provider: provider)
                }
                .padding(DCTheme.spacingXL)
                .frame(maxWidth: DCTheme.contentMaxWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: DCTheme.spacingS) {
                    Button(action: onAgree) {
                        Text("Agree and Continue")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(DCPrimaryButtonStyle())
                    .accessibilityIdentifier("podcastConsentAgree")
                    Button(action: onDeviceVoices) {
                        Text("Use This Device’s Voices")
                            .frame(maxWidth: .infinity, minHeight: DCTheme.controlHeight)
                    }
                    .accessibilityIdentifier("podcastConsentOnDevice")
                }
                .padding(.horizontal, DCTheme.spacingXL)
                .padding(.vertical, DCTheme.spacingM)
                .frame(maxWidth: DCTheme.contentMaxWidth)
                .frame(maxWidth: .infinity)
                .background(.bar)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
            }
        }
        .interactiveDismissDisabled()
        .accessibilityIdentifier("podcastConsentSheet")
    }
}

/// What Google's voices send where, shared by the sheet and Settings.
struct PodcastDisclosure: View {
    let provider: VoiceProvider

    var body: some View {
        VStack(alignment: .leading, spacing: DCTheme.spacingM) {
            point("arrow.up.forward.circle", Text("The podcast’s script (text written from your digest: topic titles, summaries and what the posts say) is sent to Google (\(provider.displayName)) with your own API key to be read aloud. No audio is recorded, and nothing goes through a Forumind server.", comment: "Podcast consent; the placeholder is Google AI Studio or Google Vertex AI"))
            switch provider {
            case .aiStudio:
                point("person.2", Text("On the free tier of Google AI Studio, Google may use what you send to improve its products, and people may review it.", comment: "Podcast consent: Google's free-tier data use"))
            case .vertex:
                point("building.columns", Text("On Vertex AI, your Google Cloud agreement decides how Google may use what you send.", comment: "Voice consent: data use on Vertex AI"))
            }
            point("creditcard", Text("Each chapter is one text-to-speech request, billed to your key or counted against its free quota. This device’s voices are free and offline instead.", comment: "Podcast consent: cost"))
            Link(destination: termsURL) {
                Label("Google’s terms for this service", systemImage: "arrow.up.right.square")
                    .font(.subheadline.weight(.semibold))
            }
        }
    }

    private var termsURL: URL {
        switch provider {
        case .aiStudio: URL(string: "https://ai.google.dev/gemini-api/terms")!
        case .vertex: URL(string: "https://cloud.google.com/terms/service-terms")!
        }
    }

    private func point(_ symbol: String, _ text: Text) -> some View {
        Label {
            text
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(DigestStyle.tint)
        }
    }
}

// MARK: - Settings

/// The podcast part of Settings › Daily digest.
struct SettingsPodcastSections: View {
    @ObservedObject var app: AppModel
    @ObservedObject var podcast: PodcastController

    var body: some View {
        Section {
            Toggle(isOn: $app.settings.podcastDailyEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Make the podcast every day")
                    Text("Right after the digest is made when you open Forumind: one request per chapter to your AI provider, then the voices.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .tint(DCTheme.brandBlue)
            .accessibilityIdentifier("podcastDailyEnabled")
            Picker("Voices", selection: $app.settings.podcast.engine) {
                ForEach(PodcastEngineChoice.allCases) { choice in
                    Text(choice.label).tag(choice)
                }
            }
            .accessibilityIdentifier("podcastEngine")
            Picker("Length per topic", selection: $app.settings.podcast.minutesPerChapter) {
                ForEach(PodcastSettings.minuteChoices, id: \.self) { minutes in
                    Text(SettingsVoicePage.duration(minutes * 60)).tag(minutes)
                }
            }
            .accessibilityIdentifier("podcastLength")
        } header: {
            Text("Podcast")
        } footer: {
            Text("Automatic uses Google’s voices when you have a Google Gemini or Vertex AI key and have agreed to send the script to Google; otherwise this device’s voices. Nothing is made in the background. The daily switch is kept on this device.")
        }

        Section {
            host(.a, name: $app.settings.podcast.hostA, voice: $app.settings.podcast.voiceA)
            host(.b, name: $app.settings.podcast.hostB, voice: $app.settings.podcast.voiceB)
        } header: {
            Text("Hosts")
        } footer: {
            Text("The first host guides the episode; the second asks what you might ask. Google’s voice names are used with Google’s voices; this device picks two of its own voices otherwise.")
        }

        let granted = VoiceProvider.allCases.filter { PodcastConsent.isGranted($0, in: app.settings) }
        if let provider = granted.first ?? podcast.googleProviders.first {
            Section {
                PodcastDisclosure(provider: provider)
                    .padding(.vertical, DCTheme.spacingXS)
                ForEach(granted) { item in
                    Button(role: .destructive) {
                        podcast.revokeConsent(item)
                    } label: {
                        Text("Withdraw consent for \(item.displayName)", comment: "Settings › Voice; the placeholder is Google AI Studio or Google Vertex AI")
                    }
                }
            } header: {
                Text("Podcast privacy", comment: "Settings › Daily digest: what the podcast sends to Google")
            }
        }
    }

    private func host(_ speaker: PodcastSpeaker, name: Binding<String>, voice: Binding<String>) -> some View {
        Group {
            LabeledContent(speaker == .a ? String(localized: "First host", comment: "Settings: the podcast's first host's name") : String(localized: "Second host", comment: "Settings: the podcast's second host's name")) {
                TextField(speaker.defaultName, text: name)
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("podcastHost\(speaker.rawValue)")
            }
            Picker(speaker == .a ? String(localized: "First host’s voice", comment: "Settings: the Google voice of the podcast's first host") : String(localized: "Second host’s voice", comment: "Settings: the Google voice of the podcast's second host"), selection: voice) {
                ForEach(VoiceCatalog.voices) { item in
                    Text(verbatim: "\(item.name) · \(item.style)").tag(item.name)
                }
            }
            .accessibilityIdentifier("podcastVoice\(speaker.rawValue)")
        }
    }
}
