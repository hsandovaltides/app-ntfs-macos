import Foundation
import ServiceManagement

public enum InstallState: Sendable, Equatable {
    case notInstalled
    case installedPendingApproval
    case installedAndApproved
}

public struct DependencyStatus: Sendable, Equatable {
    public let homebrewPrefix: String?
    /// Directory holding `ntfs-3g`, `ntfs-3g.probe` and `ntfsfix` — the copies
    /// embedded in the app bundle when they're there, otherwise a Homebrew
    /// install. `nil` means neither was found.
    ///
    /// Stored rather than derived from `homebrewPrefix` because those two facts
    /// came apart once the binaries ship inside the app: ntfs-3g can now be
    /// present with no Homebrew at all.
    public let ntfs3gBinDirectory: String?
    public let macFUSEState: InstallState
    public let helperState: InstallState
    /// Full Disk Access for the helper *binary* specifically — a separate,
    /// one-time TCC grant that being root doesn't substitute for (confirmed
    /// on real hardware: `EPERM` opening `/dev/rdiskN` from the root helper
    /// until its exact path was added to Privacy & Security → Full Disk
    /// Access). Defaults to `true` when unset/unchecked (e.g. no
    /// `FullDiskAccessProbing` wired in, as in tests; or the helper not yet
    /// approved, so there's nothing to ask) rather than blocking on a check
    /// that couldn't run.
    public let fullDiskAccessGranted: Bool
    /// Whether macFUSE's FSKit backend is worth attempting — macOS 15.4+ with
    /// macFUSE's file-system extension present on disk. See
    /// `FuseBackendAvailability`, which deliberately does *not* try to
    /// establish that the extension is switched on.
    public let fskitBackendAvailable: Bool

    /// Whether ntfs-3g was found anywhere. Homebrew is no longer implied — see
    /// `ntfs3gBinDirectory`.
    public var ntfs3gInstalled: Bool { ntfs3gBinDirectory != nil }

    /// Backends the mount pipeline should try, in order.
    ///
    /// FSKit first when it's plausible: it needs no kext, so it works on a
    /// machine where the user never went near Recovery Mode. The kext stays
    /// last as the proven fallback — it is attempted whether or not FSKit was,
    /// because "FSKit plausible" is not "FSKit enabled".
    public var mountBackends: [FuseBackend] {
        fskitBackendAvailable ? [.fskit, .kext] : [.kext]
    }

    /// macFUSE's kext approval is only a *requirement* when the kext is the
    /// only way in. With FSKit available, an installed-but-unapproved macFUSE
    /// is a perfectly workable install — demanding approval there would send
    /// the user to Recovery Mode for a backend the app is not going to use,
    /// which is the entire thing nivel 1 removes.
    ///
    /// It is still only "plausible", so this can let a mount through that then
    /// fails on both backends. That is the right trade: the failure is a
    /// recoverable one the pipeline reports (and falls back to read-only
    /// from), whereas an over-strict gate is a volume the app refuses to touch
    /// on a machine where it would have worked.
    public var macFUSEUsable: Bool {
        fskitBackendAvailable ? macFUSEState != .notInstalled : macFUSEState == .installedAndApproved
    }

    /// Homebrew is deliberately absent from this list. It is a delivery
    /// mechanism for ntfs-3g, not a requirement of its own, and with the
    /// binaries embedded a machine with no Homebrew is a perfectly ready one.
    public var isReady: Bool {
        ntfs3gInstalled
            && macFUSEUsable
            && helperState == .installedAndApproved
            && fullDiskAccessGranted
    }

    public init(
        homebrewPrefix: String?,
        ntfs3gBinDirectory: String?,
        macFUSEState: InstallState,
        helperState: InstallState,
        fullDiskAccessGranted: Bool = true,
        fskitBackendAvailable: Bool = false
    ) {
        self.homebrewPrefix = homebrewPrefix
        self.ntfs3gBinDirectory = ntfs3gBinDirectory
        self.macFUSEState = macFUSEState
        self.helperState = helperState
        self.fullDiskAccessGranted = fullDiskAccessGranted
        self.fskitBackendAvailable = fskitBackendAvailable
    }

    /// Homebrew-flavoured form: "installed" means installed *by Homebrew*, at
    /// the canonical `opt/ntfs-3g-mac/bin` location under the given prefix.
    public init(
        homebrewPrefix: String?,
        ntfs3gInstalled: Bool,
        macFUSEState: InstallState,
        helperState: InstallState,
        fullDiskAccessGranted: Bool = true,
        fskitBackendAvailable: Bool = false
    ) {
        self.init(
            homebrewPrefix: homebrewPrefix,
            ntfs3gBinDirectory: (ntfs3gInstalled ? homebrewPrefix : nil)
                .map(Ntfs3gCommand.homebrewBinDirectory(prefix:)),
            macFUSEState: macFUSEState,
            helperState: helperState,
            fullDiskAccessGranted: fullDiskAccessGranted,
            fskitBackendAvailable: fskitBackendAvailable
        )
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
        "homebrew=\(homebrewPrefix ?? "missing") ntfs3g=\(ntfs3gBinDirectory ?? "missing") macFUSE=\(macFUSEState) helper=\(helperState) fullDiskAccess=\(fullDiskAccessGranted) backends=\(mountBackends.map(\.rawValue).joined(separator: ">"))"
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

    /// How long `cachedStatus()` may reuse a previous probe.
    ///
    /// A full check is not cheap: `macFUSEInstallState` shells out to
    /// `kmutil showloaded`, which routinely takes seconds, and the Full Disk
    /// Access probe is an XPC round trip to the helper. `MountManager` runs
    /// one check *per volume*, so plugging in a drive with several NTFS
    /// partitions paid that cost once per partition.
    ///
    /// Ten seconds is safe because dependency state only changes through
    /// deliberate user action — a `brew install`, a toggle in System Settings
    /// — and every one of those paths ends at the "Recomprobar" button, which
    /// calls `checkAll()` and refreshes the cache outright.
    public static let defaultCacheTTL: TimeInterval = 10

    /// Reference-type box so the cache survives the value-semantics copies a
    /// `Sendable` struct undergoes when captured across tasks: every copy of a
    /// given `DependencyChecker` shares one cache, while two separately
    /// constructed checkers (the app coordinator's and `MountManager`'s) stay
    /// independent, as they were before.
    private final class StatusCache: @unchecked Sendable {
        private let lock = NSLock()
        private var value: DependencyStatus?
        private var storedAt: Date?

        func read(ttl: TimeInterval, now: Date) -> DependencyStatus? {
            lock.lock()
            defer { lock.unlock() }
            guard let value, let storedAt, now.timeIntervalSince(storedAt) < ttl else { return nil }
            return value
        }

        func write(_ status: DependencyStatus, at now: Date) {
            lock.lock()
            defer { lock.unlock() }
            value = status
            storedAt = now
        }
    }

    private let runner: ProcessRunning
    private let fileSystem: FileSystemProbing
    private let helperStatusProbe: HelperServiceStatusProbing
    private let fullDiskAccessProbe: FullDiskAccessProbing?
    private let bundledBinariesDirectory: String?
    private let cacheTTL: TimeInterval
    /// Injectable so the FSKit branch can be exercised from a test regardless
    /// of the macOS version the tests happen to run on — the one input to
    /// `fskitIsPlausible` a fake filesystem can't stand in for.
    private let operatingSystemIsAtLeast: @Sendable (OperatingSystemVersion) -> Bool
    private let cache = StatusCache()

    public init(
        runner: ProcessRunning = ProcessRunner(),
        fileSystem: FileSystemProbing = DefaultFileSystemProbe(),
        helperStatusProbe: HelperServiceStatusProbing = DefaultHelperServiceStatusProbe(),
        fullDiskAccessProbe: FullDiskAccessProbing? = nil,
        bundledBinariesDirectory: String? = BundledNtfs3g.runningHostDirectory,
        cacheTTL: TimeInterval = DependencyChecker.defaultCacheTTL,
        operatingSystemIsAtLeast: @escaping @Sendable (OperatingSystemVersion) -> Bool = {
            ProcessInfo.processInfo.isOperatingSystemAtLeast($0)
        }
    ) {
        self.runner = runner
        self.fileSystem = fileSystem
        self.helperStatusProbe = helperStatusProbe
        self.fullDiskAccessProbe = fullDiskAccessProbe
        self.bundledBinariesDirectory = bundledBinariesDirectory
        self.cacheTTL = cacheTTL
        self.operatingSystemIsAtLeast = operatingSystemIsAtLeast
    }

    /// Always re-probes, and refreshes the cache `cachedStatus()` reads.
    ///
    /// This is what the user's explicit "Recomprobar" drives, so a recheck
    /// taken right after changing something in System Settings can never be
    /// answered from a stale entry.
    public func checkAll() async -> DependencyStatus {
        let status = await probeAll()
        cache.write(status, at: Date())
        return status
    }

    /// Cached variant for the mount path, where the same status is needed once
    /// per volume and cannot meaningfully differ between partitions of the
    /// same drive.
    ///
    /// Two concurrent misses can both probe. That is deliberate: the probes are
    /// read-only and idempotent, the only cost is a duplicated check, and
    /// single-flighting would mean making this an actor for no real benefit —
    /// the one hot caller, `MountManager`, is already an actor and serializes
    /// its own calls.
    public func cachedStatus() async -> DependencyStatus {
        if let cached = cache.read(ttl: cacheTTL, now: Date()) { return cached }
        return await checkAll()
    }

    private func probeAll() async -> DependencyStatus {
        let prefix = homebrewPrefix()
        let helperState = helperStatusProbe.status(forPlistName: Self.helperLaunchDaemonPlistName)
        return DependencyStatus(
            homebrewPrefix: prefix,
            ntfs3gBinDirectory: ntfs3gBinDirectory(homebrewPrefix: prefix),
            macFUSEState: await macFUSEInstallState(homebrewPrefix: prefix),
            helperState: helperState,
            fullDiskAccessGranted: await fullDiskAccessGranted(helperState: helperState),
            fskitBackendAvailable: FuseBackendAvailability.fskitIsPlausible(
                fileSystem: fileSystem,
                operatingSystemIsAtLeast: operatingSystemIsAtLeast
            )
        )
    }

    /// The FDA probe works by asking the helper to open a raw disk device, so
    /// it's only meaningful once the helper is installed and approved. Before
    /// that, the call is guaranteed to fail for an unrelated reason (no
    /// approved daemon to answer) — treating that as "FDA missing" would show
    /// a spurious banner on top of the "approve the helper" one. `true` here
    /// just defers the check; `helperState` already gates readiness.
    private func fullDiskAccessGranted(helperState: InstallState) async -> Bool {
        guard let fullDiskAccessProbe, helperState == .installedAndApproved else { return true }
        return await fullDiskAccessProbe.hasFullDiskAccess()
    }

    func homebrewPrefix() -> String? {
        Self.knownHomebrewPrefixes.first { fileSystem.isExecutableFile(atPath: "\($0)/bin/brew") }
    }

    /// Where ntfs-3g lives, preferring the copies embedded in the app bundle.
    ///
    /// Bundled first because it's the only location the user cannot break: it
    /// ships with the app, is signed with it, and needs no tap, no `brew link`
    /// and no `PATH`. Homebrew stays as the fallback so an install predating
    /// the embedded binaries — or a build where the embed step didn't run —
    /// keeps working unchanged.
    func ntfs3gBinDirectory(homebrewPrefix: String?) -> String? {
        // All three binaries are required here, unlike the Homebrew branch
        // below: this directory is our own build output, so a partial copy is
        // a broken embed step rather than a user's install choice, and falling
        // through to Homebrew is a better outcome than mounting with a
        // half-present toolchain.
        if let bundledBinariesDirectory,
           HelperRequestValidation.allowedExecutableNames.allSatisfy({
               fileSystem.isExecutableFile(atPath: "\(bundledBinariesDirectory)/\($0)")
           }) {
            return bundledBinariesDirectory
        }

        // ntfs-3g on macOS ships from the `gromgit/homebrew-fuse` tap as the
        // `ntfs-3g-mac` formula (the plain `ntfs-3g` homebrew-core formula is
        // Linux-only). Homebrew always maintains a stable `opt/<formula>` symlink
        // regardless of link state, so probe that rather than `bin/` directly.
        guard let homebrewPrefix else { return nil }
        let directory = Ntfs3gCommand.homebrewBinDirectory(prefix: homebrewPrefix)
        return fileSystem.isExecutableFile(atPath: "\(directory)/ntfs-3g") ? directory : nil
    }

    func macFUSEInstallState(homebrewPrefix: String?) async -> InstallState {
        let caskInstalled = fileSystem.fileExists(atPath: "/Library/Filesystems/macfuse.fs")
            || (homebrewPrefix.map { fileSystem.fileExists(atPath: "\($0)/Caskroom/macfuse") } ?? false)

        guard caskInstalled else { return .notInstalled }

        // A loaded kext is the strongest available signal that macFUSE is
        // approved and working (see KextInspector's doc comment for why
        // there's no direct "approved but idle" check).
        //
        // Note this only ever describes the *kext* backend. FSKit needs none
        // of it, which is why `macFUSEUsable` stops requiring
        // `.installedAndApproved` once `fskitBackendAvailable` is true — a
        // machine using FSKit will sit at `.installedPendingApproval` forever
        // and be perfectly functional.
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
