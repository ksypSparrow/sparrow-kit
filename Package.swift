// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "SparrowKit",
    platforms: [.iOS(.v27), .macOS(.v27)],
    products: [
        .library(name: "ServiceContracts", targets: ["ServiceContracts"]),
        .library(name: "Services", targets: ["Services"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/ksypSparrow/sparrow-domain",
            .upToNextMinor(from: "0.3.0")
        ),
        .package(
            url: "https://github.com/ksypSparrow/sparrow-cold-storage",
            .upToNextMinor(from: "0.3.0")
        ),
    ],
    targets: [
        .target(name: "ServiceContracts", dependencies: [
            .product(name: "SparrowDomain", package: "sparrow-domain"),
        ]),
        .target(name: "Services", dependencies: [
            "ServiceContracts",
            .product(name: "StorageContracts", package: "sparrow-cold-storage"),
            // ColdStorage is deliberately absent. Adding it here is the
            // one-line mistake that collapses the layering.
        ]),
        .testTarget(name: "ServicesTests", dependencies: [
            "Services",
            // Tests link the implementation to prove the whole stack works.
            // Sources/Services never may — see RELEASING.md.
            .product(name: "ColdStorage", package: "sparrow-cold-storage"),
        ]),
    ]
)
