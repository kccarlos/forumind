import SwiftUI

// The podcast UI: the Today page's podcast section (Make, Play, the mini
// player and the chapter list), the consent sheet for Google's voices, the
// read-aloud button, and the podcast part of Settings › Daily digest. The
// logic is in Podcast/PodcastController.swift.

// MARK: - Today page

/// Make / Play before an episode exists; the mini player and the chapters
/// after.
struct PodcastTodaySection: View {
    @ObservedObject var app: AppModel
    @ObservedObject var podcast: PodcastController
    let digest: DailyDigest
    /// Opens a chapter's topic at its post (the page closes).
    let onOpen: (URL, DigestCard) -> Void

    var body: some View {
        Section {
            if let episode = podcast.episode, episode.digestID == digest.id {
                PodcastMiniPlayer(app: app, podcast: podcast, episode: episode, onOpen: onOpen)
                PodcastChapterList(app: app, podcast: podcast, episode: episode, digest: digest, onOpen: onOpen)
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

/// Now playing on the Today page: the chapter, the progress, the controls
/// and "Ask about this".
struct PodcastMiniPlayer: View {
    @ObservedObject var app: AppModel
    @ObservedObject var podcast: PodcastController
    let episode: PodcastEpisode
    let onOpen: (URL, DigestCard) -> Void

    private var player: PodcastPlayer { podcast.player }
    private var isThisEpisode: Bool { podcast.isPlayingEpisode }

    var body: some View {
        VStack(alignment: .leading, spacing: DCTheme.spacingS) {
            HStack(spacing: DCTheme.spacingS) {
                Image(systemName: "headphones")
                    .foregroundStyle(DigestStyle.tint)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 0) {
                    Text(chapterTitle)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .accessibilityIdentifier("podcastStatus")
                }
                Spacer(minLength: 0)
                if podcast.activity.isRunning || player.state == .waiting && isThisEpisode {
                    ProgressView().controlSize(.small)
                }
            }

            ProgressView(value: progress.elapsed, total: max(progress.total, 1))
                .tint(DigestStyle.tint)
                .accessibilityLabel(Text("Position", comment: "Podcast progress bar"))
                .accessibilityValue(Text(verbatim: "\(Self.time(progress.elapsed)) / \(Self.time(progress.total))"))
            HStack {
                Text(Self.time(progress.elapsed))
                Spacer()
                Text(Self.time(progress.total))
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)

            controls

            if let error = podcast.lastError ?? player.failure {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(DCTheme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if needsContinue {
                Button {
                    podcast.make(play: false)
                } label: {
                    Label("Make Podcast", systemImage: "waveform")
                }
                .buttonStyle(DCActionButtonStyle(prominent: false))
                .disabled(!podcast.canMake && podcast.episode == nil)
                .accessibilityIdentifier("makePodcast")
            }
            if let chapter = askChapter, podcast.canAsk(about: chapter) {
                Button {
                    DCHaptics.tap()
                    ask(chapter)
                } label: {
                    Label("Ask about this", systemImage: "waveform.circle")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.borderless)
                .accessibilityHint(Text("Pauses the podcast and starts a voice conversation about this topic", comment: "Podcast: what Ask about this does"))
                .accessibilityIdentifier("podcastAsk")
            }
        }
        .padding(.vertical, DCTheme.spacingXS)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("podcastMiniPlayer")
    }

    private var controls: some View {
        HStack(spacing: 0) {
            control("backward.end.fill", Text("Previous chapter"), id: "podcastPreviousChapter") { player.previousChapter() }
            control("gobackward.15", Text("Back 15 seconds"), id: "podcastSkipBack") { player.skip(by: -15) }
            Button {
                DCHaptics.tap()
                if isThisEpisode { player.toggle() } else { podcast.playEpisode() }
            } label: {
                Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(DigestStyle.tint)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderless)
            .disabled(!episode.hasAudio)
            .accessibilityLabel(isPlaying ? Text("Pause") : Text("Play"))
            .accessibilityIdentifier("podcastPlay")
            control("goforward.15", Text("Forward 15 seconds"), id: "podcastSkipForward") { player.skip(by: 15) }
            control("forward.end.fill", Text("Next chapter"), id: "podcastNextChapter") { player.nextChapter() }
        }
    }

    private func control(_ symbol: String, _ label: Text, id: String, action: @escaping () -> Void) -> some View {
        Button {
            DCHaptics.tap()
            if !isThisEpisode { podcast.playEpisode() }
            action()
        } label: {
            Image(systemName: symbol)
                .font(.title3)
                .frame(maxWidth: .infinity, minHeight: DCTheme.controlHeight)
        }
        .buttonStyle(.borderless)
        .disabled(!episode.hasAudio)
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
    }

    private var isPlaying: Bool { isThisEpisode && player.isActive }

    private var progress: (elapsed: TimeInterval, total: TimeInterval) {
        let timeline = PodcastTimeline(durations: episode.entries.map { $0.isReady ? $0.duration : nil })
        guard isThisEpisode else { return (0, timeline.total) }
        return (timeline.elapsed(player.position), timeline.total)
    }

    private var chapterTitle: String {
        if isThisEpisode, let item = player.currentItem { return item.title }
        return episode.title
    }

    private var needsContinue: Bool {
        !podcast.activity.isRunning && (!episode.isComplete || episode.entries.contains { $0.state == .failed })
    }

    private var status: String {
        switch podcast.activity {
        case .scripting(let id):
            return String(localized: "Writing “\(title(of: id))”…", comment: "Podcast: a chapter's dialogue is being written; the placeholder is its title")
        case .speaking(let id):
            return String(localized: "Recording “\(title(of: id))”…", comment: "Podcast: a chapter is being spoken; the placeholder is its title")
        case .unreachable:
            return String(localized: "Offline. The podcast continues when you’re back online.", comment: "Podcast: couldn't reach the AI provider or Google")
        case .idle:
            if isThisEpisode, player.state == .waiting {
                return String(localized: "Waiting for the next chapter…", comment: "Podcast: playback waits for the next chapter to be recorded")
            }
            if isThisEpisode, player.playlist != nil {
                let index = player.chapterIndex
                return String(localized: "Chapter \(index + 1) of \(episode.entries.count)", comment: "Podcast: the current chapter, then the number of chapters")
            }
            return episode.isComplete
                ? String(localized: "Ready to play", comment: "Podcast: every chapter is recorded")
                : String(localized: "\(episode.readyCount) of \(episode.entries.count) chapters ready", comment: "Podcast progress: chapters recorded so far, then the number of chapters")
        }
    }

    private func title(of id: String) -> String {
        episode.entries.first { $0.id == id }?.chapter.title ?? ""
    }

    /// The chapter being played, or the first topic.
    private var askChapter: PodcastChapter? {
        if let current = podcast.currentChapter, current.kind == .topic { return current }
        return nil
    }

    private func ask(_ chapter: PodcastChapter) {
        podcast.ask(about: chapter) { url in
            guard let card = app.todaysDigest?.cards.first(where: { $0.topicKey == chapter.id }) else { return }
            onOpen(url, card)
        }
    }

    static func time(_ seconds: TimeInterval) -> String {
        Duration.seconds(max(0, seconds.rounded(.down))).formatted(.time(pattern: .minuteSecond))
    }
}

/// The episode's chapters: tap to play one; a topic's arrow opens it at the
/// post the chapter talks about.
struct PodcastChapterList: View {
    @ObservedObject var app: AppModel
    @ObservedObject var podcast: PodcastController
    let episode: PodcastEpisode
    let digest: DailyDigest
    let onOpen: (URL, DigestCard) -> Void

    var body: some View {
        ForEach(Array(episode.entries.enumerated()), id: \.element.id) { index, entry in
            HStack(spacing: DCTheme.spacingS) {
                Button {
                    DCHaptics.tap()
                    if podcast.isPlayingEpisode {
                        podcast.player.playChapter(index)
                    } else {
                        podcast.playEpisode(chapter: index)
                    }
                } label: {
                    HStack(spacing: DCTheme.spacingS) {
                        Image(systemName: symbol(index, entry))
                            .font(.footnote)
                            .foregroundStyle(isCurrent(index) ? DigestStyle.tint : .secondary)
                            .frame(width: 20)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(entry.chapter.title)
                                .font(.subheadline)
                                .foregroundStyle(.primary)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                            Text(detail(entry))
                                .font(.caption)
                                .foregroundStyle(entry.state == .failed ? DCTheme.danger : .secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .disabled(!entry.isReady)
                .accessibilityIdentifier("podcastChapter-\(index)")
                if let url = entry.chapter.topicURL, let card = digest.cards.first(where: { $0.topicKey == entry.chapter.id }) {
                    Button {
                        DCHaptics.tap()
                        onOpen(url, card)
                    } label: {
                        Image(systemName: "arrow.up.right.square")
                            .font(.body)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(Text("Open the topic", comment: "Podcast chapter list: opens the chapter's topic at the post it talks about"))
                    .accessibilityIdentifier("podcastChapterOpen-\(index)")
                }
            }
        }
    }

    private func isCurrent(_ index: Int) -> Bool {
        podcast.isPlayingEpisode && podcast.player.chapterIndex == index
    }

    private func symbol(_ index: Int, _ entry: PodcastEpisode.Entry) -> String {
        if isCurrent(index) { return podcast.player.isActive ? "speaker.wave.2.fill" : "pause.fill" }
        switch entry.state {
        case .ready: return entry.chapter.kind == .topic ? "text.bubble" : "sparkles"
        case .failed: return "exclamationmark.triangle"
        case .pending, .working: return "clock"
        }
    }

    private func detail(_ entry: PodcastEpisode.Entry) -> String {
        switch entry.state {
        case .ready:
            return entry.duration.map(PodcastMiniPlayer.time) ?? ""
        case .working:
            return String(localized: "Recording…", comment: "Podcast chapter: being written or spoken")
        case .pending:
            return String(localized: "Waiting", comment: "Podcast chapter: queued behind other chapters")
        case .failed:
            return entry.error.isEmpty ? String(localized: "Couldn’t be recorded", comment: "Podcast chapter error without details") : entry.error
        }
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
