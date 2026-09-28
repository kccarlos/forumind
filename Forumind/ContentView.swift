import SwiftUI

enum AppPane: String, CaseIterable {
    case browser = "Browse"
    case assistant = "Assistant"

    var icon: String {
        switch self {
        case .browser: "safari"
        case .assistant: "sparkles"
        }
    }

    /// Visible label; `rawValue` stays English for state and tests.
    var title: String {
        switch self {
        case .browser: String(localized: "Browse", comment: "Workspace switch: the web browser pane")
        case .assistant: String(localized: "Assistant", comment: "Workspace switch: the AI assistant pane")
        }
    }
}

struct ContentView: View {
    @ObservedObject var app: AppModel
    @State private var compactPane: AppPane = .browser
    /// nil until the first size is known; then updated with hysteresis.
    @State private var splitState: Bool?
    /// The pane the user last worked in; picks the pane to keep when the
    /// window narrows from split to single pane.
    @State private var focusedPane: AppPane = .browser
    @State private var expandedPanel: ExpandedPanelRoute?
    @State private var showingLoginInfo = false
    @State private var showingAddForum = false
    @State private var keyboardVisible = false
    @State private var addressFocusRequest = 0
    /// Assistant panel width chosen with the handle (0 = default 40%).
    @AppStorage("dc.assistantPanelWidth") private var storedPanelWidth: Double = 0
    @State private var dragStartWidth: CGFloat?
    @State private var dragWidth: CGFloat?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            workspace(width: proxy.size.width)
                .onChange(of: proxy.size.width, initial: true) { _, width in
                    updateLayout(forWidth: width)
                }
        }
        .background(DCTheme.pageBackground)
        #if DEBUG
        .modifier(DebugWindowWidth())
        #endif
        .dcKeyboardVisible($keyboardVisible)
        .task {
            #if DEBUG
            app.applyDebugLaunchArguments()
            if let value = AssistantDebug.value("-dc-bar"), let position = BrowserBarPosition(rawValue: value) {
                app.settings.browserBarPosition = position
            }
            if ProcessInfo.processInfo.arguments.contains("-dc-add-forum") {
                try? await Task.sleep(for: .seconds(1.5))
                showingAddForum = true
            }
            #endif
            app.restorePendingTasksIfNeeded()
        }
        .onOpenURL { url in
            app.handleDeepLink(url)
        }
        .onChange(of: app.presentAssistant) {
            // A shared link asked for the assistant (summary/chat/agent).
            if app.presentAssistant {
                showPane(.assistant)
                app.presentAssistant = false
            }
        }
        // Where the user is working, without intercepting taps: using the
        // assistant (Manage/Settings, typing) vs. navigating the page. (Not
        // the mode: a new topic resets it programmatically.)
        .onChange(of: app.panelRoute) {
            if app.panelRoute != .topic { focusedPane = .assistant }
        }
        .onChange(of: app.chatDraft) { focusedPane = .assistant }
        .onChange(of: app.agentGoalDraft) { focusedPane = .assistant }
        .onChange(of: app.agentFollowUpDraft) { focusedPane = .assistant }
        .onChange(of: app.browser.currentURL) { focusedPane = .browser }
        .onChange(of: app.browser.isForumsHomeRequested) { focusedPane = .browser }
        .onReceive(app.browser.userInteraction) { focusedPane = .browser }
        .onChange(of: compactPane) {
            focusedPane = compactPane
            if compactPane == .browser {
                // A hidden chat field must not keep the keyboard up.
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .dcWorkspaceCommand)) { notification in
            if let command = WorkspaceCommand(notification) { perform(command) }
        }
        .fullScreenCover(item: $expandedPanel) { route in
            ExpandedPanel(app: app, route: route)
        }
        .sheet(isPresented: $showingLoginInfo) {
            LoginReadinessView(browser: app.browser)
        }
        .sheet(isPresented: $showingAddForum) {
            AddForumSheet(app: app) { forum in
                app.openForum(forum)
                compactPane = .browser
            }
        }
        .alert(
            "Forumind",
            isPresented: Binding(
                get: { app.presentedError != nil },
                set: { if !$0 { app.presentedError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {
                app.presentedError = nil
            }
        } message: {
            Text(app.presentedError ?? "")
        }
    }

    /// The side-by-side forum/assistant layout needs an iPad-class window. An
    /// iPhone in landscape can be wider than the split threshold but is too short
    /// to keep the panel usable, so phones always use the single-pane layout.
    static func usesSplitLayout(
        width: CGFloat,
        idiom: UIUserInterfaceIdiom = UIDevice.current.userInterfaceIdiom
    ) -> Bool {
        idiom != .phone && width >= DCTheme.splitLayoutMinimumWidth
    }

    private func isSplit(width: CGFloat) -> Bool {
        splitState ?? Self.usesSplitLayout(width: width)
    }

    /// Crossing the threshold moves the panes inside the system's own size
    /// transition (rotation, Split View, Stage Manager resize), which already
    /// animates; an extra SwiftUI animation on top makes a resizing List (the
    /// Forums home grid) loop in UICollectionView self-sizing and crash.
    /// Split → single keeps the pane the user was in (Settings or Manage
    /// open, typing in the assistant → Assistant; page or bar → Browse).
    private func updateLayout(forWidth width: CGFloat) {
        guard width > 0 else { return }
        let next = WorkspaceMetrics.nextIsSplit(current: splitState, width: width)
        guard next != splitState else { return }
        let wasSplit = splitState
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            if wasSplit == true, !next {
                compactPane = app.panelRoute != .topic || focusedPane == .assistant ? .assistant : .browser
            }
            splitState = next
        }
    }

    private func panelWidth(containerWidth: CGFloat) -> CGFloat {
        WorkspaceMetrics.panelWidth(
            preferred: dragWidth ?? (storedPanelWidth > 0 ? CGFloat(storedPanelWidth) : nil),
            containerWidth: containerWidth
        )
    }

    private var actions: BrowserActions {
        BrowserActions(
            noteInteraction: { focusedPane = .browser },
            showLoginInfo: { showingLoginInfo = true },
            addForum: { showingAddForum = true },
            openForum: { forum in
                app.openForum(forum)
                showPane(.browser)
            },
            showForumsHome: {
                app.showForumsHome()
                showPane(.browser)
            }
        )
    }

    // MARK: Workspace

    private func workspace(width: CGFloat) -> some View {
        let split = isSplit(width: width)
        let panel = panelWidth(containerWidth: width)
        let barPosition = app.settings.browserBarPosition
        let showsBrowser = split || compactPane == .browser
        let showsAssistant = split || compactPane == .assistant
        let showsWebView = showsBrowser && !app.browser.showsForumsHome
        // Typing in the assistant with the bar at the bottom: the bar would
        // sit between the chat field and the keyboard, so it steps aside
        // until the keyboard goes. (While browsing it holds the address.)
        let hidesChrome = !split && barPosition == .bottom && keyboardVisible && compactPane == .assistant

        return WorkspaceLayout(
            isSplit: split,
            panelWidth: panel,
            barPosition: barPosition,
            showsChrome: !hidesChrome,
            parksPanel: !split && compactPane == .browser
        ) {
            BrowserChrome(
                app: app,
                browser: app.browser,
                position: barPosition,
                workspace: split ? nil : $compactPane,
                actions: actions,
                addressFocusRequest: addressFocusRequest
            )
            .opacity(hidesChrome ? 0 : 1)

            BrowserContent(app: app, browser: app.browser, onAddForum: { showingAddForum = true })
                // With the bar on top the page runs under the home indicator;
                // WKWebView insets its own scroll view for the safe area and
                // the keyboard, so only the bar moves when the keyboard
                // appears (which keeps a bottom address field visible).
                .ignoresSafeArea(.container, edges: barPosition == .top && showsWebView ? .bottom : [])
                .ignoresSafeArea(.keyboard, edges: showsWebView ? .bottom : [])
                .opacity(showsBrowser ? 1 : 0)
                .allowsHitTesting(showsBrowser)
                .accessibilityHidden(!showsBrowser)

            AssistantPanel(
                app: app,
                onExpand: { route in expandedPanel = route },
                onOpenURL: { _ in showPane(.browser) }
            )
            .opacity(showsAssistant ? 1 : 0)
            .allowsHitTesting(showsAssistant)
            // Hidden: no keyboard shortcuts (⌘Return) or focus, and out of
            // VoiceOver's order (it is also parked off screen).
            .disabled(!showsAssistant)
            .accessibilityHidden(!showsAssistant)

            PanelResizeHandle(
                panelWidth: panel,
                onDrag: { translation in
                    let start = dragStartWidth ?? panel
                    dragStartWidth = start
                    // The panel is on the right: dragging left widens it.
                    dragWidth = WorkspaceMetrics.panelWidth(preferred: start - translation, containerWidth: width)
                },
                onDragEnded: {
                    if let dragWidth { storedPanelWidth = Double(dragWidth) }
                    dragWidth = nil
                    dragStartWidth = nil
                },
                // Width changes are not animated: animating a List's width
                // (the Forums home) can loop UICollectionView self-sizing.
                onReset: { storedPanelWidth = 0 },
                onAdjust: { delta in
                    storedPanelWidth = Double(
                        WorkspaceMetrics.panelWidth(preferred: panel - delta, containerWidth: width)
                    )
                }
            )
            .opacity(split ? 1 : 0)
            .allowsHitTesting(split)
            .accessibilityHidden(!split)
        }
        .animation(DCMotion.respecting(reduceMotion, DCMotion.quick), value: compactPane)
        .animation(DCMotion.respecting(reduceMotion, DCMotion.smooth), value: app.browser.isChromeMinimized)
        .animation(DCMotion.respecting(reduceMotion, DCMotion.quick), value: hidesChrome)
    }

    /// Brings a pane forward in the single-pane layout (split shows both).
    private func showPane(_ pane: AppPane) {
        focusedPane = pane
        guard compactPane != pane else { return }
        withAnimation(DCMotion.respecting(reduceMotion, DCMotion.smooth)) { compactPane = pane }
    }

    // MARK: Keyboard commands

    private func perform(_ command: WorkspaceCommand) {
        // Not over the first-launch walkthrough.
        guard app.settings.hasCompletedOnboarding else { return }
        let browser = app.browser
        switch command {
        case .focusAddress:
            showPane(.browser)
            addressFocusRequest += 1
        case .reload:
            if browser.currentURL != nil { browser.reload() }
        case .back:
            if browser.isForumsHomeRequested, browser.currentURL != nil {
                withAnimation(DCMotion.respecting(reduceMotion)) { browser.hideForumsHome() }
            } else {
                browser.goBack()
            }
        case .forward:
            browser.goForward()
        case .forumsHome:
            withAnimation(DCMotion.respecting(reduceMotion)) { app.showForumsHome() }
            showPane(.browser)
        case .settings:
            withAnimation(DCMotion.respecting(reduceMotion)) { app.panelRoute = .settings }
            showPane(.assistant)
        case .summary, .chat, .agent:
            let mode: AssistantMode = command == .summary ? .summary : command == .chat ? .chat : .agent
            withAnimation(DCMotion.respecting(reduceMotion, DCMotion.spring)) {
                app.panelRoute = .topic
                app.assistantMode = mode
            }
            showPane(.assistant)
        }
    }
}

/// Callbacks the browser bar needs from the screen that owns sheets.
struct BrowserActions {
    /// The user used the browser bar (picks the pane kept when the window
    /// narrows to one pane).
    var noteInteraction: () -> Void = {}
    var showLoginInfo: () -> Void
    var addForum: () -> Void
    var openForum: (Forum) -> Void
    var showForumsHome: () -> Void
}

/// The web view, with the Forums home over it when no page is loaded or the
/// user asked for it. The web view stays mounted so its page and scroll
/// position survive a trip to the Forums home.
private struct BrowserContent: View {
    @ObservedObject var app: AppModel
    @ObservedObject var browser: ForumBrowserModel
    let onAddForum: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let showsHome = browser.showsForumsHome
        ZStack {
            ForumWebView(browser: browser)
                .background(Color(uiColor: .systemBackground))
                .opacity(showsHome ? 0 : 1)
                .allowsHitTesting(!showsHome)
                .accessibilityHidden(showsHome)
            if showsHome {
                ForumsHome(app: app, onAddForum: onAddForum)
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
        .animation(DCMotion.respecting(reduceMotion), value: showsHome)
        .animation(DCMotion.respecting(reduceMotion, DCMotion.spring), value: browser.showsCrashNotice)
    }
}

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


/// Safari-style browser bar: forum switcher, navigation + address (only while
/// browsing), the Browse/Assistant switch in single-pane layouts, and a
/// minimized strip while the page is being scrolled.
private struct BrowserChrome: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ObservedObject var app: AppModel
    @ObservedObject var browser: ForumBrowserModel
    let position: BrowserBarPosition
    let workspace: Binding<AppPane>?
    let actions: BrowserActions
    /// Bumped by ⌘L to start editing the address.
    var addressFocusRequest = 0
    @State private var isEditingAddress = false
    @State private var addressDraft = ""
    @State private var addressError: AddressError?
    @State private var showingSwitcher = false
    @FocusState private var addressFocused: Bool

    private var isBrowsing: Bool {
        (workspace?.wrappedValue ?? .browser) == .browser
    }

    private var isMinimized: Bool {
        isBrowsing && browser.isChromeMinimized && !browser.showsForumsHome
    }

    private var showsHome: Bool { browser.showsForumsHome }

    private var forum: Forum? { app.barForum }

    var body: some View {
        VStack(spacing: 0) {
            if position == .bottom { Divider() }
            Group {
                if isMinimized {
                    minimizedStrip
                        .transition(.opacity)
                } else {
                    // The workspace switch hugs the screen edge and the address
                    // row stays next to the page: switch-then-address at the top,
                    // address-then-switch at the bottom (closest to the thumb).
                    VStack(spacing: 0) {
                        if position == .top, let workspace {
                            workspaceRow(workspace)
                        }
                        if isBrowsing {
                            addressRow
                                .transition(.opacity)
                        }
                        if position == .bottom, let workspace {
                            workspaceRow(workspace)
                        }
                    }
                    .transition(.opacity)
                }
            }
            if position == .top { Divider() }
        }
        .background(.bar)
        .overlay(alignment: position == .top ? .bottom : .top) {
            if isBrowsing, !showsHome {
                LoadingLine(progress: browser.estimatedProgress, isLoading: browser.isLoading)
            }
        }
        .alert(
            addressError?.title ?? "",
            isPresented: Binding(
                get: { addressError != nil },
                set: { if !$0 { addressError = nil } }
            ),
            presenting: addressError
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { error in
            Text(error.message)
        }
        .onChange(of: addressFocused) {
            if !addressFocused {
                withAnimation(DCMotion.quick) { isEditingAddress = false }
            }
        }
        .onChange(of: addressFocusRequest) {
            if isMinimized { browser.expandChrome() }
            beginEditingAddress()
        }
        #if DEBUG
        .task {
            if ProcessInfo.processInfo.arguments.contains("-dc-show-switcher") {
                try? await Task.sleep(for: .seconds(4))
                showingSwitcher = true
            }
        }
        #endif
    }

    // MARK: Rows

    private func workspaceRow(_ workspace: Binding<AppPane>) -> some View {
        HStack(spacing: DCTheme.spacingS) {
            forumSwitcher(compact: true)
                .frame(maxWidth: dynamicTypeSize.isAccessibilitySize ? 150 : 190, alignment: .leading)
            Picker("Workspace", selection: workspace.animation(DCMotion.quick)) {
                ForEach(AppPane.allCases, id: \.self) { pane in
                    Label(pane.title, systemImage: pane.icon)
                        .tag(pane)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("workspacePicker")
        }
        .padding(.horizontal, DCTheme.spacingM)
        .padding(.vertical, 6)
    }

    private var minimizedStrip: some View {
        Button(action: browser.expandChrome) {
            HStack(spacing: 6) {
                if let forum, browser.pageContext.isForum {
                    ForumIcon(forum: forum, size: 14)
                } else {
                    Image(systemName: "lock.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text(browser.currentURL == nil ? browser.pageTitle : Self.displayHost(browser.currentURL))
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                if workspace != nil {
                    Image(systemName: "sparkles")
                        .font(.caption2)
                        .foregroundStyle(DCTheme.brandGradient)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .accessibilityLabel("Show browser bar")
        .accessibilityIdentifier("browserChromeStrip")
    }

    private var addressRow: some View {
        HStack(spacing: 2) {
            if workspace == nil {
                forumSwitcher(compact: false)
                    .frame(maxWidth: 190, alignment: .leading)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.trailing, DCTheme.spacingXS)
            }
            browserButton("chevron.left", label: String(localized: "Back"), action: goBack)
                .disabled(!canGoBack)
            browserButton("chevron.right", label: String(localized: "Forward"), action: browser.goForward)
                .disabled(!browser.canGoForward || showsHome)

            if horizontalSizeClass == .compact {
                pageIdentity
                reloadButton
                overflowMenu
            } else {
                // All forums lives in the switcher and the menu, so the
                // address keeps its room next to the assistant panel.
                homeButton
                reloadButton
                pageIdentity
                accountButton
                overflowMenu
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
    }

    // MARK: Forum switcher

    private func forumSwitcher(compact: Bool) -> some View {
        Button {
            DCHaptics.tap()
            actions.noteInteraction()
            showingSwitcher = true
        } label: {
            ForumSwitcherLabel(forum: forum, compact: compact)
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .accessibilityLabel(forum.map { String(localized: "Forum: \($0.displayName)") } ?? String(localized: "Forums"))
        .accessibilityHint("Switch to another forum")
        .accessibilityIdentifier("forumSwitcher")
        .popover(isPresented: $showingSwitcher, arrowEdge: position == .top ? .top : .bottom) {
            ForumSwitcherPanel(
                app: app,
                onSelect: { selected in
                    showingSwitcher = false
                    actions.openForum(selected)
                },
                onAllForums: {
                    showingSwitcher = false
                    actions.showForumsHome()
                },
                onAddForum: {
                    showingSwitcher = false
                    // Present the sheet once the popover has gone.
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(350))
                        actions.addForum()
                    }
                }
            )
            .presentationCompactAdaptation(.popover)
        }
    }

    // MARK: Buttons

    /// Back also leaves the Forums home when it covers a page.
    private var canGoBack: Bool {
        (browser.isForumsHomeRequested && browser.currentURL != nil) || (browser.canGoBack && !showsHome)
    }

    private func goBack() {
        if browser.isForumsHomeRequested, browser.currentURL != nil {
            withAnimation(DCMotion.respecting(reduceMotion)) { browser.hideForumsHome() }
        } else {
            browser.goBack()
        }
    }

    private var homeLabel: String {
        forum.map { String(localized: "\($0.displayName) home", comment: "Button label: the forum's home page (forum name)") }
            ?? String(localized: "Forums")
    }

    private func goHome() {
        withAnimation(DCMotion.respecting(reduceMotion)) { app.goHome() }
    }

    private var homeButton: some View {
        browserButton("house", label: homeLabel, action: goHome)
            .accessibilityIdentifier("browserHome")
    }

    private var reloadButton: some View {
        browserButton(
            browser.isLoading ? "xmark" : "arrow.clockwise",
            label: browser.isLoading ? String(localized: "Stop loading") : String(localized: "Reload"),
            action: browser.isLoading ? browser.stopLoading : browser.reload
        )
        .disabled(browser.currentURL == nil || showsHome)
    }

    private var accountLabel: String {
        browser.isAuthenticated
            ? String(localized: "Forum account")
            : String(localized: "Forum sign in", comment: "Button: open the forum's sign-in page")
    }

    private var accountHint: String {
        browser.isAuthenticated
            ? String(localized: "Open the forum home")
            : String(localized: "Open the forum sign in page")
    }

    private func openAccount() {
        let opened = browser.isAuthenticated ? browser.loadHome() : browser.loadLogin()
        if !opened { actions.showForumsHome() }
    }

    private var accountButton: some View {
        Button(action: openAccount) {
            Image(
                systemName: browser.isAuthenticated
                    ? "person.crop.circle.fill"
                    : "person.badge.key"
            )
            .foregroundStyle(browser.isAuthenticated ? DCTheme.success : .primary)
        }
        .buttonStyle(DCIconButtonStyle())
        .disabled(forum == nil)
        .accessibilityLabel(accountLabel)
        .accessibilityHint(accountHint)
    }

    private var signInHelpLabel: String { String(localized: "Sign-in help") }

    /// Narrow windows (iPhone, or a compact Stage Manager window) keep the
    /// remaining browser controls one tap away in a menu.
    private var overflowMenu: some View {
        Menu {
            Section {
                if horizontalSizeClass == .compact {
                    Button(action: goHome) {
                        Label(homeLabel, systemImage: "house")
                    }
                    .accessibilityIdentifier("browserHome")
                }
                Button(action: actions.showForumsHome) {
                    Label("All Forums", systemImage: "square.grid.2x2")
                }
                Button(action: actions.addForum) {
                    Label("Add Forum…", systemImage: "plus")
                }
            }
            if forum != nil, horizontalSizeClass == .compact {
                Section {
                    Button(action: openAccount) {
                        Label(
                            accountLabel,
                            systemImage: browser.isAuthenticated
                                ? "person.crop.circle.fill"
                                : "person.badge.key"
                        )
                    }
                    Button(action: actions.showLoginInfo) {
                        Label(signInHelpLabel, systemImage: "questionmark.circle")
                    }
                }
            }
            if forum != nil, horizontalSizeClass != .compact {
                Button(action: actions.showLoginInfo) {
                    Label(signInHelpLabel, systemImage: "questionmark.circle")
                }
            }
            if browser.currentURL != nil, !showsHome, let toggle = adsToggle {
                Section(blockingStatusTitle) {
                    Button(action: toggle.action) {
                        Label(toggle.title, systemImage: toggle.systemImage)
                    }
                    .accessibilityIdentifier("menuToggleAdsOnSite")
                }
            }
            if let url = browser.currentURL, !showsHome {
                Section {
                    ShareLink(item: url) {
                        Label("Share Page", systemImage: "square.and.arrow.up")
                    }
                    Button {
                        UIPasteboard.general.url = url
                        DCHaptics.success()
                    } label: {
                        Label("Copy Link", systemImage: "link")
                    }
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .buttonStyle(DCIconButtonStyle())
        .accessibilityLabel("More browser actions")
        .accessibilityIdentifier("browserMoreMenu")
    }

    // MARK: Address

    /// Tap to edit the address; Go loads it.
    private var pageIdentity: some View {
        HStack(spacing: 7) {
            identityIcon
                .frame(width: 18, height: 18)
            if isEditingAddress {
                addressField
            } else {
                // Title over address on every width; a long topic URL clips in
                // the middle rather than disappearing.
                titleAndAddress
                    .contentShape(Rectangle())
                    .onTapGesture(perform: beginEditingAddress)
                    .hoverEffect(.highlight)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityHint("Tap to enter a forum address")
            }
            Spacer(minLength: 0)
            if !isEditingAddress, !showsHome, browser.currentURL != nil {
                shieldMenu
            }
        }
        .padding(.horizontal, 10)
        .frame(minHeight: DCTheme.controlHeight)
        .background(
            Color(uiColor: .tertiarySystemFill),
            in: RoundedRectangle(cornerRadius: DCTheme.controlCornerRadius, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: DCTheme.controlCornerRadius, style: .continuous)
                .strokeBorder(isEditingAddress ? Color.accentColor : .clear, lineWidth: 1.5)
        }
        .animation(DCMotion.quick, value: isEditingAddress)
        .layoutPriority(1)
    }

    @ViewBuilder
    private var identityIcon: some View {
        if isEditingAddress {
            Image(systemName: "globe")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if showsHome {
            Image(systemName: "square.grid.2x2.fill")
                .font(.caption)
                .foregroundStyle(DCTheme.brandGradient)
        } else if browser.pageContext.isForum, let forum {
            ForumIcon(forum: forum, size: 18)
        } else {
            Image(systemName: browser.currentURL?.scheme == "https" ? "lock.fill" : "globe")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Ad and tracker blocking

    private var blockingStatus: ContentBlockingStatus {
        app.contentBlockingStatus(for: browser.currentURL)
    }

    private var blockingStatusTitle: String {
        switch blockingStatus {
        case .off: String(localized: "Ad blocking is off")
        case .blocking(let ads, _):
            ads ? String(localized: "Ads blocked on this site") : String(localized: "Trackers blocked on this site")
        case .allowedSite: String(localized: "Ads allowed on this site")
        case .signInPage: String(localized: "Nothing blocked on sign-in pages")
        }
    }

    /// Allow / block ads on the current site (nil when it doesn't apply).
    private var adsToggle: (title: String, systemImage: String, action: () -> Void)? {
        let url = browser.currentURL
        guard let host = url?.host.flatMap(ContentBlockingRules.normalizedHost) else { return nil }
        switch blockingStatus {
        case .blocking:
            return (String(localized: "Allow ads on \(host)", comment: "Menu item; the placeholder is a website host"), "shield.slash", {
                DCHaptics.tap()
                app.setAdsAllowed(true, on: url)
            })
        case .allowedSite:
            return (String(localized: "Block ads on \(host)", comment: "Menu item; the placeholder is a website host"), "shield.lefthalf.filled", {
                DCHaptics.tap()
                app.setAdsAllowed(false, on: url)
            })
        case .off, .signInPage:
            return nil
        }
    }

    /// Shield at the end of the address: shows whether ads are blocked here
    /// and toggles the site. Blocking is off by default (out of respect for
    /// forum owners who rely on ads); then the shield is neutral and offers to
    /// turn it on. (WebKit reports no per-page block count.)
    private var shieldMenu: some View {
        Menu {
            Section(blockingStatusTitle) {
                if blockingStatus == .off {
                    Button {
                        DCHaptics.tap()
                        app.turnOnContentBlocking()
                    } label: {
                        Label("Turn on ad blocking", systemImage: "shield.lefthalf.filled")
                    }
                    .accessibilityIdentifier("shieldTurnOnBlocking")
                }
                if let toggle = adsToggle {
                    Button(action: toggle.action) {
                        Label(toggle.title, systemImage: toggle.systemImage)
                    }
                    .accessibilityIdentifier("shieldToggleAdsOnSite")
                }
            }
        } label: {
            Image(systemName: shieldSymbol)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(shieldTint)
                .frame(width: 26, height: 30)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(blockingStatusTitle)
        .accessibilityIdentifier("contentBlockingShield")
    }

    private var shieldSymbol: String {
        switch blockingStatus {
        case .blocking: "shield.lefthalf.filled"
        case .off: "shield"
        case .allowedSite, .signInPage: "shield.slash"
        }
    }

    private var shieldTint: Color {
        switch blockingStatus {
        case .blocking: DCTheme.success
        case .allowedSite, .signInPage, .off: Color.secondary
        }
    }

    private var addressField: some View {
        HStack(spacing: 6) {
            TextField("Forum address", text: $addressDraft)
                .textContentType(.URL)
                .keyboardType(.URL)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.go)
                .focused($addressFocused)
                .onSubmit(commitAddress)
                .accessibilityIdentifier("addressField")
                // Select the whole address so typing replaces it, like Safari.
                .onReceive(
                    NotificationCenter.default.publisher(
                        for: UITextField.textDidBeginEditingNotification
                    )
                ) { notification in
                    (notification.object as? UITextField)?.selectAll(nil)
                }
            // Esc / ⌘. leaves the address unchanged, like Safari.
            Button("Cancel editing") { addressFocused = false }
                .keyboardShortcut(.cancelAction)
                .frame(width: 0, height: 0)
                .opacity(0)
                .accessibilityHidden(true)
            if !addressDraft.isEmpty {
                Button {
                    addressDraft = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear address")
            }
        }
    }

    private func beginEditingAddress() {
        actions.noteInteraction()
        addressDraft = showsHome ? "" : (browser.currentURL?.absoluteString ?? "")
        isEditingAddress = true
        addressFocused = true
    }

    private func commitAddress() {
        if browser.open(address: addressDraft) {
            addressFocused = false
            isEditingAddress = false
        } else {
            addressError = AddressError(address: addressDraft, hasForum: browser.homeSiteURL != nil)
        }
    }

    private var titleAndAddress: some View {
        VStack(alignment: .leading, spacing: 1) {
            if showsHome {
                Text("Forums")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text("Enter a forum address")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Text(browser.pageTitle)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                HStack(spacing: 4) {
                    if browser.pageContext.state == .notForum, !browser.isLoading {
                        // On a phone the chip is icon-only so the host stays
                        // readable; the label still says "Not a Discourse forum".
                        DCStatusChip(
                            text: horizontalSizeClass == .compact ? nil : String(localized: "Not a Discourse forum"),
                            systemImage: "exclamationmark.circle",
                            tint: DCTheme.warning
                        )
                        .accessibilityLabel("Not a Discourse forum")
                        .accessibilityIdentifier("pageStatusNotForum")
                        .transition(.opacity)
                    }
                    // Off-forum the chip needs the room; the host is enough.
                    Text(
                        browser.pageContext.state == .notForum
                            ? Self.displayHost(browser.currentURL)
                            : Self.displayAddress(browser.currentURL)
                    )
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .layoutPriority(1)
                }
                .animation(DCMotion.quick, value: browser.pageContext.state)
            }
        }
    }

    /// Host without "www.", as Safari shows it.
    static func displayHost(_ url: URL?) -> String {
        guard let host = url?.host() else { return "" }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// Host and path without the scheme (the part people read); a bare "/"
    /// path is dropped. Middle truncation keeps both ends visible.
    static func displayAddress(_ url: URL?) -> String {
        guard let url else { return "" }
        var text = displayHost(url)
        let path = url.path()
        if !path.isEmpty, path != "/" { text += path }
        if let query = url.query(), !query.isEmpty { text += "?" + query }
        return text.isEmpty ? url.absoluteString : text
    }

    private func browserButton(
        _ systemImage: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: { actions.noteInteraction(); action() }) {
            Image(systemName: systemImage)
        }
        .buttonStyle(DCIconButtonStyle())
        .accessibilityLabel(label)
    }
}

/// Why an address typed into the bar could not be opened.
private struct AddressError: Identifiable {
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
private struct LoadingLine: View {
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

private struct LoginReadinessView: View {
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
