#!/bin/bash
#
# Build vkd3d-proton, Direct3D 12 on Vulkan, for the native arm64 macOS Wine build.
#
#   lib/wine/aarch64-windows/{d3d12,d3d12core}.dll   ARM64X
#
# under $VKD3D_DIST. The DLLs are ARM64X, built with llvm-mingw and vkd3d-proton's own
# build-arm64x.txt cross file: an x86_64 game runs as an ARM64EC process and loads their
# ARM64EC half, so vkd3d-proton's own code runs natively and only the game's code goes through
# FEX. vkd3d-proton reaches Vulkan through Wine's winevulkan and the driver that
# macos/build-mesa.sh builds (KosmicKrisp), and DXMT's dxgi.dll (macos/build-dxmt.sh) presents
# its swap chains.
#
# Unlike DXMT it links nothing of Wine: it is plain PE code on the mingw runtime. Wine ignores a
# DLL in its lib/wine directories that is not marked as a builtin, and vkd3d-proton's build has
# no step for that, so the staged copies are marked with the Wine build tree's winebuild. The
# mark does not depend on the Wine commit. The i386 DLLs, for 32-bit games, are not built: this
# Wine build has no 32-bit side yet.
#
# The source is the macos-patched branch of github.com/athei/vkd3d-proton at a fixed commit,
# built as it is, the way github.com/athei/mach9 builds it. This script never patches the
# source, and refuses a source tree that differs from the commit.
#
# Environment overrides:
#   BUILD_ROOT     (default /Users/annon/projects/proton-macos-build)
#   BUILD_DIR      the Wine build tree whose winebuild marks the DLLs (default $BUILD_ROOT/wine-arm64ec)
#   TOOLCHAIN_DIR  (default /Users/annon/projects/proton-macos-toolchain/llvm-mingw-20261020-ucrt-macos-universal)
#   VKD3D_REPO     (default https://github.com/athei/vkd3d-proton)
#   VKD3D_COMMIT   (default c5e2c9b8c55872893e3ba47d60448dd4f35185ef, macos-patched on 2026-11-15)
#   VKD3D_SRC      (default $BUILD_ROOT/vkd3d-proton-src), cloned when missing
#   VKD3D_DIST     (default $BUILD_ROOT/vkd3d-proton-dist)
#   VENV           Python environment that gets meson (default $BUILD_ROOT/py-venv)
#   JOBS           build parallelism (default 12)
#   MIN_FREE_GB    abort if less free disk space than this (default 10)

set -euo pipefail

BUILD_ROOT=${BUILD_ROOT:-/Users/annon/projects/proton-macos-build}
BUILD_DIR=${BUILD_DIR:-$BUILD_ROOT/wine-arm64ec}
TOOLCHAIN_DIR=${TOOLCHAIN_DIR:-/Users/annon/projects/proton-macos-toolchain/llvm-mingw-20261020-ucrt-macos-universal}
VKD3D_REPO=${VKD3D_REPO:-https://github.com/athei/vkd3d-proton}
VKD3D_COMMIT=${VKD3D_COMMIT:-c5e2c9b8c55872893e3ba47d60448dd4f35185ef}
VKD3D_SRC=${VKD3D_SRC:-$BUILD_ROOT/vkd3d-proton-src}
VKD3D_DIST=${VKD3D_DIST:-$BUILD_ROOT/vkd3d-proton-dist}
VENV=${VENV:-$BUILD_ROOT/py-venv}
JOBS=${JOBS:-12}
MIN_FREE_GB=${MIN_FREE_GB:-10}
MESON_VERSION=1.11.2
TRIPLE=arm64ec-w64-mingw32
DLLS="d3d12 d3d12core"
BLD=$BUILD_ROOT/vkd3d-proton-build/arm64x

log() { echo ":: $*" >&2; }
die() { echo "build-vkd3d-proton.sh: error: $*" >&2; exit 1; }

[ "$(uname -s)" = Darwin ] || die "this script builds on macOS only"
[ "$(uname -m)" = arm64 ] || die "this script expects an arm64 (Apple Silicon) host"
for tool in git ninja python3; do command -v $tool >/dev/null || die "$tool not found"; done
MINGW_BIN=$TOOLCHAIN_DIR/bin
READOBJ=$MINGW_BIN/llvm-readobj
[ -x "$READOBJ" ] || die "no llvm-readobj in $MINGW_BIN"
WINEBUILD=$BUILD_DIR/tools/winebuild/winebuild
[ -x "$WINEBUILD" ] || die "no tools/winebuild/winebuild in $BUILD_DIR: build Wine first (macos/build-wine.sh)"
# vkd3d-proton compiles its internal shaders with glslang; its meson.build takes either name.
GLSLANG=$(command -v glslang || command -v glslangValidator || true)
[ -n "$GLSLANG" ] || die "glslang not found (brew install glslang)"

# llvm-mingw goes after everything else on PATH: its bin has an unprefixed clang, which would
# otherwise take the place of Apple's as the native compiler. The cross file names its tools
# without a path, so each has to resolve into llvm-mingw and not to another mingw earlier on
# PATH. meson prefers an unprefixed widl to the one the cross file names, and llvm-mingw has
# none, so one from elsewhere is refused.
export PATH="$PATH:$MINGW_BIN"
for tool in gcc g++ ar strip widl windres; do
    [ "$(command -v "$TRIPLE-$tool")" = "$MINGW_BIN/$TRIPLE-$tool" ] \
        || die "$TRIPLE-$tool does not resolve to $MINGW_BIN (found: $(command -v "$TRIPLE-$tool" || echo nothing))"
done
! command -v widl >/dev/null || die "$(command -v widl) would take the place of llvm-mingw's widl; remove it from PATH"

key="vkd3d-proton=$VKD3D_COMMIT meson=$MESON_VERSION clang=[$("$MINGW_BIN/clang" --version | head -1)] glslang=[$("$GLSLANG" --version | head -1)]"
complete=yes
for dll in $DLLS; do [ -f "$VKD3D_DIST/lib/wine/aarch64-windows/$dll.dll" ] || complete=no; done
if [ $complete = yes ] && [ "$(cat "$VKD3D_DIST/KEY" 2>/dev/null)" = "$key" ]; then
    log "vkd3d-proton $(cat "$VKD3D_DIST/DESCRIBE" 2>/dev/null): built already in $VKD3D_DIST"
    exit 0
fi

mkdir -p "$BUILD_ROOT"
free_gb=$(df -g "$BUILD_ROOT" | awk 'NR==2 {print $4}')
log "free disk space: ${free_gb} GB"
[ "$free_gb" -ge "$MIN_FREE_GB" ] || die "only ${free_gb} GB free on $BUILD_ROOT (minimum ${MIN_FREE_GB} GB)"

########################################################################
# 1. meson
########################################################################
if [ "$("$VENV/bin/meson" --version 2>/dev/null)" != "$MESON_VERSION" ]; then
    log "meson $MESON_VERSION into $VENV"
    [ -x "$VENV/bin/python3" ] || python3 -m venv "$VENV"
    "$VENV/bin/python3" -m pip install --quiet --disable-pip-version-check "meson==$MESON_VERSION"
fi

########################################################################
# 2. Source at the fixed commit, unmodified
########################################################################
# With every tag: vkd3d-proton's build runs `git describe --tags` for the version it reports.
# The submodules (dxil-spirv with its own, and the Khronos headers) are fetched shallow at the
# commits the commit records.
if [ ! -d "$VKD3D_SRC/.git" ]; then
    log "cloning $VKD3D_REPO -> $VKD3D_SRC"
    GIT_TERMINAL_PROMPT=0 git clone -q --no-checkout "$VKD3D_REPO" "$VKD3D_SRC"
fi
git -C "$VKD3D_SRC" cat-file -e "$VKD3D_COMMIT^{commit}" 2>/dev/null || GIT_TERMINAL_PROMPT=0 git -C "$VKD3D_SRC" fetch -q origin "$VKD3D_COMMIT"
[ "$(git -C "$VKD3D_SRC" rev-parse HEAD 2>/dev/null)" = "$VKD3D_COMMIT" ] \
    || git -C "$VKD3D_SRC" -c advice.detachedHead=false checkout -q --detach "$VKD3D_COMMIT"
GIT_TERMINAL_PROMPT=0 git -C "$VKD3D_SRC" submodule update -q --init --recursive --depth 1
# a leading '+', '-' or 'U' marks a submodule that is not at the recorded commit
bad=$(git -C "$VKD3D_SRC" submodule status --recursive | grep '^[-+U]' || true)
[ -z "$bad" ] || die "submodules of $VKD3D_SRC do not match $VKD3D_COMMIT:
$bad"
dirty=$(git -C "$VKD3D_SRC" status --porcelain --untracked-files=no --ignore-submodules=none | head -5)
[ -z "$dirty" ] || die "$VKD3D_SRC differs from $VKD3D_COMMIT; vkd3d-proton is built unmodified:
$dirty"
describe=$(git -C "$VKD3D_SRC" describe --always --tags)
log "vkd3d-proton $describe ($VKD3D_COMMIT)"

########################################################################
# 3. Build: a fresh tree whenever what it is built from changes
########################################################################
if [ "$(cat "$BLD/.build-vkd3d-key" 2>/dev/null)" != "$key" ]; then
    log "configuring $BLD"
    rm -rf "$BLD"
    "$VENV/bin/meson" setup "$BLD" "$VKD3D_SRC" --cross-file "$VKD3D_SRC/build-arm64x.txt" --buildtype release \
        -Denable_tests=false >"$BUILD_ROOT/vkd3d-proton-build.setup.log" 2>&1 \
        || die "meson setup failed, see $BUILD_ROOT/vkd3d-proton-build.setup.log"
    echo "$key" >"$BLD/.build-vkd3d-key"
fi
log "building"
# only the two DLLs; the default targets add nothing the bundle needs
ninja -C "$BLD" -j"$JOBS" libs/d3d12/d3d12.dll libs/d3d12core/d3d12core.dll >"$BUILD_ROOT/vkd3d-proton-build.ninja.log" 2>&1 \
    || die "ninja failed, see $BUILD_ROOT/vkd3d-proton-build.ninja.log"

########################################################################
# 4. Stage, mark and check
########################################################################
# Into $VKD3D_DIST.part, renamed into place once all of it is checked. The mark goes on the
# staged copies, so ninja never sees its outputs changed.
part=$VKD3D_DIST.part
pe=$part/lib/wine/aarch64-windows
rm -rf "$part"
mkdir -p "$pe"
for dll in $DLLS; do
    cp "$BLD/libs/$dll/$dll.dll" "$pe/$dll.dll"
    "$WINEBUILD" --builtin "$pe/$dll.dll" || die "winebuild --builtin failed for $dll.dll"
    # A cross file that fell back to another compiler, or a link without -marm64x, would still
    # leave a DLL: of the wrong machine, or without its ARM64 half.
    [ "$("$READOBJ" --file-headers "$pe/$dll.dll" | sed -n 's/^Format: //p' | head -1)" = COFF-ARM64X ] \
        || die "$dll.dll is not ARM64X"
    head -c 128 "$pe/$dll.dll" | grep -qa "Wine builtin DLL" || die "$dll.dll is not marked as a Wine builtin"
    # the entry points Wine's own d3d12 has, in both halves: games call D3D12CreateDevice, and
    # d3d12.dll finds d3d12core.dll through the other two
    case $dll in
        d3d12) syms="D3D12CreateDevice" ;;
        d3d12core) syms="D3D12GetInterface D3D12SDKVersion" ;;
    esac
    for sym in $syms; do
        n=$("$READOBJ" --coff-exports "$pe/$dll.dll" | grep -cxE " *Name: $sym" || true)
        [ "$n" = 2 ] || die "$dll.dll exports $sym in $n of its 2 halves"
    done
done
echo "$describe" >"$part/DESCRIBE"
echo "$key" >"$part/KEY"
rm -rf "$VKD3D_DIST"
mv "$part" "$VKD3D_DIST"
log "done: $VKD3D_DIST ($describe)"
ls -l "$VKD3D_DIST/lib/wine/aarch64-windows" >&2
