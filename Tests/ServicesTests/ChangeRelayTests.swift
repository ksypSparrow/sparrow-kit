import Foundation
import ColdStorage
import ServiceContracts
import SparrowDomain
import StorageContracts
import Testing
@testable import Services

@Suite("ChangeRelay")
struct ChangeRelayTests {
    private static let window = Duration.milliseconds(20)

    private func makeRelay(collapseAbove: Int = 20) -> ChangeRelay {
        ChangeRelay(
            thresholds: .init(window: Self.window, collapseAbove: collapseAbove)
        )
    }

    /// Waits a little past the window, so a flush has certainly happened.
    private func settle() async throws {
        try await Task.sleep(for: Self.window * 4)
    }

    @Test("One change in the window arrives as one event")
    func oneChangeIsOneEvent() async throws {
        let relay = makeRelay()
        var events = relay.notebookChanges.makeAsyncIterator()
        let id = NotebookID()

        await relay.announce(NotebookChange.created(id))

        #expect(await events.next() == .created(id))
    }

    /// The reason the relay exists. A bulk import writes thousands of rows,
    /// and a list that reloads thousands of times is unusable.
    @Test("A thousand changes in the window collapse to one reloaded")
    func aBurstCollapses() async throws {
        let relay = makeRelay()
        var events = relay.noteChanges.makeAsyncIterator()

        for _ in 0..<1_000 {
            await relay.announce(NoteChange.updated(NoteID()))
        }

        #expect(await events.next() == .reloaded)
    }

    @Test("Exactly at the threshold, changes are still listed individually")
    func thresholdIsExclusive() async throws {
        let relay = makeRelay(collapseAbove: 3)
        var events = relay.noteChanges.makeAsyncIterator()
        let ids = (0..<3).map { _ in NoteID() }

        for id in ids { await relay.announce(NoteChange.updated(id)) }

        for id in ids {
            #expect(await events.next() == .updated(id))
        }
    }

    @Test("One past the threshold collapses")
    func onePastTheThresholdCollapses() async throws {
        let relay = makeRelay(collapseAbove: 3)
        var events = relay.noteChanges.makeAsyncIterator()

        for _ in 0..<4 { await relay.announce(NoteChange.updated(NoteID())) }

        #expect(await events.next() == .reloaded)
    }

    @Test("Repeated changes to one identifier arrive once")
    func repeatsAreDeduplicated() async throws {
        let relay = makeRelay()
        var events = relay.noteChanges.makeAsyncIterator()
        let id = NoteID()

        for _ in 0..<50 { await relay.announce(NoteChange.updated(id)) }

        #expect(await events.next() == .updated(id))
    }

    /// Storage cannot tell a create from an update — it only knows the row
    /// moved. A service that just performed the write does know, so its verb
    /// must survive the merge.
    @Test("A service's precise verb beats storage's generic one")
    func preciseVerbWins() async throws {
        let relay = makeRelay()
        var events = relay.noteChanges.makeAsyncIterator()
        let id = NoteID()
        let (stream, continuation) = AsyncStream<StoredChange>.makeStream()
        await relay.start(consuming: stream)

        await relay.announce(NoteChange.created(id))
        continuation.yield(.notes([id]))

        #expect(await events.next() == .created(id))
    }

    @Test("Storage's reloaded passes straight through, uncoalesced")
    func storageReloadedPassesThrough() async throws {
        let relay = makeRelay()
        var events = relay.noteChanges.makeAsyncIterator()
        let (stream, continuation) = AsyncStream<StoredChange>.makeStream()
        await relay.start(consuming: stream)

        continuation.yield(.reloaded)

        #expect(await events.next() == .reloaded)
    }

    @Test("Note and notebook events do not contaminate each other")
    func streamsAreSeparate() async throws {
        let relay = makeRelay()
        var notebookEvents = relay.notebookChanges.makeAsyncIterator()
        let noteID = NoteID()
        let notebookID = NotebookID()

        await relay.announce(NoteChange.updated(noteID))
        await relay.announce(NotebookChange.created(notebookID))

        #expect(await notebookEvents.next() == .created(notebookID))
    }
}

@Suite("ChangeRelay · against real storage")
struct ChangeRelayIntegrationTests {
    private static let window = Duration.milliseconds(20)

    private func makeStack() throws -> (NotebookService, ChangeRelay, StorageSet) {
        let storage = try ColdStorage.inMemory()
        let relay = ChangeRelay(
            thresholds: .init(window: Self.window, collapseAbove: 20)
        )
        let service = NotebookService(
            notebooks: storage.notebooks,
            transactions: storage.transactions,
            relay: relay
        )
        return (service, relay, storage)
    }

    @Test("A committed create is announced")
    func commitIsAnnounced() async throws {
        let (service, relay, _) = try makeStack()
        var events = relay.notebookChanges.makeAsyncIterator()

        let notebook = try await service.create(NotebookDraft(name: "Observed"))

        #expect(await events.next() == .created(notebook.id))
    }

    /// Storage publishes nothing for a rolled-back transaction, so the relay
    /// has nothing to coalesce. This checks the whole chain rather than the
    /// relay alone.
    @Test("A refused write announces nothing")
    func rolledBackWriteAnnouncesNothing() async throws {
        let (service, relay, _) = try makeStack()
        let parent = try await service.create(NotebookDraft(name: "Surveys"))
        try await service.create(
            NotebookDraft(name: "Wetlands", parentID: parent.id)
        )

        // Let the setup's own events flush before subscribing. The relay
        // buffers, so a subscriber arriving mid-window still receives that
        // window — correct behaviour, and a trap for a test that assumes the
        // stream starts empty.
        try await Task.sleep(for: Self.window * 4)
        var events = relay.notebookChanges.makeAsyncIterator()

        await #expect(throws: ServiceError.self) {
            try await service.delete(parent.id)
        }

        // The next event must be the *successful* write that follows.
        let survivor = try await service.create(NotebookDraft(name: "Survivor"))
        #expect(await events.next() == .created(survivor.id))
    }
}
