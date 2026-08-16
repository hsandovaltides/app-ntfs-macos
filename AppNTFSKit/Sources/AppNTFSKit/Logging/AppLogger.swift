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

    public init() {}

    public var entries: [LogEntry] {
        bufferQueue.sync { buffer }
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
        bufferQueue.sync { buffer.removeAll() }
    }

    private func record(_ level: LogEntry.Level, _ message: String) {
        let entry = LogEntry(level: level, message: message)
        bufferQueue.sync {
            buffer.append(entry)
            if buffer.count > maxEntries {
                buffer.removeFirst(buffer.count - maxEntries)
            }
        }
    }
}
