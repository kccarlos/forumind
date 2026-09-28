import XCTest
@testable import Forumind

/// Sync between simulated devices through `FakeCloudServer` (no CloudKit):
/// each device has its own app state, controller, merge engine and fake
/// `CKSyncEngine`. `sync(a, b)` runs fetch → merge → send on each in turn.
@MainActor
final class CloudSyncTests: XCTestCase {
    private let site = "https://forum.example.com"
    private let other = "https://other.example.org"

    struct Device {
        let app: AppModel
        let sync: CloudSyncController
        let transport: FakeCloudTransport
        let providerKeys: InMemoryProviderKeyStore
        let directory: URL
    }

    private var server: FakeCloudServer!

    override func setUp() async throws {
        server = FakeCloudServer()
    }

    // MARK: Helpers

    private func makeDevice(
        _ snapshot: AppSnapshot = AppSnapshot(),
        apiKeys: [AIProvider: String] = [:],
        user: String? = "user-1",
        defaults: UserDefaults? = nil
    ) throws -> Device {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cloudsync-\(UUID().uuidString)", isDirectory: true)
        let providerKeys = InMemoryProviderKeyStore(apiKeys)
        let store = PersistentStore(fileURL: directory.appendingPathComponent("state.json"), keys: providerKeys)
        var snapshot = snapshot
        snapshot.settings.hasCompletedOnboarding = true
        try store.save(snapshot)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return launch(directory: directory, providerKeys: providerKeys, user: user, defaults: defaults)
    }

    /// The app (re)launched from what is on disk in `directory`.
    private func launch(
        directory: URL,
        providerKeys: InMemoryProviderKeyStore,
        user: String? = "user-1",
        defaults: UserDefaults? = nil
    ) -> Device {
        let store = PersistentStore(fileURL: directory.appendingPathComponent("state.json"), keys: providerKeys)
        let transport = FakeCloudTransport(server: server, user: user)
        let sync = CloudSyncController(
            transport: transport,
            files: CloudSyncFiles(directory: directory),
            defaults: defaults,
            schedulesAutomatically: false
        )
        let app = AppModel(store: store, cloudSync: sync)
        app.browser.onPageContextChanged = nil
        return Device(app: app, sync: sync, transport: transport, providerKeys: providerKeys, directory: directory)
    }

    private func relaunch(_ device: Device) -> Device {
        launch(directory: device.directory, providerKeys: device.providerKeys, user: device.transport.user)
    }

    private func sync(_ devices: Device...) async {
        for device in devices { await device.sync.performSync() }
    }

    /// Server writes (saves + deletes) while `body` runs.
    private func writes(during body: () async -> Void) async -> Int {
        let before = server.writes
        await body()
        return server.writes - before
    }

    private func topic(_ id: String, site: String? = nil) -> ForumTopic {
        let siteURL = site ?? self.site
        return ForumTopic(siteURL: siteURL, topicID: id, url: URL(string: "\(siteURL)/t/topic-\(id)/\(id)")!, title: "Topic \(id)")
    }

    private func session(_ id: String, summary: String = "", chat: [String] = [], minutesAgo: Double = 10) -> TopicSession {
        let t = topic(id)
        var session = TopicSession(siteURL: t.siteURL, topicID: t.topicID, url: t.url, title: t.title)
        let date = Date(timeIntervalSinceNow: -minutesAgo * 60)
        session.summary = summary
        session.summaryUpdatedAt = summary.isEmpty ? nil : date
        session.source = "LOCAL SOURCE \(id)"
        session.rawPages = [RawForumPage(page: 1, content: "raw \(id)")]
        session.history = chat.enumerated().map { ChatMessage(role: $0.offset % 2 == 0 ? .user : .assistant, content: $0.element, createdAt: date) }
        session.chatUpdatedAt = chat.isEmpty ? nil : date
        session.totalPosts = 10
        session.createdAt = date
        session.updatedAt = date
        session.lastAccessedAt = date
        return session
    }

    private func run(goal: String, minutesAgo: Double = 30, steps: Int = 3) -> AgentRun {
        var run = AgentRun(siteURL: site, goal: goal, provider: .anthropic, model: "claude")
        let date = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970 - minutesAgo * 60))
        run.status = .completed
        run.createdAt = date
        run.updatedAt = date
        run.completedAt = date
        run.answer = "Answer to \(goal)"
        run.initialAnswer = run.answer
        run.steps = (0..<steps).map {
            AgentStep(tool: "search_forum", arguments: ["query": "q\($0)"], outcome: "found \($0)", startedAt: date, finishedAt: date)
        }
        run.transcript = [ChatMessage(role: .user, content: goal, createdAt: date)]
        return run
    }

    private func watched(_ id: String, posts: Int) -> WatchedTopic {
        let t = topic(id)
        return WatchedTopic(siteURL: t.siteURL, topicID: t.topicID, url: t.url, title: t.title, knownPostCount: posts)
    }

    private func canonical<T: Encodable>(_ value: T) throws -> Data {
        try SyncCoding.data(value)
    }

    private func name(_ kind: SyncKind, _ id: String) -> String {
        SyncRecord.recordName(kind: kind, id: id)
    }

    /// The decrypted payload of every record on the server.
    private func serverPlaintexts(_ user: String = "user-1") throws -> [String: String] {
        try server.records(user).mapValues {
            String(decoding: try SyncPayload.canonical(from: $0.payload), as: UTF8.self)
        }
    }

    // MARK: Convergence

    func testTwoDevicesConvergeAndThenSendNothing() async throws {
        let a = try makeDevice(AppSnapshot(
            sessions: [session("1", summary: "Summary one", chat: ["Q", "A"]), session("2", summary: "Summary two")],
            agentRuns: [run(goal: "Goal A")],
            watchedTopics: [watched("1", posts: 12)],
            forums: [Forum(siteURL: site, name: "Example", isPinned: true, pinOrder: 0)]
        ))
        a.app.settings.systemPrompt = "Be brief."
        a.app.flushPendingSaves()
        let b = try makeDevice(AppSnapshot(
            sessions: [session("3", summary: "Summary three")],
            agentRuns: [run(goal: "Goal B", minutesAgo: 5)],
            forums: [Forum(siteURL: other, name: "Other")]
        ))

        await sync(a, b, a, b)

        for device in [a, b] {
            XCTAssertEqual(Set(device.app.sessions.keys), Set(["1", "2", "3"].map { topic($0).topicKey }))
            XCTAssertEqual(Set(device.app.agentRuns.map(\.goal)), ["Goal A", "Goal B"])
            XCTAssertEqual(device.app.watchedTopics.map(\.knownPostCount), [12])
            XCTAssertEqual(Set(device.app.forums.map(\.siteURL)), [site, other])
            XCTAssertEqual(device.app.settings.systemPrompt, "Be brief.")
            XCTAssertEqual(device.sync.status, .upToDate)
            XCTAssertNotNil(device.sync.lastSyncedAt)
        }
        XCTAssertEqual(b.app.sessions[topic("1").topicKey]?.summary, "Summary one")
        XCTAssertEqual(b.app.sessions[topic("1").topicKey]?.history.map(\.content), ["Q", "A"])
        // The fetched topic text never leaves the device.
        XCTAssertEqual(b.app.sessions[topic("1").topicKey]?.source, "")
        XCTAssertEqual(a.app.sessions[topic("1").topicKey]?.source, "LOCAL SOURCE 1")
        XCTAssertEqual(b.app.forums.first { $0.siteURL == site }?.isPinned, true)
        // settings + 3 sessions + 2 runs + 1 watched + 2 forums
        XCTAssertEqual(server.records().count, 9)

        // Converged: fetches keep coming back with nothing to send.
        let sent = await writes { await sync(a, b, a, b) }
        XCTAssertEqual(sent, 0)
        XCTAssertEqual(a.sync.lastPassQueued + b.sync.lastPassQueued, 0)

        // A relaunch (state, baseline, mirror and engine state from disk;
        // dates truncated) is still converged.
        let relaunched = relaunch(a)
        let afterRelaunch = await writes { await sync(relaunched) }
        XCTAssertEqual(afterRelaunch, 0)
        XCTAssertEqual(relaunched.sync.status, .upToDate)
        XCTAssertEqual(relaunched.app.sessions.count, 3)
    }

    func testFetchWithoutPushPicksUpChanges() async throws {
        let key = topic("1").topicKey
        let a = try makeDevice(AppSnapshot(sessions: [session("1", summary: "S")]))
        let b = try makeDevice()
        await sync(a, b)
        a.app.setInstructions("New instructions", topicKey: key)
        await sync(a)
        // No push reaches B; its next fetch (foreground, Sync now) does.
        XCTAssertEqual(b.app.sessions[key]?.instructions, "")
        try await b.transport.fetchChanges()
        XCTAssertEqual(b.app.sessions[key]?.instructions, "New instructions")
    }

    func testWatchCheckTimesStayOnTheDeviceAndSendNothing() async throws {
        let a = try makeDevice(AppSnapshot(
            sessions: [session("1", summary: "Summary one")],
            watchedTopics: [watched("1", posts: 12)]
        ))
        let b = try makeDevice()
        await sync(a, b, a, b)

        // A watch check on A only moves its local "last checked" times.
        let checkedAt = Date(timeIntervalSince1970: 1_800_000_000)
        var sessions = a.app.sessions
        sessions[topic("1").topicKey]?.lastCheckedAt = checkedAt
        var watchedTopics = a.app.watchedTopics
        watchedTopics[0].lastCheckedAt = checkedAt
        a.app.replaceSyncedData(
            sessions: sessions, agentRuns: a.app.agentRuns,
            watchedTopics: watchedTopics, forums: a.app.forums
        )
        let sent = await writes { await sync(a, b, a, b) }

        XCTAssertEqual(sent, 0)
        XCTAssertEqual(a.app.watchedTopics.first?.lastCheckedAt, checkedAt)
        XCTAssertNotEqual(b.app.watchedTopics.first?.lastCheckedAt, checkedAt)
        XCTAssertNotEqual(b.app.sessions[topic("1").topicKey]?.lastCheckedAt, checkedAt)
    }

    func testEditsOnBothDevicesMergePerField() async throws {
        let key = topic("1").topicKey
        let a = try makeDevice(AppSnapshot(sessions: [session("1", summary: "S")]))
        let b = try makeDevice()
        await sync(a, b)

        a.app.setKept(true, topicKey: key)
        b.app.setInstructions("Focus on data points", topicKey: key)
        await sync(a, b, a)

        for device in [a, b] {
            XCTAssertEqual(device.app.sessions[key]?.kept, true)
            XCTAssertEqual(device.app.sessions[key]?.instructions, "Focus on data points")
            XCTAssertEqual(device.app.sessions[key]?.summary, "S")
        }
    }

    /// Both devices edit the same record before either fetches: the second
    /// save is rejected (`serverRecordChanged`), merged with the server's
    /// copy, and saved again.
    func testConcurrentEditConflictIsMergedAndResent() async throws {
        let key = topic("1").topicKey
        let a = try makeDevice(AppSnapshot(sessions: [session("1", summary: "S")]))
        let b = try makeDevice()
        await sync(a, b)

        a.app.setKept(true, topicKey: key)
        b.app.setInstructions("From B", topicKey: key)
        await a.sync.performPass()
        await b.sync.performPass()
        try await a.transport.sendChanges()
        try await b.transport.sendChanges()
        XCTAssertEqual(b.transport.conflicts, 1)

        await sync(a, b)
        for device in [a, b] {
            XCTAssertEqual(device.app.sessions[key]?.kept, true)
            XCTAssertEqual(device.app.sessions[key]?.instructions, "From B")
        }
        let sent = await writes { await sync(a, b, a) }
        XCTAssertEqual(sent, 0)
        XCTAssertEqual(server.records().count, 2) // settings, one session
    }

    // MARK: Settings

    func testSettingsMergePerFieldAndDeviceLocalSettingsStayPut() async throws {
        let a = try makeDevice()
        let b = try makeDevice()
        b.app.settings.browserBarPosition = .bottom
        b.app.settings.syncAPIKeys = false
        b.app.flushPendingSaves()
        await sync(a, b, a)

        a.app.settings.systemPrompt = "From A"
        a.app.settings.browserBarPosition = .top
        a.app.flushPendingSaves()
        b.app.settings.forumContextLimit = 45_000
        b.app.settings.blockTrackers = true
        b.app.settings.forumRequestPace = .fast
        b.app.flushPendingSaves()
        a.sync.clock = { Date().addingTimeInterval(2) }
        b.sync.clock = { Date().addingTimeInterval(3) }
        await sync(a, b, a, b)

        for device in [a, b] {
            XCTAssertEqual(device.app.settings.systemPrompt, "From A")
            XCTAssertEqual(device.app.settings.forumContextLimit, 45_000)
            XCTAssertTrue(device.app.settings.blockTrackers)
            XCTAssertEqual(device.app.settings.forumRequestPace, .fast)
        }
        XCTAssertEqual(b.app.settings.browserBarPosition, .bottom)
        XCTAssertFalse(b.app.settings.syncAPIKeys)
        XCTAssertTrue(a.app.settings.syncAPIKeys)
        let units = try SyncSchema.settingsUnits(a.app.settings)
        for key in SyncSettings.deviceLocalKeys { XCTAssertNil(units[key]) }
        let settingsRecord = try XCTUnwrap(serverPlaintexts()["settings"])
        for key in SyncSettings.deviceLocalKeys { XCTAssertFalse(settingsRecord.contains("\"\(key)\""), key) }
    }

    func testJoiningDeviceAdoptsTheCloudSettings() async throws {
        let a = try makeDevice()
        a.app.settings.systemPrompt = "Customized"
        a.app.settings.agentMaxSteps = 25
        a.app.flushPendingSaves()
        await sync(a)
        let b = try makeDevice()
        await sync(b, a)
        XCTAssertEqual(b.app.settings.systemPrompt, "Customized")
        XCTAssertEqual(b.app.settings.agentMaxSteps, 25)
        XCTAssertEqual(a.app.settings.systemPrompt, "Customized")
    }

    // MARK: Model roles

    /// The two model roles are separate settings units: one device changes
    /// the summaries & chat model, the other the Ask the forum model, and
    /// both changes survive on both devices.
    func testTwoDevicesEditingDifferentModelRolesKeepBoth() async throws {
        let a = try makeDevice()
        let b = try makeDevice()
        await sync(a, b, a)

        let cheap = ModelSelection(provider: .gemini, model: "gemini-3.1-flash-lite")
        let agentic = ModelSelection(provider: .deepSeek, model: "deepseek-v4-flash")
        a.app.selectModel(cheap, for: .role(.assistant))
        a.app.flushPendingSaves()
        b.app.selectModel(agentic, for: .role(.agent))
        b.app.flushPendingSaves()
        a.sync.clock = { Date().addingTimeInterval(2) }
        b.sync.clock = { Date().addingTimeInterval(3) }
        await sync(a, b, a, b)

        for device in [a, b] {
            XCTAssertEqual(device.app.settings.assistantModel, cheap)
            XCTAssertEqual(device.app.settings.agentModel, agentic)
            // What builds without roles read follows the assistant role.
            XCTAssertEqual(device.app.settings.selectedProvider, .gemini)
            XCTAssertEqual(device.app.settings.configuration(for: .gemini).model, "gemini-3.1-flash-lite")
        }
        let units = try SyncSchema.settingsUnits(a.app.settings)
        XCTAssertNotNil(units["assistantModel"])
        XCTAssertNotNil(units["agentModel"])
        XCTAssertNotNil(units["selectedProvider"])
        let writes = await writes { await sync(a, b) }
        XCTAssertEqual(writes, 0, "the devices agree and stop sending")
    }

    /// A role that arrives pointing at a provider this device has no key
    /// for: that role isn't ready here, the other one is unaffected.
    func testSyncedRoleForAProviderWithoutAKeyHereOnlyAffectsThatRole() async throws {
        let a = try makeDevice(apiKeys: [.deepSeek: "sk-a"])
        let b = try makeDevice()
        a.app.selectModel(ModelSelection(provider: .ollama, model: "llama3.2"), for: .both)
        a.app.flushPendingSaves()
        await sync(a, b)
        XCTAssertTrue(b.app.isProviderReady)

        a.app.selectModel(ModelSelection(provider: .deepSeek, model: "deepseek-v4-flash"), for: .role(.agent))
        a.app.flushPendingSaves()
        await sync(a, b)
        XCTAssertEqual(b.app.settings.agentModel.provider, .deepSeek)
        XCTAssertFalse(b.app.isProviderReady(for: .agent))
        XCTAssertTrue(b.app.isProviderReady(for: .assistant))
        XCTAssertTrue(a.app.isProviderReady(for: .agent))
        XCTAssertEqual(b.app.settings.configuration(for: .deepSeek).apiKey, "")
    }

    /// A settings record from a build without roles: it carries no role
    /// units, and its provider change moves the assistant role only.
    func testSettingsFromABuildWithoutRolesMoveOnlyTheAssistantRole() async throws {
        let a = try makeDevice()
        let agentic = ModelSelection(provider: .deepSeek, model: "deepseek-v4-flash")
        a.app.selectModel(ModelSelection(provider: .gemini, model: "gemini-3.1-flash-lite"), for: .role(.assistant))
        a.app.selectModel(agentic, for: .role(.agent))

        var legacyUnits = try SyncSchema.settingsUnits(a.app.settings)
        legacyUnits.removeValue(forKey: "assistantModel")
        legacyUnits.removeValue(forKey: "agentModel")
        legacyUnits["selectedProvider"] = .string("groq")
        legacyUnits["configurations.groq"] = .object([
            "model": .string("llama-legacy"),
            "baseURL": .string(AIProvider.groq.defaultBaseURL)
        ])
        a.app.settings = try SyncSchema.applying(settingsUnits: legacyUnits, to: a.app.settings)
        XCTAssertEqual(a.app.settings.assistantModel, ModelSelection(provider: .groq, model: "llama-legacy"))
        XCTAssertEqual(a.app.settings.agentModel, agentic)
        XCTAssertEqual(a.app.settings.selectedProvider, .groq)
    }

    /// One pass the way CKSyncEngine runs in the app: a fetch triggers a pass
    /// (`didFetch`) and the engine sends what it queued right away
    /// (`automaticallySync`), before any later pass.
    private func fetchAndSend(_ device: Device, at time: Date) async {
        device.sync.clock = { time }
        try? await device.transport.fetchChanges()
        try? await device.transport.sendChanges()
    }

    /// The server's settings units, as plain JSON values.
    private func serverSettingsUnits() throws -> [String: JSONValue] {
        let record = try XCTUnwrap(server.records()["settings"])
        let decoded = try SyncPayload.decode(record.payload).record
        return try XCTUnwrap(decoded.fields)
    }

    /// Both devices run the same summaries & chat model, stored consistently
    /// for older builds too, and match the server.
    private func assertModelRolesConverged(
        _ a: Device, _ b: Device, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        for device in [a, b] {
            let settings = device.app.settings
            XCTAssertEqual(settings.selectedProvider, settings.assistantModel.provider, file: file, line: line)
            XCTAssertEqual(
                settings.configuration(for: settings.assistantModel.provider).model, settings.assistantModel.model,
                file: file, line: line
            )
            XCTAssertEqual(try SyncSchema.settingsUnits(settings), try serverSettingsUnits(), file: file, line: line)
        }
        XCTAssertEqual(a.app.settings.assistantModel, b.app.settings.assistantModel, file: file, line: line)
    }

    /// One device changes the summaries & chat model; the other, not synced
    /// yet, edits the same provider's address, so its configuration unit
    /// (newer) carries the old model. Each device used to settle the mixed
    /// record against its own previous state, in opposite directions, and
    /// with CKSyncEngine sending after every fetch-triggered pass the model
    /// flipped between the devices forever. Now the merge settles it once.
    func testMixedModelUnitsFromTwoDevicesSettleOnceAndStopSending() async throws {
        let a = try makeDevice()
        let b = try makeDevice()
        var now = SyncCoding.stamp(Date())
        func next() -> Date {
            now = now.addingTimeInterval(5)
            return now
        }
        a.sync.clock = { now }
        b.sync.clock = { now }
        a.app.selectModel(ModelSelection(provider: .gemini, model: "gemini-old"), for: .both)
        a.app.flushPendingSaves()
        await sync(a, b, a)
        XCTAssertEqual(b.app.settings.assistantModel.model, "gemini-old")

        a.app.selectModel(ModelSelection(provider: .gemini, model: "gemini-new"), for: .role(.assistant))
        a.app.flushPendingSaves()
        await fetchAndSend(a, at: next())

        var configuration = b.app.settings.configuration(for: .gemini)
        configuration.baseURL = "https://proxy.example.com/v1beta"
        b.app.settings.setConfiguration(configuration, for: .gemini)
        b.app.flushPendingSaves()
        await fetchAndSend(b, at: next())
        await fetchAndSend(a, at: next())

        try assertModelRolesConverged(a, b)
        for device in [a, b] {
            XCTAssertEqual(device.app.settings.configuration(for: .gemini).baseURL, "https://proxy.example.com/v1beta")
            XCTAssertEqual(device.app.settings.agentModel, ModelSelection(provider: .gemini, model: "gemini-old"))
        }
        let sent = await writes {
            for device in [b, a, b, a] { await fetchAndSend(device, at: next()) }
            await sync(a, b)
        }
        XCTAssertEqual(sent, 0, "settled devices stop sending")
        try assertModelRolesConverged(a, b)
    }

    /// Two devices pick different summaries & chat models on the same
    /// provider in the same second: the tie is broken per unit, so the merged
    /// record can pair one device's `assistantModel` with the other's
    /// configuration. The merge settles it the same way on both devices.
    func testSameSecondAssistantModelTieOnOneProviderSettlesOnce() async throws {
        let a = try makeDevice()
        let b = try makeDevice()
        let base = SyncCoding.stamp(Date())
        a.sync.clock = { base }
        b.sync.clock = { base }
        await sync(a, b, a)

        let tie = base.addingTimeInterval(10)
        a.app.selectModel(ModelSelection(provider: .gemini, model: "gemini-a"), for: .role(.assistant))
        a.app.flushPendingSaves()
        b.app.selectModel(ModelSelection(provider: .gemini, model: "gemini-z"), for: .role(.assistant))
        b.app.flushPendingSaves()
        await fetchAndSend(a, at: tie)
        await fetchAndSend(b, at: tie)
        await fetchAndSend(a, at: base.addingTimeInterval(20))

        try assertModelRolesConverged(a, b)
        XCTAssertEqual(a.app.settings.assistantModel.provider, .gemini)
        var later = base.addingTimeInterval(20)
        let sent = await writes {
            for device in [b, a, b, a] {
                later = later.addingTimeInterval(5)
                await fetchAndSend(device, at: later)
            }
        }
        XCTAssertEqual(sent, 0, "settled devices stop sending")
    }

    /// The merge's settling of model roles, on records alone.
    func testMergeSettlesTheAssistantModelFromTheNewestUnit() throws {
        func record(
            assistant: ModelSelection, _ assistantStamp: TimeInterval,
            provider: AIProvider, _ providerStamp: TimeInterval,
            models: [AIProvider: (String, TimeInterval)]
        ) throws -> SyncRecord {
            var fields: [String: JSONValue] = [
                "assistantModel": try SyncCoding.json(assistant),
                "selectedProvider": .string(provider.rawValue)
            ]
            var stamps: [String: Date] = [
                "assistantModel": Date(timeIntervalSince1970: assistantStamp),
                "selectedProvider": Date(timeIntervalSince1970: providerStamp)
            ]
            for (provider, (model, stamp)) in models {
                fields["configurations.\(provider.rawValue)"] = .object(["model": .string(model), "baseURL": .string("u")])
                stamps["configurations.\(provider.rawValue)"] = Date(timeIntervalSince1970: stamp)
            }
            return SyncRecord(kind: .settings, id: "settings", fields: fields, stamps: stamps, deletedAt: nil)
        }
        func settled(_ record: SyncRecord) throws -> (ModelSelection, String?, String?) {
            let merged = try XCTUnwrap(SyncMerge.merge([record]))
            XCTAssertEqual(SyncMerge.merge([merged]), merged, "settling twice changes nothing")
            let fields = try XCTUnwrap(merged.fields)
            let assistant = try SyncCoding.decode(ModelSelection.self, from: try XCTUnwrap(fields["assistantModel"]))
            return (
                assistant,
                fields["selectedProvider"]?.stringValue,
                fields["configurations.\(assistant.provider.rawValue)"]?.objectValue?["model"]?.stringValue
            )
        }

        // An older build switched the provider after the role was chosen.
        var result = try settled(record(
            assistant: ModelSelection(provider: .gemini, model: "g"), 10, provider: .groq, 20,
            models: [.gemini: ("g", 10), .groq: ("llama", 5)]
        ))
        XCTAssertEqual(result.0, ModelSelection(provider: .groq, model: "llama"))
        XCTAssertEqual(result.1, "groq")
        // The role is newer than the provider: the provider follows it.
        result = try settled(record(
            assistant: ModelSelection(provider: .gemini, model: "g"), 20, provider: .groq, 10,
            models: [.gemini: ("old", 5), .groq: ("llama", 10)]
        ))
        XCTAssertEqual(result.0, ModelSelection(provider: .gemini, model: "g"))
        XCTAssertEqual(result.1, "gemini")
        XCTAssertEqual(result.2, "g")
        // Same provider, the configuration is newer (an older build's model
        // change, or an address edit elsewhere): the role takes its model.
        result = try settled(record(
            assistant: ModelSelection(provider: .gemini, model: "g"), 10, provider: .gemini, 10,
            models: [.gemini: ("g2", 20)]
        ))
        XCTAssertEqual(result.0, ModelSelection(provider: .gemini, model: "g2"))
        // A tie goes to the role.
        result = try settled(record(
            assistant: ModelSelection(provider: .gemini, model: "g"), 20, provider: .gemini, 20,
            models: [.gemini: ("g2", 20)]
        ))
        XCTAssertEqual(result.0, ModelSelection(provider: .gemini, model: "g"))
        XCTAssertEqual(result.2, "g")
    }

    /// The roles live inside the encrypted payload: the CloudKit record keeps
    /// its plain fields (kind, format, tombstone time) and nothing else.
    func testModelRolesAddNoPlainRecordFields() async throws {
        let a = try makeDevice()
        a.app.selectModel(ModelSelection(provider: .gemini, model: "gemini-3.1-flash-lite"), for: .role(.assistant))
        a.app.selectModel(ModelSelection(provider: .deepSeek, model: "deepseek-v4-flash"), for: .role(.agent))
        a.app.flushPendingSaves()
        await sync(a)

        let record = try XCTUnwrap(server.records()["settings"])
        XCTAssertEqual(record.kind, "settings")
        XCTAssertEqual(record.formatVersion, CloudRecord.formatVersion)
        XCTAssertEqual(CloudRecord.formatVersion, 1)
        let plain = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
        XCTAssertTrue(Set(plain.keys).isSubset(of: ["recordName", "kind", "formatVersion", "deletedAt", "payload", "systemFields"]), "\(plain.keys)")
        let payload = try XCTUnwrap(serverPlaintexts()["settings"])
        XCTAssertTrue(payload.contains("\"assistantModel\""))
        XCTAssertTrue(payload.contains("deepseek-v4-flash"))
        XCTAssertFalse(payload.contains("apiKey"))
    }

    // MARK: API keys

    func testAPIKeysNeverReachAnyRecordAndPulledSettingsKeepLocalKeys() async throws {
        let secret = "sk-SECRET-\(UUID().uuidString)"
        let a = try makeDevice(apiKeys: [.openAI: secret])
        var configuration = a.app.settings.configuration(for: .openAI)
        configuration.model = "gpt-5-mini"
        a.app.setConfiguration(configuration, for: .openAI)
        a.app.settings.selectedProvider = .openAI
        a.app.flushPendingSaves()
        XCTAssertEqual(a.app.settings.configuration(for: .openAI).apiKey, secret)
        let bSecret = "sk-B-\(UUID().uuidString)"
        let b = try makeDevice(apiKeys: [.openAI: bSecret])
        await sync(a, b, a)

        XCTAssertFalse(server.records().isEmpty)
        for (name, plaintext) in try serverPlaintexts() {
            XCTAssertFalse(plaintext.contains(secret), name)
            XCTAssertFalse(plaintext.contains(bSecret), name)
            XCTAssertFalse(plaintext.contains("apiKey"), name)
        }
        for record in server.records().values {
            let plain = try String(decoding: JSONEncoder().encode(record), as: UTF8.self)
            XCTAssertFalse(plain.contains(secret))
        }
        // B got the model and provider, and kept its own key.
        XCTAssertEqual(b.app.settings.selectedProvider, .openAI)
        XCTAssertEqual(b.app.settings.configuration(for: .openAI).model, "gpt-5-mini")
        XCTAssertEqual(b.app.settings.configuration(for: .openAI).apiKey, bSecret)
        XCTAssertEqual(b.providerKeys.value(for: .openAI), bSecret)
        XCTAssertEqual(a.app.settings.configuration(for: .openAI).apiKey, secret)
    }

    func testKeysArrivingInTheKeyStoreAreAdoptedByTheNextPass() async throws {
        let a = try makeDevice()
        await sync(a)
        try a.providerKeys.set("sk-arrived", for: .anthropic)
        await sync(a)
        XCTAssertEqual(a.app.settings.configuration(for: .anthropic).apiKey, "sk-arrived")
    }

    /// Keys changed on another device (iCloud Keychain) show up when the app
    /// returns to the foreground, with or without iCloud sync.
    func testKeysArrivingInTheKeyStoreAreAdoptedOnForeground() throws {
        let a = try makeDevice(user: nil)
        try a.providerKeys.set("sk-arrived", for: .anthropic)
        a.app.handleScenePhase(.active)
        XCTAssertEqual(a.app.settings.configuration(for: .anthropic).apiKey, "sk-arrived")
    }

    // MARK: Deletes, prunes, clears

    func testDeleteRacesAgainstEditByTime() async throws {
        let one = topic("1").topicKey, two = topic("2").topicKey
        let a = try makeDevice(AppSnapshot(sessions: [session("1", summary: "S1"), session("2", summary: "S2")]))
        let b = try makeDevice()
        await sync(a, b)

        // Topic 1: A's delete is newer than B's edit → deleted everywhere.
        // (A delete is stamped with the time it happens.)
        b.app.setKept(true, topicKey: one)
        await sync(b)
        a.sync.clock = { Date().addingTimeInterval(300) }
        a.app.deleteSession(topicKey: one)
        await sync(a, b, a)
        XCTAssertNil(a.app.sessions[one])
        XCTAssertNil(b.app.sessions[one])
        XCTAssertNotNil(server.records()[name(.session, one)]?.deletedAt, "a tombstone record")

        // Topic 2: A deletes (stamped in the past), B edited afterwards → it comes back.
        a.sync.clock = { Date().addingTimeInterval(-600) }
        a.app.deleteSession(topicKey: two)
        b.app.setKept(true, topicKey: two)
        await sync(b, a, b, a)
        XCTAssertEqual(a.app.sessions[two]?.kept, true)
        XCTAssertEqual(b.app.sessions[two]?.kept, true)
        XCTAssertEqual(a.app.sessions[two]?.summary, "S2")
    }

    func testLocalEditMadeDuringAPassIsNotClobbered() async throws {
        let key = topic("1").topicKey
        let a = try makeDevice(AppSnapshot(sessions: [session("1", summary: "S")]))
        let b = try makeDevice()
        await sync(a, b)
        a.app.setInstructions("Remote instructions", topicKey: key)
        await sync(a)

        // B fetches and computes the merge, then the user edits before it is applied.
        let modified = Array(server.records().values)
        await b.sync.engine.ingest(modified: modified, deleted: [])
        let plan = await b.sync.engine.plan(local: b.app.syncLocalState(), now: Date())
        XCTAssertEqual(plan.changes.sessions.count, 1)
        b.app.setKept(true, topicKey: key)
        let skipped = b.app.applyRemote(plan.changes)
        XCTAssertEqual(skipped, [SyncRecord.recordKey(kind: .session, id: key)])
        XCTAssertEqual(b.app.sessions[key]?.kept, true)
        XCTAssertEqual(b.app.sessions[key]?.instructions, "")

        // The next pass merges both edits.
        await sync(b, a)
        for device in [a, b] {
            XCTAssertEqual(device.app.sessions[key]?.kept, true)
            XCTAssertEqual(device.app.sessions[key]?.instructions, "Remote instructions")
        }
    }

    /// A delete made just before the app is killed keeps its real time: an
    /// edit made elsewhere after it wins, however late the next pass runs.
    func testDeletionLogSurvivesARelaunch() async throws {
        let base = SyncCoding.stamp(Date())
        let a = try makeDevice(AppSnapshot(forums: [Forum(siteURL: site, name: "Example"), Forum(siteURL: other, name: "Other")]))
        let b = try makeDevice()
        a.sync.clock = { base }
        b.sync.clock = { base }
        await sync(a, b)

        a.sync.clock = { base.addingTimeInterval(100) }
        a.app.removeForum(a.app.forum(for: site)!, deleteData: false)
        a.app.removeForum(a.app.forum(for: other)!, deleteData: false)
        XCTAssertEqual(Set(a.sync.deletionLog.keys), [
            SyncRecord.recordKey(kind: .forum, id: site), SyncRecord.recordKey(kind: .forum, id: other)
        ])
        // Killed before any pass. Meanwhile B pins one of them.
        b.sync.clock = { base.addingTimeInterval(200) }
        b.app.pin(b.app.forum(for: site)!)
        await sync(b)

        let relaunched = relaunch(a)
        XCTAssertEqual(relaunched.sync.deletionLog.count, 2)
        relaunched.sync.clock = { base.addingTimeInterval(24 * 60 * 60) }
        await sync(relaunched, b, relaunched)
        // The pin (t+200) is newer than the delete (t+100): it stays everywhere.
        XCTAssertEqual(relaunched.app.forum(for: site)?.isPinned, true)
        XCTAssertEqual(b.app.forum(for: site)?.isPinned, true)
        // The untouched one is deleted everywhere.
        XCTAssertNil(relaunched.app.forum(for: other))
        XCTAssertNil(b.app.forum(for: other))
        XCTAssertTrue(relaunched.sync.deletionLog.isEmpty)
        let sent = await writes { await sync(relaunched, b) }
        XCTAssertEqual(sent, 0)
    }

    func testPrunedSessionIsNotDeletedRemotelyOrReimportedUntilItChanges() async throws {
        let key = topic("1").topicKey
        let a = try makeDevice(AppSnapshot(sessions: [session("1", summary: "S1")]))
        let b = try makeDevice()
        await sync(a, b)

        // A prunes (no tombstone): B keeps it, A does not get it back.
        a.app.deleteSession(topicKey: key)
        a.sync.notePruned(kind: .session, ids: [key])
        XCTAssertTrue(a.sync.deletionLog.isEmpty)
        await sync(a, b, a, b, a)
        XCTAssertNil(a.app.sessions[key])
        XCTAssertNotNil(b.app.sessions[key])
        XCTAssertNil(server.records()[name(.session, key)]?.deletedAt)
        XCTAssertEqual(a.sync.lastPassQueued, 0)

        // B changes it: now it is news for A.
        b.app.setKept(true, topicKey: key)
        await sync(b, a)
        XCTAssertEqual(a.app.sessions[key]?.kept, true)
    }

    func testClearedChatStaysCleared() async throws {
        let key = topic("1").topicKey
        let a = try makeDevice(AppSnapshot(sessions: [session("1", summary: "S", chat: ["Q1", "A1", "Q2", "A2"])]))
        let b = try makeDevice()
        await sync(a, b)
        XCTAssertEqual(b.app.sessions[key]?.history.count, 4)

        b.app.select(topic: topic("1"))
        b.app.clearChat()
        await sync(b, a, b, a)
        XCTAssertEqual(a.app.sessions[key]?.history, [])
        XCTAssertEqual(b.app.sessions[key]?.history, [])
        XCTAssertEqual(a.app.sessions[key]?.summary, "S")
        let sent = await writes { await sync(a, b) }
        XCTAssertEqual(sent, 0)
    }

    func testRemovedForumDeletedRunAndUnwatchedTopicDisappearElsewhere() async throws {
        let goal = run(goal: "Goal")
        let a = try makeDevice(AppSnapshot(
            agentRuns: [goal],
            watchedTopics: [watched("1", posts: 3)],
            forums: [Forum(siteURL: site, name: "Example"), Forum(siteURL: other, name: "Other")]
        ))
        let b = try makeDevice()
        await sync(a, b)
        XCTAssertEqual(b.app.forums.count, 2)
        XCTAssertEqual(b.app.agentRuns.count, 1)

        a.sync.clock = { Date().addingTimeInterval(5) }
        a.app.removeForum(a.app.forum(for: other)!, deleteData: false)
        a.app.deleteAgentRun(id: goal.id)
        a.app.unwatch(topicKey: topic("1").topicKey)
        await sync(a, b)
        XCTAssertEqual(b.app.forums.map(\.siteURL), [site])
        XCTAssertTrue(b.app.agentRuns.isEmpty)
        XCTAssertTrue(b.app.watchedTopics.isEmpty)
    }

    func testRunningRunStaysOnItsDevice() async throws {
        var running = run(goal: "Still running")
        running.status = .running
        let a = try makeDevice(AppSnapshot(agentRuns: [run(goal: "Done")]))
        await sync(a)
        // Not restorable (no activity record): init marks it cancelled — so
        // check the rule with a pure plan instead.
        let state = SyncLocalState(settings: AppSettings(), sessions: [:], runs: [running], watched: [], forums: [])
        let plan = await a.sync.engine.plan(local: state, remote: .init(), now: Date())
        XCTAssertNil(plan.operations[SyncRecord.recordKey(kind: .run, id: running.id.uuidString)])
        XCTAssertNil(server.records()[name(.run, running.id.uuidString)])
    }

    func testTombstonesAreDeletedFromTheServerAfterSixtyDays() async throws {
        let a = try makeDevice(AppSnapshot(forums: [Forum(siteURL: site, name: "Example")]))
        await sync(a)
        a.app.removeForum(a.app.forums[0], deleteData: false)
        await sync(a)
        XCTAssertNotNil(server.records()[name(.forum, site)]?.deletedAt)
        a.sync.clock = { Date().addingTimeInterval(61 * 24 * 60 * 60) }
        // Back after 61 days: re-list first, then collect the tombstone.
        await sync(a, a)
        XCTAssertNil(server.records()[name(.forum, site)])
        let sent = await writes { await sync(a) }
        XCTAssertEqual(sent, 0)
    }

    /// A device away for longer than tombstones live doesn't bring back
    /// what was deleted meanwhile — unless it changed it itself.
    func testDeviceAwayLongerThanTombstonesLiveDoesNotResurrectDeletes() async throws {
        let third = "https://third.example.net"
        let a = try makeDevice(AppSnapshot(forums: [
            Forum(siteURL: site, name: "Example"), Forum(siteURL: other, name: "Other"), Forum(siteURL: third, name: "Third")
        ]))
        let b = try makeDevice()
        await sync(a, b)
        XCTAssertEqual(b.app.forums.count, 3)

        // A deletes two forums; B is away (no syncs) and pins one of them.
        a.sync.clock = { Date().addingTimeInterval(5) }
        a.app.removeForum(a.app.forum(for: site)!, deleteData: false)
        a.app.removeForum(a.app.forum(for: other)!, deleteData: false)
        await sync(a)
        b.app.pin(b.app.forum(for: other)!)
        // 61 days later the tombstones are gone.
        a.sync.clock = { Date().addingTimeInterval(61 * 24 * 60 * 60) }
        await sync(a, a)
        XCTAssertNil(server.records()[name(.forum, site)])
        XCTAssertNil(server.records()[name(.forum, other)])

        // B's change token expired meanwhile: it only sees what is there now.
        b.transport.start(state: nil)
        b.sync.clock = { Date().addingTimeInterval(61 * 24 * 60 * 60 + 60) }
        await sync(b, b, a)
        XCTAssertNil(b.app.forum(for: site), "unchanged on B: deleted, not re-uploaded")
        XCTAssertNil(server.records()[name(.forum, site)])
        XCTAssertEqual(b.app.forum(for: other)?.isPinned, true, "changed on B: kept")
        XCTAssertEqual(a.app.forum(for: other)?.isPinned, true)
        XCTAssertNotNil(b.app.forum(for: third))
        let sent = await writes { await sync(b, a) }
        XCTAssertEqual(sent, 0)
    }

    /// A record missing from the server on a recently synced device isn't a
    /// delete (its tombstone would still be there): it is uploaded again.
    func testMissingRecordOnARecentDeviceIsUploadedAgain() async throws {
        let a = try makeDevice(AppSnapshot(forums: [Forum(siteURL: site, name: "Example")]))
        await sync(a)
        server.removeRecord(name(.forum, site))
        await sync(a)
        XCTAssertNotNil(a.app.forum(for: site))
        XCTAssertNotNil(server.records()[name(.forum, site)])
    }

    /// A record whose save failed is never taken as deleted elsewhere later.
    func testFailedSaveIsRetriedAndNeverTakenAsADelete() async throws {
        let a = try makeDevice(AppSnapshot(forums: [Forum(siteURL: site, name: "Example")]))
        await sync(a)
        a.app.recordVisit(siteURL: other, name: "Other", iconURL: nil)
        server.failsSaves = true
        await sync(a)
        guard case .error = a.sync.status else { return XCTFail("status \(a.sync.status)") }
        XCTAssertNil(server.records()[name(.forum, other)])

        // Much later (the last pass is old), saves work again.
        server.failsSaves = false
        a.sync.clock = { Date().addingTimeInterval(61 * 24 * 60 * 60) }
        await sync(a, a)
        XCTAssertNotNil(a.app.forum(for: other))
        XCTAssertNotNil(server.records()[name(.forum, other)])
        XCTAssertEqual(a.sync.status, .upToDate)
    }

    /// Joining a zone that has an old tombstone for a record this device
    /// used after the delete keeps it; one it hasn't touched since is deleted.
    func testJoiningKeepsRecordsUsedAfterAnOldDelete() async throws {
        let base = SyncCoding.stamp(Date()).addingTimeInterval(-3 * 24 * 60 * 60)
        let a = try makeDevice(AppSnapshot(forums: [
            Forum(siteURL: site, name: "Example", addedAt: base.addingTimeInterval(-9000)),
            Forum(siteURL: other, name: "Other", addedAt: base.addingTimeInterval(-9000))
        ]))
        a.sync.clock = { base }
        await sync(a)
        a.app.removeForum(a.app.forum(for: site)!, deleteData: false)
        a.app.removeForum(a.app.forum(for: other)!, deleteData: false)
        await sync(a)

        let b = try makeDevice(AppSnapshot(forums: [
            Forum(siteURL: site, name: "Example", addedAt: base.addingTimeInterval(-7200), lastVisitedAt: base.addingTimeInterval(3600)),
            Forum(siteURL: other, name: "Other", addedAt: base.addingTimeInterval(-7200), lastVisitedAt: base.addingTimeInterval(-3600))
        ]))
        await sync(b, a)
        XCTAssertNotNil(b.app.forum(for: site), "visited after the delete: kept")
        XCTAssertNotNil(a.app.forum(for: site))
        XCTAssertNil(b.app.forum(for: other), "not used since the delete: deleted")
        XCTAssertNil(a.app.forum(for: other))
        let sent = await writes { await sync(b, a) }
        XCTAssertEqual(sent, 0)
    }

    /// A device whose clock runs a day ahead doesn't keep winning: an edit
    /// made after seeing its change beats it.
    func testClockAheadDoesNotBeatLaterEdits() async throws {
        let a = try makeDevice(AppSnapshot(forums: [Forum(siteURL: site, name: "Example")]))
        let b = try makeDevice()
        await sync(a, b)
        a.sync.clock = { Date().addingTimeInterval(24 * 60 * 60) }
        a.app.pin(a.app.forum(for: site)!)
        await sync(a, b)
        XCTAssertEqual(b.app.forum(for: site)?.isPinned, true)
        b.app.unpin(b.app.forum(for: site)!)
        await sync(b, a)
        XCTAssertEqual(a.app.forum(for: site)?.isPinned, false)
        XCTAssertEqual(b.app.forum(for: site)?.isPinned, false)
        let sent = await writes { await sync(a, b) }
        XCTAssertEqual(sent, 0)
    }

    /// A new device offline at first launch: the failed fetch doesn't look
    /// like an empty zone, so nothing is sent, and once online it adopts the
    /// cloud's settings instead of overwriting them with its defaults.
    func testOfflineJoinSendsNothingAndDoesNotClobberTheCloud() async throws {
        let a = try makeDevice(AppSnapshot(forums: [Forum(siteURL: site, name: "Example")]))
        a.app.settings.systemPrompt = "Customized"
        a.app.flushPendingSaves()
        await sync(a)

        let b = try makeDevice(AppSnapshot(forums: [Forum(siteURL: other, name: "Other")]))
        b.transport.failsFetches = true
        let offline = await writes { await sync(b, b) }
        XCTAssertEqual(offline, 0)
        XCTAssertEqual(b.sync.status, .syncing)
        XCTAssertNil(b.app.forum(for: site))

        b.transport.failsFetches = false
        await sync(b, a)
        for device in [a, b] {
            XCTAssertEqual(device.app.settings.systemPrompt, "Customized")
            XCTAssertEqual(Set(device.app.forums.map(\.siteURL)), [site, other])
        }
    }

    /// A long-absent device whose re-listing fetch fails deletes nothing.
    func testFailedRelistingDeletesNothing() async throws {
        let third = "https://third.example.net"
        let a = try makeDevice(AppSnapshot(forums: [
            Forum(siteURL: site, name: "Example"), Forum(siteURL: other, name: "Other"), Forum(siteURL: third, name: "Third")
        ]))
        let b = try makeDevice()
        await sync(a, b)
        a.sync.clock = { Date().addingTimeInterval(5) }
        a.app.removeForum(a.app.forum(for: site)!, deleteData: false)
        await sync(a)
        a.sync.clock = { Date().addingTimeInterval(61 * 24 * 60 * 60) }
        await sync(a, a)
        XCTAssertNil(server.records()[name(.forum, site)])

        b.transport.start(state: nil) // change token expired
        b.sync.clock = { Date().addingTimeInterval(61 * 24 * 60 * 60 + 60) }
        await sync(b) // notices the long absence, starts re-listing
        b.transport.failsFetches = true
        await sync(b, b)
        XCTAssertEqual(b.app.forums.count, 3, "an incomplete listing deletes nothing")
        let before = server.writes
        b.transport.failsFetches = false
        await sync(b)
        XCTAssertNil(b.app.forum(for: site))
        XCTAssertNotNil(b.app.forum(for: other))
        XCTAssertNotNil(b.app.forum(for: third))
        XCTAssertEqual(server.writes, before)
        XCTAssertNil(server.records()[name(.forum, site)])
    }

    // MARK: Zone and account events

    func testPurgedZoneIsRecreatedAndReuploadedWithoutDuplicates() async throws {
        let a = try makeDevice(AppSnapshot(
            sessions: [session("1", summary: "S")],
            forums: [Forum(siteURL: site, name: "Example")]
        ))
        let b = try makeDevice(AppSnapshot(forums: [Forum(siteURL: other, name: "Other")]))
        await sync(a, b, a)
        let count = server.records().count
        XCTAssertEqual(count, 4) // settings, session, two forums

        // The user deletes the app's iCloud data in Settings.
        server.deleteZone(reason: .purged)
        await sync(a)
        XCTAssertTrue(server.zone("user-1").exists)
        XCTAssertEqual(server.records().count, count)
        await sync(b, a)
        XCTAssertEqual(server.records().count, count)
        for device in [a, b] {
            XCTAssertEqual(device.app.sessions.count, 1)
            XCTAssertEqual(Set(device.app.forums.map(\.siteURL)), [site, other])
            XCTAssertTrue(device.sync.isEnabled)
        }
        let sent = await writes { await sync(a, b) }
        XCTAssertEqual(sent, 0)
    }

    func testEncryptedDataResetReuploads() async throws {
        let a = try makeDevice(AppSnapshot(forums: [Forum(siteURL: site, name: "Example")]))
        await sync(a)
        server.deleteZone(reason: .encryptedDataReset)
        await sync(a)
        XCTAssertNotNil(server.records()[name(.forum, site)])
        XCTAssertEqual(a.sync.status, .upToDate)
    }

    func testDeleteCloudDataRemovesTheZoneKeepsLocalDataAndStopsOtherDevices() async throws {
        let a = try makeDevice(AppSnapshot(sessions: [session("1", summary: "S")]))
        let b = try makeDevice(AppSnapshot(forums: [Forum(siteURL: other, name: "Other")]))
        await sync(a, b, a)

        try await a.sync.deleteCloudData()
        XCTAssertFalse(server.zone("user-1").exists)
        XCTAssertTrue(server.records().isEmpty)
        XCTAssertFalse(a.sync.isEnabled)
        XCTAssertEqual(a.sync.status, .off)
        XCTAssertEqual(a.app.sessions.count, 1)
        XCTAssertEqual(a.app.forums.count, 1)

        // B learns about it on its next fetch: it stops too (not re-uploading
        // what the user just deleted) and keeps its data.
        await sync(b)
        XCTAssertFalse(b.sync.isEnabled)
        XCTAssertEqual(b.sync.status, .off)
        XCTAssertTrue(server.records().isEmpty)
        XCTAssertEqual(b.app.sessions.count, 1)

        // Turning it back on uploads this device's data again.
        b.sync.setEnabled(true)
        await sync(b)
        XCTAssertEqual(b.sync.status, .upToDate)
        XCTAssertEqual(server.records().count, 3) // settings, session, forum
    }

    func testSignOutKeepsLocalDataAndSendsNothingUntilSignIn() async throws {
        let key = topic("1").topicKey
        let a = try makeDevice(AppSnapshot(sessions: [session("1", summary: "S")]))
        await sync(a)
        await a.transport.signOut()
        XCTAssertEqual(a.sync.status, .noAccount)
        XCTAssertFalse(a.transport.isRunning)
        XCTAssertEqual(a.app.sessions.count, 1)

        a.app.setKept(true, topicKey: key)
        let sent = await writes { await sync(a) }
        XCTAssertEqual(sent, 0)
        XCTAssertEqual(a.sync.status, .noAccount)

        // Signing in again (CKAccountChanged) joins and uploads the edit.
        a.transport.user = "user-1"
        a.transport.onAccountChanged?()
        await sync(a)
        XCTAssertEqual(a.sync.status, .upToDate)
        XCTAssertEqual(server.records().count, 2)
        let record = try XCTUnwrap(serverPlaintexts()[name(.session, key)])
        XCTAssertTrue(record.contains("\"kept\":true"))
    }

    func testAccountSwitchUploadsToTheNewAccountWithoutDuplicates() async throws {
        let a = try makeDevice(AppSnapshot(
            sessions: [session("1", summary: "S")],
            forums: [Forum(siteURL: site, name: "Example")]
        ))
        await sync(a)
        let firstAccount = server.records("user-1")
        XCTAssertEqual(firstAccount.count, 3)

        await a.transport.switchAccount(to: "user-2")
        await sync(a, a)
        XCTAssertEqual(server.records("user-2").count, 3)
        XCTAssertEqual(server.records("user-1"), firstAccount, "the old account is untouched")
        XCTAssertEqual(a.app.sessions.count, 1)
        XCTAssertEqual(a.sync.status, .upToDate)

        // And back: the first account's records are merged, not duplicated.
        await a.transport.switchAccount(to: "user-1")
        await sync(a, a)
        XCTAssertEqual(server.records("user-1").count, 3)
        XCTAssertEqual(a.app.sessions.count, 1)
        let sent = await writes { await sync(a) }
        XCTAssertEqual(sent, 0)
    }

    func testNoAccountThenSignInStartsSyncing() async throws {
        let a = try makeDevice(AppSnapshot(forums: [Forum(siteURL: site, name: "Example")]), user: nil)
        await sync(a)
        XCTAssertEqual(a.sync.status, .noAccount)
        XCTAssertTrue(server.records().isEmpty)
        a.transport.user = "user-1"
        a.transport.onAccountChanged?()
        await sync(a)
        XCTAssertEqual(a.sync.status, .upToDate)
        XCTAssertNotNil(server.records()[name(.forum, site)])
    }

    func testRestrictedAccountReportsRestricted() async throws {
        let a = try makeDevice()
        a.transport.statusOverride = .restricted
        await a.sync.start()
        XCTAssertEqual(a.sync.status, .restricted)
        a.transport.statusOverride = .temporarilyUnavailable
        await a.sync.start()
        guard case .unavailable = a.sync.status else { return XCTFail("status \(a.sync.status)") }
    }

    // MARK: On / off

    func testSetEnabledFalseStopsSendingAndTrueJoinsAgain() async throws {
        let suite = "cloud-sync-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        let key = topic("1").topicKey
        let a = try makeDevice(AppSnapshot(sessions: [session("1", summary: "S")]), defaults: defaults)
        XCTAssertTrue(a.sync.isEnabled, "on by default")
        await sync(a)

        a.sync.setEnabled(false)
        XCTAssertEqual(a.sync.status, .off)
        XCTAssertEqual(defaults.object(forKey: CloudSyncController.enabledKey) as? Bool, false)
        a.app.setKept(true, topicKey: key)
        let sent = await writes { await sync(a) }
        XCTAssertEqual(sent, 0)
        XCTAssertEqual(a.app.sessions[key]?.kept, true)

        // The flag is per device and survives a relaunch.
        let relaunched = launch(directory: a.directory, providerKeys: a.providerKeys, defaults: defaults)
        XCTAssertFalse(relaunched.sync.isEnabled)
        XCTAssertEqual(relaunched.sync.status, .off)

        relaunched.sync.setEnabled(true)
        await sync(relaunched)
        XCTAssertEqual(relaunched.sync.status, .upToDate)
        let record = try XCTUnwrap(serverPlaintexts()[name(.session, key)])
        XCTAssertTrue(record.contains("\"kept\":true"))
    }

    func testWithoutATransportSyncIsUnavailable() {
        let sync = CloudSyncController(transport: nil, files: nil, defaults: nil, schedulesAutomatically: false)
        XCTAssertEqual(sync.status, .unavailable(CloudSyncController.unsignedBuildReason))
        XCTAssertEqual(CloudSyncController.unsignedBuildReason, "Sync needs a signed build")
        sync.setEnabled(false)
        XCTAssertEqual(sync.status, .off)
        sync.setEnabled(true)
        XCTAssertEqual(sync.status, .unavailable(CloudSyncController.unsignedBuildReason))
    }

    // MARK: Payloads

    func testRecordNamesAreASCIIHashesAndIDsStayEncrypted() async throws {
        let unicodeSite = "https://форум.example.com"
        let a = try makeDevice(AppSnapshot(forums: [Forum(siteURL: unicodeSite, name: "Unicode")]))
        await sync(a)
        for (recordName, record) in server.records() {
            XCTAssertTrue(recordName.allSatisfy { $0.isASCII && ($0.isHexDigit || $0.isLetter) }, recordName)
            XCTAssertLessThanOrEqual(recordName.count, 40)
            XCTAssertEqual(record.formatVersion, CloudRecord.formatVersion)
        }
        let record = try XCTUnwrap(server.records()[name(.forum, unicodeSite)])
        XCTAssertEqual(record.kind, "forum")
        XCTAssertNil(record.deletedAt)
        XCTAssertTrue(String(decoding: try SyncPayload.canonical(from: record.payload), as: UTF8.self).contains(unicodeSite))
    }

    func testBigAgentRunRoundTripsCompressed() async throws {
        var big = run(goal: "Big run", steps: 200)
        let date = big.createdAt
        big.transcript = (0..<400).map {
            ChatMessage(role: $0 % 2 == 0 ? .user : .assistant, content: String(repeating: "Observation \($0) ✓ 日本語 ", count: 150), createdAt: date)
        }
        big.followUps = [ChatMessage(role: .user, content: "Follow-up?", createdAt: date), ChatMessage(role: .assistant, content: "Yes.", createdAt: date)]
        big.topicIDs = (0..<30).map(String.init)
        let a = try makeDevice(AppSnapshot(agentRuns: [big]))
        let b = try makeDevice()
        await sync(a, b)
        let received = try XCTUnwrap(b.app.agentRuns.first { $0.id == big.id })
        XCTAssertEqual(try canonical(received), try canonical(a.app.agentRuns.first { $0.id == big.id }!))
        XCTAssertEqual(received.transcript.count, 400)
        XCTAssertEqual(received.steps.count, 200)
        let payload = try XCTUnwrap(server.records()[name(.run, big.id.uuidString)]?.payload)
        XCTAssertEqual(payload.first, UInt8(ascii: "Z"), "compressed")
        XCTAssertLessThan(payload.count, SyncPayload.maxBytes)
        let sent = await writes { await sync(a, b) }
        XCTAssertEqual(sent, 0)
    }

    /// A run too big for one record even compressed keeps its goal message
    /// and the newest transcript messages; the device that ran it keeps all.
    func testHugeAgentRunIsTruncatedDeterministically() async throws {
        var huge = run(goal: "Huge run")
        let date = huge.createdAt
        let goalMessage = ChatMessage(role: .user, content: "GOAL", createdAt: date)
        huge.transcript = [goalMessage] + (0..<300).map { index in
            // Random text barely compresses.
            let text = (0..<280).map { _ in UUID().uuidString }.joined()
            return ChatMessage(role: index % 2 == 0 ? .assistant : .user, content: "#\(index) " + text, createdAt: date)
        }
        let a = try makeDevice(AppSnapshot(agentRuns: [huge]))
        let b = try makeDevice()
        await sync(a, b)
        let received = try XCTUnwrap(b.app.agentRuns.first { $0.id == huge.id })
        XCTAssertLessThan(received.transcript.count, huge.transcript.count)
        XCTAssertGreaterThan(received.transcript.count, 1)
        XCTAssertEqual(received.transcript.first, goalMessage)
        XCTAssertEqual(received.transcript.last, huge.transcript.last)
        XCTAssertEqual(received.answer, huge.answer)
        XCTAssertEqual(a.app.agentRuns.first { $0.id == huge.id }?.transcript.count, 301, "the original stays whole")
        let payload = try XCTUnwrap(server.records()[name(.run, huge.id.uuidString)]?.payload)
        XCTAssertLessThanOrEqual(payload.count, SyncPayload.maxBytes)
        let sent = await writes { await sync(a, b, a) }
        XCTAssertEqual(sent, 0)
    }

    func testUnreadableRecordsAreSkippedWithAnErrorAndLeftAlone() async throws {
        let key = topic("1").topicKey
        let a = try makeDevice(AppSnapshot(sessions: [session("1", summary: "S")]))
        await sync(a)
        server.inject(CloudRecord(recordName: "deadbeef", kind: "session", deletedAt: nil, payload: Data("not a sync record".utf8), systemFields: nil))
        // A session's payload stored under the watched-topic name for the
        // same key is refused (a record is bound to its name).
        let sessionRecord = try XCTUnwrap(server.records()[name(.session, key)])
        server.inject(CloudRecord(
            recordName: name(.watched, key), kind: "watched", deletedAt: nil,
            payload: sessionRecord.payload, systemFields: nil
        ))

        let b = try makeDevice()
        await sync(b)
        guard case .error = b.sync.status else { return XCTFail("status \(b.sync.status)") }
        XCTAssertEqual(b.app.sessions[key]?.summary, "S")
        XCTAssertTrue(b.app.watchedTopics.isEmpty)
        XCTAssertEqual(server.records()["deadbeef"]?.payload, Data("not a sync record".utf8))
    }

    /// 500 sessions with chats: time per sync, and nothing sent once converged.
    func testFiveHundredSessionsConverge() async throws {
        let sessions = (0..<500).map { index in
            session("\(index)", summary: String(repeating: "Summary line \(index). ", count: 60), chat: ["Question \(index)?", String(repeating: "Answer. ", count: 80)])
        }
        let a = try makeDevice(AppSnapshot(sessions: sessions))
        let b = try makeDevice()
        func timed(_ device: Device) async -> TimeInterval {
            let start = Date()
            await device.sync.performSync()
            return Date().timeIntervalSince(start)
        }
        let upload = await timed(a)
        let join = await timed(b)
        XCTAssertEqual(b.app.sessions.count, 500)
        _ = await timed(a)
        let before = server.writes
        let idle = await timed(b)
        XCTAssertEqual(server.writes, before)
        let relaunched = relaunch(b)
        let relaunch = await timed(relaunched)
        XCTAssertEqual(server.writes, before)
        print("CloudSync 500 sessions: upload \(upload)s, join \(join)s, idle \(idle)s, relaunch \(relaunch)s")
        XCTAssertLessThan(idle, 5)
        XCTAssertLessThan(join, 20)
    }

    func testMergeIsCommutative() {
        let t1 = Date(timeIntervalSince1970: 1_000), t2 = Date(timeIntervalSince1970: 2_000)
        let x = SyncRecord(kind: .watched, id: "w", fields: ["title": .string("A"), "knownPostCount": .int(5)], stamps: ["title": t1, "knownPostCount": t2])
        let y = SyncRecord(kind: .watched, id: "w", fields: ["title": .string("B"), "knownPostCount": .int(9)], stamps: ["title": t2, "knownPostCount": t1])
        let z = SyncRecord.tombstone(kind: .watched, id: "w", deletedAt: Date(timeIntervalSince1970: 1_500))
        XCTAssertEqual(SyncMerge.merge(x, y), SyncMerge.merge(y, x))
        XCTAssertEqual(SyncMerge.merge(x, y).fields?["title"], .string("B"))
        XCTAssertEqual(SyncMerge.merge(x, y).fields?["knownPostCount"], .int(9))
        // A tombstone wins only over copies last changed before it.
        XCTAssertFalse(SyncMerge.merge(x, z).isTombstone)
        let old = SyncRecord(kind: .watched, id: "w", fields: ["title": .string("A")], stamps: ["title": t1])
        XCTAssertTrue(SyncMerge.merge(old, z).isTombstone)
        XCTAssertTrue(SyncMerge.merge(z, old).isTombstone)
    }

    func testPayloadCodecRoundTrips() throws {
        let record = SyncRecord(kind: .forum, id: site, fields: ["name": .string("Example")], stamps: ["name": Date(timeIntervalSince1970: 1_000)])
        let small = try SyncPayload.encode(record)
        XCTAssertEqual(small.first, UInt8(ascii: "J"))
        XCTAssertEqual(try SyncPayload.decode(small).record, record)
        let bigRecord = SyncRecord(kind: .forum, id: site, fields: ["name": .string(String(repeating: "x", count: 300_000))], stamps: [:])
        let big = try SyncPayload.encode(bigRecord)
        XCTAssertEqual(big.first, UInt8(ascii: "Z"))
        XCTAssertEqual(try SyncPayload.decode(big).record, bigRecord)
        XCTAssertThrowsError(try SyncPayload.decode(Data("?".utf8)))
    }
}
