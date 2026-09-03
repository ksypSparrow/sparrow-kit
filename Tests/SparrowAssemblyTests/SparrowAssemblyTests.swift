import Foundation
import ServiceContracts
import SparrowDomain
import Testing
@testable import SparrowAssembly

/// The composition root, exercised through the surface an app actually gets.
///
/// These tests hold no storage type. If `SparrowAssembly` stopped wiring the
/// store, or wired two relays, or forgot the change subscription, nothing else
/// in the package would notice — the app used to do this wiring, and nothing
/// tested it there either.
@Suite("SparrowAssembly")
struct SparrowAssemblyTests {
    @Test("in-memory services are usable end to end")
    func inMemoryWorks() async throws {
        let services = try SparrowAssembly.inMemory()

        let notebook = try await services.notebooks.defaultNotebook()
        let note = try await services.notes.create(
            NoteDraft(title: RichText(plain: "Kingfisher"), notebookID: notebook.id)
        )

        let recent = try await services.notes.recent(limit: 10)
        #expect(recent.map(\.id).contains(note.id))
    }

    /// ⚠️ This does **not** prove `relay.start(consuming:)` was called. The
    /// services announce their own changes directly; the storage observer is a
    /// second, generic source, and the assembly exposes no way to write to
    /// storage while bypassing a service. Deleting the subscription leaves this
    /// test green — verified — so it claims only what it can see: a write
    /// through the assembled graph reaches a listener.
    @Test("a write through the assembled graph reaches a listener")
    func writesReachListeners() async throws {
        let services = try SparrowAssembly.inMemory()

        // Listen before writing: events are published after a commit, and a
        // listener attached afterwards would miss it and pass for the wrong
        // reason.
        let observed = Task {
            for await _ in services.notes.changes { return true }
            return false
        }
        try await Task.sleep(for: .milliseconds(50))

        _ = try await services.notes.create(NoteDraft(title: RichText(plain: "Heron")))

        let delivered = try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask { await observed.value }
            group.addTask {
                try await Task.sleep(for: .seconds(2))
                return false
            }
            let first = try await group.next() ?? false
            group.cancelAll()
            return first
        }
        #expect(delivered, "a write produced no change event")
    }

    @Test("on-disk services persist across two assemblies")
    func onDiskPersists() async throws {
        let url = URL.temporaryDirectory
            .appending(path: "assembly-\(UUID().uuidString)", directoryHint: .isDirectory)
            .appending(path: "sparrow.sqlite")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let first = try SparrowAssembly.onDisk(at: url)
        let note = try await first.notes.create(
            NoteDraft(title: RichText(plain: "Estuary"))
        )

        // A second assembly over the same file: proves the store was written
        // and that migrations are idempotent on reopen.
        let second = try SparrowAssembly.onDisk(at: url)
        let reread = try await second.notes.note(note.id)
        #expect(reread?.plainTitle == "Estuary")
    }
}
