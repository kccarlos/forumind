import Combine
import SwiftUI

// MARK: - iPhone AI drawer
//
// A system sheet over the page with three heights: peek (header and one
// line), medium (the page stays scrollable and tappable) and large. It shows
// on web pages, never on the Forums home, and opens from the bar's AI button.
// A swipe down from the peek closes it; from medium or large it only goes
// down a height. While it is up, every root presentation is hosted inside it
// (PresentationRouter.swift), so it comes back at the same height after each.

struct AIDrawerModifier: ViewModifier {
    @ObservedObject var app: AppModel
    @ObservedObject var router: PresentationRouter
    let onOpenURL: (URL) -> Void
    let onForumAdded: (Forum) -> Void

    init(
        app: AppModel,
        onOpenURL: @escaping (URL) -> Void,
        onForumAdded: @escaping (Forum) -> Void
    ) {
        self.app = app
        router = app.router
        self.onOpenURL = onOpenURL
        self.onForumAdded = onForumAdded
    }

    private var isPresented: Binding<Bool> {
        Binding(
            get: { router.drawerPhase.isPresented },
            set: { shown in
                // A swipe down from the peek (SwiftUI also writes false when
                // the app closes it: the phase has moved on already then).
                if !shown, router.drawerPhase.isPresented {
                    router.wantsDrawer = false
                    router.dismissDrawer()
                }
            }
        )
    }

    func body(content: Content) -> some View {
        // Not onDisappear: a full-screen cover over the drawer hides its
        // content too, and the host must stay active under it.
        content.sheet(isPresented: isPresented, onDismiss: {
            router.drawerDismissed()
            // Reopened while it was still closing.
            app.syncDrawer()
        }) {
            AIDrawerContent(app: app, router: router, onOpenURL: onOpenURL)
                .modifier(RouterHost(
                    app: app,
                    active: router.drawerHostIsActive,
                    onForumAdded: onForumAdded
                ))
                .presentationDetents(
                    Set(DrawerDetent.allCases.map(\.presentationDetent)),
                    selection: $router.drawerDetentSelection
                )
                .presentationBackgroundInteraction(.enabled(upThrough: .medium))
                .presentationDragIndicator(.visible)
                .interactiveDismissDisabled(router.drawerDetent != .peek)
                .onAppear {
                    #if DEBUG
                    if AIDrawerDebug.dropsThisPresentation() { return }
                    #endif
                    router.drawerAppeared()
                }
        }
    }
}

extension AppModel {
    /// The drawer shows on web pages, not on the Forums home.
    var isDrawerAvailable: Bool {
        router.usesDrawer && !browser.showsForumsHome
    }

    /// Presents or closes the drawer to match the request, but only while no
    /// root presentation is up: the router host moves with the drawer, so
    /// moving it under a live sheet would close that sheet. While it is on
    /// its way in or out, the sheet's callbacks (or the router's watchdog)
    /// come back here.
    func syncDrawer() {
        guard rootPresentation == nil else { return }
        let wanted = router.wantsDrawer && isDrawerAvailable
        switch router.drawerPhase {
        case .closed where wanted: router.presentDrawer()
        case .presenting where !wanted, .shown where !wanted: router.dismissDrawer()
        default: break
        }
    }

    /// The first topic ever opened shows the drawer once at its peek.
    func showFirstTopicPeekIfNeeded() {
        guard router.usesDrawer, !router.wantsDrawer, isDrawerAvailable else { return }
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: PresentationRouter.firstTopicPeekKey) else { return }
        defaults.set(true, forKey: PresentationRouter.firstTopicPeekKey)
        router.openDrawer(at: .peek)
    }
}

/// Keeps the drawer in step with the page, the request and the root
/// presentations, and resets the mode for a new topic. On the root view.
struct AIDrawerCoordinator: ViewModifier {
    @ObservedObject var app: AppModel
    @ObservedObject var router: PresentationRouter

    init(app: AppModel) {
        self.app = app
        router = app.router
    }

    func body(content: Content) -> some View {
        content
            // A new topic opens on its Summary, unless the mode was picked
            // for it in the same update (a shared "Chat" link). Here, not in
            // the panel: on iPhone the panel only exists while the drawer is up.
            .onChange(of: TopicMode(topicKey: app.currentTopic?.topicKey, mode: app.assistantMode)) { old, new in
                guard old.topicKey != new.topicKey else { return }
                if new.mode != .agent, old.mode == new.mode { app.assistantMode = .summary }
                if new.topicKey != nil { app.showFirstTopicPeekIfNeeded() }
            }
            // A citation or solved-hint jump landed (§4.5).
            .sensoryFeedback(.selection, trigger: app.citationJump)
            .onChange(of: router.wantsDrawer) { app.syncDrawer() }
            // Closed again by the watchdog (a dropped presentation): retry.
            .onChange(of: router.drawerPhase) { app.syncDrawer() }
            .onChange(of: app.rootPresentation?.id) { app.syncDrawer() }
            // The browser's and the controllers' changes don't re-render the
            // root, and arrive before the value lands: look once it has.
            .onReceive(
                app.browser.$isForumsHomeRequested
                    .combineLatest(app.browser.$currentURL.map { $0 == nil })
                    .map { $0 || $1 }
                    .removeDuplicates()
            ) { _ in
                Task { @MainActor in
                    // Leaving for Home closes the drawer; leaving Home pops
                    // the pages pushed over it.
                    if app.browser.showsForumsHome { router.closeDrawer() }
                    app.homeVisibilityChanged()
                    app.syncDrawer()
                }
            }
            .onReceive(app.voice.$consentProvider) { _ in Task { @MainActor in app.syncDrawer() } }
            .onReceive(app.podcast.$consentProvider) { _ in Task { @MainActor in app.syncDrawer() } }
            .onReceive(app.aiConsent.$queue) { _ in Task { @MainActor in app.syncDrawer() } }
    }

    private struct TopicMode: Equatable {
        let topicKey: String?
        let mode: AssistantMode
    }
}

private struct AIDrawerContent: View {
    @ObservedObject var app: AppModel
    @ObservedObject var router: PresentationRouter
    let onOpenURL: (URL) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        AssistantPanel(
            app: app,
            // Post & responses opens as a sheet over the drawer.
            onExpand: { route in app.router.item = .expanded(route) },
            onOpenURL: onOpenURL,
            drawerDetent: router.drawerDetent
        )
        .environment(\.composerFocusChanged, ComposerFocusAction { focused in
            // Never cover the keyboard.
            if focused { setDetent(.large) }
        })
        // Manage and Settings need the room.
        .onChange(of: app.panelRoute, initial: true) {
            if app.panelRoute != .topic { setDetent(.large) }
        }
        // VoiceOver's escape (two-finger scrub) closes the drawer.
        .accessibilityElement(children: .contain)
        .accessibilityAction(.escape) { router.closeDrawer() }
        #if DEBUG
        .overlay(alignment: .topLeading) { DrawerDebugState(router: router) }
        #endif
    }

    private func setDetent(_ detent: DrawerDetent) {
        guard router.drawerDetent != detent else { return }
        withAnimation(DCMotion.respecting(reduceMotion, DCMotion.smooth)) { router.drawerDetent = detent }
    }
}

#if DEBUG
/// The drawer's height as an accessibility element for UI tests
/// (`drawerState`, label `detent=<peek|medium|large>`).
private struct DrawerDebugState: View {
    @ObservedObject var router: PresentationRouter

    var body: some View {
        let state = "detent=\(router.drawerDetent.rawValue)"
        Text(verbatim: state)
            .font(.system(size: 2))
            .frame(width: 4, height: 4)
            .opacity(0.02)
            .allowsHitTesting(false)
            .accessibilityLabel(Text(verbatim: state))
            .accessibilityIdentifier("drawerState")
    }
}
#endif

#if DEBUG
/// `-dc-drawer-drop-first`: the first presentation's content never reports
/// it appeared, as when UIKit drops a presentation (UI tests of the watchdog).
enum AIDrawerDebug {
    private static var dropped = false

    static func dropsThisPresentation() -> Bool {
        guard AssistantDebug.has("-dc-drawer-drop-first"), !dropped else { return false }
        dropped = true
        return true
    }
}
#endif
