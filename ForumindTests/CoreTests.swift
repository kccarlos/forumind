import XCTest
@testable import Forumind

final class CoreTests: XCTestCase {
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
            summary: ""
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
            CachePlan.make(
                cachedPages: pages,
                knownTotalPosts: 200,
                currentTotalPosts: 200,
                totalPages: 2
            ),
            .unchanged
        )
        XCTAssertEqual(
            CachePlan.make(
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
            CachePlan.make(
                cachedPages: pages,
                knownTotalPosts: 200,
                currentTotalPosts: 150,
                totalPages: 2
            ),
            .fetch(reusablePages: [], pageNumbers: [1, 2])
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
        let result = try await service.fetchTopic(
            siteURL: "https://forum.example.com",
            topicID: "517303",
            cachedPages: [],
            knownTotalPosts: nil,
            cookieHeader: "_forum_session=test"
        ) { _ in }

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
        let service = AIService(session: session)
        let answer = try await service.answer(
            source: "forum",
            summary: "summary",
            history: [ChatMessage(role: .user, content: "question")],
            contextLimit: 10_000,
            customPrompt: "",
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
        let service = AIService(session: session)

        let summary = try await service.generateSummary(
            content: "forum source",
            configuration: ProviderConfiguration(
                model: "test-model",
                baseURL: "https://example.test/v1",
                apiKey: "key"
            ),
            provider: .openAI,
            customPrompt: ""
        ) { _ in }

        XCTAssertEqual(summary, "Summary")
        XCTAssertEqual(attempts, 2)
    }

    func testTaskLimiterSerializesSameTopicWithoutBlockingOtherTopics() async {
        let limiter = TaskLimiter(limit: 2)
        let acquiredTopicA = await limiter.acquire(topicID: "topic-a", workID: UUID())
        let acquiredTopicB = await limiter.acquire(topicID: "topic-b", workID: UUID())
        XCTAssertTrue(acquiredTopicA)
        XCTAssertTrue(acquiredTopicB)

        let secondTopicA = Task {
            await limiter.acquire(topicID: "topic-a", workID: UUID())
        }
        for _ in 0..<100 {
            if await limiter.state().waitingTopics == ["topic-a"] { break }
            await Task.yield()
        }

        var state = await limiter.state()
        XCTAssertEqual(state.activeTopics, ["topic-a", "topic-b"])
        XCTAssertEqual(state.waitingTopics, ["topic-a"])

        await limiter.release(topicID: "topic-b")
        let acquiredTopicC = await limiter.acquire(topicID: "topic-c", workID: UUID())
        XCTAssertTrue(acquiredTopicC)
        state = await limiter.state()
        XCTAssertEqual(state.activeTopics, ["topic-a", "topic-c"])
        XCTAssertEqual(state.waitingTopics, ["topic-a"])

        await limiter.release(topicID: "topic-a")
        let acquiredSecondTopicA = await secondTopicA.value
        XCTAssertTrue(acquiredSecondTopicA)
        state = await limiter.state()
        XCTAssertEqual(state.activeTopics, ["topic-a", "topic-c"])
        XCTAssertTrue(state.waitingTopics.isEmpty)

        await limiter.release(topicID: "topic-a")
        await limiter.release(topicID: "topic-c")
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
            forumName: "Discourse Meta",
            siteURL: "https://meta.discourse.org",
            maxSteps: 7,
            maxTopicReads: 3,
            customInstructions: "Be terse."
        )
        for tool in AgentPrompt.tools {
            XCTAssertTrue(prompt.contains(tool.name), "Prompt is missing \(tool.name)")
        }
        XCTAssertTrue(prompt.contains("at most 7 tool calls and 3 topic reads"))
        XCTAssertTrue(prompt.contains("Be terse."))
        XCTAssertFalse(AgentPrompt.tools.contains { $0.requiresApproval })
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
        let listings = ForumService.parseSearchResults(
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
        let recent = ForumService.parseTopicList(Data(latest.utf8), siteURL: "https://example.com/forum")
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
        let json = #"{"settings":{"selectedProvider":"groq"},"sessions":[],"activities":[]}"#
        let snapshot = try JSONDecoder().decode(AppSnapshot.self, from: Data(json.utf8))
        XCTAssertEqual(snapshot.settings.selectedProvider, .groq)
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

        XCTAssertEqual(run.status, .completed)
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
            if let run = app.agentRuns.first, run.status.isTerminal { return run }
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
        let text = try await AIService(session: session).complete(
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
          "selectedProvider": "openai",
          "favoriteModels": [],
          "systemPrompt": "keep it short",
          "forumContextLimit": 40000
        }
        """
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        XCTAssertEqual(settings.selectedProvider, .openAI)
        XCTAssertEqual(settings.systemPrompt, "keep it short")
        XCTAssertEqual(settings.forumContextLimit, 40_000)
        XCTAssertEqual(settings.summaryBatchLimit, SummaryBatchLimit.default)
        XCTAssertEqual(settings.browserBarPosition, .top)
        XCTAssertEqual(settings.configuration(for: .openAI).model, AIProvider.openAI.defaultModel)

        let sessionJSON = """
        {
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
        let acquiredRunningTopic = await limiter.acquire(
            topicID: "running-topic",
            workID: UUID()
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

        await limiter.release(topicID: "running-topic")
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
