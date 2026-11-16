#!/bin/bash
#
# Wave 3b acceptance check for the native arm64 macOS Wine build: Wine runs from an install tree
# with its loader in wine.app (macos/bundle-wine.sh), the only place where a provisioning profile
# can give it the cross-architecture entitlement (4K pages, memory below 4 GB, hardware TSO), and
# runs x86_64 programs through FEX.
#
#   macos/tests/check-wave3b.sh                                    # ad-hoc signed bundle
#   LOADER_PROFILE=/path/to/loader.provisionprofile macos/tests/check-wave3b.sh
#
# This wave's build is not the one of the earlier waves: an x86_64 program runs as an ARM64EC
# process, so the PE side is built for arm64ec and aarch64 with clang in MSVC mode, as Proton's
# own arm64 build is (PE_MODE=msvc, see macos/build-wine.sh), in $BUILD_DIR. The earlier checks
# keep their aarch64 mingw build in $MINGW_BUILD_DIR; item 5 runs them there and their runtime
# items here as well.
#
# Items (pass/fail):
#   1  the bundle: wine.app/Contents/{MacOS/wine, Info.plist} next to ntdll.so, lib/wine/
#      aarch64-unix/wine and bin/wine are links into it, the signature verifies (--strict) and
#      carries exactly the x18 entitlement (with LOADER_PROFILE: the cross-architecture
#      entitlement too, and the profile is embedded); wineserver has no entitlements; FEX's
#      ARM64EC module is installed with Wine's modules
#   2  the loader finds ntdll.so started through bin/wine, through the link next to ntdll.so and
#      by its path in the bundle (wine --version)
#   3  bin/wine hello.exe prints its line and exits 0, HELLO_RUNS runs (the first in a fresh
#      prefix), and no allocation is tried past the end of the host address space
#   4  bin/wine wineboot -u in a fresh prefix, WINEBOOT_RUNS runs: exit 0, no fault, and every
#      process Wine starts is started by the loader's path inside wine.app, none through the link
#      (a process started through the link has no bundle)
#   5  regression: check-wave3a.sh passes on the aarch64 mingw build (it runs check-wave1.sh, 2a
#      and 2b itself), and its runtime items (3 4 6 7) pass on this wave's build
#   6  other targets unchanged: every line of this wave in Wine is under __APPLE__ && __aarch64__,
#      or under WX_EXCLUSIVE_HOST, which is only defined there (with either undefined the files
#      are the wave base text); diff scope
#   7  through FEX: bin/wine runs hello.exe built as ARM64EC and hello_x64.exe, an x86_64
#      program built with the mingw compiler and its CRT; both print their line and exit 0,
#      FEX_RUNS runs, and libarm64ecfex.dll is loaded as a builtin. cpuid_x64.exe is told that
#      the CPU has SSE4.2, PCLMULQDQ, AES and SHA, which every Apple Silicon CPU has the ARM
#      counterparts of, and Wine no longer says that the ID registers are a stub
#   8  MAP_JIT memory for an emulator's code: jit_view_test.exe passes (a view allocated with
#      Wine's JIT attribute follows protection changes, decommits and guard pages and keeps its
#      contents; a write from Windows code faults and Wine says why). jit_x64.exe, an x86_64
#      program of 4000 functions, prints the checksum of a native build of its source through
#      FEX, FEX says that it uses per-thread W^X memory, and the run takes at most
#      JIT_MAX_FLIPS page flips (over 8000 with FEX's code in flipped pages)
#   9  callbacks from native code into x86 code: callback_x64.exe, an x86_64 program, has the C
#      runtime's qsort(), which is native code, call its comparison function, which is x86
#      code. With 1000 elements (some 12000 callbacks) it has to sort them. With
#      CALLBACK_ELEMENTS elements (millions of callbacks) it has to as well when there is a
#      profile. Without one it does not finish, and the item is a TODO then, not a pass: FEX
#      catches the end of its call-return stack with a 4K guard page, which a host with 16K
#      pages cannot give it, so the program gets an access violation it did not cause. Any
#      larger x86_64 program runs into this (the first was the Godot editor).
#  10  a 32-bit program: hello_x86.exe, built for i686, runs in a WoW64 process through FEX's
#      libwow64fex.dll and prints its line, FEX_RUNS runs, when there is a profile. Without one
#      the item is a TODO: a 32-bit process lives below 4 GB, where macOS maps nothing without
#      the entitlement. What can be had before that day is checked: the build step wants
#      Wine's i386 DLLs and FEX's WoW64 module, and the item runs the program from the build
#      tree, which has the 32-bit side, and wants ntdll to refuse it by saying what is missing
#      and not to end on the assertion in build_wow64_parameters(), which left a crash report
#      for every 32-bit program that anything tried to start.
#  11  memory below 4 GB: shared_data_test.exe, for 32-bit x86 and for x86_64, finds
#      KUSER_SHARED_DATA at its Windows address, 0x7ffe0000, as a read-only page of its own
#      with a tick count in it, when there is a profile. Without one nothing can be mapped
#      there and the item is a TODO.
# The build (macos/build-wine.sh, macos/build-fex.sh, macos/bundle-wine.sh) and the test programs
# come first ("build").
#
# What the profile gates: 4K pages (item 9 needs them), memory below 4 GB (items 10 and 11) and
# hardware TSO, which has no item yet. Without LOADER_PROFILE those items are TODO lines and the
# exit status is 3 when nothing failed (1 when an item failed, 0 only when all of it passed).
# Logs go to $EVIDENCE_DIR.

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
PROTON_DIR=$(cd "$SCRIPT_DIR/../.." && pwd)
WINE_DIR=$PROTON_DIR/wine
BUILD_ROOT=${BUILD_ROOT:-/Users/annon/projects/proton-macos-build}
BUILD_DIR=${BUILD_DIR:-$BUILD_ROOT/wine-arm64ec}
MINGW_BUILD_DIR=${MINGW_BUILD_DIR:-$BUILD_ROOT/wine-aarch64}
FEX_DIST=${FEX_DIST:-$BUILD_ROOT/fex-dist}
VULKAN_DIST=${VULKAN_DIST:-$BUILD_ROOT/vulkan-dist}
DXMT_DIST=${DXMT_DIST:-$BUILD_ROOT/dxmt-dist}
MESA_DIST=${MESA_DIST:-$BUILD_ROOT/mesa-dist}
VKD3D_DIST=${VKD3D_DIST:-$BUILD_ROOT/vkd3d-proton-dist}
SRC_DIR=${SRC_DIR:-$BUILD_ROOT/wine-src}
TOOLCHAIN_DIR=${TOOLCHAIN_DIR:-/Users/annon/projects/proton-macos-toolchain/llvm-mingw-20261020-ucrt-macos-universal}
EVIDENCE_DIR=${EVIDENCE_DIR:-$BUILD_ROOT/evidence/wave3b}
LOADER_PROFILE=${LOADER_PROFILE:-}
# wine and superproject commits this wave starts from (the tips after Wave 3a)
WINE_WAVE_BASE=${WINE_WAVE_BASE:-47775ab13b6141ecf958fbb5fedc5fd5e7bc8604}
SUPER_WAVE_BASE=${SUPER_WAVE_BASE:-56a14d835ae96ab59e2753a21fb855c08ce913a5}
WINEBOOT_TIMEOUT=${WINEBOOT_TIMEOUT:-300}
RUN_TIMEOUT=${RUN_TIMEOUT:-120}
HELLO_RUNS=${HELLO_RUNS:-5}
WINEBOOT_RUNS=${WINEBOOT_RUNS:-3}
FEX_RUNS=${FEX_RUNS:-5}
CALLBACK_ELEMENTS=${CALLBACK_ELEMENTS:-200000}
CALLBACK_TIMEOUT=${CALLBACK_TIMEOUT:-30}
JIT_MAX_FLIPS=${JIT_MAX_FLIPS:-200}
UNIX_DIR=aarch64-unix
X18_ENTITLEMENT=com.apple.security.custom-x18-abi-toggle
CROSS_ARCH_ENTITLEMENT=com.apple.developer.cross-architecture-support
# Wine files this wave may change: the loader in an app bundle, the ARM64 ID registers that FEX
# takes the CPU features of x86 code from, and the end of the host address space; plus those of
# Wave 4 (winemac.drv's table for DXMT, see check-wave4.sh item 7).
WAVE_FILES="loader/main.c dlls/ntdll/unix/loader.c dlls/ntdll/unix/system.c dlls/ntdll/unix/virtual.c dlls/winemac.drv/macdrv.h dlls/winemac.drv/window.c dlls/uiautomationcore/uia_client.c"
# The build scripts stop below 20 GB free by default; 10 GB is the limit agreed for this work.
export MIN_FREE_GB=${MIN_FREE_GB:-10}
# A new prefix would otherwise wait on the Mono and Gecko install dialogs.
export WINEDLLOVERRIDES=${WINEDLLOVERRIDES:-mscoree,mshtml=}

mkdir -p "$EVIDENCE_DIR"
RESULTS=()
FAILED=0
TODO=0
# CHECK_ITEMS limits the run to some items ("build" rebuilds Wine, the bundle and the test programs).
CHECK_ITEMS=${CHECK_ITEMS:-"build 1 2 3 4 5 6 7 8 9 10 11"}
want() { case " $CHECK_ITEMS " in *" $1 "*) return 0 ;; esac; return 1; }
pass() { RESULTS+=("PASS  item $1: $2"); echo "PASS  item $1: $2"; }
fail() { RESULTS+=("FAIL  item $1: $2"); echo "FAIL  item $1: $2"; FAILED=1; }
todo() { RESULTS+=("TODO  $1"); echo "TODO  $1"; TODO=1; }
# run_timeout SECONDS cmd...: the command's exit status, or 142 when it ran out of time. The
# command runs as a child that is killed with SIGKILL then: an alarm in the command's own
# process is not enough, an x86_64 program that spins in an exception loop under FEX lived on
# for minutes past one.
run_timeout() {
    local t=$1; shift
    perl -e 'my $t = shift; my $pid = fork; die "fork: $!" unless defined $pid;
             if (!$pid) { exec @ARGV or die "exec: $!" }
             $SIG{ALRM} = sub { kill "KILL", $pid }; alarm $t; waitpid $pid, 0;
             exit((($? & 127) == 9) ? 142 : ($? & 127) ? 128 + ($? & 127) : $? >> 8)' "$t" "$@"
}

WORK=$EVIDENCE_DIR/work
mkdir -p "$WORK"
MINGW_BIN=$TOOLCHAIN_DIR/bin
OBJDUMP=$MINGW_BIN/llvm-objdump
READOBJ=$MINGW_BIN/llvm-readobj
INSTALL_DIR=$(sed -n 's/^prefix = //p' "$BUILD_DIR/Makefile" 2>/dev/null | head -1)
INSTALL_DIR=$(cd "${INSTALL_DIR:-/nonexistent}" 2>/dev/null && pwd -P || echo "${INSTALL_DIR:-/nonexistent}")
VERSION=$(sed -n 's/^PACKAGE_VERSION = //p' "$BUILD_DIR/Makefile" 2>/dev/null | head -1)
UNIXLIB=$INSTALL_DIR/lib/wine/$UNIX_DIR
APP=$UNIXLIB/wine.app
BUNDLE_LOADER=$APP/Contents/MacOS/wine
WINE=$INSTALL_DIR/bin/wine
SERVER=$INSTALL_DIR/bin/wineserver
TESTS_OUT=$EVIDENCE_DIR/programs
mkdir -p "$TESTS_OUT"

cleanup_prefix() {
    WINEPREFIX=$1 run_timeout 30 "$SERVER" -k >/dev/null 2>&1
    WINEPREFIX=$1 run_timeout 60 "$SERVER" -w >/dev/null 2>&1
    rm -rf "$1"
}
# Proton's wineserver starts to shut down the moment its last process exits (server/main.c sets
# master_socket_timeout to 0, where Wine's own default is 3 seconds). A wine that starts right
# after another one has exited then meets a server that is going away: it brings Wine's
# services up again, and now and then it is dropped while the server exits, which ends it with
# status 0 and no output. For a run of launches in one prefix, hold_server starts a server that
# waits 10 seconds for the next process instead; cleanup_prefix ends it.
hold_server() { WINEPREFIX=$1 run_timeout 30 "$SERVER" -p10 >/dev/null 2>&1; }
# entitlement keys of a signed file or bundle, one per line
entitlement_keys() {
    codesign -d --entitlements - --xml "$1" 2>/dev/null | perl -ne 'print "$1\n" while /<key>([^<]*)<\/key>/g'
}

########################################################################
# Build: Wine, the bundle and the test programs
########################################################################
if want build; then
echo "== build: macos/build-vulkan.sh, build-wine.sh (arm64ec + aarch64 + i386, MSVC mode, Vulkan), build-fex.sh, build-dxmt.sh, build-mesa.sh, build-vkd3d-proton.sh, bundle-wine.sh and the test programs"
# This build has Vulkan and DXMT, which Wave 4 uses; it is one configuration, so that the two
# waves' checks don't rebuild Wine and the bundle back and forth. Nothing in this wave's items
# needs either.
vlog=$EVIDENCE_DIR/build-vulkan.log
VULKAN_DIST=$VULKAN_DIST "$PROTON_DIR/macos/build-vulkan.sh" >"$vlog" 2>&1
vstatus=$?
if [ $vstatus = 0 ]; then
    pass build "build-vulkan.sh exit 0 ($vlog)"
else
    fail build "build-vulkan.sh exited $vstatus: $(tail -1 "$vlog") ($vlog)"
fi
blog=$EVIDENCE_DIR/build.log
start=$(date +%s)
PE_MODE=msvc WINE_ARCHS=arm64ec,aarch64,i386 BUILD_DIR=$BUILD_DIR VULKAN_DIST=$VULKAN_DIST "$PROTON_DIR/macos/build-wine.sh" >"$blog" 2>&1
bstatus=$?
if [ $bstatus = 0 ]; then
    pass build "build-wine.sh (PE_MODE=msvc, arm64ec,aarch64,i386, Vulkan) exit 0 in $(( $(date +%s) - start ))s ($blog)"
else
    fail build "build-wine.sh (PE_MODE=msvc, arm64ec,aarch64,i386, Vulkan) exited $bstatus: $(tail -1 "$blog") ($blog)"
fi
# the 32-bit side: i386 PE DLLs, and the ARM64 wow64.dll that runs them
n386=$(find "$BUILD_DIR/dlls" -path '*/i386-windows/*.dll' 2>/dev/null | wc -l | tr -d ' ')
if [ -f "$BUILD_DIR/dlls/ntdll/i386-windows/ntdll.dll" ] && [ -f "$BUILD_DIR/dlls/wow64/aarch64-windows/wow64.dll" ] && [ "$n386" -ge 500 ]; then
    pass build "the 32-bit side built: $n386 i386 DLLs, with ntdll.dll, and wow64.dll for aarch64"
else
    fail build "the 32-bit side did not build: $n386 i386 DLLs under $BUILD_DIR/dlls"
fi
flog=$EVIDENCE_DIR/build-fex.log
FEX_DIST=$FEX_DIST "$PROTON_DIR/macos/build-fex.sh" >"$flog" 2>&1
fstatus=$?
if [ $fstatus = 0 ]; then
    pass build "build-fex.sh exit 0, $(sed -n 's/^:: \(FEX .*\)/\1/p' "$flog" | head -1) ($flog)"
else
    fail build "build-fex.sh exited $fstatus: $(tail -1 "$flog") ($flog)"
fi
if [ "$("$READOBJ" --file-headers "$FEX_DIST/lib/wine/aarch64-windows/libwow64fex.dll" 2>/dev/null | sed -n 's/^Format: //p' | head -1)" = COFF-ARM64 ] &&
   [ "$(lipo -archs "$FEX_DIST/lib/wine/aarch64-unix/libwow64fex.so" 2>/dev/null)" = arm64 ]; then
    pass build "FEX's WoW64 module built: libwow64fex.dll (COFF-ARM64) and libwow64fex.so"
else
    fail build "FEX's WoW64 module is not in $FEX_DIST"
fi
# DXMT links against this Wine build tree, so it comes after it
dlog=$EVIDENCE_DIR/build-dxmt.log
BUILD_DIR=$BUILD_DIR DXMT_DIST=$DXMT_DIST "$PROTON_DIR/macos/build-dxmt.sh" >"$dlog" 2>&1
dstatus=$?
if [ $dstatus = 0 ]; then
    pass build "build-dxmt.sh exit 0, $(sed -n 's/^:: \(DXMT .*\)/\1/p' "$dlog" | head -1) ($dlog)"
else
    fail build "build-dxmt.sh exited $dstatus: $(tail -1 "$dlog") ($dlog)"
fi
# the Vulkan driver, which the bundle installs for the loader (check-wave4.sh uses it)
mlog=$EVIDENCE_DIR/build-mesa.log
MESA_DIST=$MESA_DIST "$PROTON_DIR/macos/build-mesa.sh" >"$mlog" 2>&1
mstatus=$?
if [ $mstatus = 0 ]; then
    pass build "build-mesa.sh exit 0, $(sed -n 's/^:: \(Mesa [0-9][^:]*\).*/\1/p' "$mlog" | head -1) ($mlog)"
else
    fail build "build-mesa.sh exited $mstatus: $(tail -1 "$mlog") ($mlog)"
fi
# Direct3D 12, which the bundle installs in place of Wine's own (check-wave4.sh uses it); the
# Wine build tree's winebuild marks its DLLs
klog=$EVIDENCE_DIR/build-vkd3d-proton.log
BUILD_DIR=$BUILD_DIR VKD3D_DIST=$VKD3D_DIST "$PROTON_DIR/macos/build-vkd3d-proton.sh" >"$klog" 2>&1
kstatus=$?
if [ $kstatus = 0 ]; then
    pass build "build-vkd3d-proton.sh exit 0, $(sed -n 's/^:: \(vkd3d-proton [^:(]*\).*/\1/p' "$klog" | head -1) ($klog)"
else
    fail build "build-vkd3d-proton.sh exited $kstatus: $(tail -1 "$klog") ($klog)"
fi
ulog=$EVIDENCE_DIR/bundle.log
BUILD_DIR=$BUILD_DIR FEX_DIST=$FEX_DIST VULKAN_DIST=$VULKAN_DIST DXMT_DIST=$DXMT_DIST MESA_DIST=$MESA_DIST VKD3D_DIST=$VKD3D_DIST LOADER_PROFILE=$LOADER_PROFILE "$PROTON_DIR/macos/bundle-wine.sh" >"$ulog" 2>&1
ustatus=$?
if [ $ustatus = 0 ]; then
    pass build "bundle-wine.sh exit 0, $([ -n "$LOADER_PROFILE" ] && echo "profile $LOADER_PROFILE" || echo "ad hoc") ($ulog)"
else
    fail build "bundle-wine.sh exited $ustatus: $(tail -1 "$ulog") ($ulog)"
fi
# hello.exe (aarch64) and hello_ec.exe (ARM64EC): hello.c with the build's own winegcc, in the
# build's MSVC mode, against Wine's CRT; the import libraries of a hybrid build are in
# aarch64-windows for both
build_hello() {
    local name=$1 target=$2 format=$3 src=${4:-hello.c} log=$TESTS_OUT/$1.build.log
    rm -f "$TESTS_OUT/$name.exe"
    {
        echo "\$ winegcc -b $target $src (Wine CRT)"
        PATH=$MINGW_BIN:$PATH "$BUILD_DIR/tools/winegcc/winegcc" -v --wine-objdir "$BUILD_DIR" -b "$target" \
            -mconsole -O2 -Wall -D_UCRT -I"$SRC_DIR/include/msvcrt" -I"$SRC_DIR/include" \
            -o "$TESTS_OUT/$name.exe" "$SCRIPT_DIR/$src" \
            "$BUILD_DIR/dlls/winecrt0/aarch64-windows/libwinecrt0.a" "$BUILD_DIR/dlls/ucrtbase/aarch64-windows/libucrtbase.a" \
            "$BUILD_DIR/dlls/kernel32/aarch64-windows/libkernel32.a" "$BUILD_DIR/dlls/ntdll/aarch64-windows/libntdll.a"
        echo "exit=$?"
        "$READOBJ" --file-headers "$TESTS_OUT/$name.exe" | grep -E 'Format|Machine'
    } >"$log" 2>&1
    [ -f "$TESTS_OUT/$name.exe" ] && grep -q "^Format: $format\$" "$log"
}
if build_hello hello aarch64-windows COFF-ARM64; then pass build "hello.exe built, COFF-ARM64 ($TESTS_OUT/hello.build.log)"; else fail build "hello.exe did not build as COFF-ARM64 ($TESTS_OUT/hello.build.log)"; fi
if build_hello hello_ec arm64ec-windows COFF-ARM64EC; then pass build "hello_ec.exe built, COFF-ARM64EC ($TESTS_OUT/hello_ec.build.log)"; else fail build "hello_ec.exe did not build as COFF-ARM64EC ($TESTS_OUT/hello_ec.build.log)"; fi
if build_hello jit_view_test aarch64-windows COFF-ARM64 jit_view_test.c; then pass build "jit_view_test.exe built, COFF-ARM64 ($TESTS_OUT/jit_view_test.build.log)"; else fail build "jit_view_test.exe did not build as COFF-ARM64 ($TESTS_OUT/jit_view_test.build.log)"; fi
# hello_x64.exe: an x86_64 program as one from outside Wine, the mingw compiler and its own CRT
xlog=$TESTS_OUT/hello_x64.build.log
rm -f "$TESTS_OUT/hello_x64.exe"
{
    echo "\$ x86_64-w64-mingw32-clang hello_x64.c"
    "$MINGW_BIN/x86_64-w64-mingw32-clang" -O2 -Wall -o "$TESTS_OUT/hello_x64.exe" "$SCRIPT_DIR/hello_x64.c"
    echo "exit=$?"
    "$READOBJ" --file-headers "$TESTS_OUT/hello_x64.exe" | grep -E 'Format|Machine'
    "$OBJDUMP" -p "$TESTS_OUT/hello_x64.exe" | grep 'DLL Name'
} >"$xlog" 2>&1
if [ -f "$TESTS_OUT/hello_x64.exe" ] && grep -q '^Format: COFF-x86-64$' "$xlog"; then pass build "hello_x64.exe built, COFF-x86-64 ($xlog)"; else fail build "hello_x64.exe did not build as COFF-x86-64 ($xlog)"; fi
clog=$TESTS_OUT/callback_x64.build.log
rm -f "$TESTS_OUT/callback_x64.exe"
{
    echo "\$ x86_64-w64-mingw32-clang callback_x64.c"
    "$MINGW_BIN/x86_64-w64-mingw32-clang" -O2 -Wall -o "$TESTS_OUT/callback_x64.exe" "$SCRIPT_DIR/callback_x64.c"
    echo "exit=$?"
    "$READOBJ" --file-headers "$TESTS_OUT/callback_x64.exe" | grep -E 'Format|Machine'
} >"$clog" 2>&1
if [ -f "$TESTS_OUT/callback_x64.exe" ] && grep -q '^Format: COFF-x86-64$' "$clog"; then pass build "callback_x64.exe built, COFF-x86-64 ($clog)"; else fail build "callback_x64.exe did not build as COFF-x86-64 ($clog)"; fi
hlog=$TESTS_OUT/hello_x86.build.log
rm -f "$TESTS_OUT/hello_x86.exe"
{
    echo "\$ i686-w64-mingw32-clang hello_x86.c"
    "$MINGW_BIN/i686-w64-mingw32-clang" -O2 -Wall -o "$TESTS_OUT/hello_x86.exe" "$SCRIPT_DIR/hello_x86.c"
    echo "exit=$?"
    "$READOBJ" --file-headers "$TESTS_OUT/hello_x86.exe" | grep -E 'Format|Machine'
} >"$hlog" 2>&1
if [ -f "$TESTS_OUT/hello_x86.exe" ] && grep -q '^Format: COFF-i386$' "$hlog"; then pass build "hello_x86.exe built, COFF-i386 ($hlog)"; else fail build "hello_x86.exe did not build as COFF-i386 ($hlog)"; fi
sdlog=$TESTS_OUT/shared_data_test.build.log
rm -f "$TESTS_OUT/shared_data_test_x86.exe" "$TESTS_OUT/shared_data_test_x64.exe"
{
    echo "\$ i686-w64-mingw32-clang and x86_64-w64-mingw32-clang shared_data_test.c"
    "$MINGW_BIN/i686-w64-mingw32-clang" -O2 -Wall -o "$TESTS_OUT/shared_data_test_x86.exe" "$SCRIPT_DIR/shared_data_test.c"
    echo "exit=$?"
    "$MINGW_BIN/x86_64-w64-mingw32-clang" -O2 -Wall -o "$TESTS_OUT/shared_data_test_x64.exe" "$SCRIPT_DIR/shared_data_test.c"
    echo "exit=$?"
    "$READOBJ" --file-headers "$TESTS_OUT/shared_data_test_x86.exe" "$TESTS_OUT/shared_data_test_x64.exe" | grep -E 'Format'
} >"$sdlog" 2>&1
if grep -q '^Format: COFF-i386$' "$sdlog" && grep -q '^Format: COFF-x86-64$' "$sdlog"; then pass build "shared_data_test.exe built, COFF-i386 and COFF-x86-64 ($sdlog)"; else fail build "shared_data_test.exe did not build for both ($sdlog)"; fi
ilog=$TESTS_OUT/cpuid_x64.build.log
rm -f "$TESTS_OUT/cpuid_x64.exe"
{
    echo "\$ x86_64-w64-mingw32-clang cpuid_x64.c"
    "$MINGW_BIN/x86_64-w64-mingw32-clang" -O2 -Wall -o "$TESTS_OUT/cpuid_x64.exe" "$SCRIPT_DIR/cpuid_x64.c"
    echo "exit=$?"
    "$READOBJ" --file-headers "$TESTS_OUT/cpuid_x64.exe" | grep -E 'Format|Machine'
} >"$ilog" 2>&1
if [ -f "$TESTS_OUT/cpuid_x64.exe" ] && grep -q '^Format: COFF-x86-64$' "$ilog"; then pass build "cpuid_x64.exe built, COFF-x86-64 ($ilog)"; else fail build "cpuid_x64.exe did not build as COFF-x86-64 ($ilog)"; fi
# jit_x64.exe, and a native build of the same source for the checksum it has to print
jlog=$TESTS_OUT/jit_x64.build.log
rm -f "$TESTS_OUT/jit_x64.exe" "$TESTS_OUT/jit_native"
{
    echo "\$ x86_64-w64-mingw32-clang -O1 jit_x64.c"
    "$MINGW_BIN/x86_64-w64-mingw32-clang" -O1 -Wall -o "$TESTS_OUT/jit_x64.exe" "$SCRIPT_DIR/jit_x64.c"
    echo "exit=$?"
    "$READOBJ" --file-headers "$TESTS_OUT/jit_x64.exe" | grep -E 'Format|Machine'
    echo "\$ clang -O1 jit_x64.c (native)"
    clang -O1 -Wall -o "$TESTS_OUT/jit_native" "$SCRIPT_DIR/jit_x64.c"
    echo "exit=$?"
} >"$jlog" 2>&1
if [ -f "$TESTS_OUT/jit_x64.exe" ] && [ -x "$TESTS_OUT/jit_native" ] && grep -q '^Format: COFF-x86-64$' "$jlog"; then pass build "jit_x64.exe built, COFF-x86-64, and natively ($jlog)"; else fail build "jit_x64.exe did not build as COFF-x86-64 and natively ($jlog)"; fi
plog=$TESTS_OUT/proc_exec_path.build.log
rm -f "$TESTS_OUT/proc_exec_path"
clang -O1 -Wall -Werror -o "$TESTS_OUT/proc_exec_path" "$SCRIPT_DIR/proc_exec_path.c" >"$plog" 2>&1
if [ -x "$TESTS_OUT/proc_exec_path" ]; then pass build "proc_exec_path built ($plog)"; else fail build "proc_exec_path did not build ($plog)"; fi
fi  # build

########################################################################
# Item 1: the bundle and its signature
########################################################################
if want 1; then
echo "== item 1: the bundle and its signature"
clog=$EVIDENCE_DIR/item1-bundle.log
ok=yes
no() { ok=no; echo "WRONG: $*" >>"$clog"; }
{
    echo "\$ ls -l (bundle, links)"
    ls -l "$APP/Contents" "$APP/Contents/MacOS" "$UNIXLIB/wine" "$WINE" "$UNIXLIB/ntdll.so" 2>&1
    echo "\$ plutil -p $APP/Contents/Info.plist"
    plutil -p "$APP/Contents/Info.plist" 2>&1
    echo "\$ codesign -dvv $APP"
    codesign -dvv "$APP" 2>&1
    echo "\$ codesign -d --entitlements - --xml $APP"
    codesign -d --entitlements - --xml "$APP" 2>&1; echo
    echo "\$ codesign --verify --strict --verbose=2 $APP"
    codesign --verify --strict --verbose=2 "$APP" 2>&1
    echo "verify exit=$?"
} >"$clog"
[ -f "$BUNDLE_LOADER" ] && [ ! -L "$BUNDLE_LOADER" ] || no "no loader file at $BUNDLE_LOADER"
[ -f "$UNIXLIB/ntdll.so" ] || no "no ntdll.so next to wine.app"
[ "$(readlink "$UNIXLIB/wine")" = "wine.app/Contents/MacOS/wine" ] || no "$UNIXLIB/wine is not the link into wine.app"
[ "$(readlink "$WINE")" = "../lib/wine/$UNIX_DIR/wine.app/Contents/MacOS/wine" ] || no "bin/wine is not the link into wine.app"
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Contents/Info.plist" 2>/dev/null)" = wine ] || no "CFBundleExecutable is not wine"
bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist" 2>/dev/null)
[ -n "$bundle_id" ] || no "no CFBundleIdentifier"
codesign --verify --strict "$APP" 2>/dev/null || no "the signature does not verify"
keys=$(entitlement_keys "$APP" | sort | paste -sd, -)
echo "entitlement keys: ${keys:-<none>}" >>"$clog"
if [ -n "$LOADER_PROFILE" ]; then
    kind="profile, $bundle_id"
    for k in "$X18_ENTITLEMENT" "$CROSS_ARCH_ENTITLEMENT"; do
        codesign -d --entitlements - --xml "$APP" 2>/dev/null | grep -q "<key>$k</key><true/>" || no "the signature does not set $k"
    done
    cmp -s "$LOADER_PROFILE" "$APP/Contents/embedded.provisionprofile" || no "embedded.provisionprofile is not $LOADER_PROFILE"
    codesign -dvv "$APP" 2>&1 | grep -q '^TeamIdentifier=not set' && no "signed without a team"
else
    kind="ad hoc, $bundle_id"
    [ "$keys" = "$X18_ENTITLEMENT" ] || no "entitlements are not exactly $X18_ENTITLEMENT"
    codesign -d --entitlements - --xml "$APP" 2>/dev/null | grep -q "<key>$X18_ENTITLEMENT</key><true/>" || no "$X18_ENTITLEMENT is not true"
    [ ! -e "$APP/Contents/embedded.provisionprofile" ] || no "a profile is embedded in an ad-hoc bundle"
fi
skeys=$(entitlement_keys "$SERVER" | paste -sd, -)
{ echo "=== $SERVER (must not carry entitlements)"; codesign -dv "$SERVER" 2>&1; echo "entitlement keys: ${skeys:-<none>}"; } >>"$clog"
[ -z "$skeys" ] || no "wineserver carries entitlements"
{ echo "=== FEX's ARM64EC module"; ls -l "$INSTALL_DIR/lib/wine/aarch64-windows/libarm64ecfex.dll" "$UNIXLIB/libarm64ecfex.so" 2>&1; } >>"$clog"
cmp -s "$FEX_DIST/lib/wine/aarch64-windows/libarm64ecfex.dll" "$INSTALL_DIR/lib/wine/aarch64-windows/libarm64ecfex.dll" || no "libarm64ecfex.dll is not the one of $FEX_DIST"
cmp -s "$FEX_DIST/lib/wine/$UNIX_DIR/libarm64ecfex.so" "$UNIXLIB/libarm64ecfex.so" || no "libarm64ecfex.so is not the one of $FEX_DIST"
if [ $ok = yes ]; then
    pass 1 "wine.app ($kind) next to ntdll.so, both links point into it, signature verifies with ${keys}; wineserver has no entitlements; FEX's module is installed ($clog)"
else
    fail 1 "$(grep -c '^WRONG' "$clog") things wrong with the bundle: $(grep '^WRONG' "$clog" | head -3 | cut -c8-90 | paste -sd';' -) ($clog)"
fi
fi  # item 1

########################################################################
# Item 2: the loader finds ntdll.so from each of its paths
########################################################################
if want 2; then
echo "== item 2: wine --version through each path of the loader"
vlog=$EVIDENCE_DIR/item2-version.log
: >"$vlog"
vpass=0
for w in "$WINE" "$UNIXLIB/wine" "$BUNDLE_LOADER"; do
    out=$(run_timeout 60 "$w" --version 2>&1); rc=$?
    { echo "\$ $w --version"; echo "$out"; echo "exit=$rc"; } >>"$vlog"
    [ "$rc" = 0 ] && [ "$out" = "wine-$VERSION" ] && vpass=$((vpass + 1))
done
if [ "$vpass" = 3 ]; then
    pass 2 "bin/wine, $UNIX_DIR/wine and wine.app/Contents/MacOS/wine all print wine-$VERSION ($vlog)"
else
    fail 2 "wine --version worked through $vpass/3 paths ($vlog)"
fi
fi  # item 2

########################################################################
# Item 3: bin/wine hello.exe, HELLO_RUNS runs
########################################################################
if want 3; then
echo "== item 3: bin/wine hello.exe x $HELLO_RUNS"
hdir=$EVIDENCE_DIR/item3-hello
rm -rf "$hdir"; mkdir -p "$hdir"
PREFIX=$BUILD_ROOT/wave3b-prefix-hello
rm -rf "$PREFIX"; mkdir -p "$PREFIX"
hold_server "$PREFIX"
hpass=0
for i in $(seq 1 "$HELLO_RUNS"); do
    t=$RUN_TIMEOUT; [ $i = 1 ] && t=$WINEBOOT_TIMEOUT   # the first run sets the prefix up
    echo "\$ WINEPREFIX=$PREFIX WINEDLLOVERRIDES=$WINEDLLOVERRIDES $WINE $TESTS_OUT/hello.exe" >"$hdir/run$i.log"
    WINEPREFIX=$PREFIX run_timeout "$t" "$WINE" "$TESTS_OUT/hello.exe" >"$hdir/run$i.stdout" 2>"$hdir/run$i.stderr"
    rc=$?
    { echo "--- stdout"; cat "$hdir/run$i.stdout"; echo "--- stderr"; cat "$hdir/run$i.stderr"; echo "exit=$rc"; } >>"$hdir/run$i.log"
    line=no; tr -d '\r' <"$hdir/run$i.stdout" | grep -qx 'hello from Windows ARM64 code on macOS' && line=yes
    [ "$rc" = 0 ] && [ $line = yes ] && hpass=$((hpass + 1))
    echo "run $i: exit=$rc line=$line" >>"$hdir/summary.txt"
done
cleanup_prefix "$PREFIX"
# an allocation past the end of the host address space fails with this message
nmap=$(cat "$hdir"/run*.stderr | grep -c 'try_map_free_area mmap() error')
echo "try_map_free_area mmap() errors in all runs: $nmap" >>"$hdir/summary.txt"
if [ "$hpass" = "$HELLO_RUNS" ] && [ "$nmap" = 0 ]; then
    pass 3 "hello.exe printed its line and exited 0 in $hpass/$HELLO_RUNS runs through bin/wine, the first in a fresh prefix; no failed mapping ($hdir/summary.txt)"
else
    fail 3 "hello.exe passed $hpass/$HELLO_RUNS runs through bin/wine, failed mappings: $nmap ($hdir/summary.txt)"
fi
fi  # item 3

########################################################################
# Item 4: wineboot -u, and how the processes are started
########################################################################
if want 4; then
echo "== item 4: bin/wine wineboot -u x $WINEBOOT_RUNS, paths the processes are started with"
bdir=$EVIDENCE_DIR/item4-wineboot
rm -rf "$bdir"; mkdir -p "$bdir"
PREFIX=$BUILD_ROOT/wave3b-prefix-boot
bpass=0
for i in $(seq 1 "$WINEBOOT_RUNS"); do
    rm -rf "$PREFIX"; mkdir -p "$PREFIX"
    blog=$bdir/run$i.log
    # PID, path of the exec and file of every process of the install tree, sampled during the run
    rm -f "$bdir/stop"
    ( while [ ! -f "$bdir/stop" ]; do "$TESTS_OUT/proc_exec_path" "$INSTALL_DIR"; perl -e 'select(undef, undef, undef, 0.05)'; done \
          | sort -u >"$bdir/run$i.processes.tsv" ) &
    sampler=$!
    echo "\$ WINEPREFIX=$PREFIX WINEDLLOVERRIDES=$WINEDLLOVERRIDES $WINE wineboot -u" >"$blog"
    start=$(date +%s)
    WINEPREFIX=$PREFIX run_timeout "$WINEBOOT_TIMEOUT" "$WINE" wineboot -u >>"$blog" 2>&1
    rc=$?
    WINEPREFIX=$PREFIX run_timeout 120 "$SERVER" -w >>"$blog" 2>&1
    wrc=$?
    end=$(date +%s)
    touch "$bdir/stop"; wait $sampler
    echo "exit=$rc wineserver_wait=$wrc seconds=$((end - start))" >>"$blog"
    cleanup_prefix "$PREFIX"
    nfault=$(grep -c -E 'page fault|Unhandled exception|c0000005' "$blog")
    # by path inside the bundle; through a name in bin (what the user starts); anything else is a link
    nbundle=$(awk -F'\t' -v l="$BUNDLE_LOADER" '$3 == l && $2 == l' "$bdir/run$i.processes.tsv" | wc -l | tr -d ' ')
    nbin=$(awk -F'\t' -v l="$BUNDLE_LOADER" -v b="$INSTALL_DIR/bin/" '$3 == l && index($2, b) == 1' "$bdir/run$i.processes.tsv" | wc -l | tr -d ' ')
    nlink=$(awk -F'\t' -v l="$BUNDLE_LOADER" -v b="$INSTALL_DIR/bin/" '$3 == l && $2 != l && index($2, b) != 1' "$bdir/run$i.processes.tsv" | wc -l | tr -d ' ')
    status=FAIL
    [ "$rc" = 0 ] && [ "$wrc" = 0 ] && [ "$nfault" = 0 ] && [ "$nbundle" -ge 3 ] && [ "$nlink" = 0 ] && { status=PASS; bpass=$((bpass + 1)); }
    echo "run $i: $status wineboot exit=$rc, faults: $nfault, loader processes started by the path in wine.app: $nbundle, through bin/: $nbin, through another link: $nlink, $((end - start))s" \
        | tee -a "$bdir/summary.txt"
done
rm -f "$bdir/stop"
if [ "$bpass" = "$WINEBOOT_RUNS" ]; then
    pass 4 "wineboot -u clean in $bpass/$WINEBOOT_RUNS fresh prefixes: exit 0, no fault, every process Wine started runs by the loader's path in wine.app ($bdir/summary.txt)"
else
    fail 4 "wineboot -u clean in $bpass/$WINEBOOT_RUNS runs ($bdir/summary.txt)"
fi
fi  # item 4

########################################################################
# Item 5: regression of Wave 3a (and through it Waves 1, 2a and 2b)
########################################################################
if want 5; then
echo "== item 5: Wave 3a regression"
R=$EVIDENCE_DIR/regression-wave3a
R2=$EVIDENCE_DIR/regression-wave3a-this-build
rm -rf "$R" "$R2"; mkdir -p "$R" "$R2/programs"
# all of it on the build it was written for
BUILD_DIR=$MINGW_BUILD_DIR EVIDENCE_DIR=$R "$PROTON_DIR/macos/tests/check-wave3a.sh" >"$R/check-wave3a.out" 2>&1
rrc=$?
# its runtime items on this wave's build, with the test programs the run above built: hello.exe,
# teb_test.exe, wx_test.exe and wineboot (its build item would rebuild in mingw mode, and its
# items 1, 2, 5, 8 and 9 are about that build's files and sources)
cp "$R"/programs/*.exe "$R2/programs/" 2>/dev/null
BUILD_DIR=$BUILD_DIR EVIDENCE_DIR=$R2 CHECK_ITEMS="3 4 6 7" "$PROTON_DIR/macos/tests/check-wave3a.sh" >"$R2/check-wave3a.out" 2>&1
r2ok=yes
for i in 3 4 6 7; do grep -q "^PASS  item $i:" "$R2/check-summary.txt" 2>/dev/null || r2ok=no; done
if [ $rrc = 0 ] && [ -s "$R/check-summary.txt" ] && ! grep -q '^FAIL' "$R/check-summary.txt" && [ $r2ok = yes ]; then
    pass 5 "check-wave3a.sh: exit 0, no FAIL on the aarch64 mingw build; items 3 4 6 7 pass on this build ($R/check-summary.txt, $R2/check-summary.txt)"
else
    fail 5 "check-wave3a.sh exit $rrc on the mingw build, runtime items on this build ok=$r2ok: $(cat "$R/check-summary.txt" "$R2/check-summary.txt" 2>/dev/null | grep '^FAIL' | cut -c1-70 | paste -sd';' -) ($R, $R2)"
fi
fi  # item 5

########################################################################
# Item 6: other targets unchanged
########################################################################
if want 6; then
echo "== item 6: other targets unchanged"
glog=$EVIDENCE_DIR/item6-guards.log
ulog=$EVIDENCE_DIR/item6-unifdef.log
dlog=$EVIDENCE_DIR/item6-diff.log
: >"$ulog"
ok=yes
# every line added since the wave base, with the stack of #if conditions it is in
{
    echo "\$ git -C wine diff $WINE_WAVE_BASE HEAD -- $WAVE_FILES: every added line with its enclosing #if stack"
    for f in $WAVE_FILES; do
        git -C "$WINE_DIR" show "HEAD:$f" >"$WORK/guard.c"
        git -C "$WINE_DIR" diff -U0 "$WINE_WAVE_BASE" HEAD -- "$f" | sed -n 's/^@@ -[0-9,]* +\([0-9]*\),\{0,1\}\([0-9]*\) @@.*/\1 \2/p' >"$WORK/hunks"
        perl -e '
            my ($file, $hunks) = @ARGV; open my $fh, "<", $file or die; my @lines = <$fh>;
            open my $hh, "<", $hunks or die; my %added;
            while (<$hh>) { my ($s, $n) = split; $n = 1 if $n eq ""; $added{$_} = 1 for $s .. $s + $n - 1; }
            my @stack; my $i = 0;
            for my $l (@lines) {
                $i++;
                # The conditions the line is in. The #if, #else and #endif lines themselves and empty
                # lines are not judged here: diff pairs a new #endif or an empty line with an old one
                # as it likes, and the unifdef comparison below is what shows that the conditionals
                # leave the other targets their old text.
                my $directive = 0;
                if ($l =~ /^\s*#\s*(if|ifdef|ifndef)\b(.*)/) { push @stack, "$1$2"; $directive = 1; }
                elsif ($l =~ /^\s*#\s*(elif)\b(.*)/) { $stack[-1] = "$1$2 (after $stack[-1])"; $directive = 1; }
                elsif ($l =~ /^\s*#\s*else\b/) { $stack[-1] = "else of $stack[-1]"; $directive = 1; }
                elsif ($l =~ /^\s*#\s*endif\b/) { pop @stack; $directive = 1; }
                next unless $added{$i};
                next if $directive || $l =~ /^\s*$/;
                my @in = @stack;
                my @g = grep { /^if defined\(__APPLE__\) && defined\(__aarch64__\)\s*$|^ifdef WX_EXCLUSIVE_HOST\s*$/ } @in;
                printf "%s %s:%d [%s] %s", (@g ? "guarded" : "UNGUARDED"), $ARGV[2], $i, join(" > ", map { s/\s+/ /gr } @in), $l;
            }' "$WORK/guard.c" "$WORK/hunks" "$f"
    done
} >"$glog" 2>&1
nadd=$(grep -c -E '^(guarded|UNGUARDED) ' "$glog")
nung=$(grep -c '^UNGUARDED ' "$glog")
[ "$nung" = 0 ] && [ "$nadd" -gt 0 ] || ok=no
echo "--- added lines other than conditionals and empty lines: $nadd, outside a defined(__APPLE__) && defined(__aarch64__) or WX_EXCLUSIVE_HOST guard: $nung" >>"$glog"
# WX_EXCLUSIVE_HOST counts as that guard because it is only ever defined inside it
nwxbad=0
for f in $WAVE_FILES; do
    bad=$(git -C "$WINE_DIR" show "HEAD:$f" | perl -ne '
        if (/^\s*#\s*(if|ifdef|ifndef)\b(.*)/) { push @stack, "$1$2"; }
        elsif (/^\s*#\s*(elif|else)\b/) { $stack[-1] = "other branch of $stack[-1]"; }
        elsif (/^\s*#\s*endif\b/) { pop @stack; }
        elsif (/^\s*#\s*(define|undef)\s+WX_EXCLUSIVE_HOST\b/) {
            $n++ unless grep { /^if defined\(__APPLE__\) && defined\(__aarch64__\)\s*$/ } @stack;
        }
        END { print $n + 0 }')
    [ "$bad" = 0 ] || { nwxbad=$((nwxbad + bad)); echo "$f: WX_EXCLUSIVE_HOST defined or undefined outside the guard, $bad times" >>"$glog"; }
done
[ "$nwxbad" = 0 ] || ok=no
# Source level: for every other system (__APPLE__ undefined) and for x86_64 macOS (__aarch64__
# undefined) each file is the wave base text.
for f in $WAVE_FILES; do
    for flags in "-U__APPLE__ -UWX_EXCLUSIVE_HOST" "-D__APPLE__ -U__aarch64__ -UWX_EXCLUSIVE_HOST"; do
        git -C "$WINE_DIR" show "$WINE_WAVE_BASE:$f" | unifdef $flags | cat -s >"$WORK/unifdef.base" 2>/dev/null
        git -C "$WINE_DIR" show "HEAD:$f" | unifdef $flags | cat -s >"$WORK/unifdef.new" 2>/dev/null
        if [ -s "$WORK/unifdef.new" ] && cmp -s "$WORK/unifdef.base" "$WORK/unifdef.new"; then
            echo "unifdef $flags $f: identical to $WINE_WAVE_BASE" >>"$ulog"
        else
            ok=no; echo "unifdef $flags $f: DIFFERS from $WINE_WAVE_BASE" >>"$ulog"
            diff "$WORK/unifdef.base" "$WORK/unifdef.new" | head -20 >>"$ulog"
        fi
    done
done
{
    echo "\$ git -C wine diff --stat $WINE_WAVE_BASE HEAD"
    git -C "$WINE_DIR" diff --stat "$WINE_WAVE_BASE" HEAD
    echo "\$ git -C wine log --format='%h %s' $WINE_WAVE_BASE..HEAD"
    git -C "$WINE_DIR" log --format='%h %s' "$WINE_WAVE_BASE..HEAD"
    echo "\$ git -C wine status --porcelain"
    git -C "$WINE_DIR" status --porcelain
    echo "\$ git diff --stat $SUPER_WAVE_BASE HEAD   (superproject)"
    git -C "$PROTON_DIR" diff --stat "$SUPER_WAVE_BASE" HEAD
    echo "\$ git diff --raw $SUPER_WAVE_BASE HEAD -- wine   (submodule pointer must be unchanged)"
    git -C "$PROTON_DIR" diff --raw "$SUPER_WAVE_BASE" HEAD -- wine
} >"$dlog" 2>&1
wbad=""
for f in $(git -C "$WINE_DIR" diff --name-only "$WINE_WAVE_BASE" HEAD); do
    case " $WAVE_FILES " in *" $f "*) ;; *) wbad="$wbad $f" ;; esac
done
wdirty=$(git -C "$WINE_DIR" status --porcelain --untracked-files=all | head -5)
sbad=$(git -C "$PROTON_DIR" diff --name-only "$SUPER_WAVE_BASE" HEAD | grep -v '^macos/')
[ -n "$(git -C "$PROTON_DIR" diff --raw "$SUPER_WAVE_BASE" HEAD -- wine)" ] && sbad="$sbad wine(pointer)"
[ -z "$wbad" ] && [ -z "$wdirty" ] && [ -z "$sbad" ] || ok=no
if [ $ok = yes ]; then
    pass 6 "$nadd lines added since $WINE_WAVE_BASE in $(echo $WAVE_FILES), all under defined(__APPLE__) && defined(__aarch64__) or WX_EXCLUSIVE_HOST, which is only defined under it; the files are the wave base text with __APPLE__ or __aarch64__ undefined; superproject changes only in macos/ ($glog, $ulog, $dlog)"
else
    fail 6 "unguarded lines: $nung of $nadd; WX_EXCLUSIVE_HOST defined outside the guard: $nwxbad; wine unexpected:${wbad:- none}; wine uncommitted: '$wdirty'; superproject: '$(echo $sbad)' ($glog, $ulog, $dlog)"
fi
fi  # item 6

########################################################################
# Item 7: ARM64EC and x86_64 programs through FEX
########################################################################
if want 7; then
echo "== item 7: hello_ec.exe (ARM64EC) and hello_x64.exe (x86_64) through FEX x $FEX_RUNS"
fdir=$EVIDENCE_DIR/item7-fex
rm -rf "$fdir"; mkdir -p "$fdir"
PREFIX=$BUILD_ROOT/wave3b-prefix-fex
rm -rf "$PREFIX"; mkdir -p "$PREFIX"
hold_server "$PREFIX"
X64_LINE='hello from x86_64 code on macOS: 6*7=42, processor architecture 9, native 12, page size 4096'
EC_LINE='hello from Windows ARM64 code on macOS'
ecpass=0; xpass=0
for i in $(seq 1 "$FEX_RUNS"); do
    t=$RUN_TIMEOUT; [ $i = 1 ] && t=$WINEBOOT_TIMEOUT   # the first run sets the prefix up
    for p in hello_ec hello_x64; do
        # the first run of each also records which modules are loaded
        dbg=; [ $i = 1 ] && dbg=+loaddll
        echo "\$ WINEPREFIX=$PREFIX WINEDEBUG=$dbg WINEDLLOVERRIDES=$WINEDLLOVERRIDES $WINE $TESTS_OUT/$p.exe" >"$fdir/$p.run$i.log"
        WINEPREFIX=$PREFIX WINEDEBUG=$dbg run_timeout "$t" "$WINE" "$TESTS_OUT/$p.exe" >"$fdir/$p.run$i.stdout" 2>"$fdir/$p.run$i.stderr"
        rc=$?
        t=$RUN_TIMEOUT
        { echo "--- stdout"; cat "$fdir/$p.run$i.stdout"; echo "--- stderr"; cat "$fdir/$p.run$i.stderr"; echo "exit=$rc"; } >>"$fdir/$p.run$i.log"
        want_line=$EC_LINE; [ $p = hello_x64 ] && want_line=$X64_LINE
        line=no; tr -d '\r' <"$fdir/$p.run$i.stdout" | grep -qxF "$want_line" && line=yes
        if [ "$rc" = 0 ] && [ $line = yes ]; then
            if [ $p = hello_ec ]; then ecpass=$((ecpass + 1)); else xpass=$((xpass + 1)); fi
        fi
        echo "run $i $p.exe: exit=$rc line=$line" >>"$fdir/summary.txt"
    done
done
# the CPU features x86 code is told, which FEX derives from the ARM64 ID registers Wine reports
WINEPREFIX=$PREFIX run_timeout "$RUN_TIMEOUT" "$WINE" "$TESTS_OUT/cpuid_x64.exe" >"$fdir/cpuid_x64.stdout" 2>"$fdir/cpuid_x64.stderr"
crc=$?
cpuid=$(tr -d '\r' <"$fdir/cpuid_x64.stdout" | grep '^cpuid: ' | head -1)
nstub=$(grep -c 'get_core_id_regs_arm64 stub' "$fdir/cpuid_x64.stderr")
cpuok=yes
[ "$crc" = 0 ] && [ "$nstub" = 0 ] || cpuok=no
for f in sse4.2 pclmulqdq aes sha; do
    case " $cpuid " in *" $f=1 "*) ;; *) cpuok=no ;; esac
done
echo "cpuid_x64.exe: exit=$crc, ID register stub messages: $nstub, ${cpuid:-no cpuid line}" >>"$fdir/summary.txt"
cleanup_prefix "$PREFIX"
# FEX's module is the builtin from the install tree, in both kinds of process
fexload=0
for p in hello_ec hello_x64; do
    grep -q -E 'Loaded L"C:\\\\windows\\\\system32\\\\libarm64ecfex\.dll" at [0-9A-F]+: builtin' "$fdir/$p.run1.stderr" && fexload=$((fexload + 1))
done
echo "libarm64ecfex.dll loaded as a builtin in the first run of: $fexload/2 programs" >>"$fdir/summary.txt"
if [ "$ecpass" = "$FEX_RUNS" ] && [ "$xpass" = "$FEX_RUNS" ] && [ "$fexload" = 2 ] && [ $cpuok = yes ]; then
    pass 7 "hello_ec.exe (ARM64EC) $ecpass/$FEX_RUNS and hello_x64.exe (x86_64) $xpass/$FEX_RUNS printed their line and exited 0 through bin/wine; libarm64ecfex.dll loaded as a builtin in both; x86 code is told '$cpuid' ($fdir/summary.txt)"
else
    fail 7 "hello_ec.exe passed $ecpass/$FEX_RUNS, hello_x64.exe $xpass/$FEX_RUNS, libarm64ecfex.dll builtin in $fexload/2, cpuid ok=$cpuok: '${cpuid:-no cpuid line}', stub messages $nstub ($fdir/summary.txt)"
fi
fi  # item 7

########################################################################
# Item 8: MAP_JIT memory for an emulator's code
########################################################################
if want 8; then
echo "== item 8: MAP_JIT memory for an emulator's code"
jdir=$EVIDENCE_DIR/item8-jit
rm -rf "$jdir"; mkdir -p "$jdir"
PREFIX=$BUILD_ROOT/wave3b-prefix-jit
rm -rf "$PREFIX"; mkdir -p "$PREFIX"
hold_server "$PREFIX"
# a view with the attribute, from Windows code (the first run sets the prefix up)
WINEPREFIX=$PREFIX run_timeout "$WINEBOOT_TIMEOUT" "$WINE" "$TESTS_OUT/jit_view_test.exe" >"$jdir/jit_view_test.stdout" 2>"$jdir/jit_view_test.stderr"
vrc=$?
navs=$(tr -d '\r' <"$jdir/jit_view_test.stdout" | sed -n 's/^jit_view_test: PASS (\([0-9]*\) expected access violations)$/\1/p')
nmsg=$(grep -c 'in MAP_JIT memory, written outside a JIT write window' "$jdir/jit_view_test.stderr")
nlost=$(grep -c -E 'lost its MAP_JIT backing|failed to replace the MAP_JIT memory|was taken by another mapping' "$jdir/jit_view_test.stderr")
viewok=no
[ "$vrc" = 0 ] && [ -n "$navs" ] && [ "$navs" -gt 0 ] && [ "$navs" = "$nmsg" ] && [ "$nlost" = 0 ] && viewok=yes
{
    echo "jit_view_test.exe: exit=$vrc, $(tr -d '\r' <"$jdir/jit_view_test.stdout" | tail -1)"
    tr -d '\r' <"$jdir/jit_view_test.stdout" | grep '^FAIL'
    echo "Wine reported $nmsg writes outside a JIT write window, $nlost lost or stuck MAP_JIT ranges"
} >>"$jdir/summary.txt"
# FEX compiling 4000 functions: the result, and what FEX says about its code memory
expected=$("$TESTS_OUT/jit_native" 2>/dev/null | sed -n 's/^jit: .*checksum \([0-9a-f]*\),.*/\1/p')
WINEPREFIX=$PREFIX FEX_SILENTLOG=0 run_timeout "$RUN_TIMEOUT" "$WINE" "$TESTS_OUT/jit_x64.exe" >"$jdir/jit_x64.stdout" 2>"$jdir/jit_x64.stderr"
jrc=$?
jline=$(tr -d '\r' <"$jdir/jit_x64.stdout" | grep '^jit: ' | head -1)
got=$(echo "$jline" | sed -n 's/^jit: .*checksum \([0-9a-f]*\),.*/\1/p')
fexjit=$(grep -a -c 'FEX: Using per-thread W^X JIT code memory' "$jdir/jit_x64.stderr")
jfault=$(grep -a -c -E 'in MAP_JIT memory|lost its MAP_JIT backing' "$jdir/jit_x64.stderr")
# the page flips of such a run, from the trace of the flip itself (one round is enough)
WINEPREFIX=$PREFIX WINEDEBUG=+virtual run_timeout "$RUN_TIMEOUT" "$WINE" "$TESTS_OUT/jit_x64.exe" 2 >/dev/null 2>"$jdir/jit_x64.trace"
nflip=$(grep -a -c 'flipping .* to ' "$jdir/jit_x64.trace")
ntrace=$(wc -l <"$jdir/jit_x64.trace" | tr -d ' ')
rm -f "$jdir/jit_x64.trace"
cleanup_prefix "$PREFIX"
{
    echo "jit_x64.exe: exit=$jrc, $jline"
    echo "native build of the same source: checksum ${expected:-none}"
    echo "FEX said 'Using per-thread W^X JIT code memory' $fexjit times; faults in JIT memory: $jfault"
    echo "page flips in a run of 2 rounds: $nflip (limit $JIT_MAX_FLIPS; trace of $ntrace lines)"
} >>"$jdir/summary.txt"
if [ $viewok = yes ] && [ "$jrc" = 0 ] && [ -n "$expected" ] && [ "$got" = "$expected" ] && [ "$fexjit" -ge 1 ] && [ "$jfault" = 0 ] &&
   [ "$ntrace" -gt 0 ] && [ "$nflip" -le "$JIT_MAX_FLIPS" ]; then
    pass 8 "jit_view_test.exe passed with $navs expected access violations; jit_x64.exe printed checksum $got as the native build does, with $nflip page flips; '$jline' ($jdir/summary.txt)"
else
    fail 8 "jit_view_test ok=$viewok (exit $vrc, $navs faults, $nmsg messages, $nlost lost); jit_x64.exe exit $jrc, checksum '${got}' expected '${expected}', FEX JIT memory lines $fexjit, JIT faults $jfault, page flips $nflip of at most $JIT_MAX_FLIPS ($jdir/summary.txt)"
fi
fi  # item 8

########################################################################
# Item 9: callbacks from native code into x86 code
########################################################################
if want 9; then
echo "== item 9: callbacks from native code into x86 code, 1000 and $CALLBACK_ELEMENTS elements"
cdir=$EVIDENCE_DIR/item9-callback
rm -rf "$cdir"; mkdir -p "$cdir"
PREFIX=$BUILD_ROOT/wave3b-prefix-callback
rm -rf "$PREFIX"; mkdir -p "$PREFIX"
hold_server "$PREFIX"
# callback_run NAME ELEMENTS TIMEOUT: sets crc and cline
callback_run() {
    WINEPREFIX=$PREFIX run_timeout "$3" "$WINE" "$TESTS_OUT/callback_x64.exe" "$2" >"$cdir/$1.stdout" 2>"$cdir/$1.stderr"
    crc=$?
    cline=$(tr -d '\r' <"$cdir/$1.stdout" | head -1)
    echo "$1: callback_x64.exe $2: exit=$crc (142 = stopped after $3 s) '$cline'" >>"$cdir/summary.txt"
}
callback_run small 1000 "$WINEBOOT_TIMEOUT"   # the first run sets the prefix up
src=$crc; sline=$cline
callback_run large "$CALLBACK_ELEMENTS" "$CALLBACK_TIMEOUT"
cleanup_prefix "$PREFIX"
smallok=no; [ "$src" = 0 ] && echo "$sline" | grep -Eqx 'callback: 1000 elements, [0-9]+ callbacks, sorted 1' && smallok=yes
largeok=no; [ "$crc" = 0 ] && echo "$cline" | grep -Eqx "callback: $CALLBACK_ELEMENTS elements, [0-9]+ callbacks, sorted 1" && largeok=yes
if [ $smallok = yes ] && [ $largeok = yes ]; then
    pass 9 "callback_x64.exe sorted 1000 and $CALLBACK_ELEMENTS elements through callbacks from native code: '$cline' ($cdir/summary.txt)"
elif [ $smallok = yes ] && [ -z "$LOADER_PROFILE" ]; then
    todo "item 9: callback_x64.exe sorts 1000 elements ('$sline') but does not finish $CALLBACK_ELEMENTS (exit $crc, 142 = stopped after $CALLBACK_TIMEOUT s): FEX's guard pages need 4K pages, which need LOADER_PROFILE ($cdir/summary.txt)"
else
    fail 9 "callback_x64.exe: 1000 elements ok=$smallok (exit $src, '$sline'); $CALLBACK_ELEMENTS elements ok=$largeok (exit $crc, '$cline') ($cdir/summary.txt)"
fi
fi  # item 9

########################################################################
# Item 10: a 32-bit program
########################################################################
if want 10; then
echo "== item 10: a 32-bit program through WoW64 and FEX"
xdir=$EVIDENCE_DIR/item10-x86
rm -rf "$xdir"; mkdir -p "$xdir"
I386_DIR=$INSTALL_DIR/lib/wine/i386-windows
if [ -z "$LOADER_PROFILE" ]; then
    # from the build tree, where the 32-bit side is whether or not the install has it
    PREFIX=$BUILD_ROOT/wave3b-prefix-x86
    rm -rf "$PREFIX"; mkdir -p "$PREFIX"
    WINEPREFIX=$PREFIX run_timeout 30 "$BUILD_DIR/server/wineserver" -p10 >/dev/null 2>&1
    WINEPREFIX=$PREFIX run_timeout "$WINEBOOT_TIMEOUT" "$BUILD_DIR/wine" "$TESTS_OUT/hello_x86.exe" >"$xdir/refused.stdout" 2>"$xdir/refused.stderr"
    rc=$?
    WINEPREFIX=$PREFIX run_timeout 60 "$BUILD_DIR/server/wineserver" -k >/dev/null 2>&1
    WINEPREFIX=$PREFIX run_timeout 60 "$BUILD_DIR/server/wineserver" -w >/dev/null 2>&1
    rm -rf "$PREFIX"
    nrefused=$(grep -a -c 'wine: a 32-bit program needs memory below 4GB' "$xdir/refused.stderr")
    nassert=$(grep -a -c 'Assertion failed' "$xdir/refused.stderr")
    echo "without a profile, from the build tree: exit=$rc, refused with the reason $nrefused times, assertions $nassert" >>"$xdir/summary.txt"
    if [ "$rc" != 0 ] && [ "$nrefused" -ge 1 ] && [ "$nassert" = 0 ]; then
        todo "item 10: hello_x86.exe cannot run: a 32-bit process lives below 4 GB, which needs LOADER_PROFILE. Its side is built, and ntdll refuses the program by saying so ($nrefused times, no assertion) ($xdir/summary.txt)"
    else
        fail 10 "without a profile hello_x86.exe should be refused with the reason: exit $rc, refused $nrefused times, assertions $nassert ($xdir/summary.txt)"
    fi
else
    PREFIX=$BUILD_ROOT/wave3b-prefix-x86
    rm -rf "$PREFIX"; mkdir -p "$PREFIX"
    hold_server "$PREFIX"
    # "native 9": Wine tells 32-bit code that the machine underneath is x86-64
    X86_LINE='hello from 32-bit x86 code on macOS: 6*7=42, pointer size 4, processor architecture 0, native 9, wow64 1'
    x86pass=0; t=$WINEBOOT_TIMEOUT   # the first run sets the prefix up
    for i in $(seq 1 "$FEX_RUNS"); do
        dbg=; [ $i = 1 ] && dbg=+loaddll
        WINEPREFIX=$PREFIX WINEDEBUG=$dbg run_timeout "$t" "$WINE" "$TESTS_OUT/hello_x86.exe" >"$xdir/run$i.stdout" 2>"$xdir/run$i.stderr"
        rc=$?
        t=$RUN_TIMEOUT
        out=$(tr -d '\r' <"$xdir/run$i.stdout" | head -1)
        line=no; [ "$out" = "$X86_LINE" ] && line=yes
        [ "$rc" = 0 ] && [ $line = yes ] && x86pass=$((x86pass + 1))
        echo "run $i: exit=$rc line=$line ($out)" >>"$xdir/summary.txt"
    done
    nwow=$(grep -a -c -i 'libwow64fex.dll.*builtin' "$xdir/run1.stderr")
    echo "libwow64fex.dll loaded as a builtin: $nwow lines" >>"$xdir/summary.txt"
    cleanup_prefix "$PREFIX"
    if [ "$x86pass" = "$FEX_RUNS" ] && [ "$nwow" -ge 1 ]; then
        pass 10 "hello_x86.exe printed its line and exited 0 in $x86pass/$FEX_RUNS runs, with libwow64fex.dll loaded as a builtin: '$out' ($xdir/summary.txt)"
    else
        fail 10 "hello_x86.exe passed $x86pass/$FEX_RUNS runs, libwow64fex.dll builtin lines $nwow: '$out' ($xdir/summary.txt)"
    fi
fi
fi  # item 10

########################################################################
# Item 11: memory below 4 GB
########################################################################
if want 11; then
echo "== item 11: KUSER_SHARED_DATA at its Windows address, 32-bit and x86_64"
mdir=$EVIDENCE_DIR/item11-shared-data
rm -rf "$mdir"; mkdir -p "$mdir"
if [ -z "$LOADER_PROFILE" ]; then
    todo "item 11: shared_data_test.exe was not run: nothing can be mapped at 0x7ffe0000 without LOADER_PROFILE"
else
    PREFIX=$BUILD_ROOT/wave3b-prefix-shared-data
    rm -rf "$PREFIX"; mkdir -p "$PREFIX"
    hold_server "$PREFIX"
    SD_LINE='shared data: base 7ffe0000, allocation base 7ffe0000, size 1000, protect 2, tick [1-9][0-9]*'
    sdpass=0; t=$WINEBOOT_TIMEOUT   # the first run sets the prefix up
    for p in shared_data_test_x86 shared_data_test_x64; do
        WINEPREFIX=$PREFIX run_timeout "$t" "$WINE" "$TESTS_OUT/$p.exe" >"$mdir/$p.stdout" 2>"$mdir/$p.stderr"
        rc=$?
        t=$RUN_TIMEOUT
        out=$(tr -d '\r' <"$mdir/$p.stdout" | head -1)
        line=no; echo "$out" | grep -Eqx "$SD_LINE" && line=yes
        [ "$rc" = 0 ] && [ $line = yes ] && sdpass=$((sdpass + 1))
        echo "$p.exe: exit=$rc line=$line ($out)" >>"$mdir/summary.txt"
    done
    cleanup_prefix "$PREFIX"
    if [ "$sdpass" = 2 ]; then
        pass 11 "a 32-bit and an x86_64 program find KUSER_SHARED_DATA at 0x7ffe0000, read-only, with a tick count: '$out' ($mdir/summary.txt)"
    else
        fail 11 "$sdpass of 2 programs found the page as it should be ($mdir/summary.txt)"
    fi
fi
fi  # item 11

todo "hardware TSO has no item yet; Wave 3b is not done"

echo
echo "== summary"
printf '%s\n' "${RESULTS[@]}" | tee "$EVIDENCE_DIR/check-summary.txt"
[ $FAILED = 0 ] || exit 1
[ $TODO = 0 ] || exit 3
exit 0
