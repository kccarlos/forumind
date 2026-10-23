import Foundation
import SwiftUI
import WebKit

/// The browser bridge (`window.__forumindBrowse`): moves and marks posts on a
/// Discourse topic page for the navigation layer (AppModel+Navigation.swift).
///
/// It runs as a third user script, main frame only, in its own content
/// world, so page scripts can neither call it nor fake its messages. It uses
/// the moderation script's selectors (`article[id^="post_"]` inside a
/// `[data-post-number]` wrapper, the author's `a[data-user-card]`, the
/// `.cooked` body) and its MutationObserver + requestAnimationFrame pattern.
/// The DOM is shared across worlds, so a post the moderation script hid
/// (`data-forumind-hidden`) is never scrolled to, highlighted or returned.
///
/// - `scrollToPost(n, smooth)` "shown", "hidden" or "missing" (not rendered:
///                       Discourse cloaks far-off posts; the app then loads
///                       `/t/slug/id/N`)
/// - `highlight([n], flash)` marks posts (re-applied when Discourse
///                       re-renders); returns the numbers marked now. `flash`
///                       (a citation jump) strokes one post in, holds and
///                       fades back to the mark, once, when it renders
/// - `clearHighlight()`
/// - `visible()`         posts in the viewport, `{number, username, excerpt}`
/// - `postText(n)`       `{number, username, text}` of a rendered post, or null
/// - `setInsets(bottom)` page area covered by the app's overlay (result cards)
///
/// After scrolling or re-rendering settles (250 ms) it posts
/// `{url, visible, highlighted}` to the `forumindBrowse` handler, which feeds
/// `PageContext.visiblePosts` and `highlightedPosts`.
enum BrowseScript {
    static let world = WKContentWorld.world(name: "ForumindBrowse")
    static let messageName = "forumindBrowse"
    /// Longest a bridge call may take; a busy or hung page answers nil.
    static let timeout: Duration = .seconds(2)

    static let installer = """
    (() => {
      if (window.__forumindBrowse) return;
      const hiddenAttr = 'data-forumind-hidden';
      const mark = 'forumind-highlight';
      const state = { numbers: [], topic: null, bottomInset: 0, flash: null };
      const flashMark = 'forumind-flash';
      function topicID() {
        const match = location.pathname.match(/\\/t\\/(?:[^/]+\\/)?(\\d+)/);
        return match ? match[1] : null;
      }
      function ensureStyle() {
        if (document.getElementById('forumind-browse-style')) return;
        const style = document.createElement('style');
        style.id = 'forumind-browse-style';
        // Brand blue, as a bar and a light tint: readable on light and dark
        // Discourse themes alike.
        style.textContent = [
          'article.' + mark + ' { box-shadow: inset 4px 0 0 #3A5BE0 !important;',
          '  background-color: rgba(58, 91, 224, 0.10) !important; border-radius: 6px;',
          '  transition: background-color 0.3s ease, box-shadow 0.3s ease; }',
          '@media (prefers-color-scheme: dark) { article.' + mark + ' {',
          '  box-shadow: inset 4px 0 0 #7B93FF !important;',
          '  background-color: rgba(123, 147, 255, 0.16) !important; } }'
        ].join('\\n');
        (document.head || document.documentElement).appendChild(style);
      }
      // Stroke in 0.2 s, hold 1.5 s, fade 0.6 s (2.3 s in all).
      function ensureFlashStyle() {
        if (document.getElementById('forumind-flash-style')) return;
        const style = document.createElement('style');
        style.id = 'forumind-flash-style';
        style.textContent = [
          'article.' + flashMark + ' { outline-style: solid; outline-width: var(--forumind-flash-width, 2px);',
          '  outline-offset: calc(-1 * var(--forumind-flash-width, 2px)); outline-color: transparent;',
          '  animation: forumind-flash 2.3s linear forwards; }',
          '@keyframes forumind-flash { 0% { outline-color: transparent; }',
          '  8.7% { outline-color: var(--forumind-flash-color); }',
          '  73.9% { outline-color: var(--forumind-flash-color); }',
          '  100% { outline-color: transparent; } }'
        ].join('\\n');
        (document.head || document.documentElement).appendChild(style);
      }
      function applyFlash() {
        const flash = state.flash;
        if (!flash || flash.done) return;
        const article = shownPost(flash.number);
        if (!article) return;
        flash.done = true;
        ensureFlashStyle();
        const dark = window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches;
        article.style.setProperty('--forumind-flash-color', dark ? flash.dark : flash.light);
        article.style.setProperty('--forumind-flash-width', flash.width + 'px');
        article.classList.remove(flashMark);
        void article.offsetWidth;
        article.classList.add(flashMark);
        setTimeout(() => article.classList.remove(flashMark), 2400);
      }
      const numberOf = article => parseInt(article.id.slice(5), 10);
      const isHidden = article => (article.closest('[data-post-number]') || article).hasAttribute(hiddenAttr);
      function authorOf(article) {
        const author = article.querySelector('a[data-user-card]');
        return author ? (author.dataset.userCard || '') : '';
      }
      function textOf(article) {
        const cooked = article.querySelector('.cooked');
        return cooked ? cooked.innerText.replace(/[ \\t]+\\n/g, '\\n').replace(/\\n{3,}/g, '\\n\\n').trim() : '';
      }
      // A rendered, shown post: Discourse leaves cloaked placeholders
      // without a body for posts far off screen.
      function shownPost(number) {
        const article = document.getElementById('post_' + number);
        if (!article || isHidden(article)) return null;
        return article;
      }
      // Discourse's fixed header covers the top of the viewport.
      function headerBottom() {
        const header = document.querySelector('.d-header-wrap') || document.querySelector('.d-header');
        if (!header) return 0;
        const rect = header.getBoundingClientRect();
        return rect.top <= 1 ? Math.max(0, rect.bottom) : 0;
      }
      function highlighted() {
        return Array.from(document.querySelectorAll('article.' + mark))
          .filter(article => !isHidden(article))
          .map(numberOf)
          .filter(number => number > 0);
      }
      function visible() {
        const top = headerBottom();
        const bottom = window.innerHeight - state.bottomInset;
        const posts = [];
        document.querySelectorAll('article[id^="post_"]').forEach(article => {
          if (isHidden(article)) return;
          const rect = article.getBoundingClientRect();
          if (rect.height === 0 || rect.bottom <= top || rect.top >= bottom) return;
          const number = numberOf(article);
          const username = authorOf(article);
          if (!(number > 0) || !username) return;
          posts.push({ number, username, excerpt: textOf(article).replace(/\\s+/g, ' ').slice(0, 160) });
        });
        return posts;
      }
      function apply() {
        // Highlights belong to one topic; an in-page route to another drops them.
        if (state.topic && state.topic !== topicID()) {
          state.numbers = [];
          state.topic = null;
        }
        const wanted = new Set(state.numbers);
        document.querySelectorAll('article.' + mark).forEach(article => {
          if (!wanted.has(numberOf(article)) || isHidden(article)) article.classList.remove(mark);
        });
        if (wanted.size > 0) ensureStyle();
        wanted.forEach(number => {
          const article = shownPost(number);
          // Only when missing: re-adding would queue a mutation every frame.
          if (article && !article.classList.contains(mark)) article.classList.add(mark);
        });
        applyFlash();
        reportSoon();
      }
      let scheduled = false;
      function schedule() {
        if (scheduled) return;
        scheduled = true;
        requestAnimationFrame(() => { scheduled = false; apply(); });
      }
      let reportTimer;
      let lastReport = '';
      function reportSoon() {
        clearTimeout(reportTimer);
        reportTimer = setTimeout(report, 250);
      }
      function report() {
        if (!topicID()) return;
        const body = { url: location.href, visible: visible().map(post => post.number), highlighted: highlighted() };
        const key = JSON.stringify(body);
        if (key === lastReport) return;
        lastReport = key;
        window.webkit?.messageHandlers?.forumindBrowse?.postMessage(body);
      }
      function start() {
        // Class changes too: Discourse re-renders a post's element in place.
        new MutationObserver(schedule).observe(document.documentElement, {
          childList: true, subtree: true, attributes: true, attributeFilter: ['class']
        });
        window.addEventListener('scroll', reportSoon, { passive: true });
        window.addEventListener('resize', reportSoon, { passive: true });
        schedule();
      }
      window.__forumindBrowse = {
        scrollToPost(number, smooth) {
          const article = document.getElementById('post_' + number);
          if (!article) return 'missing';
          if (isHidden(article)) return 'hidden';
          const rect = article.getBoundingClientRect();
          if (rect.height === 0) return 'missing';
          const top = window.scrollY + rect.top - headerBottom() - 8;
          window.scrollTo({ top: Math.max(0, top), behavior: smooth ? 'smooth' : 'auto' });
          reportSoon();
          return 'shown';
        },
        highlight(numbers, flash) {
          state.numbers = (numbers || []).filter(number => number > 0);
          state.topic = topicID();
          if (flash && flash.number > 0) state.flash = { ...flash, done: false };
          apply();
          return highlighted();
        },
        clearHighlight() {
          state.numbers = [];
          state.topic = null;
          apply();
          return [];
        },
        visible,
        postText(number) {
          const article = shownPost(number);
          if (!article) return null;
          const text = textOf(article);
          const username = authorOf(article);
          return text && username ? { number, username, text } : null;
        },
        setInsets(bottom) {
          state.bottomInset = Math.max(0, bottom || 0);
          reportSoon();
          return true;
        }
      };
      if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', start);
      else start();
    })();
    """
}

/// A rendered post's plain text, from the bridge or from `/posts.json`.
struct BrowsePostText: Codable, Equatable {
    var number: Int
    var username: String
    var text: String
}

/// What `scrollToPost` found.
enum BrowseScrollOutcome: String, Equatable {
    /// Scrolled to it.
    case shown
    /// Not rendered (or cloaked): load `/t/slug/id/N` instead.
    case missing
    /// Hidden by moderation: never shown.
    case hidden
    /// The page is not a topic, or the bridge didn't answer in time.
    case unavailable
}

/// The bridge's scroll report, as decoded on the Swift side.
struct BrowseBridgeReport: Equatable {
    var url: URL
    var visible: [Int]
    var highlighted: [Int]
}

// MARK: - Typed bridge calls

extension ForumBrowserModel {
    /// Scrolls the rendered post into view under Discourse's header; a
    /// citation jump (`pendingJump`) scrolls smoothly unless Reduce Motion.
    func scrollToPost(_ number: Int) async -> BrowseScrollOutcome {
        let smooth = pendingJump?.number == number && !UIAccessibility.isReduceMotionEnabled
        guard number >= 1,
              let value = await callBridge("return b.scrollToPost(n, smooth);", arguments: ["n": number, "smooth": smooth])
        else {
            return .unavailable
        }
        return BrowseScrollOutcome(rawValue: value) ?? .unavailable
    }

    /// Marks posts on the page (and on the next load of this topic, see
    /// `highlightAfterLoad`). Returns the numbers marked now; posts not
    /// rendered yet are marked when they appear.
    @discardableResult
    func highlight(_ numbers: [Int], flash: PostFlash? = nil) async -> [Int] {
        let flashArgument: [String: Any] = flash.map {
            ["number": $0.number, "light": $0.lightColor, "dark": $0.darkColor, "width": Double($0.width)]
        } ?? ["number": 0]
        guard let json = await callBridge(
            "return JSON.stringify(b.highlight(numbers, flash));",
            arguments: ["numbers": numbers, "flash": flashArgument]
        ),
              let marked = try? JSONDecoder().decode([Int].self, from: Data(json.utf8))
        else {
            return []
        }
        return marked
    }

    func clearHighlight() async {
        pendingHighlight = nil
        _ = await callBridge("return JSON.stringify(b.clearHighlight());")
    }

    /// Posts in the viewport now, not hidden by moderation.
    func postsOnScreen() async -> [VisiblePost] {
        guard let json = await callBridge("return JSON.stringify(b.visible());"),
              let posts = try? JSONDecoder().decode([VisiblePost].self, from: Data(json.utf8))
        else {
            return []
        }
        return posts
    }

    /// The plain text of a rendered post; nil when it is not rendered, cloaked
    /// or hidden.
    func postText(_ number: Int) async -> BrowsePostText? {
        guard let json = await callBridge("return JSON.stringify(b.postText(n));", arguments: ["n": number]),
              let post = try? JSONDecoder().decode(BrowsePostText?.self, from: Data(json.utf8))
        else {
            return nil
        }
        return post
    }

    /// The height the app's overlay covers at the bottom of the page, so
    /// `visible()` leaves those posts out.
    func setCoveredBottomInset(_ inset: CGFloat) {
        guard coveredBottomInset != inset else { return }
        coveredBottomInset = inset
        Task { _ = await callBridge("return String(b.setInsets(bottom));", arguments: ["bottom": Double(inset)]) }
    }

    /// Highlights `numbers` once topic `topicID` is on screen, also after a
    /// full page load (which starts a fresh bridge). Cleared by
    /// `clearHighlight()` or by leaving the topic.
    func highlightAfterLoad(_ numbers: [Int], topicID: String) {
        // A citation jump strokes its post once as it shows.
        var flash: PostFlash?
        if let jump = pendingJump, numbers == [jump.number] {
            flash = PostFlash(number: jump.number)
            pendingJump = nil
        }
        pendingHighlight = PendingHighlight(topicID: topicID, numbers: numbers, flash: flash)
        // Another topic is still showing while the load starts: the next
        // topic change applies it.
        if pageContext.topic?.topicID == topicID { applyPendingHighlight() }
    }

    /// Re-sends the pending highlight when the page shows its topic.
    func applyPendingHighlight() {
        guard let pending = pendingHighlight else { return }
        guard pageContext.state == .topic, let topic = pageContext.topic else { return }
        guard topic.topicID == pending.topicID else {
            // The reader went to another topic: the mark stays behind.
            if !isLoading { pendingHighlight = nil }
            return
        }
        Task {
            let marked = await highlight(pending.numbers, flash: pending.flash)
            // Flashed once it rendered: a later re-apply only marks.
            if let flash = pending.flash, marked.contains(flash.number), pendingHighlight?.flash == flash {
                pendingHighlight?.flash = nil
            }
        }
    }

    /// Runs `body` with `b` bound to the bridge, in the bridge's world. Nil
    /// when the page is not a topic, the bridge is missing, the call fails or
    /// it takes longer than `BrowseScript.timeout`.
    private func callBridge(_ body: String, arguments: [String: Any] = [:]) async -> String? {
        guard pageContext.state == .topic, webView.url.map(Self.isBrowsableURL) == true else { return nil }
        let script = "const b = window.__forumindBrowse; if (!b) return null; \(body)"
        return await withCheckedContinuation { continuation in
            let once = ResumeOnce(continuation)
            webView.callAsyncJavaScript(script, arguments: arguments, in: nil, in: BrowseScript.world) { result in
                let value = (try? result.get()) as? String
                MainActor.assumeIsolated { once.resume(value) }
            }
            Task { @MainActor in
                try? await Task.sleep(for: BrowseScript.timeout)
                once.resume(nil)
            }
        }
    }

    /// Decodes a `forumindBrowse` message (pure, for tests).
    nonisolated static func bridgeReport(from body: Any) -> BrowseBridgeReport? {
        guard let body = body as? [String: Any],
              let url = (body["url"] as? String).flatMap(URL.init(string:))
        else {
            return nil
        }
        func numbers(_ key: String) -> [Int] {
            (body[key] as? [Any] ?? []).compactMap { ($0 as? NSNumber)?.intValue }.filter { $0 > 0 }
        }
        return BrowseBridgeReport(url: url, visible: numbers("visible"), highlighted: numbers("highlighted"))
    }
}

/// A highlight to re-apply after the next load of its topic.
struct PendingHighlight: Equatable {
    var topicID: String
    var numbers: [Int]
    var flash: PostFlash?
}

/// Resumes a continuation once: the bridge's answer or the timeout.
@MainActor
private final class ResumeOnce {
    private var continuation: CheckedContinuation<String?, Never>?

    init(_ continuation: CheckedContinuation<String?, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: String?) {
        continuation?.resume(returning: value)
        continuation = nil
    }
}

/// Receives the bridge's scroll reports. Registered in the bridge's content
/// world only, so the page's own scripts can't post to it.
final class BrowseMessageHandler: NSObject, WKScriptMessageHandler {
    weak var browser: ForumBrowserModel?

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.frameInfo.isMainFrame,
              let report = ForumBrowserModel.bridgeReport(from: message.body)
        else {
            return
        }
        Task { @MainActor [weak browser] in
            browser?.handleBridgeReport(report)
        }
    }
}

/// A citation jump in progress (AppModel.jumpToCitation): the next scroll to
/// this post is smooth and its highlight flashes.
struct PostJump: Equatable {
    var number: Int
}

/// The citation jump's stroke (DCTheme.postHighlight*), resolved for the page.
struct PostFlash: Equatable {
    var number: Int
    var lightColor: String
    var darkColor: String
    var width: CGFloat

    @MainActor
    init(number: Int) {
        let highContrast = UIAccessibility.isDarkerSystemColorsEnabled
        self.number = number
        lightColor = DCTheme.postHighlightStroke.cssHex(dark: false, highContrast: highContrast)
        darkColor = DCTheme.postHighlightStroke.cssHex(dark: true, highContrast: highContrast)
        width = DCTheme.postHighlightStrokeWidth(highContrast: highContrast)
    }
}
