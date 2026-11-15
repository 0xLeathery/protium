#!/bin/bash
#
# Build the LLVM 15 static libraries that DXMT needs.
#
# DXMT's Unix library, winemetal.so, links airconv, DXMT's converter from Direct3D shader
# bytecode to Metal's, which is written against LLVM 15. There is no arm64 LLVM 15 to install,
# so its libraries are built from the release tag into $LLVM15_DIST (include/, lib/libLLVM*.a),
# the way github.com/athei/mach9 does it: no code generation targets and no tools, since
# airconv only writes bitcode.
#
# Nothing is built when $LLVM15_DIST is complete for the pinned commit.
#
# Environment overrides:
#   BUILD_ROOT       (default /Users/annon/projects/proton-macos-build)
#   LLVM15_DIST      (default $BUILD_ROOT/llvm15-dist)
#   LLVM15_TAG       (default llvmorg-15.0.7)
#   LLVM15_COMMIT    the commit that tag has to name
#   JOBS             build parallelism (default 12)
#   MIN_FREE_GB      abort if less free disk space than this (default 14: the source and the
#                    build tree take about 4 GB until they are removed at the end)

set -euo pipefail

BUILD_ROOT=${BUILD_ROOT:-/Users/annon/projects/proton-macos-build}
LLVM15_DIST=${LLVM15_DIST:-$BUILD_ROOT/llvm15-dist}
LLVM15_TAG=${LLVM15_TAG:-llvmorg-15.0.7}
LLVM15_COMMIT=${LLVM15_COMMIT:-8dfdcc7b7bf66834a761bd8de445840ef68e4d1a}
JOBS=${JOBS:-12}
MIN_FREE_GB=${MIN_FREE_GB:-14}
SRC=$BUILD_ROOT/llvm15-src
BLD=$BUILD_ROOT/llvm15-build

log() { echo ":: $*" >&2; }
die() { echo "build-llvm15.sh: error: $*" >&2; exit 1; }

[ "$(uname -s)" = Darwin ] || die "this script builds on macOS only"
[ "$(uname -m)" = arm64 ] || die "this script expects an arm64 (Apple Silicon) host"
command -v cmake >/dev/null || die "cmake not installed: brew install cmake"
command -v ninja >/dev/null || die "ninja not installed: brew install ninja"

key="tag=$LLVM15_TAG commit=$LLVM15_COMMIT"
if [ -f "$LLVM15_DIST/lib/libLLVMCore.a" ] && [ "$(cat "$LLVM15_DIST/KEY" 2>/dev/null)" = "$key" ]; then
    log "LLVM $LLVM15_TAG: built already in $LLVM15_DIST"
    exit 0
fi

mkdir -p "$BUILD_ROOT"
free_gb=$(df -g "$BUILD_ROOT" | awk 'NR==2 {print $4}')
log "free disk space: ${free_gb} GB"
[ "$free_gb" -ge "$MIN_FREE_GB" ] || die "only ${free_gb} GB free on $BUILD_ROOT (minimum ${MIN_FREE_GB} GB)"

# Only what the build of llvm/ reads: the checkout of the whole project is three times as big.
if [ ! -d "$SRC/.git" ]; then
    log "cloning llvm-project $LLVM15_TAG (llvm, cmake, third-party)"
    git -c advice.detachedHead=false clone -q --depth 1 --branch "$LLVM15_TAG" --filter=blob:none --sparse \
        https://github.com/llvm/llvm-project "$SRC"
    git -C "$SRC" sparse-checkout set llvm cmake third-party
fi
[ "$(git -C "$SRC" rev-parse HEAD)" = "$LLVM15_COMMIT" ] || die "$SRC is not at $LLVM15_COMMIT ($LLVM15_TAG)"
[ -z "$(git -C "$SRC" status --porcelain --untracked-files=no)" ] || die "$SRC has local changes"

rm -rf "$BLD" "$LLVM15_DIST" "$LLVM15_DIST.part"
log "configuring"
# _LIBCPP_KEEP_TRANSITIVE_INCLUDES_LLVM23: LLVM 15 relies on headers that later libc++ versions
# no longer include from one another.
cmake -S "$SRC/llvm" -B "$BLD" -G Ninja \
    -DCMAKE_C_COMPILER=/usr/bin/clang -DCMAKE_CXX_COMPILER=/usr/bin/clang++ \
    -DCMAKE_INSTALL_PREFIX="$LLVM15_DIST.part" \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DLLVM_HOST_TRIPLE=arm64-apple-darwin \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_CXX_FLAGS="-D_LIBCPP_KEEP_TRANSITIVE_INCLUDES_LLVM23" \
    -DLLVM_ENABLE_ASSERTIONS=On \
    -DLLVM_ENABLE_ZSTD=Off \
    -DLLVM_TARGETS_TO_BUILD="" \
    -DLLVM_BUILD_TOOLS=Off \
    -DLLVM_INCLUDE_BENCHMARKS=Off \
    -DLLVM_INCLUDE_TESTS=Off \
    -DLLVM_INCLUDE_EXAMPLES=Off \
    -DLLVM_VERSION_PRINTER_SHOW_HOST_TARGET_INFO=Off >"$BLD.configure.log" 2>&1 \
    || die "configuring LLVM failed, see $BLD.configure.log"
log "building (ninja -j$JOBS)"
cmake --build "$BLD" -j "$JOBS" >"$BLD.build.log" 2>&1 || die "building LLVM failed, see $BLD.build.log"
cmake --install "$BLD" --prefix "$LLVM15_DIST.part" >/dev/null || die "installing LLVM failed"
[ -f "$LLVM15_DIST.part/lib/libLLVMCore.a" ] || die "no libLLVMCore.a in the install"
echo "$key" >"$LLVM15_DIST.part/KEY"
mv "$LLVM15_DIST.part" "$LLVM15_DIST"
# the source and the objects are not needed again while the pin stays
rm -rf "$BLD" "$SRC"
log "done: $LLVM15_DIST ($(ls "$LLVM15_DIST/lib" | grep -c '\.a$') static libraries, $(du -sh "$LLVM15_DIST" | cut -f1))"
