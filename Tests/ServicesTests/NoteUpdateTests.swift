import Foundation
import ColdStorage
import ServiceContracts
import SparrowDomain
import StorageContracts
import Testing
@testable import Services

@Suite("NoteService · notebook resolution")
struct NoteResolutionTests {
    /// FR-1.1. A note captured by voice names no notebook, and the person is
    /// not there to be asked which one.
    @Test("A draft with no notebook lands in the default")
    func unfiledDraftLandsInTheDefault() async throws {
        let (service, storage) = try makeService()

        let note = try await service.create(NoteDraft(title: "Kingfisher"))

        let expected = try await storage.notebooks.defaultNotebook()
        #expect(note.notebookID == expected.id)
    }

    @Test("A draft naming a real notebook lands there")
    func namedNotebookIsHonoured() async throws {
        let (service, storage) = try makeService()
        let target = makeNotebook("Wetlands")
        try await storage.transactions.write { session in
            try session.notebooks.insert(target)
        }

        let note = try await service.create(
            NoteDraft(title: "Kingfisher", notebookID: target.id)
        )
        #expect(note.notebookID == target.id)
    }

    /// Resolution happens before the transaction opens, so a bad notebook
    /// costs a read rather than a rolled-back write.
    @Test("A draft naming a notebook that does not exist is refused")
    func missingNotebookIsRefused() async throws {
        let (service, storage) = try makeService()
        let ghost = NotebookID()

        await #expect(throws: ServiceError.notebookNotFound(ghost)) {
            try await service.create(
                NoteDraft(title: "Kingfisher", notebookID: ghost)
            )
        }
        #expect(try await storage.notes.count() == 0)
    }
}

@Suite("NoteService · update")
struct NoteUpdateTests {
    private static let later = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("An edit changes only the fields it names")
    func partialEditTouchesOnlyNamedFields() async throws {
        let clock = SteppingClock()
        let (service, _) = try makeService(now: clock.now)
        let note = try await service.create(
            NoteDraft(title: "Kingfisher", body: "North bank")
        )

        let updated = try await service.update(
            note.id, with: NoteEdit(isPinned: true)
        )

        #expect(updated.isPinned)
        #expect(updated.plainTitle == "Kingfisher")
        #expect(updated.plainBody == "North bank")
        #expect(updated.id == note.id)
        #expect(updated.createdAt == note.createdAt)
    }

    /// ⚠️ The plan expected an empty edit to change `updatedAt`. Domain 0.3.0
    /// deliberately decided otherwise: a bumped timestamp on an empty save
    /// looks like a real change to the sync journal, and V2 would ship a row
    /// to say nothing happened. So an empty edit changes *nothing*, and the
    /// service does not journal or announce one either.
    @Test("An empty edit changes nothing at all, timestamp included")
    func emptyEditIsANoOp() async throws {
        let clock = SteppingClock()
        let (service, storage) = try makeService(now: clock.now)
        let note = try await service.create(NoteDraft(title: "Unchanged"))
        let journalled = try await storage.journal.pending(limit: 100).count

        let updated = try await service.update(note.id, with: NoteEdit())

        #expect(updated == note)
        #expect(updated.updatedAt == note.updatedAt)
        #expect(try await storage.journal.pending(limit: 100).count == journalled)
    }

    @Test("A real edit bumps updatedAt and journals once")
    func realEditJournals() async throws {
        let clock = SteppingClock()
        let (service, storage) = try makeService(now: clock.now)
        let note = try await service.create(NoteDraft(title: "Before"))
        let journalled = try await storage.journal.pending(limit: 100).count

        let updated = try await service.update(
            note.id, with: NoteEdit(title: RichText(plain: "After"))
        )

        #expect(updated.plainTitle == "After")
        #expect(updated.updatedAt > note.updatedAt)
        #expect(try await storage.journal.pending(limit: 100).count == journalled + 1)
    }

    @Test("Updating an unknown note is noteNotFound")
    func updatingUnknownIsNotFound() async throws {
        let (service, _) = try makeService()
        let id = NoteID()

        await #expect(throws: ServiceError.noteNotFound(id)) {
            try await service.update(id, with: NoteEdit(isPinned: true))
        }
    }

    @Test("Rich text survives an edit")
    func richTextSurvivesAnEdit() async throws {
        let clock = SteppingClock()
        let (service, _) = try makeService(now: clock.now)
        var attributed = AttributedString("Kingfisher here")
        if let range = attributed.range(of: "Kingfisher") {
            attributed[range].inlinePresentationIntent = .stronglyEmphasized
        }
        let note = try await service.create(NoteDraft(title: "placeholder"))

        let updated = try await service.update(
            note.id, with: NoteEdit(title: RichText(attributed))
        )

        #expect(updated.title.attributedString() == attributed)
    }

    // MARK: move and setPinned

    @Test("move relocates the note")
    func moveRelocates() async throws {
        let clock = SteppingClock()
        let (service, storage) = try makeService(now: clock.now)
        let target = makeNotebook("Wetlands")
        try await storage.transactions.write { session in
            try session.notebooks.insert(target)
        }
        let note = try await service.create(NoteDraft(title: "Movable"))

        try await service.move(note.id, to: target.id)

        #expect(try await service.note(note.id)?.notebookID == target.id)
    }

    /// The target is checked before the transaction, so a bad move costs a
    /// read rather than a rolled-back write.
    @Test("Moving to a notebook that does not exist is refused")
    func moveToMissingNotebookIsRefused() async throws {
        let clock = SteppingClock()
        let (service, _) = try makeService(now: clock.now)
        let note = try await service.create(NoteDraft(title: "Stays put"))
        let ghost = NotebookID()

        await #expect(throws: ServiceError.notebookNotFound(ghost)) {
            try await service.move(note.id, to: ghost)
        }
        #expect(try await service.note(note.id)?.notebookID == note.notebookID)
    }

    @Test("setPinned both pins and unpins")
    func setPinnedBothWays() async throws {
        let clock = SteppingClock()
        let (service, _) = try makeService(now: clock.now)
        let note = try await service.create(NoteDraft(title: "Pinnable"))

        try await service.setPinned(note.id, true)
        #expect(try await service.note(note.id)?.isPinned == true)

        try await service.setPinned(note.id, false)
        #expect(try await service.note(note.id)?.isPinned == false)
    }

    @Test("Pinning an already-pinned note journals nothing new")
    func redundantPinIsANoOp() async throws {
        let clock = SteppingClock()
        let (service, storage) = try makeService(now: clock.now)
        let note = try await service.create(NoteDraft(title: "Pinned"))
        try await service.setPinned(note.id, true)
        let journalled = try await storage.journal.pending(limit: 100).count

        try await service.setPinned(note.id, true)

        #expect(try await storage.journal.pending(limit: 100).count == journalled)
    }
}

@Suite("NoteService · error translation")
struct NoteErrorTranslationTests {
    /// Every storage failure must arrive as something a person can be shown.
    /// An intent that had to catch `corrupted("malformed FTS row")` would need
    /// storage vocabulary to explain itself.
    @Test(
        "Every StorageError case surfaces as a ServiceError",
        arguments: [
            StorageError.notFound,
            .constraintViolated("x"),
            .corrupted("x"),
            .unavailable("x"),
            .migrationFailed(from: 1, to: 2),
        ]
    )
    func storageFailuresAreTranslated(error: StorageError) async throws {
        let storage = try ColdStorage.inMemory()
        let service = NoteService(
            notes: FailingNoteReader(error: error),
            notebooks: storage.notebooks,
            transactions: storage.transactions,
            relay: ChangeRelay(thresholds: .immediate)
        )

        do {
            _ = try await service.recent(limit: 10)
            Issue.record("expected a failure")
        } catch is StorageError {
            Issue.record("a StorageError escaped the service layer")
        } catch let error as ServiceError {
            #expect(error == .storageUnavailable || error == .noteNotFound(NoteID()) )
        }
    }

    /// `.notFound` is the one case that carries a caller-specific meaning, so
    /// it maps to the identifier the caller asked about rather than to a
    /// generic failure.
    @Test("notFound becomes noteNotFound for the identifier asked about")
    func notFoundNamesTheNote() async throws {
        let (service, _) = try makeService()
        let id = NoteID()

        await #expect(throws: ServiceError.noteNotFound(id)) {
            try await service.delete(id)
        }
    }
}

/// A `NoteReading` that fails on every call.
struct FailingNoteReader: NoteReading {
    let error: StorageError

    func note(_ id: NoteID) async throws -> Note? { throw error }
    func notes(_ ids: [NoteID]) async throws -> [Note] { throw error }
    func recentNotes(limit: Int) async throws -> [Note] { throw error }
    func count() async throws -> Int { throw error }
}
