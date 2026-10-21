import Combine
import Foundation

// The live voice session (plan B5): one Gemini Live conversation over a
// `LiveTransport`, with the audio behind `VoiceAudioIO` (plan B6, not built
// yet) and the tools in `VoiceToolBridge`.
//
//   idle → connecting → listening ⇄ thinking ⇄ speaking → ended
//                ↘ failed           ↘ reconnecting ↗
//
// Field lessons it encodes (from field notes of earlier Gemini Live apps):
//
// - A function response is held until the `turnComplete` that follows its
//   call (at most 1.5 s); answered sooner, the model says the function is
//   not available.
// - INTERRUPT is downgraded to WHEN_IDLE while the model speaks or playback
//   still has queued audio (Gemini generates about 4× faster than real time).
// - Briefings (updates that answer no call) are function responses under a
//   made-up id and the name `briefing`.
// - Silent notes (`clientContent`, `turnComplete:false`) go out only while
//   the user and the model are both quiet, and the whole context again after
//   every reconnect: what was sent after the last resumption handle is lost.
// - Mute sends nothing; when the capture gate closes, about 1 s of comfort
//   noise at real-time pace, then `audioStreamEnd`.
// - AI Studio allows one connection per session (close before resume) and
//   ends sessions at 60 minutes, so a session is refreshed fresh at about
//   54. On Vertex a session resumed from a resumed session loses what it
//   inherited, so a resumed connection's handles are never used: the next
//   reconnect opens a fresh session seeded with the context.
// - A turn that gets no server message for 10 s is a stall: the connection
//   is recycled with the handle.
// - Watchdogs: a research call the model didn't acknowledge within 1.5 s
//   gets a nudge; a result unspoken for 6 s is re-sent as a turn; tool-call
//   markup spoken as text is cut off and corrected.

@MainActor
final class VoiceSession: ObservableObject {
    enum State: Equatable {
        case idle
        case connecting
        case listening
        case thinking
        case speaking
        case reconnecting
        case ended(EndReason)
        case failed(Failure)

        var isActive: Bool {
            switch self {
            case .listening, .thinking, .speaking: true
            default: false
            }
        }

        var isOver: Bool {
            switch self {
            case .ended, .failed: true
            default: false
            }
        }
    }

    enum EndReason: Equatable {
        case user
        /// No speech either way for the idle timeout.
        case idle
        /// The model ended it (`end` tool) after its goodbye.
        case model
    }

    enum Failure: Error, Equatable {
        /// Voice is off on this device (Settings).
        case disabled
        case noConsent
        case noKey
        case noVertexProject
        case microphone
        /// Google refused the setup, the key or the model (close 1007/1008).
        case refused(String)
        /// Reconnecting kept failing.
        case connectionLost

        /// What the voice UI shows.
        var message: String {
            switch self {
            case .disabled:
                String(localized: "Turn on voice in Settings first.", comment: "Voice session error: voice is off on this device")
            case .noConsent:
                String(localized: "Voice needs your permission to send audio to Google first.", comment: "Voice session error: the user hasn't agreed to send audio to the provider yet")
            case .noKey:
                String(localized: "Add a Google Gemini or Vertex AI key in Settings › AI models to use voice.", comment: "Voice session error. Settings › AI models names the app's own Settings pages.")
            case .noVertexProject:
                String(localized: "Voice on Vertex AI needs your Google Cloud project. Add it in the voice settings.", comment: "Voice session error: Vertex AI needs a project ID")
            case .microphone:
                String(localized: "The microphone isn't available.", comment: "Voice session error")
            case .refused(let reason):
                String(localized: "Google refused the voice session: \(reason)", comment: "Voice session error; the placeholder is Google's reason, in English")
            case .connectionLost:
                String(localized: "The voice connection was lost.", comment: "Voice session error")
            }
        }
    }

    struct Configuration {
        var endpoint: GeminiLive.Endpoint
        var apiKey: String
        var model = GeminiLive.model
        var settings = VoiceSettings()
        /// The user agreed to send audio to this provider (the consent gate).
        var hasConsent: Bool
    }

    /// Timers, as named constants so tests and tuning see them.
    struct Timing {
        var toolResponseHold: TimeInterval = 1.5
        var acknowledgementGrace: TimeInterval = 1.5
        var unspokenGrace: TimeInterval = 6
        var stallAfter: TimeInterval = 10
        /// AI Studio ends a session 60 minutes after it opened.
        var aiStudioMaxAge: TimeInterval = 54 * 60
        var dwell: TimeInterval = 2
        /// After `end`, the goodbye's turn and playback get this long.
        var goodbyeLimit: TimeInterval = 8
        /// Reconnect attempts in a row before the session fails.
        var reconnectAttempts = 3
        var tickInterval: Duration = .milliseconds(100)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var isMuted = false
    /// The live transcript lines (the voice bar shows the last one).
    @Published private(set) var lastUserText = ""
    @Published private(set) var lastModelText = ""
    /// Seconds connected in this session.
    @Published private(set) var connectedSeconds: Double = 0

    let configuration: Configuration
    var timing = Timing()
    private let makeTransport: LiveTransportFactory
    private let audio: VoiceAudioIO
    let tools: VoiceToolBridge
    private weak var navigator: VoiceNavigator?
    private let clock: VoiceClock
    private let usage: VoiceUsageStore?
    /// Runs the tick loop and the audio; tests drive `tick()` themselves.
    private let runsLoop: Bool

    private(set) var context = VoiceContext()
    private var transport: LiveTransport?
    private var connectionSerial = 0
    private var setupDone = false
    /// 0 for a fresh session's connection, n + 1 when resumed from a
    /// generation-n handle.
    private(set) var connectionGeneration = 0
    private(set) var resumptionHandle: String?
    /// When the current model session was opened fresh (AI Studio's limit).
    private(set) var freshAt: Date?
    private var reconnectFailures = 0
    private var isReconnecting = false
    private var pendingReconnect: (reason: ReconnectReason, deadline: Date)?

    // Turn state.
    private var modelSpeaking = false
    private var lastModelOutputAt: Date?
    private var turnCompleteCount = 0
    private var gateOpen = false
    private var sentAudioThisTurn = false
    private var lastUserSpeechAt: Date?
    /// The server transcribed words in the current user turn: a reply is
    /// owed once it ends (noise that opened the gate owes none).
    private var heardThisTurn = false
    private var awaitingReplySince: Date?
    private var lastServerMessageAt: Date?
    private var lastActivityAt: Date?
    private var modelTurnText = ""

    // Outgoing.
    private struct PendingResponse {
        var id: String
        var name: String
        var serial: Int
        var calledAt: Date
        var turnAtCall: Int
        var outcome: VoiceToolOutcome?
    }
    private var pendingResponses: [PendingResponse] = []
    private var noteQueue: [String] = []
    private var briefingQueue: [VoiceBriefing] = []
    private var briefingSequence = 0
    private var comfortNoise: (start: Date, sent: Int)?
    private var noiseSeed: UInt64 = 0x9E37_79B9_7F4A_7C15

    // Watchdogs.
    private var acknowledgementWatch: Date?
    private var unspokenWatch: (since: Date, text: String)?
    private var suppressingModelTurn = false
    private var markupCorrectionDue = false
    private var endRequestedAt: Date?

    // Context.
    private var dwell: (topicKey: String, number: Int, since: Date)?
    private var lastEyesFree: Bool?
    private var usageFlushedAt: Date?
    private var unflushedSeconds: Double = 0
    private var lastUsageTick: Date?
    private var loopTask: Task<Void, Never>?
    private var contextTasks: [Task<Void, Never>] = []

    enum ReconnectReason: Equatable {
        case goAway
        case stalled
        /// A fresh session before AI Studio's 60-minute limit.
        case refresh
        case dropped
        case sessionGone
    }

    init(
        configuration: Configuration,
        transport: @escaping LiveTransportFactory = { WebSocketLiveTransport() },
        audio: VoiceAudioIO,
        navigator: VoiceNavigator?,
        clock: VoiceClock = SystemVoiceClock(),
        usage: VoiceUsageStore? = VoiceUsageStore(),
        runsLoop: Bool = true
    ) {
        self.configuration = configuration
        makeTransport = transport
        self.audio = audio
        self.navigator = navigator
        self.clock = clock
        self.usage = usage
        self.runsLoop = runsLoop
        tools = VoiceToolBridge(navigator: navigator)
        tools.onBriefing = { [weak self] in self?.brief($0) }
    }

    // MARK: Lifecycle

    /// Opens the session (on demand: the first tap). Blocked without the
    /// user's consent for this provider.
    func start() async {
        guard state == .idle else { return }
        guard configuration.hasConsent else {
            state = .failed(.noConsent)
            return
        }
        guard !configuration.apiKey.isEmpty else {
            state = .failed(.noKey)
            return
        }
        state = .connecting
        lastActivityAt = clock.now
        if runsLoop {
            do {
                try await audio.start(
                    frame: { [weak self] in self?.microphoneFrame($0) },
                    gate: { [weak self] in self?.captureGate(open: $0) }
                )
            } catch {
                state = .failed(.microphone)
                return
            }
            loopTask = Task { @MainActor [weak self] in
                while let self, !self.state.isOver, !Task.isCancelled {
                    try? await Task.sleep(for: self.timing.tickInterval)
                    self.tick()
                }
            }
        }
        await connect(handle: nil)
    }

    /// The user ended the session.
    func stop() {
        end(.user)
    }

    private func end(_ reason: EndReason) {
        guard !state.isOver else { return }
        finish(.ended(reason))
    }

    private func fail(_ failure: Failure) {
        guard !state.isOver else { return }
        finish(.failed(failure))
    }

    private func finish(_ final: State) {
        recordUsage()
        flushUsage()
        state = final
        connectionSerial += 1
        transport?.close()
        transport = nil
        tools.stop()
        audio.flushPlayback()
        audio.stop()
        loopTask?.cancel()
        contextTasks.forEach { $0.cancel() }
        contextTasks = []
    }

    func setMuted(_ muted: Bool) {
        guard muted != isMuted else { return }
        isMuted = muted
        guard muted else { return }
        // Mute means send nothing; end the user's turn now if one is open.
        comfortNoise = nil
        if sentAudioThisTurn {
            send(.audioStreamEnd)
            sentAudioThisTurn = false
            if heardThisTurn { awaitingReplySince = clock.now }
        }
    }

    // MARK: Connection

    private func connect(handle: String?) async {
        let transport = makeTransport()
        connectionSerial += 1
        let serial = connectionSerial
        self.transport = transport
        setupDone = false
        let generation = handle == nil ? 0 : connectionGeneration + 1
        do {
            try await transport.connect(configuration.endpoint.request(apiKey: configuration.apiKey))
        } catch {
            guard serial == connectionSerial else { return }
            await connectionEnded(LiveClose(code: nil, reason: error.localizedDescription), serial: serial, handleUsed: handle)
            return
        }
        guard serial == connectionSerial, !state.isOver else {
            transport.close()
            return
        }
        connectionGeneration = generation
        if handle == nil {
            freshAt = clock.now
            resumptionHandle = nil
        }
        send(.setup(setup(handle: handle)))
        let frames = transport.frames
        Task { @MainActor [weak self] in
            for await frame in frames {
                guard let self, serial == self.connectionSerial else { return }
                self.receive(frame)
            }
            guard let self, serial == self.connectionSerial else { return }
            await self.connectionEnded(transport.closeReason ?? LiveClose(code: nil, reason: "Closed"), serial: serial, handleUsed: handle)
        }
    }

    /// The setup for a connection (the whole of it again when resuming).
    func setup(handle: String?) -> GeminiLive.Setup {
        let page = navigator?.pageContext
        return GeminiLive.Setup(
            endpoint: configuration.endpoint,
            model: configuration.model,
            voice: configuration.settings.voiceName,
            instructions: VoiceInstructions.system(
                answerLength: configuration.settings.answerLength,
                eyesFree: eyesFree,
                forumName: page?.forumName
            ),
            functions: VoiceTool.geminiDeclarations,
            vocabulary: Self.vocabulary(page: page),
            resumptionHandle: handle
        )
    }

    /// Custom vocabulary for transcription: the forum's and topic's names.
    static func vocabulary(page: PageContext?) -> [String] {
        guard let page else { return [] }
        var words: [String] = []
        if !page.forumName.isEmpty { words.append(page.forumName) }
        if let title = page.topic?.title, !title.isEmpty {
            words.append(title)
            words += title.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .map(String.init)
                .filter { $0.count >= 4 && $0.first?.isUppercase == true }
        }
        var seen = Set<String>()
        return words.filter { seen.insert($0).inserted }.prefix(20).map { $0 }
    }

    private func connectionEnded(_ close: LiveClose, serial: Int, handleUsed: String?) async {
        guard serial == connectionSerial, !state.isOver else { return }
        transport = nil
        let wasSetUp = setupDone
        setupDone = false
        if endRequestedAt != nil {
            end(.model)
            return
        }
        if close.isRefusal, !wasSetUp, handleUsed == nil {
            fail(.refused(close.reason))
            return
        }
        if close.isSessionGone || (!wasSetUp && handleUsed != nil) {
            // A dead handle: start over (one attempt with it is enough).
            resumptionHandle = nil
        }
        await reconnect(close.isSessionGone ? .sessionGone : .dropped, closing: false)
    }

    /// Opens a new connection: resumed with the handle when the rules allow,
    /// else a fresh session seeded with the current context.
    func reconnect(_ reason: ReconnectReason, closing: Bool = true) async {
        guard !isReconnecting, !state.isOver else { return }
        isReconnecting = true
        defer { isReconnecting = false }
        pendingReconnect = nil
        state = .reconnecting
        recordUsage()
        if closing {
            // Close before resume: AI Studio refuses a second connection.
            connectionSerial += 1
            transport?.close()
            transport = nil
        }
        // Calls of the old connection can't be answered on the new one.
        pendingResponses = []
        resetTurn()
        while !state.isOver {
            reconnectFailures += 1
            guard reconnectFailures <= timing.reconnectAttempts else {
                fail(.connectionLost)
                return
            }
            let handle = handleForReconnect(reason)
            await connect(handle: handle)
            if transport != nil || state.isOver { return }
        }
    }

    /// The handle a reconnect may present, if any.
    func handleForReconnect(_ reason: ReconnectReason) -> String? {
        switch reason {
        case .refresh, .sessionGone: return nil
        case .goAway, .stalled, .dropped: break
        }
        if !configuration.endpoint.isVertex, let freshAt, clock.now.timeIntervalSince(freshAt) >= timing.aiStudioMaxAge {
            return nil
        }
        return resumptionHandle
    }

    private func resetTurn() {
        modelSpeaking = false
        gateOpen = false
        sentAudioThisTurn = false
        heardThisTurn = false
        comfortNoise = nil
        awaitingReplySince = nil
        suppressingModelTurn = false
        modelTurnText = ""
        audio.flushPlayback()
    }

    // MARK: Receiving

    /// One server frame.
    func receive(_ data: Data) {
        guard let message = GeminiLive.decode(data), !state.isOver else { return }
        let now = clock.now
        lastServerMessageAt = now
        if message.setupComplete { setupCompleted() }
        if let update = message.resumption { resumptionUpdated(handle: update.handle, resumable: update.resumable) }
        if let goAway = message.goAway { goAwayReceived(timeLeft: goAway) }
        if message.interrupted {
            audio.flushPlayback()
            modelSpeaking = false
            suppressingModelTurn = false
        }
        if let input = message.inputTranscription { userTranscribed(input.text) }
        if !message.audio.isEmpty, !suppressingModelTurn {
            modelOutput(at: now)
            message.audio.forEach(audio.play)
        }
        if let output = message.outputTranscription { modelTranscribed(output.text, at: now) }
        if !message.toolCalls.isEmpty { message.toolCalls.forEach(toolCalled) }
        if !message.cancelledCalls.isEmpty {
            let cancelled = Set(message.cancelledCalls)
            pendingResponses.removeAll { cancelled.contains($0.id) }
        }
        if message.turnComplete { turnCompleted() }
        updateState()
    }

    private func setupCompleted() {
        guard !setupDone else { return }
        setupDone = true
        reconnectFailures = 0
        lastUsageTick = clock.now
        let first = freshAt != nil && noteQueue.isEmpty && context.briefedTopic == nil
        // Context sent after the last handle is lost: send all of it again.
        noteQueue.insert(contentsOf: context.fullContextNotes(), at: 0)
        if first, let page = navigator?.pageContext { pageChanged(page) }
        state = .listening
        flushBriefings()
        flushNotes()
    }

    private func resumptionUpdated(handle: String?, resumable: Bool) {
        guard resumable, let handle else { return }
        if configuration.endpoint.isVertex, connectionGeneration > 0 {
            // Never resume a resumed session on Vertex: the generation-0
            // handle no longer covers this connection's turns either.
            resumptionHandle = nil
            return
        }
        resumptionHandle = handle
    }

    private func goAwayReceived(timeLeft: TimeInterval) {
        let deadline = clock.now.addingTimeInterval(max(0, timeLeft - 5))
        let pastAge = !configuration.endpoint.isVertex
            && freshAt.map { clock.now.timeIntervalSince($0) >= timing.aiStudioMaxAge } == true
        pendingReconnect = (pastAge ? .refresh : .goAway, deadline)
    }

    private func userTranscribed(_ text: String) {
        let now = clock.now
        lastUserSpeechAt = now
        lastActivityAt = now
        if gateOpen || sentAudioThisTurn || heardThisTurn {
            lastUserText += text
        } else {
            lastUserText = text
        }
        heardThisTurn = true
        // Words transcribed after the stream ended: the reply is owed now.
        if !gateOpen, !sentAudioThisTurn, comfortNoise == nil, awaitingReplySince == nil { awaitingReplySince = now }
        groundIfNeeded(lastUserText)
    }

    private func modelOutput(at now: Date) {
        modelSpeaking = true
        lastModelOutputAt = now
        lastActivityAt = now
        awaitingReplySince = nil
    }

    private func modelTranscribed(_ text: String, at now: Date) {
        guard !suppressingModelTurn else { return }
        modelOutput(at: now)
        modelTurnText += text
        lastModelText = modelTurnText
        if VoiceWatchdog.markupStart(in: modelTurnText) != nil {
            // Tool markup spoken as text: nothing ran. Cut it off.
            audio.flushPlayback()
            suppressingModelTurn = true
            markupCorrectionDue = true
            modelSpeaking = false
            if let start = VoiceWatchdog.markupStart(in: modelTurnText) {
                lastModelText = String(modelTurnText[..<start]).trimmingCharacters(in: .whitespaces)
            }
        }
    }

    private func turnCompleted() {
        turnCompleteCount += 1
        heardThisTurn = false
        modelSpeaking = false
        suppressingModelTurn = false
        awaitingReplySince = nil
        modelTurnText = ""
        if markupCorrectionDue {
            markupCorrectionDue = false
            send(.content(VoiceWatchdog.markupCorrection, turnComplete: true))
            awaitingReplySince = clock.now
        }
        releaseResponses()
    }

    // MARK: Tools

    private func toolCalled(_ call: GeminiLive.FunctionCall) {
        let now = clock.now
        lastActivityAt = now
        awaitingReplySince = nil
        let serial = connectionSerial
        pendingResponses.append(PendingResponse(
            id: call.id, name: call.name, serial: serial, calledAt: now, turnAtCall: turnCompleteCount
        ))
        let eyesFree = eyesFree
        Task { @MainActor [weak self] in
            guard let self else { return }
            let outcome = await self.tools.handle(call, eyesFree: eyesFree)
            guard let index = self.pendingResponses.firstIndex(where: { $0.id == call.id && $0.serial == serial }) else { return }
            self.pendingResponses[index].outcome = outcome
            self.toolFinished(call, outcome: outcome, calledAt: now)
            self.releaseResponses()
            self.updateState()
        }
    }

    private func toolFinished(_ call: GeminiLive.FunctionCall, outcome: VoiceToolOutcome, calledAt: Date) {
        switch outcome.effect {
        case .researchStarted:
            acknowledgementWatch = lastUserSpeechAt.map { min($0, calledAt) } ?? calledAt
        case .end:
            endRequestedAt = clock.now
        case .none:
            break
        }
        // A post whose text the model got with a result needs no grounding.
        if outcome.response["content"] != nil, let topic = navigator?.pageContext.topic,
           let shown = outcome.response["shown"]?.stringValue, let number = Self.postNumber(in: shown) {
            context.noteContentSent(topicKey: topic.topicKey, number: number)
        }
    }

    /// "Post 37 of 120 by alice" → 37.
    static func postNumber(in shown: String) -> Int? {
        guard let range = shown.range(of: #"[Pp]ost (\d+)"#, options: .regularExpression) else { return nil }
        return Int(shown[range].filter(\.isNumber))
    }

    /// Sends the responses that are ready and whose call's turn is over (or
    /// that waited `toolResponseHold`).
    private func releaseResponses() {
        let now = clock.now
        var remaining: [PendingResponse] = []
        for pending in pendingResponses {
            guard pending.serial == connectionSerial else { continue }
            guard setupDone, let outcome = pending.outcome,
                  turnCompleteCount > pending.turnAtCall || now.timeIntervalSince(pending.calledAt) >= timing.toolResponseHold
            else {
                remaining.append(pending)
                continue
            }
            let scheduling = downgraded(outcome.scheduling)
            send(.toolResponse([GeminiLive.FunctionResponse(
                id: pending.id, name: pending.name, response: outcome.response, scheduling: scheduling
            )]))
            if scheduling != .silent { awaitingReplySince = now }
        }
        pendingResponses = remaining
    }

    /// INTERRUPT waits while the model, or its queued playback, is speaking.
    func downgraded(_ scheduling: GeminiLive.Scheduling) -> GeminiLive.Scheduling {
        scheduling == .interrupt && isSpeaking ? .whenIdle : scheduling
    }

    var isSpeaking: Bool { modelSpeaking || audio.isPlaying }

    // MARK: Briefings

    /// Sends a briefing (queued while reconnecting).
    func brief(_ briefing: VoiceBriefing) {
        guard !state.isOver else { return }
        guard setupDone else {
            briefingQueue.append(briefing)
            return
        }
        briefingSequence += 1
        var facts = briefing.facts
        facts["about_this"] = "Not the user speaking: facts from the Forumind app. You decide whether, when and how to tell the user, in your own words."
        facts["kind"] = .string(briefing.kind.rawValue)
        let scheduling = downgraded(briefing.scheduling)
        send(.toolResponse([GeminiLive.FunctionResponse(
            id: "b-\(briefingSequence)", name: VoiceBriefing.name, response: facts, scheduling: scheduling
        )]))
        if scheduling != .silent {
            awaitingReplySince = clock.now
            if let text = briefing.spokenText, !text.isEmpty { unspokenWatch = (clock.now, text) }
        }
        if briefing.kind == .researchAnswer || briefing.kind == .researchEnded { acknowledgementWatch = nil }
    }

    private func flushBriefings() {
        let queued = briefingQueue
        briefingQueue = []
        queued.forEach(brief)
    }

    // MARK: Silent context

    /// The page settled (AppModel.pageChanges): the topic brief when the
    /// topic is new, then the position delta.
    func pageChanged(_ page: PageContext) {
        guard !state.isOver else { return }
        if let topic = page.topic, page.state == .topic {
            if let number = page.currentPost, dwell?.topicKey != topic.topicKey || dwell?.number != number {
                dwell = (topic.topicKey, number, clock.now)
            }
        } else {
            dwell = nil
        }
        let task = Task { @MainActor [weak self] in
            guard let self, let navigator = self.navigator else { return }
            if let topic = page.topic, page.state == .topic, topic.topicKey != self.context.briefedTopic,
               let brief = await navigator.voiceTopicBrief(), brief.topicKey == topic.topicKey {
                if let note = self.context.topicBriefNote(brief) { self.queueNote(note) }
                if brief.summary == nil { self.requestSummary(brief) }
            }
            let visible = await navigator.postsOnScreen()
            if let note = self.context.positionNote(page: navigator.pageContext, visible: visible, cursor: navigator.browseCursor) {
                self.queueNote(note)
            }
        }
        contextTasks.append(task)
        contextTasks.removeAll { $0.isCancelled }
        if contextTasks.count > 8 { contextTasks.removeFirst() }
    }

    private func requestSummary(_ brief: VoiceTopicBrief) {
        let task = Task { @MainActor [weak self] in
            guard let summary = await self?.navigator?.quickSummary(topicKey: brief.topicKey), let self else { return }
            if let note = self.context.summaryNote(summary, topicKey: brief.topicKey, title: brief.title) {
                self.queueNote(note)
            }
        }
        contextTasks.append(task)
    }

    func queueNote(_ note: String) {
        noteQueue.append(note)
        flushNotes()
    }

    /// Both sides are quiet: no speech, no playback, no open user turn, no
    /// reply on its way.
    var isQuiet: Bool {
        !isSpeaking && !gateOpen && comfortNoise == nil && awaitingReplySince == nil
            && pendingResponses.isEmpty && !(lastUserSpeechAt.map { clock.now.timeIntervalSince($0) < 1 } ?? false)
    }

    private func flushNotes() {
        guard setupDone, isQuiet, !noteQueue.isEmpty else { return }
        let text = noteQueue.joined(separator: "\n")
        noteQueue = []
        send(.content(text, turnComplete: false))
    }

    /// The code-level grounding guarantee: words that point at the screen,
    /// and the focused post's full text not sent yet, send it now, before
    /// the model's answer (not waiting for quiet: the model is not speaking).
    private func groundIfNeeded(_ transcript: String) {
        guard configuration.settings.groundsOnScreenReference, VoiceContext.refersToScreen(transcript) else { return }
        sendFocusedPost(urgent: true)
    }

    private func sendFocusedPost(urgent: Bool) {
        guard let navigator, let topic = navigator.pageContext.topic, navigator.pageContext.state == .topic,
              let number = navigator.pageContext.currentPost,
              !context.hasFullText(topicKey: topic.topicKey, number: number)
        else {
            return
        }
        // Marked now, so a second reference before the read returns waits.
        context.noteContentSent(topicKey: topic.topicKey, number: number)
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await navigator.read(post: number)
            guard let note = self.context.fullTextNote(result, topicKey: topic.topicKey, number: number) else {
                // Not readable now: a later reference tries again.
                self.context.forgetFullText(topicKey: topic.topicKey, number: number)
                return
            }
            if urgent, self.setupDone, !self.isSpeaking {
                self.send(.content(note, turnComplete: false))
            } else {
                self.queueNote(note)
            }
        }
        contextTasks.append(task)
    }

    private var eyesFree: Bool {
        configuration.settings.eyesFree.isActive(headphones: audio.headphonesConnected)
    }

    // MARK: Audio in

    func microphoneFrame(_ pcm: Data) {
        guard !isMuted, gateOpen, setupDone, state.isActive else { return }
        sentAudioThisTurn = true
        lastActivityAt = clock.now
        send(.audio(pcm))
    }

    func captureGate(open: Bool) {
        guard open != gateOpen else { return }
        gateOpen = open
        let now = clock.now
        if open {
            comfortNoise = nil
            lastActivityAt = now
            lastUserSpeechAt = now
            if !sentAudioThisTurn {
                lastUserText = ""
                heardThisTurn = false
            }
        } else if sentAudioThisTurn, !isMuted {
            comfortNoise = (now, 0)
        }
        updateState()
    }

    /// Comfort-noise frames due by now, then `audioStreamEnd`.
    private func sendComfortNoise(now: Date) {
        guard let noise = comfortNoise, setupDone else { return }
        let total = Int(ComfortNoise.duration / ComfortNoise.frameDuration)
        let due = min(total, Int(now.timeIntervalSince(noise.start) / ComfortNoise.frameDuration) + 1)
        var sent = noise.sent
        while sent < due {
            send(.audio(ComfortNoise.frame(seed: &noiseSeed)))
            sent += 1
        }
        if sent >= total {
            comfortNoise = nil
            send(.audioStreamEnd)
            sentAudioThisTurn = false
            if heardThisTurn { awaitingReplySince = now }
        } else {
            comfortNoise = (noise.start, sent)
        }
    }

    // MARK: Timers

    /// Runs every 100 ms (tests call it with a manual clock).
    func tick() {
        guard !state.isOver else { return }
        let now = clock.now
        recordUsage()
        sendComfortNoise(now: now)
        releaseResponses()
        guard setupDone, !isReconnecting else { return }

        if eyesFree != lastEyesFree {
            if lastEyesFree != nil {
                queueNote(eyesFree
                    ? "[Forumind: the user can't look at the screen now; you may read posts out briefly.]"
                    : "[Forumind: the user can see the screen again; point at it instead of reading posts out.]")
            }
            lastEyesFree = eyesFree
        }

        // The goodbye has played: end.
        if let endAt = endRequestedAt,
           (!isSpeaking && pendingResponses.isEmpty && now.timeIntervalSince(endAt) >= 0.5) || now.timeIntervalSince(endAt) >= timing.goodbyeLimit {
            end(.model)
            return
        }

        // Watchdog: research started, the model said nothing.
        if let since = acknowledgementWatch, now.timeIntervalSince(since) >= timing.acknowledgementGrace {
            if let spoke = lastModelOutputAt, spoke >= since {
                acknowledgementWatch = nil
            } else if !isSpeaking, !gateOpen {
                acknowledgementWatch = nil
                send(.content(VoiceWatchdog.acknowledgementPrompt, turnComplete: true))
                awaitingReplySince = now
            }
        }
        // Watchdog: a result the model hasn't voiced.
        if let watch = unspokenWatch {
            if let spoke = lastModelOutputAt, spoke > watch.since {
                unspokenWatch = nil
            } else if now.timeIntervalSince(watch.since) >= timing.unspokenGrace, !isSpeaking, !gateOpen {
                unspokenWatch = nil
                send(.content(VoiceWatchdog.unspokenPrompt(watch.text), turnComplete: true))
                awaitingReplySince = now
            }
        }

        // Stall: a reply is owed and the server has gone quiet.
        if let since = awaitingReplySince {
            let lastHeard = max(since, lastServerMessageAt ?? since)
            if now.timeIntervalSince(lastHeard) >= timing.stallAfter {
                Task { await reconnect(.stalled) }
                return
            }
        }

        // GoAway or AI Studio's age: reconnect at a quiet moment (or the deadline).
        if let pending = pendingReconnect, isQuiet || now >= pending.deadline {
            Task { await reconnect(pending.reason) }
            return
        }
        if !configuration.endpoint.isVertex, let freshAt, now.timeIntervalSince(freshAt) >= timing.aiStudioMaxAge, isQuiet,
           navigator?.isResearching != true {
            Task { await reconnect(.refresh) }
            return
        }

        // Dwell: the reader stopped on a post.
        if configuration.settings.groundsOnDwell, let dwell, now.timeIntervalSince(dwell.since) >= timing.dwell,
           navigator?.pageContext.topic?.topicKey == dwell.topicKey, navigator?.pageContext.currentPost == dwell.number {
            self.dwell = nil
            sendFocusedPost(urgent: false)
        }

        flushNotes()

        // Idle: nobody spoke for the timeout.
        if let last = lastActivityAt, now.timeIntervalSince(last) >= configuration.settings.idleTimeout, isQuiet,
           navigator?.isResearching != true {
            end(.idle)
            return
        }
        updateState()
    }

    private func updateState() {
        guard setupDone, !state.isOver, !isReconnecting else { return }
        if isSpeaking {
            state = .speaking
        } else if awaitingReplySince != nil || pendingResponses.contains(where: { $0.outcome == nil }) {
            state = .thinking
        } else {
            state = .listening
        }
    }

    // MARK: Usage

    private func recordUsage() {
        let now = clock.now
        defer { lastUsageTick = setupDone ? now : nil }
        guard setupDone, let last = lastUsageTick else { return }
        let delta = min(5, max(0, now.timeIntervalSince(last)))
        connectedSeconds += delta
        unflushedSeconds += delta
        if usageFlushedAt.map({ now.timeIntervalSince($0) >= 10 }) ?? true { flushUsage() }
    }

    private func flushUsage() {
        guard unflushedSeconds > 0 else { return }
        usage?.add(seconds: unflushedSeconds, at: clock.now, sessionTotal: connectedSeconds)
        unflushedSeconds = 0
        usageFlushedAt = clock.now
    }

    // MARK: Sending

    private func send(_ message: GeminiLive.ClientMessage) {
        guard let transport, let text = try? GeminiLive.encode(message) else { return }
        transport.send(text)
    }
}

/// The watchdogs' texts and the tool-markup check. Written for the
/// model, so English and not localized.
enum VoiceWatchdog {
    /// Markup a model sometimes speaks instead of calling a tool.
    static let markers = ["<tool_call", "</tool_call", "<function_call", "<|tool", "<tool_code", "```tool", "print(default_api"]

    static func markupStart(in text: String) -> String.Index? {
        markers.compactMap { text.range(of: $0, options: .caseInsensitive)?.lowerBound }.min()
    }

    static let markupCorrection = "[Forumind: your last reply spoke a tool call out loud as text instead of making it, so nothing ran and the page stayed where it was. Forumind stopped that reply. Don't say tool names, calls or arguments aloud. If you wanted a tool, make the function call now, silently, and don't tell the user it's done until its result arrives. If you only meant to talk, continue normally.]"

    static let acknowledgementPrompt = "[Forumind: research for the user's question is running and you haven't said anything yet. Let the user know in a few words of your own that you're looking into it. Don't call research again.]"

    static func unspokenPrompt(_ text: String) -> String {
        "[Forumind: you haven't told the user the research answer yet. Tell them now in about two sentences, and say the sources are on screen: \(BrowseText.trimmed(text, limit: 1_500))]"
    }
}
