import SwiftUI
import UIKit
import UniformTypeIdentifiers

enum ExpandedPanelRoute: String, Identifiable {
    case topic
    case post
    case activity
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .topic: "Assistant"
        case .post: "Post & responses"
        case .activity: "Manage"
        case .settings: "Settings"
        }
    }
}

/// The assistant column (iPad) or pane (iPhone): a header with the forum,
/// topic and the Summary · Chat · Ask the forum switch, a body that follows
/// the page state (not a forum, forum home, topic…), and the Manage and
/// Settings screens shown in place.
struct AssistantPanel: View {
    @ObservedObject var app: AppModel
    /// nil when the panel already owns the whole screen.
    let onExpand: ((ExpandedPanelRoute) -> Void)?
    /// Opens a forum URL in the Browse workspace (the agent's step log uses it).
    let onOpenURL: ((URL) -> Void)?
    @State private var exportOptions = ExportOptions()
    @State private var showingExportOptions = false
    @State private var showingInstructions = false
    @State private var exporting = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        app: AppModel,
        onExpand: ((ExpandedPanelRoute) -> Void)? = nil,
        onOpenURL: ((URL) -> Void)? = nil
    ) {
        self.app = app
        self.onExpand = onExpand
        self.onOpenURL = onOpenURL
    }

    private var activeRecords: [WorkRecord] {
        guard let topicKey = app.currentTopic?.topicKey else { return [] }
        return app.activities.filter { $0.topicKey == topicKey && !$0.status.isTerminal }
    }

    private var activeSummary: WorkRecord? { activeRecords.first { $0.type == .summary } }
    private var activePull: WorkRecord? { activeRecords.first { $0.type == .pull } }
    private var activeChat: WorkRecord? { activeRecords.first { $0.type == .chat } }

    private var payload: TopicExportPayload {
        let session = app.currentSession
        return TopicExportPayload(
            summary: session?.summary ?? "",
            source: session?.source ?? "",
            title: session?.title ?? app.currentTopic?.title ?? "",
            url: session?.url ?? app.currentTopic?.url,
            history: session?.history ?? []
        )
    }

    private var exportText: String {
        payload.text(options: exportOptions)
    }

    private var exportDisabled: Bool {
        activePull != nil || !payload.hasContent(options: exportOptions)
    }

    /// What the body shows; the key drives the cross-fade between states.
    private enum BodyKind: Hashable {
        case summary, chat, agent, forumHome, notForum, maybe, loading
    }

    private var bodyKind: BodyKind {
        let state = app.assistantPageState
        if app.assistantMode == .agent, state == .topic || app.agentForum != nil {
            return .agent
        }
        switch state {
        case .topic: return app.assistantMode == .chat ? .chat : .summary
        case .forumHome: return .forumHome
        case .notForum: return .notForum
        case .maybe: return .maybe
        case .loading: return .loading
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            switch app.panelRoute {
            case .topic:
                topicHeader
                Divider()
                topicContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .activity:
                subHeader("Manage")
                Divider()
                ActivityPanel(app: app)
            case .settings:
                SettingsPanel(app: app) {
                    withAnimation(DCMotion.respecting(reduceMotion)) {
                        app.panelRoute = .topic
                    }
                }
            }
        }
        .background(DCTheme.pageBackground)
        .environment(\.openURL, OpenURLAction { url in
            guard ForumBrowserModel.isBrowsableURL(url) else { return .systemAction }
            openInBrowser(url)
            return .handled
        })
        .onChange(of: TopicMode(topicKey: app.currentTopic?.topicKey, mode: app.assistantMode)) { old, new in
            guard old.topicKey != new.topicKey else { return }
            // A new topic opens on its Summary, unless the mode was picked for
            // it in the same update (a shared "Chat" link). The panel stays
            // alive across layouts, so this runs even while it is hidden.
            if new.mode != .agent, old.mode == new.mode { app.assistantMode = .summary }
            exportOptions = ExportOptions()
        }
        .sheet(isPresented: $showingExportOptions) {
            ExportOptionsSheet(payload: payload, options: $exportOptions)
        }
        .sheet(isPresented: $showingInstructions) {
            InstructionsSheet(app: app)
        }
        .fileExporter(
            isPresented: $exporting,
            document: PlainTextDocument(text: exportText),
            contentType: .plainText,
            defaultFilename: "forumind-\(exportSlug).txt"
        ) { result in
            if case .failure(let error) = result {
                app.presentedError = error.localizedDescription
            }
        }
    }

    private struct TopicMode: Equatable {
        let topicKey: String?
        let mode: AssistantMode
    }

    private var exportSlug: String {
        guard let topic = app.currentTopic else { return "topic" }
        let host = ForumSite.host(of: topic.siteURL)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ".", with: "-")
        return "\(host)-\(topic.topicID)"
    }

    private func openInBrowser(_ url: URL) {
        app.browser.load(url)
        onOpenURL?(url)
    }

    // MARK: Header

    private var headerForum: Forum? {
        if bodyKind == .agent { return app.agentForum }
        switch app.assistantPageState {
        case .topic, .forumHome: return app.assistantForum
        case .notForum, .maybe, .loading: return nil
        }
    }

    /// Off-forum pages name the page's host instead of a forum.
    private var headerSubtitle: String {
        if let headerForum { return headerForum.host }
        switch app.assistantPageState {
        case .notForum: return app.pageContext.url?.host.map { "\($0) · not a Discourse forum" } ?? "Not a Discourse forum"
        case .maybe: return app.pageContext.url?.host.map { "\($0) · checking…" } ?? "Checking this page…"
        default: return app.pageContext.url == nil && app.currentForum == nil ? "No forum open" : "Loading page…"
        }
    }

    private var topicHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                AssistantForumIcon(forum: headerForum, size: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(headerForum?.displayName ?? "Forumind")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .accessibilityIdentifier("assistantForumName")
                    Text(headerSubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)

                HStack(spacing: 0) {
                    // Same cross-fade as the back buttons, so opening and
                    // leaving Manage/Settings feel alike.
                    headerIcon("tray.full", label: "Manage", identifier: "openManage") {
                        withAnimation(DCMotion.respecting(reduceMotion)) { app.panelRoute = .activity }
                    }
                    headerIcon("gearshape", label: "Settings", identifier: "openSettings") {
                        withAnimation(DCMotion.respecting(reduceMotion)) { app.panelRoute = .settings }
                    }
                    moreMenu
                }
            }

            if let title = headerTitle {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.headline)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("assistantTopicTitle")
                    Text(metaLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .transition(.opacity)
            }

            AssistantModeSwitcher(mode: $app.assistantMode)
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .background(DCTheme.toolbar)
        .animation(DCMotion.respecting(reduceMotion), value: headerTitle)
    }

    private var headerTitle: String? {
        if app.assistantMode == .agent { return nil }
        return app.currentTopic?.title
    }

    private var metaLine: String {
        var parts = [app.providerSummary]
        if let session = app.currentSession, let count = session.totalPosts, count > 0 {
            parts.append("\(count) posts")
        }
        return parts.joined(separator: " · ")
    }

    private func headerIcon(
        _ systemImage: String,
        label: String,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.body.weight(.medium))
        }
        .buttonStyle(DCIconButtonStyle())
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }

    private var moreMenu: some View {
        Menu {
            Section {
                Button {
                    UIPasteboard.general.string = exportText
                    DCHaptics.success()
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .accessibilityIdentifier("copyExport")
                .disabled(exportDisabled)

                ShareLink(item: exportText) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                .accessibilityIdentifier("shareExport")
                .disabled(exportDisabled)

                Button {
                    exporting = true
                } label: {
                    Label("Export .txt", systemImage: "arrow.down.doc")
                }
                .accessibilityIdentifier("exportExport")
                .disabled(exportDisabled)

                Button {
                    showingExportOptions = true
                } label: {
                    Label("Export options", systemImage: "slider.horizontal.3")
                }
                .accessibilityIdentifier("exportOptions")
            }

            Section {
                Button {
                    app.pullTopic()
                } label: {
                    Label("Pull post + replies", systemImage: "arrow.down.circle")
                }
                .accessibilityIdentifier("pullPost")
                .disabled(app.currentTopic == nil || activeSummary != nil || activePull != nil)

                Button {
                    onExpand?(.post)
                } label: {
                    Label("Post & responses", systemImage: "text.bubble")
                }
                .accessibilityIdentifier("viewPost")
                .disabled(onExpand == nil || (app.currentSession?.source.isEmpty ?? true))

                Button {
                    app.toggleWatchCurrentTopic()
                } label: {
                    if let topicKey = app.currentTopic?.topicKey, app.isWatched(topicKey: topicKey) {
                        Label("Unwatch topic", systemImage: "eye.slash")
                    } else {
                        Label("Watch topic for new replies", systemImage: "eye")
                    }
                }
                .accessibilityIdentifier("toggleWatchTopic")
                .disabled(app.currentTopic == nil)
            }

            if !app.settings.favoriteModels.isEmpty {
                Menu {
                    ForEach(app.settings.favoriteModels) { favorite in
                        Button {
                            app.activateFavorite(favorite)
                        } label: {
                            Text("\(favorite.provider.displayName) · \(favorite.model)")
                        }
                    }
                } label: {
                    Label("Switch model", systemImage: "star")
                }
            }

            if app.assistantMode == .chat, !(app.currentSession?.history.isEmpty ?? true) {
                Button(role: .destructive) {
                    app.clearChat()
                } label: {
                    Label("Clear chat", systemImage: "trash")
                }
            }

            if onExpand != nil {
                Button {
                    onExpand?(.topic)
                } label: {
                    Label("Open full screen", systemImage: "arrow.up.left.and.arrow.down.right")
                }
                .accessibilityIdentifier("openFullScreen")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.body.weight(.medium))
        }
        .buttonStyle(DCIconButtonStyle())
        .accessibilityLabel("More assistant actions")
        .accessibilityIdentifier("assistantMoreMenu")
    }

    private func subHeader(_ title: String) -> some View {
        HStack {
            Button {
                withAnimation(DCMotion.respecting(reduceMotion)) {
                    app.panelRoute = .topic
                }
            } label: {
                Label("Assistant", systemImage: "chevron.left")
                    .labelStyle(.titleAndIcon)
                    .font(.body.weight(.medium))
            }
            .accessibilityLabel("Back to assistant")
            .accessibilityIdentifier("backToTopic")
            // Esc closes Manage in the window (the full-screen copy has Done).
            .dcCancelShortcut(onExpand != nil)
            Spacer()
            Text(title)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            // Balance the back button so the title stays centered.
            Label("Assistant", systemImage: "chevron.left")
                .font(.body.weight(.medium))
                .hidden()
        }
        .padding(.horizontal, 14)
        .frame(minHeight: DCTheme.controlHeight + 8)
        .background(DCTheme.toolbar)
    }

    // MARK: Body

    private var providerCard: some View {
        ProviderSetupCard {
            withAnimation(DCMotion.respecting(reduceMotion)) {
                app.panelRoute = .settings
            }
        }
    }

    @ViewBuilder
    private var topicContent: some View {
        let kind = bodyKind
        Group {
            switch kind {
            case .summary:
                summaryContent
            case .chat:
                ChatThread(
                    app: app,
                    activeChat: activeChat,
                    showsProviderCard: !app.isProviderReady,
                    onSetUpProvider: { app.panelRoute = .settings },
                    onShowInstructions: { showingInstructions = true },
                    onCreateSummary: {
                        app.assistantMode = .summary
                        app.startSummary()
                    }
                )
            case .agent:
                AgentView(
                    app: app,
                    showsProviderCard: !app.isProviderReady,
                    onSetUpProvider: { app.panelRoute = .settings }
                ) { url in
                    openInBrowser(url)
                }
            case .forumHome, .notForum, .maybe, .loading:
                stateContent(kind)
            }
        }
        .id(kind)
        .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 6)))
        .animation(DCMotion.respecting(reduceMotion), value: kind)
    }

    private func stateContent(_ kind: BodyKind) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if !app.isProviderReady, kind != .loading {
                    providerCard
                }
                switch kind {
                case .forumHome:
                    if let forum = app.assistantForum {
                        ForumHomeState(app: app, forum: forum)
                    }
                case .notForum:
                    NotForumState(app: app)
                case .maybe:
                    MaybeForumState(app: app)
                default:
                    AssistantLoadingState()
                }
            }
            .padding(14)
            .frame(maxWidth: DCTheme.contentMaxWidth + 220, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .accessibilityIdentifier("assistantStateScroll")
    }

    // MARK: Summary

    private var visibleSummary: String {
        if let activeSummary,
           let streamed = app.summaryStreams[activeSummary.id],
           !streamed.isEmpty {
            return streamed
        }
        return app.currentSession?.summary ?? ""
    }

    private var forumName: String {
        app.assistantForum?.displayName ?? "the forum"
    }

    private var summaryContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if !app.isProviderReady {
                    providerCard
                }

                if activeSummary == nil, activePull == nil {
                    if visibleSummary.isEmpty {
                        summaryHero
                    } else {
                        summarizeControl(prominent: false)
                    }
                }

                if let record = activePull {
                    WorkProgressCard(record: record) { app.cancel(record: record) }
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
                if let record = activeSummary {
                    WorkProgressCard(record: record) { app.cancel(record: record) }
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                if app.currentSession?.hasStaleSummary == true, activeSummary == nil {
                    StaleSummaryNotice(compact: false, session: app.currentSession)
                }

                if !visibleSummary.isEmpty {
                    summaryCard
                }
            }
            .padding(14)
            .frame(maxWidth: 860, alignment: .leading)
            .frame(maxWidth: .infinity)
            .animation(DCMotion.respecting(reduceMotion), value: activeSummary?.id)
            .animation(DCMotion.respecting(reduceMotion), value: activePull?.id)
        }
        .accessibilityIdentifier("topicPanelScroll")
    }

    /// No summary yet: the topic hero with Create summary as the primary action.
    private var summaryHero: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Topic on \(forumName)".uppercased())
                    .font(.caption.weight(.bold))
                    .kerning(0.8)
                    .foregroundStyle(DCTheme.summaryTint)
                    .lineLimit(1)
                Text(app.currentTopic?.title ?? "No topic open")
                    .font(.title3.weight(.bold))
                    .fixedSize(horizontal: false, vertical: true)
                Text(
                    app.currentTopic == nil
                        ? "Open a forum topic in Browse, then come back here."
                        : "Read every reply and create a focused overview."
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
            summarizeControl(prominent: true)
            Label("Runs in the background — keep browsing. Hold for batch options.", systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .dcCard(tint: DCTheme.summaryTint)
    }

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "text.alignleft")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(DCTheme.summaryTint)
                    .frame(width: 32, height: 32)
                    .background(DCTheme.summaryTint.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .accessibilityHidden(true)
                Text(activeSummary == nil ? "Summary" : "Writing summary…")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                if activeSummary != nil {
                    TypingIndicator(tint: DCTheme.summaryTint)
                }
            }
            if activeSummary == nil, let session = app.currentSession {
                summaryMeta(session)
            }
            Divider()
            MarkdownView(visibleSummary)
                .textSelection(.enabled)
                .accessibilityIdentifier("summaryContent")
            if activeSummary == nil {
                Divider()
                HStack(spacing: 8) {
                    Button {
                        UIPasteboard.general.string = app.currentSession?.summary
                        DCHaptics.success()
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                    .accessibilityIdentifier("copySummaryInline")
                    ShareLink(item: app.currentSession?.summary ?? "") {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    Spacer()
                    Button {
                        withAnimation(DCMotion.respecting(reduceMotion)) {
                            app.assistantMode = .chat
                        }
                    } label: {
                        Label("Ask about it", systemImage: "bubble.left.and.bubble.right")
                    }
                    .tint(DCTheme.chatTint)
                }
                .font(.footnote.weight(.semibold))
                .buttonStyle(.borderless)
            }
        }
        .dcCard()
    }

    private func summaryMeta(_ session: TopicSession) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                if !session.model.isEmpty {
                    DCPill(text: session.model, systemImage: "cpu", tint: .secondary)
                }
                if let count = session.summaryPostCount ?? session.totalPosts, count > 0 {
                    DCPill(text: "\(count) posts", systemImage: "text.bubble", tint: DCTheme.summaryTint)
                }
                if let date = session.summaryUpdatedAt {
                    DCPill(
                        // Abbreviated ("6 min. ago") so the row fits a phone card.
                        text: date.formatted(.relative(presentation: .named, unitsStyle: .abbreviated)),
                        systemImage: "clock",
                        tint: .secondary
                    )
                }
                if session.kept {
                    DCPill(text: "Kept", systemImage: "pin.fill", tint: DCTheme.warning)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// Tap summarizes with the default batch size; hold to pick a batch size for
    /// this run or to pull the post without summarizing.
    @ViewBuilder
    private func summarizeControl(prominent: Bool) -> some View {
        let menu = Menu {
            Section("Context per batch") {
                ForEach(SummaryBatchLimit.presets, id: \.self) { limit in
                    Button {
                        app.startSummary(batchLimit: limit)
                    } label: {
                        if limit == app.settings.summaryBatchLimit {
                            Label(SummaryBatchLimit.label(limit), systemImage: "checkmark")
                        } else {
                            Text(SummaryBatchLimit.label(limit))
                        }
                    }
                }
            }
            Button {
                app.pullTopic()
            } label: {
                Label("Pull post + replies only", systemImage: "arrow.down.circle")
            }
        } label: {
            Label(
                app.currentSession?.hasSummary == true ? "Check for new replies" : "Create summary",
                systemImage: app.currentSession?.hasSummary == true ? "arrow.triangle.2.circlepath" : "sparkles"
            )
            .frame(maxWidth: .infinity)
        } primaryAction: {
            DCHaptics.tap()
            app.startSummary()
        }
        .accessibilityIdentifier("createSummary")
        .disabled(app.currentTopic == nil || activeSummary != nil || activePull != nil)

        if prominent {
            menu.buttonStyle(DCPrimaryButtonStyle())
        } else {
            menu.buttonStyle(DCActionButtonStyle(prominent: false))
        }
    }
}

private struct StaleSummaryNotice: View {
    let compact: Bool
    var session: TopicSession?

    private var newReplies: Int? {
        guard let session, let total = session.totalPosts, let summarized = session.summaryPostCount else {
            return nil
        }
        return max(0, total - summarized)
    }

    var body: some View {
        if compact {
            Label(
                "Saved summary may be stale; current post and responses are authoritative.",
                systemImage: "exclamationmark.triangle"
            )
            .font(.caption)
            .foregroundStyle(DCTheme.warning)
            .accessibilityIdentifier("staleSummaryChatNotice")
        } else {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(DCTheme.warning)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(
                        newReplies.map { "Stale summary — \($0) newer replies" }
                            ?? "Stale summary — newer replies are available."
                    )
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(DCTheme.warning)
                    .accessibilityIdentifier("staleSummaryNotice")
                    Text("You can still read it. Use Check for new replies to update it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .dcCard(tint: DCTheme.warning)
            .accessibilityElement(children: .combine)
        }
    }
}

// MARK: - Chat

/// The conversation: a collapsed summary card, messages, and a pinned composer.
private struct ChatThread: View {
    @ObservedObject var app: AppModel
    let activeChat: WorkRecord?
    let showsProviderCard: Bool
    let onSetUpProvider: () -> Void
    let onShowInstructions: () -> Void
    let onCreateSummary: () -> Void
    @State private var summaryExpanded = false
    @State private var atBottom = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var stream: String {
        guard let activeChat else { return "" }
        return app.chatStreams[activeChat.id] ?? ""
    }

    private var history: [ChatMessage] {
        app.currentSession?.history ?? []
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if showsProviderCard {
                            ProviderSetupCard(onSetUp: onSetUpProvider)
                        }

                        summaryCard

                        if app.currentSession?.hasStaleSummary == true {
                            StaleSummaryNotice(compact: true)
                        }

                        if history.isEmpty, stream.isEmpty, activeChat == nil {
                            emptyState
                        }

                        ForEach(history) { message in
                            ChatBubble(message: message) {
                                app.editChat(messageID: message.id)
                            }
                            .transition(.asymmetric(
                                insertion: reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .bottom)),
                                removal: .opacity
                            ))
                        }

                        if !stream.isEmpty {
                            ChatBubble(
                                message: ChatMessage(role: .assistant, content: stream),
                                onEdit: nil,
                                isStreaming: true
                            )
                            .id("chatStream")
                        } else if activeChat != nil {
                            typingBubble
                        }

                        if let activeChat {
                            chatStatus(activeChat)
                        }

                        if !history.isEmpty, activeChat == nil {
                            followUpChips
                        }

                        Color.clear
                            .frame(height: 1)
                            .id("chatBottom")
                            .onAppear { if #unavailable(iOS 18.0) { atBottom = true } }
                            .onDisappear { if #unavailable(iOS 18.0) { atBottom = false } }
                    }
                    .padding(14)
                    .frame(maxWidth: 860, alignment: .leading)
                    .frame(maxWidth: .infinity)
                    .animation(DCMotion.respecting(reduceMotion), value: history.count)
                    .animation(DCMotion.respecting(reduceMotion), value: activeChat?.id)
                }
                .defaultScrollAnchor(.bottom)
                .modifier(ScrollBottomTracker(atBottom: $atBottom))
                .scrollDismissesKeyboard(.interactively)
                .accessibilityIdentifier("chatScroll")
                .onAppear {
                    proxy.scrollTo("chatBottom", anchor: .bottom)
                }
                .onChange(of: history.count) {
                    withAnimation(DCMotion.respecting(reduceMotion)) {
                        proxy.scrollTo("chatBottom", anchor: .bottom)
                    }
                }
                .onChange(of: stream) {
                    // Follow the answer only while the reader is at the bottom.
                    if atBottom { proxy.scrollTo("chatBottom", anchor: .bottom) }
                }
                .overlay(alignment: .bottomTrailing) {
                    if !atBottom {
                        Button {
                            withAnimation(DCMotion.respecting(reduceMotion)) {
                                proxy.scrollTo("chatBottom", anchor: .bottom)
                            }
                        } label: {
                            Image(systemName: "arrow.down")
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(DCTheme.chatTint)
                                .frame(width: 40, height: 40)
                                .background(.regularMaterial, in: Circle())
                                .overlay { Circle().stroke(DCTheme.border) }
                                .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
                        }
                        .buttonStyle(.plain)
                        .padding(14)
                        .transition(.scale(scale: 0.7).combined(with: .opacity))
                        .accessibilityLabel("Scroll to latest message")
                        .accessibilityIdentifier("chatScrollToBottom")
                    }
                }
                .animation(DCMotion.respecting(reduceMotion, DCMotion.quick), value: atBottom)
            }

            ChatComposer(
                app: app,
                activeChat: activeChat,
                onShowInstructions: onShowInstructions
            )
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 10)
            .background {
                Rectangle()
                    .fill(.bar)
                    .overlay(alignment: .top) { Divider() }
                    .ignoresSafeArea(edges: .bottom)
            }
        }
        .onChange(of: app.currentTopic?.topicKey) {
            summaryExpanded = false
        }
    }

    private var typingBubble: some View {
        HStack {
            TypingIndicator(tint: DCTheme.chatTint)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .background(DCTheme.surface, in: ChatBubbleShape(isUser: false))
                .overlay { ChatBubbleShape(isUser: false).stroke(DCTheme.border) }
            Spacer(minLength: 34)
        }
        .transition(.opacity)
    }

    private func chatStatus(_ record: WorkRecord) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.mini)
            Text(record.statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            Button("Stop", role: .destructive) {
                app.cancel(record: record)
            }
            .font(.caption.weight(.semibold))
            .buttonStyle(.borderless)
            .accessibilityIdentifier("cancelChat")
        }
        .padding(.horizontal, 4)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "bubble.left.and.text.bubble.right")
                    .font(.title3)
                    .foregroundStyle(DCTheme.chatTint)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Ask about this topic")
                        .font(.headline)
                    Text("Answers use the post, its replies and the summary.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            suggestionFlow
        }
        .dcCard(tint: DCTheme.chatTint)
    }

    private static let suggestions: [(String, String)] = [
        ("Key takeaways", "What are the key takeaways?"),
        ("Warnings", "Are there any warnings or important caveats?"),
        ("Latest replies", "What do the latest replies add?"),
        ("Disagreements", "Where do people disagree, and why?")
    ]

    private var suggestionFlow: some View {
        ChipFlowLayout(spacing: 8) {
            ForEach(Self.suggestions, id: \.0) { suggestion in
                suggestionChip(suggestion.0, question: suggestion.1)
            }
        }
    }

    private var followUpChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Self.suggestions.prefix(3), id: \.0) { suggestion in
                    suggestionChip(suggestion.0, question: suggestion.1)
                }
            }
        }
        .padding(.top, 2)
    }

    private func suggestionChip(_ title: String, question: String) -> some View {
        Button {
            DCHaptics.tap()
            app.chatDraft = question
        } label: {
            Label(title, systemImage: "sparkle")
                .labelStyle(.titleAndIcon)
                .font(.footnote.weight(.semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .foregroundStyle(DCTheme.chatTint)
                .background(DCTheme.chatTint.opacity(0.1), in: Capsule())
                .overlay { Capsule().stroke(DCTheme.chatTint.opacity(0.22)) }
        }
        .buttonStyle(.plain)
        .accessibilityHint("Fills the question box")
    }

    /// The summary is one tap away but collapsed: by the time someone opens Chat
    /// they have usually read it in the Summary view already.
    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(DCMotion.respecting(reduceMotion)) {
                    summaryExpanded.toggle()
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "text.alignleft")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(DCTheme.summaryTint)
                        .frame(width: 28, height: 28)
                        .background(DCTheme.summaryTint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    Text("Summary")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Spacer()
                    if let session = app.currentSession, session.hasSummary {
                        Text("\(session.summaryPostCount ?? session.totalPosts ?? 0) posts")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Image(systemName: "chevron.down")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(summaryExpanded ? 180 : 0))
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!(app.currentSession?.hasSummary ?? false))
            .accessibilityIdentifier("chatSummaryCard")
            .accessibilityValue(summaryExpanded ? "Expanded" : "Collapsed")

            if app.currentSession?.hasSummary == true {
                if summaryExpanded {
                    MarkdownView(app.currentSession?.summary ?? "")
                        .textSelection(.enabled)
                        .accessibilityIdentifier("chatSummaryContent")
                        .transition(.opacity)
                }
            } else {
                Text(app.currentSession?.source.isEmpty == false
                     ? "No summary yet. Chat can still use the pulled post and responses."
                     : "No summary yet. Chat reads the topic when you ask your first question.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Create summary", action: onCreateSummary)
                    .buttonStyle(DCActionButtonStyle(prominent: false))
                    .disabled(app.currentTopic == nil)
            }
        }
        .padding(12)
        .background(DCTheme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(DCTheme.border) }
    }
}

private struct ChatComposer: View {
    @ObservedObject var app: AppModel
    let activeChat: WorkRecord?
    let onShowInstructions: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            Button(action: onShowInstructions) {
                Image(
                    systemName: app.currentSession?.hasInstructions == true
                        ? "text.badge.checkmark"
                        : "text.quote"
                )
                .foregroundStyle(app.currentSession?.hasInstructions == true ? DCTheme.chatTint : .secondary)
            }
            .buttonStyle(DCIconButtonStyle())
            .accessibilityLabel("Instructions and context")
            .accessibilityIdentifier("chatInstructions")
            .disabled(app.currentTopic == nil)

            HStack(alignment: .bottom, spacing: 4) {
                TextField(
                    "Ask a follow-up question…",
                    text: $app.chatDraft,
                    axis: .vertical
                )
                .lineLimit(1...6)
                .padding(.leading, 14)
                .padding(.vertical, 11)
                .focused($focused)
                #if DEBUG
                .task {
                    // `-dc-focus-chat`: raise the keyboard (QA screenshots).
                    if AssistantDebug.has("-dc-focus-chat") {
                        try? await Task.sleep(for: .milliseconds(900))
                        focused = true
                    }
                }
                #endif
                .accessibilityIdentifier("chatInput")
                .onSubmit {
                    if canSend { send() }
                }

                Button {
                    send()
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(
                            canSend ? AnyShapeStyle(DCTheme.chatTint) : AnyShapeStyle(Color.secondary.opacity(0.35)),
                            in: Circle()
                        )
                        .frame(width: DCTheme.controlHeight - 2, height: DCTheme.controlHeight - 2)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .hoverEffect(.highlight)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!canSend)
                .accessibilityLabel("Send question")
                .animation(DCMotion.quick, value: canSend)
            }
            .background(Color(uiColor: .systemBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(focused ? DCTheme.chatTint : DCTheme.border, lineWidth: focused ? 1.5 : 1)
            }
            .animation(DCMotion.quick, value: focused)
        }
    }

    private func send() {
        DCHaptics.tap()
        app.sendChat()
    }

    private var canSend: Bool {
        !app.chatDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && activeChat == nil
            && !(app.currentSession?.source.isEmpty ?? true)
    }
}

/// Wraps chips onto as many lines as they need.
struct ChipFlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = arrange(width: bounds.width, subviews: subviews)
        for row in rows {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(
                    at: CGPoint(x: x, y: bounds.minY + row.y),
                    proposal: ProposedViewSize(width: min(size.width, bounds.width), height: size.height)
                )
                x += min(size.width, bounds.width) + spacing
            }
        }
    }

    private struct Row {
        var indices: [Int] = []
        var y: CGFloat = 0
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let itemWidth = min(size.width, width)
            if !current.indices.isEmpty, current.width + spacing + itemWidth > width {
                let y = current.y + current.height + spacing
                rows.append(current)
                current = Row(y: y)
            }
            current.width += (current.indices.isEmpty ? 0 : spacing) + itemWidth
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}

/// Per-topic instructions plus the chat context budget.
private struct InstructionsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var app: AppModel
    @State private var draft = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $draft)
                        .frame(minHeight: 140)
                        .accessibilityIdentifier("topicInstructions")
                } header: {
                    Text("Instructions for this topic")
                } footer: {
                    Text(
                        app.settings.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? "Used for this topic's summary and chat. Leave blank to use the built-in structured summary prompt (in the discussion's language)."
                            : "Used for this topic's summary and chat. Leave blank to use the custom instructions from Settings."
                    )
                }

                Section {
                    ContextLimitControl(app: app)
                } header: {
                    Text("Chat context")
                } footer: {
                    Text("How much of the pulled discussion each chat answer can read.")
                }
            }
            .navigationTitle("Instructions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if let topicKey = app.currentTopic?.topicKey {
                            app.setInstructions(draft, topicKey: topicKey)
                        }
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
            .onAppear {
                draft = app.currentSession?.instructions ?? ""
            }
        }
        .presentationDetents([.medium, .large])
        .dcFormSheet()
    }
}

private struct ContextLimitControl: View {
    @ObservedObject var app: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Forum context", systemImage: "text.append")
                Spacer()
                Text(formattedLimit)
                    .foregroundStyle(.secondary)
            }
            .font(.subheadline)

            Slider(
                value: Binding(
                    get: { Double(app.settings.forumContextLimit) },
                    set: { app.settings.forumContextLimit = Int($0) }
                ),
                in: 5_000...1_000_000,
                step: 5_000
            )
            .onChange(of: app.settings.forumContextLimit) {
                app.saveSettings()
            }
            .accessibilityLabel("Forum context size")
            .accessibilityValue(formattedLimit)
        }
    }

    private var formattedLimit: String {
        app.settings.forumContextLimit >= 1_000_000
            ? "1M characters"
            : "\(app.settings.forumContextLimit / 1_000)k characters"
    }
}

// MARK: - Export

private struct ExportOptionsSheet: View {
    @Environment(\.dismiss) private var dismiss
    let payload: TopicExportPayload
    @Binding var options: ExportOptions

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Exclude Title and URL", isOn: $options.excludeTitleAndURL)
                        .disabled(!payload.hasTitleAndURL)
                        .accessibilityIdentifier("excludeTitleURL")
                    Toggle("Exclude Summary", isOn: $options.excludeSummary)
                        .disabled(!payload.hasSummary)
                        .accessibilityIdentifier("excludeSummary")
                    Toggle("Exclude Post & responses", isOn: $options.excludePostAndResponses)
                        .disabled(!payload.hasSource)
                        .accessibilityIdentifier("excludePostResponses")
                    Toggle("Exclude Chat history", isOn: $options.excludeChatHistory)
                        .disabled(!payload.hasChatHistory)
                        .accessibilityIdentifier("excludeChatHistory")
                } footer: {
                    Text("Copy, Share, and Export use the complete post and responses.")
                }
            }
            .navigationTitle("Export options")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
            }
        }
        .presentationDetents([.medium])
        .dcFormSheet()
    }
}

// MARK: - Post preview

/// Full-screen view of the pulled post and responses (first and last 50 lines).
struct PostPreviewView: View {
    @ObservedObject var app: AppModel
    @State private var isExpanded = false

    private var source: String {
        app.currentSession?.source ?? ""
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if source.isEmpty {
                    ContentUnavailableView(
                        "Post not pulled",
                        systemImage: "text.bubble",
                        description: Text("Pull the post and responses to view a compact preview.")
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 30)
                } else {
                    Button {
                        isExpanded.toggle()
                    } label: {
                        Label(
                            isExpanded ? "Hide preview" : "Show first and last 50 lines",
                            systemImage: isExpanded ? "chevron.down" : "chevron.right"
                        )
                        .font(.subheadline)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("postResponsesDisclosure")
                    .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")

                    if isExpanded {
                        Text(ForumPreview.compact(source))
                            .font(.body)
                            .textSelection(.enabled)
                            .accessibilityIdentifier("pulledPostContent")
                    }

                    Text("Copy, Share, and Export use the complete post and responses.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(18)
            .frame(maxWidth: 860, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(DCTheme.pageBackground)
    }
}

// MARK: - Full screen

struct ExpandedPanel: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var app: AppModel
    let route: ExpandedPanelRoute

    var body: some View {
        NavigationStack {
            Group {
                switch route {
                case .topic:
                    AssistantPanel(app: app, onExpand: nil, onOpenURL: { _ in dismiss() })
                case .post:
                    PostPreviewView(app: app)
                case .activity:
                    ActivityPanel(app: app)
                case .settings:
                    SettingsRootView(app: app)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .navigationTitle(route.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                        .keyboardShortcut(.cancelAction)
                }
            }
        }
    }
}

private struct PlainTextDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText] }
    var text: String

    init(text: String) {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        text = configuration.file.regularFileContents
            .flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

struct WorkProgressCard: View {
    let record: WorkRecord
    let cancel: () -> Void

    private var tint: Color {
        switch record.type {
        case .summary, .pull: DCTheme.summaryTint
        case .chat: DCTheme.chatTint
        case .agent: DCTheme.agentTint
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                    .tint(tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(taskTitle)
                        .font(.subheadline.weight(.semibold))
                    Text(record.statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .contentTransition(.opacity)
                        .animation(DCMotion.quick, value: record.statusText)
                }
                Spacer(minLength: 4)
                if let progress = record.progress {
                    Text(progress, format: .percent.precision(.fractionLength(0)))
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .foregroundStyle(tint)
                        .contentTransition(.numericText())
                        .animation(DCMotion.quick, value: progress)
                }
                Button("Cancel", role: .destructive, action: cancel)
                    .font(.subheadline.weight(.medium))
                    .buttonStyle(.borderless)
            }
            AssistantProgressBar(value: record.progress, tint: tint)
        }
        .dcCard(tint: tint)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("workProgressCard")
    }

    private var taskTitle: String {
        switch record.type {
        case .summary: "Creating summary"
        case .pull: "Pulling post + replies"
        case .chat: "Answering"
        case .agent: "Asking the forum"
        }
    }
}

/// A chat bubble with a tail-side corner.
struct ChatBubbleShape: Shape {
    let isUser: Bool

    func path(in rect: CGRect) -> Path {
        let large: CGFloat = 18
        let small: CGFloat = 6
        return Path(
            roundedRect: rect,
            cornerRadii: RectangleCornerRadii(
                topLeading: large,
                bottomLeading: isUser ? large : small,
                bottomTrailing: isUser ? small : large,
                topTrailing: large
            ),
            style: .continuous
        )
    }
}

private struct ChatBubble: View {
    let message: ChatMessage
    let onEdit: (() -> Void)?
    var isStreaming = false

    private var isUser: Bool { message.role == .user }

    var body: some View {
        HStack(alignment: .bottom) {
            if isUser { Spacer(minLength: 40) }
            VStack(alignment: isUser ? .trailing : .leading, spacing: 6) {
                if isUser {
                    Text(message.content)
                        .font(.body)
                        .foregroundStyle(.white)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    MarkdownView(message.content)
                        .textSelection(.enabled)
                }
                if isUser, let onEdit {
                    Button(action: onEdit) {
                        Label("Edit", systemImage: "pencil")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(.white.opacity(0.2), in: Capsule())
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Edit")
                }
                if isStreaming {
                    TypingIndicator(tint: DCTheme.chatTint)
                        .scaleEffect(0.8, anchor: .leading)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background {
                if isUser {
                    ChatBubbleShape(isUser: true)
                        .fill(LinearGradient(
                            colors: [DCTheme.brandBlue, Color(light: 0x4A57E8, dark: 0x5B6FE0)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ))
                } else {
                    ChatBubbleShape(isUser: false).fill(DCTheme.surface)
                }
            }
            .overlay {
                if !isUser {
                    ChatBubbleShape(isUser: false).stroke(DCTheme.border)
                }
            }
            if !isUser { Spacer(minLength: 24) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(isUser ? "You" : "Assistant")
        .accessibilityIdentifier("chatMessage-\(message.role.rawValue)")
    }
}

/// Tracks whether a scroll view shows its end (iOS 18+; older systems use the
/// bottom anchor's appear/disappear instead).
private struct ScrollBottomTracker: ViewModifier {
    @Binding var atBottom: Bool

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            // Track the distance itself: it changes with every scroll, so the
            // final position always reaches the action (a Bool can be coalesced
            // away while a lazy stack re-estimates its height).
            content.onScrollGeometryChange(for: CGFloat.self) { geometry in
                (geometry.contentSize.height - geometry.visibleRect.maxY).rounded()
            } action: { _, distance in
                let isAtBottom = distance < 48
                if atBottom != isAtBottom { atBottom = isAtBottom }
            }
        } else {
            content
        }
    }
}
