import Foundation

/// Validates the raw parameters the app sends to the privileged helper over
/// XPC before the helper — running as root — acts on them.
///
/// The helper's code-signature check (`HelperListenerDelegate`) already
/// guarantees the *connecting process* is `AppNTFS.app`. This is the second
/// layer: even assuming the caller is our app, the helper must not be a
/// general "run this binary as root" primitive. `AppNTFS` is not sandboxed
/// and (on a free/personal team) not notarized, so code injected into the app
/// would otherwise reach `fix(ntfsfixExecutablePath:…)` / `probeReadWrite`
/// and run an arbitrary executable as root with an attacker-chosen argument.
///
/// So the helper only ever executes one of three known ntfs-3g binaries, only
/// against a `/dev/diskN…` node, only mounting under `/Volumes/`, and only
/// with mount options drawn from a fixed key set.
///
/// Those binaries may live in the app bundle's `Contents/Helpers` (the copies
/// `Scripts/embed-ntfs-3g.sh` puts there) or under a Homebrew prefix. Neither
/// location is one the helper takes from the request: Homebrew's is a
/// hardcoded list, and the bundle's is derived from the helper's *own*
/// executable path (`BundledNtfs3g.runningHostDirectory`).
///
/// The bundled rule is the tighter of the two, which is worth being explicit
/// about since it is the newer one. `/opt/homebrew` is owned by the invoking
/// user on Apple Silicon — anyone who can write there could already swap the
/// binary this helper runs as root, and that has been true since the
/// allow-list was written. `Contents/Helpers` sits inside a signed bundle
/// that `SMAppService` requires to be in `/Applications`, so writing to it
/// needs admin rights the attacker would not otherwise have. It is also
/// matched as an exact directory rather than a prefix.
public enum HelperRequestValidation {
    /// Apple Silicon and Intel Homebrew prefixes — must match
    /// `DependencyChecker.knownHomebrewPrefixes`.
    static let allowedHomebrewPrefixes = ["/opt/homebrew", "/usr/local"]

    /// The only executables the helper will ever spawn (basename match). All
    /// three ship from the `gromgit/homebrew-fuse` `ntfs-3g-mac` formula.
    static let allowedExecutableNames: Set<String> = ["ntfs-3g", "ntfs-3g.probe", "ntfsfix"]

    /// Mount option keys `Ntfs3gCommand.mountOptions(volumeName:backend:)` is
    /// allowed to produce. Anything else (`rw`, `allow_other`, `uid=`, …) is
    /// rejected so a tampered option string can't widen the mount's exposure.
    static let allowedMountOptionKeys: Set<String> = [
        "volname", "windows_names", "auto_xattr", "local_lockfile", "backend"
    ]

    /// Keys whose *value* is constrained too, and to what.
    ///
    /// `backend` selects which macFUSE implementation performs the mount, so
    /// unlike `volname` — a display string — its value decides what code runs.
    /// Allow-listing the key alone would have let a tampered option string
    /// name any backend macFUSE might grow, present or future, which is
    /// exactly the kind of open-ended choice this type exists to prevent. The
    /// kext backend is the default and carries no token, so `fskit` is the
    /// only value the app ever sends.
    ///
    /// A key listed here must appear as `key=value`; the bare `key` form is
    /// rejected, since "no value" is not in the allowed set.
    static let allowedMountOptionValues: [String: Set<String>] = [
        "backend": [FuseBackend.fskit.rawValue]
    ]

    /// An `ntfs-3g-mac` binary path the helper is willing to execute: absolute,
    /// no `..` traversal, an allow-listed basename, and located either in the
    /// app bundle's own `Contents/Helpers` or under a known Homebrew prefix.
    ///
    /// The bundled directory is resolved from the *running* executable
    /// (`BundledNtfs3g.runningHostDirectory`), never from the request — so
    /// accepting bundled paths does not let a caller nominate a directory. It
    /// is also matched exactly rather than by prefix, which is tighter than
    /// the Homebrew rule below.
    public static func isValidExecutablePath(_ path: String) -> Bool {
        isValidExecutablePath(path, bundledBinariesDirectory: BundledNtfs3g.runningHostDirectory)
    }

    /// Testable form of `isValidExecutablePath(_:)` with the bundled directory
    /// supplied explicitly, since a test binary is not inside an app bundle
    /// and would otherwise only ever exercise the Homebrew branch.
    public static func isValidExecutablePath(
        _ path: String,
        bundledBinariesDirectory: String?
    ) -> Bool {
        guard path.hasPrefix("/"), !pathContainsTraversal(path) else { return false }
        guard allowedExecutableNames.contains((path as NSString).lastPathComponent) else { return false }
        if let bundledBinariesDirectory,
           (path as NSString).deletingLastPathComponent == bundledBinariesDirectory {
            return true
        }
        return allowedHomebrewPrefixes.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    /// A whole-disk or partition device node: `/dev/disk3`, `/dev/disk3s1`,
    /// `/dev/rdisk3s1`. Rules out paths, `..`, and non-disk device nodes.
    public static func isValidDevicePath(_ path: String) -> Bool {
        path.range(of: #"^/dev/r?disk[0-9]+(s[0-9]+)*$"#, options: .regularExpression) != nil
    }

    /// A single directory directly under `/Volumes/` (where macOS mounts
    /// removable media). No nesting, no `..`, non-empty leaf.
    public static func isValidMountPath(_ path: String) -> Bool {
        let prefix = "/Volumes/"
        guard path.hasPrefix(prefix), !pathContainsTraversal(path) else { return false }
        let leaf = String(path.dropFirst(prefix.count))
        return !leaf.isEmpty && !leaf.contains("/")
    }

    /// Every comma-separated token is `key` or `key=value` with `key` in the
    /// allow-list — and, for the keys in `allowedMountOptionValues`, with the
    /// value in that key's set too. Empty option strings are rejected.
    public static func isValidMountOptions(_ options: String) -> Bool {
        let tokens = options.split(separator: ",", omittingEmptySubsequences: false)
        guard !tokens.isEmpty else { return false }
        return tokens.allSatisfy { token in
            let parts = token.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let key = String(parts[0])
            guard allowedMountOptionKeys.contains(key) else { return false }
            guard let allowedValues = allowedMountOptionValues[key] else { return true }
            // `parts.count == 1` is the bare `key` form, which has no value to
            // check against the set — so it fails, rather than slipping past a
            // constraint that only inspects `key=value`.
            guard parts.count == 2 else { return false }
            return allowedValues.contains(String(parts[1]))
        }
    }

    private static func pathContainsTraversal(_ path: String) -> Bool {
        path.split(separator: "/", omittingEmptySubsequences: false).contains("..")
    }
}
