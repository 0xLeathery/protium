#!/bin/bash
#
# Build FEX's emulator modules for the native arm64 macOS Wine build.
#
# An x86_64 Windows program runs as an ARM64EC process, and Proton's Wine loads
# libarm64ecfex.dll into every one of them. The module has two parts, built here as Proton's
# Makefile.in builds them for Linux ("fex" for arm64ec-windows, "fex_unixlib" for aarch64-unix):
#
#   lib/wine/aarch64-windows/libarm64ecfex.dll   PE, llvm-mingw (arm64ec-w64-mingw32)
#   lib/wine/aarch64-unix/libarm64ecfex.so       its Unix library, Apple clang
#
# A 32-bit x86 program runs in a WoW64 process, an ARM64 process whose wow64.dll loads
# libwow64fex.dll for the 32-bit code ("fex" for aarch64-windows in Makefile.in):
#
#   lib/wine/aarch64-windows/libwow64fex.dll     PE, llvm-mingw (aarch64-w64-mingw32)
#   lib/wine/aarch64-unix/libwow64fex.so         its Unix library, Apple clang
#
# Such a process needs memory below 4 GB, which macOS gives only with the cross-architecture
# entitlement, so this module is built ahead of the day it can run.
#
# under $FEX_DIST. Run Wine with WINEDLLPATH=$FEX_DIST/lib/wine to use them.
#
# The source is not Proton's FEX submodule, which has no macOS support. It is the macos-patched
# branch of github.com/athei/FEX at a fixed commit, with the patches in macos/patches/fex applied
# in the order of their names. Each patch says at its head what it is for. They are local to
# this port: FEX takes no AI-generated code contributions (its CLAUDE.md, AGENTS.md and
# CONTRIBUTING.md), so none of them may be sent to FEX as a pull request; what was found may be
# reported to its developers, and a patch leaves here when the pinned commit has their fix. A
# source tree that differs from the commit by anything else is refused, and the version that
# the modules carry ends in "+local" when they were built with patches.
#
# Environment overrides:
#   BUILD_ROOT     (default ~/projects/proton-macos-build)
#   TOOLCHAIN_DIR  (default ~/projects/proton-macos-toolchain/llvm-mingw-20261020-ucrt-macos-universal)
#   FEX_REPO       (default https://github.com/athei/FEX)
#   FEX_COMMIT     (default 8425ea974e072821c75969723efe49cca605200c, macos-patched on 2026-11-15)
#   FEX_SRC        (default $BUILD_ROOT/fex-src), cloned when missing
#   FEX_DIST       (default $BUILD_ROOT/fex-dist)
#   JOBS           build parallelism (default 12)
#   MIN_FREE_GB    abort if less free disk space than this (default 10)

set -euo pipefail

# The oldest macOS the build runs on: Protium supports macOS 27.0 and later. It is part of
# what decides a rebuild, so a change rebuilds everything this script makes.
export MACOSX_DEPLOYMENT_TARGET=${MACOSX_DEPLOYMENT_TARGET:-27.0}

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
BUILD_ROOT=${BUILD_ROOT:-$HOME/projects/proton-macos-build}
TOOLCHAIN_DIR=${TOOLCHAIN_DIR:-$HOME/projects/proton-macos-toolchain/llvm-mingw-20261020-ucrt-macos-universal}
FEX_REPO=${FEX_REPO:-https://github.com/athei/FEX}
FEX_COMMIT=${FEX_COMMIT:-8425ea974e072821c75969723efe49cca605200c}
FEX_SRC=${FEX_SRC:-$BUILD_ROOT/fex-src}
FEX_DIST=${FEX_DIST:-$BUILD_ROOT/fex-dist}
JOBS=${JOBS:-12}
MIN_FREE_GB=${MIN_FREE_GB:-10}
# What the MinGW build uses of FEX's nested submodules; the test binaries and the Linux-only
# ones are left out.
FEX_SUBMODULES="External/fmt External/range-v3 External/rpmalloc External/unordered_dense External/xxhash External/vixl External/zydis Source/Common/cpp-optparse"
PATCH_DIR=$SCRIPT_DIR/patches/fex
shopt -s nullglob
PATCHES=("$PATCH_DIR"/*.patch)
shopt -u nullglob

log() { echo ":: $*" >&2; }
die() { echo "build-fex.sh: error: $*" >&2; exit 1; }

[ "$(uname -s)" = Darwin ] || die "this script builds on macOS only"
[ "$(uname -m)" = arm64 ] || die "this script expects an arm64 (Apple Silicon) host"
command -v cmake >/dev/null || die "cmake not installed: brew install cmake"
command -v ninja >/dev/null || die "ninja not installed: brew install ninja"
MINGW_BIN=$TOOLCHAIN_DIR/bin
[ -x "$MINGW_BIN/arm64ec-w64-mingw32-clang++" ] || die "llvm-mingw (arm64ec) not found in $TOOLCHAIN_DIR"
[ -x "$MINGW_BIN/aarch64-w64-mingw32-clang++" ] || die "llvm-mingw (aarch64) not found in $TOOLCHAIN_DIR"

mkdir -p "$BUILD_ROOT"
free_gb=$(df -g "$BUILD_ROOT" | awk 'NR==2 {print $4}')
log "free disk space: ${free_gb} GB"
[ "$free_gb" -ge "$MIN_FREE_GB" ] || die "only ${free_gb} GB free on $BUILD_ROOT (minimum ${MIN_FREE_GB} GB)"

########################################################################
# 1. Source at the fixed commit, with our patches
########################################################################
if [ ! -d "$FEX_SRC/.git" ]; then
    log "cloning $FEX_REPO -> $FEX_SRC"
    git clone -q --filter=blob:none --no-checkout "$FEX_REPO" "$FEX_SRC"
fi
git -C "$FEX_SRC" cat-file -e "$FEX_COMMIT^{commit}" 2>/dev/null || git -C "$FEX_SRC" fetch -q origin "$FEX_COMMIT"
[ "$(git -C "$FEX_SRC" rev-parse HEAD 2>/dev/null)" = "$FEX_COMMIT" ] || git -C "$FEX_SRC" checkout -q --detach "$FEX_COMMIT"
# shellcheck disable=SC2086
git -C "$FEX_SRC" submodule update -q --init --depth 1 -- $FEX_SUBMODULES
# A tree that already is the commit with these patches is left alone, so that the build after
# it compiles nothing again. Otherwise the patches of the build before come off first, and what
# is left is compared with the commit.
patch_key=none
[ ${#PATCHES[@]} -eq 0 ] || patch_key=$(cat "${PATCHES[@]}" | shasum | cut -c1-12)
tree_key() { git -C "$FEX_SRC" diff --ignore-submodules=none | shasum | cut -c1-12; }
applied=$FEX_SRC/.git/build-fex-patches
if [ "$(cat "$applied" 2>/dev/null)" != "$patch_key $(tree_key)" ]; then
    if [ -n "$(git -C "$FEX_SRC" status --porcelain --untracked-files=no --ignore-submodules=all | head -1)" ]; then
        for ((i = ${#PATCHES[@]} - 1; i >= 0; i--)); do
            git -C "$FEX_SRC" apply -R "${PATCHES[i]}" 2>/dev/null || true
        done
    fi
    dirty=$(git -C "$FEX_SRC" status --porcelain --untracked-files=no --ignore-submodules=none | head -5)
    [ -z "$dirty" ] || die "$FEX_SRC differs from $FEX_COMMIT by more than the patches in $PATCH_DIR:
$dirty"
    for patch in ${PATCHES[@]+"${PATCHES[@]}"}; do
        git -C "$FEX_SRC" apply "$patch" || die "$(basename "$patch") does not apply to $FEX_COMMIT"
        log "applied $(basename "$patch")"
    done
    echo "$patch_key $(tree_key)" >"$applied"
fi
describe=$(git -C "$FEX_SRC" describe --abbrev=7 --tags 2>/dev/null || git -C "$FEX_SRC" rev-parse --short=7 HEAD)
rev=$(git -C "$FEX_SRC" rev-parse --short=7 HEAD)
if [ ${#PATCHES[@]} -eq 0 ]; then
    log "FEX $describe ($FEX_COMMIT)"
else
    log "FEX $describe + ${#PATCHES[@]} local patch(es) ($FEX_COMMIT)"
    # FEX gives the guest this text through CPUID and wants it under 32 bytes with its end
    describe="${describe:0:24}+local"
fi
# what a build directory was configured for: the version says whether there are patches
config_key="$FEX_COMMIT $describe macos=$MACOSX_DEPLOYMENT_TARGET"

########################################################################
# 2. libarm64ecfex.dll (the arguments of FEX_CMAKE_ARGS and FEX_arm64ec_CMAKE_ARGS in Makefile.in)
########################################################################
pe_build=$BUILD_ROOT/fex-arm64ec
pe_libdir=$FEX_DIST/lib/wine/aarch64-windows
export PATH="$MINGW_BIN:$PATH"
if [ ! -f "$pe_build/build.ninja" ] || [ "$(cat "$pe_build/.build-fex-commit" 2>/dev/null)" != "$config_key" ]; then
    log "configuring $pe_build"
    cmake -G Ninja -S "$FEX_SRC" -B "$pe_build" \
        -DCMAKE_TOOLCHAIN_FILE="$FEX_SRC/Data/CMake/toolchain_mingw.cmake" \
        -DMINGW_TRIPLE=arm64ec-w64-mingw32 \
        -DCMAKE_BUILD_TYPE=Release -DENABLE_LTO=False -DBUILD_TESTING=False \
        -DENABLE_FEXCORE_PROFILER=True -DTUNE_CPU=none -DRANGES_NATIVE=OFF \
        -DOVERRIDE_VERSION="$describe" -DOVERRIDE_HASH="$rev" \
        -DCMAKE_INSTALL_PREFIX="$FEX_DIST" -DCMAKE_INSTALL_LIBDIR="$pe_libdir"
    echo "$config_key" >"$pe_build/.build-fex-commit"
fi
log "building libarm64ecfex.dll"
cmake --build "$pe_build" -j "$JOBS" --target arm64ecfex
mkdir -p "$pe_libdir"
cp "$pe_build/Bin/libarm64ecfex.dll" "$pe_libdir/libarm64ecfex.dll" 2>/dev/null \
    || cp "$(find "$pe_build" -name libarm64ecfex.dll -type f | head -1)" "$pe_libdir/libarm64ecfex.dll"

########################################################################
# 3. libarm64ecfex.so (FEX_UNIXLIB_CMAKE_ARGS in Makefile.in), with the host compiler
########################################################################
unix_build=$BUILD_ROOT/fex-unixlib
unix_libdir=$FEX_DIST/lib/wine/aarch64-unix
if [ ! -f "$unix_build/build.ninja" ] || [ "$(cat "$unix_build/.build-fex-commit" 2>/dev/null)" != "$config_key" ]; then
    log "configuring $unix_build"
    # a fresh tree: CMake keeps the deployment target of the tree's first configure, and ninja
    # rebuilds nothing for it
    rm -rf "$unix_build"
    # Apple's compiler by its path: llvm-mingw's clang++ comes first in PATH by now
    cmake -G Ninja -S "$FEX_SRC/Source/Windows/UnixLib" -B "$unix_build" \
        -DCMAKE_CXX_COMPILER=/usr/bin/clang++ \
        -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=arm64 \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOSX_DEPLOYMENT_TARGET" \
        -DCMAKE_INSTALL_PREFIX="$FEX_DIST" -DCMAKE_INSTALL_LIBDIR="$unix_libdir"
    echo "$config_key" >"$unix_build/.build-fex-commit"
fi
log "building libarm64ecfex.so"
cmake --build "$unix_build" -j "$JOBS" --target arm64ecfex_unixlib
mkdir -p "$unix_libdir"
cp "$(find "$unix_build" -name libarm64ecfex.so -type f | head -1)" "$unix_libdir/libarm64ecfex.so"

########################################################################
# 4. libwow64fex.dll (FEX_aarch64_CMAKE_ARGS in Makefile.in) and libwow64fex.so
########################################################################
wow_build=$BUILD_ROOT/fex-wow64
if [ ! -f "$wow_build/build.ninja" ] || [ "$(cat "$wow_build/.build-fex-commit" 2>/dev/null)" != "$config_key" ]; then
    log "configuring $wow_build"
    cmake -G Ninja -S "$FEX_SRC" -B "$wow_build" \
        -DCMAKE_TOOLCHAIN_FILE="$FEX_SRC/Data/CMake/toolchain_mingw.cmake" \
        -DMINGW_TRIPLE=aarch64-w64-mingw32 \
        -DCMAKE_BUILD_TYPE=Release -DENABLE_LTO=False -DBUILD_TESTING=False \
        -DENABLE_FEXCORE_PROFILER=True -DTUNE_CPU=none -DRANGES_NATIVE=OFF \
        -DOVERRIDE_VERSION="$describe" -DOVERRIDE_HASH="$rev" \
        -DCMAKE_INSTALL_PREFIX="$FEX_DIST" -DCMAKE_INSTALL_LIBDIR="$pe_libdir"
    echo "$config_key" >"$wow_build/.build-fex-commit"
fi
log "building libwow64fex.dll"
cmake --build "$wow_build" -j "$JOBS" --target wow64fex
cp "$wow_build/Bin/libwow64fex.dll" "$pe_libdir/libwow64fex.dll" 2>/dev/null \
    || cp "$(find "$wow_build" -name libwow64fex.dll -type f | head -1)" "$pe_libdir/libwow64fex.dll"
log "building libwow64fex.so"
cmake --build "$unix_build" -j "$JOBS" --target wow64fex_unixlib
cp "$(find "$unix_build" -name libwow64fex.so -type f | head -1)" "$unix_libdir/libwow64fex.so"

log "done: WINEDLLPATH=$FEX_DIST/lib/wine"
ls -l "$pe_libdir/libarm64ecfex.dll" "$unix_libdir/libarm64ecfex.so" "$pe_libdir/libwow64fex.dll" "$unix_libdir/libwow64fex.so" >&2
