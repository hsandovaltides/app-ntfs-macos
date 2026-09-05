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
/// So the helper only ever executes one of three known Homebrew binaries,
/// only against a `/dev/diskN…` node, only mounting under `/Volumes/`, and
/// only with mount options drawn from a fixed key set.
public enum HelperRequestValidation {
    /// Apple Silicon and Intel Homebrew prefixes — must match
    /// `DependencyChecker.knownHomebrewPrefixes`.
    static let allowedHomebrewPrefixes = ["/opt/homebrew", "/usr/local"]

    /// The only executables the helper will ever spawn (basename match). All
    /// three ship from the `gromgit/homebrew-fuse` `ntfs-3g-mac` formula.
    static let allowedExecutableNames: Set<String> = ["ntfs-3g", "ntfs-3g.probe", "ntfsfix"]

    /// Mount option keys `Ntfs3gCommand.mountOptions(volumeName:)` is allowed
    /// to produce. Anything else (`rw`, `allow_other`, `uid=`, …) is rejected
    /// so a tampered option string can't widen the mount's exposure.
    static let allowedMountOptionKeys: Set<String> = [
        "volname", "windows_names", "auto_xattr", "local_lockfile"
    ]

    /// A Homebrew-managed `ntfs-3g-mac` binary path: absolute, no `..`
    /// traversal, under a known prefix, with an allow-listed basename.
    public static func isValidExecutablePath(_ path: String) -> Bool {
        guard path.hasPrefix("/"), !pathContainsTraversal(path) else { return false }
        guard allowedExecutableNames.contains((path as NSString).lastPathComponent) else { return false }
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
    /// allow-list. Empty option strings are rejected.
    public static func isValidMountOptions(_ options: String) -> Bool {
        let tokens = options.split(separator: ",", omittingEmptySubsequences: false)
        guard !tokens.isEmpty else { return false }
        return tokens.allSatisfy { token in
            let key = token.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)[0]
            return allowedMountOptionKeys.contains(String(key))
        }
    }

    private static func pathContainsTraversal(_ path: String) -> Bool {
        path.split(separator: "/", omittingEmptySubsequences: false).contains("..")
    }
}
