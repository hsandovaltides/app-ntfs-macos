import AppNTFSKit
import Darwin
import Foundation

/// Runs as root. Does exactly one thing: create the /Volumes mountpoint if
/// needed and invoke ntfs-3g, atomically from the caller's point of view —
/// see AppNTFSKit's PrivilegedMounting doc comment for why this isn't split
/// into separate mkdir/mount XPC calls (a crashed/killed client between the
/// two would leave a root-owned directory under /Volumes the user can't even
/// delete without sudo).
/// @unchecked Sendable: a fresh instance is created per XPC connection (see
/// HelperListenerDelegate), has no mutable stored state, and everything it
/// captures into `Task { }` below (runner, fileManager, reply) is itself
/// Sendable — safe for XPC to invoke concurrently.
final class HelperService: NSObject, AppNTFSHelperProtocol, @unchecked Sendable {
    private let runner: ProcessRunning = ProcessRunner()
    private let fileManager = FileManager.default

    func probeReadWrite(
        ntfs3gProbeExecutablePath: String,
        devicePath: String,
        reply: @escaping @Sendable (HelperOperationResult) -> Void
    ) {
        Task {
            do {
                let result = try await runner.run(
                    executable: ntfs3gProbeExecutablePath,
                    arguments: ["--readwrite", devicePath]
                )
                reply(HelperOperationResult(
                    exitCode: result.exitCode,
                    standardOutput: result.standardOutput,
                    standardError: result.standardError
                ))
            } catch {
                reply(HelperOperationResult(exitCode: -1, standardOutput: "", standardError: "\(error)"))
            }
        }
    }

    func mountReadWrite(
        ntfs3gExecutablePath: String,
        devicePath: String,
        mountPath: String,
        options: String,
        reply: @escaping @Sendable (HelperOperationResult) -> Void
    ) {
        Task {
            let createdDirectory = (try? createMountPointIfNeeded(mountPath)) ?? false

            do {
                let result = try await runner.run(
                    executable: ntfs3gExecutablePath,
                    arguments: [devicePath, mountPath, "-o", options]
                )
                if !result.succeeded, createdDirectory {
                    try? fileManager.removeItem(atPath: mountPath)
                }
                reply(HelperOperationResult(
                    exitCode: result.exitCode,
                    standardOutput: result.standardOutput,
                    standardError: result.standardError
                ))
            } catch {
                if createdDirectory {
                    try? fileManager.removeItem(atPath: mountPath)
                }
                reply(HelperOperationResult(exitCode: -1, standardOutput: "", standardError: "\(error)"))
            }
        }
    }

    /// Raw disk device nodes are gated by the Full Disk Access TCC
    /// permission independent of root — confirmed on real hardware, a fresh
    /// helper running as root still got `EPERM` ("Operation not permitted")
    /// opening `/dev/rdiskN` until this specific binary was added to
    /// Privacy & Security → Full Disk Access. `/dev/rdisk0` (the primary
    /// physical disk) is used as the probe target since it's present on
    /// every Mac; only `EPERM` specifically is treated as "access missing" —
    /// any other errno (e.g. the disk being busy) doesn't indicate that.
    func checkFullDiskAccess(reply: @escaping @Sendable (Bool) -> Void) {
        let fd = open("/dev/rdisk0", O_RDONLY)
        if fd >= 0 {
            close(fd)
            reply(true)
            return
        }
        reply(errno != EPERM)
    }

    /// Returns whether this call is the one that created the directory — a
    /// pre-existing directory is left alone on failure either way.
    private func createMountPointIfNeeded(_ path: String) throws -> Bool {
        guard !fileManager.fileExists(atPath: path) else { return false }
        try fileManager.createDirectory(atPath: path, withIntermediateDirectories: true)
        return true
    }
}
