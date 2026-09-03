import Foundation
import SparrowDomain

/// The only errors that cross the service boundary.
///
/// ⚠️ Conforms to `LocalizedError` and to nothing from App Intents.
/// Conforming it to `CustomLocalizedStringResourceConvertible` would make this
/// target — and therefore `Services` — unbuildable without the App Intents
/// framework, which is exactly the dependency the V2 server cannot have. The
/// App Intents layer maps this into its own error type, in the same file that
/// maps `Note` to `NoteEntity`.
///
/// `StorageError` never appears here. `storageUnavailable` says everything the
/// UI can act on; `corrupted("malformed FTS row")` says nothing a person can
/// use.
public enum ServiceError: Error, Hashable, Sendable {
    case noteNotFound(NoteID)
    case notebookNotFound(NotebookID)
    case tagNotFound(TagID)
    case emptyNote
    case emptyNotebookName
    /// A label with no letters or digits has no slug — `"!!!"`, `"🐦"`.
    case emptyTagLabel
    /// Deleting a notebook must not silently take its contents with it.
    case notebookNotEmpty(NotebookID)
    case storageUnavailable
}

extension ServiceError: LocalizedError {
    /// ⚠️ **`bundle: .module`, not the main bundle.**
    ///
    /// These strings ship inside the package. Without the bundle the lookup
    /// falls back to the key — which *is* the English text, so a missing
    /// catalog would read perfectly in English and never translate. The bug
    /// would be invisible in the language it was written in.
    private static func localized(_ key: String.LocalizationValue) -> String {
        String(localized: key, bundle: .module)
    }

    public var errorDescription: String? {
        switch self {
        case .noteNotFound:
            Self.localized("That note no longer exists.")
        case .notebookNotFound:
            Self.localized("That notebook no longer exists.")
        case .tagNotFound:
            Self.localized("That tag no longer exists.")
        case .emptyNote:
            Self.localized("A note needs a title or some text.")
        case .emptyNotebookName:
            Self.localized("A notebook needs a name.")
        case .emptyTagLabel:
            Self.localized("A tag needs a word or a number in it.")
        case .notebookNotEmpty:
            Self.localized("That notebook still has things in it.")
        case .storageUnavailable:
            Self.localized("Sparrow can’t reach your notes right now.")
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .noteNotFound, .notebookNotFound, .tagNotFound:
            Self.localized("It may have been deleted on another device.")
        case .emptyNote:
            Self.localized("Add a title or a few words, then save.")
        case .emptyNotebookName:
            Self.localized("Give it a name, then save.")
        case .emptyTagLabel:
            Self.localized("Try something like “wetlands” or “survey 2026”.")
        case .notebookNotEmpty:
            Self.localized("Move or delete what’s inside it first.")
        case .storageUnavailable:
            Self.localized("Try again in a moment.")
        }
    }
}
