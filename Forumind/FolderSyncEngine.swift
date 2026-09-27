import CryptoKit
import Foundation

// MARK: - Baseline

/// What this device and the folder last agreed on, per record: unit hashes
/// and stamps (to tell local edits from remote ones), the plaintext hash of
/// the file, tombstones, and "pruned locally at remote hash X".
/// Stored in Application Support beside `state.json` (`foldersync.json`).
struct FolderSyncBaseline: Codable, Equatable {
    struct Unit: Codable, Equatable {
        var h: String
        var s: Date
    }

    struct Entry: Codable, Equatable {
        var units: [String: Unit]?
        var deletedAt: Date?
        /// Plaintext hash of the file as last read or written.
        var remoteHash: String?
        /// Set when this device pruned the record (no tombstone): it is not
        /// imported again until the remote file's hash differs from this.
        var prunedRemoteHash: String?
        /// First pass that found the file missing while this device may have
        /// missed its tombstone (see `plan`); cleared once the file is seen.
        var missingSince: Date?

        var latestStamp: Date {
            deletedAt ?? units?.values.map(\.s).max() ?? .distantPast
        }
    }

    /// The sync root this baseline belongs to (another folder starts fresh).
    var folder: String?
    var keyID: String?
    var records: [String: Entry] = [:]
    /// Start of the last pass that committed without errors. A device whose
    /// last pass is older than the tombstone lifetime may have missed
    /// deletes whose tombstones are gone (see `plan`).
    var lastPassAt: Date?

    static func load(from url: URL?) -> FolderSyncBaseline {
        guard let url, let data = try? Data(contentsOf: url),
              let baseline = try? FolderSyncCoding.makeDecoder().decode(FolderSyncBaseline.self, from: data)
        else {
            return FolderSyncBaseline()
        }
        return baseline
    }

    func save(to url: URL?) {
        guard let url else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if let data = try? FolderSyncCoding.data(self) {
            try? data.write(to: url, options: .atomic)
        }
    }
}

// MARK: - Encryption

/// `format.json` (plaintext): the folder's format and current key id.
struct FolderSyncFormat: Codable, Equatable {
    var format = 1
    var keyID: String
}

/// A record file: AES-GCM (CryptoKit) sealed box of the plaintext record.
struct FolderSyncEnvelope: Codable {
    var v = 1
    var keyID: String
    /// Base64 of nonce + ciphertext + tag.
    var box: String
}

enum FolderSyncError: LocalizedError, Equatable {
    case missingKey(String)
    case unreadable(String)
    case noFolder

    var errorDescription: String? {
        switch self {
        case .missingKey: "This device doesn’t have the sync key yet."
        case .unreadable(let name): "Couldn’t read \(name) in the sync folder."
        case .noFolder: "No sync folder is chosen."
        }
    }
}

enum FolderSyncCrypto {
    static func seal(_ plaintext: Data, key: SymmetricKey, keyID: String) throws -> Data {
        let box = try AES.GCM.seal(plaintext, using: key)
        guard let combined = box.combined else { throw FolderSyncError.unreadable("record") }
        let envelope = FolderSyncEnvelope(keyID: keyID, box: combined.base64EncodedString())
        return try FolderSyncCoding.data(envelope)
    }

    static func open(_ data: Data, keys: SyncKeyProvider) throws -> (plaintext: Data, keyID: String) {
        guard let envelope = try? JSONDecoder().decode(FolderSyncEnvelope.self, from: data),
              let combined = Data(base64Encoded: envelope.box)
        else {
            throw FolderSyncError.unreadable("record")
        }
        guard let key = keys.key(id: envelope.keyID) else { throw FolderSyncError.missingKey(envelope.keyID) }
        do {
            let box = try AES.GCM.SealedBox(combined: combined)
            return (try AES.GCM.open(box, using: key), envelope.keyID)
        } catch {
            throw FolderSyncError.unreadable("record")
        }
    }
}

// MARK: - Local state and changes

/// The synced part of the app's state, captured on the main actor.
struct FolderSyncLocalState {
    var settings: AppSettings
    var sessions: [String: TopicSession]
    var runs: [AgentRun]
    var watched: [WatchedTopic]
    var forums: [Forum]
    /// Topics with work queued or running here: a remote delete of their
    /// session waits (like a local delete, which the app refuses meanwhile).
    var busyTopicKeys: Set<String> = []
    /// Records deleted on this device, with the time of the delete
    /// (`FolderSyncController`'s deletion log), by record key.
    var deletions: [String: Date] = [:]
}

/// One record to change locally. `expected` is the local value the merge was
/// computed from; if the record changed since, the change is skipped (the
/// next pass merges again), so a local edit is never clobbered.
struct FolderSyncRecordChange<Value> {
    var id: String
    var expected: Value?
    /// nil deletes the record.
    var value: Value?
}

struct FolderSyncSettingsChange {
    /// `settings.persistable` the merge was computed from.
    var expected: AppSettings
    var units: [String: JSONValue]
}

/// Merged remote data to apply locally (`AppModel.applyRemote(_:)`).
struct FolderSyncChanges {
    var settings: FolderSyncSettingsChange?
    var sessions: [FolderSyncRecordChange<TopicSession>] = []
    var runs: [FolderSyncRecordChange<AgentRun>] = []
    var watched: [FolderSyncRecordChange<WatchedTopic>] = []
    var forums: [FolderSyncRecordChange<Forum>] = []

    var isEmpty: Bool {
        settings == nil && sessions.isEmpty && runs.isEmpty && watched.isEmpty && forums.isEmpty
    }
}

// MARK: - Engine

/// One sync pass = read the folder → merge with local state and baseline →
/// (main actor) apply → write. Runs off the main thread; all file access is
/// coordinated through `FolderSyncStorage`.
actor FolderSyncEngine {
    static let rootName = "Forumind Sync"
    static let tombstoneLifetime: TimeInterval = 60 * 24 * 60 * 60
    /// A file must stay missing this long (over two passes) before a device
    /// back from a long absence takes it as deleted: right after it returns,
    /// iCloud Drive may not list other devices' files yet.
    static let missingFileGrace: TimeInterval = 30 * 60
    private static let epoch = Date(timeIntervalSince1970: 0)

    struct RemoteRecord {
        var record: SyncRecord
        /// Canonical plaintext of the file itself (without conflict versions).
        var canonical: Data
        var keyID: String
        var hasConflicts: Bool
        var url: URL
    }

    struct Remote {
        var keyID: String
        /// The folder's key differs from the one this baseline was built
        /// with (another device reset the folder): missing files are not
        /// taken as deletes.
        var keyChanged = false
        /// `setRoot`/`forget`/`resetFolder` count; a plan from an older
        /// folder is never committed.
        var generation = 0
        var records: [String: RemoteRecord] = [:]
        /// Relative paths not to touch this pass (downloading or unreadable).
        var heldPaths: Set<String> = []
        var unreadable: [String] = []
    }

    enum ReadOutcome {
        case ready(Remote)
        case waitingForKey
        /// `format.json` is still downloading.
        case downloading
    }

    struct Operation {
        var url: URL
        /// Plaintext hash of the file before this pass (nil: no file); the
        /// baseline keeps it when the write fails.
        var previousRemoteHash: String?
        var write: SyncRecord?
        var removeFile = false
        var resolveConflicts = false
        /// New baseline entry; nil removes it.
        var baseline: FolderSyncBaseline.Entry?
    }

    struct Plan {
        var changes = FolderSyncChanges()
        var operations: [String: Operation] = [:]
        var now = Date()
        var generation = 0
        /// Entries of `FolderSyncLocalState.deletions` this plan used up (all
        /// but those whose file is still downloading).
        var handledDeletions: [String: Date] = [:]
    }

    struct CommitResult {
        var writes = 0
        var errors: [Error] = []
        /// The folder changed (stop, another folder, reset) since the plan
        /// was made: nothing was written.
        var stale = false
    }

    private struct LocalItem {
        var kind: SyncKind
        var id: String
        var units: [String: JSONValue]
        var recordTime: Date?
        /// When this device last touched the record (forums: last visit;
        /// watched: added). Only decides whether a copy that joins a folder
        /// holding a tombstone for it is newer than the delete.
        var touchedAt: Date?
        var held = false
    }

    private struct CachedFile {
        var modifiedAt: Date?
        var size: Int?
        var remote: RemoteRecord
    }

    let storage: FolderSyncStorage
    let keys: SyncKeyProvider
    private let baselineURL: URL?
    private(set) var baseline: FolderSyncBaseline
    private(set) var root: URL?
    private(set) var generation = 0
    private var cache: [String: CachedFile] = [:]
    /// Records pruned since the last commit (a pass may have captured them
    /// before the prune; commit keeps their pruned mark).
    private var prunedDuringPass: Set<String> = []
    /// Files written or removed by this engine (tests check for zero).
    private(set) var totalWrites = 0

    init(storage: FolderSyncStorage, keys: SyncKeyProvider, baselineURL: URL?) {
        self.storage = storage
        self.keys = keys
        self.baselineURL = baselineURL
        baseline = FolderSyncBaseline.load(from: baselineURL)
    }

    /// The sync root inside a picked folder (the picked folder itself when
    /// the user picked an existing "Forumind Sync" folder).
    static func syncRoot(forPicked folder: URL) -> URL {
        folder.lastPathComponent == rootName
            ? folder
            : folder.appendingPathComponent(rootName, isDirectory: true)
    }

    func setRoot(_ url: URL?) {
        root = url
        cache = [:]
        generation += 1
        guard let url else { return }
        let path = url.standardizedFileURL.path
        if baseline.folder != path {
            baseline = FolderSyncBaseline(folder: path)
            baseline.save(to: baselineURL)
        }
    }

    /// Stop syncing: forget the folder and the baseline (the folder is untouched).
    func forget() {
        root = nil
        cache = [:]
        generation += 1
        prunedDuringPass = []
        baseline = FolderSyncBaseline()
        if let baselineURL { try? FileManager.default.removeItem(at: baselineURL) }
    }

    func notePruned(kind: SyncKind, ids: [String]) {
        for id in ids {
            let key = SyncRecord.recordKey(kind: kind, id: id)
            prunedDuringPass.insert(key)
            guard var entry = baseline.records[key], entry.units != nil else { continue }
            entry.prunedRemoteHash = entry.remoteHash ?? ""
            baseline.records[key] = entry
        }
        baseline.save(to: baselineURL)
    }

    private func path(kind: SyncKind, id: String) -> String {
        let name = SyncRecord.fileName(kind: kind, id: id)
        return kind.directory.map { "\($0)/\(name)" } ?? name
    }

    private func url(forPath path: String) -> URL {
        root!.appendingPathComponent(path)
    }

    // MARK: Read

    func readRemote(thorough: Bool) throws -> ReadOutcome {
        guard let root else { throw FolderSyncError.noFolder }
        try storage.ensureDirectory(root)
        for kind in SyncKind.allCases {
            if let directory = kind.directory {
                try storage.ensureDirectory(root.appendingPathComponent(directory, isDirectory: true))
            }
        }
        let rootFiles = try storage.list(root)
        let formatURL = root.appendingPathComponent("format.json")
        if let info = rootFiles.first(where: { $0.name == "format.json" }), !info.isCurrent {
            return .downloading
        }

        // format.json: create if absent; with conflicting copies the lowest
        // key id wins and records under other keys are re-encrypted.
        var keyID: String
        if let data = try storage.read(formatURL) {
            guard let format = try? JSONDecoder().decode(FolderSyncFormat.self, from: data) else {
                throw FolderSyncError.unreadable("format.json")
            }
            keyID = format.keyID
        } else {
            let newID = try keys.makeKey()
            let data = try FolderSyncCoding.data(FolderSyncFormat(keyID: newID))
            let actual: Data
            do {
                actual = try storage.createIfAbsent(data, at: formatURL)
            } catch {
                keys.remove(id: newID)
                throw error
            }
            guard let format = try? JSONDecoder().decode(FolderSyncFormat.self, from: actual) else {
                throw FolderSyncError.unreadable("format.json")
            }
            keyID = format.keyID
            if actual == data {
                totalWrites += 1
            } else if format.keyID != newID {
                // Another device created format.json first: the new key was
                // never written anywhere, so it doesn't linger in iCloud Keychain.
                keys.remove(id: newID)
            }
        }
        let candidates = storage.conflictVersions(of: formatURL)
            .compactMap { try? JSONDecoder().decode(FolderSyncFormat.self, from: $0).keyID }
        if !candidates.isEmpty {
            let winner = (candidates + [keyID]).min()!
            if winner != keyID {
                try storage.write(try FolderSyncCoding.data(FolderSyncFormat(keyID: winner)), to: formatURL)
                totalWrites += 1
                keyID = winner
            }
            storage.resolveConflicts(of: formatURL)
        }
        guard keys.key(id: keyID) != nil else { return .waitingForKey }

        // The baseline takes the new key id in `commit`.
        var remote = Remote(keyID: keyID)
        remote.keyChanged = baseline.keyID != nil && baseline.keyID != keyID
        remote.generation = generation
        var seenPaths: Set<String> = []
        var listings: [(String, FolderSyncFileInfo)] = rootFiles
            .filter { $0.name == "settings.json" }
            .map { ($0.name, $0) }
        for kind in SyncKind.allCases {
            guard let directory = kind.directory else { continue }
            for info in try storage.list(root.appendingPathComponent(directory, isDirectory: true)) {
                listings.append(("\(directory)/\(info.name)", info))
            }
        }
        for (path, info) in listings {
            seenPaths.insert(path)
            guard info.isCurrent else {
                remote.heldPaths.insert(path)
                continue
            }
            if !thorough, let cached = cache[path],
               cached.modifiedAt == info.modifiedAt, cached.size == info.size {
                remote.records[cached.remote.record.recordKey] = cached.remote
                continue
            }
            guard let data = try storage.read(info.url) else { continue }
            let conflicts = storage.conflictVersions(of: info.url)
            do {
                let (plaintext, fileKeyID) = try FolderSyncCrypto.open(data, keys: keys)
                let record = try FolderSyncCoding.makeDecoder().decode(SyncRecord.self, from: plaintext)
                // The name and folder must match the record inside, so a file
                // copied or moved over another record's is refused.
                guard self.path(kind: record.kind, id: record.id) == path else {
                    throw FolderSyncError.unreadable(path)
                }
                var copies = [record]
                for version in conflicts {
                    if let opened = try? FolderSyncCrypto.open(version, keys: keys),
                       let other = try? FolderSyncCoding.makeDecoder().decode(SyncRecord.self, from: opened.plaintext),
                       other.kind == record.kind, other.id == record.id {
                        copies.append(other)
                    }
                }
                let entry = RemoteRecord(
                    record: FolderSyncMerge.merge(copies) ?? record,
                    canonical: try record.canonicalData(),
                    keyID: fileKeyID,
                    hasConflicts: !conflicts.isEmpty,
                    url: info.url
                )
                remote.records[record.recordKey] = entry
                if conflicts.isEmpty {
                    cache[path] = CachedFile(modifiedAt: info.modifiedAt, size: info.size, remote: entry)
                } else {
                    cache.removeValue(forKey: path)
                }
            } catch {
                // Undecryptable or corrupt: leave the file alone, keep going.
                remote.heldPaths.insert(path)
                remote.unreadable.append(path)
                cache.removeValue(forKey: path)
            }
        }
        for path in cache.keys where !seenPaths.contains(path) {
            cache.removeValue(forKey: path)
        }
        return .ready(remote)
    }

    // MARK: Plan

    private func localItems(_ local: FolderSyncLocalState, now: Date) -> [String: LocalItem] {
        var items: [String: LocalItem] = [:]
        func add(
            _ kind: SyncKind, _ id: String, _ units: [String: JSONValue]?,
            time: Date?, touched: Date? = nil, held: Bool = false
        ) {
            guard let units else { return }
            items[SyncRecord.recordKey(kind: kind, id: id)] = LocalItem(
                kind: kind, id: id, units: units, recordTime: time, touchedAt: touched ?? time, held: held
            )
        }
        add(.settings, "settings", try? FolderSyncSchema.settingsUnits(local.settings), time: nil)
        for (key, session) in local.sessions {
            add(
                .session, key, Self.units(session: session, now: now),
                time: session.updatedAt, touched: max(session.updatedAt, session.lastAccessedAt)
            )
        }
        for run in local.runs {
            // A run syncs once it has finished; until then it belongs to the
            // device running it (and remote copies do not touch it).
            add(.run, run.id.uuidString, Self.units(.run, run), time: run.updatedAt, held: !run.status.isTerminal)
        }
        for watched in local.watched {
            add(.watched, watched.topicKey, Self.units(.watched, watched), time: nil, touched: watched.addedAt)
        }
        for forum in local.forums {
            add(
                .forum, forum.siteURL, Self.units(.forum, forum),
                time: nil, touched: max(forum.addedAt, forum.lastVisitedAt ?? forum.addedAt)
            )
        }
        return items
    }

    static func units<T: Encodable>(_ kind: SyncKind, _ value: T) -> [String: JSONValue]? {
        guard let object = (try? FolderSyncCoding.json(value))?.objectValue else { return nil }
        return FolderSyncSchema.units(kind: kind, object: object)
    }

    /// A chat that expired (unkept, 24 h idle) counts as cleared on every
    /// device, whether or not this launch already cleared it.
    static func units(session: TopicSession, now: Date) -> [String: JSONValue]? {
        var canonical = session
        if !session.kept, let updated = session.chatUpdatedAt, now.timeIntervalSince(updated) >= 24 * 60 * 60 {
            canonical.history = []
            canonical.chatUpdatedAt = nil
        }
        return units(.session, canonical)
    }

    private func decode<T: Decodable>(_ type: T.Type, kind: SyncKind, units: [String: JSONValue]) -> T? {
        try? FolderSyncCoding.decode(type, from: .object(FolderSyncSchema.object(kind: kind, units: units)))
    }

    /// Stamps for a local record: unchanged units keep the baseline stamp;
    /// changed ones get the record's own time (sessions, runs) or now, and
    /// always something newer than what they replace.
    private func stamped(
        _ item: LocalItem,
        entry: FolderSyncBaseline.Entry?,
        remoteExists: Bool,
        now: Date,
        fresh: Bool
    ) -> SyncRecord {
        var stamps: [String: Date] = [:]
        for (unit, value) in item.units {
            let hash = FolderSyncCoding.hash(value)
            if let known = entry?.units?[unit], known.h == hash {
                stamps[unit] = known.s
            } else if entry == nil || (entry?.units == nil && entry?.deletedAt == nil) {
                // Never synced from this device. A record the folder does
                // not have yet is new; on joining a folder that already has
                // it, the folder's values win (unless the record carries its
                // own modification time). After a reset this device wins.
                let time = fresh ? now : (item.recordTime ?? (remoteExists ? Self.epoch : now))
                stamps[unit] = FolderSyncCoding.stamp(time)
            } else {
                let previous = entry?.units?[unit]?.s ?? entry?.deletedAt ?? Self.epoch
                let floor = previous.addingTimeInterval(1)
                stamps[unit] = FolderSyncCoding.stamp(max(item.recordTime ?? now, floor))
            }
        }
        return SyncRecord(kind: item.kind, id: item.id, fields: item.units, stamps: stamps, deletedAt: nil)
    }

    private func baselineEntry(for record: SyncRecord, remoteHash: String?) -> FolderSyncBaseline.Entry {
        if let deletedAt = record.deletedAt {
            return FolderSyncBaseline.Entry(deletedAt: deletedAt, remoteHash: remoteHash)
        }
        var units: [String: FolderSyncBaseline.Unit] = [:]
        for (unit, value) in record.fields ?? [:] {
            units[unit] = FolderSyncBaseline.Unit(h: FolderSyncCoding.hash(value), s: record.stamps?[unit] ?? Self.epoch)
        }
        return FolderSyncBaseline.Entry(units: units, remoteHash: remoteHash)
    }

    /// Merges local state, the folder, and the baseline. `fresh` (after
    /// "Reset sync data") stamps this device's records as new so they win.
    func plan(local: FolderSyncLocalState, remote: Remote, now: Date, fresh: Bool = false) -> Plan {
        let now = FolderSyncCoding.stamp(now)
        let items = localItems(local, now: now)
        var plan = Plan(now: now, generation: remote.generation)
        var keys = Set(items.keys).union(remote.records.keys)
        for key in baseline.records.keys where !fresh { keys.insert(key) }
        for (key, date) in local.deletions {
            guard let (kind, id) = Self.parse(key), !remote.heldPaths.contains(path(kind: kind, id: id)) else { continue }
            plan.handledDeletions[key] = date
        }
        // Tombstones are removed after `tombstoneLifetime`. A device whose
        // last pass is older than that may have missed a delete entirely: a
        // record it synced, didn't change since, and that is no longer in
        // the folder was deleted elsewhere (see below).
        let missedTombstones = !fresh && !remote.keyChanged
            && baseline.lastPassAt.map { now.timeIntervalSince($0) > Self.tombstoneLifetime - 24 * 60 * 60 } == true

        let sessionsByKey = local.sessions
        let runsByID = Dictionary(local.runs.map { ($0.id.uuidString, $0) }, uniquingKeysWith: { a, _ in a })
        let watchedByKey = Dictionary(local.watched.map { ($0.topicKey, $0) }, uniquingKeysWith: { a, _ in a })
        let forumsByURL = Dictionary(local.forums.map { ($0.siteURL, $0) }, uniquingKeysWith: { a, _ in a })

        for key in keys.sorted() {
            guard let (kind, id) = Self.parse(key) else { continue }
            let path = path(kind: kind, id: id)
            if remote.heldPaths.contains(path) { continue }
            let item = items[key]
            if item?.held == true { continue }
            let entry = fresh ? nil : baseline.records[key]
            let remoteRecord = remote.records[key]
            let remoteHash = remoteRecord.map { FolderSyncCoding.hash($0.canonical) }

            // Synced before, unchanged here, gone from the folder, and this
            // device has been away longer than tombstones live: deleted
            // elsewhere. (A recent device re-uploads instead: its tombstone
            // would still be there, so a missing file isn't a delete.)
            // The first pass only notes the absence; the record goes once the
            // file has stayed missing for `missingFileGrace` (a listing right
            // after a long absence may not show other devices' files yet).
            if let item, let entry, missedTombstones || entry.missingSince != nil, remoteRecord == nil,
               entry.remoteHash != nil, entry.prunedRemoteHash == nil,
               let known = entry.units, Set(known.keys) == Set(item.units.keys),
               item.units.allSatisfy({ known[$0.key]?.h == FolderSyncCoding.hash($0.value) }) {
                var operation = Operation(url: url(forPath: path))
                guard let since = entry.missingSince else {
                    var marked = entry
                    marked.missingSince = now
                    operation.baseline = marked
                    plan.operations[key] = operation
                    continue
                }
                guard now.timeIntervalSince(since) >= Self.missingFileGrace else { continue }
                if kind == .session, local.busyTopicKeys.contains(id) { continue }
                appendDelete(kind: kind, id: id, to: &plan, local: local)
                operation.baseline = nil
                plan.operations[key] = operation
                continue
            }

            // This device's copy of the record.
            var mine: SyncRecord?
            if let item {
                mine = stamped(item, entry: entry, remoteExists: remoteRecord != nil, now: now, fresh: fresh)
                if entry == nil, !fresh, let deletedAt = remoteRecord?.record.deletedAt,
                   let touched = item.touchedAt, FolderSyncCoding.stamp(touched) > deletedAt,
                   let fields = mine?.fields {
                    // Joining a folder that holds a tombstone for a record this
                    // device used after the delete: keep it (and bring it back).
                    let stamp = FolderSyncCoding.stamp(touched)
                    mine?.stamps = fields.mapValues { _ in stamp }
                }
            } else if let entry, let prunedHash = entry.prunedRemoteHash {
                // Pruned here: stay out until the remote file changes.
                if remoteRecord == nil || remoteHash == prunedHash { continue }
            } else if let deletedAt = local.deletions[key], entry != nil || remoteRecord != nil {
                // Deleted here, at a known time (never later than the delete
                // itself, e.g. when the app was killed before the next pass),
                // and after everything this device had seen of the record.
                let floor = entry.map { $0.latestStamp.addingTimeInterval(1) } ?? .distantPast
                mine = .tombstone(kind: kind, id: id, deletedAt: max(FolderSyncCoding.stamp(deletedAt), floor))
            } else if let entry, let deletedAt = entry.deletedAt {
                mine = .tombstone(kind: kind, id: id, deletedAt: deletedAt)
            } else if let entry, entry.units != nil {
                // Deleted here since the last pass.
                let deletedAt = max(now, entry.latestStamp.addingTimeInterval(1))
                mine = .tombstone(kind: kind, id: id, deletedAt: deletedAt)
            }

            let copies = [mine, remoteRecord?.record].compactMap { $0 }
            guard let merged = FolderSyncMerge.merge(copies) else { continue }
            var operation = Operation(url: url(forPath: path), previousRemoteHash: remoteHash)

            // Tombstones expire after 60 days.
            if let deletedAt = merged.deletedAt, now.timeIntervalSince(deletedAt) > Self.tombstoneLifetime {
                if item != nil { appendDelete(kind: kind, id: id, to: &plan, local: local) }
                operation.removeFile = remoteRecord != nil
                operation.baseline = nil
                plan.operations[key] = operation
                continue
            }

            // Local change (none when the merge is this device's own copy).
            if let mine, !mine.isTombstone, merged.fields == mine.fields {
                // Unchanged here.
            } else if merged.isTombstone {
                if item != nil {
                    if kind == .session, local.busyTopicKeys.contains(id) { continue }
                    appendDelete(kind: kind, id: id, to: &plan, local: local)
                }
            } else if let fields = merged.fields {
                switch kind {
                case .settings:
                    if let current = try? FolderSyncSchema.settingsUnits(local.settings),
                       let applied = try? FolderSyncSchema.applying(settingsUnits: fields, to: local.settings),
                       let appliedUnits = try? FolderSyncSchema.settingsUnits(applied),
                       appliedUnits != current {
                        plan.changes.settings = FolderSyncSettingsChange(expected: local.settings, units: fields)
                    }
                case .session:
                    if var value = decode(TopicSession.self, kind: kind, units: fields),
                       Self.units(session: value, now: now) != item?.units {
                        let expected = sessionsByKey[id]
                        value.source = expected?.source ?? ""
                        value.rawPages = expected?.rawPages ?? []
                        value.lastCheckedAt = expected?.lastCheckedAt
                        plan.changes.sessions.append(.init(id: id, expected: expected, value: value))
                    }
                case .run:
                    if let value = decode(AgentRun.self, kind: kind, units: fields),
                       Self.units(.run, value) != item?.units {
                        plan.changes.runs.append(.init(id: id, expected: runsByID[id], value: value))
                    }
                case .watched:
                    if var value = decode(WatchedTopic.self, kind: kind, units: fields),
                       Self.units(.watched, value) != item?.units {
                        // Device-local, see FolderSyncSchema.watchedExcluded.
                        value.lastCheckedAt = watchedByKey[id]?.lastCheckedAt
                        plan.changes.watched.append(.init(id: id, expected: watchedByKey[id], value: value))
                    }
                case .forum:
                    if let value = decode(Forum.self, kind: kind, units: fields),
                       Self.units(.forum, value) != item?.units {
                        plan.changes.forums.append(.init(id: id, expected: forumsByURL[id], value: value))
                    }
                }
            }

            // Remote change. (The file's own record equal to the merge means
            // the same canonical bytes: skip encoding it again.)
            let unchangedRemote = remoteRecord.map { !$0.hasConflicts && $0.record == merged } ?? false
            let mergedData = unchangedRemote ? remoteRecord!.canonical : ((try? merged.canonicalData()) ?? Data())
            let needsWrite = remoteRecord == nil
                || remoteRecord?.canonical != mergedData
                || remoteRecord?.keyID != remote.keyID
                || remoteRecord?.hasConflicts == true
            if needsWrite {
                operation.write = merged
            }
            operation.resolveConflicts = remoteRecord?.hasConflicts == true
            let mergedHash = unchangedRemote ? remoteHash! : FolderSyncCoding.hash(mergedData)
            operation.baseline = baselineEntry(for: merged, remoteHash: mergedHash)
            plan.operations[key] = operation
        }
        return plan
    }

    /// "kind/id" → (kind, id).
    static func parse(_ recordKey: String) -> (SyncKind, String)? {
        guard let slash = recordKey.firstIndex(of: "/"),
              let kind = SyncKind(rawValue: String(recordKey[..<slash]))
        else {
            return nil
        }
        return (kind, String(recordKey[recordKey.index(after: slash)...]))
    }

    private func appendDelete(kind: SyncKind, id: String, to plan: inout Plan, local: FolderSyncLocalState) {
        switch kind {
        case .settings:
            break
        case .session:
            plan.changes.sessions.append(.init(id: id, expected: local.sessions[id], value: nil))
        case .run:
            plan.changes.runs.append(.init(id: id, expected: local.runs.first { $0.id.uuidString == id }, value: nil))
        case .watched:
            plan.changes.watched.append(.init(id: id, expected: local.watched.first { $0.topicKey == id }, value: nil))
        case .forum:
            plan.changes.forums.append(.init(id: id, expected: local.forums.first { $0.siteURL == id }, value: nil))
        }
    }

    // MARK: Commit

    /// Writes the plan (except records whose local apply was skipped) and
    /// saves the baseline. A failed write is retried by the next pass: the
    /// merge is compared with what the folder actually holds.
    func commit(_ plan: Plan, skipped: Set<String>, keyID: String) -> CommitResult {
        var result = CommitResult()
        guard plan.generation == generation, let root else {
            result.stale = true
            return result
        }
        guard let key = keys.key(id: keyID) else {
            result.errors.append(FolderSyncError.missingKey(keyID))
            return result
        }
        for (recordKey, operation) in plan.operations.sorted(by: { $0.key < $1.key })
        where !skipped.contains(recordKey) {
            let relative = String(operation.url.path.dropFirst(root.path.count + 1))
            var failed = false
            do {
                if let record = operation.write {
                    let plaintext = try record.canonicalData()
                    let sealed = try FolderSyncCrypto.seal(plaintext, key: key, keyID: keyID)
                    try storage.write(sealed, to: operation.url)
                    result.writes += 1
                    let remote = RemoteRecord(
                        record: record, canonical: plaintext, keyID: keyID, hasConflicts: false, url: operation.url
                    )
                    if let info = storage.info(of: operation.url) {
                        cache[relative] = CachedFile(modifiedAt: info.modifiedAt, size: info.size, remote: remote)
                    }
                }
                if operation.removeFile {
                    try storage.remove(operation.url)
                    cache.removeValue(forKey: relative)
                    result.writes += 1
                }
                if operation.resolveConflicts {
                    storage.resolveConflicts(of: operation.url)
                }
            } catch {
                result.errors.append(error)
                failed = true
            }
            if var entry = operation.baseline {
                // A failed write leaves the file as it was: the baseline says
                // so, and the next pass writes again (a record that never
                // reached the folder is never taken as deleted elsewhere).
                if failed, operation.write != nil { entry.remoteHash = operation.previousRemoteHash }
                if prunedDuringPass.contains(recordKey), entry.units != nil {
                    entry.prunedRemoteHash = entry.remoteHash ?? ""
                }
                baseline.records[recordKey] = entry
            } else if !failed {
                baseline.records.removeValue(forKey: recordKey)
            }
        }
        prunedDuringPass = []
        totalWrites += result.writes
        baseline.keyID = keyID
        if result.errors.isEmpty { baseline.lastPassAt = plan.now }
        baseline.save(to: baselineURL)
        return result
    }

    // MARK: Reset

    /// "Reset sync data": a new key, every record file removed; the next
    /// pass (with `fresh`) uploads this device's data.
    func resetFolder() throws {
        guard let root else { throw FolderSyncError.noFolder }
        try storage.ensureDirectory(root)
        let newID = try keys.makeKey()
        try storage.write(try FolderSyncCoding.data(FolderSyncFormat(keyID: newID)), to: root.appendingPathComponent("format.json"))
        totalWrites += 1
        var files = try storage.list(root).filter { $0.name == "settings.json" }
        for kind in SyncKind.allCases {
            guard let directory = kind.directory else { continue }
            files += try storage.list(root.appendingPathComponent(directory, isDirectory: true))
        }
        for file in files {
            try storage.remove(file.url)
            totalWrites += 1
        }
        cache = [:]
        generation += 1
        baseline = FolderSyncBaseline(folder: root.standardizedFileURL.path, keyID: newID)
        baseline.save(to: baselineURL)
    }
}
