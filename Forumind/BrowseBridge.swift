import Foundation
import SwiftUI
import WebKit

/// The browser bridge (`window.__forumindBrowse`): moves and marks posts on a
/// topic page for the navigation layer (AppModel+Navigation.swift). The
/// script is the site's (`PageBridgeProfile.bridgeInstaller`; Discourse's is
/// `DiscourseDOM`); this is the Swift side of its interface.
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
        guard pageBridge != nil, pageContext.state == .topic else { return nil }
        let script = "const b = window.__forumindBrowse; if (!b) return null; \(body)"
        #if DEBUG
        scriptSpy?(script)
        #endif
        guard webView.url.map(Self.isBrowsableURL) == true else { return nil }
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
