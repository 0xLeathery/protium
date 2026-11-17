#!/bin/bash
#
# Run a Windows game that Mac Steam installed, under the macOS Proton build, the way Steam Play
# runs one through Proton on Linux.
#
#   macos/steamplay-run.sh <app id> [game arguments...]
#
# Mac Steam downloads a Windows build when its download platform is forced (in its console:
# @sSteamCmdForcePlatformType windows, then app_install <app id>), but it neither shows the
# Steam Play settings nor launches a compatibility tool on macOS. This script does the launch:
# it finds the game through Steam's library folders and the app's manifest, gives it a prefix
# in <library>/steamapps/compatdata/<app id>/pfx as Proton does, puts Valve's Windows client
# DLLs where steam_api looks for them, and starts the game through Proton's steam.exe, so
# that lsteamclient connects it to the running Mac Steam (login, ownership, stats and
# playtime; not the overlay, which Steam would have to inject into the game's process).
#
# Environment overrides:
#   WINE_INSTALL    the bundle (default /Users/annon/projects/proton-macos-build/install-aarch64)
#   STEAM_ROOT      Mac Steam's data folder (default ~/Library/Application Support/Steam)
#   WIN_STEAM_DLLS  a folder with Valve's Windows steamclient.dll and steamclient64.dll, which
#                   Mac Steam does not ship (Linux Steam has them in legacycompat/)
#   GAME_EXE        the executable, relative to the install folder or as a full path, when the
#                   largest .exe in its top folder is not the game (macos/steamplay-launch gives
#                   the one Steam chose)
#   STEAMPLAY_LOG   where Wine's output goes (default <prefix>/../steamplay-run.log)

set -euo pipefail

WINE_INSTALL=${WINE_INSTALL:-/Users/annon/projects/proton-macos-build/install-aarch64}
STEAM_ROOT=${STEAM_ROOT:-$HOME/Library/Application Support/Steam}
WIN_STEAM_DLLS=${WIN_STEAM_DLLS:-/Volumes/Samsung T7/Windows Games/Steam}

die() { echo "steamplay-run.sh: error: $*" >&2; exit 1; }
log() { echo ":: $*" >&2; }

[ $# -ge 1 ] || die "usage: steamplay-run.sh <app id> [game arguments...]"
appid=$1; shift
[[ $appid =~ ^[0-9]+$ ]] || die "'$appid' is not an app id"
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
[ -f "$exe" ] || die "no game executable in $game_dir (set GAME_EXE)"

# Steam Play names the game's compatibility data folder itself; it is the same one
compat=${STEAM_COMPAT_DATA_PATH:-"$library/steamapps/compatdata/$appid"}
prefix="$compat/pfx"
mkdir -p "$prefix"
export WINEPREFIX="$prefix"
export STEAM_COMPAT_DATA_PATH="$compat"
export STEAM_COMPAT_CLIENT_INSTALL_PATH="$CLIENT_DIR"
export STEAM_COMPAT_INSTALL_PATH="$game_dir"
export STEAM_COMPAT_LIBRARY_PATHS="$library/steamapps"
export SteamAppId=$appid SteamGameId=$appid SteamOverlayGameId=$appid
export WINEDLLOVERRIDES="${WINEDLLOVERRIDES:-mscoree,mshtml=}"
unset VK_DRIVER_FILES VK_ICD_FILENAMES VK_ADD_DRIVER_FILES PROTON_DISABLE_LSTEAMCLIENT

if [ ! -f "$prefix/system.reg" ]; then
    log "creating the prefix in $prefix"
    "$WINE_INSTALL/bin/wine" wineboot -u >/dev/null 2>&1 || die "wineboot failed in $prefix"
fi
# steam_api loads Valve's Windows client DLLs from Steam's folder in the prefix, and ntdll
# points their exports at lsteamclient
steam_in_pfx="$prefix/drive_c/Program Files (x86)/Steam"
mkdir -p "$steam_in_pfx"
for dll in steamclient.dll steamclient64.dll; do
    [ -f "$steam_in_pfx/$dll" ] && continue
    [ -f "$WIN_STEAM_DLLS/$dll" ] || die "no $dll in $WIN_STEAM_DLLS (set WIN_STEAM_DLLS)"
    cp "$WIN_STEAM_DLLS/$dll" "$steam_in_pfx/$dll"
done

logfile=${STEAMPLAY_LOG:-$compat/steamplay-run.log}
log "app $appid: $exe (log: $logfile)"
cd "$(dirname "$exe")"
# steam.exe starts the game by its full Windows path (Wine's Z: drive is the host's /)
exec "$WINE_INSTALL/bin/wine" steam.exe "Z:${exe//\//\\}" "$@" >"$logfile" 2>&1 </dev/null
