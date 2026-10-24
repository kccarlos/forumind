import SwiftUI

/// Text an AI job is streaming in (summary sections, chat answers), by work
/// record id. Tokens arrive far faster than a screen needs: they collect in
/// a buffer and publish at most every `interval`, so only the views that
/// show the text (the summary and the chat thread) redraw, about ten times
/// a second. `text(for:)` always returns the latest text, buffered or
/// published.
@MainActor
final class StreamStore: ObservableObject {
    /// What views draw; trails the buffer by up to `interval`.
    @Published private(set) var texts: [UUID: String] = [:]
    private var buffer: [UUID: String] = [:]
    private var flushTask: Task<Void, Never>?
    private let interval: Duration

    init(interval: Duration = .milliseconds(100)) {
        self.interval = interval
    }

    var isEmpty: Bool { texts.isEmpty && buffer.isEmpty }

    func text(for id: UUID) -> String? {
        buffer[id] ?? texts[id]
    }

    /// Starts (or restarts) a stream, empty, at once.
    func start(_ id: UUID) {
        buffer.removeValue(forKey: id)
        texts[id] = ""
    }

    /// Replaces the stream's text at once (fixtures, debug scripts).
    func set(_ text: String, for id: UUID) {
        buffer.removeValue(forKey: id)
        texts[id] = text
    }

    func append(_ delta: String, to id: UUID) {
        buffer[id] = (buffer[id] ?? texts[id] ?? "") + delta
        guard flushTask == nil else { return }
        flushTask = Task { [weak self, interval] in
            try? await Task.sleep(for: interval)
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    /// Publishes what the buffer holds now.
    func flush() {
        flushTask?.cancel()
        flushTask = nil
        guard !buffer.isEmpty else { return }
        for (id, text) in buffer { texts[id] = text }
        buffer.removeAll()
    }

    /// Ends the stream (finished, cancelled, or paused); a late delta must
    /// not bring it back, which callers guard with their own liveness check.
    func remove(_ id: UUID) {
        buffer.removeValue(forKey: id)
        if texts[id] != nil { texts.removeValue(forKey: id) }
    }
}
