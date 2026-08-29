import Foundation
import Synchronization
import ServiceContracts

/// Fans service events out to every observer.
///
/// Synchronous subscription on purpose: a view that subscribes and immediately
/// saves must not miss its own change.
final class NoteChangeBroadcaster: Sendable {
    private let observers =
        Mutex<[UUID: AsyncStream<NoteChange>.Continuation]>([:])

    func stream() -> AsyncStream<NoteChange> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<NoteChange>.makeStream()
        observers.withLock { $0[id] = continuation }
        continuation.onTermination = { [weak self] _ in
            self?.remove(id)
        }
        return stream
    }

    func publish(_ change: NoteChange) {
        for continuation in observers.withLock({ Array($0.values) }) {
            continuation.yield(change)
        }
    }

    private func remove(_ id: UUID) {
        observers.withLock { $0[id] = nil }
    }
}
