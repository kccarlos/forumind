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

    /// iPad: the bar's microphone. iPhone: the forum menu (on a page a long
    /// press on the AI button too; the Forums home has no drawer).
    private func startVoice(in app: XCUIApplication) {
        if isPhone {
            openForumMenu(in: app)
            let item = app.buttons["Talk to Forumind"]
            XCTAssertTrue(item.waitForExistence(timeout: 10), "The forum menu has no Talk to Forumind.")
            item.tap()
            return
        }
        let mic = app.buttons["voiceButton"]
        XCTAssertTrue(waitForHittable(mic, timeout: 10), "The browser bar has no microphone.")
        mic.tap()
    }

    private func isEnglish(_ app: XCUIApplication) -> Bool {
        Locale.preferredLanguages.first?.hasPrefix("en") ?? true
    }
}
