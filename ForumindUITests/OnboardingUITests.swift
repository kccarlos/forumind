import XCTest

/// The first-launch walkthrough (`-dc-reset` shows it again; nothing is deleted).
final class OnboardingUITests: DCUITestCase {
    func testWalkthroughPagesThroughToForumsHome() throws {
        let app = launch(["-dc-reset"])

        XCTAssertTrue(any(app, "onboarding").waitForExistence(timeout: 20), "The walkthrough did not appear.")
        let progress = any(app, "onboardingProgress")
        let next = app.buttons["onboardingContinue"]
        let skipStep = app.buttons["onboardingSkipStep"]

        // Welcome → Choose your AI.
        XCTAssertTrue(waitForHittable(next))
        XCTAssertFalse(skipStep.exists, "Welcome has nothing to skip.")
        next.tap()
        assertStep(2, progress)

        // Provider: Gemini is offered first; skip for now (nothing is tested).
        XCTAssertTrue(any(app, "onboardingProvider-gemini").waitForExistence(timeout: 5), "Google Gemini is not offered first.")
        XCTAssertTrue(waitForHittable(skipStep))
        skipStep.tap()
        assertStep(3, progress)
        XCTAssertTrue(
            app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH 'onboardingForum-'"))
                .firstMatch.waitForExistence(timeout: 5),
            "The forums step lists no suggested forums."
        )

        // Forums: skip for now (pins nothing).
        XCTAssertTrue(waitForHittable(skipStep))
        skipStep.tap()
        assertStep(4, progress)

        // Your day: everything is off by default; skip.
        XCTAssertTrue(any(app, "onboardingDigest").waitForExistence(timeout: 5))
        XCTAssertTrue(waitForHittable(skipStep))
        skipStep.tap()
        assertStep(5, progress)

        // Privacy needs the Terms of Use accepted; the iCloud toggle is here.
        XCTAssertTrue(app.switches["onboardingSyncToggle"].waitForExistence(timeout: 5))
        XCTAssertFalse(skipStep.exists, "Only the provider, forums and daily steps can be skipped.")
        XCTAssertFalse(next.isEnabled, "Continue works before the Terms of Use are accepted.")
        acceptTerms(app)
        XCTAssertTrue(waitForHittable(next))
        next.tap()

        // Done: "Browse (all) forums" is offered whether or not forums were pinned before.
        assertStep(6, progress)
        let browse = app.buttons["onboardingBrowseForums"]
        XCTAssertTrue(waitForHittable(browse), "The last step did not appear.")
        XCTAssertFalse(app.buttons["onboardingSkipAll"].isEnabled, "Skip is hidden on the last step.")
        browse.tap()

        XCTAssertTrue(waitForGone(any(app, "onboarding"), timeout: 10), "The walkthrough did not close.")
        XCTAssertTrue(any(app, "home").waitForExistence(timeout: 10), "Finishing did not land on the Forums home.")
        XCTAssertTrue(app.buttons["forumSwitcher"].exists)
    }

    func testSkipStopsAtTheTermsThenJumpsToTheLastStep() throws {
        let app = launch(["-dc-onboarding-step", "daily"])

        let skipAll = app.buttons["onboardingSkipAll"]
        XCTAssertTrue(waitForHittable(skipAll, timeout: 20), "Skip is missing on a middle step.")
        skipAll.tap()
        // The Terms of Use can't be skipped.
        assertStep(5, any(app, "onboardingProgress"))
        XCTAssertFalse(app.buttons["onboardingContinue"].isEnabled)
        skipAll.tap()
        assertStep(5, any(app, "onboardingProgress"))
        acceptTerms(app)
        skipAll.tap()
        let browse = app.buttons["onboardingBrowseForums"]
        XCTAssertTrue(waitForHittable(browse), "Skip did not jump to the last step.")

        // Back is hidden on the last step; finishing closes the walkthrough.
        XCTAssertFalse(app.buttons["onboardingBack"].isEnabled)
        browse.tap()
        XCTAssertTrue(waitForGone(any(app, "onboarding"), timeout: 10))
        XCTAssertTrue(any(app, "home").waitForExistence(timeout: 10))
    }

    func testBackReturnsToThePreviousStep() throws {
        let app = launch(["-dc-onboarding-step", "forums"])

        let progress = any(app, "onboardingProgress")
        XCTAssertTrue(progress.waitForExistence(timeout: 20))
        assertStep(3, progress)
        let back = app.buttons["onboardingBack"]
        XCTAssertTrue(waitForHittable(back))
        back.tap()
        assertStep(2, progress)
        // Leave the walkthrough completed for the other tests (Skip stops
        // at the Terms of Use first).
        let skipAll = app.buttons["onboardingSkipAll"]
        XCTAssertTrue(waitForHittable(skipAll))
        skipAll.tap()
        assertStep(5, progress)
        acceptTerms(app)
        XCTAssertTrue(waitForHittable(skipAll))
        skipAll.tap()
        let browse = app.buttons["onboardingBrowseForums"]
        XCTAssertTrue(waitForHittable(browse))
        browse.tap()
        XCTAssertTrue(waitForGone(any(app, "onboarding"), timeout: 10))
    }

    func testDoneStepOpensTheShareHowToPage() throws {
        let app = launch(["-dc-onboarding-step", "done"])

        let row = app.buttons["onboardingShareHowTo"]
        let browse = app.buttons["onboardingBrowseForums"]
        XCTAssertTrue(waitForHittable(row, timeout: 20), "The Safari or Chrome row is missing.")
        // Scroll the row clear of the bottom buttons before tapping it.
        for _ in 0..<4 where row.frame.maxY > browse.frame.minY - 8 { app.swipeUp() }
        row.tap()
        let done = app.buttons["shareHowToDone"]
        for _ in 0..<4 where !(done.waitForExistence(timeout: 3) && done.isHittable) { app.swipeUp() }
        XCTAssertTrue(waitForHittable(done), "The Share how-to page did not open.")
        done.tap()
        // Leave the walkthrough completed for the other tests.
        XCTAssertTrue(waitForHittable(browse))
        browse.tap()
        XCTAssertTrue(waitForGone(any(app, "onboarding"), timeout: 10))
    }

    /// The progress dots read "Step N of 6: <title>".
    private func assertStep(
        _ number: Int,
        _ progress: XCUIElement,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let prefix = "Step \(number) of"
        XCTAssertTrue(
            wait(timeout: 10) { progress.exists && progress.label.hasPrefix(prefix) },
            "Expected \(prefix)…, got “\(progress.label)”.",
            file: file,
            line: line
        )
    }

    private func acceptTerms(_ app: XCUIApplication) {
        let agree = app.switches["termsAgree"]
        for _ in 0..<6 where !agree.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(waitForHittable(agree), "The Terms of Use toggle is missing.")
        // Tap the switch itself (right edge), not its label.
        agree.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
    }
}
