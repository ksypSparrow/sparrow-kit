import Foundation
import SparrowDomain
import StorageContracts

/// A whole storage layer in a dictionary, with no database behind it.
///
/// Written against `StorageContracts` alone — which is the point. If the
/// service layer had leaked a storage implementation detail into its own API,
/// this file could not exist.
final class FakeStore: @unchecked Sendable {
    let defaultNotebookID = NotebookID()
    private(set) var transactionCount = 0
    var failure: StorageError?

    private var notes: [NoteID: Note] = [:]
    private var notebooks: [NotebookID: Notebook]

    init() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let fallback = Notebook(
            id: defaultNotebookID, name: "Field Notes",
            createdAt: now, updatedAt: now
        )
        notebooks = [fallback.id: fallback]
    }

    private func check() throws {
        if let failure { throw failure }
    }
}

// MARK: - Reading

extension FakeStore: NoteReading {
    func note(_ id: NoteID) async throws -> Note? {
        try check()
        return notes[id]
    }

    func notes(_ ids: [NoteID]) async throws -> [Note] {
        try check()
        return ids.compactMap { notes[$0] }
    }

    func recentNotes(limit: Int) async throws -> [Note] {
        try check()
        return Array(notes.values.sorted { $0.updatedAt > $1.updatedAt }.prefix(limit))
    }

    func notes(
        matching filter: NoteFilter, sort: NoteSort, limit: Int
    ) async throws -> [Note] {
        try check()
        return Array(
            notes.values.filter(filter.matchesFields).sorted(by: sort.orders).prefix(limit)
        )
    }

    func count(matching filter: NoteFilter) async throws -> Int {
        try check()
        return notes.values.count(where: filter.matchesFields)
    }

    func dailyNote(on day: Date) async throws -> Note? {
        try check()
        let calendar = Calendar.current
        return notes.values.first {
            $0.kind == .daily && calendar.isDate($0.happenedAt, inSameDayAs: day)
        }
    }
}

extension FakeStore: NotebookReading {
    func notebook(_ id: NotebookID) async throws -> Notebook? {
        try check()
        return notebooks[id]
    }

    func allNotebooks() async throws -> [Notebook] {
        try check()
        return notebooks.values.sorted(by: Notebook.orderedBySiblingPosition)
    }

    func notebook(named name: String) async throws -> Notebook? {
        try check()
        return notebooks.values.first { $0.name.lowercased() == name.lowercased() }
    }

    func defaultNotebook() async throws -> Notebook {
        try check()
        guard let found = notebooks[defaultNotebookID] else {
            throw StorageError.corrupted("no default notebook")
        }
        return found
    }
}

// MARK: - Writing

extension FakeStore: TransactionRunning {
    func write<T: Sendable>(
        _ body: @Sendable (any StorageSession) throws -> T
    ) async throws -> T {
        try check()
        transactionCount += 1
        let snapshot = (notes, notebooks)
        do {
            return try body(FakeSession(store: self))
        } catch {
            // Same contract as the real stores: nothing survives a failure.
            (notes, notebooks) = snapshot
            throw error
        }
    }

    fileprivate func insert(_ note: Note) throws {
        guard notes[note.id] == nil else {
            throw StorageError.constraintViolated("duplicate note")
        }
        notes[note.id] = note
    }

    fileprivate func update(_ note: Note) throws {
        guard notes[note.id] != nil else { throw StorageError.notFound }
        notes[note.id] = note
    }

    fileprivate func remove(_ id: NoteID) throws {
        guard notes.removeValue(forKey: id) != nil else {
            throw StorageError.notFound
        }
    }

    fileprivate func insert(_ notebook: Notebook) throws {
        guard notebooks[notebook.id] == nil else {
            throw StorageError.constraintViolated("duplicate notebook")
        }
        notebooks[notebook.id] = notebook
    }

    fileprivate func update(_ notebook: Notebook) throws {
        guard notebooks[notebook.id] != nil else { throw StorageError.notFound }
        notebooks[notebook.id] = notebook
    }

    fileprivate func remove(_ id: NotebookID) throws {
        guard notebooks.removeValue(forKey: id) != nil else {
            throw StorageError.notFound
        }
    }

    fileprivate func siblingCount(under parent: NotebookID?) -> Int {
        notebooks.values.count { $0.parentID == parent }
    }

    fileprivate func note(id: NoteID) -> Note? { notes[id] }
    fileprivate func notebook(id: NotebookID) -> Notebook? { notebooks[id] }
    fileprivate func notebook(named name: String) -> Notebook? {
        notebooks.values.first { $0.name.lowercased() == name.lowercased() }
    }
}

private struct FakeSession: StorageSession {
    let store: FakeStore

    var notes: any NoteSessionAccess { FakeNotes(store: store) }
    var notebooks: any NotebookSessionAccess { FakeNotebooks(store: store) }
    var tags: any TagSessionAccess { FakeTags() }
    var index: any SearchIndexWriting { FakeIndex() }
    var journal: any ChangeJournalWriting { FakeJournal() }
}

private struct FakeNotes: NoteSessionAccess {
    let store: FakeStore
    func note(_ id: NoteID) throws -> Note? { store.note(id: id) }
    func insert(_ note: Note) throws { try store.insert(note) }
    func update(_ note: Note) throws { try store.update(note) }
    func markDeleted(_ id: NoteID, at date: Date) throws { try store.remove(id) }
}

private struct FakeNotebooks: NotebookSessionAccess {
    let store: FakeStore
    func notebook(_ id: NotebookID) throws -> Notebook? { store.notebook(id: id) }
    func notebook(named name: String) throws -> Notebook? {
        store.notebook(named: name)
    }
    func siblingCount(under parent: NotebookID?) throws -> Int {
        store.siblingCount(under: parent)
    }
    func insert(_ notebook: Notebook) throws { try store.insert(notebook) }
    func update(_ notebook: Notebook) throws { try store.update(notebook) }
    func markDeleted(_ id: NotebookID, at date: Date) throws {
        try store.remove(id)
    }
}

private struct FakeTags: TagSessionAccess {
    func tag(_ id: TagID) throws -> Tag? { nil }
    func upsert(_ tag: Tag) throws {}
    func markDeleted(_ id: TagID, at date: Date) throws {}
}

private struct FakeIndex: SearchIndexWriting {
    func index(_ note: Note) throws {}
    func remove(_ id: NoteID) throws {}
}

private struct FakeJournal: ChangeJournalWriting {
    @discardableResult
    func record(_ draft: JournalDraft) throws -> JournalEntry {
        JournalEntry(
            id: UUID(), sequence: 0, subject: draft.subject,
            operation: draft.operation, payload: draft.payload,
            recordedAt: draft.recordedAt
        )
    }
}
