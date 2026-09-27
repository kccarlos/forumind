import SwiftUI

/// The start screen: pinned forums, recent forums, suggestions, and Add
/// forum. Shown when no page is loaded and from the browser bar's Forums
/// button (then with a "Back to page" row).
struct ForumsHome: View {
    @ObservedObject var app: AppModel
    @ObservedObject var browser: ForumBrowserModel
    let onAddForum: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .body) private var tileWidth: CGFloat = 104
    @State private var forumToRemove: Forum?
    @State private var showingPinnedEditor = false
    @State private var addingSuggested: Set<String> = []

    init(app: AppModel, onAddForum: @escaping () -> Void) {
        self.app = app
        self.browser = app.browser
        self.onAddForum = onAddForum
    }

    private var isNewUser: Bool { app.forums.isEmpty }

    var body: some View {
        List {
            header
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: DCTheme.spacingS, leading: 4, bottom: 0, trailing: 4))

            if browser.isForumsHomeRequested, browser.currentURL != nil {
                backToPage
            }

            if isNewUser {
                welcome
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
            } else {
                pinnedSection
                recentSection
            }

            suggestedSection
            addSection
            tipSection
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(.compact)
        .contentMargins(.top, DCTheme.spacingXS, for: .scrollContent)
        .scrollContentBackground(.hidden)
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity)
        .background(DCTheme.pageBackground)
        .animation(DCMotion.respecting(reduceMotion, DCMotion.smooth), value: app.forums)
        .sheet(isPresented: $showingPinnedEditor) {
            PinnedForumsEditor(app: app)
        }
        .accessibilityIdentifier("forumsHome")
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: DCTheme.spacingM) {
            Image(systemName: "sparkles")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(DCTheme.brandGradient, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text("Forumind")
                    .font(.title2.weight(.bold))
                    .fontDesign(.rounded)
                    .foregroundStyle(DCTheme.brandInk)
                Text(isNewUser ? "Your AI companion for Discourse forums" : "Forums")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            if !isNewUser {
                Button(action: onAddForum) {
                    Image(systemName: "plus")
                        .font(.body.weight(.semibold))
                        .frame(width: 36, height: 36)
                        .background(Color.accentColor.opacity(0.12), in: Circle())
                }
                .buttonStyle(.plain)
                .hoverEffect(.highlight)
                .foregroundStyle(Color.accentColor)
                .accessibilityLabel("Add forum")
                .accessibilityIdentifier("forumsHomeAdd")
            }
        }
        .padding(.bottom, DCTheme.spacingXS)
    }

    private var backToPage: some View {
        Section {
            Button {
                withAnimation(DCMotion.respecting(reduceMotion)) { browser.hideForumsHome() }
            } label: {
                HStack(spacing: DCTheme.spacingM) {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 36)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Back to page")
                            .font(.body.weight(.medium))
                            .foregroundStyle(.primary)
                        Text(browser.pageTitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
            }
            .tint(.primary)
            .accessibilityIdentifier("forumsHomeBackToPage")
        }
    }

    // MARK: New user

    private var welcome: some View {
        VStack(alignment: .leading, spacing: DCTheme.spacingM) {
            HStack(spacing: DCTheme.spacingS) {
                capability("doc.text.magnifyingglass", "Summaries", DCTheme.summaryTint)
                capability("bubble.left.and.bubble.right", "Chat", DCTheme.chatTint)
                capability("sparkle.magnifyingglass", "Ask the forum", DCTheme.agentTint)
            }
            Text("Start with a forum")
                .font(.title3.weight(.semibold))
            Text("Open any Discourse community to summarize long topics, chat about them, or ask the whole forum a question.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: onAddForum) {
                Label("Add a Forum", systemImage: "plus")
            }
            .buttonStyle(DCPrimaryButtonStyle())
            .accessibilityIdentifier("forumsHomeAddFirst")
            .padding(.top, DCTheme.spacingXS)
        }
        .dcCard(tint: DCTheme.brandBlue)
        .padding(.vertical, DCTheme.spacingS)
    }

    private func capability(_ systemImage: String, _ title: String, _ tint: Color) -> some View {
        Label(title, systemImage: systemImage)
            .font(.caption.weight(.semibold))
            .labelStyle(CapabilityLabelStyle(tint: tint))
            .frame(maxWidth: .infinity)
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
        } header: {
            HStack {
                Text("Pinned")
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
                }
            } header: {
                Text("Recent")
            }
            .headerProminence(.increased)
        }
    }

    private func visitedText(_ forum: Forum) -> String {
        guard let visited = forum.lastVisitedAt else { return forum.host }
        if Date().timeIntervalSince(visited) < 60 { return "\(forum.host) · just now" }
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
                Text(isNewUser ? "Popular forums" : "Suggested")
            } footer: {
                if isNewUser {
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
                Image(systemName: "pin")
                    .font(.subheadline.weight(.semibold))
                    .frame(width: 34, height: 34)
                    .background(Color.accentColor.opacity(0.12), in: Circle())
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

    // MARK: Add + tip

    private var addSection: some View {
        Section {
            Button(action: onAddForum) {
                Label {
                    Text("Add a forum by address…")
                } icon: {
                    Image(systemName: "plus.circle.fill")
                        .foregroundStyle(Color.accentColor)
                }
            }
            .accessibilityIdentifier("forumsHomeAddByAddress")
        }
    }

    private var tipSection: some View {
        Section {
            HStack(alignment: .top, spacing: DCTheme.spacingM) {
                Image(systemName: "square.and.arrow.up")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(DCTheme.brandPurple)
                    .frame(width: 28)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Share from Safari or Chrome")
                        .font(.subheadline.weight(.semibold))
                    Text("Share any forum page to Forumind to open it here, summarize it, or ask about it.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, DCTheme.spacingXS)
            .accessibilityElement(children: .combine)
        }
        .listRowBackground(DCTheme.brandPurple.opacity(0.08))
    }

    private func open(_ forum: Forum) {
        DCHaptics.tap()
        app.openForum(forum)
    }
}

private struct CapabilityLabelStyle: LabelStyle {
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        VStack(spacing: 6) {
            configuration.icon
                .font(.title3)
                .foregroundStyle(tint)
                .frame(width: 44, height: 44)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            configuration.title
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
        }
    }
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
