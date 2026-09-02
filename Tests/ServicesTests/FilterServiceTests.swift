import Foundation
import ColdStorage
import ServiceContracts
import SparrowDomain
import StorageContracts
import Testing
@testable import Services

@Suite("SearchService · filtering")
struct FilterServiceTests {
    private func makeStack() throws -> (SearchService, NoteService, StorageSet) {
        let storage = try ColdStorage.inMemory()
        let relay = ChangeRelay(thresholds: .immediate)
        let notes = NoteService(
            notes: storage.notes,
            notebooks: storage.notebooks,
            transactions: storage.transactions,
            relay: relay,
            clock: SteppingClock()
        )
        let search = SearchService(notes: storage.notes, index: storage.search)
        return (search, notes, storage)
    }

    @discardableResult
    private func seed(_ notes: NoteService) async throws -> [String: Note] {
        var made: [String: Note] = [:]
        for (title, kind, pinned) in [
            ("heron sketch", NoteKind.sketch, true),
            ("heron voice", NoteKind.voice, false),
            ("kingfisher sketch", NoteKind.sketch, false),
        ] {
            let note = try await notes.create(
                NoteDraft(title: RichText(plain: title), kind: kind)
            )
            if pinned { try await notes.setPinned(note.id, true) }
            made[title] = note
        }
        return made
    }

    /// `.all` with a limit is `recent` by another name, and the two must not
    /// disagree — a Find action with no criteria and a list of recents are the
    /// same question.
    @Test(".all behaves like recent")
    func allBehavesLikeRecent() async throws {
        let (search, notes, _) = try makeStack()
        try await seed(notes)

        let filtered = try await search.filter(.all, sort: .mostRecent, limit: 10)
        let recent = try await notes.recent(limit: 10)
        #expect(filtered.map(\.id) == recent.map(\.id))
    }

    @Test("Text and properties apply together")
    func textAndPropertiesCombine() async throws {
        let (search, notes, _) = try makeStack()
        let made = try await seed(notes)

        let found = try await search.filter(
            NoteFilter(text: "heron", kinds: [.sketch]),
            sort: .mostRecent, limit: 10
        )
        #expect(found.map(\.id) == [made["heron sketch"]?.id])
    }

    @Test("Every sort field and order is honoured",
          arguments: NoteSort.Field.allCases)
    func everySortIsHonoured(field: NoteSort.Field) async throws {
        let (search, notes, _) = try makeStack()
        try await seed(notes)

        let everything = try await search.filter(.all, sort: .mostRecent, limit: 100)

        for order in NoteSort.Order.allCases {
            let sort = NoteSort(field: field, order: order)
            let fromService = try await search.filter(.all, sort: sort, limit: 100)
            // Compared against the domain's own ordering, not a hand-written
            // expectation — the same discipline storage uses.
            #expect(fromService.map(\.id) == everything.sorted(by: sort.orders).map(\.id))
        }
    }

    @Test("count(matching:) agrees with what filter returns")
    func countAgreesWithFilter() async throws {
        let (search, notes, _) = try makeStack()
        try await seed(notes)

        for filter in [
            NoteFilter.all,
            NoteFilter(kinds: [.sketch]),
            NoteFilter(text: "heron"),
            NoteFilter(isPinned: true),
        ] {
            let counted = try await search.count(matching: filter)
            let listed = try await search.filter(filter, sort: .mostRecent, limit: 1_000)
            #expect(counted == listed.count)
        }
    }

    @Test("A limit of zero or less returns nothing", arguments: [0, -1])
    func nonPositiveLimitReturnsNothing(limit: Int) async throws {
        let (search, notes, _) = try makeStack()
        try await seed(notes)

        #expect(try await search.filter(.all, sort: .mostRecent, limit: limit).isEmpty)
    }

    @Test("A deleted note matches no filter")
    func deletedNotesMatchNothing() async throws {
        let (search, notes, _) = try makeStack()
        let made = try await seed(notes)
        let gone = try #require(made["heron voice"])

        try await notes.delete(gone.id)

        for filter in [NoteFilter.all, NoteFilter(text: "heron"), NoteFilter(kinds: [.voice])] {
            let found = try await search.filter(filter, sort: .mostRecent, limit: 10)
            #expect(!found.contains { $0.id == gone.id })
        }
    }

    @Test("A hostile filter is harmless")
    func hostileFilterIsHarmless() async throws {
        let (search, notes, _) = try makeStack()
        try await seed(notes)

        for hostile in ["'; DROP TABLE note; --", "\" OR 1=1 --", "%", "_"] {
            _ = try await search.filter(
                NoteFilter(text: hostile), sort: .mostRecent, limit: 10
            )
        }
        #expect(try await search.count(matching: .all) == 3)
    }
}

@Suite("NoteService · notes(in:)")
struct NotesInNotebookTests {
    /// Deferred from 0.4.0, when `NoteReading` had no by-notebook read and
    /// adding one would have meant an unplanned storage release. `NoteFilter`
    /// subsumes it, exactly as the plan predicted.
    @Test("Notes are scoped to one notebook")
    func notesAreScopedToANotebook() async throws {
        let storage = try ColdStorage.inMemory()
        let relay = ChangeRelay(thresholds: .immediate)
        let clock = SteppingClock()
        let notes = NoteService(
            notes: storage.notes, notebooks: storage.notebooks,
            transactions: storage.transactions, relay: relay, clock: clock
        )
        let notebooks = NotebookService(
            notebooks: storage.notebooks,
            transactions: storage.transactions, relay: relay, clock: clock
        )

        let wetlands = try await notebooks.create(NotebookDraft(name: "Wetlands"))
        let here = try await notes.create(
            NoteDraft(title: "In Wetlands", notebookID: wetlands.id)
        )
        try await notes.create(NoteDraft(title: "In the default"))

        let scoped = try await notes.notes(in: wetlands.id, limit: 10)
        #expect(scoped.map(\.id) == [here.id])
    }

    @Test("A nil notebook means every notebook")
    func nilNotebookMeansEverything() async throws {
        let storage = try ColdStorage.inMemory()
        let relay = ChangeRelay(thresholds: .immediate)
        let notes = NoteService(
            notes: storage.notes, notebooks: storage.notebooks,
            transactions: storage.transactions, relay: relay,
            clock: SteppingClock()
        )
        try await notes.create(NoteDraft(title: "One"))
        try await notes.create(NoteDraft(title: "Two"))

        #expect(try await notes.notes(in: nil, limit: 10).count == 2)
    }
}
