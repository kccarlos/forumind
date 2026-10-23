import SwiftUI
import UIKit
import XCTest
@testable import Forumind

final class DesignTokenTests: XCTestCase {
    private enum Mode: CaseIterable {
        case light, dark, lightHighContrast, darkHighContrast

        var traits: UITraitCollection {
            let isDark = self == .dark || self == .darkHighContrast
            let isHigh = self == .lightHighContrast || self == .darkHighContrast
            return UITraitCollection { mutable in
                mutable.userInterfaceStyle = isDark ? .dark : .light
                mutable.accessibilityContrast = isHigh ? .high : .normal
            }
        }
    }

    private func hex(_ color: Color, _ mode: Mode) -> UInt32 {
        let resolved = UIColor(color).resolvedColor(with: mode.traits)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        resolved.getRed(&r, green: &g, blue: &b, alpha: &a)
        func byte(_ v: CGFloat) -> UInt32 { UInt32((v * 255).rounded()) }
        return byte(r) << 16 | byte(g) << 8 | byte(b)
    }

    private struct Expectation {
        let name: String
        let color: Color
        let light: UInt32
        let dark: UInt32
        let highContrastLight: UInt32
        let highContrastDark: UInt32
    }

    private var expectations: [Expectation] {
        [
            Expectation(name: "brandBlue", color: DCTheme.brandBlue, light: 0x3A5BE0, dark: 0x7B93FF, highContrastLight: 0x2A45B8, highContrastDark: 0xA9BAFF),
            Expectation(name: "brandPurple", color: DCTheme.brandPurple, light: 0x8E2DB5, dark: 0xC77DEB, highContrastLight: 0x6E1F8E, highContrastDark: 0xE0A8F7),
            Expectation(name: "chatTint", color: DCTheme.chatTint, light: 0x0E8A7E, dark: 0x4FD1C0, highContrastLight: 0x0A6B62, highContrastDark: 0x8BEBDD),
            Expectation(name: "newRepliesBadgeText", color: DCTheme.newRepliesBadgeText, light: 0x8A4A00, dark: 0xFFB44C, highContrastLight: 0x6E3A00, highContrastDark: 0xFFD08A),
            Expectation(name: "newRepliesBadgeBackground", color: DCTheme.newRepliesBadgeBackground, light: 0xFFF1DE, dark: 0x3A2A12, highContrastLight: 0xFFE6C4, highContrastDark: 0x2A1C08),
            Expectation(name: "postHighlightBackground", color: DCTheme.postHighlightBackground, light: 0xEEF1FF, dark: 0x1E2550, highContrastLight: 0xEEF1FF, highContrastDark: 0x1E2550),
        ]
    }

    func testTokensResolveInEveryAppearanceAndContrast() {
        for item in expectations {
            XCTAssertEqual(hex(item.color, .light), item.light, "\(item.name) light")
            XCTAssertEqual(hex(item.color, .dark), item.dark, "\(item.name) dark")
            XCTAssertEqual(hex(item.color, .lightHighContrast), item.highContrastLight, "\(item.name) light high contrast")
            XCTAssertEqual(hex(item.color, .darkHighContrast), item.highContrastDark, "\(item.name) dark high contrast")
        }
    }

    func testHighContrastDiffersWhereSpecified() {
        for item in expectations where item.name != "postHighlightBackground" {
            XCTAssertNotEqual(item.light, item.highContrastLight, "\(item.name) light")
            XCTAssertNotEqual(item.dark, item.highContrastDark, "\(item.name) dark")
        }
    }

    func testBrandInkUsesSystemLabelInHighContrast() {
        XCTAssertEqual(hex(DCTheme.brandInk, .light), 0x17132B)
        XCTAssertEqual(hex(DCTheme.brandInk, .dark), 0xF2F0FA)
        for mode in [Mode.lightHighContrast, .darkHighContrast] {
            let label = UIColor.label.resolvedColor(with: mode.traits)
            XCTAssertEqual(UIColor(DCTheme.brandInk).resolvedColor(with: mode.traits), label)
        }
        XCTAssertEqual(hex(DCTheme.brandInk, .lightHighContrast), 0x000000)
        XCTAssertEqual(hex(DCTheme.brandInk, .darkHighContrast), 0xFFFFFF)
    }

    func testPostHighlightStrokeIsBrandBlueAndThickerInHighContrast() {
        XCTAssertEqual(DCTheme.postHighlightStrokeWidth(highContrast: false), 2)
        XCTAssertEqual(DCTheme.postHighlightStrokeWidth(highContrast: true), 3)
        for mode in Mode.allCases {
            XCTAssertEqual(hex(DCTheme.postHighlightStroke, mode), hex(DCTheme.brandBlue, mode))
        }
        XCTAssertEqual(hex(DCTheme.postHighlightStroke, .light), 0x3A5BE0)
        XCTAssertEqual(hex(DCTheme.postHighlightStroke, .dark), 0x7B93FF)
    }

    func testLaunchBackgroundColorIsConfigured() throws {
        let color = try XCTUnwrap(UIColor(named: "LaunchBackground", in: Bundle(for: AppModel.self), compatibleWith: nil))
        func white(_ mode: Mode) -> CGFloat {
            var value: CGFloat = -1
            color.resolvedColor(with: mode.traits).getWhite(&value, alpha: nil)
            return value
        }
        XCTAssertEqual(white(.light), 1, accuracy: 0.01)
        XCTAssertEqual(white(.dark), 0, accuracy: 0.01)
    }
}
