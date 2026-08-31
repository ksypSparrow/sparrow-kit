# SparrowKit

Use cases for Sparrow FieldNotes — validation, orchestration, and the
translation between what storage reports and what the app can act on.

**Two products:**

```
   ServiceContracts   what the UI and App Intents may ask for
   Services           the actors that answer
```

## What this package is not allowed to know

`Services` depends on the **`StorageContracts` product**, never on
`ColdStorage`. It cannot name `SQLiteNoteRepository`, or discover that SQLite
is involved at all.

```
   ✓  Sources/Services  ──►  StorageContracts   the abstraction
   ✗  Sources/Services  ──►  ColdStorage        the implementation
```

That single line in `Package.swift` is the whole layering, and across
repositories it is easy to get wrong — the reviewer sees only the manifest. The
release gate greps for it.

## What a service is responsible for

```
   ┌─────────────────────────────────────────────────────────┐
   │  NoteService.create(draft)                              │
   │                                                         │
   │   1. validate      draft is not empty                   │
   │   2. assemble      stamp id, createdAt, updatedAt       │
   │   3. one write     insert · index · journal             │
   │   4. announce      NoteChange.created                   │
   └─────────────────────────────────────────────────────────┘
```

Steps 1–2 are *what is true*. Step 3 asks storage to make it durable,
atomically. Step 4 lets the rest of the app react. Nothing here knows how any
of it is stored.

## Errors stop at this boundary

`StorageError` never escapes. Every path out of a service runs through
`translatingStorageErrors`, so a view is handed `ServiceError.noteNotFound` —
which it can present — rather than `corrupted("malformed FTS row")`, which it
cannot.

## Contents

| Since | Contracts | Services |
|---|---|---|
| 0.1.0 | `NoteServicing`, `NoteChange`, `ServiceError` | `NoteService`: create, delete, read, recent |
| 0.2.0 | `NotebookServicing` | `NotebookService`: reads |
| 0.3.0 | `NotebookChange` | `NotebookService`: writes · `ChangeRelay` |

## Build

```bash
swift build && swift test
```

Tests link `ColdStorage` and run against `ColdStorage.inMemory()` — the whole
stack, assembled the way the app's composition root will assemble it.
`Sources/Services` never links it.

## Documents

[`contracts.md`](../01-Sparrow-FieldNotes/contracts.md) ·
[`plans/sparrow-kit.md`](../01-Sparrow-FieldNotes/plans/sparrow-kit.md) ·
[`RELEASING.md`](RELEASING.md)
