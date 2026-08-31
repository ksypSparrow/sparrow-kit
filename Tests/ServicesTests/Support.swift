import Foundation
import Synchronization
import ColdStorage
import ServiceContracts
import SparrowDomain
import StorageContracts
@testable import Services

/// A service wired to a real in-memory store — the wave-0 walking skeleton,
/// assembled exactly as the app's composition root will assemble it.
///
/// The test target links `ColdStorage`; `Sources/Services` never may.
func makeService(
    now: @escaping @Sendable () -> Date = { .distantPast },
    relay: ChangeRelay = ChangeRelay(thresholds: .immediate)
) throws -> (service: NoteService, storage: StorageSet) {
    let storage = try ColdStorage.inMemory()
    let service = NoteService(
        notes: storage.notes,
        transactions: storage.transactions,
        relay: relay,
        now: now
    )
    return (service, storage)
}

extension ChangeRelay.Thresholds {
    /// A window short enough that a test does not wait on it, but still a real
    /// window — setting it to zero would test a code path that never ships.
    static let immediate = ChangeRelay.Thresholds(
        window: .milliseconds(1),
        collapseAbove: 20
    )
}

/// A clock that advances a fixed step on every read, so ordering assertions
/// cannot flake and do not depend on wall-clock resolution.
final class SteppingClock: Sendable {
    private let state = Mutex(Date(timeIntervalSince1970: 1_700_000_000))
    private let step: TimeInterval

    init(step: TimeInterval = 60) {
        self.step = step
    }

    var now: @Sendable () -> Date {
        { [self] in
            // Captured through `self`: Mutex is non-copyable, so capturing the
            // property directly would try to consume it.
            state.withLock { current in
                defer { current.addTimeInterval(step) }
                return current
            }
        }
    }
}
