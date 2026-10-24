import SwiftUI

// Now Playing (§9.1): the Today podcast's player. Opened from the Dock's
// podcast row, the drawer's status row and the Today page; a routed sheet
// (`RootPresentation.nowPlaying`) that zooms out of the row on iOS 18+.
// The elapsed / remaining time observes the player itself: the controller
// does not forward its twice-a-second ticks, so nothing else redraws.

// MARK: - Zoom transition

private struct NowPlayingNamespaceKey: EnvironmentKey {
    static let defaultValue: Namespace.ID? = nil
}

extension EnvironmentValues {
    /// The namespace the rows and Now Playing share for the zoom transition.
    var nowPlayingNamespace: Namespace.ID? {
        get { self[NowPlayingNamespaceKey.self] }
        set { self[NowPlayingNamespaceKey.self] = newValue }
    }
}

private let nowPlayingSourceID = "nowPlaying"

extension View {
    /// Marks a row as the place Now Playing zooms out of (iOS 18+).
    func nowPlayingZoomSource() -> some View { modifier(NowPlayingZoomSource()) }

    /// Makes the presented Now Playing zoom from its row (iOS 18+); a plain
    /// sheet before.
    func nowPlayingZoomDestination() -> some View { modifier(NowPlayingZoomDestination()) }
}

private struct NowPlayingZoomSource: ViewModifier {
    @Environment(\.nowPlayingNamespace) private var namespace

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *), let namespace {
            content.matchedTransitionSource(id: nowPlayingSourceID, in: namespace)
        } else {
            content
        }
    }
}

private struct NowPlayingZoomDestination: ViewModifier {
    @Environment(\.nowPlayingNamespace) private var namespace

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *), let namespace {
            content.navigationTransition(.zoom(sourceID: nowPlayingSourceID, in: namespace))
        } else {
            content
        }
    }
}

// MARK: - Page

struct NowPlayingView: View {
    @ObservedObject var app: AppModel
    @ObservedObject var podcast: PodcastController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if let episode = podcast.episode {
                content(episode)
            } else {
                // The episode went away (a new day, deleted): nothing to play.
                Color.clear.onAppear { dismiss() }
            }
        }
        .background(DCTheme.pageBackground)
        .accessibilityIdentifier("nowPlaying")
    }

    private var player: PodcastPlayer { podcast.player }

    private func content(_ episode: PodcastEpisode) -> some View {
        ScrollView {
            VStack(spacing: DCTheme.spacingL) {
                header(episode)
                cover
                titles(episode)
                NowPlayingScrubber(player: player, episode: episode)
                controls(episode)
                if let error = podcast.lastError ?? player.failure {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(DCTheme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
                actions
                Divider()
                chapters(episode)
            }
            .padding(.horizontal, DCTheme.spacingXL)
            .padding(.bottom, DCTheme.spacingXL)
            .frame(maxWidth: DCTheme.contentMaxWidth)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: Header

    private func header(_ episode: PodcastEpisode) -> some View {
        HStack {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(DCIconButtonStyle())
            .accessibilityLabel(Text("Close"))
            .accessibilityIdentifier("nowPlayingClose")
            Spacer()
            Text("Today · \(episode.createdAt.formatted(.dateTime.month(.abbreviated).day()))", comment: "Now Playing: the title; the placeholder is the episode's date")
                .font(.subheadline.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Spacer()
            Menu {
                Button {
                    dismiss()
                    app.showsTodayPage = true
                } label: {
                    Label("Open Today", systemImage: "newspaper")
                }
                .accessibilityIdentifier("nowPlayingOpenToday")
                if needsContinue(episode) {
                    Button {
                        podcast.make(play: false)
                    } label: {
                        Label("Make Podcast", systemImage: "waveform")
                    }
                    .disabled(!podcast.canMake && podcast.episode == nil)
                    .accessibilityIdentifier("makePodcast")
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .buttonStyle(DCIconButtonStyle())
            .accessibilityLabel(Text("More"))
            .accessibilityIdentifier("nowPlayingMore")
        }
        .padding(.top, DCTheme.spacingM)
    }

    private var cover: some View {
        RoundedRectangle(cornerRadius: 24, style: .continuous)
            .fill(LinearGradient(colors: [DigestStyle.tint, DCTheme.brandPurple], startPoint: .topLeading, endPoint: .bottomTrailing))
            .aspectRatio(1, contentMode: .fit)
            .frame(maxWidth: 260)
            .overlay {
                Image(systemName: "headphones")
                    .font(.system(size: 72, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
            }
            .accessibilityHidden(true)
    }

    private func titles(_ episode: PodcastEpisode) -> some View {
        VStack(spacing: DCTheme.spacingXS) {
            Text(positionLine(episode))
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(chapterTitle(episode))
                .font(.title3.weight(.bold))
                .multilineTextAlignment(.center)
                .lineLimit(3)
            Text(podcast.statusLine(for: episode))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("podcastStatus")
        }
    }

    private func chapterTitle(_ episode: PodcastEpisode) -> String {
        if podcast.isPlayingEpisode, let item = player.currentItem { return item.title }
        return episode.title
    }

    /// "Topic 2 of 6 · Maker Space", or Welcome / Wrap-up for the other chapters.
    private func positionLine(_ episode: PodcastEpisode) -> String {
        guard podcast.isPlayingEpisode, let chapter = podcast.currentChapter else {
            return String(localized: "Today’s podcast", comment: "Now Playing: above the title before anything plays")
        }
        switch chapter.kind {
        case .intro:
            return String(localized: "Welcome", comment: "Now Playing: the opening chapter")
        case .outro:
            return String(localized: "Wrap-up", comment: "Now Playing: the closing chapter")
        case .topic:
            let topics = episode.entries.filter { $0.chapter.kind == .topic }
            let number = (topics.firstIndex { $0.id == chapter.id } ?? 0) + 1
            let line = String(localized: "Topic \(number) of \(topics.count)", comment: "Now Playing: the topic chapter being played, then the number of topic chapters")
            guard let siteURL = chapter.siteURL else { return line }
            return line + " · " + app.forumInfo(siteURL: siteURL).displayName
        }
    }

    // MARK: Controls

    private func controls(_ episode: PodcastEpisode) -> some View {
        HStack(spacing: 0) {
            control("backward.end.fill", Text("Previous chapter"), id: "podcastPreviousChapter", episode) { player.previousChapter() }
            control("gobackward.15", Text("Back 15 seconds"), id: "podcastSkipBack", episode) { player.skip(by: -15) }
            Button {
                DCHaptics.tap()
                if podcast.isPlayingEpisode { player.toggle() } else { podcast.playEpisode() }
            } label: {
                Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .contentTransition(.symbolEffect(.replace))
                    .font(.system(size: 64))
                    .foregroundStyle(DigestStyle.tint)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderless)
            .disabled(!episode.hasAudio)
            .accessibilityLabel(isPlaying ? Text("Pause") : Text("Play"))
            .accessibilityIdentifier("podcastPlay")
            control("goforward.15", Text("Forward 15 seconds"), id: "podcastSkipForward", episode) { player.skip(by: 15) }
            control("forward.end.fill", Text("Next chapter"), id: "podcastNextChapter", episode) { player.nextChapter() }
        }
    }

    private func control(
        _ symbol: String,
        _ label: Text,
        id: String,
        _ episode: PodcastEpisode,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            DCHaptics.tap()
            if !podcast.isPlayingEpisode { podcast.playEpisode() }
            action()
        } label: {
            Image(systemName: symbol)
                .font(.title2)
                .frame(maxWidth: .infinity, minHeight: DCTheme.controlHeight)
        }
        .buttonStyle(.borderless)
        .disabled(!episode.hasAudio)
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
    }

    private var isPlaying: Bool { podcast.isPlayingEpisode && player.isActive }

    private func needsContinue(_ episode: PodcastEpisode) -> Bool {
        !podcast.activity.isRunning && (!episode.isComplete || episode.entries.contains { $0.state == .failed })
    }

    // MARK: Ask about this, Open at

    @ViewBuilder
    private var actions: some View {
        if let chapter = podcast.currentChapter, chapter.kind == .topic {
            HStack(spacing: DCTheme.spacingM) {
                if podcast.canAsk(about: chapter) {
                    Button {
                        DCHaptics.tap()
                        ask(chapter)
                    } label: {
                        Label("Ask about this", systemImage: "waveform.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(DCActionButtonStyle(prominent: false))
                    .accessibilityHint(Text("Pauses the podcast and starts a voice conversation about this topic", comment: "Podcast: what Ask about this does"))
                    .accessibilityIdentifier("podcastAsk")
                }
                if let url = chapter.topicURL, let card = card(for: chapter) {
                    Button {
                        DCHaptics.tap()
                        open(url, card)
                    } label: {
                        Label { openLabel(chapter) } icon: { Image(systemName: "arrow.up.right.square") }
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(DCActionButtonStyle(prominent: false))
                    .accessibilityIdentifier("podcastOpenAt")
                }
            }
        }
    }

    private func openLabel(_ chapter: PodcastChapter) -> Text {
        if let post = chapter.postNumber {
            return Text("Open at #\(post)", comment: "Now Playing: opens the chapter's topic at the post it talks about")
        }
        return Text("Open topic", comment: "Now Playing: opens the chapter's topic")
    }

    private func card(for chapter: PodcastChapter) -> DigestCard? {
        app.todaysDigest?.cards.first { $0.topicKey == chapter.id }
    }

    private func open(_ url: URL, _ card: DigestCard) {
        dismiss()
        app.openDigestLink(url, card: card)
    }

    private func ask(_ chapter: PodcastChapter) {
        dismiss()
        podcast.ask(about: chapter) { url in
            guard let card = card(for: chapter) else { return }
            app.openDigestLink(url, card: card)
        }
    }

    // MARK: Chapters

    private func chapters(_ episode: PodcastEpisode) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Chapters", comment: "Now Playing: the chapter list's title")
                .font(.headline)
                .padding(.bottom, DCTheme.spacingS)
            ForEach(Array(episode.entries.enumerated()), id: \.element.id) { index, entry in
                chapterRow(index, entry)
                if index < episode.entries.count - 1 { Divider() }
            }
        }
    }

    private func chapterRow(_ index: Int, _ entry: PodcastEpisode.Entry) -> some View {
        HStack(spacing: DCTheme.spacingS) {
            Button {
                DCHaptics.tap()
                if podcast.isPlayingEpisode {
                    player.playChapter(index)
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
                .padding(.vertical, DCTheme.spacingS)
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .disabled(!entry.isReady)
            .accessibilityIdentifier("podcastChapter-\(index)")
            if let url = entry.chapter.topicURL, let card = card(for: entry.chapter) {
                Button {
                    DCHaptics.tap()
                    open(url, card)
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

    private func isCurrent(_ index: Int) -> Bool {
        podcast.isPlayingEpisode && player.chapterIndex == index
    }

    private func symbol(_ index: Int, _ entry: PodcastEpisode.Entry) -> String {
        if isCurrent(index) { return player.isActive ? "speaker.wave.2.fill" : "pause.fill" }
        switch entry.state {
        case .ready: return entry.chapter.kind == .topic ? "text.bubble" : "sparkles"
        case .failed: return "exclamationmark.triangle"
        case .pending, .working: return "clock"
        }
    }

    private func detail(_ entry: PodcastEpisode.Entry) -> String {
        switch entry.state {
        case .ready:
            return entry.duration.map(PodcastClock.format) ?? ""
        case .working:
            return String(localized: "Recording…", comment: "Podcast chapter: being written or spoken")
        case .pending:
            return String(localized: "Waiting", comment: "Podcast chapter: queued behind other chapters")
        case .failed:
            return entry.error.isEmpty ? String(localized: "Couldn’t be recorded", comment: "Podcast chapter error without details") : entry.error
        }
    }
}

// MARK: - Scrubber

/// Elapsed and remaining time with a seek bar. Observes the player, which is
/// the only thing that redraws on its time ticks.
private struct NowPlayingScrubber: View {
    @ObservedObject var player: PodcastPlayer
    let episode: PodcastEpisode
    /// The value under the thumb while dragging; nil follows the player.
    @State private var dragging: Double?

    private var timeline: PodcastTimeline {
        PodcastTimeline(durations: episode.entries.map { $0.isReady ? $0.duration : nil })
    }

    private var isThisEpisode: Bool { player.playlist?.id == episode.digestID.uuidString }

    private var elapsed: Double {
        isThisEpisode ? timeline.elapsed(player.position) : 0
    }

    var body: some View {
        let total = max(timeline.total, 1)
        let shown = min(dragging ?? elapsed, total)
        VStack(spacing: 2) {
            Slider(
                value: Binding(get: { shown }, set: { dragging = $0 }),
                in: 0...total
            ) { editing in
                guard !editing, let target = dragging else { return }
                dragging = nil
                if isThisEpisode { player.seek(toElapsed: target) }
            }
            .tint(DigestStyle.tint)
            .disabled(!isThisEpisode || timeline.total <= 0)
            .accessibilityLabel(Text("Position", comment: "Podcast progress bar"))
            .accessibilityValue(Text(verbatim: "\(PodcastClock.format(shown)) / \(PodcastClock.format(timeline.total))"))
            .accessibilityIdentifier("nowPlayingScrubber")
            HStack {
                Text(PodcastClock.format(shown))
                Spacer()
                Text("-" + PodcastClock.format(max(0, timeline.total - shown)))
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
        }
    }
}

// MARK: - Shared bits

enum PodcastClock {
    /// "3:07".
    static func format(_ seconds: TimeInterval) -> String {
        Duration.seconds(max(0, seconds.rounded(.down))).formatted(.time(pattern: .minuteSecond))
    }
}

extension PodcastController {
    /// What the podcast is doing: writing or recording a chapter, offline,
    /// or the playback position.
    func statusLine(for episode: PodcastEpisode) -> String {
        func title(of id: String) -> String {
            episode.entries.first { $0.id == id }?.chapter.title ?? ""
        }
        switch activity {
        case .scripting(let id):
            return String(localized: "Writing “\(title(of: id))”…", comment: "Podcast: a chapter's dialogue is being written; the placeholder is its title")
        case .speaking(let id):
            return String(localized: "Recording “\(title(of: id))”…", comment: "Podcast: a chapter is being spoken; the placeholder is its title")
        case .unreachable:
            return String(localized: "Offline. The podcast continues when you’re back online.", comment: "Podcast: couldn't reach the AI provider or Google")
        case .idle:
            if isPlayingEpisode, player.state == .waiting {
                return String(localized: "Waiting for the next chapter…", comment: "Podcast: playback waits for the next chapter to be recorded")
            }
            if isPlayingEpisode, player.playlist != nil {
                return String(localized: "Chapter \(player.chapterIndex + 1) of \(episode.entries.count)", comment: "Podcast: the current chapter, then the number of chapters")
            }
            return episode.isComplete
                ? String(localized: "Ready to play", comment: "Podcast: every chapter is recorded")
                : String(localized: "\(episode.readyCount) of \(episode.entries.count) chapters ready", comment: "Podcast progress: chapters recorded so far, then the number of chapters")
        }
    }
}
