import Combine
import Foundation

/// Starts and ends voice sessions for the UI: the browser bar's microphone,
/// the consent sheet (once per provider) and the voice bar. AppModel owns
/// one; the session itself is in `VoiceSession`.
@MainActor
final class VoiceController: ObservableObject {
    /// The running session, or the last one while its bar still shows
    /// how it ended.
    @Published private(set) var session: VoiceSession?
    /// Asks the user to agree before the first session with this provider.
    @Published var consentProvider: VoiceProvider?
    /// Why a session couldn't start (no key, voice off), shown in the bar.
    @Published private(set) var startFailure: VoiceSession.Failure?

    private weak var app: AppModel?
    /// The device's audio; made on the first session (it asks for the
    /// microphone then, not at launch).
    private var engine: VoiceAudioIO?
    private var stateSubscription: AnyCancellable?

    init(app: AppModel) {
        self.app = app
    }

    /// The bar is up: a session, or a failure to show.
    var showsBar: Bool { session != nil || startFailure != nil }

    var isActive: Bool { session.map { !$0.state.isOver } ?? false }

    /// The audio engine, when it is the real one (for the Health row).
    var audioEngine: VoiceAudioEngine? { engine as? VoiceAudioEngine }

    // MARK: Actions

    /// The microphone in the browser bar: start, or end a running session.
    func toggle() {
        if isActive {
            session?.stop()
        } else {
            start()
        }
    }

    func start() {
        guard let app, !isActive else { return }
        startFailure = nil
        guard let provider = app.voiceProvider else {
            show(.noKey)
            return
        }
        guard VoiceConsent.isGranted(provider, in: app.settings) else {
            consentProvider = provider
            return
        }
        // Tapping the microphone is asking for voice.
        if !app.settings.voiceEnabled { app.settings.voiceEnabled = true }
        let audio = makeAudio()
        let result: Result<VoiceSession, VoiceSession.Failure>
        #if DEBUG
        if VoiceDebug.isFake {
            result = app.makeVoiceSession(audio: audio, transport: { ScriptedLiveTransport() })
        } else {
            result = app.makeVoiceSession(audio: audio)
        }
        #else
        result = app.makeVoiceSession(audio: audio)
        #endif
        switch result {
        case .failure(let failure):
            show(failure)
        case .success(let session):
            self.session = session
            stateSubscription = session.$state.sink { [weak self] state in
                if state.isOver { self?.sessionEnded() }
            }
            audioEngine?.onStopped = { [weak session] _ in session?.audioFailed() }
            Task { await session.start() }
        }
    }

    /// The consent sheet's Agree.
    func agree(_ provider: VoiceProvider) {
        guard let app else { return }
        app.grantVoiceConsent(provider)
        app.settings.voiceEnabled = true
        consentProvider = nil
        start()
    }

    func declineConsent() {
        consentProvider = nil
    }

    func end() {
        session?.stop()
    }

    /// Closes the bar of a session that is over.
    func dismiss() {
        guard !isActive else { return }
        session = nil
        startFailure = nil
        stateSubscription = nil
    }

    // MARK: Private

    private func makeAudio() -> VoiceAudioIO {
        if let engine { return engine }
        let audio: VoiceAudioIO
        #if DEBUG
        audio = VoiceDebug.isFake ? SilentVoiceAudio() : VoiceAudioEngine()
        #else
        audio = VoiceAudioEngine()
        #endif
        engine = audio
        return audio
    }

    private func show(_ failure: VoiceSession.Failure) {
        session = nil
        startFailure = failure
    }

    private func sessionEnded() {
        app?.voiceSessionEnded()
    }
}
