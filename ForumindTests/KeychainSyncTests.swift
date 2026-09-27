import Security
import XCTest
@testable import Forumind

/// "Sync API keys": provider keys as iCloud Keychain (synchronizable) items,
/// the launch migration of local items, and turning sync off and on.
final class KeychainSyncTests: XCTestCase {
    // MARK: In-memory Keychain

    private func makeStore(
        _ backend: FakeKeychainBackend,
        synchronizes: Bool = true
    ) -> KeychainProviderKeyStore {
        KeychainProviderKeyStore(keychain: KeychainStore(backend: backend), synchronizes: synchronizes)
    }

    func testSettingDefaultsToOnAndOlderSnapshotsDecodeAsOn() throws {
        XCTAssertTrue(AppSettings().syncAPIKeys)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        XCTAssertTrue(decoded.syncAPIKeys)
        var off = AppSettings()
        off.syncAPIKeys = false
        let roundTrip = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(off))
        XCTAssertFalse(roundTrip.syncAPIKeys)
    }

    func testWritesWithSyncOnCreateOnlySynchronizableItems() throws {
        let backend = FakeKeychainBackend()
        let store = makeStore(backend)
        try store.set("sk-1", for: .openAI)
        XCTAssertEqual(backend.item("openai", synchronizable: true), "sk-1")
        XCTAssertNil(backend.item("openai", synchronizable: false))
        XCTAssertEqual(store.value(for: .openAI), "sk-1")

        try store.set("sk-2", for: .openAI)
        XCTAssertEqual(backend.item("openai", synchronizable: true), "sk-2", "an edit updates the synced item")
        XCTAssertEqual(backend.count, 1)
    }

    func testDeletingWithSyncOnRemovesTheSyncedItem() throws {
        let backend = FakeKeychainBackend()
        backend.put("openai", "sk-synced", synchronizable: true)
        backend.put("openai", "sk-local", synchronizable: false)
        let store = makeStore(backend)
        try store.set("", for: .openAI)
        XCTAssertEqual(backend.count, 0, "deleting while syncing deletes every copy")
        XCTAssertEqual(store.value(for: .openAI), "")
    }

    func testLaunchMigrationMovesLocalKeysToICloudKeychain() {
        let backend = FakeKeychainBackend()
        backend.put("openai", "sk-local", synchronizable: false)
        backend.put("anthropic", "sk-ant", synchronizable: false)
        let store = makeStore(backend, synchronizes: false)
        store.configure(synchronizes: true)

        XCTAssertEqual(backend.item("openai", synchronizable: true), "sk-local")
        XCTAssertNil(backend.item("openai", synchronizable: false))
        XCTAssertEqual(backend.item("anthropic", synchronizable: true), "sk-ant")
        XCTAssertEqual(store.lastMigration[.openAI], .moved)
        XCTAssertEqual(store.lastMigration[.groq], .nothingToMove)
        XCTAssertEqual(store.value(for: .openAI), "sk-local")

        // Running again (every launch) changes nothing.
        store.configure(synchronizes: true)
        XCTAssertEqual(store.lastMigration[.openAI], .nothingToMove)
        XCTAssertEqual(backend.count, 2)
    }

    func testFailedMigrationKeepsTheLocalKey() {
        let backend = FakeKeychainBackend()
        backend.put("openai", "sk-local", synchronizable: false)
        backend.syncAddStatus = errSecMissingEntitlement
        let store = makeStore(backend, synchronizes: false)
        store.configure(synchronizes: true)

        XCTAssertEqual(store.lastMigration[.openAI], .failed(errSecMissingEntitlement))
        XCTAssertEqual(backend.item("openai", synchronizable: false), "sk-local", "a key is never lost")
        XCTAssertEqual(store.value(for: .openAI), "sk-local")

        // Once iCloud Keychain works, the next launch moves it.
        backend.syncAddStatus = nil
        store.configure(synchronizes: true)
        XCTAssertEqual(store.lastMigration[.openAI], .moved)
        XCTAssertEqual(backend.item("openai", synchronizable: true), "sk-local")
    }

    func testMigrationWithTheSameSyncedKeyRemovesTheLocalCopy() {
        let backend = FakeKeychainBackend()
        backend.put("openai", "sk-same", synchronizable: false)
        backend.put("openai", "sk-same", synchronizable: true)
        let store = makeStore(backend)
        store.configure(synchronizes: true)
        XCTAssertEqual(store.lastMigration[.openAI], .alreadySynced)
        XCTAssertEqual(backend.count, 1)
    }

    func testMigrationKeepsADifferentLocalKeyAndNeverOverwritesTheSyncedOne() {
        // Another device already synced its key; this device's own key stays
        // in use here and the other device keeps its key.
        let backend = FakeKeychainBackend()
        backend.put("openai", "sk-this-device", synchronizable: false)
        backend.put("openai", "sk-other-device", synchronizable: true)
        let store = makeStore(backend)
        store.configure(synchronizes: true)

        XCTAssertEqual(store.lastMigration[.openAI], .keptLocal)
        XCTAssertEqual(backend.item("openai", synchronizable: true), "sk-other-device")
        XCTAssertEqual(store.value(for: .openAI), "sk-this-device")
    }

    func testSyncedKeyFromAnotherDeviceIsRead() {
        let backend = FakeKeychainBackend()
        backend.put("groq", "gsk-remote", synchronizable: true)
        XCTAssertEqual(makeStore(backend).value(for: .groq), "gsk-remote")
    }

    func testWriteFallsBackToLocalWhenICloudKeychainRefuses() throws {
        let backend = FakeKeychainBackend()
        backend.syncAddStatus = errSecMissingEntitlement
        let store = makeStore(backend)
        try store.set("sk-1", for: .openAI)
        XCTAssertEqual(backend.item("openai", synchronizable: false), "sk-1")
        XCTAssertEqual(store.value(for: .openAI), "sk-1")
    }

    func testTurningSyncOffKeepsALocalCopyAndLeavesTheSyncedItem() throws {
        let backend = FakeKeychainBackend()
        let store = makeStore(backend)
        try store.set("sk-1", for: .openAI)

        store.setSynchronizes(false, keys: [.openAI: "sk-1", .groq: ""])
        XCTAssertEqual(backend.item("openai", synchronizable: false), "sk-1")
        XCTAssertEqual(backend.item("openai", synchronizable: true), "sk-1", "other devices keep the key")
        XCTAssertNil(backend.item("groq", synchronizable: false))

        // Edits while off stay on this device and win here.
        try store.set("sk-local-edit", for: .openAI)
        XCTAssertEqual(store.value(for: .openAI), "sk-local-edit")
        XCTAssertEqual(backend.item("openai", synchronizable: true), "sk-1")

        // Deleting while off never touches the synced item, and the synced
        // key does not come back on this device.
        try store.set("", for: .openAI)
        XCTAssertEqual(store.value(for: .openAI), "")
        XCTAssertEqual(backend.item("openai", synchronizable: true), "sk-1")

        // A synced key from another device is not used while off.
        backend.put("groq", "gsk-remote", synchronizable: true)
        XCTAssertEqual(store.value(for: .groq), "")
    }

    func testTurningSyncBackOnPushesThisDevicesKeys() throws {
        let backend = FakeKeychainBackend()
        backend.put("openai", "sk-old", synchronizable: true)
        let store = makeStore(backend, synchronizes: false)
        try store.set("sk-new", for: .openAI)

        store.setSynchronizes(true, keys: [.openAI: "sk-new"])
        XCTAssertEqual(backend.item("openai", synchronizable: true), "sk-new")
        XCTAssertNil(backend.item("openai", synchronizable: false))
        XCTAssertEqual(store.value(for: .openAI), "sk-new")
    }

    func testAppModelLoadsKeysThroughTheSyncingStore() throws {
        let backend = FakeKeychainBackend()
        backend.put("openai", "sk-local", synchronizable: false)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("KeychainSyncTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let keys = makeStore(backend, synchronizes: false)
        let persistent = PersistentStore(fileURL: directory.appendingPathComponent("state.json"), keys: keys)
        let snapshot = persistent.load()
        XCTAssertTrue(snapshot.settings.syncAPIKeys)
        XCTAssertTrue(keys.synchronizes, "load() applies the saved setting")
        XCTAssertEqual(backend.item("openai", synchronizable: true), "sk-local", "load() migrates")
    }

    /// Reset settings with "Sync API keys" off deletes this device's keys and
    /// leaves sync off: the key synced by other devices doesn't come back
    /// (on the next pass, foreground or launch), and isn't deleted for them.
    @MainActor
    func testResetSettingsWithKeySyncOffDoesNotBringTheSyncedKeyBack() throws {
        let backend = FakeKeychainBackend()
        backend.put("openai", "sk-synced", synchronizable: true)
        backend.put("openai", "sk-local", synchronizable: false)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("KeychainSyncTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("state.json")
        var snapshot = AppSnapshot()
        snapshot.settings.syncAPIKeys = false
        snapshot.settings.hasCompletedOnboarding = true
        try PersistentStore(fileURL: fileURL, keys: InMemoryProviderKeyStore()).save(snapshot)

        let keys = makeStore(backend)
        let app = AppModel(store: PersistentStore(fileURL: fileURL, keys: keys))
        XCTAssertFalse(keys.synchronizes)
        XCTAssertEqual(app.settings.configuration(for: .openAI).apiKey, "sk-local")

        app.resetSettings()
        XCTAssertFalse(app.settings.syncAPIKeys)
        XCTAssertEqual(app.settings.configuration(for: .openAI).apiKey, "")
        XCTAssertNil(backend.item("openai", synchronizable: false))
        XCTAssertEqual(backend.item("openai", synchronizable: true), "sk-synced", "other devices keep theirs")
        app.reloadProviderKeysFromKeychain()
        XCTAssertEqual(app.settings.configuration(for: .openAI).apiKey, "")

        let relaunchedKeys = makeStore(backend)
        let relaunched = AppModel(store: PersistentStore(fileURL: fileURL, keys: relaunchedKeys))
        XCTAssertEqual(relaunched.settings.configuration(for: .openAI).apiKey, "")
        XCTAssertFalse(relaunched.settings.syncAPIKeys)
    }

    // MARK: Real Keychain (simulator test host)

    /// Exercises the Security framework under a throwaway service. Skips when
    /// the test host can't use synchronizable items (unsigned builds).
    func testRealKeychainSynchronizableRoundTrip() throws {
        let service = AppIdentity.identifier("tests-\(UUID().uuidString)")
        let backend = SecKeychainBackend(service: service)
        let account = "openai"
        defer {
            _ = backend.delete(account: account, synchronizable: nil)
        }

        let probe = backend.add(account: account, data: Data("probe".utf8), synchronizable: true)
        if probe == errSecMissingEntitlement || probe == errSecNotAvailable {
            throw XCTSkip("Synchronizable Keychain items aren't available in this test host (\(probe)).")
        }
        XCTAssertEqual(probe, errSecSuccess)
        _ = backend.delete(account: account, synchronizable: nil)

        // A pre-sync local key migrates, then reads back from the synced item.
        XCTAssertEqual(backend.add(account: account, data: Data("sk-local".utf8), synchronizable: false), errSecSuccess)
        let store = KeychainProviderKeyStore(keychain: KeychainStore(backend: backend), synchronizes: false)
        store.configure(synchronizes: true)
        XCTAssertEqual(store.lastMigration[.openAI], .moved)
        XCTAssertEqual(backend.read(account: account, synchronizable: false).status, errSecItemNotFound)
        XCTAssertEqual(backend.read(account: account, synchronizable: true).data, Data("sk-local".utf8))
        XCTAssertEqual(store.value(for: .openAI), "sk-local")

        // Off: a local copy; the synced item stays.
        store.setSynchronizes(false, keys: [.openAI: "sk-local"])
        try store.set("sk-edit", for: .openAI)
        XCTAssertEqual(store.value(for: .openAI), "sk-edit")
        XCTAssertEqual(backend.read(account: account, synchronizable: true).data, Data("sk-local".utf8))

        // Back on: this device's key replaces the synced one.
        store.setSynchronizes(true, keys: [.openAI: "sk-edit"])
        XCTAssertEqual(backend.read(account: account, synchronizable: true).data, Data("sk-edit".utf8))
        XCTAssertEqual(backend.read(account: account, synchronizable: false).status, errSecItemNotFound)

        // Delete with sync on removes everything.
        try store.set("", for: .openAI)
        XCTAssertEqual(backend.read(account: account, synchronizable: true).status, errSecItemNotFound)
        XCTAssertEqual(store.value(for: .openAI), "")
    }

    /// Runs even where synchronizable items are refused (unsigned simulator
    /// builds): keys fall back to local items and deleting still works.
    func testRealKeychainFallsBackToLocalItems() throws {
        let service = AppIdentity.identifier("tests-\(UUID().uuidString)")
        let backend = SecKeychainBackend(service: service)
        defer { _ = backend.delete(account: "openai", synchronizable: nil) }
        let local = backend.add(account: "openai", data: Data("probe".utf8), synchronizable: false)
        if local == errSecMissingEntitlement {
            throw XCTSkip("This test host has no Keychain access (unsigned build).")
        }
        _ = backend.delete(account: "openai", synchronizable: false)
        let store = KeychainProviderKeyStore(keychain: KeychainStore(backend: backend), synchronizes: true)
        try store.set("sk-1", for: .openAI)
        XCTAssertEqual(store.value(for: .openAI), "sk-1")
        try store.set("", for: .openAI)
        XCTAssertEqual(store.value(for: .openAI), "")
        XCTAssertEqual(backend.read(account: "openai", synchronizable: false).status, errSecItemNotFound)
    }

    #if DEBUG
    func testProbeCleansUpAfterItself() throws {
        let service = AppIdentity.identifier("sync-probe-test-\(UUID().uuidString)")
        let result = KeychainSyncProbe.run(service: service)
        XCTAssertFalse(result.summary.isEmpty)
        if result.addStatus == errSecMissingEntitlement {
            XCTAssertFalse(result.passed)
            throw XCTSkip("Synchronizable Keychain items aren't available in this test host.")
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
        ]
        XCTAssertEqual(SecItemCopyMatching(query as CFDictionary, nil), errSecItemNotFound)
        XCTAssertTrue(result.passed, result.summary)
    }
    #endif
}

/// Keychain with separate local and synchronizable items per account.
private final class FakeKeychainBackend: KeychainBackend {
    private struct Key: Hashable {
        var account: String
        var synchronizable: Bool
    }

    private var items: [Key: Data] = [:]
    /// When set, adding a synchronizable item fails with this status.
    var syncAddStatus: OSStatus?

    var count: Int { items.count }

    func put(_ account: String, _ value: String, synchronizable: Bool) {
        items[Key(account: account, synchronizable: synchronizable)] = Data(value.utf8)
    }

    func item(_ account: String, synchronizable: Bool) -> String? {
        items[Key(account: account, synchronizable: synchronizable)].flatMap { String(data: $0, encoding: .utf8) }
    }

    func read(account: String, synchronizable: Bool) -> (status: OSStatus, data: Data?) {
        guard let data = items[Key(account: account, synchronizable: synchronizable)] else {
            return (errSecItemNotFound, nil)
        }
        return (errSecSuccess, data)
    }

    func add(account: String, data: Data, synchronizable: Bool) -> OSStatus {
        if synchronizable, let syncAddStatus { return syncAddStatus }
        let key = Key(account: account, synchronizable: synchronizable)
        guard items[key] == nil else { return errSecDuplicateItem }
        items[key] = data
        return errSecSuccess
    }

    func update(account: String, data: Data, synchronizable: Bool) -> OSStatus {
        let key = Key(account: account, synchronizable: synchronizable)
        guard items[key] != nil else { return errSecItemNotFound }
        items[key] = data
        return errSecSuccess
    }

    func delete(account: String, synchronizable: Bool?) -> OSStatus {
        let targets = synchronizable.map { [$0] } ?? [false, true]
        var found = false
        for flag in targets where items.removeValue(forKey: Key(account: account, synchronizable: flag)) != nil {
            found = true
        }
        return found ? errSecSuccess : errSecItemNotFound
    }
}
