import SwiftUI
import UIKit
import XCTest
@testable import Forumind

extension XCTestCase {
    @MainActor
    func makeSummaryTestApp(
        summary: String,
        totalPosts: Int,
        source: String = "alice | 2026-10-20 | #1\nPost 1",
        aiService: AIService = AIService()
    ) throws -> (AppModel, ForumTopic) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = PersistentStore(fileURL: directory.appendingPathComponent("state.json"), keys: InMemoryProviderKeyStore())
        let siteURL = "https://forum.example.com"
        let url = try XCTUnwrap(URL(string: "\(siteURL)/t/test-topic/42"))
        let topic = ForumTopic(siteURL: siteURL, topicID: "42", url: url, title: "Test topic")
        var session = TopicSession(siteURL: siteURL, topicID: "42", url: url, title: "Test topic")
        session.source = source
        session.summary = summary
        session.totalPosts = totalPosts
        session.summaryPostCount = totalPosts
        session.summaryUpdatedAt = Date()
        session.model = "test-model"
        var snapshot = AppSnapshot()
        snapshot.sessions = [session]
        try store.save(snapshot)
        let app = AppModel(store: store, aiService: aiService)
        let handler = app.browser.onPageContextChanged
        app.browser.onPageContextChanged = nil
        app.allowAllAIProviders()
        app.selectModel(ModelSelection(provider: .ollama, model: "test-model"), for: .both)
        let page = PageContext(url: url, site: .discourse, siteURL: siteURL, forumName: "Forum", topic: topic, state: .topic)
        app.browser.setPageContext(page)
        handler?(page)
        return (app, topic)
    }

    @MainActor
    func hostView<V: View>(_ view: V, size: CGSize) -> (UIWindow, UIHostingController<V>) {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map(UIWindow.init(windowScene:)) ?? UIWindow(frame: CGRect(origin: .zero, size: size))
        window.frame = CGRect(origin: .zero, size: size)
        let host = UIHostingController(rootView: view)
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        window.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        window.layoutIfNeeded()
        addTeardownBlock {
            MainActor.assumeIsolated {
                window.isHidden = true
                window.rootViewController = nil
                window.windowScene = nil
            }
        }
        return (window, host)
    }
}
