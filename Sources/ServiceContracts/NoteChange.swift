import Foundation
import SparrowDomain

/// What the service layer announces upward.
///
/// Not a pass-through of `StoredChange`. Storage reports *which rows moved*;
/// this reports *what happened*, which is what a view or an intent can act on.
public enum NoteChange: Hashable, Sendable {
    case created(NoteID)
    case updated(NoteID)
    case deleted(NoteID)
    /// Bulk import, migration, restore. Assume everything changed.
    case reloaded
}
