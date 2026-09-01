import Foundation
import ServiceContracts
import SparrowDomain
import StorageContracts

/// Search use cases.
///
/// Holds a reader and an index, and **nothing that can write**. A service with
/// no `TransactionRunning` in its dependency graph cannot open a transaction,
/// so "searching never changes anything" is a property of the type rather than
/// a rule someone has to remember.
public actor SearchService: SearchServicing {
    private let notes: any NoteReading
    private let index: any SearchIndexing

    public init(notes: any NoteReading, index: any SearchIndexing) {
        self.notes = notes
        self.index = index
    }

    public func search(_ text: String, limit: Int) async throws -> [Note] {
        guard limit > 0 else { return [] }

        let ids = try await translatingStorageErrors {
            try await index.matches(text, limit: limit)
        }
        guard !ids.isEmpty else { return [] }

        // The index decides the order; `notes(_:)` promises to keep it. If
        // that promise ever breaks, results silently re-sort — which looks
        // like a ranking bug rather than a contract violation.
        return try await translatingStorageErrors {
            try await notes.notes(ids)
        }
    }

    public func suggestions(limit: Int) async throws -> [Note] {
        guard limit > 0 else { return [] }
        return try await translatingStorageErrors {
            try await notes.recentNotes(limit: limit)
        }
    }
}
