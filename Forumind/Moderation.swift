import Foundation

// Moderation for content shown from forums (App Store guideline 1.2):
//
// - Terms of Use the user accepts before using the app (`ModerationTerms`).
// - Report: a prefilled email to the developer about a topic, post or user
//   (`ModerationReport`).
// - Block: per forum, by username. Blocked users' posts are hidden in the
//   browser and left out of everything sent to the AI.
// - Filter: words or phrases; matching posts are hidden the same way.
// - The developer's own list (`RemoteModerationList`), published in the
//   public repository and fetched by every copy of the app, so reported
//   content can be removed for all users.

/// A user blocked on one forum.
struct BlockedUser: Codable, Hashable, Identifiable {
    /// Site URL as `ForumSite.normalizeSiteURL` returns it.
    var siteURL: String
    var username: String
    var blockedAt = Date()

    var id: String { "\(siteURL)|\(username.lowercased())" }

    func matches(siteURL: String, username: String) -> Bool {
        self.siteURL == siteURL && self.username.caseInsensitiveCompare(username) == .orderedSame
    }
}

enum ModerationTerms {
    /// Bump when the terms change materially; everyone accepts again.
    static let currentVersion = 1
    static let url = URL(string: "https://github.com/kccarlos/forumind/blob/main/TERMS.md")!
    /// The app's privacy policy (Settings › Data & privacy).
    static let privacyURL = URL(string: "https://github.com/kccarlos/forumind/blob/main/PRIVACY.md")!
    /// Receives content reports. Reports are reviewed within 24 hours.
    static let reportEmail = "kccarlos.opensource@gmail.com"
}

/// What hides content: the user's blocks and words plus the developer's list.
struct ModerationRules: Equatable {
    /// Lowercased usernames per site URL.
    var blockedUsers: [String: Set<String>] = [:]
    /// Lowercased words and phrases.
    var filteredWords: [String] = []
    /// Lowercased usernames hidden on every forum by the developer's list.
    var globallyHiddenUsers: Set<String> = []
    /// Post numbers hidden per "siteURL|topicID".
    var hiddenPosts: [String: Set<Int>] = [:]

    static let none = ModerationRules()

    init(
        blockedUsers: [String: Set<String>] = [:],
        filteredWords: [String] = [],
        globallyHiddenUsers: Set<String> = [],
        hiddenPosts: [String: Set<Int>] = [:]
    ) {
        self.blockedUsers = blockedUsers
        self.filteredWords = filteredWords
        self.globallyHiddenUsers = globallyHiddenUsers
        self.hiddenPosts = hiddenPosts
    }

    init(settings: AppSettings, remote: RemoteModerationList?) {
        for user in settings.blockedUsers {
            blockedUsers[user.siteURL, default: []].insert(user.username.lowercased())
        }
        filteredWords = Self.normalizedWords(settings.filteredWords + (remote?.words ?? []))
        for entry in remote?.users ?? [] {
            let name = entry.username.lowercased()
            if let site = entry.site.flatMap(ForumSite.normalizeSiteURL) {
                blockedUsers[site, default: []].insert(name)
            } else {
                globallyHiddenUsers.insert(name)
            }
        }
        for entry in remote?.posts ?? [] {
            guard let site = ForumSite.normalizeSiteURL(entry.site) else { continue }
            hiddenPosts["\(site)|\(entry.topic)", default: []].insert(entry.post)
        }
    }

    static func normalizedWords(_ words: [String]) -> [String] {
        var seen = Set<String>()
        return words
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    func hidesUser(_ username: String, siteURL: String) -> Bool {
        let name = username.lowercased()
        return globallyHiddenUsers.contains(name) || blockedUsers[siteURL]?.contains(name) == true
    }

    func hidesText(_ text: String) -> Bool {
        guard !filteredWords.isEmpty else { return false }
        let lowered = text.lowercased()
        return filteredWords.contains { lowered.contains($0) }
    }

    func hidesPost(_ number: Int, siteURL: String, topicID: String) -> Bool {
        hiddenPosts["\(siteURL)|\(topicID)"]?.contains(number) == true
    }

    var isEmpty: Bool {
        blockedUsers.isEmpty && filteredWords.isEmpty && globallyHiddenUsers.isEmpty && hiddenPosts.isEmpty
    }
}

/// Removes hidden posts from Discourse's `/raw` topic text, the source of
/// summaries, chat and Ask the forum. Each post there starts with a
/// `username | 2024-01-01 12:00:00 UTC | #N` line.
enum ModerationFilter {
    static func filter(_ raw: String, siteURL: String, topicID: String, rules: ModerationRules) -> String {
        guard !rules.isEmpty, !raw.isEmpty else { return raw }
        let text = raw as NSString
        let headers = RawTopicFormat.parseHeaders(raw)
        guard !headers.isEmpty else {
            // Not /raw text: hide it all only if a filtered word appears.
            return rules.hidesText(raw) ? "" : raw
        }
        var kept = ""
        // Text before the first post (rare) is kept as is.
        kept += text.substring(to: headers[0].range.location)
        var removedAny = false
        for (index, header) in headers.enumerated() {
            let end = index + 1 < headers.count ? headers[index + 1].range.location : text.length
            let block = text.substring(with: NSRange(location: header.range.location, length: end - header.range.location))
            if rules.hidesUser(header.author, siteURL: siteURL)
                || rules.hidesPost(header.number, siteURL: siteURL, topicID: topicID)
                || rules.hidesText(block)
            {
                removedAny = true
                continue
            }
            kept += block
        }
        return removedAny ? kept : raw
    }
}

/// The developer's moderation list, published in the public repository
/// (`moderation/blocklist.json`) and fetched at most once a day. Content
/// reported by users is added here to remove it for everyone.
struct RemoteModerationList: Codable, Equatable {
    struct User: Codable, Equatable {
        /// A site URL, or nil for every forum.
        var site: String?
        var username: String
    }

    struct Post: Codable, Equatable {
        var site: String
        var topic: Int
        var post: Int
    }

    var version = 1
    var users: [User] = []
    var posts: [Post] = []
    var words: [String] = []

    static let url = URL(string: "https://raw.githubusercontent.com/kccarlos/forumind/main/moderation/blocklist.json")!
    static let refreshInterval: TimeInterval = 24 * 60 * 60

    private enum CodingKeys: String, CodingKey { case version, users, posts, words }

    init(users: [User] = [], posts: [Post] = [], words: [String] = []) {
        self.users = users
        self.posts = posts
        self.words = words
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        users = try container.decodeIfPresent([User].self, forKey: .users) ?? []
        posts = try container.decodeIfPresent([Post].self, forKey: .posts) ?? []
        words = try container.decodeIfPresent([String].self, forKey: .words) ?? []
    }

    /// Downloads the list. Sends nothing about the user: a plain GET of a
    /// public file.
    static func fetch(session: URLSession = .shared) async throws -> RemoteModerationList {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 30
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw AssistantError.invalidResponse
        }
        return try JSONDecoder().decode(RemoteModerationList.self, from: data)
    }
}

/// The last good copy of the developer's list, kept on this device.
enum RemoteModerationCache {
    private static let listKey = "remoteModerationList"
    private static let dateKey = "remoteModerationFetchedAt"

    static func load(defaults: UserDefaults = .standard) -> RemoteModerationList? {
        guard let data = defaults.data(forKey: listKey) else { return nil }
        return try? JSONDecoder().decode(RemoteModerationList.self, from: data)
    }

    static func lastFetch(defaults: UserDefaults = .standard) -> Date? {
        defaults.object(forKey: dateKey) as? Date
    }

    static func store(_ list: RemoteModerationList, at date: Date = Date(), defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(list) { defaults.set(data, forKey: listKey) }
        defaults.set(date, forKey: dateKey)
    }
}

/// A post the browser shows, as the report sheet lists it.
struct VisiblePost: Codable, Equatable, Identifiable {
    var number: Int
    var username: String
    var excerpt: String

    var id: Int { number }
}

/// Text the AI wrote that someone reports (App Review 1.2).
struct AIOutput: Equatable {
    enum Feature: String {
        case summary
        case chatAnswer = "chat answer"
        case askAnswer = "Ask the forum answer"
    }

    var feature: Feature
    /// "Provider · model", as the app shows it.
    var model: String
    var text: String
    /// Ask the forum: the question it answered.
    var question: String?

    /// How much of the text goes in the report email.
    static let reportTextLimit = 4_000
}

/// What a report is about.
struct ReportTarget: Identifiable, Equatable {
    enum Kind: Equatable {
        case topic
        case post(number: Int, username: String)
        case user(username: String)
        case aiOutput(AIOutput)
    }

    var siteURL: String
    var forumName: String
    var topicTitle: String
    var topicURL: URL?
    var kind: Kind

    var id: String {
        switch kind {
        case .topic: "topic|\(topicURL?.absoluteString ?? siteURL)"
        case .post(let number, _): "post|\(topicURL?.absoluteString ?? siteURL)|\(number)"
        case .user(let username): "user|\(siteURL)|\(username)"
        case .aiOutput(let output): "ai|\(topicURL?.absoluteString ?? siteURL)|\(output.feature.rawValue)|\(output.text.hashValue)"
        }
    }
}

enum ReportReason: String, CaseIterable, Identifiable {
    case spam
    case harassment
    case hate
    case sexual
    case violence
    case illegal
    /// AI output only.
    case inaccurate
    case other

    var id: String { rawValue }

    /// The reasons offered for `kind`, the likeliest first.
    static func reasons(for kind: ReportTarget.Kind) -> [ReportReason] {
        if case .aiOutput = kind { return [.inaccurate, .harassment, .hate, .sexual, .violence, .illegal, .other] }
        return allCases.filter { $0 != .inaccurate }
    }

    var title: String {
        switch self {
        case .spam: String(localized: "Spam or scam", comment: "Content report reason")
        case .harassment: String(localized: "Harassment or bullying", comment: "Content report reason")
        case .hate: String(localized: "Hate speech", comment: "Content report reason")
        case .sexual: String(localized: "Sexual content", comment: "Content report reason")
        case .violence: String(localized: "Violence or threats", comment: "Content report reason")
        case .illegal: String(localized: "Illegal content", comment: "Content report reason")
        case .inaccurate: String(localized: "Inaccurate or misleading", comment: "Content report reason for text the AI wrote")
        case .other: String(localized: "Something else", comment: "Content report reason")
        }
    }
}

/// The email a report sends to the developer (English, for the reviewer of
/// the report; the user's own note can be in any language).
enum ModerationReport {
    static func subject(for target: ReportTarget, blocked: Bool) -> String {
        let what: String
        switch target.kind {
        case .topic: what = "topic"
        case .post(let number, let username): what = "post #\(number) by @\(username)"
        case .user(let username): what = "user @\(username)"
        case .aiOutput(let output): what = "AI \(output.feature.rawValue)"
        }
        return "Forumind \(blocked ? "block" : "report"): \(what) on \(ForumSite.host(of: target.siteURL))"
    }

    static func body(
        for target: ReportTarget,
        reason: ReportReason?,
        note: String,
        blocked: Bool,
        links: (any SiteLinks)?,
        appVersion: String = AppVersion.text()
    ) -> String {
        var lines: [String] = []
        lines.append(blocked ? "I blocked this user in Forumind." : "I'm reporting this content in Forumind.")
        lines.append("")
        lines.append("Forum: \(target.forumName) (\(target.siteURL))")
        if !target.topicTitle.isEmpty { lines.append("Topic: \(target.topicTitle)") }
        if let url = target.topicURL { lines.append("Topic URL: \(url.absoluteString)") }
        switch target.kind {
        case .topic:
            break
        case .post(let number, let username):
            if let url = target.topicURL, let links {
                lines.append("Post URL: \(links.postURL(topicURL: url, number: number, anchor: nil).absoluteString)")
            }
            lines.append("Post: #\(number) by @\(username)")
        case .user(let username):
            lines.append("User: @\(username)")
        case .aiOutput(let output):
            if let question = output.question { lines.append("Question: \(question)") }
            lines.append("AI output: \(output.feature.rawValue)")
            lines.append("Model: \(output.model)")
        }
        if let reason { lines.append("Reason: \(reason.rawValue)") }
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            lines.append("")
            lines.append("Details:")
            lines.append(trimmed)
        }
        if case .aiOutput(let output) = target.kind {
            let text = output.text.trimmingCharacters(in: .whitespacesAndNewlines)
            lines.append("")
            lines.append("AI text:")
            lines.append(text.count > AIOutput.reportTextLimit ? String(text.prefix(AIOutput.reportTextLimit)) + " […]" : text)
        }
        lines.append("")
        lines.append("App version: \(appVersion)")
        return lines.joined(separator: "\n")
    }

    /// `links` are the target forum's (nil without an adapter: no post link).
    static func draft(for target: ReportTarget, reason: ReportReason?, note: String, blocked: Bool, links: (any SiteLinks)?) -> MailDraft {
        MailDraft(
            subject: subject(for: target, blocked: blocked),
            body: body(for: target, reason: reason, note: note, blocked: blocked, links: links)
        )
    }

    static func mailtoURL(subject: String, body: String) -> URL? {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = ModerationTerms.reportEmail
        components.queryItems = [
            URLQueryItem(name: "subject", value: subject),
            URLQueryItem(name: "body", value: body)
        ]
        return components.url
    }
}

/// Hides blocked and filtered posts in the built-in browser: the config the
/// site's moderation script (`window.__forumindModeration`, installed from
/// `PageBridgeProfile.moderationInstaller`) takes.
enum ModerationScript {
    struct Config: Encodable {
        var users: [String]
        var words: [String]
        var posts: [String: [Int]]
    }

    /// The config for pages on `siteURL` (users blocked there or everywhere).
    static func config(rules: ModerationRules, siteURL: String?) -> Config {
        var users = rules.globallyHiddenUsers
        if let siteURL { users.formUnion(rules.blockedUsers[siteURL] ?? []) }
        var posts: [String: [Int]] = [:]
        if let siteURL {
            let prefix = "\(siteURL)|"
            for (key, numbers) in rules.hiddenPosts where key.hasPrefix(prefix) {
                posts[String(key.dropFirst(prefix.count))] = numbers.sorted()
            }
        }
        return Config(users: users.sorted(), words: rules.filteredWords, posts: posts)
    }

    static func json(_ config: Config) -> String {
        guard let data = try? JSONEncoder().encode(config),
              let string = String(data: data, encoding: .utf8)
        else { return #"{"users":[],"words":[],"posts":{}}"# }
        return string
    }

    /// Calls `window.__forumindModeration.update(config)`. The site's installer
    /// (`PageBridgeProfile.moderationInstaller`) runs on every page as a user
    /// script, so the interface is there; a page without one is left alone.
    static func source(config: Config) -> String {
        "if (window.__forumindModeration) window.__forumindModeration.update(\(json(config)));"
    }
}
