import SwiftUI

// The Assistant's page-state cards
// and the small pieces the assistant screens share: forum icon, mode
// switcher, provider setup card, progress bar, typing indicator.

extension AssistantMode {
    /// Visible title; the accessibility tree uses `accessibilityTitle`.
    var title: String {
        switch self {
        case .summary: String(localized: "Summary", comment: "Assistant mode: the topic's AI summary")
        case .chat: String(localized: "Chat", comment: "Assistant mode: chat about the open topic")
        case .agent: String(localized: "Ask the forum", comment: "Assistant mode: the research agent that searches the whole forum")
        }
    }

    /// The name in the accessibility tree ("Summary", "Chat", "Agent" in
    /// English, as the UI tests expect), translated for VoiceOver.
    var accessibilityTitle: String {
        switch self {
        case .summary: String(localized: "Summary", comment: "Assistant mode: the topic's AI summary")
        case .chat: String(localized: "Chat", comment: "Assistant mode: chat about the open topic")
        case .agent: String(localized: "Agent", comment: "VoiceOver name of the “Ask the forum” assistant mode (the research agent)")
        }
    }

    /// Used when the full titles don't fit the mode switcher.
    var shortTitle: String {
        switch self {
        case .summary: String(localized: "Summary", comment: "Assistant mode: the topic's AI summary")
        case .chat: String(localized: "Chat", comment: "Assistant mode: chat about the open topic")
        case .agent: String(localized: "Ask", comment: "Short form of the “Ask the forum” assistant mode, for narrow switchers")
        }
    }

    var systemImage: String {
        switch self {
        case .summary: "text.alignleft"
        case .chat: "bubble.left.and.bubble.right"
        case .agent: "sparkle.magnifyingglass"
        }
    }

    var tint: Color {
        switch self {
        case .summary: DCTheme.summaryTint
        case .chat: DCTheme.chatTint
        case .agent: DCTheme.agentTint
        }
    }
}

// MARK: - Forum icon

/// A forum's favicon, or a colored monogram when it has none (or offline).
struct AssistantForumIcon: View {
    let siteURL: String?
    let name: String
    var iconURL: URL?
    var size: CGFloat = 28

    init(forum: Forum?, size: CGFloat = 28) {
        siteURL = forum?.siteURL
        name = forum?.displayName ?? "Forumind"
        iconURL = ForumIconPolicy.loadsRemoteIcons ? forum?.iconURL : nil
        self.size = size
    }

    private var tint: Color {
        siteURL.map(DCTheme.forumTint(for:)) ?? DCTheme.brandBlue
    }

    private var monogram: String {
        let letters = name.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
        return letters.first.map { String($0).uppercased() } ?? "D"
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
        ZStack {
            if siteURL == nil {
                BrandMark(size: size)
            } else {
                shape.fill(tint)
                Text(monogram)
                    .font(.system(size: size * 0.5, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                if let iconURL {
                    AsyncImage(url: iconURL) { phase in
                        if let image = phase.image {
                            image.resizable().scaledToFit()
                                .padding(size * 0.08)
                                .background(Color.white)
                        }
                    }
                    .clipShape(shape)
                }
            }
        }
        .frame(width: size, height: size)
        .overlay { shape.stroke(Color.primary.opacity(0.08)) }
        .accessibilityHidden(true)
    }
}

/// "Searching Discourse Meta" style pill with the forum's icon.
struct AssistantForumPill: View {
    let forum: Forum?
    var prefix: String?
    var tint: Color = DCTheme.agentTint

    var body: some View {
        HStack(spacing: 6) {
            AssistantForumIcon(forum: forum, size: 18)
            Text(label)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
        }
        .foregroundStyle(tint)
        .padding(.leading, 4)
        .padding(.trailing, 10)
        .padding(.vertical, 4)
        .background(tint.opacity(0.12), in: Capsule())
    }

    private var label: String {
        let name = forum?.displayName ?? String(localized: "No forum")
        guard let prefix else { return name }
        return String(
            localized: "forumPill.prefixAndName",
            defaultValue: "\(prefix) \(name)",
            comment: "Pill with a forum's icon: an action (e.g. “Searching”), then the forum name"
        )
    }
}

// MARK: - Mode switcher

/// Summary · Chat · Ask the forum, with a sliding selection. Exposed to
/// accessibility (and UI tests) as a segmented picker.
struct AssistantModeSwitcher: View {
    @Binding var mode: AssistantMode
    @Namespace private var namespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Every segment uses the same label variant, the richest that fits.
    private enum LabelVariant: CaseIterable {
        case iconAndTitle, title, iconAndShort, short
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            ForEach(LabelVariant.allCases, id: \.self) { variant in
                HStack(spacing: 2) {
                    ForEach(AssistantMode.allCases) { item in
                        segment(item, variant: variant)
                    }
                }
            }
        }
        .padding(3)
        .background(Color.primary.opacity(0.07), in: Capsule())
        .accessibilityRepresentation {
            Picker("Assistant mode", selection: $mode) {
                ForEach(AssistantMode.allCases) { item in
                    Text(item.accessibilityTitle).tag(item)
                }
            }
            .pickerStyle(.segmented)
        }
        .accessibilityIdentifier("assistantModePicker")
    }

    @ViewBuilder
    private func label(_ item: AssistantMode, variant: LabelVariant) -> some View {
        switch variant {
        case .iconAndTitle: Label(item.title, systemImage: item.systemImage)
        case .title: Text(item.title)
        case .iconAndShort: Label(item.shortTitle, systemImage: item.systemImage)
        case .short: Text(item.shortTitle)
        }
    }

    private func segment(_ item: AssistantMode, variant: LabelVariant) -> some View {
        let selected = mode == item
        return Button {
            guard !selected else { return }
            DCHaptics.tap()
            withAnimation(DCMotion.respecting(reduceMotion, DCMotion.spring)) {
                mode = item
            }
        } label: {
            label(item, variant: variant)
            .labelStyle(SwitcherLabelStyle())
            .fixedSize()
            .font(.subheadline.weight(selected ? .semibold : .medium))
            .lineLimit(1)
            .foregroundStyle(selected ? item.tint : Color.secondary)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: 34)
            .background {
                if selected {
                    Capsule()
                        .fill(Color(uiColor: .systemBackground))
                        .overlay { Capsule().fill(item.tint.opacity(0.1)) }
                        .overlay { Capsule().stroke(item.tint.opacity(0.28)) }
                        .shadow(color: .black.opacity(0.08), radius: 3, y: 1)
                        .matchedGeometryEffect(id: "selection", in: namespace)
                }
            }
            .contentShape(Capsule())
            .contentShape(.hoverEffect, Capsule())
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
    }

    private struct SwitcherLabelStyle: LabelStyle {
        func makeBody(configuration: Configuration) -> some View {
            HStack(spacing: 5) {
                configuration.icon.imageScale(.small)
                configuration.title
            }
        }
    }
}

// MARK: - Provider setup

/// Shown above the assistant while the mode's model can't run. When only
/// that role is missing (the other one works), it says so.
struct ProviderSetupCard: View {
    @ObservedObject var app: AppModel
    let role: ModelRole
    let onSetUp: () -> Void

    /// The other role works: only this one needs a model.
    private var onlyThisRole: Bool { app.isProviderReady(for: role.other) }

    private var title: String {
        guard onlyThisRole else { return String(localized: "Connect an AI provider") }
        switch role {
        case .assistant: return String(localized: "Choose a model for summaries & chat", comment: "Assistant card when only the summaries & chat model isn't ready")
        case .agent: return String(localized: "Choose a model for Ask the forum", comment: "Assistant card when only the Ask the forum model isn't ready")
        }
    }

    private var detail: String {
        guard onlyThisRole else {
            return String(localized: "Summaries, chat and Ask the forum use your own key. It stays in the Keychain.")
        }
        return String(
            localized: "\(app.providerSummary(for: role)) isn’t ready. Pick a model or add its key in Settings › AI models.",
            comment: "Assistant card when one model role isn't ready. The placeholder is a provider and model, e.g. DeepSeek · deepseek-chat."
        )
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "key.horizontal.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(DCTheme.brandGradient, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("Set up", action: onSetUp)
                .buttonStyle(DCActionButtonStyle(prominent: true))
                .accessibilityIdentifier("providerSetupButton")
        }
        .dcCard(tint: DCTheme.brandPurple)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("providerSetupCard")
    }
}

// MARK: - Progress

/// Determinate bar that animates to its value, or a sliding indeterminate one.
///
/// Motion is computed from the clock (`TimelineView`), not started by
/// `onAppear`, so the bar moves whenever it is on screen — however and whenever
/// `value` changed (a job going from its fetch to the AI phase, a view
/// appearing mid-transition). While a job runs, a determinate bar carries a
/// sheen so a long step never looks frozen. With Reduce Motion the sweep and
/// sheen become a gentle pulse.
struct AssistantProgressBar: View {
    let value: Double?
    var tint: Color = DCTheme.summaryTint
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Width of the indeterminate segment, as a fraction of the track.
    static let segment = 0.3
    /// Seconds for one sweep there and back.
    static let sweepPeriod: TimeInterval = 2.2
    static let sheenPeriod: TimeInterval = 2.2
    static let pulsePeriod: TimeInterval = 2.4

    /// Leading edge of the indeterminate segment (fraction of the track
    /// width) at `time`: glides back and forth between -0.1 and 0.8, so the
    /// segment is always mostly on the track (never an empty bar, no snap).
    static func sweepOffset(at time: TimeInterval, period: TimeInterval = sweepPeriod) -> Double {
        let wave = (1 - cos(time / period * 2 * .pi)) / 2
        return -0.1 + 0.9 * wave
    }

    /// 0…1 through the current sweep, eased at both ends.
    static func sweepPhase(at time: TimeInterval, period: TimeInterval) -> Double {
        let phase = (time / period).truncatingRemainder(dividingBy: 1)
        return (1 - cos(max(phase, 0) * .pi)) / 2
    }

    /// A slow breathing opacity between `low` and `high` (Reduce Motion).
    static func pulse(at time: TimeInterval, low: Double, high: Double) -> Double {
        let wave = (1 + sin(time / pulsePeriod * 2 * .pi)) / 2
        return low + (high - low) * wave
    }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(tint.opacity(0.14))
                if let value {
                    determinate(value: value, width: width)
                        .transition(.opacity)
                } else {
                    indeterminate(width: width)
                        .transition(.opacity)
                }
            }
            .clipShape(Capsule())
            .animation(.easeInOut(duration: 0.3), value: value == nil)
        }
        .frame(height: 6)
        .accessibilityElement()
        .accessibilityLabel("Progress")
        .accessibilityValue(value.map { "\(Int(($0 * 100).rounded())) percent" } ?? "In progress")
    }

    private func determinate(value: Double, width: CGFloat) -> some View {
        let fill = max(8, width * min(max(value, 0), 1))
        let sheen = max(24, fill * 0.35)
        return TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            Capsule()
                .fill(LinearGradient(colors: [tint, DCTheme.brandPurple], startPoint: .leading, endPoint: .trailing))
                .overlay(alignment: .leading) {
                    if !reduceMotion {
                        // A highlight gliding along the filled part.
                        LinearGradient(
                            colors: [.white.opacity(0), .white.opacity(0.45), .white.opacity(0)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: sheen)
                        .offset(x: -sheen + (fill + sheen) * Self.sweepPhase(at: time, period: Self.sheenPeriod))
                        .blendMode(.plusLighter)
                    }
                }
                .clipShape(Capsule())
                .opacity(reduceMotion ? Self.pulse(at: time, low: 0.7, high: 1) : 1)
        }
        .frame(width: fill)
        .animation(DCMotion.respecting(reduceMotion), value: value)
    }

    private func indeterminate(width: CGFloat) -> some View {
        TimelineView(.animation(minimumInterval: 1 / 60)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            if reduceMotion {
                Capsule()
                    .fill(tint)
                    .opacity(Self.pulse(at: time, low: 0.25, high: 0.65))
            } else {
                Capsule()
                    .fill(LinearGradient(colors: [tint.opacity(0.6), tint, DCTheme.brandPurple], startPoint: .leading, endPoint: .trailing))
                    .frame(width: width * Self.segment)
                    .offset(x: width * Self.sweepOffset(at: time))
            }
        }
        .frame(width: width, alignment: .leading)
    }
}

/// Three pulsing dots while an answer is on its way.
struct TypingIndicator: View {
    var tint: Color = .secondary
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 20, paused: reduceMotion)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { index in
                    let phase = reduceMotion ? 0.5 : (sin(time * 5 - Double(index) * 0.9) + 1) / 2
                    Circle()
                        .fill(tint)
                        .frame(width: 7, height: 7)
                        .opacity(0.35 + 0.65 * phase)
                        .scaleEffect(0.8 + 0.25 * phase)
                }
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Answering")
    }
}

// MARK: - Page-state cards

/// Eyebrow + title + text header shared by the state cards.
private struct StateCardHeader: View {
    let eyebrow: LocalizedStringKey
    let title: LocalizedStringKey
    var text: LocalizedStringKey?
    var tint: Color = DCTheme.brandBlue

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(eyebrow)
                .textCase(.uppercase)
                .font(.caption.weight(.bold))
                .kerning(0.8)
                .foregroundStyle(tint)
            Text(title)
                .font(.title3.weight(.bold))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            if let text {
                Text(text)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A tappable forum row (icon, name, host).
struct AssistantForumRow: View {
    let forum: Forum
    var detail: String?
    var systemImage = "chevron.right"
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                AssistantForumIcon(forum: forum, size: 32)
                VStack(alignment: .leading, spacing: 1) {
                    Text(forum.displayName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(detail ?? forum.host)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Image(systemName: systemImage)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
            .frame(minHeight: DCTheme.controlHeight)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open \(forum.displayName)")
    }
}

/// Subtle placeholder while the page has not been checked yet.
struct AssistantLoadingState: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 10) {
                bar(width: 90, height: 10)
                bar(width: 230, height: 18)
                bar(width: nil, height: 12)
                bar(width: 180, height: 12)
                bar(width: nil, height: 46).padding(.top, 6)
            }
            .dcCard()
            VStack(alignment: .leading, spacing: 10) {
                bar(width: 120, height: 14)
                bar(width: nil, height: 12)
                bar(width: nil, height: 12)
                bar(width: 200, height: 12)
            }
            .dcCard()
            Label("Loading page…", systemImage: "hourglass")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
        }
        .opacity(pulse ? 0.55 : 1)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading page")
        .accessibilityIdentifier("assistantLoadingState")
    }

    private func bar(width: CGFloat?, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: height / 2.4, style: .continuous)
            .fill(Color.primary.opacity(0.08))
            .frame(maxWidth: width ?? .infinity, alignment: .leading)
            .frame(height: height)
    }
}

/// "This page isn't a Discourse forum" with the user's forums to open.
struct NotForumState: View {
    @ObservedObject var app: AppModel

    private var forums: [Forum] {
        let pinned = app.pinnedForums
        let recent = app.recentForums
        return Array((pinned + recent).prefix(4))
    }

    private var suggested: [SuggestedForum] {
        Array(AppModel.suggestedForums.filter { app.forum(for: $0.siteURL) == nil }.prefix(forums.isEmpty ? 3 : 2))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            StateCardHeader(
                eyebrow: "Current page",
                title: "This page isn’t a Discourse forum",
                text: "Forumind works on forums built with Discourse. Open one to summarize topics, chat about them, or ask the whole forum a question.",
                tint: .secondary
            )
            if let host = app.pageContext.url?.host {
                DCPill(text: host, systemImage: "globe", tint: .secondary)
            }

            if !forums.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Your forums")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(forums) { forum in
                        AssistantForumRow(forum: forum, detail: forum.isPinned ? String(localized: "Pinned · \(forum.host)") : forum.host) {
                            app.openForum(forum)
                        }
                    }
                }
            }
            if !suggested.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(forums.isEmpty ? "Try one of these" : "Suggested")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(suggested) { suggestion in
                        AssistantForumRow(
                            forum: Forum(siteURL: suggestion.siteURL, name: suggestion.name),
                            detail: suggestion.description,
                            systemImage: "arrow.up.right"
                        ) {
                            app.openForum(suggestion)
                        }
                    }
                }
            }
            Button {
                app.showForumsHome()
            } label: {
                Label("All forums", systemImage: "square.grid.2x2")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(DCActionButtonStyle(prominent: false))
            .accessibilityIdentifier("stateAllForums")
        }
        .dcCard()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("notForumState")
    }
}

/// A `/t/…/{id}` page the probe has not confirmed: offer to add the forum.
struct MaybeForumState: View {
    @ObservedObject var app: AppModel
    @State private var adding = false
    @State private var errorText: String?

    private var host: String { app.pageContext.url?.host ?? String(localized: "this site") }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            StateCardHeader(
                eyebrow: "Looks like a Discourse topic",
                title: "Is this a Discourse forum?",
                text: "Forumind couldn’t confirm \(host) yet. If it’s a Discourse forum, add it so the assistant can read topics with your current login.",
                tint: DCTheme.warning
            )
            VStack(alignment: .leading, spacing: 8) {
                step(1, "Add the forum — the app checks it’s Discourse.")
                step(2, "Then create a summary or ask the forum a question.")
            }
            if let errorText {
                Label(errorText, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(DCTheme.danger)
                    .transition(.opacity)
            }
            Button {
                add()
            } label: {
                HStack(spacing: 8) {
                    if adding { ProgressView().tint(.white) }
                    Text(adding ? "Checking \(host)…" : "Add \(host)")
                }
            }
            .buttonStyle(DCPrimaryButtonStyle())
            .disabled(adding || app.pageContext.url == nil)
            .accessibilityIdentifier("maybeAddForum")

            Button {
                errorText = nil
                app.browser.refreshPageContext()
            } label: {
                Label("Try anyway — check the page again", systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(DCActionButtonStyle(prominent: false))
            .accessibilityIdentifier("maybeCheckAgain")
        }
        .dcCard(tint: DCTheme.warning)
        .animation(DCMotion.smooth, value: errorText)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("maybeForumState")
    }

    private func step(_ number: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(number)")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(DCTheme.brandBlue, in: Circle())
            Text(text)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func add() {
        guard let url = app.pageContext.url else { return }
        adding = true
        errorText = nil
        Task {
            do {
                try await app.addForum(fromAddress: url.absoluteString)
                DCHaptics.success()
            } catch {
                errorText = error.localizedDescription
                DCHaptics.warning()
            }
            adding = false
        }
    }
}

/// "You're on {forum}": Ask the forum first, then what the user saved here.
struct ForumHomeState: View {
    @ObservedObject var app: AppModel
    let forum: Forum
    @FocusState private var focused: Bool

    /// Example goals; sent to the model as the user's question, so they are
    /// in the app's language (the answer follows the question's language).
    private let examples = [
        String(localized: "What are people discussing this week?", comment: "Example question for the forum research agent"),
        String(localized: "Most helpful answers about getting started", comment: "Example question for the forum research agent"),
        String(localized: "Common problems people report lately", comment: "Example question for the forum research agent")
    ]

    private var canAsk: Bool {
        !app.agentGoalDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    AssistantForumIcon(forum: forum, size: 44)
                    StateCardHeader(
                        eyebrow: "Discourse forum",
                        title: "You’re on \(forum.displayName)",
                        text: "Open a topic to summarize it, or ask the whole forum a question."
                    )
                }

                TextField("Ask \(forum.displayName) anything…", text: $app.agentGoalDraft, axis: .vertical)
                    .lineLimit(2...5)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Color(uiColor: .systemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(focused ? DCTheme.agentTint : DCTheme.border, lineWidth: focused ? 1.5 : 1)
                    }
                    .focused($focused)
                    .submitLabel(.send)
                    .accessibilityIdentifier("forumHomeGoalInput")

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(examples, id: \.self) { example in
                            Button {
                                app.agentGoalDraft = example
                                focused = true
                            } label: {
                                Text(example)
                                    .font(.footnote.weight(.medium))
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 7)
                                    .background(DCTheme.agentTint.opacity(0.1), in: Capsule())
                                    .foregroundStyle(DCTheme.agentTint)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Button {
                    ask()
                } label: {
                    Label("Ask the forum", systemImage: "sparkle.magnifyingglass")
                }
                .buttonStyle(DCPrimaryButtonStyle())
                .disabled(!canAsk)
                .accessibilityIdentifier("forumHomeAsk")

                Text("Searches and reads \(forum.host) on its own, then answers with sources. It never posts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .dcCard(tint: DCTheme.agentTint)

            recent
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("forumHomeState")
    }

    @ViewBuilder
    private var recent: some View {
        let sessions = app.recentSessions(siteURL: forum.siteURL)
        let runs = Array(app.agentRuns.filter { $0.siteURL == forum.siteURL }.prefix(3))
        VStack(alignment: .leading, spacing: 10) {
            DCSectionHeader(title: String(localized: "Recent on \(forum.displayName)", comment: "Section header; the placeholder is the forum name"))
            if sessions.isEmpty, runs.isEmpty {
                Text("Topics you summarize or chat about here, and your questions to the forum, show up here.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            ForEach(sessions) { session in
                recentRow(
                    icon: "text.alignleft",
                    tint: DCTheme.summaryTint,
                    title: session.title,
                    detail: sessionDetail(session)
                ) {
                    app.open(session: session)
                }
            }
            ForEach(runs) { run in
                recentRow(
                    icon: "sparkle.magnifyingglass",
                    tint: DCTheme.agentTint,
                    title: run.goal,
                    detail: String(localized: "Asked \(run.createdAt.formatted(.relative(presentation: .named)))", comment: "When a question to the forum was asked; the placeholder is a relative time such as “2 hours ago”")
                ) {
                    app.openAgentRun(id: run.id)
                }
            }
        }
        .dcCard()
    }

    private func sessionDetail(_ session: TopicSession) -> String {
        var parts: [String] = []
        if session.hasSummary { parts.append(String(localized: "Summary", comment: "Assistant mode: the topic's AI summary")) }
        if !session.history.isEmpty { parts.append(String(localized: "\(session.history.count) messages", comment: "Number of chat messages")) }
        parts.append(session.lastAccessedAt.formatted(.relative(presentation: .named)))
        return parts.joined(separator: " · ")
    }

    private func recentRow(
        icon: String,
        tint: Color,
        title: String,
        detail: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(tint)
                    .frame(width: 32, height: 32)
                    .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func ask() {
        guard canAsk else { return }
        focused = false
        app.agentSiteURL = forum.siteURL
        app.startAgentRun(goal: app.agentGoalDraft, siteURL: forum.siteURL)
        withAnimation(DCMotion.smooth) {
            app.assistantMode = .agent
        }
    }
}
