import Combine
import Foundation

// MARK: - Post-level browsing (the navigation layer)
//
// What the voice agent's tools will call (`find`, `open`, `move`, `focus`,
// `read`, `research`), usable without voice through the result cards and
// the typed paths (`openLink`):
//
// - `openTopic(_:at:)`         opens a topic at a post, the solution, the last
//                              post, the top posts or the first new post, and
//                              highlights the landing post until the next
//                              navigation
// - `focus(_:)`                one author, the opening poster, the top posts,
//                              a set of posts (highlighted), or clear
// - `find(_:scope:)`           Discourse search on the forum or in the topic;
//                              the hits become the current list and the cards
// - `next()` / `previous()`    along the current list (`browseCursor`)
// - `openCard(_:)`             a card of the current list
// - `back()` / `forward()`     the browser's history
// - `read(post:)`              a post's text: the page first, else posts.json
// - `research(_:)` / `cancelResearch()`  Ask the forum, one at a time; the
//                              sources become the current list
// - `openLink(_:)`             a tapped forum link (Ask the forum, Today)
// - `pageChanges`              page context changes, debounced
//
// AppModel and `browseCursor` own this state; every action returns a
// `BrowseResult` (BrowseCursor.swift). Moderation applies throughout: a post
// hidden by the user's blocks or filters is never opened, listed or read.

/// What `openTopic` opens.
enum BrowseTarget: Equatable {
    /// A topic of the current forum by id.
    case topic(String)
    case listing(ForumTopicListing)
    case item(BrowseItem)
    case url(URL)
}

/// Where `find` searches.
enum BrowseSearchScope: String, Equatable {
    case forum
    case topic
}

/// A resolved topic to open (pure).
struct BrowseTopicRef: Equatable {
    var siteURL: String
    var topicID: String
    var slug: String?
    var title: String?

    var topicKey: String { TopicIdentity.key(siteURL: siteURL, topicID: topicID) }
}

/// Landing URLs (pure, so unit tests pin them).
enum BrowseNavigation {
    struct Plan: Equatable {
        var url: URL
        /// The post it lands on, when known (highlighted).
        var postNumber: Int?
        /// `.noSolution` when the topic has no accepted answer.
        var status: BrowseResult.Status = .opened
    }

    /// Where `landing` goes in a topic. `facts` are needed for `.solution`
    /// (and give `.last` its number); `newSince` is the post count a watched
    /// topic had when the reader last caught up (`.firstNew`).
    static func plan(
        siteURL: String,
        topicID: String,
        slug: String?,
        landing: BrowseLanding,
        facts: ForumTopicFacts?,
        newSince: Int? = nil
    ) -> Plan? {
        guard let topic = ForumSite.topicURL(siteURL: siteURL, topicID: topicID, slug: slug) else { return nil }
        func post(_ number: Int) -> Plan? {
            ForumSite.topicURL(siteURL: siteURL, topicID: topicID, slug: slug, postNumber: number)
                .map { Plan(url: $0, postNumber: number) }
        }
        switch landing {
        case .post(let number):
            return post(max(1, number))
        case .solution:
            if let answer = facts?.acceptedAnswer?.postNumber { return post(answer) }
            return Plan(url: topic, postNumber: nil, status: .noSolution)
        case .last:
            if let highest = facts?.highestPostNumber, highest >= 1 { return post(highest) }
            return Plan(url: topic.appendingPathComponent("last"), postNumber: nil)
        case .top:
            return ForumSite.topicURL(siteURL: siteURL, topicID: topicID, slug: slug, filter: .summary)
                .map { Plan(url: $0, postNumber: nil) }
        case .firstNew:
            if let newSince, let total = facts?.highestPostNumber ?? facts?.postsCount, total > newSince {
                return post(newSince + 1)
            }
            return Plan(url: topic, postNumber: nil)
        }
    }
}

extension AppModel {
    /// Page context changes (new pages, routes, posts on screen), once the
    /// page has settled for `pageChangeDelay`: the voice layer's silent notes.
    var pageChanges: AnyPublisher<PageContext, Never> {
        pageUpdates
            .debounce(for: pageChangeDelay, scheduler: DispatchQueue.main)
            .removeDuplicates()
            .eraseToAnyPublisher()
    }

    // MARK: Topic facts

    /// The topic's title, slug and facts, fetched once per topic (`refresh`
    /// fetches again). Nil when the forum can't be reached.
    func topicOverview(siteURL: String, topicID: String, refresh: Bool = false) async -> ForumTopicOverview? {
        let key = TopicIdentity.key(siteURL: siteURL, topicID: topicID)
        if !refresh, let cached = topicOverviews[key] { return cached }
        let cookies = await browser.cookieHeader(forSite: siteURL)
        guard let overview = try? await forumService.fetchOverview(
            siteURL: siteURL,
            topicID: topicID,
            cookieHeader: cookies,
            resourceLoader: webViewResourceLoader,
            pace: settings.forumRequestPace
        ) else {
            return topicOverviews[key]
        }
        if topicOverviews.count >= 100 { topicOverviews.removeAll() }
        topicOverviews[key] = overview
        if pageContext.topic?.topicKey == key { browser.refreshTopicFacts() }
        return overview
    }

    // MARK: Open

    /// Opens a topic and lands on `landing`, highlighting the landing post
    /// until the next navigation. A post already rendered on the page is
    /// scrolled to; otherwise `/t/slug/id/N` loads and Discourse lands on it.
    /// `includeContent: false` (taps in the UI) skips fetching the post's
    /// text and, unless needed, the topic's facts: no extra request.
    @discardableResult
    func openTopic(_ target: BrowseTarget, at landing: BrowseLanding = .firstNew, includeContent: Bool = true) async -> BrowseResult {
        guard let ref = resolve(target) else {
            return BrowseResult(status: .unavailable, shown: "There is no forum topic to open.")
        }
        if landing == .top { return await focus(.top, in: ref) }

        var overview = topicOverviews[ref.topicKey]
        if landing == .last || (overview == nil && (landing == .solution || includeContent)) {
            overview = await topicOverview(siteURL: ref.siteURL, topicID: ref.topicID, refresh: landing == .last)
        }
        let facts = overview?.facts
        let watched = watchedTopics.first { $0.topicKey == ref.topicKey }
        let newSince = watched.flatMap { $0.newReplies > 0 ? $0.knownPostCount - $0.newReplies : nil }
        guard let plan = BrowseNavigation.plan(
            siteURL: ref.siteURL,
            topicID: ref.topicID,
            slug: ref.slug ?? overview?.slug,
            landing: landing,
            facts: facts,
            newSince: newSince
        ) else {
            return BrowseResult(status: .notFound, shown: "That topic can't be opened.")
        }
        let title = ref.title ?? overview?.title ?? pageContext.topic.flatMap { $0.topicID == ref.topicID ? $0.title : nil }
        guard let number = plan.postNumber else {
            await browser.clearHighlight()
            browser.load(plan.url)
            let shown = plan.status == .noSolution
                ? "\(quoted(title)) has no accepted answer; opened at the top."
                : "Opened \(quoted(title))."
            return BrowseResult(status: plan.status, shown: shown)
        }
        if hidesPost(number, in: ref, username: facts?.posts.first { $0.number == number }?.username) {
            return BrowseResult(status: .hidden, shown: "Post \(number) is hidden by your blocks or filters.")
        }
        switch await show(post: number, in: ref, url: plan.url) {
        case .hidden:
            return BrowseResult(status: .hidden, shown: "Post \(number) is hidden by your blocks or filters.")
        case .shown, .missing, .unavailable:
            break
        }
        guard includeContent else {
            return BrowseResult(status: plan.status, shown: "Opened \(quoted(title)) at post \(number).")
        }
        let post = await postText(number, in: ref, facts: facts)
        if case .hidden = post {
            return BrowseResult(status: .hidden, shown: "Post \(number) is hidden by your blocks or filters.")
        }
        let text = post.text
        let shown = BrowseText.postDescription(
            number: number,
            total: facts?.postsCount ?? facts?.highestPostNumber,
            username: text?.username ?? facts?.posts.first { $0.number == number }?.username,
            acceptedAnswer: facts?.acceptedAnswer?.postNumber
        )
        return BrowseResult(
            status: .opened,
            shown: title.map { "\(quoted($0)): \(shown)" } ?? shown,
            content: text.map(BrowseText.content(of:))
        )
    }

    /// A post of the current topic.
    @discardableResult
    func goToPost(_ number: Int) async -> BrowseResult {
        guard let ref = currentTopicRef else {
            return BrowseResult(status: .unavailable, shown: "No topic is open.")
        }
        return await openTopic(.item(item(post: number, in: ref)), at: .post(number))
    }

    /// Scrolls to a rendered post or loads the topic at it, then marks it.
    private func show(post number: Int, in ref: BrowseTopicRef, url: URL) async -> BrowseScrollOutcome {
        let onPage = pageContext.state == .topic && pageContext.topic?.topicKey == ref.topicKey
        if onPage {
            let outcome = await browser.scrollToPost(number)
            if outcome == .hidden { return .hidden }
            browser.highlightAfterLoad([number], topicID: ref.topicID)
            if outcome == .shown { return .shown }
        } else {
            browser.highlightAfterLoad([number], topicID: ref.topicID)
        }
        browser.load(url)
        return .missing
    }

    // MARK: Focus

    /// Narrows the current topic: one author's posts, the opening poster's,
    /// the top posts (Discourse's own filtered views), or highlights a set of
    /// posts. The focused posts become the current list; `.clear` shows the
    /// whole topic again.
    @discardableResult
    func focus(_ focus: BrowseFocus) async -> BrowseResult {
        guard let ref = currentTopicRef else {
            return BrowseResult(status: .unavailable, shown: "No topic is open.")
        }
        return await self.focus(focus, in: ref)
    }

    private func focus(_ focus: BrowseFocus, in ref: BrowseTopicRef) async -> BrowseResult {
        let overview = await topicOverview(siteURL: ref.siteURL, topicID: ref.topicID)
        let slug = ref.slug ?? overview?.slug
        let title = ref.title ?? overview?.title
        switch focus {
        case .clear:
            await browser.clearHighlight()
            if case .focus = browseCursor.origin { browseCursor.clear() }
            if let current = browser.currentURL, URLComponents(url: current, resolvingAgainstBaseURL: false)?.query != nil,
               let url = pageContext.currentPost.flatMap({
                   ForumSite.topicURL(siteURL: ref.siteURL, topicID: ref.topicID, slug: slug, postNumber: $0)
               }) ?? ForumSite.topicURL(siteURL: ref.siteURL, topicID: ref.topicID, slug: slug) {
                browser.load(url)
            }
            return BrowseResult(status: .focused, shown: "Showing all of \(quoted(title)).")

        case .posts(let numbers):
            let rules = browser.moderationRules
            let wanted = numbers.filter { $0 >= 1 && !rules.hidesPost($0, siteURL: ref.siteURL, topicID: ref.topicID) }
            guard let first = wanted.first else {
                return BrowseResult(status: .notFound, shown: "None of those posts can be shown.")
            }
            let items = wanted.map { item(post: $0, in: ref, facts: overview?.facts) }
            browseCursor.replace(with: items, origin: .focus, current: 0)
            var result = await openTopic(.item(items[0]), at: .post(first))
            // A tour marks every post of the set, not just the first.
            browser.highlightAfterLoad(wanted, topicID: ref.topicID)
            if result.status == .opened {
                result.status = .focused
                result.shown = "\(wanted.count) posts highlighted; at 1 of \(wanted.count). " + result.shown
            }
            return result

        case .user, .op, .top:
            let filter: ForumSite.TopicFilter
            let label: String
            switch focus {
            case .user(let name):
                filter = .username(name)
                label = "posts by \(name)"
            case .op:
                guard let poster = overview?.facts?.openingPoster else {
                    return BrowseResult(status: .unavailable, shown: "The opening poster isn't known.")
                }
                filter = .username(poster)
                label = "posts by the opening poster, \(poster)"
            default:
                filter = .summary
                label = "top posts"
            }
            guard let url = ForumSite.topicURL(siteURL: ref.siteURL, topicID: ref.topicID, slug: slug, filter: filter) else {
                return BrowseResult(status: .notFound, shown: "That topic can't be opened.")
            }
            await browser.clearHighlight()
            browser.load(url)
            // The filtered JSON lists the posts (about the first 20).
            let cookies = await browser.cookieHeader(forSite: ref.siteURL)
            let filtered = try? await forumService.fetchOverview(
                siteURL: ref.siteURL,
                topicID: ref.topicID,
                filter: filter,
                cookieHeader: cookies,
                resourceLoader: webViewResourceLoader,
                pace: settings.forumRequestPace
            )
            let rules = browser.moderationRules
            let posts = (filtered?.facts?.posts ?? []).filter {
                !rules.hidesUser($0.username, siteURL: ref.siteURL)
                    && !rules.hidesPost($0.number, siteURL: ref.siteURL, topicID: ref.topicID)
            }
            let items = posts.map {
                BrowseItem(
                    kind: .post, siteURL: ref.siteURL, topicID: ref.topicID, slug: slug,
                    postNumber: $0.number, title: title ?? "", username: $0.username
                )
            }
            browseCursor.replace(with: items, origin: .focus, current: items.isEmpty ? nil : 0)
            guard let first = posts.first else {
                return BrowseResult(status: .focused, shown: "Showing \(label) in \(quoted(title)).")
            }
            var content: String?
            if let facts = filtered?.facts,
               case .shown(let text) = await postText(first.number, in: ref, facts: facts) {
                content = BrowseText.content(of: text)
            }
            return BrowseResult(
                status: .focused,
                shown: "Showing \(label) in \(quoted(title)): \(posts.count) posts, at post \(first.number).",
                content: content
            )
        }
    }

    // MARK: Find

    /// Discourse search on the current forum, or within the open topic
    /// (`topic:<id>`). The hits (best first) become the current list and
    /// show as cards; none is open until `next` or a tap.
    @discardableResult
    func find(_ query: String, scope: BrowseSearchScope = .forum) async -> BrowseResult {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return BrowseResult(status: .unavailable, shown: "There is nothing to search for.")
        }
        guard let siteURL = pageContext.siteURL ?? currentForum?.siteURL else {
            return BrowseResult(status: .unavailable, shown: "No forum is open.")
        }
        var search = trimmed
        if scope == .topic {
            guard let topic = currentTopicRef else {
                return BrowseResult(status: .unavailable, shown: "No topic is open to search in.")
            }
            search += " topic:\(topic.topicID)"
        }
        let cookies = await browser.cookieHeader(forSite: siteURL)
        let results: (hits: [ForumSearchHit], topics: [ForumTopicListing])
        do {
            results = try await forumService.searchResults(
                siteURL: siteURL,
                query: search,
                cookieHeader: cookies,
                resourceLoader: webViewResourceLoader,
                pace: settings.forumRequestPace
            )
        } catch {
            return BrowseResult(status: .failed, shown: "The search didn't go through: \(error.localizedDescription)")
        }
        let rules = browser.moderationRules
        let hits = results.hits.filter { hit in
            !(hit.username.map { rules.hidesUser($0, siteURL: siteURL) } ?? false)
                && !rules.hidesPost(hit.postNumber, siteURL: siteURL, topicID: hit.topic.topicID)
                && !rules.hidesText(hit.blurb ?? "")
                && !rules.hidesText(hit.topic.title)
        }
        let items = hits.prefix(Self.browseListLimit).map(BrowseItem.init(hit:))
        browseCursor.replace(with: Array(items), origin: .search(trimmed))
        // New cards: bring the bar back so they show expanded.
        browser.expandChrome()
        guard !items.isEmpty else {
            return BrowseResult(status: .noResults, shown: "No results for \(quoted(trimmed)).")
        }
        let scopeText = scope == .topic ? " in this topic" : ""
        return BrowseResult(
            status: .found,
            shown: "\(items.count) results for \(quoted(trimmed))\(scopeText), shown as numbered cards.",
            hits: Self.hits(Array(items))
        )
    }

    /// The most items a current list holds.
    static let browseListLimit = 20

    private static func hits(_ items: [BrowseItem], limit: Int = 10) -> [BrowseResult.Hit] {
        items.prefix(limit).enumerated().map { offset, item in
            BrowseResult.Hit(
                number: offset + 1,
                title: item.title,
                topicID: item.topicID,
                postNumber: item.postNumber,
                username: item.username,
                excerpt: item.excerpt
            )
        }
    }

    // MARK: Move

    /// The next item of the current list (the first after a search).
    @discardableResult
    func next() async -> BrowseResult {
        guard !browseCursor.isEmpty else {
            return BrowseResult(status: .emptyList, shown: "There is no list to move along.")
        }
        guard let item = browseCursor.next() else {
            return BrowseResult(status: .endOfList, shown: "That was the last of \(browseCursor.items.count).")
        }
        return await open(item)
    }

    @discardableResult
    func previous() async -> BrowseResult {
        guard !browseCursor.isEmpty else {
            return BrowseResult(status: .emptyList, shown: "There is no list to move along.")
        }
        guard let item = browseCursor.previous() else {
            return BrowseResult(status: .endOfList, shown: "That is the first of \(browseCursor.items.count).")
        }
        return await open(item)
    }

    /// Card `index` of the current list (a tap).
    @discardableResult
    func openCard(_ index: Int, includeContent: Bool = true) async -> BrowseResult {
        guard let item = browseCursor.select(index) else {
            return BrowseResult(status: .notFound, shown: "There is no card \(index + 1).")
        }
        return await open(item, includeContent: includeContent)
    }

    private func open(_ item: BrowseItem, includeContent: Bool = true) async -> BrowseResult {
        var result: BrowseResult
        let filtered = item.kind == .post && isFilteredView(of: item)
        if filtered, let number = item.postNumber {
            // Inside a focused (filtered) view: stay in it.
            result = await openFiltered(item, number: number)
        } else {
            result = await openTopic(.item(item), at: item.postNumber.map(BrowseLanding.post) ?? .firstNew, includeContent: includeContent)
        }
        if result.status == .opened {
            result.status = .moved
            if let position = browseCursor.positionText { result.shown = "\(position): " + result.shown }
        }
        return result
    }

    private func isFilteredView(of item: BrowseItem) -> Bool {
        guard pageContext.topic?.topicKey == item.topicKey, let url = browser.currentURL else { return false }
        let names = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.map(\.name) ?? []
        return names.contains("username_filters") || names.contains("filter")
    }

    /// A post of a filtered view: scroll there, or load it with the filter kept.
    private func openFiltered(_ item: BrowseItem, number: Int) async -> BrowseResult {
        let ref = BrowseTopicRef(siteURL: item.siteURL, topicID: item.topicID, slug: item.slug, title: item.title)
        let outcome = await browser.scrollToPost(number)
        if outcome == .hidden {
            return BrowseResult(status: .hidden, shown: "Post \(number) is hidden by your blocks or filters.")
        }
        if outcome != .shown, let current = browser.currentURL,
           var components = URLComponents(url: ForumSite.postURL(topicURL: current, number: number), resolvingAgainstBaseURL: false) {
            components.query = URLComponents(url: current, resolvingAgainstBaseURL: false)?.query
            if let url = components.url { browser.load(url) }
        }
        let facts = topicOverviews[ref.topicKey]?.facts
        let post = await postText(number, in: ref, facts: facts)
        let shown = BrowseText.postDescription(
            number: number,
            total: facts?.postsCount,
            username: post.text?.username ?? item.username,
            acceptedAnswer: facts?.acceptedAnswer?.postNumber
        )
        return BrowseResult(status: .opened, shown: shown, content: post.text.map(BrowseText.content(of:)))
    }

    /// The browser's back and forward.
    @discardableResult
    func back() -> BrowseResult {
        guard browser.canGoBack else { return BrowseResult(status: .endOfList, shown: "There is nothing to go back to.") }
        browser.goBack()
        return BrowseResult(status: .moved, shown: "Went back.")
    }

    @discardableResult
    func forward() -> BrowseResult {
        guard browser.canGoForward else { return BrowseResult(status: .endOfList, shown: "There is nothing to go forward to.") }
        browser.goForward()
        return BrowseResult(status: .moved, shown: "Went forward.")
    }

    // MARK: Read

    /// The text of a post of the open topic (default: the current post).
    @discardableResult
    func read(post: Int? = nil) async -> BrowseResult {
        guard let ref = currentTopicRef else {
            return BrowseResult(status: .unavailable, shown: "No topic is open.")
        }
        let number = post ?? pageContext.currentPost ?? 1
        let facts: ForumTopicFacts?
        if let cached = topicOverviews[ref.topicKey]?.facts {
            facts = cached
        } else {
            facts = await topicOverview(siteURL: ref.siteURL, topicID: ref.topicID)?.facts
        }
        switch await postText(number, in: ref, facts: facts) {
        case .shown(let text):
            return BrowseResult(
                status: .read,
                shown: BrowseText.postDescription(
                    number: number,
                    total: facts?.postsCount,
                    username: text.username,
                    acceptedAnswer: facts?.acceptedAnswer?.postNumber
                ),
                content: BrowseText.content(of: text)
            )
        case .hidden:
            return BrowseResult(status: .hidden, shown: "Post \(number) is hidden by your blocks or filters.")
        case .missing:
            return BrowseResult(status: .notFound, shown: "Post \(number) couldn't be read.")
        }
    }

    enum PostTextLookup: Equatable {
        case shown(BrowsePostText)
        case hidden
        case missing

        var text: BrowsePostText? {
            if case .shown(let text) = self { return text }
            return nil
        }
    }

    /// A post's text: from the page when it is rendered there, else from
    /// `/posts.json` (with the topic's facts for the post id). Moderation is
    /// checked again on the text itself.
    func postText(_ number: Int, in ref: BrowseTopicRef, facts: ForumTopicFacts?) async -> PostTextLookup {
        let rules = browser.moderationRules
        if rules.hidesPost(number, siteURL: ref.siteURL, topicID: ref.topicID) { return .hidden }
        var post: BrowsePostText?
        if pageContext.topic?.topicKey == ref.topicKey {
            post = await browser.postText(number)
        }
        if post == nil, let facts {
            let cookies = await browser.cookieHeader(forSite: ref.siteURL)
            post = (try? await forumService.fetchPosts(
                siteURL: ref.siteURL,
                topicID: ref.topicID,
                numbers: [number],
                facts: facts,
                cookieHeader: cookies,
                resourceLoader: webViewResourceLoader,
                pace: settings.forumRequestPace
            ))?.first.map { BrowsePostText(number: $0.number, username: $0.username, text: $0.text) }
        }
        guard let post else { return .missing }
        if rules.hidesUser(post.username, siteURL: ref.siteURL) || rules.hidesText(post.text) { return .hidden }
        return .shown(post)
    }

    // MARK: Research

    /// Runs Ask the forum on the current forum, one at a time: a new request
    /// cancels the running one, which then returns `.cancelled`. On an
    /// answer the sources become the current list and the first opens at its
    /// post. The run's agent never moves the page; this does.
    @discardableResult
    func research(_ request: String, siteURL: String? = nil) async -> BrowseResult {
        researchTask?.cancel()
        researchGeneration += 1
        let generation = researchGeneration
        let forum = siteURL ?? pageContext.siteURL
        let task = Task { @MainActor in try await self.performAgentRun(goal: request, siteURL: forum) }
        researchTask = task
        let outcome: AgentRunOutcome
        do {
            outcome = try await task.value
        } catch {
            guard generation == researchGeneration else {
                return BrowseResult(status: .cancelled, shown: "Replaced by a newer request.")
            }
            researchTask = nil
            return BrowseResult(status: .failed, shown: "The research couldn't start: \(error.localizedDescription)")
        }
        guard generation == researchGeneration else {
            return BrowseResult(status: .cancelled, shown: "Replaced by a newer request.")
        }
        researchTask = nil
        switch outcome.status {
        case .completed:
            break
        case .cancelled:
            return BrowseResult(status: .cancelled, shown: "The research was stopped.")
        default:
            return BrowseResult(status: .failed, shown: "The research failed: \(outcome.error)")
        }
        let runSite = agentRuns.first { $0.id == outcome.runID }?.siteURL ?? forum ?? ""
        let items = sourceItems(outcome.sources, siteURL: runSite)
        browseCursor.replace(with: items, origin: .research(request), current: items.isEmpty ? nil : 0)
        browser.expandChrome()
        guard let first = items.first else {
            return BrowseResult(status: .answered, shown: "Answered without sources to open.", content: outcome.answer)
        }
        let opened = await openTopic(.item(first), at: first.postNumber.map(BrowseLanding.post) ?? .firstNew, includeContent: false)
        let landing = opened.status == .opened ? " Opened source 1 of \(items.count): \(opened.shown)" : ""
        return BrowseResult(
            status: .answered,
            shown: "Answered with \(items.count) sources on the cards.\(landing)",
            content: outcome.answer,
            hits: Self.hits(items)
        )
    }

    /// Stops the running research ("never mind").
    @discardableResult
    func cancelResearch() -> BrowseResult {
        guard let task = researchTask else {
            return BrowseResult(status: .unavailable, shown: "No research is running.")
        }
        researchGeneration += 1
        researchTask = nil
        task.cancel()
        return BrowseResult(status: .cancelled, shown: "The research was stopped.")
    }

    var isResearching: Bool { researchTask != nil }

    /// Agent sources as current-list items, without hidden posts.
    func sourceItems(_ sources: [AgentSources.Source], siteURL: String) -> [BrowseItem] {
        let rules = browser.moderationRules
        return sources.compactMap { BrowseItem(source: $0, siteURL: siteURL) }
            .filter { item in
                !(item.postNumber.map { rules.hidesPost($0, siteURL: siteURL, topicID: item.topicID) } ?? false)
                    && !rules.hidesText(item.title)
            }
            .prefix(Self.browseListLimit)
            .map { $0 }
    }

    // MARK: Typed paths

    /// A forum link tapped in the app (Ask the forum, Today): a post link
    /// opens the topic at that post and highlights it; anything else loads.
    func openLink(_ url: URL) {
        guard let siteURL = siteURL(containing: url),
              let topicID = ForumSite.extractTopicID(from: url, basePath: ForumSite.parse(siteURL: siteURL)?.basePath ?? ""),
              let number = ForumSite.postNumber(from: url)
        else {
            browser.load(url)
            return
        }
        let slug = BrowseItem.slug(of: url, topicID: topicID)
        Task { [weak self] in
            await self?.openTopic(
                .item(BrowseItem(kind: .post, siteURL: siteURL, topicID: topicID, slug: slug, postNumber: number, title: "")),
                at: .post(number),
                includeContent: false
            )
        }
    }

    /// A source tapped in Ask the forum: its run's sources become the
    /// current list, at that source, so the cards and Next follow them.
    func followSources(_ sources: [AgentSources.Source], selecting source: AgentSources.Source, siteURL: String) {
        let items = sourceItems(sources, siteURL: siteURL)
        let index = items.firstIndex { $0.topicID == source.topicID && $0.postNumber == source.postNumber }
        browseCursor.replace(with: items, origin: .sources, current: index)
    }

    // MARK: Cards

    func dismissResultCards() {
        browseCursor.cards = .hidden
    }

    func setResultCardsCollapsed(_ collapsed: Bool) {
        guard !browseCursor.isEmpty else { return }
        browseCursor.cards = collapsed ? .collapsed : .expanded
    }

    // MARK: Helpers

    /// The open topic, when the page is one.
    var currentTopicRef: BrowseTopicRef? {
        guard pageContext.state == .topic, let topic = pageContext.topic else { return nil }
        return BrowseTopicRef(
            siteURL: topic.siteURL,
            topicID: topic.topicID,
            slug: BrowseItem.slug(of: topic.url, topicID: topic.topicID),
            title: topic.title
        )
    }

    func resolve(_ target: BrowseTarget) -> BrowseTopicRef? {
        switch target {
        case .topic(let id):
            guard let siteURL = pageContext.siteURL ?? currentForum?.siteURL else { return nil }
            let digits = id.filter(\.isNumber)
            guard !digits.isEmpty else { return nil }
            let current = currentTopicRef.flatMap { $0.topicID == digits && $0.siteURL == siteURL ? $0 : nil }
            return current ?? BrowseTopicRef(siteURL: siteURL, topicID: digits)
        case .listing(let listing):
            return BrowseTopicRef(siteURL: listing.siteURL, topicID: listing.topicID, slug: listing.slug, title: listing.title)
        case .item(let item):
            return BrowseTopicRef(
                siteURL: item.siteURL,
                topicID: item.topicID,
                slug: item.slug,
                title: item.title.isEmpty ? nil : item.title
            )
        case .url(let url):
            guard let siteURL = siteURL(containing: url),
                  let topicID = ForumSite.extractTopicID(from: url, basePath: ForumSite.parse(siteURL: siteURL)?.basePath ?? "")
            else {
                return nil
            }
            return BrowseTopicRef(siteURL: siteURL, topicID: topicID, slug: BrowseItem.slug(of: url, topicID: topicID))
        }
    }

    private func item(post number: Int, in ref: BrowseTopicRef, facts: ForumTopicFacts? = nil) -> BrowseItem {
        BrowseItem(
            kind: .post,
            siteURL: ref.siteURL,
            topicID: ref.topicID,
            slug: ref.slug,
            postNumber: number,
            title: ref.title ?? "",
            username: facts?.posts.first { $0.number == number }?.username
        )
    }

    private func hidesPost(_ number: Int, in ref: BrowseTopicRef, username: String?) -> Bool {
        let rules = browser.moderationRules
        return rules.hidesPost(number, siteURL: ref.siteURL, topicID: ref.topicID)
            || (username.map { rules.hidesUser($0, siteURL: ref.siteURL) } ?? false)
    }

    private func quoted(_ title: String?) -> String {
        guard let title, !title.isEmpty else { return "the topic" }
        return "“\(title)”"
    }
}

#if DEBUG
extension AppModel {
    /// UI-test hooks for post-level browsing:
    /// - `-dc-browse-post <n>`    once the first topic shows, opens it at post n
    /// - `-dc-browse-find <query>` then searches the forum (cards appear)
    /// - `-dc-browse-debug`       shows the browse state as an accessibility
    ///                            element (ContentView, `browseDebugState`)
    func applyBrowseDebugArguments() {
        let post = AssistantDebug.value("-dc-browse-post").flatMap(Int.init)
        let query = AssistantDebug.value("-dc-browse-find")
        guard post != nil || query != nil else { return }
        Task { @MainActor [weak self] in
            for _ in 0..<240 {
                if self?.pageContext.state == .topic { break }
                try? await Task.sleep(for: .milliseconds(250))
            }
            guard let self, let topic = self.currentTopicRef else { return }
            if let post {
                await self.openTopic(.listing(ForumTopicListing(
                    siteURL: topic.siteURL, id: Int(topic.topicID) ?? 0, title: topic.title ?? "",
                    slug: topic.slug ?? topic.topicID, postsCount: 0
                )), at: .post(post), includeContent: false)
            }
            if let query {
                try? await Task.sleep(for: .seconds(3))
                await self.find(query)
            }
        }
    }
}
#endif
