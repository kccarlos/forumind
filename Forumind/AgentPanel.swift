import SwiftUI
import UIKit

/// "Ask the forum": a goal box scoped to one forum, the selected run's live
/// step timeline and sourced answer, and a follow-up composer once it ends.
struct AgentView: View {
    @ObservedObject var app: AppModel
    var showsProviderCard = false
    var onSetUpProvider: () -> Void = {}
    /// Opens a topic the agent read in the browser.
    let onOpenTopic: (URL) -> Void
    @FocusState private var goalFocused: Bool
    @FocusState private var followUpFocused: Bool
    /// nil follows the run: open while it works, closed once it has an answer.
    @State private var stepsExpanded: Bool?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var run: AgentRun? { app.selectedAgentRun }

    private var activeRecord: WorkRecord? {
        guard let run else { return nil }
        return app.activeRecord(forAgentRun: run.id)
    }

    private var isRunning: Bool {
        guard let run else { return false }
        return !run.status.isTerminal
    }

    private var forum: Forum? { app.agentForum }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if showsProviderCard {
                            ProviderSetupCard(app: app, role: .agent, onSetUp: onSetUpProvider)
                        }

                        goalComposer

                        if let run {
                            runHeader(run)
                            if !run.steps.isEmpty {
                                stepTimeline(run)
                            }
                            if !run.answer.isEmpty || !run.followUps.isEmpty {
                                answerSection(run)
                                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                            }
                            if !run.error.isEmpty {
                                Label(run.error, systemImage: "exclamationmark.triangle.fill")
                                    .font(.caption)
                                    .foregroundStyle(DCTheme.danger)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .dcCard(tint: DCTheme.danger)
                                    .accessibilityIdentifier("agentRunError")
                            }
                        } else {
                            emptyState
                        }

                        Color.clear
                            .frame(height: 1)
                            .id("agentBottom")
                    }
                    .padding(14)
                    .frame(maxWidth: 860, alignment: .leading)
                    .frame(maxWidth: .infinity)
                    .animation(DCMotion.respecting(reduceMotion), value: run?.steps.count)
                    .animation(DCMotion.respecting(reduceMotion), value: run?.status)
                }
                .scrollDismissesKeyboard(.interactively)
                .accessibilityIdentifier("agentScroll")
                .environment(\.openURL, OpenURLAction { url in
                    guard ForumBrowserModel.isBrowsableURL(url) else { return .systemAction }
                    onOpenTopic(url)
                    return .handled
                })
                #if DEBUG
                .task {
                    if AssistantDebug.has("-dc-scroll-sources") {
                        try? await Task.sleep(for: .milliseconds(600))
                        proxy.scrollTo("agentSources", anchor: .bottom)
                    }
                }
                #endif
                .onChange(of: run?.steps.count ?? 0) {
                    guard isRunning else { return }
                    withAnimation(DCMotion.respecting(reduceMotion)) {
                        proxy.scrollTo("agentBottom", anchor: .bottom)
                    }
                }
            }

            if let run, run.status.isTerminal {
                followUpComposer(run)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .padding(.bottom, 10)
                    .background {
                        Rectangle()
                            .fill(.bar)
                            .overlay(alignment: .top) { Divider() }
                            .ignoresSafeArea(edges: .bottom)
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(DCMotion.respecting(reduceMotion), value: run?.status.isTerminal)
        .onChange(of: app.selectedAgentRunID) { stepsExpanded = nil }
    }

    // MARK: Goal

    private var canRun: Bool {
        !app.agentGoalDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !isRunning && forum != nil
    }

    private var goalComposer: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                forumMenu
                Spacer(minLength: 4)
                if app.agentRuns.count > 1 {
                    historyMenu
                }
            }

            // One TextField in a fixed position, so focusing it (which
            // expands the composer) never recreates it and drops the focus.
            HStack(alignment: .bottom, spacing: 8) {
                goalField(lines: compactComposer ? 1...4 : 2...6)
                if compactComposer {
                    runButton(compact: true)
                        .transition(.opacity)
                }
            }
            if !compactComposer {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        budgetText
                        Spacer(minLength: 4)
                        runButton(compact: false).fixedSize()
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        runButton(compact: false).frame(maxWidth: .infinity)
                        budgetText
                    }
                }
            }
        }
        .dcCard(tint: DCTheme.agentTint)
        .animation(DCMotion.respecting(reduceMotion), value: compactComposer)
    }

    /// With a run on screen the goal box shrinks to one line until focused.
    private var compactComposer: Bool {
        run != nil && !goalFocused && app.agentGoalDraft.isEmpty
    }

    private func goalField(lines: ClosedRange<Int>) -> some View {
        TextField(
            goalPlaceholder,
            text: $app.agentGoalDraft,
            axis: .vertical
        )
        .lineLimit(lines)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(uiColor: .systemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(goalFocused ? DCTheme.agentTint : DCTheme.border, lineWidth: goalFocused ? 1.5 : 1)
        }
        .focused($goalFocused)
        .accessibilityIdentifier("agentGoalInput")
    }

    private var goalPlaceholder: String {
        guard run == nil else { return String(localized: "Ask another question…") }
        if let name = forum?.displayName {
            return String(localized: "Ask \(name) anything…", comment: "Ask the forum placeholder; the placeholder is a forum name")
        }
        return String(localized: "Ask the forum anything…")
    }

    private var budgetText: some View {
        Text(
            "Reads the forum on its own — up to \(app.settings.agentMaxSteps) steps, \(app.settings.agentMaxTopicReads) topics. It never posts.",
            comment: "Ask the forum budget: maximum tool calls (steps) and topic reads per run"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func runButton(compact: Bool) -> some View {
        Button {
            goalFocused = false
            DCHaptics.tap()
            stepsExpanded = nil
            app.startAgentRun(goal: app.agentGoalDraft, siteURL: forum?.siteURL)
        } label: {
            if compact {
                Label("Ask", systemImage: "sparkle.magnifyingglass")
            } else {
                Label("Ask the forum", systemImage: "sparkle.magnifyingglass")
                    .frame(maxWidth: .infinity)
            }
        }
        .buttonStyle(AgentRunButtonStyle())
        // ⌘Return runs the goal (the follow-up field has its own while focused).
        .dcSendShortcut(!followUpFocused)
        .accessibilityLabel("Ask the forum")
        .accessibilityIdentifier("runAgent")
        .disabled(!canRun)
    }

    /// "Searching {forum}" — tap to pick another of the user's forums.
    private var forumMenu: some View {
        Menu {
            Section("Search this forum") {
                ForEach(app.pinnedForums + app.recentForums) { option in
                    Button {
                        app.agentSiteURL = option.siteURL
                    } label: {
                        if option.siteURL == forum?.siteURL {
                            Label(option.displayName, systemImage: "checkmark")
                        } else {
                            Text(option.displayName)
                        }
                    }
                }
            }
            if app.agentSiteURL != nil, let pageForum = app.assistantForum,
               pageForum.siteURL != app.agentSiteURL {
                Button {
                    app.agentSiteURL = nil
                } label: {
                    Label("Use this page’s forum", systemImage: "arrow.uturn.backward")
                }
            }
        } label: {
            HStack(spacing: 4) {
                AssistantForumPill(
                    forum: forum,
                    prefix: String(localized: "Searching", comment: "Prefix before the forum name in Ask the forum: “Searching <forum>”")
                )
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityLabel(forumMenuAccessibilityLabel)
        .accessibilityIdentifier("agentForumMenu")
    }

    private var forumMenuAccessibilityLabel: String {
        if let name = forum?.displayName {
            return String(localized: "Searching \(name). Change forum", comment: "Accessibility label; the placeholder is a forum name")
        }
        return String(localized: "Searching no forum. Change forum")
    }

    private var historyMenu: some View {
        Menu {
            ForEach(app.agentRuns) { previous in
                Button {
                    withAnimation(DCMotion.respecting(reduceMotion)) {
                        app.selectedAgentRunID = previous.id
                    }
                } label: {
                    Label(
                        "\(String(previous.goal.prefix(60))) · \(app.forumInfo(siteURL: previous.siteURL).displayName)",
                        systemImage: statusIcon(previous.status)
                    )
                }
            }
        } label: {
            Label("History", systemImage: "clock.arrow.circlepath")
                .font(.footnote.weight(.semibold))
        }
        .accessibilityIdentifier("agentHistoryMenu")
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("How it works", systemImage: "sparkle.magnifyingglass")
                .font(.headline)
                .foregroundStyle(DCTheme.agentTint)
            howItWorks(
                "magnifyingglass",
                forum.map {
                    String(localized: "Searches \($0.displayName) for your question.", comment: "How Ask the forum works; the placeholder is a forum name")
                } ?? String(localized: "Searches the forum for your question.")
            )
            howItWorks("text.bubble", String(localized: "Reads or summarizes the most relevant topics."))
            howItWorks("checkmark.seal", String(localized: "Answers with numbered sources you can open."))
            Text("Summaries it creates are saved like your own. It can watch topics for new replies.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .dcCard()
    }

    private func howItWorks(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(DCTheme.agentTint)
                .frame(width: 20)
                .accessibilityHidden(true)
            Text(text).font(.subheadline)
        }
    }

    // MARK: Run

    private func runHeader(_ run: AgentRun) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                statusBadge(run.status)
                VStack(alignment: .leading, spacing: 4) {
                    Text(run.goal)
                        .font(.headline)
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("agentRunGoal")
                    Text(runStatusText(run))
                        .font(.caption)
                        .foregroundStyle(run.status == .failed ? DCTheme.danger : .secondary)
                        .contentTransition(.opacity)
                        .accessibilityIdentifier("agentRunStatus")
                }
                Spacer(minLength: 0)
                if let activeRecord {
                    Button("Stop", role: .destructive) {
                        app.cancel(record: activeRecord)
                    }
                    .font(.subheadline.weight(.semibold))
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("cancelAgentRun")
                }
            }
            if !run.status.isTerminal {
                AssistantProgressBar(value: activeRecord?.progress, tint: DCTheme.agentTint)
            }
        }
        .dcCard(tint: run.status.isTerminal ? .clear : DCTheme.agentTint)
    }

    private func statusBadge(_ status: WorkStatus) -> some View {
        ZStack {
            Circle().fill(statusColor(status).opacity(0.14))
            if status.isTerminal {
                Image(systemName: statusIcon(status))
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(statusColor(status))
            } else {
                ProgressView().controlSize(.small).tint(DCTheme.agentTint)
            }
        }
        .frame(width: 32, height: 32)
        .accessibilityHidden(true)
    }

    private func runStatusText(_ run: AgentRun) -> String {
        // Two keys so each count gets its own plural form.
        let steps = [
            String(localized: "\(run.steps.count) steps", comment: "Ask the forum run progress: tool calls made"),
            String(localized: "\(run.readTopicCount) topics read", comment: "Ask the forum run progress: topics read")
        ].joined(separator: " · ")
        switch run.status {
        case .queued:
            return String(localized: "Waiting for a worker · \(steps)", comment: "Run status; the placeholder is “3 steps · 1 topics read”")
        case .running:
            let latest = activeRecord?.statusText ?? String(localized: "Working…")
            return "\(latest) · \(steps)"
        case .completed:
            let when = (run.completedAt ?? run.updatedAt).formatted(.relative(presentation: .named))
            return String(
                localized: "Done · \(steps) · \(when)",
                comment: "Run status; placeholders: “3 steps · 1 topics read” and a relative time such as “2 minutes ago”"
            )
        case .failed:
            return String(localized: "Failed · \(steps)", comment: "Run status; the placeholder is “3 steps · 1 topics read”")
        case .cancelled:
            return String(localized: "Cancelled · \(steps)", comment: "Run status; the placeholder is “3 steps · 1 topics read”")
        }
    }

    private func isStepsExpanded(_ run: AgentRun) -> Bool {
        stepsExpanded ?? (!run.status.isTerminal || run.answer.isEmpty)
    }

    private func stepTimeline(_ run: AgentRun) -> some View {
        let expanded = isStepsExpanded(run)
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(DCMotion.respecting(reduceMotion)) {
                    stepsExpanded = !expanded
                }
            } label: {
                HStack(spacing: 8) {
                    Text("Steps")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text("\(run.steps.count)")
                        .font(.caption.weight(.bold).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Color.primary.opacity(0.07), in: Capsule())
                    if !expanded {
                        toolStrip(run)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            .accessibilityIdentifier("agentStepsToggle")

            if expanded {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(run.steps.enumerated()), id: \.element.id) { index, step in
                        stepRow(
                            step,
                            isLast: index == run.steps.count - 1,
                            isActive: !run.status.isTerminal && index == run.steps.count - 1
                        )
                    }
                }
                .padding(.top, 12)
                .transition(.opacity)
            }
        }
        .dcCard()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("agentStepLog")
    }

    /// Collapsed timeline: one tinted icon per step.
    private func toolStrip(_ run: AgentRun) -> some View {
        HStack(spacing: -4) {
            ForEach(run.steps.suffix(7)) { step in
                Image(systemName: toolIcon(step.tool))
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 18, height: 18)
                    .background(step.isError ? DCTheme.danger : toolTint(step.tool), in: Circle())
                    .overlay { Circle().stroke(DCTheme.surface, lineWidth: 1.5) }
            }
        }
        .accessibilityHidden(true)
    }

    private func stepRow(_ step: AgentStep, isLast: Bool, isActive: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 0) {
                ZStack {
                    Circle()
                        .fill((step.isError ? DCTheme.danger : toolTint(step.tool)).opacity(0.15))
                    if isActive {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: toolIcon(step.tool))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(step.isError ? DCTheme.danger : toolTint(step.tool))
                    }
                }
                .frame(width: 28, height: 28)
                if !isLast {
                    Rectangle()
                        .fill(DCTheme.border)
                        .frame(width: 2)
                        .frame(maxHeight: .infinity)
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(toolTitle(step))
                    .font(.subheadline.weight(.medium))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                if !step.thought.isEmpty {
                    Text(step.thought)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !step.outcome.isEmpty {
                    Text(step.outcome)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(step.isError ? DCTheme.danger : toolTint(step.tool))
                        .lineLimit(3)
                }
            }
            .padding(.top, 4)
            .padding(.bottom, isLast ? 0 : 14)
            Spacer(minLength: 0)
            if let topicKey = step.topicKey, let session = app.sessions[topicKey] {
                Button {
                    onOpenTopic(session.url)
                } label: {
                    Image(systemName: "arrow.up.right.square")
                        .foregroundStyle(DCTheme.brandBlue)
                }
                .buttonStyle(DCIconButtonStyle())
                .accessibilityLabel("Open \(session.title) in Browse")
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("agentStep")
    }

    // MARK: Answer

    private func answerSection(_ run: AgentRun) -> some View {
        let answer = run.initialAnswer.isEmpty ? run.answer : run.initialAnswer
        let sources = AgentSources.extract(from: answer, run: run, sessions: app.sessions)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "text.bubble.fill")
                    .font(.subheadline)
                    .foregroundStyle(DCTheme.agentTint)
                    .frame(width: 32, height: 32)
                    .background(DCTheme.agentTint.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Answer")
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)
                    HStack(spacing: 6) {
                        AssistantForumPill(forum: app.forumInfo(siteURL: run.siteURL))
                        if !sources.isEmpty {
                            Text("\(sources.count) sources")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer(minLength: 0)
                Menu {
                    Button {
                        UIPasteboard.general.string = answer
                        DCHaptics.success()
                    } label: {
                        Label("Copy answer", systemImage: "doc.on.doc")
                    }
                    ShareLink(item: answer) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    if run.status.isTerminal {
                        Button(role: .destructive) {
                            app.deleteAgentRun(id: run.id)
                        } label: {
                            Label("Delete run", systemImage: "trash")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .buttonStyle(DCIconButtonStyle())
                .accessibilityLabel("Answer actions")
                .accessibilityIdentifier("agentAnswerMenu")
            }

            MarkdownView(AgentSources.annotate(answer, sources: sources))
                .textSelection(.enabled)
                .accessibilityIdentifier("agentAnswer")

            if !sources.isEmpty {
                sourcesList(sources)
                    .id("agentSources")
            }

            if !run.followUps.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(run.followUps) { message in
                        followUpRow(message)
                    }
                }
                .padding(.top, 4)
            }
        }
        .dcCard()
    }

    private func sourcesList(_ sources: [AgentSources.Source]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Sources")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            ForEach(sources) { source in
                Button {
                    DCHaptics.tap()
                    onOpenTopic(source.url)
                } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Text(source.label)
                            .font(.caption.weight(.bold).monospacedDigit())
                            .foregroundStyle(DCTheme.agentTint)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(DCTheme.agentTint.opacity(0.14), in: Capsule())
                        VStack(alignment: .leading, spacing: 2) {
                            Text(source.title)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.primary)
                                .multilineTextAlignment(.leading)
                                .lineLimit(2)
                            Text(
                                source.cited
                                    ? (source.url.host ?? "")
                                    : String(localized: "Read, not cited · \(source.url.host ?? "")", comment: "Source the agent read but didn't cite; the placeholder is the forum host")
                            )
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        Image(systemName: "arrow.up.right")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(DCTheme.brandBlue)
                    }
                    .padding(10)
                    .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Source \(source.number): \(source.title)")
                .accessibilityHint("Opens the topic in the browser")
                .accessibilityIdentifier("agentSource-\(source.number)")
            }
        }
    }

    private func followUpRow(_ message: ChatMessage) -> some View {
        Group {
            if message.role == .user {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "person.crop.circle.fill")
                        .foregroundStyle(DCTheme.brandBlue)
                        .accessibilityHidden(true)
                    Text(message.content)
                        .font(.subheadline.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 6)
            } else {
                MarkdownView(message.content)
                    .textSelection(.enabled)
                    .padding(12)
                    .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }

    private func followUpComposer(_ run: AgentRun) -> some View {
        HStack(alignment: .bottom, spacing: 4) {
            TextField("Ask a follow-up…", text: $app.agentFollowUpDraft, axis: .vertical)
                .lineLimit(1...6)
                .padding(.leading, 14)
                .padding(.vertical, 11)
                .focused($followUpFocused)
                .accessibilityIdentifier("agentFollowUpInput")
                .onSubmit { send(run) }

            let canSend = !app.agentFollowUpDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            Button {
                send(run)
            } label: {
                Image(systemName: "arrow.up")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(
                        canSend ? AnyShapeStyle(DCTheme.agentTint) : AnyShapeStyle(Color.secondary.opacity(0.35)),
                        in: Circle()
                    )
                    .frame(width: DCTheme.controlHeight - 2, height: DCTheme.controlHeight - 2)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .hoverEffect(.highlight)
            .dcSendShortcut(followUpFocused)
            .disabled(!canSend)
            .accessibilityLabel("Send follow-up")
        }
        .background(Color(uiColor: .systemBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(followUpFocused ? DCTheme.agentTint : DCTheme.border, lineWidth: followUpFocused ? 1.5 : 1)
        }
    }

    private func send(_ run: AgentRun) {
        followUpFocused = false
        DCHaptics.tap()
        app.continueAgentRun(id: run.id, question: app.agentFollowUpDraft)
    }

    // MARK: Presentation helpers

    private func toolIcon(_ tool: String) -> String {
        switch tool {
        case "search_forum": "magnifyingglass"
        case "list_latest": "clock"
        case "read_topic": "doc.text"
        case "summarize_topic": "text.alignleft"
        case "saved_summaries": "tray.full"
        case "watch_topic": "eye"
        case AgentPrompt.finalAnswerTool: "checkmark"
        default: "questionmark"
        }
    }

    private func toolTint(_ tool: String) -> Color {
        switch tool {
        case "search_forum", "list_latest": DCTheme.brandBlue
        case "read_topic", "saved_summaries": DCTheme.chatTint
        case "summarize_topic": DCTheme.agentTint
        case "watch_topic": DCTheme.warning
        case AgentPrompt.finalAnswerTool: DCTheme.success
        default: .secondary
        }
    }

    private func toolTitle(_ step: AgentStep) -> String {
        func topicName() -> String {
            if let topicKey = step.topicKey, let title = app.sessions[topicKey]?.title { return title }
            let id = step.arguments["topic_id"] ?? ""
            return String(localized: "topic \(id)", comment: "A topic without a known title; the placeholder is its number")
        }
        let query = step.arguments["query"] ?? ""
        switch step.tool {
        case "search_forum":
            return String(localized: "Searched “\(query)”", comment: "Agent step; the placeholder is the search query")
        case "list_latest": return String(localized: "Listed latest topics", comment: "Agent step")
        case "read_topic":
            return String(localized: "Read \(topicName())", comment: "Agent step (past tense); the placeholder is a topic title")
        case "summarize_topic":
            return String(localized: "Summarized \(topicName())", comment: "Agent step; the placeholder is a topic title")
        case "saved_summaries":
            return query.isEmpty
                ? String(localized: "Checked saved summaries", comment: "Agent step")
                : String(localized: "Saved summaries: \(query)", comment: "Agent step; the placeholder is a search query")
        case "watch_topic":
            return String(localized: "Watching \(topicName())", comment: "Agent step; the placeholder is a topic title")
        case AgentPrompt.finalAnswerTool: return String(localized: "Wrote the answer", comment: "Agent step")
        default: return step.tool
        }
    }

    private func statusIcon(_ status: WorkStatus) -> String {
        switch status {
        case .queued, .running: "circle.dotted"
        case .completed: "checkmark"
        case .failed: "exclamationmark"
        case .cancelled: "xmark"
        }
    }

    private func statusColor(_ status: WorkStatus) -> Color {
        switch status {
        case .queued, .running: DCTheme.agentTint
        case .completed: DCTheme.success
        case .failed: DCTheme.danger
        case .cancelled: .secondary
        }
    }
}

/// Compact gradient button for "Ask the forum" inside the goal card.
private struct AgentRunButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .frame(minHeight: DCTheme.controlHeight)
            .background(
                LinearGradient(
                    colors: [DCTheme.brandBlue, DCTheme.brandPurple],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .opacity(isEnabled ? 1 : 0.35),
                in: RoundedRectangle(cornerRadius: DCTheme.controlCornerRadius, style: .continuous)
            )
            .contentShape(.hoverEffect, RoundedRectangle(cornerRadius: DCTheme.controlCornerRadius, style: .continuous))
            .hoverEffect(.lift)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(DCMotion.quick, value: configuration.isPressed)
    }
}
