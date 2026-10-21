import Foundation

// The voice agent's seven tools, defined once in no provider's format, with
// a Gemini Live adapter. The descriptions are prompt engineering: each says
// when to call the tool, what the result means and what to say next. They
// are written for the model, so they are English and not localized.
//
// Every tool is NON_BLOCKING: a BLOCKING call pauses the whole server
// stream (the user's transcript and the model's "let me check" stall until
// it is answered). Results come back with the scheduling below.

/// A parameter schema, in the subset every live provider accepts.
indirect enum VoiceSchema: Equatable {
    case string(description: String, options: [String]? = nil)
    case integer(description: String)
    case array(of: VoiceSchema, description: String)
    case object(properties: [(name: String, schema: VoiceSchema)], required: [String])

    static func == (lhs: VoiceSchema, rhs: VoiceSchema) -> Bool {
        lhs.gemini == rhs.gemini
    }

    /// Gemini's OpenAPI subset (upper-case type names).
    var gemini: JSONValue {
        switch self {
        case .string(let description, let options):
            var object: [String: JSONValue] = ["type": "STRING", "description": .string(description)]
            if let options { object["enum"] = .array(options.map(JSONValue.string)) }
            return .object(object)
        case .integer(let description):
            return ["type": "INTEGER", "description": .string(description)]
        case .array(let item, let description):
            return ["type": "ARRAY", "items": item.gemini, "description": .string(description)]
        case .object(let properties, let required):
            var object: [String: JSONValue] = [
                "type": "OBJECT",
                "properties": .object(Dictionary(properties.map { ($0.name, $0.schema.gemini) }, uniquingKeysWith: { a, _ in a }))
            ]
            if !required.isEmpty { object["required"] = .array(required.map(JSONValue.string)) }
            return .object(object)
        }
    }
}

enum VoiceTool: String, CaseIterable {
    case find
    case open
    case move
    case focus
    case read
    case research
    case end

    /// How its result is scheduled. `research` answers `started` silently;
    /// its answer comes later as a WHEN_IDLE briefing (VoiceToolBridge).
    var scheduling: GeminiLive.Scheduling {
        switch self {
        case .find, .open, .move, .focus: .whenIdle
        // The plan has `read` silent, "then the model answers"; a silent
        // result makes no answer until the user speaks again, so it is
        // WHEN_IDLE: the model answers from it as soon as it arrives.
        case .read: .whenIdle
        case .research, .end: .silent
        }
    }

    var description: String {
        switch self {
        case .find:
            return """
            Search the forum the user is on, or only the open topic, and show the hits on screen as numbered cards, best first. \
            Call it when the user asks to find, look for or search something, or asks whether anyone wrote about something. \
            Pass a few distinctive words in the forum's language (the topic brief says which): Discourse matches words, so search \
            an English forum in English even when the user speaks another language. Scope "topic" searches inside the open topic \
            ("where did someone mention the firmware version"). The result lists the hits by number with title, author and a line. \
            If one hit clearly fits, call open with its card number right away, without asking. If several could fit, say the \
            titles of the top two or three and let the user pick; they are on the cards. If nothing matched, say so and offer \
            other words. Never read out ids, post numbers in bulk or URLs.
            """
        case .open:
            return """
            Open a topic and land on a post. Pass card for a card from the last find or research, or topic_id for a topic \
            whose id you got from a result; pass neither to stay in the open topic. at says where to land: "post" with post, \
            "solution" for the accepted answer, "last" for the newest post, "top" for the most liked posts, "unread" for the \
            first post the user hasn't seen. Call it at once when the user asks to go somewhere ("take me to the solution", \
            "open the second one", "show me the latest reply"); navigation can be undone, so don't ask first. The result says \
            what is on screen and carries the landing post's text. Tell the user in a few words where you are and give the \
            gist; the post is on screen, so don't read it out unless the result says reading is fine.
            """
        case .move:
            return """
            Move along the current list (the cards from the last find, research or focus) or around the open topic. action: \
            "next" or "previous" along the list, "back" or "forward" in the browser's history, "post" with post to go to post \
            N of the open topic, "top" for the first post, "bottom" for the last. Call it right away for "next", "go back", \
            "post 37" or "the first post". The result carries the post now on screen: say in a few words where you are and \
            what it says, without reading it out. At the end of the list, say so.
            """
        case .focus:
            return """
            Narrow the open topic. mode: "user" with user shows only that author's posts; "op" only the opening poster's; \
            "top" the most liked posts; "posts" with posts highlights those posts as a tour, starting at the first; "clear" \
            shows the whole topic again. The focused posts become the current list, so "next" moves along them. Call it for \
            "only what the original poster said", "just alice's posts", "show me the best answers" or "back to everything". \
            The result says how many posts there are and carries the first one's text: give the user the count and the gist.
            """
        case .read:
            return """
            Get the full text of a post in the open topic: post N, or the current post when post is left out; scope "visible" \
            returns every post on screen. Only call it when the user asks about a post whose text you haven't received in a \
            note or a tool result; posts you navigated to already came with their text. Answer only from what it returns, \
            never from a guess.
            """
        case .research:
            return """
            Hand a question to Forumind's research agent, which reads across several topics or a long thread and answers \
            with sources. Use it only for questions that need reasoning across many posts or topics ("what are the main \
            objections", "has anyone fixed this on firmware 5"), never for something find, open, move, focus or read can do. \
            Before calling it, say one short acknowledgement in your own words, once. It answers "started" at once and runs \
            in the background; one research runs at a time, and a new request replaces the running one. The answer arrives \
            later as a briefing: open with the answer. action "cancel" stops it when the user says never mind.
            """
        case .end:
            return """
            End the voice conversation, when the user says goodbye, that's all, or asks you to stop listening. Say a short \
            goodbye first, then call it.
            """
        }
    }

    var parameters: VoiceSchema? {
        switch self {
        case .find:
            return .object(properties: [
                ("query", .string(description: "A few distinctive search words, in the forum's language.")),
                ("scope", .string(description: "\"forum\" (default) or \"topic\" for the open topic only.", options: ["forum", "topic"]))
            ], required: ["query"])
        case .open:
            return .object(properties: [
                ("card", .integer(description: "A card number from the last find or research, like 2.")),
                ("topic_id", .string(description: "A topic id from a result. Leave out for the open topic.")),
                ("at", .string(description: "Where to land.", options: ["post", "solution", "last", "top", "unread"])),
                ("post", .integer(description: "The post number, with at \"post\"."))
            ], required: [])
        case .move:
            return .object(properties: [
                ("action", .string(
                    description: "Where to move.",
                    options: ["next", "previous", "back", "forward", "post", "top", "bottom"]
                )),
                ("post", .integer(description: "The post number, with action \"post\"."))
            ], required: ["action"])
        case .focus:
            return .object(properties: [
                ("mode", .string(description: "What to show.", options: ["user", "op", "top", "posts", "clear"])),
                ("user", .string(description: "The author's username, with mode \"user\".")),
                ("posts", .array(of: .integer(description: "A post number."), description: "Post numbers to highlight, with mode \"posts\"."))
            ], required: ["mode"])
        case .read:
            return .object(properties: [
                ("post", .integer(description: "The post number; leave out for the current post.")),
                ("scope", .string(description: "\"post\" (default) or \"visible\" for every post on screen.", options: ["post", "visible"]))
            ], required: [])
        case .research:
            return .object(properties: [
                ("request", .string(description: "The user's question, complete, in their words.")),
                ("action", .string(description: "\"start\" (default) or \"cancel\".", options: ["start", "cancel"]))
            ], required: [])
        case .end:
            return nil
        }
    }

    /// Gemini Live's function declarations for every tool.
    static var geminiDeclarations: [GeminiLive.FunctionDeclaration] {
        allCases.map {
            GeminiLive.FunctionDeclaration(
                name: $0.rawValue,
                description: $0.description,
                parameters: $0.parameters?.gemini,
                behavior: .nonBlocking
            )
        }
    }
}
