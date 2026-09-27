import CryptoKit
import Foundation
import Security

/// Source of the 256-bit AES-GCM keys that encrypt the sync folder.
///
/// A key is identified by the `keyID` written in `format.json`; every device
/// that shares the folder needs the key with that id. Old keys are kept (a
/// record written with a previous key can still be read and is re-encrypted
/// with the current one).
protocol SyncKeyProvider: AnyObject, Sendable {
    /// The key with this id, or nil when this device does not have it (yet).
    func key(id: String) -> SymmetricKey?
    /// Stores a newly created key.
    func store(_ key: SymmetricKey, id: String) throws
    /// Deletes a key that was never used (lost the `format.json` race).
    func remove(id: String)
}

extension SyncKeyProvider {
    /// Stores a new random key under a new id and returns the id. Read the
    /// key back with `key(id:)` (a DEBUG fixed-key provider substitutes its own).
    func makeKey() throws -> String {
        let id = UUID().uuidString.lowercased()
        try store(SymmetricKey(size: .bits256), id: id)
        return id
    }
}

/// Production keys: one Keychain item per key, **always synchronizable**
/// (iCloud Keychain), in a service of its own so it is independent of the
/// provider API keys and of "Sync API keys". Reads use
/// `kSecAttrSynchronizableAny`, so a local item (e.g. one written while
/// iCloud Keychain refused synchronizable items) is found too.
///
/// There is no change notification for Keychain items on iOS: callers ask
/// again at the start of every sync pass, so a device waiting for the key
/// picks it up once iCloud Keychain delivers it.
final class KeychainSyncKeyProvider: SyncKeyProvider, @unchecked Sendable {
    static let service = AppIdentity.identifier("sync-key")

    func key(id: String) -> SymmetricKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: id,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data, data.count == 32
        else {
            return nil
        }
        return SymmetricKey(data: data)
    }

    func remove(id: String) {
        // One query per kind (a SynchronizableAny delete fails outright where
        // synchronizable items aren't allowed).
        for synchronizable in [kCFBooleanTrue, kCFBooleanFalse] {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: Self.service,
                kSecAttrAccount as String: id,
                kSecAttrSynchronizable as String: synchronizable as Any
            ]
            SecItemDelete(query as CFDictionary)
        }
    }

    func store(_ key: SymmetricKey, id: String) throws {
        let data = key.withUnsafeBytes { Data($0) }
        var item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: id,
            kSecAttrSynchronizable as String: kCFBooleanTrue as Any,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecValueData as String: data
        ]
        var status = SecItemAdd(item as CFDictionary, nil)
        if status == errSecDuplicateItem {
            item.removeValue(forKey: kSecValueData as String)
            item.removeValue(forKey: kSecAttrAccessible as String)
            status = SecItemUpdate(item as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        }
        if status != errSecSuccess {
            // iCloud Keychain unavailable for this build/device: keep the key
            // locally so this device can still write; other devices will
            // wait for it (and "Reset sync data" is the way out).
            var local = item
            local[kSecAttrSynchronizable as String] = kCFBooleanFalse as Any
            local[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            local[kSecValueData as String] = data
            let localStatus = SecItemAdd(local as CFDictionary, nil)
            guard localStatus == errSecSuccess || localStatus == errSecDuplicateItem else {
                throw NSError(
                    domain: NSOSStatusErrorDomain,
                    code: Int(status),
                    userInfo: [NSLocalizedDescriptionKey: "Unable to store the sync key in the Keychain."]
                )
            }
        }
    }
}

/// Keys in memory (tests, previews). Share one instance between two
/// simulated devices to model iCloud Keychain delivering the key; start a
/// device with an empty one to model iCloud Keychain being off.
final class InMemorySyncKeyProvider: SyncKeyProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [String: SymmetricKey]

    init(_ keys: [String: SymmetricKey] = [:]) {
        self.keys = keys
    }

    func key(id: String) -> SymmetricKey? {
        lock.withLock { keys[id] }
    }

    func store(_ key: SymmetricKey, id: String) throws {
        lock.withLock { keys[id] = key }
    }

    func remove(id: String) {
        lock.withLock { keys[id] = nil }
    }

    var ids: Set<String> {
        lock.withLock { Set(keys.keys) }
    }

    /// Simulates iCloud Keychain delivering keys created on another device.
    func receive(from other: InMemorySyncKeyProvider) {
        let theirs = other.lock.withLock { other.keys }
        lock.withLock { keys.merge(theirs) { mine, _ in mine } }
    }
}

#if DEBUG
/// DEBUG `-dc-sync-key <base64>`: one fixed key for every key id, so two
/// simulators (which do not share a Keychain) can read each other's folder.
final class FixedSyncKeyProvider: SyncKeyProvider, @unchecked Sendable {
    private let key: SymmetricKey

    init(key: SymmetricKey) {
        self.key = key
    }

    func key(id: String) -> SymmetricKey? { key }
    func store(_ key: SymmetricKey, id: String) throws {}
    func remove(id: String) {}
}
#endif
