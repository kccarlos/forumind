#if CLOUDKIT_ENABLED
import CloudKit
import Foundation
import os

// MARK: - CloudKit transport
//
// Only in builds with `CLOUDKIT_ENABLED` (scripts/generate_project.rb defines
// it when a development team is set): CloudKit terminates an app that lacks
// the iCloud entitlement, and unsigned builds have none.
//
// A `CKSyncEngine` on the private database, zone `Forumind`. One CKRecord per
// synced item, record type `SyncRecord`, record name from
// `SyncRecord.recordName` (a hash; the real id is inside the payload). Plain
// fields: `kind`, `formatVersion`, `deletedAt` (tombstones). The record's id,
// units and stamps are in `encryptedValues["payload"]` (end-to-end encrypted
// with the user's iCloud keys).
final class CloudKitTransport: CloudSyncTransport, @unchecked Sendable {
    static let zoneName = "Forumind"
    static let recordType = "SyncRecord"
    static let defaultContainerIdentifier = "iCloud.io.github.kccarlos.forumind"

    /// Info.plist `DCCloudKitContainer`, else the default container.
    static var containerIdentifier: String {
        if let value = Bundle.main.object(forInfoDictionaryKey: "DCCloudKitContainer") as? String,
           !value.isEmpty, !value.contains("$(") {
            return value
        }
        return defaultContainerIdentifier
    }

    weak var delegate: CloudSyncTransportDelegate?
    var onAccountChanged: (@MainActor () -> Void)?

    private let container: CKContainer
    private let zoneID: CKRecordZone.ID
    private let lock = NSLock()
    private var engine: CKSyncEngine?
    private var engineDelegate: EngineDelegate?
    /// A record-zone fetch error, reported with the end of the fetch.
    private var fetchFailure: CloudSendFailure?
    /// The failure the last finished fetch reported (see `fetchChanges`).
    private var lastFetchFailure: CloudSendFailure?
    private var accountObserver: NSObjectProtocol?
    private let logger = Logger(subsystem: AppIdentity.identifierPrefix, category: "CloudKit")

    init(containerIdentifier: String) {
        container = CKContainer(identifier: containerIdentifier)
        zoneID = CKRecordZone.ID(zoneName: Self.zoneName, ownerName: CKCurrentUserDefaultName)
        accountObserver = NotificationCenter.default.addObserver(
            forName: .CKAccountChanged, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.onAccountChanged?() }
        }
    }

    deinit {
        if let accountObserver { NotificationCenter.default.removeObserver(accountObserver) }
    }

    private var currentEngine: CKSyncEngine? { lock.withLock { engine } }

    var isRunning: Bool { currentEngine != nil }

    func accountStatus() async -> CloudAccountStatus {
        do {
            switch try await container.accountStatus() {
            case .available: return .available
            case .noAccount: return .noAccount
            case .restricted: return .restricted
            case .temporarilyUnavailable: return .temporarilyUnavailable
            case .couldNotDetermine: return .couldNotDetermine
            @unknown default: return .couldNotDetermine
            }
        } catch {
            logger.error("Account status failed: \(error.localizedDescription, privacy: .public)")
            return .couldNotDetermine
        }
    }

    func start(state: Data?) {
        let serialization = state.flatMap { try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: $0) }
        let delegate = EngineDelegate(transport: self)
        var configuration = CKSyncEngine.Configuration(
            database: container.privateCloudDatabase,
            stateSerialization: serialization,
            delegate: delegate
        )
        configuration.automaticallySync = true
        let engine = CKSyncEngine(configuration)
        lock.withLock {
            self.engine = engine
            engineDelegate = delegate
            fetchFailure = nil
        }
    }

    func stop() {
        let engine = lock.withLock { () -> CKSyncEngine? in
            let engine = self.engine
            self.engine = nil
            engineDelegate = nil
            return engine
        }
        if let engine {
            Task { await engine.cancelOperations() }
        }
    }

    private func recordID(_ name: String) -> CKRecord.ID {
        CKRecord.ID(recordName: name, zoneID: zoneID)
    }

    func queue(saves: [String], deletes: [String]) {
        guard let engine = currentEngine, !(saves.isEmpty && deletes.isEmpty) else { return }
        let pending = Set(engine.state.pendingRecordZoneChanges)
        var add: [CKSyncEngine.PendingRecordZoneChange] = []
        var remove: [CKSyncEngine.PendingRecordZoneChange] = []
        for name in saves {
            let id = recordID(name)
            if pending.contains(.deleteRecord(id)) { remove.append(.deleteRecord(id)) }
            if !pending.contains(.saveRecord(id)) { add.append(.saveRecord(id)) }
        }
        for name in deletes {
            let id = recordID(name)
            if pending.contains(.saveRecord(id)) { remove.append(.saveRecord(id)) }
            if !pending.contains(.deleteRecord(id)) { add.append(.deleteRecord(id)) }
        }
        if !remove.isEmpty { engine.state.remove(pendingRecordZoneChanges: remove) }
        if !add.isEmpty { engine.state.add(pendingRecordZoneChanges: add) }
    }

    func unqueue(_ names: [String]) {
        guard let engine = currentEngine, !names.isEmpty else { return }
        let changes = names.flatMap { name -> [CKSyncEngine.PendingRecordZoneChange] in
            let id = recordID(name)
            return [.saveRecord(id), .deleteRecord(id)]
        }
        engine.state.remove(pendingRecordZoneChanges: changes)
    }

    func queueZoneSave() {
        currentEngine?.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
    }

    func fetchChanges() async throws {
        guard let engine = currentEngine else { return }
        lock.withLock { lastFetchFailure = nil }
        do {
            try await engine.fetchChanges()
        } catch {
            throw CloudTransportError(failure: failure(for: error))
        }
        // A zone fetch can fail while the call as a whole succeeds.
        if let failure = lock.withLock({ lastFetchFailure }) {
            throw CloudTransportError(failure: failure)
        }
    }

    func sendChanges() async throws {
        guard let engine = currentEngine else { return }
        do {
            try await engine.sendChanges()
        } catch {
            throw CloudTransportError(failure: failure(for: error))
        }
    }

    func deleteZone() async throws {
        do {
            _ = try await container.privateCloudDatabase.deleteRecordZone(withID: zoneID)
        } catch {
            throw CloudTransportError(failure: failure(for: error))
        }
    }

    // MARK: Records

    private func makeRecord(_ cloud: CloudRecord) -> CKRecord {
        let id = recordID(cloud.recordName)
        var record: CKRecord?
        if let fields = cloud.systemFields, let coder = try? NSKeyedUnarchiver(forReadingFrom: fields) {
            coder.requiresSecureCoding = true
            record = CKRecord(coder: coder)
            coder.finishDecoding()
        }
        if record?.recordID != id { record = nil }
        let result = record ?? CKRecord(recordType: Self.recordType, recordID: id)
        result["kind"] = cloud.kind as NSString
        result["formatVersion"] = cloud.formatVersion as NSNumber
        result["deletedAt"] = cloud.deletedAt as NSDate?
        result.encryptedValues["payload"] = cloud.payload as NSData
        return result
    }

    private func cloudRecord(_ record: CKRecord) -> CloudRecord {
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: archiver)
        archiver.finishEncoding()
        // A record of another type, or without a payload, has empty
        // payload bytes: the engine counts it as unreadable.
        let payload = record.recordType == Self.recordType ? (record.encryptedValues["payload"] as? Data ?? Data()) : Data()
        return CloudRecord(
            recordName: record.recordID.recordName,
            kind: record["kind"] as? String ?? "",
            formatVersion: (record["formatVersion"] as? NSNumber)?.intValue ?? 0,
            deletedAt: record["deletedAt"] as? Date,
            payload: payload,
            systemFields: archiver.encodedData
        )
    }

    private func failure(for error: Error) -> CloudSendFailure {
        guard let error = error as? CKError else { return .other(error.localizedDescription) }
        switch error.code {
        case .serverRecordChanged:
            return .serverRecordChanged(error.serverRecord.map(cloudRecord))
        case .zoneNotFound, .userDeletedZone:
            return .zoneNotFound
        case .unknownItem:
            return .unknownItem
        case .quotaExceeded:
            return .quotaExceeded
        case .notAuthenticated:
            return .notAuthenticated
        case .networkFailure, .networkUnavailable, .serviceUnavailable, .requestRateLimited,
             .zoneBusy, .operationCancelled, .serverResponseLost:
            return .retryLater
        case .permissionFailure, .managedAccountRestricted:
            return .other(String(localized: "iCloud is restricted for this app."))
        default:
            return .other(error.localizedDescription)
        }
    }

    // MARK: Engine delegate

    fileprivate func handle(_ event: CKSyncEngine.Event, from syncEngine: CKSyncEngine) async {
        guard currentEngine === syncEngine, let delegate else { return }
        switch event {
        case .stateUpdate(let update):
            if let data = try? JSONEncoder().encode(update.stateSerialization) {
                await delegate.transport(handle: .stateUpdate(data))
            }
        case .accountChange(let change):
            let mapped: CloudAccountChange
            switch change.changeType {
            case .signIn(let user): mapped = .signIn(user: user.recordName)
            case .signOut: mapped = .signOut
            case .switchAccounts(_, let user): mapped = .switchAccounts(user: user.recordName)
            @unknown default: return
            }
            await delegate.transport(handle: .accountChange(mapped))
        case .fetchedDatabaseChanges(let changes):
            for deletion in changes.deletions where deletion.zoneID == zoneID {
                let reason: CloudZoneDeletionReason
                switch deletion.reason {
                case .deleted: reason = .deleted
                case .purged: reason = .purged
                case .encryptedDataReset: reason = .encryptedDataReset
                @unknown default: reason = .purged
                }
                await delegate.transport(handle: .zoneDeleted(reason))
            }
        case .fetchedRecordZoneChanges(let changes):
            let modified = changes.modifications
                .filter { $0.record.recordID.zoneID == zoneID }
                .map { cloudRecord($0.record) }
            let deleted = changes.deletions
                .filter { $0.recordID.zoneID == zoneID }
                .map(\.recordID.recordName)
            guard !modified.isEmpty || !deleted.isEmpty else { return }
            await delegate.transport(handle: .fetchedRecords(modified: modified, deleted: deleted))
        case .sentDatabaseChanges(let sent):
            if sent.savedZones.contains(where: { $0.zoneID == zoneID }) {
                await delegate.transport(handle: .sentZone(failure: nil))
            }
            for failed in sent.failedZoneSaves where failed.zone.zoneID == zoneID {
                await delegate.transport(handle: .sentZone(failure: failure(for: failed.error)))
            }
        case .sentRecordZoneChanges(let sent):
            var failed: [String: CloudSendFailure] = [:]
            for save in sent.failedRecordSaves where save.record.recordID.zoneID == zoneID {
                failed[save.record.recordID.recordName] = failure(for: save.error)
            }
            var failedDeletes: [String: CloudSendFailure] = [:]
            for (id, error) in sent.failedRecordDeletes where id.zoneID == zoneID {
                failedDeletes[id.recordName] = failure(for: error)
            }
            await delegate.transport(handle: .sentRecords(
                saved: sent.savedRecords.filter { $0.recordID.zoneID == zoneID }.map(cloudRecord),
                failed: failed,
                deleted: sent.deletedRecordIDs.filter { $0.zoneID == zoneID }.map(\.recordName),
                failedDeletes: failedDeletes
            ))
        case .willFetchChanges:
            lock.withLock { fetchFailure = nil }
            await delegate.transport(handle: .willFetch)
        case .didFetchRecordZoneChanges(let result):
            if result.zoneID == zoneID, let error = result.error {
                let failure = failure(for: error)
                // No zone yet (first device, before its first send): nothing to fetch.
                if failure != .zoneNotFound {
                    lock.withLock { fetchFailure = failure }
                }
            }
        case .didFetchChanges:
            let failure = lock.withLock { () -> CloudSendFailure? in
                let failure = fetchFailure
                fetchFailure = nil
                lastFetchFailure = failure
                return failure
            }
            await delegate.transport(handle: .didFetch(failure: failure))
        case .willSendChanges:
            await delegate.transport(handle: .willSend)
        case .didSendChanges:
            await delegate.transport(handle: .didSend)
        case .willFetchRecordZoneChanges:
            break
        @unknown default:
            break
        }
    }

    fileprivate func nextBatch(
        _ context: CKSyncEngine.SendChangesContext,
        from syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        guard currentEngine === syncEngine, let delegate else { return nil }
        var pending = syncEngine.state.pendingRecordZoneChanges.filter { context.options.scope.contains($0) }
        // Build records in slices (agent runs can be large); skip changes
        // with nothing left to send.
        while !pending.isEmpty {
            let slice = Array(pending.prefix(20))
            pending.removeFirst(slice.count)
            let names = slice.map { change -> String in
                switch change {
                case .saveRecord(let id), .deleteRecord(let id): id.recordName
                @unknown default: ""
                }
            }
            let outgoing = await delegate.transport(outgoingFor: names)
            var records: [CKRecord.ID: CKRecord] = [:]
            var stale: [CKSyncEngine.PendingRecordZoneChange] = []
            var changes: [CKSyncEngine.PendingRecordZoneChange] = []
            for change in slice {
                switch change {
                case .saveRecord(let id):
                    if let cloud = outgoing.saves[id.recordName] {
                        records[id] = makeRecord(cloud)
                        changes.append(change)
                    } else {
                        stale.append(change)
                    }
                case .deleteRecord(let id):
                    if outgoing.deletes.contains(id.recordName) {
                        changes.append(change)
                    } else {
                        stale.append(change)
                    }
                @unknown default:
                    stale.append(change)
                }
            }
            if !stale.isEmpty { syncEngine.state.remove(pendingRecordZoneChanges: stale) }
            guard !changes.isEmpty else { continue }
            let provided = records
            return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: changes) { provided[$0] }
        }
        return nil
    }

    // MARK: Debug probe

    #if DEBUG
    /// `-dc-cloudkit-probe`: account status and a save/fetch/delete round
    /// trip in a separate zone, printed to the console.
    static func probe(containerIdentifier: String) async {
        let container = CKContainer(identifier: containerIdentifier)
        print("[cloudkit-probe] container \(containerIdentifier)")
        do {
            let status = try await container.accountStatus()
            print("[cloudkit-probe] account status: \(status.rawValue) (1 = available)")
            guard status == .available else { return }
            let database = container.privateCloudDatabase
            let zoneID = CKRecordZone.ID(zoneName: "ForumindProbe", ownerName: CKCurrentUserDefaultName)
            let start = Date()
            _ = try await database.save(CKRecordZone(zoneID: zoneID))
            let record = CKRecord(recordType: recordType, recordID: CKRecord.ID(recordName: "probe", zoneID: zoneID))
            let token = UUID().uuidString
            record["kind"] = "probe" as NSString
            record["formatVersion"] = CloudRecord.formatVersion as NSNumber
            record.encryptedValues["payload"] = Data(token.utf8) as NSData
            _ = try await database.save(record)
            let fetched = try await database.record(for: record.recordID)
            let roundTrip = (fetched.encryptedValues["payload"] as? Data).map { String(decoding: $0, as: UTF8.self) }
            _ = try await database.deleteRecordZone(withID: zoneID)
            let elapsed = String(format: "%.2f", Date().timeIntervalSince(start))
            print("[cloudkit-probe] zone round trip \(roundTrip == token ? "OK" : "MISMATCH") in \(elapsed) s")
        } catch {
            print("[cloudkit-probe] failed: \(error)")
        }
    }
    #endif
}

/// Forwards `CKSyncEngine` callbacks to the transport (events from an engine
/// that was stopped are ignored).
private final class EngineDelegate: CKSyncEngineDelegate, @unchecked Sendable {
    private weak var transport: CloudKitTransport?

    init(transport: CloudKitTransport) {
        self.transport = transport
    }

    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        await transport?.handle(event, from: syncEngine)
    }

    func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        await transport?.nextBatch(context, from: syncEngine)
    }
}
#endif
