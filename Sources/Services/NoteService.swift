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
    private let relay: ChangeRelay
    private let now: @Sendable () -> Date

    /// - Parameter relay: every event this service announces goes through it,
    ///   so a burst of writes reaches the UI as one change rather than
    ///   hundreds.
    /// - Parameter now: injected so date-dependent behaviour is testable
    ///   without waiting for the clock. It becomes a `Clock` abstraction in
    ///   0.8.0, when daily notes need one.
    public init(
        notes: any NoteReading,
        transactions: any TransactionRunning,
        relay: ChangeRelay,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.notes = notes
        self.transactions = transactions
        self.relay = relay
        self.now = now
    }

    public nonisolated var changes: AsyncStream<NoteChange> {
        relay.noteChanges
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
                try session.notes.insert(note)
                try session.index.index(note)
                try session.journal.record(
                    JournalDraft(
                        subject: .note(note.id),
                        operation: .upsert,
                        payload: try JSONEncoder().encode(note),
                        recordedAt: timestamp
                    )
                )
            }
        }

        await relay.announce(.created(note.id))
        return note
    }

    public func delete(_ id: NoteID) async throws {
        let timestamp = now()

        try await translatingStorageErrors(missing: .noteNotFound(id)) {
            try await transactions.write { session in
                try session.notes.markDeleted(id, at: timestamp)
                try session.index.remove(id)
                try session.journal.record(
                    JournalDraft(
                        subject: .note(id),
                        operation: .delete,
                        payload: Data(),
                        recordedAt: timestamp
                    )
                )
            }
        }

        await relay.announce(.deleted(id))
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
