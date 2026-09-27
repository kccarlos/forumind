import CryptoKit
import XCTest
@testable import Forumind

/// Wraps the real coordinated storage (on a temp folder) to count writes and
/// to fabricate iCloud conflict versions, which `NSFileVersion` cannot.
final class CountingFolderStorage: FolderSyncStorage, @unchecked Sendable {
    let inner = CoordinatedFolderStorage()
    private let lock = NSLock()
    private var _writes = 0
    private var conflicts: [String: [Data]] = [:]
    private(set) var resolved: [String] = []
    private var _failsWrites = false
    private var _hidesFormatOnce = false

    var writes: Int { lock.withLock { _writes } }
    /// Record writes fail (iCloud Drive out of space, folder gone…).
    var failsWrites: Bool {
        get { lock.withLock { _failsWrites } }
        set { lock.withLock { _failsWrites = newValue } }
    }
    /// The next read of format.json sees no file, as when another device
    /// creates it between this device's read and its create.
    var hidesFormatOnce: Bool {
        get { lock.withLock { _hidesFormatOnce } }
        set { lock.withLock { _hidesFormatOnce = newValue } }
    }

    func injectConflict(_ data: Data, at url: URL) {
        lock.withLock { conflicts[url.standardizedFileURL.path, default: []].append(data) }
    }

    func ensureDirectory(_ url: URL) throws { try inner.ensureDirectory(url) }
    func list(_ directory: URL) throws -> [FolderSyncFileInfo] { try inner.list(directory) }
    func read(_ url: URL) throws -> Data? {
        let hides = lock.withLock {
            guard _hidesFormatOnce, url.lastPathComponent == "format.json" else { return false }
            _hidesFormatOnce = false
            return true
        }
        return hides ? nil : try inner.read(url)
    }
    func conflictVersions(of url: URL) -> [Data] {
        lock.withLock { conflicts[url.standardizedFileURL.path] ?? [] }
    }
    func resolveConflicts(of url: URL) {
        lock.withLock {
            conflicts.removeValue(forKey: url.standardizedFileURL.path)
            resolved.append(url.lastPathComponent)
        }
    }
    func write(_ data: Data, to url: URL) throws {
        if failsWrites, url.lastPathComponent != "format.json" {
            throw CocoaError(.fileWriteOutOfSpace)
        }
        lock.withLock { _writes += 1 }
        try inner.write(data, to: url)
    }
    func createIfAbsent(_ data: Data, at url: URL) throws -> Data {
        let result = try inner.createIfAbsent(data, at: url)
        if result == data { lock.withLock { _writes += 1 } }
        return result
    }
    func remove(_ url: URL) throws {
        lock.withLock { _writes += 1 }
        try inner.remove(url)
    }
    func info(of url: URL) -> FolderSyncFileInfo? { inner.info(of: url) }
}

@MainActor
final class FolderSyncTests: XCTestCase {
    private let site = "https://forum.example.com"
    private let other = "https://other.example.org"

    struct Device {
        let app: AppModel
        let sync: FolderSyncController
        let storage: CountingFolderStorage
        let keys: InMemorySyncKeyProvider
        let providerKeys: InMemoryProviderKeyStore
        let directory: URL
    }

    private var folder: URL!
    private var root: URL { folder.appendingPathComponent(FolderSyncEngine.rootName, isDirectory: true) }

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("sync-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: Helpers

    private func makeDevice(
        _ snapshot: AppSnapshot = AppSnapshot(),
        keys: InMemorySyncKeyProvider = InMemorySyncKeyProvider(),
        apiKeys: [AIProvider: String] = [:],
        join: Bool = true
    ) throws -> Device {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let providerKeys = InMemoryProviderKeyStore(apiKeys)
        let store = PersistentStore(fileURL: directory.appendingPathComponent("state.json"), keys: providerKeys)
        var snapshot = snapshot
        snapshot.settings.hasCompletedOnboarding = true
        try store.save(snapshot)
        let storage = CountingFolderStorage()
        let sync = FolderSyncController(
            storage: storage,
            keys: keys,
            baselineURL: store.folderSyncBaselineURL,
            defaults: nil,
            schedulesAutomatically: false
        )
        let app = AppModel(store: store, folderSync: sync)
        app.browser.onPageContextChanged = nil
        if join { try sync.useFolder(folder) }
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return Device(app: app, sync: sync, storage: storage, keys: keys, providerKeys: providerKeys, directory: directory)
    }

    private func pass(_ devices: Device...) async {
        for device in devices { await device.sync.performPass() }
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

    /// Every file in the sync folder, decrypted (throws on unreadable ones).
    private func folderPlaintexts(keys: SyncKeyProvider) throws -> [String: Data] {
        var result: [String: Data] = [:]
        for url in allFiles() where url.pathExtension == "json" {
            let data = try Data(contentsOf: url)
            if url.lastPathComponent == "format.json" {
                result[url.lastPathComponent] = data
            } else {
                result[url.path] = try FolderSyncCrypto.open(data, keys: keys).plaintext
            }
        }
        return result
    }

    private func allFiles() -> [URL] {
        Self.files(under: root)
    }

    /// Synchronous: `NSDirectoryEnumerator` iteration is unavailable in async code.
    private nonisolated static func files(under root: URL) -> [URL] {
        (FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.allObjects ?? [])
            .compactMap { $0 as? URL }
    }

    private func canonical<T: Encodable>(_ value: T) throws -> Data {
        try FolderSyncCoding.data(value)
    }

    // MARK: Convergence

    func testTwoDevicesConvergeAndStopWritingOnceConverged() async throws {
        let keys = InMemorySyncKeyProvider()
        let a = try makeDevice(AppSnapshot(
            sessions: [session("1", summary: "Summary one", chat: ["Q", "A"]), session("2", summary: "Summary two")],
            agentRuns: [run(goal: "Goal A")],
            watchedTopics: [watched("1", posts: 12)],
            forums: [Forum(siteURL: site, name: "Example", isPinned: true, pinOrder: 0)]
        ), keys: keys)
        a.app.settings.systemPrompt = "Be brief."
        a.app.flushPendingSaves()
        let b = try makeDevice(AppSnapshot(
            sessions: [session("3", summary: "Summary three")],
            agentRuns: [run(goal: "Goal B", minutesAgo: 5)],
            forums: [Forum(siteURL: other, name: "Other")]
        ), keys: keys)

        await pass(a, b, a, b)

        for device in [a, b] {
            XCTAssertEqual(Set(device.app.sessions.keys), Set(["1", "2", "3"].map { topic($0).topicKey }))
            XCTAssertEqual(Set(device.app.agentRuns.map(\.goal)), ["Goal A", "Goal B"])
            XCTAssertEqual(device.app.watchedTopics.map(\.knownPostCount), [12])
            XCTAssertEqual(Set(device.app.forums.map(\.siteURL)), [site, other])
            XCTAssertEqual(device.app.settings.systemPrompt, "Be brief.")
        }
        XCTAssertEqual(b.app.sessions[topic("1").topicKey]?.summary, "Summary one")
        XCTAssertEqual(b.app.sessions[topic("1").topicKey]?.history.map(\.content), ["Q", "A"])
        // The fetched topic text never leaves the device.
        XCTAssertEqual(b.app.sessions[topic("1").topicKey]?.source, "")
        XCTAssertEqual(a.app.sessions[topic("1").topicKey]?.source, "LOCAL SOURCE 1")
        XCTAssertEqual(b.app.forums.first { $0.siteURL == site }?.isPinned, true)

        // Converged: further passes on either side write nothing.
        let writes = a.storage.writes + b.storage.writes
        await pass(a, b, a, b)
        XCTAssertEqual(a.sync.lastPassWrites, 0)
        XCTAssertEqual(b.sync.lastPassWrites, 0)
        XCTAssertEqual(a.storage.writes + b.storage.writes, writes)
        XCTAssertEqual(a.sync.status, .notInICloud)
        XCTAssertNotNil(a.sync.lastSyncedAt)

        // A relaunch (state reloaded from disk, dates truncated) is still converged.
        let reloadedStore = PersistentStore(fileURL: a.directory.appendingPathComponent("state.json"), keys: a.providerKeys)
        let reloadedSync = FolderSyncController(
            storage: a.storage, keys: keys, baselineURL: reloadedStore.folderSyncBaselineURL,
            defaults: nil, schedulesAutomatically: false
        )
        let reloaded = AppModel(store: reloadedStore, folderSync: reloadedSync)
        try reloadedSync.useFolder(folder)
        await reloadedSync.performPass()
        XCTAssertEqual(reloadedSync.lastPassWrites, 0)
        _ = reloaded
    }

    func testWatchCheckTimesStayOnTheDeviceAndWriteNothing() async throws {
        let keys = InMemorySyncKeyProvider()
        let a = try makeDevice(AppSnapshot(
            sessions: [session("1", summary: "Summary one")],
            watchedTopics: [watched("1", posts: 12)]
        ), keys: keys)
        let b = try makeDevice(AppSnapshot(), keys: keys)
        await pass(a, b, a, b)

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
        let writes = a.storage.writes + b.storage.writes
        await pass(a, b, a, b)

        XCTAssertEqual(a.storage.writes + b.storage.writes, writes)
        XCTAssertEqual(a.app.watchedTopics.first?.lastCheckedAt, checkedAt)
        XCTAssertNotEqual(b.app.watchedTopics.first?.lastCheckedAt, checkedAt)
        XCTAssertNotEqual(b.app.sessions[topic("1").topicKey]?.lastCheckedAt, checkedAt)
    }

    func testEditsOnBothDevicesMergePerField() async throws {
        let keys = InMemorySyncKeyProvider()
        let key = topic("1").topicKey
        let a = try makeDevice(AppSnapshot(sessions: [session("1", summary: "S")]), keys: keys)
        let b = try makeDevice(keys: keys)
        await pass(a, b)

        a.app.setKept(true, topicKey: key)
        b.app.setInstructions("Focus on data points", topicKey: key)
        await pass(a, b, a)

        for device in [a, b] {
            XCTAssertEqual(device.app.sessions[key]?.kept, true)
            XCTAssertEqual(device.app.sessions[key]?.instructions, "Focus on data points")
            XCTAssertEqual(device.app.sessions[key]?.summary, "S")
        }
    }

    // MARK: Deletes, prunes, clears

    func testDeleteRacesAgainstEditByTime() async throws {
        let keys = InMemorySyncKeyProvider()
        let one = topic("1").topicKey, two = topic("2").topicKey
        let a = try makeDevice(AppSnapshot(sessions: [session("1", summary: "S1"), session("2", summary: "S2")]), keys: keys)
        let b = try makeDevice(keys: keys)
        await pass(a, b)

        // Topic 1: A's delete is newer than B's edit → deleted everywhere.
        // (A delete is stamped with the time it happens.)
        b.app.setKept(true, topicKey: one)
        await pass(b)
        a.sync.clock = { Date().addingTimeInterval(300) }
        a.app.deleteSession(topicKey: one)
        await pass(a, b, a)
        XCTAssertNil(a.app.sessions[one])
        XCTAssertNil(b.app.sessions[one])

        // Topic 2: A deletes (stamped in the past), B edited afterwards → it comes back.
        a.sync.clock = { Date().addingTimeInterval(-600) }
        a.app.deleteSession(topicKey: two)
        b.app.setKept(true, topicKey: two)
        await pass(b, a, b, a)
        XCTAssertEqual(a.app.sessions[two]?.kept, true)
        XCTAssertEqual(b.app.sessions[two]?.kept, true)
        XCTAssertEqual(a.app.sessions[two]?.summary, "S2")
    }

    func testLocalEditMadeDuringAPassIsNotClobbered() async throws {
        let keys = InMemorySyncKeyProvider()
        let key = topic("1").topicKey
        let a = try makeDevice(AppSnapshot(sessions: [session("1", summary: "S")]), keys: keys)
        let b = try makeDevice(keys: keys)
        await pass(a, b)
        a.app.setInstructions("Remote instructions", topicKey: key)
        await pass(a)

        // B computes the merge, then the user edits before it is applied.
        guard case .ready(let remote) = try await b.sync.engine.readRemote(thorough: true) else {
            return XCTFail("folder not ready")
        }
        let plan = await b.sync.engine.plan(local: b.app.folderSyncLocalState(), remote: remote, now: Date())
        XCTAssertEqual(plan.changes.sessions.count, 1)
        b.app.setKept(true, topicKey: key)
        let skipped = b.app.applyRemote(plan.changes)
        XCTAssertEqual(skipped, [SyncRecord.recordKey(kind: .session, id: key)])
        XCTAssertEqual(b.app.sessions[key]?.kept, true)
        XCTAssertEqual(b.app.sessions[key]?.instructions, "")

        // The next pass merges both edits.
        await pass(b, a)
        for device in [a, b] {
            XCTAssertEqual(device.app.sessions[key]?.kept, true)
            XCTAssertEqual(device.app.sessions[key]?.instructions, "Remote instructions")
        }
    }

    func testPrunedSessionIsNotReimportedUntilItChangesRemotely() async throws {
        let keys = InMemorySyncKeyProvider()
        let key = topic("1").topicKey
        let a = try makeDevice(AppSnapshot(sessions: [session("1", summary: "S1")]), keys: keys)
        let b = try makeDevice(keys: keys)
        await pass(a, b)

        // A prunes (no tombstone): B keeps it, A does not get it back.
        await a.sync.engine.notePruned(kind: .session, ids: [key])
        a.app.deleteSession(topicKey: key)
        await pass(a, b, a, b, a)
        XCTAssertNil(a.app.sessions[key])
        XCTAssertNotNil(b.app.sessions[key])
        XCTAssertEqual(a.sync.lastPassWrites, 0)

        // B changes it: now it is news for A.
        b.app.setKept(true, topicKey: key)
        await pass(b, a)
        XCTAssertEqual(a.app.sessions[key]?.kept, true)
    }

    func testClearedChatDoesNotComeBack() async throws {
        let keys = InMemorySyncKeyProvider()
        let key = topic("1").topicKey
        let a = try makeDevice(AppSnapshot(sessions: [session("1", summary: "S", chat: ["Q1", "A1", "Q2", "A2"])]), keys: keys)
        let b = try makeDevice(keys: keys)
        await pass(a, b)
        XCTAssertEqual(b.app.sessions[key]?.history.count, 4)

        b.app.select(topic: topic("1"))
        b.app.clearChat()
        await pass(b, a, b, a)
        XCTAssertEqual(a.app.sessions[key]?.history, [])
        XCTAssertEqual(b.app.sessions[key]?.history, [])
        XCTAssertEqual(a.app.sessions[key]?.summary, "S")
        await pass(a, b)
        XCTAssertEqual(a.sync.lastPassWrites + b.sync.lastPassWrites, 0)
    }

    func testRemovedForumAndDeletedRunDisappearOnTheOtherDevice() async throws {
        let keys = InMemorySyncKeyProvider()
        let goal = run(goal: "Goal")
        let a = try makeDevice(AppSnapshot(
            agentRuns: [goal],
            watchedTopics: [watched("1", posts: 3)],
            forums: [Forum(siteURL: site, name: "Example"), Forum(siteURL: other, name: "Other")]
        ), keys: keys)
        let b = try makeDevice(keys: keys)
        await pass(a, b)
        XCTAssertEqual(b.app.forums.count, 2)
        XCTAssertEqual(b.app.agentRuns.count, 1)

        a.app.removeForum(a.app.forum(for: other)!, deleteData: false)
        a.app.deleteAgentRun(id: goal.id)
        a.app.unwatch(topicKey: topic("1").topicKey)
        a.sync.clock = { Date().addingTimeInterval(5) }
        await pass(a, b)
        XCTAssertEqual(b.app.forums.map(\.siteURL), [site])
        XCTAssertTrue(b.app.agentRuns.isEmpty)
        XCTAssertTrue(b.app.watchedTopics.isEmpty)
    }

    func testRunningRunStaysOnItsDevice() async throws {
        let keys = InMemorySyncKeyProvider()
        var running = run(goal: "Still running")
        running.status = .running
        let a = try makeDevice(AppSnapshot(agentRuns: [running, run(goal: "Done")]), keys: keys)
        await pass(a)
        // Not restorable (no activity record): init marks it cancelled — so
        // check the rule with a pure plan instead.
        let state = FolderSyncLocalState(
            settings: AppSettings(), sessions: [:], runs: [running], watched: [], forums: []
        )
        let plan = await a.sync.engine.plan(local: state, remote: .init(keyID: "k"), now: Date())
        XCTAssertNil(plan.operations[SyncRecord.recordKey(kind: .run, id: running.id.uuidString)])
    }

    func testTombstonesExpireAfterSixtyDays() async throws {
        let keys = InMemorySyncKeyProvider()
        let a = try makeDevice(AppSnapshot(forums: [Forum(siteURL: site, name: "Example")]), keys: keys)
        await pass(a)
        a.app.removeForum(a.app.forums[0], deleteData: false)
        await pass(a)
        let forumsDir = root.appendingPathComponent("forums")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: forumsDir.path).count, 1)
        a.sync.clock = { Date().addingTimeInterval(61 * 24 * 60 * 60) }
        await pass(a)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: forumsDir.path).count, 0)
    }

    // MARK: Conflicts and format

    func testConflictVersionsAreMergedAndResolved() async throws {
        let keys = InMemorySyncKeyProvider()
        let key = topic("1").topicKey
        let a = try makeDevice(AppSnapshot(sessions: [session("1", summary: "Old summary")]), keys: keys)
        await pass(a)

        // Another device's copy that iCloud kept as a conflict version: a
        // newer summary, same everything else.
        let fileURL = root.appendingPathComponent("sessions")
            .appendingPathComponent(SyncRecord.fileName(kind: .session, id: key))
        let format = try JSONDecoder().decode(FolderSyncFormat.self, from: Data(contentsOf: root.appendingPathComponent("format.json")))
        let current = try FolderSyncCrypto.open(Data(contentsOf: fileURL), keys: keys).plaintext
        var record = try FolderSyncCoding.makeDecoder().decode(SyncRecord.self, from: current)
        var summary = record.fields!["summary"]!.objectValue!
        summary["summary"] = .string("Newer summary from the other device")
        record.fields!["summary"] = .object(summary)
        record.stamps!["summary"] = FolderSyncCoding.stamp(Date().addingTimeInterval(60))
        let conflict = try FolderSyncCrypto.seal(record.canonicalData(), key: keys.key(id: format.keyID)!, keyID: format.keyID)
        a.storage.injectConflict(conflict, at: fileURL)

        await a.sync.performPass(thorough: true)
        XCTAssertEqual(a.app.sessions[key]?.summary, "Newer summary from the other device")
        XCTAssertTrue(a.storage.resolved.contains(fileURL.lastPathComponent))
        XCTAssertTrue(a.storage.conflictVersions(of: fileURL).isEmpty)
        let merged = try FolderSyncCoding.makeDecoder().decode(
            SyncRecord.self,
            from: FolderSyncCrypto.open(Data(contentsOf: fileURL), keys: keys).plaintext
        )
        XCTAssertEqual(merged.fields?["summary"]?.objectValue?["summary"], .string("Newer summary from the other device"))
        await a.sync.performPass(thorough: true)
        XCTAssertEqual(a.sync.lastPassWrites, 0)
    }

    func testFormatRaceLowestKeyIDWinsAndLoserReencrypts() async throws {
        let keys = InMemorySyncKeyProvider()
        let a = try makeDevice(AppSnapshot(
            sessions: [session("1", summary: "S")],
            forums: [Forum(siteURL: site, name: "Example")]
        ), keys: keys)
        await pass(a)
        let formatURL = root.appendingPathComponent("format.json")
        let original = try JSONDecoder().decode(FolderSyncFormat.self, from: Data(contentsOf: formatURL)).keyID

        // Another device created format.json at the same time with a lower key id.
        let winner = "00000000-0000-0000-0000-000000000000"
        try keys.store(SymmetricKey(size: .bits256), id: winner)
        a.storage.injectConflict(try FolderSyncCoding.data(FolderSyncFormat(keyID: winner)), at: formatURL)
        await a.sync.performPass(thorough: true)

        XCTAssertEqual(try JSONDecoder().decode(FolderSyncFormat.self, from: Data(contentsOf: formatURL)).keyID, winner)
        XCTAssertNotEqual(original, winner)
        var records = 0
        for url in allFiles() where url.pathExtension == "json" && url.lastPathComponent != "format.json" {
            let envelope = try JSONDecoder().decode(FolderSyncEnvelope.self, from: Data(contentsOf: url))
            XCTAssertEqual(envelope.keyID, winner, url.lastPathComponent)
            records += 1
        }
        XCTAssertEqual(records, 3) // settings, one session, one forum
    }

    func testTwoDevicesCreatingTheFolderAgreeOnOneKey() async throws {
        let keys = InMemorySyncKeyProvider()
        let a = try makeDevice(AppSnapshot(forums: [Forum(siteURL: site, name: "A")]), keys: keys)
        let b = try makeDevice(AppSnapshot(forums: [Forum(siteURL: other, name: "B")]), keys: keys)
        async let first: Void = a.sync.performPass()
        async let second: Void = b.sync.performPass()
        _ = await (first, second)
        await pass(a, b, a)
        XCTAssertEqual(Set(a.app.forums.map(\.siteURL)), [site, other])
        XCTAssertEqual(Set(b.app.forums.map(\.siteURL)), [site, other])
    }

    // MARK: Keys

    func testWaitingForKeyRecoversWhenTheKeyArrives() async throws {
        let keysA = InMemorySyncKeyProvider()
        let keysB = InMemorySyncKeyProvider()
        let a = try makeDevice(AppSnapshot(sessions: [session("1", summary: "S")]), keys: keysA)
        await pass(a)
        let b = try makeDevice(AppSnapshot(forums: [Forum(siteURL: other, name: "B")]), keys: keysB)
        await pass(b)
        XCTAssertEqual(b.sync.status, .waitingForKey)
        XCTAssertEqual(b.storage.writes, 0)
        XCTAssertTrue(b.app.sessions.isEmpty)

        keysB.receive(from: keysA)
        await pass(b, a)
        XCTAssertEqual(b.sync.status, .notInICloud)
        XCTAssertEqual(b.app.sessions[topic("1").topicKey]?.summary, "S")
        XCTAssertEqual(Set(a.app.forums.map(\.siteURL)), [other])
    }

    func testAPIKeysNeverReachTheFolderAndPulledSettingsKeepLocalKeys() async throws {
        let keys = InMemorySyncKeyProvider()
        let secret = "sk-SECRET-\(UUID().uuidString)"
        let a = try makeDevice(keys: keys, apiKeys: [.openAI: secret])
        var configuration = a.app.settings.configuration(for: .openAI)
        configuration.model = "gpt-5-mini"
        a.app.setConfiguration(configuration, for: .openAI)
        a.app.settings.selectedProvider = .openAI
        a.app.flushPendingSaves()
        XCTAssertEqual(a.app.settings.configuration(for: .openAI).apiKey, secret)
        let bSecret = "sk-B-\(UUID().uuidString)"
        let b = try makeDevice(keys: keys, apiKeys: [.openAI: bSecret])
        await pass(a, b, a)

        for (path, plaintext) in try folderPlaintexts(keys: keys) {
            let text = String(decoding: plaintext, as: UTF8.self)
            XCTAssertFalse(text.contains(secret), path)
            XCTAssertFalse(text.contains(bSecret), path)
            XCTAssertFalse(text.contains("apiKey"), path)
        }
        for url in allFiles() {
            guard let raw = try? Data(contentsOf: url) else { continue }
            XCTAssertFalse(String(decoding: raw, as: UTF8.self).contains(secret))
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
        XCTAssertFalse(a.app.settings.configuration(for: .anthropic).apiKey == "sk-arrived")
        try a.providerKeys.set("sk-arrived", for: .anthropic)
        await pass(a)
        XCTAssertEqual(a.app.settings.configuration(for: .anthropic).apiKey, "sk-arrived")
    }

    // MARK: Settings

    func testSettingsMergePerFieldAndDeviceLocalSettingsStayPut() async throws {
        let keys = InMemorySyncKeyProvider()
        let a = try makeDevice(keys: keys)
        let b = try makeDevice(keys: keys)
        b.app.settings.browserBarPosition = .bottom
        b.app.settings.syncAPIKeys = false
        b.app.flushPendingSaves()
        await pass(a, b, a)

        a.app.settings.systemPrompt = "From A"
        a.app.settings.browserBarPosition = .top
        a.app.flushPendingSaves()
        b.app.settings.forumContextLimit = 45_000
        b.app.settings.blockTrackers = false
        b.app.flushPendingSaves()
        a.sync.clock = { Date().addingTimeInterval(2) }
        b.sync.clock = { Date().addingTimeInterval(3) }
        await pass(a, b, a, b)

        for device in [a, b] {
            XCTAssertEqual(device.app.settings.systemPrompt, "From A")
            XCTAssertEqual(device.app.settings.forumContextLimit, 45_000)
            XCTAssertFalse(device.app.settings.blockTrackers)
        }
        XCTAssertEqual(b.app.settings.browserBarPosition, .bottom)
        XCTAssertFalse(b.app.settings.syncAPIKeys)
        XCTAssertTrue(a.app.settings.syncAPIKeys)
        let units = try FolderSyncSchema.settingsUnits(a.app.settings)
        for key in FolderSyncSettings.deviceLocalKeys { XCTAssertNil(units[key]) }
    }

    func testJoiningDeviceAdoptsTheFolderSettings() async throws {
        let keys = InMemorySyncKeyProvider()
        let a = try makeDevice(keys: keys)
        a.app.settings.systemPrompt = "Customized"
        a.app.settings.agentMaxSteps = 25
        a.app.flushPendingSaves()
        await pass(a)
        let b = try makeDevice(keys: keys)
        await pass(b, a)
        XCTAssertEqual(b.app.settings.systemPrompt, "Customized")
        XCTAssertEqual(b.app.settings.agentMaxSteps, 25)
        XCTAssertEqual(a.app.settings.systemPrompt, "Customized")
    }

    // MARK: Payloads and failures

    func testBigAgentRunRoundTrips() async throws {
        let keys = InMemorySyncKeyProvider()
        var big = run(goal: "Big run", steps: 200)
        let date = big.createdAt
        big.transcript = (0..<400).map {
            ChatMessage(role: $0 % 2 == 0 ? .user : .assistant, content: String(repeating: "Observation \($0) ✓ 日本語 ", count: 150), createdAt: date)
        }
        big.followUps = [ChatMessage(role: .user, content: "Follow-up?", createdAt: date), ChatMessage(role: .assistant, content: "Yes.", createdAt: date)]
        big.topicIDs = (0..<30).map(String.init)
        let a = try makeDevice(AppSnapshot(agentRuns: [big]), keys: keys)
        let b = try makeDevice(keys: keys)
        await pass(a, b)
        let received = try XCTUnwrap(b.app.agentRuns.first { $0.id == big.id })
        XCTAssertEqual(try canonical(received), try canonical(a.app.agentRuns.first { $0.id == big.id }!))
        XCTAssertEqual(received.transcript.count, 400)
        XCTAssertEqual(received.steps.count, 200)
        await pass(a, b)
        XCTAssertEqual(a.sync.lastPassWrites + b.sync.lastPassWrites, 0)
    }

    func testCorruptFileIsSkippedWithAnErrorAndLeftAlone() async throws {
        let keys = InMemorySyncKeyProvider()
        let a = try makeDevice(AppSnapshot(sessions: [session("1", summary: "S")]), keys: keys)
        await pass(a)
        let garbage = root.appendingPathComponent("sessions/deadbeefdeadbeefdeadbeefdeadbeef.json")
        try Data("not a sync file".utf8).write(to: garbage)
        let foreign = root.appendingPathComponent("sessions/0123456789abcdef0123456789abcdef.json")
        let otherKey = SymmetricKey(size: .bits256)
        try FolderSyncCrypto.seal(Data("{}".utf8), key: otherKey, keyID: "unknown-key").write(to: foreign)

        let b = try makeDevice(keys: keys)
        await pass(b)
        guard case .error = b.sync.status else { return XCTFail("status \(b.sync.status)") }
        XCTAssertEqual(b.app.sessions[topic("1").topicKey]?.summary, "S")
        XCTAssertEqual(try Data(contentsOf: garbage), Data("not a sync file".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: foreign.path))
    }

    func testResetSyncDataStartsANewKeyAndUploadsThisDevice() async throws {
        let keys = InMemorySyncKeyProvider()
        let a = try makeDevice(AppSnapshot(sessions: [session("1", summary: "S")]), keys: keys)
        let b = try makeDevice(AppSnapshot(forums: [Forum(siteURL: other, name: "B")]), keys: keys)
        await pass(a, b, a)
        let formatURL = root.appendingPathComponent("format.json")
        let before = try JSONDecoder().decode(FolderSyncFormat.self, from: Data(contentsOf: formatURL)).keyID
        b.app.settings.systemPrompt = "B wins after reset"
        b.app.flushPendingSaves()
        try await b.sync.resetSyncData()
        let after = try JSONDecoder().decode(FolderSyncFormat.self, from: Data(contentsOf: formatURL)).keyID
        XCTAssertNotEqual(before, after)
        await pass(a, b)
        XCTAssertEqual(a.app.settings.systemPrompt, "B wins after reset")
        XCTAssertNotNil(b.app.sessions[topic("1").topicKey])
        XCTAssertEqual(Set(a.app.forums.map(\.siteURL)), [other])
        await pass(a, b)
        XCTAssertEqual(a.sync.lastPassWrites + b.sync.lastPassWrites, 0)
    }

    func testStopKeepsLocalDataAndTheFolder() async throws {
        let a = try makeDevice(AppSnapshot(sessions: [session("1", summary: "S")]))
        await pass(a)
        a.sync.stop()
        XCTAssertEqual(a.sync.status, .off)
        XCTAssertNil(a.sync.folderName)
        XCTAssertEqual(a.app.sessions.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("format.json").path))
        let writes = a.storage.writes
        a.app.setKept(true, topicKey: topic("1").topicKey)
        await pass(a)
        XCTAssertEqual(a.storage.writes, writes)
    }

    func testOverlappingPassRequestsRunOneAfterAnother() async throws {
        let a = try makeDevice(AppSnapshot(sessions: [session("1", summary: "S")]))
        async let first: Void = a.sync.performPass()
        async let second: Void = a.sync.performPass()
        async let third: Void = a.sync.performPass(thorough: true)
        _ = await (first, second, third)
        XCTAssertEqual(a.sync.passCount, 3)
        XCTAssertEqual(a.sync.lastPassWrites, 0)
        // The main actor is free again (a spinning wait would starve it).
        let expectation = expectation(description: "main actor")
        Task { @MainActor in expectation.fulfill() }
        await fulfillment(of: [expectation], timeout: 2)
    }

    func testStopThenChoosingAFolderAgainSyncs() async throws {
        let a = try makeDevice(AppSnapshot(sessions: [session("1", summary: "S")]))
        await pass(a)
        a.sync.stop()
        try a.sync.useFolder(folder)
        await pass(a)
        XCTAssertEqual(a.sync.status, .notInICloud)
        XCTAssertEqual(a.sync.folderName, folder.lastPathComponent)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("settings.json").path))
    }

    func testBookmarkIsRestoredOnLaunchAndABadOneAsksForAccess() async throws {
        let suite = "folder-sync-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        func launch() throws -> (AppModel, FolderSyncController) {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let store = PersistentStore(fileURL: directory.appendingPathComponent("state.json"), keys: InMemoryProviderKeyStore())
            let sync = FolderSyncController(
                keys: InMemorySyncKeyProvider(), baselineURL: store.folderSyncBaselineURL,
                defaults: defaults, schedulesAutomatically: false
            )
            return (AppModel(store: store, folderSync: sync), sync)
        }
        let (first, firstSync) = try launch()
        try firstSync.useFolder(folder)
        await firstSync.performPass()
        XCTAssertNotNil(defaults.data(forKey: FolderSyncController.bookmarkKey))
        _ = first

        // Next launch: the bookmark resolves and sync resumes.
        let (second, secondSync) = try launch()
        XCTAssertEqual(secondSync.folderName, folder.lastPathComponent)
        XCTAssertNotEqual(secondSync.status, .needsFolderAccess)
        await secondSync.performPass()
        XCTAssertEqual(secondSync.status, .waitingForKey) // new device, key not arrived
        _ = second

        // An unresolvable bookmark asks the user to pick the folder again.
        defaults.set(Data("garbage".utf8), forKey: FolderSyncController.bookmarkKey)
        let (_, thirdSync) = try launch()
        XCTAssertEqual(thirdSync.status, .needsFolderAccess)
        XCTAssertEqual(thirdSync.folderName, folder.lastPathComponent)

        thirdSync.stop()
        XCTAssertNil(defaults.data(forKey: FolderSyncController.bookmarkKey))
        XCTAssertEqual(thirdSync.status, .off)
    }


    // MARK: Review fixes

    /// The same device after a relaunch: state, baseline and deletion log from disk.
    private func relaunch(_ device: Device, keys: InMemorySyncKeyProvider) throws -> Device {
        let store = PersistentStore(fileURL: device.directory.appendingPathComponent("state.json"), keys: device.providerKeys)
        let sync = FolderSyncController(
            storage: device.storage, keys: keys, baselineURL: store.folderSyncBaselineURL,
            defaults: nil, schedulesAutomatically: false
        )
        let app = AppModel(store: store, folderSync: sync)
        app.browser.onPageContextChanged = nil
        try sync.useFolder(folder)
        return Device(app: app, sync: sync, storage: device.storage, keys: keys, providerKeys: device.providerKeys, directory: device.directory)
    }

    private func forumFile(_ siteURL: String) -> URL {
        root.appendingPathComponent("forums").appendingPathComponent(SyncRecord.fileName(kind: .forum, id: siteURL))
    }

    /// A delete made just before the app is killed keeps its real time: an
    /// edit made elsewhere after it wins, however late the next pass runs.
    func testDeleteKeepsItsTimeAcrossARelaunch() async throws {
        let keys = InMemorySyncKeyProvider()
        let base = FolderSyncCoding.stamp(Date())
        let a = try makeDevice(AppSnapshot(forums: [Forum(siteURL: site, name: "Example"), Forum(siteURL: other, name: "Other")]), keys: keys)
        let b = try makeDevice(keys: keys)
        a.sync.clock = { base }
        b.sync.clock = { base }
        await pass(a, b)

        a.sync.clock = { base.addingTimeInterval(100) }
        a.app.removeForum(a.app.forum(for: site)!, deleteData: false)
        a.app.removeForum(a.app.forum(for: other)!, deleteData: false)
        XCTAssertEqual(Set(a.sync.deletionLog.keys), [
            SyncRecord.recordKey(kind: .forum, id: site), SyncRecord.recordKey(kind: .forum, id: other)
        ])
        // Killed before any pass. Meanwhile B pins one of them.
        b.sync.clock = { base.addingTimeInterval(200) }
        b.app.pin(b.app.forum(for: site)!)
        await pass(b)

        let relaunched = try relaunch(a, keys: keys)
        relaunched.sync.clock = { base.addingTimeInterval(24 * 60 * 60) }
        await pass(relaunched, b, relaunched)
        // The pin (t+200) is newer than the delete (t+100): it stays everywhere.
        XCTAssertEqual(relaunched.app.forum(for: site)?.isPinned, true)
        XCTAssertEqual(b.app.forum(for: site)?.isPinned, true)
        // The untouched one is deleted everywhere.
        XCTAssertNil(relaunched.app.forum(for: other))
        XCTAssertNil(b.app.forum(for: other))
        XCTAssertTrue(relaunched.sync.deletionLog.isEmpty)
        await pass(relaunched, b)
        XCTAssertEqual(relaunched.sync.lastPassWrites + b.sync.lastPassWrites, 0)
    }

    /// Pruning (no tombstone) never enters the deletion log.
    func testPrunedRecordsAreNotLoggedAsDeletes() async throws {
        let keys = InMemorySyncKeyProvider()
        let key = topic("1").topicKey
        let a = try makeDevice(AppSnapshot(sessions: [session("1", summary: "S1")]), keys: keys)
        let b = try makeDevice(keys: keys)
        await pass(a, b)
        a.app.deleteSession(topicKey: key)
        a.sync.notePruned(kind: .session, ids: [key])
        XCTAssertTrue(a.sync.deletionLog.isEmpty)
        await pass(a, b, a)
        XCTAssertNil(a.app.sessions[key])
        XCTAssertNotNil(b.app.sessions[key])
    }

    /// A device away for longer than tombstones live doesn't bring back
    /// what was deleted meanwhile — unless it changed it itself.
    func testDeviceAwayLongerThanTombstonesLiveDoesNotResurrectDeletes() async throws {
        let keys = InMemorySyncKeyProvider()
        let third = "https://third.example.net"
        let a = try makeDevice(AppSnapshot(forums: [
            Forum(siteURL: site, name: "Example"), Forum(siteURL: other, name: "Other"), Forum(siteURL: third, name: "Third")
        ]), keys: keys)
        let b = try makeDevice(keys: keys)
        await pass(a, b)
        XCTAssertEqual(b.app.forums.count, 3)

        // A deletes two forums; B is away (no passes) and pins one of them.
        a.sync.clock = { Date().addingTimeInterval(5) }
        a.app.removeForum(a.app.forum(for: site)!, deleteData: false)
        a.app.removeForum(a.app.forum(for: other)!, deleteData: false)
        await pass(a)
        b.app.pin(b.app.forum(for: other)!)
        // 61 days later the tombstones are gone.
        a.sync.clock = { Date().addingTimeInterval(61 * 24 * 60 * 60) }
        await pass(a)
        XCTAssertFalse(FileManager.default.fileExists(atPath: forumFile(site).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: forumFile(other).path))

        b.sync.clock = { Date().addingTimeInterval(61 * 24 * 60 * 60 + 60) }
        await pass(b, a)
        // The first pass back only notes the missing file (the listing may be
        // incomplete right after a long absence) and neither deletes nor uploads.
        XCTAssertNotNil(b.app.forum(for: site))
        XCTAssertFalse(FileManager.default.fileExists(atPath: forumFile(site).path))
        b.sync.clock = { Date().addingTimeInterval(61 * 24 * 60 * 60 + 60 + 31 * 60) }
        await pass(b, a)
        XCTAssertNil(b.app.forum(for: site), "unchanged on B: deleted, not re-uploaded")
        XCTAssertFalse(FileManager.default.fileExists(atPath: forumFile(site).path))
        XCTAssertEqual(b.app.forum(for: other)?.isPinned, true, "changed on B: kept")
        XCTAssertEqual(a.app.forum(for: other)?.isPinned, true)
        XCTAssertNotNil(b.app.forum(for: third))
        await pass(b, a)
        XCTAssertEqual(a.sync.lastPassWrites + b.sync.lastPassWrites, 0)
    }

    /// A file that shows up again after a long-absent device noted it missing
    /// (a late iCloud listing) clears the mark: nothing is deleted.
    func testFileReappearingAfterALongAbsenceIsNotDeleted() async throws {
        let keys = InMemorySyncKeyProvider()
        let a = try makeDevice(AppSnapshot(forums: [Forum(siteURL: site, name: "Example")]), keys: keys)
        let b = try makeDevice(keys: keys)
        await pass(a, b)
        let file = forumFile(site)
        let saved = try Data(contentsOf: file)
        try FileManager.default.removeItem(at: file)
        let later = Date().addingTimeInterval(61 * 24 * 60 * 60)
        b.sync.clock = { later }
        await pass(b)
        XCTAssertNotNil(b.app.forum(for: site))
        var entry = await b.sync.engine.baseline.records[SyncRecord.recordKey(kind: .forum, id: site)]
        XCTAssertNotNil(entry?.missingSince)
        try saved.write(to: file)
        b.sync.clock = { later.addingTimeInterval(60 * 60) }
        await pass(b)
        entry = await b.sync.engine.baseline.records[SyncRecord.recordKey(kind: .forum, id: site)]
        XCTAssertNil(entry?.missingSince)
        b.sync.clock = { later.addingTimeInterval(3 * 60 * 60) }
        await pass(b)
        XCTAssertNotNil(b.app.forum(for: site))
        XCTAssertEqual(b.sync.lastPassWrites, 0)
    }

    /// A file missing from the folder of a recently synced device isn't a
    /// delete (its tombstone would still be there): the record is uploaded again.
    func testMissingFileOnARecentDeviceIsUploadedAgain() async throws {
        let a = try makeDevice(AppSnapshot(forums: [Forum(siteURL: site, name: "Example")]))
        await pass(a)
        try FileManager.default.removeItem(at: forumFile(site))
        await pass(a)
        XCTAssertNotNil(a.app.forum(for: site))
        XCTAssertTrue(FileManager.default.fileExists(atPath: forumFile(site).path))
    }

    /// A record whose write failed is never taken as deleted elsewhere later.
    func testFailedWriteIsRetriedAndNeverTakenAsADelete() async throws {
        let a = try makeDevice(AppSnapshot(forums: [Forum(siteURL: site, name: "Example")]))
        await pass(a)
        a.app.recordVisit(siteURL: other, name: "Other", iconURL: nil)
        a.storage.failsWrites = true
        await pass(a)
        guard case .error = a.sync.status else { return XCTFail("status \(a.sync.status)") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: forumFile(other).path))

        // Much later (the last clean pass is old), writes work again.
        a.storage.failsWrites = false
        a.sync.clock = { Date().addingTimeInterval(61 * 24 * 60 * 60) }
        await pass(a)
        XCTAssertNotNil(a.app.forum(for: other))
        XCTAssertTrue(FileManager.default.fileExists(atPath: forumFile(other).path))
    }

    /// Joining a folder that has an old tombstone for a record this device
    /// used after the delete keeps it; one it hasn't touched since is deleted.
    func testJoiningKeepsRecordsUsedAfterAnOldDelete() async throws {
        let keys = InMemorySyncKeyProvider()
        let base = FolderSyncCoding.stamp(Date()).addingTimeInterval(-3 * 24 * 60 * 60)
        let a = try makeDevice(AppSnapshot(forums: [
            Forum(siteURL: site, name: "Example", addedAt: base.addingTimeInterval(-9000)),
            Forum(siteURL: other, name: "Other", addedAt: base.addingTimeInterval(-9000))
        ]), keys: keys)
        a.sync.clock = { base }
        await pass(a)
        a.app.removeForum(a.app.forum(for: site)!, deleteData: false)
        a.app.removeForum(a.app.forum(for: other)!, deleteData: false)
        await pass(a)

        let b = try makeDevice(AppSnapshot(forums: [
            Forum(siteURL: site, name: "Example", addedAt: base.addingTimeInterval(-7200), lastVisitedAt: base.addingTimeInterval(3600)),
            Forum(siteURL: other, name: "Other", addedAt: base.addingTimeInterval(-7200), lastVisitedAt: base.addingTimeInterval(-3600))
        ]), keys: keys)
        await pass(b, a)
        XCTAssertNotNil(b.app.forum(for: site), "visited after the delete: kept")
        XCTAssertNotNil(a.app.forum(for: site))
        XCTAssertNil(b.app.forum(for: other), "not used since the delete: deleted")
        XCTAssertNil(a.app.forum(for: other))
        await pass(b, a)
        XCTAssertEqual(a.sync.lastPassWrites + b.sync.lastPassWrites, 0)
    }

    /// A device whose clock runs a day ahead doesn't keep winning: an edit
    /// made after seeing its change beats it.
    func testClockAheadDoesNotBeatLaterEdits() async throws {
        let keys = InMemorySyncKeyProvider()
        let a = try makeDevice(AppSnapshot(forums: [Forum(siteURL: site, name: "Example")]), keys: keys)
        let b = try makeDevice(keys: keys)
        await pass(a, b)
        a.sync.clock = { Date().addingTimeInterval(24 * 60 * 60) }
        a.app.pin(a.app.forum(for: site)!)
        await pass(a, b)
        XCTAssertEqual(b.app.forum(for: site)?.isPinned, true)
        b.app.unpin(b.app.forum(for: site)!)
        await pass(b, a)
        XCTAssertEqual(a.app.forum(for: site)?.isPinned, false)
        XCTAssertEqual(b.app.forum(for: site)?.isPinned, false)
        await pass(a, b)
        XCTAssertEqual(a.sync.lastPassWrites + b.sync.lastPassWrites, 0)
    }

    /// Stop, then another folder: the new folder gets everything (fresh
    /// baseline), the old one isn't touched again, nothing is tombstoned.
    func testSwitchingToAnotherFolderStartsFresh() async throws {
        let a = try makeDevice(AppSnapshot(
            sessions: [session("1", summary: "S")],
            forums: [Forum(siteURL: site, name: "Example")]
        ))
        await pass(a)
        let second = FileManager.default.temporaryDirectory.appendingPathComponent("sync2-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: second) }
        let secondRoot = second.appendingPathComponent(FolderSyncEngine.rootName)

        for viaStop in [true, false] {
            let target = viaStop ? second : folder!
            if viaStop { a.sync.stop() }
            let oldFiles = Set(Self.files(under: viaStop ? root : secondRoot).map(\.path))
            try a.sync.useFolder(target)
            await pass(a)
            XCTAssertEqual(a.sync.status, .notInICloud)
            XCTAssertEqual(a.sync.folderName, target.lastPathComponent)
            let baselineFolder = await a.sync.engine.baseline.folder
            XCTAssertEqual(baselineFolder, FolderSyncEngine.syncRoot(forPicked: target).standardizedFileURL.path)
            XCTAssertEqual(a.app.sessions.count, 1)
            XCTAssertEqual(a.app.forums.count, 1)
            let targetRoot = FolderSyncEngine.syncRoot(forPicked: target)
            XCTAssertTrue(FileManager.default.fileExists(atPath: targetRoot.appendingPathComponent("forums")
                .appendingPathComponent(SyncRecord.fileName(kind: .forum, id: site)).path))
            XCTAssertEqual(Set(Self.files(under: viaStop ? root : secondRoot).map(\.path)), oldFiles)
        }
    }

    /// A pass planned for one folder never commits after Stop or a switch.
    func testPlanFromAnEarlierFolderIsNotCommitted() async throws {
        let a = try makeDevice(AppSnapshot(forums: [Forum(siteURL: site, name: "Example")]))
        await pass(a)
        a.app.recordVisit(siteURL: other, name: "Other", iconURL: nil)
        guard case .ready(let remote) = try await a.sync.engine.readRemote(thorough: true) else {
            return XCTFail("folder not ready")
        }
        let plan = await a.sync.engine.plan(local: a.app.folderSyncLocalState(), remote: remote, now: Date())
        XCTAssertFalse(plan.operations.isEmpty)
        let writes = a.storage.writes
        a.sync.stop()
        await a.sync.performPass()
        let result = await a.sync.engine.commit(plan, skipped: [], keyID: remote.keyID)
        XCTAssertTrue(result.stale)
        XCTAssertEqual(a.storage.writes, writes)
        XCTAssertEqual(a.sync.status, .off)
    }

    /// Another device created format.json between this device's read and
    /// create: the key made for it is removed (never used anywhere).
    func testKeyMadeForALostFormatRaceIsRemoved() async throws {
        let keys = InMemorySyncKeyProvider()
        let a = try makeDevice(AppSnapshot(forums: [Forum(siteURL: site, name: "A")]), keys: keys)
        await pass(a)
        let original = keys.ids
        XCTAssertEqual(original.count, 1)
        let b = try makeDevice(AppSnapshot(forums: [Forum(siteURL: other, name: "B")]), keys: keys)
        b.storage.hidesFormatOnce = true
        await pass(b, a)
        XCTAssertEqual(keys.ids, original)
        XCTAssertEqual(Set(a.app.forums.map(\.siteURL)), [site, other])
    }

    /// A record file copied over another kind's file of the same name (a
    /// session and a watched topic share the topic key) is refused.
    func testRecordFileInTheWrongFolderIsRefused() async throws {
        let keys = InMemorySyncKeyProvider()
        let key = topic("1").topicKey
        let a = try makeDevice(AppSnapshot(sessions: [session("1", summary: "S")]), keys: keys)
        await pass(a)
        let name = SyncRecord.fileName(kind: .session, id: key)
        try FileManager.default.copyItem(
            at: root.appendingPathComponent("sessions").appendingPathComponent(name),
            to: root.appendingPathComponent("watched").appendingPathComponent(name)
        )
        let b = try makeDevice(keys: keys)
        await pass(b)
        guard case .error = b.sync.status else { return XCTFail("status \(b.sync.status)") }
        XCTAssertEqual(b.app.sessions[key]?.summary, "S")
        XCTAssertTrue(b.app.watchedTopics.isEmpty)
    }

    /// Keys changed on another device (iCloud Keychain) show up when the app
    /// returns to the foreground, with or without a sync folder.
    func testKeysArrivingInTheKeyStoreAreAdoptedOnForeground() throws {
        let a = try makeDevice(join: false)
        try a.providerKeys.set("sk-arrived", for: .anthropic)
        a.app.handleScenePhase(.active)
        XCTAssertEqual(a.app.settings.configuration(for: .anthropic).apiKey, "sk-arrived")
    }

    /// 500 sessions with chats: pass time, and no writes once converged.
    func testFiveHundredSessionsSyncAndConverge() async throws {
        let keys = InMemorySyncKeyProvider()
        let sessions = (0..<500).map { index in
            session("\(index)", summary: String(repeating: "Summary line \(index). ", count: 60), chat: ["Question \(index)?", String(repeating: "Answer. ", count: 80)])
        }
        let a = try makeDevice(AppSnapshot(sessions: sessions), keys: keys)
        let b = try makeDevice(keys: keys)
        func timed(_ device: Device, thorough: Bool = false) async -> TimeInterval {
            let start = Date()
            await device.sync.performPass(thorough: thorough)
            return Date().timeIntervalSince(start)
        }
        let upload = await timed(a)
        let join = await timed(b)
        XCTAssertEqual(b.app.sessions.count, 500)
        _ = await timed(a)
        let thorough = await timed(b, thorough: true)
        let cached = await timed(b)
        XCTAssertEqual(b.sync.lastPassWrites, 0)
        let folderBytes = Self.files(under: root).reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        print("FolderSync 500 sessions: upload \(upload)s, join \(join)s, thorough \(thorough)s, cached \(cached)s, folder \(folderBytes / 1024) KB")
        XCTAssertLessThan(cached, 5)
    }

    func testMergeIsCommutative() {
        let t1 = Date(timeIntervalSince1970: 1_000), t2 = Date(timeIntervalSince1970: 2_000)
        let x = SyncRecord(kind: .watched, id: "w", fields: ["title": .string("A"), "knownPostCount": .int(5)], stamps: ["title": t1, "knownPostCount": t2])
        let y = SyncRecord(kind: .watched, id: "w", fields: ["title": .string("B"), "knownPostCount": .int(9)], stamps: ["title": t2, "knownPostCount": t1])
        let z = SyncRecord.tombstone(kind: .watched, id: "w", deletedAt: Date(timeIntervalSince1970: 1_500))
        XCTAssertEqual(FolderSyncMerge.merge(x, y), FolderSyncMerge.merge(y, x))
        XCTAssertEqual(FolderSyncMerge.merge(x, y).fields?["title"], .string("B"))
        XCTAssertEqual(FolderSyncMerge.merge(x, y).fields?["knownPostCount"], .int(9))
        // A tombstone wins only over copies last changed before it.
        XCTAssertFalse(FolderSyncMerge.merge(x, z).isTombstone)
        let old = SyncRecord(kind: .watched, id: "w", fields: ["title": .string("A")], stamps: ["title": t1])
        XCTAssertTrue(FolderSyncMerge.merge(old, z).isTombstone)
        XCTAssertTrue(FolderSyncMerge.merge(z, old).isTombstone)
    }
}
