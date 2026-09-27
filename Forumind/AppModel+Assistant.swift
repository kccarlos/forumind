import Foundation
import SwiftUI

// MARK: - Assistant helpers (UI engineer C)
//
// - `assistantPageState`           page state the Assistant shows (`.topic` while a topic is selected)
// - `assistantForum`               forum of the page (directory entry or ad hoc), else `currentForum`
// - `agentForum`                   forum the next agent run searches (`agentSiteURL` → page forum)
// - `forumInfo(siteURL:)`          directory entry for a site URL, or a placeholder built from it
// - `manageForums`                 forums that own saved data, pinned first (Manage grouping)
// - `recentSessions(siteURL:limit:)` saved topics on one forum, newest first
// - `AgentSources.extract(run:sessions:)` numbered [S1]… sources of an agent answer

extension AppModel {
    /// What the Assistant body shows. A selected topic wins (UI-test seeds keep
    /// a topic while the browser reports another page).
    var assistantPageState: PageContext.State {
        currentTopic != nil ? .topic : pageContext.state
    }

    /// The forum the Assistant header names.
    var assistantForum: Forum? {
        if let siteURL = pageContext.siteURL ?? currentTopic?.siteURL {
            if let forum = forum(for: siteURL) { return forum }
            return Forum(siteURL: siteURL, name: pageContext.forumName, iconURL: pageContext.iconURL)
        }
        return currentForum
    }

    /// The forum the next agent run searches.
    var agentForum: Forum? {
        if let agentSiteURL { return forumInfo(siteURL: agentSiteURL) }
        return assistantForum
    }

    func forumInfo(siteURL: String) -> Forum {
        if let forum = forum(for: siteURL) { return forum }
        if pageContext.siteURL == siteURL {
            return Forum(siteURL: siteURL, name: pageContext.forumName, iconURL: pageContext.iconURL)
        }
        return Forum(siteURL: siteURL, name: ForumSite.displayName(siteURL: siteURL, name: nil))
    }

    /// Forums with saved summaries, chats, agent runs, watched topics or
    /// activity: pinned ones in the user's order, then the rest by name.
    var manageForums: [Forum] {
        var siteURLs = Set(sessions.values.map(\.siteURL))
        siteURLs.formUnion(activities.map(\.siteURL))
        siteURLs.formUnion(agentRuns.map(\.siteURL))
        siteURLs.formUnion(watchedTopics.map(\.siteURL))
        siteURLs.remove("")
        let known = siteURLs.map(forumInfo(siteURL:))
        let pinned = known.filter(\.isPinned).sorted { $0.pinOrder < $1.pinOrder }
        let others = known.filter { !$0.isPinned }.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
        return pinned + others
    }

    func recentSessions(siteURL: String, limit: Int = 4) -> [TopicSession] {
        Array(
            sessions.values
                .filter { $0.siteURL == siteURL && ($0.hasSummary || !$0.history.isEmpty) }
                .sorted { $0.lastAccessedAt > $1.lastAccessedAt }
                .prefix(limit)
        )
    }
}

// MARK: - Agent sources

/// The topics an agent answer relies on, numbered in order of first citation.
/// The agent cites as `[title](url)`; topics it read but did not cite follow.
enum AgentSources {
    struct Source: Identifiable, Equatable {
        var number: Int
        var title: String
        var url: URL
        var cited: Bool

        var id: Int { number }
        var label: String { "S\(number)" }
    }

    private static let linkPattern = try? NSRegularExpression(
        pattern: #"\[([^\]\n]+)\]\((https?://[^)\s]+)\)"#
    )

    /// Same topic regardless of slug, post number, or query.
    static func identity(of url: URL) -> String {
        let host = url.host?.lowercased() ?? ""
        if let topicID = ForumSite.looseTopicID(from: url) { return "\(host)/t/\(topicID)" }
        return url.absoluteString
    }

    static func extract(from answer: String, run: AgentRun?, sessions: [String: TopicSession]) -> [Source] {
        var sources: [Source] = []
        var seen: [String: Int] = [:]
        for (title, url) in links(in: answer) {
            let key = identity(of: url)
            guard seen[key] == nil else { continue }
            let number = sources.count + 1
            seen[key] = number
            sources.append(Source(number: number, title: title, url: url, cited: true))
        }
        for step in run?.steps ?? [] {
            guard let topicKey = step.topicKey, let session = sessions[topicKey] else { continue }
            let key = identity(of: session.url)
            guard seen[key] == nil else { continue }
            let number = sources.count + 1
            seen[key] = number
            sources.append(Source(number: number, title: session.title, url: session.url, cited: false))
        }
        return sources
    }

    /// Rewrites each `[title](url)` citation as `title [S1](url)`, so the
    /// Markdown view renders the number as a tappable chip.
    static func annotate(_ answer: String, sources: [Source]) -> String {
        guard let linkPattern, !sources.isEmpty else { return answer }
        let numbers = Dictionary(
            sources.map { (identity(of: $0.url), $0.number) },
            uniquingKeysWith: { first, _ in first }
        )
        let nsAnswer = answer as NSString
        var result = ""
        var cursor = 0
        for match in linkPattern.matches(in: answer, range: NSRange(location: 0, length: nsAnswer.length)) {
            let title = nsAnswer.substring(with: match.range(at: 1))
            let urlText = nsAnswer.substring(with: match.range(at: 2))
            guard let url = URL(string: urlText), let number = numbers[identity(of: url)] else { continue }
            result += nsAnswer.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            // A bare "[S1](url)" or a title that is just the URL keeps only the chip.
            let trimmed = title.trimmingCharacters(in: .whitespaces)
            if trimmed.range(of: #"^S\d+$"#, options: .regularExpression) == nil, trimmed != urlText {
                result += "\(trimmed) "
            }
            result += "[S\(number)](\(urlText))"
            cursor = match.range.location + match.range.length
        }
        result += nsAnswer.substring(from: cursor)
        return result
    }

    private static func links(in text: String) -> [(String, URL)] {
        guard let linkPattern else { return [] }
        let nsText = text as NSString
        return linkPattern.matches(in: text, range: NSRange(location: 0, length: nsText.length))
            .compactMap { match in
                let title = nsText.substring(with: match.range(at: 1))
                guard let url = URL(string: nsText.substring(with: match.range(at: 2))) else { return nil }
                return (title, url)
            }
    }
}

// MARK: - DEBUG sample data (screenshots / QA)

#if DEBUG
/// Everything a DEBUG seed replaces (applied by `AppModel.applyDebugSeed`).
struct AssistantDebugSeed {
    var forums: [Forum]
    var sessions: [TopicSession]
    var activities: [WorkRecord]
    var agentRuns: [AgentRun]
    var watchedTopics: [WatchedTopic]
    var currentTopic: ForumTopic?
    var currentForum: Forum?
    var pageContext: PageContext
}

/// Launch arguments (need no API key or network):
///
/// - `-dc-sample`                      multi-forum sample data (required for the others)
/// - `-dc-page-state <state>`          loading | notForum | maybe | forumHome | topic (default)
/// - `-dc-topic meta|makers`           which sample topic is open (default meta)
/// - `-dc-assistant-mode <mode>`       summary | chat | agent
/// - `-dc-open-manage`                 opens Manage
/// - `-dc-no-provider`                 leaves the AI provider unconfigured
/// - `-dc-summary-running`             a summary in progress (streaming text)
/// - `-dc-chat-streaming`              a chat answer in progress
/// - `-dc-agent-running`               the agent run is still working
/// - `-dc-no-summary`                  the open topic has no summary yet
/// - `-dc-scroll-sources`              Agent: scrolls to the answer's sources
/// - `-dc-manage-kind <kind>`          Manage: all | summaries | agent | watched | activity
/// - `-dc-chat-typing`                 with `-dc-chat-streaming`: no text yet (typing dots)
/// - `-dc-stale-summary`               the makers topic's summary is behind (stale notice)
/// - `-dc-forums-home`                 keeps the Forums home up (no sample page load)
/// - with `-dc-apple-intelligence on-device|pcc`, sample runs are labeled Apple Intelligence
enum AssistantDebug {
    static var arguments: [String] { ProcessInfo.processInfo.arguments }
    static var isActive: Bool { arguments.contains("-dc-sample") }
    static func has(_ flag: String) -> Bool { arguments.contains(flag) }
    static func value(_ flag: String) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }
}

extension AppModel {
    func seedAssistantSample() {
        let now = Date()
        // With `-dc-apple-intelligence on-device|pcc`, the sample runs are
        // labeled as Apple Intelligence runs (for screenshots).
        let sampleBackend = AppleIntelligenceClient.debugStatus?.backend
        let sampleProvider: AIProvider = sampleBackend == nil ? .anthropic : .appleIntelligence
        let sampleModel = sampleBackend?.label ?? "claude-sonnet-4-5"
        func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }

        let meta = Forum(
            siteURL: "https://meta.discourse.org", name: "Discourse Meta",
            isPinned: true, pinOrder: 0, lastVisitedAt: ago(2)
        )
        // Fictional communities on reserved example domains (screenshots
        // show no real companies or people).
        let makers = Forum(
            siteURL: "https://community.example.org", name: "Maker Space Community",
            isPinned: true, pinOrder: 1, lastVisitedAt: ago(30)
        )
        let homeLab = Forum(
            siteURL: "https://forum.example.net", name: "Home Lab Forum",
            lastVisitedAt: ago(60 * 26)
        )

        func topic(_ forum: Forum, _ id: String, _ slug: String, _ title: String) -> ForumTopic {
            ForumTopic(
                siteURL: forum.siteURL,
                topicID: id,
                url: URL(string: "\(forum.siteURL)/t/\(slug)/\(id)")!,
                title: title
            )
        }
        func session(
            _ topic: ForumTopic, posts: Int, summarized: Int? = nil, summary: String,
            chat: [(ChatRole, String)] = [], kept: Bool = false, updated: Double
        ) -> TopicSession {
            var value = TopicSession(siteURL: topic.siteURL, topicID: topic.topicID, url: topic.url, title: topic.title)
            value.source = "Sample post and replies for \(topic.title)."
            value.summary = summary
            value.history = chat.enumerated().map { index, message in
                ChatMessage(role: message.0, content: message.1, createdAt: ago(updated - Double(index)))
            }
            value.kept = kept
            value.totalPosts = posts
            value.summaryPostCount = summarized ?? posts
            value.provider = sampleProvider
            value.model = sampleModel
            value.createdAt = ago(updated + 30)
            value.updatedAt = ago(updated)
            value.summaryUpdatedAt = ago(updated)
            value.chatUpdatedAt = chat.isEmpty ? nil : ago(updated)
            value.lastAccessedAt = ago(updated)
            return value
        }

        let unifiedNew = topic(meta, "404728", "introducing-the-unified-new-view-for-the-topic-list",
                               "Introducing the unified new view for the topic list")
        let markdownEndpoints = topic(meta, "413006", "discourse-core-now-includes-markdown-endpoints-for-topic-lists-and-views",
                                      "Discourse core now includes Markdown endpoints for topic lists and views")
        let sidebar = topic(meta, "413150", "experimental-user-sidebar-navigation", "Experimental user sidebar navigation")
        let layerShifts = topic(makers, "18342",
                                "layer-shifts-on-long-prints-after-the-2-4-firmware-update",
                                "Layer shifts on long prints after the 2.4 firmware update")
        let stepperHeat = topic(makers, "18391", "stepper-drivers-overheating-in-enclosed-printers",
                                "Stepper drivers overheating in enclosed printers")
        let slicerPresets = topic(makers, "18377", "sharing-slicer-presets-between-machines",
                                  "Sharing slicer presets between machines")
        let fanAfterPrint = topic(makers, "18402", "cooling-fan-keeps-running-after-a-print-finishes",
                                  "Cooling fan keeps running after a print finishes")
        let lowPowerNAS = topic(homeLab, "7713", "low-power-nas-build-for-2026", "Low-power NAS build for 2026")

        let metaSummary = """
        ## Original post
        The Discourse team merged the separate **New** and **Unread** lists into one *unified new view*, \
        with tabs to narrow it to new topics or new replies. It is on by default for new sites and \
        opt-in for existing ones.

        ## What people are saying
        - **Most like it**: one place to catch up, and the counts in the sidebar finally match.
        - **Keyboard users** asked for a shortcut to switch tabs; `g n` still opens the view.
        - **Admins** want a per-group default so staff can keep the old lists for a while.

        ## Tips from the thread
        1. Enable it under *Admin → Settings → experimental new new view groups* first.
        2. Tell members that “Dismiss” now clears both topics and replies.

        > “It took a day to get used to, now I can’t go back.” — a site admin

        Settings keys mentioned:

        ```text
        experimental_new_new_view_groups
        ```

        See the [announcement](https://meta.discourse.org/t/introducing-the-unified-new-view-for-the-topic-list/404728) for screenshots.
        """
        let metaChat: [(ChatRole, String)] = [
            (.user, "Can I roll it out to staff first?"),
            (.assistant, "Yes. Add your **staff** group to `experimental_new_new_view_groups`; everyone else keeps the separate New and Unread lists until you add more groups.")
        ]
        let streamSummary = """
        ## Problem
        Since the **2.4 firmware update**, prints longer than about six hours show *layer shifts* \
        partway up, while short prints come out fine.

        ## Workarounds reported
        - Lower the **travel speed** by 20–30%.
        - Re-tension the belts, then re-run the calibration.
        - Rolling back to 2.3 helps some, but not everyone.

        ## Status
        The firmware maintainers confirmed the report; no fix date yet.
        """
        let streamChat: [(ChatRole, String)] = [
            (.user, "Which workaround works most often?"),
            (.assistant, "Lowering the travel speed is the one most people confirm. Re-tensioning the belts helped in **about a third** of replies."),
            (.user, "Did anyone hear back from the firmware maintainers?"),
            (.assistant, "Yes — a maintainer asked for print logs and said a fix is being tested. There is no release date in the thread yet.")
        ]

        var sessions = [
            session(unifiedNew, posts: 68, summary: metaSummary, chat: metaChat, kept: true, updated: 6),
            session(markdownEndpoints, posts: 12, summary: "## Summary\nAppending `.md` to topic list and topic URLs now returns Markdown — handy for tools and AI assistants.", updated: 12),
            session(sidebar, posts: 7, summary: "## Summary\nAn experimental sidebar lets each user choose sections and links.", updated: 60 * 5),
            session(layerShifts, posts: 35, summarized: AssistantDebug.has("-dc-stale-summary") ? 29 : nil, summary: streamSummary, chat: streamChat, kept: true, updated: 45),
            session(stepperHeat, posts: 2, summary: "## Summary\nDrivers in enclosed printers hit thermal shutdown on long prints; a small fan on the board fixes it.", updated: 60 * 2),
            session(slicerPresets, posts: 5, summary: "## Summary\nMembers keep their slicer presets in a shared folder so every machine prints the same way.", updated: 60 * 3),
            session(lowPowerNAS, posts: 78, summary: "## Summary\nMembers compare low-power storage builds; most idle under 15 W with the disks spun down.", updated: 60 * 26)
        ]

        let openTopic = AssistantDebug.value("-dc-topic") == "makers" ? layerShifts : unifiedNew
        if AssistantDebug.has("-dc-no-summary"),
           let index = sessions.firstIndex(where: { $0.topicKey == openTopic.topicKey }) {
            sessions[index].summary = ""
            sessions[index].history = []
            sessions[index].summaryPostCount = nil
        }

        // Agent runs: a finished run with a sourced answer, and an older one.
        var run = AgentRun(
            siteURL: makers.siteURL,
            goal: "What are people saying about layer shifts after the 2.4 firmware update?",
            provider: sampleProvider,
            model: sampleModel
        )
        run.createdAt = ago(20)
        run.updatedAt = ago(18)
        run.completedAt = ago(18)
        run.status = .completed
        run.topicIDs = [layerShifts.topicID, stepperHeat.topicID, fanAfterPrint.topicID]
        run.steps = [
            AgentStep(tool: "search_forum", arguments: ["query": "layer shift firmware 2.4"],
                      thought: "Search for reports of the layer shifts.", outcome: "8 topics found",
                      startedAt: ago(20), finishedAt: ago(20)),
            AgentStep(tool: "read_topic", arguments: ["topic_id": layerShifts.topicID],
                      thought: "The main report thread.", outcome: "Read 35 posts",
                      topicID: layerShifts.topicID, topicKey: layerShifts.topicKey,
                      startedAt: ago(19.5), finishedAt: ago(19.4)),
            AgentStep(tool: "read_topic", arguments: ["topic_id": stepperHeat.topicID],
                      thought: "Overheating drivers can also skip steps.", outcome: "Read 2 posts",
                      topicID: stepperHeat.topicID, topicKey: stepperHeat.topicKey,
                      startedAt: ago(19.2), finishedAt: ago(19.1)),
            AgentStep(tool: "search_forum", arguments: ["query": "layer shift travel speed workaround"],
                      thought: "Look for confirmed workarounds.", outcome: "5 topics found",
                      startedAt: ago(19), finishedAt: ago(19)),
            AgentStep(tool: "read_topic", arguments: ["topic_id": fanAfterPrint.topicID],
                      thought: "Check whether the other 2.4 change is related.", outcome: "Read 1 post",
                      topicID: fanAfterPrint.topicID, topicKey: fanAfterPrint.topicKey,
                      startedAt: ago(18.8), finishedAt: ago(18.7)),
            AgentStep(tool: AgentPrompt.finalAnswerTool, thought: "Enough to answer.", outcome: "Answered",
                      startedAt: ago(18.2), finishedAt: ago(18))
        ]
        run.answer = """
        People report the shifts mostly on **prints longer than six hours**, while short prints \
        come out fine ([Layer shifts after 2.4](\(layerShifts.url.absoluteString))). \
        The most confirmed workaround is to **lower the travel speed**; re-tensioning the belts \
        helps some members.

        A few replies link it to drivers overheating in enclosures \
        ([Stepper drivers overheating](\(stepperHeat.url.absoluteString))), but the fan that keeps \
        running after a print looks like a separate bug ([Cooling fan](\(fanAfterPrint.url.absoluteString))).

        - The maintainers asked for print logs; no fix date yet.
        - Rolling back to 2.3 does **not** reliably help.
        """
        run.initialAnswer = run.answer
        run.followUps = [
            ChatMessage(role: .user, content: "Is it only on the larger printers?", createdAt: ago(17)),
            ChatMessage(role: .assistant, content: "No — reports cover both the small and the large beds. Nobody reports it on resin printers.", createdAt: ago(16))
        ]
        var olderRun = AgentRun(
            siteURL: meta.siteURL,
            goal: "How do I roll out the unified new view gradually?",
            provider: sampleProvider,
            model: sampleModel
        )
        olderRun.status = .completed
        olderRun.createdAt = ago(60 * 4)
        olderRun.completedAt = ago(60 * 4)
        olderRun.answer = "Add groups to `experimental_new_new_view_groups` one at a time, starting with staff."
        olderRun.initialAnswer = olderRun.answer
        olderRun.steps = [
            AgentStep(tool: "search_forum", arguments: ["query": "unified new view groups"], outcome: "3 topics found"),
            AgentStep(tool: AgentPrompt.finalAnswerTool, outcome: "Answered")
        ]
        olderRun.topicIDs = [unifiedNew.topicID]

        var activities: [WorkRecord] = []
        func record(_ type: WorkType, _ topic: ForumTopic, _ minutes: Double, status: WorkStatus = .completed, text: String = "Completed") -> WorkRecord {
            var value = WorkRecord(type: type, siteURL: topic.siteURL, topicID: topic.topicID,
                                   title: topic.title, url: topic.url, provider: sampleProvider, model: sampleModel)
            value.status = status
            value.phase = status.rawValue
            value.statusText = text
            value.progress = status == .completed ? 1 : nil
            value.createdAt = ago(minutes + 2)
            value.updatedAt = ago(minutes)
            value.completedAt = status.isTerminal ? ago(minutes) : nil
            return value
        }
        activities.append(record(.summary, unifiedNew, 6, text: "Summarized 68 posts"))
        activities.append(record(.chat, layerShifts, 45, text: "Answered"))
        activities.append(record(.summary, stepperHeat, 120, status: .failed, text: "Failed"))

        var currentRun = run
        if AssistantDebug.has("-dc-agent-running") {
            currentRun.status = .running
            currentRun.completedAt = nil
            currentRun.answer = ""
            currentRun.initialAnswer = ""
            currentRun.followUps = []
            currentRun.steps = Array(run.steps.prefix(4))
            currentRun.steps[3].finishedAt = nil
            currentRun.steps[3].outcome = ""
            var agentRecord = WorkRecord(
                type: .agent, siteURL: makers.siteURL, topicID: "agent:" + run.id.uuidString,
                title: run.goal, url: makers.latestURL!, provider: sampleProvider, model: sampleModel
            )
            agentRecord.status = .running
            agentRecord.statusText = "Searching “layer shift travel speed workaround”…"
            activities.insert(agentRecord, at: 0)
        }
        if AssistantDebug.has("-dc-summary-running") {
            var summaryRecord = record(.summary, openTopic, 0, status: .running, text: "Summarizing posts 41–60 of 68…")
            summaryRecord.phase = "summarizing"
            summaryRecord.progress = 0.62
            activities.insert(summaryRecord, at: 0)
            summaryStreams[summaryRecord.id] = """
            ## Original post
            The Discourse team merged the separate **New** and **Unread** lists into one *unified new view*.

            ## What people are saying
            - **Most like it**: one place to catch up
            """
        }
        if AssistantDebug.has("-dc-chat-streaming") {
            var chatRecord = record(.chat, openTopic, 0, status: .running, text: "Answering…")
            chatRecord.question = "Does it change the keyboard shortcuts?"
            activities.insert(chatRecord, at: 0)
            if let index = sessions.firstIndex(where: { $0.topicKey == openTopic.topicKey }) {
                sessions[index].history.append(ChatMessage(role: .user, content: chatRecord.question))
            }
            chatStreams[chatRecord.id] = AssistantDebug.has("-dc-chat-typing") ? "" : "Only one: `g n` now opens the unified view, and"
        }

        var watchedMeta = WatchedTopic(siteURL: meta.siteURL, topicID: unifiedNew.topicID, url: unifiedNew.url,
                                       title: unifiedNew.title, knownPostCount: 68)
        watchedMeta.newReplies = 3
        watchedMeta.lastCheckedAt = ago(8)
        var watchedStream = WatchedTopic(siteURL: makers.siteURL, topicID: layerShifts.topicID, url: layerShifts.url,
                                         title: layerShifts.title, knownPostCount: 35)
        watchedStream.lastCheckedAt = ago(40)
        var watchedNAS = WatchedTopic(siteURL: homeLab.siteURL, topicID: lowPowerNAS.topicID, url: lowPowerNAS.url,
                                         title: lowPowerNAS.title, knownPostCount: 78)
        watchedNAS.newReplies = 1
        watchedNAS.lastCheckedAt = ago(90)

        // Page state.
        let state = AssistantDebug.value("-dc-page-state").flatMap(PageContext.State.init(rawValue:)) ?? .topic
        let openForum = openTopic.siteURL == makers.siteURL ? makers : meta
        var context: PageContext
        var selected: ForumTopic?
        switch state {
        case .topic:
            selected = openTopic
            context = PageContext(url: openTopic.url, isDiscourse: true, siteURL: openForum.siteURL,
                                  forumName: openForum.name, topic: openTopic, state: .topic)
        case .forumHome:
            context = PageContext(url: openForum.latestURL, isDiscourse: true, siteURL: openForum.siteURL,
                                  forumName: openForum.name, state: .forumHome)
        case .notForum:
            context = PageContext(url: URL(string: "https://www.apple.com/newsroom/"), state: .notForum)
        case .maybe:
            context = PageContext(url: URL(string: "https://forum.example.org/t/welcome-to-our-community/1234"), state: .maybe)
        case .loading:
            context = PageContext(url: nil, state: .loading)
        }

        applyDebugSeed(AssistantDebugSeed(
            forums: [meta, makers, homeLab],
            sessions: sessions,
            activities: activities,
            agentRuns: [currentRun, olderRun],
            watchedTopics: [watchedMeta, watchedStream, watchedNAS],
            currentTopic: selected,
            currentForum: openForum,
            pageContext: context
        ))

        // Keep the seeded page state: later page loads must not replace it.
        browser.onPageContextChanged = { _ in }
        browser.homeSiteURL = openForum.siteURL
        // `-dc-forums-home` keeps the Forums home up: no page load at all.
        if let url = context.url, state != .maybe, !AssistantDebug.has("-dc-forums-home") {
            browser.load(url)
        }

        settings.hasCompletedOnboarding = true
        settings.selectedProvider = sampleProvider
        if sampleProvider == .anthropic {
            var configuration = settings.configuration(for: .anthropic)
            configuration.model = "claude-sonnet-4-5"
            // In memory only: never sent anywhere unless the user starts work.
            configuration.apiKey = AssistantDebug.has("-dc-no-provider") ? "" : "sample-key"
            settings.setConfiguration(configuration, for: .anthropic)
        }

        if let mode = AssistantDebug.value("-dc-assistant-mode")?.lowercased() {
            assistantMode = AssistantMode.allCases.first { $0.rawValue.lowercased() == mode } ?? .summary
        }
        if AssistantDebug.has("-dc-open-manage") { panelRoute = .activity }
        // Show the Assistant pane on iPhone once the UI is up (sent twice in
        // case the first arrives before ContentView observes it).
        Task { @MainActor [weak self] in
            for delay in [500, 1200] {
                try? await Task.sleep(for: .milliseconds(delay))
                self?.presentAssistant = true
            }
        }
    }
}
#endif
