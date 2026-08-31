import Foundation
import SparrowDomain
import StorageContracts

/// A `NotebookReading` that fails on every call.
///
/// The real store cannot be made to fail on demand, and the assertion that
/// matters here is about what happens when it does: a `StorageError` must never
/// reach the layers above. A fake is the only way to ask that question.
struct FailingNotebookReader: NotebookReading {
    let error: StorageError

    func notebook(_ id: NotebookID) async throws -> Notebook? { throw error }
    func allNotebooks() async throws -> [Notebook] { throw error }
    func notebook(named name: String) async throws -> Notebook? { throw error }
    func defaultNotebook() async throws -> Notebook { throw error }
}

/// A `NotebookReading` over a fixed list, for ordering assertions that would
/// otherwise need writes the storage layer does not have until 0.3.0.
struct StubNotebookReader: NotebookReading {
    let notebooks: [Notebook]

    func notebook(_ id: NotebookID) async throws -> Notebook? {
        notebooks.first { $0.id == id }
    }

    func allNotebooks() async throws -> [Notebook] {
        notebooks.sorted(by: Notebook.orderedBySiblingPosition)
    }

    func notebook(named name: String) async throws -> Notebook? {
        notebooks.first { $0.name.lowercased() == name.lowercased() }
    }

    func defaultNotebook() async throws -> Notebook {
        guard let first = try await allNotebooks().first else {
            throw StorageError.corrupted("the stub has no notebooks")
        }
        return first
    }
}

func makeNotebook(
    _ name: String,
    parent: NotebookID? = nil,
    sortIndex: Int = 0
) -> Notebook {
    let base = Date(timeIntervalSince1970: 1_700_000_000)
    return Notebook(
        name: name,
        parentID: parent,
        sortIndex: sortIndex,
        createdAt: base,
        updatedAt: base
    )
}
