import Foundation

// Folder sync glue (FolderSyncController drives it; see FolderSyncRecords.swift
// for the merge rules). Remote changes go through the same state as local
// edits: running work keeps its `RunSettings`, a job re-reads its session
// before writing results, and work that is running here is never touched.
extension AppModel {
    /// The synced part of the state (API keys stripped).
    func folderSyncLocalState() -> FolderSyncLocalState {
        FolderSyncLocalState(
            settings: settings.persistable,
            sessions: sessions,
            runs: agentRuns,
            watched: watchedTopics,
            forums: forums,
            busyTopicKeys: Set(activities.filter { !$0.status.isTerminal }.map(\.topicKey))
        )
    }

    /// Applies merged remote data in one main-actor pass and saves once.
    /// A record that changed since the merge was computed (a local edit, a
    /// job writing its result) is skipped and returned; the next pass merges
    /// it again. So is a delete of a session with work running, and any
    /// change to an agent run that is still running here.
    @discardableResult
    func applyRemote(_ changes: FolderSyncChanges) -> Set<String> {
        var skipped: Set<String> = []

        var newSettings = settings
        if let change = changes.settings {
            if settings.persistable == change.expected,
               let merged = try? FolderSyncSchema.applying(settingsUnits: change.units, to: settings) {
                newSettings = merged
            } else {
                skipped.insert(SyncRecord.recordKey(kind: .settings, id: "settings"))
            }
        }

        var newSessions = sessions
        for change in changes.sessions {
            let key = SyncRecord.recordKey(kind: .session, id: change.id)
            guard newSessions[change.id] == change.expected else {
                skipped.insert(key)
                continue
            }
            if var value = change.value {
                // The fetched topic text is a local cache; keep this device's.
                value.source = newSessions[change.id]?.source ?? ""
                value.rawPages = newSessions[change.id]?.rawPages ?? []
                value.lastCheckedAt = newSessions[change.id]?.lastCheckedAt
                newSessions[change.id] = value
            } else if hasActiveWork(topicKey: change.id) {
                skipped.insert(key)
            } else {
                newSessions.removeValue(forKey: change.id)
            }
        }

        var newRuns = agentRuns
        for change in changes.runs {
            let key = SyncRecord.recordKey(kind: .run, id: change.id)
            let index = newRuns.firstIndex { $0.id.uuidString == change.id }
            let current = index.map { newRuns[$0] }
            guard current == change.expected, current?.status.isTerminal ?? true else {
                skipped.insert(key)
                continue
            }
            switch (index, change.value) {
            case (let index?, let value?): newRuns[index] = value
            case (nil, let value?): newRuns.append(value)
            case (let index?, nil): newRuns.remove(at: index)
            case (nil, nil): break
            }
        }
        newRuns.sort { $0.createdAt > $1.createdAt }

        let newWatched = Self.applying(changes.watched, to: watchedTopics, kind: .watched, id: \.topicKey, skipped: &skipped)
        let newForums = Self.applying(changes.forums, to: forums, kind: .forum, id: \.siteURL, skipped: &skipped)

        if newSettings != settings { settings = newSettings }
        if newSessions != sessions || newRuns != agentRuns || newWatched != watchedTopics
            || newForums != forums || changes.settings != nil {
            replaceSyncedData(
                sessions: newSessions,
                agentRuns: newRuns,
                watchedTopics: newWatched,
                forums: newForums
            )
        }
        return skipped
    }

    private func hasActiveWork(topicKey: String) -> Bool {
        activities.contains { $0.topicKey == topicKey && !$0.status.isTerminal }
    }

    private static func applying<Value: Equatable>(
        _ changes: [FolderSyncRecordChange<Value>],
        to values: [Value],
        kind: SyncKind,
        id: KeyPath<Value, String>,
        skipped: inout Set<String>
    ) -> [Value] {
        var result = values
        for change in changes {
            let index = result.firstIndex { $0[keyPath: id] == change.id }
            guard index.map({ result[$0] }) == change.expected else {
                skipped.insert(SyncRecord.recordKey(kind: kind, id: change.id))
                continue
            }
            switch (index, change.value) {
            case (let index?, let value?): result[index] = value
            case (nil, let value?): result.append(value)
            case (let index?, nil): result.remove(at: index)
            case (nil, nil): break
            }
        }
        return result
    }
}
