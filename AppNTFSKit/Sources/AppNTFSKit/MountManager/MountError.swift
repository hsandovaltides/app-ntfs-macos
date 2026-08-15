import Foundation

public enum MountError: Error, Sendable, Equatable {
    case dependenciesNotReady(DependencyStatus)
    case volumeDirty
    case unmountFailed(String)
    case mountFailed(String)
    case mountFailedAndFallbackFailed(mountError: String, fallbackError: String)
    case operationAlreadyInProgress
}
