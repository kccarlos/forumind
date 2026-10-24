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
    /// nil when the panel already owns the whole screen.
    let onExpand: ((ExpandedPanelRoute) -> Void)?
    /// Opens a forum URL in the Browse workspace (the agent's step log uses it).
    let onOpenURL: ((URL) -> Void)?
    /// In the iPhone AI drawer: its height. The drawer has a one-row header
    /// (the page bar already names the forum); at the peek only that row and
    /// one line show.
    var drawerDetent: DrawerDetent?
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
        onOpenURL: ((URL) -> Void)? = nil,
        drawerDetent: DrawerDetent? = nil
    ) {
        self.app = app
        self.onExpand = onExpand
        self.onOpenURL = onOpenURL
        self.drawerDetent = drawerDetent
    }

    private var isDrawer: Bool { drawerDetent != nil }
    private var isPeek: Bool { drawerDetent == .peek }

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
        // The drawer shows the summary and the conversation together.
        case .topic: return app.assistantMode == .chat && !isDrawer ? .chat : .summary
        case .forumHome: return .forumHome
        case .notForum: return .notForum
        case .maybe: return .maybe
        case .loading: return .loading
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if isPeek {
                drawerHeader
                peekLine
                Spacer(minLength: 0)
            } else if isDrawer, app.panelRoute == .topic {
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
        .background(isDrawer ? Color.clear : DCTheme.pageBackground)
        .environment(\.activeCitation, app.citationJump?.number)
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
                if isDrawer { drawerHeader }
                topicHeader
                Divider()
                topicContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        if isDrawer, app.router.drawerDetent == .large {
            withAnimation(DCMotion.respecting(reduceMotion, DCMotion.smooth)) { app.router.drawerDetent = .medium }
        }
        app.openLink(url)
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
        // Ask the forum names its own model here (the topic modes show theirs
        // under the topic title).
        if bodyKind == .agent, let headerForum {
            return "\(headerForum.host) · \(app.providerSummary(for: .agent))"
        }
        if let headerForum { return headerForum.host }
        switch app.assistantPageState {
        case .notForum:
            return app.pageContext.url?.host.map {
                String(localized: "\($0) · not a Discourse forum", comment: "Assistant header subtitle; the placeholder is a website host")
            } ?? String(localized: "Not a Discourse forum")
        case .maybe:
            return app.pageContext.url?.host.map {
                String(localized: "\($0) · checking…", comment: "Assistant header subtitle while checking whether a site is a forum; the placeholder is a website host")
            } ?? String(localized: "Checking this page…")
        default:
            return app.pageContext.url == nil && app.currentForum == nil
                ? String(localized: "No forum open") : String(localized: "Loading page…")
        }
    }

    private var topicHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            // In the drawer the page bar names the forum and the drawer's own
            // header row holds the buttons.
            if !isDrawer { forumRow }

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
        .padding(.top, isDrawer ? 2 : 10)
        .padding(.bottom, 12)
        .background(isDrawer ? Color.clear : DCTheme.toolbar)
        .animation(DCMotion.respecting(reduceMotion), value: headerTitle)
    }

    private var forumRow: some View {
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

            headerButtons
        }
    }

    private var headerButtons: some View {
        HStack(spacing: 0) {
            // Same cross-fade as the back buttons, so opening and
            // leaving Manage/Settings feel alike.
            headerIcon("clock.arrow.circlepath", label: "History", identifier: "openHistory") {
                withAnimation(DCMotion.respecting(reduceMotion)) { app.panelRoute = .history }
            }
            headerIcon("gearshape", label: "Settings", identifier: "openSettings") {
                withAnimation(DCMotion.respecting(reduceMotion)) { app.panelRoute = .settings }
            }
            moreMenu
        }
    }

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
                if !isPeek { drawerModelPill }
                if bodyKind == .summary || bodyKind == .chat, let session = app.currentSession, session.hasSummary {
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

    /// The peek's one line (DrawerPeek): tap to open the drawer to medium.
    /// The first topic ever opened shows it as a tip.
    private var peekLine: some View {
        let text = peekText
        let showsTip = !UserDefaults.standard.bool(forKey: PresentationRouter.summarizeTipKey)
            && bodyKind == .summary && app.isProviderReady(for: .assistant) && visibleSummary.isEmpty
        return Button {
            withAnimation(DCMotion.respecting(reduceMotion, DCMotion.smooth)) { app.router.drawerDetent = .medium }
        } label: {
            HStack(spacing: 8) {
                if showsTip {
                    Image(systemName: "lightbulb.fill")
                        .foregroundStyle(DCTheme.warning)
                        .accessibilityHidden(true)
                }
                Text(text)
                    .font(.subheadline)
                    .foregroundStyle(showsTip ? .primary : .secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, showsTip ? 10 : 0)
            .padding(.vertical, showsTip ? 6 : 0)
            .background {
                if showsTip {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(DCTheme.warning.opacity(0.12))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .onDisappear {
            // Seen once: the tip never comes back.
            if showsTip { UserDefaults.standard.set(true, forKey: PresentationRouter.summarizeTipKey) }
        }
        .accessibilityLabel(Text(verbatim: text))
        .accessibilityHint(Text("Opens the drawer", comment: "Accessibility hint of the AI drawer's peek line"))
        .accessibilityIdentifier("drawerPeekLine")
    }

    private var peekText: String {
        DrawerPeek.line(DrawerPeek.Input(
            pageState: app.assistantPageState,
            mode: bodyKind == .agent ? .agent : app.assistantMode,
            providerReady: app.isProviderReady(for: app.currentRole),
            summary: visibleSummary,
            summaryRunning: activeSummary != nil
        ))
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

    private var headerTitle: String? {
        if app.assistantMode == .agent { return nil }
        return app.currentTopic?.title
    }

    private var metaLine: String {
        var parts = [app.providerSummary(for: .assistant)]
        if let session = app.currentSession, let count = session.totalPosts, count > 0 {
            parts.append(String(localized: "\(count) posts"))
        }
        return parts.joined(separator: " · ")
    }

    private func headerIcon(
        _ systemImage: String,
        label: LocalizedStringKey,
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

            modelSwitcher

            if app.assistantMode != .agent { reportAIOutputButton }

            if app.assistantMode == .chat, !(app.currentSession?.history.isEmpty ?? true) {
                Button(role: .destructive) {
                    app.clearChat()
                } label: {
                    Label("Clear chat", systemImage: "trash")
                }
            }

            if onExpand != nil, !isDrawer {
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

    /// Favorites for the current mode's model (Summary and Chat share one,
    /// Ask the forum has its own); the other role is never changed.
    private var modelSwitcher: some View {
        Menu {
            modelSwitcherItems
        } label: {
            Label(app.currentRole.switcherTitle, systemImage: "cpu")
        }
        .menuOrder(.fixed)
        .accessibilityIdentifier("modelSwitcher")
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
                if isDrawer { drawerThread } else { summaryContent }
            case .chat:
                ChatThread(
                    app: app,
                    activeChat: activeChat,
                    showsProviderCard: !app.isProviderReady(for: .assistant),
                    onShowInstructions: { showingInstructions = true },
                    onCreateSummary: {
                        app.assistantMode = .summary
                        app.startSummary()
                    }
                )
            case .agent:
                AgentView(
                    app: app,
                    showsProviderCard: !app.isProviderReady(for: .agent),
                    usesAskBox: isDrawer
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
           let streamed = app.summaryStreams[activeSummary.id],
           !streamed.isEmpty {
            return streamed
        }
        return app.currentSession?.summary ?? ""
    }

    /// The small caps line above the topic title.
    private var topicEyebrow: String {
        if let name = app.assistantForum?.displayName {
            return String(localized: "Topic on \(name)", comment: "Eyebrow above a topic title; the placeholder is a forum name")
        }
        return String(localized: "Topic on the forum", comment: "Eyebrow above a topic title when the forum name is unknown")
    }

    private var summaryContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if !app.isProviderReady(for: .assistant) {
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

    // MARK: Drawer topic (summary + conversation)

    /// §4.4: the summary, then the topic's conversation, with the chat input
    /// pinned at the bottom.
    private var drawerThread: some View {
        ChatThread(
            app: app,
            activeChat: activeChat,
            showsProviderCard: false,
            onShowInstructions: { showingInstructions = true },
            onCreateSummary: { app.startSummary() },
            leading: AnyView(drawerSummary),
            showsComposer: false
        )
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

    /// No summary yet: the topic hero with Create summary as the primary action.
    private var summaryHero: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text(topicEyebrow.uppercased())
                    .font(.caption.weight(.bold))
                    .kerning(0.8)
                    .foregroundStyle(DCTheme.summaryTint)
                    .lineLimit(1)
                Text(app.currentTopic?.title ?? String(localized: "No topic open"))
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
            // The drawer leaves the page in view, so no "keep browsing".
            if !isDrawer {
                Label("Runs in the background — keep browsing. Hold for batch options.", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
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
                    if let session = app.currentSession, session.hasSummary {
                        ReadAloudButton(podcast: app.podcast, id: "summary-\(session.topicKey)", title: session.title, text: session.summary)
                        TranslateButton(app: app, title: session.title, text: session.summary)
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
                        newReplies.map { String(localized: "Stale summary — \($0) newer replies") }
                            ?? String(localized: "Stale summary — newer replies are available.")
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
    let onShowInstructions: () -> Void
    let onCreateSummary: () -> Void
    /// The drawer: the summary above the conversation (replaces the
    /// collapsed summary card), scrolled from the top.
    var leading: AnyView?
    /// The drawer's Ask box replaces the composer.
    var showsComposer = true
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
                            ProviderSetupCard(app: app, role: .assistant)
                        }

                        if let leading {
                            leading
                            if !history.isEmpty || activeChat != nil {
                                conversationHeader
                            }
                        } else {
                            summaryCard

                            if app.currentSession?.hasStaleSummary == true {
                                StaleSummaryNotice(compact: true)
                            }

                            if history.isEmpty, stream.isEmpty, activeChat == nil {
                                emptyState
                            }
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
                .defaultScrollAnchor(leading == nil ? .bottom : .top)
                .modifier(ScrollBottomTracker(atBottom: $atBottom))
                .scrollDismissesKeyboard(.interactively)
                .accessibilityIdentifier("chatScroll")
                .onAppear {
                    if leading == nil { proxy.scrollTo("chatBottom", anchor: .bottom) }
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
                    if !atBottom, leading == nil || !history.isEmpty {
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

            if showsComposer {
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
        }
        .onChange(of: app.currentTopic?.topicKey) {
            summaryExpanded = false
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

    private static var suggestions: [(String, String)] { AskBox.suggestions }

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
    @Environment(\.composerFocusChanged) private var composerFocusChanged

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
                .onChange(of: focused) { composerFocusChanged(focused) }
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
/// runs: research progress, "Answer ready", or the Today podcast.
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

    var body: some View {
        let sections = Self.sections(of: text)
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
                MarkdownView(PostCitations.linked(section, maximum: maximumPost), citations: true)
                    .textSelection(.enabled)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 8)))
            }
        }
        .animation(.easeOut(duration: 0.25), value: sections.count)
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
