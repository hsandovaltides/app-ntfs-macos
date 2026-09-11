import AppKit

/// Deep links into the System Settings panes the user has to visit to finish
/// setup.
///
/// Two reasons this is a type rather than a couple of inline URLs:
///
/// 1. **The destinations are different panes.** Approving the privileged
///    helper happens in General → Login Items & Extensions, while the macFUSE
///    kernel-extension prompt and Full Disk Access live in Privacy &
///    Security. A single shared "open System Settings" button — which is what
///    this replaces — sent the user to Privacy & Security for the helper too,
///    where the helper simply is not listed.
///
/// 2. **The anchors moved.** macOS 13 renamed the preference-pane bundle IDs
///    (`com.apple.preference.*` → `com.apple.settings.*`) and support for the
///    old names has been inconsistent since. Each case therefore lists its
///    candidates newest-first and opens the first one that resolves, so the
///    app degrades to "lands on roughly the right pane" instead of "does
///    nothing" on either side of that split.
enum SystemSettingsLink {
    /// Privacy & Security, where a blocked kernel extension surfaces its
    /// one-time "Allow" button after macFUSE is installed.
    case privacyAndSecurity

    /// Privacy & Security → Full Disk Access: the list the helper binary has
    /// to be dragged into. No API can add an entry, so the best the app can
    /// do is open the exact list and reveal the binary in Finder.
    case fullDiskAccess

    /// General → Login Items & Extensions, where the `SMAppService` daemon
    /// waits for approval.
    case loginItems

    /// General → Login Items & Extensions → File System Extensions: the switch
    /// that turns on macFUSE's FSKit module.
    ///
    /// This is the one that replaces the Recovery Mode trip. It is a plain
    /// toggle, no restart, and it is also the *only* way in — a registered,
    /// PluginKit-enabled extension still refuses to mount ("File system
    /// extension not enabled") until it is flipped here.
    ///
    /// Shares `loginItems`' anchors as its fallbacks: the sub-list has no
    /// documented anchor of its own, so the realistic outcomes are "lands on
    /// the right pane, one click away" or "lands on the parent pane".
    case fileSystemExtensions

    private var candidates: [String] {
        switch self {
        case .privacyAndSecurity:
            [
                "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension",
                "x-apple.systempreferences:com.apple.preference.security",
            ]
        case .fullDiskAccess:
            [
                "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles",
                "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles",
            ]
        case .loginItems:
            [
                "x-apple.systempreferences:com.apple.LoginItems-Settings.extension",
                "x-apple.systempreferences:com.apple.settings.LoginItems",
            ]
        case .fileSystemExtensions:
            [
                "x-apple.systempreferences:com.apple.LoginItems-Settings.extension?FileSystemExtensions",
                "x-apple.systempreferences:com.apple.LoginItems-Settings.extension",
                "x-apple.systempreferences:com.apple.settings.LoginItems",
            ]
        }
    }

    /// Opens the first candidate macOS accepts. Returns `false` only if every
    /// candidate was refused, which would mean the pane identifiers moved
    /// again.
    @discardableResult
    func open() -> Bool {
        for candidate in candidates {
            guard let url = URL(string: candidate) else { continue }
            if NSWorkspace.shared.open(url) { return true }
        }
        return false
    }
}
