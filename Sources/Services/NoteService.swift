import Foundation
import SparrowDomain
import ServiceContracts
import StorageContracts

/// Note use cases.
///
/// Everything injected is a protocol. `NoteService` cannot name a database
/// type, because none is in its dependency graph.
///
/// ```
///    NoteService.create(draft)
///
///     1. validate      draft is not empty
///     2. assemble      stamp id, createdAt, updatedAt
///     3. one write     insert · index · journal
///     4. announce      NoteChange.created
/// ```
///
/// Steps 1–2 are *what is true*. Step 3 asks storage to make it durable,
/// atomically. Step 4 lets the rest of the app react.
public actor NoteService: NoteServicing {
    private let notes: any NoteReading
    private let transactions: any TransactionRunning
    private let now: @Sendable () -> Date
    private let broadcaster = NoteChangeBroadcaster()

    /// - Parameter now: injected so date-dependent behaviour is testable
    ///   without waiting for the clock. It becomes a `Clock` abstraction in
    ///   0.8.0, when daily notes need one.
    public init(
        notes: any NoteReading,
        transactions: any TransactionRunning,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.notes = notes
        self.transactions = transactions
        self.now = now
    }

    public nonisolated var changes: AsyncStream<NoteChange> {
        broadcaster.stream()
    }

    // MARK: Commands

    @discardableResult
    public func create(_ draft: NoteDraft) async throws -> Note {
        guard !draft.isEmpty else { throw ServiceError.emptyNote }

        let timestamp = now()
        let note = Note(
            title: draft.title,
            body: draft.body,
            createdAt: timestamp,
            updatedAt: timestamp
        )

        try await translatingStorageErrors {
            try await transactions.write { session in
                try await session.notes.insert(note)
                try await session.index.index(note)
                try await session.journal.record(
                    JournalEntry(
                        sequence: 0,
                        subject: .note(note.id),
                        operation: .upsert,
                        payload: try JSONEncoder().encode(note),
                        recordedAt: timestamp
                    )
                )
            }
        }

        broadcaster.publish(.created(note.id))
        return note
    }

    public func delete(_ id: NoteID) async throws {
        let timestamp = now()

        try await translatingStorageErrors(missing: .noteNotFound(id)) {
            try await transactions.write { session in
                try await session.notes.markDeleted(id, at: timestamp)
                try await session.index.remove(id)
                try await session.journal.record(
                    JournalEntry(
                        sequence: 0,
                        subject: .note(id),
                        operation: .delete,
                        payload: Data(),
                        recordedAt: timestamp
                    )
                )
            }
        }

        broadcaster.publish(.deleted(id))
    }

    // MARK: Queries

    public func note(_ id: NoteID) async throws -> Note? {
        try await translatingStorageErrors { try await notes.note(id) }
    }

    public func notes(_ ids: [NoteID]) async throws -> [Note] {
        try await translatingStorageErrors { try await notes.notes(ids) }
    }

    public func recent(limit: Int) async throws -> [Note] {
        try await translatingStorageErrors {
            try await notes.recentNotes(limit: limit)
        }
    }
}
