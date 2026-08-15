import Foundation

/// Thin wrapper over the `ntfs-3g-mac` formula's binaries (tap
/// `gromgit/homebrew-fuse`; the plain homebrew-core `ntfs-3g` formula is
/// Linux-only and cannot be installed on macOS at all). Binaries are addressed
/// through `opt/ntfs-3g-mac/...`, Homebrew's stable per-formula symlink that
/// exists regardless of link state.
struct Ntfs3gCommand: PrivilegedMounting {
    private let runner: ProcessRunning
    private let homebrewPrefix: String

    init(runner: ProcessRunning, homebrewPrefix: String) {
        self.runner = runner
        self.homebrewPrefix = homebrewPrefix
    }

    private var optDirectory: String { "\(homebrewPrefix)/opt/ntfs-3g-mac" }
    private var binDirectory: String { "\(optDirectory)/bin" }

    var executablePath: String { "\(binDirectory)/ntfs-3g" }
    var probeExecutablePath: String { "\(binDirectory)/ntfs-3g.probe" }

    /// Uses macFUSE's classic kext backend (the default when `backend=fskit`
    /// is omitted). FSKit was tried first to avoid the Recovery Mode "reduced
    /// security" toggle, but its file-system-extension registration is
    /// unreliable on current macOS/macFUSE builds (confirmed via hands-on
    /// testing and macfuse/macfuse#1071 — PluginKit sometimes never surfaces
    /// the approval prompt) and it carries more active limitations besides
    /// (mountpoints restricted to /Volumes, no traditional mount options,
    /// files always opened read/write). The kext path needs the one-time
    /// Recovery Mode toggle documented in the README, but is otherwise the
    /// proven, fully-working backend. `allow_other`/uid/gid overrides are
    /// intentionally omitted — the mount is only ever accessed by the
    /// logged-in user anyway.
    func mountOptions(volumeName: String) -> String {
        "volname=\(volumeName),windows_names,auto_xattr,local_lockfile"
    }

    /// `PrivilegedMounting` conformance used only when no privileged helper is
    /// configured (unit tests, mainly). In practice reading the raw disk
    /// device requires root ("Permission denied" as a regular user — see
    /// `PrivilegedMounting`'s doc comment), so real probes always go through
    /// `PrivilegedHelperMounter` (AppNTFS/Helper/) — see MountManager.
    func probeReadWrite(ntfs3gProbeExecutablePath: String, devicePath: String) async throws -> Bool {
        let result = try await runner.run(
            executable: ntfs3gProbeExecutablePath,
            arguments: ["--readwrite", devicePath]
        )
        return result.succeeded
    }

    /// `PrivilegedMounting` conformance used only when no privileged helper is
    /// configured (unit tests, mainly). In practice `ntfs-3g` refuses to mount
    /// NTFS block devices as a non-root user ("Unprivileged user can not mount
    /// NTFS..."), so real mounts always go through `PrivilegedHelperMounter`
    /// (AppNTFS/Helper/) — see MountManager.
    func mountReadWrite(
        ntfs3gExecutablePath: String,
        devicePath: String,
        mountPath: String,
        options: String
    ) async throws -> ProcessResult {
        try await runner.run(executable: ntfs3gExecutablePath, arguments: [devicePath, mountPath, "-o", options])
    }

    @discardableResult
    func fix(devicePath: String) async throws -> ProcessResult {
        try await runner.run(executable: "\(binDirectory)/ntfsfix", arguments: [devicePath])
    }
}
