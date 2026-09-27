import SwiftUI
import UIKit

final class ShareSheetModel: ObservableObject {
    enum Phase: Equatable {
        case loading
        case ready(SharedPage)
        case handingOff(SharedPage, IncomingLinkRequest.Action)
        case saved(SharedPage)
        case failed(SharedPage)
        case unsupported
    }

    @Published var phase: Phase = .loading
    var onChoose: (IncomingLinkRequest.Action) -> Void = { _ in }
    var onCancel: () -> Void = {}

    var page: SharedPage? {
        switch phase {
        case .ready(let page), .handingOff(let page, _), .saved(let page), .failed(let page):
            return page
        case .loading, .unsupported:
            return nil
        }
    }
}

struct ShareSheetView: View {
    @ObservedObject var model: ShareSheetModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    PageCard(page: model.page, isLoading: model.phase == .loading)

                    switch model.phase {
                    case .unsupported:
                        MessageRow(
                            symbol: "link.badge.plus",
                            tint: .secondary,
                            title: "Nothing to open",
                            detail: "Share a web page or link to open it in Forumind."
                        )
                    case .saved:
                        MessageRow(
                            symbol: "checkmark.circle.fill",
                            tint: .green,
                            title: "Saved — open Forumind to continue",
                            detail: "Your page will be waiting when the app opens."
                        )
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    case .failed:
                        MessageRow(
                            symbol: "exclamationmark.triangle.fill",
                            tint: .orange,
                            title: "Couldn't hand off this page",
                            detail: "Open Forumind and paste the link in the address bar."
                        )
                    case .loading, .ready, .handingOff:
                        actions
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 24)
                .animation(.snappy, value: model.phase)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Forumind")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: model.onCancel)
                        .disabled(isSaved)
                }
                if case .failed = model.phase {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done", action: model.onCancel)
                    }
                }
            }
        }
    }

    private var isSaved: Bool {
        if case .saved = model.phase { return true }
        return false
    }

    private var busyAction: IncomingLinkRequest.Action? {
        if case .handingOff(_, let action) = model.phase { return action }
        return nil
    }

    private var actions: some View {
        VStack(spacing: 10) {
            ForEach(ShareAction.all) { action in
                Button {
                    model.onChoose(action.kind)
                } label: {
                    ShareActionLabel(action: action, isBusy: busyAction == action.kind)
                }
                .buttonStyle(ShareActionButtonStyle(prominent: action.kind == .summary))
                .disabled(model.page == nil || busyAction != nil)
                .accessibilityIdentifier("share.\(action.kind.rawValue)")
            }
        }
    }
}

// MARK: - Page card

private struct PageCard: View {
    let page: SharedPage?
    let isLoading: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                AppGlyph()
                VStack(alignment: .leading, spacing: 3) {
                    Text(page?.displayTitle ?? "Reading page…")
                        .font(.headline)
                        .foregroundStyle(page == nil ? .secondary : .primary)
                        .lineLimit(3)
                        .redacted(reason: page == nil && isLoading ? .placeholder : [])
                    if let page {
                        Label(page.host, systemImage: page.url.scheme == "https" ? "lock.fill" : "globe")
                            .labelStyle(HostLabelStyle())
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }

            if let page {
                DetectionBadge(detection: page.detection)
            } else if isLoading {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Checking page…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color(uiColor: .secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 20, style: .continuous)
        )
        .accessibilityElement(children: .combine)
    }
}

private struct HostLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.imageScale(.small)
            configuration.title
        }
    }
}

private struct AppGlyph: View {
    @ScaledMetric(relativeTo: .headline) private var size: CGFloat = 48

    var body: some View {
        Group {
            if let icon = UIImage(named: "AppIcon") {
                Image(uiImage: icon)
                    .resizable()
                    .interpolation(.high)
            } else {
                ZStack {
                    LinearGradient(
                        colors: [.indigo, .blue],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    Image(systemName: "bubble.left.and.text.bubble.right.fill")
                        .font(.system(size: size * 0.45, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.225, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
                .stroke(Color.primary.opacity(0.08))
        }
        .accessibilityHidden(true)
    }
}

private struct DetectionBadge: View {
    let detection: SharedPage.Detection

    var body: some View {
        Label {
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol)
        }
        .font(.footnote.weight(.medium))
        .foregroundStyle(tint)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(tint.opacity(0.12), in: Capsule())
    }

    private var text: String {
        switch detection {
        case .discourse(let forumName):
            return "Discourse forum detected · \(forumName)"
        case .notDetected:
            return "Couldn't confirm this is a Discourse forum"
        case .unknown:
            return "Discourse forum? Forumind will check when it opens"
        }
    }

    private var symbol: String {
        switch detection {
        case .discourse: return "checkmark.seal.fill"
        case .notDetected: return "exclamationmark.circle.fill"
        case .unknown: return "questionmark.circle.fill"
        }
    }

    private var tint: Color {
        switch detection {
        case .discourse: return .green
        case .notDetected: return .orange
        case .unknown: return .secondary
        }
    }
}

// MARK: - Actions

private struct ShareAction: Identifiable {
    let kind: IncomingLinkRequest.Action
    let title: String
    let detail: String
    let symbol: String
    let tint: Color

    var id: String { kind.rawValue }

    static let all: [ShareAction] = [
        ShareAction(
            kind: .summary,
            title: "Summarize",
            detail: "Key points of this topic",
            symbol: "sparkles",
            tint: .indigo
        ),
        ShareAction(
            kind: .chat,
            title: "Chat about it",
            detail: "Ask questions about this page",
            symbol: "bubble.left.and.bubble.right.fill",
            tint: .blue
        ),
        ShareAction(
            kind: .agent,
            title: "Ask the forum",
            detail: "Research across the whole forum",
            symbol: "text.magnifyingglass",
            tint: .teal
        ),
        ShareAction(
            kind: .open,
            title: "Just open",
            detail: "Open it in the Forumind browser",
            symbol: "safari.fill",
            tint: .gray
        )
    ]
}

private struct ShareActionLabel: View {
    let action: ShareAction
    let isBusy: Bool
    @ScaledMetric(relativeTo: .body) private var iconSize: CGFloat = 38

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: iconSize * 0.3, style: .continuous)
                    .fill(action.tint.gradient)
                Image(systemName: action.symbol)
                    .font(.system(size: iconSize * 0.45, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: iconSize, height: iconSize)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(action.title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(action.detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.leading)

            Spacer(minLength: 8)

            if isBusy {
                ProgressView()
            } else {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct ShareActionButtonStyle: ButtonStyle {
    let prominent: Bool
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                Color(uiColor: .secondarySystemGroupedBackground),
                in: RoundedRectangle(cornerRadius: 18, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(prominent ? Color.accentColor.opacity(0.35) : Color.primary.opacity(0.06))
            }
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1) : 0.55)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}

// MARK: - Messages

private struct MessageRow: View {
    let symbol: String
    let tint: Color
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(
            Color(uiColor: .secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 20, style: .continuous)
        )
        .accessibilityElement(children: .combine)
    }
}
