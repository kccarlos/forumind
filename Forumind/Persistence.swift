import Foundation
import Security

struct AppSnapshot: Codable {
    var settings = AppSettings()
    var sessions: [TopicSession] = []
    var activities: [WorkRecord] = []
    var agentRuns: [AgentRun] = []
    var watchedTopics: [WatchedTopic] = []
    var forums: [Forum] = []

    init(
        settings: AppSettings = AppSettings(),
        sessions: [TopicSession] = [],
        activities: [WorkRecord] = [],
        agentRuns: [AgentRun] = [],
        watchedTopics: [WatchedTopic] = [],
        forums: [Forum] = []
    ) {
        self.settings = settings
        self.sessions = sessions
        self.activities = activities
        self.agentRuns = agentRuns
        self.watchedTopics = watchedTopics
        self.forums = forums
    }

    private enum CodingKeys: String, CodingKey {
        case settings, sessions, activities, agentRuns, watchedTopics, forums
    }

    // Missing collections (older or partial snapshots) decode as empty.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        settings = try container.decodeIfPresent(AppSettings.self, forKey: .settings) ?? AppSettings()
        sessions = try container.decodeIfPresent([TopicSession].self, forKey: .sessions) ?? []
        activities = try container.decodeIfPresent([WorkRecord].self, forKey: .activities) ?? []
        agentRuns = try container.decodeIfPresent([AgentRun].self, forKey: .agentRuns) ?? []
        watchedTopics = try container.decodeIfPresent([WatchedTopic].self, forKey: .watchedTopics)
            ?? []
        forums = try container.decodeIfPresent([Forum].self, forKey: .forums) ?? []
    }
}

final class PersistentStore {
    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    /// Where provider API keys live. The app's store uses the Keychain; a
    /// store at a custom location (tests, previews) keeps them in memory so it
    /// never reads or overwrites the app's real keys.
    let keys: ProviderKeyStore
    /// Snapshot saves asked for so far (lets tests check that edits are
    /// coalesced); main thread only.
    private(set) var saveCount = 0
    /// Encodes and writes snapshots off the main thread, one at a time.
    private let writeQueue = DispatchQueue(label: "Forumind.snapshot-writer", qos: .utility)
    private let pendingLock = NSLock()
    /// The newest snapshot not written yet (an older one waiting is
    /// replaced: only the latest state matters), with who hears of a failure.
    private var pendingWrite: (snapshot: AppSnapshot, onError: (Error) -> Void)?
    /// The app's own store (Application Support), not a test/preview location.
    let usesDefaultLocation: Bool
    /// The folder holding the snapshot; iCloud sync keeps its files here too
    /// (`CloudSyncFiles`: `cloudsync.json`, `cloudsync-state.json`,
    /// `cloudsync-deletions.json`, `cloudsync-records/`).
    var directoryURL: URL {
        fileURL.deletingLastPathComponent()
    }

    init(fileURL: URL? = nil, keys: ProviderKeyStore? = nil) {
        self.keys = keys ?? (fileURL == nil ? KeychainProviderKeyStore.shared : InMemoryProviderKeyStore())
        usesDefaultLocation = fileURL == nil
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let support = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first!
            self.fileURL = support
                .appendingPathComponent("Forumind", isDirectory: true)
                .appendingPathComponent("state.json")
        }

        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    func load() -> AppSnapshot {
        flush()
        let snapshot = decodeSnapshot()
        // The key store follows "Sync API keys" before any key is read.
        (keys as? KeychainProviderKeyStore)?.configure(synchronizes: snapshot.settings.syncAPIKeys)
        return snapshot
    }

    private func decodeSnapshot() -> AppSnapshot {
        guard let data = try? Data(contentsOf: fileURL) else { return AppSnapshot() }
        do {
            return try decoder.decode(AppSnapshot.self, from: data)
        } catch {
            // The next save would overwrite the unreadable file with an empty
            // snapshot; keep a copy so the user's history can be recovered.
            preserveUnreadableSnapshot(data)
            return AppSnapshot()
        }
    }

    /// `state.unreadable-<timestamp>.json` next to the snapshot.
    private func preserveUnreadableSnapshot(_ data: Data) {
        let stamp = Int(Date().timeIntervalSince1970)
        let copy = fileURL.deletingLastPathComponent()
            .appendingPathComponent("state.unreadable-\(stamp).json")
        try? data.write(to: copy, options: .atomic)
    }

    /// Writes now, after any scheduled write (seeding, tests).
    func save(_ snapshot: AppSnapshot) throws {
        saveCount += 1
        try writeQueue.sync {
            drainPendingWrite()
            try write(snapshot)
        }
    }

    /// Writes in the background. Saves that arrive while one is being
    /// written are coalesced into one write of the newest snapshot, so writes
    /// land in order and never fall behind. `onError` runs on the main thread.
    func scheduleSave(_ snapshot: AppSnapshot, onError: @escaping (Error) -> Void) {
        saveCount += 1
        let startsWrite: Bool = pendingLock.withLock {
            let idle = pendingWrite == nil
            pendingWrite = (snapshot, onError)
            return idle
        }
        guard startsWrite else { return }
        writeQueue.async { [self] in drainPendingWrite() }
    }

    /// Waits until every scheduled snapshot is on disk (the app leaving the
    /// foreground, a background task ending, reading the file back).
    func flush() {
        writeQueue.sync { drainPendingWrite() }
    }

    /// On `writeQueue`.
    private func drainPendingWrite() {
        guard let pending = pendingLock.withLock({ () -> (snapshot: AppSnapshot, onError: (Error) -> Void)? in
            defer { pendingWrite = nil }
            return pendingWrite
        }) else {
            return
        }
        do {
            try write(pending.snapshot)
        } catch {
            DispatchQueue.main.async { pending.onError(error) }
        }
    }

    /// On `writeQueue`.
    private func write(_ snapshot: AppSnapshot) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let data = try encoder.encode(snapshot)
        try data.write(to: fileURL, options: .atomic)
    }
}

/// Storage for provider API keys (one per provider).
protocol ProviderKeyStore: AnyObject {
    func value(for provider: AIProvider) -> String
    func set(_ value: String, for provider: AIProvider) throws
    /// Settings › Sync › "Sync API keys" changed on this device. `keys` are
    /// the keys the app currently holds (a local copy is kept when turning off).
    func setSynchronizes(_ synchronizes: Bool, keys: [AIProvider: String])
}

extension ProviderKeyStore {
    func setSynchronizes(_ synchronizes: Bool, keys: [AIProvider: String]) {}
}

/// Provider keys in the Keychain. With sync on (the default) they are iCloud
/// Keychain (synchronizable) items, so every device signed in to the same
/// Apple Account gets them; with it off they are local items.
///
/// - Reads: a local item first (a local copy made while sync was off, or one
///   whose move to iCloud Keychain failed), then — with sync on — the
///   synchronizable item. With sync off only local items are read.
/// - Writes with sync on: the synchronizable item, then the local copy is
///   removed. If iCloud Keychain refuses the item the key is kept locally.
/// - Deleting a key with sync on removes the synchronizable item too, which
///   removes it on the user's other devices (it is what they asked for).
/// - Launch with sync on: local items move to iCloud Keychain (add, then
///   delete the local one only if the add worked). If a different synced key
///   already exists, the local key stays and keeps overriding it here.
/// - Turning sync off writes local copies and leaves the synced items alone
///   (deleting them would delete them on the user's other devices).
/// - Turning sync back on moves this device's keys into iCloud Keychain,
///   replacing the synced values.
final class KeychainProviderKeyStore: ProviderKeyStore {
    /// The app's store (Settings › Sync talks to it through `setSynchronizes`).
    static let shared = KeychainProviderKeyStore()

    let keychain: KeychainStore
    private(set) var synchronizes: Bool
    /// Last launch migration, for diagnostics.
    private(set) var lastMigration: [AIProvider: KeychainStore.MigrationOutcome] = [:]

    init(keychain: KeychainStore = KeychainStore(), synchronizes: Bool = true) {
        self.keychain = keychain
        self.synchronizes = synchronizes
    }

    func value(for provider: AIProvider) -> String {
        keychain.value(account: provider.rawValue, includeSynchronizable: synchronizes)
    }

    func set(_ value: String, for provider: AIProvider) throws {
        try keychain.set(value, account: provider.rawValue, synchronizable: synchronizes)
    }

    /// Launch: adopts the saved setting before any key is read; with sync on,
    /// moves local keys into iCloud Keychain (idempotent, runs every launch so
    /// a failed move is retried).
    func configure(synchronizes: Bool) {
        self.synchronizes = synchronizes
        guard synchronizes else { return }
        var outcomes: [AIProvider: KeychainStore.MigrationOutcome] = [:]
        for provider in AIProvider.allCases {
            outcomes[provider] = keychain.migrateToSynchronizable(account: provider.rawValue, replacingSynced: false)
        }
        lastMigration = outcomes
    }

    func setSynchronizes(_ synchronizes: Bool, keys: [AIProvider: String]) {
        guard synchronizes != self.synchronizes else { return }
        self.synchronizes = synchronizes
        for provider in AIProvider.allCases {
            if synchronizes {
                _ = keychain.migrateToSynchronizable(account: provider.rawValue, replacingSynced: true)
            } else if let key = keys[provider], !key.isEmpty {
                _ = keychain.writeLocalCopy(key, account: provider.rawValue)
            }
        }
    }
}

final class InMemoryProviderKeyStore: ProviderKeyStore {
    private var values: [AIProvider: String] = [:]
    /// Writes so far (tests check that typing does not write per keystroke).
    private(set) var writeCount = 0
    private(set) var synchronizes = true

    init(_ values: [AIProvider: String] = [:]) {
        self.values = values
    }

    func value(for provider: AIProvider) -> String { values[provider] ?? "" }

    func set(_ value: String, for provider: AIProvider) throws {
        writeCount += 1
        values[provider] = value.isEmpty ? nil : value
    }

    func setSynchronizes(_ synchronizes: Bool, keys: [AIProvider: String]) {
        self.synchronizes = synchronizes
    }
}

/// Raw generic-password operations for one service (seam for tests).
protocol KeychainBackend {
    /// `synchronizable`: true = only iCloud Keychain items, false = only local.
    func read(account: String, synchronizable: Bool) -> (status: OSStatus, data: Data?)
    func add(account: String, data: Data, synchronizable: Bool) -> OSStatus
    func update(account: String, data: Data, synchronizable: Bool) -> OSStatus
    /// `synchronizable` nil deletes both kinds (`kSecAttrSynchronizableAny`).
    func delete(account: String, synchronizable: Bool?) -> OSStatus
}

/// The Security framework. Items use `kSecAttrAccessibleWhenUnlocked` (the
/// Keychain default; synchronizable items can't use a ThisDeviceOnly class).
struct SecKeychainBackend: KeychainBackend {
    let service: String

    private func query(account: String, synchronizable: Bool?) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: synchronizable.map { $0 as CFBoolean } ?? kSecAttrSynchronizableAny
        ]
    }

    func read(account: String, synchronizable: Bool) -> (status: OSStatus, data: Data?) {
        var query = query(account: account, synchronizable: synchronizable)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return (status, result as? Data)
    }

    func add(account: String, data: Data, synchronizable: Bool) -> OSStatus {
        var query = query(account: account, synchronizable: synchronizable)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        return SecItemAdd(query as CFDictionary, nil)
    }

    func update(account: String, data: Data, synchronizable: Bool) -> OSStatus {
        SecItemUpdate(
            query(account: account, synchronizable: synchronizable) as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
    }

    func delete(account: String, synchronizable: Bool?) -> OSStatus {
        guard let synchronizable else {
            // One query per kind: where synchronizable items aren't allowed
            // (errSecMissingEntitlement), a SynchronizableAny delete fails
            // without removing the local item either.
            let local = delete(account: account, synchronizable: false)
            let synced = delete(account: account, synchronizable: true)
            return local == errSecSuccess || synced == errSecSuccess ? errSecSuccess : local
        }
        return SecItemDelete(query(account: account, synchronizable: synchronizable) as CFDictionary)
    }
}

/// Provider-key rules on top of a `KeychainBackend` (see
/// `KeychainProviderKeyStore` for the behavior).
struct KeychainStore {
    static let providerKeysService = AppIdentity.identifier("provider-keys")

    enum MigrationOutcome: Equatable {
        /// No local item.
        case nothingToMove
        /// Added to iCloud Keychain; the local item was removed.
        case moved
        /// iCloud Keychain already had the same key; the local item was removed.
        case alreadySynced
        /// Turning sync on: this device's key replaced the synced one.
        case replacedSynced
        /// A different synced key exists; the local key stays and overrides it here.
        case keptLocal
        /// iCloud Keychain refused the item; the local key stays.
        case failed(OSStatus)
    }

    let backend: KeychainBackend

    init(backend: KeychainBackend = SecKeychainBackend(service: KeychainStore.providerKeysService)) {
        self.backend = backend
    }

    func value(account: String, includeSynchronizable: Bool) -> String {
        if let local = string(account: account, synchronizable: false) { return local }
        guard includeSynchronizable else { return "" }
        return string(account: account, synchronizable: true) ?? ""
    }

    func set(_ value: String, account: String, synchronizable: Bool) throws {
        if value.isEmpty {
            // With sync on this removes the synced item on every device.
            _ = backend.delete(account: account, synchronizable: synchronizable ? nil : false)
            return
        }
        let data = Data(value.utf8)
        if synchronizable {
            if upsert(account: account, data: data, synchronizable: true) == errSecSuccess {
                _ = backend.delete(account: account, synchronizable: false)
                return
            }
            // iCloud Keychain unavailable: keep the key on this device instead.
        }
        let status = upsert(account: account, data: data, synchronizable: false)
        guard status == errSecSuccess else {
            throw NSError(
                domain: NSOSStatusErrorDomain,
                code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: String(localized: "Unable to store API key in Keychain.")]
            )
        }
    }

    /// Moves a local item into iCloud Keychain. The local item is deleted
    /// only once the synchronizable one holds the same key.
    func migrateToSynchronizable(account: String, replacingSynced: Bool) -> MigrationOutcome {
        let localRead = backend.read(account: account, synchronizable: false)
        guard localRead.status == errSecSuccess, let local = localRead.data else { return .nothingToMove }
        let syncedRead = backend.read(account: account, synchronizable: true)
        if syncedRead.status == errSecSuccess, let synced = syncedRead.data {
            if synced == local {
                _ = backend.delete(account: account, synchronizable: false)
                return .alreadySynced
            }
            guard replacingSynced else { return .keptLocal }
            let status = backend.update(account: account, data: local, synchronizable: true)
            guard status == errSecSuccess else { return .failed(status) }
            _ = backend.delete(account: account, synchronizable: false)
            return .replacedSynced
        }
        let status = backend.add(account: account, data: local, synchronizable: true)
        guard status == errSecSuccess else { return .failed(status) }
        _ = backend.delete(account: account, synchronizable: false)
        return .moved
    }

    /// Turning sync off: a local copy (the synced item is left alone).
    @discardableResult
    func writeLocalCopy(_ value: String, account: String) -> OSStatus {
        upsert(account: account, data: Data(value.utf8), synchronizable: false)
    }

    private func string(account: String, synchronizable: Bool) -> String? {
        let result = backend.read(account: account, synchronizable: synchronizable)
        guard result.status == errSecSuccess, let data = result.data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func upsert(account: String, data: Data, synchronizable: Bool) -> OSStatus {
        let status = backend.update(account: account, data: data, synchronizable: synchronizable)
        guard status == errSecItemNotFound else { return status }
        return backend.add(account: account, data: data, synchronizable: synchronizable)
    }
}

/// The work queue's worker slots: at most `limit` jobs at once, one per
/// topic. A slot belongs to its job (`workID`), so cancelling a job frees
/// its slot at once, even while its task is still unwinding (a provider or
/// web page that ignores cancellation), and a late release is a no-op.
actor TaskLimiter {
    private struct Waiter {
        let workID: UUID
        let topicID: String
        let continuation: CheckedContinuation<Bool, Never>
    }

    private let limit: Int
    /// Topic of each job holding a slot.
    private var active: [UUID: String] = [:]
    private var waiters: [Waiter] = []

    init(limit: Int) {
        self.limit = max(1, limit)
    }

    private var activeTopics: Set<String> { Set(active.values) }

    func acquire(topicID: String, workID: UUID) async -> Bool {
        if Task.isCancelled {
            return false
        }
        if active.count < limit, !activeTopics.contains(topicID) {
            active[workID] = topicID
            return true
        }
        return await withCheckedContinuation { continuation in
            waiters.append(
                Waiter(workID: workID, topicID: topicID, continuation: continuation)
            )
        }
    }

    /// A cancelled job: out of the queue, or its slot freed.
    func cancel(workID: UUID) {
        if let index = waiters.firstIndex(where: { $0.workID == workID }) {
            waiters.remove(at: index).continuation.resume(returning: false)
        } else {
            release(workID: workID)
        }
    }

    func release(workID: UUID) {
        guard active.removeValue(forKey: workID) != nil else { return }
        while active.count < limit,
              let nextIndex = waiters.firstIndex(where: {
                  !activeTopics.contains($0.topicID)
              })
        {
            let next = waiters.remove(at: nextIndex)
            active[next.workID] = next.topicID
            next.continuation.resume(returning: true)
        }
    }

    func state() -> (activeTopics: Set<String>, waitingTopics: [String]) {
        (activeTopics, waiters.map(\.topicID))
    }
}
