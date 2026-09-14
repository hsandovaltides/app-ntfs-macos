import Foundation

public enum MountError: Error, Sendable, Equatable {
    case dependenciesNotReady(DependencyStatus)
    case volumeDirty
    case unmountFailed(String)
    case mountFailed(String)
    case mountFailedAndFallbackFailed(mountError: String, fallbackError: String)
    case operationAlreadyInProgress
}

extension MountError: CustomStringConvertible {
    /// One line, fit for a notification body and a menu-bar row.
    ///
    /// The failure cases carry the underlying reason in condensed form rather
    /// than dropping it. They used to render as bare category labels — most
    /// starkly `.mountFailedAndFallbackFailed`, which showed "Error crítico: el
    /// volumen podría no estar accesible" while discarding *both* strings
    /// explaining what had actually gone wrong. That is the worst state the app
    /// can reach and it was the one saying the least; the detail existed only
    /// in the log, which a user with a drive that will not mount has no reason
    /// to think of opening.
    public var description: String {
        switch self {
        case .dependenciesNotReady:
            return "Faltan dependencias (macFUSE/ntfs-3g)"
        case .volumeDirty:
            return "Hibernación de Windows detectada — no se remonta en escritura"
        case .unmountFailed(let detail):
            return Self.compose("No se pudo desmontar", detail)
        case .mountFailed(let detail):
            return Self.compose("No se pudo montar en escritura", detail)
        case .mountFailedAndFallbackFailed(let mountError, _):
            return Self.compose(
                "Error crítico: no se pudo montar ni restaurar el modo solo lectura",
                mountError
            )
        case .operationAlreadyInProgress:
            return "Operación en curso"
        }
    }

    /// The full, untruncated diagnostic text, for a tooltip or a bug report —
    /// `nil` when the case carries nothing beyond its `description`.
    public var detail: String? {
        switch self {
        case .unmountFailed(let detail), .mountFailed(let detail):
            let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case .mountFailedAndFallbackFailed(let mountError, let fallbackError):
            return """
                Montaje: \(mountError.trimmingCharacters(in: .whitespacesAndNewlines))
                Restauración a solo lectura: \(fallbackError.trimmingCharacters(in: .whitespacesAndNewlines))
                """
        case .dependenciesNotReady(let status):
            return status.description
        case .volumeDirty, .operationAlreadyInProgress:
            return nil
        }
    }

    /// How much of a tool's diagnostic fits on one UI line before it stops
    /// being readable and starts pushing the buttons off the row.
    private static let maximumDetailLength = 110

    /// `label: <first meaningful line of detail>`, or just `label` when the
    /// tool said nothing useful.
    ///
    /// Only the first non-empty line is kept: `ntfs-3g` and `diskutil` both
    /// lead with the actual error and follow it with generic advice ("Please
    /// see the FAQ…"), so the first line is the informative one and the rest
    /// is what would blow up a notification.
    private static func compose(_ label: String, _ detail: String) -> String {
        let firstLine = detail
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }

        guard let firstLine, !firstLine.isEmpty else { return label }

        let condensed = firstLine.count > maximumDetailLength
            ? firstLine.prefix(maximumDetailLength).trimmingCharacters(in: .whitespaces) + "…"
            : firstLine
        return "\(label): \(condensed)"
    }
}
