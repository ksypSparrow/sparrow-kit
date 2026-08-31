import Foundation
import ServiceContracts
import SparrowDomain
import StorageContracts

/// Notebook use cases.
///
/// A thin actor in 0.2.0 — every method is a read, and the service's only job
/// is to translate storage's vocabulary into one the app can act on. It gains
/// real work in 0.3.0, when creating a notebook has to validate a name and
/// reject a cycle in the parent chain.
public actor NotebookService: NotebookServicing {
    private let notebooks: any NotebookReading

    public init(notebooks: any NotebookReading) {
        self.notebooks = notebooks
    }

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
