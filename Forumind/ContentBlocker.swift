import Combine
import CryptoKit
import Foundation
import OSLog
import WebKit

// MARK: - Built-in ad and tracker blocking
//
// The rules pipeline bundles WebKit content-rule-list JSON chunks in the
// `ContentBlocking` resource folder, described by `manifest.json`. At launch
// `ContentRuleLibrary` looks each chunk up in the rule-list store (instant on
// relaunch) and compiles the missing ones in the background, one at a time;
// every chunk attaches to the browser the moment it is ready. The first page
// load never waits for compilation (it waits at most ~300 ms for lookups).
//
// How exceptions work (verified at runtime, see ContentBlockerTests):
// - WebKit evaluates each rule list on its own: an `ignore-previous-rules`
//   rule only cancels earlier rules *of the same list*. So the always-allowed
//   requests (forum sign-in and JSON/raw endpoints, sign-in and captcha
//   providers) are appended to every chunk as a fixed exceptions tail before
//   compiling. The tail is versioned into the identifier.
// - Sites the user allows (and sign-in pages such as accounts.google.com)
//   are handled by `ContentBlocker`: while the main frame shows such a page,
//   the blocking lists are removed from the web view's user content
//   controller; they are put back when a main-frame navigation leaves it.
//   Changing lists in `decidePolicyFor` applies to that navigation's loads.

enum ContentBlockingCategory: String, Codable, CaseIterable, Hashable {
    /// EasyList.
    case ads
    /// EasyPrivacy (trackers).
    case privacy
}

/// `ContentBlocking/manifest.json`, written by the rules pipeline.
struct ContentBlockingManifest: Codable, Equatable {
    struct Source: Codable, Equatable {
        var name: String
        var url: String?
        var listVersion: String?
        var license: String?
    }

    struct List: Codable, Equatable {
        var identifier: String
        /// Raw category; chunks of an unknown category are ignored.
        var category: String
        var file: String
        var ruleCount: Int?
        var sha256: String?

        var knownCategory: ContentBlockingCategory? { ContentBlockingCategory(rawValue: category) }
    }

    var version: String
    var generatedAt: String?
    var sources: [Source]
    var lists: [List]

    init(version: String, generatedAt: String? = nil, sources: [Source] = [], lists: [List]) {
        self.version = version
        self.generatedAt = generatedAt
        self.sources = sources
        self.lists = lists
    }

    private enum CodingKeys: String, CodingKey { case version, generatedAt, sources, lists }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(String.self, forKey: .version)
        generatedAt = try container.decodeIfPresent(String.self, forKey: .generatedAt)
        sources = try container.decodeIfPresent([Source].self, forKey: .sources) ?? []
        lists = try container.decodeIfPresent([List].self, forKey: .lists) ?? []
    }

    /// `generatedAt` as a date (ISO 8601, with or without fractional seconds).
    var generatedDate: Date? {
        guard let generatedAt else { return nil }
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: generatedAt) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: generatedAt) { return date }
        formatter.formatOptions = [.withFullDate]
        return formatter.date(from: generatedAt)
    }

    static func load(from directory: URL) -> ContentBlockingManifest? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("manifest.json")) else {
            return nil
        }
        return try? JSONDecoder().decode(ContentBlockingManifest.self, from: data)
    }
}

/// Pure rule helpers: identifiers, the exceptions tail, allowed-site matching.
enum ContentBlockingRules {
    /// Our identifiers in the rule-list store start with this; anything else
    /// with it that is not current is stale and removed.
    static let identifierPrefix = "dc-"

    static func identifier(for list: ContentBlockingManifest.List, manifestVersion: String) -> String {
        "\(identifierPrefix)\(list.identifier)-\(manifestVersion)-x\(exceptionsVersion)"
    }

    // MARK: Exceptions tail

    /// First-party requests a forum page must always be able to make: the
    /// app's in-page `fetch()` (topic JSON, `/raw`, search, latest, site
    /// info) and Discourse sign-in. Only first-party loads are exempt, so a
    /// page cannot use these paths to pull in a third-party ad.
    static let firstPartyPathPatterns = [
        #"^https?://[^?#]*\.json"#,           // /t/1.json, /latest.json, /search.json, /site/basic-info.json, /about.json…
        #"^https?://[^?#]*/raw/[0-9]"#,
        #"^https?://[^?#]*/session"#,          // /session, /session/csrf, other sign-in routes
        #"^https?://[^?#]*/auth/"#,
        #"^https?://[^?#]*/login"#,
        #"^https?://[^?#]*/u/"#,
        #"^https?://[^?#]*/message-bus/"#,
        #"^https?://[^?#]*/cdn-cgi/challenge-platform/"#
    ]

    /// Sign-in, OAuth, and challenge (captcha) resources used by forum logins,
    /// allowed from any page.
    static let signInResourcePatterns = [
        #"^https?://accounts\.google\.com/"#,
        #"^https?://www\.google\.com/recaptcha/"#,
        #"^https?://www\.recaptcha\.net/recaptcha/"#,
        #"^https?://www\.gstatic\.com/recaptcha/"#,
        #"^https?://appleid\.apple\.com/"#,
        #"^https?://idmsa\.apple\.com/"#,
        #"^https?://appleid\.cdn-apple\.com/"#,
        #"^https?://github\.com/login"#,
        #"^https?://github\.com/session"#,
        #"^https?://challenges\.cloudflare\.com/"#,
        #"^https?://[a-z0-9.-]*hcaptcha\.com/"#,
        #"^https?://discord\.com/oauth2"#,
        #"^https?://discord\.com/api/oauth2"#,
        #"^https?://discord\.com/login"#,
        #"^https?://[a-z]+\.facebook\.com/[^?#]*dialog/oauth"#,
        #"^https?://[a-z]+\.facebook\.com/login"#,
        #"^https?://login\.microsoftonline\.com/"#,
        #"^https?://login\.live\.com/"#,
        #"^https?://x\.com/i/oauth2"#,
        #"^https?://twitter\.com/i/oauth2"#,
        #"^https?://api\.twitter\.com/oauth"#,
        #"^https?://api\.x\.com/oauth"#
    ]

    static var exceptionRules: [[String: Any]] {
        firstPartyPathPatterns.map { pattern in
            [
                "trigger": ["url-filter": pattern, "load-type": ["first-party"]],
                "action": ["type": "ignore-previous-rules"]
            ]
        } + signInResourcePatterns.map { pattern in
            [
                "trigger": ["url-filter": pattern],
                "action": ["type": "ignore-previous-rules"]
            ]
        }
    }

    /// The tail as a JSON array (stable key order).
    static let exceptionsJSON: String = {
        let data = try? JSONSerialization.data(
            withJSONObject: exceptionRules,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    }()

    /// First 8 hex digits of the tail's SHA-256: a new tail recompiles.
    static let exceptionsVersion: String = {
        SHA256.hash(data: Data(exceptionsJSON.utf8))
            .prefix(4)
            .map { String(format: "%02x", $0) }
            .joined()
    }()

    /// Appends the exceptions tail to a rule-list JSON array (text surgery,
    /// so a multi-megabyte chunk is not parsed). Nil when it is not an array.
    static func appendingExceptions(to json: String) -> String? {
        appending(tail: exceptionsJSON, to: json)
    }

    static func appending(tail: String, to json: String) -> String? {
        let tailBody = tail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard tailBody.hasPrefix("["), tailBody.hasSuffix("]") else { return nil }
        let tailRules = tailBody.dropFirst().dropLast().trimmingCharacters(in: .whitespacesAndNewlines)
        guard let open = json.firstIndex(where: { !$0.isWhitespace }), json[open] == "[",
              let close = json.lastIndex(where: { !$0.isWhitespace }), json[close] == "]",
              open < close
        else {
            return nil
        }
        if tailRules.isEmpty { return json }
        let inner = json[json.index(after: open)..<close]
        let isEmpty = inner.allSatisfy(\.isWhitespace)
        return isEmpty ? "[" + tailRules + "]" : "[" + inner + "," + tailRules + "]"
    }

    // MARK: Allowed sites

    /// Lowercased host for an allowed-sites entry (a host or a site URL),
    /// without "www."; nil when it has no host.
    static func normalizedHost(_ entry: String) -> String? {
        let text = entry.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty else { return nil }
        let host: String?
        if text.contains("://") {
            host = URL(string: text)?.host
        } else {
            host = URL(string: "https://" + text)?.host
        }
        guard var host, !host.isEmpty, !host.contains(" ") else { return nil }
        if host.hasSuffix(".") { host.removeLast() }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host.isEmpty ? nil : host
    }

    /// True when `url`'s host is an allowed site or one of its subdomains.
    static func isAllowed(_ url: URL?, allowedSites: [String]) -> Bool {
        guard let host = url?.host.flatMap(normalizedHost) else { return false }
        return allowedSites.contains { entry in
            guard let allowed = normalizedHost(entry) else { return false }
            return host == allowed || host.hasSuffix("." + allowed)
        }
    }

    /// Sign-in pages shown as the main page (OAuth, Apple ID, challenges):
    /// blocking stays off there so a forum login is never broken.
    static let signInPages: [(host: String, pathPrefixes: [String])] = [
        ("accounts.google.com", []),
        ("appleid.apple.com", []),
        ("idmsa.apple.com", []),
        ("challenges.cloudflare.com", []),
        ("login.microsoftonline.com", []),
        ("login.live.com", []),
        ("github.com", ["/login", "/session", "/sessions"]),
        ("discord.com", ["/oauth2", "/api/oauth2", "/login"]),
        ("facebook.com", ["/login", "/dialog/oauth", "/v"]),
        ("x.com", ["/i/oauth2"]),
        ("twitter.com", ["/i/oauth2"]),
        ("api.twitter.com", ["/oauth"]),
        ("api.x.com", ["/oauth"])
    ]

    static func isSignInPage(_ url: URL?) -> Bool {
        guard let url, let host = url.host.flatMap(normalizedHost) else { return false }
        let path = url.path.lowercased()
        return signInPages.contains { page in
            let hostMatches = host == page.host
                || (page.host == "facebook.com" && host.hasSuffix(".facebook.com"))
            guard hostMatches else { return false }
            if page.host == "facebook.com", path.hasPrefix("/v") {
                return path.contains("/dialog/oauth")
            }
            return page.pathPrefixes.isEmpty || page.pathPrefixes.contains { path.hasPrefix($0) }
        }
    }
}

/// What the browser applies: category switches and allowed sites.
struct ContentBlockingPolicy: Equatable {
    var blockAds = true
    var blockTrackers = true
    var allowedSites: [String] = []

    init(blockAds: Bool = true, blockTrackers: Bool = true, allowedSites: [String] = []) {
        self.blockAds = blockAds
        self.blockTrackers = blockTrackers
        self.allowedSites = allowedSites
    }

    init(settings: AppSettings) {
        self.init(
            blockAds: settings.contentBlockingEnabled,
            blockTrackers: settings.blockTrackers,
            allowedSites: settings.adBlockAllowedSites
        )
    }

    var enabledCategories: Set<ContentBlockingCategory> {
        var categories: Set<ContentBlockingCategory> = []
        if blockAds { categories.insert(.ads) }
        if blockTrackers { categories.insert(.privacy) }
        return categories
    }

    /// Categories blocked while `topURL` is the main page.
    func activeCategories(forTopURL topURL: URL?) -> Set<ContentBlockingCategory> {
        if ContentBlockingRules.isAllowed(topURL, allowedSites: allowedSites)
            || ContentBlockingRules.isSignInPage(topURL) {
            return []
        }
        return enabledCategories
    }
}

/// How the browser bar describes blocking on the current page.
enum ContentBlockingStatus: Equatable {
    /// Both switches are off in Settings.
    case off
    /// Ads and/or trackers are blocked on this page.
    case blocking(ads: Bool, trackers: Bool)
    /// The user allowed ads on this host.
    case allowedSite(host: String)
    /// A sign-in page: blocking is paused so logins keep working.
    case signInPage

    static func make(policy: ContentBlockingPolicy, url: URL?) -> ContentBlockingStatus {
        guard !policy.enabledCategories.isEmpty else { return .off }
        if ContentBlockingRules.isAllowed(url, allowedSites: policy.allowedSites),
           let host = url?.host.flatMap(ContentBlockingRules.normalizedHost) {
            return .allowedSite(host: host)
        }
        if ContentBlockingRules.isSignInPage(url) { return .signInPage }
        return .blocking(ads: policy.blockAds, trackers: policy.blockTrackers)
    }
}

// MARK: - Library (lookup / compile, shared by every web view)

/// Loads the bundled lists into compiled `WKContentRuleList`s once per process.
@MainActor
final class ContentRuleLibrary: ObservableObject {
    struct LoadedList {
        let entry: ContentBlockingManifest.List
        let category: ContentBlockingCategory
        let identifier: String
        let ruleList: WKContentRuleList
        /// Position in the manifest (lists attach in manifest order).
        let order: Int
    }

    enum Phase: Equatable {
        case idle
        /// Looking up already-compiled lists.
        case lookingUp
        /// Compiling missing lists (first launch or after an update).
        case compiling
        case ready
        /// No bundled lists (or an unreadable manifest).
        case unavailable
    }

    static let shared = ContentRuleLibrary(
        store: WKContentRuleListStore.default(),
        directory: Bundle.main.url(forResource: "ContentBlocking", withExtension: nil)
    )
    private static let log = Logger(subsystem: AppIdentity.identifierPrefix, category: "contentBlocking")

    @Published private(set) var manifest: ContentBlockingManifest?
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var lists: [LoadedList] = []
    /// Chunks that failed to compile (logged and skipped).
    @Published private(set) var failedIdentifiers: [String] = []
    /// Seconds the last compile pass took (nil when nothing was compiled).
    private(set) var lastCompileDuration: TimeInterval?
    /// Chunks compiled by this launch (empty on a relaunch: lookups only).
    private(set) var compiledIdentifiers: [String] = []

    private let store: WKContentRuleListStore?
    private let directory: URL?
    private var lookupWaiters: [CheckedContinuation<Void, Never>] = []
    private var observers: [UUID: @MainActor () -> Void] = [:]
    private var startTask: Task<Void, Never>?

    init(store: WKContentRuleListStore?, directory: URL?) {
        self.store = store
        self.directory = directory
    }

    /// Nothing left to wait for before a page load: true while idle too
    /// (blocking is off and the lists were never started; `start()` moves to
    /// `.lookingUp` synchronously, so a load right after it still waits).
    var lookupsFinished: Bool {
        switch phase {
        case .lookingUp: false
        case .idle, .compiling, .ready, .unavailable: true
        }
    }

    /// Chunks still being compiled.
    var isPreparing: Bool { phase == .lookingUp || phase == .compiling }

    /// Calls `handler` whenever a list becomes ready; keep the token.
    func observe(_ handler: @escaping @MainActor () -> Void) -> ObservationToken {
        let id = UUID()
        observers[id] = handler
        return ObservationToken { [weak self] in
            Task { @MainActor in self?.observers[id] = nil }
        }
    }

    /// Reads the manifest only (Settings shows the lists' date) without
    /// looking up or compiling anything.
    func loadManifestIfNeeded() {
        guard manifest == nil, let directory else { return }
        manifest = ContentBlockingManifest.load(from: directory)
    }

    /// Starts lookups and compilation (idempotent). Called only once blocking
    /// is on: with ads and trackers both off nothing is looked up or compiled.
    func start() {
        guard phase == .idle else { return }
        guard let store, let directory,
              let manifest = ContentBlockingManifest.load(from: directory)
        else {
            phase = .unavailable
            resumeLookupWaiters()
            if directory != nil {
                Self.log.error("Content blocking: manifest missing or unreadable")
            }
            return
        }
        self.manifest = manifest
        phase = .lookingUp
        startTask = Task { [weak self] in
            await self?.run(manifest: manifest, store: store, directory: directory)
        }
    }

    /// Waits until the lookups finish (compiled lists attached), at most `timeout`.
    func waitForLookups(timeout: Duration) async {
        guard !lookupsFinished else { return }
        let timer = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            self?.resumeLookupWaiters()
        }
        await withCheckedContinuation { continuation in
            if lookupsFinished { continuation.resume() } else { lookupWaiters.append(continuation) }
        }
        timer.cancel()
    }

    /// Waits for every chunk to be looked up or compiled (tests, QA).
    func waitUntilReady() async {
        await startTask?.value
    }

    private func resumeLookupWaiters() {
        let waiters = lookupWaiters
        lookupWaiters = []
        waiters.forEach { $0.resume() }
    }

    private func run(manifest: ContentBlockingManifest, store: WKContentRuleListStore, directory: URL) async {
        let entries = manifest.lists.enumerated().compactMap { index, entry -> (Int, ContentBlockingManifest.List, ContentBlockingCategory)? in
            guard let category = entry.knownCategory else {
                Self.log.notice("Content blocking: skipping \(entry.identifier, privacy: .public) (category \(entry.category, privacy: .public))")
                return nil
            }
            return (index, entry, category)
        }

        // 1. Lookups: relaunches attach everything straight away.
        var missing: [(Int, ContentBlockingManifest.List, ContentBlockingCategory)] = []
        for (index, entry, category) in entries {
            let identifier = ContentBlockingRules.identifier(for: entry, manifestVersion: manifest.version)
            if let list = await Self.lookUp(identifier, in: store) {
                add(LoadedList(entry: entry, category: category, identifier: identifier, ruleList: list, order: index))
            } else {
                missing.append((index, entry, category))
            }
        }
        phase = missing.isEmpty ? .ready : .compiling
        resumeLookupWaiters()

        // 2. Compile what is missing, one chunk at a time (memory), each
        //    attached as soon as it is ready.
        if !missing.isEmpty {
            let started = Date()
            for (index, entry, category) in missing {
                let identifier = ContentBlockingRules.identifier(for: entry, manifestVersion: manifest.version)
                let fileURL = directory.appendingPathComponent(entry.file)
                let chunkStart = Date()
                guard let source = await Self.readChunk(fileURL) else {
                    Self.log.error("Content blocking: cannot read \(entry.file, privacy: .public)")
                    failedIdentifiers.append(identifier)
                    continue
                }
                do {
                    let list = try await Self.compile(identifier, source: source, in: store)
                    add(LoadedList(entry: entry, category: category, identifier: identifier, ruleList: list, order: index))
                    compiledIdentifiers.append(identifier)
                    Self.log.notice(
                        "Content blocking: compiled \(entry.identifier, privacy: .public) (\(entry.ruleCount ?? -1) rules) in \(Date().timeIntervalSince(chunkStart), format: .fixed(precision: 2)) s"
                    )
                } catch {
                    failedIdentifiers.append(identifier)
                    Self.log.error(
                        "Content blocking: \(entry.identifier, privacy: .public) failed to compile: \(error.localizedDescription, privacy: .public)"
                    )
                }
            }
            lastCompileDuration = Date().timeIntervalSince(started)
            phase = .ready
        }

        // 3. Remove lists compiled for older manifests or exceptions.
        await removeStaleLists(keeping: Set(entries.map {
            ContentBlockingRules.identifier(for: $0.1, manifestVersion: manifest.version)
        }), in: store)
    }

    private func add(_ list: LoadedList) {
        lists.append(list)
        lists.sort { $0.order < $1.order }
        for observer in observers.values { observer() }
    }

    private func removeStaleLists(keeping current: Set<String>, in store: WKContentRuleListStore) async {
        let available = await Self.availableIdentifiers(in: store)
        for identifier in available
        where identifier.hasPrefix(ContentBlockingRules.identifierPrefix) && !current.contains(identifier) {
            await Self.remove(identifier, from: store)
            Self.log.notice("Content blocking: removed stale \(identifier, privacy: .public)")
        }
    }

    // MARK: Store wrappers

    static func lookUp(_ identifier: String, in store: WKContentRuleListStore) async -> WKContentRuleList? {
        await withCheckedContinuation { continuation in
            store.lookUpContentRuleList(forIdentifier: identifier) { list, _ in
                continuation.resume(returning: list)
            }
        }
    }

    static func compile(_ identifier: String, source: String, in store: WKContentRuleListStore) async throws -> WKContentRuleList {
        try await withCheckedThrowingContinuation { continuation in
            store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: source) { list, error in
                if let list {
                    continuation.resume(returning: list)
                } else {
                    continuation.resume(throwing: error ?? CocoaError(.fileReadCorruptFile))
                }
            }
        }
    }

    static func availableIdentifiers(in store: WKContentRuleListStore) async -> [String] {
        await withCheckedContinuation { continuation in
            store.getAvailableContentRuleListIdentifiers { identifiers in
                continuation.resume(returning: identifiers ?? [])
            }
        }
    }

    static func remove(_ identifier: String, from store: WKContentRuleListStore) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            store.removeContentRuleList(forIdentifier: identifier) { _ in
                continuation.resume()
            }
        }
    }

    /// Reads a chunk and appends the exceptions tail, off the main thread.
    private static func readChunk(_ url: URL) async -> String? {
        await Task.detached(priority: .utility) {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            return ContentBlockingRules.appendingExceptions(to: text)
        }.value
    }
}

/// Cancels an observation when released.
final class ObservationToken {
    private let cancel: () -> Void
    init(_ cancel: @escaping () -> Void) { self.cancel = cancel }
    deinit { cancel() }
}

// MARK: - Per-web-view blocker

/// Keeps one `WKUserContentController`'s rule lists in line with the policy
/// and the page shown in the main frame.
@MainActor
final class ContentBlocker {
    let library: ContentRuleLibrary
    private weak var controller: WKUserContentController?
    /// Lists currently added to the controller, by identifier.
    private(set) var installed: [String: WKContentRuleList] = [:]
    private var token: ObservationToken?
    /// The main page the lists were last applied for.
    private(set) var topURL: URL?

    var policy = ContentBlockingPolicy() {
        didSet { if policy != oldValue { apply() } }
    }

    /// `library` nil: the shared one (a default argument can't name the
    /// main-actor `shared` — defaults are evaluated outside the actor).
    init(controller: WKUserContentController, library: ContentRuleLibrary? = nil) {
        let library = library ?? .shared
        self.controller = controller
        self.library = library
        token = library.observe { [weak self] in self?.apply() }
    }

    /// Call before allowing a main-frame navigation to `url`: the lists for
    /// that page are in place before its requests start.
    func prepare(forTopURL url: URL?) {
        topURL = url
        apply()
    }

    var activeCategories: Set<ContentBlockingCategory> {
        policy.activeCategories(forTopURL: topURL)
    }

    /// Adds and removes lists so exactly the ones for the active categories
    /// are installed, in manifest order.
    func apply() {
        guard let controller else { return }
        let active = activeCategories
        let desired = library.lists.filter { active.contains($0.category) }
        let desiredIDs = Set(desired.map(\.identifier))
        for (identifier, list) in installed where !desiredIDs.contains(identifier) {
            controller.remove(list)
            installed[identifier] = nil
        }
        for list in desired where installed[list.identifier] == nil {
            controller.add(list.ruleList)
            installed[list.identifier] = list.ruleList
        }
    }
}
