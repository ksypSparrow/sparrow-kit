import Foundation
import ColdStorage
import ServiceContracts
import SparrowDomain
import StorageContracts
import Testing
@testable import Services

@Suite("NotebookService · writes")
struct NotebookWriteTests {
    private func makeService() throws -> (NotebookService, StorageSet) {
        let storage = try ColdStorage.inMemory()
        let service = NotebookService(
            notebooks: storage.notebooks,
            transactions: storage.transactions,
            relay: ChangeRelay(thresholds: .immediate)
        )
        return (service, storage)
    }

    @Test("create returns a notebook carrying the draft's contents")
    func createCarriesTheDraft() async throws {
        let (service, _) = try makeService()

        let notebook = try await service.create(
            NotebookDraft(name: "Wetlands", colorName: "riverbank")
        )

        #expect(notebook.name == "Wetlands")
        #expect(notebook.colorName == "riverbank")
        #expect(notebook.isTopLevel)
    }

    /// The caller never supplies one. This is the service asking storage where
    /// the notebook lands, inside the same transaction that inserts it.
    @Test("create appends to the end of its siblings")
    func createAppendsToTheEnd() async throws {
        let (service, _) = try makeService()

        let first = try await service.create(NotebookDraft(name: "First"))
        let second = try await service.create(NotebookDraft(name: "Second"))

        // The seeded default already occupies index 0.
        #expect(first.sortIndex == 1)
        #expect(second.sortIndex == 2)
    }

    @Test("Nested notebooks are numbered within their own parent")
    func nestingHasItsOwnNumbering() async throws {
        let (service, _) = try makeService()
        let parent = try await service.create(NotebookDraft(name: "Surveys"))

        let child = try await service.create(
            NotebookDraft(name: "Wetlands", parentID: parent.id)
        )

        #expect(child.sortIndex == 0)
        #expect(child.parentID == parent.id)
    }

    @Test("A created notebook is immediately readable back")
    func createdNotebookIsReadable() async throws {
        let (service, _) = try makeService()
        let notebook = try await service.create(NotebookDraft(name: "Persisted"))

        #expect(try await service.notebook(notebook.id)?.name == "Persisted")
    }

    @Test("Names are trimmed", arguments: ["  Wetlands", "Wetlands  ", " Wetlands "])
    func namesAreTrimmed(raw: String) async throws {
        let (service, _) = try makeService()
        let notebook = try await service.create(NotebookDraft(name: raw))
        #expect(notebook.name == "Wetlands")
    }

    @Test("A blank name is refused before storage is touched",
          arguments: ["", "   ", "\n"])
    func blankNameIsRefused(raw: String) async throws {
        let (service, storage) = try makeService()

        await #expect(throws: ServiceError.emptyNotebookName) {
            try await service.create(NotebookDraft(name: raw))
        }
        #expect(try await storage.notebooks.allNotebooks().count == 1)
    }

    // MARK: Rename

    @Test("rename changes the name and nothing else")
    func renameTouchesOnlyTheName() async throws {
        let (service, _) = try makeService()
        let original = try await service.create(
            NotebookDraft(name: "Untitled", colorName: "riverbank")
        )

        try await service.rename(original.id, to: "Saltmarsh")

        let renamed = try await service.notebook(original.id)
        #expect(renamed?.name == "Saltmarsh")
        #expect(renamed?.colorName == "riverbank")
        #expect(renamed?.sortIndex == original.sortIndex)
        #expect(renamed?.id == original.id)
    }

    @Test("Renaming an unknown notebook is notebookNotFound")
    func renamingUnknownIsNotFound() async throws {
        let (service, _) = try makeService()
        let id = NotebookID()

        await #expect(throws: ServiceError.notebookNotFound(id)) {
            try await service.rename(id, to: "Ghost")
        }
    }

    @Test("A blank rename is refused")
    func blankRenameIsRefused() async throws {
        let (service, _) = try makeService()
        let notebook = try await service.create(NotebookDraft(name: "Keep"))

        await #expect(throws: ServiceError.emptyNotebookName) {
            try await service.rename(notebook.id, to: "  ")
        }
        #expect(try await service.notebook(notebook.id)?.name == "Keep")
    }

    // MARK: Delete

    @Test("An empty notebook can be deleted")
    func emptyNotebookDeletes() async throws {
        let (service, _) = try makeService()
        let notebook = try await service.create(NotebookDraft(name: "Transient"))

        try await service.delete(notebook.id)

        #expect(try await service.notebook(notebook.id) == nil)
    }

    /// Deleting a notebook must not silently take its contents with it.
    @Test("A notebook with children refuses to be deleted")
    func nonEmptyNotebookRefuses() async throws {
        let (service, _) = try makeService()
        let parent = try await service.create(NotebookDraft(name: "Surveys"))
        try await service.create(
            NotebookDraft(name: "Wetlands", parentID: parent.id)
        )

        await #expect(throws: ServiceError.notebookNotEmpty(parent.id)) {
            try await service.delete(parent.id)
        }
        #expect(try await service.notebook(parent.id) != nil)
    }

    @Test("Emptying a notebook makes it deletable")
    func emptiedNotebookDeletes() async throws {
        let (service, _) = try makeService()
        let parent = try await service.create(NotebookDraft(name: "Surveys"))
        let child = try await service.create(
            NotebookDraft(name: "Wetlands", parentID: parent.id)
        )

        try await service.delete(child.id)
        try await service.delete(parent.id)

        #expect(try await service.notebook(parent.id) == nil)
    }

    @Test("Deleting an unknown notebook is notebookNotFound")
    func deletingUnknownIsNotFound() async throws {
        let (service, _) = try makeService()
        let id = NotebookID()

        await #expect(throws: ServiceError.notebookNotFound(id)) {
            try await service.delete(id)
        }
    }

    /// `notebookNotEmpty` is thrown from inside `write { }`. The error mapper
    /// only translates `StorageError`, so a `ServiceError` raised in there has
    /// to arrive as itself — not flattened into `.storageUnavailable`.
    @Test("A ServiceError thrown inside a transaction survives the mapper")
    func serviceErrorsSurviveTheTransaction() async throws {
        let (service, _) = try makeService()
        let parent = try await service.create(NotebookDraft(name: "Surveys"))
        try await service.create(
            NotebookDraft(name: "Wetlands", parentID: parent.id)
        )

        do {
            try await service.delete(parent.id)
            Issue.record("expected a failure")
        } catch let error as ServiceError {
            #expect(error != .storageUnavailable)
            #expect(error == .notebookNotEmpty(parent.id))
        }
    }

    @Test("Every write goes through a transaction, so a refusal changes nothing")
    func refusedWriteLeavesNoTrace() async throws {
        let (service, storage) = try makeService()
        let parent = try await service.create(NotebookDraft(name: "Surveys"))
        try await service.create(
            NotebookDraft(name: "Wetlands", parentID: parent.id)
        )
        let before = try await storage.journal.pending(limit: 100).count

        await #expect(throws: ServiceError.self) {
            try await service.delete(parent.id)
        }

        #expect(try await storage.journal.pending(limit: 100).count == before)
    }
}
