import XCTest
@testable import Forumind

/// The Gemini Live wire format: the setup for both endpoints, every client
/// frame, every server message decoded from fixture JSON, the tool
/// declarations and the close codes.
final class VoiceProtocolTests: XCTestCase {
    // MARK: Setup

    func testAIStudioSetup() throws {
        let setup = GeminiLive.Setup(
            endpoint: .aiStudio, voice: "Puck", instructions: "Be brief.",
            functions: VoiceTool.geminiDeclarations(for: VoiceSite(adapter: DiscourseAdapter())), vocabulary: ["Prusa", "MK4"], resumptionHandle: nil
        )
        let object = try json(GeminiLive.encode(.setup(setup)))
        let body = try XCTUnwrap(object["setup"] as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "models/gemini-3.8-live")
        let generation = try XCTUnwrap(body["generationConfig"] as? [String: Any])
        XCTAssertEqual(generation["responseModalities"] as? [String], ["AUDIO"])
        let voice = ((generation["speechConfig"] as? [String: Any])?["voiceConfig"] as? [String: Any])?["prebuiltVoiceConfig"] as? [String: Any]
        XCTAssertEqual(voice?["voiceName"] as? String, "Puck")
        // Native audio picks the language itself: no language code anywhere.
        XCTAssertFalse(try GeminiLive.encode(.setup(setup)).contains("languageCode"))
        XCTAssertEqual(((body["systemInstruction"] as? [String: Any])?["parts"] as? [[String: Any]])?.first?["text"] as? String, "Be brief.")

        let declarations = try XCTUnwrap((body["tools"] as? [[String: Any]])?.first?["functionDeclarations"] as? [[String: Any]])
        XCTAssertEqual(declarations.map { $0["name"] as? String }, ["find", "open", "move", "focus", "read", "research", "end"])
        XCTAssertTrue(declarations.allSatisfy { $0["behavior"] as? String == "NON_BLOCKING" })
        let find = try XCTUnwrap(declarations.first)
        XCTAssertEqual((find["parameters"] as? [String: Any])?["type"] as? String, "OBJECT")
        XCTAssertEqual((find["parameters"] as? [String: Any])?["required"] as? [String], ["query"])
        XCTAssertNil(declarations.last?["parameters"], "end takes no arguments")

        let detection = (body["realtimeInputConfig"] as? [String: Any])?["automaticActivityDetection"] as? [String: Any]
        XCTAssertEqual(detection?["disabled"] as? Bool, false)
        XCTAssertEqual((body["inputAudioTranscription"] as? [String: Any])?["customVocabulary"] as? [String], ["Prusa", "MK4"])
        XCTAssertNotNil(body["outputAudioTranscription"] as? [String: Any])
        let compression = try XCTUnwrap(body["contextWindowCompression"] as? [String: Any])
        // int64 in proto JSON: strings.
        XCTAssertEqual(compression["triggerTokens"] as? String, "16000")
        XCTAssertEqual((compression["slidingWindow"] as? [String: Any])?["targetTokens"] as? String, "4000")
        // An empty object opts in to resumption handles.
        XCTAssertEqual((body["sessionResumption"] as? [String: Any])?.count, 0)

        let request = GeminiLive.Endpoint.aiStudio.request(apiKey: "test-key")
        XCTAssertEqual(
            request.url?.absoluteString,
            "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent"
        )
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-goog-api-key"), "test-key")
        XCTAssertFalse(request.url?.absoluteString.contains("test-key") ?? true, "The key never goes in the URL")
    }

    func testVertexSetupUsesTheRegionalHostAndTheFullModelPath() throws {
        let endpoint = GeminiLive.Endpoint.vertex(project: "my-project", location: "us-central1")
        let setup = GeminiLive.Setup(
            endpoint: endpoint, voice: "", instructions: "x", functions: [], resumptionHandle: "8149f0e4-handle"
        )
        let body = try XCTUnwrap(try json(GeminiLive.encode(.setup(setup)))["setup"] as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "projects/my-project/locations/us-central1/publishers/google/models/gemini-3.8-live")
        XCTAssertEqual((body["sessionResumption"] as? [String: Any])?["handle"] as? String, "8149f0e4-handle")
        XCTAssertNil((body["generationConfig"] as? [String: Any])?["speechConfig"], "No voice keeps Google's default")
        XCTAssertNil((body["inputAudioTranscription"] as? [String: Any])?["customVocabulary"])
        XCTAssertEqual(
            endpoint.url.absoluteString,
            "wss://us-central1-aiplatform.googleapis.com/ws/google.cloud.aiplatform.v1beta1.LlmBidiService/BidiGenerateContent"
        )
        XCTAssertEqual(endpoint.request(apiKey: "k").value(forHTTPHeaderField: "x-goog-api-key"), "k")

        XCTAssertEqual(
            GeminiLive.Endpoint.vertexProject(fromBaseURL: "https://aiplatform.googleapis.com/v1/projects/forum-123/locations/global"),
            "forum-123"
        )
        XCTAssertNil(GeminiLive.Endpoint.vertexProject(fromBaseURL: "https://aiplatform.googleapis.com/v1"), "Express mode has no project")
    }

    // MARK: Client frames

    func testClientFrames() throws {
        let audio = try json(GeminiLive.encode(.audio(Data([1, 0, 2, 0]))))
        let blob = (audio["realtimeInput"] as? [String: Any])?["audio"] as? [String: Any]
        XCTAssertEqual(blob?["mimeType"] as? String, "audio/pcm;rate=16000")
        XCTAssertEqual(blob?["data"] as? String, Data([1, 0, 2, 0]).base64EncodedString())

        let end = try json(GeminiLive.encode(.audioStreamEnd))
        XCTAssertEqual((end["realtimeInput"] as? [String: Any])?["audioStreamEnd"] as? Bool, true)

        let note = try json(GeminiLive.encode(.content("[Screen: post 3]", turnComplete: false)))
        let content = try XCTUnwrap(note["clientContent"] as? [String: Any])
        XCTAssertEqual(content["turnComplete"] as? Bool, false)
        let turn = (content["turns"] as? [[String: Any]])?.first
        XCTAssertEqual(turn?["role"] as? String, "user")
        XCTAssertEqual((turn?["parts"] as? [[String: Any]])?.first?["text"] as? String, "[Screen: post 3]")

        let response = try json(GeminiLive.encode(.toolResponse([
            GeminiLive.FunctionResponse(id: "call_1", name: "find", response: ["status": "found", "card": 2], scheduling: .whenIdle)
        ])))
        let item = try XCTUnwrap(((response["toolResponse"] as? [String: Any])?["functionResponses"] as? [[String: Any]])?.first)
        XCTAssertEqual(item["id"] as? String, "call_1")
        XCTAssertEqual(item["name"] as? String, "find")
        // Both placements: the docs put it in `response`, the API also beside it.
        XCTAssertEqual(item["scheduling"] as? String, "WHEN_IDLE")
        let inner = try XCTUnwrap(item["response"] as? [String: Any])
        XCTAssertEqual(inner["scheduling"] as? String, "WHEN_IDLE")
        XCTAssertEqual(inner["status"] as? String, "found")
        XCTAssertEqual(inner["card"] as? Int, 2)

        XCTAssertEqual(GeminiLive.Scheduling.interrupt.rawValue, "INTERRUPT")
        XCTAssertEqual(GeminiLive.Scheduling.silent.rawValue, "SILENT")
    }

    // MARK: Server messages

    func testServerMessagesFromFixtures() throws {
        XCTAssertTrue(try decode(#"{"setupComplete":{}}"#).setupComplete)
        XCTAssertTrue(try decode(#"{"setupComplete":{"sessionId":"abc"}}"#).setupComplete, "Vertex adds a session id")
        XCTAssertTrue(try decode("{}").isEmpty, "Keep-alive")
        XCTAssertTrue(try decode(#"{"serverContent":{}}"#).isEmpty, "Keep-alive")
        XCTAssertNil(GeminiLive.decode(Data("not json".utf8)))

        let pcm = Data([0, 1, 2, 3])
        let audio = try decode("""
        {"serverContent":{"modelTurn":{"parts":[{"inlineData":{"mimeType":"audio/pcm;rate=24000","data":"\(pcm.base64EncodedString())"}}]},
         "outputTranscription":{"text":"Hello, team "}}}
        """)
        XCTAssertEqual(audio.audio, [pcm])
        XCTAssertEqual(audio.outputTranscription, .init(text: "Hello, team ", finished: false))

        let input = try decode(#"{"serverContent":{"inputTranscription":{"text":"next one","finished":true}}}"#)
        XCTAssertEqual(input.inputTranscription, .init(text: "next one", finished: true))

        let end = try decode("""
        {"serverContent":{"generationComplete":true,"turnComplete":true},
         "usageMetadata":{"promptTokenCount":583,"responseTokenCount":49,"totalTokenCount":632,
           "promptTokensDetails":[{"modality":"TEXT","tokenCount":344}]}}
        """)
        XCTAssertTrue(end.generationComplete)
        XCTAssertTrue(end.turnComplete)
        XCTAssertEqual(end.usage, .init(promptTokens: 583, responseTokens: 49, totalTokens: 632))

        XCTAssertTrue(try decode(#"{"serverContent":{"interrupted":true}}"#).interrupted)

        let call = try decode("""
        {"toolCall":{"functionCalls":[{"id":"call_263855","name":"move","args":{"action":"post","post":37}},
                                      {"id":"call_9","name":"end","args":{}}]}}
        """)
        XCTAssertEqual(call.toolCalls.map(\.name), ["move", "end"])
        XCTAssertEqual(call.toolCalls.first?.id, "call_263855")
        XCTAssertEqual(call.toolCalls.first?.args["post"]?.intValue, 37)
        XCTAssertEqual(call.toolCalls.first?.args["action"]?.textValue, "post")

        XCTAssertEqual(try decode(#"{"toolCallCancellation":{"ids":["call_1","call_2"]}}"#).cancelledCalls, ["call_1", "call_2"])
        XCTAssertEqual(try decode(#"{"goAway":{"timeLeft":"50s"}}"#).goAway, 50)
        XCTAssertEqual(try decode(#"{"goAway":{"timeLeft":{"seconds":"1","nanos":500000000}}}"#).goAway, 1.5)

        let handle = try decode(#"{"sessionResumptionUpdate":{"newHandle":"91d82179-a54","resumable":true}}"#)
        XCTAssertEqual(handle.resumption?.handle, "91d82179-a54")
        XCTAssertEqual(handle.resumption?.resumable, true)
        let notResumable = try decode(#"{"sessionResumptionUpdate":{"resumable":false}}"#)
        XCTAssertNil(notResumable.resumption?.handle)
        XCTAssertEqual(notResumable.resumption?.resumable, false)
    }

    func testCloseCodes() {
        let refused = LiveClose(code: 1007, reason: "The requested combination of response modalities (TEXT) is not supported by the model.")
        XCTAssertTrue(refused.isRefusal)
        XCTAssertTrue(LiveClose(code: 1008, reason: "Request is missing required authentication credential").isRefusal)
        XCTAssertTrue(LiveClose(code: 1008, reason: "Publisher model `projects/p/locations/global/publishers/google/models/gemini-3.8-live` was not found").isRefusal)
        let gone = LiveClose(code: 1008, reason: "Requested entity was not found.")
        XCTAssertTrue(gone.isSessionGone)
        XCTAssertFalse(gone.isRefusal)
        XCTAssertTrue(LiveClose(code: 1008, reason: "BidiGenerateContent session not found or expired").isSessionGone)
        let busy = LiveClose(code: 1008, reason: "BidiGenerateContent session is already connected to an existing client")
        XCTAssertTrue(busy.isAlreadyConnected)
        XCTAssertFalse(busy.isRefusal)
        XCTAssertFalse(LiveClose(code: 1011, reason: "Internal error encountered.").isRefusal)
    }

    // MARK: Tools

    func testToolDefinitions() {
        let site = VoiceSite(adapter: DiscourseAdapter())
        XCTAssertEqual(VoiceTool.allCases.count, 7)
        XCTAssertEqual(VoiceTool.find.scheduling, .whenIdle)
        XCTAssertEqual(VoiceTool.open.scheduling, .whenIdle)
        XCTAssertEqual(VoiceTool.research.scheduling, .silent, "research answers started silently; its answer is a briefing")
        for tool in VoiceTool.allCases {
            XCTAssertGreaterThan(tool.description(for: site).count, 80, tool.rawValue)
            XCTAssertFalse(tool.description(for: site).contains("\n"), "\(tool.rawValue): one paragraph")
        }
        XCTAssertTrue(VoiceTool.find.description(for: site).contains("Never read out ids"))
        XCTAssertTrue(VoiceTool.find.description(for: site).contains("call open with its card number right away"))
        XCTAssertTrue(VoiceTool.research.description(for: site).contains("never for something find, open, move, focus or read can do"))
        guard case .object(let properties, _)? = VoiceTool.move.parameters(for: site) else { return XCTFail() }
        XCTAssertEqual(properties.map(\.name), ["action", "post"])
    }

    // MARK: Helpers

    private func json(_ text: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    private func decode(_ text: String) throws -> GeminiLive.ServerMessage {
        try XCTUnwrap(GeminiLive.decode(Data(text.utf8)))
    }
}
