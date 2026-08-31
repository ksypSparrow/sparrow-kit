import Foundation
import SparrowDomain

/// What the service layer announces about notebooks.
public enum NotebookChange: Hashable, Sendable {
    case created(NotebookID)
    case updated(NotebookID)
    case deleted(NotebookID)
    /// Too many at once to be worth listing. Re-read everything.
    case reloaded
}
