import SwiftUI
import UIKit
import XCTest
@testable import Forumind

final class CoreTests: XCTestCase {
    /// A full stop "touches" its citation chip when the gap is at most this many points:
    /// 2 pt of spacing plus one pixel at the tests' 2x render scale, so a simulator that
    /// rasterises the same layout half a point differently does not fail the test.
    private let citationTouchLimit: CGFloat = 2.5

    // MARK: Browser bar position

    func testNewSettingsPlaceTheBarAutomatically() {
        XCTAssertEqual(AppSettings().browserBarPosition, .automatic)
    }

    func testStoredBarPositionsSurviveAndAMissingOneTakesTheDefault() throws {
        func decode(_ json: String) throws -> BrowserBarPosition {
            try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8)).browserBarPosition
        }
        XCTAssertEqual(try decode(#"{"browserBarPosition":"top"}"#), .top)
        XCTAssertEqual(try decode(#"{"browserBarPosition":"bottom"}"#), .bottom)
        XCTAssertEqual(try decode(#"{"browserBarPosition":"automatic"}"#), .automatic)
        XCTAssertEqual(try decode("{}"), AppSettings().browserBarPosition)
        // An unreadable value fails the decode; the store then starts fresh.
        XCTAssertThrowsError(try decode(#"{"browserBarPosition":"floating"}"#))
    }

    func testAutomaticBarIsAtTheBottomExceptInTheSplitLayout() {
        XCTAssertEqual(BrowserBarPosition.automatic.resolved(isSplit: false), .bottom)
        XCTAssertEqual(BrowserBarPosition.automatic.resolved(isSplit: true), .top)
        for isSplit in [false, true] {
            XCTAssertEqual(BrowserBarPosition.top.resolved(isSplit: isSplit), .top)
            XCTAssertEqual(BrowserBarPosition.bottom.resolved(isSplit: isSplit), .bottom)
        }
        XCTAssertEqual(BrowserBarPosition.allCases, [.automatic, .top, .bottom])
    }

    @MainActor
    func testCitationPunctuationTouchesChipAndStaysOnItsLine() throws {
        func render<V: View>(_ view: V, dynamicTypeSize: DynamicTypeSize, width: CGFloat, height: CGFloat) -> UIImage {
            let content = view
                .environment(\.dynamicTypeSize, dynamicTypeSize)
                .environment(\.colorScheme, .light)
                .foregroundStyle(Color.black)
                .frame(width: width, alignment: .leading)
                .background(Color.white)
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: height))
            let host = UIHostingController(rootView: content)
            if dynamicTypeSize.isAccessibilitySize {
                host.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
            }
            window.rootViewController = host
            window.makeKeyAndVisible()
            host.view.frame = window.bounds
            window.layoutIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            let format = UIGraphicsImageRendererFormat()
            format.scale = 2
            let image = UIGraphicsImageRenderer(bounds: host.view.bounds, format: format).image { ctx in
                host.view.layer.render(in: ctx.cgContext)
            }
            window.isHidden = true
            return image
        }

        struct PillMetric {
            var pillMinX: CGFloat
            var pillMaxX: CGFloat
            var pillMinY: CGFloat
            var pillMaxY: CGFloat
            var gapBefore: CGFloat?
            var prevWasPill: Bool
            var gapAfter: CGFloat?
            var dotMaxY: CGFloat?
        }

        func measurePills(in uiImage: UIImage) throws -> [PillMetric] {
            let cgImage = try XCTUnwrap(uiImage.cgImage)
            let scale = uiImage.scale
            let w = cgImage.width, h = cgImage.height
            var px = [UInt8](repeating: 255, count: w * h * 4)
            px.withUnsafeMutableBytes { bytes in
                let ctx = CGContext(
                    data: bytes.baseAddress, width: w, height: h,
                    bitsPerComponent: 8, bytesPerRow: w * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                )
                ctx?.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
            }
            func isPill(_ x: Int, _ y: Int) -> Bool {
                let i = (y * w + x) * 4
                let r = Int(px[i]), g = Int(px[i + 1]), b = Int(px[i + 2])
                return r > 220 && g > 220 && b > 245 && b - r > 8
            }
            func isInk(_ x: Int, _ y: Int) -> Bool {
                let i = (y * w + x) * 4
                let r = Int(px[i]), g = Int(px[i + 1]), b = Int(px[i + 2])
                return r < 90 && g < 90 && b < 90
            }

            var metrics: [PillMetric] = []
            var y = 0
            while y < h {
                guard (0..<w).contains(where: { isPill($0, y) }) else {
                    y += 1
                    continue
                }
                let bandTop = y
                while y < h, (0..<w).contains(where: { isPill($0, y) }) { y += 1 }
                let bandBottom = y - 1
                guard bandBottom - bandTop >= Int(14 * scale), bandBottom - bandTop <= Int(70 * scale) else { continue }

                // Find contiguous horizontal pill segments in this row band.
                var x = 0
                while x < w {
                    guard (bandTop...bandBottom).contains(where: { isPill(x, $0) }) else {
                        x += 1
                        continue
                    }
                    let minX = x
                    while x < w, (bandTop...bandBottom).contains(where: { isPill(x, $0) }) { x += 1 }
                    let maxX = x - 1
                    guard maxX - minX >= Int(20 * scale), maxX - minX <= Int(120 * scale) else { continue }

                    var prevMaxX: Int?
                    var prevWasPill = false
                    let searchLeft = max(0, minX - Int(24 * scale))
                    for by in bandTop...bandBottom {
                        for sx in searchLeft..<minX where isInk(sx, by) || isPill(sx, by) {
                            if prevMaxX == nil || sx >= prevMaxX! {
                                prevMaxX = sx
                                if isPill(sx, by) { prevWasPill = true }
                            }
                        }
                    }

                    // Search for trailing punctuation ink immediately to the right of the pill
                    // (including up to 8 pt below bandBottom to detect AX5 baseline drop).
                    var dotMinX: Int?
                    var dotMaxY: Int?
                    let searchRight = min(w, maxX + 1 + Int(14 * scale))
                    let dotSearchBottom = min(h - 1, bandBottom + Int(8 * scale))
                    if maxX + 1 < searchRight {
                        // Stop at the first blank vertical column after the first ink blob so we only measure the punctuation mark.
                        var foundDotInk = false
                        for sx in (maxX + 1)..<searchRight {
                            var colHasInk = false
                            for by in bandTop...dotSearchBottom where isInk(sx, by) {
                                colHasInk = true
                                dotMinX = min(dotMinX ?? sx, sx)
                                dotMaxY = max(dotMaxY ?? by, by)
                            }
                            if colHasInk {
                                foundDotInk = true
                            } else if foundDotInk {
                                break
                            }
                        }
                    }

                    metrics.append(PillMetric(
                        pillMinX: CGFloat(minX) / scale,
                        pillMaxX: CGFloat(maxX) / scale,
                        pillMinY: CGFloat(bandTop) / scale,
                        pillMaxY: CGFloat(bandBottom) / scale,
                        gapBefore: prevMaxX.map { CGFloat(minX - $0 - 1) / scale },
                        prevWasPill: prevWasPill,
                        gapAfter: dotMinX.map { CGFloat($0 - maxX - 1) / scale },
                        dotMaxY: dotMaxY.map { CGFloat($0) / scale }
                    ))
                }
            }
            return metrics
        }

        for (name, summary, dts) in [
            ("en-large", SampleContent.english.tipsSummary, DynamicTypeSize.large),
            ("en-ax5", SampleContent.english.tipsSummary, DynamicTypeSize.accessibility5),
            ("zh-large", SampleContent.simplifiedChinese.tipsSummary, DynamicTypeSize.large),
            ("zh-ax5", SampleContent.simplifiedChinese.tipsSummary, DynamicTypeSize.accessibility5)
        ] {
            let rows = DrawerSummarySections.parsed(for: .init(text: summary, maximumPost: 88)).rows
            let image = render(
                VStack(alignment: .leading, spacing: 8) {
                    DrawerSummarySections(rows: rows, layout: .singleColumn)
                }
                .padding(.horizontal, 14),
                dynamicTypeSize: dts,
                width: 390,
                height: dts.isAccessibilitySize ? 4400 : 1100
            )
            let pills = try measurePills(in: image)
            XCTAssertEqual(pills.count, 8, "\(name): expected all 8 sample summary citations (#1, #2, #7, #3, #12, #9, #1, #14)")
            // Citations at indices 0 (#1), 2 (#7), 4 (#12), 5 (#9), 6 (#1), 7 (#14) have a trailing full stop.
            for idx in [0, 2, 4, 5, 6, 7] where idx < pills.count {
                let pill = pills[idx]
                let gapAfter = try XCTUnwrap(pill.gapAfter, "\(name) pill[\(idx)]: trailing full stop must stay on the same line right after its chip")
                XCTAssertLessThanOrEqual(gapAfter, citationTouchLimit, "\(name) pill[\(idx)]: full stop must touch the chip without a space (got \(gapAfter) pt)")
                if let dotMaxY = pill.dotMaxY {
                    XCTAssertLessThanOrEqual(dotMaxY, pill.pillMaxY + 1.5, "\(name) pill[\(idx)]: full stop must not drop below the chip pill")
                }
                if !dts.isAccessibilitySize {
                    if let gapBefore = pill.gapBefore {
                        let maxGapBefore: CGFloat = pill.prevWasPill ? 10.0 : 6.5
                        XCTAssertLessThanOrEqual(gapBefore, maxGapBefore, "\(name) pill[\(idx)]: chip must not have extra leading touch-padding gap before it (got \(gapBefore) pt)")
                    } else {
                        // Wrapped to the start of a bullet (x=34) or numbered (x=42) line.
                        let expectedStart: CGFloat = idx >= 6 ? 43.0 : 35.0
                        XCTAssertLessThanOrEqual(pill.pillMinX, expectedStart, "\(name) pill[\(idx)]: wrapped chip at line start must align with text column, not indent (got x=\(pill.pillMinX) pt)")
                    }
                }
            }
        }

        // Line-wrap boundary: when a line ends right at a cited full stop (including compound punctuation),
        // the punctuation must never wrap onto a line below its chip.
        for (name, sample, dts, wrapWidth) in [
            ("wrap-en", "counts match [#3](forumind-post:3) [#7](forumind-post:7).", DynamicTypeSize.large, CGFloat(175)),
            ("wrap-zh", "计数对得上了 [#3](forumind-post:3) [#7](forumind-post:7)。", DynamicTypeSize.large, CGFloat(175)),
            ("wrap-zh-paren", "（见 [#7](forumind-post:7)）。", DynamicTypeSize.large, CGFloat(100))
        ] {
            let image = render(
                MarkdownBlockView(row: MarkdownRow(content: .paragraph(sample), topSpacing: 0), citations: true),
                dynamicTypeSize: dts,
                width: wrapWidth,
                height: 160
            )
            let pills = try measurePills(in: image)
            let lastPill = try XCTUnwrap(pills.last, "\(name): expected citation pill")
            let gapAfter = try XCTUnwrap(lastPill.gapAfter, "\(name): full stop must stay on the same line as its chip")
            XCTAssertLessThanOrEqual(gapAfter, citationTouchLimit, "\(name): full stop must touch its chip")
            // Verify there is no orphan ink below the last pill's line band.
            let cgImage = try XCTUnwrap(image.cgImage)
            let scale = image.scale
            let w = cgImage.width, h = cgImage.height
            var px = [UInt8](repeating: 255, count: w * h * 4)
            px.withUnsafeMutableBytes { bytes in
                let ctx = CGContext(
                    data: bytes.baseAddress, width: w, height: h,
                    bitsPerComponent: 8, bytesPerRow: w * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                )
                ctx?.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
            }
            let belowStart = min(h, Int((lastPill.pillMaxY + 4) * scale))
            var orphanInkBelow = false
            for y in belowStart..<h {
                for x in 0..<w {
                    let i = (y * w + x) * 4
                    if px[i] < 90 && px[i + 1] < 90 && px[i + 2] < 90 {
                        orphanInkBelow = true
                    }
                }
            }
            XCTAssertFalse(orphanInkBelow, "\(name): full stop must never drop onto its own line below the chip")
        }

        // Chat answer bubbles in English and Chinese at default and AX5 sizes.
        for (name, reply, dts) in [
            ("chat-en-large", "Enable it for staff first #12. See also #3 #7.", DynamicTypeSize.large),
            ("chat-en-ax5", "Enable it for staff first #12. See also #3 #7.", DynamicTypeSize.accessibility5),
            ("chat-zh-large", "先为工作人员开启 #12。另见 #3 #7。", DynamicTypeSize.large),
            ("chat-zh-ax5", "先为工作人员开启 #12。另见 #3 #7。", DynamicTypeSize.accessibility5)
        ] {
            let image = render(
                ChatBubble(
                    message: ChatMessage(role: .assistant, content: reply),
                    maximumPost: 68
                )
                .padding(.horizontal, 14),
                dynamicTypeSize: dts,
                width: 390,
                height: dts.isAccessibilitySize ? 900 : 300
            )
            let pills = try measurePills(in: image)
            XCTAssertEqual(pills.count, 3, "\(name): expected 3 chat citations")
            for idx in [0, 2] where idx < pills.count {
                let gapAfter = try XCTUnwrap(pills[idx].gapAfter, "\(name) pill[\(idx)]: full stop must stay with its chip in chat")
                XCTAssertLessThanOrEqual(gapAfter, citationTouchLimit, "\(name) pill[\(idx)]: full stop in chat must touch the chip (got \(gapAfter) pt)")
            }
        }
    }

    @MainActor
    func testCitedParagraphScalesWordSpacesAtAX5() throws {
        let font = UIFont.preferredFont(forTextStyle: .body, compatibleWith:
            UITraitCollection(preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge))
        let wordsWidth = (["Hello", "world"].map {
            ($0 as NSString).size(withAttributes: [.font: font]).width
        }).reduce(0, +)
        // Six points fits the old hard-coded four-point gap, but cannot fit
        // the native AX5 word space. The black words must occupy two lines.
        let content = MarkdownBlockView(row: MarkdownRow(
            content: .paragraph("Hello world [#1](forumind-post:1)"), topSpacing: 0), citations: true)
            .environment(\.dynamicTypeSize, .accessibility5)
            .environment(\.colorScheme, .light)
            .foregroundStyle(Color.black)
            .frame(width: wordsWidth + 6, alignment: .leading)
            .background(Color.white)
        let renderer = ImageRenderer(content: content)
        let image = try XCTUnwrap(renderer.cgImage)
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        pixels.withUnsafeMutableBytes { bytes in
            let context = CGContext(data: bytes.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            context?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        var bands = 0
        var wasInk = false
        for y in 0..<height {
            let ink = (0..<width).contains { x in
                let offset = (y * width + x) * 4
                return pixels[offset] < 70 && pixels[offset + 1] < 70 && pixels[offset + 2] < 70
            }
            if ink && !wasInk { bands += 1 }
            wasInk = ink
        }
        XCTAssertEqual(bands, 2, "AX5 spaces must grow with the words instead of collapsing to four points")
        let attachment = XCTAttachment(image: UIImage(cgImage: image))
        attachment.name = "AX5 cited word spacing"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testMarkdownParserRecognizesStructuredBlocks() {
        let document = MarkdownDocument(
            source: """
            # Summary

            Intro with **bold**.

            - First
            - Second

            1. One
            2. Two

            > Important

            ```swift
            let answer = 42
            ```

            | Card | Reward |
            | --- | --- |
            | Gold | 4x |

            ---
            """
        )

        XCTAssertEqual(
            document.blocks,
            [
                .heading(level: 1, text: "Summary"),
                .paragraph("Intro with **bold**."),
                .unorderedList(["First", "Second"]),
                .orderedList(["One", "Two"]),
                .quote("Important"),
                .code(language: "swift", content: "let answer = 42"),
                .table(headers: ["Card", "Reward"], rows: [["Gold", "4x"]]),
                .rule
            ]
        )
    }

    func testMarkdownParserKeepsMultilineParagraphsAndUnclosedCode() {
        let document = MarkdownDocument(
            source: """
            first line
            second line

            ```
            unfinished
            """
        )

        XCTAssertEqual(
            document.blocks,
            [
                .paragraph("first line\nsecond line"),
                .code(language: nil, content: "unfinished")
            ]
        )
    }

    func testMarkdownRowExpandsListsAndPreservesSectionAndBlockSpacing() {
        let sections = [
            "## First\n\nIntro.\n\n- Alpha\n- Beta\n\n1. One\n2. Two",
            "## Second\n\nOutro."
        ]
        let rows = MarkdownRow.rows(fromSections: sections)
        XCTAssertEqual(
            rows,
            [
                MarkdownRow(content: .heading(level: 2, text: "First"), topSpacing: 0),
                MarkdownRow(content: .paragraph("Intro."), topSpacing: 12),
                MarkdownRow(content: .listItem(number: nil, text: "Alpha"), topSpacing: 12),
                MarkdownRow(content: .listItem(number: nil, text: "Beta"), topSpacing: 8),
                MarkdownRow(content: .listItem(number: 1, text: "One"), topSpacing: 12),
                MarkdownRow(content: .listItem(number: 2, text: "Two"), topSpacing: 8),
                MarkdownRow(content: .heading(level: 2, text: "Second"), topSpacing: 14),
                MarkdownRow(content: .paragraph("Outro."), topSpacing: 12)
            ]
        )

        // When flattened into ChatThread's LazyVStack(spacing: 8) with top padding 10,
        // every effective gap (8 + topSpacing) matches 12 / 8 / 14 pt identically.
        let threadRows = MarkdownRow.rows(fromSections: sections, initialTopSpacing: 4, stackSpacing: 8)
        XCTAssertEqual(threadRows.map { 8 + $0.topSpacing }, [12, 12, 12, 8, 12, 8, 14, 12])
    }

    @MainActor
    func testDrawerLongSummaryLaysOutOnlyVisibleBlocksAcrossSheetDrags() throws {
        // ~18,000 characters, 281 headings and bullets, 480 #N citations.
        var lines = ["## Original post"]
        for section in 1...40 {
            lines.append("\n## Section \(section)")
            for point in 1...6 {
                lines.append("- Readers report that the card works well and pays out quickly after a short wait #\(section * point) #\(section + point + 40)")
            }
        }
        let longSummary = lines.joined(separator: "\n")
        XCTAssertGreaterThan(longSummary.count, 18_000)
        let totalRows = MarkdownRow.rows(fromSections: DrawerSummarySections.sections(of: longSummary)).count
        XCTAssertEqual(totalRows, 281)

        let (app, _) = try makeSummaryTestApp(summary: longSummary, totalPosts: 500)
        MarkdownLayoutProbe.reset()

        let (window, host) = hostView(
            AssistantPanel(app: app, onExpand: { _ in }),
            size: CGSize(width: 377, height: 420)
        )
        defer { window.isHidden = true }

        let initialBodies = MarkdownLayoutProbe.blockBodies
        let initialCitations = MarkdownLayoutProbe.citationLayouts
        XCTAssertGreaterThan(initialBodies, 0)
        XCTAssertLessThan(initialBodies, 60, "Only on-screen rows should materialize in medium drawer; got \(initialBodies)/\(totalRows).")
        XCTAssertLessThan(initialCitations, 120, "Offscreen cited bullets must not lay out; got \(initialCitations).")

        // Simulate 20 drag frames between medium (floating, ~4% narrower) and large.
        MarkdownLayoutProbe.reset()
        for step in 1...20 {
            let fraction = CGFloat(step) / 20
            let width = 377 + (393 - 377) * fraction
            let height = 420 + (780 - 420) * fraction
            window.frame = CGRect(origin: .zero, size: CGSize(width: width, height: height))
            host.view.frame = window.bounds
            window.layoutIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.005))
        }
        let dragBodies = MarkdownLayoutProbe.blockBodies
        let dragCitations = MarkdownLayoutProbe.citationLayouts
        // Eager layout of 240 cited bullets across 20 width steps would run >= 4,800 layouts.
        XCTAssertLessThan(dragBodies, 60, "Dragging medium->large should only materialize newly exposed rows; got \(dragBodies).")
        XCTAssertLessThan(dragCitations, 900, "Dragging medium->large must only re-measure visible cited rows; got \(dragCitations).")

        // Single-section 200-bullet list (no intermediate ## headings) also stays lazy.
        let singleSection = "## Discussion\n" + (1...200).map {
            "- Detailed point number \($0) explaining what fixed the issue in practice #\($0) #\($0 + 1)"
        }.joined(separator: "\n")
        let (singleApp, _) = try makeSummaryTestApp(summary: singleSection, totalPosts: 500)
        MarkdownLayoutProbe.reset()
        let (singleWindow, _) = hostView(
            AssistantPanel(app: singleApp, onExpand: { _ in }),
            size: CGSize(width: 393, height: 420)
        )
        defer { singleWindow.isHidden = true }
        XCTAssertLessThan(MarkdownLayoutProbe.blockBodies, 60, "A 200-bullet list inside one section must lay out lazily.")

        // Wide portrait iPad drawer (>= 640 pt -> two columns) also stays lazy.
        let (wideApp, _) = try makeSummaryTestApp(summary: longSummary, totalPosts: 500)
        MarkdownLayoutProbe.reset()
        let (wideWindow, _) = hostView(
            AssistantPanel(app: wideApp, onExpand: { _ in }),
            size: CGSize(width: 820, height: 460)
        )
        defer { wideWindow.isHidden = true }
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        wideWindow.layoutIfNeeded()
        XCTAssertGreaterThan(MarkdownLayoutProbe.blockBodies, 0)
        XCTAssertLessThan(MarkdownLayoutProbe.blockBodies, 110, "Two-column wide drawer summary must lay out lazily; got \(MarkdownLayoutProbe.blockBodies)/\(totalRows).")
    }

    @MainActor
    func testChatScrollToBottomAndFollowStreamingOverLongLazySummary() throws {
        // Mix short bullets at the top with taller multi-sentence cited bullets
        // deeper down so unmeasured row heights genuinely differ from the initial estimate.
        var lines = ["## Original post"]
        for section in 1...40 {
            lines.append("\n## Section \(section)")
            for point in 1...6 {
                if section <= 3 {
                    lines.append("- Short point #\(point)")
                } else {
                    lines.append("- Readers report that the card works well, posts the bonus reliably after statement close, and waives the first-year fee in branch #\(section * point) #\(section + point + 40)")
                }
            }
        }
        let longSummary = lines.joined(separator: "\n")
        let ai = HeldChatAIStub()
        let (app, _) = try makeSummaryTestApp(summary: longSummary, totalPosts: 500, aiService: ai)

        let (window, host) = hostView(
            AssistantPanel(app: app, onExpand: { _ in }),
            size: CGSize(width: 393, height: 740)
        )
        defer { window.isHidden = true }

        let scrollView = try XCTUnwrap(findScrollView(in: host.view), "Missing chatScroll UIScrollView")
        XCTAssertLessThan(scrollView.contentOffset.y, 10)

        // Send a user question via AppModel.sendChat(), starting an active chat stream.
        app.drafts.chat = "What is the consensus?"
        app.sendChat()

        // Let the scroll animation and post-jump lazy settle complete.
        RunLoop.current.run(until: Date().addingTimeInterval(0.9))
        host.view.layoutIfNeeded()

        let distanceAfterSend = scrollView.contentSize.height - (scrollView.contentOffset.y + scrollView.bounds.height)
        XCTAssertLessThan(distanceAfterSend, 48, "scrollTo(chatBottom) must reach the bottom over lazy rows; distance=\(distanceAfterSend)")

        // Stream a multi-paragraph answer: follow-the-answer must stay at the bottom.
        let chatRecord = try XCTUnwrap(app.activities.first { $0.type == .chat })
        for line in 1...8 {
            app.streams.append("Line \(line) of the streaming chat answer with enough words to wrap onto another line.\n\n", to: chatRecord.id)
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
            host.view.layoutIfNeeded()
        }
        let distanceAfterStream = scrollView.contentSize.height - (scrollView.contentOffset.y + scrollView.bounds.height)
        XCTAssertLessThan(distanceAfterStream, 48, "Streaming chat must follow the answer to the bottom; distance=\(distanceAfterStream)")

        // Reader scrolls up mid-stream: follow-the-answer must pause instead of yanking back down.
        // A real drag sets `userScrolling` at once. This offset change has no gesture,
        // so a flush already on its way must land first and the position report
        // must arrive before the next one.
        app.streams.flush()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        let pausedOffset = max(0, scrollView.contentOffset.y - 300)
        scrollView.setContentOffset(CGPoint(x: 0, y: pausedOffset), animated: false)
        scrollView.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        for line in 9...12 {
            app.streams.append("Line \(line) arriving while the reader scrolled up.\n\n", to: chatRecord.id)
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
            host.view.layoutIfNeeded()
        }
        let distanceWhilePaused = scrollView.contentSize.height - (scrollView.contentOffset.y + scrollView.bounds.height)
        XCTAssertGreaterThan(distanceWhilePaused, 250, "Streaming while scrolled up must not force-scroll back to the bottom.")

        // Scroll upward in steps through unmeasured lazy summary rows above the viewport:
        // late row measurement must keep scroll progress monotonic without wild jumps.
        var previousOffset = scrollView.contentOffset.y
        for step in 1...12 {
            let target = max(0, previousOffset - 240)
            scrollView.setContentOffset(CGPoint(x: 0, y: target), animated: false)
            window.layoutIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            window.layoutIfNeeded()
            let actual = scrollView.contentOffset.y
            let drift = abs(actual - target)
            XCTAssertLessThan(actual, previousOffset, "Scrolling up must move upward even as offscreen rows materialize.")
            XCTAssertLessThan(drift, 160, "Late row measurement above viewport jumped offset by \(drift) pt at step \(step).")
            previousOffset = actual
        }

        ai.finish()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))

        // Wide two-column portrait iPad drawer (820 pt) also jumps and follows chat streaming.
        let wideAI = HeldChatAIStub()
        let (wideApp, _) = try makeSummaryTestApp(summary: longSummary, totalPosts: 500, aiService: wideAI)
        let (wideWindow, wideHost) = hostView(
            AssistantPanel(app: wideApp, onExpand: { _ in }),
            size: CGSize(width: 820, height: 740)
        )
        defer { wideWindow.isHidden = true }
        let wideScroll = try XCTUnwrap(findScrollView(in: wideHost.view))
        wideApp.drafts.chat = "Summarize in one sentence"
        wideApp.sendChat()
        RunLoop.current.run(until: Date().addingTimeInterval(0.9))
        wideHost.view.layoutIfNeeded()
        let wideRecord = try XCTUnwrap(wideApp.activities.first { $0.type == .chat })
        for line in 1...4 {
            wideApp.streams.append("Wide column streaming answer paragraph \(line).\n\n", to: wideRecord.id)
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
            wideHost.view.layoutIfNeeded()
        }
        let wideDistance = wideScroll.contentSize.height - (wideScroll.contentOffset.y + wideScroll.bounds.height)
        XCTAssertLessThan(wideDistance, 48, "Two-column drawer chat must follow streaming to the bottom; distance=\(wideDistance)")
        wideAI.finish()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    }

    @MainActor
    func testLazyEarlierChatMessagesAndScrollFollowWith60Messages() throws {
        var lines = ["## Original post"]
        for section in 1...12 {
            lines.append("\n## Section \(section)")
            for point in 1...4 {
                lines.append("- Summary point \(section).\(point) discussing the card offer and timing #\(section * point)")
            }
        }
        let longSummary = lines.joined(separator: "\n")
        let ai = HeldChatAIStub()
        let (app, topic) = try makeSummaryTestApp(summary: longSummary, totalPosts: 500, aiService: ai)

        var session = try XCTUnwrap(app.sessions[topic.topicKey])
        let messages: [ChatMessage] = (1...60).map { index in
            ChatMessage(
                role: index.isMultiple(of: 2) ? .assistant : .user,
                content: index.isMultiple(of: 2)
                    ? "Assistant reply \(index) with enough detail to occupy a full bubble height and cite #\(index)."
                    : "User question \(index) about the discussion?"
            )
        }
        session.history = messages
        app.upsertSessionForTesting(session)

        DrawerRenderProbe.reset()
        let (window, host) = hostView(
            AssistantPanel(app: app, onExpand: { _ in }),
            size: CGSize(width: 393, height: 740)
        )
        defer { window.isHidden = true }

        let initialBodies = DrawerRenderProbe.chatBubbleBodies
        XCTAssertGreaterThan(initialBodies, 0, "Newest chat bubbles must still evaluate eagerly on open.")
        XCTAssertLessThan(
            initialBodies,
            15,
            "Opening AssistantPanel with 60 chat messages must evaluate fewer than 15 ChatBubble.body instances; got \(initialBodies)."
        )

        let scrollView = try XCTUnwrap(findScrollView(in: host.view), "Missing chatScroll UIScrollView")

        // Adding a user message and streaming an answer must still land and stay at the bottom.
        app.drafts.chat = "What is the latest takeaway?"
        app.sendChat()
        RunLoop.current.run(until: Date().addingTimeInterval(0.9))
        host.view.layoutIfNeeded()

        let distanceAfterSend = scrollView.contentSize.height - (scrollView.contentOffset.y + scrollView.bounds.height)
        XCTAssertLessThan(distanceAfterSend, 48, "sendChat over 60 lazy chat messages must reach the bottom; distance=\(distanceAfterSend)")

        let chatRecord = try XCTUnwrap(app.activities.first { $0.type == .chat })
        for line in 1...6 {
            app.streams.append("Streamed paragraph \(line) over a 60-message conversation.\n\n", to: chatRecord.id)
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
            host.view.layoutIfNeeded()
        }
        let distanceAfterStream = scrollView.contentSize.height - (scrollView.contentOffset.y + scrollView.bounds.height)
        XCTAssertLessThan(distanceAfterStream, 48, "Streaming answer over 60 lazy chat messages must stay at the bottom; distance=\(distanceAfterStream)")

        ai.finish()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        host.view.layoutIfNeeded()

        // Scrolling from the bottom toward the top must materialize earlier messages.
        DrawerRenderProbe.reset()
        var currentOffset = scrollView.contentOffset.y
        while currentOffset > 0 {
            currentOffset = max(0, currentOffset - 350)
            scrollView.setContentOffset(CGPoint(x: 0, y: currentOffset), animated: false)
            window.layoutIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            window.layoutIfNeeded()
        }
        XCTAssertGreaterThan(
            DrawerRenderProbe.chatBubbleBodies,
            0,
            "Scrolling to the top must materialize earlier chat bubbles."
        )
        XCTAssertTrue(
            DrawerRenderProbe.chatBubbleMessageIDs.contains(messages[0].id),
            "Scrolling to the top must materialize the earliest chat message."
        )
    }

    @MainActor
    func testExternalMarkdownViewCallersRenderLazilyAndSizeInForm() throws {
        // Long MarkdownView inside an outer ScrollView + VStack (as in AgentView and TranslationViews).
        let longMarkdown = (1...180).map { "## Heading \($0)\n\nParagraph \($0) with **bold** and `code`." }.joined(separator: "\n\n")
        MarkdownLayoutProbe.reset()
        let (scrollWindow, _) = hostView(
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    MarkdownView(longMarkdown)
                }
                .padding(14)
            },
            size: CGSize(width: 393, height: 500)
        )
        defer { scrollWindow.isHidden = true }
        XCTAssertGreaterThan(MarkdownLayoutProbe.blockBodies, 0)
        XCTAssertLessThan(MarkdownLayoutProbe.blockBodies, 60, "MarkdownView inside ScrollView + VStack must render lazily.")

        // SettingsAcknowledgementsPage hosts MarkdownView inside Form -> Section.
        let (app, _) = try makeSummaryTestApp(summary: "", totalPosts: 1)
        MarkdownLayoutProbe.reset()
        let (formWindow, _) = hostView(
            NavigationStack { SettingsAcknowledgementsPage(app: app) },
            size: CGSize(width: 393, height: 740)
        )
        defer { formWindow.isHidden = true }
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        formWindow.layoutIfNeeded()
        XCTAssertGreaterThanOrEqual(MarkdownLayoutProbe.blockBodies, 3, "MarkdownView inside Form must render its acknowledgement blocks.")
    }

    @MainActor
    private func findScrollView(in view: UIView) -> UIScrollView? {
        if let scroll = view as? UIScrollView, scroll.bounds.height > 200 {
            return scroll
        }
        for subview in view.subviews {
            if let found = findScrollView(in: subview) { return found }
        }
        return nil
    }

    func testTopicExportPayloadIncludesAllAvailableSectionsByDefault() throws {
        let url = try XCTUnwrap(
            URL(string: "https://forum.example.com/t/example/517303")
        )
        let payload = TopicExportPayload(
            summary: "# Summary\n\nUse the welcome offer.",
            source: "Original post\n\nReply one",
            title: "Example discussion",
            url: url,
            history: [
                ChatMessage(role: .user, content: "Is this still available?"),
                ChatMessage(role: .assistant, content: "The latest replies say yes.")
            ]
        )

        XCTAssertEqual(
            payload.text(options: ExportOptions()),
            """
            Example discussion

            Post URL: https://forum.example.com/t/example/517303

            Summary:
            # Summary

            Use the welcome offer.

            Full post:
            Original post

            Reply one

            Chat history:
            User:
            Is this still available?

            Assistant:
            The latest replies say yes.
            """
        )
    }

    func testTopicExportPayloadHonorsExclusionsAndMissingSections() throws {
        let payload = TopicExportPayload(
            summary: "",
            source: "Original post\n\nReply one",
            title: "Example discussion",
            url: try XCTUnwrap(URL(string: "https://forum.example.com/t/example/517303")),
            history: []
        )

        XCTAssertEqual(
            payload.text(
                options: ExportOptions(
                    excludeTitleAndURL: true,
                    excludeSummary: true,
                    excludeChatHistory: true
                )
            ),
            """
            Full post:
            Original post

            Reply one
            """
        )
        XCTAssertTrue(payload.hasContent(options: ExportOptions()))
        XCTAssertFalse(
            payload.hasContent(
                options: ExportOptions(
                    excludeTitleAndURL: true,
                    excludeSummary: true,
                    excludePostAndResponses: true,
                    excludeChatHistory: true
                )
            )
        )
    }

    func testForumPreviewUsesFirstAndLastFiftyLines() {
        let source = (1...125).map { "line \($0)" }.joined(separator: "\n")

        let preview = ForumPreview.compact(source)

        XCTAssertTrue(preview.hasPrefix("line 1\nline 2"))
        XCTAssertTrue(preview.contains("[… 25 middle lines omitted from the preview …]"))
        XCTAssertTrue(preview.hasSuffix("line 124\nline 125"))
        XCTAssertFalse(preview.contains("line 51\nline 52"))
    }

    func testStaleSummaryIsDerivedFromPostCounts() {
        var session = TopicSession(
            siteURL: "https://forum.example.com",
            topicID: "517303",
            url: URL(string: "https://forum.example.com/t/example/517303")!,
            title: "Example"
        )
        session.summary = "Summary"
        session.summaryPostCount = 100
        session.totalPosts = 101
        XCTAssertTrue(session.hasStaleSummary)

        session.totalPosts = 100
        XCTAssertFalse(session.hasStaleSummary)
    }

    func testStaleChatPromptLabelsSummaryAndSourceAuthority() {
        let prompt = PromptBuilder.chatSystem(
            custom: "",
            source: "Latest post and reply",
            summary: "Older summary",
            discussion: DiscourseAdapter().discussion,
            summaryIsStale: true
        )

        XCTAssertTrue(prompt.contains("SAVED SUMMARY (MAY BE STALE)"))
        XCTAssertTrue(prompt.contains("Treat the forum source as authoritative."))
        XCTAssertTrue(prompt.contains("Latest post and reply"))
    }

    func testPulledPostExportOmitsUnavailableSections() throws {
        let payload = TopicExportPayload(
            summary: "",
            source: "Original post\n\nReply one",
            title: "Example discussion",
            url: try XCTUnwrap(URL(string: "https://forum.example.com/t/example/517303")),
            history: []
        )

        XCTAssertEqual(
            payload.text(options: ExportOptions()),
            """
            Example discussion

            Post URL: https://forum.example.com/t/example/517303

            Full post:
            Original post

            Reply one
            """
        )
    }

    func testChatPromptCanUsePulledPostWithoutSummary() {
        let prompt = PromptBuilder.chatSystem(
            custom: "",
            source: "Original post\n\nReply one",
            summary: "",
            discussion: DiscourseAdapter().discussion
        )

        XCTAssertTrue(prompt.contains("No saved summary; rely on the forum source."))
        XCTAssertTrue(prompt.contains("Original post\n\nReply one"))
    }

    func testParsesTopicRoutesOnAnyForum() throws {
        let topic = ForumTopic.parse(
            url: try XCTUnwrap(URL(string: "https://forum.example.com/t/example/517303/42?x=1")),
            title: "Example"
        )
        XCTAssertEqual(topic?.topicID, "517303")
        XCTAssertEqual(topic?.siteURL, "https://forum.example.com")
        XCTAssertEqual(topic?.topicKey, "forum.example.com/t/517303")
        XCTAssertEqual(topic?.url.absoluteString, "https://forum.example.com/t/example/517303/42")

        // Any host: the page probe (not a host allow-list) decides it is Discourse.
        let meta = ForumTopic.parse(
            url: URL(string: "https://meta.discourse.org/t/some-topic/12345"),
            title: nil,
            forumName: "Discourse Meta"
        )
        XCTAssertEqual(meta?.siteURL, "https://meta.discourse.org")
        XCTAssertEqual(meta?.topicKey, "meta.discourse.org/t/12345")
        XCTAssertEqual(meta?.title, "Discourse Meta topic 12345")
        XCTAssertEqual(
            ForumTopic.parse(url: URL(string: "https://meta.discourse.org/t/12345"), title: " ")?.title,
            "meta.discourse.org topic 12345"
        )

        // Subfolder install.
        let folder = ForumTopic.parse(
            url: URL(string: "https://example.com/forum/t/hello/77?page=2"),
            title: "Hello",
            basePath: "/forum"
        )
        XCTAssertEqual(folder?.siteURL, "https://example.com/forum")
        XCTAssertEqual(folder?.topicKey, "example.com/forum/t/77")
        XCTAssertEqual(folder?.url.absoluteString, "https://example.com/forum/t/hello/77")
        XCTAssertNil(
            ForumTopic.parse(url: URL(string: "https://example.com/other/t/hello/77"), title: nil, basePath: "/forum")
        )

        XCTAssertNil(
            ForumTopic.parse(
                url: URL(string: "https://forum.example.com/latest"),
                title: nil
            )
        )
        // Plain http is only a forum on localhost.
        XCTAssertNil(ForumTopic.parse(url: URL(string: "http://example.com/t/a/1"), title: nil))
        XCTAssertEqual(
            ForumTopic.parse(url: URL(string: "http://localhost:3000/t/a/1"), title: nil)?.topicKey,
            "localhost:3000/t/1"
        )
    }

    func testCachePlanReusesOnlyImmutableFullPages() {
        let pages = [
            RawForumPage(page: 1, content: "one"),
            RawForumPage(page: 2, content: "two")
        ]
        XCTAssertEqual(
            DiscoursePagePlan.make(
                cachedPages: pages,
                knownTotalPosts: 200,
                currentTotalPosts: 200,
                totalPages: 2
            ),
            .unchanged
        )
        XCTAssertEqual(
            DiscoursePagePlan.make(
                cachedPages: pages,
                knownTotalPosts: 150,
                currentTotalPosts: 201,
                totalPages: 3
            ),
            .fetch(
                reusablePages: [RawForumPage(page: 1, content: "one")],
                pageNumbers: [2, 3]
            )
        )
        XCTAssertEqual(
            DiscoursePagePlan.make(
                cachedPages: pages,
                knownTotalPosts: 200,
                currentTotalPosts: 150,
                totalPages: 2
            ),
            .fetch(reusablePages: [], pageNumbers: [1, 2])
        )
        // A read cut short (same count): only the missing pages.
        XCTAssertEqual(
            DiscoursePagePlan.make(cachedPages: pages, knownTotalPosts: 250, currentTotalPosts: 250, totalPages: 3),
            .fetch(reusablePages: pages, pageNumbers: [3])
        )
        // No pages at all (dropped, or a session from another device): all of them.
        XCTAssertEqual(
            DiscoursePagePlan.make(cachedPages: [], knownTotalPosts: 250, currentTotalPosts: 260, totalPages: 3),
            .fetch(reusablePages: [], pageNumbers: [1, 2, 3])
        )
        // Pages carry the count they were read at: page 2 was the growing
        // last page at 150, whatever the session's count says now.
        let counted = [
            RawForumPage(page: 1, content: "one", topicPostCount: 150),
            RawForumPage(page: 2, content: "two", topicPostCount: 150)
        ]
        XCTAssertEqual(
            DiscoursePagePlan.make(cachedPages: counted, knownTotalPosts: 260, currentTotalPosts: 260, totalPages: 3),
            .fetch(reusablePages: [counted[0]], pageNumbers: [2, 3])
        )
        XCTAssertEqual(
            DiscoursePagePlan.make(cachedPages: counted, knownTotalPosts: 260, currentTotalPosts: 150, totalPages: 2),
            .unchanged
        )
    }

    func testBoundedForumContextPreservesBeginningAndLatestReplies() {
        let source = String(repeating: "A", count: 8_000)
            + String(repeating: "M", count: 10_000)
            + String(repeating: "Z", count: 8_000)
        let bounded = PromptBuilder.boundedForumContext(source, limit: 10_000)
        XCTAssertTrue(bounded.hasPrefix(String(repeating: "A", count: 5_000)))
        XCTAssertTrue(bounded.hasSuffix(String(repeating: "Z", count: 5_000)))
        XCTAssertTrue(bounded.contains("middle replies omitted"))

        // Values across the 5k...1M slider range are honored without secret clamping at 10k or 200k.
        let fiveK = PromptBuilder.boundedForumContext(source, limit: 5_000)
        XCTAssertTrue(fiveK.hasPrefix(String(repeating: "A", count: 2_500)))
        XCTAssertFalse(fiveK.hasPrefix(String(repeating: "A", count: 2_501)))

        let longSource = String(repeating: "B", count: 350_000)
        let fiveHundredK = PromptBuilder.boundedForumContext(longSource, limit: 500_000)
        XCTAssertEqual(fiveHundredK.count, 350_000)
        XCTAssertFalse(fiveHundredK.contains("middle replies omitted"))
    }

    func testLongSourceIsSplitWithoutLosingContent() {
        let source = (0..<300)
            .map { "Post \($0): \(String(repeating: "x", count: 100))" }
            .joined(separator: "\n\n\n")
        let chunks = PromptBuilder.splitForHierarchicalSummary(source, limit: 2_000)
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertEqual(chunks.joined(), source)
        XCTAssertTrue(chunks.allSatisfy { $0.count <= 2_000 })
    }

    func testPersistentStoreRoundTripsSessionsAndNeverPersistsAPIKeys() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let file = directory.appendingPathComponent("state.json")
        let store = PersistentStore(fileURL: file)
        var settings = AppSettings()
        var configuration = settings.configuration(for: .openAI)
        configuration.apiKey = "secret"
        settings.setConfiguration(configuration, for: .openAI)
        let session = TopicSession(
            siteURL: "https://forum.example.com",
            topicID: "123",
            url: try XCTUnwrap(URL(string: "https://forum.example.com/t/123")),
            title: "Saved"
        )

        try store.save(
            AppSnapshot(
                settings: settings.persistable,
                sessions: [session],
                activities: []
            )
        )
        let restored = store.load()
        XCTAssertEqual(restored.sessions.first?.topicID, "123")
        XCTAssertEqual(restored.sessions.first?.topicKey, "forum.example.com/t/123")
        XCTAssertEqual(restored.settings.configuration(for: .openAI).apiKey, "")
        let raw = try String(contentsOf: file, encoding: .utf8)
        XCTAssertFalse(raw.contains("secret"))
    }

    @MainActor
    func testDeleteActivityRemovesOnlyTerminalRecords() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = PersistentStore(fileURL: directory.appendingPathComponent("state.json"))
        let url = try XCTUnwrap(URL(string: "https://forum.example.com/t/activity/1"))

        var completed = WorkRecord(
            type: .summary,
            siteURL: "https://forum.example.com",
            topicID: "1",
            title: "Completed activity",
            url: url,
            provider: .openAI,
            model: "test-model"
        )
        completed.status = .completed

        let running = WorkRecord(
            type: .chat,
            siteURL: "https://forum.example.com",
            topicID: "1",
            title: "Running activity",
            url: url,
            provider: .openAI,
            model: "test-model"
        )
        try store.save(AppSnapshot(activities: [completed, running]))

        let app = AppModel(store: store)
        app.deleteActivity(id: completed.id)

        XCTAssertFalse(app.activities.contains { $0.id == completed.id })
        XCTAssertTrue(app.activities.contains { $0.id == running.id })

        app.deleteActivity(id: running.id)
        XCTAssertTrue(app.activities.contains { $0.id == running.id })
        XCTAssertEqual(store.load().activities.map(\.id), [running.id])
    }

    @MainActor
    func testSavedSummaryKeepUnkeepAndDeleteUpdateTheSessionStore() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = PersistentStore(fileURL: directory.appendingPathComponent("state.json"))
        let url = try XCTUnwrap(URL(string: "https://forum.example.com/t/saved/1"))
        var session = TopicSession(
            siteURL: "https://forum.example.com",
            topicID: "1",
            url: url,
            title: "Saved topic"
        )
        session.summary = "Saved summary"
        try store.save(AppSnapshot(sessions: [session]))

        let app = AppModel(store: store)
        app.setKept(true, topicKey: session.topicKey)
        XCTAssertTrue(app.sessions[session.topicKey]?.kept == true)
        app.setKept(false, topicKey: session.topicKey)
        XCTAssertFalse(app.sessions[session.topicKey]?.kept == true)
        app.deleteSession(topicKey: session.topicKey)
        XCTAssertNil(app.sessions[session.topicKey])
        XCTAssertTrue(store.load().sessions.isEmpty)
    }

    func testForumServiceFetchesEveryRawPage() async throws {
        let session = stubbedSession { request in
            if request.url?.path.hasSuffix(".json") == true {
                return Self.response(
                    request,
                    status: 200,
                    body: #"{"posts_count":101,"highest_post_number":101}"#
                )
            }
            let page = URLComponents(
                url: try XCTUnwrap(request.url),
                resolvingAgainstBaseURL: false
            )?.queryItems?.first(where: { $0.name == "page" })?.value
            return Self.response(request, status: 200, body: "raw-page-\(page ?? "?")")
        }
        let service = ForumService(session: session, pacer: ForumRequestPacer(clock: InstantPacingClock()))
        let result = try await DiscourseAdapter().readTopic(
            TopicReadRequest(
                topic: TopicRef(siteURL: "https://forum.example.com", topicID: "517303"),
                cachedPages: [],
                knownTotalPosts: nil
            ),
            net: service.net("https://forum.example.com", cookieHeader: "_forum_session=test"),
            progress: { _ in },
            onPage: nil
        )

        XCTAssertEqual(result.totalPosts, 101)
        XCTAssertEqual(result.rawPages.map(\.page), [1, 2])
        XCTAssertEqual(result.content, "raw-page-1\n\n\nraw-page-2")
        XCTAssertFalse(result.unchanged)
    }

    func testOpenAICompatibleStreamingIsDecoded() async throws {
        let session = stubbedSession { request in
            let body = """
            data: {"choices":[{"delta":{"content":"你"}}]}

            data: {"choices":[{"delta":{"content":"好"}}]}

            data: [DONE]

            """
            return Self.response(request, status: 200, body: body)
        }
        let service = AIService.allowingAll(session: session)
        let answer = try await service.answer(
            source: "forum",
            summary: "summary",
            history: [ChatMessage(role: .user, content: "question")],
            contextLimit: 10_000,
            customPrompt: "",
            discussion: DiscourseAdapter().discussion,
            configuration: ProviderConfiguration(
                model: "test-model",
                baseURL: "https://example.test/v1",
                apiKey: "key"
            ),
            provider: .openAI
        ) { _ in }
        XCTAssertEqual(answer, "你好")
    }

    func testSummaryRetriesWithAffordableTokenBudgetAfterProvider402() async throws {
        var attempts = 0
        let session = stubbedSession { request in
            attempts += 1
            if attempts == 1 {
                return Self.response(
                    request,
                    status: 402,
                    body: #"{"error":{"message":"This request requires more credits, or fewer max_tokens."}}"#
                )
            }

            return Self.response(
                request,
                status: 200,
                body: "data: {\"choices\":[{\"delta\":{\"content\":\"Summary\"}}]}\n\ndata: [DONE]\n"
            )
        }
        let service = AIService.allowingAll(session: session)

        let summary = try await service.generateSummary(
            content: "forum source",
            configuration: ProviderConfiguration(
                model: "test-model",
                baseURL: "https://example.test/v1",
                apiKey: "key"
            ),
            provider: .openAI,
            customPrompt: "",
            discussion: DiscourseAdapter().discussion
        ) { _ in }

        XCTAssertEqual(summary, "Summary")
        XCTAssertEqual(attempts, 2)
    }

    func testTaskLimiterSerializesSameTopicWithoutBlockingOtherTopics() async {
        let limiter = TaskLimiter(limit: 2)
        let (a, b, c, secondA) = (UUID(), UUID(), UUID(), UUID())
        let acquiredTopicA = await limiter.acquire(topicID: "topic-a", workID: a)
        let acquiredTopicB = await limiter.acquire(topicID: "topic-b", workID: b)
        XCTAssertTrue(acquiredTopicA)
        XCTAssertTrue(acquiredTopicB)

        let secondTopicA = Task {
            await limiter.acquire(topicID: "topic-a", workID: secondA)
        }
        for _ in 0..<100 {
            if await limiter.state().waitingTopics == ["topic-a"] { break }
            await Task.yield()
        }

        var state = await limiter.state()
        XCTAssertEqual(state.activeTopics, ["topic-a", "topic-b"])
        XCTAssertEqual(state.waitingTopics, ["topic-a"])

        await limiter.release(workID: b)
        let acquiredTopicC = await limiter.acquire(topicID: "topic-c", workID: c)
        XCTAssertTrue(acquiredTopicC)
        state = await limiter.state()
        XCTAssertEqual(state.activeTopics, ["topic-a", "topic-c"])
        XCTAssertEqual(state.waitingTopics, ["topic-a"])

        await limiter.release(workID: a)
        let acquiredSecondTopicA = await secondTopicA.value
        XCTAssertTrue(acquiredSecondTopicA)
        state = await limiter.state()
        XCTAssertEqual(state.activeTopics, ["topic-a", "topic-c"])
        XCTAssertTrue(state.waitingTopics.isEmpty)

        // A late release of a job that already gave its slot back is a no-op.
        await limiter.release(workID: a)
        state = await limiter.state()
        XCTAssertEqual(state.activeTopics, ["topic-a", "topic-c"])

        await limiter.release(workID: secondA)
        await limiter.release(workID: c)
    }

    /// Cancelling a running job frees its slot for the next one at once.
    func testTaskLimiterFreesACancelledRunningJobsSlot() async {
        let limiter = TaskLimiter(limit: 1)
        let running = UUID()
        let acquired = await limiter.acquire(topicID: "a", workID: running)
        XCTAssertTrue(acquired)
        let next = Task { await limiter.acquire(topicID: "b", workID: UUID()) }
        for _ in 0..<100 {
            if await limiter.state().waitingTopics == ["b"] { break }
            await Task.yield()
        }
        await limiter.cancel(workID: running)
        let nextAcquired = await next.value
        XCTAssertTrue(nextAcquired)
        let state = await limiter.state()
        XCTAssertEqual(state.activeTopics, ["b"])
    }

    @MainActor
    func testSplitLayoutIsReservedForIPadClassWindows() {
        XCTAssertTrue(ContentView.usesSplitLayout(width: 1_180, idiom: .pad))
        XCTAssertTrue(ContentView.usesSplitLayout(width: 850, idiom: .pad))
        XCTAssertFalse(ContentView.usesSplitLayout(width: 849, idiom: .pad))
        // An iPhone Pro Max in landscape is wider than the threshold but too
        // short for the side-by-side panel, so phones always use the switcher.
        XCTAssertFalse(ContentView.usesSplitLayout(width: 956, idiom: .phone))
        XCTAssertFalse(ContentView.usesSplitLayout(width: 402, idiom: .phone))
    }

    func testHierarchicalSplitHonorsBatchLimit() {
        let paragraph = String(repeating: "x", count: 9_000) + "\n\n\n"
        let content = String(repeating: paragraph, count: 10)

        XCTAssertEqual(PromptBuilder.splitForHierarchicalSummary(content).count, 2)
        XCTAssertEqual(PromptBuilder.splitForHierarchicalSummary(content, limit: 20_000).count, 5)
        XCTAssertEqual(PromptBuilder.splitForHierarchicalSummary(content, limit: 200_000).count, 1)
        XCTAssertEqual(
            PromptBuilder.splitForHierarchicalSummary(content, limit: 20_000).joined().count,
            content.count
        )
    }

    func testDiscourseRawPostsSplitOnPostBoundariesNotMidSentence() {
        let post1 = "alice | 2026-03-01 10:00:00 UTC | #1\n\nOpening question with a complete first sentence."
        let post2 = "bob | 2026-03-01 10:05:00 UTC | #2\n\nDetailed second post body that must stay together."
        let post3 = "carol | 2026-03-01 10:10:00 UTC | #3\n\nClosing confirmation."
        let raw = [post1, post2, post3].joined(separator: "\n\n-------------------------\n\n")

        let batches = PromptBuilder.splitForHierarchicalSummary(raw, limit: 130)

        XCTAssertGreaterThanOrEqual(batches.count, 2)
        XCTAssertFalse(
            batches[0].contains("bob |"),
            "First batch should split at the Discourse post separator before #2, got: \(batches[0])"
        )
        XCTAssertTrue(
            batches[1].hasPrefix("bob | 2026-03-01 10:05:00 UTC | #2"),
            "Second batch should start cleanly at post #2's header, got: \(batches[1])"
        )
        XCTAssertEqual(batches.joined(), raw)

        let normalized = DiscourseParsing.normalizeRawPage(raw + "\n\n-------------------------\n")
        let normalizedBatches = PromptBuilder.splitForHierarchicalSummary(normalized, limit: 110)
        XCTAssertGreaterThanOrEqual(normalizedBatches.count, 2)
        XCTAssertTrue(normalizedBatches[0].hasSuffix(RawTopicFormat.blockSeparator))
        XCTAssertTrue(normalizedBatches[1].hasPrefix("bob | 2026-03-01 10:05:00 UTC | #2"))
    }

    func testTypedAddressesResolveAgainstTheCurrentForum() {
        let forum = "https://forum.example.com"
        func resolve(_ address: String, _ site: String? = forum) -> String? {
            ForumBrowserModel.resolveAddress(address, currentSiteURL: site)?.absoluteString
        }
        XCTAssertEqual(resolve("https://forum.example.com/t/abc/123"), "https://forum.example.com/t/abc/123")
        XCTAssertEqual(resolve("  example.org/latest "), "https://example.org/latest")
        XCTAssertEqual(resolve("/t/abc/123"), "https://forum.example.com/t/abc/123")
        XCTAssertEqual(resolve("t/abc/123"), "https://forum.example.com/t/abc/123")
        // Any site may be opened; bare hosts get https.
        XCTAssertEqual(resolve("https://example.com/t/abc/123"), "https://example.com/t/abc/123")
        XCTAssertEqual(resolve("meta.discourse.org/t/x/5"), "https://meta.discourse.org/t/x/5")
        XCTAssertEqual(resolve("localhost:3000/latest", nil), "http://localhost:3000/latest")
        // Paths follow the current forum, including its base path.
        let folder = "https://example.com/forum"
        XCTAssertEqual(resolve("/t/abc/9", folder), "https://example.com/forum/t/abc/9")
        XCTAssertEqual(resolve("/forum/t/abc/9", folder), "https://example.com/forum/t/abc/9")
        XCTAssertEqual(resolve("latest/x", folder), "https://example.com/forum/latest/x")
        XCTAssertEqual(resolve("/t/abc/9", "https://meta.discourse.org"), "https://meta.discourse.org/t/abc/9")
        // No forum → paths do nothing; plain words never become a web search.
        XCTAssertNil(resolve("/t/abc/123", nil))
        XCTAssertNil(resolve("amex platinum"))
        XCTAssertNil(resolve("hello"))
        XCTAssertNil(resolve(""))
        XCTAssertNil(resolve("ftp://forum.example.com/latest"))
        XCTAssertNil(resolve("javascript:alert(1)"))
        XCTAssertNil(resolve("mailto:a@b.c"))
    }

    // MARK: Agent

    func testAgentActionParserToleratesFencesProseAndAliases() throws {
        let fenced = """
        Sure, here is my next step:
        ```json
        {"thought": "search first", "tool": "search_forum", "arguments": {"query": "amex platinum"}}
        ```
        """
        let action = try AgentActionParser.parse(fenced)
        XCTAssertEqual(action.tool, "search_forum")
        XCTAssertEqual(action.arguments["query"], "amex platinum")
        XCTAssertEqual(action.thought, "search first")

        let numeric = try AgentActionParser.parse(
            #"{"tool":"read_topic","arguments":{"topic_id":12345}}"#
        )
        XCTAssertEqual(numeric.arguments["topic_id"], "12345")

        let direct = try AgentActionParser.parse(
            "{\"thought\":\"done\",\"tool\":\"final_answer\",\"answer\":\"## Result\"}"
        )
        XCTAssertEqual(direct.arguments["answer"], "## Result")

        let nested = try AgentActionParser.parse(
            #"prefix {"action":"saved_summaries","args":{"query":"x \"quoted\" {y}"}} suffix"#
        )
        XCTAssertEqual(nested.tool, "saved_summaries")
        XCTAssertEqual(nested.arguments["query"], "x \"quoted\" {y}")

        XCTAssertThrowsError(try AgentActionParser.parse("I do not know what to do."))
        XCTAssertThrowsError(try AgentActionParser.parse(#"{"arguments":{}}"#))
    }

    func testAgentSystemPromptListsToolsAndBudget() {
        let prompt = AgentPrompt.system(
            profile: DiscourseAgent.profile,
            forumName: "Discourse Meta",
            siteURL: "https://meta.discourse.org",
            maxSteps: 7,
            maxTopicReads: 3,
            customInstructions: "Be terse."
        )
        for tool in AgentPrompt.tools(for: DiscourseAgent.profile) {
            XCTAssertTrue(prompt.contains(tool.name), "Prompt is missing \(tool.name)")
        }
        XCTAssertTrue(prompt.contains("at most 7 tool calls and 3 topic reads"))
        XCTAssertTrue(prompt.contains("Be terse."))
        XCTAssertFalse(AgentPrompt.tools(for: DiscourseAgent.profile).contains { $0.requiresApproval })
        // Templated on the run's forum; no single-forum or fixed-language assumptions.
        XCTAssertTrue(prompt.contains("research agent for Discourse Meta (https://meta.discourse.org)"))
        XCTAssertTrue(prompt.contains("same language as the user's question"))
        XCTAssertFalse(prompt.contains("Chinese"))
    }

    func testForumSearchAndLatestParsing() {
        let search = """
        {"posts":[{"topic_id":42,"blurb":"Retention offer 55k points"}],
         "topics":[{"id":42,"title":"Amex Platinum retention DP","slug":"amex-platinum-retention-dp",
                    "posts_count":88,"last_posted_at":"2026-09-12T10:00:00.000Z"},
                   {"id":7,"fancy_title":"No blurb topic","posts_count":3}]}
        """
        let listings = DiscourseParsing.parseSearchResults(
            Data(search.utf8),
            siteURL: "https://forum.example.com"
        )
        XCTAssertEqual(listings.map(\.id), [42, 7])
        XCTAssertEqual(listings[0].excerpt, "Retention offer 55k points")
        XCTAssertEqual(listings[0].url.absoluteString,
                       "https://forum.example.com/t/amex-platinum-retention-dp/42")
        XCTAssertNil(listings[1].excerpt)
        XCTAssertEqual(listings[1].slug, "7")

        let latest = """
        {"topic_list":{"topics":[{"id":1,"title":"A","slug":"a","posts_count":2,"bumped_at":"2026-09-13T01:00:00Z"}]}}
        """
        let recent = DiscourseParsing.parseTopicList(Data(latest.utf8), siteURL: "https://example.com/forum")
        XCTAssertEqual(recent.count, 1)
        XCTAssertEqual(recent[0].url.absoluteString, "https://example.com/forum/t/a/1")
        XCTAssertEqual(recent[0].lastPostedAt, "2026-09-13T01:00:00Z")
        XCTAssertTrue(AgentPrompt.format(listings: recent).contains("id 1: A — 2 posts"))
        XCTAssertEqual(AgentPrompt.format(listings: []), "No topics found.")
    }

    func testWatchedTopicCountsOnlyNewReplies() {
        var watched = WatchedTopic(
            siteURL: "https://forum.example.com",
            topicID: "1",
            url: URL(string: "https://forum.example.com/t/a/1")!,
            title: "A",
            knownPostCount: 10
        )
        XCTAssertEqual(watched.record(postCount: 10), 0)
        XCTAssertEqual(watched.newReplies, 0)
        XCTAssertEqual(watched.record(postCount: 13), 3)
        XCTAssertEqual(watched.record(postCount: 14), 1)
        XCTAssertEqual(watched.newReplies, 4)
        XCTAssertEqual(watched.knownPostCount, 14)
        // A lower count (deleted posts) never produces negative arrivals.
        XCTAssertEqual(watched.record(postCount: 12), 0)
        watched.markSeen()
        XCTAssertEqual(watched.newReplies, 0)
        XCTAssertNotNil(watched.lastCheckedAt)
    }

    func testSnapshotsWithoutAgentDataStillDecode() throws {
        let json = #"{"settings":{"assistantModel":{"provider":"groq","model":"m"}},"sessions":[],"activities":[]}"#
        let snapshot = try JSONDecoder().decode(AppSnapshot.self, from: Data(json.utf8))
        XCTAssertEqual(snapshot.settings.assistantModel.provider, .groq)
        XCTAssertEqual(snapshot.settings.agentMaxSteps, AgentLimits.defaultMaxSteps)
        XCTAssertTrue(snapshot.settings.watchAutoRefreshSummaries)
        XCTAssertTrue(snapshot.agentRuns.isEmpty)
        XCTAssertTrue(snapshot.watchedTopics.isEmpty)
    }

    @MainActor
    func testAgentRunSearchesReadsAndAnswersWithScriptedPlanner() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = PersistentStore(fileURL: directory.appendingPathComponent("state.json"))
        var seeded = AppSnapshot()
        seeded.ensureForum("https://forum.example.com")
        try store.save(seeded)
        let session = stubbedSession { request in
            let path = request.url?.path ?? ""
            if path == "/search.json" {
                return Self.response(
                    request,
                    status: 200,
                    body: #"{"posts":[{"topic_id":12,"blurb":"DP inside"}],"topics":[{"id":12,"title":"Retention DP","slug":"retention-dp","posts_count":2}]}"#
                )
            }
            if path == "/t/12.json" {
                return Self.response(
                    request,
                    status: 200,
                    body: #"{"title":"Retention DP","slug":"retention-dp","posts_count":2}"#
                )
            }
            if path == "/raw/12" {
                return Self.response(request, status: 200, body: "Post 1: offer was 55k\n\n\nPost 2: took it")
            }
            return Self.response(request, status: 404, body: "missing")
        }
        let planner = ScriptedPlanner(actions: [
            AgentAction(thought: "search", tool: "search_forum", arguments: ["query": "retention"]),
            AgentAction(thought: "read", tool: "read_topic", arguments: ["topic_id": "12"]),
            AgentAction(thought: "unknown", tool: "post_reply", arguments: [:]),
            AgentAction(
                thought: "done",
                tool: AgentPrompt.finalAnswerTool,
                arguments: ["answer": "Offer was **55k** ([Retention DP](https://forum.example.com/t/retention-dp/12))"]
            )
        ])
        let app = AppModel(
            store: store,
            forumService: ForumService(session: session, pacer: ForumRequestPacer(clock: InstantPacingClock())),
            aiService: AIService(session: session),
            planner: planner
        )
        app.usesDirectForumRequests = true
        app.allowAllAIProviders()
        var settings = app.settings
        settings.configurations["openrouter"] = ProviderConfiguration(
            model: "test-model", baseURL: "https://example.com/v1", apiKey: "key"
        )
        app.settings = settings

        app.startAgentRun(
            goal: "What retention offers are people reporting?",
            siteURL: "https://forum.example.com"
        )
        let run = try await waitForTerminalAgentRun(in: app)

        XCTAssertEqual(run.result, .completed)
        XCTAssertEqual(run.steps.map(\.tool), ["search_forum", "read_topic", "post_reply", "final_answer"])
        XCTAssertEqual(run.steps[0].outcome, "1 topic")
        XCTAssertEqual(run.steps[1].outcome, "Read 2 posts")
        XCTAssertTrue(run.steps[2].isError)
        XCTAssertTrue(run.steps[2].outcome.contains("Unknown tool"))
        XCTAssertEqual(run.topicIDs, ["12"])
        XCTAssertTrue(run.answer.contains("55k"))
        XCTAssertEqual(run.initialAnswer, run.answer)
        XCTAssertEqual(run.siteURL, "https://forum.example.com")
        XCTAssertEqual(run.steps[1].topicKey, "forum.example.com/t/12")
        XCTAssertEqual(
            app.sessions["forum.example.com/t/12"]?.source,
            "Post 1: offer was 55k\n\n\nPost 2: took it"
        )
        XCTAssertEqual(app.sessions["forum.example.com/t/12"]?.title, "Retention DP")
        XCTAssertTrue(app.activities.contains { $0.type == .agent && $0.status == .completed })

        // The planner saw the goal, its own actions, and the observations.
        let transcript = planner.lastTranscript
        XCTAssertTrue(transcript.first?.content.contains("GOAL:") ?? false)
        XCTAssertTrue(transcript.contains { $0.content.contains("OBSERVATION from search_forum") })
        XCTAssertTrue(transcript.contains { $0.content.contains("ERROR from post_reply") })

        // Persisted and reloadable.
        let reloaded = AppModel(store: store, planner: planner)
        XCTAssertEqual(reloaded.agentRuns.first?.answer, run.answer)
        XCTAssertEqual(reloaded.selectedAgentRun?.id, run.id)
    }

    @MainActor
    private func waitForTerminalAgentRun(in app: AppModel, timeout: TimeInterval = 20) async throws -> AgentRun {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let run = app.agentRuns.first, run.isFinished { return run }
            try await Task.sleep(for: .milliseconds(50))
        }
        return try XCTUnwrap(app.agentRuns.first, "No agent run was created.")
    }

    func testNVIDIAProviderUsesOpenAICompatibleDefaults() {
        let configuration = ProviderConfiguration(provider: .nvidia)
        XCTAssertEqual(configuration.baseURL, "https://integrate.api.nvidia.com/v1")
        XCTAssertEqual(configuration.model, "deepseek-ai/deepseek-v4-flash-0731")
        XCTAssertTrue(AIProvider.nvidia.requiresAPIKey)
        XCTAssertEqual(AIProvider.nvidia.displayName, "NVIDIA NIM")
        XCTAssertEqual(AIProvider(rawValue: "nvidia"), .nvidia)
        // Existing settings snapshots gain the provider with its defaults.
        XCTAssertEqual(AppSettings().configuration(for: .nvidia).baseURL, configuration.baseURL)
    }

    /// Opt-in live check: set TEST_RUNNER_NVIDIA_API_KEY (e.g. from `op read`)
    /// when running xcodebuild; skipped otherwise.
    @MainActor
    func testNVIDIAProviderLiveDiscoveryAndStreaming() async throws {
        guard let apiKey = ProcessInfo.processInfo.environment["NVIDIA_API_KEY"],
              !apiKey.isEmpty
        else {
            throw XCTSkip("NVIDIA_API_KEY is not set for the test runner.")
        }
        var configuration = ProviderConfiguration(provider: .nvidia)
        configuration.apiKey = apiKey
        let service = AIService()

        let models = try await service.discoverModels(configuration: configuration, provider: .nvidia)
        XCTAssertFalse(models.isEmpty)
        XCTAssertTrue(models.contains(configuration.model), "Default model is not offered: \(models.prefix(5))")

        try await service.testConnection(configuration: configuration, provider: .nvidia)

        var streamed = ""
        let answer = try await service.answer(
            source: "Post 1: The welcome offer is 80k points after $6k spend.",
            summary: "",
            history: [ChatMessage(role: .user, content: "Reply with only the number of points in the welcome offer.")],
            contextLimit: 10_000,
            customPrompt: "",
            discussion: DiscourseAdapter().discussion,
            configuration: configuration,
            provider: .nvidia,
            onDelta: { delta in streamed += delta }
        )
        XCTAssertTrue(answer.contains("80"), "Unexpected answer: \(answer.prefix(200))")
        XCTAssertFalse(streamed.isEmpty, "Streaming produced no content deltas.")
    }

    func testVertexAIProviderDefaultsAndBuiltInModels() async throws {
        let configuration = ProviderConfiguration(provider: .vertexAI)
        XCTAssertEqual(configuration.baseURL, "https://aiplatform.googleapis.com/v1")
        XCTAssertEqual(configuration.model, "gemini-2.5-flash")
        XCTAssertTrue(AIProvider.vertexAI.requiresAPIKey)
        XCTAssertEqual(AIProvider(rawValue: "vertexai"), .vertexAI)
        XCTAssertTrue(AIProvider.vertexAIModels.contains(configuration.model))
        // The list is built in: no request is made.
        let session = stubbedSession { _ in
            XCTFail("Vertex AI model listing should not reach the network")
            throw URLError(.badServerResponse)
        }
        let models = try await AIService(session: session).discoverModels(configuration: configuration, provider: .vertexAI)
        XCTAssertEqual(models, AIProvider.vertexAIModels)
    }

    func testVertexAIStreamsGeminiEventsWithHeaderKey() async throws {
        var configuration = ProviderConfiguration(provider: .vertexAI)
        configuration.apiKey = "vertex-test-key"
        var seen: URLRequest?
        let session = stubbedSession { request in
            seen = request
            let events = [
                #"data: {"candidates":[{"content":{"role":"model","parts":[{"text":"Hello"}]}}]}"#,
                "",
                #"data: {"candidates":[{"content":{"role":"model","parts":[{"text":" there"}]}}]}"#,
                ""
            ].joined(separator: "\n")
            return Self.response(request, status: 200, body: events)
        }
        let text = try await AIService.allowingAll(session: session).complete(
            system: "Be brief.",
            messages: [ChatMessage(role: .user, content: "Hi")],
            configuration: configuration,
            provider: .vertexAI
        )
        XCTAssertEqual(text, "Hello there")
        let request = try XCTUnwrap(seen)
        XCTAssertEqual(
            request.url?.absoluteString,
            "https://aiplatform.googleapis.com/v1/publishers/google/models/gemini-2.5-flash:streamGenerateContent?alt=sse"
        )
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-goog-api-key"), "vertex-test-key")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }

    func testVertexAIConnectionTestChecksTheKeyWithCountTokens() async throws {
        var configuration = ProviderConfiguration(provider: .vertexAI)
        configuration.baseURL = "https://aiplatform.googleapis.com/v1/projects/demo/locations/global/"
        configuration.apiKey = "bad-key"
        var seen: URLRequest?
        let session = stubbedSession { request in
            seen = request
            return Self.response(request, status: 400, body: #"{"error":{"message":"API key not valid."}}"#)
        }
        do {
            try await AIService(session: session).testConnection(configuration: configuration, provider: .vertexAI)
            XCTFail("A rejected key must fail the connection test")
        } catch AssistantError.http(let status, let message) {
            XCTAssertEqual(status, 400)
            XCTAssertTrue(message.contains("API key not valid"))
        }
        XCTAssertEqual(
            seen?.url?.absoluteString,
            "https://aiplatform.googleapis.com/v1/projects/demo/locations/global/publishers/google/models/gemini-2.5-flash:countTokens"
        )
        XCTAssertEqual(seen?.httpMethod, "POST")
    }

    /// Opt-in live check: set TEST_RUNNER_VERTEX_API_KEY when running
    /// xcodebuild; skipped otherwise. TEST_RUNNER_VERTEX_BASE_URL overrides
    /// the express-mode host (for a project and location path).
    @MainActor
    func testVertexAIProviderLiveConnectionAndStreaming() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let apiKey = environment["VERTEX_API_KEY"], !apiKey.isEmpty else {
            throw XCTSkip("VERTEX_API_KEY is not set for the test runner.")
        }
        var configuration = ProviderConfiguration(provider: .vertexAI)
        configuration.apiKey = apiKey
        if let base = environment["VERTEX_BASE_URL"], !base.isEmpty { configuration.baseURL = base }
        if let model = environment["VERTEX_MODEL"], !model.isEmpty { configuration.model = model }
        let service = AIService()

        try await service.testConnection(configuration: configuration, provider: .vertexAI)

        var streamed = ""
        let answer = try await service.answer(
            source: "Post 1: The welcome offer is 80k points after $6k spend.",
            summary: "",
            history: [ChatMessage(role: .user, content: "Reply with only the number of points in the welcome offer.")],
            contextLimit: 10_000,
            customPrompt: "",
            discussion: DiscourseAdapter().discussion,
            configuration: configuration,
            provider: .vertexAI,
            onDelta: { delta in streamed += delta }
        )
        XCTAssertTrue(answer.contains("80"), "Unexpected answer: \(answer.prefix(200))")
        XCTAssertFalse(streamed.isEmpty, "Streaming produced no content deltas.")
    }

    func testSummaryBatchLimitNormalizationAndLabels() {
        XCTAssertEqual(SummaryBatchLimit.normalized(1), SummaryBatchLimit.minimum)
        XCTAssertEqual(SummaryBatchLimit.normalized(5_000_000), SummaryBatchLimit.maximum)
        XCTAssertEqual(SummaryBatchLimit.normalized(55_000), 55_000)
        XCTAssertEqual(SummaryBatchLimit.maximum, 1_000_000)
        XCTAssertEqual(SummaryBatchLimit.label(55_000), "55k characters")
        XCTAssertEqual(SummaryBatchLimit.label(1_000_000), "1M characters")
        XCTAssertTrue(SummaryBatchLimit.presets.contains(SummaryBatchLimit.default))
    }

    func testTopicInstructionsOverrideGlobalOnlyWhenSet() {
        XCTAssertEqual(
            PromptBuilder.effectiveInstructions(topic: "  ", global: "global"),
            "global"
        )
        XCTAssertEqual(
            PromptBuilder.effectiveInstructions(topic: " topic ", global: "global"),
            "topic"
        )
        XCTAssertEqual(PromptBuilder.effectiveInstructions(topic: "", global: ""), "")
    }

    func testOlderSnapshotsDecodeWithDefaultsForNewFields() throws {
        let json = """
        {
          "assistantModel": {"provider": "openai", "model": "gpt-test"},
          "favoriteModels": [],
          "systemPrompt": "keep it short",
          "forumContextLimit": 40000
        }
        """
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        XCTAssertEqual(settings.assistantModel.provider, .openAI)
        XCTAssertEqual(settings.systemPrompt, "keep it short")
        XCTAssertEqual(settings.forumContextLimit, 40_000)
        XCTAssertEqual(settings.summaryBatchLimit, SummaryBatchLimit.default)
        XCTAssertEqual(settings.browserBarPosition, AppSettings().browserBarPosition)

        let sessionJSON = """
        {
          "siteURL": "https://forum.example.com",
          "topicID": "1",
          "url": "https://forum.example.com/t/a/1",
          "title": "A",
          "summary": "s",
          "kept": true
        }
        """
        let decoder = JSONDecoder()
        let session = try decoder.decode(TopicSession.self, from: Data(sessionJSON.utf8))
        XCTAssertEqual(session.summary, "s")
        XCTAssertTrue(session.kept)
        XCTAssertEqual(session.instructions, "")
        XCTAssertFalse(session.hasInstructions)
        XCTAssertTrue(session.history.isEmpty)

        // A full round trip through the app's ISO-8601 coding keeps the new fields.
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let isoDecoder = JSONDecoder()
        isoDecoder.dateDecodingStrategy = .iso8601
        var updated = session
        updated.instructions = "focus on fees"
        var settingsCopy = AppSettings()
        settingsCopy.summaryBatchLimit = 100_000
        settingsCopy.browserBarPosition = .bottom
        let roundTrippedSession = try isoDecoder.decode(
            TopicSession.self,
            from: encoder.encode(updated)
        )
        let roundTrippedSettings = try isoDecoder.decode(
            AppSettings.self,
            from: encoder.encode(settingsCopy)
        )
        XCTAssertEqual(roundTrippedSession.instructions, "focus on fees")
        XCTAssertEqual(roundTrippedSettings.summaryBatchLimit, 100_000)
        XCTAssertEqual(roundTrippedSettings.browserBarPosition, .bottom)
    }

    func testTaskLimiterRemovesCancelledQueuedWork() async {
        let limiter = TaskLimiter(limit: 1)
        let runningID = UUID()
        let acquiredRunningTopic = await limiter.acquire(
            topicID: "running-topic",
            workID: runningID
        )
        XCTAssertTrue(acquiredRunningTopic)

        let waitingID = UUID()
        let queued = Task {
            await limiter.acquire(topicID: "queued-topic", workID: waitingID)
        }
        for _ in 0..<100 {
            if await limiter.state().waitingTopics == ["queued-topic"] { break }
            await Task.yield()
        }

        await limiter.cancel(workID: waitingID)
        let acquiredQueuedTopic = await queued.value
        XCTAssertFalse(acquiredQueuedTopic)
        let state = await limiter.state()
        XCTAssertEqual(state.activeTopics, ["running-topic"])
        XCTAssertTrue(state.waitingTopics.isEmpty)

        await limiter.release(workID: runningID)
    }

    private func stubbedSession(
        handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> URLSession {
        URLProtocolStub.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        return URLSession(configuration: configuration)
    }

    private static func response(
        _ request: URLRequest,
        status: Int,
        body: String
    ) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        return (response, Data(body.utf8))
    }
}

/// Replays a fixed list of actions and records what the run showed it.
private final class ScriptedPlanner: AgentPlanner, @unchecked Sendable {
    private var actions: [AgentAction]
    private(set) var lastTranscript: [ChatMessage] = []

    init(actions: [AgentAction]) {
        self.actions = actions
    }

    func nextAction(
        system: String,
        transcript: [ChatMessage],
        configuration: ProviderConfiguration,
        provider: AIProvider
    ) async throws -> AgentAction {
        lastTranscript = transcript
        guard !actions.isEmpty else {
            return AgentAction(thought: "out of script", tool: AgentPrompt.finalAnswerTool, arguments: ["answer": "n/a"])
        }
        return actions.removeFirst()
    }
}

private final class URLProtocolStub: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let (response, data) = try Self.handler!(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private final class HeldChatAIStub: AIService, @unchecked Sendable {
    private var continuation: CheckedContinuation<Void, Never>?

    func finish() {
        continuation?.resume()
        continuation = nil
    }

    override func answer(
        source: String,
        summary: String,
        history: [ChatMessage],
        contextLimit: Int,
        customPrompt: String,
        discussion: DiscussionProfile,
        configuration: ProviderConfiguration,
        provider: AIProvider,
        onDelta: @escaping @MainActor (String) -> Void,
        summaryIsStale: Bool = false
    ) async throws -> String {
        await withCheckedContinuation { continuation = $0 }
        return "Done."
    }
}

// MARK: - Lazy Markdown & Assistant Scroll Regressions

final class LazyMarkdownTests: XCTestCase {
    override func tearDown() {
        URLProtocolStub.handler = nil
        super.tearDown()
    }

    @MainActor
    private func findScrollView(in view: UIView) -> UIScrollView? {
        if let scroll = view as? UIScrollView, scroll.bounds.height > 200 {
            return scroll
        }
        for subview in view.subviews {
            if let found = findScrollView(in: subview) { return found }
        }
        return nil
    }

    private func makeLongSummary(prefix: String = "Section") -> String {
        var lines = ["## Original post"]
        for section in 1...40 {
            lines.append("\n## \(prefix) \(section)")
            for point in 1...6 {
                lines.append("- Readers report that the card works well, posts the bonus reliably after statement close, and waives the first-year fee #\(section * point) #\(section + point + 40)")
            }
        }
        return lines.joined(separator: "\n")
    }

    private func makeStubbedForumService(postsCount: Int = 1, bodyText: String = "alice | 2026-10-20 | #1\nPost A1") -> ForumService {
        URLProtocolStub.handler = { request in
            let path = request.url?.path ?? ""
            let body = path.hasSuffix(".json")
                ? #"{"title":"Topic A","slug":"topic-a","posts_count":\#(postsCount),"highest_post_number":\#(postsCount)}"#
                : bodyText
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(body.utf8))
        }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [URLProtocolStub.self]
        return ForumService(session: URLSession(configuration: cfg), pacer: ForumRequestPacer(clock: InstantPacingClock()))
    }

    @MainActor
    private func makeTwoTopicApp(
        summaryA: String,
        historyA: [ChatMessage],
        summaryB: String,
        historyB: [ChatMessage],
        aiService: AIService = AIService(),
        forumService: ForumService? = nil
    ) throws -> (AppModel, ForumTopic, ForumTopic, ((PageContext) -> Void)?) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = PersistentStore(fileURL: directory.appendingPathComponent("state.json"), keys: InMemoryProviderKeyStore())
        let siteURL = "https://forum.example.com"
        let urlA = try XCTUnwrap(URL(string: "\(siteURL)/t/topic-a/42"))
        let urlB = try XCTUnwrap(URL(string: "\(siteURL)/t/topic-b/43"))
        let topicA = ForumTopic(siteURL: siteURL, topicID: "42", url: urlA, title: "Topic A")
        let topicB = ForumTopic(siteURL: siteURL, topicID: "43", url: urlB, title: "Topic B")

        var sessionA = TopicSession(siteURL: siteURL, topicID: "42", url: urlA, title: "Topic A")
        sessionA.source = "alice | 2026-10-20 | #1\nPost A1"
        sessionA.summary = summaryA
        sessionA.totalPosts = 500
        sessionA.summaryPostCount = 500
        sessionA.summaryUpdatedAt = Date()
        sessionA.model = "test-model"
        sessionA.history = historyA

        var sessionB = TopicSession(siteURL: siteURL, topicID: "43", url: urlB, title: "Topic B")
        sessionB.source = "bob | 2026-10-20 | #1\nPost B1"
        sessionB.summary = summaryB
        sessionB.totalPosts = 500
        sessionB.summaryPostCount = 500
        sessionB.summaryUpdatedAt = Date()
        sessionB.model = "test-model"
        sessionB.history = historyB

        var snapshot = AppSnapshot()
        snapshot.forums = [Forum(siteURL: siteURL, kind: .discourse, name: "Forum")]
        snapshot.sessions = [sessionA, sessionB]
        try store.save(snapshot)

        let app = if let forumService {
            AppModel(store: store, forumService: forumService, aiService: aiService)
        } else {
            AppModel(store: store, aiService: aiService)
        }
        app.usesDirectForumRequests = true
        let handler = app.browser.onPageContextChanged
        app.browser.onPageContextChanged = nil
        app.allowAllAIProviders()
        app.selectModel(ModelSelection(provider: .ollama, model: "test-model"), for: .both)
        let pageA = PageContext(url: urlA, site: .discourse, siteURL: siteURL, forumName: "Forum", topic: topicA, state: .topic)
        app.browser.setPageContext(pageA)
        handler?(pageA)
        return (app, topicA, topicB, handler)
    }

    // Finding 2: Sending a follow-up chat message or tapping chatScrollToBottom over a long lazy
    // summary with an offscreen multi-paragraph ChatBubble must reach chatBottom instead of stopping short.
    @MainActor
    func testSendChatOverUniformLazySummaryReachesChatBottom() throws {
        let forumService = makeStubbedForumService()
        let ai = HeldChatAIStub()
        let (app, _, _, _) = try makeTwoTopicApp(
            summaryA: makeLongSummary(),
            historyA: [
                ChatMessage(role: .user, content: "First question"),
                ChatMessage(role: .assistant, content: String(repeating: "Detailed earlier assistant paragraph with citations #1 #2 that wraps across multiple lines.\n\n", count: 30))
            ],
            summaryB: "",
            historyB: [],
            aiService: ai,
            forumService: forumService
        )

        let (window, host) = hostView(
            AssistantPanel(app: app, onExpand: { _ in }),
            size: CGSize(width: 393, height: 740)
        )
        defer { window.isHidden = true }

        let scrollView = try XCTUnwrap(findScrollView(in: host.view))
        app.drafts.chat = "Does my follow-up reach the viewport?"
        app.sendChat()
        // Wait for the jump to settle rather than a fixed time: on a loaded
        // machine the settle loop can still be running at 0.8 s. A jump that
        // freezes short (the bug this pins) never gets closer, so the 3 s cap
        // still fails it.
        func distanceToBottom() -> CGFloat {
            window.layoutIfNeeded()
            return scrollView.contentSize.height - (scrollView.contentOffset.y + scrollView.bounds.height)
        }
        let deadline = Date().addingTimeInterval(3)
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        while distanceToBottom() >= 48, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }

        XCTAssertNotNil(app.activities.first { $0.type == .chat && $0.status == .running })
        let distance = distanceToBottom()
        ai.finish()

        XCTAssertLessThan(
            distance,
            48,
            "After sendChat() from top of a long summary with an offscreen multi-paragraph ChatBubble, jumpToBottom stopped \(distance) pt short of chatBottom (offsetY=\(scrollView.contentOffset.y), contentHeight=\(scrollView.contentSize.height))!"
        )
    }

    // Finding 3a: Switching topics with different chat history counts starts at the top of the new topic's summary.
    @MainActor
    func testTopicSwitchWithDifferentChatHistoryCountDoesNotJumpToBottomOfSummary() throws {
        let (app, topicA, topicB, handler) = try makeTwoTopicApp(
            summaryA: makeLongSummary(prefix: "TopicA"),
            historyA: [
                ChatMessage(role: .user, content: "Question on A?"),
                ChatMessage(role: .assistant, content: "Answer on A.")
            ],
            summaryB: makeLongSummary(prefix: "TopicB"),
            historyB: []
        )

        let (window, host) = hostView(
            AssistantPanel(app: app, onExpand: { _ in }),
            size: CGSize(width: 393, height: 740)
        )
        defer { window.isHidden = true }

        let scrollViewA = try XCTUnwrap(findScrollView(in: host.view))
        scrollViewA.setContentOffset(CGPoint(x: 0, y: 1200), animated: false)
        window.layoutIfNeeded()

        let pageB = PageContext(
            url: topicB.url,
            site: .discourse,
            siteURL: topicB.siteURL,
            forumName: "Forum",
            topic: topicB,
            state: .topic
        )
        app.browser.setPageContext(pageB)
        handler?(pageB)

        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        window.layoutIfNeeded()

        let scrollViewB = try XCTUnwrap(findScrollView(in: host.view))
        XCTAssertLessThan(
            scrollViewB.contentOffset.y,
            20,
            "Opening Topic B (2 -> 0 messages) must start at the top of its summary; offsetY=\(scrollViewB.contentOffset.y), contentHeight=\(scrollViewB.contentSize.height)"
        )

        // Now scroll down on Topic B (0 messages) and switch back to Topic A (2 messages).
        scrollViewB.setContentOffset(CGPoint(x: 0, y: 900), animated: false)
        window.layoutIfNeeded()

        let pageA = PageContext(
            url: topicA.url,
            site: .discourse,
            siteURL: topicA.siteURL,
            forumName: "Forum",
            topic: topicA,
            state: .topic
        )
        app.browser.setPageContext(pageA)
        handler?(pageA)

        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        window.layoutIfNeeded()

        let scrollViewBackToA = try XCTUnwrap(findScrollView(in: host.view))
        XCTAssertLessThan(
            scrollViewBackToA.contentOffset.y,
            20,
            "Switching from Topic B (0 messages) back to Topic A (2 messages) must start at the top of Topic A's summary, not jump to chatBottom; offsetY=\(scrollViewBackToA.contentOffset.y)"
        )
    }

    // Finding 3b: Clearing or editing chat while viewing the top of a summary does not scroll to chatBottom.
    @MainActor
    func testClearAndEditChatDoNotJumpReaderFromTopOfSummaryToBottom() throws {
        let secondQuestion = ChatMessage(role: .user, content: "Question 2")
        let (app, _, _, _) = try makeTwoTopicApp(
            summaryA: makeLongSummary(prefix: "SummarySection"),
            historyA: [
                ChatMessage(role: .user, content: "Question 1"),
                ChatMessage(role: .assistant, content: "Answer 1"),
                secondQuestion,
                ChatMessage(role: .assistant, content: "Answer 2")
            ],
            summaryB: "",
            historyB: []
        )

        let (window, host) = hostView(
            AssistantPanel(app: app, onExpand: { _ in }),
            size: CGSize(width: 393, height: 740)
        )
        defer { window.isHidden = true }

        let scrollView = try XCTUnwrap(findScrollView(in: host.view))
        scrollView.setContentOffset(.zero, animated: false)
        window.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(scrollView.contentOffset.y, 0, accuracy: 2)

        app.editChat(messageID: secondQuestion.id)
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        window.layoutIfNeeded()
        XCTAssertLessThan(
            scrollView.contentOffset.y,
            20,
            "editChat() while viewing the top of the summary must not scroll to chatBottom; offsetY=\(scrollView.contentOffset.y)"
        )

        app.clearChat()
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        window.layoutIfNeeded()
        XCTAssertLessThan(
            scrollView.contentOffset.y,
            20,
            "clearChat() while viewing the top of the summary must not scroll to chatBottom; offsetY=\(scrollView.contentOffset.y)"
        )
    }

    // Finding 4: Smooth upward scroll at <= 2 pt/frame pauses follow-the-answer during streaming.
    @MainActor
    func testSlowSmoothUpwardUserScrollPausesFollowWhileStreaming() throws {
        let forumService = makeStubbedForumService()
        let ai = HeldChatAIStub()
        let (app, _, _, _) = try makeTwoTopicApp(
            summaryA: makeLongSummary(),
            historyA: [],
            summaryB: "",
            historyB: [],
            aiService: ai,
            forumService: forumService
        )

        let (window, host) = hostView(
            AssistantPanel(app: app, onExpand: { _ in }),
            size: CGSize(width: 393, height: 740)
        )
        defer { window.isHidden = true }

        let scrollView = try XCTUnwrap(findScrollView(in: host.view))
        app.drafts.chat = "What is the consensus?"
        app.sendChat()
        RunLoop.current.run(until: Date().addingTimeInterval(0.7))
        window.layoutIfNeeded()

        let chatRecord = try XCTUnwrap(app.activities.first { $0.type == .chat })
        for line in 1...6 {
            app.streams.append("Streaming paragraph \(line) with enough detail to wrap onto multiple lines in the bubble.\n\n", to: chatRecord.id)
            RunLoop.current.run(until: Date().addingTimeInterval(0.14))
            window.layoutIfNeeded()
        }

        print("PROBE_DRAG_START \(Date().timeIntervalSince1970)")
        // Simulate 90 frames of smooth upward scrolling at 1.8 pt/frame (~162 pt total, > 3x the 48 pt threshold).
        for _ in 1...90 {
            let nextY = max(0, scrollView.contentOffset.y - 1.8)
            scrollView.setContentOffset(CGPoint(x: 0, y: nextY), animated: false)
            window.layoutIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.016))
        }
        let distanceAfterUserDrag = scrollView.contentSize.height - (scrollView.contentOffset.y + scrollView.bounds.height)
        XCTAssertGreaterThan(distanceAfterUserDrag, 100, "User scrolled ~162 pt away from bottom")

        app.streams.append("Next token arriving after user dragged upward smoothly.\n\n", to: chatRecord.id)
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        window.layoutIfNeeded()

        let distanceAfterNextToken = scrollView.contentSize.height - (scrollView.contentOffset.y + scrollView.bounds.height)
        ai.finish()
        XCTAssertGreaterThan(
            distanceAfterNextToken,
            120,
            "Smooth upward scroll (1.8 pt/frame for 162 pt) must pause follow-the-answer; instead stream yanked back to distance=\(distanceAfterNextToken)"
        )
    }

    // Finding 6: Regenerating or updating a saved summary never displays old summary text after new tokens arrive.
    @MainActor
    func testSummaryRetryOverSavedSummaryDoesNotFlashOldSummaryDuringStream() throws {
        final class ControlledSummaryAI: AIService, @unchecked Sendable {
            var onStart: (@MainActor (@escaping @MainActor (String) -> Void, CheckedContinuation<Result<String, Error>, Never>) -> Void)?

            override func generateSummary(
                content: String,
                configuration: ProviderConfiguration,
                provider: AIProvider,
                customPrompt: String,
                discussion: DiscussionProfile,
                batchLimit: Int = SummaryBatchLimit.default,
                onDelta: @escaping @MainActor (String) -> Void,
                onProgress: @escaping @MainActor (SummaryProgressEvent) -> Void = { _ in }
            ) async throws -> String {
                let result: Result<String, Error> = await withCheckedContinuation { cont in
                    Task { @MainActor in
                        self.onStart?(onDelta, cont)
                    }
                }
                return try result.get()
            }
        }

        let forumService = makeStubbedForumService(postsCount: 10, bodyText: "alice | 2026-10-20 | #1\nUpdated content")
        let ai = ControlledSummaryAI()
        var streamDelta: (@MainActor (String) -> Void)?
        var finishSummary: CheckedContinuation<Result<String, Error>, Never>?
        ai.onStart = { delta, cont in
            streamDelta = delta
            finishSummary = cont
        }

        let legacySummary = (1...15)
            .map { "## LEGACY SAVED SUMMARY \($0)\n\nLEGACY POINT ALPHA \($0) without post citations." }
            .joined(separator: "\n\n")
        let (app, _, _, _) = try makeTwoTopicApp(
            summaryA: legacySummary,
            historyA: [],
            summaryB: "",
            historyB: [],
            aiService: ai,
            forumService: forumService
        )

        let (window, host) = hostView(
            AssistantPanel(app: app, onExpand: { _ in }),
            size: CGSize(width: 393, height: 740)
        )
        defer { window.isHidden = true }

        let scrollView = try XCTUnwrap(findScrollView(in: host.view))
        XCTAssertGreaterThan(
            scrollView.contentSize.height,
            1_100,
            "Precondition: 30-block saved summary must be laid out before Retry (height=\(scrollView.contentSize.height))"
        )

        MarkdownLayoutProbe.reset()
        app.startSummary(regenerate: true)
        let startDeadline = Date().addingTimeInterval(10.0)
        while (streamDelta == nil || scrollView.contentSize.height >= 450), Date() < startDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            window.layoutIfNeeded()
        }
        XCTAssertNotNil(streamDelta, "Expected generateSummary continuation to start")
        XCTAssertLessThan(
            scrollView.contentSize.height,
            450,
            "While regenerating a summary before first delta, old 30-block summary must not appear under Creating summary (height=\(scrollView.contentSize.height))"
        )
        XCTAssertEqual(
            MarkdownLayoutProbe.blockBodies,
            0,
            "No summary Markdown blocks may render while waiting for the first streamed delta"
        )

        MarkdownLayoutProbe.reset()
        let freshSummary = "## FRESH STREAMED SUMMARY\n\n- Fresh point one #1\n- Fresh point two #2"
        streamDelta?(freshSummary)

        let flushDeadline = Date().addingTimeInterval(10.0)
        while Date() < flushDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            window.layoutIfNeeded()
            XCTAssertLessThan(
                scrollView.contentSize.height,
                650,
                "Old 30-block saved summary flashed during stream (height=\(scrollView.contentSize.height))"
            )
            XCTAssertLessThanOrEqual(
                MarkdownLayoutProbe.blockBodies,
                6,
                "Old 30-block saved summary evaluated during stream (blockBodies=\(MarkdownLayoutProbe.blockBodies))"
            )
            if app.streams.texts.values.contains(freshSummary),
               MarkdownLayoutProbe.blockBodies >= 3,
               MarkdownLayoutProbe.citationLayouts >= 2 {
                break
            }
        }

        XCTAssertTrue(app.streams.texts.values.contains(freshSummary), "Expected StreamStore to flush fresh summary")
        XCTAssertGreaterThanOrEqual(MarkdownLayoutProbe.blockBodies, 3, "Expected fresh streamed summary blocks to render")
        XCTAssertGreaterThanOrEqual(MarkdownLayoutProbe.citationLayouts, 2, "Expected #1 and #2 citations from fresh streamed summary to lay out")
        XCTAssertLessThan(scrollView.contentSize.height, 650, "After stream flush, old summary must not appear")

        // Verify ThrottledParse post-flush window also keeps only the fresh summary.
        let postThrottleEnd = Date().addingTimeInterval(MarkdownView.throttle + 0.05)
        while Date() < postThrottleEnd {
            RunLoop.current.run(until: Date().addingTimeInterval(0.015))
            window.layoutIfNeeded()
            XCTAssertLessThan(scrollView.contentSize.height, 650)
            XCTAssertLessThanOrEqual(MarkdownLayoutProbe.blockBodies, 6)
        }

        finishSummary?.resume(returning: .success(freshSummary))
        let finishDeadline = Date().addingTimeInterval(10.0)
        while app.currentSession?.summary != freshSummary, Date() < finishDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertEqual(app.currentSession?.summary, freshSummary)
    }

    // Finding 8: AgentView scrollTo('agentBottom') over lazy MarkdownView reaches the bottom.
    @MainActor
    func testAgentViewScrollToBottomOverLongLazyMarkdownAnswerReachesBottom() throws {
        let (app, _, _, _) = try makeTwoTopicApp(
            summaryA: "",
            historyA: [],
            summaryB: "",
            historyB: []
        )
        let siteURL = "https://forum.example.com"
        var run = AgentRun(siteURL: siteURL, goal: "Best low-power NAS build?", provider: .ollama, model: "test-model")
        run.initialAnswer = makeLongSummary(prefix: "AgentSection")
        run.answer = run.initialAnswer
        run.followUps = [ChatMessage(role: .user, content: "What about ECC memory support?")]
        run.steps = [AgentStep(tool: "search_forum", outcome: "5 topics", finishedAt: Date())]
        var agentWork = WorkRecord(
            type: .agent,
            siteURL: siteURL,
            topicID: "agent:\(run.id.uuidString)",
            title: run.goal,
            url: URL(string: siteURL)!,
            provider: .ollama,
            model: "test-model"
        )
        agentWork.status = .running
        agentWork.statusText = "Searching forum…"

        app.applyDebugSeed(AssistantDebugSeed(
            forums: app.forums,
            sessions: Array(app.sessions.values),
            activities: [agentWork],
            agentRuns: [run],
            watchedTopics: [],
            currentTopic: app.currentTopic,
            currentForum: app.forums.first,
            pageContext: app.pageContext
        ))
        app.selectedAgentRunID = run.id
        app.assistantMode = .agent

        let (window, host) = hostView(
            AgentView(app: app, showsProviderCard: false, onOpenTopic: { _ in }),
            size: CGSize(width: 393, height: 740)
        )
        defer { window.isHidden = true }

        let scrollView = try XCTUnwrap(findScrollView(in: host.view))
        run.steps.append(AgentStep(tool: "read_topic", outcome: "Read 42 posts", finishedAt: Date()))
        app.applyDebugSeed(AssistantDebugSeed(
            forums: app.forums,
            sessions: Array(app.sessions.values),
            activities: [agentWork],
            agentRuns: [run],
            watchedTopics: [],
            currentTopic: app.currentTopic,
            currentForum: app.forums.first,
            pageContext: app.pageContext
        ))
        app.selectedAgentRunID = run.id

        let deadline = Date().addingTimeInterval(10.0)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            window.layoutIfNeeded()
            let currentDistance = scrollView.contentSize.height - (scrollView.contentOffset.y + scrollView.bounds.height)
            if scrollView.contentOffset.y > 0, currentDistance < 60 {
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
                window.layoutIfNeeded()
                if scrollView.contentSize.height - (scrollView.contentOffset.y + scrollView.bounds.height) < 60 {
                    break
                }
            }
        }

        let distance = scrollView.contentSize.height - (scrollView.contentOffset.y + scrollView.bounds.height)
        XCTAssertLessThan(
            distance,
            60,
            "AgentView scrollTo('agentBottom') over lazy MarkdownView stopped \(distance) pt short of agentBottom (offsetY=\(scrollView.contentOffset.y), contentHeight=\(scrollView.contentSize.height))!"
        )
    }

    // Finding 9: Scrolling upward from the bottom through tall upper rows does not jump.
    @MainActor
    func testScrollingUpFromBottomThroughTallUpperRowsHasNoLayoutJump() throws {
        var lines = ["## Overview"]
        for section in 1...18 {
            lines.append("\n## Tall Section \(section)")
            lines.append("```swift\nlet line1 = \(section)\nlet line2 = \(section * 2)\nlet line3 = \(section * 3)\nlet line4 = \(section * 4)\nlet line5 = \(section * 5)\nlet line6 = \(section * 6)\n```")
        }
        for section in 19...40 {
            lines.append("\n## Short \(section)")
            lines.append("- Tiny item \(section)")
        }

        let (app, _, _, _) = try makeTwoTopicApp(
            summaryA: lines.joined(separator: "\n"),
            historyA: [
                ChatMessage(role: .user, content: "Summary question"),
                ChatMessage(role: .assistant, content: "Short answer.")
            ],
            summaryB: "",
            historyB: []
        )

        let (window, host) = hostView(
            AssistantPanel(app: app, onExpand: { _ in }),
            size: CGSize(width: 393, height: 740)
        )
        defer { window.isHidden = true }
        let scrollView = try XCTUnwrap(findScrollView(in: host.view))

        scrollView.setContentOffset(CGPoint(x: 0, y: max(0, scrollView.contentSize.height - scrollView.bounds.height)), animated: false)
        window.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        scrollView.setContentOffset(CGPoint(x: 0, y: max(0, scrollView.contentSize.height - scrollView.bounds.height)), animated: false)
        window.layoutIfNeeded()

        var maxJumpOnSingleUpwardStep: CGFloat = 0
        for _ in 1...80 {
            guard scrollView.contentOffset.y > 0 else { break }
            let targetY = max(0, scrollView.contentOffset.y - 160)
            let beforeHeight = scrollView.contentSize.height
            scrollView.setContentOffset(CGPoint(x: 0, y: targetY), animated: false)
            window.layoutIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            window.layoutIfNeeded()
            let heightDelta = abs(scrollView.contentSize.height - beforeHeight)
            let offsetShift = abs(scrollView.contentOffset.y - targetY)
            maxJumpOnSingleUpwardStep = max(maxJumpOnSingleUpwardStep, max(heightDelta, offsetShift))
        }

        XCTAssertLessThan(
            maxJumpOnSingleUpwardStep,
            50,
            "Scrolling up through tall upper rows caused a \(maxJumpOnSingleUpwardStep) pt layout/scroll shift!"
        )
    }

    @MainActor
    func testStreamingSummaryDragInvalidatesOnlyChangedRowAndLaysOutLazily() throws {
        final class HeldSummaryAI: AIService, @unchecked Sendable {
            var onStart: (@MainActor (@escaping @MainActor (String) -> Void, CheckedContinuation<Result<String, Error>, Never>) -> Void)?

            override func generateSummary(
                content: String,
                configuration: ProviderConfiguration,
                provider: AIProvider,
                customPrompt: String,
                discussion: DiscussionProfile,
                batchLimit: Int = SummaryBatchLimit.default,
                onDelta: @escaping @MainActor (String) -> Void,
                onProgress: @escaping @MainActor (SummaryProgressEvent) -> Void = { _ in }
            ) async throws -> String {
                let result: Result<String, Error> = await withCheckedContinuation { cont in
                    Task { @MainActor in self.onStart?(onDelta, cont) }
                }
                return try result.get()
            }
        }

        let forumService = makeStubbedForumService(postsCount: 500, bodyText: "alice | 2026-10-20 | #1\nPost 1")
        let ai = HeldSummaryAI()
        var streamDelta: (@MainActor (String) -> Void)?
        var finishSummary: CheckedContinuation<Result<String, Error>, Never>?
        ai.onStart = { delta, cont in
            streamDelta = delta
            finishSummary = cont
        }

        let (app, _, _, _) = try makeTwoTopicApp(
            summaryA: "",
            historyA: [],
            summaryB: "",
            historyB: [],
            aiService: ai,
            forumService: forumService
        )

        let (window, host) = hostView(
            AssistantPanel(app: app, onExpand: { _ in }),
            size: CGSize(width: 377, height: 780)
        )
        defer { window.isHidden = true }

        app.startSummary(regenerate: true)
        for _ in 0..<300 where streamDelta == nil {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertNotNil(streamDelta)
        defer {
            finishSummary?.resume(returning: .success("## Original post"))
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }

        // Stream first section (on-screen at large height): 1 heading + 4 bullets.
        let initialChunk = """
        ## Original post

        ## Section 1
        - First bullet with citation #1 #41
        - Second bullet with citation #2 #42
        - Third bullet with citation #3 #43
        - Active bullet streaming
        """
        streamDelta?(initialChunk)
        app.streams.flush()
        RunLoop.current.run(until: Date().addingTimeInterval(0.16))
        window.layoutIfNeeded()

        // 1. Appending words to the active last bullet across 3 throttled flushes must only re-evaluate that 1 row per flush,
        // and growing a word in place inside CitedText (same subview count) must refresh CitationFlowLayout's cache.
        let scrollView = try XCTUnwrap(findScrollView(in: host.view))
        MarkdownLayoutProbe.reset()
        for word in [" wordA", " wordB #4", " wordC #44"] {
            streamDelta?(word)
            app.streams.flush()
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
            window.layoutIfNeeded()
        }
        XCTAssertEqual(
            MarkdownLayoutProbe.blockBodies,
            3,
            "Each stream flush extending the last bullet must invalidate only the 1 changed row, not all rows; got \(MarkdownLayoutProbe.blockBodies)."
        )

        streamDelta?(" stub")
        app.streams.flush()
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        window.layoutIfNeeded()
        let heightBeforeInPlaceGrowth = scrollView.contentSize.height
        streamDelta?("SupercalifragilisticexpialidociousRepeatedToForceAnExtraWrappedLineInCitedText")
        app.streams.flush()
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        window.layoutIfNeeded()
        XCTAssertGreaterThan(
            scrollView.contentSize.height,
            heightBeforeInPlaceGrowth + 14,
            "In-place token growth inside CitedText must update CitationFlowLayout cache and wrap onto a new line."
        )

        // 2. Reproduce testDragWhileStreaming: stream sections 2..10 (up to 65 rows, < 100) while dragging medium <-> large.
        var section2 = "\n- Fifth bullet #5 #45\n- Sixth bullet #6 #46\n\n## Section 2"
        for point in 1...6 {
            section2 += "\n- Readers report that the card works well and pays out quickly after a short wait #\(2 * point) #\(42 + point)"
        }
        streamDelta?(section2)
        app.streams.flush()
        RunLoop.current.run(until: Date().addingTimeInterval(0.16))
        window.frame = CGRect(origin: .zero, size: CGSize(width: 377, height: 420))
        host.view.frame = window.bounds
        window.layoutIfNeeded()

        MarkdownLayoutProbe.reset()
        for step in 0..<32 {
            let section = 3 + step / 4
            let phase = step % 4
            let delta: String
            if phase == 0 {
                delta = "\n\n## Section \(section)\n- Readers report that the card works well and pays out quickly #\(section) #\(section + 40)"
            } else {
                let p1 = phase * 2 - 1
                let p2 = phase * 2
                delta = "\n- Readers report that the card works well and pays out quickly after a short wait #\(section * p1) #\(section + p1 + 40)"
                    + (p2 <= 5 ? "\n- Readers report that the card works well and pays out quickly after a short wait #\(section * p2) #\(section + p2 + 40)" : "")
            }
            streamDelta?(delta)
            app.streams.flush()

            // Oscillate between medium (377x420) and large (393x780).
            let progress = step < 16 ? CGFloat(step + 1) / 16 : CGFloat(32 - step) / 16
            let width = 377 + (393 - 377) * progress
            let height = 420 + (780 - 420) * progress
            window.frame = CGRect(origin: .zero, size: CGSize(width: width, height: height))
            host.view.frame = window.bounds
            window.layoutIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.14))
            window.layoutIfNeeded()
        }

        let streamDragBodies = MarkdownLayoutProbe.blockBodies
        let streamDragCitations = MarkdownLayoutProbe.citationLayouts
        XCTAssertLessThan(
            streamDragBodies,
            25,
            "Offscreen streaming rows (sections 3..10) must not materialize while dragging at top; got \(streamDragBodies) blockBodies."
        )
        XCTAssertLessThan(
            streamDragCitations,
            650,
            "Dragging medium<->large while streaming < 100 rows must only lay out visible cited rows; got \(streamDragCitations) citationLayouts."
        )
    }

    @MainActor
    func testExportIncludesTimeSummarizedAndPostCoverageOnOnePlainLine() throws {
        var components = DateComponents()
        components.calendar = Calendar(identifier: .iso8601)
        components.timeZone = TimeZone(secondsFromGMT: 0)
        components.year = 2026
        components.month = 11
        components.day = 6
        components.hour = 14
        let summaryDate = try XCTUnwrap(components.date)

        let payload = TopicExportPayload(
            summary: "## Overview\n- Key takeaway #1",
            source: "alice | 2026-11-06 | #1\nPost 1",
            title: "Sample Topic",
            url: URL(string: "https://forum.example.com/t/sample/42"),
            history: [],
            summaryUpdatedAt: summaryDate,
            summaryPostCount: 120,
            totalPosts: 340
        )
        XCTAssertEqual(payload.summaryMetadataLine, "Summarized 2026-11-06 · 120 of 340 posts")
        let exported = payload.text(options: ExportOptions(excludePostAndResponses: true))
        XCTAssertTrue(
            exported.contains("Summary:\nSummarized 2026-11-06 · 120 of 340 posts\n## Overview\n- Key takeaway #1"),
            exported
        )

        // Also verify AppModel's currentExportPayload populates summaryUpdatedAt, summaryPostCount, and totalPosts.
        let (app, _, _, _) = try makeTwoTopicApp(summaryA: "Summary A", historyA: [], summaryB: "", historyB: [])
        let panelPayload = AssistantPanel(app: app, onExpand: { _ in }).payload
        XCTAssertEqual(panelPayload.summaryPostCount, 500)
        XCTAssertEqual(panelPayload.totalPosts, 500)
        XCTAssertNotNil(panelPayload.summaryUpdatedAt)
        XCTAssertTrue(panelPayload.summaryMetadataLine?.hasSuffix("· 500 of 500 posts") ?? false)
    }

    @MainActor
    func testDiscourseAgentReadTopicSupportsPageAndQueryWithoutRefetching() async throws {
        let page1Posts = (1...100).map { n in
            "user\(n) | 2026-10-20 10:00:00 UTC | #\(n)\n\n"
                + (n == 1 ? "Opening post about router firmware." : "Reply \(n) with padding \(String(repeating: "x", count: 140)).")
        }.joined(separator: RawTopicFormat.blockSeparator)
        let page2Posts = (101...120).map { n in
            "user\(n) | 2026-10-20 11:00:00 UTC | #\(n)\n\n"
                + (n == 105 ? "The secret needle workaround is setting MTU to 1492." : "Reply \(n) on page two \(String(repeating: "y", count: 140)).")
        }.joined(separator: RawTopicFormat.blockSeparator)

        var rawPage1Fetches = 0
        var rawPage2Fetches = 0
        URLProtocolStub.handler = { request in
            let path = request.url?.path ?? ""
            let page = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "page" })?.value ?? "1"
            let body: String
            if path.hasSuffix("/t/42.json") {
                body = #"{"title":"Router Firmware","slug":"router-firmware","posts_count":120,"highest_post_number":120}"#
            } else if path.hasSuffix("/raw/42") {
                if page == "2" {
                    rawPage2Fetches += 1
                    body = page2Posts
                } else {
                    rawPage1Fetches += 1
                    body = page1Posts
                }
            } else {
                body = "{}"
            }
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": path.hasSuffix(".json") ? "application/json" : "text/plain"]
            )!
            return (response, Data(body.utf8))
        }

        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [URLProtocolStub.self]
        let forumService = ForumService(session: URLSession(configuration: cfg), pacer: ForumRequestPacer(clock: InstantPacingClock()))

        let planner = ScriptedAgentPlanner(actions: [
            AgentAction(thought: "", tool: "read_topic", arguments: ["topic_id": "42"]),
            AgentAction(thought: "", tool: "read_topic", arguments: ["topic_id": "42", "page": "2"]),
            AgentAction(thought: "", tool: "read_topic", arguments: ["topic_id": "42", "query": "needle workaround"]),
            AgentAction(thought: "", tool: "read_topic", arguments: ["topic_id": "42", "page": "0"]),
            AgentAction(thought: "", tool: "read_topic", arguments: ["topic_id": "42", "page": "3"]),
            AgentAction(thought: "", tool: AgentPrompt.finalAnswerTool, arguments: ["answer": "Set MTU to 1492."])
        ])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = PersistentStore(fileURL: directory.appendingPathComponent("state.json"), keys: InMemoryProviderKeyStore())
        try store.save(AppSnapshot(forums: [Forum(siteURL: "https://forum.example.com", kind: .discourse, name: "Forum")]))
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        let ai = StateAIStub()
        ai.gated = false
        let app = AppModel(store: store, forumService: forumService, aiService: ai, planner: planner)
        app.usesDirectForumRequests = true
        app.allowAllAIProviders()
        app.selectModel(ModelSelection(provider: .ollama, model: "test-model"), for: .both)
        app.browser.onPageContextChanged = nil
        app.settings.agentReadLimit = 10_000
        app.settings.agentMaxTopicReads = 1

        app.startAgentRun(goal: "How to fix router MTU?", siteURL: "https://forum.example.com")
        let deadline = Date().addingTimeInterval(15)
        while !(app.agentRuns.first?.isFinished ?? false), Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let run = try XCTUnwrap(app.agentRuns.first)
        XCTAssertEqual(run.result, .completed, run.error)
        XCTAssertEqual(run.topicIDs, ["42"], "Paging/querying an already-read topic does not consume extra topic-read budget.")
        XCTAssertEqual(rawPage1Fetches, 1)
        XCTAssertEqual(rawPage2Fetches, 1)

        let firstObs = try XCTUnwrap(planner.transcripts[1].last?.content)
        XCTAssertTrue(firstObs.contains("pass page=2 or query=\"<keywords>\" to read other parts."), firstObs)

        let page2Obs = try XCTUnwrap(planner.transcripts[2].last?.content)
        XCTAssertTrue(page2Obs.contains("Showing: page 2 of 2"), page2Obs)
        XCTAssertTrue(page2Obs.contains("#105\nThe secret needle workaround"), page2Obs)
        XCTAssertFalse(page2Obs.contains("Opening post about router firmware."), page2Obs)

        let queryObs = try XCTUnwrap(planner.transcripts[3].last?.content)
        XCTAssertTrue(queryObs.contains("Showing: 1 matching post for \"needle workaround\" (of 120 posts)"), queryObs)
        XCTAssertTrue(queryObs.contains("Opening post about router firmware."), "Includes opening post #1 for context")
        XCTAssertTrue(queryObs.contains("#105\nThe secret needle workaround"), queryObs)

        let zeroPageObs = try XCTUnwrap(planner.transcripts[4].last?.content)
        XCTAssertEqual(zeroPageObs, "ERROR from read_topic:\nInvalid argument \"page\": use a positive integer.")

        let outOfRangeObs = try XCTUnwrap(planner.transcripts[5].last?.content)
        XCTAssertEqual(outOfRangeObs, "ERROR from read_topic:\nInvalid argument \"page\": use a number from 1 to 2.")
    }

    @MainActor
    func testCitedTextCoalescesTextRunsAndPreservesAccessibilityLabel() {
        func measureTokenViews(for source: String) -> Int {
            MarkdownLayoutProbe.reset()
            let content = MarkdownBlockView(
                row: MarkdownRow(content: .paragraph(source), topSpacing: 0),
                citations: true
            )
            .frame(width: 360, alignment: .leading)
            let renderer = ImageRenderer(content: content)
            _ = renderer.cgImage
            return MarkdownLayoutProbe.textViews
        }

        let enSeg1 = "Members discussing the **onboarding flow** noticed that new accounts often hit link limits right away"
        let enSeg2 = "while moderators explained that community flags are reviewed together so spam stays out of threads"
        let enSeg3 = "Several admins also shared plugins extending the default trust level rules across busy forum categories"
        let enSeg4 = "Trust level unlocks after reading."
        let englishSource = "\(enSeg1) [#1](forumind-post:1) \(enSeg2) [#7](forumind-post:7). \(enSeg3) [#14](forumind-post:14). \(enSeg4)"
        let englishPlain = "Members discussing the onboarding flow noticed that new accounts often hit link limits right away "
            + "\(enSeg2) . \(enSeg3) . \(enSeg4)"

        XCTAssertEqual(CitedText.accessibilityLabel(for: englishSource), englishPlain)
        let englishTokenViews = measureTokenViews(for: englishSource)
        XCTAssertGreaterThan(englishTokenViews, 0)
        XCTAssertLessThanOrEqual(
            englishTokenViews,
            7,
            "A 50-word English paragraph with 3 citations must yield at most 7 CitedText token views; got \(englishTokenViews)."
        )

        let zhSeg1 = "一篇官方帖子整理了新用户最常问的问题，包括信任等级是怎么回事、为什么一开始能发布"
        let zhSeg2 = "的链接有限，以及去哪里查看社区的准则。不少人在第二个链接被拦下时还以为账号出了问"
        let zhSeg3 = "题，版主解释这只是防垃圾信息的措施，只要正常浏览一两天并认真回复几次就会自动升级"
        XCTAssertEqual(zhSeg1.count + zhSeg2.count + zhSeg3.count, 120)
        let chineseSource = "\(zhSeg1) [#2](forumind-post:2)。\(zhSeg2) [#9](forumind-post:9)。\(zhSeg3)"
        let chinesePlain = "\(zhSeg1) 。\(zhSeg2) 。\(zhSeg3)"

        XCTAssertEqual(CitedText.accessibilityLabel(for: chineseSource), chinesePlain)
        let chineseTokenViews = measureTokenViews(for: chineseSource)
        XCTAssertGreaterThan(chineseTokenViews, 0)
        XCTAssertLessThanOrEqual(
            chineseTokenViews,
            5,
            "A 120-character Chinese paragraph with 2 citations must yield at most 5 CitedText token views; got \(chineseTokenViews)."
        )

        // Leading non-opening punctuation on words or styled runs after a chip must not glue onto the chip.
        XCTAssertEqual(CitedText.citationSuffixes(for: "See [#1](forumind-post:1) @alice"), [nil])
        XCTAssertEqual(CitedText.accessibilityLabel(for: "See [#1](forumind-post:1) @alice"), "See @alice")

        XCTAssertEqual(CitedText.citationSuffixes(for: #"See [#1](forumind-post:1) "quoted""#), [nil])
        XCTAssertEqual(CitedText.accessibilityLabel(for: #"See [#1](forumind-post:1) "quoted""#), #"See "quoted""#)

        XCTAssertEqual(CitedText.citationSuffixes(for: "See [#1](forumind-post:1) `.env`"), [nil])
        XCTAssertEqual(CitedText.accessibilityLabel(for: "See [#1](forumind-post:1) `.env`"), "See .env")

        XCTAssertEqual(CitedText.citationSuffixes(for: "See [#1](forumind-post:1). `@alice`"), ["."])
        XCTAssertEqual(CitedText.accessibilityLabel(for: "See [#1](forumind-post:1). `@alice`"), "See . @alice")

        XCTAssertEqual(CitedText.citationSuffixes(for: #"See [#1](forumind-post:1). **"quoted"**"#), ["."])
        XCTAssertEqual(CitedText.accessibilityLabel(for: #"See [#1](forumind-post:1). **"quoted"**"#), #"See . "quoted""#)

        // True trailing punctuation still glues onto its chip (including space-before-period and CJK).
        XCTAssertEqual(CitedText.citationSuffixes(for: "See [#1](forumind-post:1) . Next"), ["."])
        XCTAssertEqual(CitedText.citationSuffixes(for: "（见 [#7](forumind-post:7)）。"), ["）。"])
        XCTAssertEqual(CitedText.citationSuffixes(for: "先开启 [#12](forumind-post:12)。另见"), ["。"])
    }
}
