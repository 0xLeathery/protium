#!/bin/bash
#
# Build Proton's Steam bridge for the native arm64 macOS Wine build:
#
#   lib/wine/aarch64-windows/lsteamclient.dll   ARM64EC, for x86_64 games (ARM64EC processes)
#   lib/wine/i386-windows/lsteamclient.dll      i386, for 32-bit games under WoW64
#   lib/wine/aarch64-unix/lsteamclient.so       arm64; dlopens Mac Steam's steamclient.dylib
#   lib/wine/aarch64-windows/steam.exe          ARM64EC, Proton's stand-in Steam process
#   lib/wine/i386-windows/steam.exe             i386
#
# under $BRIDGE_DIST, from the Proton tree's own lsteamclient/ and steam_helper/ sources,
# unmodified. This does what Proton's make/rules-makedep.mk does on Linux: it takes the Wine
# build tree's Makefile, points its SUBDIRS at the module's source, drops aarch64 from PE_ARCHS
# (the games are x86, so their processes are ARM64EC or i386), and lets Wine's makedep and make
# build the module against that tree. lsteamclient.so finds steamclient.dylib through
# STEAM_COMPAT_CLIENT_INSTALL_PATH, which Steam sets for a compatibility tool
# (lsteamclient/unixlib.cpp).
#
# Environment overrides:
#   BUILD_ROOT     (default ~/projects/proton-macos-build)
#   BUILD_DIR      the Wine build tree (default $BUILD_ROOT/wine-arm64ec), built with
#                  PE_MODE=msvc WINE_ARCHS=arm64ec,aarch64,i386
#   BRIDGE_DIST    (default $BUILD_ROOT/steam-bridge-dist)
#   TOOLCHAIN_DIR  (default ~/projects/proton-macos-toolchain/llvm-mingw-20261020-ucrt-macos-universal)

set -euo pipefail

# The oldest macOS the build runs on: Protium supports macOS 27.0 and later. It is part of
# what decides a rebuild, so a change rebuilds everything this script makes.
export MACOSX_DEPLOYMENT_TARGET=${MACOSX_DEPLOYMENT_TARGET:-27.0}

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
PROTON_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
BUILD_ROOT=${BUILD_ROOT:-$HOME/projects/proton-macos-build}
BUILD_DIR=${BUILD_DIR:-$BUILD_ROOT/wine-arm64ec}
BRIDGE_DIST=${BRIDGE_DIST:-$BUILD_ROOT/steam-bridge-dist}
TOOLCHAIN_DIR=${TOOLCHAIN_DIR:-$HOME/projects/proton-macos-toolchain/llvm-mingw-20261020-ucrt-macos-universal}
OBJ_ROOT=$BUILD_ROOT/steam-bridge-build
# objects built for another macOS are not reused
if [ "$(cat "$OBJ_ROOT/.macos-target" 2>/dev/null)" != "$MACOSX_DEPLOYMENT_TARGET" ]; then
    rm -rf "$OBJ_ROOT"
    mkdir -p "$OBJ_ROOT"
    echo "$MACOSX_DEPLOYMENT_TARGET" >"$OBJ_ROOT/.macos-target"
fi

log() { echo ":: $*" >&2; }
die() { echo "build-steam-bridge.sh: error: $*" >&2; exit 1; }

[ "$(uname -s)" = Darwin ] || die "this script builds on macOS only"
[ -x "$TOOLCHAIN_DIR/bin/clang++" ] || die "llvm-mingw not found in $TOOLCHAIN_DIR"
# winegcc and wineg++ link PE files with the clang found in PATH, as in macos/build-wine.sh
export PATH="$TOOLCHAIN_DIR/bin:$PATH"
for f in Makefile tools/makedep dlls/ntdll/ntdll.so dlls/winecrt0/aarch64-windows/libwinecrt0.a dlls/winecrt0/i386-windows/libwinecrt0.a; do
    [ -e "$BUILD_DIR/$f" ] || die "no $f in $BUILD_DIR: build Wine first (macos/build-wine.sh with PE_MODE=msvc WINE_ARCHS=arm64ec,aarch64,i386)"
done
grep -q '^PE_ARCHS = .*i386' "$BUILD_DIR/Makefile" || die "$BUILD_DIR has no i386 side (WINE_ARCHS without i386)"

# $1 module name, $2 source directory
build_module() {
    local name=$1 src=$2 obj=$OBJ_ROOT/$1
    mkdir -p "$obj"
    # makedep takes SUBDIRS as words: a checkout whose path has a space in it is reached
    # through a link that has none, with the folder's own name, which makedep names the outputs by
    case "$src" in
    *" "*) mkdir -p "$OBJ_ROOT/src"; ln -sfn "$src" "$OBJ_ROOT/src/$(basename "$src")"; src=$OBJ_ROOT/src/$(basename "$src") ;;
    esac
    log "configuring $name in $obj"
    # The same rewrite as make/rules-makedep.mk, for this Wine build tree. Every PE file of
    # the module goes into PE_ARCHS other than aarch64; the Unix side links against ntdll.so.
    # Its C++ files include winbase.h, which defines wcsncpy as a macro that stops any later
    # declaration of it, and the macOS SDK's libc++ headers declare it after that (glibc's
    # wchar.h comes in earlier on Linux), so <wchar.h> is included first. The module links with
    # wineg++, which needs a C++ compiler per PE target, as Proton's rule adds: here llvm-mingw's
    # clang++ next to the tree's clang.
    sed -e "1i\\
UNIX_LIBS = $BUILD_DIR/dlls/ntdll/ntdll.so
" \
        -e '/^all:$/,$c\
all:' \
        -e '/^SUBDIRS/,/[^\\]$/c\
SUBDIRS = '"$src" \
        -e '/^TOP_INSTALL_LIB/c\
TOP_INSTALL_LIB =' \
        -e '/^srcdir/a\
objdir = '"$BUILD_DIR" \
        -e '/^toolsdir/c\
toolsdir = '"$BUILD_DIR" \
        -e '/^CXXFLAGS/s/$/ -std=c++17 -include wchar.h -DNOMINMAX/' \
        -e '/^PE_ARCHS/s/ aarch64//' \
        -e '/^arm64ec_CC = /{p;s/^arm64ec_CC = \(.*\)clang$/arm64ec_CXX = \1clang++/;}' \
        -e '/^i386_CC = /{p;s/^i386_CC = \(.*\)clang$/i386_CXX = \1clang++/;}' \
        "$BUILD_DIR/Makefile" >"$obj/Makefile"
    grep -q '^arm64ec_CXX = .*clang++$' "$obj/Makefile" && grep -q '^i386_CXX = .*clang++$' "$obj/Makefile" \
        || die "no PE C++ compiler set for $name (the Wine tree's arm64ec_CC or i386_CC is not a clang)"
    touch "$obj/config.status"
    (cd "$obj" && "$BUILD_DIR/tools/makedep") || die "makedep failed for $name"
    log "building $name"
    make -C "$obj" -j"$(sysctl -n hw.ncpu)" >"$OBJ_ROOT/$name.log" 2>&1 || { tail -20 "$OBJ_ROOT/$name.log" >&2; die "make failed for $name, see $OBJ_ROOT/$name.log"; }
}

build_module lsteamclient "$PROTON_DIR/lsteamclient"
build_module steamexe "$PROTON_DIR/steam_helper"

log "staging into $BRIDGE_DIST"
rm -rf "$BRIDGE_DIST"
mkdir -p "$BRIDGE_DIST/lib/wine/aarch64-windows" "$BRIDGE_DIST/lib/wine/i386-windows" "$BRIDGE_DIST/lib/wine/aarch64-unix"
copy() { [ -f "$1" ] || die "missing $1"; cp "$1" "$2"; }
copy "$OBJ_ROOT/lsteamclient/dlls/lsteamclient/arm64ec-windows/lsteamclient.dll" "$BRIDGE_DIST/lib/wine/aarch64-windows/lsteamclient.dll"
copy "$OBJ_ROOT/lsteamclient/dlls/lsteamclient/i386-windows/lsteamclient.dll" "$BRIDGE_DIST/lib/wine/i386-windows/lsteamclient.dll"
copy "$OBJ_ROOT/lsteamclient/dlls/lsteamclient/lsteamclient.so" "$BRIDGE_DIST/lib/wine/aarch64-unix/lsteamclient.so"
copy "$OBJ_ROOT/steamexe/dlls/steam_helper/arm64ec-windows/steam.exe" "$BRIDGE_DIST/lib/wine/aarch64-windows/steam.exe"
copy "$OBJ_ROOT/steamexe/dlls/steam_helper/i386-windows/steam.exe" "$BRIDGE_DIST/lib/wine/i386-windows/steam.exe"
log "done: $BRIDGE_DIST"
