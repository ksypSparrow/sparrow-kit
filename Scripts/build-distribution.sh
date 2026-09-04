#!/bin/bash
# Builds SparrowKit's three modules as XCFrameworks for binary distribution to
# a team that does not get the source.
#
# ⚠️ Each layer is built from a generated single-target package, NOT from the
# real manifest. That is not tidiness — it is the whole trick.
#
# Targets inside one SwiftPM package link STATICALLY. Building the real
# manifest with dynamic products makes SparrowAssembly.framework absorb private
# copies of Services and ServiceContracts:
#
#   Class _TtC8Services15NotebookService is implemented in both
#     Services.framework/Services and SparrowAssembly.framework/SparrowAssembly
#
# Two copies of a module have two type identities. The visible symptom was a
# crash with a misleading message —
#   Fatal error: unable to find bundle named SparrowKit_ServiceContracts
# because `Bundle.module`'s BundleFinder resolved to the duplicate inside
# SparrowAssembly.framework, which carries no resource bundle. The resource
# placement was never the bug.
#
# Building each layer alone, against the layer below as a *binary*, leaves
# nothing to absorb.
set -euo pipefail

OUT="${OUT:-$PWD/build}"
SRC="$PWD/Sources"
SCAFFOLD="$OUT/scaffold"
mkdir -p "$OUT"

DOMAIN_URL="https://github.com/ksypSparrow/sparrow-domain/releases/download/2.0.0/SparrowDomain.xcframework.zip"
DOMAIN_SUM="ab2924912497ecb95f90168f6bf445c028ad1cdeef617d008ac371121c7526ef"
SC_URL="https://github.com/ksypSparrow/sparrow-cold-storage/releases/download/3.0.0/StorageContracts.xcframework.zip"
SC_SUM="f2f23b91bf68c3f7cd2329d8a0f92b2ff939c09f62d63cb85749d3c6b7cfd518"
CS_URL="https://github.com/ksypSparrow/sparrow-cold-storage/releases/download/3.0.0/ColdStorage.xcframework.zip"
CS_SUM="63d5589cd05975c044a483164cd3a4ebec46600842ac00f41db017032b913aac"

# $1 module, $2 extra target deps, $3 extra manifest targets, $4 resources line
scaffold () {
    local name="$1" deps="$2" extra="$3" res="$4"
    local dir="$SCAFFOLD/$name"
    rm -rf "$dir"; mkdir -p "$dir/Sources"
    cp -R "$SRC/$name" "$dir/Sources/$name"
    # ⚠️ SwiftPM requires a binaryTarget path to be relative to the package
    # root, so each already-built layer is copied in rather than referenced
    # where it was produced.
    for built in "$OUT"/*.xcframework; do
        [ -e "$built" ] && cp -R "$built" "$dir/"
    done
    cat > "$dir/Package.swift" <<EOF
// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "$name",
    defaultLocalization: "en",
    platforms: [.iOS(.v27), .macOS(.v27)],
    products: [.library(name: "$name", type: .dynamic, targets: ["$name"])],
    targets: [
        .binaryTarget(name: "SparrowDomain", url: "$DOMAIN_URL", checksum: "$DOMAIN_SUM"),
$extra
        .target(name: "$name", dependencies: [$deps]$res),
    ]
)
EOF
}

build () {
    local name="$1"
    local dir="$SCAFFOLD/$name" dd="$SCAFFOLD/$name/dd" args=""
    for dest in "generic/platform=iOS Simulator:Release-iphonesimulator" \
                "generic/platform=iOS:Release-iphoneos" \
                "generic/platform=macOS:Release" ; do
        ( cd "$dir" && xcodebuild build -scheme "$name" -destination "${dest%%:*}" \
            -derivedDataPath "$dd" -configuration Release \
            BUILD_LIBRARY_FOR_DISTRIBUTION=YES SKIP_INSTALL=NO > /dev/null )
        local products="$dd/Build/Products/${dest##*:}"
        local fw="$products/PackageFrameworks/$name.framework"
        mkdir -p "$fw/Modules"
        cp -R "$products/$name.swiftmodule" "$fw/Modules/"
        # Resource bundles live where Bundle.module looks: the framework root
        # for a flat iOS framework, Versions/A/Resources for a versioned macOS one.
        local resdir="$fw"; [ -d "$fw/Resources" ] && resdir="$fw/Resources"
        for b in "$products"/*"_$name.bundle"; do [ -e "$b" ] && cp -R "$b" "$resdir/"; done
        args="$args -framework $fw"
    done
    rm -rf "$OUT/$name.xcframework" "$OUT/$name.xcframework.zip"
    xcodebuild -create-xcframework $args -output "$OUT/$name.xcframework" > /dev/null
    ( cd "$OUT" && zip -qry "$name.xcframework.zip" "$name.xcframework" )
    printf "%-20s %s\n" "$name" "$(swift package compute-checksum "$OUT/$name.xcframework.zip")"
}

LOCAL_SC='        .binaryTarget(name: "ServiceContracts", path: "ServiceContracts.xcframework"),'
LOCAL_SV='        .binaryTarget(name: "Services", path: "Services.xcframework"),'
STORAGE='        .binaryTarget(name: "StorageContracts", url: "'"$SC_URL"'", checksum: "'"$SC_SUM"'"),'
COLD='        .binaryTarget(name: "ColdStorage", url: "'"$CS_URL"'", checksum: "'"$CS_SUM"'"),'

scaffold ServiceContracts '"SparrowDomain"' '' ', resources: [.process("Resources")]'
build ServiceContracts

scaffold Services '"SparrowDomain", "ServiceContracts", "StorageContracts"' "$LOCAL_SC
$STORAGE" ''
build Services

# ⚠️ StorageContracts is here even though SparrowAssembly never imports it:
# Services' .swiftinterface does, and resolving that interface needs the module.
scaffold SparrowAssembly '"SparrowDomain", "ServiceContracts", "Services", "StorageContracts", "ColdStorage"' "$LOCAL_SC
$LOCAL_SV
$STORAGE
$COLD" ''
build SparrowAssembly
