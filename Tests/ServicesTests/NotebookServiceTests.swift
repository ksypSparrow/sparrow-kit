import Foundation
import ColdStorage
import ServiceContracts
import SparrowDomain
import StorageContracts
import Testing
@testable import Services

@Suite("NotebookService")
struct NotebookServiceTests {
    private func makeService() throws -> NotebookService {
        // The real in-memory store, so this suite fails if cold-storage's
        // seeding behaviour ever drifts from what the service assumes.
        NotebookService(notebooks: try ColdStorage.inMemory().notebooks)
    }

    @Test("A fresh store already has a default notebook")
    func defaultNotebookExists() async throws {
        let service = try makeService()

        let notebook = try await service.defaultNotebook()
        #expect(notebook.isTopLevel)
        #expect(!notebook.name.isEmpty)
    }

    @Test("all() returns what storage has")
    func allReturnsStoredNotebooks() async throws {
        let service = try makeService()

        let all = try await service.all()
        #expect(all.count == 1)
        #expect(all.first?.id == (try await service.defaultNotebook()).id)
    }

    @Test("Lookup by identifier finds the seeded notebook")
    func lookupByIdentifier() async throws {
        let service = try makeService()
        let seeded = try await service.defaultNotebook()

        #expect(try await service.notebook(seeded.id)?.name == seeded.name)
    }

    @Test("An unknown identifier reads as nil, not as an error")
    func unknownIdentifierIsNil() async throws {
        let service = try makeService()
        #expect(try await service.notebook(NotebookID()) == nil)
    }

    @Test("Lookup by name ignores case")
    func lookupByNameIgnoresCase() async throws {
        let service = try makeService()
        let seeded = try await service.defaultNotebook()

        let upper = try await service.notebook(named: seeded.name.uppercased())
        let lower = try await service.notebook(named: seeded.name.lowercased())
        #expect(upper?.id == seeded.id)
        #expect(lower?.id == seeded.id)
    }

    @Test("A name that matches nothing reads as nil")
    func unknownNameIsNil() async throws {
        let service = try makeService()
        #expect(try await service.notebook(named: "Wetlands") == nil)
    }

    @Test("all() passes storage's ordering through unchanged")
    func orderingPassesThrough() async throws {
        let service = NotebookService(notebooks: StubNotebookReader(notebooks: [
            makeNotebook("Zostera", sortIndex: 1),
            makeNotebook("Alder", sortIndex: 2),
            makeNotebook("Alder Carr", sortIndex: 1),
        ]))

        let names = try await service.all().map(\.name)
        #expect(names == ["Alder Carr", "Zostera", "Alder"])
    }
}

@Suite("NotebookService · error translation")
struct NotebookServiceErrorTests {
    private func failing(_ error: StorageError) -> NotebookService {
        NotebookService(notebooks: FailingNotebookReader(error: error))
    }

    /// The assertion the layering rests on. An intent that had to catch
    /// `StorageError.corrupted("malformed FTS row")` would need storage
    /// vocabulary to describe what went wrong to a person.
    @Test(
        "Every storage failure surfaces as a ServiceError",
        arguments: [
            StorageError.notFound,
            .constraintViolated("x"),
            .corrupted("x"),
            .unavailable("x"),
            .migrationFailed(from: 1, to: 2),
        ]
    )
    func storageFailuresAreTranslated(error: StorageError) async throws {
        let service = failing(error)

        do {
            _ = try await service.all()
            Issue.record("expected a failure")
        } catch is StorageError {
            Issue.record("a StorageError escaped the service layer")
        } catch let error as ServiceError {
            #expect(error == .storageUnavailable)
        }
    }

    @Test("defaultNotebook() translates too, rather than trapping")
    func defaultNotebookTranslates() async throws {
        let service = failing(.corrupted("no notebooks"))

        await #expect(throws: ServiceError.storageUnavailable) {
            try await service.defaultNotebook()
        }
    }
}
