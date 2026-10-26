import SwiftUI

/// The current list (`AppModel.browseCursor`) as numbered cards over the
/// page: search hits, research sources or focused posts. A horizontal strip
/// at the bottom of the page, so it never covers the browser bar (top or
/// bottom) or the post a jump lands on (shown at the top of the page).
/// While the bar is minimized (the reader is scrolling) it shrinks to a
/// small "N results" chip; tapping the chip brings both back.
struct ResultCardsOverlay: View {
    @ObservedObject var app: AppModel
    @ObservedObject var browser: ForumBrowserModel
    @ObservedObject var voice: VoiceController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var cursor: BrowseCursor { app.browseCursor }

    /// Collapsed by the user, or while the bar is minimized.
    private var showsChip: Bool {
        cursor.cards == .collapsed || (cursor.cards == .expanded && browser.isChromeMinimized)
    }

    private var tint: Color { cursor.tint }

    var body: some View {
        Group {
            if cursor.cards == .hidden || cursor.isEmpty {
                EmptyView()
            } else if showsChip {
                chip
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
            } else {
                strip
                    .transition(DCMotion.slide(.bottom, reduceMotion: reduceMotion))
            }
        }
        .animation(DCMotion.respecting(reduceMotion, DCMotion.spring), value: showsChip)
        .animation(DCMotion.respecting(reduceMotion, DCMotion.spring), value: cursor.cards)
    }

    private var countLabel: String { cursor.countLabel }

    // MARK: Strip

    /// The card the strip is on: the cursor's, and a settled swipe moves it.
    private var stripPosition: Binding<Int?> {
        Binding(
            get: { cursor.index },
            set: { index in
                guard let index, index != cursor.index, cursor.items.indices.contains(index) else { return }
                Task { await app.openCard(index, includeContent: false) }
            }
        )
    }

    private var strip: some View {
        VStack(alignment: .leading, spacing: DCTheme.spacingXS) {
            header
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: DCTheme.spacingS) {
                    ForEach(Array(cursor.items.enumerated()), id: \.element.id) { index, item in
                        ResultCard(
                            number: index + 1,
                            count: cursor.items.count,
                            item: item,
                            isCurrent: cursor.index == index,
                            tint: tint
                        ) {
                            Task { await app.openCard(index, includeContent: false) }
                        }
                        .id(index)
                    }
                }
                .scrollTargetLayout()
                .padding(.horizontal, DCTheme.spacingS)
                .padding(.bottom, DCTheme.spacingS)
            }
            // The strip follows the current card (next, previous, voice); a
            // swipe that settles on another card opens it and the page jumps.
            .scrollPosition(id: stripPosition, anchor: .center)
            .scrollTargetBehavior(.viewAligned)
            // Only as tall as a card (an overlay offers the whole page).
            .fixedSize(horizontal: false, vertical: true)
            .modifier(NoScrollEdgeEffect())
            if voice.isActive {
                Text("Say “next” or swipe", comment: "Result cards while voice runs: how to move to the next card")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, DCTheme.spacingM)
                    .padding(.bottom, DCTheme.spacingS)
            }
        }
        .sensoryFeedback(.selection, trigger: cursor.index)
        .frame(maxWidth: DCTheme.contentMaxWidth)
        // Content, not glass: opaque.
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: DCTheme.cardCornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: DCTheme.cardCornerRadius, style: .continuous)
                .stroke(DCTheme.border)
        }
        .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
        // Swipe down to dismiss (the cards scroll sideways).
        .simultaneousGesture(
            DragGesture(minimumDistance: 24).onEnded { value in
                let vertical = value.translation.height
                if vertical > 40, abs(vertical) > abs(value.translation.width) {
                    app.dismissResultCards()
                }
            }
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("resultCards")
        .accessibilityAction(named: Text("Dismiss")) { app.dismissResultCards() }
    }

    private var header: some View {
        HStack(spacing: 0) {
            Text(countLabel)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.leading, DCTheme.spacingM)
                .accessibilityAddTraits(.isHeader)
            if let position = cursor.index {
                Text(verbatim: " · \(position + 1)/\(cursor.items.count)")
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            Spacer(minLength: DCTheme.spacingXS)
            Button {
                Task { await app.previous() }
            } label: {
                Image(systemName: "chevron.left").font(.subheadline.weight(.semibold))
            }
            .buttonStyle(DCIconButtonStyle())
            .disabled(!cursor.hasPrevious)
            .accessibilityLabel(Text("Previous result", comment: "Result cards over the page: open the previous card"))
            .accessibilityIdentifier("resultCardsPrevious")
            Button {
                Task { await app.next() }
            } label: {
                Image(systemName: "chevron.right").font(.subheadline.weight(.semibold))
            }
            .buttonStyle(DCIconButtonStyle())
            .disabled(!cursor.hasNext)
            .accessibilityLabel(Text("Next result", comment: "Result cards over the page: open the next card"))
            .accessibilityIdentifier("resultCardsNext")
            if !dynamicTypeSize.isAccessibilitySize {
                Button {
                    app.setResultCardsCollapsed(true)
                } label: {
                    Image(systemName: "chevron.down").font(.subheadline.weight(.semibold))
                }
                .buttonStyle(DCIconButtonStyle())
                .accessibilityLabel(Text("Minimize results", comment: "Result cards over the page: shrink them to a small chip"))
                .accessibilityIdentifier("resultCardsCollapse")
            }
            Button {
                app.dismissResultCards()
            } label: {
                Image(systemName: "xmark").font(.caption.weight(.bold))
            }
            .buttonStyle(DCIconButtonStyle())
            .accessibilityLabel("Close")
            .accessibilityIdentifier("resultCardsClose")
        }
        .padding(.trailing, DCTheme.spacingXS)
    }

    // MARK: Chip

    private var chip: some View {
        Button {
            browser.expandChrome()
            app.setResultCardsCollapsed(false)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "rectangle.stack")
                    .imageScale(.small)
                    .accessibilityHidden(true)
                Text(countLabel)
                if let position = cursor.index {
                    Text(verbatim: "\(position + 1)/\(cursor.items.count)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
            }
            .font(.footnote.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, DCTheme.spacingM)
            .frame(minHeight: 36)
            .background(.regularMaterial, in: Capsule())
            .overlay { Capsule().stroke(DCTheme.border) }
            .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .hoverEffect(.lift)
        .accessibilityHint(Text("Shows the result cards", comment: "Accessibility hint of the collapsed result cards chip"))
        .accessibilityIdentifier("resultCardsChip")
    }
}

extension BrowseCursor {
    /// "3 results", "4 sources", "5 posts".
    var countLabel: String {
        let count = items.count
        switch origin {
        case .research, .sources:
            return String(localized: "\(count) sources")
        case .focus:
            return String(localized: "\(count) posts")
        case .search, .none:
            return String(localized: "\(count) results", comment: "Result cards over the page: the number of search results")
        }
    }

    /// "4 sources · 2/4": the cards as a chip in the AI drawer's status row
    /// (under the drawer the strip would be hidden).
    var chipLabel: String {
        guard let index else { return countLabel }
        return "\(countLabel) · \(index + 1)/\(items.count)"
    }

    /// The cards show in the drawer's status row: a list the reader has not
    /// dismissed.
    var showsInDrawer: Bool { cards != .hidden && !isEmpty }

    var tint: Color {
        switch origin {
        case .research, .sources: DCTheme.agentTint
        case .search, .focus, .none: DCTheme.brandBlue
        }
    }
}

/// The system's soft scroll edge (iOS 26) would fade the cards' lower lines.
private struct NoScrollEdgeEffect: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.scrollEdgeEffectHidden(true, for: .all)
        } else {
            content
        }
    }
}

/// One numbered card: title, post number and author, one line of text.
private struct ResultCard: View {
    let number: Int
    let count: Int
    let item: BrowseItem
    let isCurrent: Bool
    let tint: Color
    let action: () -> Void
    // Plain (not vibrant) secondary text: over the material the vibrant
    // style all but disappears.

    private var detail: String {
        switch (item.postNumber, item.username) {
        case let (post?, name?) where !name.isEmpty:
            String(localized: "Post \(post) · \(name)", comment: "Result card: the post number, then its author's username")
        case let (post?, _):
            String(localized: "Post \(post)", comment: "Accessibility value of an Ask the forum source that is one post of a topic; the number is the post number")
        default:
            String(localized: "Whole topic", comment: "Result card for a source that is a whole topic, not one post")
        }
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(verbatim: "\(number)")
                        .font(.caption2.weight(.bold).monospacedDigit())
                        .foregroundStyle(isCurrent ? Color.white : tint)
                        .frame(minWidth: 18, minHeight: 18)
                        .background(isCurrent ? tint : tint.opacity(0.14), in: Circle())
                    Text(item.title.isEmpty ? detail : item.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(Color(uiColor: .secondaryLabel))
                    .lineLimit(1)
                if !item.excerpt.isEmpty {
                    Text(item.excerpt)
                        .font(.caption)
                        .foregroundStyle(Color(uiColor: .secondaryLabel))
                        .lineLimit(1)
                }
            }
            .frame(width: 240, alignment: .leading)
            .padding(.horizontal, DCTheme.spacingM)
            .padding(.vertical, DCTheme.spacingS)
            .background(
                isCurrent ? tint.opacity(0.12) : Color(uiColor: .tertiarySystemFill),
                in: RoundedRectangle(cornerRadius: DCTheme.controlCornerRadius, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: DCTheme.controlCornerRadius, style: .continuous)
                    .stroke(isCurrent ? tint.opacity(0.7) : Color.clear, lineWidth: 1.5)
            }
            .contentShape(RoundedRectangle(cornerRadius: DCTheme.controlCornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: "\(number). \(item.title)"))
        .accessibilityValue(Text("\(number) of \(count). \(detail)", comment: "Result card VoiceOver value: its place in the list, then its details"))
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
        .accessibilityHint(Text("Opens it in the browser", comment: "Accessibility hint of a result card over the page"))
        .accessibilityIdentifier("resultCard-\(number)")
    }
}
