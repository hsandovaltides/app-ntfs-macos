import Foundation

public enum SystemExtensionApprovalState: Sendable, Equatable {
    case notPresent
    case pendingApproval
    case approved
}

/// Parses `systemextensionsctl list` output to determine whether macFUSE's
/// system extension has been approved in System Settings > Privacy & Security.
/// Apple exposes no structured API for this, so parsing is deliberately
/// substring-based (not strict column parsing) to stay resilient to the
/// formatting changes this command has had across macOS versions.
public enum SystemExtensionInspector {
    static let macFUSEIdentifierHint = "macfuse"
    static let approvedStateHint = "activated enabled"

    public static func macFUSEApprovalState(fromOutput output: String) -> SystemExtensionApprovalState {
        let matchingLines = output
            .split(separator: "\n")
            .filter { $0.lowercased().contains(macFUSEIdentifierHint) }

        guard !matchingLines.isEmpty else { return .notPresent }

        let isApproved = matchingLines.contains { $0.lowercased().contains(approvedStateHint) }
        return isApproved ? .approved : .pendingApproval
    }

    public static func macFUSEApprovalState(using runner: ProcessRunning) async -> SystemExtensionApprovalState {
        guard let result = try? await runner.run(
            executable: "/usr/bin/systemextensionsctl",
            arguments: ["list"]
        ), result.succeeded else {
            return .notPresent
        }
        return macFUSEApprovalState(fromOutput: result.standardOutput)
    }
}
