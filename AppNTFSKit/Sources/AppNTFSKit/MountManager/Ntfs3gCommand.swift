import Foundation

/// Thin wrapper over the `ntfs-3g-mac` formula's binaries (tap
/// `gromgit/homebrew-fuse`; the plain homebrew-core `ntfs-3g` formula is
/// Linux-only and cannot be installed on macOS at all). Binaries are addressed
/// through `opt/ntfs-3g-mac/...`, Homebrew's stable per-formula symlink that
/// exists regardless of link state.
struct Ntfs3gCommand: PrivilegedMounting {
    private let runner: ProcessRunning
    private let binDirectory: String

    /// Primary initialiser: the directory holding the three binaries, already
    /// resolved by `DependencyChecker` to either the copies embedded in the app
    /// bundle or a Homebrew install.
    init(runner: ProcessRunning, binDirectory: String) {
        self.runner = runner
        self.binDirectory = binDirectory
    }

    /// Homebrew convenience form. `opt/ntfs-3g-mac` is Homebrew's stable
    /// per-formula symlink, present regardless of link state.
    init(runner: ProcessRunning, homebrewPrefix: String) {
        self.init(runner: runner, binDirectory: Self.homebrewBinDirectory(prefix: homebrewPrefix))
    }

    static func homebrewBinDirectory(prefix: String) -> String {
        "\(prefix)/opt/ntfs-3g-mac/bin"
    }

    var executablePath: String { "\(binDirectory)/ntfs-3g" }
    var probeExecutablePath: String { "\(binDirectory)/ntfs-3g.probe" }
    var fixExecutablePath: String { "\(binDirectory)/ntfsfix" }

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
        var options = ["windows_names", "auto_xattr", "local_lockfile"]
        let sanitized = Self.sanitizedVolumeName(volumeName)
        if !sanitized.isEmpty {
            options.insert("volname=\(sanitized)", at: 0)
        }
        return options.joined(separator: ",")
    }

    /// `ntfs-3g` parses `-o` as a comma-separated list, so a comma in the
    /// volume label would split into bogus (potentially privilege-widening)
    /// options; newlines / control characters have no place in a mount option
    /// either. `volname` only sets the Finder display name, so dropping those
    /// characters is a harmless cosmetic scrub — and the privileged helper
    /// rejects anything that slips through regardless (see
    /// `HelperRequestValidation`).
    static func sanitizedVolumeName(_ name: String) -> String {
        let disallowed = CharacterSet(charactersIn: ",")
            .union(.controlCharacters)
            .union(.newlines)
        return String(String.UnicodeScalarView(name.unicodeScalars.filter { !disallowed.contains($0) }))
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

    /// Arguments `ntfsfix` is always invoked with, on top of the device path.
    ///
    /// `-d` is not optional here. `ntfsfix` rewrites the dirty flag on every
    /// run and the flag it writes is chosen by this branch (ntfsfix.c):
    ///
    ///     if (opt.clear_dirty) vol->flags &= ~VOLUME_IS_DIRTY;
    ///     else                 vol->flags |=  VOLUME_IS_DIRTY;
    ///     ntfs_volume_write_flags(vol, vol->flags);
    ///
    /// So without `-d` the "repair and retry" flow *marks the volume dirty* —
    /// the exact condition that makes `ntfs-3g` refuse a read-write mount, and
    /// the most common reason a user reaches for repair in the first place.
    /// The repair itself (`fix_mount`, `check_alternate_boot`) runs either
    /// way, so `-d` only ever adds the flag clear.
    ///
    /// A volume left dirty by Windows *hibernation* is a different problem
    /// that `ntfsfix` cannot solve at all — that needs the `remove_hiberfile`
    /// mount option or a full Windows shutdown.
    ///
    /// Kept in sync with `HelperService.fix`, which rebuilds this list
    /// helper-side: the app sends only paths over XPC, never arguments, so the
    /// helper can never be talked into running `ntfsfix` with attacker-chosen
    /// flags.
    static let fixArguments = ["-d"]

    /// `PrivilegedMounting` conformance used only when no privileged helper is
    /// configured (unit tests, mainly) — real fixes always go through
    /// `PrivilegedHelperMounter` (AppNTFS/Helper/), same reasoning as
    /// `probeReadWrite`/`mountReadWrite`.
    func fix(ntfsfixExecutablePath: String, devicePath: String) async throws -> ProcessResult {
        try await runner.run(
            executable: ntfsfixExecutablePath,
            arguments: Self.fixArguments + [devicePath]
        )
    }
}
