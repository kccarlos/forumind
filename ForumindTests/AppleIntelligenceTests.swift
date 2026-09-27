import XCTest
#if canImport(FoundationModels)
import FoundationModels
#endif
@testable import Forumind

/// Scriptable stand-in for FoundationModels.
private final class FakeAppleIntelligence: AppleIntelligenceServing {
    var status: AppleIntelligenceStatus = .available(.onDevice)
    var tokens = 4_096
    /// Each call pops one result; the last one repeats.
    var replies: [Result<String, Error>] = [.success("OK")]
    var actions: [Result<AppleIntelligenceActionDraft, Error>] = []
    private(set) var prompts: [(instructions: String, prompt: String, maxTokens: Int)] = []
    private(set) var actionPrompts: [String] = []

    func currentStatus() -> AppleIntelligenceStatus { status }

    func contextTokens(for backend: AppleIntelligenceBackend) async -> Int { tokens }

    func generate(
        backend: AppleIntelligenceBackend,
        instructions: String,
        prompt: String,
        maxResponseTokens: Int,
        onDelta: @escaping @MainActor (String) -> Void
    ) async throws -> String {
        prompts.append((instructions, prompt, maxResponseTokens))
        let result = replies.count > 1 ? replies.removeFirst() : replies[0]
        let text = try result.get()
        await onDelta(text)
        return text
    }

    func generateAgentAction(
        backend: AppleIntelligenceBackend,
        instructions: String,
        prompt: String
    ) async throws -> AppleIntelligenceActionDraft {
        actionPrompts.append(prompt)
        guard !actions.isEmpty else { throw AppleIntelligenceError.guidedGenerationFailed }
        return try (actions.count > 1 ? actions.removeFirst() : actions[0]).get()
    }
}

final class AppleIntelligenceTests: XCTestCase {
    private let configuration = ProviderConfiguration(provider: .appleIntelligence)

    // MARK: Availability

    func testAvailabilityPrefersPrivateCloudComputeThenOnDevice() {
        typealias Probe = AppleIntelligenceProbe
        XCTAssertEqual(
            AppleIntelligenceAvailability.resolve(Probe(onDevice: .available, privateCloud: .available)),
            .available(.privateCloudCompute)
        )
        // PCC not compiled in (no entitlement) or below iOS 27: on-device.
        XCTAssertEqual(
            AppleIntelligenceAvailability.resolve(Probe(onDevice: .available, privateCloud: nil)),
            .available(.onDevice)
        )
        XCTAssertEqual(
            AppleIntelligenceAvailability.resolve(
                Probe(onDevice: .available, privateCloud: .unavailable(.modelNotReady))
            ),
            .available(.onDevice)
        )
        // PCC works even while the on-device model is still downloading.
        XCTAssertEqual(
            AppleIntelligenceAvailability.resolve(
                Probe(onDevice: .unavailable(.modelNotReady), privateCloud: .available)
            ),
            .available(.privateCloudCompute)
        )
    }

    func testAvailabilityReportsTheUsefulReason() {
        typealias Probe = AppleIntelligenceProbe
        XCTAssertEqual(
            AppleIntelligenceAvailability.resolve(Probe(onDevice: nil, privateCloud: nil)),
            .unavailable(.requiresNewerOS)
        )
        XCTAssertEqual(
            AppleIntelligenceAvailability.resolve(
                Probe(onDevice: .unavailable(.appleIntelligenceNotEnabled), privateCloud: .unavailable(.deviceNotEligible))
            ),
            .unavailable(.appleIntelligenceNotEnabled)
        )
        XCTAssertEqual(
            AppleIntelligenceAvailability.resolve(Probe(onDevice: .unavailable(.deviceNotEligible))),
            .unavailable(.deviceNotEligible)
        )
        XCTAssertEqual(
            AppleIntelligenceAvailability.resolve(Probe(onDevice: .unavailable(.modelNotReady))),
            .unavailable(.modelNotReady)
        )
        XCTAssertEqual(
            AppleIntelligenceAvailability.resolve(Probe(onDevice: .available, localeSupported: false)),
            .unavailable(.unsupportedLanguage)
        )
        XCTAssertEqual(AppleIntelligenceUnavailableReason.appleIntelligenceNotEnabled.title, "Turn on Apple Intelligence in Settings")
        XCTAssertEqual(AppleIntelligenceUnavailableReason.deviceNotEligible.title, "Device not supported")
        XCTAssertEqual(AppleIntelligenceUnavailableReason.modelNotReady.title, "Model downloading…")
        XCTAssertEqual(AppleIntelligenceUnavailableReason.unsupportedLanguage.title, "Not available in your region or language")
        XCTAssertEqual(AppleIntelligenceStatus.available(.onDevice).title, "Ready · On-device")
        XCTAssertEqual(AppleIntelligenceStatus.available(.privateCloudCompute).title, "Ready · Private Cloud Compute")
    }

    func testProviderNeedsNoKeyAndIsListedFirst() {
        XCTAssertEqual(AIProvider.allCases.first, .appleIntelligence)
        XCTAssertFalse(AIProvider.appleIntelligence.requiresAPIKey)
        XCTAssertFalse(AIProvider.appleIntelligence.isLocalServer)
        XCTAssertEqual(AIProvider.appleIntelligence.displayName, "Apple Intelligence")
        XCTAssertEqual(AIProvider(rawValue: "appleintelligence"), .appleIntelligence)
        let guide = ProviderGuide.guide(for: .appleIntelligence)
        XCTAssertTrue(guide.blurb.contains("Private Cloud Compute"))
        XCTAssertFalse(guide.isLocal)
    }

    @MainActor
    func testReadinessFollowsAvailability() throws {
        let fake = FakeAppleIntelligence()
        let app = makeApp(fake)
        app.settings.selectedProvider = .appleIntelligence
        XCTAssertTrue(app.isProviderReady)
        fake.status = .unavailable(.appleIntelligenceNotEnabled)
        XCTAssertFalse(app.isProviderReady)
    }

    // MARK: Default provider

    func testDefaultsToAppleIntelligenceOnlyForUntouchedUsers() {
        let fresh = AppSettings()
        XCTAssertTrue(AppleIntelligenceDefaults.shouldSelectAppleIntelligence(
            settings: fresh, status: .available(.onDevice), alreadyApplied: false
        ))
        // Unavailable: onboarding keeps OpenRouter.
        XCTAssertFalse(AppleIntelligenceDefaults.shouldSelectAppleIntelligence(
            settings: fresh, status: .unavailable(.deviceNotEligible), alreadyApplied: false
        ))
        // Applied once already (the user may have switched back).
        XCTAssertFalse(AppleIntelligenceDefaults.shouldSelectAppleIntelligence(
            settings: fresh, status: .available(.onDevice), alreadyApplied: true
        ))

        var withKey = AppSettings()
        var openRouter = withKey.configuration(for: .openRouter)
        openRouter.apiKey = "sk-or-123"
        withKey.setConfiguration(openRouter, for: .openRouter)
        XCTAssertFalse(AppleIntelligenceDefaults.isUntouched(withKey))

        var otherProvider = AppSettings()
        otherProvider.selectedProvider = .ollama
        XCTAssertFalse(AppleIntelligenceDefaults.isUntouched(otherProvider))

        var editedModel = AppSettings()
        var anthropic = editedModel.configuration(for: .anthropic)
        anthropic.model = "claude-sonnet-4-5"
        editedModel.setConfiguration(anthropic, for: .anthropic)
        XCTAssertFalse(AppleIntelligenceDefaults.isUntouched(editedModel))

        var withFavorite = AppSettings()
        withFavorite.favoriteModels = [FavoriteModel(provider: .openAI, model: "gpt-4o")]
        XCTAssertFalse(AppleIntelligenceDefaults.isUntouched(withFavorite))
    }

    @MainActor
    func testApplyingTheDefaultHappensOnceAndNeverOverridesAConfiguredProvider() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "ai-tests-\(UUID().uuidString)"))
        let app = makeApp(FakeAppleIntelligence())
        XCTAssertEqual(app.settings.selectedProvider, .openRouter)
        app.applyAppleIntelligenceDefaultIfNeeded(status: .available(.onDevice), defaults: defaults)
        XCTAssertEqual(app.settings.selectedProvider, .appleIntelligence)

        // The user switches back; the default is not applied again.
        app.settings.selectedProvider = .openRouter
        app.applyAppleIntelligenceDefaultIfNeeded(status: .available(.onDevice), defaults: defaults)
        XCTAssertEqual(app.settings.selectedProvider, .openRouter)

        // An existing user with a key keeps their provider.
        let existing = makeApp(FakeAppleIntelligence())
        var configuration = existing.settings.configuration(for: .openRouter)
        configuration.apiKey = "sk-or-123"
        existing.settings.setConfiguration(configuration, for: .openRouter)
        let freshDefaults = try XCTUnwrap(UserDefaults(suiteName: "ai-tests-\(UUID().uuidString)"))
        existing.applyAppleIntelligenceDefaultIfNeeded(status: .available(.privateCloudCompute), defaults: freshDefaults)
        XCTAssertEqual(existing.settings.selectedProvider, .openRouter)

        // Unavailable: nothing changes and the one-time flag stays unset.
        let other = makeApp(FakeAppleIntelligence())
        let otherDefaults = try XCTUnwrap(UserDefaults(suiteName: "ai-tests-\(UUID().uuidString)"))
        other.applyAppleIntelligenceDefaultIfNeeded(status: .unavailable(.modelNotReady), defaults: otherDefaults)
        XCTAssertEqual(other.settings.selectedProvider, .openRouter)
        XCTAssertFalse(otherDefaults.bool(forKey: AppleIntelligenceDefaults.appliedKey))
    }

    func testRunsRecordTheBackendAsTheModel() {
        let resolved = RunSettings.resolvingAppleIntelligence(
            configuration, provider: .appleIntelligence, status: .available(.privateCloudCompute)
        )
        XCTAssertEqual(resolved.model, "Private Cloud Compute")
        XCTAssertEqual(
            RunSettings.resolvingAppleIntelligence(configuration, provider: .appleIntelligence, status: .available(.onDevice)).model,
            "On-device"
        )
        let openAI = ProviderConfiguration(provider: .openAI)
        XCTAssertEqual(
            RunSettings.resolvingAppleIntelligence(openAI, provider: .openAI, status: .available(.onDevice)),
            openAI
        )
        XCTAssertEqual(AppleIntelligenceBackend(label: "On-device"), .onDevice)
        XCTAssertNil(AppleIntelligenceBackend(label: "gpt-4o"))
    }

    // MARK: Budgets

    func testBatchLimitIsDerivedFromTheContextWindow() {
        let english = String(repeating: "The quick brown fox jumps over the lazy dog. ", count: 100)
        let chinese = String(repeating: "这张信用卡的年费值得吗？大家怎么看。", count: 100)
        let system = PromptBuilder.summarySystem(custom: "")

        let onDevice = AppleIntelligenceBudget.summaryBatchCharacters(contextTokens: 4_096, sample: english, systemPrompt: system)
        XCTAssertLessThan(onDevice, SummaryBatchLimit.minimum, "the on-device window is far below the hosted minimum")
        XCTAssertGreaterThanOrEqual(onDevice, AppleIntelligenceBudget.minimumBatchCharacters)
        // Tokens × chars/token must fit: input + reply ≤ window.
        let tokens = Double(onDevice + system.count) / AppleIntelligenceBudget.charactersPerToken(sample: english)
        XCTAssertLessThan(Int(tokens) + AppleIntelligenceBudget.reservedOutputTokens(contextTokens: 4_096), 4_096)

        let cjk = AppleIntelligenceBudget.summaryBatchCharacters(contextTokens: 4_096, sample: chinese, systemPrompt: system)
        XCTAssertLessThan(cjk, onDevice, "CJK text uses more tokens per character")

        let cloud = AppleIntelligenceBudget.summaryBatchCharacters(contextTokens: 65_536, sample: english, systemPrompt: system)
        XCTAssertGreaterThan(cloud, onDevice * 10)
        let huge = AppleIntelligenceBudget.summaryBatchCharacters(contextTokens: 10_000_000, sample: english, systemPrompt: system)
        XCTAssertEqual(huge, SummaryBatchLimit.maximum)
        let tiny = AppleIntelligenceBudget.summaryBatchCharacters(contextTokens: 512, sample: english, systemPrompt: system)
        XCTAssertEqual(tiny, AppleIntelligenceBudget.minimumBatchCharacters)

        XCTAssertEqual(AppleIntelligenceBudget.charactersPerToken(sample: english), 3, accuracy: 0.01)
        XCTAssertEqual(AppleIntelligenceBudget.charactersPerToken(sample: chinese), 1, accuracy: 0.2)
        XCTAssertEqual(AppleIntelligenceBudget.reservedOutputTokens(contextTokens: 4_096), 1_024)
        XCTAssertEqual(AppleIntelligenceBudget.reservedOutputTokens(contextTokens: 16_384), 2_048)
        XCTAssertEqual(AppleIntelligenceBudget.reservedOutputTokens(contextTokens: 128_000), 8_192)
    }

    func testSummaryUsesTheDerivedBatchesAndStaysWithinTheWindow() async throws {
        let fake = FakeAppleIntelligence()
        fake.replies = [.success("Partial summary.")]
        let service = AIService(appleIntelligence: fake)
        let post = "A reply with a data point and some advice about the card.\n\n\n"
        let content = String(repeating: post, count: 500) // ~30k characters

        let summary = try await service.generateSummary(
            content: content,
            configuration: configuration,
            provider: .appleIntelligence,
            customPrompt: "",
            batchLimit: SummaryBatchLimit.maximum, // the user's slider is ignored
            onDelta: { _ in }
        )
        XCTAssertEqual(summary, "Partial summary.")
        XCTAssertGreaterThan(fake.prompts.count, 3, "long content is summarized in several on-device batches")
        let budget = AppleIntelligenceBudget.promptCharacters(contextTokens: 4_096, charactersPerToken: 3)
        for call in fake.prompts {
            XCTAssertLessThanOrEqual(call.instructions.count + call.prompt.count, budget + 200)
            XCTAssertLessThanOrEqual(call.maxTokens, 1_024)
        }
    }

    /// Every batch, fold and the final pass is reported, in order, so the
    /// record's bar can follow the whole pipeline.
    func testSummaryReportsEachBatchAndTheFinalPass() async throws {
        let fake = FakeAppleIntelligence()
        fake.replies = [.success("Partial summary.")]
        let service = AIService(appleIntelligence: fake)
        let post = "A reply with a data point and some advice about the card.\n\n\n"
        var events: [SummaryProgressEvent] = []
        var tracker = SummaryProgressTracker()
        var fractions: [Double] = []
        _ = try await service.generateSummary(
            content: String(repeating: post, count: 500),
            configuration: configuration,
            provider: .appleIntelligence,
            customPrompt: "",
            onDelta: { _ in },
            onProgress: { event in
                events.append(event)
                fractions.append(tracker.apply(event))
            }
        )
        let started = events.compactMap { event -> (Int, Int)? in
            if case let .batchStarted(level, _, count) = event, level == 1 { return (1, count) }
            return nil
        }
        let finished = events.filter {
            if case .batchFinished(level: 1, _, _) = $0 { return true }
            return false
        }
        XCTAssertGreaterThan(started.count, 3)
        XCTAssertEqual(started.count, started.first?.1)
        XCTAssertEqual(finished.count, started.count)
        XCTAssertTrue(events.contains(.finalStarted(combining: true)))
        XCTAssertTrue(events.contains { if case .streamed = $0 { return true }; return false },
                      "batch text moves the bar while it streams")
        XCTAssertEqual(fractions, fractions.sorted())
        XCTAssertGreaterThanOrEqual(fractions.last ?? 0, SummaryProgressTracker.foldsEnd)

        // A short topic is one pass.
        events = []
        _ = try await service.generateSummary(
            content: "Short topic.",
            configuration: configuration,
            provider: .appleIntelligence,
            customPrompt: "",
            onDelta: { _ in },
            onProgress: { events.append($0) }
        )
        XCTAssertEqual(events.first, .finalStarted(combining: false))
    }

    func testContextOverflowRetriesWithSmallerBatches() async throws {
        let fake = FakeAppleIntelligence()
        fake.replies = [.failure(AppleIntelligenceError.contextExceeded), .success("Fits now.")]
        let service = AIService(appleIntelligence: fake)
        var streamed = ""
        let summary = try await service.generateSummary(
            content: String(repeating: "Word ", count: 400),
            configuration: configuration,
            provider: .appleIntelligence,
            customPrompt: "",
            onDelta: { streamed += $0 }
        )
        XCTAssertEqual(summary, "Fits now.")
        XCTAssertTrue(streamed.contains("retrying in smaller sections"))

        // Gives up after the bounded retries with a clear message.
        let failing = FakeAppleIntelligence()
        failing.replies = [.failure(AppleIntelligenceError.contextExceeded)]
        do {
            _ = try await AIService(appleIntelligence: failing).generateSummary(
                content: String(repeating: "Word ", count: 4_000),
                configuration: configuration,
                provider: .appleIntelligence,
                customPrompt: "",
                onDelta: { _ in }
            )
            XCTFail("expected contextExceeded")
        } catch let error as AppleIntelligenceError {
            XCTAssertEqual(error, .contextExceeded)
            XCTAssertLessThanOrEqual(failing.prompts.count, 3)
        }
    }

    func testChatBoundsTheSourceToTheWindowAndReportsUnavailability() async throws {
        let fake = FakeAppleIntelligence()
        fake.replies = [.success("Answer")]
        let service = AIService(appleIntelligence: fake)
        let source = String(repeating: "Forum post text about annual fees. ", count: 3_000) // ~105k
        let answer = try await service.answer(
            source: source,
            summary: "Summary",
            history: [ChatMessage(role: .user, content: "Is it worth it?")],
            contextLimit: 30_000,
            customPrompt: "",
            configuration: configuration,
            provider: .appleIntelligence,
            onDelta: { _ in }
        )
        XCTAssertEqual(answer, "Answer")
        let call = try XCTUnwrap(fake.prompts.first)
        XCTAssertLessThan(call.instructions.count, 12_000)
        XCTAssertTrue(call.prompt.contains("Is it worth it?"))

        fake.status = .unavailable(.appleIntelligenceNotEnabled)
        do {
            _ = try await service.complete(system: "s", messages: [], configuration: configuration, provider: .appleIntelligence)
            XCTFail("expected unavailable")
        } catch let error as AppleIntelligenceError {
            XCTAssertEqual(error, .unavailable(.appleIntelligenceNotEnabled))
            XCTAssertTrue(error.localizedDescription.contains("Turn on Apple Intelligence"))
        }
        // Test & save reports the same reason; no network involved.
        do {
            try await service.testConnection(configuration: configuration, provider: .appleIntelligence)
            XCTFail("expected unavailable")
        } catch {}
        fake.status = .available(.privateCloudCompute)
        try await service.testConnection(configuration: configuration, provider: .appleIntelligence)
        let models = try await service.discoverModels(configuration: configuration, provider: .appleIntelligence)
        XCTAssertEqual(models, ["Private Cloud Compute"])
    }

    // MARK: Prompts and streaming

    func testFittingKeepsTheGoalAndNewestMessages() {
        let messages = [
            ChatMessage(role: .user, content: "GOAL: find the best card"),
            ChatMessage(role: .assistant, content: String(repeating: "a", count: 3_000)),
            ChatMessage(role: .user, content: "OBSERVATION " + String(repeating: "b", count: 5_000)),
            ChatMessage(role: .assistant, content: "{\"tool\":\"read_topic\"}"),
            ChatMessage(role: .user, content: "OBSERVATION latest " + String(repeating: "c", count: 5_000) + " END")
        ]
        let fitted = AppleIntelligencePrompt.fit(messages, budget: 4_000)
        let total = fitted.reduce(0) { $0 + $1.content.count }
        XCTAssertLessThanOrEqual(total, 4_000 + 400)
        XCTAssertEqual(fitted.first?.content, "GOAL: find the best card")
        XCTAssertTrue(fitted.last?.content.hasPrefix("OBSERVATION latest") == true)
        XCTAssertTrue(fitted.last?.content.hasSuffix("END") == true)
        XCTAssertTrue(fitted.contains { $0.content == AppleIntelligencePrompt.omittedMarker })
        // Small conversations pass through untouched.
        XCTAssertEqual(AppleIntelligencePrompt.fit(Array(messages.prefix(1)), budget: 4_000), Array(messages.prefix(1)))

        let rendered = AppleIntelligencePrompt.render([
            ChatMessage(role: .user, content: "Q1"),
            ChatMessage(role: .assistant, content: "A1"),
            ChatMessage(role: .user, content: "Q2")
        ])
        XCTAssertTrue(rendered.contains("User:\nQ1"))
        XCTAssertTrue(rendered.contains("Assistant:\nA1"))
        XCTAssertTrue(rendered.hasSuffix("User (reply to this):\nQ2"))
        XCTAssertEqual(AppleIntelligencePrompt.render([ChatMessage(role: .user, content: "Only")]), "Only")
    }

    func testStreamSnapshotsBecomeDeltas() {
        XCTAssertEqual(AppleIntelligenceStreaming.delta(previous: "", current: "Hel"), "Hel")
        XCTAssertEqual(AppleIntelligenceStreaming.delta(previous: "Hel", current: "Hello"), "lo")
        XCTAssertEqual(AppleIntelligenceStreaming.delta(previous: "Hello", current: "Hello"), "")
        XCTAssertEqual(AppleIntelligenceStreaming.delta(previous: "Hello wrld", current: "Hello world!"), "d!")
    }

    // MARK: Errors

    func testErrorsHaveActionableMessages() {
        let cases: [(AppleIntelligenceError, String)] = [
            (.contextExceeded, "too long"),
            (.guardrailViolation, "safety"),
            (.unsupportedLanguage, "language"),
            (.rateLimited(nil), "busy"),
            (.quotaReached(nil), "Private Cloud Compute limit"),
            (.network, "connection"),
            (.unavailable(.modelNotReady), "Model downloading"),
            (.refusal, "declined")
        ]
        for (error, fragment) in cases {
            XCTAssertTrue(
                error.localizedDescription.localizedCaseInsensitiveContains(fragment),
                "\(error): \(error.localizedDescription)"
            )
        }
    }

    func testFoundationModelsErrorsAreMapped() throws {
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, *) else { throw XCTSkip("FoundationModels needs iOS 26") }
        typealias GenerationError = LanguageModelSession.GenerationError
        let context = GenerationError.Context(debugDescription: "test")
        let expectations: [(GenerationError, AppleIntelligenceError)] = [
            (.exceededContextWindowSize(context), .contextExceeded),
            (.guardrailViolation(context), .guardrailViolation),
            (.unsupportedLanguageOrLocale(context), .unsupportedLanguage),
            (.rateLimited(context), .rateLimited(nil)),
            (.concurrentRequests(context), .busy),
            (.assetsUnavailable(context), .modelNotReady),
            (.decodingFailure(context), .guidedGenerationFailed),
            (.unsupportedGuide(context), .guidedGenerationFailed)
        ]
        for (error, expected) in expectations {
            XCTAssertEqual(FoundationModelsBridge.mapped(error) as? AppleIntelligenceError, expected, "\(error)")
        }
        XCTAssertTrue(FoundationModelsBridge.mapped(CancellationError()) is CancellationError)
        XCTAssertEqual(
            FoundationModelsBridge.mapped(URLError(.timedOut)) as? AppleIntelligenceError,
            .other(URLError(.timedOut).localizedDescription)
        )
        #else
        throw XCTSkip("SDK without FoundationModels")
        #endif
    }

    // MARK: Agent

    func testGeneratedActionsDecodeIntoAgentActions() throws {
        let draft = AppleIntelligenceActionDraft(
            thought: "Search first",
            tool: " search_forum ",
            arguments: [.init(name: "query", value: "annual fee"), .init(name: " ", value: "ignored")]
        )
        XCTAssertEqual(
            try draft.agentAction(),
            AgentAction(thought: "Search first", tool: "search_forum", arguments: ["query": "annual fee"])
        )
        XCTAssertThrowsError(try AppleIntelligenceActionDraft(thought: "", tool: " ", arguments: []).agentAction())
        XCTAssertEqual(AppleIntelligenceActionDraft.toolNames, AgentPrompt.tools.map(\.name))

        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            // The @Generable schema decodes model output without a model.
            let content = try GeneratedContent(json: """
            {"thought": "Answer now", "tool": "final_answer", "arguments": [{"name": "answer", "value": "Yes."}]}
            """)
            let generated = try AppleIntelligenceGeneratedAction(content)
            XCTAssertEqual(
                try generated.draft.agentAction(),
                AgentAction(thought: "Answer now", tool: "final_answer", arguments: ["answer": "Yes."])
            )
            // The guide's tool list matches the agent's tools.
            let schema = String(describing: AppleIntelligenceGeneratedAction.generationSchema)
            for name in AgentPrompt.tools.map(\.name) {
                XCTAssertTrue(schema.contains(name), "schema is missing \(name)")
            }
        }
        #endif
    }

    func testAgentPlannerUsesGuidedGenerationThenFallsBackToJSON() async throws {
        let fake = FakeAppleIntelligence()
        fake.actions = [.success(.init(thought: "t", tool: "list_latest", arguments: []))]
        let planner = PromptAgentPlanner(aiService: AIService(appleIntelligence: fake))
        let transcript = [AgentPrompt.goalMessage("What's new?")]
        let action = try await planner.nextAction(
            system: "system", transcript: transcript, configuration: configuration, provider: .appleIntelligence
        )
        XCTAssertEqual(action.tool, "list_latest")
        XCTAssertTrue(fake.prompts.isEmpty)

        // Guided generation unavailable: the JSON reply is parsed instead.
        let fallback = FakeAppleIntelligence()
        fallback.replies = [.success("{\"thought\": \"x\", \"tool\": \"search_forum\", \"arguments\": {\"query\": \"fees\"}}")]
        let fallbackPlanner = PromptAgentPlanner(aiService: AIService(appleIntelligence: fallback))
        let parsed = try await fallbackPlanner.nextAction(
            system: "system", transcript: transcript, configuration: configuration, provider: .appleIntelligence
        )
        XCTAssertEqual(parsed, AgentAction(thought: "x", tool: "search_forum", arguments: ["query": "fees"]))
    }

    // MARK: Live (opt-in)

    // Run with the real model where it exists (a device, or the simulator on a
    // Mac with Apple Intelligence on):
    //   xcodebuild test … TEST_RUNNER_DC_LIVE_APPLE_INTELLIGENCE=1
    // Skipped otherwise, and when the model is unavailable.
    private func liveBackend() throws -> AppleIntelligenceBackend {
        guard ProcessInfo.processInfo.environment["DC_LIVE_APPLE_INTELLIGENCE"] == "1" else {
            throw XCTSkip("Set TEST_RUNNER_DC_LIVE_APPLE_INTELLIGENCE=1 to run live Apple Intelligence tests.")
        }
        let status = AppleIntelligenceClient.shared.currentStatus()
        guard let backend = status.backend else {
            throw XCTSkip("Apple Intelligence unavailable here: \(status.title)")
        }
        return backend
    }

    func testLiveModelStreamsAnAnswer() async throws {
        let backend = try liveBackend()
        var deltas = 0
        let text = try await AppleIntelligenceClient.shared.generate(
            backend: backend,
            instructions: "Answer in one word.",
            prompt: "What color is a clear daytime sky?",
            maxResponseTokens: 32,
            onDelta: { _ in deltas += 1 }
        )
        XCTAssertFalse(text.isEmpty)
        XCTAssertGreaterThan(deltas, 0)
    }

    /// A long discussion goes through several batches without overflowing
    /// the real context window.
    func testLiveHierarchicalSummaryFitsTheWindow() async throws {
        let backend = try liveBackend()
        let tokens = await AppleIntelligenceClient.shared.contextTokens(for: backend)
        let post: (Int) -> String = { index in
            "Post \(index) by member\(index): I have had this travel card for \(index % 7 + 1) years. "
                + "The annual fee is $95 and the lounge access saved me about $\(index * 10) last year. "
                + "Customer service was \(index.isMultiple(of: 3) ? "slow" : "helpful") when I disputed a charge."
        }
        let batch = AppleIntelligenceBudget.summaryBatchCharacters(
            contextTokens: tokens,
            sample: post(1),
            systemPrompt: PromptBuilder.summarySystem(custom: "")
        )
        // About 2.2 batches: several section requests plus the final combine.
        var posts: [String] = []
        while posts.joined(separator: "\n\n\n").count < batch * 22 / 10 { posts.append(post(posts.count + 1)) }
        var streamed = ""
        let summary = try await AIService().generateSummary(
            content: posts.joined(separator: "\n\n\n"),
            configuration: configuration,
            provider: .appleIntelligence,
            customPrompt: "",
            onDelta: { streamed += $0 }
        )
        XCTAssertFalse(summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertTrue(streamed.contains("Reading section 3 of 3"), "context \(tokens) tokens, batch \(batch)")
        XCTAssertFalse(streamed.contains("retrying"), "the derived batch should fit the first time")
    }

    func testLiveGuidedAgentAction() async throws {
        _ = try liveBackend()
        let system = AgentPrompt.system(
            forumName: "Example Forum",
            siteURL: "https://forum.example.com",
            maxSteps: 5,
            maxTopicReads: 2,
            customInstructions: ""
        )
        let action = try await PromptAgentPlanner(aiService: AIService()).nextAction(
            system: system,
            transcript: [AgentPrompt.goalMessage("Find discussions about annual fees.")],
            configuration: configuration,
            provider: .appleIntelligence
        )
        XCTAssertTrue(AgentPrompt.tools.map(\.name).contains(action.tool), action.tool)
    }

    // MARK: Helpers

    @MainActor
    private func makeApp(_ fake: FakeAppleIntelligence) -> AppModel {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = PersistentStore(fileURL: directory.appendingPathComponent("state.json"))
        return AppModel(store: store, aiService: AIService(appleIntelligence: fake))
    }
}
