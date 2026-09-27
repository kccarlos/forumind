import Foundation

// MARK: - Transport
//
// `CloudSyncController` talks to CloudKit only through `CloudSyncTransport`,
// in CloudKit-free types, so the controller, the merge core and the tests
// build and run without the iCloud entitlement. The real transport
// (`CloudKitTransport`, a `CKSyncEngine` wrapper) exists only in builds with
// `CLOUDKIT_ENABLED` (a development team is set); the unit tests use an
// in-memory fake server.
//
// The transport mirrors `CKSyncEngine`: it owns the change token and the list
// of pending record saves/deletes (both part of the serialized state it hands
// back through `.stateUpdate`), asks its delegate for the records to send
// when it builds a batch, and reports everything that happens as events.

/// One record as stored in the private database (zone `Forumind`).
struct CloudRecord: Codable, Equatable, Sendable {
    var recordName: String
    /// Plain fields (not encrypted): `SyncKind` raw value, payload format, and
    /// the delete time of a tombstone.
    var kind: String
    var formatVersion: Int
    var deletedAt: Date?
    /// `encryptedValues["payload"]`: `SyncPayload` bytes (the record's id,
    /// units and stamps).
    var payload: Data
    /// Server metadata (CloudKit: `encodeSystemFields`, which carries the
    /// change tag). A save with stale metadata fails with
    /// `.serverRecordChanged`; one without metadata creates the record.
    var systemFields: Data?

    static let formatVersion = 1

    init(recordName: String, kind: String, formatVersion: Int = Self.formatVersion, deletedAt: Date?, payload: Data, systemFields: Data?) {
        self.recordName = recordName
        self.kind = kind
        self.formatVersion = formatVersion
        self.deletedAt = deletedAt
        self.payload = payload
        self.systemFields = systemFields
    }

    init(_ record: SyncRecord, systemFields: Data?) throws {
        self.init(
            recordName: record.recordName,
            kind: record.kind.rawValue,
            deletedAt: record.deletedAt,
            payload: try SyncPayload.encode(record),
            systemFields: systemFields
        )
    }
}

enum CloudAccountStatus: Equatable, Sendable {
    case available
    case noAccount
    case restricted
    case temporarilyUnavailable
    case couldNotDetermine
}

enum CloudAccountChange: Equatable, Sendable {
    case signIn(user: String)
    case signOut
    case switchAccounts(user: String)
}

enum CloudZoneDeletionReason: Equatable, Sendable {
    /// Deleted by the app (Delete iCloud Data on another device).
    case deleted
    /// The user deleted the app's data in iCloud settings.
    case purged
    /// The user reset Advanced Data Protection keys: encrypted fields are gone.
    case encryptedDataReset
}

/// Why a record save or delete failed.
enum CloudSendFailure: Equatable, Sendable {
    /// Someone saved the record first; carries the server's copy.
    case serverRecordChanged(CloudRecord?)
    case zoneNotFound
    /// The record's metadata refers to a record the server no longer has.
    case unknownItem
    case quotaExceeded
    case notAuthenticated
    /// Network, throttling, server busy: the transport retries by itself.
    case retryLater
    case other(String)
}

enum CloudSyncEvent: Sendable {
    /// Serialized transport state (change token, pending changes) to persist.
    case stateUpdate(Data)
    case accountChange(CloudAccountChange)
    case zoneDeleted(CloudZoneDeletionReason)
    case fetchedRecords(modified: [CloudRecord], deleted: [String])
    case sentRecords(saved: [CloudRecord], failed: [String: CloudSendFailure], deleted: [String], failedDeletes: [String: CloudSendFailure])
    case sentZone(failure: CloudSendFailure?)
    case willFetch
    case didFetch(failure: CloudSendFailure?)
    case willSend
    case didSend
}

/// What the transport sends for a batch of pending record names.
struct CloudOutgoing: Sendable {
    var saves: [String: CloudRecord] = [:]
    var deletes: Set<String> = []
}

protocol CloudSyncTransportDelegate: AnyObject, Sendable {
    /// Called for every event, one at a time (the transport waits).
    func transport(handle event: CloudSyncEvent) async
    /// The records to send for these pending names. A name the delegate
    /// doesn't return has nothing left to send; the transport drops it.
    func transport(outgoingFor names: [String]) async -> CloudOutgoing
}

protocol CloudSyncTransport: AnyObject {
    var delegate: CloudSyncTransportDelegate? { get set }
    /// Called when the device's iCloud account may have changed
    /// (`CKAccountChanged`); the controller re-checks `accountStatus()`.
    var onAccountChanged: (@MainActor () -> Void)? { get set }
    var isRunning: Bool { get }

    func accountStatus() async -> CloudAccountStatus
    /// Starts syncing from a state from `.stateUpdate` (nil: from scratch).
    func start(state: Data?)
    /// Stops syncing: cancels operations and drops the pending list.
    func stop()
    /// Queues record saves / deletes (duplicates are ignored).
    func queue(saves: [String], deletes: [String])
    /// Drops pending changes for these names.
    func unqueue(_ names: [String])
    /// Queues creating the zone (idempotent on the server).
    func queueZoneSave()
    func fetchChanges() async throws
    func sendChanges() async throws
    /// Deletes the zone and everything in it, for every device.
    func deleteZone() async throws
}

/// What `fetchChanges()`, `sendChanges()` and `deleteZone()` throw.
struct CloudTransportError: LocalizedError, Equatable {
    var failure: CloudSendFailure

    var errorDescription: String? { failure.message }
}

extension CloudSendFailure {
    /// A short message for Settings.
    var message: String {
        switch self {
        case .serverRecordChanged: "Another device changed the same item; merging."
        case .zoneNotFound, .unknownItem: "The iCloud copy changed; uploading again."
        case .quotaExceeded: "Your iCloud storage is full."
        case .notAuthenticated: "Sign in to iCloud to sync."
        case .retryLater: "iCloud is busy or offline; syncing will retry."
        case .other(let message): message
        }
    }
}
