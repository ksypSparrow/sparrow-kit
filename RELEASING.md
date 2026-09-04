# Releasing SparrowKit

Waits on two repositories, blocks the app.

## The ritual

```
   1  bump domain and cold-storage in Package.swift, as the wave requires
   2  swift package resolve
   3  implement · run the tests (see below)
   4  grep -rn "import ColdStorage" Sources/Services/   → must be empty
   5  CHANGELOG.md entry naming the wave
   6  git tag vX.Y.Z && git push --tags
   7  notify: sparrow-app
```

Step 4 is not ceremony. `Services` links `StorageContracts`; the day it links
`ColdStorage`, every service can name a database type and the layering is gone
with no visible symptom.

## Gate for every release

```
   ✓  swift build
   ✓  xcodebuild test -scheme SparrowKit-Package \
          -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=27.0'
   ✓  swift build -Xswiftc -strict-concurrency=complete
   ✓  xcodebuild -scheme SparrowKit-Package \
        -destination 'generic/platform=iOS'
   ✓  grep -rn "import ColdStorage" Sources/Services/     → empty
   ✓  imports in Sources/ServiceContracts/                → Foundation,
                                                            SparrowDomain
```

The last check keeps `ServiceContracts` free of App Intents. The moment
`ServiceError` conforms to `CustomLocalizedStringResourceConvertible`, this
package stops building anywhere App Intents is unavailable.

## Standing rules

| | |
|---|---|
| Injected | Protocols only. A service cannot name a concrete store |
| Errors | `StorageError` never escapes; translate at the boundary |
| Events | `NoteChange` says what happened, not which rows moved |
| Contracts | Depend on `SparrowDomain` and nothing else |

**Never re-tag.** SwiftPM caches by tag.

## ⚠️ Why the tests need a simulator now

`swift test` no longer works in this package. Domain and storage arrive as
binary `.xcframework`s containing **dynamic** frameworks, and SwiftPM does not
set an rpath its test bundles can use:

```
   Library not loaded: @rpath/SparrowDomain.framework/Versions/A/SparrowDomain
```

`DYLD_FRAMEWORK_PATH` does not rescue it either — SIP strips `DYLD_*` when the
toolchain's test helper is spawned. An iOS Simulator destination gives the tests
a real host that embeds the frameworks properly.

`swift build` still works, and is worth keeping in the loop: it catches
compile-time breakage far faster than a simulator run.

## The umbrella build

`Scripts/build-umbrella.sh` produces a single `SparrowKit.xcframework` — one
artifact, one module — for a consumer that should write `import SparrowKit` and
embed nothing else. `Scripts/build-distribution.sh` produces the layered
six-framework form instead, which keeps the module boundaries.

```bash
OUT=/tmp/out ./Scripts/build-umbrella.sh
```

⚠️ It builds from **sibling checkouts**, not from tags:

```
   sparrow/
     ├── sparrow-domain
     ├── sparrow-cold-storage
     └── sparrow-kit
```

Whatever is checked out is what ships. Check out the intended tags first; the
build stamps all three into `SOURCES.txt` inside the framework so a shipped
binary can be traced back.

⚠️ Everything merges into one module, because a framework can only vend the
`.swiftmodule` matching its own name. That is why the layered build exists as
well — pick the umbrella for ergonomics, the layered one for enforced layering.

GRDB is statically linked inside and appears in no interface, and the script
**fails** if `sparrow-kit`'s own sources ever reference it.
