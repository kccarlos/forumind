import Foundation
import os
import SwiftUI
import UIKit

// MARK: - CloudSyncController API (for the UI)
//
// `app.cloudSync` (constructed in `AppModel.init`) syncs forums, summaries,
// chats, agent runs, watched topics and settings through the user's private
// CloudKit database (container from Info.plist `DCCloudKitContainer`, zone
// `Forumind`). It is on by default whenever an iCloud account is available.
// API keys sync separately through iCloud Keychain (Persistence.swift).
//
//     @MainActor final class CloudSyncController: ObservableObject {
//         enum Status: Equatable {
//             case off                  // user turned sync off on this device
//             case noAccount            // not signed into iCloud
//             case restricted           // iCloud restricted (parental controls, MDM),
//                                       // or iCloud turned off for the app
//             case unavailable(String)  // unsigned build, temporarily unavailable, …
//             case syncing
//             case upToDate
//             case error(String)
//         }
//         @Published private(set) var status: Status
//         @Published private(set) var lastSyncedAt: Date?
//         @Published private(set) var isEnabled: Bool   // device-local (UserDefaults), default true
//         func setEnabled(_ enabled: Bool)  // off: stop, keep local data; on: start (joins/merges)
//         func syncNow()                    // fetch, then send
//         func deleteCloudData() async throws
//             // deletes the zone: the iCloud copy is gone for every device (local
//             // data stays everywhere; other devices that sync stop syncing too),
//             // then turns sync off on this device
//     }
//
// How it works: `CloudSyncTransport` (CKSyncEngine in `CloudKitTransport`,
// only in builds with `CLOUDKIT_ENABLED`) fetches and sends records. Fetched
// records land in the engine's mirror; after every fetch, and ~2 s after a
// local save, a *pass* merges app state, mirror and baseline
// (`CloudSyncEngine`), applies remote changes (`AppModel.applyRemote`) and
// queues the records whose merged content differs from the server's copy.
// The transport then builds CloudKit records from that outbox. See
// docs/SYNC.md for the record model and merge rules.
//
// Local deletes are noticed at save time (records gone since the last save,
// minus pruned ones and remote deletes being applied) and logged with their
// real time in `cloudsync-deletions.json` until a pass has turned them into
// tombstones. Turning sync off (or signing out) clears the log.
//
// Without `CLOUDKIT_ENABLED` (unsigned builds, CI, unit tests) there is no
// transport and `status` is `.unavailable("Sync needs a signed build")`.
// DEBUG: `-dc-cloudkit-probe` prints the account status and a zone round trip
// (CloudKit builds only). Sync stays off under `-dc-sample` and `-ui-test-*`
// so sample data never reaches iCloud.
@MainActor
final class CloudSyncController: ObservableObject, CloudSyncTransportDelegate {
    enum Status: Equatable {
        case off
        case noAccount
        case restricted
        case unavailable(String)
        case syncing
        case upToDate
        case error(String)
    }

    @Published private(set) var status: Status = .off
    @Published private(set) var lastSyncedAt: Date?
    @Published private(set) var isEnabled: Bool

    static let enabledKey = "cloudSync.enabled"
    static let lastSyncedKey = "cloudSync.lastSyncedAt"
    nonisolated static let unsignedBuildReason = "Sync needs a signed build"

    let engine: CloudSyncEngine
    let transport: CloudSyncTransport?
    private let unavailableReason: String
    private let files: CloudSyncFiles?
    private let defaults: UserDefaults?
    private weak var model: AppModel?
    private let logger = Logger(subsystem: AppIdentity.identifierPrefix, category: "CloudSync")

    private var accountStatus: CloudAccountStatus?
    private var isFetching = false
    private var isSending = false
    /// Last fetch/send failure (cleared by the next clean send).
    private var lastError: String?
    /// Records that couldn't be read (newer app version, corrupt).
    private var unreadableMessage: String?
    /// The mirror is complete (a fetch finished since the last reset).
    private var hasCompletedFetch = false
    /// Bumped whenever the transport starts or stops: a fetch that spans a
    /// restart doesn't complete the mirror.
    private var transportStarts = 0
    /// A pass ran since the transport started (the outbox is current).
    private var hasPassedSinceStart = false
    private var startTask: Task<Void, Never>?
    private var resetTask: Task<Void, Never>?
    private var passTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?
    private var isApplying = false
    /// Bumped whenever syncing stops or starts over: a pass that began before
    /// neither applies nor commits.
    private var activation = 0
    /// Record keys ("kind/id") the app held at the last save, to notice deletes.
    private var knownRecordKeys: Set<String> = []
    /// Local deletes with the time they happened, until a pass has turned
    /// them into tombstones (persisted: a delete made just before the app is
    /// killed keeps its real time).
    private(set) var deletionLog: [String: Date] = [:]

    /// Debounced passes and foreground/background work (off in unit tests,
    /// which call `performSync()` directly).
    var schedulesAutomatically: Bool
    var debounceDelay: Duration = .seconds(2)
    var clock: () -> Date = Date.init
    /// Records the last pass queued to send (tests).
    private(set) var lastPassQueued = 0
    private(set) var passCount = 0

    init(
        transport: CloudSyncTransport?,
        unavailableReason: String = CloudSyncController.unsignedBuildReason,
        files: CloudSyncFiles?,
        defaults: UserDefaults?,
        schedulesAutomatically: Bool = true
    ) {
        self.transport = transport
        self.unavailableReason = unavailableReason
        self.files = files
        self.defaults = defaults
        self.schedulesAutomatically = schedulesAutomatically
        engine = CloudSyncEngine(baselineURL: files?.baseline, mirrorDirectory: files?.mirror)
        isEnabled = defaults?.object(forKey: Self.enabledKey) as? Bool ?? true
        lastSyncedAt = defaults?.object(forKey: Self.lastSyncedKey) as? Date
        if let url = files?.deletions, let data = try? Data(contentsOf: url),
           let log = try? SyncCoding.makeDecoder().decode([String: Date].self, from: data) {
            deletionLog = log
        }
        transport?.delegate = self
        transport?.onAccountChanged = { [weak self] in
            guard let self, self.isEnabled else { return }
            self.startTask = Task { await self.start() }
        }
        refreshStatus()
    }

    /// The app's controller for a store: CloudKit for the app's own store in
    /// a CloudKit build; an inert one otherwise (tests inject their own).
    static func makeDefault(for store: PersistentStore) -> CloudSyncController {
        let files = CloudSyncFiles(store: store)
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if AssistantDebug.isActive || arguments.contains(where: { $0.hasPrefix("-ui-test-") }) {
            return CloudSyncController(
                transport: nil, unavailableReason: "Sync is off for sample data",
                files: nil, defaults: nil, schedulesAutomatically: false
            )
        }
        #endif
        guard store.usesDefaultLocation, !isRunningTests else {
            return CloudSyncController(transport: nil, files: nil, defaults: nil, schedulesAutomatically: false)
        }
        #if CLOUDKIT_ENABLED
        let transport = CloudKitTransport(containerIdentifier: CloudKitTransport.containerIdentifier)
        #if DEBUG
        if arguments.contains("-dc-cloudkit-probe") {
            Task { await CloudKitTransport.probe(containerIdentifier: CloudKitTransport.containerIdentifier) }
        }
        #endif
        return CloudSyncController(transport: transport, files: files, defaults: .standard)
        #else
        return CloudSyncController(transport: nil, files: files, defaults: .standard)
        #endif
    }

    private static var isRunningTests: Bool {
        NSClassFromString("XCTestCase") != nil
    }

    /// Called at the end of `AppModel.init`; starts syncing when enabled.
    func attach(_ model: AppModel) {
        self.model = model
        knownRecordKeys = model.syncRecordKeys()
        guard isEnabled, transport != nil else { return }
        startTask = Task { await start() }
    }

    // MARK: Public actions

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        defaults?.set(enabled, forKey: Self.enabledKey)
        if enabled {
            startTask = Task { await start() }
        } else {
            stopAndForget()
        }
        refreshStatus()
    }

    /// Sync off on this device (also when already off: forgets server state).
    private func disable() {
        isEnabled = false
        defaults?.set(false, forKey: Self.enabledKey)
        stopAndForget()
    }

    func syncNow() {
        guard isEnabled, transport != nil else { return }
        status = .syncing
        Task { await performSync() }
    }

    func deleteCloudData() async throws {
        guard let transport else { throw CloudTransportError(failure: .other(unavailableReason)) }
        do {
            try await transport.deleteZone()
        } catch let error as CloudTransportError where error.failure == .zoneNotFound {
            // Nothing in iCloud: done.
        }
        disable()
    }

    // MARK: Start and stop

    /// Checks the account and starts the transport (from its saved state).
    func start() async {
        await resetTask?.value
        guard isEnabled, let transport else {
            refreshStatus()
            return
        }
        let account = await transport.accountStatus()
        guard isEnabled else { return }
        accountStatus = account
        guard account == .available else {
            if transport.isRunning, account == .noAccount || account == .restricted {
                // The account went away without a sign-out event. (A status
                // that is only temporarily unknown keeps the sync state.)
                stopAndForget()
            }
            refreshStatus()
            return
        }
        if !transport.isRunning {
            activation += 1
            hasPassedSinceStart = false
            lastError = nil
            transportStarts += 1
            transport.start(state: readState())
            if !(await engine.baseline.zoneSaved) { transport.queueZoneSave() }
            hasCompletedFetch = await engine.isMirrorComplete
        }
        refreshStatus()
        if schedulesAutomatically {
            Task { await performSync() }
        }
    }

    /// Stops the transport and forgets the server state (baseline, mirror,
    /// transport state, deletion log). Local data stays.
    private func stopAndForget() {
        activation += 1
        debounceTask?.cancel()
        debounceTask = nil
        transportStarts += 1
        transport?.stop()
        removeState()
        updateDeletionLog { $0 = [:] }
        hasCompletedFetch = false
        hasPassedSinceStart = false
        isFetching = false
        isSending = false
        lastError = nil
        unreadableMessage = nil
        let engine = engine
        let previous = resetTask
        resetTask = Task { await previous?.value; await engine.reset() }
        refreshStatus()
    }

    /// Another iCloud account: forget the old one's server state and join
    /// the new account's zone with this device's data.
    private func restartForAccount(_ user: String) async {
        activation += 1
        transport?.stop()
        removeState()
        updateDeletionLog { $0 = [:] }
        hasCompletedFetch = false
        hasPassedSinceStart = false
        await engine.reset(accountID: user)
        transportStarts += 1
        transport?.start(state: nil)
        transport?.queueZoneSave()
        refreshStatus()
        if schedulesAutomatically {
            Task { await fetchAndComplete() }
        }
    }

    // MARK: Status

    private func refreshStatus() {
        status = computeStatus()
    }

    private func computeStatus() -> Status {
        guard isEnabled else { return .off }
        guard transport != nil else { return .unavailable(unavailableReason) }
        switch accountStatus {
        case .noAccount: return .noAccount
        case .restricted: return .restricted
        case .temporarilyUnavailable: return .unavailable("iCloud is temporarily unavailable.")
        case .couldNotDetermine: return .unavailable("Couldn’t check your iCloud account.")
        case nil, .available: break
        }
        if let message = lastError ?? unreadableMessage { return .error(message) }
        if accountStatus == nil || isFetching || isSending || !hasCompletedFetch { return .syncing }
        return .upToDate
    }

    private func noteError(_ error: Error) {
        let failure = (error as? CloudTransportError)?.failure ?? .other(error.localizedDescription)
        noteFailure(failure)
    }

    private func noteFailure(_ failure: CloudSendFailure) {
        switch failure {
        case .notAuthenticated:
            accountStatus = .noAccount
        case .retryLater, .serverRecordChanged, .zoneNotFound, .unknownItem:
            break
        case .quotaExceeded, .other:
            lastError = failure.message
            logger.error("Sync failed: \(failure.message, privacy: .public)")
        }
        refreshStatus()
    }

    private func markSynced() {
        let now = clock()
        lastSyncedAt = now
        defaults?.set(now, forKey: Self.lastSyncedKey)
    }

    // MARK: Scheduling

    /// `AppModel.save()` calls this after every local save.
    func localDataDidChange() {
        guard !isApplying else { return }
        noteLocalDeletions()
        guard isEnabled, transport?.isRunning == true, schedulesAutomatically else { return }
        debounceTask?.cancel()
        debounceTask = Task { [weak self, debounceDelay] in
            try? await Task.sleep(for: debounceDelay)
            guard !Task.isCancelled else { return }
            await self?.performPass()
        }
    }

    /// Logs records that left the app since the last save (not pruned ones,
    /// not remote deletes being applied) with the time of the delete.
    private func noteLocalDeletions() {
        guard let model else { return }
        let current = model.syncRecordKeys()
        let removed = knownRecordKeys.subtracting(current)
        knownRecordKeys = current
        guard !removed.isEmpty, isEnabled, transport?.isRunning == true else { return }
        let now = clock()
        updateDeletionLog { log in
            for key in removed { log[key] = now }
        }
    }

    private func updateDeletionLog(_ change: (inout [String: Date]) -> Void) {
        let before = deletionLog
        change(&deletionLog)
        guard deletionLog != before, let url = files?.deletions else { return }
        if deletionLog.isEmpty {
            try? FileManager.default.removeItem(at: url)
        } else if let data = try? SyncCoding.data(deletionLog) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }

    /// `AppModel.pruneSessions()` and the agent-run cap call this: the
    /// records left this device without being deleted (no tombstone).
    func notePruned(kind: SyncKind, ids: [String]) {
        guard !ids.isEmpty else { return }
        let keys = ids.map { SyncRecord.recordKey(kind: kind, id: $0) }
        knownRecordKeys.subtract(keys)
        updateDeletionLog { log in
            for key in keys { log.removeValue(forKey: key) }
        }
        let engine = engine
        Task { await engine.notePruned(kind: kind, ids: ids) }
    }

    func handleScenePhase(_ phase: ScenePhase) {
        guard isEnabled, let transport, schedulesAutomatically else { return }
        switch phase {
        case .active:
            Task {
                if !transport.isRunning { await start() }
                guard transport.isRunning else { return }
                await fetchAndComplete()
            }
        case .background:
            debounceTask?.cancel()
            debounceTask = nil
            guard transport.isRunning else { return }
            // Send what changed before the app is suspended.
            let backgroundTask = BackgroundTaskHandle()
            backgroundTask.begin()
            Task {
                await performPass()
                try? await transport.sendChanges()
                backgroundTask.end()
            }
        default:
            break
        }
    }

    // MARK: Sync

    /// Fetch, merge, send (Sync now; tests).
    func performSync() async {
        await startTask?.value
        guard isEnabled, let transport else { return }
        if !transport.isRunning { await start() }
        guard transport.isRunning else { return }
        await fetchAndComplete()
        await performPass()
        guard transport.isRunning else { return }
        do {
            try await transport.sendChanges()
        } catch {
            noteError(error)
        }
    }

    /// Fetches. When the mirror isn't complete yet (joining, re-listing, after
    /// a purge) and the fetch succeeded, it is now: merge. Only a fetch this
    /// controller starts reports its errors (CKSyncEngine's `didFetchChanges`
    /// carries none), so only this completes the mirror — never a fetch that
    /// failed offline, which would look like an empty zone.
    func fetchAndComplete() async {
        guard let transport, transport.isRunning else { return }
        let starts = transportStarts
        do {
            try await transport.fetchChanges()
        } catch {
            noteError(error)
            return
        }
        guard starts == transportStarts, isEnabled, transport.isRunning, !hasCompletedFetch else { return }
        let engine = engine, now = clock()
        await enqueue { await engine.finishFetch(now: now) }
        hasCompletedFetch = true
        if lastError == nil { markSynced() }
        refreshStatus()
        await performPass()
        await noteUnreadable()
    }

    /// Runs one pass (after any pass or event already being handled).
    func performPass() async {
        await enqueue { [weak self] in await self?.runPass() }
    }

    /// Serializes passes and the handling of fetched/sent records.
    private func enqueue(_ operation: @escaping @MainActor () async -> Void) async {
        let previous = passTask
        let task = Task { @MainActor in
            await previous?.value
            await operation()
        }
        passTask = task
        await task.value
        if passTask == task { passTask = nil }
    }

    private func runPass() async {
        await resetTask?.value
        guard let model, let transport, isEnabled, transport.isRunning else { return }
        let activation = activation
        guard await engine.isMirrorComplete, activation == self.activation else { return }
        if await engine.needsRelisting(now: clock()) {
            await relist()
            return
        }
        passCount += 1
        lastPassQueued = 0
        // iOS has no Keychain change notifications: keys that arrived via
        // iCloud Keychain are picked up here.
        model.reloadProviderKeysFromKeychain()
        var local = model.syncLocalState()
        local.deletions = deletionLog
        let plan = await engine.plan(local: local, now: clock())
        guard activation == self.activation else { return }
        isApplying = true
        let skipped = plan.changes.isEmpty ? [] : model.applyRemote(plan.changes)
        isApplying = false
        // Remote deletes just applied aren't local deletes.
        knownRecordKeys = model.syncRecordKeys()
        let result = await engine.commit(plan, skipped: skipped)
        guard !result.stale, activation == self.activation else { return }
        hasPassedSinceStart = true
        updateDeletionLog { log in
            for (key, date) in plan.handledDeletions where log[key] == date {
                log.removeValue(forKey: key)
            }
        }
        transport.unqueue(result.cancelled)
        transport.queue(saves: result.saves, deletes: result.deletes)
        lastPassQueued = result.saves.count + result.deletes.count
        if !skipped.isEmpty, schedulesAutomatically {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(2))
                await self?.performPass()
            }
        }
    }

    /// Long absence: fetch the whole zone again from scratch; records that
    /// don't come back were deleted while this device was away.
    private func relist() async {
        guard let transport else { return }
        activation += 1
        await engine.beginRelisting()
        hasCompletedFetch = false
        transportStarts += 1
        transport.stop()
        removeState()
        transport.start(state: nil)
        if !(await engine.baseline.zoneSaved) { transport.queueZoneSave() }
        refreshStatus()
        if schedulesAutomatically {
            // Not awaited: this runs inside the pass queue.
            Task { await fetchAndComplete() }
        }
    }

    // MARK: Transport events

    func transport(handle event: CloudSyncEvent) async {
        guard isEnabled, let transport, transport.isRunning else { return }
        switch event {
        case .stateUpdate(let data):
            writeState(data)
        case .accountChange(let change):
            await handleAccountChange(change)
        case .zoneDeleted(let reason):
            await handleZoneDeleted(reason)
        case .fetchedRecords(let modified, let deleted):
            let engine = engine
            await enqueue { await engine.ingest(modified: modified, deleted: deleted) }
            await noteUnreadable()
        case .sentRecords(let saved, let failed, let deleted, let failedDeletes):
            await enqueue { [weak self] in
                await self?.handleSent(saved: saved, failed: failed, deleted: deleted, failedDeletes: failedDeletes)
            }
        case .sentZone(let failure):
            if let failure {
                noteFailure(failure)
            } else {
                await engine.setZoneSaved(true)
            }
        case .willFetch:
            isFetching = true
            refreshStatus()
        case .didFetch(let failure):
            isFetching = false
            if let failure {
                noteFailure(failure)
            } else if hasCompletedFetch {
                // Steady state (pushes, scheduled fetches): merge what came.
                // A join or re-listing completes only in `fetchAndComplete`,
                // where a failed fetch is known to have failed.
                if lastError == nil { markSynced() }
                await performPass()
                await noteUnreadable()
            }
            refreshStatus()
        case .willSend:
            isSending = true
            refreshStatus()
        case .didSend:
            isSending = false
            if lastError == nil { markSynced() }
            refreshStatus()
        }
    }

    func transport(outgoingFor names: [String]) async -> CloudOutgoing {
        // After a launch the transport may send before the first pass has
        // rebuilt the outbox from the saved state.
        if !hasPassedSinceStart, hasCompletedFetch { await performPass() }
        return await engine.outgoing(for: names)
    }

    private func handleAccountChange(_ change: CloudAccountChange) async {
        switch change {
        case .signIn(let user):
            accountStatus = .available
            let previous = await engine.baseline.accountID
            if let previous, previous != user {
                await restartForAccount(user)
            } else {
                await engine.setAccountID(user)
            }
        case .signOut:
            // Local data stays; the next sign-in joins from scratch.
            accountStatus = .noAccount
            stopAndForget()
        case .switchAccounts(let user):
            accountStatus = .available
            await restartForAccount(user)
        }
        refreshStatus()
    }

    private func handleZoneDeleted(_ reason: CloudZoneDeletionReason) async {
        switch reason {
        case .deleted:
            // "Delete iCloud Data" on another device: the copy in iCloud is
            // meant to be gone, so this device stops syncing too instead of
            // uploading everything again. Local data stays.
            logger.info("Sync zone deleted by another device; turning sync off here.")
            disable()
        case .purged, .encryptedDataReset:
            // iCloud data removed in Settings, or encryption keys reset: upload
            // this device's data again (it wins over what was there).
            activation += 1
            let engine = engine
            let accountID = await engine.baseline.accountID
            await enqueue { await engine.reset(fresh: true, accountID: accountID) }
            hasCompletedFetch = false
            hasPassedSinceStart = false
            transport?.queueZoneSave()
            refreshStatus()
            if schedulesAutomatically {
                Task { await fetchAndComplete() }
            }
        }
    }

    private func handleSent(
        saved: [CloudRecord],
        failed: [String: CloudSendFailure],
        deleted: [String],
        failedDeletes: [String: CloudSendFailure]
    ) async {
        guard let transport else { return }
        var requeue = await engine.didSave(saved)
        await engine.didDelete(deleted)
        var conflicts = false
        var zoneMissing = false
        for (name, failure) in failed.sorted(by: { $0.key < $1.key }) {
            switch failure {
            case .serverRecordChanged(let server):
                await engine.conflict(name: name, server: server)
                conflicts = true
            case .zoneNotFound:
                zoneMissing = true
                if await engine.forgetServerCopy(name: name) { requeue.append(name) }
            case .unknownItem:
                if await engine.forgetServerCopy(name: name) { requeue.append(name) }
            case .quotaExceeded, .notAuthenticated, .retryLater, .other:
                noteFailure(failure)
            }
        }
        for (name, failure) in failedDeletes.sorted(by: { $0.key < $1.key }) {
            switch failure {
            case .unknownItem, .zoneNotFound:
                await engine.didDelete([name])
            default:
                noteFailure(failure)
            }
        }
        if zoneMissing {
            await engine.setZoneSaved(false)
            transport.queueZoneSave()
        }
        let hardFailure = (Array(failed.values) + Array(failedDeletes.values)).contains {
            if case .other = $0 { return true }
            return $0 == .quotaExceeded
        }
        if !hardFailure, lastError != nil {
            lastError = nil
            refreshStatus()
        }
        transport.queue(saves: requeue, deletes: [])
        // Merge what the other device saved and queue the result.
        if conflicts { await runPass() }
    }

    private func noteUnreadable() async {
        let count = await engine.unreadable.count
        unreadableMessage = switch count {
        case 0: nil
        case 1: "1 synced item couldn’t be read and was skipped."
        default: "\(count) synced items couldn’t be read and were skipped."
        }
        refreshStatus()
    }

    // MARK: Transport state

    private func readState() -> Data? {
        guard let url = files?.state else { return nil }
        return try? Data(contentsOf: url)
    }

    private func writeState(_ data: Data) {
        guard let url = files?.state else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    private func removeState() {
        guard let url = files?.state else { return }
        try? FileManager.default.removeItem(at: url)
    }
}

/// Where the controller keeps its files (beside `state.json`).
struct CloudSyncFiles {
    /// Merge baseline (`cloudsync.json`).
    var baseline: URL
    /// Serialized transport state: CKSyncEngine change tokens and pending
    /// changes (`cloudsync-state.json`).
    var state: URL
    /// Local deletes not yet turned into tombstones (`cloudsync-deletions.json`).
    var deletions: URL
    /// The server's records as last fetched (`cloudsync-records/`).
    var mirror: URL

    init(directory: URL) {
        baseline = directory.appendingPathComponent("cloudsync.json")
        state = directory.appendingPathComponent("cloudsync-state.json")
        deletions = directory.appendingPathComponent("cloudsync-deletions.json")
        mirror = directory.appendingPathComponent("cloudsync-records", isDirectory: true)
    }

    init(store: PersistentStore) {
        self.init(directory: store.directoryURL)
    }
}

/// A `beginBackgroundTask` that ends exactly once (work finished or time up).
@MainActor
private final class BackgroundTaskHandle {
    private var identifier = UIBackgroundTaskIdentifier.invalid

    func begin() {
        identifier = UIApplication.shared.beginBackgroundTask(withName: "iCloud sync") { [weak self] in
            MainActor.assumeIsolated { self?.end() }
        }
    }

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}
