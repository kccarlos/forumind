import SwiftUI

// The Forumind brand mark, drawn by hand: two overlapping speech bubbles
// (the front one carries three lines of "text") and a four-point sparkle.
//
// Pure SwiftUI with no UIKit or AppKit, so the same code compiles into the
// app and into `scripts/brand/render_app_icon.swift`, which renders the app
// icon PNGs on macOS. `docs/brand/forumind-mark.svg` uses the same numbers.
//
// Every shape is laid out in a 100 × 100 unit box (`BrandGeometry`) and
// scaled to the rect it is asked to fill, so the mark stays proportional
// from 16pt to 1024px.

/// Brand colors, shared by the app theme and the icon renderer.
enum BrandPalette {
    /// #4A6BFF
    static let blue = Color(.sRGB, red: 74 / 255, green: 107 / 255, blue: 1, opacity: 1)
    /// #C13AE0
    static let purple = Color(.sRGB, red: 193 / 255, green: 58 / 255, blue: 224 / 255, opacity: 1)
    /// #17132B, the dark icon background.
    static let ink = Color(.sRGB, red: 23 / 255, green: 19 / 255, blue: 43 / 255, opacity: 1)

    static let gradient = LinearGradient(
        colors: [blue, purple],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    /// A lighter pair for the glyph on the dark icon: #7B93FF → #D77BF0.
    static let glowGradient = LinearGradient(
        colors: [
            Color(.sRGB, red: 123 / 255, green: 147 / 255, blue: 1, opacity: 1),
            Color(.sRGB, red: 215 / 255, green: 123 / 255, blue: 240 / 255, opacity: 1),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

/// Coordinates of the mark in its 100 × 100 design box.
enum BrandGeometry {
    // Back bubble (tail bottom-left).
    static let backBody = CGRect(x: 4, y: 12, width: 56, height: 42)
    static let backRadius: CGFloat = 15
    // Front bubble (tail bottom-right).
    static let frontBody = CGRect(x: 30, y: 36, width: 64, height: 46)
    static let frontRadius: CGFloat = 16
    // Clear ring cut around the front bubble where it overlaps the back one.
    static let gap: CGFloat = 4.5
    // Tails: where they leave the bottom edge (from the outer side), how far
    // they drop below it, and how far the tip reaches past the side.
    static let tailBase: CGFloat = 15
    static let tailDepth: CGFloat = 10.5
    static let tailFlare: CGFloat = 1.5
    // Text lines inside the front bubble: (minX, maxX, centerY).
    static let lineHeight: CGFloat = 6.5
    static let lines: [(CGFloat, CGFloat, CGFloat)] = [
        (41, 83, 48.5),
        (41, 83, 59),
        (41, 68, 69.5),
    ]
    // Sparkle, top right.
    static let sparkleCenter = CGPoint(x: 81, y: 16)
    static let sparkleRadius = CGSize(width: 12, height: 14)
    /// How far the sparkle's sides pinch toward its center (0 = straight).
    static let sparklePinch: CGFloat = 0.16
}

private struct BrandSpace {
    let rect: CGRect
    var scale: CGFloat { min(rect.width, rect.height) / 100 }
    var origin: CGPoint {
        CGPoint(x: rect.midX - 50 * scale, y: rect.midY - 50 * scale)
    }

    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: origin.x + x * scale, y: origin.y + y * scale)
    }

    func r(_ box: CGRect) -> CGRect {
        CGRect(x: origin.x + box.minX * scale, y: origin.y + box.minY * scale,
               width: box.width * scale, height: box.height * scale)
    }
}

/// A rounded speech bubble whose bottom-left (or, mirrored, bottom-right) corner
/// sweeps out into a tail. Coordinates are in design units.
private func bubblePath(body b: CGRect, radius r: CGFloat, tailOnLeft: Bool, in s: BrandSpace) -> Path {
    // Built for a left tail, mirrored for a right one.
    func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        let mx = tailOnLeft ? x : (b.minX + b.maxX - x)
        return s.p(mx, y)
    }
    let x0 = b.minX, x1 = b.maxX, y0 = b.minY, y1 = b.maxY
    var path = Path()
    path.move(to: pt(x0 + r, y0))
    path.addLine(to: pt(x1 - r, y0))
    path.addArc(tangent1End: pt(x1, y0), tangent2End: pt(x1, y0 + r), radius: r * s.scale)
    path.addLine(to: pt(x1, y1 - r))
    path.addArc(tangent1End: pt(x1, y1), tangent2End: pt(x1 - r, y1), radius: r * s.scale)
    // Bottom edge into the tail.
    path.addLine(to: pt(x0 + BrandGeometry.tailBase, y1))
    path.addQuadCurve(to: pt(x0 - BrandGeometry.tailFlare, y1 + BrandGeometry.tailDepth),
                      control: pt(x0 + BrandGeometry.tailBase * 0.35, y1 + BrandGeometry.tailDepth * 0.3))
    path.addQuadCurve(to: pt(x0, y1 - 5), control: pt(x0, y1 + BrandGeometry.tailDepth * 0.5))
    path.addLine(to: pt(x0, y0 + r))
    path.addArc(tangent1End: pt(x0, y0), tangent2End: pt(x0 + r, y0), radius: r * s.scale)
    path.closeSubpath()
    return path
}

/// The back (upper-left) bubble.
struct BrandBackBubble: Shape {
    func path(in rect: CGRect) -> Path {
        bubblePath(body: BrandGeometry.backBody, radius: BrandGeometry.backRadius,
                   tailOnLeft: true, in: BrandSpace(rect: rect))
    }
}

/// The front (lower-right) bubble.
struct BrandFrontBubble: Shape {
    func path(in rect: CGRect) -> Path {
        bubblePath(body: BrandGeometry.frontBody, radius: BrandGeometry.frontRadius,
                   tailOnLeft: false, in: BrandSpace(rect: rect))
    }
}

/// The three text lines inside the front bubble.
struct BrandTextLines: Shape {
    func path(in rect: CGRect) -> Path {
        let s = BrandSpace(rect: rect)
        let h = BrandGeometry.lineHeight
        var path = Path()
        for (minX, maxX, midY) in BrandGeometry.lines {
            let box = s.r(CGRect(x: minX, y: midY - h / 2, width: maxX - minX, height: h))
            path.addRoundedRect(in: box, cornerSize: CGSize(width: box.height / 2, height: box.height / 2))
        }
        return path
    }
}

/// The four-point sparkle.
struct BrandSparkle: Shape {
    func path(in rect: CGRect) -> Path {
        let s = BrandSpace(rect: rect)
        let c = BrandGeometry.sparkleCenter
        let rx = BrandGeometry.sparkleRadius.width
        let ry = BrandGeometry.sparkleRadius.height
        let k = BrandGeometry.sparklePinch
        var path = Path()
        path.move(to: s.p(c.x, c.y - ry))
        path.addQuadCurve(to: s.p(c.x + rx, c.y), control: s.p(c.x + rx * k, c.y - ry * k))
        path.addQuadCurve(to: s.p(c.x, c.y + ry), control: s.p(c.x + rx * k, c.y + ry * k))
        path.addQuadCurve(to: s.p(c.x - rx, c.y), control: s.p(c.x - rx * k, c.y + ry * k))
        path.addQuadCurve(to: s.p(c.x, c.y - ry), control: s.p(c.x - rx * k, c.y - ry * k))
        path.closeSubpath()
        return path
    }
}

/// The mark's glyph as a single-color alpha shape: the front bubble and
/// sparkle opaque, the back bubble at `backOpacity`, the text lines and the
/// ring around the front bubble cut out. Fill it with any style via
/// `.foregroundStyle`, or use it as a mask.
struct BrandGlyphShape: View {
    var backOpacity: Double = 0.55

    var body: some View {
        let ring = BrandGeometry.gap * 2
        GeometryReader { proxy in
            let unit = min(proxy.size.width, proxy.size.height) / 100
            ZStack {
                BrandBackBubble().opacity(backOpacity)
                BrandFrontBubble()
                    .stroke(style: StrokeStyle(lineWidth: ring * unit, lineCap: .round, lineJoin: .round))
                    .blendMode(.destinationOut)
                BrandFrontBubble()
                BrandSparkle()
                BrandTextLines().blendMode(.destinationOut)
            }
            .compositingGroup()
        }
    }
}
