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

        // Cancelling the calling task kills the child, rather than leaving an
        // `ntfs-3g` or `diskutil` running unsupervised while nobody is left to
        // read its result. This is what makes the UI's per-volume cancel
        // button mean something: without it, "cancel" would only stop the app
        // from *listening*. `MountManager.restoreReadOnly` is deliberately
        // shielded from this so the read-only fallback still runs.
        return try await withTaskCancellationHandler {
            try await runToCompletion(handle, executable: executable, timeout: timeout)
        } onCancel: {
            handle.terminate()
        }
    }

    private func runToCompletion(
        _ handle: ProcessHandle,
        executable: String,
        timeout: Duration
    ) async throws -> ProcessResult {
        try await withThrowingTaskGroup(of: ProcessResult?.self) { group in
            group.addTask { try await handle.run() }
            group.addTask {
                do {
                    try await Task.sleep(for: timeout)
                } catch {
                    // The sleep was cancelled, not elapsed. The enclosing
                    // cancellation handler has already SIGTERMed the child, so
                    // say so — reporting a cancellation as a 120 s timeout
                    // would put a wrong diagnosis in the user's error row.
                    throw CancellationError()
                }
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

            // Both pipes are drained on their own queues, started *before* the
            // process launches, rather than read from the termination handler
            // once it has already exited.
            //
            // Reading after exit only works while the output fits in the pipe's
            // kernel buffer (64 KiB): past that the child blocks in `write()`
            // waiting for a reader that, by construction, will not read until
            // the child exits. That deadlock resolves only when the 120 s
            // timeout fires and SIGTERMs the process, and every command here
            // spawns a third-party binary whose output volume is not ours to
            // promise — `ntfs-3g` in particular can be arbitrarily chatty on
            // stderr when a mount goes wrong, which is exactly the case that
            // most needs its output captured.
            let collector = OutputCollector()
            let drained = DispatchGroup()
            for (pipe, isStandardOutput) in [(stdoutPipe, true), (stderrPipe, false)] {
                drained.enter()
                DispatchQueue.global().async {
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    collector.store(data, isStandardOutput: isStandardOutput)
                    drained.leave()
                }
            }

            // `notify` rather than `wait`: the termination handler runs on a
            // queue owned by Process, and blocking it would stall every other
            // process this app is waiting on. In practice both reads are
            // already at EOF by now — the child exiting is what closed the
            // write ends — so the notify fires immediately.
            process.terminationHandler = { finishedProcess in
                let exitCode = finishedProcess.terminationStatus
                drained.notify(queue: DispatchQueue.global()) {
                    continuation.resume(returning: ProcessResult(
                        exitCode: exitCode,
                        standardOutput: collector.standardOutput,
                        standardError: collector.standardError
                    ))
                }
            }

            do {
                try process.run()
            } catch {
                // Nothing was spawned, so nothing will ever close the write
                // ends — without this the two drain tasks block on
                // `readDataToEndOfFile` for the lifetime of the process.
                try? stdoutPipe.fileHandleForWriting.close()
                try? stderrPipe.fileHandleForWriting.close()
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
        //
        // The liveness re-check is not optional. Capturing the pid and killing
        // it unconditionally three seconds later targets whatever holds that
        // pid *at that moment*: if the SIGTERM worked (the overwhelming
        // majority of the time) the pid is free to be recycled, and this would
        // signal an unrelated process. `HelperService` runs this same code as
        // root, so the unrelated process could be anything on the machine.
        // `Process.isRunning` answers from the state Foundation already reaped,
        // so consulting it under the lock closes the window rather than
        // narrowing it.
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) { [self] in
            lock.lock()
            defer { lock.unlock() }
            guard process.isRunning else { return }
            kill(process.processIdentifier, SIGKILL)
        }
    }
}

/// Accumulates the two pipe drains started by `ProcessHandle.run()`.
///
/// `@unchecked Sendable`: the two writers touch disjoint fields and the reader
/// only runs after both have left the `DispatchGroup`, but the lock makes that
/// ordering argument unnecessary rather than load-bearing.
private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var stdoutData = Data()
    private var stderrData = Data()

    func store(_ data: Data, isStandardOutput: Bool) {
        lock.lock()
        defer { lock.unlock() }
        if isStandardOutput {
            stdoutData = data
        } else {
            stderrData = data
        }
    }

    var standardOutput: String {
        lock.lock()
        defer { lock.unlock() }
        return String(data: stdoutData, encoding: .utf8) ?? ""
    }

    var standardError: String {
        lock.lock()
        defer { lock.unlock() }
        return String(data: stderrData, encoding: .utf8) ?? ""
    }
}
