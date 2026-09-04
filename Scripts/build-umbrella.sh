#!/bin/bash
# Builds SparrowKit.xcframework — ONE artifact, ONE module — so a consuming app
# embeds a single framework and writes `import SparrowKit`.
#
# ⚠️ Why everything is merged into one module.
#
# A framework can only vend the .swiftmodule that matches its own name. Putting
# StorageContracts.swiftmodule inside ColdStorage.framework was tried and the
# import does not resolve. So every module that appears in SparrowKit's public
# interface has to BE SparrowKit:
#
#   SparrowDomain      re-exported models — required by the app
#   StorageContracts   reachable through Services' public inits
#   ServiceContracts   the service protocols
#   Services           the implementations
#   SparrowAssembly    the composition root
#   ColdStorage        pulled in by the above; imports GRDB
#
# ⚠️ GRDB therefore ships INSIDE SparrowKit.framework, statically linked. What
# is preserved is the property that matters:
#
#   - sparrow-kit's own sources contain zero GRDB references (verified below)
#   - GRDB is `internal import`ed by cold-storage, so it appears nowhere in
#     SparrowKit's public interface
#   - no consumer can `import GRDB` — the module is not shipped
#
# The rule "only cold-storage knows GRDB" stays enforced by the compiler in the
# source repositories, which is where development happens. In a single-module
# artifact it cannot also be enforced, because a single module is the thing
# being asked for.
set -euo pipefail

OUT="${OUT:-$PWD/build}"
KIT="$PWD"
DOMAIN="${DOMAIN:-$KIT/../sparrow-domain}"
COLD="${COLD:-$KIT/../sparrow-cold-storage}"
DIR="$OUT/umbrella"

# ⚠️ Builds from SIBLING CHECKOUTS, not from tags:
#
#   sparrow/
#     ├── sparrow-domain        ($DOMAIN)
#     ├── sparrow-cold-storage  ($COLD)
#     └── sparrow-kit           (here)
#
# Whatever is checked out is what ships, so check out the intended tags before
# releasing. The provenance of all three is recorded in the framework as
# SOURCES.txt — read it when a shipped binary needs to be traced back.

# Gate: kit's sources must never reference GRDB.
if grep -rq "import GRDB" "$KIT/Sources"; then
    echo "sparrow-kit sources reference GRDB — the layering gate has been broken." >&2
    exit 1
fi

rm -rf "$DIR"; mkdir -p "$DIR/Sources/SparrowKit"
cp -R "$DOMAIN/Sources/SparrowDomain"/.           "$DIR/Sources/SparrowKit/"
cp -R "$COLD/Contracts/Sources/StorageContracts"/. "$DIR/Sources/SparrowKit/"
cp -R "$COLD/Sources/ColdStorage"/.               "$DIR/Sources/SparrowKit/"
cp -R "$KIT/Sources/ServiceContracts"/.           "$DIR/Sources/SparrowKit/"
cp -R "$KIT/Sources/Services"/.                   "$DIR/Sources/SparrowKit/"
cp -R "$KIT/Sources/SparrowAssembly"/.            "$DIR/Sources/SparrowKit/"

# Intra-module imports are now self-imports. Strip them; leave GRDB alone.
find "$DIR/Sources/SparrowKit" -name "*.swift" -print0 | xargs -0 sed -i '' -E \
    '/^(internal |public |@_exported )?import (SparrowDomain|StorageContracts|ServiceContracts|Services|SparrowAssembly|ColdStorage)$/d'

cat > "$DIR/Package.swift" <<EOF
// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "SparrowKit",
    defaultLocalization: "en",
    platforms: [.iOS(.v27), .macOS(.v27)],
    products: [.library(name: "SparrowKit", type: .dynamic, targets: ["SparrowKit"])],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", .upToNextMajor(from: "7.0.0")),
    ],
    targets: [
        .target(
            name: "SparrowKit",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")],
            resources: [.process("Resources")]
        ),
    ]
)
EOF

args=""
for dest in "generic/platform=iOS Simulator:Release-iphonesimulator" \
            "generic/platform=iOS:Release-iphoneos" \
            "generic/platform=macOS:Release" ; do
    ( cd "$DIR" && xcodebuild build -scheme SparrowKit -destination "${dest%%:*}" \
        -derivedDataPath "$DIR/dd" -configuration Release \
        BUILD_LIBRARY_FOR_DISTRIBUTION=YES SKIP_INSTALL=NO > /dev/null )
    products="$DIR/dd/Build/Products/${dest##*:}"
    fw="$products/PackageFrameworks/SparrowKit.framework"
    mkdir -p "$fw/Modules"
    cp -R "$products/SparrowKit.swiftmodule" "$fw/Modules/"
    resdir="$fw"; [ -d "$fw/Resources" ] && resdir="$fw/Resources"
    { echo "SparrowKit umbrella build"; date -u "+built  %Y-%m-%dT%H:%M:%SZ";
      for r in "$DOMAIN" "$COLD" "$KIT"; do
          printf "%-22s %s\n" "$(basename "$r")" \
              "$(git -C "$r" describe --tags --always --dirty 2>/dev/null || echo unknown)"
      done; } > "$resdir/SOURCES.txt"
    # SparrowKit's own resources, plus GRDB's privacy manifest — static linking
    # brings a dependency's code but not its resource bundle.
    for b in "$products"/*.bundle; do [ -e "$b" ] && cp -R "$b" "$resdir/"; done
    args="$args -framework $fw"
done

rm -rf "$OUT/SparrowKit.xcframework" "$OUT/SparrowKit.xcframework.zip"
xcodebuild -create-xcframework $args -output "$OUT/SparrowKit.xcframework" > /dev/null
( cd "$OUT" && zip -qry "SparrowKit.xcframework.zip" "SparrowKit.xcframework" )
printf "%-18s %s\n" "SparrowKit" "$(swift package compute-checksum "$OUT/SparrowKit.xcframework.zip")"
