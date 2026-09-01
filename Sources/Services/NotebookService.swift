import Foundation
import ServiceContracts
import SparrowDomain
import StorageContracts

/// Notebook use cases.
///
/// Every command opens exactly one `write { }`. Nothing here reaches a writer
/// any other way, because there is no other way to reach one.
public actor NotebookService: NotebookServicing {
    private let notebooks: any NotebookReading
    private let transactions: any TransactionRunning
    private let relay: ChangeRelay
    private let now: @Sendable () -> Date

    public init(
        notebooks: any NotebookReading,
        transactions: any TransactionRunning,
        relay: ChangeRelay,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.notebooks = notebooks
        self.transactions = transactions
        self.relay = relay
        self.now = now
    }

    public nonisolated var changes: AsyncStream<NotebookChange> {
        relay.notebookChanges
    }

    // MARK: Commands

    @discardableResult
    public func create(_ draft: NotebookDraft) async throws -> Notebook {
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw ServiceError.emptyNotebookName }

        let timestamp = now()
        let notebook = try await translatingStorageErrors {
            try await transactions.write { session in
                // Storage answers where this lands, because only storage knows
                // how many siblings there already are.
                let position = try session.notebooks
                    .siblingCount(under: draft.parentID)

                let notebook = Notebook(
                    name: name,
                    parentID: draft.parentID,
                    colorName: draft.colorName,
                    sortIndex: position,
                    createdAt: timestamp,
                    updatedAt: timestamp
                )
                try session.notebooks.insert(notebook)
                try session.journal.record(
                    JournalDraft(
                        subject: .notebook(notebook.id),
                        operation: .upsert,
                        payload: try JSONEncoder().encode(notebook),
                        recordedAt: timestamp
                    )
                )
                return notebook
            }
        }

        await relay.announce(.created(notebook.id))
        return notebook
    }

    public func rename(_ id: NotebookID, to name: String) async throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw ServiceError.emptyNotebookName }

        let timestamp = now()
        try await translatingStorageErrors(missing: .notebookNotFound(id)) {
            try await transactions.write { session in
                guard let current = try session.notebooks.notebook(id) else {
                    throw ServiceError.notebookNotFound(id)
                }
                let renamed = current.applying(
                    NotebookEdit(name: name),
                    at: timestamp
                )
                try session.notebooks.update(renamed)
                try session.journal.record(
                    JournalDraft(
                        subject: .notebook(id),
                        operation: .upsert,
                        payload: try JSONEncoder().encode(renamed),
                        recordedAt: timestamp
                    )
                )
            }
        }

        await relay.announce(.updated(id))
    }

    public func delete(_ id: NotebookID) async throws {
        let timestamp = now()
        try await translatingStorageErrors(missing: .notebookNotFound(id)) {
            try await transactions.write { session in
                guard try session.notebooks.notebook(id) != nil else {
                    throw ServiceError.notebookNotFound(id)
                }
                // Checked inside the transaction, not before it. A check made
                // outside could be true when it ran and false by the time the
                // delete lands.
                let children = try session.notebooks.siblingCount(under: id)
                guard children == 0 else {
                    throw ServiceError.notebookNotEmpty(id)
                }

                try session.notebooks.markDeleted(id, at: timestamp)
                try session.journal.record(
                    JournalDraft(
                        subject: .notebook(id),
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

    public func all() async throws -> [Notebook] {
        try await translatingStorageErrors { try await notebooks.allNotebooks() }
    }

    public func notebook(_ id: NotebookID) async throws -> Notebook? {
        try await translatingStorageErrors { try await notebooks.notebook(id) }
    }

    public func notebook(named name: String) async throws -> Notebook? {
        try await translatingStorageErrors {
            try await notebooks.notebook(named: name)
        }
    }

    public func defaultNotebook() async throws -> Notebook {
        try await translatingStorageErrors {
            try await notebooks.defaultNotebook()
        }
    }
}
