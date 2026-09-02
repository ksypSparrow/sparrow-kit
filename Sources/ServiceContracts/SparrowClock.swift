import Foundation

/// Where the services get "now" and "which day is that".
///
/// ⚠️ **Not called `Clock`.** `Clock` is a Swift standard-library protocol, so
/// `any Clock` would be ambiguous at every call site outside this module, and
/// a type called `SystemClock` would read as if it were Apple's. The design
/// sketch named it `Clock`; that was a mistake filed in wave 0 and this is it
/// being fixed.
///
/// The only injected dependency that is not a domain concept. It earns that:
/// "does the daily note roll over correctly?" is otherwise untestable, because
/// the answer depends on the wall clock and on the calendar.
public protocol SparrowClock: Sendable {
    var now: Date { get }

    /// The start of the calendar day containing `date`.
    ///
    /// A calendar question, not arithmetic — it moves with the timezone and
    /// with daylight saving.
    func startOfDay(_ date: Date) -> Date
}

/// The real one.
public struct SystemSparrowClock: SparrowClock {
    private let calendar: Calendar

    public init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    public var now: Date { Date() }

    public func startOfDay(_ date: Date) -> Date {
        calendar.startOfDay(for: date)
    }
}

/// A clock stopped at a chosen moment.
///
/// Test support, shipped in the package rather than duplicated per test
/// target: the app needs it for previews, and a second copy would be a second
/// definition of what "yesterday" means.
public struct FixedSparrowClock: SparrowClock {
    public let now: Date
    private let calendar: Calendar

    public init(_ now: Date, calendar: Calendar = .current) {
        self.now = now
        self.calendar = calendar
    }

    public func startOfDay(_ date: Date) -> Date {
        calendar.startOfDay(for: date)
    }

    /// The same clock, moved.
    public func advanced(by interval: TimeInterval) -> FixedSparrowClock {
        FixedSparrowClock(now.addingTimeInterval(interval), calendar: calendar)
    }
}
