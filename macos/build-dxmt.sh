#!/bin/bash
#
# Build DXMT, Direct3D 10 and 11 on Metal, for the native arm64 macOS Wine build.
#
#   lib/wine/aarch64-windows/{dxgi,d3d10core,d3d11,winemetal}.dll   ARM64X
#   lib/wine/aarch64-unix/winemetal.so                              arm64
#   lib/wine/i386-windows/{dxgi,d3d10core,d3d11,winemetal}.dll      i386, when the Wine build
#                                                                   has a 32-bit side
#
# under $DXMT_DIST. The DLLs are ARM64X: an x86_64 game runs as an ARM64EC process and loads
# their ARM64EC half, so DXMT's own code runs natively and only the game's code goes through
# FEX. They are built with llvm-mingw and DXMT's build-arm64ec.txt cross file against the Wine
# build tree (its libwinecrt0.a, libntdll.a and winebuild, which marks them as Wine builtins),
# and winemetal.so against that tree's winemac.so and ntdll.so, so they belong to that Wine
# build. winemetal.so also links LLVM 15 (macos/build-llvm15.sh) for DXMT's shader converter.
#
# A 32-bit game runs under WoW64 and loads the i386 DLLs, which reach the same winemetal.so
# through its __wine_unix_call_wow64_funcs. Without them its Direct3D 11 would go to Wine's
# wined3d and its Vulkan renderer instead. They are built with llvm-mingw's i686 compilers; the
# cross file for that is written into the build directory, since DXMT's build-win32.txt names
# MinGW-w64 GCC.
#
# The source is the macos-patched branch of github.com/athei/dxmt at a fixed commit, the way
# github.com/athei/mach9 builds it, with the patches in macos/patches/dxmt applied in the order
# of their names. Each patch says at its head what it is for. They are local to this port: DXMT
# does not accept contributions made or co-authored by AI (its AGENTS.md and CONTRIBUTING.md),
# so none of them may be sent to DXMT as a pull request; what was found may be reported to its
# developers, and a patch leaves here when the pinned commit has their fix. A source tree that
# differs from the commit by anything else is refused.
#
# Environment overrides:
#   BUILD_ROOT     (default ~/projects/proton-macos-build)
#   BUILD_DIR      the Wine build tree to link against (default $BUILD_ROOT/wine-arm64ec)
#   TOOLCHAIN_DIR  (default ~/projects/proton-macos-toolchain/llvm-mingw-20261020-ucrt-macos-universal)
#   LLVM15_DIST    (default $BUILD_ROOT/llvm15-dist), built when missing
#   DXMT_REPO      (default https://github.com/athei/dxmt)
#   DXMT_COMMIT    (default 01e59e9bde030f105937f249afaac92ada01b4d7, macos-patched on 2026-11-15)
#   DXMT_SRC       (default $BUILD_ROOT/dxmt-src), cloned when missing
#   DXMT_DIST      (default $BUILD_ROOT/dxmt-dist)
#   VENV           Python environment that gets meson (default $BUILD_ROOT/py-venv)
#   JOBS           build parallelism (default: ninja's own, every core)
#   MIN_FREE_GB    abort if less free disk space than this (default 10)

set -euo pipefail

# The oldest macOS the build runs on: Protium supports macOS 27.0 and later. It is part of
# what decides a rebuild, so a change rebuilds everything this script makes.
export MACOSX_DEPLOYMENT_TARGET=${MACOSX_DEPLOYMENT_TARGET:-27.0}

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
PROTON_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
BUILD_ROOT=${BUILD_ROOT:-$HOME/projects/proton-macos-build}
BUILD_DIR=${BUILD_DIR:-$BUILD_ROOT/wine-arm64ec}
TOOLCHAIN_DIR=${TOOLCHAIN_DIR:-$HOME/projects/proton-macos-toolchain/llvm-mingw-20261020-ucrt-macos-universal}
LLVM15_DIST=${LLVM15_DIST:-$BUILD_ROOT/llvm15-dist}
DXMT_REPO=${DXMT_REPO:-https://github.com/athei/dxmt}
DXMT_COMMIT=${DXMT_COMMIT:-01e59e9bde030f105937f249afaac92ada01b4d7}
DXMT_SRC=${DXMT_SRC:-$BUILD_ROOT/dxmt-src}
DXMT_DIST=${DXMT_DIST:-$BUILD_ROOT/dxmt-dist}
VENV=${VENV:-$BUILD_ROOT/py-venv}
MIN_FREE_GB=${MIN_FREE_GB:-10}
MESON_VERSION=1.11.2
JOBS=${JOBS:-}
PATCH_DIR=$SCRIPT_DIR/patches/dxmt
shopt -s nullglob
PATCHES=("$PATCH_DIR"/*.patch)
shopt -u nullglob
DLLS="dxgi d3d10core d3d11 winemetal"
BLD=$BUILD_ROOT/dxmt-build/arm64x
BLD32=$BUILD_ROOT/dxmt-build/i386

log() { echo ":: $*" >&2; }
die() { echo "build-dxmt.sh: error: $*" >&2; exit 1; }

[ "$(uname -s)" = Darwin ] || die "this script builds on macOS only"
[ "$(uname -m)" = arm64 ] || die "this script expects an arm64 (Apple Silicon) host"
for tool in git ninja xxd python3; do command -v $tool >/dev/null || die "$tool not found"; done
MINGW_BIN=$TOOLCHAIN_DIR/bin
[ -x "$MINGW_BIN/arm64ec-w64-mingw32-g++" ] || die "llvm-mingw (arm64ec) not found in $TOOLCHAIN_DIR"
READOBJ=$MINGW_BIN/llvm-readobj
for f in dlls/winecrt0/aarch64-windows/libwinecrt0.a dlls/winemac.drv/winemac.so dlls/ntdll/ntdll.so tools/winebuild/winebuild; do
    [ -e "$BUILD_DIR/$f" ] || die "no $f in $BUILD_DIR: build Wine first (macos/build-wine.sh with PE_MODE=msvc WINE_ARCHS=arm64ec,aarch64)"
done

mkdir -p "$BUILD_ROOT"
free_gb=$(df -g "$BUILD_ROOT" | awk 'NR==2 {print $4}')
log "free disk space: ${free_gb} GB"
[ "$free_gb" -ge "$MIN_FREE_GB" ] || die "only ${free_gb} GB free on $BUILD_ROOT (minimum ${MIN_FREE_GB} GB)"

########################################################################
# 1. LLVM 15 and meson
########################################################################
LLVM15_DIST=$LLVM15_DIST "$SCRIPT_DIR/build-llvm15.sh"
if [ "$("$VENV/bin/meson" --version 2>/dev/null)" != "$MESON_VERSION" ]; then
    log "meson $MESON_VERSION into $VENV"
    [ -x "$VENV/bin/python3" ] || python3 -m venv "$VENV"
    "$VENV/bin/python3" -m pip install --quiet --disable-pip-version-check "meson==$MESON_VERSION"
fi

########################################################################
# 2. Source at the fixed commit, with our patches
########################################################################
if [ ! -d "$DXMT_SRC/.git" ]; then
    log "cloning $DXMT_REPO -> $DXMT_SRC"
    git clone -q --filter=blob:none --no-checkout "$DXMT_REPO" "$DXMT_SRC"
fi
git -C "$DXMT_SRC" cat-file -e "$DXMT_COMMIT^{commit}" 2>/dev/null || git -C "$DXMT_SRC" fetch -q origin "$DXMT_COMMIT"
[ "$(git -C "$DXMT_SRC" rev-parse HEAD 2>/dev/null)" = "$DXMT_COMMIT" ] \
    || git -C "$DXMT_SRC" -c advice.detachedHead=false checkout -q --detach "$DXMT_COMMIT"
git -C "$DXMT_SRC" submodule update -q --init --recursive
# A tree that already is the commit with these patches is left alone, so that the build after
# it compiles nothing again. Otherwise the patches of the build before come off first, and what
# is left is compared with the commit.
patch_key=none
[ ${#PATCHES[@]} -eq 0 ] || patch_key=$(cat "${PATCHES[@]}" | shasum | cut -c1-12)
tree_key() { git -C "$DXMT_SRC" diff --ignore-submodules=none | shasum | cut -c1-12; }
applied=$DXMT_SRC/.git/build-dxmt-patches
if [ "$(cat "$applied" 2>/dev/null)" != "$patch_key $(tree_key)" ]; then
    if [ -n "$(git -C "$DXMT_SRC" status --porcelain --untracked-files=no --ignore-submodules=all | head -1)" ]; then
        for ((i = ${#PATCHES[@]} - 1; i >= 0; i--)); do
            git -C "$DXMT_SRC" apply -R "${PATCHES[i]}" 2>/dev/null || true
        done
    fi
    dirty=$(git -C "$DXMT_SRC" status --porcelain --untracked-files=no --ignore-submodules=none | head -5)
    [ -z "$dirty" ] || die "$DXMT_SRC differs from $DXMT_COMMIT by more than the patches in $PATCH_DIR:
$dirty"
    for patch in ${PATCHES[@]+"${PATCHES[@]}"}; do
        git -C "$DXMT_SRC" apply "$patch" || die "$(basename "$patch") does not apply to $DXMT_COMMIT"
        log "applied $(basename "$patch")"
    done
    echo "$patch_key $(tree_key)" >"$applied"
fi
describe=$(git -C "$DXMT_SRC" describe --always --tags)
[ ${#PATCHES[@]} -eq 0 ] || describe="$describe + ${#PATCHES[@]} local patch(es)"
log "DXMT $describe ($DXMT_COMMIT)"

########################################################################
# 3. Build: a fresh tree whenever what it is built from or linked against changes
########################################################################
wine_commit=$(git -C "$PROTON_DIR/wine" rev-parse HEAD)
[ -z "$(git -C "$PROTON_DIR/wine" status --porcelain --untracked-files=no)" ] || wine_commit="$wine_commit-dirty"
key="dxmt=$DXMT_COMMIT wine=$wine_commit build=$BUILD_DIR llvm=$(cat "$LLVM15_DIST/KEY") meson=$MESON_VERSION clang=$("$MINGW_BIN/clang" --version | head -1)"
key="$key macos=$MACOSX_DEPLOYMENT_TARGET"
export PATH="$VENV/bin:$MINGW_BIN:$PATH"
if [ "$(cat "$BLD/.build-dxmt-key" 2>/dev/null)" != "$key" ]; then
    log "configuring $BLD"
    rm -rf "$BLD"
    meson setup "$BLD" "$DXMT_SRC" --cross-file "$DXMT_SRC/build-arm64ec.txt" --buildtype release \
        -Dnative_llvm_path="$LLVM15_DIST" -Dwine_build_path="$BUILD_DIR" -Denable_d3d12=false >"$BUILD_ROOT/dxmt-build.setup.log" 2>&1 \
        || die "meson setup failed, see $BUILD_ROOT/dxmt-build.setup.log"
    echo "$key" >"$BLD/.build-dxmt-key"
fi
log "building"
ninja ${JOBS:+-j "$JOBS"} -C "$BLD" src/dxgi/dxgi.dll.postproc src/d3d10/d3d10core.dll.postproc src/d3d11/d3d11.dll.postproc \
    src/winemetal/winemetal.dll.postproc src/winemetal/unix/winemetal.so >"$BUILD_ROOT/dxmt-build.ninja.log" 2>&1 \
    || die "ninja failed, see $BUILD_ROOT/dxmt-build.ninja.log"

########################################################################
# 4. Stage and check
########################################################################
# The 32-bit DLLs, when the Wine build has an i386 side to link against
build32=
if [ -e "$BUILD_DIR/dlls/winecrt0/i386-windows/libwinecrt0.a" ]; then
    build32=1
    [ -x "$MINGW_BIN/i686-w64-mingw32-clang++" ] || die "llvm-mingw (i686) not found in $TOOLCHAIN_DIR"
    if [ "$(cat "$BLD32/.build-dxmt-key" 2>/dev/null)" != "$key" ]; then
        log "configuring $BLD32"
        rm -rf "$BLD32"
        mkdir -p "$BLD32"
        cat >"$BLD32/cross-i686.txt" <<CROSS
[binaries]
c = '$MINGW_BIN/i686-w64-mingw32-clang'
cpp = '$MINGW_BIN/i686-w64-mingw32-clang++'
ar = '$MINGW_BIN/i686-w64-mingw32-ar'
strip = '$MINGW_BIN/i686-w64-mingw32-strip'
windres = '$MINGW_BIN/i686-w64-mingw32-windres'

[properties]
needs_exe_wrapper = true

[host_machine]
system = 'windows'
cpu_family = 'x86'
cpu = 'x86'
endian = 'little'
CROSS
        meson setup "$BLD32/build" "$DXMT_SRC" --cross-file "$BLD32/cross-i686.txt" --buildtype release \
            -Dnative_llvm_path="$LLVM15_DIST" -Dwine_build_path="$BUILD_DIR" -Denable_d3d12=false >"$BUILD_ROOT/dxmt-build-i386.setup.log" 2>&1 \
            || die "meson setup (i386) failed, see $BUILD_ROOT/dxmt-build-i386.setup.log"
        echo "$key" >"$BLD32/.build-dxmt-key"
    fi
    log "building the 32-bit DLLs"
    ninja ${JOBS:+-j "$JOBS"} -C "$BLD32/build" src/dxgi/dxgi.dll.postproc src/d3d10/d3d10core.dll.postproc src/d3d11/d3d11.dll.postproc \
        src/winemetal/winemetal.dll.postproc >"$BUILD_ROOT/dxmt-build-i386.ninja.log" 2>&1 \
        || die "ninja (i386) failed, see $BUILD_ROOT/dxmt-build-i386.ninja.log"
fi

pe=$DXMT_DIST/lib/wine/aarch64-windows
unix=$DXMT_DIST/lib/wine/aarch64-unix
rm -rf "$DXMT_DIST"
mkdir -p "$pe" "$unix"
for dll in $DLLS; do
    dir=$dll; [ $dll = d3d10core ] && dir=d3d10
    cp "$BLD/src/$dir/$dll.dll" "$pe/$dll.dll"
    # A cross file that fell back to another compiler, or a link without -marm64x, would still
    # leave a DLL: of the wrong machine, or without its ARM64 half.
    [ "$("$READOBJ" --file-headers "$pe/$dll.dll" | sed -n 's/^Format: //p' | head -1)" = COFF-ARM64X ] \
        || die "$dll.dll is not ARM64X"
    head -c 128 "$pe/$dll.dll" | grep -qa "Wine builtin DLL" || die "$dll.dll is not marked as a Wine builtin"
done
cp "$BLD/src/winemetal/unix/winemetal.so" "$unix/winemetal.so"
if [ -n "$build32" ]; then
    pe32=$DXMT_DIST/lib/wine/i386-windows
    mkdir -p "$pe32"
    for dll in $DLLS; do
        dir=$dll; [ $dll = d3d10core ] && dir=d3d10
        cp "$BLD32/build/src/$dir/$dll.dll" "$pe32/$dll.dll"
        [ "$("$READOBJ" --file-headers "$pe32/$dll.dll" | sed -n 's/^Format: //p' | head -1)" = COFF-i386 ] \
            || die "$dll.dll (32-bit) is not an i386 DLL"
        head -c 128 "$pe32/$dll.dll" | grep -qa "Wine builtin DLL" || die "$dll.dll (32-bit) is not marked as a Wine builtin"
    done
fi
[ "$(lipo -archs "$unix/winemetal.so")" = arm64 ] || die "winemetal.so is not an arm64-only Mach-O"
echo "$describe" >"$DXMT_DIST/DESCRIBE"
echo "$key" >"$DXMT_DIST/KEY"
log "done: $DXMT_DIST ($describe)"
ls -l "$pe" "$unix" ${build32:+"$pe32"} >&2
