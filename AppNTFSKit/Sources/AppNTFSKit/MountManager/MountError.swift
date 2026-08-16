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
    public var description: String {
        switch self {
        case .dependenciesNotReady:
            return "Faltan dependencias (macFUSE/ntfs-3g)"
        case .volumeDirty:
            return "Hibernación de Windows detectada — no se remonta en escritura"
        case .unmountFailed(let detail):
            return "No se pudo desmontar: \(detail)"
        case .mountFailed(let detail):
            return "No se pudo montar en escritura: \(detail)"
        case .mountFailedAndFallbackFailed:
            return "Error crítico: el volumen podría no estar accesible"
        case .operationAlreadyInProgress:
            return "Operación en curso"
        }
    }
}
