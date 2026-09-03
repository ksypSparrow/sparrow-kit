// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "SparrowKit",
    // ⚠️ Required before a target may carry a string catalog. Without it
    // SwiftPM refuses the resource, and `Bundle.module` has nothing to look
    // in.
    defaultLocalization: "en",
    platforms: [.iOS(.v27), .macOS(.v27)],
    products: [
        .library(name: "ServiceContracts", targets: ["ServiceContracts", "SparrowDomain"]),
        .library(name: "Services", targets: ["Services"]),
        // The composition root. Links `ColdStorage` so an app does not
        // have to name a concrete store.
        .library(name: "SparrowAssembly", targets: ["SparrowAssembly", "SparrowDomain"]),
    ],
    // ⚠️ **No package dependencies, on purpose.** Domain and storage arrive as
    // binaries below, so an app that links this package sees exactly one row in
    // Xcode's Package Dependencies. Add a `.package(...)` here and that row
    // count goes up for every consumer, which is the whole thing this design
    // exists to prevent.
    dependencies: [],
    targets: [
        // Prebuilt, from the releases of the two upstream repos. Those repos
        // are unchanged and still build from source — the V2 Linux server
        // consumes them that way. These are an Apple-platform convenience.
        .binaryTarget(
            name: "SparrowDomain",
            url: "https://github.com/ksypSparrow/sparrow-domain/releases/download/2.0.0/SparrowDomain.xcframework.zip",
            checksum: "ab2924912497ecb95f90168f6bf445c028ad1cdeef617d008ac371121c7526ef"
        ),
        .binaryTarget(
            name: "StorageContracts",
            url: "https://github.com/ksypSparrow/sparrow-cold-storage/releases/download/3.0.0/StorageContracts.xcframework.zip",
            checksum: "f2f23b91bf68c3f7cd2329d8a0f92b2ff939c09f62d63cb85749d3c6b7cfd518"
        ),
        // ⚠️ GRDB is compiled inside this one and appears nowhere in its public
        // interface. That is what lets this package have no dependencies.
        .binaryTarget(
            name: "ColdStorage",
            url: "https://github.com/ksypSparrow/sparrow-cold-storage/releases/download/3.0.0/ColdStorage.xcframework.zip",
            checksum: "63d5589cd05975c044a483164cd3a4ebec46600842ac00f41db017032b913aac"
        ),
        .target(
            name: "ServiceContracts",
            dependencies: [
                "SparrowDomain",
            ],
            resources: [.process("Resources")]
        ),
        .target(name: "Services", dependencies: [
            "ServiceContracts",
            "StorageContracts",
            // ColdStorage is deliberately absent. Adding it here is the
            // one-line mistake that collapses the layering.
        ]),
        // ⚠️ The **only** target here that links `ColdStorage`. It exists so
        // the app does not have to: before it, `sparrow-app` depended on
        // `sparrow-cold-storage` for one call. The layering still lives in the
        // `Services` edge above, which stays storage-agnostic.
        .target(name: "SparrowAssembly", dependencies: [
            "Services",
            "ServiceContracts",
            "ColdStorage",
        ]),
        .testTarget(name: "SparrowAssemblyTests", dependencies: [
            "SparrowAssembly",
            "ServiceContracts",
        ]),
        // ⚠️ **Links no database.** The gate asks that every service test be
        // able to run with none, and the `Sources/Services` grep only proves
        // the *library* does not link one. This target proves the services are
        // actually usable that way: hand-written fakes, no `ColdStorage`.
        .testTarget(name: "ServicesIsolationTests", dependencies: [
            "Services",
            "ServiceContracts",
        ]),
        .testTarget(name: "ServicesTests", dependencies: [
            "Services",
            "ServiceContracts",
            // Tests link the implementation to prove the whole stack works.
            // Sources/Services never may — see RELEASING.md.
            "ColdStorage",
        ]),
    ]
)
