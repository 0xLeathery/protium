#!/bin/bash
#
# Wave 1 acceptance check for the native arm64 macOS Wine build.
#
#   macos/tests/check-wave1.sh                # incremental: re-run build-wine.sh, then check items 1-6
#   macos/tests/check-wave1.sh --clean-build  # wipe build dir + source mirror, record a clean build (item 2)
#
# Items 1-4 and 6 are pass/fail. Item 5 (wineboot -u) is run and logged; it is expected to fail
# until Wave 2 (x18/TEB), so it only fails the check if it could not be run at all.
# Logs go to $EVIDENCE_DIR.

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
PROTON_DIR=$(cd "$SCRIPT_DIR/../.." && pwd)
BUILD_ROOT=${BUILD_ROOT:-/Users/annon/projects/proton-macos-build}
BUILD_DIR=${BUILD_DIR:-$BUILD_ROOT/wine-aarch64}
TOOLCHAIN_DIR=${TOOLCHAIN_DIR:-/Users/annon/projects/proton-macos-toolchain/llvm-mingw-20261020-ucrt-macos-universal}
EVIDENCE_DIR=${EVIDENCE_DIR:-$BUILD_ROOT/evidence/wave1}
BASE_BRANCH=${BASE_BRANCH:-proton_11.0}
# Superproject commit whose committed changes item 6 judges (uncommitted state is ignored).
SUPER_HEAD=${SUPER_HEAD:-HEAD}
WINE_BASE=${WINE_BASE:-e60892cc2398b0a83c332a2078c7b85e47bdb42b}
WINEBOOT_TIMEOUT=${WINEBOOT_TIMEOUT:-180}
# Wine files this wave is allowed to change (each change must be Darwin/aarch64-Darwin scoped),
# plus those of later waves (Wave 2a: shared user data above 4 GB, see check-wave2a.sh item 6;
# Wave 2b: TEB in a TSD slot instead of x18, see check-wave2b.sh item 7; Wave 3a: x18 opt-in and W^X
# page flipping, see check-wave3a.sh item 9; Wave 3b: the loader in an app bundle, see
# check-wave3b.sh item 6; Wave 4: winemac.drv's table for DXMT, see check-wave4.sh item 7).
WINE_ALLOWED_FILES=${WINE_ALLOWED_FILES:-"configure.ac dlls/ntdll/unix/fsync.c dlls/ntdll/unix/loader.c dlls/ntdll/unix/sync.c dlls/win32u/opengl.c server/fsync.c server/inproc_sync.c dlls/ntdll/unix/system.c include/ddk/wdm.h dlls/ntdll/unix/virtual.c dlls/ntdll/thread.c dlls/kernelbase/sync.c dlls/kernel32/process.c dlls/kernel32/sync.c dlls/win32u/message.c include/winnt.h dlls/ntdll/signal_arm64.c dlls/ntdll/unix/signal_arm64.c include/minwindef.h dlls/ntdll/unix/unix_private.h dlls/ntdll/unix/file.c dlls/ntdll/unix/server.c loader/main.c dlls/winemac.drv/macdrv.h dlls/winemac.drv/window.c dlls/uiautomationcore/uia_client.c dlls/winegstreamer/media-converter/media-converter.h dlls/winebus.sys/bus_iohid.c"}

CLEAN_BUILD=no
for arg in "$@"; do
    case $arg in
        --clean-build) CLEAN_BUILD=yes ;;
        *) echo "usage: $0 [--clean-build]" >&2; exit 2 ;;
    esac
done

mkdir -p "$EVIDENCE_DIR"
RESULTS=()
FAILED=0

pass() { RESULTS+=("PASS  item $1: $2"); echo "PASS  item $1: $2"; }
fail() { RESULTS+=("FAIL  item $1: $2"); echo "FAIL  item $1: $2"; FAILED=1; }
info() { RESULTS+=("INFO  item $1: $2"); echo "INFO  item $1: $2"; }

# run_timeout SECONDS cmd... : exit 142 if the alarm fired
run_timeout() { local t=$1; shift; perl -e 'alarm shift; exec @ARGV or die "exec: $!"' "$t" "$@"; }

BUILD_SCRIPT=$PROTON_DIR/macos/build-wine.sh

########################################################################
# Item 2 first: the other items need a build.
########################################################################
echo "== item 2: macos/build-wine.sh"
if [ ! -x "$BUILD_SCRIPT" ]; then
    fail 2 "$BUILD_SCRIPT missing or not executable"
else
    if [ $CLEAN_BUILD = yes ]; then
        log=$EVIDENCE_DIR/build-clean.log
        rm -rf "$BUILD_DIR" "$BUILD_ROOT/wine-src" "$BUILD_ROOT/.wine-src-generated"
        start=$(date +%s)
        BUILD_ROOT=$BUILD_ROOT BUILD_DIR=$BUILD_DIR "$BUILD_SCRIPT" >"$log" 2>&1
        status=$?
        end=$(date +%s)
        size=$(du -sh "$BUILD_DIR" 2>/dev/null | cut -f1)
        srcsize=$(du -sh "$BUILD_ROOT/wine-src" 2>/dev/null | cut -f1)
        {
            echo "date=$(date -u +%FT%TZ)"
            echo "exit=$status"
            echo "wall_seconds=$((end - start))"
            echo "build_dir=$BUILD_DIR size=$size"
            echo "source_mirror=$BUILD_ROOT/wine-src size=$srcsize"
            echo "log=$log"
        } >"$EVIDENCE_DIR/build-clean-result.txt"
    else
        log=$EVIDENCE_DIR/build-incremental.log
        start=$(date +%s)
        BUILD_ROOT=$BUILD_ROOT BUILD_DIR=$BUILD_DIR "$BUILD_SCRIPT" >"$log" 2>&1
        status=$?
        end=$(date +%s)
        echo "exit=$status wall_seconds=$((end - start)) log=$log" >"$EVIDENCE_DIR/build-incremental-result.txt"
        [ $status = 0 ] || fail 2 "incremental build-wine.sh exited $status (see $log)"
    fi
    if [ -f "$EVIDENCE_DIR/build-clean-result.txt" ] && grep -qx 'exit=0' "$EVIDENCE_DIR/build-clean-result.txt"; then
        [ "${status:-1}" = 0 ] && pass 2 "clean build recorded: $(tr '\n' ' ' <"$EVIDENCE_DIR/build-clean-result.txt")"
    else
        fail 2 "no successful clean build recorded in $EVIDENCE_DIR/build-clean-result.txt (run with --clean-build)"
    fi
fi

########################################################################
# Item 1: toolchain actually used by the build
########################################################################
echo "== item 1: toolchain"
tlog=$EVIDENCE_DIR/toolchain.log
: >"$tlog"
bison_used=$(sed -n 's/^BISON *= *//p' "$BUILD_DIR/Makefile" 2>/dev/null | head -1)
mingw_used=$(sed -n 's/^aarch64_CC *= *//p' "$BUILD_DIR/Makefile" 2>/dev/null | head -1)
{
    echo "BISON from $BUILD_DIR/Makefile: ${bison_used:-<none>}"
    echo "aarch64_CC from $BUILD_DIR/Makefile: ${mingw_used:-<none>}"
} >>"$tlog"
bison_ok=no
if [ -n "$bison_used" ]; then
    bison_path=$(command -v "${bison_used%% *}" 2>/dev/null || echo "${bison_used%% *}")
    case $bison_used in
        /*) bison_path=${bison_used%% *} ;;
    esac
    echo "\$ $bison_path --version" >>"$tlog"
    bver=$("$bison_path" --version 2>&1 | head -1)
    echo "$bver" >>"$tlog"
    bmajor=$(echo "$bver" | sed -n 's/.* \([0-9][0-9]*\)\.[0-9.]*$/\1/p')
    [ -n "$bmajor" ] && [ "$bmajor" -ge 3 ] && bison_ok=yes
fi
mingw_ok=no
mingw_bin=$TOOLCHAIN_DIR/bin/aarch64-w64-mingw32-clang
echo "\$ $mingw_bin --version" >>"$tlog"
if "$mingw_bin" --version >>"$tlog" 2>&1; then
    case $mingw_used in
        *"$TOOLCHAIN_DIR"/bin/aarch64-w64-mingw32-clang*|aarch64-w64-mingw32-clang*) mingw_ok=yes ;;
    esac
fi
if [ $bison_ok = yes ] && [ $mingw_ok = yes ]; then
    pass 1 "bison '$bver' and llvm-mingw used by the build ($tlog)"
else
    fail 1 "bison_ok=$bison_ok mingw_ok=$mingw_ok ($tlog)"
fi

########################################################################
# Item 3: loader is arm64 Mach-O, __PAGEZERO >= 4 GB, wine --version works
########################################################################
echo "== item 3: loader"
llog=$EVIDENCE_DIR/loader.log
: >"$llog"
LOADER=$BUILD_DIR/loader/wine
WINE=$BUILD_DIR/wine            # build-tree front end (symlink to tools/wine/wine)
if [ ! -f "$LOADER" ] || [ ! -x "$WINE" ]; then
    fail 3 "$LOADER or $WINE not built"
else
    ok=yes
    summary=""
    for bin in "$LOADER" "$(cd "$(dirname "$WINE")" && pwd -P)/$(readlink "$WINE")"; do
        { echo "\$ file $bin"; file "$bin"; } >>"$llog" 2>&1
        { echo "\$ otool -l $bin (__PAGEZERO and WINE_* segments)"; otool -l "$bin" | grep -A5 -E 'segname (__PAGEZERO|WINE_)'; } >>"$llog" 2>&1
        file "$bin" | grep -q 'Mach-O 64-bit executable arm64' || { ok=no; echo "$bin: not an arm64 Mach-O executable" >>"$llog"; }
        pz=$(otool -l "$bin" | awk '/segname __PAGEZERO/{f=1} f&&/vmsize/{print $2; exit}')
        if [ -z "$pz" ] || [ $((pz)) -lt $((0x100000000)) ]; then ok=no; echo "$bin: __PAGEZERO vmsize ${pz:-missing} < 0x100000000" >>"$llog"; fi
        echo "\$ $bin --version" >>"$llog"
        ver=$(run_timeout 30 "$bin" --version 2>&1)
        vstatus=$?
        { echo "$ver"; echo "exit=$vstatus"; } >>"$llog"
        { [ $vstatus = 0 ] && echo "$ver" | grep -q '^wine-'; } || ok=no
        summary="$summary ${bin#$BUILD_DIR/}: pagezero=${pz:-?} '$ver' exit=$vstatus;"
    done
    if [ $ok = yes ]; then
        pass 3 "arm64 Mach-O;$summary ($llog)"
    else
        fail 3 "$summary ($llog)"
    fi
fi

########################################################################
# Item 4: wineserver starts and stops in a throwaway prefix
########################################################################
echo "== item 4: wineserver"
slog=$EVIDENCE_DIR/wineserver.log
: >"$slog"
SERVER=$BUILD_DIR/server/wineserver
PREFIX=$BUILD_DIR/wave1-prefix-server
if [ ! -x "$SERVER" ]; then
    fail 4 "$SERVER not built"
else
    rm -rf "$PREFIX"; mkdir -p "$PREFIX"
    devino=$(stat -f '%d %i' "$PREFIX")
    sockdir=$(printf '/tmp/.wine-%s/server-%x-%x' "$(id -u)" ${devino})
    {
        echo "WINEPREFIX=$PREFIX"
        echo "\$ wineserver -p   (persistent, daemonizes)"
        WINEPREFIX=$PREFIX run_timeout 30 "$SERVER" -p; echo "start exit=$?"
    } >>"$slog" 2>&1
    started=no
    for _ in $(seq 1 50); do [ -S "$sockdir/socket" ] && { started=yes; break; }; perl -e 'select undef,undef,undef,0.1'; done
    pid=$(pgrep -f "^$SERVER" | head -1)
    { echo "socket $sockdir/socket present=$started pid=${pid:-none}"; ls -la "$sockdir" 2>&1; } >>"$slog"
    {
        echo "\$ wineserver -k"; WINEPREFIX=$PREFIX run_timeout 30 "$SERVER" -k; echo "kill exit=$?"
        echo "\$ wineserver -w"; WINEPREFIX=$PREFIX run_timeout 30 "$SERVER" -w; echo "wait exit=$?"
    } >>"$slog" 2>&1
    stopped=yes
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && stopped=no
    [ -S "$sockdir/socket" ] && stopped=no
    echo "stopped=$stopped" >>"$slog"
    if [ $started = yes ] && [ -n "$pid" ] && [ $stopped = yes ]; then
        pass 4 "wineserver pid $pid started, socket created, stopped cleanly ($slog)"
    else
        fail 4 "started=$started pid=${pid:-none} stopped=$stopped ($slog)"
    fi
    rm -rf "$PREFIX"
fi

########################################################################
# Item 5: wineboot -u to the first failure (failure expected)
########################################################################
echo "== item 5: wineboot -u"
blog=$EVIDENCE_DIR/wineboot.log
PREFIX=$BUILD_DIR/wave1-prefix-boot
if [ ! -x "$WINE" ] || [ ! -x "$SERVER" ]; then
    fail 5 "wine/wineserver not built"
else
    rm -rf "$PREFIX"; mkdir -p "$PREFIX"
    {
        echo "\$ WINEPREFIX=$PREFIX WINEDEBUG=+seh,+loaddll,+process $WINE wineboot -u   (timeout ${WINEBOOT_TIMEOUT}s)"
    } >"$blog"
    WINEPREFIX=$PREFIX WINEDEBUG=+seh,+loaddll,+process run_timeout "$WINEBOOT_TIMEOUT" "$WINE" wineboot -u >>"$blog" 2>&1
    bstatus=$?
    echo "exit=$bstatus" >>"$blog"
    WINEPREFIX=$PREFIX run_timeout 30 "$SERVER" -k >/dev/null 2>&1
    WINEPREFIX=$PREFIX run_timeout 30 "$SERVER" -w >/dev/null 2>&1
    {
        echo "exit=$bstatus (142 = timed out)"
        echo "--- first seh/exception lines ---"
        grep -n -m 20 -E 'seh:|exception|EXCEPTION|fault|Unhandled|err:' "$blog"
        echo "--- loaded dlls ---"
        grep -n -E 'loaddll' "$blog" | head -40
        echo "--- last 40 lines ---"
        tail -40 "$blog"
    } >"$EVIDENCE_DIR/wineboot-summary.txt" 2>&1
    info 5 "wineboot -u exit=$bstatus (failure expected); log $blog, summary $EVIDENCE_DIR/wineboot-summary.txt"
fi

########################################################################
# Item 6: Linux build untouched
########################################################################
echo "== item 6: diff scope"
dlog=$EVIDENCE_DIR/diffstat.log
{
    echo "\$ git diff --stat $BASE_BRANCH...$SUPER_HEAD   (superproject, committed changes incl. submodule gitlinks)"
    git -C "$PROTON_DIR" diff --stat "$BASE_BRANCH...$SUPER_HEAD"
    echo "\$ git diff --raw $BASE_BRANCH...$SUPER_HEAD -- wine   (gitlink must be unchanged)"
    git -C "$PROTON_DIR" diff --raw "$BASE_BRANCH...$SUPER_HEAD" -- wine
    echo "\$ git -C wine diff --stat $WINE_BASE"
    git -C "$PROTON_DIR/wine" diff --stat "$WINE_BASE"
    echo "\$ git -C wine status --porcelain"
    git -C "$PROTON_DIR/wine" status --porcelain
} >"$dlog" 2>&1
# Committed changes only; gitlink changes (wine or any other submodule) are listed by path and fail too.
# Two lsteamclient files take Mac Steam's client library (Wave 5); their changes are under
# defined(__APPLE__) && defined(__aarch64__), which check-wave5.sh verifies.
bad=$(git -C "$PROTON_DIR" diff --name-only "$BASE_BRANCH...$SUPER_HEAD" | grep -v '^macos/' | grep -v -x -F -e lsteamclient/unixlib.cpp -e lsteamclient/unix_steam_input_manual.cpp)
wbad=""
for f in $(git -C "$PROTON_DIR/wine" diff --name-only "$WINE_BASE"); do
    case " $WINE_ALLOWED_FILES dlls/mfreadwrite/reader.c " in *" $f "*) ;; *) wbad="$wbad $f" ;; esac  # reader.c: Wave 5's, guarded by WINE_MACOS_AARCH64
done
wdirty=$(git -C "$PROTON_DIR/wine" status --porcelain --untracked-files=all | grep -v '^ M\|^M ' | head -5)
if [ -z "$bad" ] && [ -z "$wbad" ] && [ -z "$wdirty" ]; then
    pass 6 "superproject commits ($BASE_BRANCH...$SUPER_HEAD) change only macos/, wine changes only in: $(git -C "$PROTON_DIR/wine" diff --name-only "$WINE_BASE" | tr '\n' ' ') ($dlog)"
else
    fail 6 "committed outside macos/ ($BASE_BRANCH...$SUPER_HEAD): '$(echo $bad)' wine unexpected:${wbad:- none} wine untracked: '${wdirty}' ($dlog)"
fi

echo
echo "== summary"
printf '%s\n' "${RESULTS[@]}" | tee "$EVIDENCE_DIR/check-summary.txt"
exit $FAILED
