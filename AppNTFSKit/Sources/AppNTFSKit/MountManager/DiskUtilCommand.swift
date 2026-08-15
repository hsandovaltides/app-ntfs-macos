import Foundation

/// Thin wrapper over `diskutil`, used for the native (read-only) mount/unmount
/// side of the remount pipeline. Kept separate from Ntfs3gCommand so each
/// wrapper owns exactly one external tool.
struct DiskUtilCommand {
    private static let executable = "/usr/sbin/diskutil"

    private let runner: ProcessRunning

    init(runner: ProcessRunning) {
        self.runner = runner
    }

    @discardableResult
    func unmount(mountPath: String, force: Bool = false) async throws -> ProcessResult {
        var arguments = ["unmount"]
        if force { arguments.append("force") }
        arguments.append(mountPath)
        return try await runner.run(executable: Self.executable, arguments: arguments)
    }

    @discardableResult
    func mount(bsdName: String) async throws -> ProcessResult {
        try await runner.run(executable: Self.executable, arguments: ["mount", bsdName])
    }
}
