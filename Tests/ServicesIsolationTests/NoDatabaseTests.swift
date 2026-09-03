import Foundation
import ServiceContracts
import SparrowDomain
import StorageContracts
import Testing
@testable import Services

/// The services, exercised with **no database linked at all**.
///
/// ⚠️ This target does not depend on `ColdStorage`. `ServicesTests` does — on
/// purpose, so the suites fail if storage's behaviour drifts from what the
/// services assume. But that leaves a question it cannot answer: *could* a
/// service run without a database?
///
/// The `grep -r "import ColdStorage" Sources/Services/` gate proves the
/// library does not link one. This target proves the services are genuinely
/// usable that way — which is what makes the layering a fact rather than a
/// build-setting.
@Suite("Services without a database")
struct NoDatabaseTests {
    private func makeStack() -> (NoteService, NotebookService, FakeStore) {
        let store = FakeStore()
        let relay = ChangeRelay(
            thresholds: .init(window: .milliseconds(1), collapseAbove: 20)
        )
        let clock = FixedSparrowClock(Date(timeIntervalSince1970: 1_700_000_000))
        return (
            NoteService(
                notes: store, notebooks: store,
                transactions: store, relay: relay, clock: clock
            ),
            NotebookService(
                notebooks: store, transactions: store,
                relay: relay, clock: clock
            ),
            store
        )
    }

    @Test("A note can be created, read and deleted with no database")
    func theWholeNoteFlowRunsOnFakes() async throws {
        let (notes, _, store) = makeStack()

        let note = try await notes.create(NoteDraft(title: "Kingfisher"))
        #expect(try await notes.note(note.id)?.plainTitle == "Kingfisher")

        try await notes.setPinned(note.id, true)
        #expect(try await notes.note(note.id)?.isPinned == true)

        try await notes.delete(note.id)
        #expect(try await notes.note(note.id) == nil)

        // The service asked storage to do all of it inside transactions.
        #expect(store.transactionCount == 3)
    }

    @Test("An unfiled draft still resolves to the default notebook")
    func resolutionWorksOnFakes() async throws {
        let (notes, _, store) = makeStack()

        let note = try await notes.create(NoteDraft(title: "Unfiled"))
        #expect(note.notebookID == store.defaultNotebookID)
    }

    @Test("Validation happens before storage is touched")
    func validationPrecedesStorage() async throws {
        let (notes, notebooks, store) = makeStack()

        await #expect(throws: ServiceError.emptyNote) {
            try await notes.create(NoteDraft())
        }
        await #expect(throws: ServiceError.emptyNotebookName) {
            try await notebooks.create(NotebookDraft(name: "   "))
        }
        #expect(store.transactionCount == 0)
    }

    @Test("A storage failure still surfaces as a ServiceError")
    func errorsAreStillTranslated() async throws {
        let store = FakeStore()
        store.failure = .corrupted("bad row")
        let notes = NoteService(
            notes: store, notebooks: store, transactions: store,
            relay: ChangeRelay(), clock: SystemSparrowClock()
        )

        do {
            _ = try await notes.recent(limit: 10)
            Issue.record("expected a failure")
        } catch is StorageError {
            Issue.record("a StorageError escaped the service layer")
        } catch let error as ServiceError {
            #expect(error == .storageUnavailable)
        }
    }
}
