import Foundation
import SparrowDomain

/// Finding notes.
///
/// ⚠️ **Searching cannot mutate anything, and the implementation is built so
/// that it could not.** `SearchService` is never given a `TransactionRunning`,
/// so there is no reachable path from a query to a write.
public protocol SearchServicing: Sendable {
    /// FR-1.3. Matches against the full text of every note.
    func search(_ text: String, limit: Int) async throws -> [Note]

    /// FR-1.4. The Find action: structural fields, optional free text, and an
    /// explicit order.
    ///
    /// `NoteFilter` is data all the way down — a Shortcut fills one in, and
    /// storage compiles it. Neither end knows the other's vocabulary.
    func filter(
        _ filter: NoteFilter,
        sort: NoteSort,
        limit: Int
    ) async throws -> [Note]

    /// How many notes a filter would return, without fetching them.
    func count(matching filter: NoteFilter) async throws -> Int

    /// FR-1.6. What to offer before anyone has typed anything.
    ///
    /// Separate from `NoteServicing.recent` on purpose. Today they return the
    /// same thing; when pinning or usage frequency starts to matter, only one
    /// of them changes.
    func suggestions(limit: Int) async throws -> [Note]
}
