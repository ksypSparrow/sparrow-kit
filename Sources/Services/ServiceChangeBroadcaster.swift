import Foundation
import Synchronization

/// Fans service events out to every observer.
///
/// Synchronous subscription on purpose: a view that subscribes and immediately
/// saves must not miss its own change.
final class ServiceChangeBroadcaster<Event: Sendable>: Sendable {
    private let observers =
        Mutex<[UUID: AsyncStream<Event>.Continuation]>([:])

    func stream() -> AsyncStream<Event> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Event>.makeStream()
        observers.withLock { $0[id] = continuation }
        continuation.onTermination = { [weak self] _ in
            self?.remove(id)
        }
        return stream
    }

    func publish(_ change: Event) {
        for continuation in observers.withLock({ Array($0.values) }) {
            continuation.yield(change)
        }
    }

    private func remove(_ id: UUID) {
        observers.withLock { $0[id] = nil }
    }
}
