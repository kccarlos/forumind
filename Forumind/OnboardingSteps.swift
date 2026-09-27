import SwiftUI

// The eight walkthrough pages. Each page scrolls on its own so large text and
// landscape phones never clip.

/// Scrolling, width-limited column shared by the pages.
struct OnboardingPage<Content: View>: View {
    var alignment: HorizontalAlignment = .leading
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: alignment, spacing: DCTheme.spacingXL) {
                content()
            }
            .padding(.horizontal, DCTheme.spacingXL)
            .padding(.top, DCTheme.spacingM)
            .padding(.bottom, DCTheme.spacingXL)
            .frame(maxWidth: 540, alignment: Alignment(horizontal: alignment, vertical: .top))
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .scrollBounceBehavior(.basedOnSize)
        #if DEBUG
        // `-dc-scroll-bottom`: start scrolled to the end (QA screenshots).
        .defaultScrollAnchor(OnboardingDebug.arguments.contains("-dc-scroll-bottom") ? .bottom : nil)
        #endif
    }
}

/// Large title + subtitle at the top of a page.
struct OnboardingHeader: View {
    var eyebrow: String?
    let title: String
    var subtitle: String?
    var alignment: HorizontalAlignment = .leading
    var titleFont: Font = .title.weight(.bold)

    var body: some View {
        VStack(alignment: alignment, spacing: DCTheme.spacingS) {
            if let eyebrow {
                Text(eyebrow.uppercased())
                    .font(.caption.weight(.bold))
                    .tracking(0.8)
                    .foregroundStyle(DCTheme.brandBlue)
            }
            Text(title)
                .font(titleFont)
                .foregroundStyle(DCTheme.brandInk)
                .fixedSize(horizontal: false, vertical: true)
            if let subtitle {
                Text(subtitle)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .multilineTextAlignment(alignment == .center ? .center : .leading)
        .frame(maxWidth: .infinity, alignment: Alignment(horizontal: alignment, vertical: .center))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// Tinted rounded icon tile.
struct OnboardingIconTile: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 44
    var filled = false

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(filled ? AnyShapeStyle(tint.gradient) : AnyShapeStyle(tint.opacity(0.14)))
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.44, weight: .semibold))
                    .foregroundStyle(filled ? Color.white : tint)
            }
            .accessibilityHidden(true)
    }
}

/// Icon + title + detail row (features, privacy).
struct OnboardingFeatureRow: View {
    let symbol: String
    let tint: Color
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: DCTheme.spacingM) {
            OnboardingIconTile(symbol: symbol, tint: tint)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: 1. Welcome

struct OnboardingWelcomePage: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    var body: some View {
        OnboardingPage(alignment: .center) {
            Spacer(minLength: DCTheme.spacingL)
            hero
                .scaleEffect(appeared || reduceMotion ? 1 : 0.86)
                .opacity(appeared ? 1 : 0)
            OnboardingHeader(
                eyebrow: "Welcome to Forumind",
                title: "Catch up on any Discourse forum in seconds",
                subtitle: "Browse your forums, get clear summaries of long topics, and ask questions with answers that cite their sources.",
                alignment: .center
            )
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared || reduceMotion ? 0 : 12)
            HStack(spacing: DCTheme.spacingS) {
                DCPill(text: "Summaries", systemImage: "sparkles", tint: DCTheme.summaryTint)
                DCPill(text: "Chat", systemImage: "bubble.left.and.bubble.right.fill", tint: DCTheme.chatTint)
                DCPill(text: "Ask the forum", systemImage: "text.magnifyingglass", tint: DCTheme.agentTint)
            }
            .opacity(appeared ? 1 : 0)
        }
        .onAppear {
            withAnimation(reduceMotion ? .easeOut(duration: 0.2) : DCMotion.spring.delay(0.05)) {
                appeared = true
            }
        }
    }

    private var hero: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 44, style: .continuous)
                .fill(DCTheme.brandGradient)
                .frame(width: 164, height: 164)
                .shadow(color: Color(hex: 0x4A6BFF, opacity: 0.35), radius: 24, y: 12)
            Image(systemName: "bubble.left.and.text.bubble.right.fill")
                .font(.system(size: 70, weight: .semibold))
                .foregroundStyle(.white)
                .offset(y: 4)
            Image(systemName: "sparkles")
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(.white.opacity(0.95))
                .offset(x: 52, y: -52)
        }
        .padding(.vertical, DCTheme.spacingS)
        .accessibilityHidden(true)
    }
}

// MARK: 2. What it does

struct OnboardingFeaturesPage: View {
    var body: some View {
        OnboardingPage {
            OnboardingHeader(
                eyebrow: "What it does",
                title: "Three ways to get to the point",
                subtitle: "Open any topic and the assistant is one tap away."
            )
            VStack(spacing: DCTheme.spacingM) {
                featureCard(
                    symbol: "sparkles",
                    tint: DCTheme.summaryTint,
                    title: "Summaries",
                    detail: "The original post, how people responded, and the key takeaways, even on topics with thousands of replies.",
                    example: "“Most replies agree the new version fixes it…”"
                )
                featureCard(
                    symbol: "bubble.left.and.bubble.right.fill",
                    tint: DCTheme.chatTint,
                    title: "Chat about a topic",
                    detail: "Ask follow-up questions about the page you’re reading. Answers stay grounded in the discussion.",
                    example: "“What workaround did people suggest?”"
                )
                featureCard(
                    symbol: "text.magnifyingglass",
                    tint: DCTheme.agentTint,
                    title: "Ask the forum",
                    detail: "Ask a question and it searches the forum, reads the best topics, and answers with cited sources like [S1].",
                    example: "“What’s the best way to self-host this?”"
                )
            }
        }
    }

    private func featureCard(symbol: String, tint: Color, title: String, detail: String, example: String) -> some View {
        VStack(alignment: .leading, spacing: DCTheme.spacingM) {
            HStack(spacing: DCTheme.spacingM) {
                OnboardingIconTile(symbol: symbol, tint: tint, size: 40, filled: true)
                Text(title).font(.headline)
                Spacer(minLength: 0)
            }
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(example)
                .font(.footnote.italic())
                .foregroundStyle(tint)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dcCard(tint: tint)
        .accessibilityElement(children: .combine)
    }
}

// MARK: 3. Connect an AI provider

struct OnboardingProviderPage: View {
    @ObservedObject var app: AppModel
    @Binding var state: ProviderTestState

    var body: some View {
        OnboardingPage {
            OnboardingHeader(
                eyebrow: OnboardingStep.provider.stepLabel,
                title: "Connect an AI provider",
                subtitle: app.appleIntelligenceStatus.isAvailable
                    ? "Apple Intelligence is built into this device: private, no account, no key. Or connect a provider you already use. You can change this any time in Settings."
                    : "Forumind doesn’t include its own AI. Connect one you use, or sign up for one. You can change this any time in Settings."
            )
            ProviderSetupForm(app: app, state: $state)
        }
    }
}

// MARK: 4. Choose your forums

struct OnboardingForumsPage: View {
    @ObservedObject var app: AppModel
    @Binding var selected: Set<String>
    @State private var address = ""
    @State private var adding = false
    @State private var addError: String?
    @State private var addedName: String?
    @FocusState private var addressFocused: Bool

    /// Suggested forums plus any forums the user already has or just added.
    private var rows: [(siteURL: String, name: String, detail: String, iconURL: URL?)] {
        var seen = Set<String>()
        var result: [(siteURL: String, name: String, detail: String, iconURL: URL?)] = []
        for forum in app.forums where seen.insert(forum.siteURL).inserted {
            let suggested = AppModel.suggestedForums.first { $0.siteURL == forum.siteURL }
            result.append((forum.siteURL, forum.displayName, suggested?.description ?? forum.host, forum.iconURL))
        }
        for suggested in AppModel.suggestedForums where seen.insert(suggested.siteURL).inserted {
            result.append((suggested.siteURL, suggested.name, suggested.description, nil))
        }
        return result
    }

    var body: some View {
        OnboardingPage {
            OnboardingHeader(
                eyebrow: OnboardingStep.forums.stepLabel,
                title: "Choose your forums",
                subtitle: "Pin the communities you read. Pinned forums stay at the top of your Forums screen. You can visit any other forum too."
            )
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.siteURL) { index, row in
                    if index > 0 { Divider().padding(.leading, 64) }
                    forumRow(row)
                }
            }
            .padding(.vertical, DCTheme.spacingXS)
            .dcCard()
            ScrollViewReader { proxy in
                addForumCard
                    .id("addForumCard")
                    .onChange(of: addressFocused) {
                        guard addressFocused else { return }
                        // Keep the field and its hint above the keyboard.
                        Task {
                            try? await Task.sleep(for: .milliseconds(350))
                            withAnimation(DCMotion.smooth) {
                                proxy.scrollTo("addForumCard", anchor: .bottom)
                            }
                        }
                    }
            }
        }
        #if DEBUG
        .task {
            if OnboardingDebug.arguments.contains("-dc-focus") {
                try? await Task.sleep(for: .milliseconds(600))
                addressFocused = true
            }
        }
        #endif
    }

    private func forumRow(_ row: (siteURL: String, name: String, detail: String, iconURL: URL?)) -> some View {
        let isOn = selected.contains(row.siteURL)
        return Button {
            DCHaptics.tap()
            withAnimation(DCMotion.quick) {
                if isOn { selected.remove(row.siteURL) } else { selected.insert(row.siteURL) }
            }
        } label: {
            HStack(spacing: DCTheme.spacingM) {
                OnboardingForumIcon(siteURL: row.siteURL, name: row.name, iconURL: row.iconURL, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.name)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(row.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: DCTheme.spacingS)
                HStack(spacing: 4) {
                    Image(systemName: isOn ? "pin.fill" : "pin")
                    Text(isOn ? "Pinned" : "Pin")
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(isOn ? Color.white : DCTheme.brandBlue)
                .padding(.horizontal, 10)
                .frame(height: 30)
                .fixedSize()
                .background {
                    Capsule().fill(isOn ? AnyShapeStyle(DCTheme.brandGradient) : AnyShapeStyle(DCTheme.brandBlue.opacity(0.12)))
                }
            }
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityValue(isOn ? "Pinned" : "Not pinned")
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .accessibilityIdentifier("onboardingForum-\(ForumSite.host(of: row.siteURL))")
    }

    private var addForumCard: some View {
        VStack(alignment: .leading, spacing: DCTheme.spacingS) {
            Text("Add another forum")
                .font(.subheadline.weight(.semibold))
            HStack(spacing: DCTheme.spacingS) {
                TextField("forum.example.com", text: $address)
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .submitLabel(.go)
                    .focused($addressFocused)
                    .onSubmit(add)
                    .fieldCard()
                    .accessibilityIdentifier("onboardingForumAddress")
                Button(action: add) {
                    Group {
                        if adding {
                            ProgressView().tint(.white)
                        } else {
                            Text("Add")
                        }
                    }
                    .frame(minWidth: 44)
                }
                .buttonStyle(DCActionButtonStyle(prominent: true))
                .disabled(adding || address.trimmingCharacters(in: .whitespaces).isEmpty)
                .accessibilityIdentifier("onboardingAddForum")
            }
            if let addError {
                Label(addError, systemImage: "exclamationmark.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(DCTheme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let addedName {
                Label("Added and pinned \(addedName).", systemImage: "checkmark.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(DCTheme.success)
            } else {
                Text("Paste the address of any Discourse forum, or a link to one of its pages.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .animation(DCMotion.quick, value: addError)
        .animation(DCMotion.quick, value: addedName)
    }

    private func add() {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !adding else { return }
        adding = true
        addError = nil
        addedName = nil
        Task {
            do {
                let forum = try await app.addForum(fromAddress: trimmed, pin: true)
                selected.insert(forum.siteURL)
                addedName = forum.displayName
                address = ""
                addressFocused = false
                DCHaptics.success()
            } catch {
                addError = error.localizedDescription
                DCHaptics.warning()
            }
            adding = false
        }
    }
}

/// Forum icon, falling back to a colored monogram.
struct OnboardingForumIcon: View {
    let siteURL: String
    let name: String
    var iconURL: URL?
    var size: CGFloat = 36

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
        ZStack {
            shape.fill(DCTheme.forumTint(for: siteURL).gradient)
            Text(String(name.trimmingCharacters(in: .whitespaces).prefix(1)).uppercased())
                .font(.system(size: size * 0.46, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
            if let iconURL {
                AsyncImage(url: iconURL) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                            .frame(width: size, height: size)
                            .background(Color.white)
                    }
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .accessibilityHidden(true)
    }
}

// MARK: 5. Sync across your devices

/// Optional: pick a folder in iCloud Drive (Skip allowed).
struct OnboardingSyncPage: View {
    @ObservedObject var app: AppModel
    @ObservedObject private var sync: FolderSyncController
    @State private var picking = false

    init(app: AppModel) {
        self.app = app
        self.sync = app.folderSync
    }

    private var status: FolderSyncController.Status { SyncDebug.status(actual: sync.status) }

    var body: some View {
        OnboardingPage {
            OnboardingHeader(
                eyebrow: "Optional",
                title: "Sync across your devices",
                subtitle: "Keep your forums, summaries, chats and agent runs on your iPhone and iPad."
            )
            VStack(alignment: .leading, spacing: DCTheme.spacingL) {
                OnboardingFeatureRow(
                    symbol: "folder.fill",
                    tint: SettingsPage.sync.tint,
                    title: "A folder in your iCloud Drive",
                    detail: FolderPicker.tip
                )
                OnboardingFeatureRow(
                    symbol: "lock.fill",
                    tint: DCTheme.brandPurple,
                    title: "Encrypted first",
                    detail: "Synced data is encrypted before it reaches iCloud Drive, with a key kept in iCloud Keychain."
                )
                OnboardingFeatureRow(
                    symbol: "key.fill",
                    tint: DCTheme.chatTint,
                    title: "API keys come along",
                    detail: "Your keys sync with iCloud Keychain. You can turn that off in Settings › iCloud Sync."
                )
            }
            .dcCard()

            if status == .off {
                Button {
                    picking = true
                } label: {
                    Label("Choose folder…", systemImage: "folder.badge.plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(DCActionButtonStyle(prominent: false))
                .accessibilityIdentifier("onboardingSyncChooseFolder")
            } else {
                let presentation = SyncStatusPresentation(status)
                HStack(alignment: .top, spacing: DCTheme.spacingM) {
                    OnboardingIconTile(symbol: presentation.symbol, tint: presentation.tint, size: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(sync.folderName.map { "Syncing with “\($0)”" } ?? presentation.title)
                            .font(.subheadline.weight(.semibold))
                        Text(presentation.detail ?? presentation.title)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    Button("Change…") { picking = true }
                        .font(.subheadline.weight(.semibold))
                        .accessibilityIdentifier("onboardingSyncChooseFolder")
                }
                .dcCard(tint: presentation.tint)
                .accessibilityIdentifier("onboardingSyncStatus")
            }
        }
        .syncFolderPicker(isPresented: $picking, app: app)
    }
}

// MARK: 6. Share from Safari or Chrome

struct OnboardingSharePage: View {
    var body: some View {
        OnboardingPage {
            OnboardingHeader(
                eyebrow: "Tip",
                title: "Share from Safari or Chrome",
                subtitle: "Reading a forum in another browser? Send the page to Forumind in a couple of taps."
            )
            ShareHowToGuide()
        }
    }
}

/// Illustrated share-sheet walkthrough, also shown in Settings › Help.
struct ShareHowToGuide: View {
    var body: some View {
        VStack(alignment: .leading, spacing: DCTheme.spacingL) {
            ShareSheetIllustration()
            VStack(alignment: .leading, spacing: DCTheme.spacingM) {
                ShareStepRow(number: 1, symbol: "square.and.arrow.up", text: "Open a forum topic in Safari or Chrome and tap **Share**. In Chrome, tap **⋯**, then **Share…**")
                ShareStepRow(number: 2, symbol: "arrow.left.and.right", text: "Swipe the row of app icons to the end and tap **More**.")
                ShareStepRow(number: 3, symbol: "switch.2", text: "Tap **Edit**, turn on **Forumind**, and add it to Favorites so it’s always near the front.")
                ShareStepRow(number: 4, symbol: "hand.tap.fill", text: "Tap **Forumind**, then pick what you want:")
            }
            ShareActionsIllustration()
                .padding(.leading, 40)
            Text("You only need to turn it on once. After that it appears in every app’s share sheet.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct ShareStepRow: View {
    let number: Int
    let symbol: String
    let text: LocalizedStringKey

    var body: some View {
        HStack(alignment: .top, spacing: DCTheme.spacingM) {
            Text("\(number)")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(DCTheme.brandGradient, in: Circle())
            Text(text)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
        }
        .accessibilityElement(children: .combine)
    }
}

/// SF Symbols mock of the iOS share sheet with Forumind highlighted.
struct ShareSheetIllustration: View {
    var body: some View {
        VStack(spacing: DCTheme.spacingM) {
            Capsule()
                .fill(Color.secondary.opacity(0.35))
                .frame(width: 36, height: 5)
            HStack(spacing: DCTheme.spacingM) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(DCTheme.brandBlue.opacity(0.15))
                    .frame(width: 38, height: 38)
                    .overlay { Image(systemName: "safari").foregroundStyle(DCTheme.brandBlue) }
                VStack(alignment: .leading, spacing: 4) {
                    RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.7)).frame(width: 150, height: 8)
                    RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.4)).frame(width: 100, height: 7)
                }
                Spacer()
            }
            Divider()
            HStack(alignment: .top, spacing: 0) {
                appIcon(symbol: "message.fill", tint: .green, label: "Messages")
                appIcon(symbol: "envelope.fill", tint: .blue, label: "Mail")
                appIcon(symbol: "note.text", tint: .orange, label: "Notes")
                appIcon
                appIcon(symbol: "ellipsis", tint: .gray, label: "More", plain: true)
            }
        }
        .padding(DCTheme.spacingL)
        .background(DCTheme.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(DCTheme.border)
        }
        .shadow(color: .black.opacity(0.06), radius: 12, y: 6)
        .accessibilityElement()
        .accessibilityLabel("Illustration: the share sheet with Forumind in the row of apps, next to More.")
    }

    private var appIcon: some View {
        VStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(DCTheme.brandGradient)
                .frame(width: 52, height: 52)
                .overlay {
                    Image(systemName: "bubble.left.and.text.bubble.right.fill")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .padding(3)
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(DCTheme.brandBlue, lineWidth: 2.5)
                }
            Text("Forumind")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(DCTheme.brandBlue)
                .multilineTextAlignment(.center)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity)
    }

    private func appIcon(symbol: String, tint: Color, label: String, plain: Bool = false) -> some View {
        VStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(plain ? AnyShapeStyle(Color.secondary.opacity(0.15)) : AnyShapeStyle(tint.gradient))
                .frame(width: 52, height: 52)
                .overlay {
                    Image(systemName: symbol)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(plain ? Color.primary : Color.white)
                }
                .padding(3)
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }
}

/// The four actions the Forumind share sheet offers.
struct ShareActionsIllustration: View {
    private let actions: [(String, String, Color)] = [
        ("Summarize", "sparkles", .indigo),
        ("Chat about it", "bubble.left.and.bubble.right.fill", .blue),
        ("Ask the forum", "text.magnifyingglass", .teal),
        ("Just open", "safari.fill", .gray)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(actions, id: \.0) { title, symbol, tint in
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(tint.gradient)
                        .frame(width: 26, height: 26)
                        .overlay {
                            Image(systemName: symbol)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.white)
                        }
                    Text(title).font(.subheadline.weight(.medium))
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: 7. Privacy

struct OnboardingPrivacyPage: View {
    var body: some View {
        OnboardingPage {
            OnboardingHeader(
                eyebrow: "Privacy",
                title: "Your data stays yours",
                subtitle: "No accounts, no analytics, no servers of ours in the middle."
            )
            VStack(alignment: .leading, spacing: DCTheme.spacingL) {
                PrivacyPoints()
            }
            .dcCard()
        }
    }
}

/// The privacy promises (onboarding and Settings › Data & privacy).
struct PrivacyPoints: View {
    var body: some View {
        OnboardingFeatureRow(
            symbol: "key.fill",
            tint: DCTheme.brandPurple,
            title: "Keys in your Keychain",
            detail: "Keys are kept in your Keychain and, if you turn on sync, in iCloud Keychain. They’re sent only to the provider they belong to."
        )
        OnboardingFeatureRow(
            symbol: "iphone",
            tint: DCTheme.brandBlue,
            title: "Saved on your devices",
            detail: "Summaries, chats, and answers are stored on your device. Synced data is encrypted before it reaches iCloud Drive. Delete them any time in Settings."
        )
        OnboardingFeatureRow(
            symbol: "arrow.left.arrow.right",
            tint: DCTheme.chatTint,
            title: "Only two destinations",
            detail: "Requests go only to the forum you’re reading and the AI provider you chose. Sync uses your own iCloud."
        )
        OnboardingFeatureRow(
            symbol: "eye.slash.fill",
            tint: DCTheme.warning,
            title: "No accounts or tracking",
            detail: "There’s nothing to sign up for, and nothing about how you use the app is collected."
        )
        OnboardingFeatureRow(
            symbol: "shield.lefthalf.filled",
            tint: DCTheme.success,
            title: "Ads and trackers blocked",
            detail: "Blocks ads and trackers in the built-in browser."
        )
    }
}

// MARK: 8. Done

struct OnboardingDonePage: View {
    @ObservedObject var app: AppModel
    let providerState: ProviderTestState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    var body: some View {
        OnboardingPage(alignment: .center) {
            Spacer(minLength: DCTheme.spacingL)
            Circle()
                .fill(DCTheme.brandGradient)
                .frame(width: 112, height: 112)
                .overlay {
                    Image(systemName: "checkmark")
                        .font(.system(size: 48, weight: .bold))
                        .foregroundStyle(.white)
                }
                .shadow(color: Color(hex: 0x4A6BFF, opacity: 0.3), radius: 20, y: 10)
                .scaleEffect(appeared || reduceMotion ? 1 : 0.6)
                .opacity(appeared ? 1 : 0)
                .accessibilityHidden(true)
            OnboardingHeader(
                title: "You’re all set",
                subtitle: "Open a topic and tap the assistant to summarize it, chat about it, or ask the forum.",
                alignment: .center
            )
            VStack(spacing: 0) {
                checklistRow(
                    done: app.isProviderReady,
                    title: app.isProviderReady ? "AI provider: \(app.settings.selectedProvider.displayName)" : "AI provider not connected",
                    detail: app.isProviderReady
                        ? (app.settings.selectedProvider.isAppleIntelligence ? app.appleIntelligenceStatus.title : app.selectedConfiguration.model)
                        : "Add one any time in Settings › AI provider."
                )
                Divider().padding(.leading, 48)
                checklistRow(
                    done: !app.pinnedForums.isEmpty,
                    title: app.pinnedForums.isEmpty ? "No pinned forums yet" : pinnedTitle,
                    detail: app.pinnedForums.isEmpty ? "Pick from suggestions or add any forum by address." : app.pinnedForums.map(\.displayName).joined(separator: ", ")
                )
                Divider().padding(.leading, 48)
                OnboardingDoneSyncRow(app: app)
            }
            .dcCard()
        }
        .onAppear {
            withAnimation(reduceMotion ? .easeOut(duration: 0.2) : DCMotion.spring.delay(0.1)) {
                appeared = true
            }
        }
    }

    private var pinnedTitle: String {
        let count = app.pinnedForums.count
        return "\(count) pinned \(count == 1 ? "forum" : "forums")"
    }

    private func checklistRow(done: Bool, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: DCTheme.spacingM) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle.dashed")
                .font(.title2)
                .foregroundStyle(done ? DCTheme.success : Color.secondary)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }
}

/// Done page checklist row for sync.
private struct OnboardingDoneSyncRow: View {
    @ObservedObject private var sync: FolderSyncController

    init(app: AppModel) {
        self.sync = app.folderSync
    }

    var body: some View {
        let on = SyncDebug.status(actual: sync.status) != .off
        HStack(alignment: .top, spacing: DCTheme.spacingM) {
            Image(systemName: on ? "checkmark.circle.fill" : "circle.dashed")
                .font(.title2)
                .foregroundStyle(on ? DCTheme.success : Color.secondary)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(on ? "Syncing across your devices" : "Sync is off")
                    .font(.subheadline.weight(.semibold))
                Text(on ? (sync.folderName.map { "Folder: \($0)" } ?? "iCloud Drive") : "Turn it on any time in Settings › iCloud Sync.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }
}
