import Foundation
import ColdStorage
import ServiceContracts
import SparrowDomain
import StorageContracts
import Testing
@testable import Services

@Suite("SearchService")
struct SearchServiceTests {
    private func makeStack() throws -> (SearchService, NoteService, StorageSet) {
        let storage = try ColdStorage.inMemory()
        let relay = ChangeRelay(thresholds: .immediate)
        let notes = NoteService(
            notes: storage.notes,
            notebooks: storage.notebooks,
            transactions: storage.transactions,
            relay: relay,
            now: SteppingClock().now
        )
        let search = SearchService(notes: storage.notes, index: storage.search)
        return (search, notes, storage)
    }

    @Test("A note is findable by a word in its title")
    func findsByTitle() async throws {
        let (search, notes, _) = try makeStack()
        let note = try await notes.create(NoteDraft(title: "Kingfisher"))

        #expect(try await search.search("kingfisher", limit: 10).map(\.id) == [note.id])
    }

    @Test("A note is findable by a word in its body")
    func findsByBody() async throws {
        let (search, notes, _) = try makeStack()
        let note = try await notes.create(
            NoteDraft(title: "Tuesday", body: "A heron on the north bank")
        )

        #expect(try await search.search("heron", limit: 10).map(\.id) == [note.id])
    }

    /// FR-1.3. The service inherits this from the index rather than
    /// implementing it, which is exactly what should happen — but a test here
    /// is what proves the two are actually wired together.
    @Test("Diacritics are ignored through the service")
    func diacriticsAreIgnored() async throws {
        let (search, notes, _) = try makeStack()
        let note = try await notes.create(NoteDraft(title: "Herón at dusk"))

        #expect(try await search.search("heron", limit: 10).map(\.id) == [note.id])
    }

    /// An empty search box must not become "show me everything". A list that
    /// silently returns the whole database is a performance problem and a
    /// confusing one.
    @Test("An empty query returns nothing, not everything",
          arguments: ["", "   ", "\n"])
    func emptyQueryReturnsNothing(query: String) async throws {
        let (search, notes, _) = try makeStack()
        try await notes.create(NoteDraft(title: "Kingfisher"))

        #expect(try await search.search(query, limit: 10).isEmpty)
    }

    @Test("A limit of zero or less returns nothing", arguments: [0, -1])
    func nonPositiveLimitReturnsNothing(limit: Int) async throws {
        let (search, notes, _) = try makeStack()
        try await notes.create(NoteDraft(title: "Kingfisher"))

        #expect(try await search.search("kingfisher", limit: limit).isEmpty)
        #expect(try await search.suggestions(limit: limit).isEmpty)
    }

    @Test("A deleted note is not findable")
    func deletedNotesAreExcluded() async throws {
        let (search, notes, _) = try makeStack()
        let gone = try await notes.create(NoteDraft(title: "heron gone"))
        let stays = try await notes.create(NoteDraft(title: "heron stays"))

        try await notes.delete(gone.id)

        #expect(try await search.search("heron", limit: 10).map(\.id) == [stays.id])
    }

    @Test("An edited note is findable by its new words, not its old ones")
    func editsAreReflected() async throws {
        let (search, notes, _) = try makeStack()
        let note = try await notes.create(NoteDraft(title: "kingfisher"))

        try await notes.update(
            note.id, with: NoteEdit(title: RichText(plain: "albatross"))
        )

        #expect(try await search.search("kingfisher", limit: 10).isEmpty)
        #expect(try await search.search("albatross", limit: 10).map(\.id) == [note.id])
    }

    /// The index decides the order and `notes(_:)` promises to keep it. If
    /// that promise breaks, results silently re-sort — which looks like a
    /// ranking bug rather than a contract violation, and is why it is asserted
    /// here rather than left to storage's own tests.
    @Test("Result order comes from the index, not from the fetch")
    func orderSurvivesTheFetch() async throws {
        let (search, notes, _) = try makeStack()
        var created: [NoteID] = []
        for title in ["heron one", "heron two", "heron three"] {
            created.append(
                try await notes.create(NoteDraft(title: RichText(plain: title))).id
            )
        }

        let found = try await search.search("heron", limit: 10).map(\.id)
        // Newest first, which is the reverse of creation order.
        #expect(found == created.reversed())
    }

    @Test("The limit is honoured")
    func limitIsHonoured() async throws {
        let (search, notes, _) = try makeStack()
        for title in ["heron one", "heron two", "heron three"] {
            try await notes.create(NoteDraft(title: RichText(plain: title)))
        }

        #expect(try await search.search("heron", limit: 2).count == 2)
    }

    @Test("Suggestions are the most recent notes")
    func suggestionsAreRecent() async throws {
        let (search, notes, _) = try makeStack()
        var created: [NoteID] = []
        for title in ["one", "two", "three"] {
            created.append(
                try await notes.create(NoteDraft(title: RichText(plain: title))).id
            )
        }

        let suggested = try await search.suggestions(limit: 2).map(\.id)
        #expect(suggested == created.reversed().prefix(2).map { $0 })
    }

    @Test("Punctuation in a query does not throw",
          arguments: ["\"", "AND", "*", "^heron", "it's", "NEAR(a b)"])
    func punctuationIsSafe(query: String) async throws {
        let (search, notes, _) = try makeStack()
        try await notes.create(NoteDraft(title: "Kingfisher"))

        // A search box must never crash on what someone types into it.
        _ = try await search.search(query, limit: 10)
    }
}

@Suite("SearchService · layering")
struct SearchServiceLayeringTests {
    /// The reason `SearchService.init` takes no `TransactionRunning`: with no
    /// writer in its dependency graph, "searching never changes anything" is a
    /// property of the type rather than a rule to remember.
    @Test("A storage failure surfaces as a ServiceError")
    func storageFailuresAreTranslated() async throws {
        let storage = try ColdStorage.inMemory()
        let search = SearchService(
            notes: FailingNoteReader(error: .corrupted("bad row")),
            index: storage.search
        )

        do {
            _ = try await search.suggestions(limit: 5)
            Issue.record("expected a failure")
        } catch is StorageError {
            Issue.record("a StorageError escaped the service layer")
        } catch let error as ServiceError {
            #expect(error == .storageUnavailable)
        }
    }
}
