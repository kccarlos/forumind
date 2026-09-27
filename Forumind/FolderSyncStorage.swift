import Foundation

/// A file in a sync folder listing.
struct FolderSyncFileInfo: Equatable {
    var url: URL
    var name: String
    /// False while iCloud Drive has only a placeholder (or an older copy):
    /// the file must not be read this pass (a download was requested).
    var isCurrent: Bool
    var modifiedAt: Date?
    var size: Int?
}

/// File access for the sync engine. Production coordinates every access
/// (`NSFileCoordinator`) and handles iCloud Drive placeholders and conflict
/// versions; tests wrap it to count writes or inject conflicts.
///
/// Calls block: the engine makes them from its own actor, never the main thread.
protocol FolderSyncStorage: AnyObject, Sendable {
    func ensureDirectory(_ url: URL) throws
    /// `.json` files in `directory` (placeholders reported as not current).
    func list(_ directory: URL) throws -> [FolderSyncFileInfo]
    /// Coordinated read; nil if the file does not exist.
    func read(_ url: URL) throws -> Data?
    /// Contents of unresolved conflict versions (other devices' copies).
    func conflictVersions(of url: URL) -> [Data]
    /// Marks conflict versions resolved and removes them.
    func resolveConflicts(of url: URL)
    /// Coordinated atomic write.
    func write(_ data: Data, to url: URL) throws
    /// Writes `data` only if no file exists, inside one coordinated write;
    /// returns what the file holds afterwards.
    func createIfAbsent(_ data: Data, at url: URL) throws -> Data
    func remove(_ url: URL) throws
    /// File modification info after a write (keeps the read cache warm).
    func info(of url: URL) -> FolderSyncFileInfo?
}

final class CoordinatedFolderStorage: FolderSyncStorage, @unchecked Sendable {
    /// Our own presenter: coordinated writes made with it do not call it back.
    weak var filePresenter: NSFilePresenter?

    init(filePresenter: NSFilePresenter? = nil) {
        self.filePresenter = filePresenter
    }

    private func coordinator() -> NSFileCoordinator {
        NSFileCoordinator(filePresenter: filePresenter)
    }

    func ensureDirectory(_ url: URL) throws {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return
        }
        var coordinationError: NSError?
        var thrown: Error?
        coordinator().coordinate(writingItemAt: url, options: [], error: &coordinationError) { target in
            do {
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            } catch {
                thrown = error
            }
        }
        if let error = coordinationError ?? thrown { throw error }
    }

    func list(_ directory: URL) throws -> [FolderSyncFileInfo] {
        let keys: [URLResourceKey] = [
            .ubiquitousItemDownloadingStatusKey, .isUbiquitousItemKey,
            .contentModificationDateKey, .fileSizeKey
        ]
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: []
        )
        var files: [String: FolderSyncFileInfo] = [:]
        for url in urls {
            let name = url.lastPathComponent
            // Legacy iCloud placeholder: `.name.json.icloud`.
            if name.hasPrefix("."), name.hasSuffix(".icloud") {
                let real = String(name.dropFirst().dropLast(".icloud".count))
                guard real.hasSuffix(".json") else { continue }
                let realURL = directory.appendingPathComponent(real)
                try? FileManager.default.startDownloadingUbiquitousItem(at: realURL)
                if files[real] == nil {
                    files[real] = FolderSyncFileInfo(url: realURL, name: real, isCurrent: false)
                }
                continue
            }
            guard !name.hasPrefix("."), name.hasSuffix(".json") else { continue }
            let values = try? url.resourceValues(forKeys: Set(keys))
            var isCurrent = true
            if values?.isUbiquitousItem == true,
               let status = values?.ubiquitousItemDownloadingStatus,
               status != .current {
                isCurrent = false
                try? FileManager.default.startDownloadingUbiquitousItem(at: url)
            }
            files[name] = FolderSyncFileInfo(
                url: url,
                name: name,
                isCurrent: isCurrent,
                modifiedAt: values?.contentModificationDate,
                size: values?.fileSize
            )
        }
        return files.values.sorted { $0.name < $1.name }
    }

    func read(_ url: URL) throws -> Data? {
        var coordinationError: NSError?
        var result: Data?
        var thrown: Error?
        coordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { target in
            guard FileManager.default.fileExists(atPath: target.path) else { return }
            do {
                result = try Data(contentsOf: target)
            } catch {
                thrown = error
            }
        }
        if let error = coordinationError ?? thrown { throw error }
        return result
    }

    func conflictVersions(of url: URL) -> [Data] {
        guard let versions = NSFileVersion.unresolvedConflictVersionsOfItem(at: url) else { return [] }
        return versions.compactMap { try? Data(contentsOf: $0.url) }
    }

    func resolveConflicts(of url: URL) {
        var coordinationError: NSError?
        coordinator().coordinate(writingItemAt: url, options: [], error: &coordinationError) { target in
            for version in NSFileVersion.unresolvedConflictVersionsOfItem(at: target) ?? [] {
                version.isResolved = true
            }
            try? NSFileVersion.removeOtherVersionsOfItem(at: target)
        }
    }

    func write(_ data: Data, to url: URL) throws {
        var coordinationError: NSError?
        var thrown: Error?
        coordinator().coordinate(writingItemAt: url, options: [.forReplacing], error: &coordinationError) { target in
            do {
                try data.write(to: target, options: .atomic)
            } catch {
                thrown = error
            }
        }
        if let error = coordinationError ?? thrown { throw error }
    }

    func createIfAbsent(_ data: Data, at url: URL) throws -> Data {
        var coordinationError: NSError?
        var thrown: Error?
        var result = data
        coordinator().coordinate(writingItemAt: url, options: [], error: &coordinationError) { target in
            do {
                if FileManager.default.fileExists(atPath: target.path) {
                    result = try Data(contentsOf: target)
                } else {
                    try data.write(to: target, options: .withoutOverwriting)
                }
            } catch {
                thrown = error
            }
        }
        if let error = coordinationError ?? thrown { throw error }
        return result
    }

    func remove(_ url: URL) throws {
        var coordinationError: NSError?
        var thrown: Error?
        coordinator().coordinate(writingItemAt: url, options: [.forDeleting], error: &coordinationError) { target in
            do {
                if FileManager.default.fileExists(atPath: target.path) {
                    try FileManager.default.removeItem(at: target)
                }
            } catch {
                thrown = error
            }
        }
        if let error = coordinationError ?? thrown { throw error }
    }

    func info(of url: URL) -> FolderSyncFileInfo? {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return FolderSyncFileInfo(
            url: url,
            name: url.lastPathComponent,
            isCurrent: true,
            modifiedAt: values?.contentModificationDate,
            size: values?.fileSize
        )
    }
}
