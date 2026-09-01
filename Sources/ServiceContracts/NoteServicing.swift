import Foundation
import SparrowDomain

/// What the UI and the App Intents layer are allowed to ask about notes.
///
/// Depends on `SparrowDomain` only — **never on `StorageContracts`**. A caller
/// of this protocol cannot discover that storage exists, let alone that it is
/// SQLite.
public protocol NoteServicing: Sendable {
    // MARK: Commands

    @discardableResult
    func create(_ draft: NoteDraft) async throws -> Note

    @discardableResult
    func update(_ id: NoteID, with edit: NoteEdit) async throws -> Note
    func move(_ id: NoteID, to notebook: NotebookID) async throws
    func setPinned(_ id: NoteID, _ pinned: Bool) async throws
    func delete(_ id: NoteID) async throws

    // MARK: Queries

    func note(_ id: NoteID) async throws -> Note?
    func notes(_ ids: [NoteID]) async throws -> [Note]
    func recent(limit: Int) async throws -> [Note]

    /// The notes in one notebook, or in all of them when `notebook` is `nil`.
    func notes(in notebook: NotebookID?, limit: Int) async throws -> [Note]

    // MARK: Events

    var changes: AsyncStream<NoteChange> { get }
}
