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
    case notebookNotFound(NotebookID)
    case emptyNote
    case emptyNotebookName
    /// A label with no letters or digits has no slug — `"!!!"`, `"🐦"`.
    case emptyTagLabel
    case tagNotFound(TagID)
    /// Deleting a notebook must not silently take its contents with it.
    case notebookNotEmpty(NotebookID)
    case storageUnavailable
}

extension ServiceError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .noteNotFound:
            "That note no longer exists."
        case .notebookNotFound:
            "That notebook no longer exists."
        case .emptyNote:
            "A note needs a title or some text."
        case .emptyNotebookName:
            "A notebook needs a name."
        case .emptyTagLabel:
            "A tag needs a word or a number in it."
        case .tagNotFound:
            "That tag no longer exists."
        case .notebookNotEmpty:
            "That notebook still has things in it."
        case .storageUnavailable:
            "Sparrow can't reach your notes right now."
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .noteNotFound:
            "It may have been deleted on another device."
        case .notebookNotFound:
            "It may have been deleted on another device."
        case .emptyNote:
            "Add a title or a few words, then save."
        case .emptyNotebookName:
            "Give it a name, then save."
        case .emptyTagLabel:
            "Try something like \u{201C}wetlands\u{201D} or \u{201C}survey 2026\u{201D}."
        case .tagNotFound:
            "It may have been deleted on another device."
        case .notebookNotEmpty:
            "Move or delete what's inside it first."
        case .storageUnavailable:
            "Try again in a moment."
        }
    }
}
