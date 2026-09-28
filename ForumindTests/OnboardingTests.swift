import XCTest
@testable import Forumind

final class OnboardingTests: XCTestCase {
    func testStepsRunInOrderFromWelcomeToDone() {
        XCTAssertEqual(OnboardingStep.allCases.count, 8)
        XCTAssertEqual(OnboardingStep.first, .welcome)
        XCTAssertEqual(OnboardingStep.last, .done)
        var visited: [OnboardingStep] = [.welcome]
        var step = OnboardingStep.welcome
        while let next = step.next {
            visited.append(next)
            step = next
        }
        XCTAssertEqual(visited, [.welcome, .features, .provider, .forums, .sync, .share, .privacy, .done])
        XCTAssertNil(OnboardingStep.done.next)
        XCTAssertNil(OnboardingStep.welcome.previous)
        XCTAssertEqual(OnboardingStep.forums.previous, .provider)
    }

    func testOnlySetupStepsCanBeSkipped() {
        XCTAssertEqual(OnboardingStep.allCases.filter(\.allowsSkip), [.provider, .forums])
        XCTAssertEqual(OnboardingStep.allCases.filter(\.hasTextInput), [.provider, .forums])
    }

    func testProgressAndLabels() {
        XCTAssertEqual(OnboardingStep.welcome.progress, 0)
        XCTAssertEqual(OnboardingStep.done.progress, 1)
        XCTAssertEqual(OnboardingStep.provider.accessibilityLabel, "Step 3 of 8: Connect an AI provider")
        XCTAssertEqual(OnboardingStep.welcome.continueTitle, "Get started")
        XCTAssertEqual(OnboardingStep.done.continueTitle, "Finish")
        XCTAssertEqual(OnboardingStep.share.continueTitle, "Continue")
    }

    func testParsesDebugStepArgument() {
        XCTAssertEqual(OnboardingStep.parse("1"), .welcome)
        XCTAssertEqual(OnboardingStep.parse("4"), .forums)
        XCTAssertEqual(OnboardingStep.parse("5"), .sync)
        XCTAssertEqual(OnboardingStep.parse("8"), .done)
        XCTAssertNil(OnboardingStep.parse("9"))
        XCTAssertEqual(OnboardingStep.parse("sync"), .sync)
        XCTAssertNil(OnboardingStep.parse("0"))
        XCTAssertEqual(OnboardingStep.parse("Privacy"), .privacy)
        XCTAssertNil(OnboardingStep.parse("nope"))
    }

    func testEveryProviderHasGuidance() {
        for provider in AIProvider.allCases {
            let guide = ProviderGuide.guide(for: provider)
            XCTAssertFalse(guide.blurb.isEmpty, "\(provider) needs a blurb")
            XCTAssertEqual(guide.link.scheme, "https", "\(provider) link must be https")
            // Local providers link to a download and explain how to reach the computer.
            XCTAssertEqual(guide.isLocal, provider.isLocalServer, "\(provider) local mismatch")
            if guide.isLocal { XCTAssertNotNil(guide.note) }
        }
    }

    func testSettingsPagesParseAndHaveTitles() {
        XCTAssertEqual(SettingsPage.parse("forums"), .forums)
        XCTAssertEqual(SettingsPage.parse("Provider"), .provider)
        XCTAssertNil(SettingsPage.parse("root"))
        for page in SettingsPage.allCases {
            XCTAssertFalse(page.title.isEmpty)
            XCTAssertFalse(page.systemImage.isEmpty)
        }
        // UI tests look for this row label on the Settings root.
        XCTAssertEqual(SettingsPage.provider.title, "AI models")
        XCTAssertEqual(SettingsPage.browser.title, "Browser")
    }

    @MainActor
    func testSyncStatusPresentation() {
        let off = SyncStatusPresentation(.off)
        XCTAssertNil(off.action)
        XCTAssertEqual(off.shortLabel, "Off")
        XCTAssertEqual(SyncStatusPresentation(.noAccount).detail, "Sign in to iCloud in the Settings app to sync across your devices.")
        XCTAssertEqual(SyncStatusPresentation(.restricted).detail, "iCloud is turned off for Forumind in Settings › [your name] › iCloud.")
        XCTAssertEqual(SyncStatusPresentation(.unavailable("Try later")).detail, "Try later")
        XCTAssertTrue(SyncStatusPresentation(.syncing).isBusy)
        XCTAssertEqual(SyncStatusPresentation(.upToDate).shortLabel, "On")
        XCTAssertNil(SyncStatusPresentation(.upToDate).action)
        let error = SyncStatusPresentation(.error("Disk full"))
        XCTAssertEqual(error.detail, "Disk full")
        XCTAssertEqual(error.actionTitle, "Sync now")

        XCTAssertEqual(SyncDebug.parse("upToDate"), .upToDate)
        XCTAssertEqual(SyncDebug.parse("no-account"), .noAccount)
        XCTAssertEqual(SyncDebug.parse("restricted"), .restricted)
        XCTAssertNil(SyncDebug.parse("nope"))
        XCTAssertEqual(SettingsPage.parse("sync"), .sync)
        XCTAssertEqual(SettingsPage.sync.title, "iCloud Sync")
    }

    func testVersionText() {
        XCTAssertEqual(
            AppVersion.text(info: ["CFBundleShortVersionString": "1.2", "CFBundleVersion": "34"]),
            "1.2 (34)"
        )
        XCTAssertEqual(AppVersion.text(info: nil), "— (—)")
    }
}
