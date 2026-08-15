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

/// Abstraction over process execution so MountManager/DependencyChecker can be
/// unit tested without spawning real diskutil/mount_ntfs-3g/brew processes.
public protocol ProcessRunning: Sendable {
    func run(executable: String, arguments: [String]) async throws -> ProcessResult
}

public struct ProcessRunner: ProcessRunning {
    public init() {}

    public func run(executable: String, arguments: [String]) async throws -> ProcessResult {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            // Reading in the termination handler is safe here because every command
            // this app runs (diskutil, mount_ntfs-3g, brew, systemextensionsctl, ...)
            // produces small text output well under the pipe's kernel buffer size —
            // there's no risk of the classic write()-blocks-before-we-read deadlock.
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
}
