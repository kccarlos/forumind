import SwiftUI
import UIKit
import UniformTypeIdentifiers

#if DEBUG
enum DrawerRenderProbe {
    nonisolated(unsafe) static var assistantPanelBodies = 0
    nonisolated(unsafe) static var headerBodies = 0
    nonisolated(unsafe) static var chatBubbleBodies = 0
    nonisolated(unsafe) static var chatBubbleMessageIDs: Set<UUID> = []

    static func reset() {
        assistantPanelBodies = 0
        headerBodies = 0
        chatBubbleBodies = 0
        chatBubbleMessageIDs.removeAll()
    }
}
#endif

/// The assistant's screens shown as a sheet (Post & responses; History and
/// Settings over Home and in the drawer layout).
enum ExpandedPanelRoute: String, Identifiable {
    case post
    case history
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .post: String(localized: "Post & responses")
        case .history: String(localized: "History", comment: "Screen title: saved summaries, chats, Ask the forum runs and watched topics")
        case .settings: String(localized: "Settings")
        }
    }
}

/// The assistant column (iPad) or the AI drawer's content (iPhone): a header
/// with the forum, topic and the Summary · Chat · Ask the forum switch, a
/// body that follows the page state (not a forum, forum home, topic…), and
/// the Manage and Settings screens shown in place.
struct AssistantPanel: View {
    @ObservedObject var app: AppModel
    @ObservedObject private var streams: StreamStore
    /// Post & responses as a sheet.
    let onExpand: (ExpandedPanelRoute) -> Void
    /// Opens a forum URL in the Browse workspace (the agent's step log uses it).
    let onOpenURL: ((URL) -> Void)?
    @State private var exporting = false
    @State private var exportDocument: PlainTextDocument?
    @State private var shareItem: ShareTextItem?
    /// "Tap a post number to jump to it", shown with the first summary.
    @State private var showsCitationTip = false
    @State private var renderedSummary: ThrottledParse<DrawerSummarySections.Input, (sections: Int, hasCitations: Bool, rows: [MarkdownRow])>?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        app: AppModel,
        onExpand: @escaping (ExpandedPanelRoute) -> Void,
        onOpenURL: ((URL) -> Void)? = nil
    ) {
        self.app = app
        _streams = ObservedObject(wrappedValue: app.streams)
        self.onExpand = onExpand
        self.onOpenURL = onOpenURL
    }

    private var activeRecords: [WorkRecord] {
        guard let topicKey = app.currentTopic?.topicKey else { return [] }
        return app.activities.filter { $0.topicKey == topicKey && !$0.status.isTerminal }
    }

    private var activeSummary: WorkRecord? { activeRecords.first { $0.type == .summary } }
    private var summaryRun: SummaryRunState {
        guard let topicKey = app.currentTopic?.topicKey else { return .idle }
        return SummaryRunState.resolve(app.activities, topicKey: topicKey)
    }
    private var activePull: WorkRecord? { activeRecords.first { $0.type == .pull } }
    private var activeChat: WorkRecord? { activeRecords.first { $0.type == .chat } }

    var payload: TopicExportPayload {
        app.currentExportPayload
    }

    private func buildExportText() -> String {
        payload.text(options: app.exportOptions)
    }

    func copyExport() {
        UIPasteboard.general.string = buildExportText()
        DCHaptics.success()
    }

    private var exportDisabled: Bool {
        activePull != nil || !app.hasCurrentExportContent(options: app.exportOptions)
    }

    /// What the body shows; the key drives the cross-fade between states.
    private enum BodyKind: Hashable {
        case summary, agent, forumHome, notForum, maybe, loading
    }

    private var bodyKind: BodyKind {
        let state = app.assistantPageState
        if app.assistantMode == .agent, state == .topic || app.agentForum != nil {
            return .agent
        }
        switch state {
        // The drawer shows the summary and the conversation together.
        case .topic: return .summary
        case .forumHome: return .forumHome
        case .notForum: return .notForum
        case .maybe: return .maybe
        case .loading: return .loading
        }
    }

    var body: some View {
        #if DEBUG
        let _ = { DrawerRenderProbe.assistantPanelBodies += 1 }()
        #endif
        VStack(spacing: 0) {
            // Over History and Settings too: voice can always be muted or
            // ended (the rest of the row is about the topic).
            DrawerStatusRow(
                app: app, podcast: app.podcast, router: app.router, voice: app.voice,
                voiceOnly: app.panelRoute != .topic
            )
            if app.panelRoute == .topic {
                drawerHeader
                topicContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                // §5: one field for the topic and the whole forum.
                if bodyKind == .summary || bodyKind == .agent {
                    AskBox(app: app) { app.router.item = .instructions }
                }
            } else {
                routeContent
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // In the drawer the system sheet's glass shows through at medium
        // (opaque at large by itself).
        .background(Color.clear)
        .environment(\.activeCitation, app.citationJump?.number)
        // A pointer over a citation pre-highlights the post on the page.
        .environment(\.citationHover, CitationHoverAction { number in
            Task { await app.browser.highlight([], flash: PostFlash(number: number)) }
        })
        .environment(\.openURL, OpenURLAction { url in
            // `#37` in a summary: scroll the page to the post (§4.5).
            if let number = PostCitations.postNumber(from: url) {
                app.jumpToCitation(number)
                return .handled
            }
            guard ForumBrowserModel.isBrowsableURL(url) else { return .systemAction }
            openInBrowser(url)
            return .handled
        })
        .onChange(of: app.currentTopic?.topicKey) {
            app.exportOptions = ExportOptions()
            renderedSummary = nil
        }
        .fileExporter(
            isPresented: $exporting,
            document: exportDocument,
            contentType: .plainText,
            defaultFilename: "forumind-\(exportSlug).txt"
        ) { result in
            exportDocument = nil
            if case .failure(let error) = result {
                app.presentError(error.localizedDescription)
            }
        }
        .onChange(of: exporting) {
            if !exporting { exportDocument = nil }
        }
        .sheet(item: $shareItem) { item in
            ActivitySheet(text: item.text)
                .presentationDetents([.medium, .large])
        }
    }

    @ViewBuilder
    private var routeContent: some View {
        VStack(spacing: 0) {
            switch app.panelRoute {
            case .topic:
                EmptyView()
            case .history:
                subHeader("History")
                Divider()
                HistoryView(app: app)
            }
        }
    }

    private var exportSlug: String {
        guard let topic = app.currentTopic else { return "topic" }
        let host = ForumSite.host(of: topic.siteURL)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ".", with: "-")
        return "\(host)-\(topic.topicID)"
    }

    /// A post link opens the topic at that post and highlights it. From
    /// the drawer at its large height, like a citation (§4.5), the drawer
    /// steps down to medium so the post shows.
    private func openInBrowser(_ url: URL) {
        if app.router.drawerPhase == .shown, app.router.drawerDetent == .large {
            withAnimation(DCMotion.respecting(reduceMotion, DCMotion.smooth)) { app.router.drawerDetent = .medium }
        }
        app.openLink(url)
        onOpenURL?(url)
    }

    // MARK: Header

    // MARK: Drawer header

    /// The drawer's title (Summary, or Ask the forum while the
    /// Ask box asks the whole forum), the model pill, Translate, Read aloud
    /// and the drawer's ··· menu. The system grabber sits above it.
    private var drawerHeader: some View {
        let role = ModelPill.role(for: app.assistantMode)
        let selection = app.selection(for: role)
        let menuRole = app.currentRole
        let menuSelection = app.selection(for: menuRole)
        let summaryAction: DrawerHeaderView.SummaryAction? = if bodyKind == .summary,
            let session = app.currentSession,
            session.hasSummary {
            .init(topicKey: session.topicKey, title: session.title, summary: session.summary)
        } else {
            nil
        }
        return DrawerHeaderView(
            title: drawerTitle,
            summaryAction: summaryAction,
            modelPill: .init(
                role: role,
                selection: selection,
                readiness: app.readiness(of: selection),
                menuRole: menuRole,
                menuSelection: menuSelection,
                favorites: app.visibleFavorites.map { favorite in
                    .init(
                        favorite: favorite,
                        isSelected: favorite.matches(menuSelection),
                        detail: app.favoriteDetail(favorite)
                    )
                },
                showsUseSameModel: !app.rolesShareModel && app.isProviderSelectable(menuSelection.provider),
                runningSearchModel: app.runningSearchModel(for: menuRole)
            ),
            moreMenu: .init(
                exportDisabled: exportDisabled,
                hasCurrentSource: app.hasCurrentSource,
                canPullPost: app.currentTopic != nil && activeSummary == nil && activePull == nil,
                hasCurrentTopic: app.currentTopic != nil,
                isWatched: app.currentTopic.map { app.isWatched(topicKey: $0.topicKey) },
                isAgentMode: app.assistantMode == .agent,
                isChatMode: app.assistantMode == .chat,
                reportTargets: reportTargets,
                hasChatHistory: !(app.currentSession?.history.isEmpty ?? true)
            ),
            app: app,
            onCopyExport: { copyExport() },
            onShareExport: { shareItem = ShareTextItem(text: buildExportText()) },
            onExportFile: {
                exportDocument = PlainTextDocument(text: buildExportText())
                exporting = true
            },
            onExpandPost: { onExpand(.post) }
        )
        .equatable()
    }

    private var drawerTitle: String {
        switch app.panelRoute {
        case .topic: bodyKind == .agent ? AssistantMode.agent.title : AssistantMode.summary.title
        case .history: String(localized: "History", comment: "Screen title: saved summaries, chats, Ask the forum runs and watched topics")
        }
    }

    /// Reportable AI outputs offered in the assistant `···` menu.
    var reportTargets: [ReportTarget] { app.currentTopicAIOutputReports }

    private func subHeader(_ title: LocalizedStringKey) -> some View {
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
            // Esc closes History in the panel.
            .dcCancelShortcut()
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
        ProviderSetupCard(app: app, role: app.currentRole)
    }

    @ViewBuilder
    private var topicContent: some View {
        let kind = bodyKind
        Group {
            switch kind {
            case .summary:
                drawerThread
            case .agent:
                AgentView(
                    app: app,
                    showsProviderCard: !app.isProviderReady(for: .agent)
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
                if !app.isProviderReady(for: app.currentRole), kind != .loading {
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

    private var streamedSummary: String? {
        guard let activeSummary,
              let streamed = streams.texts[activeSummary.id],
              !streamed.isEmpty else { return nil }
        return streamed
    }

    private var visibleSummary: String {
        activeSummary != nil ? (streamedSummary ?? "") : (app.currentSession?.summary ?? "")
    }

    // MARK: Drawer topic (summary + conversation)

    /// §4.4: the summary, then the topic's conversation, with the chat input
    /// pinned at the bottom.
    private var drawerThread: some View {
        let hiddenPosts = app.currentHiddenPosts
        let streamInput = streamedSummary.map {
            DrawerSummarySections.Input(text: $0, maximumPost: app.currentSession?.totalPosts, hiddenPosts: hiddenPosts)
        }
        let parsed: (sections: Int, hasCitations: Bool, rows: [MarkdownRow]) = if streamInput != nil,
            let renderedSummary,
            !renderedSummary.output.rows.isEmpty {
            renderedSummary.output
        } else if visibleSummary.isEmpty {
            (0, false, [])
        } else {
            DrawerSummarySections.parsed(
                for: .init(text: visibleSummary, maximumPost: app.currentSession?.totalPosts, hiddenPosts: hiddenPosts)
            )
        }
        let isLazy = parsed.hasCitations
            || parsed.rows.count >= MarkdownView.lazyRowThreshold
        return ChatThread(
            app: app,
            topicKey: app.currentTopic?.topicKey ?? "",
            activeChat: activeChat,
            isLazy: isLazy
        ) {
            drawerSummary(rows: parsed.rows)
        }
        .animation(DCMotion.respecting(reduceMotion), value: activeSummary?.id)
        .animation(DCMotion.respecting(reduceMotion), value: activePull?.id)
        .animation(DCMotion.respecting(reduceMotion), value: summaryRun)
        .animation(.easeOut(duration: 0.25), value: parsed.sections)
        .task(id: streamInput) {
            guard let streamInput else {
                renderedSummary = nil
                return
            }
            if let updated = await ThrottledParse.refreshed(
                from: renderedSummary,
                to: streamInput,
                parse: DrawerSummarySections.parsed
            ) {
                renderedSummary = updated
            }
        }
        .onChange(of: app.currentSession?.hasSummary == true, initial: true) {
            // Once, with the first summary that has post numbers.
            let key = PresentationRouter.citationTipKey
            guard app.currentSession?.hasSummary == true, !UserDefaults.standard.bool(forKey: key),
                  !PostCitations.numbers(in: app.currentSession?.summary ?? "", hidden: hiddenPosts).isEmpty else { return }
            UserDefaults.standard.set(true, forKey: key)
            showsCitationTip = true
        }
    }

    @ViewBuilder
    private func drawerSummary(rows: [MarkdownRow]) -> some View {
        if !app.isProviderReady(for: .assistant) {
            providerCard
                .padding(.top, 4)
        }
        if let record = activePull {
            WorkProgressCard(record: record, progress: app.progress) { app.cancel(record: record) }
                .padding(.top, 4)
                .transition(.opacity)
        }
        if let record = activeSummary {
            WorkProgressCard(record: record, progress: app.progress) { app.cancel(record: record) }
                .padding(.top, 4)
                .transition(.opacity)
        }
        if case .failed(let message) = summaryRun {
            SummaryFailedCard(message: message, canRetry: activePull == nil) {
                app.startSummary(regenerate: true)
            }
            .padding(.top, 4)
            .transition(.opacity)
        }
        if rows.isEmpty {
            if activeSummary != nil {
                SummaryPlaceholder()
                    .padding(.top, 4)
                    .transition(.asymmetric(insertion: .opacity, removal: .identity))
            } else if activePull == nil {
                drawerSummaryStart
                    .padding(.top, 4)
            }
        } else {
            if activeSummary == nil, let session = app.currentSession {
                drawerSummaryMeta(session)
                    .padding(.top, 4)
                    .transition(.asymmetric(insertion: .opacity, removal: .identity))
                if session.hasStaleSummary {
                    DrawerStaleBanner(session: session) { app.startSummary() }
                        .disabled(activeSummary != nil || activePull != nil)
                        .padding(.top, 4)
                        .transition(.asymmetric(insertion: .opacity, removal: .identity))
                }
            }
            DrawerSummarySections(
                rows: rows,
                layout: app.router.usesWideDrawerSummary && app.router.drawerDetent == .medium
                    ? .twoColumns
                    : .singleColumn
            )
                .accessibilityIdentifier("summaryContent")
                .transition(.identity)
            if activeSummary == nil {
                if showsCitationTip {
                    citationTip
                        .padding(.top, 4)
                        .transition(.asymmetric(insertion: .opacity, removal: .identity))
                }
                summarizeControl(prominent: false)
                    .padding(.top, 4)
                    .transition(.asymmetric(insertion: .opacity, removal: .identity))
            }
        }
    }

    /// No summary yet: the topic and the main button.
    private var drawerSummaryStart: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(app.currentTopic?.title ?? String(localized: "No topic open"))
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("assistantTopicTitle")
            summarizeControl(prominent: true)
        }
    }

    /// Meta chips: model, post count, age, Kept.
    @ViewBuilder
    private func summaryMeta(_ session: TopicSession) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 6) {
                if !session.model.isEmpty {
                    Text(verbatim: AppleIntelligenceBackend.displayModel(session.model))
                }
                let count = session.summaryPostCount ?? session.totalPosts
                let details = [
                    count.flatMap { $0 > 0 ? String(localized: "\($0) posts") : nil },
                    session.summaryUpdatedAt.map { $0.formatted(.relative(presentation: .named, unitsStyle: .abbreviated)) },
                    session.kept ? String(localized: "Kept") : nil
                ].compactMap { $0 }
                Text(verbatim: details.joined(separator: " · "))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        } else {
            summaryMetaRow(session)
                .minimumScaleFactor(0.85)
                .accessibilityElement(children: .combine)
        }
    }

    private func summaryMetaRow(_ session: TopicSession) -> some View {
        HStack(spacing: 5) {
            if !session.model.isEmpty {
                DCPill(text: AppleIntelligenceBackend.displayModel(session.model), systemImage: "cpu", tint: .secondary)
                    .truncationMode(.middle)
            }
            if let count = session.summaryPostCount ?? session.totalPosts, count > 0 {
                DCPill(text: String(localized: "\(count) posts"), systemImage: "text.bubble", tint: DCTheme.summaryTint)
                    .layoutPriority(1)
            }
            if let date = session.summaryUpdatedAt {
                DCPill(
                    // Abbreviated ("6 min. ago") so the row fits a phone card.
                    text: date.formatted(.relative(presentation: .named, unitsStyle: .abbreviated)),
                    systemImage: "clock",
                    tint: .secondary
                )
                .layoutPriority(1)
            }
            if session.kept {
                DCPill(
                    text: String(localized: "Kept", comment: "Badge: the user chose to keep this summary (not cleared automatically)"),
                    systemImage: "pin.fill",
                    tint: DCTheme.warning
                )
                .layoutPriority(1)
            }
        }
    }

    /// Model, post count, age, Kept; then the AI label and Retry.
    private func drawerSummaryMeta(_ session: TopicSession) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if !dynamicTypeSize.isAccessibilitySize { summaryMeta(session) }
            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 0))
                : AnyLayout(HStackLayout(spacing: 8))
            layout {
                if dynamicTypeSize.isAccessibilitySize {
                    DisclosureGroup {
                        summaryMeta(session)
                    } label: {
                        summaryNotice
                    }
                    .accessibilityIdentifier("summaryDetails")
                } else {
                    summaryNotice
                }
                if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 0) }
                Button {
                    DCHaptics.tap()
                    app.startSummary(regenerate: true)
                } label: {
                    Text("Retry", comment: "Button: writes the AI summary again")
                        .font(.caption.weight(.semibold))
                        .frame(minHeight: DCTheme.controlHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .disabled(activeSummary != nil || activePull != nil)
                .accessibilityHint(Text("Writes the summary again", comment: "Accessibility hint of the summary's Retry button"))
                .accessibilityIdentifier("retrySummary")
            }
        }
    }

    private var summaryNotice: some View {
        Label {
            Text("AI-generated, may be wrong", comment: "Label under an AI summary in the AI drawer")
        } icon: {
            Image(systemName: "sparkles")
        }
        .font(.caption)
        .foregroundStyle(Color.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("aiGeneratedLabel")
    }

    private var citationTip: some View {
        HStack(spacing: 8) {
            Image(systemName: "lightbulb.fill")
                .foregroundStyle(DCTheme.warning)
                .accessibilityHidden(true)
            Text("Tap a post number to jump to it", comment: "First-run tip under the first AI summary with post citations")
                .font(.footnote)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                withAnimation(DCMotion.respecting(reduceMotion)) { showsCitationTip = false }
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(DCIconButtonStyle())
            .accessibilityLabel("Dismiss")
        }
        .padding(.leading, 12)
        .background(DCTheme.warning.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("citationTip")
    }

    /// Tap summarizes with the default batch size; hold to pick a batch size for
    /// this run or to pull the post without summarizing.
    @ViewBuilder
    private func summarizeControl(prominent: Bool) -> some View {
        let menu = Menu {
            Section("Context per batch") {
                ForEach(SummaryBatchLimit.presets, id: \.self) { limit in
                    Button {
                        app.startSummary(batchLimit: limit, regenerate: app.currentSession?.hasSummary == true)
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

/// Equatable drawer header over only the fields it draws so unrelated
/// `AppModel` publishes skip re-evaluating the title, model pill, actions, and
/// more menu.
private struct DrawerHeaderView: View, Equatable {
    struct SummaryAction: Equatable {
        let topicKey: String
        let title: String
        let summary: String
    }

    struct FavoriteItem: Identifiable, Equatable {
        let favorite: FavoriteModel
        let isSelected: Bool
        let detail: String

        var id: FavoriteModel.ID { favorite.id }
    }

    struct ModelPillSnapshot: Equatable {
        let role: ModelRole
        let selection: ModelSelection
        let readiness: ModelReadiness
        let menuRole: ModelRole
        let menuSelection: ModelSelection
        let favorites: [FavoriteItem]
        let showsUseSameModel: Bool
        let runningSearchModel: String?
    }

    struct MoreMenuSnapshot: Equatable {
        let exportDisabled: Bool
        let hasCurrentSource: Bool
        let canPullPost: Bool
        let hasCurrentTopic: Bool
        let isWatched: Bool?
        let isAgentMode: Bool
        let isChatMode: Bool
        let reportTargets: [ReportTarget]
        let hasChatHistory: Bool
    }

    private struct PillState: Equatable {
        let role: ModelRole
        let selection: ModelSelection
    }

    let title: String
    let summaryAction: SummaryAction?
    let modelPill: ModelPillSnapshot
    let moreMenu: MoreMenuSnapshot
    let app: AppModel
    let onCopyExport: () -> Void
    let onShareExport: () -> Void
    let onExportFile: () -> Void
    let onExpandPost: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static func == (lhs: DrawerHeaderView, rhs: DrawerHeaderView) -> Bool {
        lhs.title == rhs.title
            && lhs.summaryAction == rhs.summaryAction
            && lhs.modelPill == rhs.modelPill
            && lhs.moreMenu == rhs.moreMenu
    }

    var body: some View {
        #if DEBUG
        let _ = { DrawerRenderProbe.headerBodies += 1 }()
        #endif
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(spacing: 4))
        return layout {
            HStack(spacing: 4) {
                Text(title)
                    .font(.headline)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.opacity)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("drawerTitle")
                if dynamicTypeSize.isAccessibilitySize {
                    Spacer(minLength: 0)
                    drawerHeaderActions
                }
            }
            if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 4) }
            if !dynamicTypeSize.isAccessibilitySize {
                drawerModelPill
                drawerHeaderActions
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .padding(.top, 14)
        .frame(minHeight: DCTheme.controlHeight + 14)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("drawerHeader")
    }

    private var drawerHeaderActions: some View {
        HStack(spacing: 4) {
            if let action = summaryAction {
                let text = PostCitations.stripped(action.summary)
                TranslateButton(app: app, title: action.title, text: text, compact: true)
                    .buttonStyle(DCIconButtonStyle())
                    .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                ReadAloudButton(podcast: app.podcast, id: "summary-\(action.topicKey)", title: action.title, text: text, compact: true)
                    .buttonStyle(DCIconButtonStyle())
                    .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            }
            drawerMoreMenu
        }
    }

    /// The current scope's model (§6), 36 pt high; tap for the favorites
    /// and AI models. The label cross-fades and the width follows; a model
    /// that can't run shows why instead.
    private var drawerModelPill: some View {
        let role = modelPill.role
        let selection = modelPill.selection
        let readiness = modelPill.readiness
        let model = ModelPill.label(for: selection)
        let ready = readiness == .ready
        let tint = role == .agent ? DCTheme.agentTint : DCTheme.summaryTint
        return Menu {
            modelSwitcherItems
        } label: {
            HStack(spacing: 4) {
                if !ready {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .imageScale(.small)
                        .accessibilityHidden(true)
                }
                Text(verbatim: ready ? model : readiness.title)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: dynamicTypeSize.isAccessibilitySize ? .infinity : nil, alignment: .leading)
                    .multilineTextAlignment(.leading)
                    .truncationMode(.middle)
                    .contentTransition(.opacity)
                Image(systemName: "chevron.up.chevron.down")
                    .font(dynamicTypeSize.isAccessibilitySize ? .system(size: 12, weight: .semibold) : .footnote.weight(.semibold))
                    .imageScale(.small)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: dynamicTypeSize.isAccessibilitySize ? .infinity : nil, alignment: .leading)
            .font(dynamicTypeSize.isAccessibilitySize ? .caption2.weight(.semibold) : .footnote.weight(.semibold))
            .foregroundStyle(ready ? tint : DCTheme.newRepliesBadgeText)
            .padding(.horizontal, dynamicTypeSize.isAccessibilitySize ? 8 : 12)
            .frame(minHeight: 36)
            .background(ready ? tint.opacity(0.12) : DCTheme.newRepliesBadgeBackground, in: RoundedRectangle(cornerRadius: dynamicTypeSize.isAccessibilitySize ? 14 : 18))
            .frame(minHeight: DCTheme.controlHeight)
            .contentShape(Rectangle())
            .animation(DCMotion.respecting(reduceMotion, DCMotion.quick), value: model)
            .animation(DCMotion.respecting(reduceMotion, DCMotion.quick), value: role)
        }
        .menuOrder(.fixed)
        .frame(maxWidth: dynamicTypeSize.isAccessibilitySize ? .infinity : 190)
        // A new model for the same role; a scope change has its own haptic.
        .sensoryFeedback(.impact(weight: .light), trigger: PillState(role: role, selection: selection)) { old, new in
            old.role == new.role && old.selection != new.selection
        }
        .accessibilityLabel(Text("Model: \(ready ? model : "\(model), \(readiness.title)")", comment: "Accessibility label of the AI drawer's model pill; the placeholder is the model name"))
        .accessibilityIdentifier("modelPill")
    }

    /// §4.4 order: export, the topic's post and pull, instructions, watch,
    /// History (Manage for now), then Clear Chat.
    private var drawerMoreMenu: some View {
        Menu {
            if dynamicTypeSize.isAccessibilitySize { drawerModelPill }
            Section {
                Button {
                    onCopyExport()
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .accessibilityIdentifier("copyExport")
                .disabled(moreMenu.exportDisabled)

                Button {
                    onShareExport()
                } label: {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                .accessibilityIdentifier("shareExport")
                .disabled(moreMenu.exportDisabled)

                Button {
                    onExportFile()
                } label: {
                    Label("Export .txt", systemImage: "arrow.down.doc")
                }
                .accessibilityIdentifier("exportExport")
                .disabled(moreMenu.exportDisabled)

                Button {
                    app.router.item = .exportOptions
                } label: {
                    Label("Export Options…", systemImage: "slider.horizontal.3")
                }
                .accessibilityIdentifier("exportOptions")
            }

            Section {
                Button {
                    onExpandPost()
                } label: {
                    Label("Post & Responses", systemImage: "text.bubble")
                }
                .accessibilityIdentifier("viewPost")
                .disabled(!moreMenu.hasCurrentSource)

                Button {
                    app.pullTopic()
                } label: {
                    Label("Pull Post + Replies Only", systemImage: "arrow.down.circle")
                }
                .accessibilityIdentifier("pullPost")
                .disabled(!moreMenu.canPullPost)

                Button {
                    app.router.item = .instructions
                } label: {
                    Label("Instructions & Context", systemImage: "text.quote")
                }
                .accessibilityIdentifier("menuInstructions")
                .disabled(!moreMenu.hasCurrentTopic)

                Button {
                    app.toggleWatchCurrentTopic()
                } label: {
                    if moreMenu.isWatched == true {
                        Label("Unwatch Topic", systemImage: "eye.slash")
                    } else {
                        Label("Watch Topic", systemImage: "eye")
                    }
                }
                .accessibilityIdentifier("toggleWatchTopic")
                .disabled(!moreMenu.hasCurrentTopic)

                Button {
                    withAnimation(DCMotion.respecting(reduceMotion)) { app.panelRoute = .history }
                } label: {
                    Label("History", systemImage: "clock.arrow.circlepath")
                }
                .accessibilityIdentifier("openHistoryMenu")
            }

            if !moreMenu.isAgentMode {
                Section { reportAIOutputButtons }
            }

            if moreMenu.hasChatHistory {
                Section {
                    Button(role: .destructive) {
                        app.clearChat()
                    } label: {
                        Label("Clear Chat", systemImage: "trash")
                    }
                    .accessibilityIdentifier("clearChat")
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(dynamicTypeSize.isAccessibilitySize ? .system(size: 24, weight: .medium) : .body.weight(.medium))
                // Watch Topic lives in this menu: the button answers the tap.
                .dcStateBounce(moreMenu.isWatched)
        }
        .buttonStyle(DCIconButtonStyle())
        .accessibilityLabel("More assistant actions")
        .accessibilityIdentifier("assistantMoreMenu")
    }

    /// Report This Summary… and/or Report This Answer…: App Review 1.2.
    /// Disabled until there is AI text to report.
    @ViewBuilder
    private var reportAIOutputButtons: some View {
        let targets = moreMenu.reportTargets
        if targets.isEmpty {
            Button {} label: {
                if moreMenu.isChatMode {
                    Label(String(localized: "Report This Answer…", comment: "Assistant menu: report the AI's latest chat answer"), systemImage: "flag")
                } else {
                    Label(String(localized: "Report This Summary…", comment: "Assistant menu: report the AI summary"), systemImage: "flag")
                }
            }
            .disabled(true)
            .accessibilityIdentifier("reportAIOutput")
        } else {
            ForEach(targets) { target in
                let isChatAnswer = if case .aiOutput(let output) = target.kind {
                    output.feature == .chatAnswer
                } else {
                    false
                }
                Button {
                    app.report(target)
                } label: {
                    if isChatAnswer {
                        Label(String(localized: "Report This Answer…", comment: "Assistant menu: report the AI's latest chat answer"), systemImage: "flag")
                    } else {
                        Label(String(localized: "Report This Summary…", comment: "Assistant menu: report the AI summary"), systemImage: "flag")
                    }
                }
                .accessibilityIdentifier(
                    targets.count > 1 && isChatAnswer ? "reportAIChatAnswer" : "reportAIOutput"
                )
            }
        }
    }

    /// The pill's menu (ModelMenu, ModelForum): the role, what it is used
    /// for, the favorites with their state, "Use X for both", AI models…, and
    /// while a search runs, that a change waits for the next question.
    @ViewBuilder
    private var modelSwitcherItems: some View {
        let role = modelPill.menuRole
        let current = modelPill.menuSelection
        Section {
            Text(role.menuExplanation)
            ForEach(modelPill.favorites) { item in
                Toggle(isOn: Binding(
                    get: { item.isSelected },
                    set: { _ in app.activateFavorite(item.favorite, for: role) }
                )) {
                    Text(item.favorite.provider.displayName)
                    Text(item.detail)
                }
            }
        } header: {
            Text(role.title.localizedUppercase)
        }
        if modelPill.showsUseSameModel {
            Button {
                app.useSameModel(as: role)
            } label: {
                Label(
                    String(localized: "Use \(ModelPill.label(for: current)) for both", comment: "Model menu: gives the other role this model too. The placeholder is a model name, e.g. claude-opus."),
                    systemImage: "arrow.left.arrow.right"
                )
            }
            .accessibilityIdentifier("modelUseForBoth")
        }
        Button {
            app.requestedSettingsPage = .provider
        } label: {
            Label("AI models…", systemImage: "gearshape")
        }
        .accessibilityIdentifier("modelMenuSettings")
        if let running = modelPill.runningSearchModel {
            Section {
                Text("A change applies to your next question. The search running now keeps \(running).", comment: "Ask the forum model menu while a search runs. The placeholder is the running search's model.")
            }
        }
    }
}

// MARK: - Chat

/// The conversation: a collapsed summary card, messages, and a pinned composer.
private struct ChatThread<Leading: View>: View {
    /// Keep the newest messages eager alongside the streaming bubble so
    /// scroll-to-bottom and follow-streaming never race lazy tail layout.
    private static var eagerTailCount: Int { 4 }
    /// Short conversations stay eager so exact row heights avoid lazy
    /// estimation drift; longer threads render earlier messages lazily.
    private static var lazyHistoryThreshold: Int { 16 }

    private struct HistoryCountKey: Equatable {
        let topicKey: String
        let count: Int
        let lastID: UUID?
    }

    @ObservedObject var app: AppModel
    @ObservedObject private var streams: StreamStore
    let topicKey: String
    let activeChat: WorkRecord?
    let isLazy: Bool
    /// The summary above the conversation, scrolled from the top.
    let leading: Leading
    @State private var atBottom = true
    @State private var userScrolling = false
    @State private var scrollTask: Task<Void, Never>?
    @State private var metricsBox = ScrollMetricsBox()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(
        app: AppModel,
        topicKey: String,
        activeChat: WorkRecord?,
        isLazy: Bool,
        @ViewBuilder leading: () -> Leading
    ) {
        self.app = app
        _streams = ObservedObject(wrappedValue: app.streams)
        self.topicKey = topicKey
        self.activeChat = activeChat
        self.isLazy = isLazy
        self.leading = leading()
    }

    private var stream: String {
        guard let activeChat else { return "" }
        return streams.text(for: activeChat.id) ?? ""
    }

    private var history: [ChatMessage] {
        app.currentSession?.history ?? []
    }

    var body: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Color.clear
                            .frame(height: 0)
                            .id("chatTop")

                        VStack(alignment: .leading, spacing: 8) {
                            if isLazy {
                                LazyVStack(alignment: .leading, spacing: 8) {
                                    leading
                                }
                                .transition(.identity)
                            } else {
                                VStack(alignment: .leading, spacing: 8) {
                                    leading
                                }
                                .transition(.identity)
                            }

                            if !history.isEmpty || activeChat != nil {
                                VStack(alignment: .leading, spacing: 8) {
                                    conversationRows
                                }
                                .transition(.identity)
                            }
                        }
                        .padding(.top, 10)
                        .padding(.horizontal, 14)

                        Color.clear
                            .frame(height: 1)
                            .padding(.top, 12)
                            .padding(.bottom, 14)
                            .id("chatBottom")
                            .onAppear { if #unavailable(iOS 18.0) { atBottom = true } }
                            .onDisappear { if #unavailable(iOS 18.0) { atBottom = false } }
                    }
                    .frame(maxWidth: 860, alignment: .leading)
                    .frame(maxWidth: .infinity)
                    .onGeometryChange(for: Int.self) { Int($0.size.height.rounded()) } action: { newHeight in
                        let grew = metricsBox.contentHeight > 0 && newHeight > metricsBox.contentHeight
                        metricsBox.contentHeight = newHeight
                        if grew, atBottom, !userScrolling, activeChat != nil {
                            scrollUnanimated(proxy: proxy)
                            DispatchQueue.main.async {
                                if atBottom, !userScrolling { scrollUnanimated(proxy: proxy) }
                            }
                        }
                    }
                    .animation(DCMotion.respecting(reduceMotion), value: history.count)
                    .animation(DCMotion.respecting(reduceMotion), value: activeChat?.id)
                }
                .defaultScrollAnchor(.top)
                .modifier(ChatScrollTracker(onPhaseChange: { scrolling in
                    userScrolling = scrolling
                    if scrolling {
                        metricsBox.pinningBottom = false
                        scrollTask?.cancel()
                        scrollTask = nil
                    }
                }, onStateChange: { old, new in
                    metricsBox.nearBottom = new.nearBottom
                    // Lazy rows re-estimating can shrink the content under a
                    // reader who scrolled away; that alone is not "back at the
                    // bottom" and must not resume following.
                    let shrankOnly = new.contentHeight < old.contentHeight && new.offsetY <= old.offsetY
                    if new.nearBottom, atBottom || !shrankOnly {
                        metricsBox.pinningBottom = false
                        if !atBottom { atBottom = true }
                    } else if atBottom, scrollTask != nil, userScrolling, new.offsetY < old.offsetY - 1 {
                        // Only the reader dragging up stops a jump. Lazy rows
                        // re-measuring above the viewport also move the offset
                        // up mid-jump; treating that as the reader froze the
                        // jump thousands of points short of the bottom.
                        scrollTask?.cancel()
                        scrollTask = nil
                        atBottom = false
                    } else if atBottom, scrollTask == nil {
                        let streamGrew = !userScrolling
                            && old.contentHeight > 0
                            && ((activeChat != nil && new.contentHeight > old.contentHeight) || new.viewportHeight < old.viewportHeight)
                            && new.offsetY >= old.offsetY - 1
                        if streamGrew {
                            metricsBox.pinningBottom = true
                            scrollUnanimated(proxy: proxy)
                            DispatchQueue.main.async {
                                metricsBox.pinningBottom = false
                                if atBottom, !userScrolling { scrollUnanimated(proxy: proxy) }
                            }
                        } else if !metricsBox.pinningBottom {
                            atBottom = false
                        }
                    }
                }))
                .scrollDismissesKeyboard(.interactively)
                .accessibilityIdentifier("chatScroll")
                .onChange(of: topicKey) {
                    scrollTask?.cancel()
                    scrollTask = nil
                    userScrolling = false
                    metricsBox.contentHeight = 0
                    atBottom = false
                    scrollUnanimated("chatTop", anchor: .top, proxy: proxy)
                    Task { @MainActor in
                        if atBottom != metricsBox.nearBottom { atBottom = metricsBox.nearBottom }
                    }
                }
                .onChange(of: HistoryCountKey(topicKey: topicKey, count: history.count, lastID: history.last?.id)) { old, new in
                    guard old.topicKey == new.topicKey else { return }
                    if new.lastID != old.lastID, history.last?.role == .user {
                        jumpToBottom(proxy: proxy)
                    } else if new.count > old.count, atBottom, !userScrolling {
                        scrollUnanimated(proxy: proxy)
                    }
                }
                .onChange(of: stream) {
                    // Follow the answer only while the reader is at the bottom.
                    if atBottom, !userScrolling { scrollUnanimated(proxy: proxy) }
                }
                .onDisappear {
                    scrollTask?.cancel()
                    scrollTask = nil
                }
                if !atBottom, !history.isEmpty {
                    Button {
                        jumpToBottom(proxy: proxy)
                    } label: {
                        Image(systemName: "arrow.down")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(DCTheme.chatTint)
                            .frame(width: 44, height: 44)
                            .background(.regularMaterial, in: Circle())
                            .overlay { Circle().stroke(DCTheme.border) }
                            .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .transition(.scale(scale: 0.7).combined(with: .opacity))
                    .accessibilityLabel("Scroll to latest message")
                    .accessibilityIdentifier("chatScrollToBottom")
                }
            }
            .animation(DCMotion.respecting(reduceMotion, DCMotion.quick), value: !atBottom && !history.isEmpty)
        }
    }

    private func scrollUnanimated(_ id: String = "chatBottom", anchor: UnitPoint = .bottom, proxy: ScrollViewProxy) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { proxy.scrollTo(id, anchor: anchor) }
    }

    private func jumpToBottom(proxy: ScrollViewProxy) {
        scrollTask?.cancel()
        atBottom = true
        scrollTask = Task { @MainActor in
            await settleScroll(reduceMotion: reduceMotion, shouldStop: { userScrolling }) {
                proxy.scrollTo("chatBottom", anchor: .bottom)
            }
            guard !Task.isCancelled else { return }
            scrollTask = nil
            if atBottom != metricsBox.nearBottom { atBottom = metricsBox.nearBottom }
        }
    }

    @ViewBuilder
    private var conversationRows: some View {
        if !history.isEmpty || activeChat != nil {
            conversationHeader
        }

        let hiddenPosts = app.currentHiddenPosts
        let splitIndex = history.count > Self.lazyHistoryThreshold
            ? max(0, history.count - Self.eagerTailCount)
            : 0
        let earlierMessages = history[..<splitIndex]
        let recentMessages = history[splitIndex...]

        if !earlierMessages.isEmpty {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(earlierMessages) { message in
                    chatBubbleRow(message, hiddenPosts: hiddenPosts)
                        .id(message.id)
                }
            }
            .transition(.identity)
        }

        ForEach(recentMessages) { message in
            chatBubbleRow(message, hiddenPosts: hiddenPosts)
                .id(message.id)
        }

        if !stream.isEmpty {
            ChatBubble(
                message: ChatMessage(role: .assistant, content: stream),
                maximumPost: app.currentSession?.totalPosts,
                hiddenPosts: hiddenPosts,
                onEdit: nil,
                isStreaming: true
            )
            .equatable()
            .padding(.top, 4)
            .id("chatStream")
        } else if activeChat != nil {
            typingBubble
                .padding(.top, 4)
        }

        if let activeChat {
            chatStatus(activeChat)
                .padding(.top, 4)
        }

        if !history.isEmpty, activeChat == nil, app.activeChatEdit == nil {
            followUpChips
        }
    }

    private func chatBubbleRow(_ message: ChatMessage, hiddenPosts: Set<Int>) -> some View {
        ChatBubble(message: message, maximumPost: app.currentSession?.totalPosts, hiddenPosts: hiddenPosts) {
            app.editChat(messageID: message.id)
        }
        .equatable()
        .padding(.top, 4)
        .transition(.asymmetric(
            insertion: reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .bottom)),
            removal: .opacity
        ))
    }

    /// "Conversation" between the drawer's summary and the messages.
    private var conversationHeader: some View {
        HStack {
            Text("Conversation", comment: "AI drawer: heading above the chat messages about the topic")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Spacer()
        }
        .padding(.top, 12)
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

    private static var suggestions: [(String, String)] { AskBox.suggestions }

    private var followUpChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Self.suggestions.prefix(3), id: \.0) { suggestion in
                    suggestionChip(suggestion.0, question: suggestion.1)
                }
            }
        }
        .padding(.top, 6)
    }

    private func suggestionChip(_ title: String, question: String) -> some View {
        Button {
            DCHaptics.tap()
            app.applyChatSuggestion(question)
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
}

/// Per-topic instructions plus the chat context budget.
struct InstructionsSheet: View {
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
            ? String(localized: "1M characters", comment: "Chat context size: one million characters")
            : String(localized: "\(app.settings.forumContextLimit / 1_000)k characters", comment: "Chat context size in thousands of characters, e.g. 60k characters")
    }
}

// MARK: - Export

struct ExportOptionsSheet: View {
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

    var source: String {
        app.currentModeratedSource
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

    /// DEBUG: `-dc-panel-settings <page>` opens Settings on that sub-page.
    private static var debugInitialPage: SettingsPage? {
        #if DEBUG
        OnboardingDebug.value(after: "-dc-panel-settings").flatMap(SettingsPage.parse)
        #else
        nil
        #endif
    }

    var body: some View {
        NavigationStack {
            Group {
                switch route {
                case .post:
                    PostPreviewView(app: app)
                case .history:
                    HistoryView(app: app)
                case .settings:
                    SettingsRootView(app: app, initialPage: Self.debugInitialPage)
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

private struct ShareTextItem: Identifiable {
    let id = UUID()
    let text: String
}

private struct ActivitySheet: UIViewControllerRepresentable {
    let text: String

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [text], applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
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

/// A failed summary run: what went wrong, and Retry (the same path as the
/// summary's own Retry). The card goes away as soon as a new run is queued,
/// so a second tap has nothing to land on.
private struct SummaryFailedCard: View {
    let message: String
    let canRetry: Bool
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                Text("The summary didn’t finish", comment: "Drawer: a summary run failed; the reason follows")
                    .font(.subheadline.weight(.semibold))
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(DCTheme.warning)
            }
            if !message.isEmpty {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("summaryFailureMessage")
            }
            Button {
                DCHaptics.tap()
                retry()
            } label: {
                Text("Retry", comment: "Button: writes the AI summary again")
                    .font(.subheadline.weight(.semibold))
                    .frame(minHeight: DCTheme.controlHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .disabled(!canRetry)
            .accessibilityHint(Text("Writes the summary again", comment: "Accessibility hint of the summary's Retry button"))
            .accessibilityIdentifier("retryFailedSummary")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dcCard(tint: DCTheme.warning)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("summaryFailedCard")
    }
}

struct WorkProgressCard: View {
    let record: WorkRecord
    @ObservedObject var progress: ProgressStore
    let cancel: () -> Void

    private var tint: Color {
        switch record.type {
        case .summary, .pull: DCTheme.summaryTint
        case .chat: DCTheme.chatTint
        case .agent: DCTheme.agentTint
        }
    }

    var body: some View {
        let fraction = progress.value(for: record.id)
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
                if showsPercent {
                    // The slot keeps its width while the value is unknown
                    // (queued), so the header never reflows.
                    ZStack(alignment: .trailing) {
                        Text(verbatim: "100%").hidden()
                        if let fraction {
                            Text(fraction, format: .percent.precision(.fractionLength(0)))
                                .foregroundStyle(tint)
                                .contentTransition(.numericText(countsDown: false))
                                .animation(DCMotion.quick, value: fraction)
                        }
                    }
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                }
                Button("Cancel", role: .destructive, action: cancel)
                    .font(.subheadline.weight(.medium))
                    .buttonStyle(.borderless)
            }
            AssistantProgressBar(value: fraction, tint: tint)
        }
        .dcCard(tint: tint)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("workProgressCard")
    }

    /// Chat's answer phase is indeterminate, so it shows no percentage.
    private var showsPercent: Bool { record.type != .chat }

    private var taskTitle: String {
        switch record.type {
        case .summary: String(localized: "Creating summary")
        case .pull: String(localized: "Pulling post + replies")
        case .chat: String(localized: "Answering")
        case .agent: String(localized: "Asking the forum")
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

struct ChatBubble: View, Equatable {
    let message: ChatMessage
    var maximumPost: Int? = nil
    var hiddenPosts: Set<Int> = []
    var onEdit: (() -> Void)? = nil
    var isStreaming = false

    static func == (lhs: ChatBubble, rhs: ChatBubble) -> Bool {
        lhs.message == rhs.message
            && lhs.maximumPost == rhs.maximumPost
            && lhs.hiddenPosts == rhs.hiddenPosts
            && (lhs.onEdit != nil) == (rhs.onEdit != nil)
            && lhs.isStreaming == rhs.isStreaming
    }

    private var isUser: Bool { message.role == .user }

    var body: some View {
        #if DEBUG
        let _ = {
            DrawerRenderProbe.chatBubbleBodies += 1
            DrawerRenderProbe.chatBubbleMessageIDs.insert(message.id)
        }()
        #endif
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
                    let linked = DrawerSummarySections.link(message.content, maximum: maximumPost, hidden: hiddenPosts)
                    MarkdownView(linked, citations: linked.contains("](\(PostCitations.scheme):"))
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

private final class ScrollMetricsBox {
    var nearBottom = true
    var contentHeight = 0
    var pinningBottom = false
}

private struct ScrollState: Equatable {
    var nearBottom: Bool
    var contentHeight: Int
    var viewportHeight: Int
    var offsetY: Int
}

/// Tracks scroll phase and whether the bottom of `ChatThread` is in view
/// (iOS 18+; older systems use the bottom anchor's appear/disappear instead).
private struct ChatScrollTracker: ViewModifier {
    let onPhaseChange: (Bool) -> Void
    let onStateChange: (ScrollState, ScrollState) -> Void

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content
                .onScrollPhaseChange { _, phase in
                    onPhaseChange(phase == .interacting || phase == .decelerating)
                }
                .onScrollGeometryChange(for: ScrollState.self) { geometry in
                    ScrollState(
                        nearBottom: geometry.contentSize.height - geometry.visibleRect.maxY < 48,
                        contentHeight: Int(geometry.contentSize.height.rounded()),
                        viewportHeight: Int(geometry.visibleRect.height.rounded()),
                        offsetY: Int(geometry.contentOffset.y.rounded())
                    )
                } action: { old, new in
                    onStateChange(old, new)
                }
        } else {
            content
        }
    }
}

// MARK: - AI drawer parts

/// The drawer's optional 44 pt row under the grabber, only while something
/// runs: voice, research progress, "Answer ready", or the Today podcast; and
/// the result cards as a chip (the strip would be under the drawer).
struct DrawerStatusRow: View {
    @ObservedObject var app: AppModel
    @ObservedObject var podcast: PodcastController
    @ObservedObject var router: PresentationRouter
    @ObservedObject var voice: VoiceController
    /// Over History or Settings: only voice.
    var voiceOnly = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var voiceStatusText: String? {
        if let session = voice.session, voice.isActive {
            return "\(VoiceSessionBar.stateText(session)) · \(DockText.clock(session.connectedSeconds))"
        }
        return voice.inactiveBarMessage
    }

    private var inAgentMode: Bool { app.assistantMode == .agent }

    private var research: WorkRecord? { app.activeResearch }
    private var readyAnswer: WorkRecord? { app.readyAnswer }

    var body: some View {
        VStack(spacing: 0) {
            if let session = voice.session, voice.isActive {
                DrawerVoiceStatus(session: session) {
                    voice.end()
                    voice.dismiss()
                }
            } else if let message = voice.inactiveBarMessage {
                DrawerVoiceInactiveStatus(
                    message: message,
                    isWarning: voice.inactiveBarIsWarning,
                    dismiss: voice.dismiss
                )
            } else if voiceOnly {
                EmptyView()
            } else if !inAgentMode, let research {
                DrawerResearchStatus(record: research, progress: app.progress) {
                    showAnswer(for: research)
                }
            } else if !inAgentMode, let readyAnswer {
                row(
                    systemImage: "checkmark.circle.fill",
                    text: String(localized: "Answer ready", comment: "AI drawer status row: an Ask the forum answer finished")
                ) {
                    showAnswer(for: readyAnswer)
                }
            } else if podcast.isPlayingEpisode, let episode = podcast.episode {
                DrawerPodcastStatus(player: podcast.player, episode: episode) {
                    app.router.item = .nowPlaying
                }
            }
            // The strip over the page is hidden while the AI view is up.
            if !voiceOnly, app.isAIViewShown, app.browseCursor.showsInDrawer {
                DrawerCardsChip(app: app, router: router)
            }
        }
        .onAppear {
            if inAgentMode, !voiceOnly { router.answersSeenAt = Date() }
        }
        .onChange(of: app.assistantMode) {
            if inAgentMode { router.answersSeenAt = Date() }
        }
    }

    private func showAnswer(for record: WorkRecord) {
        withAnimation(DCMotion.respecting(reduceMotion)) { app.showAnswer(for: record) }
    }

    private func row(systemImage: String, text: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            DrawerStatusLabel(systemImage: systemImage, text: text, progress: nil)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("drawerStatusRow")
    }
}

private struct DrawerResearchStatus: View {
    let record: WorkRecord
    @ObservedObject var progress: ProgressStore
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            DrawerStatusLabel(
                systemImage: "magnifyingglass",
                text: record.statusText,
                progress: progress.value(for: record.id)
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("drawerStatusRow")
    }
}

/// The result cards while the drawer is up: "4 sources · 2/4" with ‹ ›,
/// the same jumps as the strip, which comes back when the drawer closes.
private struct DrawerCardsChip: View {
    @ObservedObject var app: AppModel
    @ObservedObject var router: PresentationRouter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var cursor: BrowseCursor { app.browseCursor }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "rectangle.stack")
                .foregroundStyle(cursor.tint)
                .accessibilityHidden(true)
            Text(verbatim: cursor.chipLabel)
                .font(.subheadline.weight(.medium).monospacedDigit())
                .foregroundStyle(cursor.tint)
                .lineLimit(1)
                .accessibilityIdentifier("drawerCardsLabel")
            Spacer(minLength: 0)
            Button {
                move { await app.previous() }
            } label: {
                Image(systemName: "chevron.left").font(.subheadline.weight(.semibold))
            }
            .buttonStyle(DCIconButtonStyle())
            .disabled(!cursor.hasPrevious)
            .accessibilityLabel(Text("Previous result", comment: "Result cards over the page: open the previous card"))
            .accessibilityIdentifier("drawerCardsPrevious")
            Button {
                move { await app.next() }
            } label: {
                Image(systemName: "chevron.right").font(.subheadline.weight(.semibold))
            }
            .buttonStyle(DCIconButtonStyle())
            .disabled(!cursor.hasNext)
            .accessibilityLabel(Text("Next result", comment: "Result cards over the page: open the next card"))
            .accessibilityIdentifier("drawerCardsNext")
        }
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .frame(height: 44)
        .padding(.top, 10)
        .sensoryFeedback(.selection, trigger: cursor.index)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("drawerCardsChip")
    }

    /// The page jumps to the card: a large drawer steps down so it shows.
    private func move(_ jump: @escaping @MainActor () async -> Void) {
        if router.drawerDetent == .large {
            withAnimation(DCMotion.respecting(reduceMotion, DCMotion.smooth)) { router.drawerDetent = .medium }
        }
        Task { await jump() }
    }
}

private struct DrawerPodcastStatus: View {
    @ObservedObject var player: PodcastPlayer
    let episode: PodcastEpisode
    let action: () -> Void

    var body: some View {
        let text = DockText.podcastLine(player: player, episode: episode)
        if player.isActive {
            Button(action: action) {
                DrawerStatusLabel(systemImage: "headphones", text: text, progress: nil)
            }
            .buttonStyle(.plain)
            .nowPlayingZoomSource()
            .accessibilityIdentifier("drawerStatusRow")
        }
    }
}

/// Voice while the drawer is up (the Dock is under it): state, time, Mute,
/// End.
private struct DrawerVoiceStatus: View {
    @ObservedObject var session: VoiceSession
    let end: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            DrawerStatusLabel(
                systemImage: "waveform",
                text: "\(VoiceSessionBar.stateText(session)) · \(DockText.clock(session.connectedSeconds))",
                progress: nil,
                showsChevron: false
            )
            Button {
                DCHaptics.tap()
                session.setMuted(!session.isMuted)
            } label: {
                Image(systemName: session.isMuted ? "mic.slash.fill" : "mic.fill")
                    .foregroundStyle(session.isMuted ? DCTheme.danger : .primary)
            }
            .buttonStyle(DCIconButtonStyle())
            .accessibilityLabel(session.isMuted ? Text("Unmute") : Text("Mute"))
            .accessibilityIdentifier("drawerVoiceMute")
            .padding(.top, 10)
            Button(action: end) {
                Image(systemName: "phone.down.fill")
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(DCTheme.danger, in: Circle())
            }
            .buttonStyle(DCIconButtonStyle())
            .accessibilityLabel(Text("End voice"))
            .accessibilityIdentifier("drawerVoiceEnd")
            .padding(.trailing, 12)
            .padding(.top, 10)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("drawerStatusRow")
    }
}

/// Voice failure or ended status while the drawer or split panel is up.
private struct DrawerVoiceInactiveStatus: View {
    let message: String
    let isWarning: Bool
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: DCTheme.spacingS) {
            Image(systemName: isWarning ? "exclamationmark.triangle.fill" : "waveform")
                .foregroundStyle(isWarning ? DCTheme.warning : .secondary)
                .accessibilityHidden(true)
            Text(verbatim: message)
                .font(.footnote)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("voiceBarState")
            Spacer(minLength: 0)
            VoiceBarCloseButton(action: dismiss)
        }
        .padding(.leading, 16)
        .padding(.vertical, 6)
        .padding(.top, 6)
        .frame(minHeight: 44)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("drawerStatusRow")
    }
}

private struct DrawerStatusLabel: View {
    let systemImage: String
    let text: String
    let progress: Double?
    var showsChevron = true

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(DCTheme.brandBlue)
                .accessibilityHidden(true)
            Text(verbatim: text)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
            Spacer(minLength: 0)
            if let progress {
                ProgressView(value: progress)
                    .frame(width: 44)
                    .tint(DCTheme.brandBlue)
            }
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
        .padding(.top, 10)
        .contentShape(Rectangle())
    }
}

/// While the summary is written and no text has come yet: three lines that
/// pulse (static with Reduce Motion).
private struct SummaryPlaceholder: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach([1.0, 0.92, 0.6], id: \.self) { width in
                GeometryReader { proxy in
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.primary.opacity(0.1))
                        .frame(width: proxy.size.width * width)
                }
                .frame(height: 12)
            }
        }
        .modifier(PulseModifier(active: !reduceMotion))
        .accessibilityElement()
        .accessibilityLabel(Text("Writing summary…"))
        .accessibilityIdentifier("summaryPlaceholder")
    }
}

private struct PulseModifier: ViewModifier {
    let active: Bool

    func body(content: Content) -> some View {
        if active {
            content.phaseAnimator([0.45, 1.0]) { view, opacity in
                view.opacity(opacity)
            } animation: { _ in .easeInOut(duration: 0.6) }
        } else {
            content
        }
    }
}

/// The summary's sections (split at its `#`/`##` headings) with `#N`
/// citations as chips. While it streams, each new section fades in and
/// rises 8 pt (only fades with Reduce Motion), never per character.
struct DrawerSummarySections: View {
    enum LayoutMode: Equatable {
        case automatic
        case singleColumn
        case twoColumns
    }

    let rows: [MarkdownRow]
    var layout: LayoutMode = .automatic
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    struct Input: Equatable {
        let text: String
        let maximumPost: Int?
        var hiddenPosts: Set<Int> = []
    }

    private static let linkedCache: NSCache<NSString, NSString> = {
        let cache = NSCache<NSString, NSString>()
        cache.countLimit = 128
        return cache
    }()

    static func link(_ text: String, maximum: Int?, hidden: Set<Int> = []) -> String {
        let hiddenKey = hidden.isEmpty ? "" : hidden.sorted().map(String.init).joined(separator: ",")
        let key = ("\(maximum ?? -1)|\(hiddenKey)|" + text) as NSString
        if let cached = linkedCache.object(forKey: key) {
            return cached as String
        }
        let value = PostCitations.linked(text, maximum: maximum, hidden: hidden)
        linkedCache.setObject(value as NSString, forKey: key)
        return value
    }

    static func parsed(for input: Input) -> (sections: Int, hasCitations: Bool, rows: [MarkdownRow]) {
        let marker = "](\(PostCitations.scheme):"
        var hasCitations = false
        let linked = sections(of: input.text).map { section -> String in
            let value = link(section, maximum: input.maximumPost, hidden: input.hiddenPosts)
            if !hasCitations, value.contains(marker) { hasCitations = true }
            return value
        }
        return (linked.count, hasCitations, MarkdownRow.rows(fromSections: linked, initialTopSpacing: 4, stackSpacing: 8))
    }

    var body: some View {
        switch layout {
        case .singleColumn:
            rowList(rows)
        case .twoColumns, .automatic:
            let columns = Self.columnRows(from: rows)
            if let right = columns.right {
                SummaryTwoColumnLayout(
                    minimumWidth: layout == .twoColumns ? 0 : WorkspaceMetrics.twoColumnSummaryMinimumWidth
                ) {
                    VStack(alignment: .leading, spacing: 8) { rowList(columns.left) }
                    VStack(alignment: .leading, spacing: 8) { rowList(right) }
                }
                .textSelection(.enabled)
            } else {
                rowList(rows)
            }
        }
    }

    @ViewBuilder
    private func rowList(_ items: [MarkdownRow]) -> some View {
        ForEach(Array(items.enumerated()), id: \.offset) { _, row in
            MarkdownBlockView(row: row, citations: true)
                .equatable()
                .transition(.asymmetric(
                    insertion: reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 8)),
                    removal: .identity
                ))
        }
        .textSelection(.enabled)
    }

    private static func columnRows(from rows: [MarkdownRow]) -> (left: [MarkdownRow], right: [MarkdownRow]?) {
        var groups: [[MarkdownRow]] = []
        for row in rows {
            if case .heading(let level, _) = row.content, level <= 2, !groups.isEmpty {
                groups.append([row])
            } else if groups.isEmpty {
                groups.append([row])
            } else {
                groups[groups.count - 1].append(row)
            }
        }
        guard groups.count >= 2 else { return (rows, nil) }
        let split = (groups.count + 1) / 2
        let left = Array(groups[..<split].joined())
        var right = Array(groups[split...].joined())
        if !right.isEmpty { right[0].topSpacing = 4 }
        return (left, right)
    }

    /// Splits before each level-1/2 heading outside code fences.
    static func sections(of markdown: String) -> [String] {
        var sections: [[String]] = [[]]
        var inFence = false
        for line in markdown.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") { inFence.toggle() }
            let isHeading = !inFence && (trimmed.hasPrefix("# ") || trimmed.hasPrefix("## "))
            if isHeading, sections[sections.count - 1].contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                sections.append([])
            }
            sections[sections.count - 1].append(line)
        }
        return sections.map { $0.joined(separator: "\n") }
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}

private struct SummaryTwoColumnLayout: Layout {
    let minimumWidth: CGFloat
    var horizontalSpacing: CGFloat = 20
    var verticalFallbackSpacing: CGFloat = 10

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 2 else { return .zero }
        if let width = proposal.width, width.isFinite, width >= minimumWidth {
            let colWidth = max(0, (width - horizontalSpacing) / 2)
            let left = subviews[0].sizeThatFits(.init(width: colWidth, height: proposal.height))
            let right = subviews[1].sizeThatFits(.init(width: colWidth, height: proposal.height))
            return CGSize(width: width, height: max(left.height, right.height))
        }
        let left = subviews[0].sizeThatFits(proposal)
        let right = subviews[1].sizeThatFits(proposal)
        return CGSize(width: max(left.width, right.width), height: left.height + verticalFallbackSpacing + right.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        if bounds.width >= minimumWidth {
            let colWidth = max(0, (bounds.width - horizontalSpacing) / 2)
            let colProposal = ProposedViewSize(width: colWidth, height: nil)
            subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.minY), anchor: .topLeading, proposal: colProposal)
            subviews[1].place(at: CGPoint(x: bounds.minX + colWidth + horizontalSpacing, y: bounds.minY), anchor: .topLeading, proposal: colProposal)
        } else {
            let rowProposal = ProposedViewSize(width: bounds.width, height: nil)
            let left = subviews[0].sizeThatFits(rowProposal)
            subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.minY), anchor: .topLeading, proposal: rowProposal)
            subviews[1].place(at: CGPoint(x: bounds.minX, y: bounds.minY + left.height + verticalFallbackSpacing), anchor: .topLeading, proposal: rowProposal)
        }
    }
}

/// "12 newer replies · Check for new replies" (totalPosts − summaryPostCount).
private struct DrawerStaleBanner: View {
    let session: TopicSession
    let onCheck: () -> Void

    private var newReplies: Int? {
        guard let total = session.totalPosts, let summarized = session.summaryPostCount, total > summarized else { return nil }
        return total - summarized
    }

    var body: some View {
        Button(action: onCheck) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .accessibilityHidden(true)
                Group {
                    if let newReplies {
                        Text("\(newReplies) newer replies · Check for new replies", comment: "AI drawer banner over a stale summary; the placeholder is the number of replies since it was written")
                    } else {
                        Text("Newer replies · Check for new replies", comment: "AI drawer banner over a stale summary when the number of new replies is unknown")
                    }
                }
                .font(.subheadline.weight(.semibold))
                .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .foregroundStyle(DCTheme.newRepliesBadgeText)
            .padding(.horizontal, 12)
            .frame(minHeight: DCTheme.controlHeight)
            .background(DCTheme.newRepliesBadgeBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("staleSummaryNotice")
    }
}
