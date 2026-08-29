# Changelog

All notable changes to `SparrowKit`. Two products: `ServiceContracts` (what the
UI and the App Intents layer may ask for) and `Services` (the implementations).

Pre-1.0, **the minor is the breaking bump**.

## [Unreleased]

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
