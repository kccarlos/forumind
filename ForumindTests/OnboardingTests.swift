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
        XCTAssertTrue(SiteRegistry.standard.adapters.flatMap(\.suggestedForums.chinese).allSatisfy { ForumSite.normalizeSiteURL($0.siteURL) == $0.siteURL })
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

    func testSettingsRootVoiceTodaySummary() {
        XCTAssertEqual(SettingsRootSummary.voiceToday(seconds: 4 * 60 + 20, dailyLimitMinutes: 30), "Voice today 4 of 30 min")
        XCTAssertEqual(SettingsRootSummary.voiceToday(seconds: 0, dailyLimitMinutes: 0), "Voice today 0 min")
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

/// "Show onboarding again" from a Settings sheet: the sheet goes first,
/// then the walkthrough covers the screen; Settings doesn't come back
/// (audit A6).
@MainActor
final class OnboardingReplayTests: XCTestCase {
    private func model() throws -> AppModel {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = PersistentStore(fileURL: directory.appendingPathComponent("state.json"), keys: InMemoryProviderKeyStore())
        let app = AppModel(store: store)
        app.settings.hasCompletedOnboarding = true
        app.acceptTerms()
        return app
    }

    func testFromASettingsSheetTheSheetGoesFirst() async throws {
        let app = try model()
        let delay = PresentationRouter.settleDelay
        PresentationRouter.settleDelay = .milliseconds(10)
        defer { PresentationRouter.settleDelay = delay }
        app.router.item = .expanded(.settings)
        XCTAssertEqual(app.rootPresentation, .expanded(.settings))
        app.replayOnboarding()
        XCTAssertEqual(app.router.onboardingReplay, .waitingForSheet)
        XCTAssertNil(app.rootPresentation, "nothing while the sheet leaves")
        app.replayOnboarding()
        XCTAssertEqual(app.router.onboardingReplay, .waitingForSheet, "a second tap changes nothing")
        app.rootSheetDismissed()
        XCTAssertNil(app.rootPresentation, "a beat for the sheet to leave for good")
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(app.rootPresentation, .onboarding)
        app.dismissRootPresentation(.onboarding)
        XCTAssertEqual(app.router.onboardingReplay, .none)
        XCTAssertNil(app.rootPresentation, "Settings does not come back")
    }

    func testWithoutASheetTheWalkthroughShowsAtOnce() throws {
        let app = try model()
        app.replayOnboarding()
        XCTAssertEqual(app.rootPresentation, .onboarding)
    }
}

/// The walkthrough's top Skip is a model intent on `skipTarget` (audit A12).
@MainActor
final class OnboardingSkipTests: XCTestCase {
    func testSkipGoesToPrivacyThenFinishesOnceTheTermsAreAgreed() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let app = AppModel(store: PersistentStore(fileURL: directory.appendingPathComponent("state.json"), keys: InMemoryProviderKeyStore()))
        app.settings.acceptedTermsVersion = 0
        for step in [OnboardingStep.welcome, .provider, .forums, .daily] {
            XCTAssertEqual(app.skipOnboarding(from: step, termsAgreed: false), .privacy, "\(step)")
        }
        XCTAssertTrue(app.needsTermsAcceptance, "skipping to Privacy accepts nothing")
        XCTAssertNil(app.skipOnboarding(from: .privacy, termsAgreed: false), "not past the Terms unagreed")
        XCTAssertTrue(app.needsTermsAcceptance)
        XCTAssertEqual(app.skipOnboarding(from: .privacy, termsAgreed: true), .done)
        XCTAssertFalse(app.needsTermsAcceptance, "agreed and skipped: accepted")
    }
}
