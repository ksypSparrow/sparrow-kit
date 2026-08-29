import Foundation
import ServiceContracts
import SparrowDomain
import Testing
@testable import Services

@Suite("NoteService · delete")
struct NoteServiceDeleteTests {
    @Test("A deleted note disappears from reads")
    func deletedNoteIsGone() async throws {
        let clock = SteppingClock()
        let (service, storage) = try makeService(now: clock.now)
        let note = try await service.create(NoteDraft(title: "Transient"))

        try await service.delete(note.id)

        #expect(try await service.note(note.id) == nil)
        #expect(try await storage.notes.count() == 0)
    }

    @Test("Deleting an unknown note is noteNotFound, not storageUnavailable")
    func deletingUnknownNoteIsNotFound() async throws {
        let (service, _) = try makeService()
        let id = NoteID()

        await #expect(throws: ServiceError.noteNotFound(id)) {
            try await service.delete(id)
        }
    }

    @Test("A failed delete leaves the other notes untouched")
    func failedDeleteChangesNothing() async throws {
        let clock = SteppingClock()
        let (service, storage) = try makeService(now: clock.now)
        try await service.create(NoteDraft(title: "Survivor"))

        await #expect(throws: ServiceError.self) {
            try await service.delete(NoteID())
        }
        #expect(try await storage.notes.count() == 1)
    }
}
