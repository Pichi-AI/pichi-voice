import Foundation
import Security

/// A locked or temporarily unavailable device keystore is not a revoked credential
/// or a corrupt recording. Preserve durable state and retry when protected data opens.
nonisolated enum ProtectedDataAccessError: Error, Sendable {
    case temporarilyUnavailable

    static func keychainFailure(_ status: OSStatus) -> Self? {
        switch status {
        case errSecInteractionNotAllowed, errSecNotAvailable: .temporarilyUnavailable
        default: nil
        }
    }
}
