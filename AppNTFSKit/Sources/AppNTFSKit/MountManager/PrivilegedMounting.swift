import Foundation

/// Narrow seam for the operations that genuinely need root: reading the raw
/// disk device to check the Windows dirty/hibernation flag, and creating the
/// mountpoint under /Volumes to invoke `ntfs-3g`. Kept as its own protocol
/// (not folded into `ProcessRunning`) because the privileged implementation
/// is structured XPC calls, not "run this argv" — see `AppNTFS/Helper/`.
///
/// Both need root: `/dev/rdiskN`/`/dev/diskN` are `root:operator` mode 0640,
/// unreadable by a regular admin user (confirmed on real hardware — the
/// unprivileged probe fails with "Permission denied", which was previously
/// misread as "volume is dirty" since both look like a probe failure).
public protocol PrivilegedMounting: Sendable {
    /// Returns whether the volume has no Windows dirty/hibernation flag set
    /// and is safe to mount read-write.
    func probeReadWrite(
        ntfs3gProbeExecutablePath: String,
        devicePath: String
    ) async throws -> Bool

    func mountReadWrite(
        ntfs3gExecutablePath: String,
        devicePath: String,
        mountPath: String,
        options: String
    ) async throws -> ProcessResult
}
