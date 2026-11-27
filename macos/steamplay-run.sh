#!/bin/bash
#
# Run a Windows game that Mac Steam installed, under the macOS Proton build, the way Steam Play
# runs one through Proton on Linux.
#
#   macos/steamplay-run.sh <app id> [game arguments...]
#
# Steam Play's compatibility tool (macos/steamplay-tools/proton-macos/run) gets here through
# macos/steamplay-launch when the player presses Play; it can also be run by hand. It stands in
# for Valve's "proton" script, which is not ported: it finds the game through Steam's library
# folders and the app's manifest, gives it a prefix in
# <library>/steamapps/compatdata/<app id>/pfx as Proton does, does what the game's install
# scripts ask for, puts Valve's Windows client DLLs where steam_api looks for them, and starts
# the game through Proton's steam.exe, so that lsteamclient connects it to the running Mac
# Steam (login, ownership, stats and playtime; not the overlay, which does not draw yet).
#
# Environment overrides:
#   WINE_INSTALL    the bundle (default: Protium.app's Contents/SharedSupport/runtime when this
#                   script is the app's copy, else ~/projects/proton-macos-build/install-aarch64)
#   PROTIUM_PYTHON  the Python that runs macos/steamplay (default: Protium.app's own when this
#                   script is the app's copy, else python3 from PATH)
#   STEAM_ROOT      Mac Steam's data folder (default ~/Library/Application Support/Steam)
#   WIN_STEAM_DLLS  a folder with Valve's Windows steamclient.dll and steamclient64.dll, which
#                   Mac Steam does not ship (Linux Steam has them in legacycompat/); copy them from
#                   the top folder of a Windows Steam install (default ~/Library/Application
#                   Support/SteamPlay/steamclient-windows)
#   GAME_EXE        the executable, relative to the install folder or as a full path, when the
#                   largest .exe in its top folder is not the game (macos/steamplay-launch gives
#                   the one Steam chose)
#   STEAMPLAY_LOG   this run's log: what this script and Wine say (default
#                   <prefix>/../steamplay-run.log; the five runs before keep theirs as
#                   steamplay-run.prev.log, the newest, to steamplay-run.prev5.log)
#   WINEDEBUG       Wine's debug channels (default +loaddll,+msgbox)
#   PROTON_NO_FSYNC 1 to have every wait for, and change to, an event, semaphore or mutex go to
#                   the wineserver again. By default they are kept in shared memory
#                   (WINEFSYNC=1), as Proton does on Linux.
#   WINE_FSYNC_STATS  seconds between lines in the log that say how each process slept and
#                   what it woke; WINE_FSYNC_PARANOID=1 reports a wake-up that did not arrive
#   WINE_PROCESS_STATS  seconds between the "Process:" lines every Wine process of the game writes
#                   to the log, of what its threads did (processor time, time waiting for a core,
#                   memory, wineserver calls, waits, and FEX's counters when FEX keeps them), and
#                   the "Audio:" lines of audio that ran dry (default 30; 0 turns them off)
#   PROTON_DISABLE_HIDRAW  1 (the default here) has every game controller come through SDL with
#                   the layout of an Xbox controller; 0 lets Wine take a PlayStation controller
#                   as itself, for a game that knows it. PROTON_NO_SDL=1 turns SDL off: then
#                   controllers come as macOS reports them, as before Protium 0.4.2.
#   FEX_DISKCACHE   0 to have FEX translate a game's x86 code afresh at every start. By default
#                   (1) it keeps the translated code in the prefix and reads it back the next
#                   time, which shortens starts and loads after the first.
#   FEX_HARDWARE_TSO_OFF  for which calls into native code a thread gives up the processor's
#                   x86 memory ordering: "all" (the default), "syscall", "unix" or "none".
#                   Giving it up costs two kernel traps for each such call; keeping it makes
#                   the native code of that call slower where it mostly writes memory.
#                   macos/tests/cpu-bench.sh measures both.
#   WINE_MAC_RETINA auto, 1 or 0: whether the game is told a HiDPI screen's pixels (see "hires"
#                   in macos/steamplay, which sets it when it is not set)
#   MTL_HUD_ENABLED 1 to have macOS draw its Metal performance HUD over the game: frames per
#                   second and frame times, with lines DXMT adds. "macos/steamplay hud on" sets
#                   it for every game.
#
# For one game, these go in ~/Library/Application Support/SteamPlay/env.<app id> (under
# STEAMPLAY_HOME when that is set), one VAR=value a line, e.g.
#   WINEDEBUG=+loaddll,+msgbox,+system,+display
# It is read as shell and exported before anything of Wine's starts. Mac Steam does not take
# "VAR=value %command%" in a game's launch options for this tool: it fails to start the game
# with "OS Error 260".
#
# Steam's STEAM_COMPAT_CONFIG is read for nativevulkanloader. When a thread of the game waits a
# minute for a lock, samples of the game's processes are left as steamplay-run.hang.<pid>.txt.

set -Eeuo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# inside Protium.app this script is Contents/Resources/steamplay/steamplay-run.sh, next to the
# app's runtime and Python in Contents/SharedSupport
app_support="$SCRIPT_DIR/../../SharedSupport"
if [ -z "${WINE_INSTALL:-}" ] && [ -x "$app_support/runtime/bin/wine" ]; then
    WINE_INSTALL=$(cd "$app_support/runtime" && pwd)
fi
if [ -z "${PROTIUM_PYTHON:-}" ] && [ -x "$app_support/python/bin/python3" ]; then
    PROTIUM_PYTHON=$(cd "$app_support/python/bin" && pwd)/python3
fi
WINE_INSTALL=${WINE_INSTALL:-$HOME/projects/proton-macos-build/install-aarch64}
PROTIUM_PYTHON=${PROTIUM_PYTHON:-python3}
# the app's Python must not write compiled files into the app, which would break its signature
export PYTHONDONTWRITEBYTECODE=1
STEAM_ROOT=${STEAM_ROOT:-$HOME/Library/Application Support/Steam}
WIN_STEAM_DLLS=${WIN_STEAM_DLLS:-$HOME/Library/Application Support/SteamPlay/steamclient-windows}

die() { echo "steamplay-run.sh: error: $*" >&2; trap - EXIT; exit 1; }
log() { echo ":: $*" >&2; }
# A step that fails before the game starts says which, in the log: set -e would otherwise end
# this script without a word (die says its own)
failed=
trap 'failed="line $LINENO: $BASH_COMMAND"' ERR
trap 'status=$?; [ $status -eq 0 ] || echo "steamplay-run.sh: error: the game was not started: a step failed (status $status${failed:+, $failed})" >&2' EXIT

# This run's log, in the game's compatibility data folder, which Steam names: the five runs before
# keep theirs, the newest as .prev.log and the oldest as .prev5.log (the next start is often how a
# crash gets looked at, and telling whether a change made a game run better takes more than one
# run to compare with). It is made before anything here can fail, and from then on what this
# script says goes into it too: Steam starts the script with its output going nowhere, so an
# error before the game started was lost, a game that "crashed at once" left no log, or the run
# before's under this run's name. Started from a terminal, the script still talks to it.
logfile=
start_log() {
    logfile=${STEAMPLAY_LOG:-$1/steamplay-run.log}
    mkdir -p "$(dirname "$logfile")"
    prev_base=${logfile%.log}
    for i in 4 3 2; do
        if [ -f "$prev_base.prev$i.log" ]; then mv -f "$prev_base.prev$i.log" "$prev_base.prev$((i + 1)).log"; fi
    done
    if [ -f "$prev_base.prev.log" ]; then mv -f "$prev_base.prev.log" "$prev_base.prev2.log"; fi
    if [ -f "$logfile" ]; then mv -f "$logfile" "$prev_base.prev.log"; fi
    # The watcher and the record below know this session's log by its file, not by its name: when
    # the game is started again before this session has quite ended (the Rockstar launcher takes a
    # minute and more to close after its game), that start moves this log aside, and by name they
    # would read the new one. Wine's output goes on at the end of this same file.
    : >"$logfile"
    log_inode=$(stat -f %i "$logfile")
    # held open on descriptor 3, so that wineboot and Wine write to this run's log even when a
    # second start has moved it aside meanwhile (a first start's install steps can take minutes)
    exec 3>>"$logfile"
    if [ ! -t 2 ]; then exec >&3 2>&3; fi
    # which Protium, and on which Mac: what a report of a game that does not start needs first
    local version memory
    version=$(cat "$SCRIPT_DIR/VERSION" 2>/dev/null) || version="$(cat "$SCRIPT_DIR/app/VERSION" 2>/dev/null || echo '?') from a checkout"
    memory=$(sysctl -n hw.memsize 2>/dev/null) || memory=0
    [[ $memory =~ ^[0-9]+$ ]] || memory=0
    log "$(date '+%Y-%m-%d %H:%M:%S'): Protium $version, app $appid, on $(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo '?')" \
        "($(sysctl -n hw.model 2>/dev/null || echo '?'), $((memory >> 30)) GB), macOS $(sw_vers -productVersion 2>/dev/null || echo '?')" \
        "($(sw_vers -buildVersion 2>/dev/null || echo '?'))"
}

[ $# -ge 1 ] || die "usage: steamplay-run.sh <app id> [game arguments...]"
appid=$1; shift
[[ $appid =~ ^[0-9]+$ ]] || die "'$appid' is not an app id"
# Steam names the folder before anything else is known; by hand, it is found with the game below
if [ -n "${STEAM_COMPAT_DATA_PATH:-}${STEAMPLAY_LOG:-}" ]; then
    start_log "${STEAM_COMPAT_DATA_PATH:-}"
fi
[ -x "$WINE_INSTALL/bin/wine" ] || die "no Wine in $WINE_INSTALL"
CLIENT_DIR="$STEAM_ROOT/Steam.AppBundle/Steam/Contents/MacOS"
[ -f "$CLIENT_DIR/steamclient.dylib" ] || die "no steamclient.dylib in $CLIENT_DIR"
pgrep -f steam_osx >/dev/null || die "Mac Steam is not running; start it and sign in first"

# The library that holds the app: the one whose steamapps has its manifest
library=
while IFS= read -r path; do
    [ -f "$path/steamapps/appmanifest_$appid.acf" ] && { library=$path; break; }
done < <(sed -n 's/^[[:space:]]*"path"[[:space:]]*"\(.*\)"$/\1/p' "$STEAM_ROOT/steamapps/libraryfolders.vdf")
[ -n "$library" ] || die "app $appid is not installed in any Steam library"
manifest="$library/steamapps/appmanifest_$appid.acf"
installdir=$(sed -n 's/^[[:space:]]*"installdir"[[:space:]]*"\(.*\)"$/\1/p' "$manifest")
game_dir="$library/steamapps/common/$installdir"
[ -d "$game_dir" ] || die "no install folder $game_dir"

if [ -n "${GAME_EXE:-}" ]; then
    case $GAME_EXE in /*) exe=$GAME_EXE ;; *) exe="$game_dir/$GAME_EXE" ;; esac
else
    exe=$(find "$game_dir" -maxdepth 1 -iname '*.exe' ! -iname 'UnityCrashHandler*' ! -iname '*setup*' \
          ! -iname 'unins*' -exec stat -f '%z %N' {} + | sort -rn | head -1 | cut -d' ' -f2-)
fi
if [ ! -f "$exe" ]; then
    if [ -n "${GAME_EXE:-}" ]; then die "the game's executable is missing: $exe"; fi
    die "no game executable in $game_dir (set GAME_EXE)"
fi

# Steam Play names the game's compatibility data folder itself; it is the same one
compat=${STEAM_COMPAT_DATA_PATH:-"$library/steamapps/compatdata/$appid"}
prefix="$compat/pfx"
[ -n "$logfile" ] || start_log "$compat"
mkdir -p "$prefix"
export WINEPREFIX="$prefix"
export STEAM_COMPAT_DATA_PATH="$compat"
export STEAM_COMPAT_CLIENT_INSTALL_PATH="$CLIENT_DIR"
export STEAM_COMPAT_INSTALL_PATH="$game_dir"
export STEAM_COMPAT_LIBRARY_PATHS="$library/steamapps"
export SteamAppId=$appid SteamGameId=$appid SteamOverlayGameId=$appid
export WINEDLLOVERRIDES="${WINEDLLOVERRIDES:-mscoree,mshtml=}"
# macOS's Metal performance HUD, for every game while "macos/steamplay hud on" has left its file
if [ -z "${MTL_HUD_ENABLED:-}" ] && [ -e "${STEAMPLAY_HOME:-$HOME/Library/Application Support/SteamPlay}/hud" ]; then
    export MTL_HUD_ENABLED=1
fi
# Whether a game is told a HiDPI screen's pixels or its points ("macos/steamplay hires"). Wine's
# Mac driver reads this in every process, and all that run in a prefix have to get the same
# answer: so it is one setting for every game, set here before anything of Wine's starts
if [ -z "${WINE_MAC_RETINA:-}" ]; then
    WINE_MAC_RETINA=$("$PROTIUM_PYTHON" "$SCRIPT_DIR/steamplay" hires --value 2>/dev/null) || WINE_MAC_RETINA=auto
    export WINE_MAC_RETINA
fi
# GLib in lib/external would load GIO modules from Homebrew's folder, which on a player's Mac
# holds modules for whatever GLib Homebrew has; it gets a folder of the bundle's own instead
export GIO_MODULE_DIR=${GIO_MODULE_DIR:-$WINE_INSTALL/lib/external/gio/modules}
# One game's own settings, from env.<app id> next to that file (see the head of this file)
game_env="${STEAMPLAY_HOME:-$HOME/Library/Application Support/SteamPlay}/env.$appid"
# its text goes with the record of the run (not exported, so the game never sees it): telling
# whether a change made a game run better needs to know what the run started with
game_env_text=
if [ -f "$game_env" ]; then
    game_env_text=$(cat "$game_env")
    set -a
    . "$game_env"
    set +a
fi
# fsync: the wineserver decides as it starts and the game's processes follow it, so this is set
# before anything of Wine's runs here. A server that an earlier run left in the prefix keeps
# what it started with.
if [ "${PROTON_NO_FSYNC:-0}" = 1 ]; then
    export WINEFSYNC=0
else
    export WINEFSYNC="${WINEFSYNC:-1}"
fi
# Game controllers come through SDL, which gives every one of them the layout of an Xbox
# controller, the only one most games know. Wine would take a PlayStation controller as itself
# instead (raw HID), for the few games that know it: on Linux Steam Input stands in for the
# others then, and there is none here. PROTON_DISABLE_HIDRAW=0 in a game's env file gives that
# game the controller as itself, PROTON_NO_SDL=1 turns SDL off for it.
export PROTON_DISABLE_HIDRAW="${PROTON_DISABLE_HIDRAW:-1}"
# FEX's cache of translated code. Without the second setting a 32-bit and a 64-bit process of
# one game delete each other's files, as each takes the other's for stale.
export FEX_DISKCACHE="${FEX_DISKCACHE:-1}"
export FEX_DISKCACHEPRUNESTALEENTRIES="${FEX_DISKCACHEPRUNESTALEENTRIES:-0}"
unset VK_DRIVER_FILES VK_ICD_FILENAMES VK_ADD_DRIVER_FILES PROTON_DISABLE_LSTEAMCLIENT

if [ ! -f "$prefix/system.reg" ]; then
    log "creating the prefix in $prefix"
    "$WINE_INSTALL/bin/wine" wineboot -u >&3 2>&3 3>&- || die "wineboot failed in $prefix (what it said is above)"
fi
# Proton's wine.inf registers its fonts by file name (arial.ttf, tahoma.ttf, ...), and Proton's
# script links the files into the prefix's Fonts folder. DirectWrite lists what it finds there
# and nothing else: with the folder empty it had no Tahoma, and the browser of the Rockstar Games
# Launcher asked for one in circles until its stack was gone. Wine's own fonts go in as Proton
# puts them; where Proton has fonts of its own making under Microsoft's names, the Mac's own
# copies of Microsoft's fonts stand in. (The East Asian and Indic ones have no such stand-in.)
fonts_dir="$prefix/drive_c/windows/Fonts"
mkdir -p "$fonts_dir"
for font in "$WINE_INSTALL"/share/wine/fonts/*.tt[fc]; do
    [ -e "$font" ] && ln -sfn "$font" "$fonts_dir/$(basename "$font")"
done
while IFS='|' read -r font mac_font; do
    [ -f "/System/Library/Fonts/Supplemental/$mac_font" ] \
        && ln -sfn "/System/Library/Fonts/Supplemental/$mac_font" "$fonts_dir/$font"
done <<'FONTS'
arial.ttf|Arial.ttf
arialbd.ttf|Arial Bold.ttf
cour.ttf|Courier New.ttf
courbd.ttf|Courier New Bold.ttf
micross.ttf|Microsoft Sans Serif.ttf
tahoma.ttf|Tahoma.ttf
tahomabd.ttf|Tahoma Bold.ttf
times.ttf|Times New Roman.ttf
wingdings.ttf|Wingdings.ttf
FONTS
# What the game's install scripts ask for, once per prefix: Steam for Windows and for Linux run
# them before a game's first start, Mac Steam does not (see "installscript" in macos/steamplay).
# Red Dead Redemption 2's installs the Vulkan runtime that the option below is about.
STEAMPLAY_WINE="$WINE_INSTALL/bin/wine" WINEDEBUG=-all "$PROTIUM_PYTHON" "$SCRIPT_DIR/steamplay" installscript "$appid" \
    || log "app $appid: an install script step did not finish (macos/steamplay installscript $appid --again repeats them)"
# Steam's own compatibility options for the game, which Proton's script takes the same way.
# nativevulkanloader: the game is to load Khronos's vulkan-1.dll, which its own installer puts
# into the prefix (Red Dead Redemption 2; wine.inf says the same for RDR2.exe): only that loader
# takes the layer Rockstar's overlay comes in, and without the overlay the game never finished
# loading a story. Where a prefix has only Wine's loader all the same, that one has to do.
case ",${STEAM_COMPAT_CONFIG:-}," in
    *,nativevulkanloader,*)
        vulkan_dll="$prefix/drive_c/windows/system32/vulkan-1.dll"
        if [ -f "$vulkan_dll" ] && ! head -c 128 "$vulkan_dll" | grep -qa -e 'Wine builtin DLL' -e 'Wine placeholder DLL'; then
            WINEDLLOVERRIDES="$WINEDLLOVERRIDES;vulkan-1=n"
        else
            WINEDLLOVERRIDES="$WINEDLLOVERRIDES;vulkan-1=b"
        fi ;;
esac
# steam_api loads Valve's Windows client DLLs from Steam's folder in the prefix, and ntdll
# points their exports at lsteamclient
steam_in_pfx="$prefix/drive_c/Program Files (x86)/Steam"
mkdir -p "$steam_in_pfx"
for dll in steamclient.dll steamclient64.dll; do
    [ -f "$steam_in_pfx/$dll" ] && continue
    [ -f "$WIN_STEAM_DLLS/$dll" ] || die "no $dll in $WIN_STEAM_DLLS: copy Valve's Windows steamclient.dll and" \
        "steamclient64.dll there from the top folder of a Windows Steam install, or set WIN_STEAM_DLLS"
    cp "$WIN_STEAM_DLLS/$dll" "$steam_in_pfx/$dll"
done
# and Valve's overlay DLLs, which steam_api loads from there as well. The overlay itself does not
# draw (ntdll points these at lsteamclient too), but a game may look for the module: Call of Duty:
# Modern Warfare Remastered ends itself, without a word, when it is not in the process
for dll in GameOverlayRenderer.dll GameOverlayRenderer64.dll; do
    [ -f "$steam_in_pfx/$dll" ] && continue
    if [ -f "$WIN_STEAM_DLLS/$dll" ]; then
        cp "$WIN_STEAM_DLLS/$dll" "$steam_in_pfx/$dll"
    else
        echo "steamplay-run: no $dll in $WIN_STEAM_DLLS (\"steamplay steamclient --again\" fetches it); some games need it" >&2
    fi
done

# where each module is loaded, so that the PE addresses of a crash can be given their DLLs, and
# what a message box says, which is often all a game tells of what it could not do
export WINEDEBUG="${WINEDEBUG:-+loaddll,+msgbox}"
# and where ntdll leaves the stack of a thread that ran out of it (wine-stack.<pid>.<tid>.bin)
export WINE_STACK_DUMP_DIR="${WINE_STACK_DUMP_DIR:-$compat}"
# every half minute, what each of the game's processes did, for the record of the run beside the
# frame lines: about 0.1 ms of processor time a line, and some 10 ns a wineserver call or wait
export WINE_PROCESS_STATS="${WINE_PROCESS_STATS:-30}"
log "app $appid: $exe$([ $# -eq 0 ] || printf ' %q' "$@") (log: $logfile)"
# A game that hangs says nothing of where. Wine does say when a thread has waited a minute for a
# lock that another one holds: at that, where every thread of the game's processes is gets
# saved next to the log (macOS's sample), once per run. The watcher goes when this process,
# which becomes Wine's, does. It reads only what the log gained since its last look, from the
# 64 KB block that holds the last 4 KB it saw, for a line written in two parts: a game's log can
# grow to tens of MB, and reading all of it every two seconds came to 38 GB in an hour of Red
# Dead Redemption 2. dd, because macOS's tail -c +N takes 20 times longer for the same bytes;
# not a pipe, because with pipefail dd's broken pipe when grep finds the line would count as no
# match.
hang=${logfile%.log}.hang
rm -f "$hang".*.txt
(
    game_dir_win="Z:${game_dir//\//\\}\\"
    # this session's log, wherever a later start of the game has moved it
    own_log() {
        local f
        for f in "$logfile" "$prev_base".prev*.log; do
            [ "$(stat -f %i "$f" 2>/dev/null)" = "$log_inode" ] && { echo "$f"; return 0; }
        done
        return 1
    }
    # from here on: a "wait timed out" of wineboot or an install step above is not the game's
    seen=$(stat -f %z "$logfile" 2>/dev/null) || seen=0
    while sleep 2 && kill -0 $$ 2>/dev/null; do
        log_now=$(own_log) || continue
        size=$(stat -f %z "$log_now" 2>/dev/null) || continue
        [ "$size" -ge "$seen" ] || seen=0
        from=$((seen > 4096 ? (seen - 4096) / 65536 : 0))
        seen=$size
        grep -qa 'RtlpWaitForCriticalSection.*wait timed out' < <(dd if="$log_now" bs=65536 skip=$from 2>/dev/null) || continue
        for pid in $(ps -axo pid=,command= | grep -F -- "$game_dir_win" | grep -v ' grep ' | awk '{print $1}'); do
            /usr/bin/sample "$pid" 3 -file "$hang.$pid.txt" &
        done
        wait
        exit 0
    done
) </dev/null >/dev/null 2>&1 &
# When the session has ended, how long it ran and how it ended goes into SteamPlay's results,
# which "macos/steamplay discover" judges games by. "record --after" waits for this process, which
# becomes Wine's, from a process of its own, out of the game's process group: Steam ends that
# group when it ends a game (Stop, or Steam quitting) and when it tidies up after one, and a
# waiter in it went with it, so that such a run had no record.
started=$(date +%s)
# One notice when a newer Protium is out, once per version; the game does not wait for it
("$PROTIUM_PYTHON" "$SCRIPT_DIR/steamplay" version --notify) </dev/null >/dev/null 2>&1 &
STEAMPLAY_GAME_ENV=$game_env_text STEAMPLAY_LOG_INODE=$log_inode "$PROTIUM_PYTHON" "$SCRIPT_DIR/steamplay" \
    record --after $$ "$appid" "$started" "$logfile" </dev/null >/dev/null 2>&1 &
cd "$(dirname "$exe")"
# steam.exe starts the game by its full Windows path (Wine's Z: drive is the host's /). It is
# named by its own full path too, as Proton does: by its bare name Wine has start.exe look for
# it and wait for it, and steam.exe, which ends when no other program is left, waits for
# start.exe in turn. Nothing of the session then ever ends, and Steam goes on showing the game
# as running after it was quit.
exec "$WINE_INSTALL/bin/wine" 'c:\windows\system32\steam.exe' "Z:${exe//\//\\}" "$@" >&3 2>&3 3>&- </dev/null
