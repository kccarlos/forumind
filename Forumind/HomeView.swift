import SwiftUI

// MARK: - Home (spec §7.1)
//
// Replaces the Forums home and the Today sheet. Fixed order: the Today module
// (TodayModuleState, HomeState.swift), Continue reading, the pinned forums,
// Watching, Recent, then suggested forums only while the user has few. With
// no forums: Start with a forum, the suggestions and "Share from Safari or
// Chrome". Shown over the web view (BrowserContent), which stays loaded under
// it. Pages pushed over Home (`HomeRoute`) live in `AppModel.homePath`: on
// iPhone in the bar's NavigationStack (PhoneBrowserBar.swift), on iPad in a
// stack of Home's own.

struct HomeView: View {
    @ObservedObject var app: AppModel
    @ObservedObject var browser: ForumBrowserModel
    @ObservedObject var podcast: PodcastController
    let actions: BrowserActions

    init(app: AppModel, actions: BrowserActions) {
        self.app = app
        browser = app.browser
        podcast = app.podcast
        self.actions = actions
    }

    var body: some View {
        // The pages pushed over Home go on the bar's stack (PhoneBrowser).
        HomeList(app: app, browser: browser, podcast: podcast, actions: actions)
    }
}

/// The pages pushed over Home. On the view at the root of the stack that
/// holds `app.homePath`, mounted whether Home shows or not.
struct HomeDestinations: ViewModifier {
    @ObservedObject var app: AppModel
    let onOpenDigestLink: (URL, DigestCard) -> Void

    func body(content: Content) -> some View {
        content.navigationDestination(for: HomeRoute.self) { route in
            switch route {
            case .today:
                TodayPage(app: app, onOpen: onOpenDigestLink)
            case .digest(let id):
                if let digest = app.digests.first(where: { $0.id == id }) {
                    DigestHistoryPage(app: app, digest: digest, onOpen: onOpenDigestLink)
                        .toolbar(.visible, for: .navigationBar)
                }
            case .digestSettings:
                SettingsDigestPage(app: app)
                    .navigationTitle(SettingsPage.digest.title)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar(.visible, for: .navigationBar)
            }
        }
    }
}

private struct HomeList: View {
    @ObservedObject var app: AppModel
    @ObservedObject var browser: ForumBrowserModel
    @ObservedObject var podcast: PodcastController
    let actions: BrowserActions
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .body) private var tileWidth: CGFloat = 104
    @State private var forumToRemove: Forum?
    @State private var showingPinnedEditor = false
    @State private var addingSuggested: Set<String> = []

    private var hasForums: Bool { !app.forums.isEmpty }

    var body: some View {
        List {
            header
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: DCTheme.spacingS, leading: 4, bottom: 0, trailing: 4))

            if hasForums {
                TodayModule(app: app, podcast: podcast, onOpen: actions.openDigestLink)
                continueReadingSection
                pinnedSection
                watchingSection
                recentSection
                if HomeSections.showsSuggestions(forumCount: app.forums.count) { suggestedSection }
            } else {
                welcome
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                suggestedSection
                shareCard
            }
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(.compact)
        .contentMargins(.top, DCTheme.spacingXS, for: .scrollContent)
        .scrollContentBackground(.hidden)
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity)
        .background(DCTheme.pageBackground)
        .animation(DCMotion.respecting(reduceMotion, DCMotion.smooth), value: app.forums)
        .animation(DCMotion.respecting(reduceMotion, DCMotion.smooth), value: app.todayModuleState)
        .sheet(isPresented: $showingPinnedEditor) {
            PinnedForumsEditor(app: app)
        }
        .task { podcast.refresh() }
        .accessibilityIdentifier("home")
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .bottom, spacing: DCTheme.spacingS) {
            VStack(alignment: .leading, spacing: 2) {
                Text(Date().formatted(.dateTime.weekday(.wide).month(.wide).day()).uppercased())
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("Home", comment: "Title of the Home screen")
                    .font(.largeTitle.weight(.heavy))
                    .foregroundStyle(DCTheme.brandInk)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            headerButton("clock.arrow.circlepath", Text("History", comment: "Home button: the history of summaries, chats and Ask the forum runs"), id: "homeHistory", action: actions.openHistory)
            headerButton("gearshape", Text("Settings"), id: "homeSettings", action: actions.openSettings)
        }
        .padding(.bottom, DCTheme.spacingXS)
    }

    private func headerButton(_ symbol: String, _ label: Text, id: String, action: @escaping () -> Void) -> some View {
        Button {
            DCHaptics.tap()
            action()
        } label: {
            Image(systemName: symbol)
                .font(.title3.weight(.medium))
                .frame(width: DCTheme.controlHeight, height: DCTheme.controlHeight)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .foregroundStyle(.primary)
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
    }

    // MARK: Continue reading

    @ViewBuilder
    private var continueReadingSection: some View {
        let sessions = HomeSections.continueReading(Array(app.sessions.values))
        if !sessions.isEmpty {
            Section {
                ForEach(sessions) { session in
                    Button {
                        DCHaptics.tap()
                        app.openTopic(topicKey: session.topicKey)
                    } label: {
                        ContinueReadingRow(session: session, forum: app.forumInfo(siteURL: session.siteURL))
                    }
                    .tint(.primary)
                    .accessibilityIdentifier("continueReading-\(session.topicID)")
                }
            } header: {
                Text("Continue reading", comment: "Home section: the topics read last")
            }
            .headerProminence(.increased)
        }
    }

    // MARK: Pinned

    @ViewBuilder
    private var pinnedSection: some View {
        Section {
            if app.pinnedForums.isEmpty {
                HStack(spacing: DCTheme.spacingM) {
                    Image(systemName: "pin")
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 36)
                    Text("Pin forums you read often for one-tap access. Swipe right on a recent forum, or use its menu.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, DCTheme.spacingXS)
            } else {
                pinnedGrid
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: DCTheme.spacingXS, leading: 0, bottom: DCTheme.spacingXS, trailing: 0))
            }
            Button(action: actions.addForum) {
                Label {
                    Text("Add a forum by address…")
                } icon: {
                    Image(systemName: "plus.circle.fill")
                        .foregroundStyle(Color.accentColor)
                }
            }
            .accessibilityIdentifier("homeAddForum")
        } header: {
            HStack {
                Text("Forums", comment: "Home section: the pinned forums")
                Spacer()
                if app.pinnedForums.count > 1 {
                    Button("Edit") { showingPinnedEditor = true }
                        .font(.subheadline.weight(.semibold))
                        .textCase(nil)
                        .accessibilityLabel("Edit pinned forums")
                        .accessibilityIdentifier("editPinnedForums")
                }
            }
        }
        .headerProminence(.increased)
    }

    private var pinnedGrid: some View {
        let width = dynamicTypeSize.isAccessibilitySize ? max(tileWidth, 150) : tileWidth
        return LazyVGrid(
            columns: [GridItem(.adaptive(minimum: width, maximum: width * 1.6), spacing: DCTheme.spacingM)],
            spacing: DCTheme.spacingM
        ) {
            ForEach(app.pinnedForums) { forum in
                Button { open(forum) } label: {
                    ForumTile(forum: forum, isCurrent: browser.currentURL != nil && app.isCurrent(forum))
                }
                .buttonStyle(TilePressStyle())
                .contextMenu { pinnedMenu(forum) } preview: {
                    ForumTile(forum: forum).frame(width: 150, height: 150)
                }
                .draggable(forum.siteURL) {
                    ForumIcon(forum: forum, size: 56)
                }
                .dropDestination(for: String.self) { items, _ in
                    guard let dropped = items.first else { return false }
                    return movePinned(dropped, onto: forum)
                }
                // The dialog is a popover on iPad; anchor it to this tile.
                .forumRemovalDialog($forumToRemove, app: app, for: forum)
                .accessibilityIdentifier("pinnedForum-\(forum.host)")
                .accessibilityAction(named: "Unpin") { app.unpin(forum) }
                .accessibilityAction(named: "Ask the forum") { app.askForum(forum) }
            }
        }
    }

    @ViewBuilder
    private func pinnedMenu(_ forum: Forum) -> some View {
        Button { open(forum) } label: { Label("Open", systemImage: "arrow.up.forward.app") }
        Button { app.askForum(forum) } label: { Label("Ask the Forum", systemImage: "sparkle.magnifyingglass") }
        Button { withAnimation(DCMotion.smooth) { app.unpin(forum) } } label: {
            Label("Unpin", systemImage: "pin.slash")
        }
        if app.pinnedForums.count > 1 {
            Button { showingPinnedEditor = true } label: {
                Label("Reorder Pinned…", systemImage: "arrow.up.arrow.down")
            }
        }
        Divider()
        Button(role: .destructive) { confirmRemoval(forum) } label: {
            Label("Remove…", systemImage: "trash")
        }
    }

    /// From a context menu: present the dialog once the menu has dismissed.
    /// Set during the dismissal, the dialog (a popover on iPad) is dropped
    /// and the binding resets, so "Remove Forum" never appears.
    private func confirmRemoval(_ forum: Forum) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            forumToRemove = forum
        }
    }

    private func movePinned(_ siteURL: String, onto target: Forum) -> Bool {
        let pinned = app.pinnedForums
        guard let from = pinned.firstIndex(where: { $0.siteURL == siteURL }),
              let to = pinned.firstIndex(where: { $0.siteURL == target.siteURL }),
              from != to
        else {
            return false
        }
        DCHaptics.tap()
        withAnimation(DCMotion.respecting(reduceMotion, DCMotion.spring)) {
            app.movePinned(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        }
        return true
    }

    // MARK: Watching

    @ViewBuilder
    private var watchingSection: some View {
        let watching = HomeSections.watching(app.watchedTopics)
        if !watching.isEmpty {
            Section {
                ForEach(watching) { watched in
                    Button {
                        DCHaptics.tap()
                        app.openWatched(watched)
                    } label: {
                        HStack(spacing: DCTheme.spacingM) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(watched.title)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.primary)
                                    .lineLimit(2)
                                Text(app.forumInfo(siteURL: watched.siteURL).displayName)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: DCTheme.spacingS)
                            NewRepliesBadge(text: String(localized: "\(watched.newReplies) new", comment: "Badge: number of new replies in a watched topic"))
                        }
                        .contentShape(Rectangle())
                    }
                    .tint(.primary)
                    .accessibilityIdentifier("watching-\(watched.topicID)")
                }
            } header: {
                HStack {
                    Text("Watching", comment: "Home section: watched topics with new replies")
                    Spacer()
                    Text("\(watching.count) with new replies", comment: "Home Watching section: how many watched topics have new replies")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .textCase(nil)
                        .contentTransition(.numericText())
                }
            }
            .headerProminence(.increased)
        }
    }

    // MARK: Recent

    @ViewBuilder
    private var recentSection: some View {
        if !app.recentForums.isEmpty {
            Section {
                ForEach(app.recentForums) { forum in
                    Button { open(forum) } label: {
                        ForumRow(forum: forum, detail: visitedText(forum))
                    }
                    .tint(.primary)
                    .swipeActions(edge: .leading, allowsFullSwipe: true) {
                        Button { withAnimation(DCMotion.smooth) { app.pin(forum) } } label: {
                            Label("Pin", systemImage: "pin")
                        }
                        .tint(DCTheme.brandBlue)
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) { forumToRemove = forum } label: {
                            Label("Remove", systemImage: "trash")
                        }
                    }
                    .contextMenu {
                        Button { open(forum) } label: { Label("Open", systemImage: "arrow.up.forward.app") }
                        Button { app.askForum(forum) } label: {
                            Label("Ask the Forum", systemImage: "sparkle.magnifyingglass")
                        }
                        Button { withAnimation(DCMotion.smooth) { app.pin(forum) } } label: {
                            Label("Pin", systemImage: "pin")
                        }
                        Divider()
                        Button(role: .destructive) { confirmRemoval(forum) } label: {
                            Label("Remove…", systemImage: "trash")
                        }
                    } preview: {
                        ForumTile(forum: forum).frame(width: 180, height: 150)
                    }
                    .forumRemovalDialog($forumToRemove, app: app, for: forum)
                    .accessibilityAction(named: "Pin") { app.pin(forum) }
                    .accessibilityAction(named: "Remove") { forumToRemove = forum }
                    .accessibilityIdentifier("recentForum-\(forum.host)")
                }
            } header: {
                Text("Recent")
            }
            .headerProminence(.increased)
        }
    }

    private func visitedText(_ forum: Forum) -> String {
        guard let visited = forum.lastVisitedAt else { return forum.host }
        if Date().timeIntervalSince(visited) < 60 {
            return String(localized: "\(forum.host) · just now", comment: "Recent forum row: the forum's host, then when it was visited")
        }
        let relative = visited.formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
        return "\(forum.host) · \(relative)"
    }

    // MARK: Suggested

    @ViewBuilder
    private var suggestedSection: some View {
        let suggestions = app.suggestedForumsToOffer
        if !suggestions.isEmpty {
            Section {
                ForEach(suggestions) { suggested in
                    suggestedRow(suggested)
                }
            } header: {
                Text("Suggested")
            } footer: {
                if !hasForums {
                    Text("Tap a forum to open it, or pin it to keep it here.")
                }
            }
            .headerProminence(.increased)
        }
    }

    private func suggestedRow(_ suggested: SuggestedForum) -> some View {
        HStack(spacing: DCTheme.spacingM) {
            Button { app.openForum(suggested) } label: {
                HStack(spacing: DCTheme.spacingM) {
                    ForumIcon(suggested: suggested, size: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(suggested.name)
                            .font(.body.weight(.medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text(suggested.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityHint("Opens \(suggested.host)")

            Button {
                DCHaptics.tap()
                withAnimation(DCMotion.respecting(reduceMotion)) { app.pinSuggested(suggested) }
            } label: {
                Text("Pin")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 14)
                    .frame(minHeight: 34)
                    .background(Color.accentColor.opacity(0.12), in: Capsule())
                    .frame(minHeight: DCTheme.controlHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .hoverEffect(.highlight)
            .foregroundStyle(Color.accentColor)
            .fixedSize()
            .accessibilityLabel("Pin \(suggested.name)")
            .accessibilityIdentifier("pinSuggested-\(suggested.host)")
        }
        .contextMenu {
            Button { app.openForum(suggested) } label: { Label("Open", systemImage: "arrow.up.forward.app") }
            Button { app.pinSuggested(suggested) } label: { Label("Pin", systemImage: "pin") }
            Button { addSuggested(suggested) } label: { Label("Add to Recent", systemImage: "plus") }
        }
        .swipeActions(edge: .trailing) {
            Button { addSuggested(suggested) } label: { Label("Add", systemImage: "plus") }
                .tint(DCTheme.chatTint)
        }
    }

    private func addSuggested(_ suggested: SuggestedForum) {
        guard addingSuggested.insert(suggested.siteURL).inserted else { return }
        Task {
            _ = try? await app.addForum(fromAddress: suggested.siteURL, pin: false)
            addingSuggested.remove(suggested.siteURL)
        }
    }

    // MARK: No forums yet

    private var welcome: some View {
        VStack(alignment: .leading, spacing: DCTheme.spacingM) {
            BrandMark(size: 52)
            Text("Start with a forum")
                .font(.title2.weight(.heavy))
            Text("Open any forum or article to summarize long topics, chat about them, or ask the whole forum a question.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: actions.addForum) {
                Text("Add a forum by address", comment: "Home with no forums: the main button")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(DCPrimaryButtonStyle())
            .accessibilityIdentifier("homeAddFirstForum")
            .padding(.top, DCTheme.spacingXS)
        }
        .dcCard()
        .padding(.vertical, DCTheme.spacingS)
    }

    /// "Share from Safari or Chrome": opens the Share how-to page.
    private var shareCard: some View {
        Section {
            Button {
                actions.showShareHowTo?()
            } label: {
                HStack(alignment: .top, spacing: DCTheme.spacingM) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(DCTheme.brandPurple)
                        .frame(width: 28)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Share from Safari or Chrome")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text("Share any forum page to Forumind to open it here, summarize it, or ask about it.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    if actions.showShareHowTo != nil {
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Color(uiColor: .tertiaryLabel))
                    }
                }
                .padding(.vertical, DCTheme.spacingXS)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(actions.showShareHowTo == nil)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("homeShareHowTo")
        }
        .listRowBackground(DCTheme.brandPurple.opacity(0.08))
    }

    private func open(_ forum: Forum) {
        DCHaptics.tap()
        actions.openForum(forum)
    }
}

// MARK: - Today module

/// The Today module at the top of Home, in one of its 7 states: the big
/// podcast card, the digest strip, or one row.
private struct TodayModule: View {
    @ObservedObject var app: AppModel
    @ObservedObject var podcast: PodcastController
    let onOpen: (URL, DigestCard) -> Void

    var body: some View {
        let state = app.todayModuleState
        Section {
            switch state {
            case .podcastReady, .podcastInProgress:
                if let episode = podcast.episode, let digest = app.todaysDigest {
                    PodcastHomeCard(app: app, podcast: podcast, episode: episode, digest: digest, isMaking: state == .podcastInProgress)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: DCTheme.spacingXS, leading: 0, bottom: DCTheme.spacingXS, trailing: 0))
                }
            case .digestReady, .digestInProgress:
                if let digest = app.todaysDigest {
                    digestHeader(digest, state: state)
                    let shown = digest.cards.filter { $0.state == .done }
                    if !shown.isEmpty {
                        DigestStrip(app: app, cards: shown, onOpen: onOpen)
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: DCTheme.spacingXS, trailing: 0))
                    }
                } else {
                    // Preparing (or offline) before there are cards.
                    progressRow(state: state, digest: nil)
                }
            case .digestOff:
                row(
                    title: Text("Today", comment: "Home Today module title"),
                    detail: Text("Make a digest of today’s topics", comment: "Forums home Today row when the daily digest is off"),
                    action: (Text("Make", comment: "Home Today module: make today's digest"), {
                        DCHaptics.tap()
                        app.makeTodaysDigest()
                    }),
                    actionID: "homeTodayMake"
                )
            case .aiNotSetUp:
                row(
                    title: Text("Today", comment: "Home Today module title"),
                    detail: Text("Set up AI to get a daily digest", comment: "Home Today module when no AI model is ready"),
                    action: (Text("Set up", comment: "Home Today module: set up an AI model"), {
                        app.needsProviderSetup = .assistant
                    }),
                    actionID: "homeTodaySetUp"
                )
            case .nothingNew:
                row(
                    title: Text("Today", comment: "Home Today module title"),
                    detail: Text("Nothing new today", comment: "Daily digest with no topics"),
                    action: nil,
                    actionID: nil
                )
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("homeToday")
    }

    private func openToday() {
        DCHaptics.tap()
        app.showsTodayPage = true
    }

    /// "Today · 6 topics · made 7:02 AM" (a tap opens the Today page) and
    /// Listen: the cards read aloud with the podcast's voices (the device's
    /// by default, free).
    private func digestHeader(_ digest: DailyDigest, state: TodayModuleState) -> some View {
        HStack(spacing: DCTheme.spacingM) {
            Button(action: openToday) {
                HStack(spacing: DCTheme.spacingM) {
                    DigestIcon(size: 30)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Today", comment: "Home Today module title")
                            .font(.headline)
                            .foregroundStyle(.primary)
                        statusText(state: state, digest: digest)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .contentTransition(.numericText())
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityHint(Text("Opens today’s digest"))
            .accessibilityIdentifier("homeTodayOpen")
            if state == .digestReady {
                ReadAloudButton(podcast: podcast, id: "today-digest", title: String(localized: "Today"), text: readAloudText(digest))
                    .font(.subheadline.weight(.semibold))
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .fixedSize()
            } else if case .digestInProgress(offline: false) = state {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.vertical, 2)
    }

    private func progressRow(state: TodayModuleState, digest: DailyDigest?) -> some View {
        Button(action: openToday) {
            HStack(spacing: DCTheme.spacingM) {
                DigestIcon(size: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Today", comment: "Home Today module title")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    statusText(state: state, digest: digest)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if case .digestInProgress(offline: false) = state { ProgressView().controlSize(.small) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("homeTodayOpen")
    }

    private func statusText(state: TodayModuleState, digest: DailyDigest?) -> Text {
        if case .digestInProgress(offline: true) = state {
            return Text("Can’t reach your forums. It continues when you’re back online.", comment: "Home Today module: the digest is paused while offline")
        }
        guard let digest else {
            return Text("Checking your forums…", comment: "Daily digest: reading the forums' topic lists before summarizing")
        }
        if !digest.isComplete {
            return Text("\(digest.finishedCount) of \(digest.cards.count) ready", comment: "Daily digest progress: cards summarized so far, then the number of cards")
        }
        let made = (digest.completedAt ?? digest.createdAt).formatted(date: .omitted, time: .shortened)
        return Text("\(digest.cards.count) topics · made \(made)", comment: "Home Today module: number of digest cards, then when the digest was made")
    }

    private func readAloudText(_ digest: DailyDigest) -> String {
        digest.cards
            .filter { $0.state == .done && !$0.summary.isEmpty }
            .map { "\($0.title).\n\($0.summary)" }
            .joined(separator: "\n\n")
    }

    /// One row: Digest off, AI not set up, Nothing new. The row opens the
    /// Today page (Earlier, digest settings); the button does its action.
    private func row(title: Text, detail: Text, action: (Text, () -> Void)?, actionID: String?) -> some View {
        HStack(spacing: DCTheme.spacingM) {
            Button(action: openToday) {
                HStack(spacing: DCTheme.spacingM) {
                    DigestIcon(size: 30)
                    VStack(alignment: .leading, spacing: 1) {
                        title
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        detail
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityHint(Text("Opens today’s digest"))
            .accessibilityIdentifier("homeTodayOpen")
            if let action {
                Button(action: action.1) {
                    action.0
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 14)
                        .frame(minHeight: 34)
                        .background(Color.accentColor.opacity(0.12), in: Capsule())
                        .frame(minHeight: DCTheme.controlHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Color.accentColor)
                .fixedSize()
                .accessibilityIdentifier(actionID ?? "")
            }
        }
    }
}

/// "Listen to today": the big card for a made (or growing) episode. Play
/// starts as soon as the first chapter is spoken.
private struct PodcastHomeCard: View {
    @ObservedObject var app: AppModel
    @ObservedObject var podcast: PodcastController
    let episode: PodcastEpisode
    let digest: DailyDigest
    let isMaking: Bool

    private var facts: PodcastCardFacts { PodcastCardFacts(episode: episode) }
    private var isPlaying: Bool { podcast.isPlayingEpisode && podcast.player.isActive }

    var body: some View {
        VStack(alignment: .leading, spacing: DCTheme.spacingM) {
            HStack(spacing: DCTheme.spacingL) {
                Button {
                    DCHaptics.tap()
                    if podcast.isPlayingEpisode { podcast.player.toggle() } else { podcast.playEpisode() }
                } label: {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.title2)
                        .foregroundStyle(HomeStyle.podcastCard)
                        .frame(width: 56, height: 56)
                        .background(.white, in: Circle())
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
                .disabled(!episode.hasAudio)
                .opacity(episode.hasAudio ? 1 : 0.5)
                .accessibilityLabel(isPlaying ? Text("Pause") : Text("Play today’s podcast", comment: "Home podcast card: play button"))
                .accessibilityIdentifier("homePodcastPlay")

                VStack(alignment: .leading, spacing: 3) {
                    Text("Listen to today", comment: "Today page: the podcast section's title")
                        .font(.title3.weight(.bold))
                    subtitle
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.78))
                        .contentTransition(.numericText())
                        .accessibilityIdentifier("homePodcastFacts")
                }
                Spacer(minLength: 0)
            }
            if isMaking {
                ProgressView(value: Double(facts.readyChapters), total: Double(max(facts.chapters, 1)))
                    .tint(.white)
                    .accessibilityLabel(Text("Making the podcast", comment: "Home podcast card: progress bar while chapters are being made"))
            }
            Divider().overlay(.white.opacity(0.15))
            HStack {
                Text(reasons)
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.78))
                    .lineLimit(1)
                Spacer(minLength: DCTheme.spacingS)
                Button {
                    DCHaptics.tap()
                    app.showsTodayPage = true
                } label: {
                    Text("Read \(digest.cards.count) topics", comment: "Home podcast card: opens the Today page; the placeholder is the number of topics")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 14)
                        .frame(minHeight: 36)
                        .background(.white.opacity(0.14), in: Capsule())
                        .frame(minHeight: DCTheme.controlHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .fixedSize()
                .accessibilityIdentifier("homeReadTopics")
            }
        }
        .foregroundStyle(.white)
        .padding(DCTheme.spacingL)
        .background(HomeStyle.podcastCard, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("homePodcastCard")
    }

    /// "6 topics · about 8 min · Google voices"; while it's made, the chapters.
    private var subtitle: Text {
        if isMaking {
            return Text("\(facts.readyChapters) of \(facts.chapters) chapters ready", comment: "Home podcast card while the podcast is being made")
        }
        return Text("\(facts.topics) topics · about \(facts.minutes) min · \(episode.engine.label)", comment: "Home podcast card: number of topics, the podcast's length in minutes, then which voices read it (Google or on-device)")
    }

    private var reasons: String {
        let watched = digest.cards.filter { if case .newReplies = $0.reason { return true } else { return false } }.count
        let trending = digest.cards.count - watched
        return String(localized: "\(watched) watched · \(trending) trending", comment: "Home podcast card: digest cards from watched topics, then trending ones")
    }
}

/// Finished digest cards in a horizontal strip: forum, reason, title and a
/// two-line summary; a tap opens the topic.
private struct DigestStrip: View {
    @ObservedObject var app: AppModel
    let cards: [DigestCard]
    let onOpen: (URL, DigestCard) -> Void
    @ScaledMetric(relativeTo: .body) private var cardWidth: CGFloat = 272

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: DCTheme.spacingM) {
                ForEach(cards) { card in
                    Button { onOpen(app.url(for: card), card) } label: { cardView(card) }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("homeDigestCard-\(card.topicID)")
                        .transition(.opacity.combined(with: .offset(y: 8)))
                }
            }
            .padding(.horizontal, DCTheme.spacingL)
            .padding(.vertical, 2)
        }
        .scrollClipDisabled()
    }

    private func cardView(_ card: DigestCard) -> some View {
        let forum = app.forumInfo(siteURL: card.siteURL)
        return VStack(alignment: .leading, spacing: DCTheme.spacingS) {
            HStack(spacing: DCTheme.spacingS) {
                ForumIcon(forum: forum, size: 22)
                Text(forum.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: DCTheme.spacingXS)
                reason(card)
            }
            Text(card.title)
                .font(.headline)
                .foregroundStyle(.primary)
                .lineLimit(3)
                .multilineTextAlignment(.leading)
            Text(card.summary)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(width: cardWidth, alignment: .topLeading)
        .frame(minHeight: 150, alignment: .topLeading)
        .background(DCTheme.surface, in: RoundedRectangle(cornerRadius: DCTheme.cardCornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: DCTheme.cardCornerRadius, style: .continuous)
                .strokeBorder(DCTheme.border)
        }
        .contentShape(RoundedRectangle(cornerRadius: DCTheme.cardCornerRadius, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the topic")
    }

    @ViewBuilder
    private func reason(_ card: DigestCard) -> some View {
        switch card.reason {
        case .newReplies(let count):
            NewRepliesBadge(text: String(localized: "\(count) new replies", comment: "Digest card: why a watched topic is in the digest"))
        case .trending:
            DCPill(text: String(localized: "Trending", comment: "Digest card: the topic is among today's top topics of a pinned forum"),
                   tint: DCTheme.brandBlue)
        }
    }
}

// MARK: - Rows and styles

private struct ContinueReadingRow: View {
    let session: TopicSession
    let forum: Forum

    var body: some View {
        let newer = HomeSections.newerReplies(session)
        HStack(spacing: DCTheme.spacingM) {
            ForumIcon(forum: forum, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if newer > 0 {
                    Text("\(newer) newer replies", comment: "Home Continue reading: posts added since the topic was summarized")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(DCTheme.newRepliesBadgeText)
                        .contentTransition(.numericText())
                } else {
                    Text(verbatim: "\(forum.displayName) · \(session.lastSeenAt.formatted(.relative(presentation: .named, unitsStyle: .abbreviated)))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// The orange "12 new" badge.
private struct NewRepliesBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption.weight(.bold))
            .foregroundStyle(DCTheme.newRepliesBadgeText)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(DCTheme.newRepliesBadgeBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .lineLimit(1)
            .fixedSize()
            .contentTransition(.numericText())
    }
}

enum HomeStyle {
    /// The podcast card: deep ink in both appearances (it is the one dark
    /// card on Home).
    static let podcastCard = Color(light: 0x17132B, dark: 0x2A2541)
}

private struct TilePressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(.hoverEffect, RoundedRectangle(cornerRadius: DCTheme.cardCornerRadius, style: .continuous))
            .hoverEffect(.lift)
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(DCMotion.quick, value: configuration.isPressed)
    }
}
