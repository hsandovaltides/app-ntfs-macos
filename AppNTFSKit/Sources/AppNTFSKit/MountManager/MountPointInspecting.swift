import Foundation

/// Reads what's currently mounted at a path. Used to make the remount
/// pipeline idempotent: if the app restarts (or is relaunched at login)
/// while an NTFS volume is still mounted read-write through `ntfs-3g`, the
/// pipeline should recognise that and do nothing rather than tear down a
/// working mount and rebuild it.
public protocol MountPointInspecting: Sendable {
    /// The filesystem type mounted at `path` (`statfs`'s `f_fstypename` —
    /// e.g. `"ntfs"` for the native read-only mount, `"macfuse"` for an
    /// `ntfs-3g` mount, `"apfs"` for the system disk), or `nil` if nothing
    /// is mounted there / the path can't be stat'd.
    func fileSystemType(atPath path: String) -> String?
}

public struct DefaultMountPointInspector: MountPointInspecting {
    public init() {}

    public func fileSystemType(atPath path: String) -> String? {
        var info = statfs()
        guard statfs(path, &info) == 0 else { return nil }
        return withUnsafeBytes(of: info.f_fstypename) { raw in
            raw.baseAddress.map { String(cString: $0.assumingMemoryBound(to: CChar.self)) }
        }
    }
}
