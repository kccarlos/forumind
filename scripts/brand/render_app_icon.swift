// Renders the Forumind app icon PNGs from the in-app brand mark code.
//
// Run from the repository root (macOS 14+, Xcode command line tools):
//
//   scripts/brand/render_app_icon.sh
//
// which compiles this file together with Forumind/BrandMarkShapes.swift and
// Forumind/BrandMark.swift (the same shapes the app draws) and writes:
//
//   Forumind/Assets.xcassets/AppIcon.appiconset/AppIcon.png         light, opaque
//   Forumind/Assets.xcassets/AppIcon.appiconset/AppIcon-Dark.png    dark, opaque
//   Forumind/Assets.xcassets/AppIcon.appiconset/AppIcon-Tinted.png  tinted, grayscale
//   docs/brand/forumind-icon-1024.png                                copy of the light icon

import AppKit
import CoreGraphics
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

@main
struct RenderAppIcon {
    @MainActor
    static func main() throws {
        let args = CommandLine.arguments.dropFirst()
        let root = URL(fileURLWithPath: args.first ?? FileManager.default.currentDirectoryPath)
        let iconSet = root.appendingPathComponent("Forumind/Assets.xcassets/AppIcon.appiconset")
        let docs = root.appendingPathComponent("docs/brand")
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)

        let size: CGFloat = 1024
        let light = try render(BrandAppIcon(size: size, appearance: .light), size: size)
        try writePNG(light, to: iconSet.appendingPathComponent("AppIcon.png"), grayscale: false)
        try writePNG(light, to: docs.appendingPathComponent("forumind-icon-1024.png"), grayscale: false)
        let dark = try render(BrandAppIcon(size: size, appearance: .dark), size: size)
        try writePNG(dark, to: iconSet.appendingPathComponent("AppIcon-Dark.png"), grayscale: false)
        let tinted = try render(BrandAppIcon(size: size, appearance: .tinted), size: size)
        try writePNG(tinted, to: iconSet.appendingPathComponent("AppIcon-Tinted.png"), grayscale: true)
        print("Wrote app icons to \(iconSet.path) and \(docs.path)")
    }

    @MainActor
    static func render(_ view: some View, size: CGFloat) throws -> CGImage {
        let renderer = ImageRenderer(content: view.environment(\.colorScheme, .light))
        renderer.scale = 1
        renderer.proposedSize = ProposedViewSize(width: size, height: size)
        guard let image = renderer.cgImage else { throw RenderError.render }
        return image
    }

    /// Redraws into a context with no alpha channel (App Store icons must be
    /// opaque) and writes a PNG.
    static func writePNG(_ image: CGImage, to url: URL, grayscale: Bool) throws {
        let width = image.width, height = image.height
        let context: CGContext?
        if grayscale {
            context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            )
        } else {
            context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            )
        }
        guard let context else { throw RenderError.context }
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let opaque = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw RenderError.write(url.path) }
        CGImageDestinationAddImage(destination, opaque, nil)
        guard CGImageDestinationFinalize(destination) else { throw RenderError.write(url.path) }
    }

    enum RenderError: Error {
        case render, context
        case write(String)
    }
}
