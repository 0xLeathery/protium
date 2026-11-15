#!/bin/bash
#
# Native arm64 macOS build of the Proton wine submodule (no Docker).
#
# Unix side: aarch64 Mach-O built with Apple clang.
# PE side:   aarch64-windows (optionally arm64ec) built with llvm-mingw.
#
# The submodule is mirrored to $SRC_DIR so generated files (configure, vulkan thunks, server
# protocol, spec files) never dirty the submodule, then built out of tree in $BUILD_DIR.
# Re-running rebuilds incrementally.
#
# Environment overrides:
#   BUILD_ROOT     (default /Users/annon/projects/proton-macos-build)
#   SRC_DIR        (default $BUILD_ROOT/wine-src)
#   BUILD_DIR      (default $BUILD_ROOT/wine-aarch64)
#   TOOLCHAIN_DIR  (default /Users/annon/projects/proton-macos-toolchain/llvm-mingw-20261020-ucrt-macos-universal)
#   WINE_ARCHS     PE architectures for --enable-archs (default aarch64)
#   PE_MODE        how the PE side is compiled (default mingw):
#                    mingw  <arch>-w64-mingw32-clang, GNU mode
#                    msvc   the toolchain's clang with -target <arch>-windows, which is what
#                           Proton's own arm64 build does (--with-mingw=clang). arm64ec only
#                           builds this way: in GNU mode the compiler defines __x86_64__ for it
#                           and Wine's headers then pick their x86 inline assembly.
#                  A build directory keeps the mode it was first built with.
#   JOBS           make parallelism (default 12)
#   MIN_FREE_GB    abort if less free disk space than this (default 20)

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
PROTON_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
WINE_ORIGIN=$PROTON_DIR/wine
BUILD_ROOT=${BUILD_ROOT:-/Users/annon/projects/proton-macos-build}
SRC_DIR=${SRC_DIR:-$BUILD_ROOT/wine-src}
BUILD_DIR=${BUILD_DIR:-$BUILD_ROOT/wine-aarch64}
TOOLCHAIN_DIR=${TOOLCHAIN_DIR:-/Users/annon/projects/proton-macos-toolchain/llvm-mingw-20261020-ucrt-macos-universal}
WINE_ARCHS=${WINE_ARCHS:-aarch64}
PE_MODE=${PE_MODE:-mingw}
JOBS=${JOBS:-12}
MIN_FREE_GB=${MIN_FREE_GB:-20}

log() { echo ":: $*" >&2; }
die() { echo "build-wine.sh: error: $*" >&2; exit 1; }

check_disk() {
    local free_gb
    free_gb=$(df -g "$BUILD_ROOT" | awk 'NR==2 {print $4}')
    log "free disk space: ${free_gb} GB"
    [ "$free_gb" -ge "$MIN_FREE_GB" ] || die "only ${free_gb} GB free on $BUILD_ROOT (minimum ${MIN_FREE_GB} GB)"
}

########################################################################
# Host and toolchain
########################################################################
[ "$(uname -s)" = Darwin ] || die "this script builds on macOS only"
[ "$(uname -m)" = arm64 ] || die "this script expects an arm64 (Apple Silicon) host"
[ -f "$WINE_ORIGIN/configure.ac" ] || die "wine submodule not checked out at $WINE_ORIGIN"
command -v brew >/dev/null || die "Homebrew is required (bison, autoconf)"

BISON_BIN=$(brew --prefix bison)/bin
[ -x "$BISON_BIN/bison" ] || die "Homebrew bison not installed: brew install bison"
command -v autoreconf >/dev/null || die "autoconf not installed: brew install autoconf"
MINGW_BIN=$TOOLCHAIN_DIR/bin
[ -x "$MINGW_BIN/aarch64-w64-mingw32-clang" ] || die "llvm-mingw not found in $TOOLCHAIN_DIR"
case "$PE_MODE" in
    mingw) ;;
    msvc) [ -x "$MINGW_BIN/clang" ] && [ -x "$MINGW_BIN/lld-link" ] || die "no clang and lld-link in $MINGW_BIN for PE_MODE=msvc" ;;
    *) die "unknown PE_MODE '$PE_MODE' (mingw or msvc)" ;;
esac
# Objects of the two modes must not be mixed, and make does not rebuild them when only the
# compiler flags change. A directory without the mode file predates PE_MODE and is mingw.
mode_file=$BUILD_DIR/.build-wine-pe-mode
if [ -f "$BUILD_DIR/Makefile" ]; then
    built_mode=mingw
    [ -f "$mode_file" ] && built_mode=$(cat "$mode_file")
    [ "$built_mode" = "$PE_MODE" ] \
        || die "$BUILD_DIR was built with PE_MODE=$built_mode; remove it or use another BUILD_DIR for PE_MODE=$PE_MODE"
fi

# Keg-only bison first; llvm-mingw for the PE side. Nothing is linked globally.
export PATH="$BISON_BIN:$MINGW_BIN:$PATH"

bison_major=$(bison --version | head -1 | sed -n 's/.* \([0-9][0-9]*\)\.[0-9.]*$/\1/p')
[ "${bison_major:-0}" -ge 3 ] || die "bison >= 3 required, found $(bison --version | head -1)"
log "bison: $(command -v bison) ($(bison --version | head -1))"
log "mingw: $(aarch64-w64-mingw32-clang --version | head -1)"

mkdir -p "$BUILD_ROOT" "$SRC_DIR" "$BUILD_DIR"
check_disk

########################################################################
# 1. Mirror the submodule (generated files are excluded so they survive re-syncs)
########################################################################
GENERATED_LIST=$BUILD_ROOT/.wine-src-generated
touch "$GENERATED_LIST"
RSYNC_ARGS=(-a --delete --exclude .git --exclude-from="$GENERATED_LIST")

log "syncing $WINE_ORIGIN -> $SRC_DIR"
rsync "${RSYNC_ARGS[@]}" "$WINE_ORIGIN/" "$SRC_DIR/"

########################################################################
# 2. Generate sources (as Proton's Makefile.in and wine's autogen.sh do)
########################################################################
cd "$SRC_DIR"

vulkan_stamp=$SRC_DIR/.build-wine-vulkan-stamp
if [ ! -f "$vulkan_stamp" ] || [ dlls/winevulkan/make_vulkan -nt "$vulkan_stamp" ] \
   || [ dlls/winevulkan/vk.xml -nt "$vulkan_stamp" ] || [ dlls/winevulkan/video.xml -nt "$vulkan_stamp" ]; then
    log "generating vulkan sources"
    XDG_CACHE_HOME=$BUILD_ROOT/cache dlls/winevulkan/make_vulkan -x vk.xml -X video.xml
    touch "$vulkan_stamp"
fi

log "running tools/make_specfiles and tools/make_requests"
tools/make_specfiles || log "make_specfiles failed (ignored, as in Proton's Makefile.in)"
tools/make_requests

if [ ! -f configure ] || [ configure.ac -nt configure ] || [ aclocal.m4 -nt configure ]; then
    log "autoreconf"
    autoreconf -fi
    rm -rf autom4te.cache
fi

# Everything the generators created or rewrote is now owned by them: keep rsync off it.
rsync -n -i "${RSYNC_ARGS[@]}" "$WINE_ORIGIN/" "$SRC_DIR/" \
    | sed -n -e 's/^\*deleting  *//p' -e 's/^>f[^ ]* //p' \
    | grep -v '/$' | sed 's|^|/|' >>"$GENERATED_LIST" || true
for f in configure include/config.h.in .build-wine-vulkan-stamp; do echo "/$f" >>"$GENERATED_LIST"; done
sort -u -o "$GENERATED_LIST" "$GENERATED_LIST"

########################################################################
# 3. Configure (only when the arguments change; make re-runs config.status itself)
########################################################################
pe_cc_vars=()
if [ "$PE_MODE" = msvc ]; then
    # configure then uses this clang for every PE architecture, with -target <arch>-windows
    pe_cc_vars+=("--with-mingw=$MINGW_BIN/clang")
else
    IFS=, read -r -a archs <<<"$WINE_ARCHS"
    for arch in "${archs[@]}"; do
        pe_cc_vars+=("${arch}_CC=$MINGW_BIN/${arch}-w64-mingw32-clang")
        [ "$arch" = arm64ec ] && pe_cc_vars+=("x86_64_CC=$MINGW_BIN/x86_64-w64-mingw32-clang")
    done
fi

CONFIGURE_ARGS=(
    --prefix="$BUILD_ROOT/install-aarch64"
    --enable-archs="$WINE_ARCHS"
    --disable-tests
    # macOS system frameworks and the host libraries that are present
    --with-coreaudio --with-opencl --with-freetype --with-pthread --with-unwind
    # not available (or not wanted) on this host: disable explicitly instead of letting configure guess
    --without-opengl --without-x --without-wayland --without-xcomposite --without-xcursor --without-xfixes
    --without-xinerama --without-xinput --without-xinput2 --without-xrandr --without-xrender
    --without-xshape --without-xshm --without-xxf86vm
    --without-alsa --without-oss --without-pulse --without-gstreamer --without-ffmpeg
    --without-capi --without-cups --without-dbus --without-fontconfig --without-gcrypt
    --without-gettext --without-gettextpo --without-gphoto --without-gnutls --without-gssapi
    --without-hwloc --without-inotify --without-krb5 --without-netapi --without-pcap
    --without-pcsclite --without-piper --without-sane --without-sdl --without-udev --without-usb
    --without-v4l2 --without-vosk --without-vulkan
    # Proton modules that need Linux-only libraries absent here (libdrm for amd_ags_x64, ffmpeg for winedmo)
    --disable-amd_ags_x64 --disable-winedmo
    BISON="$BISON_BIN/bison"
    "${pe_cc_vars[@]}"
)

args_file=$BUILD_DIR/.build-wine-configure-args
new_args=$(printf '%s\n' "${CONFIGURE_ARGS[@]}")
if [ ! -f "$BUILD_DIR/Makefile" ] || [ ! -f "$args_file" ] || [ "$(cat "$args_file")" != "$new_args" ]; then
    log "configuring in $BUILD_DIR"
    cd "$BUILD_DIR"
    rm -f "$args_file"
    "$SRC_DIR/configure" "${CONFIGURE_ARGS[@]}"
    printf '%s\n' "$new_args" >"$args_file"
    echo "$PE_MODE" >"$mode_file"
fi

########################################################################
# 4. Build
########################################################################
cd "$BUILD_DIR"
log "make -j$JOBS"
make -j"$JOBS"

########################################################################
# 5. Sign the loader
########################################################################
# Windows ARM64 code keeps the TEB in x18, and the kernel only preserves x18 on threads that opt
# into Apple's custom x18 ABI, which needs com.apple.security.custom-x18-abi-toggle on the
# executable. Linking replaces the signature, so sign after every build, incremental ones too.
# wineserver runs no Windows code and stays as the linker signed it.
ENTITLEMENTS=$SCRIPT_DIR/wine-loader.entitlements
[ -f "$ENTITLEMENTS" ] || die "missing $ENTITLEMENTS"
launcher=$BUILD_DIR/wine
[ -L "$launcher" ] && launcher=$BUILD_DIR/$(readlink "$launcher")
for f in "$BUILD_DIR/loader/wine" "$launcher"; do
    [ -f "$f" ] || die "no loader at $f"
    log "signing $f (ad hoc, $(basename "$ENTITLEMENTS"))"
    codesign --force --sign - --entitlements "$ENTITLEMENTS" "$f" || die "codesign failed for $f"
    codesign --verify "$f" || die "signature of $f does not verify"
done

check_disk
log "done: $BUILD_DIR/wine"
