#!/bin/bash
#
# An experiment on Mac Steam: does its startup configuration file, steam_dev.cfg, keep the switch
# that makes it treat this Mac as a Windows machine (@sSteamCmdForcePlatformType windows, typed
# into its console until now) across a restart?
#
# Why it matters: without the switch Mac Steam "repairs" Windows installs when it starts. It swaps
# a game's Windows depots for its Mac ones (Left 4 Dead lost its Windows binaries) and updates a
# Windows-only game to no depots at all, deleting every file (Just Die Already). A restart that
# forgets the switch is therefore destructive, and this experiment has to restart Steam. So it
# first sets the manifests of all installed games but one aside, where Steam cannot see them:
# Steam then takes those games for not installed and leaves their folders alone. The one left,
# the canary, shows what a restart does.
#
#   steam-platform-persist-test.sh setup     Steam quit: set the manifests aside (all but the
#                                            canary's) and write the switch into steam_dev.cfg
#   steam-platform-persist-test.sh status    what Steam did to the canary since setup (reads only)
#   steam-platform-persist-test.sh restore   Steam quit: put the manifests back
#   steam-platform-persist-test.sh clean-cfg Steam quit: take the switch out of steam_dev.cfg
#
# The run: quit Steam, "setup", start Steam and let it settle for a minute, "status", quit Steam,
# "restore", start Steam. While the manifests are aside, do not press Install on those games.
#
# Reading "status": if the canary's depots were changed after setup ("config changed : added /
# removed depots"), steam_dev.cfg did not keep the switch (pause or cancel the canary's download in
# Steam: its Windows files are only replaced once that finishes). No such line and no update
# started for it means the switch held at startup.
#
# steam_dev.cfg is written in both places Steam might read it: its data folder and the folder of
# its executables.
#
# Environment: STEAM_ROOT (default ~/Library/Application Support/Steam), BUILD_ROOT (default
# /Users/annon/projects/proton-macos-build; the manifests wait in $BUILD_ROOT/steamplay/persist-test),
# CANARY (app id, default 500, Left 4 Dead: it has Windows and Mac depots), and
# PERSIST_TEST_FAKE_STEAM=1 to try the script on a copy of a Steam folder while Steam runs.

set -euo pipefail

BUILD_ROOT=${BUILD_ROOT:-/Users/annon/projects/proton-macos-build}
STEAM_ROOT=${STEAM_ROOT:-$HOME/Library/Application Support/Steam}
CANARY=${CANARY:-500}
KEEP="$CANARY 228980"   # the canary, and Steam's own shared redistributables
STATE_DIR=$BUILD_ROOT/steamplay/persist-test
CFG_LINE='@sSteamCmdForcePlatformType windows'
CFG_FILES=("$STEAM_ROOT/steam_dev.cfg" "$STEAM_ROOT/Steam.AppBundle/Steam/Contents/MacOS/steam_dev.cfg")

die() { echo "steam-platform-persist-test.sh: error: $*" >&2; exit 1; }
steam_running() { [ -z "${PERSIST_TEST_FAKE_STEAM:-}" ] && pgrep -x steam_osx >/dev/null; }
libraries() { sed -n 's/^[[:space:]]*"path"[[:space:]]*"\(.*\)"$/\1/p' "$STEAM_ROOT/steamapps/libraryfolders.vdf"; }
app_name() { sed -n 's/^[[:space:]]*"name"[[:space:]]*"\(.*\)"$/\1/p' "$1" | head -1; }

[ -f "$STEAM_ROOT/steamapps/libraryfolders.vdf" ] || die "no Steam library list in $STEAM_ROOT"

case ${1:-} in
setup)
    steam_running && die "quit Steam first (Steam > Quit Steam)"
    [ ! -s "$STATE_DIR/moved.tsv" ] || die "manifests are already set aside in $STATE_DIR; run restore first"
    canary=
    mkdir -p "$STATE_DIR/manifests"
    : > "$STATE_DIR/moved.tsv"
    n=0
    while IFS= read -r library; do
        for manifest in "$library"/steamapps/appmanifest_*.acf; do
            [ -f "$manifest" ] || continue
            id=$(basename "$manifest" .acf); id=${id#appmanifest_}
            [ "$id" = "$CANARY" ] && canary=$manifest
            case " $KEEP " in *" $id "*) continue ;; esac
            dest="$STATE_DIR/manifests/$n-$(basename "$manifest")"
            mv "$manifest" "$dest"
            printf '%s\t%s\n' "$dest" "$manifest" >> "$STATE_DIR/moved.tsv"
            echo "set aside  $id  $(app_name "$dest")"
        done
        n=$((n + 1))
    done < <(libraries)
    [ -n "$canary" ] || echo "warning: the canary, app $CANARY, is not installed: a restart will show nothing"
    for cfg in "${CFG_FILES[@]}"; do
        [ -d "$(dirname "$cfg")" ] || continue
        grep -qxF "$CFG_LINE" "$cfg" 2>/dev/null || printf '%s\n' "$CFG_LINE" >> "$cfg"
        echo "switch in  $cfg"
    done
    date '+%Y-%m-%d %H:%M:%S' > "$STATE_DIR/setup-time"
    echo "Now start Steam, wait a minute, and run: $0 status"
    ;;
status)
    steam_running && echo "Steam is running" || echo "Steam is not running"
    for cfg in "${CFG_FILES[@]}"; do
        grep -qxF "$CFG_LINE" "$cfg" 2>/dev/null && echo "switch in  $cfg" || echo "no switch  $cfg"
    done
    aside=0; [ -s "$STATE_DIR/moved.tsv" ] && aside=$(wc -l < "$STATE_DIR/moved.tsv" | tr -d ' ')
    echo "manifests set aside: $aside"
    while IFS= read -r library; do
        for manifest in "$library"/steamapps/appmanifest_*.acf; do
            [ -f "$manifest" ] || continue
            id=$(basename "$manifest" .acf)
            echo "installed  ${id#appmanifest_}  $(app_name "$manifest")  ($library)"
        done
    done < <(libraries)
    [ -f "$STATE_DIR/setup-time" ] || { echo "setup has not run"; exit 0; }
    since=$(cat "$STATE_DIR/setup-time")
    log="$STEAM_ROOT/logs/content_log.txt"
    echo "Steam's content log since setup ($since):"
    if [ -f "$log" ]; then
        LC_ALL=C awk -v s="[$since]" 'substr($0, 1, 21) >= s' "$log" \
            | LC_ALL=C grep -E "config changed|update started|finished update|update canceled|finished uninstall" \
            | cut -c1-200 || echo "  (nothing about depots or updates)"
    else
        echo "  (no $log)"
    fi
    ;;
restore)
    steam_running && die "quit Steam first (Steam > Quit Steam)"
    [ -s "$STATE_DIR/moved.tsv" ] || die "no manifests are set aside"
    left=
    while IFS=$'\t' read -r from to; do
        if [ -e "$to" ]; then echo "kept aside $from: $to exists now"; left=1; continue; fi
        mv "$from" "$to"
        echo "put back   $(basename "$to")  $(app_name "$to")"
    done < "$STATE_DIR/moved.tsv"
    [ -n "$left" ] || rm "$STATE_DIR/moved.tsv"
    ;;
clean-cfg)
    steam_running && die "quit Steam first (Steam > Quit Steam)"
    for cfg in "${CFG_FILES[@]}"; do
        [ -f "$cfg" ] || continue
        grep -vxF "$CFG_LINE" "$cfg" > "$cfg.tmp" || true
        if [ -s "$cfg.tmp" ]; then mv "$cfg.tmp" "$cfg"; else rm -f "$cfg.tmp" "$cfg"; fi
        echo "switch out of $cfg"
    done
    ;;
*)
    die "usage: $0 setup | status | restore | clean-cfg"
    ;;
esac
