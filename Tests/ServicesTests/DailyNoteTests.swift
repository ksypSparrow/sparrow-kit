import Foundation
import ColdStorage
import ServiceContracts
import SparrowDomain
import StorageContracts
import Testing
@testable import Services

@Suite("Daily notes")
struct DailyNoteServiceTests {
    /// Noon, so no test sits within hours of a day boundary and starts
    /// failing depending on when it runs.
    private static let noon = Date(timeIntervalSince1970: 1_756_814_400)

    private func makeStack(
        at instant: Date = DailyNoteServiceTests.noon
    ) throws -> (NoteService, StorageSet) {
        let storage = try ColdStorage.inMemory()
        let service = NoteService(
            notes: storage.notes,
            notebooks: storage.notebooks,
            transactions: storage.transactions,
            relay: ChangeRelay(thresholds: .immediate),
            clock: FixedSparrowClock(instant)
        )
        return (service, storage)
    }

    @Test("Opening today's entry creates it when there is none")
    func openCreatesWhenAbsent() async throws {
        let (service, _) = try makeStack()

        let note = try await service.openOrCreateDailyNote(on: Self.noon)

        #expect(note.kind == .daily)
        #expect(!note.plainTitle.isEmpty)
    }

    /// FR-1.7: "open today's entry" must work whether or not today has one.
    @Test("Calling twice returns the same note")
    func callingTwiceReturnsTheSameNote() async throws {
        let (service, storage) = try makeStack()

        let first = try await service.openOrCreateDailyNote(on: Self.noon)
        let second = try await service.openOrCreateDailyNote(on: Self.noon)

        #expect(first.id == second.id)
        #expect(try await storage.notes.count() == 1)
    }

    /// The gate's concurrency test. Without the unique index underneath, some
    /// of these would both see `nil` and both insert.
    @Test("Twenty concurrent calls create exactly one note")
    func concurrentCallsCreateOne() async throws {
        let (service, storage) = try makeStack()

        let ids = try await withThrowingTaskGroup(of: NoteID.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    try await service.openOrCreateDailyNote(on: Self.noon).id
                }
            }
            var seen: Set<NoteID> = []
            for try await id in group { seen.insert(id) }
            return seen
        }

        #expect(ids.count == 1)
        #expect(try await storage.notes.count() == 1)
    }

    @Test("Different days get different entries")
    func differentDaysDiffer() async throws {
        let (service, storage) = try makeStack()
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Self.noon).addingTimeInterval(3_600)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!

        let a = try await service.openOrCreateDailyNote(on: today)
        let b = try await service.openOrCreateDailyNote(on: tomorrow)

        #expect(a.id != b.id)
        #expect(try await storage.notes.count() == 2)
    }

    @Test("dailyNote reads back what openOrCreate wrote")
    func dailyNoteReadsItBack() async throws {
        let (service, _) = try makeStack()
        let created = try await service.openOrCreateDailyNote(on: Self.noon)

        #expect(try await service.dailyNote(on: Self.noon)?.id == created.id)
    }

    @Test("A day with no entry reads as nil without creating one")
    func readingDoesNotCreate() async throws {
        let (service, storage) = try makeStack()

        #expect(try await service.dailyNote(on: Self.noon) == nil)
        #expect(try await storage.notes.count() == 0)
    }

    /// An entry opened for a day is *about* that day, so one opened at 00:05
    /// for yesterday still belongs to yesterday.
    @Test("observedAt is the day asked for, not the moment of writing")
    func observedAtIsTheDayAskedFor() async throws {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Self.noon)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
        // The clock says 00:05 today; the caller asks for yesterday.
        let (service, _) = try makeStack(at: today.addingTimeInterval(300))

        let note = try await service.openOrCreateDailyNote(on: yesterday)

        #expect(note.observedAt == yesterday)
        #expect(try await service.dailyNote(on: yesterday)?.id == note.id)
        #expect(try await service.dailyNote(on: today) == nil)
    }

    @Test("Only one announcement is made, however many callers there were")
    func oneAnnouncementForOneNote() async throws {
        let relay = ChangeRelay(thresholds: .immediate)
        let storage = try ColdStorage.inMemory()
        let service = NoteService(
            notes: storage.notes, notebooks: storage.notebooks,
            transactions: storage.transactions, relay: relay,
            clock: FixedSparrowClock(Self.noon)
        )
        var events = service.changes.makeAsyncIterator()

        let note = try await service.openOrCreateDailyNote(on: Self.noon)
        #expect(await events.next() == .created(note.id))

        // The second call finds the existing note and announces nothing, so
        // the next event is whatever comes after it.
        try await service.openOrCreateDailyNote(on: Self.noon)
        let other = try await service.create(NoteDraft(title: "Next"))
        #expect(await events.next() == .created(other.id))
    }
}

@Suite("SparrowClock")
struct SparrowClockTests {
    /// The reason a clock is injected at all: midnight rollover is otherwise
    /// untestable, because the answer depends on the wall clock.
    @Test("23:59 and 00:01 are different days")
    func midnightRollsOver() {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_756_814_400))
        let lateTonight = today.addingTimeInterval(23 * 3_600 + 59 * 60)
        let earlyTomorrow = today.addingTimeInterval(24 * 3_600 + 60)

        let before = FixedSparrowClock(lateTonight)
        let after = FixedSparrowClock(earlyTomorrow)

        #expect(before.startOfDay(before.now) != after.startOfDay(after.now))
    }

    @Test("A fixed clock does not move")
    func fixedClockIsFixed() {
        let instant = Date(timeIntervalSince1970: 1_756_814_400)
        let clock = FixedSparrowClock(instant)

        #expect(clock.now == instant)
        #expect(clock.now == instant)
    }

    @Test("advanced(by:) moves it")
    func advancedMovesIt() {
        let clock = FixedSparrowClock(Date(timeIntervalSince1970: 0))
        #expect(clock.advanced(by: 3_600).now.timeIntervalSince1970 == 3_600)
    }

    @Test("startOfDay is the calendar's, not a 24-hour truncation")
    func startOfDayFollowsTheCalendar() {
        let clock = SystemSparrowClock()
        let noon = Date(timeIntervalSince1970: 1_756_814_400)
        let start = clock.startOfDay(noon)

        #expect(start <= noon)
        #expect(Calendar.current.isDate(start, inSameDayAs: noon))
    }
}
