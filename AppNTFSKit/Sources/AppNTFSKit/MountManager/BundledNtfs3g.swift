import Darwin
import Foundation

/// Locates the `ntfs-3g` binaries shipped *inside* `AppNTFS.app`.
///
/// Embedding them removes two of the setup steps the user used to perform by
/// hand — installing Homebrew and tapping `gromgit/homebrew-fuse` for the
/// `ntfs-3g-mac` formula. It does not remove the macFUSE cask: `ntfs-3g` links
/// `/usr/local/lib/libfuse.2.dylib` by absolute path, and that library belongs
/// to macFUSE.
///
/// The directory is always derived from the path of the *running* executable
/// rather than passed in, and that is a security property, not a convenience.
/// Both processes that need it live in the same bundle — the app at
/// `Contents/MacOS/AppNTFS`, the helper at `Contents/MacOS/AppNTFSHelper` — so
/// both resolve to the same `Contents/Helpers`. Because the root helper
/// computes it from its own location, it never has to trust a directory the
/// app named for it, and `HelperRequestValidation` can accept bundled paths
/// without widening into a "run any binary as root" primitive.
public enum BundledNtfs3g {
    /// Where the embedded binaries sit relative to the bundle root. `Helpers`
    /// rather than `MacOS` keeps them separate from the two executables macOS
    /// itself launches, while staying a location the codesign/notarisation
    /// pipeline already understands.
    public static let bundleRelativeDirectory = "Contents/Helpers"

    /// Resolves the embedded-binaries directory from an executable known to
    /// live at `<bundle>/Contents/MacOS/<name>`.
    ///
    /// Returns `nil` for any layout that doesn't match — a unit-test binary, a
    /// bare `swift run`, a relocated executable — which makes the caller fall
    /// back to Homebrew rather than fabricating a path.
    public static func directory(forHostExecutable executablePath: String) -> String? {
        let macOSDirectory = (executablePath as NSString).deletingLastPathComponent
        let contentsDirectory = (macOSDirectory as NSString).deletingLastPathComponent
        guard (macOSDirectory as NSString).lastPathComponent == "MacOS",
              (contentsDirectory as NSString).lastPathComponent == "Contents"
        else { return nil }
        return (contentsDirectory as NSString).appendingPathComponent("Helpers")
    }

    /// The embedded-binaries directory for the process making the call, or
    /// `nil` when this executable isn't inside an app bundle.
    public static var runningHostDirectory: String? {
        guard let executablePath = currentExecutablePath() else { return nil }
        return directory(forHostExecutable: executablePath)
    }

    /// `_NSGetExecutablePath` rather than `CommandLine.arguments[0]` or
    /// `Bundle.main`: it reports the path the kernel actually loaded, so it
    /// can't be steered by whoever spawned the process, and it behaves the
    /// same for the bundled app and for the helper (a bare `type: tool`
    /// executable, for which `Bundle.main` is not an app bundle at all).
    private static func currentExecutablePath() -> String? {
        var capacity = UInt32(0)
        _ = _NSGetExecutablePath(nil, &capacity)
        guard capacity > 0 else { return nil }

        var buffer = [UInt8](repeating: 0, count: Int(capacity))
        let filled = buffer.withUnsafeMutableBufferPointer { raw -> Bool in
            raw.baseAddress!.withMemoryRebound(to: CChar.self, capacity: raw.count) {
                _NSGetExecutablePath($0, &capacity) == 0
            }
        }
        guard filled else { return nil }

        // `_NSGetExecutablePath` writes a NUL-terminated string into a buffer
        // sized by its own first call, so drop everything from the terminator
        // on before decoding.
        let rawPath = String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
        // `_NSGetExecutablePath` may hand back a path containing symlinks or
        // `..`; resolve so it compares equal to the directory the helper
        // derives independently.
        return URL(fileURLWithPath: rawPath).resolvingSymlinksInPath().path
    }
}
