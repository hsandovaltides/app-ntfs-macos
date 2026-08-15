import Foundation
import Security
import os.log

/// Diagnostic-only logger: NSLog/print output gets redacted to `<private>`
/// under unified logging by default, so this uses explicit `%{public}@`
/// formatting to make the connection-rejection reason actually visible in
/// Console.app / `log stream` while debugging the helper's code-signature
/// check.
private let diagnosticLog = OSLog(subsystem: "com.appntfs.app.helper", category: "connection-validation")

/// The mach service this helper registers is visible to any local process
/// that knows its name — launchd doesn't scope it to a single client. This
/// delegate is the only thing standing between "any process on the Mac" and
/// a root XPC service, so it verifies the connecting process is actually
/// AppNTFS.app (same Team ID + bundle identifier) before exporting anything.
final class HelperListenerDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        guard Self.isConnectionFromExpectedApp(newConnection) else {
            os_log("rejected XPC connection — see preceding diagnostic line", log: diagnosticLog, type: .default)
            return false
        }

        newConnection.exportedInterface = AppNTFSHelperXPC.makeInterface()
        newConnection.exportedObject = HelperService()
        newConnection.resume()
        return true
    }

    private static func isConnectionFromExpectedApp(_ connection: NSXPCConnection) -> Bool {
        guard let requirement else {
            os_log("no SecRequirement built — ExpectedAppTeamID missing/empty in Info.plist", log: diagnosticLog, type: .default)
            return false
        }
        guard let auditToken = auditToken(from: connection) else {
            os_log("could not read auditToken via KVC", log: diagnosticLog, type: .default)
            return false
        }

        var code: SecCode?
        let auditData = withUnsafeBytes(of: auditToken) { Data($0) } as CFData
        let attributes = [kSecGuestAttributeAudit: auditData] as CFDictionary

        let copyStatus = SecCodeCopyGuestWithAttributes(nil, attributes, [], &code)
        guard copyStatus == errSecSuccess, let code else {
            os_log("SecCodeCopyGuestWithAttributes failed: %{public}d", log: diagnosticLog, type: .default, copyStatus)
            return false
        }

        let validityStatus = SecCodeCheckValidity(code, [], requirement)
        guard validityStatus == errSecSuccess else {
            var staticCode: SecStaticCode?
            SecCodeCopyStaticCode(code, [], &staticCode)
            var infoRef: CFDictionary?
            if let staticCode {
                SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &infoRef)
            }
            os_log(
                "SecCodeCheckValidity failed: %{public}d info=%{public}@",
                log: diagnosticLog, type: .default,
                validityStatus, String(describing: infoRef)
            )
            return false
        }
        return true
    }

    /// `NSXPCConnection.auditToken` exists at the Objective-C runtime level
    /// but isn't declared in Foundation's public Swift-visible interface, so
    /// it has to be fetched via KVC instead of direct member access. This is
    /// the standard, widely-used workaround for this specific Foundation gap.
    private static func auditToken(from connection: NSXPCConnection) -> audit_token_t? {
        let key = "auditToken"
        guard connection.responds(to: NSSelectorFromString(key)),
              let boxed = connection.value(forKey: key) as? NSValue else {
            return nil
        }
        var token = audit_token_t()
        boxed.getValue(&token)
        return token
    }

    /// Built from this helper's own Info.plist (`ExpectedAppTeamID`, injected
    /// at build time from `$(DEVELOPMENT_TEAM)`) rather than hardcoded, so the
    /// same source works across development machines/teams without edits.
    /// `nonisolated(unsafe)`: CFType security objects aren't Sendable-annotated
    /// in the SDK, but this is written once (static let) and only ever read
    /// afterward, so sharing it is safe.
    private nonisolated(unsafe) static let requirement: SecRequirement? = {
        guard let teamID = Bundle.main.infoDictionary?["ExpectedAppTeamID"] as? String, !teamID.isEmpty else {
            return nil
        }

        let requirementString =
            "anchor apple generic and identifier \"\(expectedAppBundleIdentifier)\" and certificate leaf[subject.OU] = \"\(teamID)\""
        os_log("built requirement: %{public}@", log: diagnosticLog, type: .default, requirementString)

        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(requirementString as CFString, [], &requirement) == errSecSuccess else {
            return nil
        }
        return requirement
    }()
}
