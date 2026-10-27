import XCTest
@testable import Forumind

/// The voice session with a fake transport, fake audio and a manual clock:
/// the tool-response hold, scheduling, briefings, silent notes, grounding,
/// resumption and refresh, stalls, idle, consent, mute and comfort noise,
/// typed input and the cost guard.
@MainActor
final class VoiceSessionTests: XCTestCase {
    private var transports: [FakeLiveTransport] = []
    private var audio = FakeVoiceAudio()
    private var clock = ManualVoiceClock()
    private var navigator = FakeVoiceNavigator()

    override func setUp() async throws {
        transports = []
        audio = FakeVoiceAudio()
        clock = ManualVoiceClock()
        navigator = FakeVoiceNavigator()
    }

    // MARK: Start and consent

    func testStartIsBlockedWithoutConsent() async {
        let session = makeSession(consent: false)
        await session.start()
        XCTAssertEqual(session.state, .failed(.noConsent))
        XCTAssertTrue(transports.isEmpty, "Nothing connects before consent")

        let keyless = makeSession(key: "")
        await keyless.start()
        XCTAssertEqual(keyless.state, .failed(.noKey))
    }

    func testStartSendsTheSetupAndSeedsTheContext() async throws {
        navigator.pageContext = FakeVoiceNavigator.topicPage(post: 3, visible: [3, 4])
        navigator.brief = brief()
        navigator.visible = [VisiblePost(number: 3, username: "bob", excerpt: "Try the quiet profile. It helps.")]
        let session = try await started()
        XCTAssertEqual(transports.count, 1)
        XCTAssertEqual(transports[0].requests.first?.value(forHTTPHeaderField: "x-goog-api-key"), "test-key")
        XCTAssertEqual(transports[0].messages.first, .setup(model: "models/gemini-3.8-live", handle: nil))
        XCTAssertEqual(session.state, .listening)
        await settle()
        let notes = transports[0].messages.compactMap(\.noteText).joined(separator: "\n")
        XCTAssertTrue(notes.hasPrefix("[Screen: the user opened the topic “Fan noise after the update” on Example."), notes)
        XCTAssertTrue(notes.contains("Accepted answer: post 3 by bob."), notes)
        XCTAssertTrue(notes.contains("At Post 3 of 9 by bob."), notes)
        XCTAssertFalse(transports[0].messages.contains { $0.turnText != nil }, "Notes never ask for a reply")
    }

    // MARK: Tool responses

    func testToolResponseWaitsForTheCallsTurnComplete() async throws {
        let session = try await started()
        session.receive(frame(#"{"toolCall":{"functionCalls":[{"id":"call_1","name":"move","args":{"action":"next"}}]}}"#))
        await settle()
        XCTAssertEqual(navigator.calls.last, "next")
        XCTAssertFalse(sent().contains { $0.isToolResponse }, "Held until the call's turn completes")
        XCTAssertEqual(session.state, .listening)
        session.receive(frame(#"{"serverContent":{"generationComplete":true,"turnComplete":true}}"#))
        XCTAssertEqual(sent().last, .toolResponse(id: "call_1", name: "move", scheduling: "WHEN_IDLE"))
        XCTAssertEqual(session.state, .thinking, "The result's answer is owed")
    }

    func testToolResponseHoldIsCappedAtOneAndAHalfSeconds() async throws {
        let session = try await started()
        session.receive(frame(#"{"toolCall":{"functionCalls":[{"id":"call_2","name":"read","args":{}}]}}"#))
        await settle()
        clock.advance(1.0)
        session.tick()
        XCTAssertFalse(sent().contains { $0.isToolResponse })
        clock.advance(0.5)
        session.tick()
        XCTAssertEqual(sent().last, .toolResponse(id: "call_2", name: "read", scheduling: "WHEN_IDLE"))
    }

    func testCancelledCallsAreNotAnswered() async throws {
        let session = try await started()
        session.receive(frame(#"{"toolCall":{"functionCalls":[{"id":"call_3","name":"find","args":{"query":"fan"}}]}}"#))
        await settle()
        session.receive(frame(#"{"toolCallCancellation":{"ids":["call_3"]}}"#))
        session.receive(frame(#"{"serverContent":{"turnComplete":true}}"#))
        XCTAssertFalse(sent().contains { $0.isToolResponse })
    }

    func testInterruptIsDowngradedWhileSpeakingOrPlaying() async throws {
        let session = try await started()
        XCTAssertEqual(session.downgraded(.interrupt), .interrupt)
        audio.isPlaying = true
        XCTAssertEqual(session.downgraded(.interrupt), .whenIdle, "Queued playback counts as speaking")
        XCTAssertEqual(session.downgraded(.silent), .silent)
        session.brief(VoiceBriefing(kind: .context, facts: ["facts": "x"], scheduling: .interrupt))
        XCTAssertEqual(sent().last, .toolResponse(id: "b-1", name: "briefing", scheduling: "WHEN_IDLE"))
        audio.isPlaying = false
        session.receive(audioFrame())
        XCTAssertEqual(session.downgraded(.interrupt), .whenIdle, "The model's own audio counts too")
        session.receive(frame(#"{"serverContent":{"turnComplete":true}}"#))
        XCTAssertEqual(session.downgraded(.interrupt), .interrupt)
    }

    func testBriefingsUseMadeUpIDsAndWaitForTheConnection() async throws {
        let session = makeSession()
        await session.start()
        session.brief(VoiceBriefing(kind: .context, facts: ["facts": "early"], scheduling: .silent))
        XCTAssertFalse(sent().contains { $0.isToolResponse }, "Queued until setup completes")
        session.receive(frame(#"{"setupComplete":{}}"#))
        session.brief(VoiceBriefing(kind: .context, facts: ["facts": "later"], scheduling: .whenIdle))
        let responses = sent().filter(\.isToolResponse)
        XCTAssertEqual(responses, [
            .toolResponse(id: "b-1", name: "briefing", scheduling: "SILENT"),
            .toolResponse(id: "b-2", name: "briefing", scheduling: "WHEN_IDLE")
        ])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(transports[0].sent.last!.utf8)) as? [String: Any])
        let response = (((object["toolResponse"] as? [String: Any])?["functionResponses"] as? [[String: Any]])?.first)?["response"] as? [String: Any]
        XCTAssertEqual(response?["facts"] as? String, "later")
        XCTAssertTrue((response?["about_this"] as? String)?.hasPrefix("Not the user speaking") ?? false)
    }

    // MARK: Research

    func testResearchStartsProgressesAndBriefsTheAnswer() async throws {
        navigator.holdsResearch = true
        let session = try await started()
        session.tools.progressInterval = .milliseconds(10)
        session.receive(frame(#"{"toolCall":{"functionCalls":[{"id":"call_r","name":"research","args":{"request":"what are the main objections"}}]}}"#))
        await settle()
        session.receive(frame(#"{"serverContent":{"turnComplete":true}}"#))
        XCTAssertEqual(sent().last, .toolResponse(id: "call_r", name: "research", scheduling: "SILENT"), "started, at once")

        navigator.researchProgress = "Step 2, read_topic 42"
        try await waitUntil { self.sent().contains(.toolResponse(id: "b-1", name: "briefing", scheduling: "SILENT")) }

        navigator.releaseResearch()
        try await waitUntil { self.sent().contains(.toolResponse(id: "b-2", name: "briefing", scheduling: "WHEN_IDLE")) }
        let answer = try lastResponse()
        XCTAssertEqual(answer["kind"] as? String, "research answer")
        XCTAssertEqual(answer["content"] as? String, "Lower the fan curve in the quiet profile.")
        XCTAssertTrue((answer["message"] as? String)?.contains("about two sentences") ?? false)
        XCTAssertTrue((answer["message"] as? String)?.contains("sources are on screen") ?? false)
    }

    func testANewResearchCancelsTheOldAndCancelStopsIt() async throws {
        navigator.holdsResearch = true
        let session = try await started()
        session.tools.progressInterval = .seconds(60)
        for (id, question) in [("call_a", "first question"), ("call_b", "second question")] {
            session.receive(frame(#"{"toolCall":{"functionCalls":[{"id":"\#(id)","name":"research","args":{"request":"\#(question)"}}]}}"#))
            await settle()
            session.receive(frame(#"{"serverContent":{"turnComplete":true}}"#))
        }
        await settle()
        XCTAssertEqual(navigator.calls.filter { $0.hasPrefix("research") }, ["research first question", "research second question"])
        XCTAssertFalse(sent().contains { if case .toolResponse(_, "briefing", _) = $0 { return true }; return false },
                       "The replaced research briefs nothing")

        session.receive(frame(#"{"toolCall":{"functionCalls":[{"id":"call_c","name":"research","args":{"action":"cancel"}}]}}"#))
        await settle()
        session.receive(frame(#"{"serverContent":{"turnComplete":true}}"#))
        XCTAssertEqual(navigator.calls.last, "cancel research")
        XCTAssertEqual(try lastResponse()["status"] as? String, "cancelled")
        await settle()
        XCTAssertFalse(sent().contains { if case .toolResponse(_, "briefing", _) = $0 { return true }; return false })
    }

    func testUnacknowledgedResearchGetsANudgeAndAnUnspokenAnswerIsResent() async throws {
        navigator.holdsResearch = true
        let session = try await started()
        session.tools.progressInterval = .seconds(60)
        session.receive(frame(#"{"toolCall":{"functionCalls":[{"id":"call_r","name":"research","args":{"request":"why"}}]}}"#))
        await settle()
        session.receive(frame(#"{"serverContent":{"turnComplete":true}}"#))
        clock.advance(1.6)
        session.tick()
        XCTAssertEqual(sent().last?.turnText, VoiceWatchdog.acknowledgementPrompt)

        session.receive(audioFrame())
        session.receive(frame(#"{"serverContent":{"turnComplete":true}}"#))
        navigator.releaseResearch()
        try await waitUntil { self.sent().contains(.toolResponse(id: "b-1", name: "briefing", scheduling: "WHEN_IDLE")) }
        clock.advance(5)
        session.tick()
        XCTAssertNil(sent().last?.turnText)
        clock.advance(1.1)
        session.tick()
        XCTAssertTrue(sent().last?.turnText?.contains("Lower the fan curve") ?? false, "\(String(describing: sent().last))")
    }

    func testToolMarkupSpokenAsTextIsCutAndCorrected() async throws {
        let session = try await started()
        session.receive(frame(#"{"serverContent":{"outputTranscription":{"text":"Sure. <tool_call>find(query"}}}"#))
        XCTAssertEqual(audio.flushes, 1)
        XCTAssertEqual(session.lastModelText, "Sure.")
        session.receive(audioFrame())
        XCTAssertTrue(audio.played.isEmpty, "The rest of the turn is dropped")
        session.receive(frame(#"{"serverContent":{"turnComplete":true}}"#))
        XCTAssertEqual(sent().last?.turnText, VoiceWatchdog.markupCorrection)
    }

    // MARK: Silent notes and grounding

    func testNotesWaitForQuietAndSendOnlyTheChange() async throws {
        navigator.pageContext = FakeVoiceNavigator.topicPage(post: 3, visible: [3])
        navigator.brief = brief()
        navigator.visible = [VisiblePost(number: 3, username: "bob", excerpt: "Try the quiet profile.")]
        let session = try await started()
        await settle()
        let before = sent().compactMap(\.noteText).count

        // The model speaks: the next note waits.
        session.receive(audioFrame())
        navigator.pageContext = FakeVoiceNavigator.topicPage(post: 4, visible: [4])
        navigator.visible = [VisiblePost(number: 4, username: "carol", excerpt: "Mine is louder after the update.")]
        session.pageChanged(navigator.pageContext)
        await settle()
        XCTAssertEqual(sent().compactMap(\.noteText).count, before)
        session.receive(frame(#"{"serverContent":{"turnComplete":true}}"#))
        session.tick()
        let delta = try XCTUnwrap(sent().compactMap(\.noteText).last)
        XCTAssertTrue(delta.contains("At Post 4 of 9 by carol."), delta)
        XCTAssertFalse(delta.contains("opened the topic"), "The brief isn't sent again")

        // Nothing changed: no note.
        session.pageChanged(navigator.pageContext)
        await settle()
        session.tick()
        XCTAssertEqual(sent().compactMap(\.noteText).count, before + 1)
    }

    func testScreenReferenceSendsTheFocusedPostBeforeTheAnswer() async throws {
        for words in ["Is this post right?", "他说的对吗", "這一樓在說什麼"] {
            transports = []
            navigator = FakeVoiceNavigator()
            navigator.pageContext = FakeVoiceNavigator.topicPage(post: 5)
            let session = try await started()
            await settle()
            session.captureGate(open: true)
            session.receive(frame(#"{"serverContent":{"inputTranscription":{"text":"\#(words)"}}}"#))
            await settle()
            XCTAssertEqual(navigator.calls.filter { $0.hasPrefix("read") }, ["read 5"], words)
            let note = try XCTUnwrap(sent().compactMap(\.noteText).last, words)
            XCTAssertTrue(note.hasPrefix("[Screen: full text of Post 5"), note)
            // Once per post.
            session.receive(frame(#"{"serverContent":{"inputTranscription":{"text":" this one"}}}"#))
            await settle()
            XCTAssertEqual(navigator.calls.filter { $0.hasPrefix("read") }.count, 1)
            session.stop()
        }
        XCTAssertFalse(VoiceContext.refersToScreen("Find posts about fan noise"))
        XCTAssertFalse(VoiceContext.refersToScreen("thispostman"), "Whole words in English")
    }

    func testGroundingSwitchesTurnItOff() async throws {
        var settings = VoiceSettings()
        settings.groundsOnScreenReference = false
        settings.groundsOnDwell = false
        navigator.pageContext = FakeVoiceNavigator.topicPage(post: 5)
        let session = try await started(settings: settings)
        session.receive(frame(#"{"serverContent":{"inputTranscription":{"text":"what did he say"}}}"#))
        session.pageChanged(navigator.pageContext)
        clock.advance(3)
        session.tick()
        await settle()
        XCTAssertFalse(navigator.calls.contains { $0.hasPrefix("read") })
    }

    func testDwellingOnAPostSendsItsText() async throws {
        navigator.pageContext = FakeVoiceNavigator.topicPage(post: 6)
        let session = try await started()
        session.pageChanged(navigator.pageContext)
        await settle()
        clock.advance(1)
        session.tick()
        XCTAssertFalse(navigator.calls.contains { $0.hasPrefix("read") })
        clock.advance(1.1)
        session.tick()
        await settle()
        session.tick()
        XCTAssertEqual(navigator.calls.filter { $0.hasPrefix("read") }, ["read 6"])
        XCTAssertTrue(sent().compactMap(\.noteText).last?.contains("full text of Post 6") ?? false)
    }

    // MARK: Resumption

    func testAIStudioResumesWithTheHandleAfterClosingAndResendsTheContext() async throws {
        navigator.pageContext = FakeVoiceNavigator.topicPage(post: 3)
        navigator.brief = brief()
        let session = try await started()
        await settle()
        session.receive(frame(#"{"sessionResumptionUpdate":{"newHandle":"h-1","resumable":true}}"#))
        session.receive(frame(#"{"sessionResumptionUpdate":{"resumable":false}}"#))
        XCTAssertEqual(session.resumptionHandle, "h-1", "A non-resumable update keeps the last handle")

        session.receive(frame(#"{"goAway":{"timeLeft":"50s"}}"#))
        session.tick()
        try await waitForTransports(2)
        XCTAssertEqual(transports.count, 2)
        XCTAssertTrue(transports[0].closed, "Close before resume: AI Studio allows one connection")
        XCTAssertEqual(transports[1].messages.first, .setup(model: "models/gemini-3.8-live", handle: "h-1"))
        session.receive(frame(#"{"setupComplete":{}}"#))
        let notes = transports[1].messages.compactMap(\.noteText)
        XCTAssertTrue(notes.first?.contains("opened the topic") ?? false, "The whole context again: \(notes)")
    }

    func testAIStudioRefreshesFreshBeforeTheHourAndAfterAGoAwayPastIt() async throws {
        let session = try await started(settings: longIdle)
        session.receive(frame(#"{"sessionResumptionUpdate":{"newHandle":"h-1","resumable":true}}"#))
        clock.advance(53 * 60)
        session.tick()
        XCTAssertEqual(transports.count, 1)
        clock.advance(60)
        session.tick()
        try await waitForTransports(2)
        XCTAssertEqual(transports.count, 2)
        XCTAssertEqual(transports[1].messages.first, .setup(model: "models/gemini-3.8-live", handle: nil), "A fresh session")
        XCTAssertTrue(transports[0].closed)
        session.receive(frame(#"{"setupComplete":{}}"#))
        XCTAssertNil(session.handleForReconnect(.goAway))

        // A GoAway past the age opens a fresh session too.
        session.receive(frame(#"{"sessionResumptionUpdate":{"newHandle":"h-2","resumable":true}}"#))
        XCTAssertEqual(session.handleForReconnect(.goAway), "h-2")
        clock.advance(55 * 60)
        XCTAssertNil(session.handleForReconnect(.goAway))
    }

    func testVertexNeverResumesAResumedSession() async throws {
        let session = try await started(endpoint: .vertex(project: "p", location: "us-central1"), settings: longIdle)
        let model = "projects/p/locations/us-central1/publishers/google/models/gemini-3.8-live"
        session.receive(frame(#"{"sessionResumptionUpdate":{"newHandle":"v-0","resumable":true}}"#))
        transports[0].drop()
        try await waitForTransports(2)
        XCTAssertEqual(transports[1].messages.first, .setup(model: model, handle: "v-0"))
        session.receive(frame(#"{"setupComplete":{}}"#))
        XCTAssertEqual(session.connectionGeneration, 1)
        // A handle from the resumed connection is never used, and the
        // generation-0 one no longer covers this connection's turns.
        session.receive(frame(#"{"sessionResumptionUpdate":{"newHandle":"v-1","resumable":true}}"#))
        XCTAssertNil(session.resumptionHandle)
        transports[1].drop()
        try await waitForTransports(3)
        XCTAssertEqual(transports[2].messages.first, .setup(model: model, handle: nil), "Fresh, seeded with the context")
        // No 54-minute refresh on Vertex.
        session.receive(frame(#"{"setupComplete":{}}"#))
        clock.advance(70 * 60)
        session.receive(frame("{}"))
        session.tick()
        XCTAssertEqual(transports.count, 3)
    }

    func testAnExpiredSessionStartsFreshAndARefusalFails() async throws {
        let session = try await started()
        session.receive(frame(#"{"sessionResumptionUpdate":{"newHandle":"h-1","resumable":true}}"#))
        transports[0].drop(LiveClose(code: 1008, reason: "Requested entity was not found."))
        try await waitForTransports(2)
        XCTAssertEqual(transports[1].messages.first, .setup(model: "models/gemini-3.8-live", handle: nil))
        session.receive(frame(#"{"setupComplete":{}}"#))

        let refused = makeSession()
        await refused.start()
        transports.last?.drop(LiveClose(code: 1008, reason: "API keys are not supported by this API."))
        try await waitUntil { refused.state == .failed(.refused("API keys are not supported by this API.")) }
        XCTAssertEqual(refused.state, .failed(.refused("API keys are not supported by this API.")))
    }

    func testStalledTurnRecyclesTheConnectionWithTheHandle() async throws {
        let session = try await started()
        session.receive(frame(#"{"sessionResumptionUpdate":{"newHandle":"h-1","resumable":true}}"#))
        session.captureGate(open: true)
        session.microphoneFrame(Data(repeating: 1, count: 1280))
        session.receive(frame(#"{"serverContent":{"inputTranscription":{"text":"next one"}}}"#))
        session.captureGate(open: false)
        clock.advance(1.0)
        session.tick()
        XCTAssertEqual(sent().last, .audioStreamEnd)
        XCTAssertEqual(session.state, .thinking)
        clock.advance(9)
        session.tick()
        XCTAssertEqual(transports.count, 1)
        clock.advance(1.1)
        session.tick()
        try await waitForTransports(2)
        XCTAssertEqual(transports.count, 2)
        XCTAssertEqual(transports[1].messages.first, .setup(model: "models/gemini-3.8-live", handle: "h-1"))
    }

    func testNoiseWithoutWordsIsNoStall() async throws {
        let session = try await started()
        session.captureGate(open: true)
        session.microphoneFrame(Data(repeating: 1, count: 1280))
        session.captureGate(open: false)
        clock.advance(1.0)
        session.tick()
        XCTAssertEqual(sent().last, .audioStreamEnd)
        XCTAssertEqual(session.state, .listening, "A cough owes no reply")
        session.queueNote("[Screen: x]")
        XCTAssertEqual(sent().last?.noteText, "[Screen: x]", "Quiet again: notes flow")
        clock.advance(11)
        session.tick()
        XCTAssertEqual(transports.count, 1)

        // Words transcribed after the stream ended: now a reply is owed.
        session.receive(frame(#"{"serverContent":{"inputTranscription":{"text":"go back"}}}"#))
        XCTAssertEqual(session.state, .thinking)
    }

    func testAFailedGroundingReadIsRetried() async throws {
        navigator.pageContext = FakeVoiceNavigator.topicPage(post: 5)
        navigator.results["read"] = BrowseResult(status: .notFound, shown: "Post 5 couldn't be read.")
        let session = try await started()
        session.receive(frame(#"{"serverContent":{"inputTranscription":{"text":"is this post right"}}}"#))
        await settle()
        navigator.results["read"] = nil
        session.receive(frame(#"{"serverContent":{"turnComplete":true}}"#))
        session.receive(frame(#"{"serverContent":{"inputTranscription":{"text":"what about this one"}}}"#))
        await settle()
        XCTAssertEqual(navigator.calls.filter { $0.hasPrefix("read") }.count, 2)
        XCTAssertTrue(sent().compactMap(\.noteText).last?.contains("full text of Post 5") ?? false)
    }

    // MARK: Idle, end, usage

    func testIdleSessionCloses() async throws {
        var settings = VoiceSettings()
        settings.idleTimeout = 60
        let session = try await started(settings: settings)
        clock.advance(59)
        session.tick()
        XCTAssertEqual(session.state, .listening)
        clock.advance(2)
        session.tick()
        XCTAssertEqual(session.state, .ended(.idle))
        XCTAssertTrue(transports[0].closed)
        XCTAssertTrue(audio.stopped)
        XCTAssertGreaterThan(session.connectedSeconds, 0)
    }

    func testEndToolClosesAfterTheGoodbye() async throws {
        let session = try await started()
        session.receive(frame(#"{"serverContent":{"outputTranscription":{"text":"Bye for now."}}}"#))
        session.receive(frame(#"{"toolCall":{"functionCalls":[{"id":"call_e","name":"end","args":{}}]}}"#))
        await settle()
        session.receive(frame(#"{"serverContent":{"turnComplete":true}}"#))
        XCTAssertEqual(sent().last, .toolResponse(id: "call_e", name: "end", scheduling: "SILENT"))
        audio.isPlaying = true
        clock.advance(1)
        session.tick()
        XCTAssertFalse(session.state.isOver, "The goodbye is still playing")
        audio.isPlaying = false
        session.tick()
        XCTAssertEqual(session.state, .ended(.model))
    }

    func testMinutesAreCountedPerSessionAndPerDay() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "voice-usage-\(UUID().uuidString)"))
        let store = VoiceUsageStore(defaults: defaults)
        let session = try await started(usage: store)
        for _ in 0..<30 {
            clock.advance(2)
            session.tick()
        }
        session.stop()
        XCTAssertEqual(session.connectedSeconds, 60, accuracy: 0.01)
        XCTAssertEqual(store.minutes(on: clock.now), 1, accuracy: 0.01)
        XCTAssertEqual(store.lastSessionSeconds, 60, accuracy: 0.01)
        store.add(seconds: 30, at: clock.now, sessionTotal: 30)
        XCTAssertEqual(store.seconds(on: clock.now), 90, accuracy: 0.01)
        XCTAssertEqual(store.seconds(on: clock.now.addingTimeInterval(-86_400 * 2)), 0)
    }

    // MARK: Cost guard

    func testTheSessionLimitEndsAfterTheCurrentAnswer() async throws {
        var settings = VoiceSettings()
        settings.idleTimeout = 100_000
        settings.sessionLimitMinutes = 5
        let session = try await started(settings: settings)
        for _ in 0..<149 {
            clock.advance(2)
            session.tick()
        }
        XCTAssertEqual(session.state, .listening, "Just under five minutes")
        session.receive(audioFrame())
        audio.isPlaying = true
        clock.advance(2)
        session.tick()
        XCTAssertEqual(session.limitReached, .sessionLimit)
        XCTAssertFalse(session.state.isOver, "The answer that is playing finishes")
        audio.isPlaying = false
        session.receive(frame(#"{"serverContent":{"turnComplete":true}}"#))
        clock.advance(1.1)
        session.tick()
        XCTAssertEqual(session.state, .ended(.sessionLimit))
        XCTAssertTrue(transports[0].closed)
    }

    func testTheDailyLimitRefusesANewSessionAndEndsARunningOne() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "voice-usage-\(UUID().uuidString)"))
        let store = VoiceUsageStore(defaults: defaults)
        var settings = VoiceSettings()
        settings.idleTimeout = 100_000
        settings.dailyLimitMinutes = 30
        settings.sessionLimitMinutes = 0
        store.add(seconds: 29 * 60, at: clock.now, sessionTotal: 0)
        let session = try await started(settings: settings, usage: store)
        for _ in 0..<35 {
            clock.advance(2)
            session.tick()
        }
        XCTAssertEqual(session.state, .ended(.dailyLimit))

        let next = makeSession(settings: settings, usage: store)
        await next.start()
        XCTAssertEqual(next.state, .ended(.dailyLimit))
        XCTAssertEqual(transports.count, 1, "Nothing connects once today's minutes are used")

        settings.dailyLimitMinutes = 0
        let unlimited = makeSession(settings: settings, usage: store)
        await unlimited.start()
        XCTAssertEqual(unlimited.state, .connecting)
    }

    func testLimitsDecodeAndZeroMeansNone() throws {
        XCTAssertEqual(VoiceSettings().sessionLimitMinutes, 15)
        XCTAssertEqual(VoiceSettings().dailyLimitMinutes, 30)
        XCTAssertEqual(VoiceSettings().voiceName, VoiceCatalog.defaultVoice)
        XCTAssertTrue(VoiceCatalog.voices.contains { $0.name == VoiceCatalog.defaultVoice })
        XCTAssertEqual(Set(VoiceCatalog.voices.map(\.name)).count, VoiceCatalog.voices.count)
        let decoded = try JSONDecoder().decode(VoiceSettings.self, from: Data(#"{"sessionLimitMinutes":0,"dailyLimitMinutes":-4}"#.utf8))
        XCTAssertEqual(decoded.sessionLimitMinutes, 0)
        XCTAssertEqual(decoded.dailyLimitMinutes, 0)
        XCTAssertNil(VoiceSettings.limit(0))
        XCTAssertEqual(VoiceSettings.limit(15), 900)
    }

    // MARK: Typed input

    func testTypedTextGoesAsRealtimeTextAndAReplyIsOwed() async throws {
        let session = try await started()
        session.sendText("  take me to the solution ")
        let last = try XCTUnwrap(transports[0].sent.last)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(last.utf8)) as? [String: Any])
        XCTAssertEqual((object["realtimeInput"] as? [String: Any])?["text"] as? String, "take me to the solution")
        XCTAssertEqual(session.lastUserText, "take me to the solution", "No input transcription comes back for text")
        XCTAssertEqual(session.state, .thinking)
        session.receive(frame(#"{"serverContent":{"outputTranscription":{"text":"Opening it."}}}"#))
        XCTAssertEqual(session.lastModelText, "Opening it.")
        session.sendText("   ")
        XCTAssertEqual(transports[0].sent.last, last, "Blank text is not sent")
    }

    func testATypedScreenReferenceReadsTheFocusedPost() async throws {
        navigator.pageContext = FakeVoiceNavigator.topicPage(post: 3, visible: [3])
        let session = try await started()
        await settle()
        session.sendText("is this post right?")
        await settle()
        XCTAssertTrue(navigator.calls.contains("read 3"), "\(navigator.calls)")
    }

    // MARK: Audio

    func testMuteSendsNothing() async throws {
        let session = try await started()
        session.setMuted(true)
        session.captureGate(open: true)
        session.microphoneFrame(Data(repeating: 1, count: 1280))
        session.captureGate(open: false)
        clock.advance(2)
        session.tick()
        XCTAssertFalse(sent().contains { $0.isAudio || $0 == .audioStreamEnd })

        // Muting mid-utterance ends the turn at once, without noise.
        session.setMuted(false)
        session.captureGate(open: true)
        session.microphoneFrame(Data(repeating: 1, count: 1280))
        session.setMuted(true)
        XCTAssertEqual(sent().suffix(2), [.audio(1280), .audioStreamEnd])
    }

    func testComfortNoiseAtRealTimePaceThenStreamEnd() async throws {
        let session = try await started()
        session.captureGate(open: true)
        session.microphoneFrame(Data(repeating: 1, count: 1280))
        session.captureGate(open: false)
        clock.advance(0.5)
        session.tick()
        let halfway = sent().filter(\.isAudio).count
        XCTAssertEqual(halfway, 1 + 13, "About half a second of 40 ms frames")
        XCTAssertNotEqual(sent().last, .audioStreamEnd)
        clock.advance(0.6)
        session.tick()
        XCTAssertEqual(sent().filter(\.isAudio).count, 1 + 25)
        XCTAssertEqual(sent().last, .audioStreamEnd)
        let noise = ComfortNoise.frame(seed: &seed)
        XCTAssertEqual(noise.count, 1280)
        let samples = noise.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        XCTAssertTrue(samples.allSatisfy { abs($0) <= 8 })
        XCTAssertTrue(samples.contains { $0 != 0 }, "Never zeros")
    }

    func testModelAudioPlaysAndInterruptionFlushes() async throws {
        let session = try await started()
        session.receive(audioFrame())
        XCTAssertEqual(audio.played.count, 1)
        XCTAssertEqual(session.state, .speaking)
        session.receive(frame(#"{"serverContent":{"interrupted":true}}"#))
        XCTAssertEqual(audio.flushes, 1)
        session.receive(frame(#"{"serverContent":{"turnComplete":true}}"#))
        XCTAssertEqual(session.state, .listening)
    }

    // MARK: Helpers

    private var seed: UInt64 = 42

    /// An idle timeout past the hour-long tests.
    private var longIdle: VoiceSettings {
        var settings = VoiceSettings()
        settings.idleTimeout = 100_000
        settings.sessionLimitMinutes = 0
        settings.dailyLimitMinutes = 0
        return settings
    }

    private func makeSession(
        endpoint: GeminiLive.Endpoint = .aiStudio,
        key: String = "test-key",
        consent: Bool = true,
        settings: VoiceSettings = VoiceSettings(),
        usage: VoiceUsageStore? = nil
    ) -> VoiceSession {
        VoiceSession(
            configuration: .init(endpoint: endpoint, apiKey: key, settings: settings, hasConsent: consent),
            transport: { [unowned self] in
                let transport = FakeLiveTransport()
                self.transports.append(transport)
                return transport
            },
            audio: audio,
            navigator: navigator,
            clock: clock,
            usage: usage,
            runsLoop: false
        )
    }

    /// A session past `setupComplete`.
    private func started(
        endpoint: GeminiLive.Endpoint = .aiStudio,
        settings: VoiceSettings = VoiceSettings(),
        usage: VoiceUsageStore? = nil
    ) async throws -> VoiceSession {
        let session = makeSession(endpoint: endpoint, settings: settings, usage: usage)
        await session.start()
        session.receive(frame(#"{"setupComplete":{}}"#))
        XCTAssertEqual(session.state, .listening)
        return session
    }

    private func brief() -> VoiceTopicBrief {
        VoiceTopicBrief(
            topicKey: navigator.pageContext.topic?.topicKey ?? "k",
            title: "Fan noise after the update",
            forumName: "Example",
            opening: "Since the last update the fan is loud. Anyone else?",
            openingPoster: "alice",
            postCount: 9,
            solution: .init(number: 3, username: "bob")
        )
    }

    /// Everything sent on the newest connection.
    private func sent() -> [VoiceSent] {
        transports.last?.messages ?? []
    }

    /// The newest tool response's `response` object.
    private func lastResponse() throws -> [String: Any] {
        let text = try XCTUnwrap(transports.last?.sent.last { $0.contains("toolResponse") })
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let item = (((object["toolResponse"] as? [String: Any])?["functionResponses"] as? [[String: Any]])?.first)
        return try XCTUnwrap(item?["response"] as? [String: Any])
    }

    private func frame(_ text: String) -> Data { Data(text.utf8) }

    private func audioFrame() -> Data {
        frame(#"{"serverContent":{"modelTurn":{"parts":[{"inlineData":{"mimeType":"audio/pcm;rate=24000","data":"AAEC"}}]}}}"#)
    }

    /// Lets the session's tasks run (tool handlers, context reads).
    private func settle() async {
        for _ in 0..<30 { await Task.yield() }
    }

    /// Waits for the session to open its `count`th connection. A reconnect
    /// runs on tasks woken by the old stream ending, so how many yields it
    /// takes depends on the machine; indexing `transports` after a fixed
    /// number of yields crashed on a slow CI runner.
    private func waitForTransports(_ count: Int) async throws {
        try await waitUntil { self.transports.count >= count }
        _ = try XCTUnwrap(transports.count >= count ? true : nil, "No connection \(count)")
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition(), "Timed out")
    }
}
