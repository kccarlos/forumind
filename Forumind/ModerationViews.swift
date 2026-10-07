import MessageUI
import SwiftUI

// Views for moderation (see Moderation.swift): the Terms of Use agreement,
// the report-or-block sheet, and the Settings sections.

// MARK: Terms of Use

/// The community rules and the agreement toggle (walkthrough privacy step
/// and the terms sheet shown to existing users).
struct TermsAgreementCard: View {
    @Binding var agreed: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: DCTheme.spacingL) {
            TermsPoints()
            Link(destination: ModerationTerms.url) {
                Label("Read the full Terms of Use", systemImage: "doc.text")
                    .font(.subheadline.weight(.semibold))
            }
            .accessibilityIdentifier("termsLink")
            Toggle(isOn: $agreed) {
                Text("I agree to the Terms of Use", comment: "Toggle the user must turn on before using the app")
                    .font(.body.weight(.semibold))
            }
            .tint(DCTheme.brandBlue)
            .accessibilityIdentifier("termsAgree")
        }
        .dcCard()
    }
}

/// The rules in short.
struct TermsPoints: View {
    var body: some View {
        OnboardingFeatureRow(
            symbol: "hand.raised.slash.fill",
            tint: DCTheme.warning,
            title: String(localized: "No tolerance for abuse", comment: "Terms of Use summary row title"),
            detail: String(localized: "Forums are run by their own communities. Objectionable content and abusive users are not tolerated, whether you read or post through Forumind.", comment: "Terms of Use summary row")
        )
        OnboardingFeatureRow(
            symbol: "flag.fill",
            tint: DCTheme.brandPurple,
            title: String(localized: "Report and block", comment: "Terms of Use summary row title"),
            detail: String(localized: "On any topic, open ⋯ › Report or block to report a post or user, or to hide everything a user posts. Reports are reviewed within 24 hours and offending content is removed from the app.", comment: "Terms of Use summary row; ⋯ is the browser's More menu")
        )
        OnboardingFeatureRow(
            symbol: "line.3.horizontal.decrease.circle.fill",
            tint: DCTheme.brandBlue,
            title: String(localized: "Filter what you see", comment: "Terms of Use summary row title"),
            detail: String(localized: "Hide posts that contain words you don’t want to see in Settings › Data & privacy.", comment: "Terms of Use summary row")
        )
    }
}

/// Shown once to anyone who hasn't accepted the current terms (existing
/// users after an update, or a walkthrough that was dismissed early).
struct TermsGateView: View {
    @ObservedObject var app: AppModel
    @State private var agreed = false

    var body: some View {
        NavigationStack {
            OnboardingPage {
                OnboardingHeader(
                    eyebrow: String(localized: "Terms of Use"),
                    title: String(localized: "Before you continue"),
                    subtitle: String(localized: "Please read and accept the Terms of Use. They explain what isn’t allowed and how to report and block content.")
                )
                TermsAgreementCard(agreed: $agreed)
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    DCHaptics.tap()
                    // Accepting closes the sheet (it is shown while needed).
                    app.acceptTerms()
                } label: {
                    Text("Continue")
                }
                .buttonStyle(DCPrimaryButtonStyle())
                .disabled(!agreed)
                .padding(.horizontal, DCTheme.spacingXL)
                .padding(.vertical, DCTheme.spacingM)
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
                .background(.bar)
                .accessibilityIdentifier("termsContinue")
            }
        }
        .interactiveDismissDisabled()
    }
}

// MARK: Report or block

/// Report the topic, a post on screen, or a user; or block a user. Reports
/// go to the developer by email; blocking hides the user at once and offers
/// the same email so the developer hears about it too.
struct ReportSheet: View {
    @ObservedObject var app: AppModel
    let topic: ForumTopic
    let forumName: String
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var posts: [VisiblePost] = []
    @State private var loaded = false
    @State private var composing: ReportTarget?
    @State private var blockingTarget: VisiblePost?
    @State private var mail: MailDraft?
    /// No mail account on this device: show the report to copy or share.
    @State private var fallback: MailDraft?
    @State private var status: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        composing = target(.topic)
                    } label: {
                        Label("Report this topic", systemImage: "flag")
                    }
                    .accessibilityIdentifier("reportTopic")
                } header: {
                    Text(topic.title)
                } footer: {
                    Text("Reports go to the Forumind developer by email and are reviewed within 24 hours. Offending content is removed from the app for everyone.")
                }

                Section {
                    if !loaded {
                        ProgressView()
                    } else if posts.isEmpty {
                        Text("No posts are on screen. Scroll to a post, then open this again.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(posts) { post in
                            postRow(post)
                        }
                    }
                } header: {
                    Text("Posts on screen")
                }

                if let status {
                    Section { Text(status).foregroundStyle(.secondary) }
                }
            }
            .navigationTitle("Report or block")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                posts = await app.browser.visiblePosts()
                loaded = true
            }
            .sheet(item: $composing) { target in
                ReportForm(target: target) { reason, note in
                    composing = nil
                    send(target: target, reason: reason, note: note, blocked: false)
                }
            }
            .confirmationDialog(
                blockingTarget.map { String(localized: "Block @\($0.username)?", comment: "Confirmation title; the placeholder is a forum username") } ?? "",
                isPresented: Binding(get: { blockingTarget != nil }, set: { if !$0 { blockingTarget = nil } }),
                titleVisibility: .visible,
                presenting: blockingTarget
            ) { post in
                Button("Block", role: .destructive) { block(post) }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("Their posts on \(forumName) are hidden right away and left out of summaries, chat, and Ask the forum. You can unblock them in Settings › Data & privacy. The developer is told about the block so the content can be reviewed.")
            }
            .sheet(item: $mail) { draft in
                MailComposer(draft: draft) { mail = nil }
                    .ignoresSafeArea()
            }
            .sheet(item: $fallback) { draft in
                ReportEmailFallback(draft: draft)
            }
        }
    }

    private func postRow(_ post: VisiblePost) -> some View {
        let blocked = app.isBlocked(post.username, on: topic.siteURL)
        return VStack(alignment: .leading, spacing: DCTheme.spacingXS) {
            Text("@\(post.username) · #\(post.number)", comment: "Report sheet row: username and post number")
                .font(.subheadline.weight(.semibold))
            if !post.excerpt.isEmpty {
                Text(post.excerpt)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            HStack(spacing: DCTheme.spacingM) {
                Button {
                    composing = target(.post(number: post.number, username: post.username))
                } label: {
                    Label("Report post", systemImage: "flag")
                }
                .accessibilityIdentifier("reportPost\(post.number)")
                Button(role: .destructive) {
                    blockingTarget = post
                } label: {
                    Label(blocked ? "Blocked" : "Block user", systemImage: "hand.raised")
                }
                .disabled(blocked)
                .accessibilityIdentifier("blockUser\(post.number)")
            }
            .buttonStyle(.borderless)
            .font(.subheadline)
            .padding(.top, DCTheme.spacingXS)
        }
        .padding(.vertical, DCTheme.spacingXS)
    }

    private func target(_ kind: ReportTarget.Kind) -> ReportTarget {
        ReportTarget(
            siteURL: topic.siteURL,
            forumName: forumName,
            topicTitle: topic.title,
            topicURL: topic.url,
            kind: kind
        )
    }

    private func block(_ post: VisiblePost) {
        app.block(post.username, on: topic.siteURL)
        posts.removeAll { $0.username.caseInsensitiveCompare(post.username) == .orderedSame }
        status = String(localized: "@\(post.username) is blocked.", comment: "Report sheet status; the placeholder is a forum username")
        // Tell the developer, as App Review asks; the user sends the email.
        send(
            target: target(.post(number: post.number, username: post.username)),
            reason: nil,
            note: "",
            blocked: true
        )
    }

    private func send(target: ReportTarget, reason: ReportReason?, note: String, blocked: Bool) {
        let subject = ModerationReport.subject(for: target, blocked: blocked)
        let body = ModerationReport.body(for: target, reason: reason, note: note, blocked: blocked)
        let draft = MailDraft(subject: subject, body: body)
        if MFMailComposeViewController.canSendMail() {
            mail = draft
        } else {
            // Mail isn't set up (another mail app may be): show the report
            // with Copy, Share and an "Open in email app" link.
            fallback = draft
        }
        if !blocked {
            status = String(localized: "Thanks. Send the email to finish your report.", comment: "Report sheet status after a report email is prepared")
        }
    }
}

/// Reason and optional details for a report.
struct ReportForm: View {
    let target: ReportTarget
    let onSend: (ReportReason, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var reason: ReportReason = .spam
    @State private var note = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Reason", selection: $reason) {
                        ForEach(ReportReason.allCases) { reason in
                            Text(reason.title).tag(reason)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } header: {
                    Text("What’s wrong?")
                }
                Section {
                    TextField("Details (optional)", text: $note, axis: .vertical)
                        .lineLimit(3...8)
                } footer: {
                    Text("Next, your email app opens with the report filled in. Send it to finish.")
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Next") { onSend(reason, note) }
                        .accessibilityIdentifier("reportNext")
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var title: String {
        switch target.kind {
        case .topic: String(localized: "Report topic")
        case .post: String(localized: "Report post")
        case .user: String(localized: "Report user")
        }
    }
}

/// The report when Mail can't send it: the text to copy or share, and a
/// link that opens whichever email app handles mailto links.
struct ReportEmailFallback: View {
    let draft: MailDraft
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var copied = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("To", value: ModerationTerms.reportEmail)
                    LabeledContent("Subject", value: draft.subject)
                } footer: {
                    Text("Mail isn’t set up on this device. Send the report from any email app, or copy it.")
                }
                Section("Report") {
                    Text(draft.body)
                        .font(.footnote.monospaced())
                        .textSelection(.enabled)
                }
                Section {
                    if let url = ModerationReport.mailtoURL(subject: draft.subject, body: draft.body) {
                        Button {
                            openURL(url)
                        } label: {
                            Label("Open in email app", systemImage: "envelope")
                        }
                    }
                    Button {
                        UIPasteboard.general.string = "To: \(ModerationTerms.reportEmail)\nSubject: \(draft.subject)\n\n\(draft.body)"
                        copied = true
                        DCHaptics.success()
                    } label: {
                        Label(copied ? String(localized: "Copied") : String(localized: "Copy report"), systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    .accessibilityIdentifier("copyReport")
                    ShareLink(item: draft.body, subject: Text(draft.subject)) {
                        Label("Share report", systemImage: "square.and.arrow.up")
                    }
                }
            }
            .navigationTitle("Send report")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

struct MailDraft: Identifiable {
    let id = UUID()
    var subject: String
    var body: String
}

/// The system mail composer, addressed to the report email.
struct MailComposer: UIViewControllerRepresentable {
    let draft: MailDraft
    let onFinish: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let controller = MFMailComposeViewController()
        controller.mailComposeDelegate = context.coordinator
        controller.setToRecipients([ModerationTerms.reportEmail])
        controller.setSubject(draft.subject)
        controller.setMessageBody(draft.body, isHTML: false)
        return controller
    }

    func updateUIViewController(_ controller: MFMailComposeViewController, context: Context) {}

    final class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        let onFinish: () -> Void
        init(onFinish: @escaping () -> Void) { self.onFinish = onFinish }

        func mailComposeController(
            _ controller: MFMailComposeViewController,
            didFinishWith result: MFMailComposeResult,
            error: Error?
        ) {
            onFinish()
        }
    }
}

// MARK: Settings

/// Settings › Data & privacy: blocked users, filtered words, terms, report.
struct ModerationSettingsSections: View {
    @ObservedObject var app: AppModel
    @Environment(\.openURL) private var openURL
    @State private var newWord = ""

    var body: some View {
        Section {
            if app.settings.blockedUsers.isEmpty {
                Text("No one is blocked. To block someone, open a topic, then ⋯ › Report or block.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(app.settings.blockedUsers.sorted { $0.blockedAt > $1.blockedAt }) { user in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(verbatim: "@\(user.username)")
                            Text(name(for: user.siteURL))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Unblock") { app.unblock(user) }
                            .buttonStyle(.borderless)
                    }
                }
            }
        } header: {
            Text("Blocked users")
        } footer: {
            Text("Posts from blocked users are hidden in the browser and left out of summaries, chat, and Ask the forum.")
        }

        Section {
            ForEach(app.settings.filteredWords, id: \.self) { word in
                Text(word)
            }
            .onDelete { app.removeFilteredWords(atOffsets: $0) }
            HStack {
                TextField("Add a word or phrase", text: $newWord)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .onSubmit(addWord)
                    .accessibilityIdentifier("filteredWordField")
                Button("Add", action: addWord)
                    .disabled(newWord.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        } header: {
            Text("Filtered words")
        } footer: {
            Text("Posts that contain any of these are hidden on every forum. Swipe to remove one.")
        }

        Section {
            Link(destination: ModerationTerms.url) {
                Label("Terms of Use", systemImage: "doc.text")
            }
            Button {
                let subject = "Forumind report"
                let body = "Forum, topic or post link:\n\nWhat's wrong:\n\nApp version: \(AppVersion.text())"
                if let url = ModerationReport.mailtoURL(subject: subject, body: body) { openURL(url) }
            } label: {
                Label("Report a problem by email", systemImage: "envelope")
            }
        } footer: {
            Text("Reports are reviewed within 24 hours.")
        }
    }

    private func addWord() {
        if app.addFilteredWord(newWord) { newWord = "" }
    }

    private func name(for siteURL: String) -> String {
        app.forum(for: siteURL)?.displayName ?? ForumSite.host(of: siteURL)
    }
}
