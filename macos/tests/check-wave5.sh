#!/bin/bash
#
# Wave 5 acceptance check for the native arm64 macOS Wine build: what games need beyond a picture.
# TLS, asymmetric keys, video, the cursor, fullscreen, Direct3D 9, OpenGL, controllers, resizing,
# and Steam through Proton's bridge to Mac Steam.
#
#   macos/tests/check-wave5.sh
#
# Items (pass/fail):
#   1  TLS: https_test.exe, for x86_64 and i386, fetches https://store.steampowered.com/ through
#      WinHTTP and gets status 200 (schannel on GnuTLS, which the bundle carries)
#   2  asymmetric keys: bcrypt_test.exe, x86_64 and i386, signs and verifies with RSA and agrees
#      on one secret between two ECDH P-256 keys (GnuTLS and libgcrypt)
#   3  video: mf_video_test.exe, x86_64 and i386, decodes one second of H.264/AAC in MP4 and of
#      VP9/Opus in WebM through Media Foundation (winedmo and winegstreamer on the bundle's
#      GStreamer and FFmpeg): all 30 video frames, the first one's centre within 6 of #3366cc in
#      each channel, and audio. Then the same with a Direct3D 11 device given to the reader, as
#      Unity's video player gives one: all 30 frames again, each as a Direct3D 11 texture (DXMT
#      has no NV12 textures, so the H.264 decoder's own samples are in system memory there)
#   4  cursor clip: cursor_clip_test.exe clips the cursor to a point and releases it 2000 times
#      and finds it where it should be every time. It shows two windows and moves the pointer.
#   5  fullscreen: fullscreen_test.exe switches a Direct3D 11 swap chain to fullscreen and back
#      three times with the client area right each time. It covers the screen for some seconds.
#   6  Direct3D 9: d3d9_test.exe, x86_64 and i386, draws offscreen on mtld3d ("Apple" adapter)
#      and reads its colour back. No window is shown.
#   7  OpenGL: opengl_test.exe, x86_64 and i386, draws into a framebuffer object on macOS's
#      OpenGL and reads its colour back. No window is shown.
#   8  controllers: controller_test.exe finds a controller through XInput or DirectInput. Without
#      one connected this is a TODO, not a fail.
#   9  resize: d3d11_resize_test.exe, with buffers of a fixed size and with ResizeBuffers, and
#      d3d12_window_test.exe resizable, are resized from outside to 1100x700 while they present,
#      and report the larger client area. That the picture fills it (winemac.drv's update of
#      DXMT's client surfaces) is for someone looking: with SCREENSHOTS=1 each window is
#      captured to the evidence folder. This item resizes windows through System Events.
#  10  Steam: with Mac Steam running and signed in, steam_api_test.exe initialises the Steam API
#      through a game's own steam_api64.dll (STEAM_API_DLL, for app STEAM_APP_ID) and is told it
#      is logged on and owns the app; without Mac Steam this is a TODO.
#  11  guards: the Wine changes since WINE_WAVE_BASE are in WAVE_FILES and vanish with __APPLE__
#      undefined, and so do the superproject's outside macos/ (two lsteamclient files)
#  12  regression: check-wave4.sh has no FAIL
#  13  adapter id: adapter_id_test.exe, x86_64 and i386, finds a display device
#      (EnumDisplayDevicesW) with the PCI id of its DXGI adapter, as a game does that reads the
#      graphics driver's version (The Last of Us Part II, which otherwise reports no GPU)
# The build comes first ("build", which takes long and can be left out with CHECK_ITEMS); the test
# programs are compiled on every run.
#
# Items 4, 5 and 9 show windows that take the focus; run them while nobody is using the Mac.
# They and item 12 need the screen unlocked.
#
# NOT YET CHECKED: AV1 video (Proton's dav1d plugin is not built); OpenGL above 2.1 and
# Proton's fullscreen hack, whose shader needs GLSL 3.30; the stuck cursor seen once in IRON NEST.
# Exit status: 1 when an item failed, 3 when none failed but some are TODO, 0 when all passed.
# Logs go to $EVIDENCE_DIR.

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
PROTON_DIR=$(cd "$SCRIPT_DIR/../.." && pwd)
BUILD_ROOT=${BUILD_ROOT:-/Users/annon/projects/proton-macos-build}
BUILD_DIR=${BUILD_DIR:-$BUILD_ROOT/wine-arm64ec}
TOOLCHAIN_DIR=${TOOLCHAIN_DIR:-/Users/annon/projects/proton-macos-toolchain/llvm-mingw-20261020-ucrt-macos-universal}
EVIDENCE_DIR=${EVIDENCE_DIR:-$BUILD_ROOT/evidence/wave5}
RUN_TIMEOUT=${RUN_TIMEOUT:-120}
SCREENSHOTS=${SCREENSHOTS:-0}
LOADER_PROFILE=${LOADER_PROFILE:-$BUILD_ROOT/signing/loader.provisionprofile}
STEAM_APP_ID=${STEAM_APP_ID:-2950790}
STEAM_API_DLL=${STEAM_API_DLL:-/Volumes/Samsung T7/SteamLibrary/steamapps/common/Iron Nest Heavy Turret Simulator/Iron Nest Heavy Turret Simulator_Data/Plugins/x86_64/steam_api64.dll}
STEAM_WIN_DLLS=${STEAM_WIN_DLLS:-/Volumes/Samsung T7/Windows Games/Steam}
FFMPEG_CLI=${FFMPEG_CLI:-/opt/homebrew/bin/ffmpeg}
WINE_DIR=$PROTON_DIR/wine
# where this wave starts: the tips after Wave 4's last change
WINE_WAVE_BASE=${WINE_WAVE_BASE:-23cb2615}
SUPER_WAVE_BASE=${SUPER_WAVE_BASE:-43acb634}
# Wine files this wave changes: ntdll's dlopen of a builtin's Unix library and its steamclient
# trampolines, winemac.drv's update of DXMT's client surfaces, ntdll's GStreamer paths, an include
# in winegstreamer's media converter, winebus's IOHID game controllers, and the source reader's
# drain of a decoder, which is PE code and so is guarded by configure's WINE_MACOS_AARCH64
WAVE_FILES="dlls/ntdll/unix/virtual.c dlls/ntdll/unix/loader.c dlls/winemac.drv/window.c dlls/winegstreamer/media-converter/media-converter.h dlls/winebus.sys/bus_iohid.c dlls/mfreadwrite/reader.c configure.ac dlls/winegstreamer/video_decoder.c dlls/winegstreamer/video_processor.c dlls/ntdll/unix/signal_arm64.c dlls/winemac.drv/cocoa_display.m programs/tabtip/tabtip.c"
SUPER_FILES="lsteamclient/unixlib.cpp lsteamclient/unix_steam_input_manual.cpp"
export MIN_FREE_GB=${MIN_FREE_GB:-4}
export WINEDLLOVERRIDES=${WINEDLLOVERRIDES:-mscoree,mshtml=}
unset VK_DRIVER_FILES VK_ICD_FILENAMES VK_ADD_DRIVER_FILES GST_PLUGIN_SYSTEM_PATH_1_0 GST_PLUGIN_SYSTEM_PATH

mkdir -p "$EVIDENCE_DIR"
RESULTS=()
FAILED=0
TODO=0
CHECK_ITEMS=${CHECK_ITEMS:-"build 1 2 3 4 5 6 7 8 9 10 11 12 13"}
want() { case " $CHECK_ITEMS " in *" $1 "*) return 0 ;; esac; return 1; }
pass() { RESULTS+=("PASS  item $1: $2"); echo "PASS  item $1: $2"; }
fail() { RESULTS+=("FAIL  item $1: $2"); echo "FAIL  item $1: $2"; FAILED=1; }
todo() { RESULTS+=("TODO  $1"); echo "TODO  $1"; TODO=1; }
run_timeout() {
    local t=$1; shift
    perl -e 'my $t = shift; my $pid = fork; die "fork: $!" unless defined $pid;
             if (!$pid) { exec @ARGV or die "exec: $!" }
             $SIG{ALRM} = sub { kill "KILL", $pid }; alarm $t; waitpid $pid, 0;
             exit((($? & 127) == 9) ? 142 : ($? & 127) ? 128 + ($? & 127) : $? >> 8)' "$t" "$@"
}
nap() { perl -e 'select(undef, undef, undef, shift)' "$1"; }
needs_unlocked() {
    ioreg -n Root -d1 2>/dev/null | grep -q '"CGSSessionScreenIsLocked"=Yes' || return 0
    fail "$1" "not checked: the screen is locked; unlock it and run this item again"
    return 1
}

MINGW_BIN=$TOOLCHAIN_DIR/bin
INSTALL_DIR=$(sed -n 's/^prefix = //p' "$BUILD_DIR/Makefile" 2>/dev/null | head -1)
WINE=$INSTALL_DIR/bin/wine
SERVER=$INSTALL_DIR/bin/wineserver
LIST_WINDOWS=$BUILD_ROOT/evidence/wave4/programs/list_windows
T=$EVIDENCE_DIR/programs
mkdir -p "$T"
PREFIX=$EVIDENCE_DIR/prefix
hold_server() { WINEPREFIX=$PREFIX run_timeout 30 "$SERVER" -p10 >/dev/null 2>&1; }
# winrun LOG exe args...: run a Windows program in the check's prefix; its stdout to LOG.out
winrun() {
    local log=$1; shift
    hold_server
    WINEPREFIX=$PREFIX run_timeout "$RUN_TIMEOUT" "$WINE" "$@" >"$log.out" 2>"$log.err" </dev/null
}
winpath() { printf 'Z:%s' "${1//\//\\}"; }

########################################################################
# Build: GStreamer, Wave 4's build (Wine and the bundle) and the Steam bridge
########################################################################
if want build; then
    echo "== build"
    blog=$EVIDENCE_DIR/build.log
    {
        "$PROTON_DIR/macos/build-gstreamer.sh" && \
        CHECK_ITEMS="build" LOADER_PROFILE=$LOADER_PROFILE \
            "$PROTON_DIR/macos/tests/check-wave4.sh" && \
        "$PROTON_DIR/macos/build-steam-bridge.sh" && \
        BUILD_DIR=$BUILD_DIR LOADER_PROFILE=$LOADER_PROFILE "$PROTON_DIR/macos/bundle-wine.sh"
    } >"$blog" 2>&1
    bstatus=$?
    if [ $bstatus -eq 0 ] && grep -q "installed GStreamer" "$blog" && grep -q "installed mtld3d" "$blog" \
        && grep -q "installed Proton's lsteamclient" "$blog"; then
        pass build "GStreamer, Wine, the Steam bridge and the bundle (with GStreamer, mtld3d, the bridge) ($blog)"
    else
        fail build "exit $bstatus: $(tail -1 "$blog" | cut -c1-120) ($blog)"
    fi
fi

########################################################################
# The test programs, every run: they take seconds
########################################################################
if true; then
    cc() { "$MINGW_BIN/$1-w64-mingw32-clang" -O2 -Wall -o "$T/$2" "$SCRIPT_DIR/$3" "${@:4}" >>"$T/build.log" 2>&1; }
    : >"$T/build.log"
    for a in x86_64 i686; do
        cc $a https_test_$a.exe https_test.c -lwinhttp
        cc $a bcrypt_test_$a.exe bcrypt_test.c -lbcrypt
        cc $a mf_video_test_$a.exe mf_video_test.c -lmfplat -lmfreadwrite -lmfuuid -lole32 -luuid -ld3d11 -ldxguid
        cc $a d3d9_test_$a.exe d3d9_test.c -ld3d9 -luser32
        cc $a opengl_test_$a.exe opengl_test.c -lopengl32 -lgdi32 -luser32
        cc $a adapter_id_test_$a.exe adapter_id_test.c -ldxgi -ldxguid -luuid -luser32
    done
    cc x86_64 cursor_clip_test.exe cursor_clip_test.c -luser32 -lgdi32
    cc x86_64 fullscreen_test.exe fullscreen_test.c -ld3d11 -ldxgi -ldxguid -luuid -luser32
    cc x86_64 controller_test.exe controller_test.c -lxinput -ldinput8 -ldxguid -luuid -lole32
    cc x86_64 d3d11_resize_test.exe d3d11_resize_test.c -ld3d11 -ldxguid -luuid -luser32
    cc x86_64 d3d12_window_test.exe d3d12_window_test.c -ld3d12 -ldxgi -ldxguid -luuid -luser32
    cc x86_64 steam_api_test.exe steam_api_test.c
    # one second of a single colour with a tone, as H.264/AAC and VP9/Opus
    "$FFMPEG_CLI" -loglevel error -y -f lavfi -i color=c=0x3366cc:s=320x240:r=30:d=1 -f lavfi -i sine=f=440:d=1 \
        -c:v libx264 -profile:v baseline -pix_fmt yuv420p -c:a aac -shortest "$T/h264_aac.mp4" >>"$T/build.log" 2>&1
    "$FFMPEG_CLI" -loglevel error -y -f lavfi -i color=c=0x3366cc:s=320x240:r=30:d=1 -f lavfi -i sine=f=440:d=1 \
        -c:v libvpx-vp9 -pix_fmt yuv420p -c:a libopus -shortest "$T/vp9_opus.webm" >>"$T/build.log" 2>&1
    n=$(ls "$T"/*.exe 2>/dev/null | wc -l | tr -d ' ')
    [ "$n" -eq 18 ] && [ -s "$T/h264_aac.mp4" ] && [ -s "$T/vp9_opus.webm" ] \
        && pass programs "18 test programs and 2 video files ($T)" || fail programs "$n of 18 test programs ($T/build.log)"
fi

if [ ! -x "$WINE" ]; then
    fail prefix "no Wine at $WINE"
else
    if [ ! -f "$PREFIX/system.reg" ]; then
        mkdir -p "$PREFIX"
        WINEPREFIX=$PREFIX run_timeout 300 "$WINE" wineboot -u >"$EVIDENCE_DIR/wineboot.log" 2>&1
    fi

# two_arch ITEM NAME PATTERN args...: run NAME for x86_64 and i686; pass when both lines match
two_arch() {
    local item=$1 name=$2 pattern=$3 a lines="" ok=yes; shift 3
    for a in x86_64 i686; do
        winrun "$EVIDENCE_DIR/item$item-$a" "$T/${name}_$a.exe" "$@"
        grep -Eq "$pattern" "$EVIDENCE_DIR/item$item-$a.out" || ok=no
        lines="$lines $a: '$(head -1 "$EVIDENCE_DIR/item$item-$a.out")'"
    done
    [ $ok = yes ] && pass "$item" "$name$lines ($EVIDENCE_DIR/item$item-*)" || fail "$item" "$name$lines ($EVIDENCE_DIR/item$item-*)"
}

want 1 && two_arch 1 https_test 'status 200'
want 2 && two_arch 2 bcrypt_test 'rsa sign 0 verify 0, ecdh agree 0 0 same 1'
want 13 && two_arch 13 adapter_id_test 'match 1'

if want 3; then
    ok=yes; lines=""
    for a in x86_64 i686; do
        for f in h264_aac.mp4 vp9_opus.webm; do
            for mode in "" d3d11; do
                winrun "$EVIDENCE_DIR/item3-$a-$f${mode:+-$mode}" "$T/mf_video_test_$a.exe" "$(winpath "$T/$f")" $mode
                line=$(head -1 "$EVIDENCE_DIR/item3-$a-$f${mode:+-$mode}.out")
                lines="$lines $a $f${mode:+ $mode}: '$line'"
                c=$(echo "$line" | sed -n 's/.*first centre \([0-9a-f]\{6\}\).*/\1/p')
                frames=$(echo "$line" | sed -n 's/^mf video: \([0-9]*\) frames.*/\1/p')
                audio=$(echo "$line" | sed -n 's/.*audio \([0-9]*\) bytes.*/\1/p')
                close=$(perl -e '$c = hex shift; $w = 0x3366cc; for $s (0, 8, 16) { exit 1 if abs((($c >> $s) & 255) - (($w >> $s) & 255)) > 6 } exit 0' "${c:-0}" && echo yes || echo no)
                [ "${frames:-0}" -eq 30 ] && [ "${audio:-0}" -gt 0 ] && [ "$close" = yes ] || ok=no
                if [ -n "$mode" ]; then
                    textures=$(echo "$line" | sed -n 's/.*d3d11 textures \([0-9]*\).*/\1/p')
                    [ "${textures:-0}" -eq 30 ] || ok=no
                fi
            done
        done
    done
    [ $ok = yes ] && pass 3 "Media Foundation decodes H.264/AAC and VP9/Opus, also with a Direct3D 11 device:$lines" || fail 3 "$lines ($EVIDENCE_DIR/item3-*)"
fi

if want 4 && needs_unlocked 4; then
    winrun "$EVIDENCE_DIR/item4" "$T/cursor_clip_test.exe" 2000
    grep -q '2000/2000 rounds' "$EVIDENCE_DIR/item4.out" && pass 4 "$(head -1 "$EVIDENCE_DIR/item4.out")" \
        || fail 4 "$(head -1 "$EVIDENCE_DIR/item4.out") ($EVIDENCE_DIR/item4.*)"
fi

if want 5 && needs_unlocked 5; then
    winrun "$EVIDENCE_DIR/item5" "$T/fullscreen_test.exe"
    grep -q '3/3 switches' "$EVIDENCE_DIR/item5.out" && pass 5 "$(head -1 "$EVIDENCE_DIR/item5.out")" \
        || fail 5 "$(head -1 "$EVIDENCE_DIR/item5.out") ($EVIDENCE_DIR/item5.*)"
fi

want 6 && two_arch 6 d3d9_test 'adapter "Apple[^"]*", hal 1, pixel 3366cc'
want 7 && two_arch 7 opengl_test 'pixel 3366cc'

if want 8; then
    winrun "$EVIDENCE_DIR/item8" "$T/controller_test.exe"; s=$?
    case $s in
        0) pass 8 "$(tail -1 "$EVIDENCE_DIR/item8.out"): $(head -1 "$EVIDENCE_DIR/item8.out")" ;;
        2) todo "item 8: no controller connected ($(tail -1 "$EVIDENCE_DIR/item8.out")); connect one and run item 8 again" ;;
        *) fail 8 "exit $s: $(head -1 "$EVIDENCE_DIR/item8.out")" ;;
    esac
fi

if want 9 && needs_unlocked 9; then
    ok=yes; lines=""
    # resize_case LABEL exe args...: start it, resize its window to 1100x700, capture, wait for it
    resize_case() {
        local label=$1 pid w; shift
        hold_server
        WINEPREFIX=$PREFIX run_timeout 90 "$WINE" "$@" >"$EVIDENCE_DIR/item9-$label.out" 2>"$EVIDENCE_DIR/item9-$label.err" </dev/null &
        for i in $(seq 1 60); do
            w=$("$LIST_WINDOWS" "$INSTALL_DIR" 2>/dev/null | awk -F'\t' '$6==1' | head -1)
            [ -n "$w" ] && break; nap 0.5
        done
        nap 2
        pid=$(echo "$w" | cut -f1)
        osascript -e "tell application \"System Events\" to tell (first process whose unix id is $pid) to set size of window 1 to {1100, 700}" >/dev/null 2>&1
        nap 3
        if [ "$SCREENSHOTS" = 1 ]; then
            w=$("$LIST_WINDOWS" "$INSTALL_DIR" 2>/dev/null | awk -F'\t' -v p="$pid" '$6==1 && $1==p' | head -1)
            read -r ww wh <<<"$(echo "$w" | cut -f2 | tr x ' ')"; read -r wx wy <<<"$(echo "$w" | cut -f3 | tr , ' ')"
            [ -n "${ww:-}" ] && screencapture -x -R"$wx,$wy,$ww,$wh" "$EVIDENCE_DIR/item9-$label.png"
        fi
        wait
        lines="$lines $label: '$(head -1 "$EVIDENCE_DIR/item9-$label.out")'"
    }
    resize_case d3d11-fixed "$T/d3d11_resize_test.exe" 14
    grep -q -- '-> 1100x668, buffers 640x360' "$EVIDENCE_DIR/item9-d3d11-fixed.out" || ok=no
    resize_case d3d11-resize "$T/d3d11_resize_test.exe" 14 resize
    grep -q -- '-> 1100x668, buffers 1100x668' "$EVIDENCE_DIR/item9-d3d11-resize.out" || ok=no
    resize_case d3d12 "$T/d3d12_window_test.exe" 900 resizable
    grep -q 'presented 900/900' "$EVIDENCE_DIR/item9-d3d12.out" || ok=no
    [ $ok = yes ] && pass 9 "resized while presenting:$lines ($EVIDENCE_DIR/item9-*)" || fail 9 "$lines ($EVIDENCE_DIR/item9-*)"
fi

if want 10; then
    if ! pgrep -f steam_osx >/dev/null; then
        todo "item 10: Mac Steam is not running; start it, sign in and run item 10 again"
    elif [ ! -f "$STEAM_API_DLL" ] || [ ! -f "$STEAM_WIN_DLLS/steamclient64.dll" ]; then
        todo "item 10: no $STEAM_API_DLL or no Windows steamclient64.dll in $STEAM_WIN_DLLS"
    else
        sdir="$PREFIX/drive_c/Program Files (x86)/Steam"
        mkdir -p "$sdir"
        cp "$STEAM_WIN_DLLS/steamclient64.dll" "$STEAM_WIN_DLLS/steamclient.dll" "$sdir/" 2>/dev/null
        cp "$STEAM_API_DLL" "$T/steam_api64.dll"
        STEAM_COMPAT_CLIENT_INSTALL_PATH="$HOME/Library/Application Support/Steam/Steam.AppBundle/Steam/Contents/MacOS" \
            winrun "$EVIDENCE_DIR/item10" "$T/steam_api_test.exe" "$(winpath "$T/steam_api64.dll")" "$STEAM_APP_ID"
        grep -q 'init 0, running 1, logged on 1, steamid \.\.\.[0-9]*, subscribed 1' "$EVIDENCE_DIR/item10.out" \
            && pass 10 "Mac Steam through lsteamclient: $(head -1 "$EVIDENCE_DIR/item10.out")" \
            || fail 10 "$(head -1 "$EVIDENCE_DIR/item10.out") ($EVIDENCE_DIR/item10.*)"
    fi
fi
fi  # Wine present

if want 11; then
    bad=""; n=0
    for f in $(git -C "$WINE_DIR" diff --name-only "$WINE_WAVE_BASE" HEAD); do
        case " $WAVE_FILES " in *" $f "*) ;; *) bad="$bad wine:$f" ;; esac
    done
    for f in $WAVE_FILES; do
        if [ "$f" = configure.ac ]; then
            # configure.ac is no C: every line it gained must be about the macOS arm64 define
            other=$(git -C "$WINE_DIR" diff -U0 "$WINE_WAVE_BASE" HEAD -- "$f" | grep '^+[^+]' \
                | grep -v -E 'wine_macos_aarch64_cflags|WINE_MACOS_AARCH64|darwin\*-aarch64|^\+case "\$host_os-\$HOST_ARCH" in$|^\+(dnl|\s*esac|\s*then|\s*fi)\b|^\+\s*$')
            [ -z "$other" ] || bad="$bad unguarded:$f"
        else
            a=$(git -C "$WINE_DIR" show "$WINE_WAVE_BASE:$f" | unifdef -U__APPLE__ -UWINE_MACOS_AARCH64 2>/dev/null | shasum)
            b=$(git -C "$WINE_DIR" show "HEAD:$f" | unifdef -U__APPLE__ -UWINE_MACOS_AARCH64 2>/dev/null | shasum)
            [ "$a" = "$b" ] || bad="$bad unguarded:$f"
        fi
        n=$((n + $(git -C "$WINE_DIR" diff "$WINE_WAVE_BASE" HEAD -- "$f" | grep -c '^+[^+]')))
    done
    for f in $(git -C "$PROTON_DIR" diff --name-only "$SUPER_WAVE_BASE" HEAD | grep -v '^macos/'); do
        case " $SUPER_FILES " in
            *" $f "*) a=$(git -C "$PROTON_DIR" show "$SUPER_WAVE_BASE:$f" | unifdef -U__APPLE__ 2>/dev/null | shasum)
                      b=$(git -C "$PROTON_DIR" show "HEAD:$f" | unifdef -U__APPLE__ 2>/dev/null | shasum)
                      [ "$a" = "$b" ] || bad="$bad unguarded:$f" ;;
            *) bad="$bad super:$f" ;;
        esac
    done
    [ -n "$(git -C "$PROTON_DIR" diff --raw "$SUPER_WAVE_BASE" HEAD -- wine)" ] && bad="$bad wine(pointer)"
    [ -z "$bad" ] && pass 11 "$n lines added in $WAVE_FILES since $WINE_WAVE_BASE and the two lsteamclient files, all gone with __APPLE__ and WINE_MACOS_AARCH64 undefined (configure.ac: only the define)" \
        || fail 11 "$bad"
fi

if want 12 && needs_unlocked 12; then
    # in check-wave4.sh's own evidence folder: its test programs are compiled by its build step,
    # which this check's build step runs there
    R=$BUILD_ROOT/evidence/wave4
    CHECK_ITEMS="1 2 3 4 5 6 7 8 9 10 11" LOADER_PROFILE=$LOADER_PROFILE \
        "$PROTON_DIR/macos/tests/check-wave4.sh" >"$EVIDENCE_DIR/regression-wave4.out" 2>&1
    if [ -s "$R/check-summary.txt" ] && ! grep -q '^FAIL' "$R/check-summary.txt"; then
        pass 12 "check-wave4.sh: no FAIL ($R/check-summary.txt)"
    else
        fail 12 "check-wave4.sh: $(grep '^FAIL' "$R/check-summary.txt" 2>/dev/null | cut -c1-80 | paste -sd';' -) ($R)"
    fi
fi

todo "AV1 video, OpenGL above 2.1 and Proton's fullscreen hack, and the cursor once stuck in IRON NEST have no items yet; Wave 5 is not done"

echo
echo "== summary"
printf '%s\n' "${RESULTS[@]}" | tee "$EVIDENCE_DIR/check-summary.txt"
[ $FAILED -eq 1 ] && exit 1
[ $TODO -eq 1 ] && exit 3
exit 0
