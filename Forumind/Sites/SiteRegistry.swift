import Foundation

/// Every adapter compiled into this build. Immutable; built once. The single
/// source for which platforms a build supports.
struct SiteRegistry: Sendable {
    /// Order = recognition priority.
    let adapters: [any SiteAdapter]

    /// Derived from `SiteRecognizers.standard` (the one list of platforms, which
    /// the share extension compiles without adapters): each recognizer's kind
    /// is paired with its adapter from `adapterFactories`. A kind without a
    /// factory stops the app at first use (and SiteContractTests fails), so a
    /// platform cannot be listed without an adapter.
    static let standard = SiteRegistry(adapters: SiteRecognizers.standard.map { recognizer in
        guard let make = adapterFactories[recognizer.kind] else {
            preconditionFailure("No adapter for site kind \(recognizer.kind): add it to SiteRegistry.adapterFactories")
        }
        return make()
    })

    /// Kind -> adapter. Adding a platform is its recognizer in
    /// `SiteRecognizers.standard` plus its line here.
    static let adapterFactories: [SiteKind: @Sendable () -> any SiteAdapter] = {
        var factories: [SiteKind: @Sendable () -> any SiteAdapter] = [
            .discourse: { DiscourseAdapter() },
            .wordpress: { WordPressAdapter() }
        ]
        #if FORUMIND_LABS
        // factories[.reddit] = { RedditAdapter() }      // P2
        #endif
        return factories
    }()

    /// Kinds must be unique (SiteContractTests checks it); a lookup finds the first.
    init(adapters: [any SiteAdapter]) {
        self.adapters = adapters
    }

    func adapter(for kind: SiteKind) -> (any SiteAdapter)? {
        adapters.first { $0.kind == kind }
    }

    /// Hosts that are one site whatever the path (Reddit later): the adapter
    /// and the canonical site URL.
    func claimedSite(forHost host: String) -> (adapter: any SiteAdapter, siteURL: String)? {
        for adapter in adapters {
            if let siteURL = adapter.recognizer.claimedSiteURL(forHost: host) { return (adapter, siteURL) }
        }
        return nil
    }

    /// The keys every recognizer declares, in registry order: the probe collects
    /// exactly these.
    var factKeys: PageFactKeys {
        PageFactKeys.declared(by: adapters.map(\.recognizer))
    }

    /// The probe script for this build's recognizers.
    var probeExpression: String {
        PageFactsProbe.expression(keys: factKeys)
    }

    /// First adapter, in registry order, whose recognizer accepts the page.
    func recognize(facts: PageFacts, url: URL) -> (adapter: any SiteAdapter, match: SitePageMatch)? {
        for adapter in adapters {
            if let match = adapter.recognizer.recognize(facts: facts, url: url) { return (adapter, match) }
        }
        return nil
    }

    /// A topic id in a URL whose site is not known yet (the `.maybe` state, shared links).
    func looseTopicID(in url: URL) -> String? {
        adapters.lazy.compactMap { $0.recognizer.looseTopicID(in: url) }.first
    }

    /// The post number of a topic URL whose site is not known yet.
    func postNumber(in url: URL) -> Int? {
        adapters.lazy.compactMap { $0.recognizer.postNumber(in: url) }.first
    }

    /// Content-blocker first-party exemptions: the union, in registry order.
    var firstPartyPathPatterns: [String] {
        var seen = Set<String>()
        return adapters.flatMap(\.capabilities.firstPartyPathPatterns).filter { seen.insert($0).inserted }
    }

    /// Tool names any registered adapter offers (in registry order), then the
    /// app tools (in `AgentPrompt` order): Apple Intelligence's guided enum.
    var allAgentToolNames: [String] {
        var seen = Set<String>()
        let siteNames = adapters.flatMap { $0.agent.siteTools.map(\.name) }
        let appNames = AgentToolName.appTools.map(\.rawValue)
        return (siteNames + appNames).filter { seen.insert($0).inserted }
    }
}
