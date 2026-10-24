import SwiftUI

struct ContentView: View {
    @ObservedObject var app: AppModel
    @ObservedObject private var router: PresentationRouter
    @Namespace private var nowPlayingNamespace
    @State private var addressFocusRequest = 0
    /// The last `AppModel.assistantRequest` shown.
    @State private var handledAssistantRequest = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(app: AppModel) {
        self.app = app
        router = app.router
    }

    var body: some View {
        GeometryReader { proxy in
            WorkspaceView(
                app: app,
                browser: app.browser,
                router: router,
                width: proxy.size.width,
                actions: actions,
                addressFocusRequest: addressFocusRequest,
                onOpenURL: { _ in showBrowser() }
            )
            .onChange(of: proxy.size.width, initial: true) { _, width in
                updateLayout(forWidth: width)
            }
        }
        .background(DCTheme.pageBackground)
        #if DEBUG
        .modifier(DebugWindowWidth())
        #endif
        .task {
            #if DEBUG
            app.applyDebugLaunchArguments()
            if let value = AssistantDebug.value("-dc-bar"), let position = BrowserBarPosition(rawValue: value) {
                app.settings.browserBarPosition = position
            }
            if ProcessInfo.processInfo.arguments.contains("-dc-add-forum") {
                try? await Task.sleep(for: .seconds(1.5))
                app.router.item = .addForum
            }
            #endif
            app.restorePendingTasksIfNeeded()
            await app.refreshRemoteModerationIfNeeded()
        }
        #if DEBUG
        .task { await app.runPresentationTestTrigger() }
        #endif
        .onOpenURL { url in
            app.handleDeepLink(url)
        }
        .onChange(of: app.assistantRequest, initial: true) {
            // A shared link asked for the assistant (summary/chat/agent),
            // possibly before this view existed (a cold launch).
            guard app.assistantRequest != handledAssistantRequest else { return }
            handledAssistantRequest = app.assistantRequest
            showAssistant()
        }
        .modifier(AIDrawerCoordinator(app: app))
        .onReceive(NotificationCenter.default.publisher(for: .dcWorkspaceCommand)) { notification in
            if let command = WorkspaceCommand(notification) { perform(command) }
        }
        .modifier(AIDrawerModifier(
            app: app,
            onOpenURL: { _ in showBrowser() },
            onForumAdded: forumAdded
        ))
        // Every root sheet, cover and alert (PresentationRouter.swift); inside
        // the drawer while it is up.
        .modifier(RouterHost(
            app: app,
            active: router.rootHostIsActive,
            onForumAdded: forumAdded
        ))
        .environment(\.nowPlayingNamespace, nowPlayingNamespace)
    }

    /// History and Settings: sheets over the drawer layout and over Home, in
    /// the panel in the split layout.
    private func openPanelRoute(_ route: ExpandedPanelRoute) {
        if router.usesDrawer || route == .post || app.browser.showsForumsHome {
            app.router.item = .expanded(route)
        } else {
            withAnimation(DCMotion.respecting(reduceMotion)) { app.panelRoute = route == .settings ? .settings : .history }
            showAssistant()
        }
    }

    /// A topic or post from the Today page or Home (Home closes).
    private func openDigestLink(_ url: URL, card: DigestCard) {
        app.openDigestLink(url, card: card)
        showBrowser()
    }

    private func forumAdded(_ forum: Forum) {
        app.openForum(forum)
    }

    /// The side-by-side page and AI panel layout needs a window wide enough
    /// for both (iPad, not an iPhone in landscape: too short to keep the
    /// panel usable). Narrower windows, iPad included, get the bottom bar and
    /// the drawer.
    static func usesSplitLayout(
        width: CGFloat,
        idiom: UIUserInterfaceIdiom = UIDevice.current.userInterfaceIdiom
    ) -> Bool {
        idiom != .phone && width >= DCTheme.splitLayoutMinimumWidth
    }

    /// Crossing the threshold moves the views inside the system's own size
    /// transition (rotation, Split View, Stage Manager resize), which already
    /// animates; an extra SwiftUI animation on top makes a resizing List (the
    /// Forums home grid) loop in UICollectionView self-sizing and crash.
    /// Widening past it closes the drawer (the panel takes over); narrowing
    /// leaves the drawer closed (the AI button opens it).
    private func updateLayout(forWidth width: CGFloat) {
        guard width > 0 else { return }
        let next = WorkspaceMetrics.nextIsSplit(current: router.splitLayout, width: width)
        guard next != router.splitLayout else { return }
        let wasMeasured = router.splitLayout != nil
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            router.splitLayout = next
            if wasMeasured, next {
                // The drawer was the reader's AI view: keep it as the panel.
                router.splitPanelMode = router.wantsDrawer ? .shown : .auto
                router.closeDrawer()
            }
        }
        app.syncDrawer()
    }

    private var actions: BrowserActions {
        BrowserActions(
            showLoginInfo: { app.router.item = .loginInfo },
            addForum: { app.router.item = .addForum },
            report: { topic in app.router.item = .report(topic) },
            translatePosts: { app.router.item = .translatePosts },
            openAssistant: openAssistant,
            openPanel: openPanelRoute,
            openForum: { forum in
                app.openForum(forum)
                showBrowser()
            },
            showForumsHome: {
                app.showForumsHome()
                showBrowser()
            },
            openDigestLink: openDigestLink,
            openHistory: { openPanelRoute(.history) },
            openSettings: { openPanelRoute(.settings) },
            showShareHowTo: { app.router.item = .shareHowTo }
        )
    }

    // MARK: AI view (drawer or panel)

    /// The assistant comes forward: the drawer opens at medium, or the split
    /// layout's panel shows.
    private func showAssistant() {
        if router.usesDrawer {
            // Not over the Forums home: the drawer is for pages.
            guard app.isDrawerAvailable else { return }
            if !router.wantsDrawer || router.drawerDetent == .peek { router.openDrawer(at: .medium) }
        } else if !app.browser.showsForumsHome, !router.splitPanelMode.isVisible(onHome: false) {
            // Not over the Forums home: the panel is for pages.
            router.splitPanelMode = .shown
        }
    }

    /// The page comes forward: a large drawer lowers to medium so the page
    /// shows (the split layout shows both).
    private func showBrowser() {
        if router.usesDrawer, router.drawerDetent == .large {
            withAnimation(DCMotion.respecting(reduceMotion, DCMotion.smooth)) { router.drawerDetent = .medium }
        }
    }

    private func openAssistant() {
        DCHaptics.tap()
        showAssistant()
    }

    /// ⌥⌘0 and the bar's button: the panel hides or shows; the drawer opens
    /// or closes.
    private func togglePanel() {
        if router.usesDrawer {
            if router.wantsDrawer { router.closeDrawer() } else { showAssistant() }
        } else {
            router.splitPanelMode = router.splitPanelMode.toggled(onHome: app.browser.showsForumsHome)
        }
    }

    // MARK: Keyboard commands

    private func perform(_ command: WorkspaceCommand) {
        // Not over the first-launch walkthrough.
        guard app.settings.hasCompletedOnboarding else { return }
        let browser = app.browser
        switch command {
        case .focusAddress:
            showBrowser()
            // The drawer covers the bar.
            if router.usesDrawer { router.closeDrawer() }
            addressFocusRequest += 1
        case .reload:
            if browser.currentURL != nil { browser.reload() }
        case .back:
            withAnimation(DCMotion.respecting(reduceMotion)) { browser.navigateBack() }
        case .forward:
            browser.goForward()
        case .forumsHome:
            withAnimation(DCMotion.respecting(reduceMotion)) { app.showForumsHome() }
            showBrowser()
        case .settings:
            withAnimation(DCMotion.respecting(reduceMotion)) { app.panelRoute = .settings }
            showAssistant()
        case .history:
            withAnimation(DCMotion.respecting(reduceMotion)) { app.panelRoute = .history }
            showAssistant()
        case .summary, .chat, .agent:
            // ⌘2 / ⌘3 pick the Ask box's scope and focus it.
            let asks = command != .summary
            withAnimation(DCMotion.respecting(reduceMotion, DCMotion.spring)) {
                app.panelRoute = .topic
                if asks {
                    app.setAskScope(command == .chat ? .topic : .forum)
                } else {
                    app.assistantMode = .summary
                }
            }
            showAssistant()
            if asks { app.askFocusRequest += 1 }
        case .togglePanel:
            togglePanel()
        case .nextResult:
            if app.browseCursor.hasNext { Task { await app.next() } }
        case .previousResult:
            if app.browseCursor.hasPrevious { Task { await app.previous() } }
        case .playPause:
            if app.podcast.isPlayingEpisode { app.podcast.player.toggle() }
        }
    }
}

/// Callbacks the browser bar needs from the screen that owns sheets.
struct BrowserActions {
    var showLoginInfo: () -> Void
    var addForum: () -> Void
    /// Report or block content in a topic.
    var report: (ForumTopic) -> Void = { _ in }
    /// Translate the posts on screen into the reading language.
    var translatePosts: () -> Void = {}
    /// The bar's AI button: opens the drawer, or shows the panel.
    var openAssistant: () -> Void = {}
    /// History and Settings: sheets over the drawer, the panel in the split.
    var openPanel: (ExpandedPanelRoute) -> Void = { _ in }
    var openForum: (Forum) -> Void
    var showForumsHome: () -> Void
    /// A digest card's topic or post (Home and the Today page close).
    var openDigestLink: (URL, DigestCard) -> Void = { _, _ in }
    /// Home's top bar.
    var openHistory: () -> Void = {}
    var openSettings: () -> Void = {}
    /// The Share how-to page ("Share from Safari or Chrome" on Home).
    var showShareHowTo: (() -> Void)?
}

/// The web view, with Home over it when no page is loaded or the user asked
/// for it. The web view stays mounted so its page and scroll position
/// survive a trip to Home. The result cards
/// (ResultCards.swift) sit at the bottom of the page, the crash banner at
/// the top; neither covers the browser bar, which is outside this view.
struct BrowserContent: View {
    @ObservedObject var app: AppModel
    @ObservedObject var browser: ForumBrowserModel
    @ObservedObject var voice: VoiceController
    let actions: BrowserActions
    /// Room the cards leave at the bottom (the home indicator).
    var cardsBottomInset: CGFloat = 0
    /// iPhone: the page runs under the bottom toolbar and the home indicator
    /// (WKWebView insets its own scroll view); the cards stay above them.
    var webViewIgnoresBottomSafeArea = false
    /// Split layout with the panel hidden: the Dock floats bottom-right.
    var dockFloatsTrailing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let showsHome = browser.showsForumsHome
        ZStack {
            ForumWebView(browser: browser)
                .background(Color(uiColor: .systemBackground))
                .ignoresSafeArea(.container, edges: webViewIgnoresBottomSafeArea ? .bottom : [])
                .opacity(showsHome ? 0 : 1)
                .allowsHitTesting(!showsHome)
                .accessibilityHidden(showsHome)
            if showsHome {
                HomeView(app: app, actions: actions)
                    .transition(DCMotion.screen(reduceMotion: reduceMotion))
                    .zIndex(1)
            }
        }
        .overlay(alignment: .top) {
            if browser.showsCrashNotice, !showsHome {
                WebContentCrashBanner(onReload: browser.retryAfterCrash, onDismiss: browser.dismissCrashNotice)
                    .padding(.top, DCTheme.spacingS)
                    .padding(.horizontal, DCTheme.spacingM)
                    .transition(DCMotion.slide(.top, reduceMotion: reduceMotion))
            }
        }
        .overlay(alignment: .bottom) {
            // Cards, then the Dock or a row (Dock.swift); the Dock stays over
            // the Forums home (a session can start there).
            DockLayer(
                app: app,
                browser: browser,
                voice: voice,
                router: app.router,
                podcast: app.podcast,
                showsHome: showsHome,
                floatsTrailing: dockFloatsTrailing
            )
            .frame(maxWidth: .infinity, alignment: dockFloatsTrailing ? .trailing : .center)
            .padding(.horizontal, DCTheme.spacingM)
            .padding(.bottom, DCTheme.spacingS + cardsBottomInset)
            .background(alignment: .bottom) {
                // The page height the cards and the voice bar cover, so the
                // bridge's "posts on screen" leaves those out.
                GeometryReader { proxy in
                    Color.clear.preference(key: CoveredHeightKey.self, value: proxy.size.height)
                }
            }
        }
        .onPreferenceChange(CoveredHeightKey.self) { height in
            // Only the padding: nothing floats over the page.
            let covers = height > DCTheme.spacingS + cardsBottomInset + 1
            browser.setCoveredBottomInset(covers ? height : 0)
        }
        #if DEBUG
        .overlay(alignment: .topLeading) {
            if AssistantDebug.has("-dc-browse-debug") { BrowseDebugState(app: app, browser: app.browser) }
        }
        #endif
        .animation(DCMotion.respecting(reduceMotion), value: showsHome)
        .animation(DCMotion.respecting(reduceMotion, DCMotion.spring), value: browser.showsCrashNotice)
    }
}

private struct CoveredHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

#if DEBUG
/// `-dc-browse-debug`: the page position and the current list as an
/// accessibility element for UI tests (`browseDebugState`). The highlighted
/// posts are the ones the bridge reports marked on the page; `top` is the
/// first post in the viewport.
private struct BrowseDebugState: View {
    @ObservedObject var app: AppModel
    @ObservedObject var browser: ForumBrowserModel

    private var state: String {
        let context = app.pageContext
        let highlighted = context.highlightedPosts.map(String.init).joined(separator: ",")
        let current = app.browseCursor.index.map { String($0 + 1) } ?? "-"
        return "post=\(context.postNumber.map(String.init) ?? "-") highlighted=\(highlighted) "
            + "cards=\(app.browseCursor.items.count) current=\(current) "
            + "top=\(context.visiblePosts.first.map(String.init) ?? "-")"
    }

    var body: some View {
        Text(verbatim: state)
            .font(.system(size: 2))
            .frame(width: 4, height: 4)
            .opacity(0.02)
            .allowsHitTesting(false)
            .accessibilityLabel(Text(verbatim: state))
            .accessibilityIdentifier("browseDebugState")
    }
}
#endif

/// Non-blocking notice after the page's web process quit more than once in a
/// short time (auto-reload is paused so it can't loop).
private struct WebContentCrashBanner: View {
    let onReload: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: DCTheme.spacingM) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(DCTheme.warning)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text("This page stopped responding")
                    .font(.subheadline.weight(.semibold))
                Text("It closed unexpectedly more than once.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 0)
            Button("Reload", action: onReload)
                .buttonStyle(DCActionButtonStyle(prominent: true))
                .accessibilityIdentifier("crashBannerReload")
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
            }
            .buttonStyle(DCIconButtonStyle())
            .accessibilityLabel("Dismiss")
        }
        .padding(.leading, DCTheme.spacingM)
        .padding(.trailing, DCTheme.spacingXS)
        .padding(.vertical, DCTheme.spacingXS)
        .frame(maxWidth: 520)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: DCTheme.cardCornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: DCTheme.cardCornerRadius, style: .continuous)
                .stroke(DCTheme.warning.opacity(0.35))
        }
        .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("webContentCrashBanner")
    }
}


/// How the bar shows a page's address.
enum BrowserAddress {
    /// Host without "www.", as Safari shows it.
    static func host(_ url: URL?) -> String {
        guard let host = url?.host() else { return "" }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// Host and path without the scheme (the part people read); a bare "/"
    /// path is dropped. Middle truncation keeps both ends visible.
    static func display(_ url: URL?) -> String {
        guard let url else { return "" }
        var text = host(url)
        let path = url.path()
        if !path.isEmpty, path != "/" { text += path }
        if let query = url.query(), !query.isEmpty { text += "?" + query }
        return text.isEmpty ? url.absoluteString : text
    }
}

/// Why an address typed into the bar could not be opened.
struct AddressError: Identifiable {
    let address: String
    let hasForum: Bool

    var id: String { address }

    private var isPath: Bool {
        let text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.hasPrefix("/") || (!text.contains(".") && text.contains("/"))
    }

    var title: String {
        address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? String(localized: "Enter an address")
            : String(localized: "Can’t open this address")
    }

    var message: String {
        if isPath, !hasForum {
            return String(localized: "Open a forum first, then enter a path such as /t/topic-name/123.")
        }
        return hasForum
            ? String(localized: "Enter a web address such as meta.discourse.org or a full https:// link. Paths such as /t/topic-name/123 open on the current forum.")
            : String(localized: "Enter a web address such as meta.discourse.org or a full https:// link.")
    }
}

/// Thin page-load progress line along the bar's edge next to the page. It
/// fades out when loading ends, so the bar never changes height.
struct LoadingLine: View {
    let progress: Double
    let isLoading: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            Capsule()
                .fill(DCTheme.brandGradient)
                .frame(width: proxy.size.width * max(0.06, min(1, progress)))
                .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: progress)
        }
        .frame(height: 2.5)
        .opacity(isLoading ? 1 : 0)
        .animation(.easeOut(duration: isLoading ? 0.1 : 0.45), value: isLoading)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct LoginReadinessView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var browser: ForumBrowserModel

    private var loginURL: URL? {
        browser.homeSiteURL.flatMap { ForumSite.loginURL(siteURL: $0) }
    }

    private var forumHost: String {
        browser.homeSiteURL.map { ForumSite.host(of: $0) } ?? String(localized: "the forum")
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    // Explicit rows: LabeledContent stretches these rows to
                    // several hundred points on compact (iPhone) widths.
                    statusRow("Forum session") {
                        Label(
                            browser.isAuthenticated ? "Signed in" : "Not signed in",
                            systemImage: browser.isAuthenticated
                                ? "checkmark.circle.fill"
                                : "person.crop.circle.badge.questionmark"
                        )
                        .foregroundStyle(browser.isAuthenticated ? DCTheme.success : .secondary)
                    }
                } header: {
                    Text("Status")
                } footer: {
                    Text(forumHost)
                }

                Section("Signing in") {
                    Text("Sign in on the forum’s page with your username and password, email link, or the forum’s single sign-on. Your session stays in this app’s browser, so summaries and Ask the forum can read topics you can see.")
                    .foregroundStyle(.secondary)
                }

                Section {
                    Button {
                        browser.loadLogin()
                        dismiss()
                    } label: {
                        Label("Open forum sign in", systemImage: "person.badge.key")
                    }
                    .disabled(loginURL == nil)

                    if let loginURL {
                        Link(destination: loginURL) {
                            Label("Open sign in in Safari", systemImage: "safari")
                        }
                    }
                }
            }
            .navigationTitle("Forum Login")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .dcFormSheet()
    }

    private func statusRow<Value: View>(
        _ title: LocalizedStringKey,
        @ViewBuilder value: () -> Value
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
            Spacer(minLength: 12)
            value()
                .multilineTextAlignment(.trailing)
        }
    }
}

#Preview {
    ContentView(app: AppModel())
        .frame(width: 1_200, height: 820)
}
