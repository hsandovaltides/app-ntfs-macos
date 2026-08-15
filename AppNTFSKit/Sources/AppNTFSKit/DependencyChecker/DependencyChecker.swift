import Foundation
import ServiceManagement

public enum InstallState: Sendable, Equatable {
    case notInstalled
    case installedPendingApproval
    case installedAndApproved
}

public struct DependencyStatus: Sendable, Equatable {
    public let homebrewPrefix: String?
    public let ntfs3gInstalled: Bool
    public let macFUSEState: InstallState
    public let helperState: InstallState
    /// Full Disk Access for the helper *binary* specifically — a separate,
    /// one-time TCC grant that being root doesn't substitute for (confirmed
    /// on real hardware: `EPERM` opening `/dev/rdiskN` from the root helper
    /// until its exact path was added to Privacy & Security → Full Disk
    /// Access). Defaults to `true` when unset/unchecked (e.g. no
    /// `FullDiskAccessProbing` wired in, as in tests) rather than blocking
    /// on a check that couldn't run.
    public let fullDiskAccessGranted: Bool

    public var isReady: Bool {
        homebrewPrefix != nil
            && ntfs3gInstalled
            && macFUSEState == .installedAndApproved
            && helperState == .installedAndApproved
            && fullDiskAccessGranted
    }

    public init(
        homebrewPrefix: String?,
        ntfs3gInstalled: Bool,
        macFUSEState: InstallState,
        helperState: InstallState,
        fullDiskAccessGranted: Bool = true
    ) {
        self.homebrewPrefix = homebrewPrefix
        self.ntfs3gInstalled = ntfs3gInstalled
        self.macFUSEState = macFUSEState
        self.helperState = helperState
        self.fullDiskAccessGranted = fullDiskAccessGranted
    }
}

/// Full Disk Access can only be checked by asking the helper to try opening
/// a raw disk device (see `DependencyStatus.fullDiskAccessGranted`), which
/// means XPC — outside what `AppNTFSKit` (plain Foundation, no XPC) can do
/// itself. `AppNTFS/Helper/PrivilegedHelperMounter` is the real
/// implementation, injected from the app target.
public protocol FullDiskAccessProbing: Sendable {
    func hasFullDiskAccess() async -> Bool
}

/// Thin seam over SMAppService so DependencyChecker can be unit tested
/// without a real LaunchDaemon registered on the test machine.
public protocol HelperServiceStatusProbing: Sendable {
    func status(forPlistName plistName: String) -> InstallState
}

public struct DefaultHelperServiceStatusProbe: HelperServiceStatusProbing {
    public init() {}

    public func status(forPlistName plistName: String) -> InstallState {
        switch SMAppService.daemon(plistName: plistName).status {
        case .enabled:
            return .installedAndApproved
        case .requiresApproval:
            return .installedPendingApproval
        case .notRegistered, .notFound:
            return .notInstalled
        @unknown default:
            return .installedPendingApproval
        }
    }
}

/// Thin seam over filesystem probes so DependencyChecker can be unit tested
/// without depending on Homebrew/macFUSE actually being installed on the
/// machine running the tests.
public protocol FileSystemProbing: Sendable {
    func fileExists(atPath path: String) -> Bool
    func isExecutableFile(atPath path: String) -> Bool
}

public struct DefaultFileSystemProbe: FileSystemProbing {
    public init() {}
    public func fileExists(atPath path: String) -> Bool { FileManager.default.fileExists(atPath: path) }
    public func isExecutableFile(atPath path: String) -> Bool { FileManager.default.isExecutableFile(atPath: path) }
}

extension DependencyStatus: CustomStringConvertible {
    public var description: String {
        "homebrew=\(homebrewPrefix ?? "missing") ntfs3g=\(ntfs3gInstalled) macFUSE=\(macFUSEState) helper=\(helperState) fullDiskAccess=\(fullDiskAccessGranted)"
    }
}

public struct DependencyChecker: Sendable {
    /// Apple Silicon vs Intel Homebrew prefixes; checked in order at runtime
    /// rather than picked via #if arch(), since the binary could run under
    /// Rosetta or the user could have a non-default prefix.
    static let knownHomebrewPrefixes = ["/opt/homebrew", "/usr/local"]

    /// Must match `AppNTFSHelperProtocol.helperLaunchDaemonPlistName`. Kept as
    /// a literal here (not a shared import) because AppNTFSKit is a
    /// standalone SPM package and AppNTFSHelperProtocol is plain sources
    /// compiled directly into the app/helper Xcode targets — the two build
    /// systems don't share modules.
    static let helperLaunchDaemonPlistName = "com.appntfs.app.helper.plist"

    private let runner: ProcessRunning
    private let fileSystem: FileSystemProbing
    private let helperStatusProbe: HelperServiceStatusProbing
    private let fullDiskAccessProbe: FullDiskAccessProbing?

    public init(
        runner: ProcessRunning = ProcessRunner(),
        fileSystem: FileSystemProbing = DefaultFileSystemProbe(),
        helperStatusProbe: HelperServiceStatusProbing = DefaultHelperServiceStatusProbe(),
        fullDiskAccessProbe: FullDiskAccessProbing? = nil
    ) {
        self.runner = runner
        self.fileSystem = fileSystem
        self.helperStatusProbe = helperStatusProbe
        self.fullDiskAccessProbe = fullDiskAccessProbe
    }

    public func checkAll() async -> DependencyStatus {
        let prefix = homebrewPrefix()
        return DependencyStatus(
            homebrewPrefix: prefix,
            ntfs3gInstalled: ntfs3gIsInstalled(homebrewPrefix: prefix),
            macFUSEState: await macFUSEInstallState(homebrewPrefix: prefix),
            helperState: helperStatusProbe.status(forPlistName: Self.helperLaunchDaemonPlistName),
            fullDiskAccessGranted: await fullDiskAccessProbe?.hasFullDiskAccess() ?? true
        )
    }

    func homebrewPrefix() -> String? {
        Self.knownHomebrewPrefixes.first { fileSystem.isExecutableFile(atPath: "\($0)/bin/brew") }
    }

    func ntfs3gIsInstalled(homebrewPrefix: String?) -> Bool {
        guard let homebrewPrefix else { return false }
        // ntfs-3g on macOS ships from the `gromgit/homebrew-fuse` tap as the
        // `ntfs-3g-mac` formula (the plain `ntfs-3g` homebrew-core formula is
        // Linux-only). Homebrew always maintains a stable `opt/<formula>` symlink
        // regardless of link state, so probe that rather than `bin/` directly.
        return fileSystem.isExecutableFile(atPath: "\(homebrewPrefix)/opt/ntfs-3g-mac/bin/ntfs-3g")
    }

    func macFUSEInstallState(homebrewPrefix: String?) async -> InstallState {
        let caskInstalled = fileSystem.fileExists(atPath: "/Library/Filesystems/macfuse.fs")
            || (homebrewPrefix.map { fileSystem.fileExists(atPath: "\($0)/Caskroom/macfuse") } ?? false)

        guard caskInstalled else { return .notInstalled }

        // The kext backend is loaded is the strongest available signal that
        // macFUSE is approved and working (see KextInspector's doc comment
        // for why there's no direct "approved but idle" check). Checked
        // first since it's the backend this app actually uses; falls back to
        // the System Extensions check for the (currently unused) FSKit path.
        if await KextInspector.macFUSEIsLoaded(using: runner) {
            return .installedAndApproved
        }

        switch await SystemExtensionInspector.macFUSEApprovalState(using: runner) {
        case .approved:
            return .installedAndApproved
        case .pendingApproval, .notPresent:
            return .installedPendingApproval
        }
    }
}
