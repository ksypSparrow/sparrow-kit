import Foundation
import SparrowDomain

/// What the UI and the App Intents layer may ask about tags.
public protocol TagServicing: Sendable {
    func all() async throws -> [Tag]
    func tag(_ id: TagID) async throws -> Tag?

    /// Find-or-create.
    ///
    /// There is no `create`. A tag comes into being by being *used* — someone
    /// types `#wetlands` on a note — and a caller that had to check first
    /// would race with itself the moment two notes were tagged at once.
    @discardableResult
    func ensure(_ label: String) async throws -> Tag

    /// Tombstones the tag. The notes that carried it keep their text; the tag
    /// simply stops appearing on them.
    func delete(_ id: TagID) async throws

    var changes: AsyncStream<TagChange> { get }
}

/// What the service layer announces about tags.
public enum TagChange: Hashable, Sendable {
    case created(TagID)
    case updated(TagID)
    case deleted(TagID)
    case reloaded
}
