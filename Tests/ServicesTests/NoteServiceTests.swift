import Foundation
import ServiceContracts
import SparrowDomain
import Testing
@testable import Services

@Suite("NoteService")
struct NoteServiceTests {
    @Test("create returns a note carrying the draft's contents")
    func createCarriesTheDraft() async throws {
        let (service, _) = try makeService()
        let draft = NoteDraft(
            title: "Kingfisher",
            body: "North bank, 40 minutes."
        )

        let note = try await service.create(draft)

        #expect(note.title == draft.title)
        #expect(note.body == draft.body)
    }

    @Test("create stamps both timestamps from the injected clock")
    func createStampsTheClock() async throws {
        let fixed = Date(timeIntervalSince1970: 1_700_000_000)
        let (service, _) = try makeService(clock: FixedSparrowClock(fixed))

        let note = try await service.create(NoteDraft(title: "Stamped"))

        #expect(note.createdAt == fixed)
        #expect(note.updatedAt == fixed)
    }

    @Test("A created note is immediately readable back")
    func createdNoteIsReadable() async throws {
        let (service, _) = try makeService()
        let note = try await service.create(NoteDraft(title: "Persisted"))

        #expect(try await service.note(note.id) == note)
    }

    @Test("An empty draft is refused before storage is touched")
    func emptyDraftIsRefused() async throws {
        let (service, storage) = try makeService()

        await #expect(throws: ServiceError.emptyNote) {
            try await service.create(NoteDraft())
        }
        #expect(try await storage.notes.count() == 0)
    }

    @Test("recent returns newest first and honours the limit")
    func recentIsOrderedNewestFirst() async throws {
        let clock = SteppingClock()
        let (service, _) = try makeService(clock: clock)

        for title in ["Oldest", "Middle", "Newest"] {
            try await service.create(NoteDraft(title: RichText(plain: title)))
        }

        let recent = try await service.recent(limit: 2)
        #expect(recent.map(\.plainTitle) == ["Newest", "Middle"])
    }

    @Test("notes(_:) resolves several identifiers at once")
    func notesResolvesManyIdentifiers() async throws {
        let clock = SteppingClock()
        let (service, _) = try makeService(clock: clock)
        let first = try await service.create(NoteDraft(title: "First"))
        let second = try await service.create(NoteDraft(title: "Second"))

        let found = try await service.notes([first.id, second.id])
        #expect(Set(found.map(\.plainTitle)) == ["First", "Second"])
    }

    @Test("An unknown identifier reads as nil, not as an error")
    func unknownIdentifierIsNil() async throws {
        let (service, _) = try makeService()
        #expect(try await service.note(NoteID()) == nil)
    }
}
