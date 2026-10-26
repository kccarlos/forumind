import XCTest

/// The voice UI on a scripted session (`-dc-voice-fake`: a fake Gemini Live
/// transport and silent audio inside the app): the consent sheet, the voice
/// bar's states and transcript, the typed-input path and ending. No
/// network, microphone or key.
final class VoiceUITests: DCUITestCase {
    func testConsentThenTheVoiceBarTalksAndEnds() throws {
        let app = launch(
            ["-dc-sample", "-dc-forums-home", "-dc-voice-fake"],
            orientation: isPhone ? .portrait : .landscapeLeft
        )
        // The sample opens on the Assistant in the single-pane layout.
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20))
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        showBrowser(in: app)

        startVoice(in: app)

        // First session with this provider: consent first, naming Google.
        let agree = app.buttons["voiceConsentAgree"]
        XCTAssertTrue(agree.waitForExistence(timeout: 10), "The consent sheet did not appear.")
        XCTAssertTrue(any(app, "voiceTermsLink").exists, "The sheet links to Google's terms.")
        if isEnglish(app) {
            XCTAssertTrue(app.staticTexts["Talk to Forumind"].exists)
            XCTAssertTrue(any(app, "voiceTrySaying").exists, "The first-start page lists examples.")
        }
        agree.tap()

        // The bar connects, listens and shows the model's greeting.
        let bar = any(app, "voiceBar")
        XCTAssertTrue(bar.waitForExistence(timeout: 10), "The voice Dock did not appear.")
        // The Dock replaces the bar (iPhone): one floating layer.
        if isPhone { XCTAssertFalse(app.buttons["aiButton"].exists, "The bar shows under the Dock.") }
        let transcript = any(app, "voiceTranscript")
        XCTAssertTrue(transcript.waitForExistence(timeout: 10), "No transcript line.")
        if isEnglish(app) {
            XCTAssertTrue(wait(timeout: 5) { transcript.label.contains("listening") }, transcript.label)
        }

        // Typed instead of spoken (DEBUG builds): the reply comes back.
        let field = app.textFields["voiceTextField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "No typed-input field in a DEBUG build.")
        field.tap()
        field.typeText("next post\n")
        XCTAssertTrue(wait(timeout: 5) { any(app, "voiceTranscript").label.contains("next post") }, "The typed turn got no reply.")

        // Mute, then end.
        let mute = app.buttons["voiceMute"]
        XCTAssertTrue(mute.exists)
        mute.tap()
        let end = app.buttons["voiceEnd"]
        XCTAssertTrue(waitForHittable(end))
        end.tap()
        let close = app.buttons["voiceBarClose"]
        XCTAssertTrue(close.waitForExistence(timeout: 5), "An ended session keeps its bar until closed.")
        close.tap()
        XCTAssertTrue(waitForGone(bar, timeout: 5))
        // Ending returns the bar.
        if isPhone { XCTAssertTrue(waitForBarItem(app.buttons["forumSwitcher"], timeout: 10), "The bar did not come back.") }

        // Consent is remembered: the next tap starts at once.
        startVoice(in: app)
        XCTAssertTrue(bar.waitForExistence(timeout: 10))
        XCTAssertFalse(agree.exists)
        app.buttons["voiceEnd"].tap()
    }

    /// Voice running, result cards over the page, then the drawer opens
    /// (`-dc-test-present drawer-on-voice`): the strip would be under the
    /// sheet, so the cards become a chip in the drawer's status row whose ›
    /// moves along them; closing the drawer brings the strip back.
    func testTheCardsBecomeAChipInTheDrawerWhileVoiceRuns() throws {
        try skipUnlessPhone("The AI drawer is an iPhone behavior.")
        try requireNetwork()
        let app = launch([
            "-dc-sample", "-dc-page-state", "topic", "-dc-voice-fake",
            "-dc-browse-find", "plugin", "-dc-test-present", "drawer-on-voice"
        ])
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20))
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        showBrowser(in: app)

        let strip = any(app, "resultCards")
        let stripChip = app.buttons["resultCardsChip"]
        XCTAssertTrue(wait(timeout: 60) { strip.exists || stripChip.exists }, "No result cards after the search.")
        startVoice(in: app)
        let agree = app.buttons["voiceConsentAgree"]
        if agree.waitForExistence(timeout: 10) { agree.tap() }
        // The drawer opens a second after voice starts (the Dock goes under it).
        let chip = any(app, "drawerCardsChip")
        XCTAssertTrue(waitOrDump(chip, timeout: 30, in: app), "The drawer has no cards chip.")
        XCTAssertTrue(drawerState(in: app).exists)
        XCTAssertTrue(any(app, "drawerStatusRow").exists, "Voice runs in the drawer's status row.")
        XCTAssertFalse(strip.exists || stripChip.exists, "The strip must not stay under the drawer.")
        let label = any(app, "drawerCardsLabel")
        let before = label.label
        XCTAssertTrue(before.contains("results"), before)
        let next = app.buttons["drawerCardsNext"]
        XCTAssertTrue(waitForHittable(next), "The chip has no ›.")
        next.tap()
        XCTAssertTrue(wait(timeout: 15) { label.label != before && label.label.contains("1/") },
                      "› did not move to the first card: \(label.label)")

        closeDrawer(in: app)
        XCTAssertTrue(wait(timeout: 10) { strip.exists || stripChip.exists }, "The strip did not come back.")
        let end = app.buttons["voiceEnd"]
        if end.waitForExistence(timeout: 5) { end.tap() }
    }

    /// Split layout: with History open in the AI panel, the voice status row
    /// stays above it with Mute and End (audit A7).
    func testVoiceCanBeMutedAndEndedOverHistoryInThePanel() throws {
        try skipUnlessPad("The split layout's panel hosts History; iPhone shows it as a sheet.")
        let app = launch(["-dc-sample", "-dc-page-state", "topic", "-dc-voice-fake"], orientation: .landscapeLeft)
        let panel = any(app, "aiPanel")
        XCTAssertTrue(waitOrDump(panel, timeout: 20, in: app))
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        startVoice(in: app)
        let agree = app.buttons["voiceConsentAgree"]
        if agree.waitForExistence(timeout: 10) { agree.tap() }
        let mute = app.buttons["drawerVoiceMute"]
        XCTAssertTrue(waitOrDump(mute, timeout: 15, in: app), "No voice status row in the panel.")

        let more = app.buttons["browserMoreMenu"]
        XCTAssertTrue(waitForHittable(more))
        more.tap()
        let history = app.buttons["History"].firstMatch
        XCTAssertTrue(history.waitForExistence(timeout: 5))
        history.tap()
        XCTAssertTrue(app.buttons["backToTopic"].waitForExistence(timeout: 10), "History did not open in the panel.")
        XCTAssertTrue(mute.exists, "The voice row went under History.")
        mute.tap()
        if isEnglish(app) { XCTAssertTrue(wait(timeout: 5) { mute.label == "Unmute" }, mute.label) }
        let end = app.buttons["drawerVoiceEnd"]
        XCTAssertTrue(waitForHittable(end))
        end.tap()
        XCTAssertTrue(waitForGone(mute, timeout: 10), "End did not end voice.")
    }

    /// The bar's microphone (the iPhone Forums home has one too; on a page a
    /// long press on the AI button starts voice).
    private func startVoice(in app: XCUIApplication) {
        // Bar items: iOS 27's toolbar reports them as not hittable, so
        // wait for a frame on screen and tap the coordinate.
        let mic = app.buttons.matching(identifier: "voiceButton").firstMatch
        if waitForBarItem(mic, timeout: 5) {
            tapBarItem(mic)
            return
        }
        // On a page the bar has no mic: a long press on the AI button starts voice.
        let ai = app.buttons["aiButton"]
        XCTAssertTrue(waitForBarItem(ai, timeout: 10), "The bar has neither a microphone nor an AI button.")
        pressBarItem(ai, duration: 1.0)
    }

    private func isEnglish(_ app: XCUIApplication) -> Bool {
        Locale.preferredLanguages.first?.hasPrefix("en") ?? true
    }
}
