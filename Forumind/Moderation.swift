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
    private static let header = try! NSRegularExpression(
        pattern: #"^(\S+) \| \d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} UTC \| #(\d+)$"#,
        options: [.anchorsMatchLines]
    )

    static func filter(_ raw: String, siteURL: String, topicID: String, rules: ModerationRules) -> String {
        guard !rules.isEmpty, !raw.isEmpty else { return raw }
        let text = raw as NSString
        let matches = header.matches(in: raw, range: NSRange(location: 0, length: text.length))
        guard !matches.isEmpty else {
            // Not /raw text: hide it all only if a filtered word appears.
            return rules.hidesText(raw) ? "" : raw
        }
        var kept = ""
        // Text before the first post (rare) is kept as is.
        kept += text.substring(to: matches[0].range.location)
        var removedAny = false
        for (index, match) in matches.enumerated() {
            let end = index + 1 < matches.count ? matches[index + 1].range.location : text.length
            let block = text.substring(with: NSRange(location: match.range.location, length: end - match.range.location))
            let username = text.substring(with: match.range(at: 1))
            let number = Int(text.substring(with: match.range(at: 2))) ?? 0
            if rules.hidesUser(username, siteURL: siteURL)
                || rules.hidesPost(number, siteURL: siteURL, topicID: topicID)
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

/// What a report is about.
struct ReportTarget: Identifiable, Equatable {
    enum Kind: Equatable {
        case topic
        case post(number: Int, username: String)
        case user(username: String)
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
    case other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .spam: String(localized: "Spam or scam", comment: "Content report reason")
        case .harassment: String(localized: "Harassment or bullying", comment: "Content report reason")
        case .hate: String(localized: "Hate speech", comment: "Content report reason")
        case .sexual: String(localized: "Sexual content", comment: "Content report reason")
        case .violence: String(localized: "Violence or threats", comment: "Content report reason")
        case .illegal: String(localized: "Illegal content", comment: "Content report reason")
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
        }
        return "Forumind \(blocked ? "block" : "report"): \(what) on \(ForumSite.host(of: target.siteURL))"
    }

    static func body(
        for target: ReportTarget,
        reason: ReportReason?,
        note: String,
        blocked: Bool,
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
            if let url = target.topicURL { lines.append("Post URL: \(postURL(topicURL: url, number: number).absoluteString)") }
            lines.append("Post: #\(number) by @\(username)")
        case .user(let username):
            lines.append("User: @\(username)")
        }
        if let reason { lines.append("Reason: \(reason.rawValue)") }
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            lines.append("")
            lines.append("Details:")
            lines.append(trimmed)
        }
        lines.append("")
        lines.append("App version: \(appVersion)")
        return lines.joined(separator: "\n")
    }

    /// `{topic URL without a post number}/{number}`.
    static func postURL(topicURL: URL, number: Int) -> URL {
        var components = URLComponents(url: topicURL, resolvingAgainstBaseURL: false)
        components?.query = nil
        components?.fragment = nil
        var path = components?.path ?? topicURL.path
        while path.hasSuffix("/") { path.removeLast() }
        // /t/slug/123 or /t/slug/123/45: keep up to the topic ID.
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        if let t = parts.firstIndex(of: "t") {
            let afterT = parts[(t + 1)...]
            let idIndex = afterT.firstIndex { Int($0) != nil }
            if let idIndex {
                path = parts[...idIndex].joined(separator: "/")
            }
        }
        components?.path = "\(path)/\(number)"
        return components?.url ?? topicURL.appendingPathComponent(String(number))
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

/// Hides blocked and filtered posts in the built-in browser. Discourse wraps
/// each post in `[data-post-number]` around `article[id^=post_]`; the author
/// is the first `a[data-user-card]` inside it.
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

    /// Calls `window.__forumindModeration.update(config)`, installing the
    /// observer first if needed.
    static func source(config: Config) -> String {
        "\(installer)\nwindow.__forumindModeration.update(\(json(config)));"
    }

    static let installer = """
    (() => {
      if (window.__forumindModeration) return;
      const state = { users: new Set(), words: [], posts: {} };
      const attr = 'data-forumind-hidden';
      function ensureStyle() {
        if (document.getElementById('forumind-moderation-style')) return;
        const style = document.createElement('style');
        style.id = 'forumind-moderation-style';
        style.textContent = '[' + attr + '] { display: none !important; }';
        (document.head || document.documentElement).appendChild(style);
      }
      function topicID() {
        const match = location.pathname.match(/\\/t\\/(?:[^/]+\\/)?(\\d+)/);
        return match ? match[1] : null;
      }
      let hasHidden = false;
      function apply() {
        ensureStyle();
        const hidden = state.posts[topicID()] || [];
        const active = state.users.size > 0 || state.words.length > 0 || hidden.length > 0;
        if (!active) {
          // Nothing to hide: undo earlier hiding once, then stay idle.
          if (hasHidden) {
            document.querySelectorAll('[' + attr + ']').forEach(element => element.removeAttribute(attr));
            hasHidden = false;
          }
          return;
        }
        hasHidden = true;
        const checksText = state.words.length > 0;
        document.querySelectorAll('article[id^="post_"]').forEach(article => {
          const wrapper = article.closest('[data-post-number]') || article;
          const author = article.querySelector('a[data-user-card]');
          const name = author ? (author.dataset.userCard || '').toLowerCase() : '';
          const number = parseInt(article.id.slice(5), 10);
          const cooked = checksText ? article.querySelector('.cooked') : null;
          // textContent: no layout pass on every page change.
          const text = cooked ? cooked.textContent.toLowerCase() : '';
          const hide = (name && state.users.has(name))
            || hidden.includes(number)
            || (text && state.words.some(word => text.includes(word)));
          if (hide) wrapper.setAttribute(attr, '');
          else wrapper.removeAttribute(attr);
        });
        // Topic lists: topics started by a hidden user.
        document.querySelectorAll('.topic-list-item').forEach(row => {
          const starter = row.querySelector('.posters a[data-user-card]');
          const name = starter ? (starter.dataset.userCard || '').toLowerCase() : '';
          if (name && state.users.has(name)) row.setAttribute(attr, '');
          else row.removeAttribute(attr);
        });
      }
      let scheduled = false;
      function schedule() {
        if (scheduled) return;
        scheduled = true;
        requestAnimationFrame(() => { scheduled = false; apply(); });
      }
      function start() {
        new MutationObserver(schedule).observe(document.documentElement, { childList: true, subtree: true });
        schedule();
      }
      window.__forumindModeration = {
        update(config) {
          state.users = new Set((config.users || []).map(name => name.toLowerCase()));
          state.words = (config.words || []).map(word => word.toLowerCase());
          state.posts = config.posts || {};
          schedule();
        },
        // The posts on screen, for the report sheet.
        posts() {
          return Array.from(document.querySelectorAll('article[id^="post_"]'))
            .filter(article => !(article.closest('[data-post-number]') || article).hasAttribute(attr))
            .map(article => {
              const author = article.querySelector('a[data-user-card]');
              const cooked = article.querySelector('.cooked');
              return {
                number: parseInt(article.id.slice(5), 10),
                username: author ? (author.dataset.userCard || '') : '',
                excerpt: cooked ? cooked.innerText.replace(/\\s+/g, ' ').trim().slice(0, 160) : ''
              };
            })
            .filter(post => post.username && post.number > 0);
        }
      };
      if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', start);
      else start();
    })();
    """
}
