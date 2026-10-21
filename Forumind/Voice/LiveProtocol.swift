import Foundation

// The Gemini Live wire format (BidiGenerateContent over a WebSocket, JSON
// text frames), for AI Studio and Vertex AI express. Pure encode and decode,
// no socket and no audio, so every message shape is unit-tested.
//
// Field facts come from the Live API docs (ai.google.dev, checked
// 2026-10-20) and from field notes of a voice app that ran this protocol
// for weeks:
//
// - `gemini-3.8-live` accepts only the AUDIO response modality (TEXT closes
//   the socket with 1007); the text side comes from the transcriptions.
// - Native-audio models pick the language themselves: no language code.
// - A function response's `scheduling` is documented inside `response`; the
//   API's FunctionResponse also has it as a sibling field. Both were seen to
//   work, so both are sent.
// - Compression token counts are int64, which proto JSON writes as strings.
// - The server sends `{}` and `{"serverContent":{}}` keep-alives while it
//   generates; they decode to an empty message and are ignored.
// - `goAway.timeLeft` is a proto Duration: "10s" (or {seconds, nanos}).

// Tool arguments, tool results and parameter schemas use `JSONValue`
// (SyncRecords.swift), with these conveniences.
extension JSONValue {
    /// A string, or a number or bool written as one (models send "37" and 37 alike).
    var textValue: String? {
        switch self {
        case .string(let value): value
        case .int(let value): String(value)
        case .double(let value): value.rounded() == value ? String(Int64(value)) : String(value)
        case .bool(let value): value ? "true" : "false"
        default: nil
        }
    }

    /// A whole number, also from a numeric string ("37").
    var intValue: Int? {
        switch self {
        case .int(let value): Int(value)
        case .double(let value): value.rounded() == value ? Int(value) : nil
        case .string(let value): Int(value.trimmingCharacters(in: .whitespaces))
        default: nil
        }
    }

    var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    init(stringLiteral value: String) { self = .string(value) }
    init(booleanLiteral value: Bool) { self = .bool(value) }
    init(integerLiteral value: Int) { self = .int(Int64(value)) }
    init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}

enum GeminiLive {
    static let model = "gemini-3.8-live"
    static let inputSampleRate = Int(VoiceAudioFormat.captureRate)
    static let outputSampleRate = Int(VoiceAudioFormat.playbackRate)
    static let inputMimeType = "audio/pcm;rate=16000"

    // MARK: Endpoints

    /// Where a session connects. The key goes in `x-goog-api-key`, never in
    /// the URL.
    enum Endpoint: Equatable {
        /// Google AI Studio (a Gemini API key).
        case aiStudio
        /// Vertex AI with an API key. The Live model is served in
        /// `us-central1` (not on the global host) and needs the full
        /// `projects/…/locations/…/publishers/google/models/…` name; the
        /// short `publishers/google/models/…` form closes with 1007.
        case vertex(project: String, location: String)

        static let vertexLocation = "us-central1"

        var url: URL {
            switch self {
            case .aiStudio:
                return URL(string: "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent")!
            case .vertex(_, let location):
                return URL(string: "wss://\(location)-aiplatform.googleapis.com/ws/google.cloud.aiplatform.v1beta1.LlmBidiService/BidiGenerateContent")!
            }
        }

        /// `setup.model` for `model`.
        func modelName(_ model: String) -> String {
            switch self {
            case .aiStudio:
                return model.hasPrefix("models/") ? model : "models/" + model
            case .vertex(let project, let location):
                return "projects/\(project)/locations/\(location)/publishers/google/models/\(model)"
            }
        }

        var isVertex: Bool {
            if case .vertex = self { return true }
            return false
        }

        /// The opening request (the key in a header).
        func request(apiKey: String) -> URLRequest {
            var request = URLRequest(url: url)
            request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
            request.timeoutInterval = 20
            return request
        }

        /// The Vertex project from a provider base URL with a project path
        /// (`…/v1/projects/<id>/locations/<loc>`); nil for the express host.
        static func vertexProject(fromBaseURL baseURL: String) -> String? {
            let segments = (URL(string: baseURL)?.path ?? "").split(separator: "/").map(String.init)
            guard let index = segments.firstIndex(of: "projects"), index + 1 < segments.count else { return nil }
            let project = segments[index + 1].trimmingCharacters(in: .whitespaces)
            return project.isEmpty ? nil : project
        }
    }

    // MARK: Client → server

    enum Scheduling: String, Codable, Equatable {
        /// Speak it now, cutting the model off.
        case interrupt = "INTERRUPT"
        /// Speak it once the model has finished what it is saying.
        case whenIdle = "WHEN_IDLE"
        /// Keep it in context; say nothing.
        case silent = "SILENT"
    }

    enum Behavior: String, Codable {
        case blocking = "BLOCKING"
        case nonBlocking = "NON_BLOCKING"
    }

    struct FunctionDeclaration: Encodable, Equatable {
        var name: String
        var description: String
        var parameters: JSONValue?
        var behavior: Behavior
    }

    /// The session's configuration, sent first on every connection (also
    /// when resuming: the server needs the whole setup again).
    struct Setup: Encodable, Equatable {
        struct GenerationConfig: Encodable, Equatable {
            var responseModalities = ["AUDIO"]
            var speechConfig: SpeechConfig?
        }
        struct SpeechConfig: Encodable, Equatable {
            struct VoiceConfig: Encodable, Equatable {
                struct Prebuilt: Encodable, Equatable { var voiceName: String }
                var prebuiltVoiceConfig: Prebuilt
            }
            var voiceConfig: VoiceConfig
        }
        struct Content: Encodable, Equatable {
            struct Part: Encodable, Equatable { var text: String }
            var parts: [Part]
        }
        struct Tool: Encodable, Equatable {
            var functionDeclarations: [FunctionDeclaration]
        }
        struct RealtimeInputConfig: Encodable, Equatable {
            struct AutomaticActivityDetection: Encodable, Equatable {
                var disabled = false
            }
            var automaticActivityDetection = AutomaticActivityDetection()
            /// The user's speech always cuts the model off.
            var activityHandling = "START_OF_ACTIVITY_INTERRUPTS"
        }
        struct Transcription: Encodable, Equatable {
            var customVocabulary: [String]?
        }
        struct Compression: Encodable, Equatable {
            struct SlidingWindow: Encodable, Equatable { var targetTokens: String }
            var triggerTokens: String
            var slidingWindow: SlidingWindow
        }
        struct Resumption: Encodable, Equatable {
            var handle: String?
        }

        var model: String
        var generationConfig: GenerationConfig
        var systemInstruction: Content
        var tools: [Tool]
        var realtimeInputConfig = RealtimeInputConfig()
        var inputAudioTranscription: Transcription
        var outputAudioTranscription = Transcription()
        var contextWindowCompression: Compression
        /// Always present: an empty object opts in to handles.
        var sessionResumption: Resumption

        /// Compression starts at `triggerTokens` and slides back to
        /// `targetTokens`: every turn re-bills the whole context.
        static let triggerTokens = 16_000
        static let targetTokens = 4_000

        init(
            endpoint: Endpoint,
            model: String = GeminiLive.model,
            voice: String?,
            instructions: String,
            functions: [FunctionDeclaration],
            vocabulary: [String] = [],
            resumptionHandle: String?
        ) {
            self.model = endpoint.modelName(model)
            let voice = voice?.trimmingCharacters(in: .whitespaces) ?? ""
            generationConfig = GenerationConfig(
                speechConfig: voice.isEmpty ? nil : SpeechConfig(voiceConfig: .init(prebuiltVoiceConfig: .init(voiceName: voice)))
            )
            systemInstruction = Content(parts: [.init(text: instructions)])
            tools = [Tool(functionDeclarations: functions)]
            inputAudioTranscription = Transcription(customVocabulary: vocabulary.isEmpty ? nil : vocabulary)
            contextWindowCompression = Compression(
                triggerTokens: String(Self.triggerTokens),
                slidingWindow: .init(targetTokens: String(Self.targetTokens))
            )
            sessionResumption = Resumption(handle: resumptionHandle.flatMap { $0.isEmpty ? nil : $0 })
        }
    }

    struct FunctionResponse: Equatable {
        var id: String
        var name: String
        var response: [String: JSONValue]
        var scheduling: Scheduling?
    }

    /// One frame the client sends.
    enum ClientMessage: Equatable {
        case setup(Setup)
        /// 16 kHz PCM16 mono microphone audio.
        case audio(Data)
        /// The user's audio stream paused: the server flushes its turn.
        case audioStreamEnd
        /// Typed user input (`realtimeInput.text`), answered like speech.
        /// It gets no input transcription back.
        case text(String)
        /// A user-role text turn. `turnComplete: false` adds it to the
        /// context without a reply (a silent note); true asks for one.
        case content(String, turnComplete: Bool)
        case toolResponse([FunctionResponse])
    }

    static func encode(_ message: ClientMessage) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data: Data
        switch message {
        case .setup(let setup):
            data = try encoder.encode(["setup": setup])
        case .audio(let pcm):
            let audio: JSONValue = ["mimeType": .string(inputMimeType), "data": .string(pcm.base64EncodedString())]
            data = try encoder.encode(["realtimeInput": ["audio": audio] as JSONValue])
        case .audioStreamEnd:
            data = try encoder.encode(["realtimeInput": ["audioStreamEnd": true] as JSONValue])
        case .text(let text):
            data = try encoder.encode(["realtimeInput": ["text": .string(text)] as JSONValue])
        case .content(let text, let turnComplete):
            let content: JSONValue = [
                "turns": [["role": "user", "parts": [["text": .string(text)]]]],
                "turnComplete": .bool(turnComplete)
            ]
            data = try encoder.encode(["clientContent": content])
        case .toolResponse(let responses):
            let items: [JSONValue] = responses.map { item in
                var response = item.response
                var object: [String: JSONValue] = ["id": .string(item.id), "name": .string(item.name)]
                if let scheduling = item.scheduling {
                    response["scheduling"] = .string(scheduling.rawValue)
                    object["scheduling"] = .string(scheduling.rawValue)
                }
                object["response"] = .object(response)
                return .object(object)
            }
            data = try encoder.encode(["toolResponse": ["functionResponses": .array(items)] as JSONValue])
        }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: Server → client

    struct FunctionCall: Equatable {
        var id: String
        var name: String
        var args: [String: JSONValue]
    }

    struct Transcription: Equatable {
        var text: String
        var finished: Bool
    }

    struct Usage: Equatable {
        var promptTokens: Int
        var responseTokens: Int
        var totalTokens: Int
    }

    /// One server frame. A frame can carry several parts at once (audio, a
    /// transcription fragment and `turnComplete`); unknown fields are ignored.
    struct ServerMessage: Equatable {
        var setupComplete = false
        /// Model speech, 24 kHz PCM16 mono.
        var audio: [Data] = []
        var inputTranscription: Transcription?
        var outputTranscription: Transcription?
        /// The user spoke over the model: flush playback.
        var interrupted = false
        /// The model has generated all of its turn (audio may still play).
        var generationComplete = false
        /// The turn is over (the server assumes real-time playback, so it
        /// lags `generationComplete` by the audio's length).
        var turnComplete = false
        var toolCalls: [FunctionCall] = []
        var cancelledCalls: [String] = []
        /// The connection closes soon; seconds left.
        var goAway: TimeInterval?
        var resumption: (handle: String?, resumable: Bool)?
        var usage: Usage?

        /// A keep-alive (`{}` or an empty `serverContent`).
        var isEmpty: Bool { self == ServerMessage() }

        static func == (lhs: ServerMessage, rhs: ServerMessage) -> Bool {
            lhs.setupComplete == rhs.setupComplete && lhs.audio == rhs.audio
                && lhs.inputTranscription == rhs.inputTranscription && lhs.outputTranscription == rhs.outputTranscription
                && lhs.interrupted == rhs.interrupted && lhs.generationComplete == rhs.generationComplete
                && lhs.turnComplete == rhs.turnComplete && lhs.toolCalls == rhs.toolCalls
                && lhs.cancelledCalls == rhs.cancelledCalls && lhs.goAway == rhs.goAway
                && lhs.resumption?.handle == rhs.resumption?.handle && lhs.resumption?.resumable == rhs.resumption?.resumable
                && lhs.usage == rhs.usage
        }
    }

    /// Decodes one frame; nil when it is not JSON.
    static func decode(_ data: Data) -> ServerMessage? {
        guard let root = try? JSONDecoder().decode([String: JSONValue].self, from: data) else { return nil }
        var message = ServerMessage()
        message.setupComplete = root["setupComplete"] != nil
        if let content = root["serverContent"]?.objectValue {
            for part in content["modelTurn"]?.objectValue?["parts"]?.arrayValue ?? [] {
                guard let inline = part.objectValue?["inlineData"]?.objectValue,
                      inline["mimeType"]?.stringValue?.hasPrefix("audio/pcm") == true,
                      let base64 = inline["data"]?.stringValue,
                      let pcm = Data(base64Encoded: base64)
                else {
                    continue
                }
                message.audio.append(pcm)
            }
            message.inputTranscription = transcription(content["inputTranscription"])
            message.outputTranscription = transcription(content["outputTranscription"])
            message.interrupted = content["interrupted"] == .bool(true)
            message.generationComplete = content["generationComplete"] == .bool(true)
            message.turnComplete = content["turnComplete"] == .bool(true)
        }
        for call in root["toolCall"]?.objectValue?["functionCalls"]?.arrayValue ?? [] {
            guard let object = call.objectValue, let name = object["name"]?.stringValue else { continue }
            message.toolCalls.append(FunctionCall(
                id: object["id"]?.textValue ?? "",
                name: name,
                args: object["args"]?.objectValue ?? [:]
            ))
        }
        message.cancelledCalls = (root["toolCallCancellation"]?.objectValue?["ids"]?.arrayValue ?? []).compactMap(\.stringValue)
        if let goAway = root["goAway"] {
            message.goAway = duration(goAway.objectValue?["timeLeft"]) ?? 0
        }
        if let update = root["sessionResumptionUpdate"]?.objectValue {
            let handle = update["newHandle"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
            message.resumption = (handle, update["resumable"] == .bool(true))
        }
        if let usage = root["usageMetadata"]?.objectValue {
            message.usage = Usage(
                promptTokens: usage["promptTokenCount"]?.intValue ?? 0,
                responseTokens: usage["responseTokenCount"]?.intValue ?? 0,
                totalTokens: usage["totalTokenCount"]?.intValue ?? 0
            )
        }
        return message
    }

    private static func transcription(_ value: JSONValue?) -> Transcription? {
        guard let object = value?.objectValue, let text = object["text"]?.stringValue, !text.isEmpty else { return nil }
        return Transcription(text: text, finished: object["finished"] == .bool(true))
    }

    /// A proto Duration: "10s", "1.5s", or `{seconds, nanos}`.
    static func duration(_ value: JSONValue?) -> TimeInterval? {
        switch value {
        case .string(let text):
            guard text.hasSuffix("s") else { return nil }
            return Double(text.dropLast())
        case .object(let object):
            let seconds = object["seconds"]?.textValue.flatMap(Double.init) ?? 0
            let nanos = object["nanos"]?.textValue.flatMap(Double.init) ?? 0
            return seconds + nanos / 1_000_000_000
        case .int(let seconds):
            return Double(seconds)
        case .double(let seconds):
            return seconds
        default:
            return nil
        }
    }
}
