import DiskArbitration
import Foundation

/// Watches DiskArbitration for NTFS volumes appearing/changing/disappearing and
/// republishes them as an AsyncStream. Deliberately DiskArbitration-only (no
/// NSWorkspace) so downstream consumers always get the BSD device node they
/// need to actually remount the volume.
public final class DiskWatcher: @unchecked Sendable {
    private var session: DASession?
    private let continuation: AsyncStream<DiskEvent>.Continuation
    public let events: AsyncStream<DiskEvent>

    public init() {
        var continuation: AsyncStream<DiskEvent>.Continuation!
        events = AsyncStream { continuation = $0 }
        self.continuation = continuation
    }

    deinit {
        stop()
    }

    public func start() {
        guard session == nil, let session = DASessionCreate(kCFAllocatorDefault) else { return }
        self.session = session

        let context = Unmanaged.passUnretained(self).toOpaque()

        DARegisterDiskAppearedCallback(session, nil, { disk, info in
            guard let info else { return }
            Unmanaged<DiskWatcher>.fromOpaque(info).takeUnretainedValue()
                .handleDisk(disk, isInitialAppearance: true)
        }, context)

        DARegisterDiskDescriptionChangedCallback(session, nil, nil, { disk, _, info in
            guard let info else { return }
            Unmanaged<DiskWatcher>.fromOpaque(info).takeUnretainedValue()
                .handleDisk(disk, isInitialAppearance: false)
        }, context)

        DARegisterDiskDisappearedCallback(session, nil, { disk, info in
            guard let info else { return }
            Unmanaged<DiskWatcher>.fromOpaque(info).takeUnretainedValue()
                .handleDiskDisappeared(disk)
        }, context)

        DASessionSetDispatchQueue(session, DispatchQueue(label: "com.appntfs.diskwatcher"))
    }

    public func stop() {
        guard let session else { return }
        DASessionSetDispatchQueue(session, nil)
        self.session = nil
    }

    private func handleDisk(_ disk: DADisk, isInitialAppearance: Bool) {
        guard let volume = Self.makeNTFSVolume(from: disk) else { return }
        continuation.yield(isInitialAppearance ? .appeared(volume) : .descriptionChanged(volume))
    }

    private func handleDiskDisappeared(_ disk: DADisk) {
        guard let bsdNamePointer = DADiskGetBSDName(disk) else { return }
        continuation.yield(.disappeared(bsdName: String(cString: bsdNamePointer)))
    }

    /// Matches only mountable, non-network NTFS *volumes* (not whole disks).
    /// The DARegister*Callback `match` dictionary is unreliable for volumes whose
    /// filesystem hasn't been resolved yet at the moment they first appear, so
    /// filtering happens here instead, against the fully populated description.
    private static func makeNTFSVolume(from disk: DADisk) -> NTFSVolume? {
        guard let description = DADiskCopyDescription(disk) as? [String: Any] else { return nil }

        guard let volumeKind = description[kDADiskDescriptionVolumeKindKey as String] as? String,
              volumeKind.lowercased() == "ntfs" else { return nil }

        guard let isWholeMedia = description[kDADiskDescriptionMediaWholeKey as String] as? Bool,
              isWholeMedia == false else { return nil }

        if let isNetwork = description[kDADiskDescriptionVolumeNetworkKey as String] as? Bool, isNetwork {
            return nil
        }

        guard let isMountable = description[kDADiskDescriptionVolumeMountableKey as String] as? Bool,
              isMountable else { return nil }

        guard let bsdNamePointer = DADiskGetBSDName(disk) else { return nil }
        let bsdName = String(cString: bsdNamePointer)

        let volumeName = (description[kDADiskDescriptionVolumeNameKey as String] as? String) ?? bsdName

        let volumeUUID: String? = {
            guard let rawValue = description[kDADiskDescriptionVolumeUUIDKey as String] else { return nil }
            let cfValue = rawValue as CFTypeRef
            guard CFGetTypeID(cfValue) == CFUUIDGetTypeID() else { return nil }
            return CFUUIDCreateString(kCFAllocatorDefault, (cfValue as! CFUUID)) as String
        }()

        let mountPath = (description[kDADiskDescriptionVolumePathKey as String] as? URL)?.path
            ?? "/Volumes/\(volumeName)"

        return NTFSVolume(
            bsdName: bsdName,
            volumeName: volumeName,
            volumeUUID: volumeUUID,
            mountPath: mountPath,
            mountState: .readOnly
        )
    }
}
