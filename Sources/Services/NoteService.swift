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
    private let clock: any SparrowClock

    public init(
        notes: any NoteReading,
        notebooks: any NotebookReading,
        transactions: any TransactionRunning,
        relay: ChangeRelay,
        clock: any SparrowClock = SystemSparrowClock()
    ) {
        self.notes = notes
        self.notebooks = notebooks
        self.transactions = transactions
        self.relay = relay
        self.clock = clock
    }

    public nonisolated var changes: AsyncStream<NoteChange> {
        relay.noteChanges
    }

    // MARK: Commands

    @discardableResult
    public func create(_ draft: NoteDraft) async throws -> Note {
        guard !draft.isEmpty else { throw ServiceError.emptyNote }

        let notebookID = try await resolve(draft.notebookID)
        let timestamp = clock.now
        let note = Note(
            title: draft.title,
            body: draft.body,
            notebookID: notebookID,
            tagIDs: draft.tagIDs,
            kind: draft.kind,
            observedAt: draft.observedAt,
            createdAt: timestamp,
            updatedAt: timestamp
        )

        try await translatingStorageErrors {
            try await transactions.write { session in
                try Self.assertTagsExist(note.tagIDs, in: session)
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

        let timestamp = clock.now
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

                try Self.assertTagsExist(updated.tagIDs, in: session)
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
        let timestamp = clock.now

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

    // MARK: Journaling

    public func dailyNote(on day: Date) async throws -> Note? {
        try await translatingStorageErrors { try await notes.dailyNote(on: day) }
    }

    /// Today's entry, creating it if there is not one yet.
    ///
    /// ⚠️ **The race is settled by the unique index, not by a second read.**
    ///
    /// The plan calls for re-checking inside the transaction. That is not
    /// expressible: `NoteSessionAccess` has no day query — cold-storage 0.8.0
    /// put `dailyNote(on:)` on `NoteReading`, which is the *outside* protocol —
    /// and adding one would mean an unplanned storage release.
    ///
    /// It is also unnecessary, and weaker than what is here. Two intents
    /// firing at midnight both see `nil`, both try to insert, and the partial
    /// unique index lets exactly one through. The loser catches the violation
    /// and reads the winner's note. That works across *processes* too, which
    /// an in-transaction re-check would not.
    @discardableResult
    public func openOrCreateDailyNote(on day: Date) async throws -> Note {
        // The common case: today's entry exists, and reading it should not
        // open a write.
        if let existing = try await dailyNote(on: day) { return existing }

        let notebookID = try await resolve(nil)
        let timestamp = clock.now
        let note = Note(
            title: RichText(plain: Self.dailyTitle(for: day)),
            notebookID: notebookID,
            kind: .daily,
            // The day this entry is *about*, so one opened at 00:05 for
            // yesterday still belongs to yesterday.
            observedAt: day,
            createdAt: timestamp,
            updatedAt: timestamp
        )

        do {
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
        } catch let error as StorageError {
            // Someone else got there first. Their note is committed by now.
            if case .constraintViolated = error,
               let winner = try await dailyNote(on: day) {
                return winner
            }
            throw ServiceError.storageUnavailable
        }

        await relay.announce(.created(note.id))
        return note
    }

    private static func dailyTitle(for day: Date) -> String {
        day.formatted(.dateTime.year().month(.wide).day())
    }

    // MARK: Resolution

    /// Every tag a note claims must exist.
    ///
    /// ⚠️ Checked **inside** the transaction, and by the service rather than
    /// left to the database. SQLite's foreign key would reject an unknown tag,
    /// but as a `constraintViolated` that reaches a person as "Sparrow can't
    /// reach your notes right now" — and the in-memory store has no foreign
    /// key at all, so the two would disagree. One check, one message, both
    /// stores.
    private static func assertTagsExist(
        _ tagIDs: [TagID],
        in session: any StorageSession
    ) throws {
        for tagID in tagIDs where try session.tags.tag(tagID) == nil {
            throw ServiceError.tagNotFound(tagID)
        }
    }

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
