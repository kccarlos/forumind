import Foundation
@testable import Forumind

/// A live connection that records what the session sends; tests deliver
/// server frames straight to `VoiceSession.receive` and end it with `drop`.
@MainActor
final class FakeLiveTransport: LiveTransport {
    private(set) var requests: [URLRequest] = []
    private(set) var sent: [String] = []
    private(set) var closed = false
    var connectError: Error?
    let frames: AsyncStream<Data>
    private var continuation: AsyncStream<Data>.Continuation?
    private(set) var closeReason: LiveClose?

    init() {
        var continuation: AsyncStream<Data>.Continuation?
        frames = AsyncStream { continuation = $0 }
        self.continuation = continuation
    }

    func connect(_ request: URLRequest) async throws {
        requests.append(request)
        if let connectError { throw connectError }
    }

    func send(_ text: String) {
        sent.append(text)
    }

    func close() {
        closed = true
        finish(LiveClose(code: LiveClose.normalClosure, reason: "closed"))
    }

    /// The server closed the connection.
    func drop(_ close: LiveClose = LiveClose(code: LiveClose.internalError, reason: "Internal error encountered.")) {
        finish(close)
    }

    private func finish(_ close: LiveClose) {
        guard closeReason == nil else { return }
        closeReason = close
        continuation?.finish()
        continuation = nil
    }

    /// What was sent, as `VoiceSent` values.
    var messages: [VoiceSent] { sent.map(VoiceSent.init) }
}

/// One sent frame, decoded for assertions.
enum VoiceSent: Equatable {
    case setup(model: String, handle: String?)
    case audio(Int)
    case audioStreamEnd
    case note(String)
    case turn(String)
    case toolResponse(id: String, name: String, scheduling: String?)
    case other(String)

    init(_ text: String) {
        let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
        if let setup = object["setup"] as? [String: Any] {
            self = .setup(
                model: setup["model"] as? String ?? "",
                handle: (setup["sessionResumption"] as? [String: Any])?["handle"] as? String
            )
        } else if let input = object["realtimeInput"] as? [String: Any] {
            if let audio = input["audio"] as? [String: Any], let data = audio["data"] as? String {
                self = .audio(Data(base64Encoded: data)?.count ?? 0)
            } else {
                self = .audioStreamEnd
            }
        } else if let content = object["clientContent"] as? [String: Any] {
            let turns = content["turns"] as? [[String: Any]] ?? []
            let text = (turns.first?["parts"] as? [[String: Any]])?.first?["text"] as? String ?? ""
            self = content["turnComplete"] as? Bool == true ? .turn(text) : .note(text)
        } else if let response = (object["toolResponse"] as? [String: Any])?["functionResponses"] as? [[String: Any]],
                  let first = response.first {
            self = .toolResponse(
                id: first["id"] as? String ?? "",
                name: first["name"] as? String ?? "",
                scheduling: first["scheduling"] as? String
            )
        } else {
            self = .other(text)
        }
    }

    var noteText: String? {
        if case .note(let text) = self { return text }
        return nil
    }

    var turnText: String? {
        if case .turn(let text) = self { return text }
        return nil
    }

    var isAudio: Bool {
        if case .audio = self { return true }
        return false
    }

    var isToolResponse: Bool {
        if case .toolResponse = self { return true }
        return false
    }
}

@MainActor
final class FakeVoiceAudio: VoiceAudioIO {
    var isPlaying = false
    var headphonesConnected = false
    private(set) var played: [Data] = []
    private(set) var flushes = 0
    private(set) var stopped = false

    func start(frame: @escaping @MainActor (Data) -> Void, gate: @escaping @MainActor (Bool) -> Void) async throws {}
    func stop() { stopped = true }
    func play(_ pcm: Data) { played.append(pcm) }
    func flushPlayback() { flushes += 1 }
}

@MainActor
final class ManualVoiceClock: VoiceClock {
    var now = Date(timeIntervalSince1970: 1_800_000_000)

    func advance(_ seconds: TimeInterval) {
        now = now.addingTimeInterval(seconds)
    }
}

/// The navigation layer, scripted: each call is logged and answers with
/// `result(for:)` (default: opened at post 3 with its text).
@MainActor
final class FakeVoiceNavigator: VoiceNavigator {
    var pageContext = PageContext.empty
    var browseCursor = BrowseCursor()
    var isResearching = false
    var voiceSite = SiteRegistry.standard.voiceFallback
    var researchProgress: String?
    private(set) var calls: [String] = []
    var results: [String: BrowseResult] = [:]
    var brief: VoiceTopicBrief?
    var visible: [VisiblePost] = []
    var summary: String?
    /// While set, `research` waits until `releaseResearch` (or a cancel).
    var holdsResearch = false
    private var researchContinuations: [CheckedContinuation<BrowseResult, Never>] = []

    private func answer(_ call: String, key: String) -> BrowseResult {
        calls.append(call)
        return results[key] ?? BrowseResult(status: .opened, shown: "“Fan noise”: Post 3 of 9 by bob", content: "bob, post 3:\nTry the quiet profile.")
    }

    func find(_ query: String, scope: BrowseSearchScope) async -> BrowseResult {
        answer("find \(query) \(scope.rawValue)", key: "find")
    }

    func openTopic(_ target: BrowseTarget, at landing: BrowseLanding, includeContent: Bool) async -> BrowseResult {
        let what: String = switch target {
        case .topic(let id): "topic \(id)"
        case .item(let item): "item \(item.topicID)/\(item.postNumber ?? 0)"
        case .listing(let listing): "listing \(listing.topicID)"
        case .url(let url): "url \(url.absoluteString)"
        }
        return answer("open \(what) at \(landing)", key: "open")
    }

    func openCard(_ index: Int, includeContent: Bool) async -> BrowseResult {
        answer("card \(index)", key: "card")
    }

    func goToPost(_ number: Int) async -> BrowseResult { answer("post \(number)", key: "post") }
    func next() async -> BrowseResult { answer("next", key: "next") }
    func previous() async -> BrowseResult { answer("previous", key: "previous") }
    func back() -> BrowseResult { answer("back", key: "back") }
    func forward() -> BrowseResult { answer("forward", key: "forward") }

    func focus(_ focus: BrowseFocus) async -> BrowseResult {
        answer("focus \(focus)", key: "focus")
    }

    func read(post: Int?) async -> BrowseResult {
        calls.append("read \(post.map(String.init) ?? "current")")
        return results["read"] ?? BrowseResult(
            status: .read, shown: "Post \(post ?? 3) of 9 by bob", content: "bob, post \(post ?? 3):\nTry the quiet profile."
        )
    }

    func readVisible() async -> BrowseResult { answer("visible", key: "visible") }

    func research(_ request: String, siteURL: String?) async -> BrowseResult {
        calls.append("research \(request)")
        // Like AppModel: a new research replaces the running one.
        let earlier = researchContinuations
        researchContinuations = []
        earlier.forEach { $0.resume(returning: BrowseResult(status: .cancelled, shown: "Replaced by a newer request.")) }
        isResearching = true
        if holdsResearch {
            let result = await withCheckedContinuation { researchContinuations.append($0) }
            return result
        }
        isResearching = false
        return results["research"] ?? Self.answered
    }

    static let answered = BrowseResult(
        status: .answered,
        shown: "Answered with 2 sources on the cards.",
        content: "Lower the fan curve in the quiet profile.",
        hits: [BrowseResult.Hit(number: 1, title: "Fan noise", topicID: "42", postNumber: 3, username: "bob", excerpt: "Try it")]
    )

    /// Answers the oldest held research.
    func releaseResearch(_ result: BrowseResult = FakeVoiceNavigator.answered) {
        guard !researchContinuations.isEmpty else { return }
        researchContinuations.removeFirst().resume(returning: result)
        isResearching = !researchContinuations.isEmpty
    }

    func cancelResearch() -> BrowseResult {
        calls.append("cancel research")
        let held = researchContinuations
        researchContinuations = []
        held.forEach { $0.resume(returning: BrowseResult(status: .cancelled, shown: "Replaced by a newer request.")) }
        isResearching = false
        return BrowseResult(status: .cancelled, shown: "The research was stopped.")
    }

    func voiceTopicBrief() async -> VoiceTopicBrief? { brief }
    func postsOnScreen() async -> [VisiblePost] { visible }
    func quickSummary(topicKey: String) async -> String? { summary }

    /// A topic page at `post`.
    static func topicPage(post: Int?, visible: [Int] = []) -> PageContext {
        let text = "https://forum.example/t/fan-noise/42" + (post.map { "/\($0)" } ?? "")
        let url = URL(string: text)!
        var page = PageContext.make(
            url: url, title: "Fan noise after the update", facts: .discourse(url, forumName: "Example"), knownForum: nil,
            registry: .standard
        )
        page.visiblePosts = visible
        page.postsCount = 9
        return page
    }
}
