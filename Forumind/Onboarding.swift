import SwiftUI

/// Replays the walkthrough (Settings › Help). Set by `ForumindApp`.
struct ReplayOnboardingAction {
    var action: () -> Void = {}
    func callAsFunction() { action() }
}

private struct ReplayOnboardingKey: EnvironmentKey {
    static let defaultValue = ReplayOnboardingAction()
}

extension EnvironmentValues {
    var replayOnboarding: ReplayOnboardingAction {
        get { self[ReplayOnboardingKey.self] }
        set { self[ReplayOnboardingKey.self] = newValue }
    }
}

/// First-launch walkthrough: paged (swipe or Back/Continue), progress dots,
/// Skip on optional steps. On iPad it is a centered card.
struct OnboardingFlow: View {
    @ObservedObject var app: AppModel
    /// Called after `completeOnboarding()`; the host dismisses the cover.
    var onFinish: () -> Void = {}

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    @State private var step: OnboardingStep
    @State private var movingForward = true
    @State private var providerState: ProviderTestState = .idle
    @State private var selectedForums: Set<String>
    @FocusState private var focused: Bool
    @State private var keyboardVisible = false

    init(app: AppModel, initialStep: OnboardingStep = .welcome, onFinish: @escaping () -> Void = {}) {
        self.app = app
        self.onFinish = onFinish
        _step = State(initialValue: initialStep)
        _selectedForums = State(initialValue: Set(app.pinnedForums.map(\.siteURL)))
    }

    private var usesCard: Bool {
        horizontalSizeClass == .regular && verticalSizeClass == .regular
    }

    var body: some View {
        ZStack {
            OnboardingBackdrop()
            if usesCard {
                content
                    .frame(maxWidth: 580, maxHeight: 860)
                    .background(
                        DCTheme.pageBackground,
                        in: RoundedRectangle(cornerRadius: 28, style: .continuous)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 28, style: .continuous)
                            .stroke(Color.primary.opacity(0.12))
                    }
                    .shadow(color: .black.opacity(0.18), radius: 30, y: 12)
                    .padding(DCTheme.spacingXL)
            } else {
                content
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("onboarding")
    }

    private var content: some View {
        VStack(spacing: 0) {
            topBar
            ZStack {
                page(for: step)
                    .id(step)
                    .transition(pageTransition)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(HorizontalClip())
            .contentShape(Rectangle())
            .simultaneousGesture(swipe)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // The bar tucks away while typing so it never rides the keyboard
            // and covers the field (and "Test & save") being edited.
            if !keyboardVisible {
                bottomBar
                    .transition(.opacity)
            }
        }
        .animation(DCMotion.respecting(reduceMotion, DCMotion.quick), value: keyboardVisible)
        .dcKeyboardVisible($keyboardVisible)
    }

    // MARK: Chrome

    private var topBar: some View {
        HStack {
            Button {
                go(to: step.previous)
            } label: {
                Image(systemName: "chevron.left")
                    .font(.body.weight(.semibold))
            }
            .buttonStyle(DCIconButtonStyle())
            .opacity(step.isFirst || step.isLast ? 0 : 1)
            .disabled(step.isFirst || step.isLast)
            .accessibilityLabel("Back")
            .accessibilityIdentifier("onboardingBack")

            Spacer()
            OnboardingProgressDots(current: step)
            Spacer()

            Button("Skip") {
                DCHaptics.tap()
                go(to: .done)
            }
            .font(.subheadline.weight(.semibold))
            .frame(minWidth: DCTheme.controlHeight, minHeight: DCTheme.controlHeight)
            .opacity(step.isFirst || step.isLast ? 0 : 1)
            .disabled(step.isFirst || step.isLast)
            .accessibilityHint("Skips the rest of the walkthrough")
            .accessibilityIdentifier("onboardingSkipAll")
        }
        .padding(.horizontal, DCTheme.spacingS)
        .padding(.top, DCTheme.spacingS)
    }

    private var bottomBar: some View {
        VStack(spacing: DCTheme.spacingS) {
            if step == .done {
                doneButtons
            } else {
                Button {
                    advance()
                } label: {
                    Text(primaryTitle)
                }
                .buttonStyle(DCPrimaryButtonStyle())
                .accessibilityIdentifier("onboardingContinue")

                if step.allowsSkip {
                    Button("Skip for now") {
                        DCHaptics.tap()
                        focused = false
                        go(to: step.next)
                    }
                    .font(.subheadline.weight(.medium))
                    .frame(minHeight: 36)
                    .accessibilityIdentifier("onboardingSkipStep")
                }
            }
        }
        .padding(.horizontal, DCTheme.spacingXL)
        .padding(.top, DCTheme.spacingM)
        .padding(.bottom, DCTheme.spacingM)
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity)
        .background {
            Rectangle()
                .fill(.bar)
                .mask(
                    LinearGradient(
                        stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.25)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .ignoresSafeArea()
        }
    }

    private var primaryTitle: String {
        switch step {
        case .provider where app.isProviderReady && providerState == .success: "Continue"
        case .forums where !selectedForums.isEmpty:
            "Continue with \(selectedForums.count) \(selectedForums.count == 1 ? "forum" : "forums")"
        default: step.continueTitle
        }
    }

    @ViewBuilder
    private var doneButtons: some View {
        if isReplayOverPage {
            // A replay from Settings returns to the page the user was on.
            Button("Back to the page") {
                finish {}
            }
            .buttonStyle(DCPrimaryButtonStyle())
            .accessibilityIdentifier("onboardingReturn")
            Button("Browse all forums") {
                finish { app.showForumsHome() }
            }
            .font(.subheadline.weight(.semibold))
            .frame(minHeight: 40)
            .accessibilityIdentifier("onboardingBrowseForums")
        } else if let first = firstPinnedForum {
            Button {
                finish { app.openForum(first) }
            } label: {
                Text("Open \(first.displayName)").lineLimit(1)
            }
            .buttonStyle(DCPrimaryButtonStyle())
            .accessibilityIdentifier("onboardingOpenForum")
            Button("Browse all forums") {
                finish { app.showForumsHome() }
            }
            .font(.subheadline.weight(.semibold))
            .frame(minHeight: 40)
            .accessibilityIdentifier("onboardingBrowseForums")
        } else {
            Button("Browse forums") {
                finish { app.showForumsHome() }
            }
            .buttonStyle(DCPrimaryButtonStyle())
            .accessibilityIdentifier("onboardingBrowseForums")
        }
    }

    /// Replaying the walkthrough (already completed) while a page is open.
    private var isReplayOverPage: Bool {
        app.settings.hasCompletedOnboarding && app.browser.currentURL != nil
    }

    private var firstPinnedForum: Forum? {
        app.pinnedForums.first
    }

    // MARK: Pages

    @ViewBuilder
    private func page(for step: OnboardingStep) -> some View {
        switch step {
        case .welcome: OnboardingWelcomePage()
        case .features: OnboardingFeaturesPage()
        case .provider: OnboardingProviderPage(app: app, state: $providerState)
        case .forums: OnboardingForumsPage(app: app, selected: $selectedForums)
        case .sync: OnboardingSyncPage(app: app)
        case .share: OnboardingSharePage()
        case .privacy: OnboardingPrivacyPage()
        case .done: OnboardingDonePage(app: app, providerState: providerState)
        }
    }

    private var pageTransition: AnyTransition {
        if reduceMotion { return .opacity }
        return .asymmetric(
            insertion: .move(edge: movingForward ? .trailing : .leading).combined(with: .opacity),
            removal: .move(edge: movingForward ? .leading : .trailing).combined(with: .opacity)
        )
    }

    private var swipe: some Gesture {
        DragGesture(minimumDistance: 30)
            .onEnded { value in
                guard !step.hasTextInput else { return }
                let horizontal = value.translation.width
                guard abs(horizontal) > 70,
                      abs(horizontal) > abs(value.translation.height) * 1.6 else { return }
                if horizontal < 0 {
                    if !step.isLast { advance() }
                } else if !step.isLast {
                    go(to: step.previous)
                }
            }
    }

    // MARK: Navigation

    private func advance() {
        DCHaptics.tap()
        focused = false
        if step == .forums { applyForumSelection() }
        if step == .provider { app.saveSettings() }
        go(to: step.next)
    }

    private func go(to target: OnboardingStep?) {
        guard let target, target != step else { return }
        movingForward = target.rawValue > step.rawValue
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil
        )
        withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : DCMotion.smooth) {
            step = target
        }
        UIAccessibility.post(notification: .screenChanged, argument: target.accessibilityLabel)
    }

    /// Pins the selected forums and unpins deselected ones (in list order).
    private func applyForumSelection() {
        let pinned = Set(app.pinnedForums.map(\.siteURL))
        for forum in app.pinnedForums where !selectedForums.contains(forum.siteURL) {
            app.unpin(forum)
        }
        for suggested in AppModel.suggestedForums
        where selectedForums.contains(suggested.siteURL) && !pinned.contains(suggested.siteURL) {
            app.pinSuggested(suggested)
        }
        for forum in app.forums
        where selectedForums.contains(forum.siteURL) && !forum.isPinned {
            app.pin(forum)
        }
    }

    private func finish(then action: @escaping () -> Void) {
        DCHaptics.success()
        app.saveSettings()
        app.completeOnboarding()
        app.settingsStatus = ""
        onFinish()
        action()
    }
}

/// Soft brand-tinted page background.
struct OnboardingBackdrop: View {
    var body: some View {
        ZStack {
            DCTheme.pageBackground
            GeometryReader { proxy in
                Circle()
                    .fill(Color(hex: 0x4A6BFF, opacity: 0.16))
                    .frame(width: proxy.size.width * 0.9)
                    .blur(radius: 80)
                    .offset(x: -proxy.size.width * 0.3, y: -proxy.size.height * 0.15)
                Circle()
                    .fill(Color(hex: 0xC13AE0, opacity: 0.12))
                    .frame(width: proxy.size.width * 0.8)
                    .blur(radius: 90)
                    .offset(x: proxy.size.width * 0.45, y: proxy.size.height * 0.55)
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

struct OnboardingProgressDots: View {
    let current: OnboardingStep

    var body: some View {
        HStack(spacing: 6) {
            ForEach(OnboardingStep.allCases) { step in
                Capsule()
                    .fill(step == current ? AnyShapeStyle(DCTheme.brandGradient) : AnyShapeStyle(Color.secondary.opacity(step.rawValue < current.rawValue ? 0.5 : 0.22)))
                    .frame(width: step == current ? 22 : 7, height: 7)
            }
        }
        .animation(DCMotion.spring, value: current)
        .accessibilityElement()
        .accessibilityLabel(current.accessibilityLabel)
        .accessibilityIdentifier("onboardingProgress")
    }
}

/// Clips sideways only, so sliding pages stay inside the column while the
/// scroll content still runs under the top and bottom bars.
private struct HorizontalClip: Shape {
    func path(in rect: CGRect) -> Path {
        Path(rect.insetBy(dx: 0, dy: -4_000))
    }
}
