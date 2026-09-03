import Foundation
import SparrowDomain
import ServiceContracts
import StorageContracts

/// Runs a storage call and translates anything it throws into the vocabulary
/// the layers above understand.
///
/// This is the only place `StorageError` is named outside the storage package.
/// Every path out of a service goes through it, so a new storage error can
/// never reach a view untranslated.
///
/// `isolation: #isolation` makes the helper adopt its caller's actor, so the
/// non-`Sendable` body never crosses an isolation boundary and the call reads
/// as if it were inline.
func translatingStorageErrors<T: Sendable>(
    missing: @autoclosure () -> ServiceError = .storageUnavailable,
    isolation: isolated (any Actor)? = #isolation,
    _ body: () async throws -> T
) async throws -> T {
    do {
        return try await body()
    } catch let error as StorageError {
        switch error {
        case .notFound:
            throw missing()
        case .constraintViolated, .corrupted, .unavailable, .migrationFailed:
            throw ServiceError.storageUnavailable
        // Reachable now that `StorageContracts` ships as a resilient binary.
        // Unlike most `@unknown default`s this one is not a compromise: every
        // case above except `.notFound` already maps here, so a storage error
        // this build has not heard of is genuinely `.storageUnavailable`.
        @unknown default:
            throw ServiceError.storageUnavailable
        }
    }
}
