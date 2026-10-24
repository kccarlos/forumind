import SwiftUI

// MARK: - Unified Ask box (§5)
//
// One field at the bottom of the AI drawer. The scope button on its left
// picks *This topic* (the topic's chat: assistant model, forum context
// limit) or *Whole forum* (Ask the forum: an agent run on the forum picked
// in the same menu). The scope is `assistantMode` (`.agent` is Whole forum),
// so the model pill, the shared links and the App Intents that set the mode
// keep working. The box edits one of the three existing drafts and carries
// the typed text along when the scope (or the run it follows up) changes.

enum AskScope: String {
    case topic, forum
}

/// The draft the Ask box edits.
enum AskDraftTarget {
    /// This topic: `ComposerDrafts.chat`.
    case chat
    /// Whole forum, a new run: `ComposerDrafts.goal`.
    case goal
    /// Whole forum, a follow-up to the selected finished run: `ComposerDrafts.followUp`.
    case followUp
}

/// Example questions for Ask the forum; sent to the model as the user's
/// question, so they are in the app's language (the answer follows the
/// question's language).
enum AgentExamples {
    static var questions: [String] {
        [
            String(localized: "What are people discussing this week?", comment: "Example question for the forum research agent"),
            String(localized: "Most helpful answers about getting started", comment: "Example question for the forum research agent"),
            String(localized: "Common problems people report lately", comment: "Example question for the forum research agent")
        ]
    }
}

extension AppModel {
    var askScope: AskScope { assistantMode == .agent ? .forum : .topic }

    /// The finished run the box follows up, unless a new question is being
    /// written.
    var askFollowUpRun: AgentRun? {
        guard askScope == .forum, !agentComposesNewQuestion,
              let run = selectedAgentRun, run.isFinished else { return nil }
        return run
    }

    /// The selected run is still working: the box waits for it (as the old
    /// goal box did), or a new question can be started instead.
    var askWaitsForRun: Bool {
        guard askScope == .forum, !agentComposesNewQuestion, let run = selectedAgentRun else { return false }
        return !run.isFinished
    }

    /// Whole forum shows its empty state: examples and recent runs.
    var asksNewForumQuestion: Bool {
        agentComposesNewQuestion || agentRuns.isEmpty
    }

    /// The draft the box shows. Typed text stays in front: a run finishing
    /// or another run being selected never swaps it for the other, empty
    /// Whole forum draft (the scope and question buttons move it along,
    /// `carryingAskText`).
    var askDraftTarget: AskDraftTarget {
        let wanted = askWantedDraftTarget
        guard askScope == .forum, !asksNewForumQuestion else { return wanted }
        switch (drafts.goal.isEmpty, drafts.followUp.isEmpty) {
        case (false, true): return .goal
        case (true, false): return .followUp
        default: return wanted
        }
    }

    /// The draft the state asks for: the chat, a new question, or a
    /// follow-up to the selected finished run.
    private var askWantedDraftTarget: AskDraftTarget {
        switch askScope {
        case .topic: .chat
        case .forum: askFollowUpRun == nil ? .goal : .followUp
        }
    }

    var askDraft: String {
        get { drafts[keyPath: Self.draftKeyPath(askDraftTarget)] }
        set { drafts[keyPath: Self.draftKeyPath(askDraftTarget)] = newValue }
    }

    private static func draftKeyPath(_ target: AskDraftTarget) -> ReferenceWritableKeyPath<ComposerDrafts, String> {
        switch target {
        case .chat: \.chat
        case .goal: \.goal
        case .followUp: \.followUp
        }
    }

    /// This topic or Whole forum (on the forum chosen last).
    func setAskScope(_ scope: AskScope) {
        guard scope != askScope else { return }
        carryingAskText {
            assistantMode = scope == .forum ? .agent : .chat
        }
    }

    /// Whole forum on `siteURL` (nil: the page's forum). A selected run on
    /// another forum gives way to a new question.
    func chooseAskForum(siteURL: String?) {
        carryingAskText {
            agentSiteURL = siteURL
            assistantMode = .agent
            if let run = selectedAgentRun, run.siteURL != agentForum?.siteURL {
                agentComposesNewQuestion = true
            }
        }
    }

    /// Whole forum: write a new question instead of a follow-up.
    func startNewAgentQuestion() {
        carryingAskText { agentComposesNewQuestion = true }
    }

    /// Back to the selected run from a new question.
    func showSelectedAgentRun() {
        carryingAskText { agentComposesNewQuestion = false }
    }

    /// Runs `change`; when it moves the box to another draft, the typed text
    /// moves along (unless the other draft already has text of its own).
    private func carryingAskText(_ change: () -> Void) {
        let from = askDraftTarget
        change()
        let to = askWantedDraftTarget
        guard from != to else { return }
        let source = Self.draftKeyPath(from)
        let destination = Self.draftKeyPath(to)
        guard !drafts[keyPath: source].isEmpty, drafts[keyPath: destination].isEmpty else { return }
        drafts[keyPath: destination] = drafts[keyPath: source]
        drafts[keyPath: source] = ""
    }

    var canSendAsk: Bool {
        let text = askDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        switch askDraftTarget {
        case .chat:
            guard let topicKey = currentTopic?.topicKey else { return false }
            return !hasActiveWork(topicKey: topicKey, type: .chat)
                && !(currentSession?.source.isEmpty ?? true)
        case .goal:
            return !askWaitsForRun && agentForum != nil
        case .followUp:
            // Kept while the selected run is still working; sent once it ends.
            return askFollowUpRun != nil
        }
    }

    /// Sends the box: a chat question, a new agent run on the chosen forum,
    /// or a follow-up to the selected run.
    func sendAsk() {
        guard canSendAsk else { return }
        switch askDraftTarget {
        case .chat:
            sendChat()
        case .goal:
            startAgentRun(goal: drafts.goal, siteURL: agentForum?.siteURL)
        case .followUp:
            if let run = askFollowUpRun { continueAgentRun(id: run.id, question: drafts.followUp) }
        }
    }
}

/// The field, its scope button and the controls around it. Hosted at the
/// bottom of the iPhone drawer; one view so the iPad panel can host it too.
struct AskBox: View {
    @ObservedObject var app: AppModel
    @ObservedObject private var drafts: ComposerDrafts
    /// This topic: the instructions and chat context size sheet.
    let onShowInstructions: () -> Void
    @FocusState private var focused: Bool
    @State private var showsScopeHint = false
    @Environment(\.composerFocusChanged) private var composerFocusChanged
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(app: AppModel, onShowInstructions: @escaping () -> Void) {
        self.app = app
        self.onShowInstructions = onShowInstructions
        _drafts = ObservedObject(wrappedValue: app.drafts)
    }

    private var scope: AskScope { app.askScope }
    private var target: AskDraftTarget { app.askDraftTarget }
    private var tint: Color { scope == .topic ? DCTheme.summaryTint : DCTheme.agentTint }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showsSuggestions {
                suggestionRow
                    .transition(.opacity)
            }
            if showsScopeHint {
                scopeHint
                    .transition(.opacity)
            }
            HStack(alignment: .bottom, spacing: 6) {
                scopeButton
                if scope == .topic {
                    instructionsButton
                        .transition(.opacity)
                }
                field
                if app.showsVoiceButton {
                    VoiceBarButton(voice: app.voice)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .background {
            Rectangle()
                .fill(.bar)
                .overlay(alignment: .top) { Divider() }
                .ignoresSafeArea(edges: .bottom)
        }
        .animation(DCMotion.respecting(reduceMotion, DCMotion.quick), value: scope)
        .animation(DCMotion.respecting(reduceMotion, DCMotion.quick), value: showsSuggestions)
        .sensoryFeedback(.selection, trigger: scope)
        .onChange(of: scope) { showsScopeHint = false }
        .onChange(of: app.askFocusRequest) { focused = true }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("askBox")
    }

    // MARK: Scope

    private var scopeTitle: String {
        switch scope {
        case .topic: String(localized: "This topic", comment: "Ask box scope: questions about the open topic")
        case .forum: app.agentForum?.displayName ?? String(localized: "Whole forum", comment: "Ask box scope: questions to the whole forum (Ask the forum)")
        }
    }

    /// This topic / Whole forum, and which forum Whole forum asks.
    private var scopeButton: some View {
        Menu {
            Section {
                Button {
                    app.setAskScope(.topic)
                } label: {
                    scopeItem(String(localized: "This topic", comment: "Ask box scope: questions about the open topic"),
                              systemImage: "text.bubble", checked: scope == .topic)
                }
                .disabled(app.currentTopic == nil)
                Button {
                    app.setAskScope(.forum)
                } label: {
                    scopeItem(String(localized: "Whole forum", comment: "Ask box scope: questions to the whole forum (Ask the forum)"),
                              systemImage: "sparkle.magnifyingglass", checked: scope == .forum)
                }
            }
            Section("Search this forum") {
                if let pageForum = app.assistantForum {
                    Button {
                        app.chooseAskForum(siteURL: nil)
                    } label: {
                        scopeItem(String(localized: "Use this page’s forum"), systemImage: "arrow.uturn.backward",
                                  checked: scope == .forum && (app.agentSiteURL == nil || app.agentSiteURL == pageForum.siteURL))
                    }
                }
                ForEach(app.pinnedForums + app.recentForums) { forum in
                    Button {
                        app.chooseAskForum(siteURL: forum.siteURL)
                    } label: {
                        scopeItem(forum.displayName, systemImage: forum.isPinned ? "pin" : "clock",
                                  checked: scope == .forum && app.agentSiteURL == forum.siteURL)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(verbatim: scopeTitle)
                    .lineLimit(1)
                    .contentTransition(.opacity)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.bold))
            }
            .font(.footnote.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 12)
            .frame(height: 40)
            .background(tint.opacity(0.12), in: Capsule())
            .frame(minHeight: DCTheme.controlHeight)
            .contentShape(Rectangle())
        }
        .frame(maxWidth: 140, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityLabel(Text("Ask: \(scopeTitle)", comment: "Accessibility label of the Ask box's scope button; the placeholder is This topic or a forum name"))
        .accessibilityHint(Text("Switches between this topic and the whole forum", comment: "Accessibility hint of the Ask box's scope button"))
        .accessibilityIdentifier("askScopeButton")
    }

    @ViewBuilder
    private func scopeItem(_ title: String, systemImage: String, checked: Bool) -> some View {
        if checked {
            Label(title, systemImage: "checkmark")
        } else {
            Label(title, systemImage: systemImage)
        }
    }

    /// Once, the first time the field is focused (§5).
    private var scopeHint: some View {
        Label {
            Text("This topic / Whole forum", comment: "One-time hint next to the Ask box's scope button: it switches between these two")
        } icon: {
            Image(systemName: "arrow.turn.left.down")
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.leading, 12)
        .accessibilityIdentifier("askScopeHint")
    }

    // MARK: This topic

    private var instructionsButton: some View {
        Button(action: onShowInstructions) {
            Image(systemName: app.currentSession?.hasInstructions == true ? "text.badge.checkmark" : "text.quote")
                .foregroundStyle(app.currentSession?.hasInstructions == true ? tint : .secondary)
        }
        .buttonStyle(DCIconButtonStyle())
        .accessibilityLabel("Instructions and context")
        .accessibilityIdentifier("chatInstructions")
        .disabled(app.currentTopic == nil)
    }

    /// Empty This topic: key points, warnings, latest replies, disagreements.
    private var showsSuggestions: Bool {
        guard scope == .topic, let topicKey = app.currentTopic?.topicKey else { return false }
        return (app.currentSession?.history.isEmpty ?? true) && !app.hasActiveWork(topicKey: topicKey, type: .chat)
    }

    /// (chip title, question put in the field). The question is sent as the
    /// user's own words, so it is in the app's language.
    static var suggestions: [(String, String)] {
        [
            (
                String(localized: "Key takeaways", comment: "Chat suggestion chip"),
                String(localized: "What are the key takeaways?", comment: "Chat question filled in by the Key takeaways chip")
            ),
            (
                String(localized: "Warnings", comment: "Chat suggestion chip"),
                String(localized: "Are there any warnings or important caveats?", comment: "Chat question filled in by the Warnings chip")
            ),
            (
                String(localized: "Latest replies", comment: "Chat suggestion chip"),
                String(localized: "What do the latest replies add?", comment: "Chat question filled in by the Latest replies chip")
            ),
            (
                String(localized: "Disagreements", comment: "Chat suggestion chip"),
                String(localized: "Where do people disagree, and why?", comment: "Chat question filled in by the Disagreements chip")
            )
        ]
    }

    private var suggestionRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Self.suggestions, id: \.0) { suggestion in
                    Button {
                        DCHaptics.tap()
                        app.drafts.chat = suggestion.1
                        focused = true
                    } label: {
                        Label(suggestion.0, systemImage: "sparkle")
                            .labelStyle(.titleAndIcon)
                            .font(.footnote.weight(.semibold))
                            .padding(.horizontal, 12)
                            .frame(minHeight: 32)
                            .foregroundStyle(tint)
                            .background(tint.opacity(0.1), in: Capsule())
                            .overlay { Capsule().stroke(tint.opacity(0.22)) }
                            .frame(minHeight: DCTheme.controlHeight)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Fills the question box")
                }
            }
            .padding(.horizontal, 2)
        }
        .accessibilityIdentifier("askSuggestions")
    }

    // MARK: Field

    private var placeholder: String {
        switch target {
        case .chat:
            return app.currentSession?.history.isEmpty ?? true
                ? String(localized: "Ask about this topic")
                : String(localized: "Ask a follow-up question…")
        case .goal:
            if app.askWaitsForRun { return String(localized: "Ask another question…") }
            if let name = app.agentForum?.displayName {
                return String(localized: "Ask \(name) anything…", comment: "Ask the forum placeholder; the placeholder is a forum name")
            }
            return String(localized: "Ask the forum anything…")
        case .followUp:
            return String(localized: "Ask a follow-up…")
        }
    }

    private var fieldIdentifier: String {
        switch target {
        case .chat: "chatInput"
        case .goal: "agentGoalInput"
        case .followUp: "agentFollowUpInput"
        }
    }

    private var sendLabel: LocalizedStringKey {
        switch target {
        case .chat: "Send question"
        case .goal: "Ask the forum"
        case .followUp: "Send follow-up"
        }
    }

    /// One TextField whatever the scope, so switching never drops the focus
    /// or the keyboard; its draft, placeholder and identifier follow the scope.
    private var field: some View {
        HStack(alignment: .bottom, spacing: 4) {
            TextField(text: $app.askDraft, prompt: Text(verbatim: ""), axis: .vertical) {
                Text(verbatim: placeholder)
            }
            .lineLimit(1...6)
            .padding(.leading, 14)
            .padding(.vertical, 11)
            // The placeholder cross-fades with the scope (a prompt would not).
            .background(alignment: .topLeading) {
                if app.askDraft.isEmpty {
                    Text(verbatim: placeholder)
                        .foregroundStyle(Color(uiColor: .placeholderText))
                        .lineLimit(1)
                        .padding(.leading, 14)
                        .padding(.vertical, 11)
                        .id(placeholder)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .animation(DCMotion.respecting(reduceMotion, DCMotion.quick), value: placeholder)
            .focused($focused)
            .onChange(of: focused) {
                composerFocusChanged(focused)
                if focused, !UserDefaults.standard.bool(forKey: PresentationRouter.askScopeHintKey) {
                    UserDefaults.standard.set(true, forKey: PresentationRouter.askScopeHintKey)
                    withAnimation(DCMotion.respecting(reduceMotion)) { showsScopeHint = true }
                } else if !focused {
                    withAnimation(DCMotion.respecting(reduceMotion)) { showsScopeHint = false }
                }
            }
            // Esc leaves the field (a hardware keyboard). A key command, not
            // onKeyPress: the text field's editor never hands Esc on.
            .background {
                if focused {
                    Button { focused = false } label: { EmptyView() }
                        .keyboardShortcut(.cancelAction)
                        .opacity(0)
                        .frame(width: 0, height: 0)
                        .accessibilityHidden(true)
                }
            }
            #if DEBUG
            .task {
                // `-dc-focus-chat`: raise the keyboard (QA screenshots).
                if AssistantDebug.has("-dc-focus-chat") {
                    try? await Task.sleep(for: .milliseconds(900))
                    focused = true
                }
            }
            #endif
            .accessibilityIdentifier(fieldIdentifier)
            .onSubmit {
                if app.canSendAsk { send() }
            }

            sendButton
        }
        .background(Color(uiColor: .systemBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(focused ? tint : DCTheme.border, lineWidth: focused ? 1.5 : 1)
        }
        .animation(DCMotion.quick, value: focused)
    }

    private var sendButton: some View {
        let canSend = app.canSendAsk
        return Button {
            send()
        } label: {
            Image(systemName: "arrow.up")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(canSend ? AnyShapeStyle(tint) : AnyShapeStyle(Color.secondary.opacity(0.35)), in: Circle())
                .frame(width: DCTheme.controlHeight - 2, height: DCTheme.controlHeight - 2)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .keyboardShortcut(.return, modifiers: .command)
        .disabled(!canSend)
        .accessibilityLabel(sendLabel)
        // The old run button's identifier; the others are found by label.
        .accessibilityIdentifier(target == .goal ? "runAgent" : "")
        .animation(DCMotion.quick, value: canSend)
    }

    private func send() {
        DCHaptics.tap()
        // A forum question runs for a while: put the keyboard away.
        if target != .chat { focused = false }
        app.sendAsk()
    }
}
