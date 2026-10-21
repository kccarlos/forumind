import AVFoundation
import Combine
import Foundation
import MediaPlayer

// MARK: - Player
//
// Plays an episode's chapter files one after another (or a read-aloud),
// separate from voice chat: the audio session is `.playback` /
// `.spokenAudio`, never `.voiceChat`, so the microphone stays off and the
// audio keeps playing in the background (`UIBackgroundModes: audio`).
//
// - `PodcastTimeline`: the chapters as one timeline (skips of 15 s cross
//   chapter boundaries; next / previous chapter).
// - `PodcastPlayer`: state, position, chapter navigation, interruptions and
//   route changes, the hand-over to a voice session and back, the
//   remembered position. The audio, the audio session and Now Playing are
//   behind protocols, so tests drive it with fakes.

struct PodcastPlaylist: Equatable {
    struct Item: Equatable, Identifiable {
        var id: String
        var title: String
        /// Nil until the chapter's audio is made.
        var url: URL?
        var duration: TimeInterval?

        var isReady: Bool { url != nil && duration != nil }
    }

    /// The digest id, or "read-aloud:…"; positions are remembered by it.
    var id: String
    var title: String
    var items: [Item]
    /// More chapters are still being made.
    var isGrowing = false
}

/// The chapters as one timeline. Only chapters with audio count; the
/// position never moves into one that isn't made yet.
struct PodcastTimeline: Equatable {
    var durations: [TimeInterval?]

    struct Position: Equatable {
        var chapter: Int
        var time: TimeInterval
    }

    var total: TimeInterval { durations.compactMap { $0 }.reduce(0, +) }

    func offset(of chapter: Int) -> TimeInterval {
        durations.prefix(max(0, min(chapter, durations.count))).compactMap { $0 }.reduce(0, +)
    }

    func elapsed(_ position: Position) -> TimeInterval {
        offset(of: position.chapter) + position.time
    }

    func isReady(_ chapter: Int) -> Bool {
        durations.indices.contains(chapter) && durations[chapter] != nil
    }

    /// Moves by `delta` seconds, across chapter boundaries, clamped to the
    /// start and to the end of the last chapter with audio.
    func skip(_ delta: TimeInterval, from position: Position) -> Position {
        var chapter = position.chapter
        var time = position.time + delta
        while time < 0 {
            guard chapter > 0, let previous = durations[chapter - 1] else { return Position(chapter: chapter, time: 0) }
            chapter -= 1
            time += previous
        }
        while let duration = durations[safe: chapter] ?? nil, time >= duration {
            guard isReady(chapter + 1) else { return Position(chapter: chapter, time: max(0, duration - 0.5)) }
            time -= duration
            chapter += 1
        }
        return Position(chapter: chapter, time: time)
    }

    /// Previous chapter, or the start of this one after its first 3 s.
    func previousChapter(from position: Position) -> Position {
        if position.time > 3 || position.chapter == 0 { return Position(chapter: position.chapter, time: 0) }
        return Position(chapter: position.chapter - 1, time: 0)
    }

    func nextChapter(from position: Position) -> Position? {
        position.chapter + 1 < durations.count ? Position(chapter: position.chapter + 1, time: 0) : nil
    }

    /// The position at `elapsed` seconds from the start.
    func position(atElapsed elapsed: TimeInterval) -> Position {
        var remaining = max(0, elapsed)
        for (index, duration) in durations.enumerated() {
            guard let duration else { return Position(chapter: index, time: 0) }
            if remaining < duration { return Position(chapter: index, time: remaining) }
            remaining -= duration
        }
        let last = max(0, durations.count - 1)
        return Position(chapter: last, time: max(0, ((durations[safe: last] ?? nil) ?? 0) - 0.5))
    }
}

/// One chapter file at a time.
@MainActor
protocol PodcastAudioPlayback: AnyObject {
    /// Loads a file and returns its duration.
    func load(_ url: URL) throws -> TimeInterval
    func play()
    func pause()
    func stop()
    var currentTime: TimeInterval { get set }
    var isPlaying: Bool { get }
    /// The loaded file played to its end.
    var onFinish: (() -> Void)? { get set }
}

@MainActor
protocol PodcastAudioSessioning: AnyObject {
    /// `.playback` / `.spokenAudio`, active.
    func activateForPlayback() throws
    func deactivate()
    /// The output is a hands-free (HFP) route: AirPods while a microphone
    /// session still holds them.
    var routeIsHandsFree: Bool { get }
}

/// The lock screen, Control Center and AirPods.
@MainActor
protocol PodcastNowPlayingCenter: AnyObject {
    func attach(_ player: PodcastPlayer)
    func update(_ info: PodcastNowPlayingInfo?)
}

struct PodcastNowPlayingInfo: Equatable {
    var title: String
    var chapterTitle: String
    var chapter: Int
    var chapterCount: Int
    var duration: TimeInterval
    var elapsed: TimeInterval
    var isPlaying: Bool
}

/// Where each playlist was left, across launches.
final class PodcastPositionStore {
    private let defaults: UserDefaults
    private static let key = "podcast.positions"
    static let kept = 12

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func position(for id: String) -> PodcastTimeline.Position? {
        guard let saved = all[id] as? [Double], saved.count >= 2 else { return nil }
        return PodcastTimeline.Position(chapter: Int(saved[0]), time: saved[1])
    }

    func save(_ position: PodcastTimeline.Position, for id: String) {
        var positions = all
        positions[id] = [Double(position.chapter), position.time, Date().timeIntervalSince1970]
        if positions.count > Self.kept {
            let oldest = positions.sorted { (($0.value as? [Double])?[safe: 2] ?? 0) < (($1.value as? [Double])?[safe: 2] ?? 0) }
            for entry in oldest.prefix(positions.count - Self.kept) { positions[entry.key] = nil }
        }
        defaults.set(positions, forKey: Self.key)
    }

    func remove(_ id: String) {
        var positions = all
        positions[id] = nil
        defaults.set(positions, forKey: Self.key)
    }

    private var all: [String: Any] { defaults.dictionary(forKey: Self.key) ?? [:] }
}

@MainActor
final class PodcastPlayer: ObservableObject {
    enum State: Equatable {
        case idle
        case playing
        case paused
        /// Playing, but the next chapter's audio isn't made yet.
        case waiting
    }

    @Published private(set) var playlist: PodcastPlaylist?
    @Published private(set) var state: State = .idle
    @Published private(set) var chapterIndex = 0
    /// Seconds into the current chapter (refreshed twice a second).
    @Published private(set) var time: TimeInterval = 0
    /// Paused for a voice session ("Ask about this"); resumes when it ends.
    @Published private(set) var isSuspendedForVoice = false
    /// The last audio failure, for the mini player.
    @Published private(set) var failure: String?

    /// Remote "play" is refused while this says so (a voice session is on).
    var blocksRemotePlay: () -> Bool = { false }
    /// How long `resumeAfterVoice` waits for AirPods to leave hands-free.
    var routeSettleLimit: Duration = .seconds(2)
    var routeSettleStep: Duration = .milliseconds(100)

    private let audio: PodcastAudioPlayback
    private let session: PodcastAudioSessioning
    private let positions: PodcastPositionStore
    private let nowPlaying: PodcastNowPlayingCenter?
    private var loadedChapter: Int?
    private var wasPlayingBeforeVoice = false
    private var wasPlayingBeforeInterruption = false
    private var ticker: Timer?
    private var lastSavedAt = Date.distantPast
    static let saveInterval: TimeInterval = 5

    init(
        audio: PodcastAudioPlayback,
        session: PodcastAudioSessioning,
        positions: PodcastPositionStore = PodcastPositionStore(),
        nowPlaying: PodcastNowPlayingCenter? = nil
    ) {
        self.audio = audio
        self.session = session
        self.positions = positions
        self.nowPlaying = nowPlaying
        audio.onFinish = { [weak self] in self?.chapterFinished() }
        nowPlaying?.attach(self)
    }

    var timeline: PodcastTimeline {
        PodcastTimeline(durations: playlist?.items.map { $0.isReady ? $0.duration : nil } ?? [])
    }

    var position: PodcastTimeline.Position {
        PodcastTimeline.Position(chapter: chapterIndex, time: time)
    }

    var isActive: Bool { state == .playing || state == .waiting }
    var currentItem: PodcastPlaylist.Item? { playlist?.items[safe: chapterIndex] }

    // MARK: Playlist

    /// Shows a playlist, at its remembered position (or a given chapter).
    func load(_ playlist: PodcastPlaylist, chapter: Int? = nil, autoplay: Bool = false) {
        if self.playlist?.id == playlist.id {
            update(playlist)
            if let chapter { select(PodcastTimeline.Position(chapter: chapter, time: 0)) }
            if autoplay { play() }
            return
        }
        savePosition()
        stopAudio()
        self.playlist = playlist
        let saved = positions.position(for: playlist.id)
        let start = chapter.map { PodcastTimeline.Position(chapter: $0, time: 0) }
            ?? saved.flatMap { $0.chapter < playlist.items.count ? $0 : nil }
            ?? PodcastTimeline.Position(chapter: 0, time: 0)
        chapterIndex = start.chapter
        time = start.time
        state = .paused
        failure = nil
        publishNowPlaying()
        if autoplay { play() }
    }

    /// The same playlist with more chapters made (or durations known).
    func update(_ playlist: PodcastPlaylist) {
        guard self.playlist?.id == playlist.id else { return }
        let previous = self.playlist
        self.playlist = playlist
        if previous?.items[safe: chapterIndex]?.url != playlist.items[safe: chapterIndex]?.url {
            loadedChapter = nil
        }
        if state == .waiting, timeline.isReady(chapterIndex) {
            startCurrent()
        }
        publishNowPlaying()
    }

    /// Ends playback and forgets the playlist (its episode was deleted).
    func unload(forgettingPosition: Bool = false) {
        if let id = playlist?.id {
            if forgettingPosition { positions.remove(id) } else { savePosition() }
        }
        stopAudio()
        playlist = nil
        state = .idle
        chapterIndex = 0
        time = 0
        isSuspendedForVoice = false
        nowPlaying?.update(nil)
        session.deactivate()
    }

    // MARK: Transport

    func play() {
        guard playlist != nil, !isSuspendedForVoice else { return }
        // At the very end: from the top.
        if let items = playlist?.items, chapterIndex == items.count - 1, let duration = items.last?.duration,
           time >= duration - 0.6, !(playlist?.isGrowing ?? false) {
            chapterIndex = 0
            time = 0
            loadedChapter = nil
        }
        guard timeline.isReady(chapterIndex) else {
            state = .waiting
            publishNowPlaying()
            return
        }
        startCurrent()
    }

    func pause() {
        guard isActive else { return }
        if loadedChapter != nil { time = audio.currentTime }
        audio.pause()
        state = .paused
        stopTicker()
        savePosition()
        publishNowPlaying()
    }

    func toggle() {
        isActive ? pause() : play()
    }

    func skip(by delta: TimeInterval) {
        guard playlist != nil else { return }
        syncTime()
        select(timeline.skip(delta, from: position))
    }

    func nextChapter() {
        syncTime()
        guard let next = timeline.nextChapter(from: position) else { return }
        select(next)
    }

    func previousChapter() {
        syncTime()
        select(timeline.previousChapter(from: position))
    }

    func playChapter(_ index: Int) {
        guard playlist?.items.indices.contains(index) == true else { return }
        select(PodcastTimeline.Position(chapter: index, time: 0))
        if !isActive { play() }
    }

    /// A position on the whole timeline (the lock screen's scrubber).
    func seek(toElapsed elapsed: TimeInterval) {
        select(timeline.position(atElapsed: elapsed))
    }

    // MARK: Events

    /// A call or Siri took the audio; resumes if iOS says it may.
    func interruptionBegan() {
        wasPlayingBeforeInterruption = isActive
        if isActive { pause() }
    }

    func interruptionEnded(shouldResume: Bool) {
        defer { wasPlayingBeforeInterruption = false }
        guard shouldResume, wasPlayingBeforeInterruption, !isSuspendedForVoice else { return }
        play()
    }

    /// Headphones unplugged (or a Bluetooth route gone): pause, as every
    /// audio app does. Other route changes (the voice hand-over's category
    /// change) don't pause.
    func outputDeviceLost() {
        pause()
    }

    /// "Ask about this": pause before the voice session takes the audio.
    func suspendForVoice() {
        guard !isSuspendedForVoice else { return }
        wasPlayingBeforeVoice = isActive
        pause()
        stopAudio()
        isSuspendedForVoice = true
    }

    /// The voice session ended: back to `.playback`, wait for the route to
    /// leave hands-free (AirPods go HFP → A2DP when the microphone closes),
    /// then reload the chapter, so it plays on that route at normal
    /// quality, and continue where it was.
    func resumeAfterVoice() async {
        guard isSuspendedForVoice else { return }
        isSuspendedForVoice = false
        guard wasPlayingBeforeVoice else {
            publishNowPlaying()
            return
        }
        wasPlayingBeforeVoice = false
        try? session.activateForPlayback()
        var waited: Duration = .zero
        while session.routeIsHandsFree, waited < routeSettleLimit {
            try? await Task.sleep(for: routeSettleStep)
            waited += routeSettleStep
        }
        guard !isSuspendedForVoice, playlist != nil else { return }
        loadedChapter = nil
        play()
    }

    /// Saves where the playlist is (also on going to the background).
    func savePosition() {
        guard let id = playlist?.id else { return }
        syncTime()
        positions.save(position, for: id)
        lastSavedAt = Date()
    }

    // MARK: Private

    private func select(_ target: PodcastTimeline.Position) {
        let wasActive = isActive
        chapterIndex = target.chapter
        time = target.time
        if wasActive {
            if timeline.isReady(target.chapter) {
                startCurrent()
            } else {
                audio.pause()
                state = .waiting
            }
        } else if loadedChapter == target.chapter {
            audio.currentTime = target.time
        } else {
            loadedChapter = nil
        }
        savePosition()
        publishNowPlaying()
    }

    private func startCurrent() {
        guard let item = currentItem, let url = item.url else {
            state = .waiting
            return
        }
        do {
            try session.activateForPlayback()
            if loadedChapter != chapterIndex {
                _ = try audio.load(url)
                loadedChapter = chapterIndex
            }
            audio.currentTime = time
            audio.play()
            state = .playing
            failure = nil
            startTicker()
        } catch {
            state = .paused
            failure = error.localizedDescription
        }
        publishNowPlaying()
    }

    private func chapterFinished() {
        guard let playlist else { return }
        stopTicker()
        let next = chapterIndex + 1
        if next < playlist.items.count {
            chapterIndex = next
            time = 0
            loadedChapter = nil
            if timeline.isReady(next) { startCurrent() } else { state = .waiting }
        } else if playlist.isGrowing {
            time = currentItem?.duration ?? time
            state = .waiting
        } else {
            time = currentItem?.duration ?? time
            state = .paused
        }
        savePosition()
        publishNowPlaying()
    }

    private func stopAudio() {
        stopTicker()
        audio.stop()
        loadedChapter = nil
    }

    private func syncTime() {
        if state == .playing, loadedChapter == chapterIndex { time = audio.currentTime }
    }

    private func startTicker() {
        guard ticker == nil else { return }
        ticker = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }

    private func tick() {
        guard state == .playing else { return }
        time = audio.currentTime
        if Date().timeIntervalSince(lastSavedAt) >= Self.saveInterval { savePosition() }
        publishNowPlaying()
    }

    private func publishNowPlaying() {
        guard let nowPlaying else { return }
        guard let playlist else {
            nowPlaying.update(nil)
            return
        }
        nowPlaying.update(PodcastNowPlayingInfo(
            title: playlist.title,
            chapterTitle: currentItem?.title ?? "",
            chapter: chapterIndex,
            chapterCount: playlist.items.count,
            duration: timeline.total,
            elapsed: timeline.elapsed(position),
            isPlaying: state == .playing
        ))
    }
}

// MARK: - System implementations

/// `AVAudioPlayer`, one chapter file at a time.
@MainActor
final class SystemPodcastAudio: NSObject, PodcastAudioPlayback, AVAudioPlayerDelegate {
    private var player: AVAudioPlayer?
    var onFinish: (() -> Void)?

    func load(_ url: URL) throws -> TimeInterval {
        player?.stop()
        let player = try AVAudioPlayer(contentsOf: url)
        player.delegate = self
        player.prepareToPlay()
        self.player = player
        return player.duration
    }

    func play() { player?.play() }
    func pause() { player?.pause() }

    func stop() {
        player?.stop()
        player = nil
    }

    var currentTime: TimeInterval {
        get { player?.currentTime ?? 0 }
        set { player?.currentTime = newValue }
    }

    var isPlaying: Bool { player?.isPlaying ?? false }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in self?.onFinish?() }
    }
}

/// The shared `AVAudioSession` in `.playback` / `.spokenAudio`, and the
/// interruptions and route changes, passed to the player.
@MainActor
final class SystemPodcastAudioSession: PodcastAudioSessioning {
    weak var player: PodcastPlayer?
    private var observers: [NSObjectProtocol] = []

    init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated { self?.interruption(note) }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated { self?.routeChanged(note) }
        })
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    func activateForPlayback() throws {
        let session = AVAudioSession.sharedInstance()
        if session.category != .playback || session.mode != .spokenAudio {
            try session.setCategory(.playback, mode: .spokenAudio, options: [])
        }
        try session.setActive(true)
    }

    func deactivate() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    var routeIsHandsFree: Bool {
        AVAudioSession.sharedInstance().currentRoute.outputs.contains { $0.portType == .bluetoothHFP }
    }

    private func interruption(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw)
        else {
            return
        }
        switch type {
        case .began:
            player?.interruptionBegan()
        case .ended:
            let options = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt).map(AVAudioSession.InterruptionOptions.init) ?? []
            player?.interruptionEnded(shouldResume: options.contains(.shouldResume))
        @unknown default:
            break
        }
    }

    private func routeChanged(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable
        else {
            return
        }
        player?.outputDeviceLost()
    }
}

/// `MPNowPlayingInfoCenter` and `MPRemoteCommandCenter`: title, chapter,
/// duration and elapsed time; play/pause, ±15 s, next/previous chapter and
/// the scrubber, on the lock screen, in Control Center and on AirPods.
@MainActor
final class SystemPodcastNowPlaying: PodcastNowPlayingCenter {
    private weak var player: PodcastPlayer?
    private var registered = false

    func attach(_ player: PodcastPlayer) {
        self.player = player
    }

    func update(_ info: PodcastNowPlayingInfo?) {
        let center = MPNowPlayingInfoCenter.default()
        guard let info else {
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
            setCommandsEnabled(false)
            return
        }
        registerIfNeeded()
        setCommandsEnabled(true)
        center.nowPlayingInfo = [
            MPMediaItemPropertyTitle: info.title,
            MPMediaItemPropertyArtist: info.chapterTitle,
            MPMediaItemPropertyAlbumTitle: "Forumind",
            MPMediaItemPropertyPlaybackDuration: info.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: info.elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: info.isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyChapterNumber: info.chapter,
            MPNowPlayingInfoPropertyChapterCount: info.chapterCount,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue
        ]
        center.playbackState = info.isPlaying ? .playing : .paused
    }

    private func registerIfNeeded() {
        guard !registered else { return }
        registered = true
        let commands = MPRemoteCommandCenter.shared()
        commands.skipForwardCommand.preferredIntervals = [15]
        commands.skipBackwardCommand.preferredIntervals = [15]
        commands.playCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated {
                guard let player = self?.player, !player.blocksRemotePlay() else { return .commandFailed }
                player.play()
                return .success
            }
        }
        commands.pauseCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated {
                self?.player?.pause()
                return .success
            }
        }
        commands.togglePlayPauseCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated {
                guard let player = self?.player else { return .commandFailed }
                if !player.isActive, player.blocksRemotePlay() { return .commandFailed }
                player.toggle()
                return .success
            }
        }
        commands.skipForwardCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated {
                self?.player?.skip(by: 15)
                return .success
            }
        }
        commands.skipBackwardCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated {
                self?.player?.skip(by: -15)
                return .success
            }
        }
        commands.nextTrackCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated {
                self?.player?.nextChapter()
                return .success
            }
        }
        commands.previousTrackCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated {
                self?.player?.previousChapter()
                return .success
            }
        }
        commands.changePlaybackPositionCommand.addTarget { [weak self] event in
            MainActor.assumeIsolated {
                guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
                self?.player?.seek(toElapsed: event.positionTime)
                return .success
            }
        }
    }

    private func setCommandsEnabled(_ enabled: Bool) {
        let commands = MPRemoteCommandCenter.shared()
        for command in [
            commands.playCommand, commands.pauseCommand, commands.togglePlayPauseCommand,
            commands.skipForwardCommand, commands.skipBackwardCommand,
            commands.nextTrackCommand, commands.previousTrackCommand, commands.changePlaybackPositionCommand
        ] as [MPRemoteCommand] {
            command.isEnabled = enabled
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
