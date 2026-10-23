import Foundation

// MARK: - Session retention
//
// Every topic the browser shows and every topic the agent reads gets a
// session (`AppModel.sessions`), and the snapshot holds them all with their
// fetched pages. `SessionRetention.plan` decides, on launch and after each
// job, what goes:
// - never: kept topics, topics with a chat or their own instructions, watched
//   topics, the open topic, and topics with work queued or running;
// - summaries: all but the newest `summaryLimit` (by last change);
// - topics the user opened, without a summary: all but the newest `visitLimit`;
// - topics only the agent read: removed once no agent run cites them; while
//   one does (its steps and sources show the title), their fetched pages are
//   dropped after `agentPagesLifetime`.

enum SessionRetention {
    static let summaryLimit = 40
    static let visitLimit = 60
    static let agentPagesLifetime: TimeInterval = 24 * 60 * 60

    struct Plan: Equatable {
        /// Topic keys whose sessions go.
        var remove: [String] = []
        /// Topic keys whose fetched pages (raw pages and text) go.
        var dropPages: [String] = []

        var isEmpty: Bool { remove.isEmpty && dropPages.isEmpty }
    }

    /// `protected`: topic keys that must stay (open topic, watched, active
    /// work). `citedByRuns`: topic keys the saved agent runs read.
    static func plan(
        sessions: [String: TopicSession],
        protected: Set<String>,
        citedByRuns: Set<String>,
        now: Date = Date()
    ) -> Plan {
        var plan = Plan()
        var summaries: [TopicSession] = []
        var visits: [TopicSession] = []
        for session in sessions.values {
            let key = session.topicKey
            if protected.contains(key) || session.kept || !session.history.isEmpty || session.hasInstructions {
                continue
            }
            if session.hasSummary {
                summaries.append(session)
            } else if session.openedByUserAt != nil {
                visits.append(session)
            } else if !citedByRuns.contains(key) {
                plan.remove.append(key)
            } else if !session.rawPages.isEmpty || !session.source.isEmpty,
                      now.timeIntervalSince(session.lastCheckedAt ?? session.updatedAt) >= agentPagesLifetime {
                plan.dropPages.append(key)
            }
        }
        // Newest first; the key breaks ties so the plan is the same every time.
        plan.remove += summaries
            .sorted { $0.updatedAt == $1.updatedAt ? $0.topicKey < $1.topicKey : $0.updatedAt > $1.updatedAt }
            .dropFirst(summaryLimit)
            .map(\.topicKey)
        plan.remove += visits
            .sorted { $0.lastSeenAt == $1.lastSeenAt ? $0.topicKey < $1.topicKey : $0.lastSeenAt > $1.lastSeenAt }
            .dropFirst(visitLimit)
            .map(\.topicKey)
        plan.remove.sort()
        plan.dropPages.sort()
        return plan
    }

    /// The topics the agent runs read (their steps and sources).
    static func topicKeys(citedBy runs: [AgentRun]) -> Set<String> {
        var keys = Set<String>()
        for run in runs {
            for topicID in run.topicIDs { keys.insert(TopicIdentity.key(siteURL: run.siteURL, topicID: topicID)) }
            for step in run.steps { if let key = step.topicKey { keys.insert(key) } }
        }
        return keys
    }
}
