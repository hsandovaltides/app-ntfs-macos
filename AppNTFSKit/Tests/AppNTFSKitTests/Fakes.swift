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

    func run(executable: String, arguments: [String]) async throws -> ProcessResult {
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
