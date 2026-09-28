// Renders the README banner, which doubles as the GitHub social preview
// (1280 × 640): the brand gradient, the mark and wordmark, a headline and
// subline on the left, and three app screens in device frames fanned out on
// the right.
//
// Run from the repository root (macOS 14+, Xcode command line tools):
//
//   scripts/brand/render_banner.sh [--preview <dir>]
//
// which compiles this file together with Forumind/BrandMarkShapes.swift and
// Forumind/BrandMark.swift (the brand colors and mark the app draws). The
// screens are the same raw captures the App Store screenshots use
// (appstore/screenshots-raw/<locale>/, see render_store_screenshots.swift),
// drawn in the same device frame, so the banner matches the store listing.
// It writes opaque sRGB PNGs to
//
//   docs/brand/forumind-banner.png           English (README.md)
//   docs/brand/forumind-banner-zh-Hans.png   Simplified Chinese (README.zh-Hans.md)
//   docs/brand/forumind-banner-zh-Hant.png   Traditional Chinese (README.zh-Hant.md)
//
// The wrapper then writes the README's small screenshot copies and, when
// pngquant is installed, compresses everything (see render_banner.sh).
//
// With --preview <dir>, it also writes each banner at 600 px wide
// (preview-600-*.png), the size link previews in chat apps use, to check the
// headline still reads.
//
// Keep everything important inside the 40 px safe margin: GitHub and social
// sites may crop the edges of the social preview.

import AppKit
import CoreGraphics
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Copy (the one place to edit the banner text)

struct BannerLocale {
    /// Folder in appstore/screenshots-raw/.
    var folder: String
    /// Output file name in docs/brand/.
    var output: String
    /// Two or three lines ("\n" sets the breaks).
    var headline: String
    /// Two short lines.
    var subline: String
    /// PostScript names of the text fonts, or nil for SF Pro Rounded. SF Pro
    /// has no CJK glyphs, so Chinese uses PingFang (heaviest face: Semibold).
    var headlineFont: String?
    var sublineFont: String?

    static let all: [BannerLocale] = [
        BannerLocale(
            folder: "en-US", output: "forumind-banner.png",
            headline: "Catch up on any\nDiscourse forum\nin seconds",
            subline: "AI summaries, chat and answers with sources\niPhone & iPad · Free & open source"
        ),
        BannerLocale(
            folder: "zh-Hans", output: "forumind-banner-zh-Hans.png",
            headline: "秒懂任何\nDiscourse 论坛",
            subline: "AI 摘要、聊天，以及附带来源的回答\niPhone 与 iPad · 免费开源",
            headlineFont: "PingFangSC-Semibold", sublineFont: "PingFangSC-Medium"
        ),
        BannerLocale(
            folder: "zh-Hant", output: "forumind-banner-zh-Hant.png",
            headline: "秒懂任何\nDiscourse 論壇",
            subline: "AI 摘要、聊天，以及附上來源的回答\niPhone 與 iPad · 免費、開放原始碼",
            headlineFont: "PingFangTC-Semibold", sublineFont: "PingFangTC-Medium"
        ),
    ]
}

/// Raw captures shown on the right, back left, back right, then front.
enum BannerScreens {
    static let backLeft = "iphone-69-4-agent.png"
    static let backRight = "iphone-69-3-chat.png"
    static let front = "iphone-69-2-summary.png"
}

// MARK: - Layout

enum BannerLayout {
    static let canvas = CGSize(width: 1280, height: 640)
    /// Safe margin on every side for the text and the mark.
    static let margin: CGFloat = 40
    static let textLeft: CGFloat = 76
    static let textWidth: CGFloat = 600

    /// Screen width of the front phone; the back ones are scaled down.
    static let frontScreenWidth: CGFloat = 240
    static let backScale: CGFloat = 0.84
    /// Horizontal center of the phone group.
    static let groupCenterX: CGFloat = 935
    static let backOffsetX: CGFloat = 135
    static let backAngle: Double = 7
    static let frontTop: CGFloat = 70
    static let backTop: CGFloat = 132
}

// MARK: - Views

/// The device frame of the store screenshots, scaled to `screenWidth`.
struct PhoneFrame: View {
    var capture: CGImage
    var screenWidth: CGFloat

    var body: some View {
        // The store renderer uses a 140 pt corner and 26 pt bezel at 1040 pt.
        let unit = screenWidth / 1040
        let radius = 140 * unit
        let bezel = 26 * unit
        let height = screenWidth * CGFloat(capture.height) / CGFloat(capture.width)
        let outer = radius + bezel
        Image(decorative: capture, scale: 1)
            .resizable()
            .interpolation(.high)
            .antialiased(true)
            .frame(width: screenWidth, height: height)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .padding(bezel)
            .background(
                RoundedRectangle(cornerRadius: outer, style: .continuous)
                    .fill(Color(.sRGB, red: 0.07, green: 0.07, blue: 0.09, opacity: 1))
            )
            .overlay(
                RoundedRectangle(cornerRadius: outer, style: .continuous)
                    .strokeBorder(
                        LinearGradient(colors: [Color(white: 0.6), Color(white: 0.25), Color(white: 0.5)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing),
                        lineWidth: 1.5
                    )
            )
            .shadow(color: Color(.sRGB, red: 0.08, green: 0.03, blue: 0.2, opacity: 0.45), radius: 28, x: 0, y: 18)
            .shadow(color: .black.opacity(0.18), radius: 5, x: 0, y: 3)
    }
}

struct BannerBackground: View {
    var body: some View {
        let size = BannerLayout.canvas
        ZStack {
            LinearGradient(colors: [BrandPalette.blue, BrandPalette.purple],
                           startPoint: UnitPoint(x: 0, y: 0.2), endPoint: UnitPoint(x: 1, y: 0.8))
            // Soft light behind the text, a deeper tone behind the phones.
            RadialGradient(colors: [.white.opacity(0.20), .clear], center: UnitPoint(x: 0.12, y: 0.1),
                           startRadius: 0, endRadius: size.width * 0.55)
            RadialGradient(colors: [Color(.sRGB, red: 0.25, green: 0.08, blue: 0.45, opacity: 0.35), .clear],
                           center: UnitPoint(x: 0.8, y: 1.0), startRadius: 0, endRadius: size.width * 0.5)
            // The brand mark as a large, faint watermark behind the phones.
            BrandGlyphShape(backOpacity: 0.6)
                .foregroundStyle(.white.opacity(0.08))
                .frame(width: 560, height: 560)
                .rotationEffect(.degrees(-10))
                .position(x: 1150, y: 120)
        }
        .frame(width: size.width, height: size.height)
    }
}

struct Banner: View {
    var locale: BannerLocale
    var backLeft: CGImage
    var backRight: CGImage
    var front: CGImage

    func font(_ name: String?, size: CGFloat, weight: Font.Weight) -> Font {
        if let name { return .custom(name, fixedSize: size) }
        return .system(size: size, weight: weight, design: .rounded)
    }

    var isLatin: Bool { locale.headlineFont == nil }

    var body: some View {
        let size = BannerLayout.canvas
        ZStack(alignment: .topLeading) {
            BannerBackground()
            phones
            text
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .clipped()
        .environment(\.colorScheme, .light)
    }

    var logo: some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 56 * BrandMark.tileCornerRatio, style: .continuous)
                .fill(.white)
                .overlay { BrandGlyphLayout(size: 56, fill: AnyShapeStyle(BrandPalette.gradient)) }
                .frame(width: 56, height: 56)
                .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
            Text("Forumind")
                .font(.system(size: 36, weight: .bold, design: .rounded))
                .tracking(-0.3)
                .foregroundStyle(.white)
        }
    }

    var text: some View {
        VStack(alignment: .leading, spacing: 0) {
            logo
            Spacer(minLength: 0)
            // One Text per line with a fixed line height: PingFang's natural
            // line height is too loose for a headline, and lineSpacing can't
            // go below it.
            let headlineSize: CGFloat = isLatin ? 62 : 68
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(locale.headline.split(separator: "\n").enumerated()), id: \.offset) { _, line in
                    Text(String(line))
                        .font(font(locale.headlineFont, size: headlineSize, weight: .heavy))
                        .tracking(isLatin ? -1.2 : 0)
                        .fixedSize()
                        .frame(height: headlineSize * (isLatin ? 1.12 : 1.22), alignment: .leading)
                }
            }
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.12), radius: 6, y: 3)
            Text(locale.subline)
                .font(font(locale.sublineFont, size: 24, weight: .semibold))
                .lineSpacing(isLatin ? 4 : 0)
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(.white.opacity(0.9))
                .padding(.top, 22)
            Spacer(minLength: 0)
        }
        .frame(width: BannerLayout.textWidth, alignment: .leading)
        .frame(height: BannerLayout.canvas.height - 2 * 64, alignment: .topLeading)
        .offset(x: BannerLayout.textLeft, y: 64)
    }

    var phones: some View {
        let w = BannerLayout.frontScreenWidth
        let back = w * BannerLayout.backScale
        return ZStack(alignment: .top) {
            PhoneFrame(capture: backLeft, screenWidth: back)
                .rotationEffect(.degrees(-BannerLayout.backAngle), anchor: .bottom)
                .offset(x: -BannerLayout.backOffsetX, y: BannerLayout.backTop)
            PhoneFrame(capture: backRight, screenWidth: back)
                .rotationEffect(.degrees(BannerLayout.backAngle), anchor: .bottom)
                .offset(x: BannerLayout.backOffsetX, y: BannerLayout.backTop)
            PhoneFrame(capture: front, screenWidth: w)
                .offset(y: BannerLayout.frontTop)
        }
        .frame(width: BannerLayout.canvas.width, height: BannerLayout.canvas.height, alignment: .top)
        .offset(x: BannerLayout.groupCenterX - BannerLayout.canvas.width / 2)
    }
}

// MARK: - Main

@main
struct RenderBanner {
    @MainActor
    static func main() throws {
        var args = Array(CommandLine.arguments.dropFirst())
        var previewDir: URL?
        if let flag = args.firstIndex(of: "--preview") {
            guard flag + 1 < args.count else { throw RenderError.usage }
            previewDir = URL(fileURLWithPath: args[flag + 1])
            args.removeSubrange(flag ... flag + 1)
        }
        let root = URL(fileURLWithPath: args.first ?? FileManager.default.currentDirectoryPath)
        if let previewDir {
            try FileManager.default.createDirectory(at: previewDir, withIntermediateDirectories: true)
        }
        let outDir = root.appendingPathComponent("docs/brand")
        for locale in BannerLocale.all {
            for name in [locale.headlineFont, locale.sublineFont].compactMap({ $0 })
            where NSFont(name: name, size: 12) == nil {
                throw RenderError.font(name)
            }
            let rawDir = root.appendingPathComponent("appstore/screenshots-raw/\(locale.folder)")
            let view = Banner(
                locale: locale,
                backLeft: try loadImage(rawDir.appendingPathComponent(BannerScreens.backLeft)),
                backRight: try loadImage(rawDir.appendingPathComponent(BannerScreens.backRight)),
                front: try loadImage(rawDir.appendingPathComponent(BannerScreens.front))
            )
            let banner = try flatten(try render(view, size: BannerLayout.canvas))
            try writePNG(banner, to: outDir.appendingPathComponent(locale.output))
            print("Wrote docs/brand/\(locale.output) (\(banner.width)x\(banner.height))")

            if let previewDir {
                let small = CGSize(width: 600, height: 300)
                let preview = try render(
                    Image(decorative: banner, scale: 1).resizable().interpolation(.high)
                        .frame(width: small.width, height: small.height),
                    size: small
                )
                try writePNG(try flatten(preview), to: previewDir.appendingPathComponent("preview-600-\(locale.output)"))
            }
        }
    }

    static func loadImage(_ url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw RenderError.read(url.path) }
        return image
    }

    @MainActor
    static func render(_ view: some View, size: CGSize) throws -> CGImage {
        let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height))
        renderer.scale = 1
        renderer.proposedSize = ProposedViewSize(size)
        guard let image = renderer.cgImage else { throw RenderError.render }
        return image
    }

    /// Redraws into an sRGB context with no alpha channel.
    static func flatten(_ image: CGImage) throws -> CGImage {
        guard let context = CGContext(
            data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { throw RenderError.context }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(rect)
        context.draw(image, in: rect)
        guard let opaque = context.makeImage() else { throw RenderError.context }
        return opaque
    }

    static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw RenderError.write(url.path) }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw RenderError.write(url.path) }
    }

    enum RenderError: Error {
        case usage, render, context
        case read(String)
        case write(String)
        case font(String)
    }
}
