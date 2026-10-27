import XCTest
@testable import Forumind

/// AI data consent (App Review 5.1.2(i)): nothing reaches a third-party
/// provider before Allow, Don't Allow and Withdraw block with the right
/// state, Apple Intelligence and local servers never ask, and work the app
/// starts by itself never shows the page. Also the AI output report.
@MainActor
final class AIDataConsentTests: XCTestCase {
    private let site = "https://forum.example.com"

    override func setUp() async throws {
        StateForumStub.reset()
        ConsentAIRequestStub.reset()
    }

    // MARK: The backstop

    /// Every AIService path that sends forum content to a third party
    /// (summaries, chat, the agent planner, the digest and podcast through
    /// `complete`) stops before the network until the provider is allowed.
    func testTheBackstopBlocksEveryRequestPathUntilAllow() async throws {
        let app = makeApp(aiService: AIService(session: ConsentAIRequestStub.session()))
        select(app, .openAI, model: "gpt-test", key: "key")
        let configuration = app.settings.configuration(for: .openAI)
        let service = app.aiService

        let paths: [(String, () async throws -> String)] = [
            ("summary", { try await service.generateSummary(content: "Post", configuration: configuration, provider: .openAI, customPrompt: "", onDelta: { _ in }) }),
            ("chat", { try await service.answer(source: "Post", summary: "", history: [ChatMessage(role: .user, content: "Q")], contextLimit: 1_000, customPrompt: "", configuration: configuration, provider: .openAI, onDelta: { _ in }) }),
            ("complete", { try await service.complete(system: "S", messages: [ChatMessage(role: .user, content: "Q")], configuration: configuration, provider: .openAI) }),
            ("planner", {
                let action = try await PromptAgentPlanner(aiService: service).nextAction(
                    system: "S", transcript: [ChatMessage(role: .user, content: "GOAL: q")], configuration: configuration, provider: .openAI
                )
                return action.tool
            })
        ]
        for (name, path) in paths {
            do {
                _ = try await path()
                XCTFail("\(name) went out without consent")
            } catch AssistantError.aiConsentRequired(.openAI) {
            } catch {
                XCTFail("\(name): \(error)")
            }
        }
        XCTAssertEqual(ConsentAIRequestStub.count, 0, "nothing reached the provider")

        app.settings.aiConsent[AIProvider.openAI.rawValue] = .declined(Date())
        do {
            _ = try await service.complete(system: "S", messages: [], configuration: configuration, provider: .openAI)
            XCTFail("declined went out")
        } catch AssistantError.aiConsentDeclined(.openAI) {}
        XCTAssertEqual(ConsentAIRequestStub.count, 0)

        app.settings.aiConsent[AIProvider.openAI.rawValue] = .allowed(Date())
        let text = try await service.complete(system: "S", messages: [ChatMessage(role: .user, content: "Q")], configuration: configuration, provider: .openAI)
        XCTAssertEqual(text, "OK")
        XCTAssertEqual(ConsentAIRequestStub.count, 1)
    }

    /// An AIService nobody configured sends nothing to a third party.
    func testAnUnconfiguredServiceBlocksByDefault() async throws {
        let service = AIService(session: ConsentAIRequestStub.session())
        let configuration = ProviderConfiguration(model: "m", baseURL: "https://api.example.com/v1", apiKey: "k")
        do {
            _ = try await service.complete(system: "S", messages: [], configuration: configuration, provider: .anthropic)
            XCTFail("went out")
        } catch AssistantError.aiConsentRequired(.anthropic) {}
        XCTAssertEqual(ConsentAIRequestStub.count, 0)
    }

    // MARK: The page

    /// A summary on an undecided provider shows the page and waits; Allow
    /// records the date and the summary runs. Two requests share one page.
    func testTheFirstSummaryWaitsForThePageThenRunsOnAllow() async throws {
        let (app, ai) = makeHarness()
        select(app, .openAI, model: "gpt-test", key: "key")

        XCTAssertTrue(app.enqueueSummary(for: topic("1")))
        XCTAssertTrue(app.enqueueSummary(for: topic("2")))
        try await waitUntil { app.aiConsent.asking == .openAI }
        XCTAssertEqual(app.aiConsent.queue, [.openAI], "one page for both")
        XCTAssertEqual(app.rootPresentation, .aiConsent(.openAI))
        XCTAssertTrue(ai.calls.isEmpty)
        XCTAssertTrue(app.activities.first?.statusText.contains("OpenAI") ?? false)

        app.answerAIConsent(.openAI, allow: true)
        app.answerAIConsent(.openAI, allow: true)
        guard case .allowed = app.aiConsentState(for: .openAI) else { return XCTFail("not allowed") }
        XCTAssertNil(app.aiConsent.asking)
        XCTAssertNotEqual(app.rootPresentation, .aiConsent(.openAI))
        try await waitUntil { ai.calls.count == 2 }
        ai.gated = false
        ai.releaseAll()
        try await waitUntil { app.activities.allSatisfy { $0.status == .completed } }
    }

    /// Don't Allow: the waiting summary fails with the blocked state (no
    /// alert), the provider stays configured but reads "Not allowed", and
    /// the next request fails at once without the page. Allow… brings the
    /// page back.
    func testDontAllowBlocksWithTheBlockedState() async throws {
        let (app, ai) = makeHarness()
        select(app, .openAI, model: "gpt-test", key: "key")

        XCTAssertTrue(app.enqueueSummary(for: topic("1")))
        try await waitUntil { app.aiConsent.asking == .openAI }
        app.answerAIConsent(.openAI, allow: false)
        try await waitUntil { app.activities.first?.status == .failed }
        XCTAssertEqual(app.activities.first?.error, AssistantError.aiConsentDeclined(.openAI).localizedDescription)
        XCTAssertNil(app.presentedError)
        XCTAssertEqual(app.readiness(of: app.selection(for: .assistant)), .aiConsentDeclined)
        XCTAssertEqual(ModelSetupAction(.aiConsentDeclined, provider: .openAI), .allow(.openAI))
        XCTAssertEqual(app.settings.configuration(for: .openAI).apiKey, "key", "still configured")

        XCTAssertTrue(app.enqueueSummary(for: topic("2")))
        try await waitUntil { app.activities.filter { $0.status == .failed }.count == 2 }
        XCTAssertNil(app.aiConsent.asking)
        XCTAssertTrue(ai.calls.isEmpty)

        app.aiConsent.ask(.openAI)
        XCTAssertEqual(app.rootPresentation, .aiConsent(.openAI))
        app.answerAIConsent(.openAI, allow: true)
        XCTAssertEqual(app.readiness(of: app.selection(for: .assistant)), .ready)
    }

    /// A shared link or Siri on a declined provider shows the consent page
    /// again, not the key form.
    func testADeclinedProviderAsksAgainInsteadOfTheKeyForm() {
        let (app, _) = makeHarness()
        select(app, .openAI, model: "gpt-test", key: "key")
        app.settings.aiConsent[AIProvider.openAI.rawValue] = .declined(Date())
        app.needsProviderSetup = .assistant
        app.presentProviderSetupIfNeeded()
        XCTAssertNil(app.needsProviderSetup)
        XCTAssertNil(app.router.item)
        XCTAssertEqual(app.rootPresentation, .aiConsent(.openAI))
    }

    func testAppleIntelligenceAndLocalServersNeverAsk() async throws {
        for provider in [AIProvider.appleIntelligence, .ollama, .lmStudio] {
            XCTAssertFalse(provider.requiresDataConsent)
            XCTAssertEqual(AppSettings().aiConsentState(for: provider), .notNeeded)
            XCTAssertNil(AIProviderPolicy.policy(for: provider))
        }
        for provider in AIProvider.allCases where provider.requiresDataConsent {
            XCTAssertNotNil(AIProviderPolicy.policy(for: provider), provider.rawValue)
        }
        let (app, ai) = makeHarness()
        select(app, .ollama, model: "llama")
        ai.gated = false
        XCTAssertTrue(app.enqueueSummary(for: topic("1")))
        try await waitUntil { app.activities.first?.status == .completed }
        XCTAssertNil(app.aiConsent.asking)
        XCTAssertEqual(ai.calls.count, 1)
    }

    /// Withdraw: running work on that provider is cancelled and new work is
    /// blocked again.
    func testWithdrawCancelsRunningWorkAndBlocksAgain() async throws {
        let (app, ai) = makeHarness()
        select(app, .openAI, model: "gpt-test", key: "key")
        app.settings.aiConsent[AIProvider.openAI.rawValue] = .allowed(Date())

        XCTAssertTrue(app.enqueueSummary(for: topic("1")))
        try await waitUntil { ai.waiting == 1 }
        app.withdrawAIConsent(.openAI)
        XCTAssertEqual(app.activities.first?.status, .cancelled)
        guard case .declined = app.aiConsentState(for: .openAI) else { return XCTFail("not declined") }

        ai.releaseAll()
        XCTAssertTrue(app.enqueueSummary(for: topic("2")))
        try await waitUntil { app.activities.first { $0.topicID == "2" }?.status == .failed }
        XCTAssertEqual(ai.calls.count, 1)
        XCTAssertNil(app.aiConsent.asking)
    }

    /// Work the app starts by itself (watched-topic refreshes, the digest)
    /// never shows the page: it fails with the waiting state, and the
    /// digest doesn't start until the provider is allowed.
    func testAutomaticWorkNeverPresentsThePage() async throws {
        let (app, ai) = makeHarness()
        select(app, .openAI, model: "gpt-test", key: "key")
        XCTAssertFalse(app.canRunUnattended(.assistant))
        XCTAssertEqual(app.providerAwaitingConsent(for: .assistant), .openAI)

        XCTAssertTrue(app.enqueueSummary(for: topic("1"), origin: .automatic))
        try await waitUntil { app.activities.first?.status == .failed }
        XCTAssertNil(app.aiConsent.asking)
        XCTAssertNil(app.rootPresentation)
        XCTAssertNil(app.presentedError)
        XCTAssertEqual(app.activities.first?.error, AssistantError.aiConsentRequired(.openAI).localizedDescription)

        app.makeTodaysDigest()
        XCTAssertEqual(app.digestActivity, .idle)
        XCTAssertNil(app.aiConsent.asking)
        XCTAssertTrue(ai.calls.isEmpty)

        app.settings.aiConsent[AIProvider.openAI.rawValue] = .allowed(Date())
        XCTAssertTrue(app.canRunUnattended(.assistant))
    }

    /// A cancelled job stops waiting; the page stays as a question.
    func testCancellingAWaitingJobStopsItsWait() async throws {
        let (app, ai) = makeHarness()
        select(app, .openAI, model: "gpt-test", key: "key")
        XCTAssertTrue(app.enqueueSummary(for: topic("1")))
        try await waitUntil { app.aiConsent.asking == .openAI }
        let record = try XCTUnwrap(app.activities.first)
        app.cancel(record: record)
        app.answerAIConsent(.openAI, allow: true)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(app.activities.first?.status, .cancelled)
        XCTAssertTrue(ai.calls.isEmpty)
    }

    // MARK: Sync

    /// Each provider's decision is its own settings unit and applies back.
    func testConsentSyncsOneUnitPerProvider() throws {
        var settings = AppSettings()
        settings.aiConsent = [
            AIProvider.gemini.rawValue: .allowed(Date(timeIntervalSince1970: 100)),
            AIProvider.openAI.rawValue: .declined(Date(timeIntervalSince1970: 200))
        ]
        let units = try SyncSchema.settingsUnits(settings)
        XCTAssertNil(units["aiConsent"])
        XCTAssertNotNil(units["aiConsent.gemini"])
        XCTAssertNotNil(units["aiConsent.openai"])

        var local = AppSettings()
        local.aiConsent = [AIProvider.anthropic.rawValue: .allowed(Date(timeIntervalSince1970: 50))]
        let applied = try SyncSchema.applying(settingsUnits: ["aiConsent.openai": units["aiConsent.openai"]!], to: local)
        XCTAssertEqual(applied.aiConsent[AIProvider.openAI.rawValue], .declined(Date(timeIntervalSince1970: 200)))
        XCTAssertEqual(applied.aiConsent[AIProvider.anthropic.rawValue], .allowed(Date(timeIntervalSince1970: 50)))
    }

    // MARK: Report AI output

    /// The report captures the topic URL, the model and the text, and is
    /// built without the network (Mail queues it; the fallback copies it).
    func testReportingASummaryCapturesTopicModelAndText() throws {
        let topic = topic("7")
        var session = TopicSession(siteURL: site, topicID: "7", url: topic.url, title: topic.title)
        session.summary = "## Summary\nThe AI wrote this."
        session.provider = .gemini
        session.model = "gemini-flash"
        let (app, _) = makeHarness(snapshot: AppSnapshot(sessions: [session]))
        app.select(topic: topic)

        let target = try XCTUnwrap(app.currentAIOutputReport(feature: .summary))
        XCTAssertNil(app.currentAIOutputReport(feature: .chatAnswer), "no chat answer yet")
        let draft = ModerationReport.draft(for: target, reason: .inaccurate, note: "Wrong", blocked: false, links: nil)
        XCTAssertEqual(draft.subject, "Forumind report: AI summary on forum.example.com")
        XCTAssertTrue(draft.body.contains("Topic URL: \(topic.url.absoluteString)"))
        XCTAssertTrue(draft.body.contains("Model: Google Gemini · gemini-flash"))
        XCTAssertTrue(draft.body.contains("Reason: inaccurate"))
        XCTAssertTrue(draft.body.contains("The AI wrote this."))
        XCTAssertNotNil(ModerationReport.mailtoURL(subject: draft.subject, body: draft.body))
        XCTAssertEqual(ReportReason.reasons(for: target.kind).first, .inaccurate)
        XCTAssertFalse(ReportReason.reasons(for: .topic).contains(.inaccurate))

        app.report(target)
        XCTAssertEqual(app.rootPresentation, .reportAIOutput(target))
    }

    func testReportingAnAskAnswerCapturesTheQuestionAndCapsTheText() {
        let (app, _) = makeHarness()
        let run = AgentRun(siteURL: site, goal: "Which printer?", provider: .anthropic, model: "claude-test")
        let long = String(repeating: "a", count: AIOutput.reportTextLimit + 50)
        let target = app.aiOutputReport(for: run, answer: long)
        let body = ModerationReport.body(for: target, reason: .other, note: "", blocked: false, links: nil)
        XCTAssertTrue(body.contains("Question: Which printer?"))
        XCTAssertTrue(body.contains("AI output: Ask the forum answer"))
        XCTAssertTrue(body.contains("Model: Anthropic · claude-test"))
        XCTAssertTrue(body.contains(String(repeating: "a", count: AIOutput.reportTextLimit) + " […]"))
        XCTAssertFalse(body.contains(long))
    }

    // MARK: Helpers

    private func makeApp(aiService: AIService, snapshot: AppSnapshot? = nil) -> AppModel {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = PersistentStore(fileURL: directory.appendingPathComponent("state.json"), keys: InMemoryProviderKeyStore())
        var seeded = snapshot ?? AppSnapshot()
        seeded.ensureForum(site)
        try? store.save(seeded)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StateForumStub.self]
        let app = AppModel(
            store: store,
            forumService: ForumService(session: URLSession(configuration: configuration), pacer: ForumRequestPacer(clock: InstantPacingClock())),
            aiService: aiService
        )
        app.usesDirectForumRequests = true
        app.browser.onPageContextChanged = nil
        app.settings.hasCompletedOnboarding = true
        app.settings.acceptedTermsVersion = ModerationTerms.currentVersion
        return app
    }

    private func makeHarness(snapshot: AppSnapshot? = nil) -> (AppModel, StateAIStub) {
        let ai = StateAIStub()
        let app = makeApp(aiService: ai, snapshot: snapshot)
        addTeardownBlock { @MainActor in
            for record in app.activities where !record.status.isTerminal { app.cancel(record: record) }
            ai.gated = false
            ai.releaseAll()
        }
        return (app, ai)
    }

    private func select(_ app: AppModel, _ provider: AIProvider, model: String, key: String = "") {
        var configuration = app.settings.configuration(for: provider)
        configuration.apiKey = key
        configuration.baseURL = provider.isLocalServer ? configuration.baseURL : "https://api.example.com/v1"
        app.setConfiguration(configuration, for: provider)
        app.selectModel(ModelSelection(provider: provider, model: model), for: .both)
    }

    private func topic(_ id: String) -> ForumTopic {
        ForumTopic(siteURL: site, topicID: id, url: URL(string: "\(site)/t/topic-\(id)/\(id)")!, title: "Topic \(id)")
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

/// Counts requests to the AI provider and answers with one OpenAI-style
/// streamed "OK".
final class ConsentAIRequestStub: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var seen = 0

    static var count: Int { lock.withLock { seen } }
    static func reset() { lock.withLock { seen = 0 } }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ConsentAIRequestStub.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.withLock { Self.seen += 1 }
        let body = "data: {\"choices\":[{\"delta\":{\"content\":\"OK\"}}]}\n\ndata: [DONE]\n\n"
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

// MARK: - Helpers for tests about other things

extension AIService {
    /// A service whose consent backstop lets everything through (tests of
    /// the wire format, not of consent).
    static func allowingAll(session: URLSession) -> AIService {
        let service = AIService(session: session)
        service.consentCheck = { _ in }
        return service
    }
}

extension AppModel {
    /// Every third-party provider allowed (tests of other features).
    func allowAllAIProviders() {
        for provider in AIProvider.allCases where provider.requiresDataConsent {
            settings.aiConsent[provider.rawValue] = .allowed(Date())
        }
    }
}
