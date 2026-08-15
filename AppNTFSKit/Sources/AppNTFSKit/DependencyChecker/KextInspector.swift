import Foundation

/// Checks whether macFUSE's classic kernel extension is currently loaded, via
/// `kextstat` (itself a thin wrapper over `kmutil showloaded` on current
/// macOS — see its own "Executing: /usr/bin/kmutil showloaded" banner).
///
/// This is the counterpart to `SystemExtensionInspector` for the kext backend
/// (the one this app actually uses — see `Ntfs3gCommand.mountOptions`).
/// `systemextensionsctl list` never lists macFUSE for the kext backend: it
/// only covers the modern System Extensions framework, which is a completely
/// separate approval mechanism from kernel extensions. There is no public API
/// to ask "is this kext approved but just not loaded yet" — kexts load
/// on-demand, so a fresh boot before any mount attempt looks identical to a
/// non-approved kext here. `.installedPendingApproval` is the correct answer
/// in both cases: the user needs to trigger a mount (from the app or by
/// hand) at least once for the OS to either load the kext or show the
/// approval banner, at which point this check reflects reality again.
public enum KextInspector {
    static let macFUSEIdentifierHint = "macfuse"

    public static func macFUSEIsLoaded(fromOutput output: String) -> Bool {
        output
            .split(separator: "\n")
            .contains { $0.lowercased().contains(macFUSEIdentifierHint) }
    }

    public static func macFUSEIsLoaded(using runner: ProcessRunning) async -> Bool {
        guard let result = try? await runner.run(executable: "/usr/sbin/kextstat", arguments: []),
              result.succeeded else {
            return false
        }
        return macFUSEIsLoaded(fromOutput: result.standardOutput)
    }
}
