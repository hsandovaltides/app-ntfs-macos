import Foundation

public struct ProcessResult: Sendable, Equatable {
    public let exitCode: Int32
    public let standardOutput: String
    public let standardError: String

    public var succeeded: Bool { exitCode == 0 }

    public init(exitCode: Int32, standardOutput: String, standardError: String) {
        self.exitCode = exitCode
        self.standardOutput = standardOutput
        self.standardError = standardError
    }
}

public enum ProcessRunnerError: Error, CustomStringConvertible, Equatable {
    /// The process didn't exit within the allotted time and was sent SIGTERM.
    /// Matters because `diskutil` / `ntfs-3g` can wedge on a FUSE deadlock,
    /// and an un-timed `await` there would pin the volume's pipeline slot
    /// (`MountManager.inFlight`) for the rest of the session.
    case timedOut(executable: String, seconds: Int)

    public var description: String {
        switch self {
        case let .timedOut(executable, seconds):
            return "\(executable) no respondió tras \(seconds)s (terminado)"
        }
    }
}

/// Abstraction over process execution so MountManager/DependencyChecker can be
/// unit tested without spawning real diskutil/mount_ntfs-3g/brew processes.
public protocol ProcessRunning: Sendable {
    func run(executable: String, arguments: [String], timeout: Duration) async throws -> ProcessResult
}

public extension ProcessRunning {
    /// Default timeout for every current call site. 120s is comfortably above
    /// the slowest legitimate operation (a large-volume `ntfs-3g` mount) while
    /// still bounding a hang.
    func run(executable: String, arguments: [String]) async throws -> ProcessResult {
        try await run(executable: executable, arguments: arguments, timeout: .seconds(120))
    }
}

public struct ProcessRunner: ProcessRunning {
    public init() {}

    public func run(
        executable: String,
        arguments: [String],
        timeout: Duration
    ) async throws -> ProcessResult {
        let handle = ProcessHandle(executable: executable, arguments: arguments)

        return try await withThrowingTaskGroup(of: ProcessResult?.self) { group in
            group.addTask { try await handle.run() }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            defer { group.cancelAll() }

            while let outcome = try await group.next() {
                if let result = outcome { return result }
                // The timeout task won the race — kill the process and surface
                // it. The still-pending `handle.run()` child resumes once the
                // SIGTERM lands and its result is discarded by the group.
                handle.terminate()
                throw ProcessRunnerError.timedOut(
                    executable: executable,
                    seconds: Int(timeout.components.seconds)
                )
            }
            throw ProcessRunnerError.timedOut(
                executable: executable,
                seconds: Int(timeout.components.seconds)
            )
        }
    }
}

/// Owns a single `Process` and serializes launch/terminate across the two
/// tasks that race in `ProcessRunner.run` (the runner and the timeout).
/// `@unchecked Sendable`: every access to the underlying `Process` goes
/// through `lock`.
private final class ProcessHandle: @unchecked Sendable {
    private let process = Process()
    private let lock = NSLock()
    private var terminateRequested = false

    init(executable: String, arguments: [String]) {
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
    }

    func run() async throws -> ProcessResult {
        try await withCheckedThrowingContinuation { continuation in
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()

            lock.lock()
            defer { lock.unlock() }

            // `terminate()` may have won the race before we even launched.
            guard !terminateRequested else {
                continuation.resume(throwing: CancellationError())
                return
            }

            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe
            // Reading in the termination handler is safe: every command this
            // app runs (diskutil, mount_ntfs-3g, brew, kmutil,
            // systemextensionsctl, …) produces small text output well under
            // the pipe's kernel buffer size — no write()-blocks-before-read
            // deadlock.
            process.terminationHandler = { finishedProcess in
                let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: ProcessResult(
                    exitCode: finishedProcess.terminationStatus,
                    standardOutput: String(data: stdoutData, encoding: .utf8) ?? "",
                    standardError: String(data: stderrData, encoding: .utf8) ?? ""
                ))
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    func terminate() {
        lock.lock()
        defer { lock.unlock() }
        terminateRequested = true
        guard process.isRunning else { return }
        process.terminate() // SIGTERM
        // Escalate to SIGKILL if it's still there a few seconds later — a
        // FUSE-deadlocked `ntfs-3g` can ignore SIGTERM, and the task group
        // that spawned us won't finish draining until this process is gone.
        let pid = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
            kill(pid, SIGKILL)
        }
    }
}
