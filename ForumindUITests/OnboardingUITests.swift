import XCTest

/// The first-launch walkthrough (`-dc-reset` shows it again; nothing is deleted).
final class OnboardingUITests: DCUITestCase {
    func testWalkthroughPagesThroughToForumsHome() throws {
        let app = launch(["-dc-reset"])

        XCTAssertTrue(any(app, "onboarding").waitForExistence(timeout: 20), "The walkthrough did not appear.")
        let progress = any(app, "onboardingProgress")
        let next = app.buttons["onboardingContinue"]
        let skipStep = app.buttons["onboardingSkipStep"]

        // Welcome → What it does.
        XCTAssertTrue(waitForHittable(next))
        XCTAssertFalse(skipStep.exists, "Welcome has nothing to skip.")
        next.tap()
        assertStep(2, progress)

        // What it does → Connect an AI provider.
        XCTAssertTrue(waitForHittable(next))
        next.tap()
        assertStep(3, progress)

        // Provider: skip for now (no key is entered or tested).
        XCTAssertTrue(waitForHittable(skipStep))
        skipStep.tap()
        assertStep(4, progress)
        XCTAssertTrue(
            app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH 'onboardingForum-'"))
                .firstMatch.waitForExistence(timeout: 5),
            "The forums step lists no suggested forums."
        )

        // Forums: skip for now (pins nothing).
        XCTAssertTrue(waitForHittable(skipStep))
        skipStep.tap()
        assertStep(5, progress)

        // Sync across your devices: informational, with the iCloud toggle
        // (on by default; left untouched).
        XCTAssertTrue(app.switches["onboardingSyncToggle"].waitForExistence(timeout: 5))
        XCTAssertFalse(skipStep.exists, "Only the provider and forums steps can be skipped.")
        XCTAssertTrue(waitForHittable(next))
        next.tap()
        assertStep(6, progress)

        // Share → Privacy → Done.
        XCTAssertTrue(waitForHittable(next))
        next.tap()
        assertStep(7, progress)
        XCTAssertTrue(waitForHittable(next))
        next.tap()

        // Done: "Browse (all) forums" is offered whether or not forums were pinned before.
        assertStep(8, progress)
        let browse = app.buttons["onboardingBrowseForums"]
        XCTAssertTrue(waitForHittable(browse), "The last step did not appear.")
        XCTAssertFalse(app.buttons["onboardingSkipAll"].isEnabled, "Skip is hidden on the last step.")
        browse.tap()

        XCTAssertTrue(waitForGone(any(app, "onboarding"), timeout: 10), "The walkthrough did not close.")
        XCTAssertTrue(any(app, "forumsHome").waitForExistence(timeout: 10), "Finishing did not land on the Forums home.")
        XCTAssertTrue(app.buttons["forumSwitcher"].exists)
    }

    func testSkipJumpsToTheLastStep() throws {
        let app = launch(["-dc-onboarding-step", "features"])

        let skipAll = app.buttons["onboardingSkipAll"]
        XCTAssertTrue(waitForHittable(skipAll, timeout: 20), "Skip is missing on a middle step.")
        skipAll.tap()
        let browse = app.buttons["onboardingBrowseForums"]
        XCTAssertTrue(waitForHittable(browse), "Skip did not jump to the last step.")

        // Back is hidden on the last step; finishing closes the walkthrough.
        XCTAssertFalse(app.buttons["onboardingBack"].isEnabled)
        browse.tap()
        XCTAssertTrue(waitForGone(any(app, "onboarding"), timeout: 10))
        XCTAssertTrue(any(app, "forumsHome").waitForExistence(timeout: 10))
    }

    func testBackReturnsToThePreviousStep() throws {
        let app = launch(["-dc-onboarding-step", "forums"])

        let progress = any(app, "onboardingProgress")
        XCTAssertTrue(progress.waitForExistence(timeout: 20))
        assertStep(4, progress)
        let back = app.buttons["onboardingBack"]
        XCTAssertTrue(waitForHittable(back))
        back.tap()
        assertStep(3, progress)
        // Leave the walkthrough completed for the other tests.
        app.buttons["onboardingSkipAll"].tap()
        let browse = app.buttons["onboardingBrowseForums"]
        XCTAssertTrue(waitForHittable(browse))
        browse.tap()
        XCTAssertTrue(waitForGone(any(app, "onboarding"), timeout: 10))
    }

    /// The progress dots read "Step N of 8: <title>".
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
}
