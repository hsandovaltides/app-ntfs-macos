import Foundation
@testable import AppNTFSKit

actor FakeProcessRunner: ProcessRunning {
    struct Call: Equatable, Sendable {
        let executable: String
        let arguments: [String]
    }

    private(set) var calls: [Call] = []
    private var responses: [String: ProcessResult]

    init(responses: [String: ProcessResult] = [:]) {
        self.responses = responses
    }

    func setResponse(for executable: String, result: ProcessResult) {
        responses[executable] = result
    }

    func run(executable: String, arguments: [String], timeout: Duration) async throws -> ProcessResult {
        calls.append(Call(executable: executable, arguments: arguments))
        return responses[executable] ?? ProcessResult(exitCode: 0, standardOutput: "", standardError: "")
    }
}

final class FakeFileSystemProbe: FileSystemProbing, @unchecked Sendable {
    private let existingPaths: Set<String>
    private let executablePaths: Set<String>

    init(existingPaths: Set<String> = [], executablePaths: Set<String> = []) {
        self.existingPaths = existingPaths
        self.executablePaths = executablePaths
    }

    func fileExists(atPath path: String) -> Bool { existingPaths.contains(path) }
    func isExecutableFile(atPath path: String) -> Bool { executablePaths.contains(path) }
}

/// A mount table that can change between calls.
///
/// The pipeline stats the same mount path twice for different reasons — once
/// up front to decide whether there is already an ntfs-3g mount to leave
/// alone, and once after mounting to confirm the mount actually took (see
/// `MountManager.mountFailureReason`). A fixed answer cannot express the
/// normal case, where those two calls must differ: nothing mounted, then
/// mounted. `sequencesByPath` supplies one answer per call and falls through
/// to `typesByPath` once exhausted.
final class FakeMountPointInspector: MountPointInspecting, @unchecked Sendable {
    /// fstype keyed by path; nil result for anything not listed.
    private let typesByPath: [String: String]
    private let lock = NSLock()
    private var sequencesByPath: [String: [String?]]

    init(typesByPath: [String: String] = [:], sequencesByPath: [String: [String?]] = [:]) {
        self.typesByPath = typesByPath
        self.sequencesByPath = sequencesByPath
    }

    /// The common case: nothing is mounted when the pipeline starts, and the
    /// mount is there by the time it verifies.
    static func mountedAfterMounting(
        _ path: String,
        as fileSystemType: String = "macfuse"
    ) -> FakeMountPointInspector {
        FakeMountPointInspector(sequencesByPath: [path: [nil, fileSystemType]])
    }

    func fileSystemType(atPath path: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        if var queued = sequencesByPath[path], !queued.isEmpty {
            let next = queued.removeFirst()
            sequencesByPath[path] = queued
            return next
        }
        return typesByPath[path]
    }
}

struct FakeHelperServiceStatusProbe: HelperServiceStatusProbing {
    let state: InstallState

    func status(forPlistName plistName: String) -> InstallState { state }
}

struct FakeFullDiskAccessProbe: FullDiskAccessProbing {
    let granted: Bool

    func hasFullDiskAccess() async -> Bool { granted }
}

enum SampleSystemExtensionsOutput {
    static let macFUSEApproved = """
    1 extension(s)
    --- com.apple.system_extension.driver_extension
    enabled\tactive\tteamID\tbundleID (version)\tname\t[state]
    *\t*\t2SGXXXXXX7\tio.macfuse.filesystems.macfuse (5.2.0/5.2.0)\tmacFUSE\t[activated enabled]
    """

    static let macFUSEPendingApproval = """
    1 extension(s)
    --- com.apple.system_extension.driver_extension
    enabled\tactive\tteamID\tbundleID (version)\tname\t[state]
    -\t-\t2SGXXXXXX7\tio.macfuse.filesystems.macfuse (5.2.0/5.2.0)\tmacFUSE\t[waiting for user]
    """

    static let empty = "0 extension(s)\n"
}
