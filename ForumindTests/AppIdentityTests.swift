import XCTest
@testable import Forumind

/// Every identifier derives from the one prefix the project generator sets.
final class AppIdentityTests: XCTestCase {
    func testIdentifiersDeriveFromTheBundlePrefix() {
        let prefix = AppIdentity.identifierPrefix
        XCTAssertEqual(prefix, Bundle.main.bundleIdentifier)
        XCTAssertEqual(AppIdentity.appGroupIdentifier, "group.\(prefix)")
        XCTAssertEqual(SharedInbox.appGroupIdentifier, AppIdentity.appGroupIdentifier)
        XCTAssertEqual(KeychainStore.providerKeysService, "\(prefix).provider-keys")
    }

    func testBackgroundTaskIdentifierIsPermittedInInfoPlist() {
        let permitted = Bundle.main.object(
            forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers"
        ) as? [String]
        XCTAssertEqual(permitted, [WatchBackgroundRefresh.identifier])
        XCTAssertEqual(WatchBackgroundRefresh.identifier, "\(AppIdentity.identifierPrefix).watchRefresh")
    }

    func testOnlyTheForumindURLSchemeIsRegistered() {
        let types = Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]]
        let schemes = types?.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
        XCTAssertEqual(schemes, [IncomingLink.scheme])
    }
}
