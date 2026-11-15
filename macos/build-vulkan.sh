#!/bin/bash
#
# Build the Vulkan loader for the native arm64 macOS Wine build.
#
# Wine reaches Vulkan through the loader, libvulkan.1.dylib, which it opens at run time; the
# loader then finds the driver (for this port KosmicKrisp, Mesa's Vulkan on Metal). macOS has
# no loader, and Wine's configure only enables Vulkan when it can link one. This builds the
# Khronos loader and headers at a fixed release into $VULKAN_DIST:
#
#   include/vulkan, include/vk_video     the headers
#   lib/libvulkan.1.dylib                the loader
#
# macos/build-wine.sh builds Wine with Vulkan when VULKAN_DIST is given to it, and
# macos/bundle-wine.sh installs the loader. A driver is not part of this.
#
# Environment overrides:
#   BUILD_ROOT     (default /Users/annon/projects/proton-macos-build)
#   VULKAN_DIST    (default $BUILD_ROOT/vulkan-dist)
#   VULKAN_TAG     release tag of both repositories (default vulkan-sdk-1.4.363.0)
#   VULKAN_HEADERS_COMMIT, VULKAN_LOADER_COMMIT   the commits that tag has to name
#   JOBS           build parallelism (default 12)
#   MIN_FREE_GB    abort if less free disk space than this (default 10)

set -euo pipefail

BUILD_ROOT=${BUILD_ROOT:-/Users/annon/projects/proton-macos-build}
VULKAN_DIST=${VULKAN_DIST:-$BUILD_ROOT/vulkan-dist}
VULKAN_TAG=${VULKAN_TAG:-vulkan-sdk-1.4.363.0}
VULKAN_HEADERS_COMMIT=${VULKAN_HEADERS_COMMIT:-6802bb4733b63ed5efd3adb308a6c885ef180ea1}
VULKAN_LOADER_COMMIT=${VULKAN_LOADER_COMMIT:-fa218055ff4948b159f31d43f800c808a13d51df}
JOBS=${JOBS:-12}
MIN_FREE_GB=${MIN_FREE_GB:-10}
SRC=$BUILD_ROOT/vulkan-src
BLD=$BUILD_ROOT/vulkan-build

log() { echo ":: $*" >&2; }
die() { echo "build-vulkan.sh: error: $*" >&2; exit 1; }

[ "$(uname -s)" = Darwin ] || die "this script builds on macOS only"
[ "$(uname -m)" = arm64 ] || die "this script expects an arm64 (Apple Silicon) host"
command -v cmake >/dev/null || die "cmake not installed: brew install cmake"
command -v ninja >/dev/null || die "ninja not installed: brew install ninja"

mkdir -p "$BUILD_ROOT"
free_gb=$(df -g "$BUILD_ROOT" | awk 'NR==2 {print $4}')
log "free disk space: ${free_gb} GB"
[ "$free_gb" -ge "$MIN_FREE_GB" ] || die "only ${free_gb} GB free on $BUILD_ROOT (minimum ${MIN_FREE_GB} GB)"

key="tag=$VULKAN_TAG headers=$VULKAN_HEADERS_COMMIT loader=$VULKAN_LOADER_COMMIT"
if [ -f "$VULKAN_DIST/lib/libvulkan.1.dylib" ] && [ "$(cat "$VULKAN_DIST/KEY" 2>/dev/null)" = "$key" ]; then
    log "Vulkan loader $VULKAN_TAG: built already in $VULKAN_DIST"
    exit 0
fi

# the source of one repository at the tag, which has to be the pinned commit
fetch() {
    local name=$1 commit=$2 dir=$SRC/$1 got
    if [ ! -d "$dir/.git" ]; then
        log "cloning $name $VULKAN_TAG"
        git -c advice.detachedHead=false clone -q --depth 1 --branch "$VULKAN_TAG" "https://github.com/KhronosGroup/$name" "$dir"
    fi
    got=$(git -C "$dir" rev-parse HEAD)
    if [ "$got" != "$commit" ]; then
        git -C "$dir" fetch -q --depth 1 origin "$commit" && git -C "$dir" checkout -q --detach "$commit" \
            || die "$name: $dir is at $got and $commit cannot be fetched"
    fi
    [ "$(git -C "$dir" rev-parse HEAD)" = "$commit" ] || die "$name: $VULKAN_TAG is not $commit"
    [ -z "$(git -C "$dir" status --porcelain --untracked-files=no)" ] || die "$dir has local changes"
}
mkdir -p "$SRC"
fetch Vulkan-Headers "$VULKAN_HEADERS_COMMIT"
fetch Vulkan-Loader "$VULKAN_LOADER_COMMIT"

rm -rf "$BLD" "$VULKAN_DIST"
log "headers"
cmake -G Ninja -S "$SRC/Vulkan-Headers" -B "$BLD/headers" -DCMAKE_INSTALL_PREFIX="$VULKAN_DIST" \
    -DCMAKE_BUILD_TYPE=Release -DVULKAN_HEADERS_ENABLE_MODULE=OFF >"$BLD-headers.log" 2>&1 \
    || die "configuring Vulkan-Headers failed, see $BLD-headers.log"
cmake --build "$BLD/headers" --target install >>"$BLD-headers.log" 2>&1 || die "installing Vulkan-Headers failed, see $BLD-headers.log"

log "loader"
cmake -G Ninja -S "$SRC/Vulkan-Loader" -B "$BLD/loader" -DCMAKE_INSTALL_PREFIX="$VULKAN_DIST" \
    -DCMAKE_PREFIX_PATH="$VULKAN_DIST" -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DBUILD_TESTS=OFF -DUPDATE_DEPS=OFF -DCMAKE_C_COMPILER=/usr/bin/clang -DCMAKE_CXX_COMPILER=/usr/bin/clang++ \
    >"$BLD-loader.log" 2>&1 || die "configuring Vulkan-Loader failed, see $BLD-loader.log"
cmake --build "$BLD/loader" -j "$JOBS" --target install >>"$BLD-loader.log" 2>&1 || die "building Vulkan-Loader failed, see $BLD-loader.log"

[ -f "$VULKAN_DIST/lib/libvulkan.1.dylib" ] || die "no libvulkan.1.dylib in $VULKAN_DIST/lib"
[ -f "$VULKAN_DIST/include/vulkan/vulkan.h" ] || die "no vulkan.h in $VULKAN_DIST/include"
echo "$key" >"$VULKAN_DIST/KEY"
rm -rf "$BLD"
log "done: $VULKAN_DIST/lib/libvulkan.1.dylib ($(lipo -archs "$VULKAN_DIST/lib/libvulkan.1.dylib"))"
