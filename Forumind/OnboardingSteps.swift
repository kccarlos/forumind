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
                title: String(localized: "Catch up on any forum or article in seconds"),
                subtitle: String(localized: "Browse your forums, get clear summaries of long topics, and ask questions with answers that cite their sources."),
                alignment: .center
            )
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared || reduceMotion ? 0 : 12)
            HStack(spacing: DCTheme.spacingS) {
                DCPill(text: String(localized: "Read", comment: "Walkthrough welcome: read forums"), systemImage: "book.fill", tint: DCTheme.summaryTint)
                DCPill(text: String(localized: "Ask", comment: "Walkthrough welcome: ask questions"), systemImage: "sparkles", tint: DCTheme.chatTint)
                DCPill(text: String(localized: "Listen", comment: "Walkthrough welcome: listen to the podcast"), systemImage: "headphones", tint: DCTheme.agentTint)
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

// MARK: 3. Connect an AI provider

struct OnboardingProviderPage: View {
    @ObservedObject var app: AppModel
    @Binding var state: ProviderTestState

    private var current: AIProvider { app.selection(for: .assistant).provider }

    var body: some View {
        OnboardingPage {
            OnboardingHeader(
                eyebrow: OnboardingStep.provider.stepLabel,
                title: String(localized: "Choose your AI"),
                subtitle: String(localized: "Forumind doesn’t include its own AI. Pick one; you can change it any time in Settings.")
            )
            VStack(spacing: DCTheme.spacingS) {
                choice(.gemini, recommended: true,
                       detail: String(localized: "Fast. Voice and podcast voices need it.", comment: "Walkthrough: why Google Gemini is recommended"))
                if app.appleIntelligenceStatus.isAvailable {
                    choice(.appleIntelligence, recommended: false,
                           detail: String(localized: "Built in and private. No key.", comment: "Walkthrough: Apple Intelligence"))
                }
            }
            // One model for everything to start; Settings › AI models can
            // give Ask the forum its own later. The form's menu lists the
            // other providers.
            ProviderSetupForm(app: app, scope: .both, state: $state)
        }
        .onAppear {
            if !app.isProviderReady, !app.appleIntelligenceStatus.isAvailable, current != .gemini {
                app.selectProvider(.gemini, for: .both)
            }
        }
    }

    private func choice(_ provider: AIProvider, recommended: Bool, detail: String) -> some View {
        let isOn = current == provider
        return Button {
            DCHaptics.tap()
            app.selectProvider(provider, for: .both)
        } label: {
            HStack(spacing: DCTheme.spacingM) {
                ProviderBadge(provider: provider)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(provider.displayName).font(.body.weight(.semibold)).foregroundStyle(.primary)
                        if recommended {
                            Text("Recommended", comment: "Walkthrough: badge on the suggested AI provider")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(DCTheme.brandBlue)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(DCTheme.brandBlue.opacity(0.12), in: Capsule())
                        }
                    }
                    Text(detail).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isOn ? DCTheme.brandBlue : Color.secondary)
            }
            .contentShape(Rectangle())
            .dcCard()
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .accessibilityIdentifier("onboardingProvider-\(provider.rawValue)")
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
    private var rows: [(siteURL: String, name: String, detail: String)] {
        var seen = Set<String>()
        var result: [(siteURL: String, name: String, detail: String)] = []
        let suggestions = AppModel.onboardingSuggestions()
        for forum in app.forums where seen.insert(forum.siteURL).inserted {
            let suggested = suggestions.first { $0.siteURL == forum.siteURL }
            result.append((forum.siteURL, forum.displayName, suggested?.description ?? forum.host))
        }
        for suggested in suggestions where seen.insert(suggested.siteURL).inserted {
            result.append((suggested.siteURL, suggested.name, suggested.description))
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

    private func forumRow(_ row: (siteURL: String, name: String, detail: String)) -> some View {
        let isOn = selected.contains(row.siteURL)
        return Button {
            DCHaptics.tap()
            withAnimation(DCMotion.quick) {
                if isOn { selected.remove(row.siteURL) } else { selected.insert(row.siteURL) }
            }
        } label: {
            HStack(spacing: DCTheme.spacingM) {
                OnboardingForumIcon(siteURL: row.siteURL, name: row.name, size: 40)
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
                Text("Paste the address of any supported site, or a link to one of its pages.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .animation(DCMotion.quick, value: addError)
        .animation(DCMotion.quick, value: addedName)
        .sensoryFeedback(.success, trigger: addedName) { _, new in new != nil }
        .sensoryFeedback(.warning, trigger: addError) { _, new in new != nil }
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
            } catch {
                addError = error.localizedDescription
            }
            adding = false
        }
    }
}

/// Forum icon, falling back to a colored letter tile (the walkthrough passes
/// no `iconURL`: forums' logos aren't shown there).
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

// MARK: 4. Your day

/// Optional daily digest and podcast; everything is off until chosen.
struct OnboardingDailyPage: View {
    @ObservedObject var app: AppModel

    var body: some View {
        OnboardingPage {
            OnboardingHeader(
                eyebrow: OnboardingStep.daily.stepLabel,
                title: String(localized: "Your day"),
                subtitle: String(localized: "Let Forumind catch you up each morning. All of this is off until you turn it on, and you can change it in Settings.", comment: "Walkthrough: daily digest step")
            )
            VStack(spacing: 0) {
                toggleRow(
                    symbol: "newspaper.fill", tint: DCTheme.summaryTint,
                    title: String(localized: "Daily digest", comment: "Walkthrough toggle"),
                    detail: String(localized: "A summary of what’s new in your watched topics and top topics.", comment: "Walkthrough toggle"),
                    isOn: $app.settings.dailyDigestEnabled, id: "onboardingDigest"
                )
                Divider().padding(.leading, 56)
                toggleRow(
                    symbol: "bell.fill", tint: DCTheme.warning,
                    title: String(localized: "Notify me when it’s ready", comment: "Walkthrough toggle"),
                    detail: String(localized: "One notification a day.", comment: "Walkthrough toggle"),
                    isOn: $app.settings.dailyDigestNotifies, id: "onboardingDigestNotifies"
                )
                .disabled(!app.settings.dailyDigestEnabled)
                Divider().padding(.leading, 56)
                toggleRow(
                    symbol: "headphones", tint: DCTheme.agentTint,
                    title: String(localized: "Podcast every day", comment: "Walkthrough toggle"),
                    detail: String(localized: "Two hosts talk through the digest.", comment: "Walkthrough toggle"),
                    isOn: $app.settings.podcastDailyEnabled, id: "onboardingPodcastDaily"
                )
            }
            .dcCard()
            Label {
                Text("Each digest and podcast sends a few requests to your AI provider. Google Gemini’s free tier covers it; other providers bill per request.", comment: "Walkthrough: cost of the daily digest")
            } icon: {
                Image(systemName: "info.circle")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func toggleRow(symbol: String, tint: Color, title: String, detail: String, isOn: Binding<Bool>, id: String) -> some View {
        Toggle(isOn: isOn) {
            HStack(spacing: DCTheme.spacingM) {
                OnboardingIconTile(symbol: symbol, tint: tint, size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.subheadline.weight(.semibold))
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .tint(DCTheme.brandBlue)
        .padding(.vertical, 8)
        .accessibilityIdentifier(id)
    }
}

// MARK: 5. Privacy and sync

/// The iCloud Sync switch on the privacy step (on by default wherever iCloud
/// is available).
struct OnboardingSyncCard: View {
    @ObservedObject private var sync: CloudSyncController

    init(app: AppModel) {
        self.sync = app.cloudSync
    }

    private var status: CloudSyncController.Status { SyncDebug.status(actual: sync.status) }
    private var isEnabled: Bool { SyncDebug.isEnabled(actual: sync.isEnabled) }

    var body: some View {
        VStack(alignment: .leading, spacing: DCTheme.spacingM) {
            Toggle(isOn: Binding(get: { isEnabled }, set: { sync.setEnabled($0) })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Sync with iCloud")
                        .font(.subheadline.weight(.semibold))
                    Text("Forums, summaries and chats follow you across your devices, end-to-end encrypted in your own iCloud.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
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
            }
        }
        .dcCard()
    }
}

// MARK: Share from Safari or Chrome

/// The Share how-to page (Home, Settings › Help, the last step). The share
/// extension's four actions are listed as `ShareSheetView` has them.
struct ShareHowToGuide: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: DCTheme.spacingL) {
            ShareSheetIllustration()
            VStack(alignment: .leading, spacing: DCTheme.spacingM) {
                ShareStepRow(number: 1, symbol: "square.and.arrow.up", text: "Open a forum topic in Safari or Chrome and tap **Share**. In Chrome, tap **⋯**, then **Share…**")
                ShareStepRow(number: 2, symbol: "switch.2", text: "First time only: swipe the row of apps to the end, tap **More**, turn on **Forumind** and add it to Favorites.")
                ShareStepRow(number: 3, symbol: "hand.tap.fill", text: "Tap **Forumind**, then pick what you want:")
            }
            ShareActionsIllustration()
                .padding(.leading, 40)
            Text("You only need to turn it on once. After that it appears in every app’s share sheet.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                openURL(AppModel.shareTryURL)
            } label: {
                Label("Try It in Safari", systemImage: "safari")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(DCActionButtonStyle(prominent: false))
            .accessibilityIdentifier("shareHowToTrySafari")
        }
    }
}

/// The Share how-to as a sheet (Home card, last walkthrough step).
struct ShareHowToSheet: View {
    let onDone: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DCTheme.spacingL) {
                    OnboardingHeader(
                        eyebrow: String(localized: "Tip"),
                        title: String(localized: "Share from Safari or Chrome"),
                        subtitle: String(localized: "Reading a forum in another browser? Send the page to Forumind in a couple of taps.")
                    )
                    ShareHowToGuide()
                    Button("Done", action: onDone)
                        .buttonStyle(DCPrimaryButtonStyle())
                        .accessibilityIdentifier("shareHowToDone")
                }
                .padding(DCTheme.spacingL)
                .frame(maxWidth: DCTheme.contentMaxWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .background(DCTheme.pageBackground)
            .navigationBarTitleDisplayMode(.inline)
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

// (continued) Privacy

struct OnboardingPrivacyPage: View {
    @ObservedObject var app: AppModel
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
            OnboardingSyncCard(app: app)
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

// MARK: 6. Done

struct OnboardingDonePage: View {
    @ObservedObject var app: AppModel
    var showShareHowTo: () -> Void = {}
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    var body: some View {
        OnboardingPage(alignment: .center) {
            Spacer(minLength: 0)
            Circle()
                .fill(DCTheme.brandGradient)
                .frame(width: 76, height: 76)
                .overlay {
                    Image(systemName: "checkmark")
                        .font(.system(size: 34, weight: .bold))
                        .foregroundStyle(.white)
                }
                .shadow(color: Color(hex: 0x4A6BFF, opacity: 0.3), radius: 20, y: 10)
                .scaleEffect(appeared || reduceMotion ? 1 : 0.6)
                .opacity(appeared ? 1 : 0)
                .accessibilityHidden(true)
            OnboardingHeader(
                title: String(localized: "You’re all set"),
                subtitle: String(localized: "Here is what you set up."),
                alignment: .center
            )
            VStack(spacing: 0) {
                checklistRow(
                    order: 0,
                    done: app.isProviderReady,
                    title: app.isProviderReady
                        ? String(localized: "AI provider: \(app.settings.assistantModel.provider.displayName)", comment: "Walkthrough checklist. The placeholder is the provider's name, e.g. OpenRouter.")
                        : String(localized: "AI provider not connected"),
                    detail: app.isProviderReady
                        ? aiDetail
                        : String(localized: "Add one any time in Settings › AI models.", comment: "Walkthrough checklist; Settings › AI models names the app's own Settings page")
                )
                Divider().padding(.leading, 48)
                checklistRow(
                    order: 1,
                    done: !app.pinnedForums.isEmpty,
                    title: app.pinnedForums.isEmpty ? String(localized: "No pinned forums yet") : pinnedTitle,
                    detail: app.pinnedForums.isEmpty ? String(localized: "Pick from suggestions or add any forum by address.") : app.pinnedForums.map(\.displayName).joined(separator: ", ")
                )
                Divider().padding(.leading, 48)
                checklistRow(
                    order: 2,
                    done: app.settings.dailyDigestEnabled,
                    title: app.settings.dailyDigestEnabled ? String(localized: "Daily digest on", comment: "Walkthrough checklist") : String(localized: "Daily digest off", comment: "Walkthrough checklist"),
                    detail: app.settings.podcastDailyEnabled ? String(localized: "With a daily podcast", comment: "Walkthrough checklist") : String(localized: "Change it in Settings › Daily digest & podcast.", comment: "Walkthrough checklist")
                )
                Divider().padding(.leading, 48)
                OnboardingDoneSyncRow(app: app, order: 3)
            }
            .dcCard()
            VStack(alignment: .leading, spacing: DCTheme.spacingS) {
                Text("Try first", comment: "Walkthrough: first things to try")
                    .font(.subheadline.weight(.semibold))
                ShareStepRow(number: 1, symbol: "sparkles", text: "Open a topic and tap the AI button.")
                ShareStepRow(number: 2, symbol: "number", text: "Tap a post number to jump to it.")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .dcCard()
            Button(action: showShareHowTo) {
                HStack {
                    Image(systemName: "square.and.arrow.up")
                    Text("Open pages from Safari or Chrome")
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold))
                }
                .font(.subheadline.weight(.semibold))
                .contentShape(Rectangle())
                .dcCard()
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("onboardingShareHowTo")
        }
        .onAppear {
            withAnimation(reduceMotion ? .easeOut(duration: 0.2) : DCMotion.spring.delay(0.1)) {
                appeared = true
            }
        }
    }

    /// "Google Gemini · voice ready" and the like.
    private var aiDetail: String {
        let provider = app.settings.assistantModel.provider
        if provider.isAppleIntelligence { return app.appleIntelligenceStatus.title }
        if provider == .gemini { return String(localized: "\(app.selectedConfiguration.model) · voice ready", comment: "Walkthrough checklist: the model name, then that voice works with this provider") }
        return app.selectedConfiguration.model
    }

    private var pinnedTitle: String {
        let count = app.pinnedForums.count
        return String(localized: "\(count) pinned forums", comment: "Walkthrough checklist: number of pinned forums")
    }

    private func checklistRow(order: Int, done: Bool, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: DCTheme.spacingM) {
            ChecklistMark(done: done, order: order)
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

    let order: Int

    init(app: AppModel, order: Int) {
        self.sync = app.cloudSync
        self.order = order
    }

    var body: some View {
        let status = SyncDebug.status(actual: sync.status)
        let enabled = SyncDebug.isEnabled(actual: sync.isEnabled)
        let on = enabled && [.syncing, .upToDate].contains(status)
        HStack(alignment: .top, spacing: DCTheme.spacingM) {
            ChecklistMark(done: on, order: order)
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

/// The timing of the Done page's checks: one after another, 60 ms apart,
/// or all at once with Reduce Motion.
enum ChecklistMotion {
    static let stagger: TimeInterval = 0.06
    /// After the page's own badge has come in.
    static let start: TimeInterval = 0.3

    static func delay(order: Int, reduceMotion: Bool) -> TimeInterval {
        reduceMotion ? 0 : start + stagger * Double(max(order, 0))
    }
}

/// A Done page checklist mark: a done item's check draws on (iOS 26) or
/// scales in and fades in (earlier); items that are not done stay dashed.
private struct ChecklistMark: View {
    let done: Bool
    let order: Int
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if done && shown {
                check
            } else {
                Image(systemName: "circle.dashed")
                    .foregroundStyle(Color.secondary)
            }
        }
        .font(.title2)
        .frame(width: 32)
        .task(id: done) {
            guard done else {
                shown = false
                return
            }
            if reduceMotion {
                shown = true
            } else {
                withAnimation(DCMotion.spring.delay(ChecklistMotion.delay(order: order, reduceMotion: false))) { shown = true }
            }
        }
    }

    @ViewBuilder
    private var check: some View {
        let image = Image(systemName: "checkmark.circle.fill").foregroundStyle(DCTheme.success)
        if reduceMotion {
            image
        } else if #available(iOS 26.0, *) {
            image.transition(.symbolEffect(.drawOn))
        } else {
            image.transition(.scale(scale: 0.5).combined(with: .opacity))
        }
    }
}
