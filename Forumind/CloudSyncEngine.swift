import CryptoKit
import Foundation

// MARK: - Baseline

/// What this device last merged, per record: unit hashes and stamps (to tell
/// local edits from remote ones), the plaintext hash the server confirmed,
/// tombstones, and "pruned locally at remote hash X". Stored in Application
/// Support beside `state.json` (`cloudsync.json`).
struct SyncBaseline: Codable, Equatable {
    struct Unit: Codable, Equatable {
        var h: String
        var s: Date
    }

    struct Entry: Codable, Equatable {
        var units: [String: Unit]?
        var deletedAt: Date?
        /// Plaintext hash of the record as the server last confirmed it (nil:
        /// this version never reached the server).
        var remoteHash: String?
        /// Set when this device pruned the record (no tombstone): it is not
        /// imported again until the server's copy differs from this hash.
        var prunedRemoteHash: String?

        var latestStamp: Date {
            deletedAt ?? units?.values.map(\.s).max() ?? .distantPast
        }

        /// Same content (units and stamps, or tombstone) as `other`.
        func describesSameRecord(as other: Entry) -> Bool {
            units == other.units && deletedAt == other.deletedAt
        }
    }

    var records: [String: Entry] = [:]
    /// Last pass that merged with a complete mirror. A device whose last pass
    /// is older than the tombstone lifetime may have missed deletes whose
    /// tombstones are gone: it re-lists the zone first (see `plan`).
    var lastPassAt: Date?
    /// iCloud user this data was synced with (from the sign-in event).
    var accountID: String?
    /// The mirror holds everything the server had at the end of the last
    /// fetch. Nothing is planned (so nothing is sent) before that: a device
    /// joining must see the server's copies first.
    var mirrorComplete = false
    /// A full re-fetch is running (long absence): mirror records that do not
    /// show up in it are gone from the server.
    var relisting = false
    /// When the last re-listing finished (the pass after it may take missing
    /// records as deleted; no second re-listing before that pass).
    var relistedAt: Date?
    /// The zone was created (or found) since the last reset.
    var zoneSaved = false
    /// The next pass stamps this device's records as new so they win (after
    /// the zone was purged and this device re-uploads).
    var uploadsFresh = false

    static func load(from url: URL?) -> SyncBaseline {
        guard let url, let data = try? Data(contentsOf: url),
              let baseline = try? SyncCoding.makeDecoder().decode(SyncBaseline.self, from: data)
        else {
            return SyncBaseline()
        }
        return baseline
    }

    func save(to url: URL?) {
        guard let url else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if let data = try? SyncCoding.data(self) {
            try? data.write(to: url, options: .atomic)
        }
    }
}

// MARK: - Local state and changes

/// The synced part of the app's state, captured on the main actor.
struct SyncLocalState {
    var settings: AppSettings
    var sessions: [String: TopicSession]
    var runs: [AgentRun]
    var watched: [WatchedTopic]
    var forums: [Forum]
    /// Topics with work queued or running here: a remote delete of their
    /// session waits (like a local delete, which the app refuses meanwhile).
    var busyTopicKeys: Set<String> = []
    /// Records deleted on this device, with the time of the delete
    /// (`CloudSyncController`'s deletion log), by record key.
    var deletions: [String: Date] = [:]
}

/// One record to change locally. `expected` is the local value the merge was
/// computed from; if the record changed since, the change is skipped (the
/// next pass merges again), so a local edit is never clobbered.
struct SyncRecordChange<Value> {
    var id: String
    var expected: Value?
    /// nil deletes the record.
    var value: Value?
}

struct SyncSettingsChange {
    /// `settings.persistable` the merge was computed from.
    var expected: AppSettings
    var units: [String: JSONValue]
}

/// Merged remote data to apply locally (`AppModel.applyRemote(_:)`).
struct SyncChanges {
    var settings: SyncSettingsChange?
    var sessions: [SyncRecordChange<TopicSession>] = []
    var runs: [SyncRecordChange<AgentRun>] = []
    var watched: [SyncRecordChange<WatchedTopic>] = []
    var forums: [SyncRecordChange<Forum>] = []

    var isEmpty: Bool {
        settings == nil && sessions.isEmpty && runs.isEmpty && watched.isEmpty && forums.isEmpty
    }
}

// MARK: - Mirror

/// The server's copy of a record, as last fetched or confirmed by a save
/// (with its CloudKit metadata). Kept in `cloudsync-records/`, one file per
/// record, so a relaunch does not need to fetch everything again.
struct SyncMirrorEntry: Equatable {
    var record: SyncRecord
    /// Canonical plaintext (what hashes and comparisons use).
    var canonical: Data
    var systemFields: Data?
}

// MARK: - Engine

/// The merge core. A *pass* merges the app's state, the mirror (the server's
/// records) and the baseline, returns the local changes to apply on the main
/// actor, and then (`commit`) fills the outbox. The transport builds its
/// batches from the outbox (`outgoing(for:)`).
actor CloudSyncEngine {
    static let tombstoneLifetime: TimeInterval = 60 * 24 * 60 * 60
    private static let epoch = Date(timeIntervalSince1970: 0)

    struct RemoteRecord {
        var record: SyncRecord
        var canonical: Data
        var systemFields: Data?
    }

    /// The server's records as a plan sees them.
    struct Remote {
        var records: [String: RemoteRecord] = [:]
        /// Record names not to touch (their server copy is unreadable).
        var heldNames: Set<String> = []
        var generation = 0
    }

    struct Operation {
        var recordName: String
        /// Hash of the server's copy before this pass (nil: none); a queued
        /// write keeps it in the baseline until the server confirms the save.
        var previousRemoteHash: String?
        var write: SyncRecord?
        /// Delete the server record (tombstone past its lifetime).
        var remove = false
        /// Server metadata the write was merged against.
        var systemFields: Data?
        /// New baseline entry; nil removes it.
        var baseline: SyncBaseline.Entry?
    }

    struct Plan {
        var changes = SyncChanges()
        var operations: [String: Operation] = [:]
        var now = Date()
        var generation = 0
        /// Entries of `SyncLocalState.deletions` this plan used up.
        var handledDeletions: [String: Date] = [:]
    }

    struct CommitResult {
        var saves: [String] = []
        var deletes: [String] = []
        /// Names with nothing left to send.
        var cancelled: [String] = []
        /// The engine was reset since the plan was made: nothing committed.
        var stale = false
    }

    /// A record waiting to be sent: a save (with the metadata it was merged
    /// against) or a delete.
    struct Outgoing: Equatable {
        var record: SyncRecord?
        var systemFields: Data?
    }

    private struct LocalItem {
        var kind: SyncKind
        var id: String
        var units: [String: JSONValue]
        var recordTime: Date?
        /// When this device last touched the record (forums: last visit;
        /// watched: added). Only decides whether a copy that joins a zone
        /// holding a tombstone for it is newer than the delete.
        var touchedAt: Date?
        var held = false
    }

    private let baselineURL: URL?
    private let mirrorDirectory: URL?
    private(set) var baseline: SyncBaseline
    private(set) var mirror: [String: SyncMirrorEntry] = [:]
    /// Names whose server copy couldn't be decoded (newer format, corrupt).
    private(set) var unreadable: Set<String> = []
    private(set) var outbox: [String: Outgoing] = [:]
    /// Names fetched during a re-listing.
    private var seenDuringRelisting: Set<String> = []
    private(set) var generation = 0
    /// Records pruned since the last commit (a pass may have captured them
    /// before the prune; commit keeps their pruned mark).
    private var prunedDuringPass: Set<String> = []

    init(baselineURL: URL?, mirrorDirectory: URL?) {
        self.baselineURL = baselineURL
        self.mirrorDirectory = mirrorDirectory
        baseline = SyncBaseline.load(from: baselineURL)
        var mirror: [String: SyncMirrorEntry] = [:]
        if let mirrorDirectory,
           let names = try? FileManager.default.contentsOfDirectory(atPath: mirrorDirectory.path) {
            let decoder = PropertyListDecoder()
            for name in names where name.hasSuffix(".plist") {
                let url = mirrorDirectory.appendingPathComponent(name)
                guard let data = try? Data(contentsOf: url),
                      let stored = try? decoder.decode(CloudRecord.self, from: data),
                      let (record, canonical) = try? SyncPayload.decode(stored.payload)
                else {
                    continue
                }
                mirror[stored.recordName] = SyncMirrorEntry(record: record, canonical: canonical, systemFields: stored.systemFields)
            }
        }
        self.mirror = mirror
    }

    // MARK: State

    var isMirrorComplete: Bool { baseline.mirrorComplete }

    /// Forget everything about the server (sign-out, account switch, sync
    /// turned off, zone deleted). `fresh`: the next pass re-uploads this
    /// device's records as new.
    func reset(fresh: Bool = false, accountID: String? = nil) {
        generation += 1
        prunedDuringPass = []
        outbox = [:]
        unreadable = []
        seenDuringRelisting = []
        mirror = [:]
        if let mirrorDirectory { try? FileManager.default.removeItem(at: mirrorDirectory) }
        baseline = SyncBaseline(accountID: accountID, uploadsFresh: fresh)
        if let baselineURL {
            if fresh || accountID != nil {
                baseline.save(to: baselineURL)
            } else {
                try? FileManager.default.removeItem(at: baselineURL)
            }
        }
    }

    func setAccountID(_ id: String) {
        guard baseline.accountID != id else { return }
        baseline.accountID = id
        baseline.save(to: baselineURL)
    }

    func setZoneSaved(_ saved: Bool) {
        guard baseline.zoneSaved != saved else { return }
        baseline.zoneSaved = saved
        baseline.save(to: baselineURL)
    }

    /// The last pass is older than tombstones live: re-list the zone before
    /// merging (see `beginRelisting`).
    func needsRelisting(now: Date) -> Bool {
        guard baseline.mirrorComplete, !baseline.relisting, let last = baseline.lastPassAt else { return false }
        if let relisted = baseline.relistedAt, relisted >= last { return false }
        return now.timeIntervalSince(last) > Self.tombstoneLifetime - 24 * 60 * 60
    }

    /// Before a full re-fetch from scratch: records that are not fetched
    /// again were deleted on the server while this device was away.
    func beginRelisting() {
        generation += 1
        outbox = [:]
        seenDuringRelisting = []
        baseline.relisting = true
        baseline.mirrorComplete = false
        baseline.save(to: baselineURL)
    }

    /// A fetch finished: the mirror is complete.
    func finishFetch(now: Date) {
        if baseline.relisting {
            baseline.relistedAt = now
            for name in mirror.keys where !seenDuringRelisting.contains(name) {
                removeMirror(name)
            }
            seenDuringRelisting = []
            baseline.relisting = false
        }
        baseline.mirrorComplete = true
        baseline.save(to: baselineURL)
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

    // MARK: Mirror updates

    /// Records fetched from the server.
    func ingest(modified: [CloudRecord], deleted: [String]) {
        for name in deleted {
            removeMirror(name)
            unreadable.remove(name)
        }
        for cloud in modified {
            if baseline.relisting { seenDuringRelisting.insert(cloud.recordName) }
            store(cloud)
        }
        baseline.save(to: baselineURL)
    }

    /// Saves the server confirmed. Returns the names that still have
    /// something to send (edited again meanwhile).
    func didSave(_ saved: [CloudRecord]) -> [String] {
        var requeue: [String] = []
        for cloud in saved {
            let previousFields = mirror[cloud.recordName]?.systemFields
            guard let entry = store(cloud) else { continue }
            guard let outgoing = outbox[cloud.recordName] else { continue }
            if outgoing.record == entry.record {
                outbox.removeValue(forKey: cloud.recordName)
            } else {
                // Merged again after this save was built, against the same
                // server version: it now follows this save.
                if outgoing.systemFields == previousFields {
                    outbox[cloud.recordName]?.systemFields = cloud.systemFields
                }
                requeue.append(cloud.recordName)
            }
        }
        baseline.save(to: baselineURL)
        return requeue
    }

    func didDelete(_ names: [String]) {
        for name in names {
            removeMirror(name)
            if let outgoing = outbox[name], outgoing.record == nil {
                outbox.removeValue(forKey: name)
            }
        }
    }

    /// Someone else saved first: take the server's copy; the next pass merges
    /// it and queues the result.
    func conflict(name: String, server: CloudRecord?) {
        outbox.removeValue(forKey: name)
        if let server {
            store(server)
            baseline.save(to: baselineURL)
        } else {
            mirror[name]?.systemFields = nil
        }
    }

    /// The server doesn't have the record (or its zone): send it as new.
    /// Returns whether there is still something to send.
    func forgetServerCopy(name: String) -> Bool {
        removeMirror(name)
        guard let outgoing = outbox[name] else { return false }
        if outgoing.record == nil {
            // A delete of a record the server doesn't have: done.
            outbox.removeValue(forKey: name)
            return false
        }
        outbox[name]?.systemFields = nil
        return true
    }

    /// The transport's batch: the outbox records for these names.
    func outgoing(for names: [String]) -> CloudOutgoing {
        var result = CloudOutgoing()
        for name in names {
            guard let outgoing = outbox[name] else { continue }
            if let record = outgoing.record {
                if let cloud = try? CloudRecord(record, systemFields: outgoing.systemFields) {
                    result.saves[name] = cloud
                }
            } else {
                result.deletes.insert(name)
            }
        }
        return result
    }

    /// Everything in the outbox (queued again after the transport restarts).
    var outboxNames: (saves: [String], deletes: [String]) {
        var saves: [String] = [], deletes: [String] = []
        for (name, outgoing) in outbox {
            if outgoing.record == nil { deletes.append(name) } else { saves.append(name) }
        }
        return (saves.sorted(), deletes.sorted())
    }

    @discardableResult
    private func store(_ cloud: CloudRecord) -> SyncMirrorEntry? {
        guard let (record, canonical) = try? SyncPayload.decode(cloud.payload),
              record.recordName == cloud.recordName,
              record.kind.rawValue == cloud.kind
        else {
            // Unreadable, or bound to another name: leave it alone.
            removeMirror(cloud.recordName)
            unreadable.insert(cloud.recordName)
            return nil
        }
        unreadable.remove(cloud.recordName)
        let entry = SyncMirrorEntry(record: record, canonical: canonical, systemFields: cloud.systemFields)
        if mirror[cloud.recordName] != entry {
            mirror[cloud.recordName] = entry
            if let mirrorDirectory {
                try? FileManager.default.createDirectory(at: mirrorDirectory, withIntermediateDirectories: true)
                if let data = try? PropertyListEncoder().encode(cloud) {
                    try? data.write(to: mirrorDirectory.appendingPathComponent(cloud.recordName + ".plist"), options: .atomic)
                }
            }
        }
        confirm(record, canonical: canonical)
        return entry
    }

    /// The server holds `record`: a baseline entry describing the same
    /// record now counts as having reached the server.
    private func confirm(_ record: SyncRecord, canonical: Data) {
        let key = record.recordKey
        guard var entry = baseline.records[key],
              entry.describesSameRecord(as: baselineEntry(for: record, remoteHash: nil))
        else {
            return
        }
        let hash = SyncCoding.hash(canonical)
        guard entry.remoteHash != hash else { return }
        entry.remoteHash = hash
        if entry.prunedRemoteHash == "" { entry.prunedRemoteHash = hash }
        baseline.records[key] = entry
    }

    private func removeMirror(_ name: String) {
        guard mirror.removeValue(forKey: name) != nil else { return }
        if let mirrorDirectory {
            try? FileManager.default.removeItem(at: mirrorDirectory.appendingPathComponent(name + ".plist"))
        }
    }

    private func remote() -> Remote {
        var remote = Remote(generation: generation)
        for entry in mirror.values {
            remote.records[entry.record.recordKey] = RemoteRecord(
                record: entry.record, canonical: entry.canonical, systemFields: entry.systemFields
            )
        }
        remote.heldNames = unreadable
        return remote
    }

    // MARK: Plan

    private func localItems(_ local: SyncLocalState, now: Date) -> [String: LocalItem] {
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
        add(.settings, "settings", try? SyncSchema.settingsUnits(local.settings), time: nil)
        for (key, session) in local.sessions {
            add(
                .session, key, Self.units(session: session, now: now),
                time: session.updatedAt, touched: max(session.updatedAt, session.lastAccessedAt)
            )
        }
        for run in local.runs {
            // A run syncs once it has finished; until then it belongs to the
            // device running it (and remote copies do not touch it).
            add(.run, run.id.uuidString, SyncSchema.runUnits(run), time: run.updatedAt, held: !run.status.isTerminal)
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
        guard let object = (try? SyncCoding.json(value))?.objectValue else { return nil }
        return SyncSchema.units(kind: kind, object: object)
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
        try? SyncCoding.decode(type, from: .object(SyncSchema.object(kind: kind, units: units)))
    }

    /// Stamps for a local record: unchanged units keep the baseline stamp;
    /// changed ones get the record's own time (sessions, runs) or now, and
    /// always something newer than what they replace.
    private func stamped(
        _ item: LocalItem,
        entry: SyncBaseline.Entry?,
        remoteExists: Bool,
        now: Date,
        fresh: Bool
    ) -> SyncRecord {
        var stamps: [String: Date] = [:]
        for (unit, value) in item.units {
            let hash = SyncCoding.hash(value)
            if let known = entry?.units?[unit], known.h == hash {
                stamps[unit] = known.s
            } else if entry == nil || (entry?.units == nil && entry?.deletedAt == nil) {
                // Never synced from this device. A record the server does
                // not have yet is new; on joining a zone that already has
                // it, the server's values win (unless the record carries its
                // own modification time). After a purge this device wins.
                let time = fresh ? now : (item.recordTime ?? (remoteExists ? Self.epoch : now))
                stamps[unit] = SyncCoding.stamp(time)
            } else {
                let previous = entry?.units?[unit]?.s ?? entry?.deletedAt ?? Self.epoch
                let floor = previous.addingTimeInterval(1)
                stamps[unit] = SyncCoding.stamp(max(item.recordTime ?? now, floor))
            }
        }
        return SyncRecord(kind: item.kind, id: item.id, fields: item.units, stamps: stamps, deletedAt: nil)
    }

    private func baselineEntry(for record: SyncRecord, remoteHash: String?) -> SyncBaseline.Entry {
        if let deletedAt = record.deletedAt {
            return SyncBaseline.Entry(deletedAt: deletedAt, remoteHash: remoteHash)
        }
        var units: [String: SyncBaseline.Unit] = [:]
        for (unit, value) in record.fields ?? [:] {
            units[unit] = SyncBaseline.Unit(h: SyncCoding.hash(value), s: record.stamps?[unit] ?? Self.epoch)
        }
        return SyncBaseline.Entry(units: units, remoteHash: remoteHash)
    }

    /// Merges local state, the mirror, and the baseline.
    func plan(local: SyncLocalState, now: Date) -> Plan {
        plan(local: local, remote: remote(), now: now, fresh: baseline.uploadsFresh)
    }

    /// Merges local state, `remote`, and the baseline. `fresh` (after a zone
    /// purge) stamps this device's records as new so they win.
    func plan(local: SyncLocalState, remote: Remote, now: Date, fresh: Bool = false) -> Plan {
        let now = SyncCoding.stamp(now)
        let items = localItems(local, now: now)
        var plan = Plan(now: now, generation: remote.generation)
        var keys = Set(items.keys).union(remote.records.keys)
        for key in baseline.records.keys where !fresh { keys.insert(key) }
        for (key, date) in local.deletions {
            guard let (kind, id) = Self.parse(key),
                  !remote.heldNames.contains(SyncRecord.recordName(kind: kind, id: id))
            else { continue }
            plan.handledDeletions[key] = date
        }
        // Tombstones are removed after `tombstoneLifetime`. A device whose
        // last pass is older than that may have missed a delete entirely; it
        // re-lists the zone before this pass (`needsRelisting`), so a record
        // it synced, didn't change since, and that the server no longer has
        // was deleted elsewhere.
        let missedTombstones = !fresh
            && baseline.lastPassAt.map { now.timeIntervalSince($0) > Self.tombstoneLifetime - 24 * 60 * 60 } == true

        let sessionsByKey = local.sessions
        let runsByID = Dictionary(local.runs.map { ($0.id.uuidString, $0) }, uniquingKeysWith: { a, _ in a })
        let watchedByKey = Dictionary(local.watched.map { ($0.topicKey, $0) }, uniquingKeysWith: { a, _ in a })
        let forumsByURL = Dictionary(local.forums.map { ($0.siteURL, $0) }, uniquingKeysWith: { a, _ in a })

        for key in keys.sorted() {
            guard let (kind, id) = Self.parse(key) else { continue }
            let name = SyncRecord.recordName(kind: kind, id: id)
            if remote.heldNames.contains(name) { continue }
            let item = items[key]
            if item?.held == true { continue }
            let entry = fresh ? nil : baseline.records[key]
            let remoteRecord = remote.records[key]
            let remoteHash = remoteRecord.map { SyncCoding.hash($0.canonical) }

            // Synced before, unchanged here, gone from the server, and this
            // device has been away longer than tombstones live: deleted
            // elsewhere. (A recent device re-uploads instead: the tombstone
            // would still be there, so a missing record isn't a delete.)
            if let item, let entry, missedTombstones, remoteRecord == nil,
               entry.remoteHash != nil, entry.prunedRemoteHash == nil,
               let known = entry.units, Set(known.keys) == Set(item.units.keys),
               item.units.allSatisfy({ known[$0.key]?.h == SyncCoding.hash($0.value) }) {
                if kind == .session, local.busyTopicKeys.contains(id) { continue }
                appendDelete(kind: kind, id: id, to: &plan, local: local)
                plan.operations[key] = Operation(recordName: name, baseline: nil)
                continue
            }

            // This device's copy of the record.
            var mine: SyncRecord?
            if let item {
                mine = stamped(item, entry: entry, remoteExists: remoteRecord != nil, now: now, fresh: fresh)
                if entry == nil, !fresh, let deletedAt = remoteRecord?.record.deletedAt,
                   let touched = item.touchedAt, SyncCoding.stamp(touched) > deletedAt,
                   let fields = mine?.fields {
                    // Joining a zone that holds a tombstone for a record this
                    // device used after the delete: keep it (and bring it back).
                    let stamp = SyncCoding.stamp(touched)
                    mine?.stamps = fields.mapValues { _ in stamp }
                }
            } else if let entry, let prunedHash = entry.prunedRemoteHash {
                // Pruned here: stay out until the server's copy changes.
                if remoteRecord == nil || remoteHash == prunedHash { continue }
            } else if let deletedAt = local.deletions[key], entry != nil || remoteRecord != nil {
                // Deleted here, at a known time (never later than the delete
                // itself, e.g. when the app was killed before the next pass),
                // and after everything this device had seen of the record.
                let floor = entry.map { $0.latestStamp.addingTimeInterval(1) } ?? .distantPast
                mine = .tombstone(kind: kind, id: id, deletedAt: max(SyncCoding.stamp(deletedAt), floor))
            } else if let entry, let deletedAt = entry.deletedAt {
                mine = .tombstone(kind: kind, id: id, deletedAt: deletedAt)
            } else if let entry, entry.units != nil {
                // Deleted here since the last pass.
                let deletedAt = max(now, entry.latestStamp.addingTimeInterval(1))
                mine = .tombstone(kind: kind, id: id, deletedAt: deletedAt)
            }

            let copies = [mine, remoteRecord?.record].compactMap { $0 }
            guard let merged = SyncMerge.merge(copies) else { continue }
            var operation = Operation(
                recordName: name, previousRemoteHash: remoteHash, systemFields: remoteRecord?.systemFields
            )

            // Tombstones expire after 60 days: the server record is deleted.
            if let deletedAt = merged.deletedAt, now.timeIntervalSince(deletedAt) > Self.tombstoneLifetime {
                if item != nil { appendDelete(kind: kind, id: id, to: &plan, local: local) }
                operation.remove = remoteRecord != nil
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
                    if let current = try? SyncSchema.settingsUnits(local.settings),
                       let applied = try? SyncSchema.applying(settingsUnits: fields, to: local.settings),
                       let appliedUnits = try? SyncSchema.settingsUnits(applied),
                       appliedUnits != current {
                        plan.changes.settings = SyncSettingsChange(expected: local.settings, units: fields)
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
                       SyncSchema.runUnits(value) != item?.units {
                        plan.changes.runs.append(.init(id: id, expected: runsByID[id], value: value))
                    }
                case .watched:
                    if var value = decode(WatchedTopic.self, kind: kind, units: fields),
                       Self.units(.watched, value) != item?.units {
                        // Device-local, see SyncSchema.watchedExcluded.
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

            // Remote change. (The server's own record equal to the merge
            // means the same canonical bytes: skip encoding it again.)
            let unchangedRemote = remoteRecord.map { $0.record == merged } ?? false
            let mergedData = unchangedRemote ? remoteRecord!.canonical : ((try? merged.canonicalData()) ?? Data())
            if remoteRecord == nil || remoteRecord?.canonical != mergedData {
                operation.write = merged
            }
            let mergedHash = unchangedRemote ? remoteHash! : SyncCoding.hash(mergedData)
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

    private func appendDelete(kind: SyncKind, id: String, to plan: inout Plan, local: SyncLocalState) {
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

    /// Saves the baseline and fills the outbox from the plan (except records
    /// whose local apply was skipped). A queued write keeps the server's
    /// previous hash in the baseline until the save is confirmed, so a record
    /// that never reached the server is never taken as deleted elsewhere.
    func commit(_ plan: Plan, skipped: Set<String>) -> CommitResult {
        var result = CommitResult()
        guard plan.generation == generation else {
            result.stale = true
            return result
        }
        for (recordKey, operation) in plan.operations.sorted(by: { $0.key < $1.key })
        where !skipped.contains(recordKey) {
            let name = operation.recordName
            if let record = operation.write {
                let outgoing = Outgoing(record: record, systemFields: operation.systemFields)
                if outbox[name] != outgoing { outbox[name] = outgoing }
                result.saves.append(name)
            } else if operation.remove {
                outbox[name] = Outgoing(record: nil, systemFields: operation.systemFields)
                result.deletes.append(name)
            } else if outbox.removeValue(forKey: name) != nil {
                result.cancelled.append(name)
            }
            if var entry = operation.baseline {
                if operation.write != nil { entry.remoteHash = operation.previousRemoteHash }
                if prunedDuringPass.contains(recordKey), entry.units != nil {
                    entry.prunedRemoteHash = entry.remoteHash ?? ""
                }
                baseline.records[recordKey] = entry
            } else {
                baseline.records.removeValue(forKey: recordKey)
            }
        }
        prunedDuringPass = []
        baseline.lastPassAt = plan.now
        baseline.uploadsFresh = false
        baseline.save(to: baselineURL)
        return result
    }
}
