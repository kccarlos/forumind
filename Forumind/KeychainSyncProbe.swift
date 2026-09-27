import Foundation
import Security

#if DEBUG
/// DEBUG `-dc-keychain-sync-probe`: checks that iCloud Keychain
/// (synchronizable) items work in this build — free-team signing is not
/// documented to support them. Adds a synchronizable item under a throwaway
/// service, reads it back with `kSecAttrSynchronizableAny`, reports whether
/// `kSecAttrSynchronizable` reads back true, then deletes it. The result is
/// printed (`DCPROBE …`) and shown in an alert.
enum KeychainSyncProbe {
    static let launchArgument = "-dc-keychain-sync-probe"
    static let service = AppIdentity.identifier("sync-probe")

    static var isRequested: Bool {
        ProcessInfo.processInfo.arguments.contains(launchArgument)
    }

    struct Result: Equatable {
        var addStatus: OSStatus
        var readStatus: OSStatus
        var readBackSynchronizable: Bool?
        var valueMatches: Bool
        var deleteStatus: OSStatus

        var passed: Bool {
            addStatus == errSecSuccess && readStatus == errSecSuccess
                && readBackSynchronizable == true && valueMatches && deleteStatus == errSecSuccess
        }

        var summary: String {
            let synced = readBackSynchronizable.map { $0 ? "true" : "false" } ?? "n/a"
            return [
                passed ? "PASS: synchronizable Keychain items work in this build." : "FAIL: synchronizable Keychain items don't work as expected.",
                "add: \(describe(addStatus))",
                "read (SynchronizableAny): \(describe(readStatus))",
                "kSecAttrSynchronizable read back: \(synced)",
                "value matches: \(valueMatches)",
                "delete: \(describe(deleteStatus))"
            ].joined(separator: "\n")
        }

        private func describe(_ status: OSStatus) -> String {
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown"
            return "\(status) (\(message))"
        }
    }

    /// Runs the probe against the real Keychain (`service` only).
    static func run(service: String = KeychainSyncProbe.service) -> Result {
        let account = "probe-\(UUID().uuidString)"
        let value = Data("sync-probe-\(Date().timeIntervalSince1970)".utf8)
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        var add = base
        add[kSecAttrSynchronizable as String] = kCFBooleanTrue
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        add[kSecValueData as String] = value
        let addStatus = SecItemAdd(add as CFDictionary, nil)

        var read = base
        read[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
        read[kSecReturnAttributes as String] = true
        read[kSecReturnData as String] = true
        read[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let readStatus = SecItemCopyMatching(read as CFDictionary, &item)
        let attributes = item as? [String: Any]
        let synchronizable = attributes.map { attributes -> Bool in
            let flag = attributes[kSecAttrSynchronizable as String]
            if let number = flag as? NSNumber { return number.boolValue }
            if let bool = flag as? Bool { return bool }
            return false
        }
        let readValue = attributes?[kSecValueData as String] as? Data

        var delete = base
        delete[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
        let deleteStatus = SecItemDelete(delete as CFDictionary)

        let result = Result(
            addStatus: addStatus,
            readStatus: readStatus,
            readBackSynchronizable: synchronizable,
            valueMatches: readValue == value,
            deleteStatus: deleteStatus
        )
        for line in result.summary.split(separator: "\n") {
            print("DCPROBE \(line)")
        }
        return result
    }
}
#endif
