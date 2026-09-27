import Combine
import OSLog
import SwiftUI
import WebKit

/// The embedded browser. Any http(s) page can be opened (so shared links
/// always open); after each navigation an in-page probe decides whether the
/// page is a Discourse forum and publishes `pageContext`.
///
/// API used by the UI:
/// - `pageContext` — current page (url, isDiscourse, siteURL, forumName,
///   iconURL, topic?, state: loading/notForum/maybe/forumHome/topic).
/// - `homeSiteURL` — the current forum (last Discourse forum shown).
/// - `load(_:)`, `open(address:)`, `loadHome()` (false with no forum),
///   `loadLogin()`, back/forward/reload/stop.
/// - `contentBlocker` — built-in ad/tracker blocking (ContentBlocker.swift);
///   its lists follow each main-frame navigation.
@MainActor
final class ForumBrowserModel: NSObject, ObservableObject {
    private static let routeMessageName = "dcRouteChanged"
    /// Serialized into both the route observer and the post-load probe: the
    /// tags Discourse renders server-side.
    private static let probeFunction = """
    () => {
      const metaContent = selector => {
        const content = document.querySelector(selector)?.getAttribute("content");
        return typeof content === "string" ? content.trim() : "";
      };
      const generator = metaContent('meta[name="generator"]');
      const baseUriMeta = document.querySelector('meta[name="discourse-base-uri"]');
      const setup = document.getElementById("data-discourse-setup");
      const icon = document.querySelector(
        'link[rel="apple-touch-icon"], link[rel="apple-touch-icon-precomposed"]'
      ) || document.querySelector('link[rel~="icon"]');
      return {
        url: window.location.href,
        isDiscourse: /\\bDiscourse\\b/i.test(generator) || Boolean(baseUriMeta) || Boolean(setup),
        basePath: setup?.dataset?.baseUri || baseUriMeta?.getAttribute("content") || "",
        forumName: metaContent('meta[property="og:site_name"]'),
        iconURL: icon?.href || ""
      };
    }
    """
    private static let routeObserverScript = """
    (() => {
      if (window.__dcRouteObserverInstalled) return;
      window.__dcRouteObserverInstalled = true;

      const probe = \(probeFunction);
      let notificationTimer;
      const isAuthenticated = () => {
        const root = document.documentElement;
        const body = document.body;
        return Boolean(
          root?.classList?.contains("logged-in") ||
          body?.classList?.contains("logged-in") ||
          document.querySelector(".current-user, [data-current-user]")
        );
      };
      const publishRoute = () => {
        window.webkit?.messageHandlers?.dcRouteChanged?.postMessage({
          url: window.location.href,
          title: document.title || "",
          authenticated: isAuthenticated(),
          // The head is not parsed yet while loading; probing then would
          // report every page as "not Discourse".
          probe: document.readyState === "loading" ? null : probe()
        });
      };
      const scheduleRoutePublish = () => {
        window.clearTimeout(notificationTimer);
        notificationTimer = window.setTimeout(publishRoute, 0);
      };

      for (const methodName of ["pushState", "replaceState"]) {
        const original = window.history[methodName];
        window.history[methodName] = function(...argumentsList) {
          const result = original.apply(this, argumentsList);
          scheduleRoutePublish();
          return result;
        };
      }

      window.addEventListener("popstate", scheduleRoutePublish);
      window.addEventListener("hashchange", scheduleRoutePublish);
      window.addEventListener("pageshow", scheduleRoutePublish);

      const observeTitle = () => {
        if (!document.head) return;
        new MutationObserver(scheduleRoutePublish).observe(document.head, {
          childList: true,
          subtree: true,
          characterData: true
        });
      };
      const observeAuthentication = () => {
        const targets = [document.documentElement, document.body]
          .filter(Boolean);
        const observer = new MutationObserver(scheduleRoutePublish);
        for (const target of targets) {
          observer.observe(target, {
            attributes: true,
            attributeFilter: ["class"]
          });
        }
      };
      if (document.readyState === "loading") {
        document.addEventListener("DOMContentLoaded", () => {
          observeTitle();
          observeAuthentication();
          scheduleRoutePublish();
        }, { once: true });
      } else {
        observeTitle();
        observeAuthentication();
      }
      scheduleRoutePublish();
    })();
    """

    static let defaultPageTitle = "Forumind"

    @Published private(set) var currentURL: URL?
    @Published private(set) var pageTitle = ForumBrowserModel.defaultPageTitle
    @Published private(set) var isLoading = false
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published private(set) var isAuthenticated = false
    /// Safari-style chrome: scrolling down the page minimizes the browser bar,
    /// scrolling back up (or reaching the top) restores it.
    @Published private(set) var isChromeMinimized = false
    /// What the assistant knows about the current page.
    @Published private(set) var pageContext = PageContext.empty
    /// The current forum: the last Discourse forum shown (or opened by the app).
    /// Home and relative addresses resolve against it.
    @Published var homeSiteURL: String?
    /// Page load progress (0…1) from WKWebView, for the bar's progress line.
    @Published private(set) var estimatedProgress: Double = 0
    /// The Forums home is requested over the current page (the browser bar's
    /// Forums button). Any navigation clears it.
    @Published private(set) var isForumsHomeRequested = false
    /// The page's web content process quit repeatedly; auto-reload paused
    /// and the page shows a small Reload banner.
    @Published private(set) var showsCrashNotice = false
    /// When the web content process last quit (auto-reload once per window).
    private var contentTerminations: [Date] = []
    /// One automatic reload per this many seconds; a second crash inside it
    /// shows the banner instead (no reload loop).
    nonisolated static let crashReloadWindow: TimeInterval = 30
    private static let log = Logger(subsystem: AppIdentity.identifierPrefix, category: "browser")

    /// The Forums home is shown instead of the web view: requested, or no
    /// page has been loaded yet.
    var showsForumsHome: Bool { isForumsHomeRequested || currentURL == nil }

    func showForumsHome() {
        if !isForumsHomeRequested { isForumsHomeRequested = true }
    }

    /// Returns to the page under the Forums home (no-op without one).
    func hideForumsHome() {
        if isForumsHomeRequested { isForumsHomeRequested = false }
    }

    let webView: WKWebView
    /// Ad and tracker blocking for this web view.
    let contentBlocker: ContentBlocker
    /// A load issued while the compiled rule lists are still being looked up
    /// (launch); it starts when they are attached, or after a short cap.
    private var deferredLoad: URL?
    /// The longest a load waits for rule-list lookups (never for compiling).
    static let ruleLookupWait: Duration = .milliseconds(300)
    /// Called whenever `pageContext` changes.
    var onPageContextChanged: ((PageContext) -> Void)?
    /// Directory lookup: pages on a known forum count as Discourse before the
    /// probe reports.
    var knownForumLookup: ((URL) -> KnownForumSite?)?
    private var lastProbe: PageProbe?
    private let routeMessageHandler = ForumRouteMessageHandler()
    private var scrollObservation: NSKeyValueObservation?
    private var progressObservation: NSKeyValueObservation?
    private var lastScrollOffset: CGFloat = 0
    private var wasTracking = false
    /// Fires when the user starts scrolling the page (once per drag), so the
    /// workspace knows the page is where they are working.
    let userInteraction = PassthroughSubject<Void, Never>()
    private var scrollTravel: CGFloat = 0
    private static let chromeToggleTravel: CGFloat = 36

    /// `contentRules` nil: the shared library (see `ContentBlocker.init`).
    init(contentRules: ContentRuleLibrary? = nil) {
        let contentRules = contentRules ?? .shared
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences.isElementFullscreenEnabled = true
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: Self.routeObserverScript,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
        )

        webView = WKWebView(frame: .zero, configuration: configuration)
        contentBlocker = ContentBlocker(
            controller: configuration.userContentController,
            library: contentRules
        )
        super.init()
        routeMessageHandler.browser = self
        configuration.userContentController.add(
            routeMessageHandler,
            name: Self.routeMessageName
        )
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsLinkPreview = true
        webView.scrollView.keyboardDismissMode = .interactive
        scrollObservation = webView.scrollView.observe(\.contentOffset, options: [.new]) {
            [weak self] scrollView, _ in
            Task { @MainActor [weak self] in
                self?.handleScroll(scrollView)
            }
        }
        progressObservation = webView.observe(\.estimatedProgress, options: [.new]) {
            [weak self] webView, _ in
            let progress = webView.estimatedProgress
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Coalesce tiny steps so the bar does not re-render constantly.
                if abs(progress - self.estimatedProgress) >= 0.02 || progress >= 1 || progress == 0 {
                    self.estimatedProgress = progress
                }
            }
        }
    }

    func expandChrome() {
        scrollTravel = 0
        if isChromeMinimized { isChromeMinimized = false }
    }

    private func handleScroll(_ scrollView: UIScrollView) {
        if scrollView.isTracking != wasTracking {
            wasTracking = scrollView.isTracking
            if wasTracking { userInteraction.send() }
        }
        let offset = scrollView.contentOffset.y + scrollView.adjustedContentInset.top
        let maximumOffset = max(
            0,
            scrollView.contentSize.height
                - scrollView.bounds.height
                + scrollView.adjustedContentInset.bottom
        )
        let delta = offset - lastScrollOffset
        lastScrollOffset = offset

        // Ignore rubber-banding past either end so the bar does not flicker.
        guard delta != 0, offset >= 0, offset <= maximumOffset else { return }
        if offset <= 0 {
            expandChrome()
            return
        }

        // Accumulate travel in one direction; reverse direction resets it so a
        // small flick is enough to toggle without reacting to every jitter.
        if (delta > 0) != (scrollTravel > 0) { scrollTravel = 0 }
        scrollTravel += delta
        if scrollTravel > Self.chromeToggleTravel, !isChromeMinimized {
            isChromeMinimized = true
        } else if scrollTravel < -Self.chromeToggleTravel, isChromeMinimized {
            isChromeMinimized = false
        }
    }

    /// Loads the current forum's /latest. Returns false (and does nothing)
    /// when there is no current forum; the UI then shows the Forums home.
    @discardableResult
    func loadHome() -> Bool {
        guard let homeSiteURL, let url = ForumSite.latestURL(siteURL: homeSiteURL) else {
            return false
        }
        load(url)
        return true
    }

    /// Loads the current forum's sign-in page; false with no current forum.
    @discardableResult
    func loadLogin() -> Bool {
        guard let homeSiteURL, let url = ForumSite.loginURL(siteURL: homeSiteURL) else {
            return false
        }
        load(url)
        return true
    }

    func load(_ url: URL) {
        guard Self.isBrowsableURL(url) else { return }
        hideForumsHome()
        // The first load (the restored forum at launch) would otherwise leave
        // `currentURL` nil until WebKit reports the navigation, so the Forums
        // home flashes in and fades out on every launch. Navigation updates
        // replace this right away.
        if currentURL == nil { currentURL = url }
        if !contentBlocker.library.lookupsFinished {
            // Launch: give the already-compiled lists a moment to attach so
            // the first page is filtered too. Compiling is never waited for.
            let isWaiting = deferredLoad != nil
            deferredLoad = url
            guard !isWaiting else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.contentBlocker.library.waitForLookups(timeout: Self.ruleLookupWait)
                guard let url = self.deferredLoad else { return }
                self.deferredLoad = nil
                self.webView.load(URLRequest(url: url))
            }
            return
        }
        deferredLoad = nil
        webView.load(URLRequest(url: url))
    }

    /// Opens an address typed into the bar. Returns false when it does not
    /// resolve to a web page.
    @discardableResult
    func open(address: String) -> Bool {
        guard let url = Self.resolveAddress(address, currentSiteURL: homeSiteURL) else {
            return false
        }
        load(url)
        return true
    }

    /// Accepts a full http(s) URL, a bare host (`meta.discourse.org/t/…`), or a
    /// path (`/t/…`, `t/…`) resolved against the current forum. Anything else
    /// (plain words, other schemes, a path with no current forum) is nil; the
    /// bar never turns text into a web search.
    nonisolated static func resolveAddress(_ address: String, currentSiteURL: String?) -> URL? {
        let text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(where: \.isWhitespace) else { return nil }
        let lowercased = text.lowercased()
        var candidate: String
        if lowercased.range(of: "^[a-z][a-z0-9+.-]*://", options: .regularExpression) != nil {
            candidate = text
        } else if lowercased.range(of: "^[a-z][a-z0-9+.-]*:[^0-9]", options: .regularExpression) != nil
            || lowercased.range(of: "^[a-z][a-z0-9+.-]*:$", options: .regularExpression) != nil {
            // javascript:, mailto:, … (host:port is handled below).
            return nil
        } else if text.hasPrefix("//") {
            candidate = "https:" + text
        } else if text.hasPrefix("/") {
            // A path already under the base path ("/forum/t/…") is not
            // prefixed again.
            guard let site = ForumSite.parse(siteURL: currentSiteURL) else { return nil }
            let path = URLComponents(string: text)?.path ?? text
            candidate = ForumSite.hasBasePathPrefix(path, basePath: site.basePath)
                && !site.basePath.isEmpty
                ? site.origin + text
                : site.siteURL + text
        } else {
            let host = String(
                lowercased.prefix { $0 != "/" && $0 != "?" && $0 != "#" }
            )
            let hostName = host.split(separator: ":").first.map(String.init) ?? host
            if hostName.contains(".") || hostName == "localhost" {
                candidate = (hostName == "localhost" || hostName == "127.0.0.1" ? "http://" : "https://")
                    + text
            } else if text.contains("/"), let site = ForumSite.parse(siteURL: currentSiteURL) {
                candidate = site.siteURL + "/" + text
            } else {
                return nil
            }
        }
        guard let url = URL(string: candidate), isBrowsableURL(url) else { return nil }
        return url
    }

    func goBack() {
        if webView.canGoBack { webView.goBack() }
    }

    func goForward() {
        if webView.canGoForward { webView.goForward() }
    }

    func reload() {
        webView.reload()
    }

    func stopLoading() {
        deferredLoad = nil
        webView.stopLoading()
    }

    /// Applies a new blocking policy right away. Returns true when it
    /// changes what is blocked on the page shown now (the caller reloads it).
    @discardableResult
    func applyContentBlocking(_ policy: ContentBlockingPolicy) -> Bool {
        let pageURL = webView.url ?? currentURL
        let before = contentBlocker.policy.activeCategories(forTopURL: pageURL)
        contentBlocker.policy = policy
        let after = policy.activeCategories(forTopURL: pageURL)
        return before != after && pageURL.map(Self.isBrowsableURL) == true
    }

    /// Cookie header for one forum host (never another site's cookies).
    func cookieHeader(forHost host: String) async -> String? {
        let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
        let forumCookies = ForumSite.cookies(cookies, forHost: host)
        guard !forumCookies.isEmpty else { return nil }
        return HTTPCookie.requestHeaderFields(with: forumCookies)["Cookie"]
    }

    /// Cookie header for a forum site URL.
    func cookieHeader(forSite siteURL: String) async -> String? {
        guard let host = ForumSite.parse(siteURL: siteURL)
            .flatMap({ URLComponents(string: $0.origin)?.host })
        else {
            return nil
        }
        return await cookieHeader(forHost: host)
    }

    /// Loads a forum resource. When the web view shows the same forum, fetch()
    /// runs in the page (with its Cloudflare clearance and Discourse session);
    /// otherwise the request goes out directly with that forum's cookies only.
    func fetchForumResource(_ url: URL) async throws -> ForumResourceResponse {
        guard Self.isBrowsableURL(url), let requestOrigin = ForumSite.origin(of: url) else {
            throw AssistantError.invalidResponse
        }

        // Restored tasks can resume before WKWebView finishes its first load.
        // Wait while it is still loading a page of the requested site.
        for _ in 0..<120 {
            try Task.checkCancellation()
            guard webView.isLoading,
                  webView.url.map({ ForumSite.origin(of: $0)?.origin == requestOrigin.origin }) ?? true
            else {
                break
            }
            try await Task.sleep(for: .milliseconds(250))
        }

        if let siteURL = pageContext.siteURL,
           !webView.isLoading,
           let current = webView.url,
           ForumSite.isSameForum(url: current, siteURL: siteURL),
           ForumSite.isSameForum(url: url, siteURL: siteURL) {
            return try await fetchInPage(url)
        }
        return try await fetchDirect(url)
    }

    private func fetchInPage(_ url: URL) async throws -> ForumResourceResponse {
        let script = """
        const response = await fetch(resourceURL, {
          credentials: "include",
          cache: "no-store",
          headers: { "Accept": "application/json,text/plain,text/html,*/*" }
        });
        return {
          statusCode: response.status,
          statusText: response.statusText,
          retryAfter: response.headers.get("Retry-After") || "",
          body: await response.text()
        };
        """
        let value = try await webView.callAsyncJavaScript(
            script,
            arguments: ["resourceURL": url.absoluteString],
            in: nil,
            contentWorld: .page
        )
        guard let result = value as? [String: Any],
              let statusCode = result["statusCode"] as? Int,
              let body = result["body"] as? String
        else {
            throw AssistantError.invalidResponse
        }
        return ForumResourceResponse(
            statusCode: statusCode,
            statusText: result["statusText"] as? String ?? "",
            retryAfter: result["retryAfter"] as? String,
            data: Data(body.utf8)
        )
    }

    private func fetchDirect(_ url: URL) async throws -> ForumResourceResponse {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 60
        request.httpShouldHandleCookies = false
        request.setValue("application/json,text/plain,text/html,*/*", forHTTPHeaderField: "Accept")
        if let host = url.host, let cookies = await cookieHeader(forHost: host) {
            request.setValue(cookies, forHTTPHeaderField: "Cookie")
        }
        // Redirects to another origin drop the forum's cookies.
        let (data, response) = try await URLSession.shared.data(
            for: request,
            delegate: ForumRedirectGuard.shared
        )
        guard let http = response as? HTTPURLResponse else {
            throw AssistantError.invalidResponse
        }
        return ForumResourceResponse(
            statusCode: http.statusCode,
            statusText: HTTPURLResponse.localizedString(forStatusCode: http.statusCode),
            retryAfter: http.value(forHTTPHeaderField: "Retry-After"),
            data: data
        )
    }

    fileprivate func handleRouteMessage(
        urlString: String,
        title: String,
        authenticated: Bool,
        probe: [String: Any]?
    ) {
        guard let url = URL(string: urlString), Self.isBrowsableURL(url),
              Self.isRouteMessage(from: url, forPageAt: webView.url)
        else {
            return
        }
        if let probe { lastProbe = Self.pageProbe(from: probe, fallbackURL: url) }
        isAuthenticated = authenticated
        updateNavigationState(url: url, title: title)
    }

    /// Route messages come from the page's own scripts, so any page (or an
    /// injected script on it) can post one. Only a message about the document
    /// the web view actually shows (same origin; SPA routes never change it)
    /// may update the page context; a message claiming another site is dropped.
    nonisolated static func isRouteMessage(from reportedURL: URL, forPageAt pageURL: URL?) -> Bool {
        guard let pageURL, let reported = webOrigin(of: reportedURL), let page = webOrigin(of: pageURL)
        else {
            return false
        }
        return reported == page
    }

    /// `scheme://host[:port]` of an http(s) URL, default port omitted.
    private nonisolated static func webOrigin(of url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host?.lowercased(), !host.isEmpty
        else {
            return nil
        }
        let defaultPort = scheme == "https" ? 443 : 80
        guard let port = url.port, port != defaultPort else { return "\(scheme)://\(host)" }
        return "\(scheme)://\(host):\(port)"
    }

    /// Runs the probe once a load finishes, so every page settles into a
    /// state even if the route observer did not report it.
    private func probeCurrentPage() async {
        guard let url = webView.url, Self.isBrowsableURL(url) else { return }
        do {
            let value = try await webView.callAsyncJavaScript(
                "return (\(Self.probeFunction))();",
                arguments: [:],
                in: nil,
                contentWorld: .defaultClient
            )
            if let result = value as? [String: Any] {
                lastProbe = Self.pageProbe(from: result, fallbackURL: url)
            }
        } catch {
            // No document to inspect (error page, download): not a forum.
            lastProbe = PageProbe(url: url, isDiscourse: false)
        }
        updateNavigationState()
    }

    nonisolated static func pageProbe(from result: [String: Any], fallbackURL: URL) -> PageProbe {
        let url = (result["url"] as? String).flatMap(URL.init(string:)) ?? fallbackURL
        let icon = (result["iconURL"] as? String).flatMap(URL.init(string:))
        return PageProbe(
            url: url,
            isDiscourse: result["isDiscourse"] as? Bool ?? false,
            basePath: result["basePath"] as? String ?? "",
            forumName: result["forumName"] as? String ?? "",
            iconURL: icon.flatMap { $0.scheme == "https" || $0.scheme == "http" ? $0 : nil }
        )
    }

    /// Recomputes the page context (e.g. after the forum directory changed).
    func refreshPageContext() {
        updateNavigationState()
    }

    // MARK: Web content process crashes

    /// WebKit killed or lost the page's content process (memory pressure,
    /// a crash): the view goes blank and `isLoading` can stay true (a
    /// spinning Stop). Reload the page once; if it keeps dying within
    /// `crashReloadWindow`, stop and show the banner.
    func handleWebContentTermination(now: Date = Date()) {
        contentTerminations = contentTerminations.filter { now.timeIntervalSince($0) < Self.crashReloadWindow }
        contentTerminations.append(now)
        // The address the user saw: after an in-page (SPA) route change the dead
        // process leaves `webView.url` on the last full load.
        let url = currentURL ?? webView.url
        let reloads = contentTerminations.count == 1 && url.map(Self.isBrowsableURL) == true
        Self.log.notice(
            "Web content process ended (\(self.contentTerminations.count, privacy: .public) in \(Int(Self.crashReloadWindow), privacy: .public) s); \(reloads ? "reloading" : "showing notice", privacy: .public)"
        )
        if reloads, let url {
            // Give WebKit a moment to tear the dead process down: a load
            // issued inside this callback can fail to launch a new one and
            // report a second termination straight away.
            let generation = contentTerminations.count
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(600))
                guard let self, self.contentTerminations.count == generation else { return }
                self.webView.load(URLRequest(url: url))
            }
        } else {
            webView.stopLoading()
        }
        // A dead page reports no title; keep the one the user saw.
        updateNavigationState(url: url, title: webView.title?.nonEmpty ?? pageTitle)
        // WebKit can still report the dead load; the bar shows Reload, not Stop.
        if !reloads { isLoading = false }
        estimatedProgress = 0
        showsCrashNotice = !reloads && url != nil
    }

    /// The banner's Reload: an explicit retry resets the crash window.
    func retryAfterCrash() {
        contentTerminations.removeAll()
        showsCrashNotice = false
        if let url = currentURL ?? webView.url {
            load(url)
        }
    }

    func dismissCrashNotice() {
        showsCrashNotice = false
    }

    private func updateNavigationState(
        url: URL? = nil,
        title: String? = nil
    ) {
        let resolvedURL = url ?? webView.url
        let resolvedTitle = title ?? webView.title
        currentURL = resolvedURL
        pageTitle = resolvedTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty ?? Self.defaultPageTitle
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
        isLoading = webView.isLoading

        let context = PageContext.make(
            url: resolvedURL,
            title: resolvedTitle,
            probe: lastProbe,
            knownForum: resolvedURL.flatMap { knownForumLookup?($0) }
        )
        if let siteURL = context.siteURL, homeSiteURL != siteURL {
            homeSiteURL = siteURL
        }
        guard context != pageContext else { return }
        pageContext = context
        onPageContextChanged?(context)
    }

    /// Pages the browser may show: http and https.
    nonisolated static func isBrowsableURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              let host = url.host, !host.isEmpty
        else {
            return false
        }
        return true
    }
}

private final class ForumRouteMessageHandler: NSObject, WKScriptMessageHandler {
    weak var browser: ForumBrowserModel?

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        // The observer script runs in the main frame only; iframes (ads,
        // embeds) can still reach the handler, so their messages are ignored.
        guard message.frameInfo.isMainFrame,
              let body = message.body as? [String: Any],
              let urlString = body["url"] as? String
        else {
            return
        }
        let title = body["title"] as? String ?? ""
        let authenticated = body["authenticated"] as? Bool ?? false
        let probe = body["probe"] as? [String: Any]
        nonisolated(unsafe) let sendableProbe = probe
        Task { @MainActor [weak browser] in
            browser?.handleRouteMessage(
                urlString: urlString,
                title: title,
                authenticated: authenticated,
                probe: sendableProbe
            )
        }
    }
}

extension ForumBrowserModel: WKNavigationDelegate {
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        Task { @MainActor in
            self.handleWebContentTermination()
        }
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }

        let scheme = url.scheme?.lowercased() ?? ""
        if ["http", "https", "about", "blob", "data"].contains(scheme) {
            // The rule lists for the new main page (an allowed site or a
            // sign-in page has none) go in before its requests start.
            if navigationAction.targetFrame?.isMainFrame == true, scheme == "http" || scheme == "https" {
                contentBlocker.prepare(forTopURL: url)
            }
            decisionHandler(.allow)
        } else {
            // mailto:, tel:, app links: hand a tapped link to the system.
            decisionHandler(.cancel)
            if navigationAction.navigationType == .linkActivated {
                Task { @MainActor in UIApplication.shared.open(url) }
            }
        }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation: WKNavigation!) {
        Task { @MainActor in
            self.expandChrome()
            self.hideForumsHome()
            self.updateNavigationState()
        }
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        Task { @MainActor in
            // The committed page (after redirects) decides the lists.
            self.contentBlocker.prepare(forTopURL: webView.url)
            self.updateNavigationState()
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            if self.showsCrashNotice { self.showsCrashNotice = false }
            self.updateNavigationState()
            await self.probeCurrentPage()
            #if DEBUG
            // `-dc-scroll-page <points>`: scrolls each loaded page (screenshots).
            if let value = OnboardingDebug.value(after: "-dc-scroll-page"), let offset = Double(value) {
                try? await Task.sleep(for: .seconds(2))
                _ = try? await webView.evaluateJavaScript("window.scrollTo(0, \(offset))")
            }
            #endif
        }
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        Task { @MainActor in
            self.updateNavigationState()
        }
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        Task { @MainActor in
            // The page did not change: back to its lists.
            self.contentBlocker.prepare(forTopURL: webView.url)
            self.updateNavigationState()
        }
    }
}

extension ForumBrowserModel: WKUIDelegate {
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        guard navigationAction.targetFrame == nil,
              let url = navigationAction.request.url
        else {
            return nil
        }
        Task { @MainActor in
            if Self.isBrowsableURL(url) {
                self.load(url)
            }
        }
        return nil
    }
}

struct ForumWebView: UIViewRepresentable {
    @ObservedObject var browser: ForumBrowserModel

    func makeUIView(context: Context) -> WKWebView {
        browser.webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
