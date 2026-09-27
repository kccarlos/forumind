import SwiftUI
import UIKit

// iPad workspace: one layout for both the side-by-side (split) and the
// single-pane arrangement, so crossing the split threshold (rotation, Split
// View, Slide Over, Stage Manager resizing) only moves views. The browser bar,
// the web view and the assistant panel keep their identity — no web view
// reload, and the panel keeps its sheets, Settings sub-page and scroll
// position.

/// Width rules for the workspace. Pure, so unit tests pin them.
enum WorkspaceMetrics {
    /// Leave split below this width (hysteresis). Enter at
    /// `DCTheme.splitLayoutMinimumWidth` (850). No iPad window class falls in
    /// 830..<850 (Pro 11 portrait is 834, Air 11 portrait 820), so a window
    /// always opens in the layout its width implies; the band only stops a
    /// Stage Manager resize near the threshold from flapping.
    static let splitExitWidth: CGFloat = 830
    /// The web page keeps at least this much room next to the panel.
    static let browserMinimumWidth: CGFloat = 460
    /// Keyboard nudge for the resize handle (VoiceOver adjust).
    static let panelWidthStep: CGFloat = 40

    /// The layout after a width change, given the current one.
    static func nextIsSplit(
        current: Bool?,
        width: CGFloat,
        idiom: UIUserInterfaceIdiom = UIDevice.current.userInterfaceIdiom
    ) -> Bool {
        guard idiom != .phone else { return false }
        switch current {
        case .none: return ContentView.usesSplitLayout(width: width, idiom: idiom)
        case .some(true): return width >= splitExitWidth
        case .some(false): return width >= DCTheme.splitLayoutMinimumWidth
        }
    }

    /// Largest panel the window allows (never below the panel minimum).
    static func maximumPanelWidth(containerWidth: CGFloat) -> CGFloat {
        max(DCTheme.panelMinimumWidth, min(DCTheme.panelMaximumWidth, containerWidth - browserMinimumWidth - 1))
    }

    /// The panel width to show: the user's width (or 40% of the window by
    /// default), clamped to 360…560 and to what the window leaves. The stored
    /// width is not rewritten, so growing the window back restores it.
    static func panelWidth(preferred: CGFloat?, containerWidth: CGFloat) -> CGFloat {
        let wanted = preferred ?? containerWidth * 0.4
        return min(maximumPanelWidth(containerWidth: containerWidth), max(DCTheme.panelMinimumWidth, wanted))
    }
}

/// Places the browser bar, the page, the assistant panel and the resize
/// handle (always these four subviews, in this order).
///
/// - Split: bar over the page column; panel on the right at full height;
///   handle on the divider.
/// - Single pane: bar across the window; the page fills the content rect and
///   the panel covers it when shown (parked off the trailing edge when not);
///   handle collapsed.
struct WorkspaceLayout: Layout {
    var isSplit: Bool
    var panelWidth: CGFloat
    var barPosition: BrowserBarPosition
    /// False while the bottom bar steps aside for the keyboard.
    var showsChrome: Bool
    /// Single pane showing the page: the panel waits just off the trailing
    /// edge (same size, so it keeps its layout and state) where it can't
    /// take the page's touches.
    var parksPanel = false

    static let dividerWidth: CGFloat = 1
    static let handleHitWidth: CGFloat = 16

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 4 else { return }
        let chrome = subviews[0], page = subviews[1], panel = subviews[2], handle = subviews[3]
        let columnWidth = isSplit ? max(0, bounds.width - panelWidth - Self.dividerWidth) : bounds.width

        let chromeSize = chrome.sizeThatFits(ProposedViewSize(width: columnWidth, height: nil))
        let chromeHeight = showsChrome ? min(chromeSize.height, bounds.height) : 0
        let chromeY: CGFloat
        if barPosition == .top {
            chromeY = showsChrome ? bounds.minY : bounds.minY - chromeSize.height
        } else {
            chromeY = showsChrome ? bounds.maxY - chromeHeight : bounds.maxY
        }
        chrome.place(
            at: CGPoint(x: bounds.minX, y: chromeY),
            proposal: ProposedViewSize(width: columnWidth, height: chromeSize.height)
        )

        let contentY = barPosition == .top ? bounds.minY + chromeHeight : bounds.minY
        let contentHeight = max(0, bounds.height - chromeHeight)
        page.place(
            at: CGPoint(x: bounds.minX, y: contentY),
            proposal: ProposedViewSize(width: columnWidth, height: contentHeight)
        )

        if isSplit {
            panel.place(
                at: CGPoint(x: bounds.minX + columnWidth + Self.dividerWidth, y: bounds.minY),
                proposal: ProposedViewSize(width: panelWidth, height: bounds.height)
            )
            handle.place(
                at: CGPoint(x: bounds.minX + columnWidth + Self.dividerWidth / 2, y: bounds.midY),
                anchor: .center,
                proposal: ProposedViewSize(width: Self.handleHitWidth, height: bounds.height)
            )
        } else {
            panel.place(
                at: CGPoint(x: parksPanel ? bounds.maxX + Self.dividerWidth : bounds.minX, y: contentY),
                proposal: ProposedViewSize(width: bounds.width, height: contentHeight)
            )
            // Off the trailing edge: its UIKit pan/pointer view must not sit
            // over the page's edge.
            handle.place(
                at: CGPoint(x: bounds.maxX + Self.handleHitWidth, y: bounds.midY),
                anchor: .center,
                proposal: ProposedViewSize(width: Self.handleHitWidth, height: bounds.height)
            )
        }
    }
}

// MARK: - Resize handle

/// The divider between the page and the assistant panel. Drag to resize,
/// double-tap to reset; the pointer shows a resize beam on hover.
struct PanelResizeHandle: View {
    let panelWidth: CGFloat
    let onDrag: (_ translation: CGFloat) -> Void
    let onDragEnded: () -> Void
    let onReset: () -> Void
    let onAdjust: (_ delta: CGFloat) -> Void
    @State private var hovering = false
    @State private var dragging = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var active: Bool { hovering || dragging }

    var body: some View {
        ZStack {
            Rectangle()
                .fill(active ? Color.accentColor.opacity(0.6) : DCTheme.border)
                .frame(width: active ? 2 : WorkspaceLayout.dividerWidth)
                .ignoresSafeArea()
            Capsule()
                .fill(active ? Color.accentColor : Color.secondary.opacity(0.35))
                .frame(width: active ? 6 : 4, height: active ? 52 : 36)
                .shadow(color: .black.opacity(active ? 0.15 : 0), radius: 3)
        }
        .frame(width: WorkspaceLayout.handleHitWidth)
        .frame(maxHeight: .infinity)
        .overlay {
            ResizeHandleInteractionView(
                onHover: { hovering = $0 },
                onBegan: { dragging = true },
                onChanged: onDrag,
                onEnded: {
                    dragging = false
                    onDragEnded()
                },
                onDoubleTap: onReset
            )
            .ignoresSafeArea()
        }
        .animation(DCMotion.respecting(reduceMotion, DCMotion.quick), value: active)
        .accessibilityElement()
        .accessibilityLabel("Assistant panel width")
        .accessibilityValue("\(Int(panelWidth)) points")
        .accessibilityHint("Swipe up or down to resize. Double-tap resets.")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onAdjust(WorkspaceMetrics.panelWidthStep)
            case .decrement: onAdjust(-WorkspaceMetrics.panelWidthStep)
            @unknown default: break
            }
        }
        .accessibilityAction(named: "Reset width", onReset)
        .accessibilityIdentifier("panelResizeHandle")
    }
}

/// UIKit pan + double-tap + hover + pointer for the handle. The pointer
/// becomes a vertical beam with left/right arrows (SwiftUI's `pointerStyle`
/// is macOS/visionOS only).
private struct ResizeHandleInteractionView: UIViewRepresentable {
    let onHover: (Bool) -> Void
    let onBegan: () -> Void
    let onChanged: (CGFloat) -> Void
    let onEnded: () -> Void
    let onDoubleTap: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isAccessibilityElement = false
        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pan(_:)))
        view.addGestureRecognizer(pan)
        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTap))
        doubleTap.numberOfTapsRequired = 2
        view.addGestureRecognizer(doubleTap)
        view.addGestureRecognizer(
            UIHoverGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.hover(_:)))
        )
        view.addInteraction(UIPointerInteraction(delegate: context.coordinator))
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.parent = self
    }

    final class Coordinator: NSObject, UIPointerInteractionDelegate {
        var parent: ResizeHandleInteractionView

        init(_ parent: ResizeHandleInteractionView) { self.parent = parent }

        @objc func pan(_ recognizer: UIPanGestureRecognizer) {
            switch recognizer.state {
            case .began:
                parent.onBegan()
            case .changed:
                parent.onChanged(recognizer.translation(in: recognizer.view?.window).x)
            case .ended, .cancelled, .failed:
                parent.onEnded()
            default:
                break
            }
        }

        @objc func doubleTap() { parent.onDoubleTap() }

        @objc func hover(_ recognizer: UIHoverGestureRecognizer) {
            switch recognizer.state {
            case .began: parent.onHover(true)
            case .ended, .cancelled, .failed: parent.onHover(false)
            default: break
            }
        }

        func pointerInteraction(_ interaction: UIPointerInteraction, styleFor region: UIPointerRegion) -> UIPointerStyle? {
            let style = UIPointerStyle(shape: .verticalBeam(length: 28), constrainedAxes: [.vertical])
            style.accessories = [.arrow(.left), .arrow(.right)]
            return style
        }
    }
}

// MARK: - Keyboard commands

/// Menu-bar / ⌘-hold commands. They reach the window's ContentView through
/// a notification (one scene), which owns the pane and address-bar state.
enum WorkspaceCommand: String {
    case focusAddress, reload, back, forward, forumsHome, settings
    case summary, chat, agent
}

extension Notification.Name {
    static let dcWorkspaceCommand = Notification.Name("dcWorkspaceCommand")
}

extension WorkspaceCommand {
    func post() {
        NotificationCenter.default.post(name: .dcWorkspaceCommand, object: nil, userInfo: ["command": rawValue])
    }

    init?(_ notification: Notification) {
        guard let raw = notification.userInfo?["command"] as? String else { return nil }
        self.init(rawValue: raw)
    }
}

/// Static on purpose: observing the app or browser here rebuilds the main
/// menu on every published change (page progress, scrolling), and key
/// commands stop firing while it rebuilds. `ContentView.perform` ignores
/// commands that don't apply.
struct WorkspaceCommands: Commands {

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { WorkspaceCommand.settings.post() }
                .keyboardShortcut(",", modifiers: .command)
        }
        CommandMenu("Browser") {
            Group {
                Button("Open Location") { WorkspaceCommand.focusAddress.post() }
                    .keyboardShortcut("l", modifiers: .command)
                Button("Reload Page") { WorkspaceCommand.reload.post() }
                    .keyboardShortcut("r", modifiers: .command)
                Divider()
                Button("Back") { WorkspaceCommand.back.post() }
                    .keyboardShortcut("[", modifiers: .command)
                Button("Forward") { WorkspaceCommand.forward.post() }
                    .keyboardShortcut("]", modifiers: .command)
                Divider()
                Button("All Forums") { WorkspaceCommand.forumsHome.post() }
                    .keyboardShortcut("h", modifiers: [.command, .shift])
            }
        }
        CommandMenu("Assistant") {
            Group {
                Button("Summary") { WorkspaceCommand.summary.post() }
                    .keyboardShortcut("1", modifiers: .command)
                Button("Chat") { WorkspaceCommand.chat.post() }
                    .keyboardShortcut("2", modifiers: .command)
                Button("Ask the Forum") { WorkspaceCommand.agent.post() }
                    .keyboardShortcut("3", modifiers: .command)
            }
        }
    }
}

// MARK: - Sheets on iPad

extension View {
    /// Esc (cancel action) on a back/close button when `enabled`.
    @ViewBuilder
    func dcCancelShortcut(_ enabled: Bool = true) -> some View {
        if enabled {
            keyboardShortcut(.cancelAction)
        } else {
            self
        }
    }
}

extension View {
    /// ⌘Return on a composer's send button (only one per screen at a time).
    @ViewBuilder
    func dcSendShortcut(_ enabled: Bool = true) -> some View {
        if enabled {
            keyboardShortcut(.return, modifiers: .command)
        } else {
            self
        }
    }
}

extension View {
    /// Form-sheet sizing on iPad (a centered card sized to its content, not
    /// a huge empty page). Detents still apply on iPhone.
    @ViewBuilder
    func dcFormSheet() -> some View {
        if #available(iOS 18.0, *) {
            presentationSizing(.form)
        } else {
            self
        }
    }
}

// MARK: - DEBUG window-width simulation

#if DEBUG
/// `-dc-force-width <pt>` letterboxes the app to that width (with the size
/// class a real Split View / Slide Over window of that width gets), so each
/// multitasking width can be screenshotted. `-dc-resize-demo [w1,w2,…]`
/// animates the width through the list (default 1032 → 800 → 1032 → 700 →
/// full), 6 s per step, to check state survives crossing the threshold.
struct DebugWindowWidth: ViewModifier {
    @State private var width: CGFloat? = DebugWindowWidth.forcedWidth

    static var forcedWidth: CGFloat? {
        AssistantDebug.value("-dc-force-width").flatMap(Double.init).map { CGFloat($0) }
    }

    static var demoWidths: [CGFloat]? {
        guard AssistantDebug.has("-dc-resize-demo") else { return nil }
        let custom = AssistantDebug.value("-dc-resize-demo")?
            .split(separator: ",")
            .compactMap { Double($0) }
            .map { CGFloat($0) } ?? []
        return custom.isEmpty ? [1_032, 800, 1_032, 700, 0] : custom
    }

    static var isActive: Bool { forcedWidth != nil || demoWidths != nil }

    func body(content: Content) -> some View {
        if Self.isActive {
            GeometryReader { proxy in
                let shown = min(width.map { $0 > 0 ? $0 : proxy.size.width } ?? proxy.size.width, proxy.size.width)
                content
                    .frame(width: shown)
                    .environment(\.horizontalSizeClass, shown < 600 ? .compact : .regular)
                    .frame(maxWidth: .infinity)
            }
            .background(Color.black.ignoresSafeArea())
            .task {
                guard let steps = Self.demoWidths else { return }
                try? await Task.sleep(for: .seconds(6))
                for step in steps {
                    // Unanimated, like a window resize (the system animates those).
                    width = step
                    print("DC-RESIZE-DEMO width=\(step)")
                    try? await Task.sleep(for: .seconds(6))
                }
            }
        } else {
            content
        }
    }
}
#endif
