import Foundation
import ColdStorage
import ServiceContracts
import SparrowDomain
import StorageContracts
import Testing
@testable import Services

@Suite("TagService")
struct TagServiceTests {
    private func makeStack() throws -> (TagService, NoteService, StorageSet) {
        let storage = try ColdStorage.inMemory()
        let relay = ChangeRelay(thresholds: .immediate)
        let clock = SteppingClock()
        let tags = TagService(
            tags: storage.tags,
            transactions: storage.transactions,
            relay: relay,
            now: clock.now
        )
        let notes = NoteService(
            notes: storage.notes,
            notebooks: storage.notebooks,
            transactions: storage.transactions,
            relay: relay,
            now: clock.now
        )
        return (tags, notes, storage)
    }

    /// The property the whole tag design rests on, reached through the
    /// service rather than the type.
    @Test("ensure twice returns the same identifier")
    func ensureIsIdempotent() async throws {
        let (tags, _, _) = try makeStack()

        let first = try await tags.ensure("Field Survey")
        let second = try await tags.ensure("Field Survey")

        #expect(first.id == second.id)
        #expect(try await tags.all().count == 1)
    }

    @Test("Different spellings reach the same tag", arguments: [
        "field survey", "FIELD SURVEY", "  Field, Survey  ", "field-survey",
    ])
    func spellingsConverge(spelling: String) async throws {
        let (tags, _, _) = try makeStack()
        let canonical = try await tags.ensure("Field Survey")

        let again = try await tags.ensure(spelling)

        #expect(again.id == canonical.id)
        #expect(try await tags.all().count == 1)
    }

    @Test("The label follows the most recent spelling")
    func labelFollowsTheLatestSpelling() async throws {
        let (tags, _, _) = try makeStack()
        try await tags.ensure("field survey")

        try await tags.ensure("Field Survey")

        #expect(try await tags.all().first?.label == "Field Survey")
    }

    /// `TagID.init?(normalizing:)` is failable, so the service has to say
    /// something a person can act on rather than trapping.
    @Test("A label with no slug is refused",
          arguments: ["", "   ", "!!!", "🐦", "---"])
    func unslugableLabelsAreRefused(label: String) async throws {
        let (tags, _, _) = try makeStack()

        await #expect(throws: ServiceError.emptyTagLabel) {
            try await tags.ensure(label)
        }
        #expect(try await tags.all().isEmpty)
    }

    @Test("Deleting a tag removes it from the list")
    func deleteRemovesTheTag() async throws {
        let (tags, _, _) = try makeStack()
        let tag = try await tags.ensure("Transient")

        try await tags.delete(tag.id)

        #expect(try await tags.all().isEmpty)
        #expect(try await tags.tag(tag.id) == nil)
    }

    @Test("Deleting an unknown tag is tagNotFound")
    func deletingUnknownIsNotFound() async throws {
        let (tags, _, _) = try makeStack()
        let id = TagID(normalizing: "absent")!

        await #expect(throws: ServiceError.tagNotFound(id)) {
            try await tags.delete(id)
        }
    }

    @Test("Re-ensuring a deleted tag brings it back")
    func ensureRevivesADeletedTag() async throws {
        let (tags, _, _) = try makeStack()
        let tag = try await tags.ensure("Wetlands")
        try await tags.delete(tag.id)

        let revived = try await tags.ensure("Wetlands")

        #expect(revived.id == tag.id)
        #expect(try await tags.all().count == 1)
    }

    // MARK: Events

    @Test("A new tag announces created, an existing one announces updated")
    func announcementsDistinguishNewFromExisting() async throws {
        let (tags, _, _) = try makeStack()
        var events = tags.changes.makeAsyncIterator()

        let tag = try await tags.ensure("Wetlands")
        #expect(await events.next() == .created(tag.id))

        try await tags.ensure("wetlands")
        #expect(await events.next() == .updated(tag.id))
    }

    @Test("A refused ensure announces nothing")
    func refusedEnsureAnnouncesNothing() async throws {
        let (tags, _, _) = try makeStack()
        var events = tags.changes.makeAsyncIterator()

        await #expect(throws: ServiceError.emptyTagLabel) {
            try await tags.ensure("🐦")
        }

        // The next event must be the successful one that follows.
        let real = try await tags.ensure("Wetlands")
        #expect(await events.next() == .created(real.id))
    }
}

@Suite("Tagging notes through the service")
struct NoteTaggingTests {
    private func makeStack() throws -> (TagService, NoteService, SearchService) {
        let storage = try ColdStorage.inMemory()
        let relay = ChangeRelay(thresholds: .immediate)
        let clock = SteppingClock()
        return (
            TagService(
                tags: storage.tags, transactions: storage.transactions,
                relay: relay, now: clock.now
            ),
            NoteService(
                notes: storage.notes, notebooks: storage.notebooks,
                transactions: storage.transactions, relay: relay, now: clock.now
            ),
            SearchService(notes: storage.notes, index: storage.search)
        )
    }

    @Test("A note can be created already tagged")
    func notesCanBeCreatedTagged() async throws {
        let (tags, notes, _) = try makeStack()
        let wetlands = try await tags.ensure("Wetlands")

        let note = try await notes.create(
            NoteDraft(title: "Kingfisher", tagIDs: [wetlands.id])
        )

        #expect(try await notes.note(note.id)?.tagIDs == [wetlands.id])
    }

    /// Matching `NoteEdit` semantics: an edit describes the state it wants.
    @Test("Tags assigned in update replace rather than append")
    func updateReplacesTags() async throws {
        let (tags, notes, _) = try makeStack()
        let old = try await tags.ensure("Old")
        let new = try await tags.ensure("New")
        let note = try await notes.create(
            NoteDraft(title: "Retagged", tagIDs: [old.id])
        )

        try await notes.update(note.id, with: NoteEdit(tagIDs: [new.id]))

        #expect(try await notes.note(note.id)?.tagIDs == [new.id])
    }

    @Test("An update that names no tags leaves them alone")
    func updateWithoutTagsLeavesThemAlone() async throws {
        let (tags, notes, _) = try makeStack()
        let kept = try await tags.ensure("Kept")
        let note = try await notes.create(
            NoteDraft(title: "Pinned later", tagIDs: [kept.id])
        )

        try await notes.setPinned(note.id, true)

        #expect(try await notes.note(note.id)?.tagIDs == [kept.id])
    }

    @Test("Filtering by tag reaches storage unchanged")
    func filteringByTagWorksThroughTheService() async throws {
        let (tags, notes, search) = try makeStack()
        let wetlands = try await tags.ensure("Wetlands")
        let survey = try await tags.ensure("Survey")

        let both = try await notes.create(
            NoteDraft(title: "Both", tagIDs: [wetlands.id, survey.id])
        )
        try await notes.create(
            NoteDraft(title: "One", tagIDs: [wetlands.id])
        )

        let found = try await search.filter(
            NoteFilter(tagIDs: [wetlands.id, survey.id]),
            sort: .mostRecent, limit: 10
        )
        #expect(found.map(\.id) == [both.id])
    }

    @Test("Deleting a tag leaves the notes that carried it")
    func deletingATagKeepsNotes() async throws {
        let (tags, notes, _) = try makeStack()
        let doomed = try await tags.ensure("Doomed")
        let note = try await notes.create(
            NoteDraft(title: "Survivor", tagIDs: [doomed.id])
        )

        try await tags.delete(doomed.id)

        let read = try await notes.note(note.id)
        #expect(read?.plainTitle == "Survivor")
        #expect(read?.tagIDs.isEmpty == true)
    }
}

@Suite("Tagging · unknown tags")
struct UnknownTagTests {
    private func makeStack() throws -> (TagService, NoteService, StorageSet) {
        let storage = try ColdStorage.inMemory()
        let relay = ChangeRelay(thresholds: .immediate)
        let clock = SteppingClock()
        return (
            TagService(
                tags: storage.tags, transactions: storage.transactions,
                relay: relay, now: clock.now
            ),
            NoteService(
                notes: storage.notes, notebooks: storage.notebooks,
                transactions: storage.transactions, relay: relay, now: clock.now
            ),
            storage
        )
    }

    /// SQLite's foreign key would reject this too, but as a
    /// `constraintViolated` that reaches a person as "Sparrow can't reach your
    /// notes right now" — and the in-memory store has no foreign key at all.
    /// One check in the service means one message, and both stores agree.
    @Test("Creating a note with a tag that does not exist is refused")
    func creatingWithUnknownTagIsRefused() async throws {
        let (_, notes, storage) = try makeStack()
        let ghost = TagID(normalizing: "ghost")!

        await #expect(throws: ServiceError.tagNotFound(ghost)) {
            try await notes.create(NoteDraft(title: "Doomed", tagIDs: [ghost]))
        }
        #expect(try await storage.notes.count() == 0)
    }

    @Test("Assigning a tag that does not exist is refused")
    func assigningUnknownTagIsRefused() async throws {
        let (tags, notes, _) = try makeStack()
        let real = try await tags.ensure("Real")
        let note = try await notes.create(
            NoteDraft(title: "Tagged", tagIDs: [real.id])
        )
        let ghost = TagID(normalizing: "ghost")!

        await #expect(throws: ServiceError.tagNotFound(ghost)) {
            try await notes.update(note.id, with: NoteEdit(tagIDs: [ghost]))
        }
        // The refusal rolled back, so the original tag survives.
        #expect(try await notes.note(note.id)?.tagIDs == [real.id])
    }

    @Test("A tag deleted after assignment does not block later edits")
    func deletedTagDoesNotBlockEdits() async throws {
        let (tags, notes, _) = try makeStack()
        let doomed = try await tags.ensure("Doomed")
        let note = try await notes.create(
            NoteDraft(title: "Note", tagIDs: [doomed.id])
        )
        try await tags.delete(doomed.id)

        // The note's tags now read as empty, so an unrelated edit carries no
        // stale identifier into the check.
        try await notes.setPinned(note.id, true)

        #expect(try await notes.note(note.id)?.isPinned == true)
    }
}
