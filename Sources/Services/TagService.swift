import Foundation
import ServiceContracts
import SparrowDomain
import StorageContracts

/// Tag use cases.
public actor TagService: TagServicing {
    private let tags: any TagReading
    private let transactions: any TransactionRunning
    private let relay: ChangeRelay
    private let now: @Sendable () -> Date

    public init(
        tags: any TagReading,
        transactions: any TransactionRunning,
        relay: ChangeRelay,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.tags = tags
        self.transactions = transactions
        self.relay = relay
        self.now = now
    }

    public nonisolated var changes: AsyncStream<TagChange> {
        relay.tagChanges
    }

    // MARK: Commands

    /// Find-or-create, in one transaction.
    ///
    /// ⚠️ **No read-then-write.** Checking for the tag first and creating it if
    /// absent races with itself: two notes tagged `#wetlands` at the same
    /// moment would both find nothing and both try to create it. `upsert`
    /// inside a single transaction has no such window, which is why storage
    /// offers it rather than `insert`.
    @discardableResult
    public func ensure(_ label: String) async throws -> Tag {
        guard let tag = Tag(label: label) else {
            throw ServiceError.emptyTagLabel
        }

        let existed = try await translatingStorageErrors {
            try await transactions.write { session in
                let existing = try session.tags.tag(tag.id)
                try session.tags.upsert(tag)
                try session.journal.record(
                    JournalDraft(
                        subject: .tag(tag.id),
                        operation: .upsert,
                        payload: try JSONEncoder().encode(tag),
                        recordedAt: self.now()
                    )
                )
                return existing != nil
            }
        }

        await relay.announce(existed ? TagChange.updated(tag.id)
                                     : TagChange.created(tag.id))
        return tag
    }

    public func delete(_ id: TagID) async throws {
        let timestamp = now()

        try await translatingStorageErrors(missing: .tagNotFound(id)) {
            try await transactions.write { session in
                try session.tags.markDeleted(id, at: timestamp)
                try session.journal.record(
                    JournalDraft(
                        subject: .tag(id),
                        operation: .delete,
                        payload: Data(),
                        recordedAt: timestamp
                    )
                )
            }
        }

        await relay.announce(TagChange.deleted(id))
    }

    // MARK: Queries

    public func all() async throws -> [Tag] {
        try await translatingStorageErrors { try await tags.allTags() }
    }

    public func tag(_ id: TagID) async throws -> Tag? {
        try await translatingStorageErrors { try await tags.tag(id) }
    }
}
