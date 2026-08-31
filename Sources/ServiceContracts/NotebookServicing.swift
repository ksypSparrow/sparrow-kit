import Foundation
import SparrowDomain

/// What the UI and the App Intents layer are allowed to ask about notebooks.
///
/// Reads only in 0.2.0. `create`, `rename` and `delete` arrive in 0.3.0, when
/// storage has transactions to run them in.
public protocol NotebookServicing: Sendable {
    func all() async throws -> [Notebook]
    func notebook(_ id: NotebookID) async throws -> Notebook?

    /// Case-insensitive. The name arrives from a Shortcut or from Siri, where
    /// nobody types capitals the way the app stored them.
    func notebook(named name: String) async throws -> Notebook?

    /// **Not optional.** Storage guarantees a notebook exists, so an optional
    /// here would only push that decision into every caller.
    func defaultNotebook() async throws -> Notebook
}
