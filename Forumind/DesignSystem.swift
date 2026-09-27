import SwiftUI
import UIKit

// Forumind design tokens. Brand colors come from the app
// icon (blue #4A6BFF → purple #C13AE0). Views use these tokens
// instead of literal colors, sizes, or animations so the app stays consistent
// in light and dark mode.

enum DCTheme {
    // Layout
    static let panelMinimumWidth: CGFloat = 360
    static let panelIdealWidth: CGFloat = 470
    static let panelMaximumWidth: CGFloat = 560
    static let splitLayoutMinimumWidth: CGFloat = 850
    static let controlHeight: CGFloat = 44
    static let cardCornerRadius: CGFloat = 18
    static let controlCornerRadius: CGFloat = 12
    static let contentMaxWidth: CGFloat = 640

    // Spacing scale
    static let spacingXS: CGFloat = 4
    static let spacingS: CGFloat = 8
    static let spacingM: CGFloat = 12
    static let spacingL: CGFloat = 16
    static let spacingXL: CGFloat = 24
    static let spacingXXL: CGFloat = 32

    // Surfaces
    static let pageBackground = Color(uiColor: .systemGroupedBackground)
    static let surface = Color(uiColor: .secondarySystemGroupedBackground)
    static let raisedSurface = Color(uiColor: .tertiarySystemGroupedBackground)
    static let toolbar = Color(uiColor: .secondarySystemBackground)
    static let border = Color.secondary.opacity(0.16)

    // Brand
    static let brandBlue = Color(light: 0x3A5BE0, dark: 0x7B93FF)
    static let brandPurple = Color(light: 0x8E2DB5, dark: 0xC77DEB)
    static let brandInk = Color(light: 0x17132B, dark: 0xF2F0FA)
    static let brandGradient = BrandPalette.gradient

    /// One color per assistant capability, used for icons and accents.
    static let summaryTint = brandBlue
    static let chatTint = Color(light: 0x0E8A7E, dark: 0x4FD1C0)
    static let agentTint = brandPurple

    // Status
    static let success = Color(light: 0x087A43, dark: 0x4CD68C)
    static let warning = Color(light: 0xA35B00, dark: 0xFFB44C)
    static let danger = Color(light: 0xC52D3A, dark: 0xFF6B76)
}

/// Shared animation curves: quick for toggles, smooth for layout changes.
enum DCMotion {
    static let quick = Animation.snappy(duration: 0.22)
    static let smooth = Animation.smooth(duration: 0.32)
    static let spring = Animation.spring(response: 0.38, dampingFraction: 0.86)
}

enum DCHaptics {
    static func tap() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    static func warning() { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }

    /// A color that adapts to light and dark mode.
    init(light: UInt32, dark: UInt32) {
        self.init(uiColor: UIColor { traits in
            let hex = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(
                red: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1
            )
        })
    }
}

struct DCCardModifier: ViewModifier {
    let tint: Color

    func body(content: Content) -> some View {
        content
            .padding(14)
            .background {
                RoundedRectangle(cornerRadius: DCTheme.cardCornerRadius, style: .continuous)
                    .fill(DCTheme.surface)
                    .overlay {
                        RoundedRectangle(cornerRadius: DCTheme.cardCornerRadius, style: .continuous)
                            .fill(tint.opacity(0.06))
                    }
            }
            .overlay {
                RoundedRectangle(cornerRadius: DCTheme.cardCornerRadius, style: .continuous)
                    .stroke(tint == .clear ? DCTheme.border : tint.opacity(0.25))
            }
    }
}

struct DCIconButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(isEnabled ? 1 : 0.3)
            .frame(minWidth: DCTheme.controlHeight, minHeight: DCTheme.controlHeight)
            .contentShape(Rectangle())
            .background(
                Color.primary.opacity(configuration.isPressed ? 0.1 : 0.001),
                in: RoundedRectangle(cornerRadius: 11, style: .continuous)
            )
            .contentShape(.hoverEffect, RoundedRectangle(cornerRadius: 11, style: .continuous))
            .hoverEffect(.highlight)
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(DCMotion.quick, value: configuration.isPressed)
    }
}

struct DCActionButtonStyle: ButtonStyle {
    let prominent: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .frame(minHeight: DCTheme.controlHeight)
            .padding(.horizontal, 14)
            .foregroundStyle(prominent ? Color.white : Color.accentColor)
            .background(
                prominent
                    ? Color.accentColor.opacity(configuration.isPressed ? 0.78 : 1)
                    : Color.accentColor.opacity(configuration.isPressed ? 0.14 : 0.08),
                in: RoundedRectangle(cornerRadius: DCTheme.controlCornerRadius, style: .continuous)
            )
            .overlay {
                if !prominent {
                    RoundedRectangle(cornerRadius: DCTheme.controlCornerRadius, style: .continuous)
                        .stroke(Color.accentColor.opacity(0.22))
                }
            }
            .contentShape(.hoverEffect, RoundedRectangle(cornerRadius: DCTheme.controlCornerRadius, style: .continuous))
            .hoverEffect(.highlight)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(DCMotion.quick, value: configuration.isPressed)
    }
}

/// Full-width primary call to action with the brand gradient (onboarding,
/// empty states, "Create summary").
struct DCPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 50)
            .padding(.horizontal, DCTheme.spacingL)
            .background(
                DCTheme.brandGradient.opacity(isEnabled ? 1 : 0.4),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .shadow(color: Color(hex: 0x4A6BFF, opacity: isEnabled ? 0.25 : 0), radius: 10, y: 4)
            .contentShape(.hoverEffect, RoundedRectangle(cornerRadius: 14, style: .continuous))
            .hoverEffect(.lift)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
            .animation(DCMotion.quick, value: configuration.isPressed)
    }
}

/// Small rounded label, e.g. forum names, counts, "Pinned".
struct DCPill: View {
    let text: String
    var systemImage: String?
    var tint: Color = .accentColor

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage).imageScale(.small)
            }
            Text(text).lineLimit(1)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(tint.opacity(0.12), in: Capsule())
    }
}

/// Section header used on scrolling pages (Forums home, Manage, onboarding).
struct DCSectionHeader: View {
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.headline)
            if let subtitle {
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityAddTraits(.isHeader)
    }
}

extension View {
    func dcCard(tint: Color = .clear) -> some View {
        modifier(DCCardModifier(tint: tint))
    }

    /// Legacy name kept while views migrate to `dcCard`.
    func ucsCard(tint: Color = .clear) -> some View {
        dcCard(tint: tint)
    }
}

// MARK: - Forum identity (Forums home, switcher, tiles)

extension DCTheme {
    /// Size of the forum icon on Forums home tiles.
    static let forumTileIcon: CGFloat = 56
    /// Corner radius of a forum icon relative to its size (app-icon squircle).
    static let forumIconCornerRatio: CGFloat = 0.26

    /// Monogram palette for forums without a usable icon; picked by host so a
    /// forum keeps its color everywhere.
    static let forumPalette: [Color] = [
        Color(light: 0x3A5BE0, dark: 0x6F88FF),
        Color(light: 0x8E2DB5, dark: 0xC77DEB),
        Color(light: 0x0E8A7E, dark: 0x3CC4B3),
        Color(light: 0xC2410C, dark: 0xFB8A4C),
        Color(light: 0xB42363, dark: 0xF06A9F),
        Color(light: 0x2F7A2F, dark: 0x6BCB6B),
        Color(light: 0x5B4BC4, dark: 0x9C8FFF),
        Color(light: 0x9A6700, dark: 0xE7B43A)
    ]

    /// Stable tint for a forum (FNV-1a over the host, not `hashValue`, which
    /// changes between launches).
    static func forumTint(for siteURL: String) -> Color {
        var hash: UInt32 = 2_166_136_261
        for byte in ForumSite.host(of: siteURL).utf8 {
            hash = (hash ^ UInt32(byte)) &* 16_777_619
        }
        return forumPalette[Int(hash % UInt32(forumPalette.count))]
    }
}

extension DCMotion {
    /// `animation`, or nil when Reduce Motion is on (state changes instantly).
    static func respecting(_ reduceMotion: Bool, _ animation: Animation = DCMotion.smooth) -> Animation? {
        reduceMotion ? nil : animation
    }

    /// Slide + fade, or a plain fade with Reduce Motion.
    static func slide(_ edge: Edge, reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .move(edge: edge).combined(with: .opacity)
    }

    /// Gentle scale + fade for swapping whole screens (Forums home ↔ page).
    static func screen(reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.98))
    }
}

/// Soft tinted capsule for page status in the browser bar, e.g. "Not a
/// Discourse forum". Smaller than `DCPill`.
struct DCStatusChip: View {
    /// nil shows the icon alone (narrow bars); give it an accessibility label.
    let text: String?
    var systemImage: String?
    var tint: Color = .secondary

    var body: some View {
        HStack(spacing: 3) {
            if let systemImage {
                Image(systemName: systemImage).imageScale(.small)
            }
            if let text {
                Text(text).lineLimit(1)
            }
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(tint)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(tint.opacity(0.14), in: Capsule())
        .fixedSize()
    }
}

// MARK: - Keyboard visibility

private struct KeyboardVisibilityModifier: ViewModifier {
    @Binding var isVisible: Bool

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
                isVisible = true
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                isVisible = false
            }
    }
}

extension View {
    /// Tracks whether the software keyboard is on screen, e.g. to tuck a
    /// pinned bottom bar away while typing so it doesn't ride the keyboard.
    func dcKeyboardVisible(_ isVisible: Binding<Bool>) -> some View {
        modifier(KeyboardVisibilityModifier(isVisible: isVisible))
    }
}
