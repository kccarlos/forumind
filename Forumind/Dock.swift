import SwiftUI

// The Dock (spec §8): the one floating layer at the bottom of the page. The
// layer for each state is chosen by `BottomLayer.resolve`; the voice Dock, the
// podcast row and the "Answer ready" row share one glass shape, so they morph
// into each other (`glassEffectID` on iOS 26+, `matchedGeometryEffect` before).

// MARK: - Which layer shows

/// What sits at the bottom of the screen (§8.1): exactly one of these.
enum BottomLayer: Equatable {
    /// The browser bar alone.
    case bar
    /// The bar with an "Answer ready" row.
    case barWithAnswerReady
    /// The bar with the podcast mini row.
    case barWithPodcast
    /// The voice Dock replaces the bar.
    case dock
    /// The drawer is up: its status row carries voice, playback and research.
    case drawer

    static func resolve(
        usesDrawer: Bool,
        drawerOpen: Bool,
        voiceShowing: Bool,
        answerReady: Bool,
        podcastPlaying: Bool
    ) -> BottomLayer {
        if usesDrawer, drawerOpen { return .drawer }
        if voiceShowing { return .dock }
        guard usesDrawer else { return .bar }
        if answerReady { return .barWithAnswerReady }
        if podcastPlaying { return .barWithPodcast }
        return .bar
    }
}

// MARK: - Text

enum DockText {
    /// "4:12".
    static func clock(_ seconds: Double) -> String {
        let whole = Int(max(0, seconds))
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }

    /// Whole minutes of today's allowance left; nil without a daily limit.
    static func minutesLeft(limitMinutes: Int, usedSeconds: Double) -> Int? {
        guard limitMinutes > 0 else { return nil }
        return max(0, Int((Double(limitMinutes) - usedSeconds / 60).rounded(.up)))
    }

    /// "4:12 · 26 min left today".
    static func sessionLine(connected: Double, minutesLeft: Int?) -> String {
        let time = clock(connected)
        guard let minutesLeft else { return time }
        return String(localized: "\(time) · \(minutesLeft) min left today", comment: "Voice Dock: the session's time, then the minutes left of today's allowance")
    }

    static func podcastPaused(at seconds: Double) -> String {
        String(localized: "Podcast paused at \(clock(seconds)) · resumes when you end", comment: "Voice Dock: the Today podcast waits while voice runs")
    }

    /// "Today · Topic 2 of 5 · 3:12 left".
    static func podcastLine(chapter: Int, count: Int, secondsLeft: Double) -> String {
        String(
            localized: "Today · Topic \(chapter + 1) of \(count) · \(PodcastClock.format(secondsLeft)) left",
            comment: "AI drawer status row while the Today podcast plays: chapter, chapter count, time left"
        )
    }

    @MainActor
    static func podcastLine(player: PodcastPlayer, episode: PodcastEpisode) -> String {
        let timeline = PodcastTimeline(durations: episode.entries.map { $0.isReady ? $0.duration : nil })
        return podcastLine(
            chapter: player.chapterIndex,
            count: episode.entries.count,
            secondsLeft: max(0, timeline.total - timeline.elapsed(player.position))
        )
    }
}

// MARK: - Answer ready and research (one source for the bar and the drawer)

extension AppModel {
    /// The running Ask the forum research, for the AI button's ring.
    var activeResearch: WorkRecord? {
        activities.first { $0.type == .agent && !$0.status.isTerminal }
    }

    /// A finished answer the reader has not looked at yet.
    var readyAnswer: WorkRecord? {
        activities.first {
            $0.type == .agent && $0.status == .completed && ($0.completedAt ?? .distantPast) > router.answersSeenAt
        }
    }

    /// Opens the drawer on the finished answer.
    func showAnswerReady() {
        assistantMode = .agent
        showSelectedAgentRun()
        router.answersSeenAt = Date()
        router.openDrawer(at: .medium)
    }
}

// MARK: - Material

/// The Dock's glass (iOS 26+) or material, one shape for every state.
private struct DockSurface: ViewModifier {
    let namespace: Namespace.ID

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: DCTheme.cardCornerRadius, style: .continuous)
        if #available(iOS 26.0, *) {
            content
                .glassEffect(.regular, in: shape)
                .glassEffectID("dock", in: namespace)
        } else {
            content
                .background(.regularMaterial, in: shape)
                .overlay { shape.stroke(DCTheme.border) }
                .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
                .matchedGeometryEffect(id: "dock", in: namespace)
        }
    }
}

private struct DockContainer<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer { content }
        } else {
            content
        }
    }
}

// MARK: - The layer

/// Result cards, and above or in place of the bar, the Dock or a row. Sits
/// in the page's bottom overlay (`BrowserContent`).
struct DockLayer: View {
    @ObservedObject var app: AppModel
    @ObservedObject var browser: ForumBrowserModel
    @ObservedObject var voice: VoiceController
    @ObservedObject var router: PresentationRouter
    @ObservedObject var podcast: PodcastController
    let showsHome: Bool
    @Namespace private var namespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var layer: BottomLayer {
        BottomLayer.resolve(
            usesDrawer: ContentView.usesDrawer,
            drawerOpen: router.drawerPhase.isPresented,
            voiceShowing: voice.showsBar,
            answerReady: app.activeResearch == nil && app.readyAnswer != nil,
            podcastPlaying: podcast.isPlayingEpisode && !podcast.player.isSuspendedForVoice
        )
    }

    private var transition: AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.96, anchor: .bottom))
    }

    var body: some View {
        VStack(spacing: DCTheme.spacingS) {
            if !showsHome { ResultCardsOverlay(app: app, browser: browser, voice: voice) }
            DockContainer {
                switch layer {
                case .dock:
                    VoiceDock(voice: voice, player: podcast.player)
                        .modifier(DockSurface(namespace: namespace))
                        .transition(transition)
                case .barWithAnswerReady:
                    DockAnswerReadyRow(app: app)
                        .modifier(DockSurface(namespace: namespace))
                        .transition(transition)
                case .barWithPodcast:
                    if let episode = podcast.episode {
                        DockPodcastRow(app: app, player: podcast.player, episode: episode)
                            .modifier(DockSurface(namespace: namespace))
                            .transition(transition)
                    }
                case .bar, .drawer:
                    EmptyView()
                }
            }
            .frame(maxWidth: DCTheme.contentMaxWidth)
        }
        .animation(DCMotion.respecting(reduceMotion, .spring(duration: 0.38, bounce: 0.14)), value: layer)
    }
}

// MARK: - Rows

private struct DockAnswerReadyRow: View {
    @ObservedObject var app: AppModel

    var body: some View {
        Button {
            DCHaptics.tap()
            app.showAnswerReady()
        } label: {
            HStack(spacing: DCTheme.spacingS) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(DCTheme.brandBlue)
                    .accessibilityHidden(true)
                Text("Answer ready", comment: "AI drawer status row: an Ask the forum answer finished")
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 0)
                Image(systemName: "chevron.up")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, DCTheme.spacingM)
            .frame(maxWidth: .infinity, minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("dockAnswerReady")
    }
}

/// The Today podcast while the drawer is closed. Tapping opens Now Playing.
private struct DockPodcastRow: View {
    @ObservedObject var app: AppModel
    @ObservedObject var player: PodcastPlayer
    let episode: PodcastEpisode

    var body: some View {
        HStack(spacing: 0) {
            Button {
                app.router.item = .nowPlaying
            } label: {
                HStack(spacing: DCTheme.spacingS) {
                    Image(systemName: "headphones")
                        .foregroundStyle(DigestStyle.tint)
                        .accessibilityHidden(true)
                    Text(verbatim: DockText.podcastLine(player: player, episode: episode))
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                        .foregroundStyle(.primary)
                    Spacer(minLength: 0)
                }
                .padding(.leading, DCTheme.spacingM)
                .frame(maxWidth: .infinity, minHeight: 48)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .nowPlayingZoomSource()
            .accessibilityIdentifier("dockPodcastOpen")
            Button {
                DCHaptics.tap()
                player.toggle()
            } label: {
                Image(systemName: player.isActive ? "pause.fill" : "play.fill")
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(DCIconButtonStyle())
            .accessibilityLabel(player.isActive ? Text("Pause") : Text("Play"))
            .accessibilityIdentifier("dockPodcastToggle")
            .padding(.trailing, DCTheme.spacingXS)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("dockPodcastRow")
    }
}

// MARK: - Level bars

/// The microphone's and the voice's loudness, written by the audio threads and
/// read by the bars' timeline. Not observable: it changes many times a second
/// and nothing but the bars cares.
final class VoiceLevels: @unchecked Sendable {
    private let lock = NSLock()
    private var inputLevel: Float = 0
    private var outputLevel: Float = 0
    private var outputAt: TimeInterval = 0

    func setInput(_ level: Float) {
        lock.lock(); inputLevel = level; lock.unlock()
    }

    func setOutput(_ level: Float, at time: TimeInterval) {
        lock.lock(); outputLevel = level; outputAt = time; lock.unlock()
    }

    var input: Float {
        lock.lock(); defer { lock.unlock() }
        return inputLevel
    }

    /// The voice's level; zero once its audio has stopped arriving.
    func output(at time: TimeInterval) -> Float {
        lock.lock(); defer { lock.unlock() }
        return time - outputAt < 0.25 ? outputLevel : 0
    }
}

/// Five bars: the input level while listening, the output level while
/// speaking, a slow pulse while thinking. 30 fps with 0.08 s smoothing; with
/// Reduce Motion they stand still and the label says the state.
struct VoiceLevelBars: View {
    enum Mode { case input, output, thinking, idle }

    let mode: Mode
    let levels: VoiceLevels?
    let tint: Color
    @State private var smoother = Smoother()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let shape: [Float] = [0.5, 0.8, 1, 0.7, 0.45]

    final class Smoother {
        var value: Float = 0
        var at: TimeInterval = 0
        func update(_ raw: Float, now: TimeInterval) -> Float {
            let dt = Float(min(0.2, max(0, now - at)))
            at = now
            value += (raw - value) * min(1, dt / 0.08)
            return value
        }
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { timeline in
            Canvas { context, size in
                let now = timeline.date.timeIntervalSinceReferenceDate
                let level = smoother.update(rawLevel(at: now), now: now)
                let width = size.width / 9
                for index in 0..<5 {
                    let wobble: Float = reduceMotion ? 0.7 : (mode == .thinking
                        ? 0.5 + 0.5 * Float(sin(now * 2.2 + Double(index) * 0.8))
                        : 0.75 + 0.25 * Float(sin(now * 9 + Double(index) * 1.3)))
                    let fraction = reduceMotion ? 0.4 : max(0.16, level * Self.shape[index] * wobble)
                    let height = size.height * CGFloat(min(1, fraction))
                    let rect = CGRect(x: CGFloat(index * 2) * width, y: (size.height - height) / 2, width: width, height: height)
                    context.fill(Path(roundedRect: rect, cornerRadius: width / 2), with: .color(tint))
                }
            }
        }
        .frame(width: 30, height: 22)
        .accessibilityHidden(true)
    }

    private func rawLevel(at now: TimeInterval) -> Float {
        switch mode {
        case .input: min(1, (levels?.input ?? 0.12) * 3)
        case .output: min(1, (levels?.output(at: now) ?? 0.3) * 2.5)
        case .thinking: 0.35
        case .idle: 0.1
        }
    }
}
