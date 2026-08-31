import Foundation
import SparrowDomain

/// What the UI and the App Intents layer are allowed to ask about notebooks.
///
public protocol NotebookServicing: Sendable {
    // MARK: Commands

    /// Creates a notebook at the end of its siblings.
    ///
    /// The caller does not supply a `sortIndex`: where a new notebook lands
    /// depends on how many siblings it will have, which a Shortcut cannot know.
    @discardableResult
    func create(_ draft: NotebookDraft) async throws -> Notebook
    func rename(_ id: NotebookID, to name: String) async throws

    /// Tombstones a notebook.
    ///
    /// Refuses if anything is still inside it — deleting a notebook should not
    /// silently take its contents with it.
    func delete(_ id: NotebookID) async throws

    // MARK: Queries

    func all() async throws -> [Notebook]
    func notebook(_ id: NotebookID) async throws -> Notebook?

    /// Case-insensitive. The name arrives from a Shortcut or from Siri, where
    /// nobody types capitals the way the app stored them.
    func notebook(named name: String) async throws -> Notebook?

    /// **Not optional.** Storage guarantees a notebook exists, so an optional
    /// here would only push that decision into every caller.
    func defaultNotebook() async throws -> Notebook

    // MARK: Events

    var changes: AsyncStream<NotebookChange> { get }
}
