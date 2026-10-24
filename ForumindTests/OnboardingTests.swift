import XCTest
@testable import Forumind

final class OnboardingTests: XCTestCase {
    func testStepsRunInOrder() {
        XCTAssertEqual(OnboardingStep.allCases, [.welcome, .provider, .forums, .daily, .privacy, .done])
        XCTAssertEqual(OnboardingStep.first, .welcome)
        XCTAssertEqual(OnboardingStep.last, .done)
        XCTAssertNil(OnboardingStep.done.next)
        XCTAssertNil(OnboardingStep.welcome.previous)
        XCTAssertEqual(OnboardingStep.forums.previous, .provider)
        XCTAssertEqual(OnboardingStep.daily.next, .privacy)
    }

    func testOnlyOptionalStepsCanBeSkipped() {
        XCTAssertEqual(OnboardingStep.allCases.filter(\.allowsSkip), [.provider, .forums, .daily])
        XCTAssertEqual(OnboardingStep.allCases.filter(\.hasTextInput), [.provider, .forums])
    }

    func testSkipStopsAtPrivacyThenFinishes() {
        for step in [OnboardingStep.welcome, .provider, .forums, .daily] {
            XCTAssertEqual(step.skipTarget, .privacy, "\(step)")
        }
        XCTAssertEqual(OnboardingStep.privacy.skipTarget, .done)
    }

    func testProgressAndLabels() {
        XCTAssertEqual(OnboardingStep.welcome.progress, 0)
        XCTAssertEqual(OnboardingStep.done.progress, 1)
        XCTAssertEqual(OnboardingStep.provider.accessibilityLabel, "Step 2 of 6: Connect an AI provider")
        XCTAssertEqual(OnboardingStep.welcome.continueTitle, "Get started")
        XCTAssertEqual(OnboardingStep.done.continueTitle, "Finish")
        XCTAssertEqual(OnboardingStep.daily.continueTitle, "Continue")
    }

    func testParseStepNumbersAndNames() {
        XCTAssertEqual(OnboardingStep.parse("1"), .welcome)
        XCTAssertEqual(OnboardingStep.parse("3"), .forums)
        XCTAssertEqual(OnboardingStep.parse("4"), .daily)
        XCTAssertEqual(OnboardingStep.parse("6"), .done)
        XCTAssertNil(OnboardingStep.parse("7"))
        XCTAssertNil(OnboardingStep.parse("0"))
        XCTAssertEqual(OnboardingStep.parse("daily"), .daily)
        XCTAssertEqual(OnboardingStep.parse("Privacy"), .privacy)
        XCTAssertNil(OnboardingStep.parse("sync"))
    }

    func testChineseLanguageSuggestsTheChineseForumsFirst() {
        let chinese = AppModel.onboardingSuggestions(chineseFirst: true).map(\.siteURL)
        XCTAssertEqual(Array(chinese.prefix(2)), ["https://www.uscardforum.com", "https://linux.do"])
        XCTAssertEqual(chinese.count, AppModel.suggestedForums.count + 2)
        let english = AppModel.onboardingSuggestions(chineseFirst: false)
        XCTAssertEqual(english, AppModel.suggestedForums)
        XCTAssertTrue(ForumDirectory.suggestedChinese.allSatisfy { ForumSite.normalizeSiteURL($0.siteURL) == $0.siteURL })
    }

    func testConsentIsAskedOnlyForThirdPartyProviders() {
        XCTAssertTrue(AIProvider.gemini.requiresDataConsent)
        XCTAssertTrue(AIProvider.openRouter.requiresDataConsent)
        XCTAssertFalse(AIProvider.appleIntelligence.requiresDataConsent)
        XCTAssertFalse(AIProvider.ollama.requiresDataConsent)
        XCTAssertEqual(AppSettings().aiConsentState(for: .gemini), .undecided)
        XCTAssertEqual(AppSettings().aiConsentState(for: .appleIntelligence), .notNeeded)
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
