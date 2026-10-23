import SwiftUI
import WebKit

// MARK: - iPhone browser bar
//
// The page in a NavigationStack (no navigation bar) with one bar of three
// items: the forum avatar (the forum menu), the title capsule (tap to edit the
// address, long press for history; the not-a-forum icon, the solved hint and
// the ad shield sit inside it) and the AI button (the drawer; long press
// starts voice). On Home the capsule is "Search or enter a forum address" and
// the AI button gives way to the mic (only when voice is available); pages
// pushed over Home (`AppModel.homePath`) go on this stack. At the bottom it
// is the system toolbar; at the top (the
// user's choice) the same items in a bar above the page. While the address
// is edited the field rides on the keyboard instead. iPad keeps
// `BrowserChrome` (ContentView.swift).

struct PhoneBrowser<Page: View>: View {
    @ObservedObject var app: AppModel
    @ObservedObject var browser: ForumBrowserModel
    /// Resolved: `.top` or `.bottom`.
    let position: BrowserBarPosition
    let actions: BrowserActions
    /// Bumped by ⌘L to start editing the address.
    var addressFocusRequest = 0
    /// The window width: toolbar items get their ideal width, so the
    /// capsule is given the room the avatar and the AI button leave.
    var width: CGFloat = 0
    @ViewBuilder let page: () -> Page

    @State private var isEditingAddress = false
    @State private var addressDraft = ""
    @State private var addressError: AddressError?
    @FocusState private var addressFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The toolbar's own side margins and the glass container's padding.
    static var toolbarMargins: CGFloat { 56 }

    /// Scrolling down the page swaps the bar for a thin strip (today's
    /// behaviour). The system's own toolbar minimization (iOS 27,
    /// `toolbarMinimizationBehavior`) doesn't follow WKWebView's scroll view,
    /// so it isn't used.
    private var showsStrip: Bool {
        !isEditingAddress && browser.isChromeMinimized && !browser.showsForumsHome
    }

    private var showsToolbar: Bool {
        position == .bottom && !isEditingAddress && !showsStrip
    }

    var body: some View {
        NavigationStack(path: $app.homePath) {
            page()
                .toolbar(.hidden, for: .navigationBar)
                .modifier(HomeDestinations(app: app, onOpenDigestLink: actions.openDigestLink))
                .toolbar {
                    // One item: the bar is one glass container (avatar,
                    // capsule, AI button); its width is set, since toolbar
                    // items otherwise get their ideal width and overflow.
                    ToolbarItem(placement: .bottomBar) {
                        if showsToolbar {
                            HStack(spacing: 2) { items }
                                .frame(width: width > 0 ? max(200, width - Self.toolbarMargins) : nil)
                        }
                    }
                }
                .toolbar(showsToolbar ? .visible : .hidden, for: .bottomBar)
                .safeAreaInset(edge: .top, spacing: 0) {
                    if position == .top { topBar }
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if position == .bottom {
                        if isEditingAddress {
                            addressRow
                                .background(.bar)
                                .transition(.opacity)
                        } else if showsStrip {
                            strip
                                .background(.bar)
                                .transition(.opacity)
                        }
                    }
                }
        }
        .onAppear { app.barShowsTopicFacts = true }
        .onChange(of: addressFocused) {
            if !addressFocused {
                withAnimation(DCMotion.respecting(reduceMotion, DCMotion.quick)) { isEditingAddress = false }
            }
        }
        .onChange(of: addressFocusRequest) {
            browser.expandChrome()
            beginEditingAddress()
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
        .animation(DCMotion.respecting(reduceMotion, DCMotion.smooth), value: showsStrip)
        .animation(DCMotion.respecting(reduceMotion, DCMotion.quick), value: isEditingAddress)
    }

    // MARK: Bars

    /// Home: the mic only when voice is available; pages: the AI button.
    private var trailingItemCount: CGFloat {
        browser.showsForumsHome && !app.showsVoiceButton ? 0 : 1
    }

    @ViewBuilder
    private var items: some View {
        ForumMenuButton(app: app, browser: browser, voice: app.voice, actions: actions)
        PhoneTitleCapsule(
            app: app,
            browser: browser,
            filled: position == .top || !PhoneBarStyle.usesGlass,
            width: max(0, (position == .bottom ? width - Self.toolbarMargins : width - 2 * DCTheme.spacingM)
                - (1 + trailingItemCount) * (DCTheme.controlHeight + DCTheme.spacingS)),
            onEdit: beginEditingAddress
        )
        if browser.showsForumsHome {
            if app.showsVoiceButton {
                VoiceBarButton(voice: app.voice, onTap: actions.noteInteraction)
            }
        } else {
            PhoneAIButton(
                app: app,
                voice: app.voice,
                isAvailable: app.isDrawerAvailable && browser.currentURL != nil,
                onOpen: { actions.openAssistant?() }
            )
        }
    }

    private var topBar: some View {
        VStack(spacing: 0) {
            Group {
                if isEditingAddress {
                    addressRow
                } else if showsStrip {
                    strip
                } else {
                    HStack(spacing: DCTheme.spacingS) { items }
                        .padding(.horizontal, DCTheme.spacingM)
                        .padding(.vertical, 6)
                }
            }
            .transition(.opacity)
            Divider()
        }
        .background(.bar)
    }

    /// The minimized bar while the page scrolls down; a tap brings it back.
    private var strip: some View {
        Button(action: browser.expandChrome) {
            HStack(spacing: 6) {
                if let forum = app.barForum, browser.pageContext.isForum {
                    ForumIcon(forum: forum, size: 14)
                } else {
                    Image(systemName: "lock.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text(BrowserChrome.displayHost(browser.currentURL))
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Show browser bar")
        .accessibilityIdentifier("browserChromeStrip")
    }

    // MARK: Address

    /// Edit, paste (the field's menu), Go (return) and clear, on the keyboard.
    private var addressRow: some View {
        HStack(spacing: DCTheme.spacingS) {
            HStack(spacing: 6) {
                Image(systemName: "globe")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
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
                        NotificationCenter.default.publisher(for: UITextField.textDidBeginEditingNotification)
                    ) { notification in
                        (notification.object as? UITextField)?.selectAll(nil)
                    }
                    .onAppear {
                        DispatchQueue.main.async { addressFocused = true }
                    }
                if !addressDraft.isEmpty {
                    Button {
                        addressDraft = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                            .frame(width: 30, height: 30)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear address")
                }
            }
            .padding(.horizontal, 10)
            .frame(minHeight: DCTheme.controlHeight)
            .background(Color(uiColor: .tertiarySystemFill), in: Capsule())
            .overlay { Capsule().strokeBorder(Color.accentColor, lineWidth: 1.5) }

            // Esc / ⌘. too, like Safari.
            Button("Cancel") { addressFocused = false }
                .keyboardShortcut(.cancelAction)
                .frame(minHeight: DCTheme.controlHeight)
                .accessibilityIdentifier("addressCancel")
        }
        .padding(.horizontal, DCTheme.spacingM)
        .padding(.vertical, 6)
    }

    private func beginEditingAddress() {
        actions.noteInteraction()
        addressDraft = browser.showsForumsHome ? "" : (browser.currentURL?.absoluteString ?? "")
        isEditingAddress = true
    }

    /// An address opens; other words search the current forum.
    private func commitAddress() {
        let query = addressDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if browser.open(address: addressDraft) {
            addressFocused = false
            isEditingAddress = false
        } else if !query.isEmpty, let siteURL = browser.homeSiteURL,
                  let url = ForumSite.searchPageURL(siteURL: siteURL, query: query) {
            browser.load(url)
            addressFocused = false
            isEditingAddress = false
        } else {
            addressError = AddressError(address: addressDraft, hasForum: browser.homeSiteURL != nil)
        }
    }
}

enum PhoneBarStyle {
    /// iOS 26+: the system toolbar is Liquid Glass, so the capsule needs no fill.
    static var usesGlass: Bool {
        if #available(iOS 26.0, *) { return true }
        return false
    }
}

// MARK: - Title capsule

/// Page title over the host; on Home "Search or enter a forum address". Tap
/// edits the address; long press lists the history. The not-a-forum icon,
/// the solved hint and the ad shield sit inside.
struct PhoneTitleCapsule: View {
    @ObservedObject var app: AppModel
    @ObservedObject var browser: ForumBrowserModel
    /// A fill of its own (top bar, and before Liquid Glass).
    var filled = true
    /// The capsule's width. A menu label in a toolbar takes its ideal width,
    /// so the title is given the room explicitly to truncate in.
    var width: CGFloat = 0
    let onEdit: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var showsHome: Bool { browser.showsForumsHome }

    private var answerPost: Int? {
        guard !showsHome, app.pageContext.state == .topic else { return nil }
        return app.pageContext.acceptedAnswerPost
    }

    var body: some View {
        HStack(spacing: 4) {
            Menu {
                historyMenu
            } label: {
                titleLabel
            } primaryAction: {
                onEdit()
            }
            .menuOrder(.fixed)
            .tint(.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel(accessibilityTitle)
            .accessibilityHint(accessibilityHint)
            .accessibilityIdentifier("browserTitle")

            if let answerPost {
                answerChip(answerPost)
                    .transition(.opacity)
            }
            if !showsHome, browser.currentURL != nil {
                AdShieldMenu(app: app, browser: browser)
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 4)
        .frame(maxWidth: .infinity, minHeight: DCTheme.controlHeight)
        .background {
            if filled { Capsule().fill(Color(uiColor: .tertiarySystemFill)) }
        }
        .overlay(alignment: .bottom) {
            if !showsHome {
                LoadingLine(progress: browser.estimatedProgress, isLoading: browser.isLoading)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 2)
            }
        }
        .contentShape(Capsule())
        .animation(DCMotion.respecting(reduceMotion, DCMotion.quick), value: answerPost)
    }

    @ViewBuilder
    private var titleLabel: some View {
        if showsHome {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("Search or enter a forum address", comment: "iPhone bar on Home: placeholder of the search and address field")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .frame(width: titleWidth, alignment: .leading)
            .frame(maxWidth: .infinity, minHeight: DCTheme.controlHeight, alignment: .leading)
            .contentShape(Rectangle())
        } else {
            pageTitleLabel
        }
    }

    private var pageTitleLabel: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text(browser.pageTitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    if browser.pageContext.state == .notForum, !browser.isLoading, !showsHome {
                        Image(systemName: "exclamationmark.circle")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(DCTheme.warning)
                            .accessibilityLabel("Not a Discourse forum")
                            .accessibilityIdentifier("pageStatusNotForum")
                    }
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(width: titleWidth, alignment: .leading)
        .frame(maxWidth: .infinity, minHeight: DCTheme.controlHeight, alignment: .leading)
        .contentShape(Rectangle())
    }

    /// What the chip and the shield leave of the capsule (nil: no limit).
    private var titleWidth: CGFloat? {
        guard width > 0 else { return nil }
        var reserved: CGFloat = 16
        if answerPost != nil { reserved += 64 }
        if !showsHome, browser.currentURL != nil { reserved += 34 }
        return max(60, width - reserved)
    }

    private var subtitle: String {
        BrowserChrome.displayHost(browser.currentURL)
    }

    private var accessibilityTitle: Text {
        if showsHome { return Text("Search or enter a forum address", comment: "iPhone bar on Home: placeholder of the search and address field") }
        return Text(verbatim: "\(browser.pageTitle), \(BrowserChrome.displayAddress(browser.currentURL))")
    }

    private var accessibilityHint: Text {
        Text("Tap to enter a forum address. Touch and hold for history.", comment: "Accessibility hint of the iPhone bar title")
    }

    @ViewBuilder
    private var historyMenu: some View {
        let back = Array(browser.backHistory.prefix(12))
        let forward = Array(browser.forwardHistory.prefix(12))
        if !forward.isEmpty {
            Section("Forward") {
                ForEach(forward.reversed(), id: \.self) { historyItem($0) }
            }
        }
        if !back.isEmpty {
            Section("Back") {
                ForEach(back, id: \.self) { historyItem($0) }
            }
        }
        if back.isEmpty, forward.isEmpty {
            Text("No history yet", comment: "iPhone bar title's history menu with no pages to go back or forward to")
        }
    }

    private func historyItem(_ item: WKBackForwardListItem) -> some View {
        Button {
            browser.go(to: item)
        } label: {
            Text(item.title?.isEmpty == false ? item.title ?? "" : BrowserChrome.displayHost(item.url))
            Text(BrowserChrome.displayAddress(item.url))
        }
    }

    /// "Solved · answer at #N": jumps to the accepted answer.
    private func answerChip(_ number: Int) -> some View {
        Button {
            // The same jump as a citation in the drawer (§4.5).
            app.jumpToCitation(number)
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.caption.weight(.semibold))
                Text(verbatim: "#\(number)")
                    .font(.caption.weight(.semibold).monospacedDigit())
            }
            .fixedSize()
            .foregroundStyle(DCTheme.success)
            .padding(.horizontal, 8)
            .frame(minHeight: 30)
            .background(DCTheme.success.opacity(0.12), in: Capsule())
            .frame(minHeight: DCTheme.controlHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Solved · answer at #\(number)", comment: "iPhone bar hint: the topic has an accepted answer; the placeholder is its post number"))
        .accessibilityHint(Text("Jumps to the answer", comment: "Accessibility hint of the solved hint in the iPhone bar"))
        .accessibilityIdentifier("acceptedAnswerHint")
    }
}

/// Shield at the end of the title: shows whether ads are blocked here and
/// toggles the site. Blocking is off by default; then the shield is neutral
/// and offers to turn it on.
struct AdShieldMenu: View {
    @ObservedObject var app: AppModel
    @ObservedObject var browser: ForumBrowserModel

    var body: some View {
        let blocking = SiteBlocking(app: app, url: browser.currentURL)
        Menu {
            Section(blocking.statusTitle) {
                if blocking.status == .off {
                    Button {
                        DCHaptics.tap()
                        app.turnOnContentBlocking()
                    } label: {
                        Label("Turn on ad blocking", systemImage: "shield.lefthalf.filled")
                    }
                    .accessibilityIdentifier("shieldTurnOnBlocking")
                }
                if let toggle = blocking.toggle {
                    Button(action: toggle.action) {
                        Label(toggle.title, systemImage: toggle.systemImage)
                    }
                    .accessibilityIdentifier("shieldToggleAdsOnSite")
                }
            }
        } label: {
            Image(systemName: blocking.symbol)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(blocking.tint)
                .frame(width: 30, height: DCTheme.controlHeight)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(blocking.statusTitle)
        .accessibilityIdentifier("contentBlockingShield")
    }
}

/// Ad blocking on the current site, for the shield and the forum menu.
@MainActor
struct SiteBlocking {
    let app: AppModel
    let url: URL?

    var status: ContentBlockingStatus { app.contentBlockingStatus(for: url) }

    var statusTitle: String {
        switch status {
        case .off: String(localized: "Ad blocking is off")
        case .blocking(let ads, _):
            ads ? String(localized: "Ads blocked on this site") : String(localized: "Trackers blocked on this site")
        case .allowedSite: String(localized: "Ads allowed on this site")
        case .signInPage: String(localized: "Nothing blocked on sign-in pages")
        }
    }

    var symbol: String {
        switch status {
        case .blocking: "shield.lefthalf.filled"
        case .off: "shield"
        case .allowedSite, .signInPage: "shield.slash"
        }
    }

    var tint: Color {
        if case .blocking = status { return DCTheme.success }
        return .secondary
    }

    /// Allow / block ads on the current site (nil when it doesn't apply).
    var toggle: (title: String, systemImage: String, action: () -> Void)? {
        guard let host = url?.host.flatMap(ContentBlockingRules.normalizedHost) else { return nil }
        let app = app, url = url
        switch status {
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

    /// The forum menu's "Block Ads on This Site" switch: on while this page
    /// is filtered. Turning it on with blocking off turns blocking on.
    var isBlockingHere: Binding<Bool>? {
        guard url?.host.flatMap(ContentBlockingRules.normalizedHost) != nil, status != .signInPage else { return nil }
        let app = app, url = url, status = status
        return Binding(
            get: { if case .blocking = status { return true } else { return false } },
            set: { blocks in
                DCHaptics.tap()
                if blocks {
                    app.setAdsAllowed(false, on: url)
                    if status == .off { app.turnOnContentBlocking() }
                } else {
                    app.setAdsAllowed(true, on: url)
                }
            }
        )
    }
}

// MARK: - AI button

/// Opens the drawer at medium; a long press starts voice (when set up).
struct PhoneAIButton: View {
    @ObservedObject var app: AppModel
    @ObservedObject var voice: VoiceController
    let isAvailable: Bool
    let onOpen: () -> Void

    private var canTalk: Bool { app.showsVoiceButton }

    var body: some View {
        Image(systemName: voice.isActive ? "waveform" : "sparkles")
            .font(.body.weight(.semibold))
            .foregroundStyle(isAvailable ? AnyShapeStyle(DCTheme.brandGradient) : AnyShapeStyle(.tertiary))
            .symbolEffect(.pulse, isActive: voice.isActive)
            .frame(width: DCTheme.controlHeight, height: DCTheme.controlHeight)
            .contentShape(Circle())
            .onTapGesture {
                guard isAvailable else { return }
                onOpen()
            }
            .onLongPressGesture(minimumDuration: 0.45) {
                guard canTalk else { return }
                DCHaptics.tap()
                voice.toggle()
            }
            .accessibilityElement()
            .accessibilityLabel(Text("AI assistant", comment: "iPhone browser bar button that opens the AI drawer"))
            .accessibilityHint(canTalk ? Text("Touch and hold to talk to Forumind", comment: "Accessibility hint of the iPhone AI button when voice is set up") : Text(verbatim: ""))
            .accessibilityAddTraits(.isButton)
            .accessibilityRemoveTraits(isAvailable ? [] : .isButton)
            .accessibilityAction { if isAvailable { onOpen() } }
            .accessibilityActions {
                if canTalk {
                    Button(voice.isActive ? "End voice" : "Talk to Forumind") { voice.toggle() }
                }
            }
            .accessibilityIdentifier("aiButton")
    }
}

// MARK: - Forum menu

/// The forum avatar; its menu (spec §4.3): the forum and account, page
/// navigation, page actions, ad blocking, report or block, other forums and
/// Home.
struct ForumMenuButton: View {
    @ObservedObject var app: AppModel
    @ObservedObject var browser: ForumBrowserModel
    @ObservedObject var voice: VoiceController
    let actions: BrowserActions
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var forum: Forum? { app.barForum }
    private var showsHome: Bool { browser.showsForumsHome }
    private var pageURL: URL? { showsHome ? nil : browser.currentURL }
    private var topic: ForumTopic? { showsHome ? nil : browser.pageContext.topic }

    var body: some View {
        Menu {
            headerSection
            ControlGroup {
                Button(action: goBack) { Label("Back", systemImage: "chevron.backward") }
                    .disabled(!canGoBack)
                Button(action: browser.goForward) { Label("Forward", systemImage: "chevron.forward") }
                    .disabled(!browser.canGoForward || showsHome)
                if browser.isLoading, !showsHome {
                    Button(action: browser.stopLoading) { Label("Stop loading", systemImage: "xmark") }
                } else {
                    Button(action: browser.reload) { Label("Reload", systemImage: "arrow.clockwise") }
                        .disabled(pageURL == nil)
                }
                Button(action: goHome) { Label(homeLabel, systemImage: "house") }
                    .accessibilityIdentifier("browserHome")
            }
            pageSection
            if let pageURL {
                Section {
                    ShareLink(item: pageURL) {
                        Label("Share Page", systemImage: "square.and.arrow.up")
                    }
                    Button {
                        UIPasteboard.general.url = pageURL
                        DCHaptics.success()
                    } label: {
                        Label("Copy Link", systemImage: "link")
                    }
                }
            }
            if pageURL != nil, let blocks = SiteBlocking(app: app, url: pageURL).isBlockingHere {
                Toggle(isOn: blocks) {
                    Label("Block Ads on This Site", systemImage: "shield.lefthalf.filled")
                }
                .accessibilityIdentifier("menuToggleAdsOnSite")
            }
            if let topic {
                Button {
                    actions.report(topic)
                } label: {
                    Label("Report or block…", systemImage: "flag")
                }
                .accessibilityIdentifier("menuReportOrBlock")
            }
            switchSection
            Section {
                Button(action: actions.showForumsHome) {
                    Label("Home · Today & all forums", systemImage: "square.grid.2x2")
                }
                .accessibilityIdentifier("switcherAllForums")
                if let openPanel = actions.openPanel {
                    Button { openPanel(.activity) } label: {
                        Label("Manage", systemImage: "tray.full")
                    }
                }
            }
        } label: {
            avatar
        }
        .menuOrder(.fixed)
        .accessibilityLabel(forum.map { String(localized: "Forum: \($0.displayName)") } ?? String(localized: "Forums"))
        .accessibilityHint(Text("Forum menu", comment: "Accessibility hint of the iPhone bar's forum avatar"))
        .accessibilityIdentifier("forumSwitcher")
    }

    private var avatar: some View {
        Group {
            if let forum {
                ForumIcon(forum: forum, size: 30)
            } else {
                Image(systemName: "square.grid.2x2.fill")
                    .font(.body)
                    .foregroundStyle(DCTheme.brandGradient)
                    .frame(width: 30, height: 30)
            }
        }
        .frame(width: DCTheme.controlHeight, height: DCTheme.controlHeight)
        .contentShape(Circle())
    }

    // MARK: Sections

    @ViewBuilder
    private var headerSection: some View {
        Section {
            if let forum {
                Button(action: openAccount) {
                    Text(forum.displayName)
                    Text(accountLine(for: forum))
                    Image(systemName: browser.isAuthenticated ? "person.crop.circle.fill" : "person.badge.key")
                }
                .accessibilityIdentifier("forumMenuAccount")
                Button(action: actions.showLoginInfo) {
                    Label("Sign-in help", systemImage: "questionmark.circle")
                }
            }
            if let openPanel = actions.openPanel {
                Button { openPanel(.settings) } label: {
                    Label("Settings", systemImage: "gearshape")
                }
            }
        }
    }

    @ViewBuilder
    private var pageSection: some View {
        Section {
            if let topic = app.currentTopic, self.topic != nil {
                Button(action: app.toggleWatchCurrentTopic) {
                    if app.isWatched(topicKey: topic.topicKey) {
                        Label("Unwatch topic", systemImage: "eye.slash")
                    } else {
                        Label("Watch this topic", systemImage: "eye")
                    }
                }
            }
            if self.topic != nil, ReadingLanguage.isTranslationAvailable {
                Button(action: actions.translatePosts) {
                    Label("Translate Posts on Screen", systemImage: "translate")
                }
                .accessibilityIdentifier("menuTranslatePosts")
            }
            // Voice also starts from a long press on the AI button.
            if app.showsVoiceButton {
                Button {
                    voice.toggle()
                } label: {
                    if voice.isActive {
                        Label("End voice", systemImage: "mic.slash")
                    } else {
                        Label("Talk to Forumind", systemImage: "mic")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var switchSection: some View {
        let pinned = app.pinnedForums
        let recents = app.recentForums.filter { recent in !pinned.contains { $0.siteURL == recent.siteURL } }.prefix(5)
        Section("Switch forum") {
            ForEach(pinned + recents) { other in
                Button {
                    actions.openForum(other)
                } label: {
                    Label(other.displayName, systemImage: app.isCurrent(other) ? "checkmark" : Self.letterSymbol(for: other))
                }
            }
            Button(action: actions.addForum) {
                Label("Add Forum…", systemImage: "plus")
            }
        }
    }

    // MARK: Actions

    private var homeLabel: String {
        forum.map { String(localized: "\($0.displayName) home", comment: "Button label: the forum's home page (forum name)") }
            ?? String(localized: "Forums")
    }

    private func accountLine(for forum: Forum) -> String {
        guard browser.isAuthenticated else {
            return String(localized: "\(forum.host) · Not signed in", comment: "Forum menu header; the placeholder is the forum's host")
        }
        if let name = browser.signedInUsername {
            return String(localized: "\(forum.host) · Logged in as \(name)", comment: "Forum menu header; placeholders: the forum's host, the user's forum username")
        }
        return String(localized: "\(forum.host) · Signed in", comment: "Forum menu header; the placeholder is the forum's host")
    }

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

    private func goHome() {
        withAnimation(DCMotion.respecting(reduceMotion)) { app.goHome() }
    }

    /// Signed in: the forum's home; otherwise its sign-in page.
    private func openAccount() {
        let opened = browser.isAuthenticated ? browser.loadHome() : browser.loadLogin()
        if !opened { actions.showForumsHome() }
    }

    /// A letter tile symbol for menus (they take symbols, not views).
    static func letterSymbol(for forum: Forum) -> String {
        let initial = ForumIcon.initial(of: forum.displayName, siteURL: forum.siteURL).lowercased()
        guard let character = initial.first, character.isASCII, character.isLetter || character.isNumber else {
            return "globe"
        }
        return "\(character).square.fill"
    }
}
