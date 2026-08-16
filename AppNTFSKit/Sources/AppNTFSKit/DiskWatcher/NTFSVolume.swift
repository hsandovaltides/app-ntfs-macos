import Foundation

public struct NTFSVolume: Sendable, Identifiable, Equatable {
    public enum MountState: Sendable, Equatable {
        case readOnly
        case mounting
        case readWrite
        /// Carries the structured `MountError`, not a pre-formatted string —
        /// callers (the UI, mainly) need to distinguish *which* error this
        /// is, e.g. to offer a "Reparar y reintentar" action specifically
        /// for `.volumeDirty`. Use `MountError.localizedDescription` (or
        /// just `error.localizedDescription`) to render it.
        case error(MountError)
    }

    public var id: String { bsdName }

    public let bsdName: String
    public let volumeName: String
    public let volumeUUID: String?
    public var mountPath: String
    public var mountState: MountState

    /// Raw (unbuffered) device node. `ntfs-3g.probe`'s dirty-flag check reads
    /// fine from this, but the actual `ntfs-3g` read-write mount does not —
    /// confirmed on real hardware and a synthetic fixture alike: mounting
    /// this path fails reading `$Bitmap` with `ntfs_pread failed: Invalid
    /// argument` (an unaligned-read error), while mounting `blockDevicePath`
    /// for the exact same volume succeeds immediately. Kept only for the
    /// probe; use `blockDevicePath` for the actual mount.
    public var rawDevicePath: String { "/dev/r\(bsdName)" }

    /// Buffered block device node — what `ntfs-3g`'s actual mount needs (see
    /// `rawDevicePath`'s doc comment). The kernel's buffer cache absorbs the
    /// unaligned reads that fail against the raw device directly.
    public var blockDevicePath: String { "/dev/\(bsdName)" }

    public init(
        bsdName: String,
        volumeName: String,
        volumeUUID: String?,
        mountPath: String,
        mountState: MountState = .readOnly
    ) {
        self.bsdName = bsdName
        self.volumeName = volumeName
        self.volumeUUID = volumeUUID
        self.mountPath = mountPath
        self.mountState = mountState
    }
}

public enum DiskEvent: Sendable, Equatable {
    case appeared(NTFSVolume)
    case descriptionChanged(NTFSVolume)
    case disappeared(bsdName: String)
}
