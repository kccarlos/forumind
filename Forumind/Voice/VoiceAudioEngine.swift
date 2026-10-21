import AVFoundation
import Combine
import Foundation

/// The microphone and the speaker of a voice session (`VoiceAudioIO`).
///
/// Capture: an `AVAudioEngine` input tap at the hardware format, copied on
/// the render thread and converted on the main actor: `PCMConverter` (16 kHz
/// mono PCM16) → `FrameChunker` (40 ms frames) → `CaptureGate` (the
/// voice-activity detector) → the session. A `MicSignalWatchdog` notices a
/// microphone that delivers only digital zero.
///
/// Playback: one `AVAudioPlayerNode` fed the model's 24 kHz chunks back to
/// back through `PlaybackQueue` (gapless, with an adaptive jitter buffer),
/// then an `AVAudioUnitTimePitch` (pitch 0) whose rate the queue steers
/// every 20 ms, then the main mixer.
///
/// Echo cancellation: the session is `.playAndRecord` / `.voiceChat`, and
/// voice processing is turned on on the input node before the engine
/// starts. That makes the engine's I/O one voice-processing unit, so the
/// output the player feeds is the canceller's reference. Losing either
/// (a route change, another audio client) makes the model hear itself, so
/// both are restored on every rebuild.
@MainActor
final class VoiceAudioEngine: ObservableObject, VoiceAudioIO {
    enum Failure: LocalizedError {
        case microphoneDenied
        case session(String)
        case engine(String)
        case noMicrophone

        var errorDescription: String? {
            switch self {
            case .microphoneDenied:
                String(localized: "Forumind needs the microphone to hear you. Turn it on in Settings › Privacy & Security › Microphone.", comment: "Voice error. The path names the iOS Settings app's pages.")
            case .session(let reason):
                String(localized: "iOS wouldn't start the audio (\(reason)).", comment: "Voice error; the placeholder is the system's reason, in English")
            case .engine(let reason):
                String(localized: "The audio engine wouldn't start (\(reason)).", comment: "Voice error; the placeholder is the system's reason, in English")
            case .noMicrophone:
                String(localized: "No microphone is available right now. Check that no other app is using it.", comment: "Voice error")
            }
        }
    }

    /// Updated about twice a second while running.
    @Published private(set) var health = VoiceAudioHealth()
    /// The last thing worth telling the user (an interruption, a route).
    @Published private(set) var notice: String?
    /// iOS paused the audio and didn't offer to resume: `resume()`.
    @Published private(set) var needsResume = false
    /// Capture stopped and couldn't be rebuilt (a route change took the
    /// microphone away). The session ends.
    var onStopped: ((String) -> Void)?

    private(set) var isRunning = false
    private var isMuted = false
    private var interrupted = false

    private var engine = AVAudioEngine()
    private var player = AVAudioPlayerNode()
    private var timePitch = AVAudioUnitTimePitch()
    private let playbackFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: VoiceAudioFormat.playbackRate, channels: 1, interleaved: false
    )!

    private var converter: PCMConverter?
    private var chunker = FrameChunker()
    private var gate = CaptureGate()
    private var watchdog = MicSignalWatchdog()
    private var queue = PlaybackQueue(profile: .gemini)
    private var hold = SpeakingHold()
    private var speaking = false
    private var restartedForSignal = false

    private var onFrame: (@MainActor (Data) -> Void)?
    private var onGate: (@MainActor (Bool) -> Void)?
    /// What the session was last told about the gate (it starts closed).
    private var reportedGateOpen = false

    private var steerTimer: Timer?
    private static let steerInterval: TimeInterval = 0.02
    private var lastHealthAt: TimeInterval = 0
    private var observers: [NSObjectProtocol] = []

    init() {}

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    // MARK: VoiceAudioIO

    func start(frame: @escaping @MainActor (Data) -> Void, gate: @escaping @MainActor (Bool) -> Void) async throws {
        guard !isRunning else { return }
        onFrame = frame
        onGate = gate
        guard await Self.requestMicrophone() else { throw Failure.microphoneDenied }
        if observers.isEmpty { observe() }
        try configureSession()
        try startEngine()
        isRunning = true
        interrupted = false
        setNeedsResume(false)
        startSteering()
        watchdog.arm(at: Self.now)
        restartedForSignal = false
        refreshHealth(force: true)
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        stopSteering()
        engine.inputNode.removeTap(onBus: 0)
        player.stop()
        engine.stop()
        queue.flush()
        hold.reset()
        speaking = false
        applyRate(1)
        chunker.reset()
        gate.reset()
        converter?.reset()
        watchdog.disarm()
        interrupted = false
        setNeedsResume(false)
        reportGate(open: false)
        onFrame = nil
        onGate = nil
        refreshHealth(force: true)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func play(_ pcm: Data) {
        let samples = [Int16](pcm16LE: pcm)
        guard !samples.isEmpty else { return }
        schedule(queue.push(samples, now: Self.now))
        updateSpeaking()
    }

    func flushPlayback() {
        if queue.flush() {
            player.stop()
            if isRunning, !interrupted { player.play() }
        }
        hold.reset()
        speaking = false
        applyRate(1)
    }

    /// Model audio is buffered, playing, or just paused between chunks.
    var isPlaying: Bool { speaking }

    var headphonesConnected: Bool {
        let personal: Set<AVAudioSession.Port> = [.headphones, .bluetoothA2DP, .bluetoothHFP, .bluetoothLE, .carAudio]
        return AVAudioSession.sharedInstance().currentRoute.outputs.contains { personal.contains($0.portType) }
    }

    /// Mute: nothing reaches the session, and the gate starts over on unmute.
    func setMuted(_ muted: Bool) {
        guard muted != isMuted else { return }
        isMuted = muted
        chunker.reset()
        gate.reset()
        reportGate(open: false)
    }

    /// "Tap to resume" after iOS paused the audio.
    func resume() {
        guard isRunning, needsResume else { return }
        do {
            try reactivate()
            notice = nil
        } catch {
            notice = String(localized: "Couldn't resume the audio. Try again, or end the session.", comment: "Voice notice")
        }
    }

    // MARK: Engine

    static func requestMicrophone() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return true
        case .denied: return false
        default: return await AVAudioApplication.requestRecordPermission()
        }
    }

    private func configureSession() throws {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetoothHFP, .allowBluetoothA2DP, .defaultToSpeaker])
            // 40 ms of hardware buffer keeps the tap in step with the frames.
            try session.setPreferredIOBufferDuration(0.04)
            try session.setActive(true, options: [])
        } catch {
            throw Failure.session(error.localizedDescription)
        }
    }

    /// Voice processing on, mutes cleared, the playback graph wired through
    /// the same voice-processing unit, the tap installed, the engine started.
    /// Called with the engine stopped (start and every rebuild).
    private func startEngine() throws {
        // Attach here, not at init: a graph wired against the launch-time
        // session (output only) plays nothing once the session changes.
        if player.engine == nil { engine.attach(player) }
        if timePitch.engine == nil { engine.attach(timePitch) }
        timePitch.pitch = 0
        let input = engine.inputNode
        enableVoiceProcessing()
        // A voice-processing unit has its own input mute, and iOS 17 an
        // app-wide one (the AirPods press-to-mute). Either left on gives
        // digital zero from the tap while the app shows unmuted.
        if input.isVoiceProcessingEnabled, input.isVoiceProcessingInputMuted {
            input.isVoiceProcessingInputMuted = false
        }
        if AVAudioApplication.shared.isInputMuted {
            try? AVAudioApplication.shared.setInputMuted(false)
        }
        connectPlayback()
        engine.mainMixerNode.outputVolume = 1
        let format = input.inputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else { throw Failure.noMicrophone }
        do {
            converter = try PCMConverter(inputFormat: format)
        } catch {
            throw Failure.noMicrophone
        }
        chunker.reset()
        gate.reset()
        reportGate(open: false)
        health.inputSampleRate = format.sampleRate
        // 4,096 frames is a hint; iOS hands over what it likes (hence the
        // chunker).
        input.installTap(onBus: 0, bufferSize: 4_096, format: format) { [weak self] buffer, _ in
            self?.captured(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw Failure.engine(error.localizedDescription)
        }
        player.play()
    }

    /// The echo canceller. `.voiceChat` alone doesn't cancel echo for
    /// AVAudioEngine; the voice-processing I/O unit does, and it must be on
    /// before the engine starts.
    private func enableVoiceProcessing() {
        let input = engine.inputNode
        if !input.isVoiceProcessingEnabled {
            try? input.setVoiceProcessingEnabled(true)
        }
        if input.isVoiceProcessingEnabled, input.isVoiceProcessingBypassed {
            input.isVoiceProcessingBypassed = false
        }
    }

    /// player → time-pitch → main mixer, at the playback format.
    private func connectPlayback() {
        engine.disconnectNodeOutput(player)
        engine.disconnectNodeOutput(timePitch)
        engine.connect(player, to: timePitch, format: playbackFormat)
        engine.connect(timePitch, to: engine.mainMixerNode, format: playbackFormat)
    }

    /// Rebuilds capture after a route or configuration change, restoring
    /// `.voiceChat` and voice processing. `fresh` replaces the engine and
    /// its nodes (after a media-services reset they are invalid).
    private func rebuild(fresh: Bool) {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        queue.flush()
        hold.reset()
        speaking = false
        if fresh {
            engine = AVAudioEngine()
            player = AVAudioPlayerNode()
            timePitch = AVAudioUnitTimePitch()
        }
        let session = AVAudioSession.sharedInstance()
        if fresh || session.mode != .voiceChat || session.category != .playAndRecord {
            try? configureSession()
        }
        do {
            try startEngine()
            if interrupted { engine.pause() }
            refreshHealth(force: true)
        } catch {
            stopSteering()
            let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            stop()
            onStopped?(reason)
        }
    }

    private func reactivate() throws {
        guard isRunning else { return }
        try AVAudioSession.sharedInstance().setActive(true, options: [])
        try engine.start()
        player.play()
        interrupted = false
        setNeedsResume(false)
        watchdog.arm(at: Self.now)
        restartedForSignal = false
    }

    private func setNeedsResume(_ value: Bool) {
        guard value != needsResume else { return }
        needsResume = value
        health.needsResume = value
    }

    // MARK: Capture

    /// On the render thread. The buffer is only valid during the callback,
    /// so it is copied and handed to the main actor, which owns the
    /// converter, the chunker and the gate.
    private nonisolated func captured(_ buffer: AVAudioPCMBuffer) {
        guard let copy = Self.copy(buffer).map(CapturedBuffer.init) else { return }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.process(copy.buffer) }
        }
    }

    private nonisolated static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard buffer.frameLength > 0,
              let out = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength)
        else {
            return nil
        }
        out.frameLength = buffer.frameLength
        let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer.audioBufferList))
        let destination = UnsafeMutableAudioBufferListPointer(out.mutableAudioBufferList)
        for index in 0..<min(source.count, destination.count) {
            guard let from = source[index].mData, let to = destination[index].mData else { continue }
            memcpy(to, from, Int(source[index].mDataByteSize))
            destination[index].mDataByteSize = source[index].mDataByteSize
        }
        return out
    }

    private func process(_ buffer: AVAudioPCMBuffer) {
        guard isRunning, let converter, buffer.format == converter.inputFormat else { return }
        guard let samples = try? converter.convert(buffer), !samples.isEmpty else { return }
        if let change = watchdog.observe(peak: PCMLevel.peak(of: samples), at: Self.now) {
            signalChanged(change)
        }
        guard !isMuted else { return }
        for frame in chunker.push(samples) {
            let out = gate.push(frame)
            // The transition first: the session drops frames while closed.
            if let transition = out.transition { reportGate(open: transition == .opened) }
            for send in out.send { onFrame?(send.pcm16LEData) }
        }
    }

    private func reportGate(open: Bool) {
        guard open != reportedGateOpen else { return }
        reportedGateOpen = open
        onGate?(open)
    }

    private func signalChanged(_ noSignal: Bool) {
        health.noMicrophoneSignal = noSignal
        // One automatic restart per arm: a capture chain that came up silent
        // usually comes back when rebuilt. The flag stays until a real
        // sample arrives.
        guard noSignal, !restartedForSignal else { return }
        restartedForSignal = true
        rebuild(fresh: false)
    }

    // MARK: Playback

    private func schedule(_ chunks: [PlaybackQueue.Chunk]) {
        guard !chunks.isEmpty else { return }
        for chunk in chunks {
            guard let buffer = Self.buffer(chunk.samples, format: playbackFormat) else { continue }
            // No `at:`: each buffer starts where the last one ended.
            player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                Task { @MainActor in
                    self?.queue.completed(chunk.id)
                    self?.updateSpeaking()
                }
            }
        }
        if isRunning, !interrupted, !player.isPlaying { player.play() }
    }

    private static func buffer(_ samples: [Int16], format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData
        else {
            return nil
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        for (index, sample) in samples.enumerated() {
            channel[0][index] = Float(sample) / 32_768
        }
        return buffer
    }

    /// Speaking while the queue buffers or plays, and briefly across a gap.
    private func updateSpeaking() {
        speaking = hold.update(playing: queue.phase != .idle, now: Self.now)
    }

    // MARK: Control loop

    private func startSteering() {
        steerTimer?.invalidate()
        let timer = Timer(timeInterval: Self.steerInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.steer() }
        }
        RunLoop.main.add(timer, forMode: .common)
        steerTimer = timer
    }

    private func stopSteering() {
        steerTimer?.invalidate()
        steerTimer = nil
    }

    /// Every 20 ms: release what's due, move the rate one slew step, watch
    /// the microphone, and refresh the Health row now and then.
    private func steer() {
        let now = Self.now
        schedule(queue.tick(now: now))
        applyRate(queue.steer(now: now))
        updateSpeaking()
        if AudioLifecycle.watchdogShouldRun(running: isRunning, interrupted: interrupted || needsResume),
           let change = watchdog.tick(at: now) {
            signalChanged(change)
        }
        refreshHealth(force: false)
    }

    private func applyRate(_ rate: Double) {
        let value = Float(rate)
        if timePitch.rate != value { timePitch.rate = value }
    }

    private func refreshHealth(force: Bool) {
        let now = Self.now
        guard force || now - lastHealthAt >= 0.5 else { return }
        lastHealthAt = now
        let session = AVAudioSession.sharedInstance()
        var next = health
        next.echoCancellation = VoiceProcessingStatus(
            inputEnabled: engine.inputNode.isVoiceProcessingEnabled,
            outputEnabled: engine.outputNode.isVoiceProcessingEnabled,
            bypassed: engine.inputNode.isVoiceProcessingBypassed,
            voiceChatMode: session.mode == .voiceChat && session.category == .playAndRecord,
            outputRoute: session.currentRoute.outputs.map(\.portName).joined(separator: ", "),
            inputRoute: session.currentRoute.inputs.map(\.portName).joined(separator: ", ")
        )
        next.underruns = queue.underruns
        next.bufferTargetMilliseconds = queue.targetMilliseconds
        next.noMicrophoneSignal = watchdog.noSignal
        next.gate = gate.diagnostics
        next.needsResume = needsResume
        if next != health { health = next }
    }

    private static var now: TimeInterval { CFAbsoluteTimeGetCurrent() }

    // MARK: Interruptions and routes

    private func observe() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated { self?.interruption(note) }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated { self?.routeChanged(note) }
        })
        // The engine stops itself when the hardware format changes under it.
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, (note.object as? AVAudioEngine) === self.engine else { return }
                self.rebuild(fresh: false)
            }
        })
        // The engine and its nodes are invalid after a media-services reset.
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuild(fresh: true) }
        })
    }

    private func interruption(_ note: Notification) {
        guard isRunning,
              let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw)
        else {
            return
        }
        switch type {
        case .began:
            interrupted = true
            engine.pause()
            flushPlayback()
            // Nothing arrives while iOS holds the audio: not a broken mic.
            watchdog.disarm()
            reportGate(open: false)
            notice = String(localized: "Paused for a call or Siri.", comment: "Voice notice: iOS interrupted the audio")
        case .ended:
            let options = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt).map(AVAudioSession.InterruptionOptions.init)
            guard options?.contains(.shouldResume) ?? false else {
                setNeedsResume(true)
                notice = String(localized: "iOS kept the audio for something else. Tap to resume.", comment: "Voice notice: after a call or Siri, iOS didn't give the audio back")
                return
            }
            do {
                try reactivate()
                notice = nil
            } catch {
                setNeedsResume(true)
                notice = String(localized: "iOS kept the audio for something else. Tap to resume.", comment: "Voice notice: after a call or Siri, iOS didn't give the audio back")
            }
        @unknown default:
            break
        }
    }

    private func routeChanged(_ note: Notification) {
        guard isRunning,
              let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: raw)
        else {
            return
        }
        switch reason {
        case .oldDeviceUnavailable, .newDeviceAvailable, .override, .categoryChange:
            // Headphones in or out: the hardware format can change under the
            // tap, and a category change can leave `.voiceChat`.
            rebuild(fresh: false)
            if let output = AVAudioSession.sharedInstance().currentRoute.outputs.first?.portName {
                notice = String(localized: "Audio moved to \(output).", comment: "Voice notice; the placeholder is an audio output such as Speaker or AirPods")
            }
        default:
            break
        }
    }
}

/// A copied tap buffer on its way to the main actor; nothing else holds it.
private struct CapturedBuffer: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
}
