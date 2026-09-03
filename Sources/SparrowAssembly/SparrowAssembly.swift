import ColdStorage
import Foundation
import ServiceContracts
import Services

/// Every service an app needs, already wired to a store.
///
/// Holds the change relay's task so the subscription lives as long as the
/// services do. Drop this value and the relay stops.
public struct SparrowServices: Sendable {
    public let notes: any NoteServicing
    public let notebooks: any NotebookServicing
    public let search: any SearchServicing
    public let tags: any TagServicing

    private let relayTask: Task<Void, Never>

    fileprivate init(
        notes: any NoteServicing,
        notebooks: any NotebookServicing,
        search: any SearchServicing,
        tags: any TagServicing,
        relayTask: Task<Void, Never>
    ) {
        self.notes = notes
        self.notebooks = notebooks
        self.search = search
        self.tags = tags
        self.relayTask = relayTask
    }
}

/// The composition root.
///
/// This is the only target in the workspace that depends on both `Services` and
/// `ColdStorage`, so it is the only place a concrete store is named. An app
/// links this and receives protocols — it never learns that SQLite exists.
///
/// ⚠️ `Services` still must not depend on `ColdStorage`. The layering lives in
/// that edge, not in this one: keeping it means `ServicesIsolationTests` can go
/// on proving the services run against fakes with no database linked at all.
public enum SparrowAssembly {
    /// The on-disk store, migrated and ready.
    public static func onDisk(at url: URL) throws -> SparrowServices {
        try assemble(storage: ColdStorage.make(at: url))
    }

    /// An ephemeral store, for previews, UI tests, and a first run before the
    /// real one is wanted. The choice the app used to make itself.
    public static func inMemory() throws -> SparrowServices {
        try assemble(storage: ColdStorage.inMemory())
    }

    private static func assemble(storage: StorageSet) throws -> SparrowServices {
        // One relay for the whole graph. Two would mean a consumer listening to
        // the wrong one, silently.
        let relay = ChangeRelay()

        let notes = NoteService(
            notes: storage.notes,
            notebooks: storage.notebooks,
            transactions: storage.transactions,
            relay: relay
        )
        let notebooks = NotebookService(
            notebooks: storage.notebooks,
            transactions: storage.transactions,
            relay: relay
        )
        // A reader and an index, and nothing that can write — so searching
        // cannot change anything, structurally.
        let search = SearchService(notes: storage.notes, index: storage.search)
        let tags = TagService(
            tags: storage.tags,
            transactions: storage.transactions,
            relay: relay
        )

        // Every write through *this* storage instance reaches every consumer
        // through here, whoever made it.
        //
        // ⚠️ Not cross-process. The broadcaster lives in this instance, so a
        // separate extension writing the same file goes unnoticed. That needs
        // `DatabaseRegionObservation` or a Darwin notification, and is not V1.
        let relayTask = Task { await relay.start(consuming: storage.observer.changes) }

        return SparrowServices(
            notes: notes,
            notebooks: notebooks,
            search: search,
            tags: tags,
            relayTask: relayTask
        )
    }
}
