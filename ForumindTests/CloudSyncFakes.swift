import Foundation
@testable import Forumind

/// An in-memory CloudKit private database: per-account zones with records,
/// change tags, and a change log (for change tokens). Used from the main
/// actor only (the tests are `@MainActor`).
final class FakeCloudServer {
    final class Zone {
        var exists = false
        /// Bumped when the zone is deleted: a device holding a token from an
        /// earlier generation hears about the deletion on its next fetch.
        var generation = 0
        var deletionReason: CloudZoneDeletionReason = .deleted
        var records: [String: (record: CloudRecord, tag: Int)] = [:]
        var log: [(seq: Int, name: String)] = []
        var seq = 0

        func append(_ name: String) {
            seq += 1
            log.append((seq, name))
        }
    }

    private(set) var zones: [String: Zone] = [:]
    private var lastTag = 0
    /// Largest record payload accepted (CloudKit: 1 MB per record).
    var maxPayloadBytes = 1_000_000
    /// Every save fails with a server error (quota, outage…).
    var failsSaves = false
    /// Accepted saves and deletes, all devices.
    private(set) var writes = 0

    func zone(_ user: String) -> Zone {
        if let zone = zones[user] { return zone }
        let zone = Zone()
        zones[user] = zone
        return zone
    }

    func nextTag() -> Int {
        lastTag += 1
        return lastTag
    }

    func noteWrite() { writes += 1 }

    func records(_ user: String = "user-1") -> [String: CloudRecord] {
        zone(user).records.mapValues(\.record)
    }

    /// The zone and all its records are gone (another device's Delete iCloud
    /// Data, or the user deleting the app's data in Settings).
    func deleteZone(_ user: String = "user-1", reason: CloudZoneDeletionReason) {
        let zone = zone(user)
        zone.exists = false
        zone.records = [:]
        zone.log = []
        zone.seq = 0
        zone.generation += 1
        zone.deletionReason = reason
    }

    /// Deletes one record server side (as another device would).
    func removeRecord(_ name: String, user: String = "user-1") {
        let zone = zone(user)
        zone.records.removeValue(forKey: name)
        zone.append(name)
    }

    /// Stores a record as is (another app version, corrupt data…).
    func inject(_ record: CloudRecord, user: String = "user-1") {
        let zone = zone(user)
        zone.exists = true
        var stored = record
        let tag = nextTag()
        stored.systemFields = Data(String(tag).utf8)
        zone.records[record.recordName] = (stored, tag)
        zone.append(record.recordName)
    }
}

/// One device's `CKSyncEngine` stand-in: a change token and a pending list
/// (both in the serialized state), events delivered one at a time, the same
/// conflict rules as CloudKit (a save must carry the server's current change
/// tag; a save with a tag for a record that is gone is `unknownItem`), and no
/// push: a device only learns about changes when it fetches.
final class FakeCloudTransport: CloudSyncTransport {
    struct State: Codable {
        var user: String?
        var generation: Int?
        var seq = 0
        var saves: [String] = []
        var deletes: [String] = []
        var zonePending = false
    }

    weak var delegate: CloudSyncTransportDelegate?
    var onAccountChanged: (@MainActor () -> Void)?
    let server: FakeCloudServer
    /// Signed-in iCloud user (nil: signed out).
    var user: String?
    var statusOverride: CloudAccountStatus?
    /// Fetches fail (offline): like CKSyncEngine, the fetch is still
    /// bracketed by will/did events without an error; only the call throws.
    var failsFetches = false
    private(set) var isRunning = false
    private(set) var state = State()
    /// Bumped by start/stop: a fetch or send from before stops delivering.
    private var run = 0
    private(set) var saved = 0
    private(set) var conflicts = 0
    private(set) var fetches = 0

    init(server: FakeCloudServer, user: String? = "user-1") {
        self.server = server
        self.user = user
    }

    func accountStatus() async -> CloudAccountStatus {
        statusOverride ?? (user == nil ? .noAccount : .available)
    }

    func start(state data: Data?) {
        state = data.flatMap { try? JSONDecoder().decode(State.self, from: $0) } ?? State()
        isRunning = true
        run += 1
    }

    func stop() {
        isRunning = false
        state = State()
        run += 1
    }

    func queue(saves: [String], deletes: [String]) {
        for name in saves {
            state.deletes.removeAll { $0 == name }
            if !state.saves.contains(name) { state.saves.append(name) }
        }
        for name in deletes {
            state.saves.removeAll { $0 == name }
            if !state.deletes.contains(name) { state.deletes.append(name) }
        }
    }

    func unqueue(_ names: [String]) {
        let names = Set(names)
        state.saves.removeAll { names.contains($0) }
        state.deletes.removeAll { names.contains($0) }
    }

    func queueZoneSave() {
        state.zonePending = true
    }

    var pendingCount: Int { state.saves.count + state.deletes.count }

    /// Delivers an event; false when the transport restarted meanwhile.
    @discardableResult
    private func emit(_ event: CloudSyncEvent, run: Int) async -> Bool {
        guard run == self.run, isRunning else { return false }
        await delegate?.transport(handle: event)
        return run == self.run && isRunning
    }

    private func emitState(run: Int) async {
        guard let data = try? JSONEncoder().encode(state) else { return }
        await emit(.stateUpdate(data), run: run)
    }

    func fetchChanges() async throws {
        guard isRunning else { return }
        guard let user else { throw CloudTransportError(failure: .notAuthenticated) }
        fetches += 1
        let run = run
        guard await emit(.willFetch, run: run) else { return }
        if failsFetches {
            await emit(.didFetch(failure: nil), run: run)
            throw CloudTransportError(failure: .retryLater)
        }
        if let previous = state.user, previous != user {
            state.user = user
            guard await emit(.accountChange(.switchAccounts(user: user)), run: run) else { return }
        } else if state.user == nil {
            state.user = user
            guard await emit(.accountChange(.signIn(user: user)), run: run) else { return }
        }
        let zone = server.zone(user)
        if let generation = state.generation, generation != zone.generation {
            state.seq = 0
            state.generation = zone.generation
            guard await emit(.zoneDeleted(zone.deletionReason), run: run) else { return }
        }
        state.generation = zone.generation
        let names = Set(zone.log.filter { $0.seq > state.seq }.map(\.name))
        let modified = names.sorted().compactMap { name -> CloudRecord? in
            guard let stored = zone.records[name] else { return nil }
            var record = stored.record
            record.systemFields = Data(String(stored.tag).utf8)
            return record
        }
        let deleted = names.sorted().filter { zone.records[$0] == nil }
        if !modified.isEmpty || !deleted.isEmpty {
            guard await emit(.fetchedRecords(modified: modified, deleted: deleted), run: run) else { return }
        }
        state.seq = zone.seq
        await emitState(run: run)
        await emit(.didFetch(failure: nil), run: run)
    }

    func sendChanges() async throws {
        guard isRunning else { return }
        guard let user else { throw CloudTransportError(failure: .notAuthenticated) }
        let run = run
        let zone = server.zone(user)
        guard await emit(.willSend, run: run) else { return }
        if state.zonePending {
            state.zonePending = false
            zone.exists = true
            guard await emit(.sentZone(failure: nil), run: run) else { return }
        }
        var rounds = 0
        while pendingCount > 0, rounds < 5 {
            rounds += 1
            let saves = state.saves, deletes = state.deletes
            let outgoing = await delegate?.transport(outgoingFor: saves + deletes) ?? CloudOutgoing()
            guard run == self.run, isRunning else { return }
            state.saves.removeAll { saves.contains($0) }
            state.deletes.removeAll { deletes.contains($0) }
            var savedRecords: [CloudRecord] = []
            var failed: [String: CloudSendFailure] = [:]
            var deleted: [String] = []
            var failedDeletes: [String: CloudSendFailure] = [:]
            for name in saves {
                guard let record = outgoing.saves[name] else { continue }
                guard zone.exists else { failed[name] = .zoneNotFound; continue }
                guard !server.failsSaves else { failed[name] = .other("The server is unavailable."); continue }
                guard record.payload.count <= server.maxPayloadBytes else { failed[name] = .other("Record too large."); continue }
                let sentTag = record.systemFields.flatMap { Int(String(decoding: $0, as: UTF8.self)) }
                if let existing = zone.records[name] {
                    guard sentTag == existing.tag else {
                        var current = existing.record
                        current.systemFields = Data(String(existing.tag).utf8)
                        failed[name] = .serverRecordChanged(current)
                        conflicts += 1
                        continue
                    }
                } else if sentTag != nil {
                    failed[name] = .unknownItem
                    continue
                }
                let tag = server.nextTag()
                var stored = record
                stored.systemFields = Data(String(tag).utf8)
                zone.records[name] = (stored, tag)
                zone.append(name)
                server.noteWrite()
                saved += 1
                savedRecords.append(stored)
            }
            for name in deletes where outgoing.deletes.contains(name) {
                guard zone.exists else { failedDeletes[name] = .zoneNotFound; continue }
                zone.records.removeValue(forKey: name)
                zone.append(name)
                server.noteWrite()
                deleted.append(name)
            }
            if !savedRecords.isEmpty || !failed.isEmpty || !deleted.isEmpty || !failedDeletes.isEmpty {
                guard await emit(
                    .sentRecords(saved: savedRecords, failed: failed, deleted: deleted, failedDeletes: failedDeletes),
                    run: run
                ) else { return }
            }
            if !failed.isEmpty, failed.values.allSatisfy({ if case .other = $0 { true } else { false } }) { break }
        }
        await emitState(run: run)
        await emit(.didSend, run: run)
    }

    func deleteZone() async throws {
        guard let user else { throw CloudTransportError(failure: .notAuthenticated) }
        guard server.zone(user).exists else { throw CloudTransportError(failure: .zoneNotFound) }
        server.deleteZone(user, reason: .deleted)
    }

    // MARK: Account events (what CKSyncEngine reports while running)

    func signOut() async {
        user = nil
        await emit(.accountChange(.signOut), run: run)
    }

    func switchAccount(to user: String) async {
        self.user = user
        state.user = user
        await emit(.accountChange(.switchAccounts(user: user)), run: run)
    }
}
