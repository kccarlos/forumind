import SwiftUI
import XCTest
@testable import Forumind

/// Settings and data that change while work is running: provider switches,
/// key edits, limits, forum removal, clearing data, resets, onboarding
/// replays, watched-topic checks, and shared links.
@MainActor
final class StateTransitionTests: XCTestCase {
    private let site = "https://forum.example.com"
    private let other = "https://other.example.org"

    override func setUp() async throws {
        StateForumStub.reset()
    }

    // MARK: 1. Provider / model switches

    /// Two summaries run while the user switches to a favorite model: the
    /// running ones keep their provider and stream, the queued one starts
    /// with the new selection, and each records what it ran with.
    func testRunningWorkKeepsItsProviderAndQueuedWorkUsesTheNewOne() async throws {
        let harness = makeHarness()
        let app = harness.app
        select(app, .ollama, model: "model-a")

        for id in ["1", "2", "3"] { XCTAssertTrue(app.enqueueSummary(for: topic(id))) }
        try await waitUntil { harness.ai.waiting == 2 }
        let running = app.activities.filter { $0.status == .running }
        XCTAssertEqual(running.count, 2)

        app.activateFavorite(FavoriteModel(provider: .lmStudio, model: "model-b"))
        // The header reads the selection: it changes at once.
        XCTAssertEqual(app.settings.selectedProvider, .lmStudio)
        XCTAssertEqual(app.selectedConfiguration.model, "model-b")
        // Running streams are untouched and not mixed.
        for record in running {
            XCTAssertEqual(app.summaryStreams[record.id], "[ollama/model-a]")
            XCTAssertEqual(record.provider, .ollama)
        }

        harness.ai.gated = false
        harness.ai.releaseAll()
        try await waitUntil { app.activities.allSatisfy(\.status.isTerminal) }

        let calls = harness.ai.calls.filter { $0.kind == "summary" }
        XCTAssertEqual(calls.count, 3)
        XCTAssertEqual(calls.prefix(2).map(\.label), ["ollama/model-a", "ollama/model-a"])
        XCTAssertEqual(calls.last?.label, "lmstudio/model-b")
        XCTAssertEqual(app.activities.first { $0.topicID == "3" }?.provider, .lmStudio)
        XCTAssertEqual(app.activities.first { $0.topicID == "3" }?.model, "model-b")
        XCTAssertEqual(app.sessions[topic("1").topicKey]?.model, "model-a")
        XCTAssertEqual(app.sessions[topic("3").topicKey]?.provider, .lmStudio)
        XCTAssertTrue(app.summaryStreams.isEmpty)
        XCTAssertTrue(app.activities.allSatisfy { $0.status == .completed })
    }

    // MARK: 2. Key and base URL edits

    func testKeyEditsMidRunKeepTheStartingKeyAndLaterWorkFailsClearly() async throws {
        let harness = makeHarness()
        let app = harness.app
        select(app, .openAI, model: "gpt-test", key: "key-1")
        XCTAssertTrue(app.isProviderReady)

        XCTAssertTrue(app.enqueueSummary(for: topic("1")))
        try await waitUntil { harness.ai.waiting == 1 }
        setKey(app, "key-2")
        var configuration = app.selectedConfiguration
        configuration.baseURL = "https://proxy.example.com/v1"
        app.setConfiguration(configuration, for: .openAI)
        setKey(app, "")
        XCTAssertFalse(app.isProviderReady)

        harness.ai.gated = false
        harness.ai.releaseAll()
        try await waitUntil { app.activities.allSatisfy(\.status.isTerminal) }
        XCTAssertEqual(harness.ai.calls.first?.configuration.apiKey, "key-1")
        XCTAssertEqual(harness.ai.calls.first?.configuration.baseURL, AIProvider.openAI.defaultBaseURL)
        XCTAssertEqual(app.activities.first?.status, .completed)

        // Work started after the key was deleted fails with a clear message.
        XCTAssertTrue(app.enqueueSummary(for: topic("2")))
        try await waitUntil { app.activities.allSatisfy(\.status.isTerminal) }
        let failed = try XCTUnwrap(app.activities.first { $0.topicID == "2" })
        XCTAssertEqual(failed.status, .failed)
        XCTAssertTrue(failed.error.contains("isn’t connected"), failed.error)
        XCTAssertEqual(harness.ai.calls.count, 1)

        setKey(app, "key-3")
        XCTAssertTrue(app.isProviderReady)
    }

    /// Typing a key writes nothing per keystroke; the last value is written
    /// once edits pause or when the app leaves the foreground.
    func testKeyTypingIsCoalescedAndTheLastValueIsFlushedOnBackground() async throws {
        let harness = makeHarness()
        let app = harness.app
        app.settingsSaveDelay = .seconds(60)
        app.settings.selectedProvider = .openAI
        let savesBefore = harness.store.saveCount
        let writesBefore = harness.keys.writeCount

        var typed = ""
        for character in "sk-live-12345" {
            typed.append(character)
            setKey(app, typed)
            app.saveSettings()
        }
        XCTAssertEqual(harness.keys.writeCount, writesBefore)
        XCTAssertEqual(harness.store.saveCount, savesBefore)

        app.handleScenePhase(.background)
        XCTAssertEqual(harness.keys.writeCount, writesBefore + 1)
        XCTAssertEqual(harness.keys.value(for: .openAI), "sk-live-12345")
        XCTAssertEqual(harness.store.saveCount, savesBefore + 1)
        XCTAssertEqual(harness.store.load().settings.selectedProvider, .openAI)
        XCTAssertEqual(harness.store.load().settings.configuration(for: .openAI).apiKey, "", "keys never go in the snapshot")

        // Nothing pending: a second background does not write again.
        app.handleScenePhase(.background)
        XCTAssertEqual(harness.store.saveCount, savesBefore + 1)

        // The trailing save also fires on its own.
        app.settingsSaveDelay = .milliseconds(30)
        setKey(app, "sk-live-67890")
        try await waitUntil { harness.keys.value(for: .openAI) == "sk-live-67890" }

        let reloaded = AppModel(store: harness.store)
        XCTAssertEqual(reloaded.settings.configuration(for: .openAI).apiKey, "sk-live-67890")
    }

    func testSliderDragWritesTheSnapshotOnce() async throws {
        let harness = makeHarness()
        let app = harness.app
        app.settingsSaveDelay = .milliseconds(50)
        let savesBefore = harness.store.saveCount
        for value in stride(from: 20_000, through: 200_000, by: 5_000) {
            app.settings.summaryBatchLimit = value
            app.saveSettings()
        }
        XCTAssertEqual(harness.store.saveCount, savesBefore)
        try await waitUntil { harness.store.saveCount > savesBefore }
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(harness.store.saveCount, savesBefore + 1)
        XCTAssertEqual(harness.store.load().settings.summaryBatchLimit, 200_000)
    }

    /// A connection test for the old configuration finishing after the user
    /// changed provider or key must not report on the new one.
    func testStaleConnectionTestResultIsDropped() async throws {
        let harness = makeHarness()
        let app = harness.app
        select(app, .openAI, model: "gpt-test", key: "key-1")

        async let stale = app.testConnection()
        try await waitUntil { harness.ai.waiting == 1 }
        setKey(app, "key-2")
        harness.ai.releaseAll()
        let staleResult = await stale
        XCTAssertEqual(staleResult, .stale)
        XCTAssertNotEqual(app.settingsStatus, "Connection successful")
        XCTAssertNil(app.presentedError)

        // A newer test supersedes an older one for the same configuration.
        async let first = app.testConnection()
        try await waitUntil { harness.ai.waiting == 1 }
        async let second = app.testConnection()
        try await waitUntil { harness.ai.waiting == 2 }
        harness.ai.releaseAll()
        let firstResult = await first
        let secondResult = await second
        XCTAssertEqual(firstResult, .stale)
        XCTAssertEqual(secondResult, .success)
        XCTAssertEqual(app.settingsStatus, "Connection successful")

        // Test & save: a stale result is neither success nor failure.
        harness.ai.failConnection = true
        let task = Task { await app.testAndSaveProvider() }
        try await waitUntil { harness.ai.waiting == 1 }
        app.settings.selectedProvider = .anthropic
        harness.ai.releaseAll()
        let state = await task.value
        XCTAssertEqual(state, .idle)
    }

    // MARK: 3. Model discovery

    func testModelsDiscoveredForAnOldProviderAreIgnored() async throws {
        let harness = makeHarness()
        let app = harness.app
        select(app, .openAI, model: "gpt-test", key: "key-1")
        app.discoveredModels = ["kept-until-provider-changes"]

        async let result = app.discoverModels()
        try await waitUntil { harness.ai.waiting == 1 }
        app.settings.selectedProvider = .groq
        XCTAssertTrue(app.discoveredModels.isEmpty, "a provider change clears the old list")
        harness.ai.releaseAll()
        let outcome = await result
        XCTAssertEqual(outcome, .stale)
        XCTAssertTrue(app.discoveredModels.isEmpty)

        harness.ai.gated = false
        let fresh = await app.discoverModels()
        XCTAssertEqual(fresh, .success)
        XCTAssertEqual(app.discoveredModels, ["groq-model"])
    }

    // MARK: 4. Limits and instructions

    func testLimitsAndInstructionsAreTakenWhenWorkStarts() async throws {
        let harness = makeHarness()
        let app = harness.app
        select(app, .ollama, model: "model-a")
        app.settings.summaryBatchLimit = 30_000
        app.settings.forumContextLimit = 40_000
        app.settings.systemPrompt = "Global A"
        harness.ai.gated = false
        // The fetch of topic 1 waits, so the edits land after the job started.
        StateForumStub.gate(path: "/raw/1")

        XCTAssertTrue(app.enqueueSummary(for: topic("1")))
        try await waitUntil { StateForumStub.isWaiting }
        XCTAssertEqual(app.activities.first?.status, .running)
        app.settings.summaryBatchLimit = 100_000
        app.settings.forumContextLimit = 90_000
        app.settings.systemPrompt = "Global B"
        StateForumStub.release()
        try await waitUntil { app.activities.allSatisfy(\.status.isTerminal) }

        XCTAssertEqual(harness.ai.calls.last?.batchLimit, 30_000)
        XCTAssertEqual(harness.ai.calls.last?.customPrompt, "Global A")

        // The next job uses the new values; per-topic instructions win.
        app.select(topic: topic("2"))
        app.setInstructions("Topic two only", topicKey: topic("2").topicKey)
        XCTAssertTrue(app.enqueueSummary(for: topic("2")))
        try await waitUntil { app.activities.allSatisfy(\.status.isTerminal) }
        XCTAssertEqual(harness.ai.calls.last?.batchLimit, 100_000)
        XCTAssertEqual(harness.ai.calls.last?.customPrompt, "Topic two only")

        // Chat: the context size is also taken at start.
        StateForumStub.gate(path: "/t/2.json")
        app.chatDraft = "What changed?"
        app.sendChat()
        try await waitUntil { StateForumStub.isWaiting }
        app.settings.forumContextLimit = 10_000
        app.setInstructions("Edited while answering", topicKey: topic("2").topicKey)
        StateForumStub.release()
        try await waitUntil { app.activities.allSatisfy(\.status.isTerminal) }
        let chat = try XCTUnwrap(harness.ai.calls.last)
        XCTAssertEqual(chat.kind, "chat")
        XCTAssertEqual(chat.contextLimit, 90_000)
        XCTAssertEqual(chat.customPrompt, "Topic two only")
        XCTAssertEqual(app.sessions[topic("2").topicKey]?.history.last?.content, "Answer by ollama/model-a")
    }

    /// Lowering the step budget below the steps already used ends the run at
    /// its next step with an answer, not a failure.
    func testLoweringTheAgentStepBudgetMidRunEndsItGracefully() async throws {
        let planner = SteppingPlanner()
        let harness = makeHarness(planner: planner)
        let app = harness.app
        select(app, .ollama, model: "model-a")
        app.settings.agentMaxSteps = 10

        app.startAgentRun(goal: "Keep looking", siteURL: site)
        for step in 1...3 {
            try await waitUntil { planner.calls == step && planner.isWaiting }
            planner.release()
        }
        try await waitUntil { planner.calls == 4 && planner.isWaiting }
        app.settings.agentMaxSteps = AgentLimits.stepRange.lowerBound
        planner.release()
        try await waitUntil { planner.calls == 5 && planner.isWaiting }
        XCTAssertTrue(planner.lastTranscript.last?.content.contains("budget") ?? false)
        planner.release()

        try await waitUntil { app.agentRuns.first?.status.isTerminal == true }
        let run = try XCTUnwrap(app.agentRuns.first)
        XCTAssertEqual(run.status, .completed)
        XCTAssertEqual(run.steps.count, 5)
        XCTAssertEqual(run.steps.last?.outcome, "Stopped at the step budget")
        XCTAssertEqual(run.provider, .ollama)
    }

    // MARK: 5. Forums

    func testRemovingTheOpenForumWithItsDataMidRun() async throws {
        let harness = makeHarness()
        let app = harness.app
        select(app, .ollama, model: "model-a")
        app.recordVisit(siteURL: other, name: "Other", iconURL: nil)
        app.recordVisit(siteURL: site, name: "Example", iconURL: nil)
        app.pin(try XCTUnwrap(app.forum(for: site)))
        harness.deliver(topicPage(topic("1")))
        app.agentSiteURL = site
        XCTAssertEqual(app.currentForum?.siteURL, site)

        for id in ["1", "2", "3"] { XCTAssertTrue(app.enqueueSummary(for: topic(id))) }
        try await waitUntil { harness.ai.waiting == 2 }

        app.removeForum(try XCTUnwrap(app.forum(for: site)), deleteData: true)
        XCTAssertNil(app.forum(for: site))
        XCTAssertTrue(app.activities.isEmpty)
        XCTAssertTrue(app.sessions.isEmpty)
        XCTAssertNil(app.agentSiteURL)
        XCTAssertEqual(app.agentForum?.siteURL, site, "the agent falls back to the page's forum")
        XCTAssertEqual(app.currentForum?.siteURL, other)
        XCTAssertTrue(app.pinnedForums.isEmpty)

        // The provider answers anyway: nothing comes back.
        harness.ai.gated = false
        harness.ai.releaseAll()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(app.sessions.filter { $0.value.siteURL == site && $0.value.hasSummary }.isEmpty)
        XCTAssertTrue(app.activities.isEmpty)
        XCTAssertTrue(app.summaryStreams.isEmpty)
        XCTAssertEqual(harness.ai.calls.count, 2, "the queued job never started")

        // Still browsing the removed forum: it is not added straight back.
        harness.deliver(topicPage(topic("4")))
        XCTAssertNil(app.forum(for: site))
        // After visiting another forum, coming back adds it as a recent forum.
        harness.deliver(topicPage(topic("9", site: other)))
        harness.deliver(topicPage(topic("5")))
        XCTAssertEqual(app.forum(for: site)?.isPinned, false)
        XCTAssertEqual(app.currentForum?.siteURL, site)
    }

    func testRemovingAForumWithoutItsDataLetsItsWorkFinish() async throws {
        let harness = makeHarness()
        let app = harness.app
        select(app, .ollama, model: "model-a")
        app.recordVisit(siteURL: site, name: "Example", iconURL: nil)
        XCTAssertTrue(app.enqueueSummary(for: topic("1")))
        try await waitUntil { harness.ai.waiting == 1 }

        app.removeForum(try XCTUnwrap(app.forum(for: site)), deleteData: false)
        harness.ai.releaseAll()
        try await waitUntil { app.activities.allSatisfy(\.status.isTerminal) }
        XCTAssertEqual(app.activities.first?.status, .completed)
        XCTAssertTrue(app.sessions[topic("1").topicKey]?.hasSummary ?? false)
        XCTAssertNil(app.forum(for: site))
    }

    func testPinStateAndOrderStayConsistent() {
        let harness = makeHarness()
        let app = harness.app
        let sites = ["https://a.example.com", "https://b.example.com", "https://c.example.com"]
        for siteURL in sites {
            app.recordVisit(siteURL: siteURL, name: nil, iconURL: nil)
            app.pin(app.forum(for: siteURL)!)
        }
        XCTAssertEqual(app.currentForum?.siteURL, sites[2])
        XCTAssertEqual(app.currentForum?.isPinned, true)

        app.removeForum(app.forum(for: sites[1])!, deleteData: false)
        XCTAssertEqual(app.pinnedForums.map(\.siteURL), [sites[0], sites[2]])
        XCTAssertEqual(app.pinnedForums.map(\.pinOrder), [0, 1])

        // `currentForum` follows pin changes (it used to keep a stale copy).
        app.unpin(app.forum(for: sites[2])!)
        XCTAssertEqual(app.currentForum?.isPinned, false)
        app.unpin(app.forum(for: sites[0])!)
        XCTAssertTrue(app.pinnedForums.isEmpty)
        XCTAssertEqual(app.recentForums.count, 2)
        app.pin(app.forum(for: sites[0])!)
        XCTAssertEqual(app.pinnedForums.map(\.pinOrder), [0])

        // A rename (the probe or basic-info reports a new name) reaches the
        // current forum too.
        app.recordVisit(siteURL: sites[2], name: "Renamed", iconURL: nil)
        XCTAssertEqual(app.currentForum?.name, "Renamed")
    }

    /// The background name/icon refresh must not re-add a forum removed
    /// meanwhile, nor re-pin one unpinned meanwhile.
    func testForumInfoRefreshDoesNotUndoRemoveOrUnpin() async throws {
        let harness = makeHarness()
        let app = harness.app
        StateForumStub.gate(path: "/site/basic-info.json")
        app.pinSuggested(SuggestedForum(name: "Example", siteURL: site, description: ""))
        try await waitUntil { StateForumStub.isWaiting }
        app.unpin(try XCTUnwrap(app.forum(for: site)))
        StateForumStub.release()
        try await waitUntil { app.forum(for: site)?.name == "Stub Forum" }
        XCTAssertEqual(app.forum(for: site)?.isPinned, false)

        StateForumStub.gate(path: "/site/basic-info.json")
        app.refreshForumInfo(siteURL: site)
        try await waitUntil { StateForumStub.isWaiting }
        app.removeForum(try XCTUnwrap(app.forum(for: site)), deleteData: false)
        StateForumStub.release()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(app.forum(for: site))
    }

    // MARK: 6. Clear data and reset

    func testClearAllWhileSummaryAndChatRunLeavesNothingBehind() async throws {
        var session = TopicSession(siteURL: site, topicID: "1", url: topic("1").url, title: "Topic 1")
        session.source = "Existing source"
        session.summary = "Old summary"
        let run = finishedRun()
        let harness = makeHarness(snapshot: AppSnapshot(sessions: [session], agentRuns: [run]))
        let app = harness.app
        select(app, .ollama, model: "model-a")
        app.select(topic: topic("1"))
        app.chatDraft = "Is it still true?"
        app.sendChat()
        XCTAssertTrue(app.enqueueSummary(for: topic("2")))
        try await waitUntil { harness.ai.waiting == 2 }
        XCTAssertFalse(app.chatStreams.isEmpty)
        app.chatDraft = "An unsent draft"
        app.agentGoalDraft = "Unsent goal"
        app.agentFollowUpDraft = "Unsent follow-up for the deleted run"

        app.clearAllSavedData()
        XCTAssertTrue(app.sessions.isEmpty)
        XCTAssertTrue(app.activities.isEmpty)
        XCTAssertTrue(app.agentRuns.isEmpty)
        XCTAssertNil(app.selectedAgentRunID)
        XCTAssertTrue(app.summaryStreams.isEmpty)
        XCTAssertTrue(app.chatStreams.isEmpty)
        // Unsent text is kept on purpose, except the draft for a deleted run.
        XCTAssertEqual(app.chatDraft, "An unsent draft")
        XCTAssertEqual(app.agentGoalDraft, "Unsent goal")
        XCTAssertEqual(app.agentFollowUpDraft, "")

        harness.ai.gated = false
        harness.ai.releaseAll()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(app.sessions.isEmpty, "no resurrected sessions")
        XCTAssertTrue(app.activities.isEmpty)
        XCTAssertTrue(app.chatStreams.isEmpty)
        XCTAssertNil(app.presentedError)
        XCTAssertTrue(harness.store.load().sessions.isEmpty)
        XCTAssertNil(app.currentSession)
    }

    func testClearingOneForumKeepsTheOthersRunning() async throws {
        let harness = makeHarness()
        let app = harness.app
        select(app, .ollama, model: "model-a")
        XCTAssertTrue(app.enqueueSummary(for: topic("1")))
        XCTAssertTrue(app.enqueueSummary(for: topic("7", site: other)))
        try await waitUntil { harness.ai.waiting == 2 }

        app.clearSavedData(forSiteURL: site)
        harness.ai.gated = false
        harness.ai.releaseAll()
        try await waitUntil { app.activities.allSatisfy(\.status.isTerminal) }
        XCTAssertEqual(app.activities.map(\.siteURL), [other])
        XCTAssertEqual(app.activities.first?.status, .completed)
        XCTAssertNil(app.sessions[topic("1").topicKey])
        XCTAssertTrue(app.sessions[topic("7", site: other).topicKey]?.hasSummary ?? false)
    }

    func testResetSettingsMidRun() async throws {
        let harness = makeHarness()
        let app = harness.app
        select(app, .openAI, model: "gpt-test", key: "key-1")
        app.settings.hasCompletedOnboarding = true
        app.flushPendingSaves()
        XCTAssertEqual(harness.keys.value(for: .openAI), "key-1")
        for id in ["1", "2", "3"] { XCTAssertTrue(app.enqueueSummary(for: topic(id))) }
        try await waitUntil { harness.ai.waiting == 2 }
        app.discoveredModels = ["gpt-test"]

        app.resetSettings()
        XCTAssertEqual(app.settings.selectedProvider, AppSettings().selectedProvider)
        XCTAssertFalse(app.isProviderReady)
        XCTAssertTrue(app.discoveredModels.isEmpty)
        XCTAssertEqual(harness.keys.value(for: .openAI), "", "reset removes keys at once")
        XCTAssertTrue(app.settings.hasCompletedOnboarding)

        harness.ai.gated = false
        harness.ai.releaseAll()
        try await waitUntil { app.activities.allSatisfy(\.status.isTerminal) }
        let byTopic = Dictionary(uniqueKeysWithValues: app.activities.map { ($0.topicID, $0) })
        XCTAssertEqual(byTopic["1"]?.status, .completed)
        XCTAssertEqual(byTopic["2"]?.status, .completed)
        XCTAssertEqual(byTopic["3"]?.status, .failed)
        XCTAssertTrue(byTopic["3"]?.error.contains("isn’t connected") ?? false)
        XCTAssertEqual(harness.ai.calls.map(\.configuration.apiKey), ["key-1", "key-1"])
    }

    /// Clearing or editing the chat while it is answered drops the answer
    /// instead of attaching it to a conversation it no longer belongs to.
    func testClearingTheChatWhileItIsAnsweredDropsTheAnswer() async throws {
        var session = TopicSession(siteURL: site, topicID: "1", url: topic("1").url, title: "Topic 1")
        session.source = "Existing source"
        let harness = makeHarness(snapshot: AppSnapshot(sessions: [session]))
        let app = harness.app
        select(app, .ollama, model: "model-a")
        app.select(topic: topic("1"))
        app.chatDraft = "First question"
        app.sendChat()
        try await waitUntil { harness.ai.waiting == 1 }
        app.clearChat()
        harness.ai.releaseAll()
        try await waitUntil { app.activities.allSatisfy(\.status.isTerminal) }
        XCTAssertEqual(app.currentSession?.history, [])
    }

    func testClearingTheChatWhileTheTopicIsReadSkipsTheProvider() async throws {
        var session = TopicSession(siteURL: site, topicID: "1", url: topic("1").url, title: "Topic 1")
        session.source = "Existing source"
        let harness = makeHarness(snapshot: AppSnapshot(sessions: [session]))
        let app = harness.app
        select(app, .ollama, model: "model-a")
        app.select(topic: topic("1"))
        StateForumStub.gate(path: "/t/1.json")
        app.chatDraft = "First question"
        app.sendChat()
        try await waitUntil { StateForumStub.isWaiting }
        app.clearChat()
        StateForumStub.release()
        try await waitUntil { app.activities.allSatisfy(\.status.isTerminal) }
        XCTAssertFalse(harness.ai.calls.contains { $0.kind == "chat" })
        XCTAssertEqual(app.currentSession?.history, [])
        XCTAssertNil(app.presentedError)
    }

    // MARK: 7. Onboarding replay

    func testFinishingAReplayedWalkthroughLeavesWorkAndTheAssistantAlone() async throws {
        let harness = makeHarness()
        let app = harness.app
        select(app, .ollama, model: "model-a")
        app.settings.hasCompletedOnboarding = true
        harness.deliver(topicPage(topic("1")))
        app.assistantMode = .chat
        app.panelRoute = .settings
        XCTAssertTrue(app.enqueueSummary(for: topic("1")))
        try await waitUntil { harness.ai.waiting == 1 }

        // The provider step edits the selection, then the walkthrough ends.
        app.activateFavorite(FavoriteModel(provider: .lmStudio, model: "model-b"))
        app.saveSettings()
        app.completeOnboarding()
        XCTAssertTrue(app.settings.hasCompletedOnboarding)
        XCTAssertEqual(app.assistantMode, .chat)
        XCTAssertEqual(app.panelRoute, .settings)
        XCTAssertEqual(app.currentTopic?.topicKey, topic("1").topicKey)
        XCTAssertEqual(app.activities.first?.status, .running)

        harness.ai.releaseAll()
        try await waitUntil { app.activities.allSatisfy(\.status.isTerminal) }
        XCTAssertEqual(app.activities.first?.status, .completed)
        XCTAssertEqual(app.sessions[topic("1").topicKey]?.provider, .ollama)
        XCTAssertEqual(harness.store.load().settings.selectedProvider, .lmStudio)
    }

    func testProviderSetupRequestClearsOnceTheProviderIsReady() {
        let harness = makeHarness()
        let app = harness.app
        app.needsProviderSetup = true
        select(app, .ollama, model: "model-a")
        XCTAssertFalse(app.needsProviderSetup)
    }

    // MARK: 8. Watched topics

    /// Unwatching a topic (and turning auto-refresh off) while a check is
    /// fetching: no crash, the right topic is updated, nothing is queued, and
    /// an overlapping check does not run twice.
    func testWatchCheckWhileTopicsAreUnwatched() async throws {
        var summarized = TopicSession(siteURL: site, topicID: "2", url: topic("2").url, title: "Topic 2")
        summarized.summary = "Summary"
        let watched = ["1", "2", "3"].map {
            WatchedTopic(siteURL: site, topicID: $0, url: topic($0).url, title: "Topic \($0)", knownPostCount: 1)
        }
        let harness = makeHarness(snapshot: AppSnapshot(sessions: [summarized], watchedTopics: watched))
        let app = harness.app
        select(app, .ollama, model: "model-a")
        XCTAssertTrue(app.settings.watchAutoRefreshSummaries)
        StateForumStub.postCounts = ["1": 4, "2": 6, "3": 2]
        StateForumStub.gate(path: "/t/1.json")

        let check = Task { await app.checkWatchedTopics(reason: .manual) }
        try await waitUntil { StateForumStub.isWaiting }
        await app.checkWatchedTopics(reason: .foreground)  // overlapping: returns at once
        app.unwatch(topicKey: topic("1").topicKey)
        app.settings.watchAutoRefreshSummaries = false
        StateForumStub.release()
        await check.value

        XCTAssertEqual(app.watchedTopics.map(\.topicID), ["2", "3"])
        XCTAssertEqual(app.watchedTopics.map(\.newReplies), [5, 1])
        XCTAssertEqual(app.watchedTopics.map(\.knownPostCount), [6, 2])
        XCTAssertFalse(app.activities.contains { $0.type == .summary })
        XCTAssertEqual(StateForumStub.count(of: "/t/2.json"), 1)

        // Unwatching everything mid-check is fine too.
        StateForumStub.postCounts = ["2": 9, "3": 9]
        StateForumStub.gate(path: "/t/2.json")
        let second = Task { await app.checkWatchedTopics(reason: .foreground) }
        try await waitUntil { StateForumStub.isWaiting }
        app.unwatch(topicKey: topic("2").topicKey)
        app.unwatch(topicKey: topic("3").topicKey)
        StateForumStub.release()
        await second.value
        XCTAssertTrue(app.watchedTopics.isEmpty)
    }

    func testWatchRefreshDoesNotQueueSummariesWithoutAProvider() async throws {
        var summarized = TopicSession(siteURL: site, topicID: "2", url: topic("2").url, title: "Topic 2")
        summarized.summary = "Summary"
        let watched = WatchedTopic(siteURL: site, topicID: "2", url: topic("2").url, title: "Topic 2", knownPostCount: 1)
        let harness = makeHarness(snapshot: AppSnapshot(sessions: [summarized], watchedTopics: [watched]))
        let app = harness.app
        select(app, .openAI, model: "gpt-test", key: "")
        StateForumStub.postCounts = ["2": 5]
        await app.checkWatchedTopics(reason: .manual)
        XCTAssertEqual(app.watchedTopics.first?.newReplies, 4)
        XCTAssertFalse(app.activities.contains { $0.type == .summary })
        XCTAssertNil(app.presentedError)

        select(app, .ollama, model: "model-a")
        StateForumStub.postCounts = ["2": 7]
        harness.ai.gated = false
        await app.checkWatchedTopics(reason: .manual)
        XCTAssertTrue(app.activities.contains { $0.type == .summary })
    }

    // MARK: 10. Shared links

    func testSharedLinksLatestWinsAndSettledOtherTopicsClearTheWait() async throws {
        let harness = makeHarness()
        let app = harness.app
        select(app, .ollama, model: "model-a")
        app.panelRoute = .settings

        let first = IncomingLinkRequest(url: topic("11").url, action: .summary)
        let second = IncomingLinkRequest(url: topic("12").url, action: .summary)
        app.handle(first)
        app.handle(second)
        app.handle(second)  // the same request again (URL and inbox)
        XCTAssertEqual(app.panelRoute, .topic)

        // A late report from the first shared page starts nothing and does
        // not cancel the second share (its page has not loaded yet).
        harness.deliver(topicPage(topic("11")))
        XCTAssertTrue(app.activities.isEmpty)
        harness.deliver(topicPage(topic("12")))
        XCTAssertEqual(app.activities.filter { $0.type == .summary }.map(\.topicID), ["12"])

        // Shared again while that summary runs: no duplicate, and the
        // Assistant shows it (not Manage).
        let again = IncomingLinkRequest(url: topic("12").url, action: .summary)
        app.handle(again)
        harness.deliver(topicPage(topic("12")))
        XCTAssertEqual(app.activities.filter { $0.type == .summary }.count, 1)
        XCTAssertEqual(app.panelRoute, .topic)

        // Once the shared page was reached, a settled page of another topic
        // ends the wait, so visiting it later does not start a summary.
        let third = IncomingLinkRequest(url: topic("13").url, action: .summary)
        app.handle(third)
        harness.deliver(PageContext(url: topic("13").url, state: .loading))
        harness.deliver(topicPage(topic("14")))  // the user went elsewhere
        harness.deliver(topicPage(topic("13")))
        XCTAssertFalse(app.activities.contains { $0.topicID == "13" })

        for record in app.activities where !record.status.isTerminal { app.cancel(record: record) }
    }

    // MARK: 11. Backgrounding

    func testBackgroundingMidStreamFlushesAndWorkContinues() async throws {
        let harness = makeHarness()
        let app = harness.app
        app.settingsSaveDelay = .seconds(60)
        select(app, .ollama, model: "model-a")
        XCTAssertTrue(app.enqueueSummary(for: topic("1")))
        try await waitUntil { harness.ai.waiting == 1 }
        app.settings.systemPrompt = "Typed just before leaving"

        app.handleScenePhase(.inactive)
        XCTAssertEqual(harness.store.load().settings.systemPrompt, "Typed just before leaving")
        app.handleScenePhase(.background)
        XCTAssertEqual(harness.store.load().activities.first?.status, .running)

        harness.ai.releaseAll()
        try await waitUntil { app.activities.allSatisfy(\.status.isTerminal) }
        XCTAssertEqual(app.activities.first?.status, .completed)
    }

    // MARK: 12. Progress

    /// The fetch fills the summary's first 40%; each summary step reported by
    /// the provider moves it on with a status, and completion reaches 100%.
    func testSummaryReportsItsStepsAsProgress() async throws {
        let harness = makeHarness()
        let app = harness.app
        select(app, .ollama, model: "model-a")
        XCTAssertTrue(app.enqueueSummary(for: topic("1")))
        try await waitUntil { harness.ai.waiting == 1 }
        let running = try XCTUnwrap(app.activities.first)
        XCTAssertEqual(running.phase, "generating")
        XCTAssertEqual(try XCTUnwrap(running.progress), WorkProgress.summary(ai: 0), accuracy: 1e-9)
        XCTAssertEqual(running.statusText, "Summarizing part 1 of 2…")

        harness.ai.gated = false
        harness.ai.releaseAll()
        try await waitUntil { app.activities.allSatisfy(\.status.isTerminal) }
        XCTAssertEqual(app.activities.first?.progress, 1)
    }

    /// A chat answer has no knowable progress: the bar is indeterminate
    /// (nil) while the model answers.
    func testChatIsIndeterminateWhileAnswering() async throws {
        var session = TopicSession(siteURL: site, topicID: "1", url: topic("1").url, title: "Topic 1")
        session.source = "Existing source"
        let harness = makeHarness(snapshot: AppSnapshot(sessions: [session]))
        let app = harness.app
        select(app, .ollama, model: "model-a")
        app.select(topic: topic("1"))
        app.chatDraft = "A question"
        app.sendChat()
        try await waitUntil { harness.ai.waiting == 1 }
        let running = try XCTUnwrap(app.activities.first)
        XCTAssertEqual(running.phase, "generating")
        XCTAssertNil(running.progress)
        harness.ai.releaseAll()
        try await waitUntil { app.activities.allSatisfy(\.status.isTerminal) }
    }

    /// The agent's bar is the steps used of its budget.
    func testAgentProgressFollowsItsSteps() async throws {
        let planner = SteppingPlanner()
        let harness = makeHarness(planner: planner)
        let app = harness.app
        select(app, .ollama, model: "model-a")
        app.settings.agentMaxSteps = 9

        app.startAgentRun(goal: "Keep looking", siteURL: site)
        var seen: [Double] = []
        for step in 1...3 {
            try await waitUntil { planner.calls == step && planner.isWaiting }
            let progress = try XCTUnwrap(app.activities.first { $0.type == .agent }?.progress)
            XCTAssertEqual(progress, WorkProgress.agent(completedSteps: step - 1, maxSteps: 9), accuracy: 1e-9)
            seen.append(progress)
            planner.release()
        }
        XCTAssertEqual(seen, seen.sorted())
        XCTAssertGreaterThan(seen.last ?? 0, 0)
        app.cancel(record: try XCTUnwrap(app.activities.first { $0.type == .agent }))
        planner.release()
    }

    // MARK: Helpers

    private struct Harness {
        let app: AppModel
        let store: PersistentStore
        let keys: InMemoryProviderKeyStore
        let ai: StateAIStub
        /// Hands a page context to the model as the browser would. The real
        /// web view's own reports are disconnected so they cannot interfere.
        let deliver: (PageContext) -> Void
    }

    private func makeHarness(snapshot: AppSnapshot? = nil, planner: AgentPlanner? = nil) -> Harness {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let keys = InMemoryProviderKeyStore()
        let store = PersistentStore(fileURL: directory.appendingPathComponent("state.json"), keys: keys)
        if let snapshot { try? store.save(snapshot) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StateForumStub.self]
        let session = URLSession(configuration: configuration)
        let ai = StateAIStub()
        let app = AppModel(
            store: store,
            forumService: ForumService(session: session),
            aiService: ai,
            planner: planner
        )
        app.usesDirectForumRequests = true
        let handler = app.browser.onPageContextChanged
        app.browser.onPageContextChanged = nil
        addTeardownBlock { @MainActor in
            for record in app.activities where !record.status.isTerminal { app.cancel(record: record) }
            ai.gated = false
            ai.releaseAll()
            StateForumStub.release()
        }
        return Harness(app: app, store: store, keys: keys, ai: ai, deliver: { handler?($0) })
    }

    private func select(_ app: AppModel, _ provider: AIProvider, model: String, key: String = "") {
        app.settings.selectedProvider = provider
        var configuration = app.settings.configuration(for: provider)
        configuration.model = model
        configuration.apiKey = key
        app.setConfiguration(configuration, for: provider)
    }

    private func setKey(_ app: AppModel, _ key: String) {
        var configuration = app.selectedConfiguration
        configuration.apiKey = key
        app.setConfiguration(configuration, for: app.settings.selectedProvider)
    }

    private func topic(_ id: String, site: String? = nil) -> ForumTopic {
        let siteURL = site ?? self.site
        return ForumTopic(
            siteURL: siteURL,
            topicID: id,
            url: URL(string: "\(siteURL)/t/topic-\(id)/\(id)")!,
            title: "Topic \(id)"
        )
    }

    private func topicPage(_ topic: ForumTopic) -> PageContext {
        PageContext(
            url: topic.url,
            isDiscourse: true,
            siteURL: topic.siteURL,
            forumName: ForumSite.host(of: topic.siteURL),
            topic: topic,
            state: .topic
        )
    }

    private func finishedRun() -> AgentRun {
        var run = AgentRun(siteURL: site, goal: "Old question", provider: .ollama, model: "model-a")
        run.status = .completed
        run.answer = "Old answer"
        return run
    }

    private func waitUntil(
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: () -> Bool
    ) async throws {
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

// MARK: - Stubs

/// Stands in for the AI provider: records what each call ran with, streams
/// one delta, then (while `gated`) waits until the test releases it —
/// ignoring task cancellation, like a provider that answers anyway.
private final class StateAIStub: AIService {
    struct Call {
        var kind: String
        var provider: AIProvider
        var configuration: ProviderConfiguration
        var batchLimit: Int?
        var contextLimit: Int?
        var customPrompt = ""

        var label: String { "\(provider.rawValue)/\(configuration.model)" }
    }

    @MainActor var calls: [Call] = []
    @MainActor var gated = true
    @MainActor var failConnection = false
    @MainActor private var waiters: [CheckedContinuation<Void, Never>] = []
    @MainActor var waiting: Int { waiters.count }

    init() {
        super.init(session: .shared)
    }

    @MainActor func releaseAll() {
        let pending = waiters
        waiters = []
        pending.forEach { $0.resume() }
    }

    @MainActor private func arrive(_ call: Call, delta: String? = nil, onDelta: (@MainActor (String) -> Void)? = nil) async {
        calls.append(call)
        if let delta { onDelta?(delta) }
        guard gated else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    override func generateSummary(
        content: String,
        configuration: ProviderConfiguration,
        provider: AIProvider,
        customPrompt: String,
        batchLimit: Int = SummaryBatchLimit.default,
        onDelta: @escaping @MainActor (String) -> Void,
        onProgress: @escaping @MainActor (SummaryProgressEvent) -> Void = { _ in }
    ) async throws -> String {
        await onProgress(.batchStarted(level: 1, index: 0, count: 2))
        let call = Call(kind: "summary", provider: provider, configuration: configuration,
                        batchLimit: batchLimit, customPrompt: customPrompt)
        await arrive(call, delta: "[\(call.label)]", onDelta: onDelta)
        return "Summary by \(call.label)"
    }

    override func answer(
        source: String,
        summary: String,
        history: [ChatMessage],
        contextLimit: Int,
        customPrompt: String,
        configuration: ProviderConfiguration,
        provider: AIProvider,
        onDelta: @escaping @MainActor (String) -> Void,
        summaryIsStale: Bool = false
    ) async throws -> String {
        let call = Call(kind: "chat", provider: provider, configuration: configuration,
                        contextLimit: contextLimit, customPrompt: customPrompt)
        await arrive(call, delta: "[\(call.label)]", onDelta: onDelta)
        return "Answer by \(call.label)"
    }

    override func testConnection(configuration: ProviderConfiguration, provider: AIProvider) async throws {
        await arrive(Call(kind: "test", provider: provider, configuration: configuration))
        if await failConnection { throw AssistantError.http(401, "Bad key") }
    }

    override func discoverModels(configuration: ProviderConfiguration, provider: AIProvider) async throws -> [String] {
        await arrive(Call(kind: "models", provider: provider, configuration: configuration))
        return ["\(provider.rawValue)-model"]
    }
}

/// Answers each step with `saved_summaries` (no network), waiting for the
/// test to release it.
private final class SteppingPlanner: AgentPlanner, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var callCount = 0
    private var transcript: [ChatMessage] = []

    var calls: Int { lock.withLock { callCount } }
    var isWaiting: Bool { lock.withLock { continuation != nil } }
    var lastTranscript: [ChatMessage] { lock.withLock { transcript } }

    func release() {
        lock.withLock {
            continuation?.resume()
            continuation = nil
        }
    }

    func nextAction(
        system: String,
        transcript: [ChatMessage],
        configuration: ProviderConfiguration,
        provider: AIProvider
    ) async throws -> AgentAction {
        await withCheckedContinuation { continuation in
            lock.withLock {
                callCount += 1
                self.transcript = transcript
                self.continuation = continuation
            }
        }
        return AgentAction(thought: "", tool: "saved_summaries", arguments: [:])
    }
}

/// Forum endpoints for any `/t/{id}.json`, `/raw/{id}`, and
/// `/site/basic-info.json`. One path at a time can be held until released.
private final class StateForumStub: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var gatedPath: String?
    nonisolated(unsafe) private static var held: (() -> Void)?
    nonisolated(unsafe) private static var seen: [String] = []
    nonisolated(unsafe) private static var counts: [String: Int] = [:]

    static var postCounts: [String: Int] {
        get { lock.withLock { counts } }
        set { lock.withLock { counts = newValue } }
    }

    static var isWaiting: Bool { lock.withLock { held != nil } }

    static func reset() {
        lock.withLock {
            gatedPath = nil
            held = nil
            seen = []
            counts = [:]
        }
    }

    static func gate(path: String) {
        lock.withLock { gatedPath = path }
    }

    static func release() {
        let respond: (() -> Void)? = lock.withLock {
            let value = held
            held = nil
            gatedPath = nil
            return value
        }
        respond?()
    }

    static func count(of path: String) -> Int {
        lock.withLock { seen.filter { $0 == path }.count }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url?.path ?? ""
        let respond = { [self] in
            let (status, body) = Self.body(for: path)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
        let hold: Bool = Self.lock.withLock {
            Self.seen.append(path)
            guard Self.gatedPath == path, Self.held == nil else { return false }
            Self.held = respond
            return true
        }
        if !hold { respond() }
    }

    override func stopLoading() {}

    private static func body(for path: String) -> (Int, String) {
        let parts = path.split(separator: "/").map(String.init)
        if path == "/site/basic-info.json" {
            return (200, #"{"title":"Stub Forum"}"#)
        }
        if parts.count == 2, parts[0] == "t", parts[1].hasSuffix(".json") {
            let id = String(parts[1].dropLast(5))
            let posts = postCounts[id] ?? 2
            return (200, #"{"title":"Topic \#(id)","slug":"topic-\#(id)","posts_count":\#(posts)}"#)
        }
        if parts.count == 2, parts[0] == "raw" {
            return (200, "Post 1 of topic \(parts[1])\n\n\nPost 2")
        }
        return (404, "missing")
    }
}
