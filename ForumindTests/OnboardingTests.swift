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
        XCTAssertEqual(OnboardingStep.allCases.filter(\.allowsSkip), [.provider, .forums, .sync])
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
        XCTAssertEqual(SettingsPage.provider.title, "AI provider")
        XCTAssertEqual(SettingsPage.browser.title, "Browser")
    }

    @MainActor
    func testSyncStatusPresentation() {
        let off = SyncStatusPresentation(.off)
        XCTAssertEqual(off.action, .chooseFolder)
        XCTAssertEqual(off.detail, "Choose a folder in iCloud Drive to sync your forums, summaries, chats and agent runs across devices.")
        XCTAssertEqual(SyncStatusPresentation(.needsFolderAccess).action, .chooseFolderAgain)
        XCTAssertEqual(SyncStatusPresentation(.notInICloud).action, .chooseAnotherFolder)
        XCTAssertTrue(SyncStatusPresentation(.notInICloud).detail?.contains("isn't in iCloud Drive") == true)
        XCTAssertTrue(SyncStatusPresentation(.waitingForKey).detail?.contains("Passwords and Keychain") == true)
        XCTAssertTrue(SyncStatusPresentation(.syncing).isBusy)
        XCTAssertEqual(SyncStatusPresentation(.upToDate).shortLabel, "On")
        let error = SyncStatusPresentation(.error("Disk full"))
        XCTAssertEqual(error.detail, "Disk full")
        XCTAssertEqual(error.actionTitle, "Sync now")

        XCTAssertEqual(SyncDebug.parse("upToDate"), .upToDate)
        XCTAssertEqual(SyncDebug.parse("needs-folder-access"), .needsFolderAccess)
        XCTAssertEqual(SyncDebug.parse("waitingForKey"), .waitingForKey)
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
