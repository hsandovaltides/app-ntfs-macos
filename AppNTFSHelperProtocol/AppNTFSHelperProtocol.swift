import Foundation

// Shared between the AppNTFS and AppNTFSHelper Xcode targets (plain source
// folder, not an SPM package — AppNTFSKit is a separate SPM package and
// can't see these files; DependencyChecker duplicates the plist name literal
// for that reason, see its comment).
public let helperMachServiceName = "com.appntfs.app.helper"
public let helperLaunchDaemonPlistName = "com.appntfs.app.helper.plist"
public let expectedAppBundleIdentifier = "com.appntfs.app"

/// Deliberately narrow: the helper runs as root, so it exposes specific,
/// auditable operations (probe/mount NTFS) rather than a generic "run this
/// command" passthrough. See HelperService for the implementation.
@objc public protocol AppNTFSHelperProtocol {
    /// Reads the raw disk device to check the Windows dirty/hibernation flag
    /// — regular users can't open `/dev/rdiskN` (root:operator, mode 0640),
    /// so this has to go through the helper same as the mount itself.
    func probeReadWrite(
        ntfs3gProbeExecutablePath: String,
        devicePath: String,
        reply: @escaping @Sendable (HelperOperationResult) -> Void
    )

    func mountReadWrite(
        ntfs3gExecutablePath: String,
        devicePath: String,
        mountPath: String,
        options: String,
        reply: @escaping @Sendable (HelperOperationResult) -> Void
    )

    /// Full Disk Access is granted per-binary by the user in System Settings
    /// and can't be queried from any public API, so this asks the helper to
    /// try the one thing that actually needs it: opening a raw disk device.
    /// `Bool` crosses XPC as a plain scalar — no `setClasses` needed, unlike
    /// `HelperOperationResult`.
    func checkFullDiskAccess(reply: @escaping @Sendable (Bool) -> Void)
}

/// @unchecked Sendable: immutable (all `let`) after init, safe to hand across
/// the XPC/Task boundaries both sides need to cross to call `reply`.
///
/// `@objc(HelperOperationResult)` is required, not decorative: this source
/// file is compiled separately into both the `AppNTFS` and `AppNTFSHelper`
/// targets (plain shared sources, not a framework), so without an explicit
/// name Swift mangles the runtime class name with each target's own module
/// name (`AppNTFS.HelperOperationResult` vs `AppNTFSHelper.HelperOperation
/// Result`). NSXPCConnection decodes by exact class name, so the two sides
/// silently disagreed and every reply was rejected as "undecodable message"
/// — confirmed via `log stream` on real hardware.
@objc(HelperOperationResult) public final class HelperOperationResult: NSObject, NSSecureCoding, @unchecked Sendable {
    public static var supportsSecureCoding: Bool { true }

    public let exitCode: Int32
    public let standardOutput: String
    public let standardError: String

    public init(exitCode: Int32, standardOutput: String, standardError: String) {
        self.exitCode = exitCode
        self.standardOutput = standardOutput
        self.standardError = standardError
    }

    public required init?(coder: NSCoder) {
        exitCode = coder.decodeInt32(forKey: "exitCode")
        standardOutput = (coder.decodeObject(of: NSString.self, forKey: "standardOutput") as String?) ?? ""
        standardError = (coder.decodeObject(of: NSString.self, forKey: "standardError") as String?) ?? ""
    }

    public func encode(with coder: NSCoder) {
        coder.encode(exitCode, forKey: "exitCode")
        coder.encode(standardOutput as NSString, forKey: "standardOutput")
        coder.encode(standardError as NSString, forKey: "standardError")
    }
}

/// Single source of truth for building an `AppNTFSHelperProtocol` XPC
/// interface. `NSXPCInterface` requires `setClasses(...)` to be called
/// explicitly for every non-basic (custom) class that crosses the wire —
/// **on both ends of the connection independently** (the exported interface
/// in `HelperListenerDelegate` and the remote object interface in
/// `PrivilegedHelperMounter`). Building both from this one function is
/// deliberate: two hand-written copies previously drifted (the app side had
/// `setClasses`, the helper side didn't), which surfaced as an opaque
/// "undecodable message" XPC error only once a call actually reached the
/// reply stage.
public enum AppNTFSHelperXPC {
    public static func makeInterface() -> NSXPCInterface {
        let interface = NSXPCInterface(with: AppNTFSHelperProtocol.self)
        let resultClasses = NSSet(object: HelperOperationResult.self) as! Set<AnyHashable>
        interface.setClasses(
            resultClasses,
            for: #selector(AppNTFSHelperProtocol.probeReadWrite(ntfs3gProbeExecutablePath:devicePath:reply:)),
            argumentIndex: 0,
            ofReply: true
        )
        interface.setClasses(
            resultClasses,
            for: #selector(AppNTFSHelperProtocol.mountReadWrite(ntfs3gExecutablePath:devicePath:mountPath:options:reply:)),
            argumentIndex: 0,
            ofReply: true
        )
        return interface
    }
}
