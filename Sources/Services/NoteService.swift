import Foundation
import ServiceContracts
import SparrowDomain
import StorageContracts

/// Note use cases.
///
/// Everything injected is a protocol. `NoteService` cannot name a database
/// type, because none is in its dependency graph.
///
/// ```
///    NoteService.create(draft)
///
///     1. validate      an empty draft throws before anything else
///     2. resolve       notebookID ?? defaultNotebook()   ← outside the write
///     3. assemble      stamp id, createdAt, updatedAt
///     4. one write     insert · index · journal, atomically
///     5. announce      NoteChange.created
/// ```
///
/// ⚠️ **Step 2 is outside the transaction deliberately.** Holding a write open
/// across a lookup would serialise every concurrent capture behind it, and the
/// lookup does not belong in the same atomic unit as the insert.
public actor NoteService: NoteServicing {
    private let notes: any NoteReading
    private let notebooks: any NotebookReading
    private let transactions: any TransactionRunning
    private let relay: ChangeRelay
    private let now: @Sendable () -> Date

    public init(
        notes: any NoteReading,
        notebooks: any NotebookReading,
        transactions: any TransactionRunning,
        relay: ChangeRelay,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.notes = notes
        self.notebooks = notebooks
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

        let notebookID = try await resolve(draft.notebookID)
        let timestamp = now()
        let note = Note(
            title: draft.title,
            body: draft.body,
            notebookID: notebookID,
            kind: draft.kind,
            observedAt: draft.observedAt,
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

    @discardableResult
    public func update(_ id: NoteID, with edit: NoteEdit) async throws -> Note {
        // A move has to land somewhere real, and that is worth knowing before
        // the transaction opens.
        if let target = edit.notebookID {
            _ = try await resolve(target)
        }

        let timestamp = now()
        let outcome = try await translatingStorageErrors(
            missing: .noteNotFound(id)
        ) {
            try await transactions.write { session -> (Note, Bool) in
                guard let current = try session.notes.note(id) else {
                    throw ServiceError.noteNotFound(id)
                }

                let updated = current.applying(edit, at: timestamp)

                // Nothing actually changed? Do not write.
                //
                // The domain's rule covers an edit that names *no* fields.
                // This covers the other kind: an edit that names a field and
                // sets it to the value it already has — pinning a pinned note,
                // moving a note to the notebook it is already in. `applying`
                // bumps `updatedAt` for any non-empty edit, so the timestamp
                // has to be discounted to see it.
                var comparable = updated
                comparable.updatedAt = current.updatedAt
                guard comparable != current else { return (current, false) }

                try session.notes.update(updated)
                try session.index.index(updated)
                try session.journal.record(
                    JournalDraft(
                        subject: .note(id),
                        operation: .upsert,
                        payload: try JSONEncoder().encode(updated),
                        recordedAt: timestamp
                    )
                )
                return (updated, true)
            }
        }

        if outcome.1 { await relay.announce(.updated(id)) }
        return outcome.0
    }

    public func move(_ id: NoteID, to notebook: NotebookID) async throws {
        try await update(id, with: NoteEdit(notebookID: notebook))
    }

    public func setPinned(_ id: NoteID, _ pinned: Bool) async throws {
        try await update(id, with: NoteEdit(isPinned: pinned))
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

    /// Deferred from 0.4.0, when `NoteReading` had no by-notebook read and
    /// adding one would have meant an unplanned storage release. `NoteFilter`
    /// subsumes it, exactly as the plan said it would.
    public func notes(
        in notebook: NotebookID?,
        limit: Int
    ) async throws -> [Note] {
        guard limit > 0 else { return [] }
        return try await translatingStorageErrors {
            try await notes.notes(
                matching: NoteFilter(notebookID: notebook),
                sort: .mostRecent,
                limit: limit
            )
        }
    }

    // MARK: Resolution

    /// FR-1.1: a note can be captured without naming a notebook. Storage
    /// guarantees a default exists, so this never fails for want of one.
    private func resolve(_ id: NotebookID?) async throws -> NotebookID {
        guard let id else {
            return try await translatingStorageErrors {
                try await notebooks.defaultNotebook().id
            }
        }
        let found = try await translatingStorageErrors {
            try await notebooks.notebook(id)
        }
        guard found != nil else { throw ServiceError.notebookNotFound(id) }
        return id
    }
}
