import Foundation
import ServiceContracts
import SparrowDomain
import StorageContracts

/// Turns storage's change notifications into events a UI can survive.
///
/// The only stateful service, and it earns that. Storage reports every row it
/// touched: a bulk import writes thousands, and a list that reloads thousands
/// of times is unusable. The relay buffers for a short window and, past a
/// threshold, says `.reloaded` once instead.
///
/// It is also where the two sources of truth meet. A service that just
/// performed a write knows whether it *created* or *deleted*; storage only
/// knows the row moved. So services announce the precise verb, storage fills in
/// anything the app did not do itself, and the precise one wins.
public actor ChangeRelay {
    /// Every tuning number, in one place.
    public struct Thresholds: Sendable {
        /// How long to collect before emitting.
        public var window: Duration
        /// Above this many changes in one window, emit `.reloaded` instead.
        public var collapseAbove: Int

        public init(
            window: Duration = .milliseconds(50),
            collapseAbove: Int = 20
        ) {
            self.window = window
            self.collapseAbove = collapseAbove
        }

        public static let `default` = Thresholds()
    }

    private let thresholds: Thresholds
    private let notes = ServiceChangeBroadcaster<NoteChange>()
    private let notebooks = ServiceChangeBroadcaster<NotebookChange>()
    private let tags = ServiceChangeBroadcaster<TagChange>()

    private var pendingNotes: [NoteID: NoteChange] = [:]
    private var pendingNoteOrder: [NoteID] = []
    private var pendingNotebooks: [NotebookID: NotebookChange] = [:]
    private var pendingNotebookOrder: [NotebookID] = []
    private var pendingTags: [TagID: TagChange] = [:]
    private var pendingTagOrder: [TagID] = []
    private var flush: Task<Void, Never>?
    private var consumption: Task<Void, Never>?

    public init(thresholds: Thresholds = .default) {
        self.thresholds = thresholds
    }

    deinit {
        flush?.cancel()
        consumption?.cancel()
    }

    // MARK: Streams

    public nonisolated var noteChanges: AsyncStream<NoteChange> {
        notes.stream()
    }

    public nonisolated var notebookChanges: AsyncStream<NotebookChange> {
        notebooks.stream()
    }

    public nonisolated var tagChanges: AsyncStream<TagChange> {
        tags.stream()
    }

    // MARK: Input

    /// A service reporting what it just did. The verb here is precise.
    public func announce(_ change: NoteChange) {
        guard let id = change.identifier else { return emit(note: .reloaded) }
        if pendingNotes.updateValue(change, forKey: id) == nil {
            pendingNoteOrder.append(id)
        }
        scheduleFlush()
    }

    public func announce(_ change: NotebookChange) {
        guard let id = change.identifier else { return emit(notebook: .reloaded) }
        if pendingNotebooks.updateValue(change, forKey: id) == nil {
            pendingNotebookOrder.append(id)
        }
        scheduleFlush()
    }

    public func announce(_ change: TagChange) {
        guard let id = change.identifier else { return emit(tag: .reloaded) }
        if pendingTags.updateValue(change, forKey: id) == nil {
            pendingTagOrder.append(id)
        }
        scheduleFlush()
    }

    /// Subscribes to storage. Everything the app did not do itself arrives
    /// here — a widget's write, or V2's sync when it exists.
    public func start(consuming changes: AsyncStream<StoredChange>) {
        consumption?.cancel()
        consumption = Task { [weak self] in
            for await change in changes {
                await self?.absorb(change)
            }
        }
    }

    private func absorb(_ change: StoredChange) {
        switch change {
        case .notes(let ids):
            for id in ids where pendingNotes[id] == nil {
                // Storage cannot tell a create from an update. If a service
                // already said which it was, that entry stays.
                pendingNotes[id] = .updated(id)
                pendingNoteOrder.append(id)
            }
        case .notebooks(let ids):
            for id in ids where pendingNotebooks[id] == nil {
                pendingNotebooks[id] = .updated(id)
                pendingNotebookOrder.append(id)
            }
        case .tags(let ids):
            for id in ids where pendingTags[id] == nil {
                pendingTags[id] = .updated(id)
                pendingTagOrder.append(id)
            }
        case .reloaded:
            emit(note: .reloaded)
            emit(notebook: .reloaded)
            emit(tag: .reloaded)
            return
        }
        scheduleFlush()
    }

    // MARK: Flushing

    private func scheduleFlush() {
        guard flush == nil else { return }
        flush = Task { [weak self, window = thresholds.window] in
            try? await Task.sleep(for: window)
            await self?.drain()
        }
    }

    private func drain() {
        flush = nil

        let noteChanges = pendingNoteOrder.compactMap { pendingNotes[$0] }
        pendingNotes = [:]
        pendingNoteOrder = []
        if noteChanges.count > thresholds.collapseAbove {
            emit(note: .reloaded)
        } else {
            noteChanges.forEach { emit(note: $0) }
        }

        let notebookChanges = pendingNotebookOrder
            .compactMap { pendingNotebooks[$0] }
        pendingNotebooks = [:]
        pendingNotebookOrder = []
        if notebookChanges.count > thresholds.collapseAbove {
            emit(notebook: .reloaded)
        } else {
            notebookChanges.forEach { emit(notebook: $0) }
        }

        let tagChanges = pendingTagOrder.compactMap { pendingTags[$0] }
        pendingTags = [:]
        pendingTagOrder = []
        if tagChanges.count > thresholds.collapseAbove {
            emit(tag: .reloaded)
        } else {
            tagChanges.forEach { emit(tag: $0) }
        }
    }

    private func emit(note change: NoteChange) { notes.publish(change) }
    private func emit(notebook change: NotebookChange) {
        notebooks.publish(change)
    }

    private func emit(tag change: TagChange) { tags.publish(change) }
}

private extension NoteChange {
    var identifier: NoteID? {
        switch self {
        case .created(let id), .updated(let id), .deleted(let id): id
        case .reloaded: nil
        }
    }
}

private extension NotebookChange {
    var identifier: NotebookID? {
        switch self {
        case .created(let id), .updated(let id), .deleted(let id): id
        case .reloaded: nil
        }
    }
}

private extension TagChange {
    var identifier: TagID? {
        switch self {
        case .created(let id), .updated(let id), .deleted(let id): id
        case .reloaded: nil
        }
    }
}
