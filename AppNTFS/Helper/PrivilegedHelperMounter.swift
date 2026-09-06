import AppNTFSKit
import Foundation

enum PrivilegedHelperMounterError: Error, CustomStringConvertible {
    case connectionUnavailable
    /// The helper accepted the call but never replied within the deadline —
    /// covers a wedged helper process or stalled XPC delivery (the helper's
    /// own `ProcessRunner` already bounds a hung `ntfs-3g` separately).
    case timedOut

    var description: String {
        switch self {
        case .connectionUnavailable: return "No se pudo conectar con el helper privilegiado"
        case .timedOut: return "El helper privilegiado no respondió a tiempo"
        }
    }
}

/// AppNTFSKit-side seam (`PrivilegedMounting`) implemented with XPC — the only
/// place in the app that talks NSXPCConnection/objc runtime. Talks to the
/// root LaunchDaemon registered by `AppCoordinator.installHelperIfNeeded()`.
final class PrivilegedHelperMounter: PrivilegedMounting, FullDiskAccessProbing, Sendable {
    func probeReadWrite(ntfs3gProbeExecutablePath: String, devicePath: String) async throws -> Bool {
        let result = try await withHelperProxy { proxy, resumeGuard, continuation in
            proxy.probeReadWrite(ntfs3gProbeExecutablePath: ntfs3gProbeExecutablePath, devicePath: devicePath) { result in
                resumeGuard.resumeOnce { continuation.resume(returning: result) }
            }
        }
        return result.exitCode == 0
    }

    func fix(ntfsfixExecutablePath: String, devicePath: String) async throws -> ProcessResult {
        let result = try await withHelperProxy { proxy, resumeGuard, continuation in
            proxy.fix(ntfsfixExecutablePath: ntfsfixExecutablePath, devicePath: devicePath) { result in
                resumeGuard.resumeOnce { continuation.resume(returning: result) }
            }
        }
        return ProcessResult(exitCode: result.exitCode, standardOutput: result.standardOutput, standardError: result.standardError)
    }

    /// `false` on any failure (connection drop, helper not approved yet,
    /// etc.) rather than throwing — a transient XPC hiccup here shouldn't
    /// itself surface as a Full Disk Access warning to the user; those
    /// failure modes are already reported by `helperState` separately.
    func hasFullDiskAccess() async -> Bool {
        (try? await withHelperProxy { proxy, resumeGuard, continuation in
            proxy.checkFullDiskAccess { granted in
                resumeGuard.resumeOnce { continuation.resume(returning: granted) }
            }
        }) ?? true
    }

    func mountReadWrite(
        ntfs3gExecutablePath: String,
        devicePath: String,
        mountPath: String,
        options: String
    ) async throws -> ProcessResult {
        let result = try await withHelperProxy { proxy, resumeGuard, continuation in
            proxy.mountReadWrite(
                ntfs3gExecutablePath: ntfs3gExecutablePath,
                devicePath: devicePath,
                mountPath: mountPath,
                options: options
            ) { result in
                resumeGuard.resumeOnce { continuation.resume(returning: result) }
            }
        }
        return ProcessResult(exitCode: result.exitCode, standardOutput: result.standardOutput, standardError: result.standardError)
    }

    /// Opens a fresh XPC connection, hands the caller the remote proxy plus a
    /// shared resume guard (the error handler and the caller's reply block
    /// can both fire for the same call), and tears the connection down when
    /// the call completes either way. Bounded by `timeout`: a helper that
    /// accepts the call but never replies would otherwise pin the caller's
    /// `MountManager` pipeline slot forever.
    private func withHelperProxy<T: Sendable>(
        timeout: Duration = .seconds(180),
        _ body: @escaping @Sendable (AppNTFSHelperProtocol, ResumeGuard, CheckedContinuation<T, Error>) -> Void
    ) async throws -> T {
        let connection = NSXPCConnection(machServiceName: helperMachServiceName, options: .privileged)
        connection.remoteObjectInterface = AppNTFSHelperXPC.makeInterface()
        connection.resume()
        // `invalidate()` also fires the proxy's error handler, which resumes
        // the abandoned continuation on the timeout path (no leaked-continuation
        // warning). NSXPCConnection is safe to touch from multiple threads.
        let connectionBox = UncheckedSendableBox(connection)
        defer { connection.invalidate() }

        return try await withThrowingTaskGroup(of: T?.self) { group in
            group.addTask {
                let value: T = try await withCheckedThrowingContinuation { continuation in
                    let resumeGuard = ResumeGuard()

                    let proxy = connectionBox.value.remoteObjectProxyWithErrorHandler { error in
                        resumeGuard.resumeOnce { continuation.resume(throwing: error) }
                    } as? AppNTFSHelperProtocol

                    guard let proxy else {
                        resumeGuard.resumeOnce {
                            continuation.resume(throwing: PrivilegedHelperMounterError.connectionUnavailable)
                        }
                        return
                    }

                    body(proxy, resumeGuard, continuation)
                }
                return value
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            defer { group.cancelAll() }

            while let outcome = try await group.next() {
                if let value = outcome { return value }
                // Timeout won. Invalidate the connection so the proxy's error
                // handler fires and resumes the still-suspended XPC
                // continuation — otherwise the task group would hang forever
                // waiting to drain that child.
                connectionBox.value.invalidate()
                throw PrivilegedHelperMounterError.timedOut
            }
            throw PrivilegedHelperMounterError.timedOut
        }
    }
}

/// Minimal escape hatch for handing a reference-thread-safe Cocoa object
/// (here `NSXPCConnection`) to a `@Sendable` closure.
private struct UncheckedSendableBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

/// The XPC error handler and the reply block can both fire for the same
/// call (e.g. the connection drops right as the reply is in flight) —
/// this guarantees the continuation only ever resumes once.
private final class ResumeGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var didResume = false

    func resumeOnce(_ body: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !didResume else { return }
        didResume = true
        body()
    }
}
