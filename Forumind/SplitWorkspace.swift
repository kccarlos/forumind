import SwiftUI

// MARK: - iPad split layout (spec §10)
//
// Windows 850 pt and wider: the page on the left, the AI panel on the right
// (360–560 pt, draggable), under one top bar (PhoneBrowser with a
// `SplitBarContext`): forum avatar, back, forward | address capsule | mic,
// ···, hide/show AI panel. The panel is the drawer's content (AssistantPanel),
// so there is one implementation for both hosts.

/// The split top bar's extras.
struct SplitBarContext {
    let panelShown: Bool
    let togglePanel: () -> Void
}

/// Back and forward in the split top bar.
struct SplitNavigationButtons: View {
    @ObservedObject var browser: ForumBrowserModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button {
            withAnimation(DCMotion.respecting(reduceMotion)) { browser.navigateBack() }
        } label: {
            Image(systemName: "chevron.backward")
        }
        .buttonStyle(DCIconButtonStyle())
        .disabled(!browser.canNavigateBack)
        .accessibilityLabel("Back")
        .accessibilityIdentifier("browserBack")
        Button {
            browser.goForward()
        } label: {
            Image(systemName: "chevron.forward")
        }
        .buttonStyle(DCIconButtonStyle())
        .disabled(!browser.canGoForward || browser.showsForumsHome)
        .accessibilityLabel("Forward")
        .accessibilityIdentifier("browserForward")
    }
}

/// The split top bar's `···`: what the forum menu leaves out (the forum
/// home, account, reload and share live there).
struct SplitMoreMenu: View {
    @ObservedObject var app: AppModel
    @ObservedObject var browser: ForumBrowserModel
    let actions: BrowserActions

    var body: some View {
        Menu {
            Section {
                Button(action: actions.showForumsHome) {
                    Label("All Forums", systemImage: "square.grid.2x2")
                }
                Button(action: actions.addForum) {
                    Label("Add Forum…", systemImage: "plus")
                }
            }
            Section {
                Button { actions.openPanel(.history) } label: {
                    Label("History", systemImage: "clock.arrow.circlepath")
                }
                Button { actions.openPanel(.settings) } label: {
                    Label("Settings", systemImage: "gearshape")
                }
            }
            if let topic = browser.pageContext.topic, !browser.showsForumsHome {
                Section {
                    if ReadingLanguage.isTranslationAvailable {
                        Button(action: actions.translatePosts) {
                            Label("Translate Posts on Screen", systemImage: "translate")
                        }
                        .accessibilityIdentifier("menuTranslatePosts")
                    }
                    Button { actions.report(topic) } label: {
                        Label("Report or block…", systemImage: "flag")
                    }
                    .accessibilityIdentifier("menuReportOrBlock")
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .frame(width: DCTheme.controlHeight, height: DCTheme.controlHeight)
                .contentShape(Rectangle())
        }
        .menuOrder(.fixed)
        .accessibilityLabel("More browser actions")
        .accessibilityIdentifier("browserMoreMenu")
    }
}

/// Hide or show the AI panel (⌥⌘0), with the AI button's research ring and
/// new-replies dot (the split layout has no hint row).
struct SplitPanelToggle: View {
    @ObservedObject var app: AppModel
    let isShown: Bool
    let action: () -> Void

    private var showsNewRepliesDot: Bool { app.showsNewRepliesDot }

    /// "Hidden, New replies, Ask the forum is searching": what the ring and
    /// the dot show.
    private var accessibilityValue: String {
        var parts = [isShown ? String(localized: "Shown") : String(localized: "Hidden")]
        if showsNewRepliesDot {
            parts.append(String(localized: "New replies", comment: "Accessibility value of the iPhone AI button while its dot says the topic has new replies"))
        }
        if app.activeResearch != nil {
            parts.append(String(localized: "Ask the forum is searching", comment: "Accessibility value of the AI panel toggle while its ring shows an Ask the forum search running"))
        } else if app.readyAnswer != nil {
            parts.append(String(localized: "Answer ready", comment: "AI drawer status row: an Ask the forum answer finished"))
        }
        return parts.joined(separator: ", ")
    }

    var body: some View {
        Button {
            DCHaptics.tap()
            action()
        } label: {
            Image(systemName: "sidebar.trailing")
                .symbolVariant(isShown ? .fill : .none)
                .foregroundStyle(isShown ? AnyShapeStyle(DCTheme.brandGradient) : AnyShapeStyle(.primary))
        }
        .buttonStyle(DCIconButtonStyle())
        .overlay { ResearchRing(app: app) }
        .overlay(alignment: .topTrailing) {
            if showsNewRepliesDot { NewRepliesDot() }
        }
        .accessibilityLabel(isShown ? Text("Hide AI panel") : Text("Show AI panel"))
        .accessibilityValue(Text(verbatim: accessibilityValue))
        .accessibilityIdentifier("aiPanelToggle")
    }
}

/// The window's content: the page under the bar, with the AI panel beside
/// it in the split layout. One view for both layouts, so the web view keeps
/// its place when the width crosses the threshold.
struct WorkspaceView: View {
    @ObservedObject var app: AppModel
    @ObservedObject var browser: ForumBrowserModel
    @ObservedObject var router: PresentationRouter
    let width: CGFloat
    let actions: BrowserActions
    let addressFocusRequest: Int
    let onOpenURL: (URL) -> Void
    /// The panel's width: what the reader chose with the handle (0 = 40% of
    /// the window).
    @AppStorage("dc.assistantPanelWidth") private var storedWidth: Double = 0
    @State private var dragStartWidth: CGFloat?
    @State private var dragWidth: CGFloat?
    @State private var dropTargeted = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isSplit: Bool { router.splitLayout ?? ContentView.usesSplitLayout(width: width) }

    private var panelVisible: Bool {
        isSplit && router.splitPanelMode.isVisible(onHome: browser.showsForumsHome)
    }

    private var panelWidth: CGFloat {
        WorkspaceMetrics.panelWidth(
            preferred: dragWidth ?? (storedWidth > 0 ? CGFloat(storedWidth) : nil),
            containerWidth: width
        )
    }

    var body: some View {
        let split = isSplit
        let showsPanel = panelVisible
        let showsWebView = !browser.showsForumsHome
        PhoneBrowser(
            app: app,
            browser: browser,
            voice: app.voice,
            position: split ? .top : app.settings.browserBarPosition.resolved(isSplit: false),
            actions: actions,
            addressFocusRequest: addressFocusRequest,
            width: width,
            split: split ? SplitBarContext(panelShown: showsPanel, togglePanel: app.toggleAIView) : nil
        ) {
            HStack(spacing: 0) {
                BrowserContent(
                    app: app,
                    browser: browser,
                    voice: app.voice,
                    actions: actions,
                    webViewIgnoresBottomSafeArea: showsWebView,
                    dockFloatsTrailing: split && !showsPanel
                )
                .ignoresSafeArea(.keyboard, edges: showsWebView ? .bottom : [])
                .frame(maxWidth: .infinity)
                if showsPanel { panel }
            }
        }
    }

    @ViewBuilder
    private var panel: some View {
        let current = panelWidth
        PanelResizeHandle(
            panelWidth: current,
            onDrag: { translation in
                let start = dragStartWidth ?? current
                dragStartWidth = start
                // The panel is on the right: dragging left widens it.
                dragWidth = WorkspaceMetrics.panelWidth(preferred: start - translation, containerWidth: width)
            },
            onDragEnded: {
                if let dragWidth { storedWidth = Double(dragWidth) }
                dragWidth = nil
                dragStartWidth = nil
            },
            // Width changes are not animated: animating a List's width (the
            // Forums home) can loop UICollectionView self-sizing.
            onReset: { storedWidth = 0 },
            onAdjust: { delta in
                storedWidth = Double(WorkspaceMetrics.panelWidth(preferred: current - delta, containerWidth: width))
            }
        )
        AssistantPanel(
            app: app,
            // Post & responses opens as a sheet, like in the drawer.
            onExpand: { route in app.router.item = .expanded(route) },
            onOpenURL: onOpenURL
        )
        .frame(width: current)
        .background(DCTheme.pageBackground)
        // A forum link dropped on the panel: summarize it.
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first, ForumBrowserModel.isBrowsableURL(url) else { return false }
            app.openShared(url: url, action: "summary")
            return true
        } isTargeted: { dropTargeted = $0 }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: DCTheme.cardCornerRadius, style: .continuous)
                    .strokeBorder(DCTheme.brandBlue, lineWidth: 3)
                    .background(.regularMaterial.opacity(0.6), in: RoundedRectangle(cornerRadius: DCTheme.cardCornerRadius, style: .continuous))
                    .overlay {
                        Label("Summarize this link", systemImage: "link")
                            .font(.headline)
                            .foregroundStyle(DCTheme.brandBlue)
                    }
                    .padding(DCTheme.spacingS)
                    .allowsHitTesting(false)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("aiPanel")
    }
}
