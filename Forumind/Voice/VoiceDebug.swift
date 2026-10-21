import Foundation

/// Developer switches for voice.
enum VoiceDebug {
    private static let textInputKey = "voice.debug.textInput"

    /// "Type instead of speak" in the voice bar: typed turns go to the
    /// model as `realtimeInput.text`, so tool routing can be checked without
    /// talking. Always on in DEBUG builds; elsewhere behind the hidden
    /// developer switch in Settings › Help › About (per device).
    static var showsTextInput: Bool {
        #if DEBUG
        true
        #else
        UserDefaults.standard.bool(forKey: textInputKey)
        #endif
    }

    static var textInputSwitch: Bool {
        get { UserDefaults.standard.bool(forKey: textInputKey) }
        set { UserDefaults.standard.set(newValue, forKey: textInputKey) }
    }

    /// `-dc-voice-fake`: a scripted session with no network, microphone or
    /// key (UI tests and screenshots). Voice consent starts cleared.
    static var isFake: Bool {
        #if DEBUG
        AssistantDebug.has("-dc-voice-fake")
        #else
        false
        #endif
    }
}

#if DEBUG
/// A Gemini Live server in a box: answers the setup, greets, and echoes
/// typed text back as a model transcript. Nothing leaves the device.
@MainActor
final class ScriptedLiveTransport: LiveTransport {
    let frames: AsyncStream<Data>
    private var continuation: AsyncStream<Data>.Continuation?
    private(set) var closeReason: LiveClose?

    init() {
        var continuation: AsyncStream<Data>.Continuation?
        frames = AsyncStream { continuation = $0 }
        self.continuation = continuation
    }

    func connect(_ request: URLRequest) async throws {}

    func send(_ text: String) {
        let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
        if object["setup"] != nil {
            deliver(#"{"setupComplete":{}}"#, after: .milliseconds(300))
            reply("Hi. I'm listening.", after: .milliseconds(700))
        } else if let typed = (object["realtimeInput"] as? [String: Any])?["text"] as? String {
            reply("You typed: \(typed)", after: .milliseconds(300))
        }
    }

    func close() {
        guard closeReason == nil else { return }
        closeReason = LiveClose(code: LiveClose.normalClosure, reason: "closed")
        continuation?.finish()
        continuation = nil
    }

    private func reply(_ text: String, after delay: Duration) {
        let escaped = text.replacingOccurrences(of: "\"", with: "\\\"")
        deliver(#"{"serverContent":{"outputTranscription":{"text":"\#(escaped)"}}}"#, after: delay)
        deliver(#"{"serverContent":{"turnComplete":true}}"#, after: delay + .milliseconds(200))
    }

    private func deliver(_ json: String, after delay: Duration) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            self?.continuation?.yield(Data(json.utf8))
        }
    }
}

/// Audio that captures nothing and plays nothing.
@MainActor
final class SilentVoiceAudio: VoiceAudioIO {
    var isPlaying: Bool { false }
    var headphonesConnected: Bool { false }
    func start(frame: @escaping @MainActor (Data) -> Void, gate: @escaping @MainActor (Bool) -> Void) async throws {}
    func stop() {}
    func play(_ pcm: Data) {}
    func flushPlayback() {}
}
#endif
