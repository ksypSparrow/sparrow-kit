# Changelog

All notable changes to `SparrowKit`. Two products: `ServiceContracts` (what the
UI and the App Intents layer may ask for) and `Services` (the implementations).

Pre-1.0, **the minor is the breaking bump**.

## [Unreleased]

## [0.9.0] — wave 11 · localized errors

**No dependency bumps.** Domain and cold-storage both have dashes this wave.
The last release before 1.0.0.

### Added

- A **string catalog** in `ServiceContracts`, English and French.
- `defaultLocalization: "en"` on the package — required before a target may
  carry one.

### Changed

`ServiceError`'s descriptions and recovery suggestions now go through
`String(localized:bundle: .module)` instead of being Swift literals.

### Notes

- ⚠️ **`LocalizedError`, still not
  `CustomLocalizedStringResourceConvertible`.** The latter is an App Intents
  protocol, and adopting it would make this target — and therefore `Services` —
  unbuildable without the framework, which is exactly what the V2 server cannot
  have. The app maps `ServiceError` into its own error type.
- ⚠️ **`bundle: .module` matters, and its absence would be invisible.** The
  keys *are* the English text, so a lookup that failed entirely would still
  read perfectly in English and never translate. The test therefore asserts the
  French differs from the English — there is nothing to assert in English.
- 🧪 Checked by removing one French translation: the test fails and names the
  case.

## [0.8.0] — wave 7 · daily notes and the clock

Depends on **SparrowColdStorage 0.8.0**. **SparrowDomain stays at 0.6.0** — its
second dash.

### Changed — breaking

**Every service's `init` takes a `clock: any SparrowClock` instead of
`now: @Sendable () -> Date`.** The closure was a placeholder from 0.1.0,
carried for seven waves because the design's chosen name collided with the
standard library.

### Added

- `SparrowClock`, `SystemSparrowClock`, `FixedSparrowClock`.
- `NoteServicing.dailyNote(on:)` and `openOrCreateDailyNote(on:)` (**FR-1.7**).

### Notes

- ⚠️ **Named `SparrowClock`, not `Clock`.** `Clock` is a Swift
  standard-library protocol: `any Clock` would be ambiguous at every call site
  outside this module, and `SystemClock` would read as if it were Apple's.
- **`FixedSparrowClock` ships in the package**, not per test target. The app
  needs it for previews, and a second copy would be a second definition of what
  "yesterday" means.
- **The race is settled by the unique index, not an in-transaction re-check.**
  The plan asks for the re-check; it is not expressible, because
  `NoteSessionAccess` has no day query. Instead everyone sees `nil`, everyone
  inserts, one wins, and the losers catch the constraint violation and read the
  winner's note — which also holds across processes, as a re-check would not.
- 🧪 The concurrency test is **red without the loser's recovery** and green
  with it.
- No service reads `Date()` directly.

## [0.7.0] — wave 6 · tags

Depends on **SparrowDomain 0.6.0** and **SparrowColdStorage 0.7.0**.

### Added

- `TagServicing` — `all()`, `tag(_:)`, `ensure(_:)`, `delete(_:)`, `changes`.
- `TagService`, and `TagChange`.
- `ChangeRelay` now coalesces tag events alongside notes and notebooks.
- `ServiceError.emptyTagLabel` and `.tagNotFound`.

### Fixed

**`NoteService.create` was dropping `draft.tagIDs`.** The parameter did not
exist when `create` was written in 0.4.0, and nothing failed when the domain
added it — a note created with tags simply arrived without them. A test caught
it.

### Notes

- **`ensure` is find-or-create in one transaction.** A read-then-write races
  with itself: two notes tagged `#wetlands` at once would both find nothing and
  both try to create it. Storage offers `upsert` for exactly this.
- **Every tag a note claims is verified inside the transaction.** SQLite's
  foreign key would reject an unknown tag, but as a `constraintViolated` that
  reaches a person as "Sparrow can't reach your notes right now" — and the
  in-memory store has no foreign key at all. One check in the service means one
  message and two stores that agree.
- `ensure` announces `.created` or `.updated` depending on whether the tag was
  already there, which storage cannot distinguish.

## [0.6.0] — wave 5 · filtering

Depends on **SparrowDomain 0.5.0** and **SparrowColdStorage 0.6.0**.

### Added

- `SearchServicing.filter(_:sort:limit:)` (**FR-1.4**) and
  `count(matching:)`.
- `NoteServicing.notes(in:limit:)` — **the deferral from 0.4.0, now closed.**

### Notes

- `notes(in:limit:)` is `NoteFilter(notebookID:)` underneath. It was deferred
  in 0.4.0 because `NoteReading` had no by-notebook read and adding one would
  have meant an unplanned storage release; `NoteFilter` subsumed it exactly as
  predicted, and no extra storage API was needed.
- **The service adds nothing to `filter` beyond error translation.** Deciding
  *how* to answer — whether to consult the index, which columns to compare — is
  storage's business, and `NoteFilter` is the whole of what passes between
  them.
- The sort tests compare against `NoteSort.orders(_:before:)` rather than a
  hand-written expectation, the same discipline storage uses.
- `SearchService` still holds no `TransactionRunning`.

## [0.5.0] — wave 4 · text search

Depends on **SparrowColdStorage 0.5.0**. **SparrowDomain stays at 0.4.0** —
wave 4 has a dash in that column, so there was nothing to bump.

### Added

- `SearchServicing` — `search(_:limit:)` (**FR-1.3**) and `suggestions(limit:)`
  (**FR-1.6**).
- `SearchService`, an actor holding a reader and an index.

### Notes

- **`SearchService` is never given a `TransactionRunning`.** With no writer in
  its dependency graph, "searching never changes anything" is a property of the
  type rather than a rule someone has to remember.
- **Result order comes from the index.** `matches` decides it and `notes(_:)`
  promises to preserve it; if that promise broke, results would silently
  re-sort and look like a ranking bug rather than a contract violation. There
  is a test here as well as in storage.
- An empty query returns **nothing, not everything**. A search box that
  silently means "show me the whole database" is both a performance problem and
  a confusing one.
- `suggestions` stays separate from `NoteServicing.recent`. Today they return
  the same thing; when pinning or usage frequency starts to matter, only one
  changes.

### Deferred

`filter(_:sort:limit:)` waits for 0.6.0 — it needs `NoteFilter`, which arrives
in domain 0.5.0 next wave.

## [0.4.0] — wave 3 · note CRUD

Depends on **SparrowDomain 0.4.0** and **SparrowColdStorage 0.4.0**.

### Changed — breaking

- **`NoteService.init` now takes `notebooks: any NotebookReading`.** Creating a
  note resolves its notebook, and an unfiled draft resolves to the default.
- `NoteServicing` gains `update`, `move`, `setPinned`.

### Added

- `NoteService.update` / `move` / `setPinned`, each one `write { }`.
- Notebook resolution: `nil` → the default notebook (FR-1.1); a named notebook
  that does not exist → `.notebookNotFound`.

### Notes

- **Resolution happens outside the transaction.** Holding a write open across a
  lookup would serialise every concurrent capture behind it — and a bad
  notebook then costs a read rather than a rolled-back write.
- **A redundant edit writes nothing.** An empty `NoteEdit` is already a no-op in
  the domain, but pinning an already-pinned note *names* a field, so `applying`
  bumps `updatedAt` and the domain's rule does not catch it. The service
  compares with the timestamp discounted, and skips the write, the journal
  entry and the announcement.

### Deferred

`notes(in:limit:)` waits for 0.6.0. It needs a by-notebook read that
`NoteReading` does not have, and adding one would mean an unplanned
cold-storage release. Wave 5's `NoteFilter` subsumes it.

## [0.3.0] — wave 2 · notebook writes and the change relay

Depends on **SparrowDomain 0.3.0** and **SparrowColdStorage 0.3.0**.

### Changed — breaking

- **`NoteService.init` and `NotebookService.init` now take a `ChangeRelay`.**
  Events go through it rather than each service owning a broadcaster, so a
  burst reaches the UI as one change instead of hundreds.
- Call sites inside `write { }` dropped their `await`, following
  cold-storage 0.3.0's synchronous session. The `sequence: 0` placeholder
  `NoteService` used to pass is gone — `JournalDraft` has no such field.
- `NotebookServicing` gains `create`, `rename`, `delete` and `changes`.
- `ServiceError` gains `notebookNotFound`, `emptyNotebookName`,
  `notebookNotEmpty`.

### Added

- `ChangeRelay` — the only stateful service. Buffers for a window, and past a
  threshold emits `.reloaded` once instead of listing every change.
- `NotebookChange`.
- `NotebookService.create` / `rename` / `delete`, each one `write { }`.

### Notes

- **Storage cannot tell a create from an update** — it only knows the row
  moved. A service that just performed the write does know, so services
  announce the precise verb and storage fills in everything the app did not do
  itself. The precise verb wins the merge.
- `delete` refuses a notebook that still has children, and checks that
  **inside** the transaction. A check made outside could be true when it ran
  and false by the time the delete landed.
- Every tuning number lives in `ChangeRelay.Thresholds`.

## [0.2.0] — wave 1 · notebook reads

Depends on **SparrowDomain 0.2.0** and **SparrowColdStorage 0.2.0**.

### Added — `ServiceContracts`

- `NotebookServicing` — `all()`, `notebook(_:)`, `notebook(named:)`,
  `defaultNotebook()`. Reads only; writes arrive in 0.3.0 with transactions.

### Added — `Services`

- `NotebookService`, an actor over `NotebookReading`.

### Notes

- `defaultNotebook()` returns non-optional. Storage guarantees one exists, so
  an optional would only push the decision into every caller.
- A thin service on purpose. It gains real work in 0.3.0, when creating a
  notebook has to validate a name and reject a cycle in the parent chain.
- Behaviour is tested against the real in-memory store, so the suite fails if
  cold-storage's seeding drifts. Failure translation is tested against a fake,
  because the real store cannot be made to fail on demand.

## [0.1.0] — wave 0 · NoteServicing skeleton

Depends on **SparrowDomain 0.1.0** and **SparrowColdStorage 0.1.0**.

### Added — `ServiceContracts`

- `NoteServicing` — `create`, `delete`, `note`, `notes`, `recent`, `changes`.
- `NoteChange` — `created` · `updated` · `deleted` · `reloaded`. What happened,
  not which rows moved.
- `ServiceError` — `LocalizedError`, and deliberately nothing from App Intents.

### Added — `Services`

- `NoteService`, an actor. Everything injected is a protocol; it cannot name a
  database type because none is in its dependency graph.
- `translatingStorageErrors` — the only place `StorageError` is named outside
  the storage package.
- `NoteChangeBroadcaster` — synchronous subscription, so a view that saves
  immediately after subscribing cannot miss its own event.

### Deferred, and why

`update`, `move`, `setPinned`, `notes(in:limit:)`, `dailyNote` and
`openOrCreateDailyNote` name types absent from domain 0.1.0 — `NoteEdit` and
`NotebookID` arrive in domain 0.3.0–0.4.0, `NoteKind.daily` in 0.4.0. Each
method lands in the wave that brings its types.

`NoteService` does not yet observe `StorageObserving`. It publishes events from
its own commands, which is precise; picking up writes made by anything else
needs the `ChangeRelay` scheduled for 0.3.0.

### Known issue for 0.8.0

The design names the injected clock `Clock` with a `SystemClock` default.
**`Clock` is a Swift standard-library protocol**, so that name would be
ambiguous at every call site outside this module. 0.1.0 injects
`now: @Sendable () -> Date` instead; 0.8.0 should introduce the abstraction
under a non-colliding name.
