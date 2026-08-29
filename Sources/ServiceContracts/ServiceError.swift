import Foundation
import SparrowDomain

/// The only errors that cross the service boundary.
///
/// ⚠️ Conforms to `LocalizedError` and to nothing from App Intents. Conforming
/// it to `CustomLocalizedStringResourceConvertible` would make this target —
/// and therefore `Services` — unbuildable without the App Intents framework.
/// The App Intents layer maps this into its own error type, in the same file
/// that maps `Note` to `NoteEntity`.
///
/// `StorageError` never appears here. `storageUnavailable` says everything the
/// UI can act on; `corrupted("malformed FTS row")` says nothing a person can
/// use.
public enum ServiceError: Error, Hashable, Sendable {
    case noteNotFound(NoteID)
    case emptyNote
    case storageUnavailable
}

extension ServiceError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .noteNotFound:
            "That note no longer exists."
        case .emptyNote:
            "A note needs a title or some text."
        case .storageUnavailable:
            "Sparrow can't reach your notes right now."
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .noteNotFound:
            "It may have been deleted on another device."
        case .emptyNote:
            "Add a title or a few words, then save."
        case .storageUnavailable:
            "Try again in a moment."
        }
    }
}
