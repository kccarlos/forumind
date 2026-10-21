import SwiftUI

// MARK: - Forums home entry

/// The Today row at the top of the Forums home: what today's digest is
/// doing, and a tap opens the Today page.
struct TodayEntry: View {
    @ObservedObject var app: AppModel

    var body: some View {
        Section {
            Button {
                DCHaptics.tap()
                app.showsTodayPage = true
            } label: {
                HStack(spacing: DCTheme.spacingM) {
                    DigestIcon(size: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Today")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text(status)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 0)
                    if app.digestActivity.isRunning {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Color(uiColor: .tertiaryLabel))
                    }
                }
                .contentShape(Rectangle())
            }
            .tint(.primary)
            .accessibilityElement(children: .combine)
            .accessibilityHint("Opens today’s digest")
            .accessibilityIdentifier("todayEntry")
        }
    }

    private var status: String {
        guard let today = app.todaysDigest else {
            if app.digestActivity == .preparing {
                return String(localized: "Checking your forums…", comment: "Daily digest: reading the forums' topic lists before summarizing")
            }
            return app.settings.dailyDigestEnabled
                ? String(localized: "Your digest of watched and trending topics", comment: "Forums home Today row before today's digest is made, with the daily digest on")
                : String(localized: "Make a digest of today’s topics", comment: "Forums home Today row when the daily digest is off")
        }
        if !today.isComplete {
            return String(localized: "\(today.finishedCount) of \(today.cards.count) ready", comment: "Daily digest progress: cards summarized so far, then the number of cards")
        }
        return today.cards.isEmpty
            ? String(localized: "Nothing new today", comment: "Daily digest with no topics")
            : String(localized: "\(today.cards.count) topics")
    }
}

/// The digest's glyph: a sun in a warm rounded square.
struct DigestIcon: View {
    var size: CGFloat = 36

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            .fill(DigestStyle.tint.gradient)
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: "sun.max.fill")
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .accessibilityHidden(true)
    }
}

enum DigestStyle {
    static let tint = Color(light: 0xD9730D, dark: 0xFFA94D)
}

// MARK: - Today page

/// Today's digest: one card per topic, filled in one by one as the
/// summaries finish, plus the earlier digests kept on this device. Shown as
/// a sheet over the browser, so it works the same on iPhone and iPad.
struct TodayPage: View {
    @ObservedObject var app: AppModel
    /// Opens a topic or post in the browser (the page closes).
    let onOpen: (URL, DigestCard) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showsSettings = false

    var body: some View {
        NavigationStack {
            List {
                header
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: DCTheme.spacingS, leading: 4, bottom: 0, trailing: 4))
                if let today = app.todaysDigest {
                    if today.cards.contains(where: { $0.state == .done }) {
                        PodcastTodaySection(app: app, podcast: app.podcast, digest: today, onOpen: onOpen)
                    }
                    todaySections(today)
                } else {
                    startSection
                }
                earlierSection
            }
            .listStyle(.insetGrouped)
            .listSectionSpacing(.compact)
            .scrollContentBackground(.hidden)
            .background(DCTheme.pageBackground)
            .animation(DCMotion.respecting(reduceMotion, DCMotion.smooth), value: app.todaysDigest)
            .navigationTitle("Today")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(isPresented: $showsSettings) {
                SettingsDigestPage(app: app)
                    .navigationTitle(SettingsPage.digest.title)
                    .navigationBarTitleDisplayMode(.inline)
            }
            .navigationDestination(for: UUID.self) { id in
                if let digest = app.digests.first(where: { $0.id == id }) {
                    DigestHistoryPage(app: app, digest: digest, onOpen: onOpen)
                }
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                        .keyboardShortcut(.cancelAction)
                        .accessibilityIdentifier("todayDone")
                }
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        if app.todaysDigest?.isComplete == true, app.isProviderReady(for: .assistant) {
                            Button {
                                app.makeTodaysDigest(replacing: true)
                            } label: {
                                Label("Make Again", systemImage: "arrow.clockwise")
                            }
                        }
                        if app.podcast.episode?.digestID == app.todaysDigest?.id, app.podcast.episode != nil,
                           !app.podcast.activity.isRunning, app.podcast.canMake {
                            Button {
                                app.podcast.remake()
                            } label: {
                                Label("Make Podcast Again", systemImage: "waveform")
                            }
                        }
                        Button {
                            showsSettings = true
                        } label: {
                            Label("Digest Settings", systemImage: "gearshape")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("More")
                    .accessibilityIdentifier("todayMenu")
                }
            }
        }
        .modifier(PodcastConsentPresenter(podcast: app.podcast))
        .dcFormSheet()
        .task {
            app.resumeDigestIfNeeded()
            app.podcast.resumeIfNeeded()
        }
        .accessibilityIdentifier("todayPage")
    }

    private var header: some View {
        HStack(spacing: DCTheme.spacingM) {
            DigestIcon(size: 40)
            VStack(alignment: .leading, spacing: 0) {
                Text(Date().formatted(.dateTime.weekday(.wide).month(.wide).day()))
                    .font(.title3.weight(.bold))
                    .fontDesign(.rounded)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
        }
    }

    private var subtitle: String {
        guard let today = app.todaysDigest, !today.cards.isEmpty else {
            return String(localized: "Watched topics and today’s top topics", comment: "Today page subtitle: what the daily digest contains")
        }
        if today.isComplete { return String(localized: "\(today.cards.count) topics") }
        return String(localized: "\(today.finishedCount) of \(today.cards.count) ready", comment: "Daily digest progress: cards summarized so far, then the number of cards")
    }

    // MARK: Today

    @ViewBuilder
    private func todaySections(_ today: DailyDigest) -> some View {
        if !today.isComplete {
            if app.digestActivity == .unreachable {
                noticeSection(
                    symbol: "wifi.exclamationmark",
                    title: "Can’t reach your forums",
                    message: "The digest continues from here when you’re back online.",
                    action: ("Try again", { app.resumeDigestIfNeeded() })
                )
            } else if !app.isProviderReady(for: .assistant) {
                providerSection
            }
        }
        if today.cards.isEmpty {
            noticeSection(
                symbol: "checkmark.circle",
                title: "Nothing new today",
                message: "No watched topic has new replies, and your pinned forums have no top topics yet. Watch topics or pin forums to fill the digest.",
                action: nil
            )
        } else {
            Section {
                ForEach(today.cards) { card in
                    DigestCardView(
                        app: app,
                        card: card,
                        onOpen: { url in onOpen(url, card) },
                        onRetry: { app.retryDigestCard(card) }
                    )
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: DCTheme.spacingXS, leading: 0, bottom: DCTheme.spacingXS, trailing: 0))
                }
            }
        }
    }

    // MARK: Before today's digest

    @ViewBuilder
    private var startSection: some View {
        switch app.digestActivity {
        case .preparing:
            Section {
                HStack(spacing: DCTheme.spacingM) {
                    ProgressView()
                    Text("Checking your forums…", comment: "Daily digest: reading the forums' topic lists before summarizing")
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, DCTheme.spacingXS)
                .accessibilityIdentifier("digestPreparing")
            }
        case .unreachable:
            noticeSection(
                symbol: "wifi.exclamationmark",
                title: "Can’t reach your forums",
                message: "Check your connection and try again.",
                action: ("Try again", { app.makeTodaysDigest() })
            )
        case .idle, .summarizing:
            if app.isProviderReady(for: .assistant) {
                makeSection
            } else {
                providerSection
            }
        }
    }

    private var makeSection: some View {
        Section {
            VStack(alignment: .leading, spacing: DCTheme.spacingM) {
                Text("Your day on the forums")
                    .font(.headline)
                Text("One card per topic: watched topics with new replies, then today’s top topics on your pinned forums, each with a short summary and links to the posts that matter.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    DCHaptics.tap()
                    app.makeTodaysDigest()
                } label: {
                    Label("Make Today’s Digest", systemImage: "sun.max")
                }
                .buttonStyle(DCPrimaryButtonStyle())
                .accessibilityIdentifier("makeDigest")
                Text("Each card is one request to your AI provider (\(app.providerSummary(for: .assistant))).", comment: "Today page: what making the digest costs; the placeholder is the provider and model")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !app.settings.dailyDigestEnabled {
                    Button {
                        showsSettings = true
                    } label: {
                        Text("Want it every day? Turn on the daily digest")
                            .font(.footnote.weight(.semibold))
                    }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("digestTurnOn")
                }
            }
            .padding(.vertical, DCTheme.spacingXS)
        }
    }

    private var providerSection: some View {
        noticeSection(
            symbol: "cpu",
            title: "Connect an AI provider",
            message: "The digest’s summaries use your AI provider or Apple Intelligence.",
            action: ("Set up", {
                dismiss()
                Task { @MainActor in
                    // After the page has gone: the setup sheet belongs to the root view.
                    try? await Task.sleep(for: .milliseconds(600))
                    app.needsProviderSetup = .assistant
                }
            })
        )
    }

    private func noticeSection(
        symbol: String,
        title: LocalizedStringKey,
        message: LocalizedStringKey,
        action: (LocalizedStringKey, () -> Void)?
    ) -> some View {
        Section {
            VStack(alignment: .leading, spacing: DCTheme.spacingS) {
                Label(title, systemImage: symbol)
                    .font(.headline)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let action {
                    Button(action.0, action: action.1)
                        .buttonStyle(DCActionButtonStyle(prominent: false))
                        .padding(.top, DCTheme.spacingXS)
                }
            }
            .padding(.vertical, DCTheme.spacingXS)
        }
    }

    // MARK: Earlier

    @ViewBuilder
    private var earlierSection: some View {
        let earlier = app.earlierDigests
        if !earlier.isEmpty {
            Section {
                ForEach(earlier) { digest in
                    NavigationLink(value: digest.id) {
                        DigestHistoryRow(digest: digest)
                    }
                    .swipeActions {
                        Button(role: .destructive) {
                            withAnimation { app.deleteDigest(id: digest.id) }
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                    .contextMenu {
                        Button(role: .destructive) {
                            withAnimation { app.deleteDigest(id: digest.id) }
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            } header: {
                Text("Earlier")
            } footer: {
                Text("The last 7 digests stay on this device. Swipe left to delete one.")
            }
            .headerProminence(.increased)
        }
    }
}

private struct DigestHistoryRow: View {
    let digest: DailyDigest

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(digest.createdAt.formatted(.dateTime.weekday(.wide).month(.wide).day()))
            Text(digest.cards.isEmpty
                 ? String(localized: "Nothing new today", comment: "Daily digest with no topics")
                 : String(localized: "\(digest.cards.count) topics"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// An earlier digest, read only.
private struct DigestHistoryPage: View {
    @ObservedObject var app: AppModel
    let digest: DailyDigest
    let onOpen: (URL, DigestCard) -> Void

    var body: some View {
        List {
            ForEach(digest.cards) { card in
                DigestCardView(app: app, card: card, onOpen: { url in onOpen(url, card) }, onRetry: nil)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: DCTheme.spacingXS, leading: 0, bottom: DCTheme.spacingXS, trailing: 0))
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(DCTheme.pageBackground)
        .navigationTitle(digest.createdAt.formatted(.dateTime.month(.abbreviated).day()))
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Card

/// One topic of a digest: its forum, why it's here, the title (opens the
/// topic), the summary or its progress, and post-level links.
struct DigestCardView: View {
    @ObservedObject var app: AppModel
    let card: DigestCard
    let onOpen: (URL) -> Void
    /// nil for earlier digests (read only).
    let onRetry: (() -> Void)?

    private var forum: Forum { app.forumInfo(siteURL: card.siteURL) }

    var body: some View {
        VStack(alignment: .leading, spacing: DCTheme.spacingS) {
            HStack(spacing: DCTheme.spacingS) {
                AssistantForumIcon(forum: forum, size: 20)
                Text(forum.displayName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: DCTheme.spacingS)
                if card.state == .done, !card.summary.isEmpty {
                    ReadAloudButton(podcast: app.podcast, id: "card-\(card.topicKey)", title: card.title,
                                    text: "\(card.title).\n\(card.summary)", compact: true)
                        .font(.subheadline)
                        .buttonStyle(.borderless)
                }
                reasonPill
            }
            Button { onOpen(card.url) } label: {
                Text(card.title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.borderless)
            .accessibilityHint("Opens the topic")
            .accessibilityIdentifier("digestTitle-\(card.topicID)")

            content

            if !links.isEmpty {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: DCTheme.spacingS) { linkButtons }
                    VStack(alignment: .leading, spacing: DCTheme.spacingS) { linkButtons }
                }
            }
        }
        .dcCard()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("digestCard-\(card.topicID)")
    }

    private var reasonPill: some View {
        switch card.reason {
        case .newReplies(let count):
            DCPill(text: String(localized: "\(count) new replies", comment: "Digest card: why a watched topic is in the digest"),
                   systemImage: "bell.badge", tint: DCTheme.brandBlue)
        case .trending:
            DCPill(text: String(localized: "Trending", comment: "Digest card: the topic is among today's top topics of a pinned forum"),
                   systemImage: "flame", tint: DigestStyle.tint)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch card.state {
        case .done:
            Text(card.summary)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .transition(.opacity)
        case .working:
            HStack(spacing: DCTheme.spacingS) {
                ProgressView().controlSize(.small)
                Text("Summarizing…", comment: "Digest card: its summary is being written")
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
        case .pending:
            Label {
                Text("Waiting to be summarized", comment: "Digest card: queued behind other cards")
            } icon: {
                Image(systemName: "clock")
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        case .failed:
            VStack(alignment: .leading, spacing: DCTheme.spacingXS) {
                Label(card.error.isEmpty ? String(localized: "The summary failed.", comment: "Digest card error without details") : card.error,
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline)
                    .foregroundStyle(DCTheme.danger)
                if let onRetry {
                    Button("Try again", action: onRetry)
                        .font(.subheadline.weight(.semibold))
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier("digestRetry-\(card.topicID)")
                }
            }
        }
    }

    private struct Link: Identifiable {
        var id: String
        var title: String
        var systemImage: String
        var url: URL
    }

    private var links: [Link] {
        var result: [Link] = []
        if let first = card.firstNewPost, card.newReplies > 0 {
            result.append(Link(id: "first", title: String(localized: "First new reply", comment: "Digest card link: opens the topic at the first reply since the last digest"),
                               systemImage: "arrow.down.to.line", url: card.url(atPost: first)))
        }
        if let answer = card.acceptedAnswerPost {
            result.append(Link(id: "solution", title: String(localized: "Accepted answer", comment: "Digest card link: opens the topic at its accepted (solution) post"),
                               systemImage: "checkmark.seal", url: card.url(atPost: answer)))
        }
        if let top = card.topPost {
            result.append(Link(id: "top", title: String(localized: "Top post", comment: "Digest card link: opens the topic at its most liked reply"),
                               systemImage: "heart", url: card.url(atPost: top)))
        } else if let url = card.topPostsURL {
            result.append(Link(id: "top", title: String(localized: "Top posts", comment: "Digest card link: opens the topic's most liked posts (Discourse's summary view)"),
                               systemImage: "heart", url: url))
        }
        return result
    }

    private var linkButtons: some View {
        ForEach(links) { link in
            Button { onOpen(link.url) } label: {
                Label(link.title, systemImage: link.systemImage)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.accentColor.opacity(0.1), in: Capsule())
            }
            .buttonStyle(.borderless)
            .hoverEffect(.highlight)
            .accessibilityIdentifier("digestLink-\(link.id)-\(card.topicID)")
        }
    }
}

// MARK: - Settings

/// Settings › Daily digest.
struct SettingsDigestPage: View {
    @ObservedObject var app: AppModel
    @State private var confirmingDelete = false

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $app.settings.dailyDigestEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Make a digest every day")
                        Text("Summaries are made when you open Forumind, with your AI provider: about one request per card.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .tint(DCTheme.brandBlue)
                .accessibilityIdentifier("digestEnabled")
            } header: {
                Text("Daily digest")
            } footer: {
                Text("While it’s on, Forumind reads your forums’ topic lists in the background when the device is charging and online, without using AI. Off, you can still make one from the Today page on the Forums home.")
            }

            Section {
                Toggle("Watched topics with new replies", isOn: $app.settings.dailyDigestIncludesWatched)
                    .tint(DCTheme.brandBlue)
                    .accessibilityIdentifier("digestIncludesWatched")
                Toggle("Today’s top topics on pinned forums", isOn: $app.settings.dailyDigestIncludesTrending)
                    .tint(DCTheme.brandBlue)
                    .accessibilityIdentifier("digestIncludesTrending")
                Stepper(value: $app.settings.dailyDigestMaxCards, in: DigestLimits.cardRange) {
                    Text("Up to \(app.settings.dailyDigestMaxCards) topics", comment: "Daily digest settings: the maximum number of cards")
                }
                .accessibilityIdentifier("digestMaxCards")
            } header: {
                Text("In the digest")
            } footer: {
                Text("Watched topics come first.")
            }

            Section {
                Toggle(isOn: $app.settings.dailyDigestNotifies) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Notify when it’s ready to make")
                        Text("After the background check finds topics. Tap it to make the digest.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .tint(DCTheme.brandBlue)
                .disabled(!app.settings.dailyDigestEnabled)
                .accessibilityIdentifier("digestNotifies")
            }

            SettingsPodcastSections(app: app, podcast: app.podcast)

            Section {
                Button(role: .destructive) {
                    confirmingDelete = true
                } label: {
                    Text("Delete All Digests")
                }
                .disabled(app.digests.isEmpty)
                .confirmationDialog("Delete all digests?", isPresented: $confirmingDelete, titleVisibility: .visible) {
                    Button("Delete All Digests", role: .destructive) { app.deleteAllDigests() }
                }
            } header: {
                Text("History")
            } footer: {
                Text("The last 7 digests and their podcasts are kept on this device only; they aren’t synced with iCloud.")
            }
        }
        .formStyle(.grouped)
        .onChange(of: app.settings.dailyDigestEnabled) { app.saveSettings() }
        .onChange(of: app.settings.dailyDigestIncludesWatched) { app.saveSettings() }
        .onChange(of: app.settings.dailyDigestIncludesTrending) { app.saveSettings() }
        .onChange(of: app.settings.dailyDigestMaxCards) { app.saveSettings() }
        .onChange(of: app.settings.dailyDigestNotifies) { app.saveSettings() }
        .onChange(of: app.settings.podcastDailyEnabled) { app.saveSettings() }
        .onChange(of: app.settings.podcast) { app.saveSettings() }
    }
}
