import SwiftUI
import UIKit
import UniformTypeIdentifiers

enum ExpandedPanelRoute: String, Identifiable {
    case topic
    case post
    case history
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .topic: String(localized: "Assistant")
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
    /// nil when the panel already owns the whole screen.
    let onExpand: ((ExpandedPanelRoute) -> Void)?
    /// Opens a forum URL in the Browse workspace (the agent's step log uses it).
    let onOpenURL: ((URL) -> Void)?
    @State private var exportOptions = ExportOptions()
    @State private var showingExportOptions = false
    @State private var showingInstructions = false
    @State private var exporting = false
    /// "Tap a post number to jump to it", shown with the first summary.
    @State private var showsCitationTip = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        app: AppModel,
        onExpand: ((ExpandedPanelRoute) -> Void)? = nil,
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
        VStack(spacing: 0) {
            if app.panelRoute == .topic {
                DrawerStatusRow(app: app, podcast: app.podcast, router: app.router, voice: app.voice)
                drawerHeader
                topicContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                // §5: one field for the topic and the whole forum.
                if bodyKind == .summary || bodyKind == .agent {
                    AskBox(app: app) { showingInstructions = true }
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
                app.presentError(error.localizedDescription)
            }
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
            case .settings:
                SettingsPanel(app: app) {
                    withAnimation(DCMotion.respecting(reduceMotion)) {
                        app.panelRoute = .topic
                    }
                }
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

    /// The drawer's one row: its title (Summary, or Ask the forum while the
    /// Ask box asks the whole forum), the model pill, Translate, Read aloud
    /// and the drawer's ··· menu. The system grabber sits above it.
    private var drawerHeader: some View {
        HStack(spacing: 4) {
            if app.panelRoute == .topic {
                Text(drawerTitle)
                    .font(.headline)
                    .lineLimit(1)
                    .contentTransition(.opacity)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("drawerTitle")
                Spacer(minLength: 4)
                drawerModelPill
                if bodyKind == .summary, let session = app.currentSession, session.hasSummary {
                    let text = PostCitations.stripped(session.summary)
                    TranslateButton(app: app, title: session.title, text: text, compact: true)
                        .buttonStyle(DCIconButtonStyle())
                    ReadAloudButton(podcast: app.podcast, id: "summary-\(session.topicKey)", title: session.title, text: text, compact: true)
                        .buttonStyle(DCIconButtonStyle())
                }
                drawerMoreMenu
            } else {
                Text(drawerTitle)
                    .font(.headline)
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .padding(.top, 14)
        .frame(minHeight: DCTheme.controlHeight + 14)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("drawerHeader")
    }

    private var drawerTitle: String {
        switch app.panelRoute {
        case .topic: bodyKind == .agent ? AssistantMode.agent.title : AssistantMode.summary.title
        case .history: String(localized: "History", comment: "Screen title: saved summaries, chats, Ask the forum runs and watched topics")
        case .settings: String(localized: "Settings")
        }
    }

    /// The current scope's model (§6), 36 pt high; tap for the favorites
    /// and AI models. The label cross-fades and the width follows; a model
    /// that can't run shows why instead.
    private var drawerModelPill: some View {
        let role = ModelPill.role(for: app.assistantMode)
        let selection = app.selection(for: role)
        let readiness = app.readiness(of: selection)
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
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .contentTransition(.opacity)
                Image(systemName: "chevron.up.chevron.down")
                    .imageScale(.small)
                    .accessibilityHidden(true)
            }
            .font(.footnote.weight(.semibold))
            .foregroundStyle(ready ? tint : DCTheme.newRepliesBadgeText)
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background(ready ? tint.opacity(0.12) : DCTheme.newRepliesBadgeBackground, in: Capsule())
            .frame(minHeight: DCTheme.controlHeight)
            .contentShape(Rectangle())
            .animation(DCMotion.respecting(reduceMotion, DCMotion.quick), value: model)
            .animation(DCMotion.respecting(reduceMotion, DCMotion.quick), value: role)
        }
        .menuOrder(.fixed)
        .frame(maxWidth: 190)
        // A new model for the same role; a scope change has its own haptic.
        .sensoryFeedback(.impact(weight: .light), trigger: PillState(role: role, selection: selection)) { old, new in
            old.role == new.role && old.selection != new.selection
        }
        .accessibilityLabel(Text("Model: \(ready ? model : "\(model), \(readiness.title)")", comment: "Accessibility label of the AI drawer's model pill; the placeholder is the model name"))
        .accessibilityIdentifier("modelPill")
    }

    private struct PillState: Equatable {
        let role: ModelRole
        let selection: ModelSelection
    }

    // MARK: Drawer ··· menu

    /// §4.4 order: export, the topic's post and pull, instructions, watch,
    /// History (Manage for now), then Clear Chat.
    private var drawerMoreMenu: some View {
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
                    Label("Export Options…", systemImage: "slider.horizontal.3")
                }
                .accessibilityIdentifier("exportOptions")
            }

            Section {
                Button {
                    onExpand?(.post)
                } label: {
                    Label("Post & Responses", systemImage: "text.bubble")
                }
                .accessibilityIdentifier("viewPost")
                .disabled(onExpand == nil || (app.currentSession?.source.isEmpty ?? true))

                Button {
                    app.pullTopic()
                } label: {
                    Label("Pull Post + Replies Only", systemImage: "arrow.down.circle")
                }
                .accessibilityIdentifier("pullPost")
                .disabled(app.currentTopic == nil || activeSummary != nil || activePull != nil)

                Button {
                    showingInstructions = true
                } label: {
                    Label("Instructions & Context", systemImage: "text.quote")
                }
                .accessibilityIdentifier("menuInstructions")
                .disabled(app.currentTopic == nil)

                Button {
                    app.toggleWatchCurrentTopic()
                } label: {
                    if let topicKey = app.currentTopic?.topicKey, app.isWatched(topicKey: topicKey) {
                        Label("Unwatch Topic", systemImage: "eye.slash")
                    } else {
                        Label("Watch Topic", systemImage: "eye")
                    }
                }
                .accessibilityIdentifier("toggleWatchTopic")
                .disabled(app.currentTopic == nil)

                Button {
                    withAnimation(DCMotion.respecting(reduceMotion)) { app.panelRoute = .history }
                } label: {
                    Label("History", systemImage: "clock.arrow.circlepath")
                }
                .accessibilityIdentifier("openHistoryMenu")
            }

            if app.assistantMode != .agent {
                Section { reportAIOutputButton }
            }

            if !(app.currentSession?.history.isEmpty ?? true) {
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
                .font(.body.weight(.medium))
        }
        .buttonStyle(DCIconButtonStyle())
        .accessibilityLabel("More assistant actions")
        .accessibilityIdentifier("assistantMoreMenu")
    }

    /// Report This Summary… (or, in chat, the latest answer): App Review
    /// 1.2. Disabled until there is AI text to report.
    private var reportAIOutputButton: some View {
        let chat = app.assistantMode == .chat
        let target = app.currentAIOutputReport(feature: chat ? .chatAnswer : .summary)
        return Button {
            if let target { app.report(target) }
        } label: {
            if chat {
                Label(String(localized: "Report This Answer…", comment: "Assistant menu: report the AI's latest chat answer"), systemImage: "flag")
            } else {
                Label(String(localized: "Report This Summary…", comment: "Assistant menu: report the AI summary"), systemImage: "flag")
            }
        }
        .disabled(target == nil)
        .accessibilityIdentifier("reportAIOutput")
    }

    /// The pill's menu (ModelMenu, ModelForum): the role, what it is used
    /// for, the favorites with their state, "Use X for both", AI models…, and
    /// while a search runs, that a change waits for the next question.
    @ViewBuilder
    private var modelSwitcherItems: some View {
        let role = app.currentRole
        let current = app.selection(for: role)
        Section {
            Text(role.menuExplanation)
            ForEach(app.visibleFavorites) { favorite in
                Toggle(isOn: Binding(
                    get: { favorite.matches(current) },
                    set: { _ in app.activateFavorite(favorite, for: role) }
                )) {
                    Text(favorite.provider.displayName)
                    Text(app.favoriteDetail(favorite))
                }
            }
        } header: {
            Text(role.title.localizedUppercase)
        }
        if !app.rolesShareModel {
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
        if let running = app.runningSearchModel(for: role) {
            Section {
                Text("A change applies to your next question. The search running now keeps \(running).", comment: "Ask the forum model menu while a search runs. The placeholder is the running search's model.")
            }
        }
    }

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

    private var visibleSummary: String {
        if let activeSummary,
           let streamed = streams.text(for: activeSummary.id),
           !streamed.isEmpty {
            return streamed
        }
        return app.currentSession?.summary ?? ""
    }

    // MARK: Drawer topic (summary + conversation)

    /// §4.4: the summary, then the topic's conversation, with the chat input
    /// pinned at the bottom.
    private var drawerThread: some View {
        ChatThread(app: app, activeChat: activeChat, leading: AnyView(drawerSummary))
    }

    private var drawerSummary: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !app.isProviderReady(for: .assistant) {
                providerCard
            }
            if let record = activePull {
                WorkProgressCard(record: record) { app.cancel(record: record) }
                    .transition(.opacity)
            }
            if let record = activeSummary {
                WorkProgressCard(record: record) { app.cancel(record: record) }
                    .transition(.opacity)
            }
            if visibleSummary.isEmpty {
                if activeSummary != nil {
                    SummaryPlaceholder()
                } else if activePull == nil {
                    drawerSummaryStart
                }
            } else {
                if activeSummary == nil, let session = app.currentSession {
                    drawerSummaryMeta(session)
                    if session.hasStaleSummary {
                        DrawerStaleBanner(session: session) { app.startSummary() }
                    }
                }
                DrawerSummarySections(
                    text: visibleSummary,
                    maximumPost: app.currentSession?.totalPosts
                )
                .accessibilityIdentifier("summaryContent")
                if activeSummary == nil {
                    if showsCitationTip { citationTip }
                    summarizeControl(prominent: false)
                }
            }
        }
        .animation(DCMotion.respecting(reduceMotion), value: activeSummary?.id)
        .animation(DCMotion.respecting(reduceMotion), value: activePull?.id)
        .onChange(of: app.currentSession?.hasSummary == true, initial: true) {
            // Once, with the first summary that has post numbers.
            let key = PresentationRouter.citationTipKey
            guard app.currentSession?.hasSummary == true, !UserDefaults.standard.bool(forKey: key),
                  !PostCitations.numbers(in: app.currentSession?.summary ?? "").isEmpty else { return }
            UserDefaults.standard.set(true, forKey: key)
            showsCitationTip = true
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
    private func summaryMeta(_ session: TopicSession) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                if !session.model.isEmpty {
                    DCPill(text: AppleIntelligenceBackend.displayModel(session.model), systemImage: "cpu", tint: .secondary)
                }
                if let count = session.summaryPostCount ?? session.totalPosts, count > 0 {
                    DCPill(text: String(localized: "\(count) posts"), systemImage: "text.bubble", tint: DCTheme.summaryTint)
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
                    DCPill(
                        text: String(localized: "Kept", comment: "Badge: the user chose to keep this summary (not cleared automatically)"),
                        systemImage: "pin.fill",
                        tint: DCTheme.warning
                    )
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// Model, post count, age, Kept; then the AI label and Retry.
    private func drawerSummaryMeta(_ session: TopicSession) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            summaryMeta(session)
            HStack(spacing: 8) {
                Label {
                    Text("AI-generated, may be wrong", comment: "Label under an AI summary in the AI drawer")
                } icon: {
                    Image(systemName: "sparkles")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("aiGeneratedLabel")
                Spacer(minLength: 0)
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
                .disabled(activePull != nil)
                .accessibilityHint(Text("Writes the summary again", comment: "Accessibility hint of the summary's Retry button"))
                .accessibilityIdentifier("retrySummary")
            }
        }
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

// MARK: - Chat

/// The conversation: a collapsed summary card, messages, and a pinned composer.
private struct ChatThread: View {
    @ObservedObject var app: AppModel
    @ObservedObject private var streams: StreamStore
    let activeChat: WorkRecord?
    /// The summary above the conversation, scrolled from the top.
    let leading: AnyView
    @State private var atBottom = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        app: AppModel,
        activeChat: WorkRecord?,
        leading: AnyView
    ) {
        self.app = app
        _streams = ObservedObject(wrappedValue: app.streams)
        self.activeChat = activeChat
        self.leading = leading
    }

    private var stream: String {
        guard let activeChat else { return "" }
        return streams.text(for: activeChat.id) ?? ""
    }

    private var history: [ChatMessage] {
        app.currentSession?.history ?? []
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        leading
                        if !history.isEmpty || activeChat != nil {
                            conversationHeader
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
                .defaultScrollAnchor(.top)
                .modifier(ScrollBottomTracker(atBottom: $atBottom))
                .scrollDismissesKeyboard(.interactively)
                .accessibilityIdentifier("chatScroll")
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
                    if !atBottom, !history.isEmpty {
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
        }
    }

    /// "Conversation" between the drawer's summary and the messages.
    private var conversationHeader: some View {
        HStack {
            Text("Conversation", comment: "AI drawer: heading above the chat messages about the topic")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Spacer()
        }
        .padding(.top, 8)
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
        .padding(.top, 2)
    }

    private func suggestionChip(_ title: String, question: String) -> some View {
        Button {
            DCHaptics.tap()
            app.drafts.chat = question
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
            ? String(localized: "1M characters", comment: "Chat context size: one million characters")
            : String(localized: "\(app.settings.forumContextLimit / 1_000)k characters", comment: "Chat context size in thousands of characters, e.g. 60k characters")
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
                case .history:
                    HistoryView(app: app)
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
                if showsPercent {
                    // The slot keeps its width while the value is unknown
                    // (queued), so the header never reflows.
                    ZStack(alignment: .trailing) {
                        Text(verbatim: "100%").hidden()
                        if let progress = record.progress {
                            Text(progress, format: .percent.precision(.fractionLength(0)))
                                .foregroundStyle(tint)
                                .contentTransition(.numericText(countsDown: false))
                                .animation(DCMotion.quick, value: progress)
                        }
                    }
                    .font(.subheadline.weight(.semibold).monospacedDigit())
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

// MARK: - AI drawer parts

/// The drawer's optional 44 pt row under the grabber, only while something
/// runs: voice, research progress, "Answer ready", or the Today podcast; and
/// the result cards as a chip (the strip would be under the drawer).
private struct DrawerStatusRow: View {
    @ObservedObject var app: AppModel
    @ObservedObject var podcast: PodcastController
    @ObservedObject var router: PresentationRouter
    @ObservedObject var voice: VoiceController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var inAgentMode: Bool { app.assistantMode == .agent }

    private var research: WorkRecord? { app.activeResearch }
    private var readyAnswer: WorkRecord? { app.readyAnswer }

    var body: some View {
        VStack(spacing: 0) {
            if let session = voice.session, voice.isActive {
                DrawerVoiceStatus(session: session) { voice.end() }
            } else if !inAgentMode, let research {
                row(systemImage: "magnifyingglass", text: research.statusText, progress: research.progress) {
                    showAgent()
                }
            } else if !inAgentMode, readyAnswer != nil {
                row(
                    systemImage: "checkmark.circle.fill",
                    text: String(localized: "Answer ready", comment: "AI drawer status row: an Ask the forum answer finished"),
                    progress: nil
                ) {
                    showAgent()
                }
            } else if podcast.isPlayingEpisode, let episode = podcast.episode {
                DrawerPodcastStatus(player: podcast.player, episode: episode) {
                    app.router.item = .nowPlaying
                }
            }
            if app.browseCursor.showsInDrawer {
                DrawerCardsChip(app: app, router: router)
            }
        }
        .onChange(of: app.assistantMode) {
            if inAgentMode { router.answersSeenAt = Date() }
        }
    }

    private func showAgent() {
        withAnimation(DCMotion.respecting(reduceMotion)) {
            app.assistantMode = .agent
            app.showSelectedAgentRun()
        }
        router.answersSeenAt = Date()
    }

    private func row(systemImage: String, text: String, progress: Double?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            DrawerStatusLabel(systemImage: systemImage, text: text, progress: progress)
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

/// Voice while the drawer is up (the Dock is under it): state, time, End.
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
private struct DrawerSummarySections: View {
    let text: String
    let maximumPost: Int?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The room the summary has: wide drawers (portrait 11" iPad, 820 pt)
    /// set it in two columns, so it fits the drawer at medium height.
    @State private var width: CGFloat = 0
    static let twoColumnMinimumWidth: CGFloat = 640

    var body: some View {
        let sections = Self.sections(of: text)
        let split = width >= Self.twoColumnMinimumWidth && sections.count > 2 ? (sections.count + 1) / 2 : sections.count
        HStack(alignment: .top, spacing: 24) {
            column(Array(sections[..<split]))
            if split < sections.count { column(Array(sections[split...])) }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .animation(.easeOut(duration: 0.25), value: sections.count)
    }

    private func column(_ sections: [String]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
                MarkdownView(PostCitations.linked(section, maximum: maximumPost), citations: true)
                    .textSelection(.enabled)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 8)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
