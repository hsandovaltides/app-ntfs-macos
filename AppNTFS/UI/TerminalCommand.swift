import AppKit
import Foundation
import os

/// Hands a shell command to Terminal.app for the user to run.
///
/// The install steps need `sudo` (macFUSE's cask installs a kext into
/// `/Library`), so they cannot run inside the app — they need a terminal that
/// can prompt for a password. Copying the command to the clipboard left the
/// user to open Terminal and paste it themselves; this opens it for them.
///
/// Implemented by writing an executable `.command` file and opening it, rather
/// than driving Terminal with AppleScript's `do script`. Scripting another app
/// is an Apple Events request, which raises a *second* TCC consent dialog
/// ("AppNTFS wants to control Terminal") — a worse trade in an app whose whole
/// problem is that it asks for too many permissions. Opening a document asks
/// for nothing.
///
/// The script does not run the command on sight: it prints it, waits for the
/// user to press Enter, and leaves the window open afterwards. A button that
/// silently starts a `sudo` install would be a surprise, and the pause is also
/// where the user gets to read what they're about to run.
enum TerminalCommand {
    private static let logger = Logger(subsystem: "com.appntfs.app", category: "TerminalCommand")

    @discardableResult
    static func run(_ command: String, title: String) -> Bool {
        do {
            let script = try writeScript(command, title: title)
            return NSWorkspace.shared.open(script)
        } catch {
            logger.error("Could not stage Terminal command: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private static func writeScript(_ command: String, title: String) throws -> URL {
        // A fresh directory per invocation: the file name is what Terminal
        // shows as the window title, so it stays readable, and nothing has to
        // be uniqued or cleaned up between runs.
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AppNTFS-install-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let script = directory.appendingPathComponent("AppNTFS.command")
        try contents(command, title: title).write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        return script
    }

    private static func contents(_ command: String, title: String) -> String {
        """
        #!/bin/bash
        # Generado por AppNTFS. Se puede borrar sin problema.
        echo '\(shellSingleQuoted(title))'
        echo
        echo '  \(shellSingleQuoted(command))'
        echo
        read -r -p 'Pulsá Enter para ejecutarlo (o cerrá esta ventana para cancelar): '
        echo
        \(command)
        status=$?
        echo
        if [ $status -eq 0 ]; then
          echo 'Listo. Volvé a AppNTFS y pulsá "Recomprobar".'
        else
          echo "El comando terminó con error $status."
        fi

        """
    }

    /// Escapes a value for interpolation *inside* a single-quoted shell string.
    /// Only `'` can end such a string, so closing, escaping it, and reopening
    /// is the whole job. Applied to the two echoed lines; `command` itself is
    /// emitted unquoted because it is a command, and every caller is a literal
    /// in this app rather than anything the user typed.
    private static func shellSingleQuoted(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "'\\''")
    }
}
