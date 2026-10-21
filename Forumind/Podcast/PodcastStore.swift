import Foundation

// MARK: - Episodes and their files
//
// An episode belongs to one digest and lives in
// `Caches/Podcasts/<digest id>/`: `episode.json` (the script, which engine
// and voices made it, each chapter's file and duration) and one audio file
// per chapter. It is kept apart from `digests.json`, so the digest's format
// never changes for it. `reconcile` deletes every episode whose digest is
// gone (deleted, made again, trimmed to the last 7) or that is older than
// 7 days. iOS may also purge Caches: a chapter whose file is missing is
// simply spoken again.

struct PodcastEpisode: Codable, Equatable {
    struct Entry: Codable, Equatable, Identifiable {
        enum State: String, Codable {
            case pending
            case working
            case ready
            case failed
        }

        var chapter: PodcastChapter
        /// The audio file's name in the episode folder.
        var audioFile: String?
        var duration: TimeInterval?
        var state: State = .pending
        var error = ""

        var id: String { chapter.id }
        var isReady: Bool { state == .ready && audioFile != nil }
    }

    var digestID: UUID
    var day: String
    var createdAt = Date()
    var title: String
    /// The script's language ("en", "zh-Hans").
    var language: String
    var hosts: PodcastHosts
    var engine: PodcastEngineKind
    var voices: PodcastVoices?
    var minutesPerChapter: Double
    var entries: [Entry]

    var isComplete: Bool { !entries.contains { $0.state == .pending || $0.state == .working } }
    var readyCount: Int { entries.filter(\.isReady).count }
    var hasAudio: Bool { entries.contains { $0.isReady } }

    /// A chapter cut short (kill, background) starts over.
    var resumed: PodcastEpisode {
        var copy = self
        for index in copy.entries.indices where copy.entries[index].state == .working {
            copy.entries[index].state = .pending
        }
        return copy
    }
}

final class PodcastStore {
    /// Episodes older than this are deleted.
    static let maxAge: TimeInterval = 7 * 24 * 60 * 60
    static let manifestName = "episode.json"
    /// Read-aloud audio (not tied to a digest).
    static let readAloudFolder = "read-aloud"

    let directory: URL
    private let fileManager = FileManager.default
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    static var defaultDirectory: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return caches.appendingPathComponent("Podcasts", isDirectory: true)
    }

    init(directory: URL = PodcastStore.defaultDirectory) {
        self.directory = directory
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    func folder(for digestID: UUID) -> URL {
        directory.appendingPathComponent(digestID.uuidString, isDirectory: true)
    }

    func audioURL(_ name: String, digestID: UUID) -> URL {
        folder(for: digestID).appendingPathComponent(name)
    }

    var readAloudDirectory: URL {
        directory.appendingPathComponent(Self.readAloudFolder, isDirectory: true)
    }

    /// The episode, with chapters whose audio file is gone set to be
    /// spoken again, and a chapter cut short set back to waiting.
    func load(digestID: UUID) -> PodcastEpisode? {
        let url = folder(for: digestID).appendingPathComponent(Self.manifestName)
        guard let data = try? Data(contentsOf: url), var episode = try? decoder.decode(PodcastEpisode.self, from: data) else {
            return nil
        }
        episode = episode.resumed
        for index in episode.entries.indices {
            guard let name = episode.entries[index].audioFile else { continue }
            if !fileManager.fileExists(atPath: audioURL(name, digestID: digestID).path) {
                episode.entries[index].audioFile = nil
                episode.entries[index].duration = nil
                if episode.entries[index].state == .ready { episode.entries[index].state = .pending }
            }
        }
        return episode
    }

    func save(_ episode: PodcastEpisode) {
        do {
            let folder = folder(for: episode.digestID)
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            try encoder.encode(episode).write(to: folder.appendingPathComponent(Self.manifestName), options: .atomic)
        } catch {
            // Best effort: the episode can be made again.
        }
    }

    func delete(digestID: UUID) {
        try? fileManager.removeItem(at: folder(for: digestID))
    }

    /// Deletes episodes whose digest isn't in `keeping`, or that are older
    /// than `maxAge`, and read-aloud audio older than `maxAge`. Returns the
    /// digest ids deleted.
    @discardableResult
    func reconcile(keeping: Set<UUID>, now: Date = Date()) -> [UUID] {
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return [] }
        var deleted: [UUID] = []
        for name in names {
            let url = directory.appendingPathComponent(name, isDirectory: true)
            if name == Self.readAloudFolder {
                pruneReadAloud(now: now)
                continue
            }
            guard let id = UUID(uuidString: name) else {
                try? fileManager.removeItem(at: url)
                continue
            }
            let created = createdAt(of: id) ?? modificationDate(of: url) ?? now
            if !keeping.contains(id) || now.timeIntervalSince(created) > Self.maxAge {
                try? fileManager.removeItem(at: url)
                deleted.append(id)
            }
        }
        return deleted
    }

    /// Deletes everything (Delete All Digests).
    func deleteAll() {
        try? fileManager.removeItem(at: directory)
    }

    private func createdAt(of id: UUID) -> Date? {
        let url = folder(for: id).appendingPathComponent(Self.manifestName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? decoder.decode(PodcastEpisode.self, from: data))?.createdAt
    }

    private func modificationDate(of url: URL) -> Date? {
        (try? fileManager.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    private func pruneReadAloud(now: Date) {
        let folder = readAloudDirectory
        for name in (try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? [] {
            let url = folder.appendingPathComponent(name)
            if let date = modificationDate(of: url), now.timeIntervalSince(date) > Self.maxAge {
                try? fileManager.removeItem(at: url)
            }
        }
    }
}
