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
                eyebrow: String(localized: "Welcome to Forumind"),
                title: String(localized: "Catch up on any Discourse forum in seconds"),
                subtitle: String(localized: "Browse your forums, get clear summaries of long topics, and ask questions with answers that cite their sources."),
                alignment: .center
            )
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared || reduceMotion ? 0 : 12)
            HStack(spacing: DCTheme.spacingS) {
                DCPill(text: String(localized: "Summaries"), systemImage: "sparkles", tint: DCTheme.summaryTint)
                DCPill(text: String(localized: "Chat"), systemImage: "bubble.left.and.bubble.right.fill", tint: DCTheme.chatTint)
                DCPill(text: String(localized: "Ask the forum"), systemImage: "text.magnifyingglass", tint: DCTheme.agentTint)
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
        BrandMark(size: 164)
            .shadow(color: Color(hex: 0x4A6BFF, opacity: 0.35), radius: 24, y: 12)
            .padding(.vertical, DCTheme.spacingS)
        .accessibilityHidden(true)
    }
}

// MARK: 2. What it does

struct OnboardingFeaturesPage: View {
    var body: some View {
        OnboardingPage {
            OnboardingHeader(
                eyebrow: String(localized: "What it does"),
                title: String(localized: "Three ways to get to the point"),
                subtitle: String(localized: "Open any topic and the assistant is one tap away.")
            )
            VStack(spacing: DCTheme.spacingM) {
                featureCard(
                    symbol: "sparkles",
                    tint: DCTheme.summaryTint,
                    title: String(localized: "Summaries"),
                    detail: String(localized: "The original post, how people responded, and the key takeaways, even on topics with thousands of replies."),
                    example: String(localized: "“Most replies agree the new version fixes it…”")
                )
                featureCard(
                    symbol: "bubble.left.and.bubble.right.fill",
                    tint: DCTheme.chatTint,
                    title: String(localized: "Chat about a topic"),
                    detail: String(localized: "Ask follow-up questions about the page you’re reading. Answers stay grounded in the discussion."),
                    example: String(localized: "“What workaround did people suggest?”")
                )
                featureCard(
                    symbol: "text.magnifyingglass",
                    tint: DCTheme.agentTint,
                    title: String(localized: "Ask the forum"),
                    detail: String(localized: "Ask a question and it searches the forum, reads the best topics, and answers with cited sources like [S1]."),
                    example: String(localized: "“What’s the best way to self-host this?”")
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
                title: String(localized: "Connect an AI provider"),
                subtitle: app.appleIntelligenceStatus.isAvailable
                    ? String(localized: "Apple Intelligence is built into this device: private, no account, no key. Or connect a provider you already use. You can change this any time in Settings.")
                    : String(localized: "Forumind doesn’t include its own AI. Connect one you use, or sign up for one. You can change this any time in Settings.")
            )
            // One model for everything to start; Settings › AI models can
            // give Ask the forum its own later.
            ProviderSetupForm(app: app, scope: .both, state: $state)
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
                title: String(localized: "Choose your forums"),
                subtitle: String(localized: "Pin the communities you read. Pinned forums stay at the top of your Forums screen. You can visit any other forum too.")
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

/// Informational: sync is on by default wherever iCloud is available.
struct OnboardingSyncPage: View {
    @ObservedObject var app: AppModel
    @ObservedObject private var sync: CloudSyncController

    init(app: AppModel) {
        self.app = app
        self.sync = app.cloudSync
    }

    private var status: CloudSyncController.Status { SyncDebug.status(actual: sync.status) }
    private var isEnabled: Bool { SyncDebug.isEnabled(actual: sync.isEnabled) }

    var body: some View {
        OnboardingPage {
            OnboardingHeader(
                eyebrow: String(localized: "Automatic"),
                title: String(localized: "Sync across your devices"),
                subtitle: String(localized: "Your forums, summaries and chats sync across your iPhone and iPad through iCloud — end-to-end encrypted.")
            )
            VStack(alignment: .leading, spacing: DCTheme.spacingL) {
                OnboardingFeatureRow(
                    symbol: "icloud.fill",
                    tint: SettingsPage.sync.tint,
                    title: String(localized: "Nothing to set up"),
                    detail: String(localized: "Sign in to the same Apple Account on each device and your data follows you.")
                )
                OnboardingFeatureRow(
                    symbol: "lock.fill",
                    tint: DCTheme.brandPurple,
                    title: String(localized: "End-to-end encrypted"),
                    detail: String(localized: "Stored in your own iCloud account with keys only your devices have. No server of ours in between.")
                )
                OnboardingFeatureRow(
                    symbol: "key.fill",
                    tint: DCTheme.chatTint,
                    title: String(localized: "API keys come along"),
                    detail: String(localized: "Your keys sync with iCloud Keychain. You can turn that off in Settings › iCloud Sync.")
                )
            }
            .dcCard()

            VStack(alignment: .leading, spacing: DCTheme.spacingM) {
                Toggle(isOn: Binding(get: { isEnabled }, set: { sync.setEnabled($0) })) {
                    Text("Sync with iCloud")
                        .font(.subheadline.weight(.semibold))
                }
                .tint(SettingsPage.sync.tint)
                .accessibilityIdentifier("onboardingSyncToggle")
                if isEnabled {
                    let presentation = SyncStatusPresentation(status)
                    HStack(alignment: .top, spacing: DCTheme.spacingM) {
                        OnboardingIconTile(symbol: presentation.symbol, tint: presentation.tint, size: 32)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(presentation.title)
                                .font(.subheadline.weight(.semibold))
                            if let detail = presentation.detail {
                                Text(detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("onboardingSyncStatus")
                } else {
                    Text("Turn it on any time in Settings › iCloud Sync.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .dcCard()
        }
    }
}

// MARK: 6. Share from Safari or Chrome

struct OnboardingSharePage: View {
    var body: some View {
        OnboardingPage {
            OnboardingHeader(
                eyebrow: String(localized: "Tip"),
                title: String(localized: "Share from Safari or Chrome"),
                subtitle: String(localized: "Reading a forum in another browser? Send the page to Forumind in a couple of taps.")
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
                appIcon(symbol: "message.fill", tint: .green, label: String(localized: "Messages", comment: "Name of Apple's Messages app, as shown in the iOS share sheet"))
                appIcon(symbol: "envelope.fill", tint: .blue, label: String(localized: "Mail", comment: "Name of Apple's Mail app, as shown in the iOS share sheet"))
                appIcon(symbol: "note.text", tint: .orange, label: String(localized: "Notes", comment: "Name of Apple's Notes app, as shown in the iOS share sheet"))
                appIcon
                appIcon(symbol: "ellipsis", tint: .gray, label: String(localized: "More", comment: "The More button at the end of the app row in the iOS share sheet"), plain: true)
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
            BrandMark(size: 52)
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
        // The share extension's buttons (same wording as ForumindShare).
        (String(localized: "Summarize"), "sparkles", .indigo),
        (String(localized: "Chat about it"), "bubble.left.and.bubble.right.fill", .blue),
        (String(localized: "Ask the forum"), "text.magnifyingglass", .teal),
        (String(localized: "Just open"), "safari.fill", .gray)
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
    @Binding var termsAgreed: Bool

    var body: some View {
        OnboardingPage {
            OnboardingHeader(
                eyebrow: String(localized: "Privacy"),
                title: String(localized: "Your data stays yours"),
                subtitle: String(localized: "No accounts, no analytics, no servers of ours in the middle.")
            )
            VStack(alignment: .leading, spacing: DCTheme.spacingL) {
                PrivacyPoints()
            }
            .dcCard()
            Text("Terms of Use")
                .font(.title3.weight(.bold))
                .accessibilityAddTraits(.isHeader)
            TermsAgreementCard(agreed: $termsAgreed)
        }
    }
}

/// The privacy promises (onboarding and Settings › Data & privacy).
struct PrivacyPoints: View {
    var body: some View {
        OnboardingFeatureRow(
            symbol: "key.fill",
            tint: DCTheme.brandPurple,
            title: String(localized: "Keys in your Keychain"),
            detail: String(localized: "Keys are kept in your Keychain and, with Sync API keys on, in iCloud Keychain. They’re sent only to the provider they belong to.")
        )
        OnboardingFeatureRow(
            symbol: "iphone",
            tint: DCTheme.brandBlue,
            title: String(localized: "Saved on your devices"),
            detail: String(localized: "Summaries, chats, and answers are stored on your device and, with sync, end-to-end encrypted in your own iCloud. Delete them any time in Settings.")
        )
        OnboardingFeatureRow(
            symbol: "arrow.left.arrow.right",
            tint: DCTheme.chatTint,
            title: String(localized: "Only where it needs to go"),
            detail: String(localized: "Requests go only to the forum you’re reading and the AI provider you chose. Sync uses your own iCloud. Once a day the app downloads Forumind’s public list of removed content, sending nothing about you.")
        )
        OnboardingFeatureRow(
            symbol: "eye.slash.fill",
            tint: DCTheme.warning,
            title: String(localized: "No accounts or tracking"),
            detail: String(localized: "There’s nothing to sign up for, and nothing about how you use the app is collected.")
        )
        OnboardingFeatureRow(
            symbol: "shield.lefthalf.filled",
            tint: DCTheme.success,
            title: String(localized: "Optional ad blocking", comment: "Onboarding privacy row title"),
            detail: String(localized: "Optional ad and tracker blocking in the built-in browser. It’s off by default; turn it on in Settings › Browser.", comment: "Onboarding privacy row")
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
                title: String(localized: "You’re all set"),
                subtitle: String(localized: "Open a topic and tap the assistant to summarize it, chat about it, or ask the forum."),
                alignment: .center
            )
            VStack(spacing: 0) {
                checklistRow(
                    done: app.isProviderReady,
                    title: app.isProviderReady
                        ? String(localized: "AI provider: \(app.settings.selectedProvider.displayName)", comment: "Walkthrough checklist. The placeholder is the provider's name, e.g. OpenRouter.")
                        : String(localized: "AI provider not connected"),
                    detail: app.isProviderReady
                        ? (app.settings.selectedProvider.isAppleIntelligence ? app.appleIntelligenceStatus.title : app.selectedConfiguration.model)
                        : String(localized: "Add one any time in Settings › AI models.", comment: "Walkthrough checklist; Settings › AI models names the app's own Settings page")
                )
                Divider().padding(.leading, 48)
                checklistRow(
                    done: !app.pinnedForums.isEmpty,
                    title: app.pinnedForums.isEmpty ? String(localized: "No pinned forums yet") : pinnedTitle,
                    detail: app.pinnedForums.isEmpty ? String(localized: "Pick from suggestions or add any forum by address.") : app.pinnedForums.map(\.displayName).joined(separator: ", ")
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
        return String(localized: "\(count) pinned forums", comment: "Walkthrough checklist: number of pinned forums")
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
    @ObservedObject private var sync: CloudSyncController

    init(app: AppModel) {
        self.sync = app.cloudSync
    }

    var body: some View {
        let status = SyncDebug.status(actual: sync.status)
        let enabled = SyncDebug.isEnabled(actual: sync.isEnabled)
        let on = enabled && [.syncing, .upToDate].contains(status)
        HStack(alignment: .top, spacing: DCTheme.spacingM) {
            Image(systemName: on ? "checkmark.circle.fill" : "circle.dashed")
                .font(.title2)
                .foregroundStyle(on ? DCTheme.success : Color.secondary)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(on ? String(localized: "Syncing across your devices") : (enabled ? SyncStatusPresentation(status).title : String(localized: "Sync is off")))
                    .font(.subheadline.weight(.semibold))
                Text(on ? "Through your iCloud account" : "Check it any time in Settings › iCloud Sync.")
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
