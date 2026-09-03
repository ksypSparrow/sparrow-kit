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
        .library(name: "ServiceContracts", targets: ["ServiceContracts"]),
        .library(name: "Services", targets: ["Services"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/ksypSparrow/sparrow-domain",
            // ⚠️ `.upToNextMajor` now that both upstreams are 1.0.0 — after a
            // compatibility promise, the major is the breaking bump.
            .upToNextMajor(from: "1.0.0")
        ),
        .package(
            url: "https://github.com/ksypSparrow/sparrow-cold-storage",
            .upToNextMajor(from: "1.0.0")
        ),
    ],
    targets: [
        .target(
            name: "ServiceContracts",
            dependencies: [
                .product(name: "SparrowDomain", package: "sparrow-domain"),
            ],
            resources: [.process("Resources")]
        ),
        .target(name: "Services", dependencies: [
            "ServiceContracts",
            .product(name: "StorageContracts", package: "sparrow-cold-storage"),
            // ColdStorage is deliberately absent. Adding it here is the
            // one-line mistake that collapses the layering.
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
            .product(name: "ColdStorage", package: "sparrow-cold-storage"),
        ]),
    ]
)
