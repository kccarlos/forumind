import Foundation

/// What the voice layer needs from the app: the navigation layer
/// (AppModel+Navigation.swift) plus a few reads for the silent context.
/// AppModel conforms (AppModel+Voice.swift); tests use a fake.
@MainActor
protocol VoiceNavigator: AnyObject {
    var pageContext: PageContext { get }
    var browseCursor: BrowseCursor { get }
    var isResearching: Bool { get }

    func find(_ query: String, scope: BrowseSearchScope) async -> BrowseResult
    func openTopic(_ target: BrowseTarget, at landing: BrowseLanding, includeContent: Bool) async -> BrowseResult
    func openCard(_ index: Int, includeContent: Bool) async -> BrowseResult
    func goToPost(_ number: Int) async -> BrowseResult
    func next() async -> BrowseResult
    func previous() async -> BrowseResult
    func back() -> BrowseResult
    func forward() -> BrowseResult
    func focus(_ focus: BrowseFocus) async -> BrowseResult
    func read(post: Int?) async -> BrowseResult
    /// The text of every post on screen.
    func readVisible() async -> BrowseResult
    func research(_ request: String, siteURL: String?) async -> BrowseResult
    func cancelResearch() -> BrowseResult
    /// The running research's latest step, in English ("Reading “Fan
    /// noise after update”"); nil when none runs.
    var researchProgress: String? { get }

    /// The open topic's facts for the topic brief; nil off topics.
    func voiceTopicBrief() async -> VoiceTopicBrief?
    /// Posts in the viewport with their first lines.
    func postsOnScreen() async -> [VisiblePost]
    /// A quick summary of the open topic from the summary pipeline, when it
    /// has no saved one; nil when it can't be made.
    func quickSummary(topicKey: String) async -> String?
}

/// What a tool call produced.
struct VoiceToolOutcome: Equatable {
    enum Effect: Equatable {
        case none
        /// A research started: the session watches for an acknowledgement.
        case researchStarted
        /// End the session after the goodbye.
        case end
    }

    var response: [String: JSONValue]
    var scheduling: GeminiLive.Scheduling
    var effect: Effect = .none
}

/// A message for the model that answers no call of its own: a function
/// response under a made-up id and the name `briefing`, so every
/// scheduling mode works for it (a user-role turn would read as the user
/// speaking).
struct VoiceBriefing: Equatable {
    static let name = "briefing"

    enum Kind: String {
        case researchProgress = "research progress"
        case researchAnswer = "research answer"
        case researchEnded = "research ended"
        case context
    }

    var kind: Kind
    var facts: [String: JSONValue]
    var scheduling: GeminiLive.Scheduling
    /// Text to re-send as a turn if the model doesn't voice it in time.
    var spokenText: String?
}

/// Runs the voice tools on the navigation layer and turns each
/// `BrowseResult` into a function response: `status`, `shown`, `content`,
/// `hits`, and a `message` telling the model what to say next.
@MainActor
final class VoiceToolBridge {
    weak var navigator: VoiceNavigator?
    /// Where research briefings go (the session).
    var onBriefing: ((VoiceBriefing) -> Void)?
    /// How often a running research is checked for progress.
    var progressInterval: Duration = .seconds(2)
    private var researchTask: Task<Void, Never>?
    private var researchSequence = 0

    init(navigator: VoiceNavigator?) {
        self.navigator = navigator
    }

    func handle(_ call: GeminiLive.FunctionCall, eyesFree: Bool) async -> VoiceToolOutcome {
        guard let tool = VoiceTool(rawValue: call.name) else {
            return refusal("There is no tool called \(call.name).", scheduling: .whenIdle)
        }
        guard let navigator else {
            return refusal("The browser isn't available.", scheduling: tool.scheduling)
        }
        let args = call.args
        let result: BrowseResult
        switch tool {
        case .find:
            let query = args["query"]?.textValue ?? ""
            let scope: BrowseSearchScope = args["scope"]?.stringValue == "topic" ? .topic : .forum
            result = await navigator.find(query, scope: scope)
        case .open:
            result = await open(args, navigator: navigator)
        case .move:
            result = await move(action: args["action"]?.stringValue ?? "", post: args["post"]?.intValue, navigator: navigator)
        case .focus:
            result = await focus(args, navigator: navigator)
        case .read:
            if args["scope"]?.stringValue == "visible" {
                result = await navigator.readVisible()
            } else {
                result = await navigator.read(post: args["post"]?.intValue)
            }
        case .research:
            return await research(args, navigator: navigator, eyesFree: eyesFree)
        case .end:
            return VoiceToolOutcome(
                response: ["status": "ending", "message": "The conversation ends once your goodbye has played. Say nothing more."],
                scheduling: tool.scheduling,
                effect: .end
            )
        }
        return VoiceToolOutcome(response: Self.response(result, tool: tool, eyesFree: eyesFree), scheduling: tool.scheduling)
    }

    /// Stops a running research (the session ends).
    func stop() {
        researchTask?.cancel()
        researchTask = nil
        if navigator?.isResearching == true { _ = navigator?.cancelResearch() }
    }

    // MARK: Tools

    private func open(_ args: [String: JSONValue], navigator: VoiceNavigator) async -> BrowseResult {
        let landing: BrowseLanding? = switch args["at"]?.stringValue {
        case "post": args["post"]?.intValue.map(BrowseLanding.post)
        case "solution": .solution
        case "last": .last
        case "top": .top
        case "unread": .firstNew
        default: args["post"]?.intValue.map(BrowseLanding.post)
        }
        if let card = args["card"]?.intValue {
            guard landing == nil || landing == .firstNew else {
                // A card opened somewhere else than its own post.
                let items = navigator.browseCursor.items
                guard items.indices.contains(card - 1) else {
                    return BrowseResult(status: .notFound, shown: "There is no card \(card).")
                }
                return await navigator.openTopic(.item(items[card - 1]), at: landing ?? .firstNew, includeContent: true)
            }
            return await navigator.openCard(card - 1, includeContent: true)
        }
        if let topic = args["topic_id"]?.textValue, !topic.filter(\.isNumber).isEmpty {
            return await navigator.openTopic(.topic(topic), at: landing ?? .firstNew, includeContent: true)
        }
        guard let ref = navigator.pageContext.topic else {
            return BrowseResult(status: .unavailable, shown: "No topic is open; search or pick a card first.")
        }
        return await navigator.openTopic(.topic(ref.topicID), at: landing ?? .firstNew, includeContent: true)
    }

    private func move(action: String, post: Int?, navigator: VoiceNavigator) async -> BrowseResult {
        switch action {
        case "next": return await navigator.next()
        case "previous": return await navigator.previous()
        case "back": return navigator.back()
        case "forward": return navigator.forward()
        case "post":
            guard let post else { return BrowseResult(status: .notFound, shown: "No post number was given.") }
            return await navigator.goToPost(post)
        case "top": return await navigator.goToPost(1)
        case "bottom":
            guard let topic = navigator.pageContext.topic else {
                return BrowseResult(status: .unavailable, shown: "No topic is open.")
            }
            return await navigator.openTopic(.topic(topic.topicID), at: .last, includeContent: true)
        default:
            return BrowseResult(status: .unavailable, shown: "Unknown move \"\(action)\".")
        }
    }

    private func focus(_ args: [String: JSONValue], navigator: VoiceNavigator) async -> BrowseResult {
        switch args["mode"]?.stringValue {
        case "user":
            let name = (args["user"]?.textValue ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "@ "))
            guard !name.isEmpty else { return BrowseResult(status: .notFound, shown: "No username was given.") }
            return await navigator.focus(.user(name))
        case "op": return await navigator.focus(.op)
        case "top": return await navigator.focus(.top)
        case "posts":
            let numbers = (args["posts"]?.arrayValue ?? []).compactMap(\.intValue)
            return await navigator.focus(.posts(numbers))
        case "clear": return await navigator.focus(.clear)
        default: return BrowseResult(status: .unavailable, shown: "Unknown focus mode.")
        }
    }

    // MARK: Research

    private func research(_ args: [String: JSONValue], navigator: VoiceNavigator, eyesFree: Bool) async -> VoiceToolOutcome {
        if args["action"]?.stringValue == "cancel" {
            researchTask?.cancel()
            researchTask = nil
            let result = navigator.cancelResearch()
            return VoiceToolOutcome(response: Self.response(result, tool: .research, eyesFree: eyesFree), scheduling: .whenIdle)
        }
        let request = (args["request"]?.textValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty else {
            return refusal("No question was given to research.", scheduling: .whenIdle)
        }
        // Routing in code: a browser action sent to research is done here.
        if let routed = VoiceRouting.browserAction(for: request) {
            let result: BrowseResult
            let tool: VoiceTool
            switch routed {
            case .move(let action):
                tool = .move
                result = await move(action: action, post: nil, navigator: navigator)
            case .post(let number):
                tool = .move
                result = await navigator.goToPost(number)
            case .solution:
                tool = .open
                result = await open(["at": "solution"], navigator: navigator)
            }
            var response = Self.response(result, tool: tool, eyesFree: eyesFree)
            response["routed"] = .string("This was a browser action, done directly with \(tool.rawValue); use \(tool.rawValue) for it next time.")
            return VoiceToolOutcome(response: response, scheduling: .whenIdle)
        }
        startResearch(request, navigator: navigator)
        return VoiceToolOutcome(
            response: [
                "status": "started",
                "shown": "Research is running in the background.",
                "message": "You have already acknowledged it, so say nothing now. The answer arrives as a briefing; don't call research again for this question."
            ],
            scheduling: .silent,
            effect: .researchStarted
        )
    }

    /// Runs one research at a time: a new one cancels the old (whose result
    /// is then dropped), progress goes out silently, the answer WHEN_IDLE.
    private func startResearch(_ request: String, navigator: VoiceNavigator) {
        researchTask?.cancel()
        researchSequence += 1
        let sequence = researchSequence
        let interval = progressInterval
        let progress = Task { @MainActor [weak self, weak navigator] in
            var last: String?
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self, self.researchSequence == sequence, let step = navigator?.researchProgress, step != last else { continue }
                last = step
                self.onBriefing?(VoiceBriefing(
                    kind: .researchProgress,
                    facts: ["request": .string(request), "step": .string(step), "message": "Progress only; say nothing unless the user asks how it's going."],
                    scheduling: .silent
                ))
            }
        }
        researchTask = Task { @MainActor [weak self, weak navigator] in
            defer { progress.cancel() }
            guard let navigator else { return }
            let result = await navigator.research(request, siteURL: nil)
            guard let self, self.researchSequence == sequence, !Task.isCancelled else { return }
            self.researchTask = nil
            self.onBriefing?(Self.researchBriefing(result, request: request))
        }
    }

    static func researchBriefing(_ result: BrowseResult, request: String) -> VoiceBriefing {
        var facts = response(result, tool: .research, eyesFree: false)
        facts["request"] = .string(request)
        switch result.status {
        case .answered:
            let first = (result.hits?.isEmpty == false)
                ? " The page is already at the first source and the sources are numbered cards, so \"next\" goes to the next one."
                : ""
            facts["message"] = .string("The research you started has answered. Open straight with the answer: restate it in about two sentences in the user's language and say the sources are on screen; don't read it out.\(first)")
            return VoiceBriefing(kind: .researchAnswer, facts: facts, scheduling: .whenIdle, spokenText: result.content)
        case .cancelled:
            facts["message"] = "The research stopped. Say nothing unless the user asks."
            return VoiceBriefing(kind: .researchEnded, facts: facts, scheduling: .silent)
        default:
            facts["message"] = "The research couldn't finish. Tell the user in a few words; don't start it again unless they ask."
            return VoiceBriefing(kind: .researchEnded, facts: facts, scheduling: .whenIdle, spokenText: result.shown)
        }
    }

    // MARK: Results

    /// A `BrowseResult` as the model gets it, with what to say next.
    static func response(_ result: BrowseResult, tool: VoiceTool, eyesFree: Bool) -> [String: JSONValue] {
        var response: [String: JSONValue] = [
            "status": .string(result.status.rawValue),
            "shown": .string(result.shown)
        ]
        if let content = result.content, !content.isEmpty { response["content"] = .string(content) }
        if let hits = result.hits, !hits.isEmpty {
            response["hits"] = .array(hits.map { hit in
                var object: [String: JSONValue] = [
                    "card": .int(Int64(hit.number)),
                    "title": .string(hit.title),
                    "excerpt": .string(hit.excerpt)
                ]
                if let post = hit.postNumber { object["post"] = .int(Int64(post)) }
                if let username = hit.username { object["author"] = .string(username) }
                object["topic_id"] = .string(hit.topicID)
                return .object(object)
            })
        }
        response["message"] = .string(message(for: result, tool: tool, eyesFree: eyesFree))
        return response
    }

    /// Plan B1 principle 5: every result says what to say next.
    static func message(for result: BrowseResult, tool: VoiceTool, eyesFree: Bool) -> String {
        let refusal = " Tell the user that instead, in a few words; don't retry."
        let landed = eyesFree
            ? "Tell the user in a few words where you are, then read or paraphrase the post briefly; they can't look at the screen."
            : "Say in a few words where you are and give the gist. It's on screen: don't read it out."
        switch result.status {
        case .opened, .moved:
            return result.content == nil ? "Say in a few words what is on screen now." : landed
        case .focused:
            return result.content == nil
                ? "Tell the user in a few words what the page shows now."
                : "Give the user the count and the gist of the first post. " + (eyesFree ? "You may read it briefly." : "It's on screen: don't read it out.")
        case .found:
            return "The hits are on screen as numbered cards. If one clearly fits what the user wants, call open with its card number now, without asking. If several could fit, say the titles of the top two or three and let the user pick. Never read out ids or URLs."
        case .read:
            return eyesFree
                ? "Answer the user from this text only. You may read it out or paraphrase it."
                : "Answer the user from this text only. It's on screen: give the gist rather than reading it out, unless they asked you to read it."
        case .answered:
            return "Restate the answer in about two sentences and say the sources are on screen. Don't read it out."
        case .cancelled:
            return "Confirm in a few words that it stopped."
        case .noResults:
            return "Nothing matched. Say so and offer to try other words; search in the forum's language."
        case .noSolution:
            return "The topic has no accepted answer, so it opened at the top. Tell the user, and offer the most liked posts instead."
        case .endOfList:
            return "There is nothing further that way. Tell the user in a few words."
        case .emptyList:
            return "There is no list to move along yet. Tell the user and offer to search." + refusal
        case .hidden:
            return "It's hidden by the user's own blocks or filters, so it was not shown or read. Say so; never guess what it says." + refusal
        case .notFound, .unavailable, .failed:
            return "It didn't work: the shown text says why." + refusal
        }
    }

    private func refusal(_ shown: String, scheduling: GeminiLive.Scheduling) -> VoiceToolOutcome {
        let result = BrowseResult(status: .unavailable, shown: shown)
        return VoiceToolOutcome(response: Self.response(result, tool: .read, eyesFree: false), scheduling: scheduling)
    }
}

/// Routing enforced in code: a `research` request that a browser tool does
/// (a bare "next", "post 37", "the solution") is done directly. Kept small
/// on purpose: only whole requests that are nothing but a browser command.
enum VoiceRouting {
    enum Action: Equatable {
        case move(String)
        case post(Int)
        case solution
    }

    static func browserAction(for request: String) -> Action? {
        let text = request.lowercased()
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".,!?;:。，！？；：")))
            .replacingOccurrences(of: #"^(please |go to |go |take me to |show me |请|去|到)"#, with: "", options: .regularExpression)
        switch text {
        case "next", "next one", "next post", "next result", "下一个", "下一楼", "下一条", "下一個", "下一條":
            return .move("next")
        case "previous", "previous one", "previous post", "back one", "上一个", "上一楼", "上一条", "上一個", "上一條":
            return .move("previous")
        case "back", "go back", "返回", "后退", "後退":
            return .move("back")
        case "top", "first post", "the first post", "第一楼", "一楼", "第一樓", "一樓":
            return .post(1)
        case "the solution", "solution", "accepted answer", "the accepted answer", "解决方案", "解決方案", "采纳的答案", "採納的答案":
            return .solution
        default:
            break
        }
        let patterns = [#"^(?:post|reply|#)\s*(\d{1,5})$"#, #"^第\s*(\d{1,5})\s*[楼樓]$"#, #"^(\d{1,5})\s*[楼樓]$"#]
        for pattern in patterns {
            if let match = text.range(of: pattern, options: .regularExpression) {
                let digits = text[match].filter(\.isNumber)
                if let number = Int(digits), number >= 1 { return .post(number) }
            }
        }
        return nil
    }
}
