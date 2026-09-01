# Changelog

All notable changes to `SparrowKit`. Two products: `ServiceContracts` (what the
UI and the App Intents layer may ask for) and `Services` (the implementations).

Pre-1.0, **the minor is the breaking bump**.

## [Unreleased]

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
