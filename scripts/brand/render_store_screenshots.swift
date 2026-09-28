// Renders the App Store marketing screenshots: a brand-gradient panel with a
// big headline, a short subline, and the raw app capture inside a simple
// device frame.
//
// Run from the repository root (macOS 14+, Xcode command line tools):
//
//   scripts/brand/render_store_screenshots.sh [--preview <dir>]
//
// which compiles this file together with Forumind/BrandMarkShapes.swift and
// Forumind/BrandMark.swift (the brand colors and mark the app draws) and
// reads the raw simulator captures for each store locale (en-US, zh-Hans,
// zh-Hant; see `StoreLocale`) from
//
//   appstore/screenshots-raw/<locale>/   iphone-69-*.png (1320 × 2868), ipad-13-*.png (2064 × 2752)
//
// and writes the final, opaque sRGB PNGs that fastlane uploads to
//
//   appstore/screenshots/<locale>/       same sizes, numbered in App Store order
//
// With --preview <dir>, it also writes downscaled copies of every final
// image (preview-<locale>-*.png) and 3-up strips of the first three at
// search-result size (300 px per tile) on white and on black
// (strip-<locale>-<device>-<white|black>.png), to judge how the listing reads.
//
// All captions live in `Captions` below, per locale; keep docs/APP_STORE.md
// in sync. Chinese captions use PingFang (SF Pro Rounded has no CJK glyphs).

import AppKit
import CoreGraphics
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Captions (the one place to edit the store copy)

/// One store language: its folder name (fastlane `deliver` layout, the same
/// for appstore/screenshots-raw/ and appstore/screenshots/) and its fonts.
struct StoreLocale {
    var folder: String
    /// PostScript names of the caption fonts, or nil for SF Pro Rounded.
    /// SF Pro has no CJK glyphs, so Chinese uses PingFang (its heaviest face
    /// is Semibold) without the negative tracking that suits Latin.
    var headlineFont: String?
    var sublineFont: String?

    static let all: [StoreLocale] = [
        StoreLocale(folder: "en-US"),
        StoreLocale(folder: "zh-Hans", headlineFont: "PingFangSC-Semibold", sublineFont: "PingFangSC-Medium"),
        StoreLocale(folder: "zh-Hant", headlineFont: "PingFangTC-Semibold", sublineFont: "PingFangTC-Medium"),
    ]
}

/// Two short lines ("\n" sets the line break) and a one-line subline.
struct Caption {
    var headline: String
    var subline: String
}

struct Slide {
    /// Raw capture in appstore/screenshots-raw/<locale>/.
    var raw: String
    /// Final file name in appstore/screenshots/<locale>/ (its number is the App Store order).
    var output: String
    var backdrop: Backdrop
    /// The caption per locale folder; every locale in `StoreLocale.all` needs one.
    var captions: [String: Caption]
}

enum Captions {
    static let catchUp: [String: Caption] = [
        "en-US": Caption(headline: "Catch up\nin seconds", subline: "AI summaries of long forum threads"),
        "zh-Hans": Caption(headline: "长篇讨论\n秒懂重点", subline: "AI 总结冗长的论坛讨论"),
        "zh-Hant": Caption(headline: "長篇討論\n秒懂重點", subline: "AI 摘要冗長的論壇討論"),
    ]
    static let ask: [String: Caption] = [
        "en-US": Caption(headline: "Ask the\nwhole forum", subline: "Answers with links to the posts"),
        "zh-Hans": Caption(headline: "问遍\n整个论坛", subline: "回答附带原帖链接"),
        "zh-Hant": Caption(headline: "問遍\n整個論壇", subline: "回答附上原文連結"),
    ]
    static let chat: [String: Caption] = [
        "en-US": Caption(headline: "Chat with\nany topic", subline: "Ask follow-ups about any thread"),
        "zh-Hans": Caption(headline: "任何话题\n随时追问", subline: "针对任何讨论串追问细节"),
        "zh-Hant": Caption(headline: "任何話題\n隨時追問", subline: "針對任何討論串追問細節"),
    ]

    static let iPhone: [Slide] = [
        Slide(raw: "iphone-69-2-summary.png", output: "iphone-69-1-summary.png",
              backdrop: .panorama(0, 1 / 3), captions: catchUp),
        Slide(raw: "iphone-69-4-agent.png", output: "iphone-69-2-ask.png",
              backdrop: .panorama(1 / 3, 2 / 3), captions: ask),
        Slide(raw: "iphone-69-3-chat.png", output: "iphone-69-3-chat.png",
              backdrop: .panorama(2 / 3, 1), captions: chat),
        Slide(raw: "iphone-69-1-home.png", output: "iphone-69-4-forums.png",
              backdrop: .panorama(1, 0.4), captions: [
                  "en-US": Caption(headline: "Every forum\nin one app", subline: "Pin favorites, share from your browser"),
                  "zh-Hans": Caption(headline: "所有论坛\n一个 App", subline: "置顶常用论坛，从浏览器一键分享"),
                  "zh-Hant": Caption(headline: "所有論壇\n一個 App", subline: "釘選常用論壇，從瀏覽器一鍵分享"),
              ]),
        // The walkthrough's privacy page. Ad blocking is optional and off by
        // default, so the caption must not promise an ad-free browser.
        Slide(raw: "iphone-69-5-privacy.png", output: "iphone-69-5-private.png",
              backdrop: .ink, captions: [
                  "en-US": Caption(headline: "Private\nby design", subline: "No accounts, no tracking. Optional ad blocking."),
                  "zh-Hans": Caption(headline: "隐私\n从设计开始", subline: "无需账户，不做跟踪，广告拦截可选"),
                  "zh-Hant": Caption(headline: "隱私\n從設計開始", subline: "無需帳號，不做追蹤，廣告阻擋可選"),
              ]),
    ]

    static let iPad: [Slide] = [
        Slide(raw: "ipad-13-1-home-summary.png", output: "ipad-13-1-summary.png",
              backdrop: .panorama(0, 1 / 3), captions: catchUp),
        Slide(raw: "ipad-13-3-agent.png", output: "ipad-13-2-ask.png",
              backdrop: .panorama(1 / 3, 2 / 3), captions: ask),
        Slide(raw: "ipad-13-2-chat.png", output: "ipad-13-3-chat.png",
              backdrop: .panorama(2 / 3, 1), captions: chat),
        Slide(raw: "ipad-13-4-manage.png", output: "ipad-13-4-manage.png",
              backdrop: .panorama(1, 0.4), captions: [
                  "en-US": Caption(headline: "Every forum\nin one app", subline: "Summaries, chats, and watched topics"),
                  "zh-Hans": Caption(headline: "所有论坛\n一个 App", subline: "摘要、聊天、关注的话题，集中管理"),
                  "zh-Hant": Caption(headline: "所有論壇\n一個 App", subline: "摘要、聊天、追蹤的話題，集中管理"),
              ]),
        Slide(raw: "ipad-13-5-sync.png", output: "ipad-13-5-sync.png",
              backdrop: .ink, captions: [
                  "en-US": Caption(headline: "Private\n& in sync", subline: "No accounts. End-to-end encrypted sync."),
                  "zh-Hans": Caption(headline: "隐私安全\n跨设备同步", subline: "无需账户，端到端加密同步"),
                  "zh-Hant": Caption(headline: "隱私安全\n跨裝置同步", subline: "無需帳號，端對端加密同步"),
              ]),
    ]
}

// MARK: - Layout per device class

struct DeviceSpec {
    var canvas: CGSize
    var headlineSize: CGFloat
    var sublineSize: CGFloat
    var topInset: CGFloat
    var textGap: CGFloat
    var deviceGap: CGFloat
    /// Width of the screen inside the frame.
    var screenWidth: CGFloat
    /// Display corner radius at `screenWidth`.
    var screenRadius: CGFloat
    var bezel: CGFloat

    static let iPhone = DeviceSpec(
        canvas: CGSize(width: 1320, height: 2868),
        headlineSize: 172, sublineSize: 62,
        topInset: 180, textGap: 30, deviceGap: 100,
        screenWidth: 1040, screenRadius: 140, bezel: 26
    )

    static let iPad = DeviceSpec(
        canvas: CGSize(width: 2064, height: 2752),
        headlineSize: 176, sublineSize: 70,
        topInset: 190, textGap: 38, deviceGap: 120,
        screenWidth: 1720, screenRadius: 56, bezel: 44
    )
}

// MARK: - Views

enum Backdrop {
    /// A horizontal slice of one wide blue-to-purple gradient: `from` and
    /// `to` are positions from 0 (#4A6BFF) to 1 (#C13AE0) at the left and
    /// right edges. Slides 1 to 3 continue each other, so they read as one
    /// band in search results.
    case panorama(Double, Double)
    /// The dark icon background with brand-colored glows.
    case ink

    static func brandColor(at t: Double) -> Color {
        // #4A6BFF → #C13AE0
        let a = (74.0, 107.0, 255.0), b = (193.0, 58.0, 224.0)
        func mix(_ x: Double, _ y: Double) -> Double { (x + (y - x) * t) / 255 }
        return Color(.sRGB, red: mix(a.0, b.0), green: mix(a.1, b.1), blue: mix(a.2, b.2), opacity: 1)
    }
}

struct BackdropView: View {
    var backdrop: Backdrop
    var size: CGSize

    var body: some View {
        ZStack {
            switch backdrop {
            case let .panorama(from, to):
                LinearGradient(colors: [Backdrop.brandColor(at: from), Backdrop.brandColor(at: to)],
                               startPoint: .leading, endPoint: .trailing)
                LinearGradient(colors: [.clear, .black.opacity(0.18)], startPoint: .center, endPoint: .bottom)
                // A soft light behind the headline.
                RadialGradient(colors: [.white.opacity(0.22), .clear], center: UnitPoint(x: 0.5, y: 0.08),
                               startRadius: 0, endRadius: size.width * 0.75)
            case .ink:
                BrandPalette.ink
                RadialGradient(colors: [BrandPalette.blue.opacity(0.85), .clear], center: UnitPoint(x: 0.1, y: 0.05),
                               startRadius: 0, endRadius: size.width * 0.95)
                RadialGradient(colors: [BrandPalette.purple.opacity(0.8), .clear], center: UnitPoint(x: 0.95, y: 0.55),
                               startRadius: 0, endRadius: size.width * 0.9)
            }
            // The brand mark as a large, faint watermark, bleeding off the top right.
            BrandGlyphShape(backOpacity: 0.6)
                .foregroundStyle(.white.opacity(0.09))
                .frame(width: size.width * 0.62, height: size.width * 0.62)
                .rotationEffect(.degrees(-10))
                .position(x: size.width * 0.93, y: size.width * 0.13)
        }
        .frame(width: size.width, height: size.height)
    }
}

/// A plain device frame: the capture clipped to the display's rounded
/// corners inside a thin dark bezel with a faint metal edge and a soft shadow.
struct DeviceFrame: View {
    var capture: CGImage
    var spec: DeviceSpec

    var body: some View {
        let w = spec.screenWidth
        let h = w * CGFloat(capture.height) / CGFloat(capture.width)
        let outer = spec.screenRadius + spec.bezel
        Image(decorative: capture, scale: 1)
            .resizable()
            .interpolation(.high)
            .frame(width: w, height: h)
            .clipShape(RoundedRectangle(cornerRadius: spec.screenRadius, style: .continuous))
            .padding(spec.bezel)
            .background(
                RoundedRectangle(cornerRadius: outer, style: .continuous)
                    .fill(Color(.sRGB, red: 0.07, green: 0.07, blue: 0.09, opacity: 1))
            )
            .overlay(
                RoundedRectangle(cornerRadius: outer, style: .continuous)
                    .strokeBorder(
                        LinearGradient(colors: [Color(white: 0.55), Color(white: 0.22), Color(white: 0.45)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing),
                        lineWidth: max(3, spec.bezel * 0.16)
                    )
            )
            .shadow(color: .black.opacity(0.35), radius: 60, x: 0, y: 30)
            .shadow(color: .black.opacity(0.18), radius: 12, x: 0, y: 6)
    }
}

struct StoreScreenshot: View {
    var caption: Caption
    var locale: StoreLocale
    var backdrop: Backdrop
    var capture: CGImage
    var spec: DeviceSpec

    func font(_ name: String?, size: CGFloat, weight: Font.Weight) -> Font {
        if let name { return .custom(name, fixedSize: size) }
        return .system(size: size, weight: weight, design: .rounded)
    }

    var body: some View {
        let size = spec.canvas
        ZStack(alignment: .top) {
            BackdropView(backdrop: backdrop, size: size)
            VStack(spacing: 0) {
                Text(caption.headline)
                    .font(font(locale.headlineFont, size: spec.headlineSize, weight: .black))
                    .tracking(locale.headlineFont == nil ? -spec.headlineSize * 0.015 : 0)
                    .lineSpacing(locale.headlineFont == nil ? 0 : -spec.headlineSize * 0.12)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.12), radius: 8, y: 4)
                Text(caption.subline)
                    .font(font(locale.sublineFont, size: spec.sublineSize, weight: .semibold))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(.top, spec.textGap)
                DeviceFrame(capture: capture, spec: spec)
                    .padding(.top, spec.deviceGap)
            }
            .padding(.horizontal, size.width * 0.07)
            .padding(.top, spec.topInset)
            .frame(width: size.width, height: size.height, alignment: .top)
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .clipped()
        .environment(\.colorScheme, .light)
    }
}

/// The first three screenshots side by side, as in App Store search results.
struct PreviewStrip: View {
    var images: [CGImage]
    var tileWidth: CGFloat
    var background: Color

    var body: some View {
        HStack(spacing: 14) {
            ForEach(images.indices, id: \.self) { index in
                let image = images[index]
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: tileWidth, height: tileWidth * CGFloat(image.height) / CGFloat(image.width))
                    .clipShape(RoundedRectangle(cornerRadius: tileWidth * 0.05, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: tileWidth * 0.05, style: .continuous)
                            .strokeBorder(Color.gray.opacity(0.25), lineWidth: 1)
                    )
            }
        }
        .padding(28)
        .background(background)
    }
}

// MARK: - Main

@main
struct RenderStoreScreenshots {
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
        for locale in StoreLocale.all {
            try renderLocale(locale, root: root, previewDir: previewDir)
        }
    }

    @MainActor
    static func renderLocale(_ locale: StoreLocale, root: URL, previewDir: URL?) throws {
        let rawDir = root.appendingPathComponent("appstore/screenshots-raw/\(locale.folder)")
        let outDir = root.appendingPathComponent("appstore/screenshots/\(locale.folder)")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        if let name = locale.headlineFont, NSFont(name: name, size: 12) == nil {
            throw RenderError.font(name)
        }
        if let name = locale.sublineFont, NSFont(name: name, size: 12) == nil {
            throw RenderError.font(name)
        }

        // Remove old finals so renamed slides don't linger in the upload folder.
        for name in try FileManager.default.contentsOfDirectory(atPath: outDir.path)
        where name.hasSuffix(".png") && (name.hasPrefix("iphone") || name.hasPrefix("ipad")) {
            try FileManager.default.removeItem(at: outDir.appendingPathComponent(name))
        }

        for (kind, slides, spec) in [("iphone", Captions.iPhone, DeviceSpec.iPhone), ("ipad", Captions.iPad, DeviceSpec.iPad)] {
            var finals: [CGImage] = []
            for slide in slides {
                guard let caption = slide.captions[locale.folder] else {
                    throw RenderError.caption("\(locale.folder)/\(slide.output)")
                }
                let capture = try loadImage(rawDir.appendingPathComponent(slide.raw))
                let view = StoreScreenshot(caption: caption, locale: locale, backdrop: slide.backdrop,
                                           capture: capture, spec: spec)
                let opaque = try flatten(try render(view, size: spec.canvas))
                try writePNG(opaque, to: outDir.appendingPathComponent(slide.output))
                finals.append(opaque)
                print("Wrote \(locale.folder)/\(slide.output) (\(opaque.width)x\(opaque.height))")

                if let previewDir {
                    let scale = 1000 / spec.canvas.height
                    let small = CGSize(width: (spec.canvas.width * scale).rounded(), height: 1000)
                    let preview = try render(
                        Image(decorative: opaque, scale: 1).resizable().interpolation(.high)
                            .frame(width: small.width, height: small.height),
                        size: small
                    )
                    try writePNG(try flatten(preview),
                                 to: previewDir.appendingPathComponent("preview-\(locale.folder)-" + slide.output))
                }
            }
            if let previewDir {
                for (name, color) in [("white", Color.white), ("black", Color.black)] {
                    let strip = PreviewStrip(images: Array(finals.prefix(3)), tileWidth: 300, background: color)
                    let renderer = ImageRenderer(content: strip)
                    renderer.scale = 1
                    guard let image = renderer.cgImage else { throw RenderError.render }
                    try writePNG(try flatten(image),
                                 to: previewDir.appendingPathComponent("strip-\(locale.folder)-\(kind)-\(name).png"))
                }
            }
        }
        print("Wrote App Store screenshots to \(outDir.path)")
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

    /// Redraws into an sRGB context with no alpha channel (App Store
    /// screenshots must be opaque).
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
        case caption(String)
    }
}
