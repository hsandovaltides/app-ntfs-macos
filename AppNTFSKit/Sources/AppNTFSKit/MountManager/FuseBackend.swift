import Foundation

/// Which of macFUSE's two backends a mount goes through.
///
/// This is the whole point of "nivel 1": the kext backend is what forces the
/// two manual steps this app cannot automate away — booting into Recovery Mode
/// to lower the security policy, and approving a kernel extension in System
/// Settings, each followed by a restart. The FSKit backend runs the same
/// `ntfs-3g` binary entirely in user space, so neither is needed.
///
/// Both are selected purely by a mount option, on the *stock* binaries: the
/// `ntfs-3g` from `gromgit/homebrew-fuse` links `libfuse.2.dylib` and
/// nonetheless accepts `-o backend=fskit`, which macFUSE's libfuse2 forwards
/// to `MFMount`. That is worth stating because it contradicts both the obvious
/// reading of macFUSE's 5.1.0 release notes ("only supported with libfuse3")
/// and the assumption that nivel 1 required rebuilding ntfs-3g against
/// `fuse-t`. Verified by running the mount and watching it reach
/// `MFMount(_:_:_:_:)` — see `README`'s "Backends de FUSE" section.
public enum FuseBackend: String, Sendable, CaseIterable {
    /// macFUSE's FSKit file-system extension. No kernel extension, therefore
    /// no Recovery Mode and no restart — the user enables one toggle in
    /// System Settings and that is the entire setup.
    ///
    /// Needs macOS 15.4+ (when FSKit shipped) and a macFUSE new enough to
    /// carry the extension.
    case fskit

    /// macFUSE's classic kernel extension: the historical backend, and still
    /// the fallback whenever FSKit isn't usable.
    case kext

    /// The `-o` token that selects this backend, or `nil` when it is the
    /// default and naming it would only risk an "unknown option" from an older
    /// macFUSE.
    var mountOptionToken: String? {
        switch self {
        case .fskit: return "backend=\(rawValue)"
        case .kext: return nil
        }
    }
}

/// Decides whether the FSKit backend is worth attempting on this machine.
///
/// Deliberately a *cheap, local* check rather than a real "is it enabled"
/// query: whether the extension is actually switched on lives behind FSKit's
/// own enablement store, and even `pluginkit` reporting it as enabled is not
/// sufficient — a mount can still come back with "File system extension not
/// enabled" (observed on macFUSE 5.3.3 / macOS 26.6.2). So this answers the
/// narrower question "could FSKit plausibly work here?", and the mount
/// pipeline settles the rest by trying it and falling back.
public enum FuseBackendAvailability {
    /// macFUSE ships its FSKit module as an app extension inside the
    /// `macfuse.app` that lives in the installed filesystem bundle.
    public static let macFUSEExtensionsDirectory =
        "/Library/Filesystems/macfuse.fs/Contents/Resources/macfuse.app/Contents/Extensions"

    /// The bundle identifier macFUSE gives its FSKit module. Versioned by
    /// macFUSE, so probed as a directory listing prefix rather than an exact
    /// path would be — but `fileExists` is all `FileSystemProbing` offers, so
    /// the known name is checked directly and a rename simply degrades to the
    /// kext backend rather than breaking anything.
    static let macFUSEFSKitExtensionName = "io.macfuse.app.fsmodule.macfuse.appex"

    /// FSKit itself shipped in macOS 15.4; macFUSE's module cannot load on
    /// anything older regardless of what is installed.
    static let minimumOperatingSystemVersion = OperatingSystemVersion(
        majorVersion: 15, minorVersion: 4, patchVersion: 0
    )

    public static func fskitIsPlausible(
        fileSystem: FileSystemProbing,
        operatingSystemIsAtLeast: (OperatingSystemVersion) -> Bool = {
            ProcessInfo.processInfo.isOperatingSystemAtLeast($0)
        }
    ) -> Bool {
        guard operatingSystemIsAtLeast(minimumOperatingSystemVersion) else { return false }
        return fileSystem.fileExists(
            atPath: "\(macFUSEExtensionsDirectory)/\(macFUSEFSKitExtensionName)"
        )
    }

    /// Shell command that registers macFUSE's file-system extensions with
    /// PluginKit, so they appear in the System Settings list at all.
    ///
    /// Needed because a macFUSE install frequently leaves them unregistered,
    /// and macFUSE's own `macfuse install --components file-system-extensions
    /// --force` does not fix it — it exits 0 having registered nothing
    /// (reproduced on macFUSE 5.3.3 / macOS 26.6.2). `pluginkit -a` is the
    /// workaround from macfuse/macfuse#1071; it needs no `sudo`, and re-adding
    /// an already-registered extension is a no-op, so it is safe to re-run.
    ///
    /// This only makes the switch *visible*. Turning it on is the user's, and
    /// no command can do it for them — hence `Scripts/register-fskit.sh`, the
    /// standalone version of this, ends by naming the pane.
    public static let registrationCommand =
        "for appex in \(macFUSEExtensionsDirectory)/*.appex; do pluginkit -v -a \"$appex\"; done"
}
