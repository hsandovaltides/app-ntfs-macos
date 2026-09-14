import Foundation
import OSLog

public struct LogEntry: Sendable, Identifiable, Equatable {
    public enum Level: String, Sendable {
        case info, warning, error
    }

    public let id: UUID
    public let timestamp: Date
    public let level: Level
    public let message: String

    public init(id: UUID = UUID(), timestamp: Date = Date(), level: Level, message: String) {
        self.id = id
        self.timestamp = timestamp
        self.level = level
        self.message = message
    }
}

/// Mirrors log lines into an in-memory ring buffer (for the app's "View Logs"
/// window) in addition to os_log/Console.app. Buffer access is serialized on
/// `bufferQueue`, which is what makes the @unchecked Sendable conformance safe.
public final class AppLogger: @unchecked Sendable {
    public static let shared = AppLogger()

    private let osLogger = Logger(subsystem: "com.appntfs.app", category: "general")
    private let bufferQueue = DispatchQueue(label: "com.appntfs.logger.buffer")
    private var buffer: [LogEntry] = []
    private let maxEntries = 500
    private var observers: [UUID: AsyncStream<[LogEntry]>.Continuation] = [:]

    public init() {}

    public var entries: [LogEntry] {
        bufferQueue.sync { buffer }
    }

    /// A snapshot of the buffer on subscribe, and another one every time it
    /// changes. Replaces the logs window polling `entries` once a second,
    /// which cost a wakeup per second whether or not anything had been logged
    /// and still showed a line up to a second after it was written — exactly
    /// backwards for a window somebody opens because they are watching a mount
    /// fail in real time.
    ///
    /// Whole snapshots rather than individual entries: the buffer is capped at
    /// `maxEntries` and drops from the front, so a consumer accumulating deltas
    /// would have to reimplement that trimming to stay in sync.
    public var updates: AsyncStream<[LogEntry]> {
        // `bufferingNewest(1)`: each element is a complete snapshot, so a
        // consumer that fell behind gains nothing from the intermediate ones
        // and the default unbounded buffer would just grow a queue of stale
        // arrays behind a slow window.
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let id = UUID()
            bufferQueue.sync {
                observers[id] = continuation
                continuation.yield(buffer)
            }
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                bufferQueue.sync { observers[id] = nil }
            }
        }
    }

    /// The buffer as plain text, oldest first — what the "Copiar" and
    /// "Exportar" actions in the logs window hand over. A user reporting a
    /// mount that won't work has the whole story in the log and, until now, no
    /// way to get it out of the window other than retyping it.
    public var transcript: String {
        let formatter = ISO8601DateFormatter()
        return entries
            .map { "\(formatter.string(from: $0.timestamp)) [\($0.level.rawValue)] \($0.message)" }
            .joined(separator: "\n")
    }

    public func info(_ message: String) {
        osLogger.info("\(message, privacy: .public)")
        record(.info, message)
    }

    public func warning(_ message: String) {
        osLogger.warning("\(message, privacy: .public)")
        record(.warning, message)
    }

    public func error(_ message: String) {
        osLogger.error("\(message, privacy: .public)")
        record(.error, message)
    }

    public func clear() {
        bufferQueue.sync {
            buffer.removeAll()
            publish()
        }
    }

    private func record(_ level: LogEntry.Level, _ message: String) {
        let entry = LogEntry(level: level, message: message)
        bufferQueue.sync {
            buffer.append(entry)
            if buffer.count > maxEntries {
                buffer.removeFirst(buffer.count - maxEntries)
            }
            publish()
        }
    }

    /// Must be called on `bufferQueue`. `yield` never blocks, and the stream's
    /// `bufferingNewest(1)` policy means a consumer that is behind simply loses
    /// the intermediate snapshots — so a slow logs window can't back up a log
    /// call made from the mount pipeline.
    private func publish() {
        let snapshot = buffer
        for continuation in observers.values {
            continuation.yield(snapshot)
        }
    }
}
