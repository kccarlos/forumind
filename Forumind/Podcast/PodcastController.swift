import AVFoundation
import Combine
import Foundation

// MARK: - Podcast
//
// Owned by AppModel (`app.podcast`), like `VoiceController`.
//
// - Making: `make(play:)` from the Today page, or right after today's
//   digest finishes on open when the daily podcast is on. The episode is
//   planned (intro, one chapter per summarized card, outro), then each
//   chapter is scripted (PodcastScript.swift) and spoken (PodcastSpeech.swift)
//   in order, saved after each step. The app going to the background stops
//   the run; it continues from the same chapter on open. No AI or TTS call
//   is made in the background.
// - Playing: `player` (PodcastPlayer.swift). Playback can start as soon as
//   the first chapter is spoken; later chapters join the playlist.
// - Ask about this: pauses the episode, opens the chapter's topic at its
//   post, and starts a voice session through `VoiceController` (with its
//   consent gate); the episode resumes where it was when the session ends,
//   is declined or can't start.
// - Read aloud: a summary or a digest card, one host, the same engines.

/// What "Ask about this" needs from the voice layer (`VoiceController`).
@MainActor
protocol PodcastVoiceStarting: AnyObject {
    var isActive: Bool { get }
    /// Called once the session is over, the consent was declined, or the
    /// session couldn't start.
    var onFinished: (() -> Void)? { get set }
    func start()
}

enum PodcastActivity: Equatable {
    case idle
    /// Writing the chapter with this id.
    case scripting(String)
    /// Speaking the chapter with this id.
    case speaking(String)
    /// The provider or Google couldn't be reached; continues next time.
    case unreachable

    var isRunning: Bool {
        switch self {
        case .scripting, .speaking: true
        case .idle, .unreachable: false
        }
    }
}

@MainActor
final class PodcastController: ObservableObject {
    /// Today's episode (nil until one is made).
    @Published private(set) var episode: PodcastEpisode?
    @Published private(set) var activity: PodcastActivity = .idle
    /// Why the last run stopped (shown on the Today page).
    @Published private(set) var lastError: String?
    /// Asks the user to agree before the first Google-voiced episode.
    @Published var consentProvider: VoiceProvider?
    /// The read-aloud being made or played (its id), for the buttons.
    @Published private(set) var readAloudID: String?

    let player: PodcastPlayer
    let store: PodcastStore
    /// The speech engine for a kind (tests and `-dc-podcast-fake` replace it).
    var makeEngine: ((PodcastEngineKind, PodcastVoices, String) -> PodcastSpeechEngine)?
    /// The voice layer for "Ask about this" (AppModel's `VoiceController`).
    weak var voice: PodcastVoiceStarting?
    /// Lets the Today page go before the voice session's consent sheet,
    /// which belongs to the root view, can appear.
    var askPresentationDelay: Duration = .milliseconds(650)

    private weak var app: AppModel?
    private var task: Task<Void, Never>?
    private var runID: UUID?
    private var readTask: Task<Void, Never>?
    /// What to do once the consent sheet is answered.
    private var pending: Pending?
    private var playerSubscription: AnyCancellable?

    private enum Pending {
        case make(play: Bool)
        case read(id: String, title: String, text: String)
    }

    init(app: AppModel, store: PodcastStore, player: PodcastPlayer? = nil) {
        self.app = app
        self.store = store
        if let player {
            self.player = player
        } else {
            let session = SystemPodcastAudioSession()
            let made = PodcastPlayer(audio: SystemPodcastAudio(), session: session, nowPlaying: SystemPodcastNowPlaying())
            session.player = made
            self.player = made
        }
        self.player.blocksRemotePlay = { [weak self] in self?.voice?.isActive ?? false }
        // The player's state changes redraw the views that observe this
        // controller; its time ticks (twice a second) do not: the views that
        // show the time observe the player.
        let player = self.player
        playerSubscription = Publishers.MergeMany(
            player.$playlist.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            player.$state.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            player.$chapterIndex.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            player.$isSuspendedForVoice.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            player.$failure.dropFirst().map { _ in () }.eraseToAnyPublisher()
        ).sink { [weak self] in self?.objectWillChange.send() }
    }

    static var isFake: Bool {
        #if DEBUG
        AssistantDebug.isActive && AssistantDebug.has("-dc-podcast-fake")
        #else
        false
        #endif
    }

    // MARK: State

    /// Loads today's episode from the cache (after launch, or a new digest).
    func refresh() {
        guard let digest = app?.todaysDigest else {
            if episode != nil { episode = nil }
            return
        }
        if episode?.digestID != digest.id {
            episode = store.load(digestID: digest.id)
            if let episode, player.playlist?.id == episode.digestID.uuidString {
                player.update(playlist(for: episode))
            }
        }
    }

    /// Today's digest has something to talk about, and nothing is making it.
    var canMake: Bool {
        guard let app, let digest = app.todaysDigest, !app.digestActivity.isRunning else { return false }
        guard digest.cards.contains(where: { $0.state == .done && !$0.summary.isEmpty }) else { return false }
        // The script is written like the digest: never showing the AI data
        // consent page, so the provider must already be allowed.
        return Self.isFake || app.canRunUnattended(.assistant)
    }

    var isPlayingEpisode: Bool {
        guard let episode else { return false }
        return player.playlist?.id == episode.digestID.uuidString
    }

    /// Google providers with a key, the voice provider first.
    var googleProviders: [VoiceProvider] {
        guard let app else { return [] }
        let preferred = app.settings.voice.provider
        return VoiceProvider.allCases
            .filter { !app.settings.configuration(for: $0.keyProvider).apiKey.isEmpty }
            .sorted { ($0 == preferred ? 0 : 1) < ($1 == preferred ? 0 : 1) }
    }

    func engineSelection(interactive: Bool) -> PodcastEngineSelection {
        if Self.isFake { return .engine(.fake) }
        guard let app else { return .engine(.onDevice) }
        return PodcastEngineSelector.select(
            choice: app.settings.podcast.engine,
            providers: googleProviders,
            settings: app.settings,
            interactive: interactive
        )
    }

    // MARK: Making

    /// The Today page's Make (and Play, with `play`). Continues an
    /// unfinished episode; asks for consent before the first Google-voiced
    /// one.
    func make(play: Bool = false, interactive: Bool = true) {
        guard let app, let digest = app.todaysDigest else { return }
        refresh()
        if var existing = episode {
            if play { playEpisode() }
            // Already being made: carry on (a restart would make the chapter
            // in progress again, another paid call).
            guard task == nil else { return }
            if !existing.isComplete || existing.entries.contains(where: { $0.state == .failed }) {
                guard interactive || !existing.entries.contains(where: { $0.state == .failed }) else { return }
                for index in existing.entries.indices where existing.entries[index].state == .failed {
                    existing.entries[index].state = .pending
                    existing.entries[index].error = ""
                }
                episode = existing
                store.save(existing)
                startRun(digestID: digest.id)
            }
            return
        }
        guard canMake else { return }
        let kind: PodcastEngineKind
        switch engineSelection(interactive: interactive) {
        case .needsConsent(let provider):
            pending = .make(play: play)
            consentProvider = provider
            return
        case .engine(let selected):
            kind = selected
        }
        let hosts = app.settings.podcast.hosts
        let chapters = PodcastScript.plan(for: digest, hosts: hosts)
        guard !chapters.isEmpty else { return }
        let made = PodcastEpisode(
            digestID: digest.id,
            day: digest.day,
            title: PodcastScript.episodeTitle(for: digest.createdAt),
            // The reading language (Settings), which is the app's language
            // unless the user chose another.
            language: ReadingLanguage.resolved(app.settings.readingLanguage),
            hosts: hosts,
            engine: kind,
            voices: kind.provider != nil ? app.settings.podcast.voices : nil,
            minutesPerChapter: app.settings.podcast.minutesPerChapter,
            entries: chapters.map { PodcastEpisode.Entry(chapter: $0) }
        )
        episode = made
        store.save(made)
        lastError = nil
        if play { playEpisode() }
        startRun(digestID: digest.id)
    }

    /// Today's episode made again from scratch (Make Podcast Again).
    func remake() {
        guard let episode else { return }
        deleteEpisodes([episode.digestID])
        make(play: false)
    }

    /// The consent sheet's Agree: recorded on this device, then on.
    func agree(_ provider: VoiceProvider) {
        guard let app else { return }
        app.settings.podcastConsent[provider.rawValue] = Date()
        app.saveSettings()
        consentProvider = nil
        continuePending()
    }

    /// The consent sheet's other choice: the device's voices from now on.
    func useOnDeviceVoices() {
        guard let app else { return }
        app.settings.podcast.engine = .onDevice
        app.saveSettings()
        consentProvider = nil
        continuePending()
    }

    func declineConsent() {
        consentProvider = nil
        pending = nil
    }

    func revokeConsent(_ provider: VoiceProvider) {
        guard let app else { return }
        app.settings.podcastConsent[provider.rawValue] = nil
        app.saveSettings()
    }

    private func continuePending() {
        let next = pending
        pending = nil
        switch next {
        case .make(let play): make(play: play)
        case .read(let id, let title, let text): readAloud(id: id, title: title, text: text)
        case nil: break
        }
    }

    /// Today's digest just finished on open: the daily podcast, if on.
    func digestCompleted(_ digestID: UUID) {
        guard let app, app.settings.podcastDailyEnabled, app.todaysDigest?.id == digestID else { return }
        make(play: false, interactive: false)
    }

    /// The app is open (Today page, foreground): continue an unfinished
    /// episode, or make today's when the daily podcast is on.
    func resumeIfNeeded() {
        guard let app, task == nil else { return }
        #if DEBUG
        if AssistantDebug.isActive { return }
        #endif
        refresh()
        if let episode {
            if !episode.isComplete { startRun(digestID: episode.digestID) }
        } else if app.settings.podcastDailyEnabled, app.todaysDigest?.isComplete == true {
            make(play: false, interactive: false)
        }
    }

    /// The app went to the background: the run stops; the chapter being
    /// made starts over next time.
    func pauseGeneration() {
        player.savePosition()
        guard let current = task else { return }
        current.cancel()
        task = nil
        runID = nil
        if let episode {
            let resumed = episode.resumed
            self.episode = resumed
            store.save(resumed)
        }
        if activity.isRunning { activity = .idle }
    }

    private func startRun(digestID: UUID) {
        if task != nil { pauseGeneration() }
        let id = UUID()
        runID = id
        task = Task { @MainActor [weak self] in
            await self?.run(digestID: digestID, runID: id)
            guard let self, self.runID == id else { return }
            self.task = nil
            self.runID = nil
            if self.activity.isRunning { self.activity = .idle }
        }
    }

    private func isCurrent(_ id: UUID) -> Bool {
        !Task.isCancelled && runID == id
    }

    private func run(digestID: UUID, runID: UUID) async {
        guard let app, var current = episode, current.digestID == digestID else { return }
        let context = app.runSettings(role: .assistant, topicKey: "")
        let kind = resolvedEngine(for: current)
        let voices = current.voices ?? app.settings.podcast.voices
        let engine = engine(kind, voices: voices, language: current.language)
        let topicCount = current.entries.filter { $0.chapter.kind == .topic }.count
        var topicIndex = 0
        var previousTitle: String?

        for index in current.entries.indices {
            guard isCurrent(runID) else { return }
            var entry = current.entries[index]
            if entry.chapter.kind == .topic { topicIndex += 1 }
            defer { if entry.chapter.kind == .topic { previousTitle = entry.chapter.title } }
            guard entry.state == .pending else { continue }

            entry.state = .working
            mutate(index, digestID: digestID) { $0 = entry }
            if !entry.chapter.isScripted {
                activity = .scripting(entry.id)
                guard let card = app.digests.first(where: { $0.id == digestID })?.cards.first(where: { $0.topicKey == entry.chapter.id }) else {
                    entry.state = .failed
                    mutate(index, digestID: digestID) { $0 = entry }
                    continue
                }
                do {
                    entry.chapter = try await script(card: card, index: topicIndex, count: topicCount, previousTitle: previousTitle, hosts: current.hosts, minutes: current.minutesPerChapter, language: current.language, context: context)
                } catch {
                    guard isCurrent(runID) else { return }
                    if NetworkFailure.isUnreachable(error) {
                        stopUnreachable(index, digestID: digestID)
                        return
                    }
                    entry.chapter.turns = PodcastScript.fallbackTurns(for: card)
                }
                guard isCurrent(runID) else { return }
                mutate(index, digestID: digestID) { $0 = entry }
            }

            activity = .speaking(entry.id)
            let name = "chapter-\(index + 1).\(engine.fileExtension)"
            do {
                try FileManager.default.createDirectory(at: store.folder(for: digestID), withIntermediateDirectories: true)
                let duration = try await engine.synthesize(entry.chapter.turns, to: store.audioURL(name, digestID: digestID))
                guard isCurrent(runID) else { return }
                entry.audioFile = name
                entry.duration = duration
                entry.state = .ready
                entry.error = ""
            } catch {
                guard isCurrent(runID) else { return }
                if NetworkFailure.isUnreachable(error) {
                    stopUnreachable(index, digestID: digestID)
                    return
                }
                entry.state = .failed
                entry.error = error.localizedDescription
                mutate(index, digestID: digestID) { $0 = entry }
                // A refused key or model fails every chapter the same way.
                if case PodcastSpeechError.http(let status, _) = error, (400..<500).contains(status), status != 429 {
                    lastError = error.localizedDescription
                    markRemainingFailed(after: index, digestID: digestID, error: error.localizedDescription)
                    return
                }
                continue
            }
            mutate(index, digestID: digestID) { $0 = entry }
            current = episode ?? current
        }
    }

    private func stopUnreachable(_ index: Int, digestID: UUID) {
        mutate(index, digestID: digestID) { $0.state = .pending }
        activity = .unreachable
    }

    private func markRemainingFailed(after index: Int, digestID: UUID, error: String) {
        guard var episode, episode.digestID == digestID else { return }
        for later in episode.entries.indices where later > index && episode.entries[later].state == .pending {
            episode.entries[later].state = .failed
            episode.entries[later].error = error
        }
        self.episode = episode
        store.save(episode)
        player.update(playlist(for: episode))
    }

    /// The episode's engine, unless its key or consent is gone since.
    private func resolvedEngine(for episode: PodcastEpisode) -> PodcastEngineKind {
        guard let app, let provider = episode.engine.provider else { return episode.engine }
        let usable = !app.settings.configuration(for: provider.keyProvider).apiKey.isEmpty
            && PodcastConsent.isGranted(provider, in: app.settings)
        return usable ? episode.engine : .onDevice
    }

    private func engine(_ kind: PodcastEngineKind, voices: PodcastVoices, language: String) -> PodcastSpeechEngine {
        if let makeEngine { return makeEngine(kind, voices, language) }
        switch kind {
        case .aiStudio, .vertex:
            let provider = kind.provider ?? .aiStudio
            let configuration = app?.settings.configuration(for: provider.keyProvider) ?? ProviderConfiguration(provider: provider.keyProvider)
            return GeminiSpeechEngine(
                endpoint: GeminiTTS.Endpoint(provider: provider, baseURL: configuration.baseURL, apiKey: configuration.apiKey),
                voices: voices
            )
        case .fake:
            #if DEBUG
            return SilentSpeechEngine()
            #else
            return SystemSpeechEngine(appLanguage: language)
            #endif
        case .onDevice:
            return SystemSpeechEngine(appLanguage: language)
        }
    }

    /// Asks the text model for the chapter; a rejected answer is asked for
    /// again once with the reason, then the chapter falls back to the card.
    private func script(
        card: DigestCard, index: Int, count: Int, previousTitle: String?, hosts: PodcastHosts,
        minutes: Double, language: String, context: RunSettings
    ) async throws -> PodcastChapter {
        guard let app, !Self.isFake else {
            var chapter = PodcastChapter(card: card)
            chapter.turns = PodcastScript.fallbackTurns(for: card)
            return chapter
        }
        let limit = context.provider == .appleIntelligence ? 1_500 : 4_000
        var topicText = ""
        if let session = app.sessions[card.topicKey] {
            let raw = session.source.isEmpty ? session.rawPages.map(\.content).joined(separator: "\n") : session.source
            if !raw.isEmpty {
                topicText = String(PromptBuilder.boundedForumContext(
                    app.moderated(raw, siteURL: card.siteURL, topicID: card.topicID),
                    limit: limit,
                    minimum: 500
                ).prefix(limit + 200))
            }
        }
        let prompt = PodcastPrompt.Chapter(
            card: card, forumName: app.forumInfo(siteURL: card.siteURL).displayName,
            index: index, count: count, previousTitle: previousTitle, topicText: topicText
        )
        let system = PodcastPrompt.system(hosts: hosts, chapter: prompt, minutes: minutes, languageName: Self.languageName(language), language: language)
        let content = PodcastPrompt.content(for: prompt)
        var messages = [ChatMessage(role: .user, content: content)]
        var lastFailure: PodcastScriptError?
        for _ in 0..<2 {
            try Task.checkCancellation()
            let answer = try await app.aiService.complete(
                system: system,
                messages: messages,
                configuration: context.configuration,
                provider: context.provider,
                maxTokens: 2_048
            )
            do {
                return try PodcastScriptParser.chapter(from: answer, for: card, grounding: content)
            } catch let failure as PodcastScriptError {
                lastFailure = failure
                messages += [
                    ChatMessage(role: .assistant, content: answer),
                    ChatMessage(role: .user, content: PodcastPrompt.retry(reason: failure.reason))
                ]
            }
        }
        throw lastFailure ?? PodcastScriptError.notJSON
    }

    static func languageName(_ code: String) -> String {
        switch code {
        case "zh-Hans": "Simplified Chinese"
        case "zh-Hant": "Traditional Chinese"
        case "en": "English"
        default: Locale(identifier: "en").localizedString(forIdentifier: code) ?? "English"
        }
    }

    private func mutate(_ index: Int, digestID: UUID, _ change: (inout PodcastEpisode.Entry) -> Void) {
        guard var episode, episode.digestID == digestID, episode.entries.indices.contains(index) else { return }
        change(&episode.entries[index])
        self.episode = episode
        store.save(episode)
        if player.playlist?.id == episode.digestID.uuidString {
            player.update(playlist(for: episode))
        }
    }

    // MARK: Playing

    func playlist(for episode: PodcastEpisode) -> PodcastPlaylist {
        PodcastPlaylist(
            id: episode.digestID.uuidString,
            title: episode.title,
            items: episode.entries.map { entry in
                PodcastPlaylist.Item(
                    id: entry.id,
                    title: entry.chapter.title,
                    url: entry.isReady ? entry.audioFile.map { store.audioURL($0, digestID: episode.digestID) } : nil,
                    duration: entry.isReady ? entry.duration : nil
                )
            },
            isGrowing: !episode.isComplete
        )
    }

    /// Plays today's episode (from where it was left, or a chapter).
    func playEpisode(chapter: Int? = nil) {
        guard let episode else { return }
        cancelReadAloud()
        player.load(playlist(for: episode), chapter: chapter, autoplay: true)
    }

    /// The episode's chapter at the player's position.
    var currentChapter: PodcastChapter? {
        guard isPlayingEpisode, let episode else { return nil }
        return episode.entries[safeIndex: player.chapterIndex]?.chapter
    }

    // MARK: Ask about this

    /// Pauses the episode, opens the chapter's topic at its post, and
    /// starts a voice session about it; the episode resumes when the
    /// session ends. `open` opens the topic (the Today page's link path).
    func ask(about chapter: PodcastChapter, open: (URL) -> Void) {
        guard let url = app.flatMap({ $0.url(for: chapter) }), let voice else { return }
        player.suspendForVoice()
        open(url)
        voice.onFinished = { [weak self] in self?.voiceFinished() }
        guard !voice.isActive else { return }
        let delay = askPresentationDelay
        Task { @MainActor [weak self, weak voice] in
            try? await Task.sleep(for: delay)
            guard let self, let voice, self.player.isSuspendedForVoice else { return }
            voice.start()
        }
    }

    /// The voice session is over (or never started): the episode goes on.
    func voiceFinished() {
        voice?.onFinished = nil
        Task { @MainActor [weak self] in await self?.player.resumeAfterVoice() }
    }

    /// "Ask about this" is offered: a Google key for voice, and a topic.
    func canAsk(about chapter: PodcastChapter?) -> Bool {
        guard let chapter, let app, app.url(for: chapter) != nil else { return false }
        return app.voiceProvider != nil
    }

    // MARK: Read aloud

    static func readAloudPlaylistID(_ id: String) -> String { "read-aloud:\(id)" }

    func isReadingAloud(_ id: String) -> Bool {
        player.playlist?.id == Self.readAloudPlaylistID(id) && player.isActive
    }

    /// Reads a text with one host (host A's voice): a summary or a digest
    /// card. Tapping again pauses it.
    func readAloud(id: String, title: String, text: String) {
        let playlistID = Self.readAloudPlaylistID(id)
        if player.playlist?.id == playlistID {
            player.toggle()
            return
        }
        guard let app else { return }
        let kind: PodcastEngineKind
        switch engineSelection(interactive: true) {
        case .needsConsent(let provider):
            pending = .read(id: id, title: title, text: text)
            consentProvider = provider
            return
        case .engine(let selected):
            kind = selected
        }
        let chunks = Self.readAloudChunks(PodcastSpeechCheck.speakable(text))
        guard !chunks.isEmpty else { return }
        cancelReadAloud()
        readAloudID = id
        var playlist = PodcastPlaylist(
            id: playlistID,
            title: title,
            items: chunks.indices.map { PodcastPlaylist.Item(id: "\($0)", title: title) },
            isGrowing: true
        )
        player.load(playlist, chapter: 0, autoplay: true)
        let voices = PodcastVoices(a: app.settings.podcast.voiceA, b: app.settings.podcast.voiceA)
        let engine = engine(kind, voices: voices, language: AppLanguage.current)
        let folder = store.readAloudDirectory
        let key = Self.cacheKey("\(kind.rawValue)|\(voices.a)|\(text)")
        readTask = Task { @MainActor [weak self] in
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for (index, chunk) in chunks.enumerated() {
                guard let self, !Task.isCancelled else { return }
                let url = folder.appendingPathComponent("\(key)-\(index).\(engine.fileExtension)")
                do {
                    // Read before: the file is reused (no second request).
                    var duration = Self.cachedDuration(url) ?? 0
                    if duration == 0 {
                        duration = try await engine.synthesize([PodcastTurn(speaker: .a, text: chunk)], to: url)
                    }
                    guard !Task.isCancelled else { return }
                    playlist.items[index].url = url
                    playlist.items[index].duration = duration
                } catch {
                    guard !Task.isCancelled else { return }
                    try? FileManager.default.removeItem(at: url)
                    self.lastError = error.localizedDescription
                    // Nothing half-loaded stays: the next tap tries again.
                    self.player.unload(forgettingPosition: true)
                    self.readAloudID = nil
                    self.readTask = nil
                    return
                }
                playlist.isGrowing = index < chunks.count - 1
                self.player.update(playlist)
            }
        }
    }

    func cancelReadAloud() {
        readTask?.cancel()
        readTask = nil
        readAloudID = nil
    }

    /// Pieces of about `limit` characters, cut at sentence ends, so the
    /// first can play while the rest is made.
    static func readAloudChunks(_ text: String, limit: Int = 1_200) -> [String] {
        var chunks: [String] = []
        var current = ""
        text.enumerateSubstrings(in: text.startIndex..., options: .bySentences) { sentence, _, _, _ in
            guard let sentence = sentence?.trimmingCharacters(in: .whitespacesAndNewlines), !sentence.isEmpty else { return }
            if !current.isEmpty, current.count + sentence.count > limit {
                chunks.append(current)
                current = ""
            }
            current += current.isEmpty ? sentence : " " + sentence
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    /// The duration of a read-aloud file made earlier, if it is there.
    private static func cachedDuration(_ url: URL) -> TimeInterval? {
        guard FileManager.default.fileExists(atPath: url.path),
              let file = try? AVAudioFile(forReading: url), file.length > 0
        else {
            return nil
        }
        return Double(file.length) / file.processingFormat.sampleRate
    }

    private static func cacheKey(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01b3
        }
        return String(hash, radix: 16)
    }

    // MARK: Storage

    /// Deletes episodes whose digest is gone or older than 7 days, and stops
    /// playing one that was deleted.
    func reconcile() {
        guard let app else { return }
        let deleted = store.reconcile(keeping: Set(app.digests.map(\.id)))
        forget(deleted)
    }

    /// A forum's cards were removed: the episodes that talked about them go.
    func deleteEpisodes(_ digestIDs: [UUID]) {
        digestIDs.forEach(store.delete)
        forget(digestIDs)
    }

    /// Delete All Digests.
    func deleteAll() {
        let ids = episode.map { [$0.digestID] } ?? []
        store.deleteAll()
        forget(ids)
        if let id = player.playlist?.id, UUID(uuidString: id) != nil { player.unload(forgettingPosition: true) }
    }

    private func forget(_ digestIDs: [UUID]) {
        guard !digestIDs.isEmpty else { return }
        let ids = Set(digestIDs)
        if let playing = player.playlist.flatMap({ UUID(uuidString: $0.id) }), ids.contains(playing) {
            player.unload(forgettingPosition: true)
        }
        if let episode, ids.contains(episode.digestID) {
            if task != nil {
                task?.cancel()
                task = nil
                runID = nil
                activity = .idle
            }
            self.episode = nil
        }
    }
}

extension VoiceController: PodcastVoiceStarting {}

private extension Array {
    subscript(safeIndex index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
