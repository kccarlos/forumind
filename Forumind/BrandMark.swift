import SwiftUI

/// The Forumind logo. Shapes live in `BrandMarkShapes.swift`.
///
/// Kept free of UIKit so `scripts/brand/render_app_icon.swift` can compile
/// this file on macOS and render the app icon from the same code.
struct BrandMark: View {
    enum Style {
        /// White glyph on the brand-gradient rounded tile (the logo).
        case full
        /// White glyph only, for placing on the brand gradient.
        case glyph
        /// One-color glyph in the current foreground style.
        case tinted
    }

    var size: CGFloat
    var style: Style = .full

    /// Corner radius of the `.full` tile relative to its size (164pt → 44pt).
    static let tileCornerRatio: CGFloat = 0.27
    /// Glyph size relative to the tile / icon canvas.
    static let glyphRatio: CGFloat = 0.64

    var body: some View {
        switch style {
        case .full:
            RoundedRectangle(cornerRadius: size * Self.tileCornerRatio, style: .continuous)
                .fill(BrandPalette.gradient)
                .overlay { BrandGlyphLayout(size: size, fill: AnyShapeStyle(Color.white)) }
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        case .glyph:
            BrandGlyphShape()
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        case .tinted:
            BrandGlyphShape()
                .foregroundStyle(.foreground)
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        }
    }
}

/// The glyph placed on a square canvas of `size`, scaled by
/// `BrandMark.glyphRatio` and optically centered.
struct BrandGlyphLayout: View {
    var size: CGFloat
    var fill: AnyShapeStyle
    var backOpacity: Double = 0.55
    var ratio: CGFloat = BrandMark.glyphRatio

    /// The solid front bubble makes the glyph's visual weight sit right of
    /// its bounding box's center, so nudge it left a touch.
    static let opticalOffset = CGSize(width: -0.012, height: 0)

    var body: some View {
        let glyph = size * ratio
        BrandGlyphShape(backOpacity: backOpacity)
            .foregroundStyle(fill)
            .frame(width: glyph, height: glyph)
            .offset(x: glyph * Self.opticalOffset.width, y: glyph * Self.opticalOffset.height)
            .frame(width: size, height: size)
    }
}

/// Full-bleed square app icon artwork (iOS applies the corner mask).
struct BrandAppIcon: View {
    enum Appearance { case light, dark, tinted }

    var size: CGFloat
    var appearance: Appearance

    var body: some View {
        ZStack {
            switch appearance {
            case .light:
                Rectangle().fill(BrandPalette.gradient)
                BrandGlyphLayout(size: size, fill: AnyShapeStyle(Color.white))
            case .dark:
                Rectangle().fill(BrandPalette.ink)
                BrandGlyphLayout(size: size, fill: AnyShapeStyle(BrandPalette.glowGradient), backOpacity: 0.6)
            case .tinted:
                Rectangle().fill(Color.black)
                BrandGlyphLayout(size: size, fill: AnyShapeStyle(Color.white), backOpacity: 0.6)
            }
        }
        .frame(width: size, height: size)
    }
}
