import SwiftUI

/// What History shows, computed from the app's records: nothing here is
/// stored. `segment` picks which sections apply; `forum` (a site URL) narrows
/// every list, nil shows all forums.
struct HistoryFeed {
    enum Segment: String, CaseIterable, Identifiable {
        case all, summaries, asks, watching

        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: String(localized: "All", comment: "History segment: show everything")
            case .summaries: String(localized: "Summaries & chats", comment: "History segment")
            case .asks: String(localized: "Asks", comment: "History segment: Ask the forum runs")
            case .watching: String(localized: "Watching", comment: "History segment: watched topics")
            }
        }

        var systemImage: String {
            switch self {
            case .all: "square.stack"
            case .summaries: "text.alignleft"
            case .asks: "sparkle.magnifyingglass"
            case .watching: "eye"
            }
        }
    }

    /// Queued or running work (summaries, chats, pulls and Ask runs).
    let inProgress: [WorkRecord]
    /// Finished work that is not an Ask run (those show as `asks`).
    let recent: [WorkRecord]
    let saved: [TopicSession]
    /// Ask runs that are not in progress.
    let asks: [AgentRun]
    let watching: [WatchedTopic]

    static let recentLimit = 30

    init(
        forum: String?,
        activities: [WorkRecord],
        sessions: [TopicSession],
        runs: [AgentRun],
        watched: [WatchedTopic]
    ) {
        func matches(_ siteURL: String) -> Bool { forum == nil || forum == siteURL }
        let active = activities.filter { !$0.status.isTerminal && matches($0.siteURL) }
        let activeAskTopics = Set(active.filter { $0.type == .agent }.map(\.topicID))
        inProgress = active
        recent = Array(
            activities.filter { $0.status.isTerminal && $0.type != .agent && matches($0.siteURL) }
                .prefix(Self.recentLimit)
        )
        saved = sessions
            .filter { ($0.hasSummary || !$0.history.isEmpty) && matches($0.siteURL) }
            .sorted {
                if $0.kept != $1.kept { return $0.kept && !$1.kept }
                return $0.updatedAt > $1.updatedAt
            }
        asks = runs.filter { matches($0.siteURL) && !activeAskTopics.contains(AppModel.agentTopicPrefix + $0.id.uuidString) }
        watching = watched.filter { matches($0.siteURL) }
    }

    func inProgress(in segment: Segment) -> [WorkRecord] {
        switch segment {
        case .all: inProgress
        case .summaries: inProgress.filter { $0.type != .agent }
        case .asks: inProgress.filter { $0.type == .agent }
        case .watching: []
        }
    }

    func count(_ segment: Segment) -> Int {
        switch segment {
        case .all: inProgress.count + recent.count + saved.count + asks.count + watching.count
        case .summaries: saved.count
        case .asks: asks.count + inProgress.filter { $0.type == .agent }.count
        case .watching: watching.count
        }
    }

    /// Items grouped by forum in `forums` order; forums without items drop out.
    static func grouped<Item>(_ items: [Item], forums: [Forum], siteURL: (Item) -> String) -> [(Forum, [Item])] {
        forums.compactMap { forum in
            let matching = items.filter { siteURL($0) == forum.siteURL }
            return matching.isEmpty ? nil : (forum, matching)
        }
    }
}

/// History: work in progress, saved summaries and chats, Ask the forum runs
/// and watched topics, grouped by forum (pinned first) with a segment and a
/// forum filter. "All" keeps every section on one scrolling list.
struct HistoryView: View {
    @ObservedObject var app: AppModel
    @State private var pendingDeletion: TopicSession?
    @State private var segment: Segment = .all
    /// nil shows every forum.
    @State private var forumFilter: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    typealias Segment = HistoryFeed.Segment

    // MARK: Data

    private var feed: HistoryFeed {
        HistoryFeed(
            forum: forumFilter,
            activities: app.activities,
            sessions: Array(app.sessions.values),
            runs: app.agentRuns,
            watched: app.watchedTopics
        )
    }

    private var forums: [Forum] { app.manageForums }

    private func grouped<Item>(_ items: [Item], siteURL: (Item) -> String) -> [(Forum, [Item])] {
        HistoryFeed.grouped(items, forums: forums, siteURL: siteURL)
    }

    private var showsForumHeaders: Bool {
        forumFilter == nil && forums.count > 1
    }

    // MARK: Body

    var body: some View {
        let feed = feed
        VStack(spacing: 0) {
            filterBar(feed)
            Divider()
            List {
                let running = feed.inProgress(in: segment)
                switch segment {
                case .all:
                    inProgressSection(running)
                    savedSection(feed.saved)
                    asksSection(feed.asks)
                    watchingSection(feed.watching)
                    recentSection(feed.recent)
                case .summaries:
                    inProgressSection(running, showsEmpty: false)
                    savedSection(feed.saved)
                    recentSection(feed.recent)
                case .asks:
                    inProgressSection(running, showsEmpty: false)
                    asksSection(feed.asks)
                case .watching:
                    watchingSection(feed.watching)
                }
            }
            .listStyle(.insetGrouped)
            .animation(DCMotion.respecting(reduceMotion), value: segment)
            .animation(DCMotion.respecting(reduceMotion), value: forumFilter)
        }
        .background(DCTheme.pageBackground)
        .accessibilityIdentifier("historyView")
        // The filtered forum was removed or its data cleared: back to All.
        .onChange(of: app.manageForums.map(\.siteURL)) { _, siteURLs in
            if let forumFilter, !siteURLs.contains(forumFilter) { self.forumFilter = nil }
        }
        #if DEBUG
        .onAppear {
            if let value = AssistantDebug.value("-dc-history-segment")?.lowercased(),
               let match = Segment.allCases.first(where: { $0.rawValue.hasPrefix(value) }) {
                segment = match
            }
        }
        #endif
        .confirmationDialog(
            "Delete this saved summary?",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete summary and chat", role: .destructive) {
                if let pendingDeletion {
                    app.deleteSession(topicKey: pendingDeletion.topicKey)
                }
                pendingDeletion = nil
            }
            Button("Cancel", role: .cancel) {
                pendingDeletion = nil
            }
        } message: {
            Text("This removes the locally saved summary and chat history. It cannot be undone.")
        }
    }

    // MARK: Filters

    private func filterBar(_ feed: HistoryFeed) -> some View {
        HStack(spacing: 8) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Segment.allCases) { item in
                            segmentChip(item, count: feed.count(item)).id(item)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }
                // Keep the selected segment visible on a narrow phone.
                .onAppear { proxy.scrollTo(segment, anchor: .center) }
                .onChange(of: segment) {
                    withAnimation(DCMotion.respecting(reduceMotion, DCMotion.quick)) {
                        proxy.scrollTo(segment, anchor: .center)
                    }
                }
            }
            forumMenu
                .padding(.trailing, 10)
        }
        .background(DCTheme.toolbar)
        .sensoryFeedback(.selection, trigger: segment)
    }

    private func segmentChip(_ item: Segment, count: Int) -> some View {
        let selected = segment == item
        return Button {
            withAnimation(DCMotion.respecting(reduceMotion, DCMotion.quick)) { segment = item }
        } label: {
            HStack(spacing: 5) {
                Text(item.title)
                if item != .all, count > 0 {
                    Text("\(count)")
                        .font(.caption2.weight(.bold).monospacedDigit())
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(selected ? Color.white.opacity(0.25) : Color.primary.opacity(0.08), in: Capsule())
                }
            }
            .font(.footnote.weight(.semibold))
            .foregroundStyle(selected ? Color.white : Color.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(selected ? AnyShapeStyle(Color(hex: 0x3A5BE0)) : AnyShapeStyle(Color.primary.opacity(0.06)), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("historySegment-\(item.rawValue)")
    }

    private var forumMenu: some View {
        Menu {
            Button {
                forumFilter = nil
            } label: {
                if forumFilter == nil {
                    Label("All forums", systemImage: "checkmark")
                } else {
                    Text("All forums")
                }
            }
            Section {
                ForEach(forums) { forum in
                    Button {
                        forumFilter = forum.siteURL
                    } label: {
                        if forumFilter == forum.siteURL {
                            Label(forum.displayName, systemImage: "checkmark")
                        } else if forum.isPinned {
                            Label(forum.displayName, systemImage: "pin")
                        } else {
                            Text(forum.displayName)
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                if let forumFilter {
                    AssistantForumIcon(forum: app.forumInfo(siteURL: forumFilter), size: 20)
                } else {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                        .font(.body)
                }
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.bold))
            }
            .foregroundStyle(forumFilter == nil ? Color.secondary : DCTheme.brandBlue)
            .frame(minWidth: DCTheme.controlHeight, minHeight: DCTheme.controlHeight)
            .contentShape(Rectangle())
        }
        .accessibilityLabel(
            forumFilter.map {
                String(localized: "Forum: \(app.forumInfo(siteURL: $0).displayName)", comment: "Accessibility label of Manage's forum filter; the placeholder is a forum name")
            } ?? String(localized: "Forum: all forums")
        )
        .accessibilityIdentifier("historyForumFilter")
    }

    // MARK: Sections

    private func inProgressSection(_ records: [WorkRecord], showsEmpty: Bool = true) -> some View {
        Section {
            ForEach(records) { record in
                taskRow(record, canCancel: true)
            }
            if records.isEmpty, showsEmpty {
                emptyRow("No work is currently running.", systemImage: "checkmark.circle")
            }
        } header: {
            if showsEmpty || !records.isEmpty {
                sectionHeader("In progress", count: records.count)
            }
        }
    }

    private func watchingSection(_ items: [WatchedTopic]) -> some View {
        Section {
            if items.isEmpty {
                emptyRow("Watch a topic from the Assistant menu, or let the agent watch one.", systemImage: "eye")
            } else {
                forumGrouped(items, siteURL: \.siteURL) { watchedRow($0) }
            }
        } header: {
            HStack {
                sectionHeader("Watching", count: items.count)
                Spacer()
                if !app.watchedTopics.isEmpty {
                    Button("Check now") {
                        DCHaptics.tap()
                        Task { await app.checkWatchedTopics(reason: .manual) }
                    }
                    .font(.caption.weight(.semibold))
                    .textCase(nil)
                    .accessibilityIdentifier("checkWatchedTopics")
                }
            }
        }
    }

    private func asksSection(_ items: [AgentRun]) -> some View {
        Section {
            if items.isEmpty {
                emptyRow("Questions you ask the forum will appear here.", systemImage: "sparkle.magnifyingglass")
            } else {
                forumGrouped(items, siteURL: \.siteURL) { agentRunRow($0) }
            }
        } header: {
            sectionHeader("Asks", count: items.count)
        }
    }

    private func savedSection(_ items: [TopicSession]) -> some View {
        Section {
            if items.isEmpty {
                emptyRow("Summaries and chats you create will appear here.", systemImage: "text.alignleft")
            } else {
                forumGrouped(items, siteURL: \.siteURL) { savedRow($0) }
            }
        } header: {
            sectionHeader("Summaries & chats", count: items.count)
        } footer: {
            Text("Chats expire after a day unless you keep the topic. Swipe to keep or delete.")
        }
    }

    private func recentSection(_ records: [WorkRecord]) -> some View {
        Section {
            if records.isEmpty {
                emptyRow("No recent tasks.", systemImage: "clock")
            } else {
                ForEach(records) { record in
                    taskRow(record, canCancel: false, allowsDelete: true)
                }
            }
        } header: {
            sectionHeader("Recent activity", count: records.count)
        }
    }

    private func sectionHeader(_ title: LocalizedStringKey, count: Int) -> some View {
        HStack(spacing: 6) {
            Text(title)
            if count > 0 {
                Text("\(count)")
                    .font(.caption2.weight(.bold).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Color.primary.opacity(0.07), in: Capsule())
            }
        }
    }

    private func emptyRow(_ text: LocalizedStringKey, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.subheadline)
            .foregroundStyle(.secondary)
    }

    /// Rows of one section, with a forum sub-header per forum when several
    /// forums are shown.
    @ViewBuilder
    private func forumGrouped<Item: Identifiable, Row: View>(
        _ items: [Item],
        siteURL: @escaping (Item) -> String,
        @ViewBuilder row: @escaping (Item) -> Row
    ) -> some View {
        if showsForumHeaders {
            ForEach(grouped(items, siteURL: siteURL), id: \.0.id) { forum, forumItems in
                forumHeaderRow(forum, count: forumItems.count)
                ForEach(forumItems) { item in
                    row(item)
                }
            }
        } else {
            ForEach(items) { item in
                row(item)
            }
        }
    }

    private func forumHeaderRow(_ forum: Forum, count: Int) -> some View {
        HStack(spacing: 8) {
            AssistantForumIcon(forum: forum, size: 20)
            Text(forum.displayName)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
            if forum.isPinned {
                Image(systemName: "pin.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Pinned")
            }
            Spacer(minLength: 4)
            Text("\(count)")
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .dcStateBounce(forum.isPinned)
        .padding(.vertical, -2)
        .listRowBackground(Color.primary.opacity(0.035))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("historyForumHeader")
    }

    // MARK: Rows

    private func forumCaption(_ siteURL: String) -> String {
        app.forumInfo(siteURL: siteURL).displayName
    }

    private func rowTitle(_ text: String) -> some View {
        Text(text)
            .font(.subheadline.weight(.semibold))
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func rowButtons<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 8) {
            content()
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .controlSize(.small)
        .font(.footnote.weight(.semibold))
        .padding(.top, 2)
    }

    @ViewBuilder
    private func taskRow(
        _ record: WorkRecord,
        canCancel: Bool,
        allowsDelete: Bool = false
    ) -> some View {
        let row = VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: 10) {
                typeIcon(record.type)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        rowTitle(record.title)
                        if originOf(record) == .voice { voiceTag }
                    }
                    Text("\(forumCaption(record.siteURL)) · \(record.statusText)")
                        .font(.caption)
                        .foregroundStyle(record.status == .failed ? DCTheme.danger : .secondary)
                        .lineLimit(2)
                    if !record.error.isEmpty {
                        Text(record.error)
                            .font(.caption2)
                            .foregroundStyle(DCTheme.danger)
                            .lineLimit(3)
                    }
                    if canCancel {
                        AssistantProgressBar(value: record.progress, tint: DCTheme.summaryTint)
                            .padding(.top, 3)
                    }
                }
                Spacer(minLength: 0)
                statusIcon(record.status)
            }
            rowButtons {
                Button {
                    app.open(record: record)
                } label: {
                    Label("Open", systemImage: "arrow.up.right")
                }
                if canCancel {
                    Button(role: .destructive) {
                        app.cancel(record: record)
                    } label: {
                        Label("Cancel", systemImage: "xmark")
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityIdentifier(allowsDelete ? "recentActivityRow" : "activityRow")

        row.swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button(role: .destructive) {
                app.removeActivity(id: record.id)
            } label: {
                Label(allowsDelete ? "Delete recent activity" : "Cancel and delete", systemImage: "trash")
            }
        }
    }

    /// An Ask record's run decides the Voice tag; other work has none.
    private func originOf(_ record: WorkRecord) -> AgentRunOrigin? {
        guard record.type == .agent, let runID = app.agentRunID(for: record) else { return nil }
        return app.agentRuns.first { $0.id == runID }?.origin
    }

    private var voiceTag: some View {
        Label("Voice", systemImage: "waveform")
            .labelStyle(.titleAndIcon)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(DCTheme.agentTint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(DCTheme.agentTint.opacity(0.12), in: Capsule())
            .accessibilityIdentifier("historyVoiceTag")
    }

    private func typeIcon(_ type: WorkType) -> some View {
        let (icon, tint): (String, Color) = switch type {
        case .summary: ("text.alignleft", DCTheme.summaryTint)
        case .pull: ("arrow.down.circle", DCTheme.summaryTint)
        case .chat: ("bubble.left.and.bubble.right", DCTheme.chatTint)
        case .agent: ("sparkle.magnifyingglass", DCTheme.agentTint)
        }
        return Image(systemName: icon)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(tint)
            .frame(width: 28, height: 28)
            .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .accessibilityHidden(true)
    }

    private func excerpt(_ summary: String) -> String {
        let lines = summary.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        let line = lines.first { !$0.isEmpty && !$0.hasPrefix("#") && !$0.hasPrefix("```") && !$0.hasPrefix("|") } ?? ""
        let stripped = line.replacingOccurrences(of: #"^([-*+>]|\d+\.)\s+"#, with: "", options: .regularExpression)
        // Inline Markdown (bold, italics, code, links) → plain text.
        if let attributed = try? AttributedString(
            markdown: stripped,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return String(attributed.characters)
        }
        return stripped
    }

    private func savedRow(_ session: TopicSession) -> some View {
        let row = VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                rowTitle(session.title)
                Spacer(minLength: 0)
                if session.kept {
                    Image(systemName: "pin.fill")
                        .font(.caption)
                        .foregroundStyle(DCTheme.warning)
                        .accessibilityLabel("Kept")
                }
            }
            .dcStateBounce(session.kept)
            let text = excerpt(session.summary)
            if !text.isEmpty {
                Text(text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Text(savedDetail(session))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            rowButtons {
                Button {
                    app.open(session: session)
                } label: {
                    Label("Open", systemImage: "arrow.up.right")
                }
                .tint(DCTheme.brandBlue)

                Menu {
                    Button {
                        app.setKept(!session.kept, topicKey: session.topicKey)
                    } label: {
                        Label(
                            session.kept ? "Unkeep" : "Keep",
                            systemImage: session.kept ? "pin.slash" : "pin"
                        )
                    }
                    Button(role: .destructive) {
                        pendingDeletion = session
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                } label: {
                    Label("More", systemImage: "ellipsis")
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityIdentifier("savedSummaryRow-\(session.topicID)")

        return row
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                if session.kept {
                    Button {
                        app.setKept(false, topicKey: session.topicKey)
                    } label: {
                        Label("Unkeep saved summary", systemImage: "pin.slash")
                    }
                    .tint(.orange)
                } else {
                    Button(role: .destructive) {
                        app.deleteSession(topicKey: session.topicKey)
                    } label: {
                        Label("Delete saved summary", systemImage: "trash")
                    }
                }
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                Button {
                    app.setKept(true, topicKey: session.topicKey)
                } label: {
                    Label("Keep saved summary", systemImage: "pin")
                }
                .tint(.orange)
            }
    }

    private func savedDetail(_ session: TopicSession) -> String {
        var parts: [String] = []
        parts.append(String(localized: "\(session.summaryPostCount ?? session.totalPosts ?? 0) posts"))
        parts.append(String(localized: "\(session.history.count) chat messages"))
        parts.append(session.updatedAt.formatted(.relative(presentation: .named)))
        return parts.joined(separator: " · ")
    }

    private func watchedRow(_ watched: WatchedTopic) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    rowTitle(watched.title)
                    Text(watchedDetail(watched))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if watched.newReplies > 0 {
                    Text("\(watched.newReplies) new")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(DCTheme.brandBlue, in: Capsule())
                        .accessibilityIdentifier("watchedNewReplies-\(watched.topicID)")
                }
            }
            rowButtons {
                Button {
                    app.openWatched(watched)
                } label: {
                    Label("Open", systemImage: "arrow.up.right")
                }
                .tint(DCTheme.brandBlue)
                Button {
                    app.unwatch(topicKey: watched.topicKey)
                } label: {
                    Label("Unwatch", systemImage: "eye.slash")
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("watchedTopicRow-\(watched.topicID)")
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button(role: .destructive) {
                app.unwatch(topicKey: watched.topicKey)
            } label: {
                Label("Unwatch topic", systemImage: "eye.slash")
            }
        }
    }

    private func watchedDetail(_ watched: WatchedTopic) -> String {
        var parts: [String] = []
        parts.append(String(localized: "\(watched.knownPostCount) posts"))
        if let checked = watched.lastCheckedAt {
            let relative = checked.formatted(.relative(presentation: .named))
            parts.append(String(localized: "checked \(relative)", comment: "Watched topic detail; the placeholder is a relative time such as “5 minutes ago”"))
        } else {
            parts.append(String(localized: "not checked yet", comment: "Watched topic detail"))
        }
        return parts.joined(separator: " · ")
    }

    private func agentRunRow(_ run: AgentRun) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: 10) {
                typeIcon(.agent)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        rowTitle(run.goal)
                        if run.origin == .voice { voiceTag }
                    }
                    Text(runDetail(run))
                        .font(.caption)
                        .foregroundStyle(run.result == .failed ? DCTheme.danger : .secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
                statusIcon(app.status(of: run))
            }
            rowButtons {
                Button {
                    app.openAgentRun(id: run.id)
                } label: {
                    Label("Open", systemImage: "arrow.up.right")
                }
                .tint(DCTheme.agentTint)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("agentRunRow")
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button(role: .destructive) {
                app.deleteAgentRun(id: run.id)
            } label: {
                Label("Delete agent run", systemImage: "trash")
            }
        }
    }

    private func runDetail(_ run: AgentRun) -> String {
        var parts: [String] = []
        parts.append(statusTitle(app.status(of: run)))
        parts.append(String(localized: "\(run.steps.count) steps", comment: "Agent run detail: tool calls made"))
        parts.append(String(localized: "\(run.readTopicCount) topics", comment: "Agent run detail: topics read"))
        parts.append(run.createdAt.formatted(.relative(presentation: .named)))
        return parts.joined(separator: " · ")
    }

    private func statusTitle(_ status: WorkStatus) -> String {
        switch status {
        case .queued: String(localized: "Queued", comment: "Work status")
        case .running: String(localized: "Running", comment: "Work status")
        case .completed: String(localized: "Completed", comment: "Work status")
        case .failed: String(localized: "Failed", comment: "Work status")
        case .cancelled: String(localized: "Cancelled", comment: "Work status")
        }
    }

    @ViewBuilder
    private func statusIcon(_ status: WorkStatus) -> some View {
        switch status {
        case .queued, .running:
            ProgressView()
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(DCTheme.success)
                .accessibilityLabel("Completed")
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(DCTheme.danger)
                .accessibilityLabel("Failed")
        case .cancelled:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.secondary)
                .accessibilityLabel("Cancelled")
        }
    }
}
