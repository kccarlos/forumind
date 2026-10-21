import XCTest
@testable import Forumind

/// The podcast: the script's JSON and its checks, chapters mapped to cards,
/// the Gemini TTS request and response, engine and system-voice selection,
/// the player's chapter navigation and remembered position, the daily
/// switch's defaults, "Ask about this" pausing and resuming, and the cache's
/// cleanup. No network, no key, no audio hardware.
@MainActor
final class PodcastTests: XCTestCase {
    private let site = "https://forum.example.com"

    override func setUp() async throws {
        TTSStub.reset()
    }

    // MARK: Script

    func testAChapterAnswerIsParsedFromFencedJSONAndTiedToItsCard() throws {
        let card = card("7", firstNew: 31, answer: 40)
        let answer = """
        Here it is:
        ```json
        {"title": "Layer shifts again", "post": 40, "turns": [
          {"speaker": "A", "text": "Seven new replies on layer shifts since post 31."},
          {"speaker": "b", "text": "Did anyone find the cause?"},
          {"speaker": "A", "text": "Yes, post 40 is the accepted answer; the post includes the config change."}
        ]}
        ```
        """
        let chapter = try PodcastScriptParser.chapter(from: answer, for: card, grounding: grounding(card))
        XCTAssertEqual(chapter.id, card.topicKey)
        XCTAssertEqual(chapter.kind, .topic)
        XCTAssertEqual(chapter.title, "Layer shifts again")
        XCTAssertEqual(chapter.turns.map(\.speaker), [.a, .b, .a])
        XCTAssertEqual(chapter.postNumber, 40, "a cited post the card links to")
        XCTAssertEqual(chapter.topicURL?.absoluteString, "\(site)/t/topic-7/7/40")

        // A post the card doesn't link to keeps the default (the first new reply).
        let other = try PodcastScriptParser.chapter(
            from: #"{"post": 99, "turns": [{"speaker":"A","text":"Hello."},{"speaker":"B","text":"Hi."}]}"#,
            for: card, grounding: grounding(card)
        )
        XCTAssertEqual(other.postNumber, 31)
        XCTAssertEqual(other.title, card.title)
    }

    func testSpokenTextWithCodeURLsCommandsOrTracesIsRejected() {
        let card = card("8")
        func reject(_ text: String, _ expected: PodcastScriptError, file: StaticString = #filePath, line: UInt = #line) {
            let json = #"{"turns": [{"speaker":"A","text":"Fine."},{"speaker":"B","text":"\#(text)"}]}"#
            XCTAssertThrowsError(try PodcastScriptParser.chapter(from: json, for: card, grounding: grounding(card)), file: file, line: line) {
                XCTAssertEqual($0 as? PodcastScriptError, expected, text, file: file, line: line)
            }
        }
        reject("See https://example.com/fix for details.", .unspeakable("a web address"))
        reject("It is on github.com now.", .unspeakable("a web address"))
        reject("Run ```make flash``` first.", .unspeakable("code"))
        reject("Set `max_velocity` lower.", .unspeakable("code"))
        reject("Just run sudo apt-get install klipper.", .unspeakable("a command"))
        reject("Add the --force flag.", .unspeakable("a command-line flag"))
        reject("It says TypeError: undefined is not a function.", .unspeakable("a stack trace"))
        reject("Set stepper_x.rotation_distance: 40 in the file.", .unspeakable("a configuration line"))
        reject("Edit /etc/klipper/printer.cfg and restart.", .unspeakable("a file path"))
        reject("**Important** news.", .unspeakable("Markdown"))
        reject("It takes <laugh> forever.", .unspeakable("markup or code"))

        // Fine as speech: says what the code is for and points to the topic.
        XCTAssertNoThrow(try PodcastScriptParser.chapter(
            from: #"{"turns": [{"speaker":"A","text":"The post includes the config change."},{"speaker":"B","text":"So the details are in the topic."}]}"#,
            for: card, grounding: grounding(card)
        ))
    }

    func testTurnsMustAlternateTwoHostsAndNumbersMustBeGrounded() {
        let card = card("9")
        let grounding = grounding(card)
        XCTAssertThrowsError(try PodcastScriptParser.chapter(from: "Sorry, I can't.", for: card, grounding: grounding)) {
            XCTAssertEqual($0 as? PodcastScriptError, .notJSON)
        }
        XCTAssertThrowsError(try PodcastScriptParser.chapter(
            from: #"{"turns": [{"speaker":"A","text":"One."},{"speaker":"A","text":"Two."}]}"#, for: card, grounding: grounding
        )) { XCTAssertEqual($0 as? PodcastScriptError, .badTurns("only one host speaks")) }
        XCTAssertThrowsError(try PodcastScriptParser.chapter(
            from: #"{"turns": [{"speaker":"Narrator","text":"One."},{"speaker":"A","text":"Two."}]}"#, for: card, grounding: grounding
        ))
        // 12 posts is in the card; 300 is not.
        XCTAssertNoThrow(try PodcastScriptParser.chapter(
            from: #"{"turns": [{"speaker":"A","text":"The topic has 12 posts."},{"speaker":"B","text":"Busy."}]}"#, for: card, grounding: grounding
        ))
        XCTAssertThrowsError(try PodcastScriptParser.chapter(
            from: #"{"turns": [{"speaker":"A","text":"Speeds went up to 300."},{"speaker":"B","text":"Wow."}]}"#, for: card, grounding: grounding
        )) { XCTAssertEqual($0 as? PodcastScriptError, .inventedNumber("300")) }
        // The retry prompt says why.
        XCTAssertTrue(PodcastPrompt.retry(reason: PodcastScriptError.inventedNumber("300").reason).contains("300"))
    }

    func testTheEpisodeHasAnIntroOneChapterPerSummarizedCardAndAnOutro() throws {
        var done = card("1", firstNew: 5)
        done.state = .done
        var trending = card("2", answer: 9)
        trending.reason = .trending
        trending.state = .done
        var failed = card("3")
        failed.state = .failed
        let pending = DigestCard(siteURL: site, topicID: "4", title: "Waiting", reason: .trending, postCount: 3)
        let digest = DailyDigest(day: "2026-10-20", cards: [done, failed, trending, pending])
        let hosts = PodcastHosts(a: "Ava", b: "Leo")

        let chapters = PodcastScript.plan(for: digest, hosts: hosts)
        XCTAssertEqual(chapters.map(\.kind), [.intro, .topic, .topic, .outro])
        XCTAssertEqual(chapters.map(\.id), ["intro", done.topicKey, trending.topicKey, "outro"])
        XCTAssertEqual(chapters[1].postNumber, 5, "a watched topic opens at its first new reply")
        XCTAssertEqual(chapters[2].postNumber, 9, "a trending topic at its accepted answer")
        XCTAssertNil(chapters[0].topicURL)
        // The intro and outro are fixed lines (no AI) with the hosts' names.
        XCTAssertTrue(chapters[0].isScripted && chapters[3].isScripted)
        XCTAssertFalse(chapters[1].isScripted)
        XCTAssertTrue(chapters[0].spokenText.contains("Ava") || !isEnglish)
        XCTAssertTrue(chapters[0].spokenText.contains("Leo") || !isEnglish)
        XCTAssertEqual(Set(chapters[0].turns.map(\.speaker)), [.a, .b])

        XCTAssertEqual(PodcastScript.plan(for: DailyDigest(day: "2026-10-20", cards: [failed, pending]), hosts: hosts), [])

        // The prompt names the language, the hosts, the citable posts and the
        // rule against reading code or links; the content carries the card.
        let prompt = PodcastPrompt.Chapter(card: done, forumName: "Example", index: 1, count: 2, previousTitle: nil, topicText: "OP text")
        let system = PodcastPrompt.system(hosts: hosts, chapter: prompt, minutes: 1, languageName: "Simplified Chinese", language: "zh-Hans")
        XCTAssertTrue(system.contains("Simplified Chinese"))
        XCTAssertTrue(system.contains("about 260 Chinese characters"))
        XCTAssertTrue(system.contains("Ava") && system.contains("Leo"))
        XCTAssertTrue(system.contains("one of 5, or null"))
        XCTAssertTrue(system.contains("Never read out code"))
        let content = PodcastPrompt.content(for: prompt)
        XCTAssertTrue(content.contains(done.summary))
        XCTAssertTrue(content.contains("OP text"))
        XCTAssertEqual(PodcastPrompt.lengthTarget(minutes: 2, language: "en"), "about 300 words")
    }

    func testAFallbackChapterAndReadAloudTextHaveNothingUnspeakable() {
        var card = card("5")
        card.summary = "Fixed by [this post](https://forum.example.com/t/x/5/3).\n```yaml\nkey: value\n```\n**Done**."
        let turns = PodcastScript.fallbackTurns(for: card)
        XCTAssertEqual(turns.map(\.speaker), [.a, .b])
        for turn in turns {
            XCTAssertNil(PodcastSpeechCheck.problem(in: turn.text), turn.text)
        }
        XCTAssertFalse(turns[1].text.contains("http"))
        XCTAssertFalse(turns[1].text.contains("key: value"))

        let chunks = PodcastController.readAloudChunks(String(repeating: "A sentence here. ", count: 200), limit: 300)
        XCTAssertGreaterThan(chunks.count, 5)
        XCTAssertTrue(chunks.allSatisfy { $0.count <= 300 })
    }

    // MARK: Gemini TTS

    func testTheTTSRequestIsMultiSpeakerWithTheKeyInAHeaderOnBothEndpoints() throws {
        let turns = [PodcastTurn(speaker: .a, text: "Hello."), PodcastTurn(speaker: .b, text: "Hi there.")]
        let voices = PodcastVoices(a: "Kore", b: "Puck")
        let studio = try GeminiTTS.request(
            turns: turns, voices: voices,
            endpoint: .init(provider: .aiStudio, baseURL: "https://generativelanguage.googleapis.com/v1beta/", apiKey: "secret-key")
        )
        XCTAssertEqual(studio.url?.absoluteString, "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.8-flash-tts:generateContent")
        XCTAssertEqual(studio.httpMethod, "POST")
        XCTAssertEqual(studio.value(forHTTPHeaderField: "x-goog-api-key"), "secret-key")
        XCTAssertFalse(studio.url?.absoluteString.contains("secret-key") ?? true, "the key never goes in the URL")

        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(studio.httpBody)) as? [String: Any])
        let contents = try XCTUnwrap(body["contents"] as? [[String: Any]])
        let parts = try XCTUnwrap(contents.first?["parts"] as? [[String: Any]])
        XCTAssertEqual(parts.map { $0["text"] as? String }, ["Hello.", "Hi there."])
        XCTAssertEqual(parts.map { ($0["speech_metadata"] as? [String: Any])?["speaker"] as? String }, ["A", "B"])
        XCTAssertNotNil((parts.first?["speech_metadata"] as? [String: Any])?["style"])
        let config = try XCTUnwrap(body["generationConfig"] as? [String: Any])
        XCTAssertEqual(config["responseModalities"] as? [String], ["AUDIO"])
        let multi = try XCTUnwrap(((config["speechConfig"] as? [String: Any])?["multiSpeakerVoiceConfig"] as? [String: Any])?["speakerVoiceConfigs"] as? [[String: Any]])
        XCTAssertEqual(multi.map { $0["speaker"] as? String }, ["A", "B"])
        XCTAssertEqual(multi.map { (($0["voiceConfig"] as? [String: Any])?["prebuiltVoiceConfig"] as? [String: Any])?["voiceName"] as? String }, ["Kore", "Puck"])

        let vertex = try GeminiTTS.request(
            turns: turns, voices: voices,
            endpoint: .init(provider: .vertex, baseURL: "https://aiplatform.googleapis.com/v1", apiKey: "vertex-key")
        )
        XCTAssertEqual(vertex.url?.absoluteString, "https://aiplatform.googleapis.com/v1/publishers/google/models/gemini-3.8-flash-tts:generateContent")
        XCTAssertEqual(vertex.value(forHTTPHeaderField: "x-goog-api-key"), "vertex-key")

        // One host (read aloud): a single voice, no speaker labels.
        let single = GeminiTTS.body(turns: [PodcastTurn(speaker: .a, text: "Only me.")], voices: voices)
        let speech = try XCTUnwrap((single["generationConfig"] as? [String: Any])?["speechConfig"] as? [String: Any])
        XCTAssertEqual((speech["voiceConfig"] as? [String: Any])?["voice"] as? String, "Kore")
        XCTAssertNil(speech["multiSpeakerVoiceConfig"])
        let singlePart = (((single["contents"] as? [[String: Any]])?.first?["parts"]) as? [[String: Any]])?.first
        XCTAssertNil((singlePart?["speech_metadata"] as? [String: Any])?["speaker"])
    }

    func testTheResponseAudioIsDecodedFromWAVOrL16() throws {
        // The docs' default: a WAV file (RIFF header), 24 kHz mono 16-bit.
        let pcm = Data((0..<4_800).flatMap { _ in [UInt8(0x10), UInt8(0x00)] })
        let wav = WAVFile.data(PCMAudio(samples: pcm, sampleRate: 24_000))
        let audio = try GeminiTTS.decode(Self.response(parts: [("audio/wav", wav)]))
        XCTAssertEqual(audio.sampleRate, 24_000)
        XCTAssertEqual(audio.channels, 1)
        XCTAssertEqual(audio.samples, pcm)
        XCTAssertEqual(audio.duration, 0.2, accuracy: 0.0001)

        // Headerless L16 with its rate in the mime type; parts are joined.
        let l16 = try GeminiTTS.decode(Self.response(parts: [("audio/L16;codec=pcm;rate=16000", pcm), ("audio/L16;codec=pcm;rate=16000", pcm)]))
        XCTAssertEqual(l16.sampleRate, 16_000)
        XCTAssertEqual(l16.samples.count, pcm.count * 2)
        XCTAssertEqual(WAVFile.parse(WAVFile.data(l16)), l16, "what is written reads back the same")

        // Blocked, or no audio: an error, not an empty file.
        let blocked = Data(#"{"promptFeedback":{"blockReason":"SAFETY"}}"#.utf8)
        XCTAssertThrowsError(try GeminiTTS.decode(blocked)) { XCTAssertEqual($0 as? PodcastSpeechError, .noAudio("SAFETY")) }
        let empty = Data(#"{"candidates":[{"content":{"parts":[]},"finishReason":"OTHER"}]}"#.utf8)
        XCTAssertThrowsError(try GeminiTTS.decode(empty)) { XCTAssertEqual($0 as? PodcastSpeechError, .noAudio("OTHER")) }
        XCTAssertThrowsError(try PCMAudio.decode(pcm, mimeType: "audio/mpeg"))
    }

    func testRateLimitsAreRetriedWithTheServersDelayAndOtherErrorsAreNot() async throws {
        let pcm = Data(count: 4_800)
        TTSStub.responses = [
            (429, Data(#"{"error":{"code":429,"message":"Quota","details":[{"@type":"type.googleapis.com/google.rpc.RetryInfo","retryDelay":"7s"}]}}"#.utf8)),
            (503, Data(#"{"error":{"message":"Overloaded"}}"#.utf8)),
            (200, Self.response(parts: [("audio/wav", WAVFile.data(PCMAudio(samples: pcm, sampleRate: 24_000)))]))
        ]
        var waits: [TimeInterval] = []
        let engine = GeminiSpeechEngine(
            endpoint: .init(provider: .aiStudio, baseURL: "https://generativelanguage.googleapis.com/v1beta", apiKey: "k"),
            voices: PodcastVoices(a: "Kore", b: "Puck"),
            session: TTSStub.session,
            sleep: { waits.append($0) }
        )
        let url = temporaryFolder().appendingPathComponent("chapter.wav")
        let duration = try await engine.synthesize([PodcastTurn(speaker: .a, text: "Hi."), PodcastTurn(speaker: .b, text: "Hello.")], to: url)
        XCTAssertEqual(duration, 0.1, accuracy: 0.0001)
        XCTAssertEqual(TTSStub.requests.count, 3)
        XCTAssertEqual(waits.first, 7, "RetryInfo's delay is honored")
        XCTAssertEqual(waits.count, 2)
        XCTAssertGreaterThanOrEqual(waits[1], 4, "then exponential backoff")
        XCTAssertEqual(WAVFile.parse(try Data(contentsOf: url))?.sampleRate, 24_000)

        // A refused key is not retried.
        TTSStub.reset()
        TTSStub.responses = [(400, Data(#"{"error":{"message":"API key not valid."}}"#.utf8))]
        waits = []
        do {
            _ = try await engine.synthesize([PodcastTurn(speaker: .a, text: "Hi.")], to: url)
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? PodcastSpeechError, .http(400, "API key not valid."))
        }
        XCTAssertEqual(TTSStub.requests.count, 1)
        XCTAssertTrue(waits.isEmpty)
    }

    // MARK: Engine selection

    func testGoogleVoicesNeedAKeyAndConsentOtherwiseTheDeviceSpeaks() {
        var settings = AppSettings()
        // No key: the device's voices, whatever the choice.
        XCTAssertEqual(PodcastEngineSelector.select(choice: .automatic, providers: [], settings: settings, interactive: true), .engine(.onDevice))
        XCTAssertEqual(PodcastEngineSelector.select(choice: .google, providers: [], settings: settings, interactive: true), .engine(.onDevice))
        // A key but no consent: a tap asks, the daily run never does.
        XCTAssertEqual(PodcastEngineSelector.select(choice: .automatic, providers: [.aiStudio], settings: settings, interactive: true), .needsConsent(.aiStudio))
        XCTAssertEqual(PodcastEngineSelector.select(choice: .automatic, providers: [.aiStudio], settings: settings, interactive: false), .engine(.onDevice))
        // Agreed: Google, on the provider agreed to.
        settings.podcastConsent["vertex"] = Date()
        XCTAssertEqual(PodcastEngineSelector.select(choice: .automatic, providers: [.aiStudio, .vertex], settings: settings, interactive: false), .engine(.vertex))
        XCTAssertEqual(PodcastEngineSelector.select(choice: .onDevice, providers: [.vertex], settings: settings, interactive: true), .engine(.onDevice))
        // Voice consent is separate: it doesn't cover the podcast.
        var voiceOnly = AppSettings()
        voiceOnly.voiceConsent["aistudio"] = Date()
        XCTAssertEqual(PodcastEngineSelector.select(choice: .automatic, providers: [.aiStudio], settings: voiceOnly, interactive: false), .engine(.onDevice))
    }

    func testTwoDistinctSystemVoicesAreChosenForTheAppLanguage() {
        let voices = [
            SystemVoiceCandidate(identifier: "en.novelty", language: "en-US", quality: 3, isNovelty: true),
            SystemVoiceCandidate(identifier: "en.samantha", language: "en-US", quality: 1, gender: .female),
            SystemVoiceCandidate(identifier: "en.ava.premium", language: "en-US", quality: 3, gender: .female),
            SystemVoiceCandidate(identifier: "en.zoe.premium", language: "en-US", quality: 3, gender: .female),
            SystemVoiceCandidate(identifier: "en.evan.premium", language: "en-US", quality: 3, gender: .male),
            SystemVoiceCandidate(identifier: "en.daniel", language: "en-GB", quality: 2, gender: .male),
            SystemVoiceCandidate(identifier: "zh.tingting", language: "zh-CN", quality: 2, gender: .female),
            SystemVoiceCandidate(identifier: "zh.meijia", language: "zh-TW", quality: 1, gender: .female)
        ]
        // Best quality, no novelty voice, host B of the other gender.
        XCTAssertEqual(PodcastSystemVoices.pick(appLanguage: "en", from: voices, region: "US"), .init(a: "en.ava.premium", b: "en.evan.premium"))
        // Chinese scripts don't mix with English; Traditional prefers Taiwan.
        XCTAssertEqual(PodcastSystemVoices.pick(appLanguage: "zh-Hans", from: voices, region: "CN"), .init(a: "zh.tingting", b: "zh.meijia"))
        let onlyOne = [SystemVoiceCandidate(identifier: "zh.meijia", language: "zh-TW", quality: 1)]
        let pick = PodcastSystemVoices.pick(appLanguage: "zh-Hant", from: onlyOne, region: "TW")
        XCTAssertEqual(pick?.a, "zh.meijia")
        XCTAssertTrue(pick?.sameVoice ?? false, "one voice: host B uses it with a raised pitch")
        XCTAssertNil(PodcastSystemVoices.pick(appLanguage: "en", from: [voices[6]], region: "US"))
    }

    // MARK: Settings

    func testTheDailyPodcastIsOffByDefaultAndItsSwitchAndConsentStayOnTheDevice() throws {
        let settings = AppSettings()
        XCTAssertFalse(settings.podcastDailyEnabled)
        XCTAssertTrue(settings.podcastConsent.isEmpty)
        XCTAssertEqual(settings.podcast.engine, .automatic)
        XCTAssertEqual(settings.podcast.minutesPerChapter, 1)
        XCTAssertEqual(settings.podcast.voiceA, "Kore")
        XCTAssertEqual(settings.podcast.voiceB, "Puck")
        XCTAssertNotEqual(settings.podcast.voiceA, settings.podcast.voiceB)
        XCTAssertTrue(settings.podcast.hostA.isEmpty, "the default name follows the interface language")
        XCTAssertEqual(settings.podcast.hosts, PodcastHosts(a: PodcastSpeaker.a.defaultName, b: PodcastSpeaker.b.defaultName))

        XCTAssertTrue(SyncSettings.deviceLocalKeys.isSuperset(of: ["podcastDailyEnabled", "podcastConsent"]))
        XCTAssertFalse(SyncSettings.deviceLocalKeys.contains("podcast"))

        // Older snapshots decode with the defaults; bad values fall back one by one.
        let old = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        XCTAssertFalse(old.podcastDailyEnabled)
        XCTAssertEqual(old.podcast, PodcastSettings())
        let odd = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"podcast": {"hostA": "  Mei ", "voiceA": "Nobody", "minutesPerChapter": 40, "engine": "future"}}"#.utf8))
        XCTAssertEqual(odd.podcast.hosts.a, "Mei")
        XCTAssertEqual(odd.podcast.voiceA, "Kore")
        XCTAssertEqual(odd.podcast.minutesPerChapter, 3)
        XCTAssertEqual(odd.podcast.engine, .automatic)
    }

    // MARK: Player

    func testTheTimelineSkipsAcrossChaptersAndNeverIntoOneNotMadeYet() {
        let timeline = PodcastTimeline(durations: [10, 30, 20, nil])
        typealias P = PodcastTimeline.Position
        XCTAssertEqual(timeline.total, 60)
        XCTAssertEqual(timeline.skip(15, from: P(chapter: 0, time: 2)), P(chapter: 1, time: 7))
        XCTAssertEqual(timeline.skip(-15, from: P(chapter: 1, time: 7)), P(chapter: 0, time: 2))
        XCTAssertEqual(timeline.skip(-15, from: P(chapter: 0, time: 5)), P(chapter: 0, time: 0))
        XCTAssertEqual(timeline.skip(15, from: P(chapter: 2, time: 10)), P(chapter: 2, time: 19.5), "chapter 4 isn't made yet")
        XCTAssertEqual(timeline.previousChapter(from: P(chapter: 2, time: 8)), P(chapter: 2, time: 0))
        XCTAssertEqual(timeline.previousChapter(from: P(chapter: 2, time: 1)), P(chapter: 1, time: 0))
        XCTAssertEqual(timeline.nextChapter(from: P(chapter: 2, time: 1)), P(chapter: 3, time: 0))
        XCTAssertNil(timeline.nextChapter(from: P(chapter: 3, time: 0)))
        XCTAssertEqual(timeline.position(atElapsed: 45), P(chapter: 2, time: 5))
        XCTAssertEqual(timeline.elapsed(P(chapter: 2, time: 5)), 45)
    }

    func testThePlayerMovesThroughChaptersWaitsForNewOnesAndRemembersWhereItWas() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "podcast-tests-\(UUID().uuidString)"))
        let audio = FakePodcastAudio()
        let session = FakePodcastSession()
        let player = PodcastPlayer(audio: audio, session: session, positions: PodcastPositionStore(defaults: defaults))
        var playlist = Self.playlist(durations: [10, 30, nil])
        playlist.isGrowing = true

        player.load(playlist, autoplay: true)
        XCTAssertEqual(player.state, .playing)
        XCTAssertEqual(session.activations, 1)
        XCTAssertEqual(audio.loaded.last?.lastPathComponent, "0.wav")

        audio.currentTime = 4
        player.skip(by: 15)
        XCTAssertEqual(player.position, .init(chapter: 1, time: 9))
        XCTAssertEqual(audio.loaded.last?.lastPathComponent, "1.wav")
        XCTAssertEqual(audio.currentTime, 9)

        player.previousChapter()
        XCTAssertEqual(player.chapterIndex, 1, "past 3 s: back to the chapter's start")
        player.previousChapter()
        XCTAssertEqual(player.chapterIndex, 0)
        player.nextChapter()
        XCTAssertEqual(player.chapterIndex, 1)

        // The end of chapter 2: chapter 3 isn't made yet, so it waits, then
        // plays as soon as it is.
        audio.finish()
        XCTAssertEqual(player.state, .waiting)
        XCTAssertEqual(player.chapterIndex, 2)
        playlist.items[2].url = URL(fileURLWithPath: "/tmp/2.wav")
        playlist.items[2].duration = 20
        playlist.isGrowing = false
        player.update(playlist)
        XCTAssertEqual(player.state, .playing)
        XCTAssertEqual(audio.loaded.last?.lastPathComponent, "2.wav")

        // Paused at 12 s; a new player (a relaunch) starts there.
        audio.currentTime = 12
        player.pause()
        XCTAssertEqual(player.state, .paused)
        let relaunched = PodcastPlayer(audio: FakePodcastAudio(), session: FakePodcastSession(), positions: PodcastPositionStore(defaults: defaults))
        relaunched.load(playlist)
        XCTAssertEqual(relaunched.position, .init(chapter: 2, time: 12))
        XCTAssertEqual(relaunched.state, .paused)

        // The last chapter ends: paused at the end; Play starts over.
        player.play()
        audio.finish()
        XCTAssertEqual(player.state, .paused)
        player.play()
        XCTAssertEqual(player.chapterIndex, 0)
        XCTAssertEqual(player.state, .playing)
    }

    func testCallsPauseAndResumeAndUnpluggedHeadphonesPause() {
        let audio = FakePodcastAudio()
        let player = PodcastPlayer(audio: audio, session: FakePodcastSession(), positions: PodcastPositionStore(defaults: UserDefaults(suiteName: UUID().uuidString)!))
        player.load(Self.playlist(durations: [10, 10]), autoplay: true)

        player.interruptionBegan()
        XCTAssertEqual(player.state, .paused)
        XCTAssertFalse(audio.isPlaying)
        player.interruptionEnded(shouldResume: true)
        XCTAssertEqual(player.state, .playing)

        player.interruptionBegan()
        player.interruptionEnded(shouldResume: false)
        XCTAssertEqual(player.state, .paused, "iOS didn't offer to resume")

        player.play()
        player.outputDeviceLost()
        XCTAssertEqual(player.state, .paused)
    }

    // MARK: Ask about this

    func testAskAboutThisPausesOpensTheTopicStartsVoiceAndResumesInPlace() async throws {
        let harness = makeHarness()
        let audio = FakePodcastAudio()
        let session = FakePodcastSession()
        let player = PodcastPlayer(audio: audio, session: session, positions: PodcastPositionStore(defaults: UserDefaults(suiteName: UUID().uuidString)!))
        player.routeSettleStep = .milliseconds(10)
        let controller = PodcastController(app: harness.app, store: PodcastStore(directory: temporaryFolder()), player: player)
        let voice = FakeVoiceStarter()
        controller.voice = voice
        controller.askPresentationDelay = .zero

        player.load(Self.playlist(durations: [10, 30]), autoplay: true)
        player.nextChapter()
        audio.currentTime = 12.5
        var chapter = PodcastChapter(card: card("7", firstNew: 31))
        chapter.turns = [PodcastTurn(speaker: .a, text: "Hi.")]
        var opened: [URL] = []

        controller.ask(about: chapter) { opened.append($0) }
        XCTAssertTrue(player.isSuspendedForVoice)
        XCTAssertEqual(player.state, .paused)
        XCTAssertEqual(player.position, .init(chapter: 1, time: 12.5))
        XCTAssertEqual(opened.map(\.absoluteString), ["\(site)/t/topic-7/7/31"], "opened at the cited post")
        try await waitUntil { voice.starts == 1 }
        // A remote Play while the voice session runs is refused.
        voice.isActive = true
        XCTAssertTrue(player.blocksRemotePlay())
        player.play()
        XCTAssertEqual(player.state, .paused)

        // The session ends while AirPods are still on hands-free: the
        // player waits for the route, then reloads the chapter and plays
        // from the same place.
        session.handsFree = true
        voice.isActive = false
        voice.finish()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(player.state, .paused, "still on HFP")
        session.handsFree = false
        try await waitUntil { player.state == .playing }
        XCTAssertFalse(player.isSuspendedForVoice)
        XCTAssertEqual(player.position.chapter, 1)
        XCTAssertEqual(audio.currentTime, 12.5)
        XCTAssertEqual(audio.loaded.last?.lastPathComponent, "1.wav")
        XCTAssertGreaterThanOrEqual(session.activations, 2, "back to .playback after the voice session")

        // Declined consent (or a failed start) resumes too; a paused podcast stays paused.
        player.pause()
        controller.ask(about: chapter) { _ in }
        voice.finish()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(player.isSuspendedForVoice)
        XCTAssertEqual(player.state, .paused)
    }

    func testTheVoiceControllerReportsADeclinedConsent() {
        let harness = makeHarness()
        var finished = 0
        harness.app.voice.onFinished = { finished += 1 }
        harness.app.voice.consentProvider = .aiStudio
        harness.app.voice.declineConsent()
        XCTAssertEqual(finished, 1)
        XCTAssertNil(harness.app.voice.onFinished, "called once")
        // No key: the start fails, and that is reported as well.
        harness.app.voice.onFinished = { finished += 1 }
        harness.app.voice.start()
        XCTAssertEqual(finished, 2)
    }

    // MARK: Making, storage

    func testAnEpisodeIsScriptedAndSpokenChapterByChapterIntoTheCache() async throws {
        let harness = makeHarness()
        let app = harness.app
        connect(app)
        let digest = completeDigest(cards: 2)
        app.digests = [digest]
        let engine = FakeSpeechEngine()
        app.podcast.makeEngine = { _, _, _ in engine }
        harness.ai.answers = [
            "not json",
            #"{"title":"First","turns":[{"speaker":"A","text":"The first topic has 12 posts."},{"speaker":"B","text":"Interesting."}]}"#,
            #"{"title":"Second","turns":[{"speaker":"A","text":"See https://x.com/a"},{"speaker":"B","text":"No."}]}"#,
            #"{"title":"Second","turns":[{"speaker":"A","text":"Still https://x.com/a"},{"speaker":"B","text":"No."}]}"#
        ]

        app.podcast.make()
        try await waitUntil { app.podcast.episode?.isComplete == true && !app.podcast.activity.isRunning }
        let episode = try XCTUnwrap(app.podcast.episode)
        XCTAssertEqual(episode.entries.map(\.state), [.ready, .ready, .ready, .ready])
        XCTAssertEqual(episode.engine, .onDevice, "no Google key: the device's voices")
        XCTAssertEqual(episode.entries[1].chapter.title, "First", "a rejected answer is asked for again")
        XCTAssertEqual(episode.entries[2].chapter.turns, PodcastScript.fallbackTurns(for: digest.cards[1]), "rejected twice: the card's own lines")
        XCTAssertEqual(harness.ai.calls.count, 4)
        XCTAssertTrue(harness.ai.calls[1].messages.last?.content.contains("rejected") ?? false)
        XCTAssertEqual(engine.spoken.count, 4, "intro, two topics, outro")
        for entry in episode.entries {
            let file = try XCTUnwrap(entry.audioFile)
            XCTAssertTrue(FileManager.default.fileExists(atPath: app.podcast.store.audioURL(file, digestID: digest.id).path))
        }
        // Saved: a relaunch finds it.
        XCTAssertEqual(app.podcast.store.load(digestID: digest.id)?.readyCount, 4)
    }

    func testTheDailyPodcastIsMadeOnlyWhenTurnedOnAndNeverAsks() async throws {
        let harness = makeHarness()
        let app = harness.app
        connect(app)
        var key = app.settings.configuration(for: .gemini)
        key.apiKey = "gemini-key"
        app.setConfiguration(key, for: .gemini)
        let digest = completeDigest(cards: 1)
        app.digests = [digest]
        let engine = FakeSpeechEngine()
        var kinds: [PodcastEngineKind] = []
        app.podcast.makeEngine = { kind, _, _ in kinds.append(kind); return engine }
        harness.ai.answers = [#"{"turns":[{"speaker":"A","text":"Hi."},{"speaker":"B","text":"Hello."}]}"#]

        app.podcast.digestCompleted(digest.id)
        app.podcast.resumeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(app.podcast.episode, "off by default")
        XCTAssertTrue(harness.ai.calls.isEmpty)

        app.settings.podcastDailyEnabled = true
        app.podcast.digestCompleted(digest.id)
        try await waitUntil { app.podcast.episode?.isComplete == true }
        XCTAssertNil(app.podcast.consentProvider, "the daily run never asks")
        XCTAssertEqual(kinds, [.onDevice], "a key without consent: the device's voices")

        // A tap asks for consent first; Agree records it on this device.
        app.podcast.remake()
        XCTAssertEqual(app.podcast.consentProvider, .aiStudio)
        app.podcast.agree(.aiStudio)
        XCTAssertNotNil(app.settings.podcastConsent["aistudio"])
        XCTAssertTrue(app.settings.voiceConsent.isEmpty, "voice consent is separate")
        try await waitUntil { app.podcast.episode?.isComplete == true }
        XCTAssertEqual(kinds.last, .aiStudio)
    }

    func testTheDailyPodcastStartsRightAfterTheDigestFinishesOnOpen() async throws {
        let harness = makeHarness()
        let app = harness.app
        connect(app)
        app.settings.podcastDailyEnabled = true
        // Today's card reuses an earlier digest's summary of the same posts:
        // the digest finishes with no AI call and no forum request.
        var earlier = completeDigest(cards: 1)
        earlier.day = "2026-10-01"
        var waiting = card("101")
        waiting.summary = ""
        waiting.state = .pending
        let today = DailyDigest(day: DailyDigest.dayKey(for: Date()), cards: [waiting])
        app.digests = [today, earlier]
        let engine = FakeSpeechEngine()
        app.podcast.makeEngine = { _, _, _ in engine }
        harness.ai.answers = [#"{"turns":[{"speaker":"A","text":"Hi."},{"speaker":"B","text":"Hello."}]}"#]

        app.makeTodaysDigest()
        try await waitUntil { app.podcast.episode?.isComplete == true }
        XCTAssertEqual(app.todaysDigest?.isComplete, true)
        XCTAssertEqual(app.podcast.episode?.digestID, today.id)
        XCTAssertEqual(engine.spoken.count, 3)
    }

    func testTopicTitlesAreSaidWithoutCodeLinksOrBrackets() {
        var card = card("6")
        card.title = "[Solved] `max_velocity` error after https://example.com/update"
        let intro = PodcastScript.introTurns(hosts: PodcastHosts(a: "Ava", b: "Leo"), firstTitle: PodcastScript.spokenTitle(card.title), date: Date())
        for turn in intro + PodcastScript.fallbackTurns(for: card) {
            XCTAssertNil(PodcastSpeechCheck.problem(in: turn.text), turn.text)
        }
        let content = PodcastPrompt.content(for: .init(card: card, forumName: "Example", index: 1, count: 1, previousTitle: nil, topicText: ""))
        XCTAssertTrue(content.contains("Topic: Solved error after"), content)
    }

    func testAFailedReadAloudLeavesNothingLoadedSoTheNextTapTriesAgain() async throws {
        let harness = makeHarness()
        let app = harness.app
        let engine = FailingSpeechEngine()
        app.podcast.makeEngine = { _, _, _ in engine }
        app.settings.podcast.engine = .onDevice

        app.podcast.readAloud(id: "summary-1", title: "Topic", text: "A short summary. It has two sentences.")
        XCTAssertEqual(app.podcast.readAloudID, "summary-1")
        try await waitUntil { app.podcast.player.playlist == nil }
        XCTAssertNil(app.podcast.readAloudID)
        XCTAssertNotNil(app.podcast.lastError)
        app.podcast.readAloud(id: "summary-1", title: "Topic", text: "A short summary. It has two sentences.")
        try await waitUntil { engine.attempts == 2 }
    }

    func testEpisodesGoWithTheirDigestAndAfterSevenDays() throws {
        let folder = temporaryFolder()
        let store = PodcastStore(directory: folder)
        let kept = UUID(), orphan = UUID(), old = UUID()
        for id in [kept, orphan, old] {
            store.save(PodcastEpisode(digestID: id, day: "2026-10-20", createdAt: id == old ? Date().addingTimeInterval(-8 * 86_400) : Date(),
                                      title: "T", language: "en", hosts: PodcastHosts(a: "A", b: "B"), engine: .onDevice,
                                      minutesPerChapter: 1, entries: []))
        }
        let deleted = store.reconcile(keeping: [kept, old])
        XCTAssertEqual(Set(deleted), [orphan, old])
        XCTAssertNotNil(store.load(digestID: kept))
        XCTAssertNil(store.load(digestID: orphan))

        // A chapter whose file iOS purged is spoken again.
        var episode = try XCTUnwrap(store.load(digestID: kept))
        episode.entries = [PodcastEpisode.Entry(chapter: .intro(title: "Hi"), audioFile: "chapter-1.wav", duration: 3, state: .ready)]
        store.save(episode)
        XCTAssertEqual(store.load(digestID: kept)?.entries.first?.state, .pending)
    }

    func testDeletingADigestOrAllDigestsDeletesTheirPodcasts() async throws {
        let harness = makeHarness()
        let app = harness.app
        connect(app)
        let today = completeDigest(cards: 1)
        var earlier = completeDigest(cards: 1)
        earlier.day = "2026-10-01"
        app.digests = [today, earlier]
        app.podcast.makeEngine = { _, _, _ in FakeSpeechEngine() }
        harness.ai.answers = [#"{"turns":[{"speaker":"A","text":"Hi."},{"speaker":"B","text":"Hello."}]}"#]
        app.podcast.make()
        try await waitUntil { app.podcast.episode?.isComplete == true }
        // An earlier digest's episode, made on its day.
        let store = app.podcast.store
        store.save(PodcastEpisode(digestID: earlier.id, day: earlier.day, title: "T", language: "en", hosts: PodcastHosts(a: "A", b: "B"),
                                  engine: .onDevice, minutesPerChapter: 1, entries: []))
        app.podcast.playEpisode()
        XCTAssertEqual(app.podcast.player.playlist?.id, today.id.uuidString)

        app.deleteDigest(id: earlier.id)
        XCTAssertNil(store.load(digestID: earlier.id))
        XCTAssertNotNil(store.load(digestID: today.id))

        // Made again: a new digest id, so the old episode goes and stops playing.
        app.deleteAllDigests()
        XCTAssertNil(store.load(digestID: today.id))
        XCTAssertNil(app.podcast.episode)
        XCTAssertNil(app.podcast.player.playlist)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.folder(for: today.id).path))
    }

    // MARK: Helpers

    private var isEnglish: Bool { AppLanguage.current == "en" }

    private func card(_ id: String, firstNew: Int? = nil, answer: Int? = nil) -> DigestCard {
        var card = DigestCard(
            siteURL: site, topicID: id, title: "Topic \(id)", slug: "topic-\(id)",
            reason: firstNew.map { _ in .newReplies(7) } ?? .trending, postCount: 12,
            firstNewPost: firstNew, acceptedAnswerPost: answer
        )
        card.summary = "People discuss topic \(id); the original poster found a workaround."
        card.state = .done
        return card
    }

    private func grounding(_ card: DigestCard) -> String {
        PodcastPrompt.content(for: .init(card: card, forumName: "Example", index: 1, count: 1, previousTitle: nil, topicText: ""))
    }

    private func completeDigest(cards: Int) -> DailyDigest {
        var digest = DailyDigest(day: DailyDigest.dayKey(for: Date()), cards: (1...cards).map { card("\($0 + 100)") })
        digest.completedAt = Date()
        return digest
    }

    private static func playlist(durations: [TimeInterval?]) -> PodcastPlaylist {
        PodcastPlaylist(id: "episode", title: "Today", items: durations.enumerated().map { index, duration in
            PodcastPlaylist.Item(id: "\(index)", title: "Chapter \(index)", url: duration.map { _ in URL(fileURLWithPath: "/tmp/\(index).wav") }, duration: duration)
        })
    }

    private static func response(parts: [(String, Data)]) -> Data {
        let encoded = parts.map { #"{"inlineData":{"mimeType":"\#($0.0)","data":"\#($0.1.base64EncodedString())"}}"# }
        return Data(#"{"candidates":[{"content":{"role":"model","parts":[\#(encoded.joined(separator: ","))]},"finishReason":"STOP"}]}"#.utf8)
    }

    private func temporaryFolder() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private struct Harness {
        let app: AppModel
        let ai: PodcastAIStub
    }

    private func makeHarness() -> Harness {
        let folder = temporaryFolder()
        let store = PersistentStore(fileURL: folder.appendingPathComponent("state.json"), keys: InMemoryProviderKeyStore())
        let ai = PodcastAIStub()
        let app = AppModel(
            store: store,
            aiService: ai,
            backgroundScheduler: FakeTaskScheduler(),
            podcastDirectory: folder.appendingPathComponent("Podcasts", isDirectory: true)
        )
        app.usesDirectForumRequests = true
        app.browser.onPageContextChanged = nil
        addTeardownBlock { @MainActor in
            app.podcast.pauseGeneration()
            app.podcast.player.unload()
        }
        return Harness(app: app, ai: ai)
    }

    private func connect(_ app: AppModel) {
        var configuration = app.settings.configuration(for: .openAI)
        configuration.apiKey = "key"
        app.setConfiguration(configuration, for: .openAI)
        app.selectModel(ModelSelection(provider: .openAI, model: "gpt-test"), for: .both)
        app.settings.hasCompletedOnboarding = true
    }

    private func waitUntil(timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("Timed out waiting", file: file, line: line)
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

// MARK: - Fakes

/// Answers `complete` from a list (the last one repeats) and records calls.
final class PodcastAIStub: AIService {
    struct Call {
        var system: String
        var messages: [ChatMessage]
    }

    @MainActor var answers: [String] = []
    @MainActor var calls: [Call] = []

    init() {
        super.init(session: .shared)
    }

    override func complete(system: String, messages: [ChatMessage], configuration: ProviderConfiguration, provider: AIProvider, maxTokens: Int = 4_096) async throws -> String {
        await MainActor.run {
            calls.append(Call(system: system, messages: messages))
            let index = min(calls.count - 1, answers.count - 1)
            return index >= 0 ? answers[index] : ""
        }
    }

    override func streamText(system: String, messages: [ChatMessage], configuration: ProviderConfiguration, provider: AIProvider, maxTokens: Int = 16_384, onDelta: @escaping @MainActor (String) -> Void) async throws -> String {
        XCTFail("no streamed request in podcast tests")
        throw AssistantError.emptyResponse
    }
}

@MainActor
final class FakeSpeechEngine: PodcastSpeechEngine {
    private(set) var spoken: [[PodcastTurn]] = []
    var fileExtension: String { "wav" }

    func synthesize(_ turns: [PodcastTurn], to url: URL) async throws -> TimeInterval {
        spoken.append(turns)
        try WAVFile.data(PCMAudio(samples: Data(count: 1_600), sampleRate: 8_000)).write(to: url)
        return 0.1
    }
}

@MainActor
final class FailingSpeechEngine: PodcastSpeechEngine {
    private(set) var attempts = 0
    var fileExtension: String { "wav" }

    func synthesize(_ turns: [PodcastTurn], to url: URL) async throws -> TimeInterval {
        attempts += 1
        throw PodcastSpeechError.http(400, "Invalid voice")
    }
}

@MainActor
final class FakePodcastAudio: PodcastAudioPlayback {
    private(set) var loaded: [URL] = []
    private(set) var isPlaying = false
    var currentTime: TimeInterval = 0
    var onFinish: (() -> Void)?

    func load(_ url: URL) throws -> TimeInterval {
        loaded.append(url)
        currentTime = 0
        return 10
    }

    func play() { isPlaying = true }
    func pause() { isPlaying = false }
    func stop() { isPlaying = false }

    /// The loaded file played to its end.
    func finish() {
        isPlaying = false
        onFinish?()
    }
}

@MainActor
final class FakePodcastSession: PodcastAudioSessioning {
    private(set) var activations = 0
    var handsFree = false

    func activateForPlayback() throws { activations += 1 }
    func deactivate() {}
    var routeIsHandsFree: Bool { handsFree }
}

@MainActor
final class FakeVoiceStarter: PodcastVoiceStarting {
    var isActive = false
    var onFinished: (() -> Void)?
    private(set) var starts = 0

    func start() { starts += 1 }

    func finish() {
        let callback = onFinished
        onFinished = nil
        callback?()
    }
}

/// Google's TTS endpoint in a box: answers with queued responses.
final class TTSStub: URLProtocol {
    nonisolated(unsafe) static var responses: [(Int, Data)] = []
    nonisolated(unsafe) static var requests: [URLRequest] = []

    static func reset() {
        responses = []
        requests = []
    }

    static var session: URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TTSStub.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests.append(request)
        let (status, body) = Self.responses.isEmpty ? (500, Data()) : Self.responses.removeFirst()
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
