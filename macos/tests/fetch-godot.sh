#!/bin/bash
#
# Download the Godot editor for Windows, for check-wave4.sh item 11: a real program from
# outside this tree, an engine with its own Vulkan and Direct3D 12 renderers.
#
#   $GODOT_DIR/arm64/Godot_v<version>_windows_arm64.exe    a native arm64 program
#   $GODOT_DIR/x86_64/Godot_v<version>_win64.exe           an x86_64 program, which runs through FEX
#
# Both come from the release on github.com/godotengine/godot (MIT licence) and have to have the
# SHA-512 that the release's SHA512-SUMS.txt gave when this script was written. Nothing here is
# built or changed. About 530 MB with the archives.
#
# Environment overrides:
#   BUILD_ROOT   (default ~/projects/proton-macos-build)
#   GODOT_DIR    (default $BUILD_ROOT/third-party/godot-4.7.2-stable)

set -euo pipefail

BUILD_ROOT=${BUILD_ROOT:-$HOME/projects/proton-macos-build}
VERSION=4.7.2-stable
GODOT_DIR=${GODOT_DIR:-$BUILD_ROOT/third-party/godot-$VERSION}
URL=https://github.com/godotengine/godot/releases/download/$VERSION

die() { echo "fetch-godot.sh: error: $*" >&2; exit 1; }

# fetch ARCH ARCHIVE SHA512 EXE
fetch() {
    local dir=$GODOT_DIR/$1 zip=$GODOT_DIR/$2 sum=$3 exe=$4 got
    if [ -f "$dir/$exe" ] && [ "$(cat "$dir/SHA512" 2>/dev/null)" = "$sum" ]; then
        echo ":: $exe: there already" >&2
        return 0
    fi
    mkdir -p "$GODOT_DIR"
    [ -f "$zip" ] || curl -fsSL --max-time 900 -o "$zip.part" "$URL/$2"
    [ -f "$zip" ] || mv "$zip.part" "$zip"
    got=$(shasum -a 512 "$zip" | cut -d' ' -f1)
    [ "$got" = "$sum" ] || die "$2 has the SHA-512 $got, not $sum"
    rm -rf "$dir"
    mkdir -p "$dir"
    unzip -q -o "$zip" -d "$dir"
    [ -f "$dir/$exe" ] || die "$2 holds no $exe"
    echo "$sum" >"$dir/SHA512"
    echo ":: $exe: downloaded and checked" >&2
}

fetch arm64 "Godot_v${VERSION}_windows_arm64.exe.zip" \
    683f8dd9fb087db79dfbbc52d5b2209df98218a4fef0d10d8478ec2230ae8db6032a36929677479b9f9c5a6aa0c51ee359d7e57eb5abbcb6cef4998526dec5a6 \
    "Godot_v${VERSION}_windows_arm64.exe"
fetch x86_64 "Godot_v${VERSION}_win64.exe.zip" \
    83decd58fdf67b9d657958a1ae6bf1929c20785315a81effe245874cdc57acb709bf868e00778a96984338c1b29dafdb453c6847747694621c6ecf5da2259993 \
    "Godot_v${VERSION}_win64.exe"
