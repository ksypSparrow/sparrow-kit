import Foundation
import ServiceContracts
import SparrowDomain
import Testing
@testable import Services

@Suite("NoteService · change events")
struct NoteChangeTests {
    @Test("create announces created, not updated")
    func createAnnouncesCreated() async throws {
        let (service, _) = try makeService()
        var events = service.changes.makeAsyncIterator()

        let note = try await service.create(NoteDraft(title: "Announced"))

        #expect(await events.next() == .created(note.id))
    }

    @Test("delete announces deleted")
    func deleteAnnouncesDeleted() async throws {
        let clock = SteppingClock()
        let (service, _) = try makeService(now: clock.now)
        let note = try await service.create(NoteDraft(title: "Doomed"))

        var events = service.changes.makeAsyncIterator()
        try await service.delete(note.id)

        #expect(await events.next() == .deleted(note.id))
    }

    @Test("A refused create announces nothing")
    func refusedCreateAnnouncesNothing() async throws {
        let (service, _) = try makeService()
        var events = service.changes.makeAsyncIterator()

        await #expect(throws: ServiceError.emptyNote) {
            try await service.create(NoteDraft())
        }

        // The next event must be the successful create, not the refused one.
        let note = try await service.create(NoteDraft(title: "Accepted"))
        #expect(await events.next() == .created(note.id))
    }

    @Test("Two observers both receive the same event")
    func eventsAreMulticast() async throws {
        let (service, _) = try makeService()
        var first = service.changes.makeAsyncIterator()
        var second = service.changes.makeAsyncIterator()

        let note = try await service.create(NoteDraft(title: "Broadcast"))

        #expect(await first.next() == .created(note.id))
        #expect(await second.next() == .created(note.id))
    }
}
