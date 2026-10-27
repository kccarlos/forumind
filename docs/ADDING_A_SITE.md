# Adding a site

Forumind reads Discourse today. Everything that knows a platform lives in
`Forumind/Sites/` behind the `SiteAdapter` protocol, so supporting another
platform (for example a WordPress comment section or Reddit, both only
possible future platforms) means adding one folder there and two list entries,
not changing the app. This page is the checklist. For how the pieces fit
together see [ARCHITECTURE.md](ARCHITECTURE.md).

Read `Forumind/Sites/Discourse/` as the worked example and
`ForumindTests/Sites/FakeSiteAdapter.swift` as the smallest one.

## The rules

- An adapter is a value: pure functions plus network calls through the
  `SiteNetwork` it is handed. No stored state, no singletons.
- What a site supports is stated only in `capabilities`, and each capability is
  either present and working or `nil`. No capability says yes and then throws.
  The UI reads the capability and hides or falls back when it is nil.
- Only `Forumind/Sites/` may name a platform (see "The layering guard").
- Output must follow the shared raw text shape below, so summaries, chat,
  moderation and exports need no per-site code.

## The protocol

```swift
protocol SiteAdapter: Sendable {
    var kind: SiteKind { get }                    // stable id, stored and synced
    var recognizer: any SiteRecognizer { get }    // reads pages (shared with the share extension)
    var links: any SiteLinks { get }              // pure URL building and parsing
    var capabilities: SiteCapabilities { get }
    var agent: AgentSiteProfile { get }           // Ask the forum
    var voice: VoiceSiteProfile { get }           // the voice agent
    var suggestedForums: SuggestedForums { get }
    func siteURLCandidates(fromAddress address: String) -> [String]
    func siteInfo(siteURL: String, net: SiteNetwork) async throws -> ForumSiteInfo
    func overview(_ topic: TopicRef, net: SiteNetwork) async throws -> ForumTopicOverview
    func readTopic(_ request: TopicReadRequest, net: SiteNetwork,
                   progress: ..., onPage: ...) async throws -> ForumFetchResult
    func run(_ query: SiteQuery, net: SiteNetwork) async throws -> SiteQueryResult
}
```

- `kind` is a `SiteKind("id")`. The id is stored on every `Forum` and synced, so
  it is never renamed. Declare it as a `static let` in your adapter's folder
  (as `SiteKind.discourse` is).
- `siteURLCandidates` turns what the user typed in Add forum into candidate
  site URLs. `siteInfo` returns the name and icon and must throw when the site
  is not this platform: it is the validation step of Add forum. It must not use
  the in-page loader (the forum may not be the open page yet).
- `overview` returns the title, post count and `TopicFacts` without pulling the
  posts. `readTopic` returns the whole topic text; see the raw shape below. Use
  `PagedTopicFetch` if the site pages its posts: you give it a `TopicPagePlan`
  and a `fetchPage` closure and it runs the paced loop, skips cached pages and
  calls `onPage` for each page.
- `run` executes a `SiteQuery` (`.search(text:scope:)`, `.latest`). Reject a
  case you do not support with `SiteQueryError.unsupported`; the agent never
  offers a tool whose query you reject, because its specs come from you.
- All requests go through `net.data(_:accept:)` or `net.json(_:)`. They are
  paced and retried, use the forum's cookies, and refuse a URL outside the site.
  Do not use `URLSession` directly.

### Links

`SiteLinks` is pure: `homeURL`, `topicURL`, `postURL(topicURL:number:anchor:)`,
`topicPageURL` (the topic without post, query or fragment), `parse` (a URL on
the platform to topic id, slug and post number, given the forum's base path) and
`lastPostURL` (the newest post when its number is unknown; nil if the platform
has no such URL). `anchor` is the `PostBlock.anchor` of the post when the
caller has it; a platform that links by number can ignore it.

## Capabilities

`SiteCapabilities` has one field per optional ability. Provide it, or pass nil.

| Capability | Provide it when | What the app does when it is nil |
| --- | --- | --- |
| `activeTopics` | the site can list recently active topics cheaply (`activeTopics(siteURL:budget:net:)`, at most `budget` requests, reporting how many it used) | The daily digest and podcast skip the site. |
| `postLookup` | a single post's text can be fetched by number when the page lacks it | Reading a post uses only text already on the page or read. |
| `topicFilters` | a topic can be narrowed to its top posts or one author (`url`, `isFiltered`, `overview(filter:)`) | The `top` landing opens the topic; the voice agent loses its `user` and `op` focus modes. |
| `pageBridge` | the app can script the page (`bridgeInstaller` and `moderationInstaller`, JavaScript that defines `window.__forumindBrowse` and `window.__forumindModeration`) | No script is ever sent to the page; moderation applies to read text only, and scrolling to a post loads its URL. |
| `loginURL` | the site has a sign-in page | The forum menu hides Sign in and Sign-in help. |
| `searchPageURL` | the site has its own search page for typed words | Words typed in the iPhone bar are treated as an address and fail as one. |
| `session` | signed-in state and the username can be read from page facts (`session(from:)`) | The browser never shows a signed-in state for the site. |
| `firstPartyPathPatterns` | always (an empty list is fine) | n/a (see below). |

`firstPartyPathPatterns` are regular expressions for the requests a page of the
site must always be able to make even with ad blocking on (the app's in-page
`fetch()`, sign-in routes). The union over all adapters becomes content-blocker
exceptions.

There are no flags for data the pages themselves show (accepted answers,
likes, author blocking). Consumers read the data: `TopicFacts.acceptedAnswer`
is nil on a site without them, `likeCount` is nil or 0.

## The raw text shape

This is the contract `readTopic` must meet, and `SiteContractTests` checks it
for every adapter. The code that renders and parses it is
`Sites/Shared/RawTopicFormat.swift`; build your text with `RawTopicFormat.render`
instead of formatting by hand.

- A post is a header line, a newline, then the body. The header is
  `author | YYYY-MM-DD HH:MM:SS UTC | #N`: the author with whitespace runs
  replaced by `_` (`anonymous` when empty), the UTC time (the epoch when the
  post has no date) and the post's number.
- Posts are joined with the separator `"\n\n\n"` (a blank line pair), and a
  page's text ends with a newline. Pages are joined with the same separator.
- No post body contains `"\n\n\n"`. `render` collapses longer newline runs to
  two and trims the body; if you build text yourself you must do the same.
- `#N` is the post number. Discourse uses the platform's own post number;
  a platform without numbers uses 1…n in read order.

Alongside the text, fill `RawForumPage.blocks` with one `PostBlock` per post, in
the same order and in the same call that writes the text (nothing may edit
either afterwards): `number`, `author`, `date`, an opaque `anchor` (what
`links.postURL` needs to point at the post: for Discourse the post number as a
string), and `score` when the source has likes or votes on every post.
`RawTopicFormat.blocks(in:)` derives blocks from text when numbers are anchors.

## Recognizer and page facts

A `SiteRecognizer` decides whether a page is this platform. It is pure and
depends only on Foundation, because the share extension compiles it too.

- `factKeys` declares everything the recognizer reads from a page, as
  `PageFactKeys`: `meta` names, `links` rels, `elements` (an element id and its
  dataset entries, `key` or `key:path.in.json`) and `selectors` (reported as
  present or not). A page never reports more than the keys asked for.
  `htmlClass` and `bodyClass` are always included.
- `recognize(facts:url:)` returns a `SitePageMatch` (site URL, base path, name,
  topic id and post number if known) or nil. A missing key reads as empty, never
  as an error. Two recognizers must not both accept a page.
- `topicID(fromURL:basePath:)`, `looseTopicID(in:)` and `postNumber(in:)` read
  URLs alone, for pages before the probe reports and for shared links.
- `claimedSiteURL(forHost:)` is for a platform where every page on a host is one
  site whatever the path; the default returns nil.

Whenever you change a recognizer's `factKeys` (or the probe), regenerate the
share extension's script and commit it:

```sh
scripts/generate-share-probe.sh
```

It writes `ForumindShare/PageFactsProbe.js` from the same Swift code the app
uses. A unit test (`SharedPageTests`) fails if the shipped file differs.

## Registering the adapter

Two entries, and nothing else:

1. Add the recognizer to `SiteRecognizers.standard`
   (`Sites/Recognition/SiteRecognizers.swift`). The list's order is the
   recognition priority, and it is what the share extension compiles.
2. Add a line to `SiteRegistry.adapterFactories`
   (`Sites/SiteRegistry.swift`): `[.yourKind: { YourAdapter() }]`.

`SiteRegistry.standard` is derived from the first list through the second. A
listed kind without a factory stops the app at first use and fails the contract
tests, so a platform cannot be half added. After adding files run
`env -u DEVELOPMENT_TEAM ruby scripts/generate_project.rb` and
`scripts/ci/check-project-drift.sh`.

## Agent tools

`SiteAdapter.agent` is an `AgentSiteProfile`:

- phrases the prompt uses: `siteDescription` ("a Discourse forum"), `siteNoun`,
  `topicNoun`, `postNumbering` (the rule on post numbers and how to cite one)
  and `postCitation`;
- `siteTools`: the site's search and list tools, as `AgentToolSpec`s whose names
  are `AgentToolName` cases. The app adds its own tools after yours
  (`read_topic`, `summarize_topic`, `saved_summaries`, `watch_topic`,
  `final_answer`) and they do not belong in `siteTools`;
- `query`: turns a tool name and its string arguments into a `SiteQuery`, and
  throws `AgentError.missingArgument` for a required argument that is empty;
- `postLinkHint`: how the model builds a link to one post from a topic URL.

Tool names are a fixed set in `AgentToolName` (`search_forum`,
`search_comments`, `list_latest`, ...). Reuse one if it fits. A new name is a
deliberate app change: add the case, and add the name to the literal
`@Guide(.anyOf…)` list in the Apple Intelligence action type (a macro cannot
read the registry; a test compares the list with `SiteRegistry.allAgentToolNames`).

Write each description so a model can use the tool without examples, and
include a call in the shape the planner expects. Example for a comment search:

```swift
AgentToolSpec(
    name: AgentToolName.searchComments.rawValue,
    description: "Search the comments of this site. Returns up to 20 comments with topic id, title and an excerpt.",
    parameters: [.init(name: "query", description: "Search text", required: true)]
)
```

and the call the model makes:

```json
{"thought": "Look for reports of the crash.", "tool": "search_comments", "arguments": {"query": "crash on launch"}}
```

A run that names a tool outside its site's list is refused with the list of
tools it may use, so the specs must be complete.

## Voice profile

`SiteAdapter.voice` is a `VoiceSiteProfile` of three model-facing English
sentences: `persona` (completes "You are the voice of Forumind, ..."), `findHint`
(how the `find` tool should choose search words, for example which language to
search in) and `languageHint`. The voice agent builds its instructions and its
tool declarations from the profile of the page's site when a session connects.
The `user` and `op` focus modes exist only when the site has `topicFilters`.

## Strings

Model-facing text (tool descriptions, prompts, voice sentences) is English and
is not localized. Any new text the user sees goes into
`Forumind/Localizable.xcstrings` (the share extension has its own
`ForumindShare/Localizable.xcstrings`) in all three languages: `en`,
`zh-Hans` and `zh-Hant`. `LocalizationCatalogTests` fails when one is missing
or a format specifier does not match. Prefer site-neutral wording; the share
sheet badge is the one place that still names a platform.

## Tests

Add your adapter to the generic suite, then write the tests only it needs.

- `SiteContractTests` (`ForumindTests/Sites/`) runs one set of checks over every
  adapter: unique kinds, link round trips, the raw text shape (header format,
  separator, no triple newline in a block, blocks matching the text), cached
  reads making the declared requests, `onPage` once per page, the tool specs
  running as queries, and present capabilities working. Add a `SiteFixture`
  (adapter, a site URL and base path, a topic id, the request counts of a first
  and a cached read, and a network) to `allFixtures()`.
- Recorded fixtures: serve responses from files through a `URLProtocol` stub
  (see `ContractStub` and `DiscourseFixtures.swift`) and keep the fixtures free
  of real people and sites: use `example.com` and names such as `alice`. Never
  call the live site from a test.
- Recognizer tests: add a recorded facts file under
  `ForumindTests/Fixtures/PageFacts/` for a topic page and a plain page of your
  platform and assert the match (`SiteRecognitionTests`). Also check that the
  share extension's list and the registry agree (`SharedPageTests`).
- `CapabilityGatingTests` runs the app against a fake whose optional
  capabilities are all nil; extend it if you add a capability.
- Run the unit suite, and the project drift and layering checks, before you
  commit.

## The layering guard

`scripts/ci/check-site-layering.sh` fails the build when Swift code outside
`Forumind/Sites/` names a platform: a Discourse type, a concrete `SiteKind`, or a
`/t/` route. If you find yourself wanting to, add a capability or a profile
field instead. Existing exceptions (sample content, UI-test seeds, the share
sheet badge, the generic topic-key format) are in
`scripts/ci/site-layering-allowlist.txt` as `path|source line`. The list may
only shrink: a new hit fails, and so does an entry that no longer matches
anything. Do not add to it.

## The Labs flag (planned)

Platforms that are not ready for everyone will ship behind a compile-time
flag, `#if FORUMIND_LABS`, in a separate Labs build with its own bundle
identifier and its own data container, so Labs never touches the data of the
release app. The two lists above already carry a commented placeholder inside
`#if FORUMIND_LABS` where such a platform goes (its recognizer in
`SiteRecognizers.standard` and its factory in `SiteRegistry.adapterFactories`).
The Labs target is not built yet; until it is, new platforms are added to the
lists directly.
