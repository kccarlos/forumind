import CryptoKit
import Foundation
import os
import SwiftUI
import UIKit

// MARK: - FolderSyncController API (for the UI)
//
// `app.folderSync` (constructed in `AppModel.init`) syncs the app's data
// through a folder the user picks in iCloud Drive (docs/ICLOUD_SYNC_PLAN.md).
//
// Published state:
// - `status`            .off               no folder chosen on this device
//                       .needsFolderAccess the saved folder can't be opened; ask to pick again
//                       .notInICloud       the folder isn't in iCloud Drive (still syncs; warn)
//                       .waitingForKey     the folder is encrypted with a key this device
//                                          doesn't have yet (iCloud Keychain off or slow);
//                                          recovers by itself once the key arrives
//                       .syncing           a pass is running (first pass, Sync now, …)
//                       .upToDate          last pass finished cleanly
//                       .error(message)    last pass failed or skipped unreadable files
// - `folderName`        display name of the picked folder (nil when off)
// - `lastSyncedAt`      end of the last clean pass
// - `isFolderInICloud`  the picked folder is in iCloud Drive
//
// Actions:
// - `useFolder(_ url:)` security-scoped URL from UIDocumentPicker (folder); keeps a
//                       bookmark (UserDefaults, this device only) and starts syncing
// - `syncNow()`         runs a pass now
// - `stop()`            this device stops syncing; local data and the folder stay
// - `resetSyncData()`   new encryption key; every record is rewritten from this device
//
// Passes run: after local saves (debounced 2 s), on foreground, every 60 s while
// active, when the folder changes (NSFilePresenter, NSMetadataQuery when available),
// on Sync now, and a final one on backgrounding (inside a background task).
//
// Local deletes are noticed at save time (records gone since the last save, minus
// pruned ones and remote deletes being applied) and logged with their real time in
// `foldersync-deletions.json` beside the baseline until a pass has written their
// tombstones; Stop clears the log. A pass that started before Stop or a folder
// switch neither applies, writes, nor sets the status.
//
// DEBUG launch arguments (two-simulator end-to-end checks):
// - `-dc-sync-folder <absolute path>`  sync with this plain directory (no bookmark,
//                                      baseline in foldersync-debug.json); simulators
//                                      can share a folder on the host Mac
// - `-dc-sync-key <base64 32 bytes>`   use this fixed encryption key for every key id
//                                      (simulators don't share a Keychain)
// - `-dc-sync-open-manage`             opens Manage after launch (to screenshot synced data)
// Without `-dc-sync-folder`, sync stays off under `-dc-sample` and `-ui-test-*` so
// sample data never reaches a real sync folder.
@MainActor
final class FolderSyncController: ObservableObject {
    enum Status: Equatable {
        case off
        case needsFolderAccess
        case notInICloud
        case waitingForKey
        case syncing
        case upToDate
        case error(String)
    }

    @Published private(set) var status: Status = .off
    @Published private(set) var folderName: String?
    @Published private(set) var lastSyncedAt: Date?
    @Published private(set) var isFolderInICloud = false

    static let bookmarkKey = "folderSync.bookmark"
    static let folderNameKey = "folderSync.folderName"
    static let lastSyncedKey = "folderSync.lastSyncedAt"

    let engine: FolderSyncEngine
    private let defaults: UserDefaults?
    private weak var model: AppModel?
    private let logger = Logger(subsystem: AppIdentity.identifierPrefix, category: "FolderSync")

    /// The sync root (`<picked>/Forumind Sync`) while syncing.
    private(set) var root: URL?
    private var pickedURL: URL?
    private var isAccessingPicked = false
    private var debugFolder: URL?
    private var presenter: FolderSyncPresenter?
    private var metadataQuery: NSMetadataQuery?
    private var metadataObserver: NSObjectProtocol?
    private var setupTask: Task<Void, Never>?
    private var passTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?
    private var timerTask: Task<Void, Never>?
    private var isApplying = false
    private var uploadsAsFresh = false
    /// Bumped on every activate/deactivate: a pass that started with another
    /// folder (or before Stop) doesn't apply, write, or set the status.
    private var activation = 0
    /// Record keys ("kind/id") the app held at the last save, to notice deletes.
    private var knownRecordKeys: Set<String> = []
    /// Local deletes with the time they happened, until a pass has written
    /// their tombstones (persisted: a delete made just before the app is
    /// killed keeps its real time, rather than the time of the next pass).
    private(set) var deletionLog: [String: Date] = [:]
    private let deletionLogURL: URL?

    /// Timers, debounced passes and file notifications (off in unit tests,
    /// which call `performPass()` directly).
    var schedulesAutomatically: Bool
    var debounceDelay: Duration = .seconds(2)
    var clock: () -> Date = Date.init
    /// Files written by the last pass (tests assert zero after convergence).
    private(set) var lastPassWrites = 0
    private(set) var passCount = 0
    /// NSMetadataQuery started and delivered updates (diagnostics).
    private(set) var metadataQueryStarted = false
    private(set) var metadataQueryUpdates = 0

    init(
        storage: FolderSyncStorage = CoordinatedFolderStorage(),
        keys: SyncKeyProvider,
        baselineURL: URL?,
        defaults: UserDefaults?,
        schedulesAutomatically: Bool = true
    ) {
        engine = FolderSyncEngine(storage: storage, keys: keys, baselineURL: baselineURL)
        self.defaults = defaults
        self.schedulesAutomatically = schedulesAutomatically
        lastSyncedAt = defaults?.object(forKey: Self.lastSyncedKey) as? Date
        deletionLogURL = baselineURL.map {
            $0.deletingLastPathComponent()
                .appendingPathComponent($0.deletingPathExtension().lastPathComponent + "-deletions.json")
        }
        if let deletionLogURL, let data = try? Data(contentsOf: deletionLogURL),
           let log = try? FolderSyncCoding.makeDecoder().decode([String: Date].self, from: data) {
            deletionLog = log
        }
    }

    /// The app's controller for a store: the real one (Keychain key, bookmark
    /// in UserDefaults) for the app's own store; an inert one for stores at
    /// other locations (tests), which inject their own when they sync.
    static func makeDefault(for store: PersistentStore) -> FolderSyncController {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "-dc-sync-folder"), index + 1 < arguments.count {
            var keys: SyncKeyProvider = KeychainSyncKeyProvider()
            if let keyIndex = arguments.firstIndex(of: "-dc-sync-key"), keyIndex + 1 < arguments.count,
               let data = Data(base64Encoded: arguments[keyIndex + 1]), data.count == 32 {
                keys = FixedSyncKeyProvider(key: SymmetricKey(data: data))
            }
            let controller = FolderSyncController(
                keys: keys,
                baselineURL: store.folderSyncBaselineURL
                    .deletingLastPathComponent()
                    .appendingPathComponent("foldersync-debug.json"),
                defaults: nil
            )
            controller.debugFolder = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
            return controller
        }
        if AssistantDebug.isActive || arguments.contains(where: { $0.hasPrefix("-ui-test-") }) {
            return FolderSyncController(keys: InMemorySyncKeyProvider(), baselineURL: nil, defaults: nil)
        }
        #endif
        guard store.usesDefaultLocation else {
            return FolderSyncController(
                keys: InMemorySyncKeyProvider(),
                baselineURL: nil,
                defaults: nil,
                schedulesAutomatically: false
            )
        }
        return FolderSyncController(
            keys: KeychainSyncKeyProvider(),
            baselineURL: store.folderSyncBaselineURL,
            defaults: .standard
        )
    }

    /// Called at the end of `AppModel.init`; resumes syncing with the saved folder.
    func attach(_ model: AppModel) {
        self.model = model
        knownRecordKeys = model.folderSyncRecordKeys()
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-dc-sync-open-manage") {
            // End-to-end checks: show Manage (summaries, agent runs, watched).
            Task { @MainActor [weak model] in
                for delay in [1500, 4000, 7000] {
                    try? await Task.sleep(for: .milliseconds(delay))
                    model?.panelRoute = .activity
                    model?.presentAssistant = true
                }
            }
        }
        #endif
        if let debugFolder {
            try? FileManager.default.createDirectory(at: debugFolder, withIntermediateDirectories: true)
            activate(picked: debugFolder, accessing: false)
            return
        }
        restoreBookmark()
    }

    // MARK: Folder

    func useFolder(_ url: URL) throws {
        let accessing = url.startAccessingSecurityScopedResource()
        do {
            let bookmark = try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
            defaults?.set(bookmark, forKey: Self.bookmarkKey)
        } catch {
            if accessing { url.stopAccessingSecurityScopedResource() }
            throw error
        }
        lastSyncedAt = nil
        defaults?.removeObject(forKey: Self.lastSyncedKey)
        activate(picked: url, accessing: accessing)
    }

    func syncNow() {
        guard root != nil else { return }
        status = .syncing
        Task { await performPass(thorough: true) }
    }

    func stop() {
        deactivate()
        updateDeletionLog { $0 = [:] }
        defaults?.removeObject(forKey: Self.bookmarkKey)
        defaults?.removeObject(forKey: Self.folderNameKey)
        defaults?.removeObject(forKey: Self.lastSyncedKey)
        let engine = engine
        let previous = setupTask
        setupTask = Task { await previous?.value; await engine.forget() }
        status = .off
        folderName = nil
        lastSyncedAt = nil
        isFolderInICloud = false
    }

    func resetSyncData() async throws {
        guard root != nil else { throw FolderSyncError.noFolder }
        await setupTask?.value
        status = .syncing
        var failure: Error?
        await enqueue { [weak self] in
            guard let self else { return }
            do {
                try await self.engine.resetFolder()
                self.uploadsAsFresh = true
                await self.runPass(thorough: true)
            } catch {
                self.status = .error(error.localizedDescription)
                failure = error
            }
        }
        if let failure { throw failure }
    }

    private func restoreBookmark() {
        guard let data = defaults?.data(forKey: Self.bookmarkKey) else {
            status = .off
            return
        }
        do {
            var isStale = false
            let url = try URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &isStale)
            let accessing = url.startAccessingSecurityScopedResource()
            if isStale, let fresh = try? url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil) {
                defaults?.set(fresh, forKey: Self.bookmarkKey)
            }
            activate(picked: url, accessing: accessing)
        } catch {
            logger.error("Bookmark could not be resolved: \(error.localizedDescription, privacy: .public)")
            folderName = defaults?.string(forKey: Self.folderNameKey)
            status = .needsFolderAccess
        }
    }

    private func activate(picked: URL, accessing: Bool) {
        deactivate()
        activation += 1
        pickedURL = picked
        isAccessingPicked = accessing
        let values = try? picked.resourceValues(forKeys: [.localizedNameKey, .isUbiquitousItemKey])
        folderName = values?.localizedName ?? picked.lastPathComponent
        defaults?.set(folderName, forKey: Self.folderNameKey)
        isFolderInICloud = values?.isUbiquitousItem ?? false
        let root = FolderSyncEngine.syncRoot(forPicked: picked)
        self.root = root
        status = .syncing
        let engine = engine
        let previous = setupTask
        setupTask = Task { await previous?.value; await engine.setRoot(root) }
        guard schedulesAutomatically else { return }

        let presenter = FolderSyncPresenter(url: root) { [weak self] in
            Task { @MainActor [weak self] in self?.folderDidChange() }
        }
        (engine.storage as? CoordinatedFolderStorage)?.filePresenter = presenter
        NSFileCoordinator.addFilePresenter(presenter)
        self.presenter = presenter
        if isFolderInICloud { startMetadataQuery() }
        if UIApplication.shared.applicationState == .active { startTimer() }
        Task { await performPass(thorough: true) }
    }

    private func deactivate() {
        activation += 1
        debounceTask?.cancel()
        debounceTask = nil
        timerTask?.cancel()
        timerTask = nil
        if let presenter {
            NSFileCoordinator.removeFilePresenter(presenter)
            self.presenter = nil
        }
        stopMetadataQuery()
        if isAccessingPicked { pickedURL?.stopAccessingSecurityScopedResource() }
        isAccessingPicked = false
        pickedURL = nil
        root = nil
    }

    /// Remote change notifications without the iCloud entitlement: the
    /// external-documents scope covers folders opened through the document
    /// picker. If the query does not start (or never updates) nothing breaks;
    /// the presenter and the 60 s poll still pick changes up.
    private func startMetadataQuery() {
        let query = NSMetadataQuery()
        query.searchScopes = [NSMetadataQueryAccessibleUbiquitousExternalDocumentsScope]
        query.predicate = NSPredicate(format: "%K LIKE %@", NSMetadataItemFSNameKey, "*.json")
        metadataObserver = NotificationCenter.default.addObserver(
            forName: .NSMetadataQueryDidUpdate,
            object: query,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.metadataQueryUpdates += 1
                self?.folderDidChange()
            }
        }
        metadataQueryStarted = query.start()
        logger.info("NSMetadataQuery (external documents) started: \(self.metadataQueryStarted, privacy: .public)")
        if metadataQueryStarted {
            metadataQuery = query
        } else {
            stopMetadataQuery()
        }
    }

    private func stopMetadataQuery() {
        metadataQuery?.stop()
        metadataQuery = nil
        if let metadataObserver { NotificationCenter.default.removeObserver(metadataObserver) }
        metadataObserver = nil
    }

    // MARK: Scheduling

    /// `AppModel.save()` calls this after every local save.
    func localDataDidChange() {
        guard !isApplying else { return }
        noteLocalDeletions()
        guard root != nil, schedulesAutomatically else { return }
        schedulePass(after: debounceDelay)
    }

    /// Logs records that left the app since the last save (not pruned ones,
    /// not remote deletes being applied) with the time of the delete.
    private func noteLocalDeletions() {
        guard let model else { return }
        let current = model.folderSyncRecordKeys()
        let removed = knownRecordKeys.subtracting(current)
        knownRecordKeys = current
        // Only while a folder is (or was, and needs access again) in use.
        guard !removed.isEmpty, root != nil || status == .needsFolderAccess else { return }
        let now = clock()
        updateDeletionLog { log in
            for key in removed { log[key] = now }
        }
    }

    private func updateDeletionLog(_ change: (inout [String: Date]) -> Void) {
        let before = deletionLog
        change(&deletionLog)
        guard deletionLog != before, let deletionLogURL else { return }
        if deletionLog.isEmpty {
            try? FileManager.default.removeItem(at: deletionLogURL)
        } else if let data = try? FolderSyncCoding.data(deletionLog) {
            try? FileManager.default.createDirectory(
                at: deletionLogURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? data.write(to: deletionLogURL, options: .atomic)
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
        guard root != nil, schedulesAutomatically else { return }
        switch phase {
        case .active:
            startTimer()
            Task { await performPass(thorough: true) }
        case .background:
            timerTask?.cancel()
            timerTask = nil
            debounceTask?.cancel()
            debounceTask = nil
            // Push what changed before the app is suspended.
            let backgroundTask = BackgroundTaskHandle()
            backgroundTask.begin()
            Task {
                await performPass()
                backgroundTask.end()
            }
        default:
            break
        }
    }

    private func folderDidChange() {
        guard root != nil, !isApplying else { return }
        schedulePass(after: .seconds(1))
    }

    private func schedulePass(after delay: Duration) {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.performPass()
        }
    }

    private func startTimer() {
        timerTask?.cancel()
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { return }
                await self?.performPass()
            }
        }
    }

    // MARK: Pass

    /// Runs one pass (after any pass already running). Tests call this.
    func performPass(thorough: Bool = false) async {
        await enqueue { [weak self] in await self?.runPass(thorough: thorough) }
    }

    /// Serializes passes (and resets): each operation starts after the
    /// previous one has finished.
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

    private func runPass(thorough: Bool) async {
        await setupTask?.value
        guard let model, root != nil else { return }
        let activation = activation
        passCount += 1
        lastPassWrites = 0
        // iOS has no Keychain change notifications: keys that arrived via
        // iCloud Keychain are picked up here.
        model.reloadProviderKeysFromKeychain()
        do {
            let outcome = try await engine.readRemote(thorough: thorough)
            guard activation == self.activation else { return }
            switch outcome {
            case .waitingForKey:
                status = .waitingForKey
            case .downloading:
                if status != .upToDate { status = .syncing }
                if schedulesAutomatically { schedulePass(after: .seconds(5)) }
            case .ready(let remote):
                let fresh = uploadsAsFresh
                uploadsAsFresh = false
                var local = model.folderSyncLocalState()
                local.deletions = deletionLog
                let plan = await engine.plan(local: local, remote: remote, now: clock(), fresh: fresh)
                guard activation == self.activation else { return }
                isApplying = true
                let skipped = plan.changes.isEmpty ? [] : model.applyRemote(plan.changes)
                isApplying = false
                // Remote deletes just applied aren't local deletes.
                knownRecordKeys = model.folderSyncRecordKeys()
                let result = await engine.commit(plan, skipped: skipped, keyID: remote.keyID)
                guard !result.stale, activation == self.activation else { return }
                updateDeletionLog { log in
                    for (key, date) in plan.handledDeletions where log[key] == date {
                        log.removeValue(forKey: key)
                    }
                }
                lastPassWrites = result.writes
                if !remote.unreadable.isEmpty {
                    let count = remote.unreadable.count
                    status = .error(count == 1
                        ? "1 synced item couldn’t be read and was skipped."
                        : "\(count) synced items couldn’t be read and were skipped.")
                } else if let error = result.errors.first {
                    status = Self.isAccessError(error) ? .needsFolderAccess : .error(error.localizedDescription)
                } else {
                    status = isFolderInICloud ? .upToDate : .notInICloud
                    let now = clock()
                    lastSyncedAt = now
                    defaults?.set(now, forKey: Self.lastSyncedKey)
                }
                if !skipped.isEmpty, schedulesAutomatically { schedulePass(after: debounceDelay) }
            }
        } catch {
            isApplying = false
            guard activation == self.activation else { return }
            logger.error("Sync pass failed: \(error.localizedDescription, privacy: .public)")
            status = Self.isAccessError(error) ? .needsFolderAccess : .error(error.localizedDescription)
        }
    }

    private static func isAccessError(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == NSCocoaErrorDomain
            && [NSFileReadNoPermissionError, NSFileWriteNoPermissionError].contains(error.code)
    }
}

/// A `beginBackgroundTask` that ends exactly once (pass finished or time up).
@MainActor
private final class BackgroundTaskHandle {
    private var identifier = UIBackgroundTaskIdentifier.invalid

    func begin() {
        identifier = UIApplication.shared.beginBackgroundTask(withName: "Folder sync") { [weak self] in
            MainActor.assumeIsolated { self?.end() }
        }
    }

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}

/// Tells the controller when files in the sync folder change (other
/// processes, iCloud Drive downloads). Our own coordinated writes pass this
/// presenter to the coordinator and so do not call it back.
final class FolderSyncPresenter: NSObject, NSFilePresenter {
    let presentedItemURL: URL?
    let presentedItemOperationQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        return queue
    }()
    private let onChange: () -> Void

    init(url: URL, onChange: @escaping () -> Void) {
        presentedItemURL = url
        self.onChange = onChange
    }

    func presentedItemDidChange() { onChange() }
    func presentedSubitemDidChange(at url: URL) { onChange() }
    func presentedSubitemDidAppear(at url: URL) { onChange() }
    func presentedSubitem(at oldURL: URL, didMoveTo newURL: URL) { onChange() }
}
