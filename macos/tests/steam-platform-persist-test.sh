#!/bin/bash
#
# Experiments on Mac Steam: how can it be made to keep a game's Windows build across a restart?
#
# Why it matters: Mac Steam only takes this Mac for a Windows machine while the console switch
# @sSteamCmdForcePlatformType windows is on, and forgets it when it quits. At its next start it
# "repairs" Windows installs: it swaps a game's Windows depots for its Mac ones (Left 4 Dead lost
# its Windows binaries) and updates a Windows-only game to no depots at all, deleting every file
# (Just Die Already and GTFO, twice). Both experiments here restart Steam, so each first sets the
# manifests of the installed games it does not need aside, where Steam cannot see them, together
# with what it has downloaded for them so far: Steam takes those games for not installed and
# leaves their folders alone.
#
# Experiment 1, the per-game override Steam Play uses on Linux. Steam's client for the Mac has the
# same code (CCompatManager): it reads userdata/<user>/config/compat.vdf, a list of
# "platform_overrides" (app id, "src" platform, "dest" platform), and its platform names are
# windows, macos, linux. So an override from windows to macos may be all it needs to keep (and
# fetch) a game's Windows depots, and, with a compatibility tool mapped to the game, to start
# that tool for Play. The probe tool of an earlier test (compatibilitytools.d/proton-macos-probe,
# mapped to IRON NEST) named its target platform "osx"; this makes it "macos".
#
#   steam-platform-persist-test.sh setup-overrides   Steam quit: set the other manifests aside,
#                                                     write compat.vdf, fix the probe tool
#
# Experiment 2, the startup configuration file steam_dev.cfg holding the console switch itself
# (for every game at once, Mac games included):
#
#   steam-platform-persist-test.sh setup-cfg          Steam quit: set all manifests but the
#                                                     canary's aside, write the switch
#
# For both:
#
#   steam-platform-persist-test.sh status             what Steam did since setup (reads only)
#   steam-platform-persist-test.sh restore            Steam quit: put the manifests back
#   steam-platform-persist-test.sh clean              Steam quit: remove compat.vdf's overrides
#                                                     and the switch from steam_dev.cfg
#
# A run: quit Steam, a setup, start Steam and let it settle for a minute, "status", and for
# experiment 1 press Play on IRON NEST's own library entry and run "status" again; then quit
# Steam and "restore". While manifests are aside, do not press Install on those games. The second
# setup can follow the first without a restore between them ("clean" first, so that one experiment
# does not hide the other): the manifests stay aside.
#
# Result of experiment 1 (2026-11-17): nothing. Left 4 Dead kept its Mac depot at startup, Just Die
# Already was not asked for again, and Play on IRON NEST failed with AppError_29 (Invalid
# platform) without the probe tool being started. The Mac client does not act on overrides.
#
# Reading "status" after experiment 1 (Left 4 Dead has its Mac depot 515 when it starts):
#   - "AppID 500 config changed : added depots 503" (its Windows depot): the override works at
#     startup. A download starting for Just Die Already says the same for a Windows-only game.
#   - "platform override cache: ignore bad entry" in the compatibility log: the names are wrong.
#   - a new entry in the probe's log after Play: Steam starts a mapped tool on the Mac.
#   - none of these: the Mac client does not act on overrides.
# After experiment 2: "config changed" for the canary in the other direction than expected, or
# nothing, as the header of each section printed by "status" explains.
#
# Environment: STEAM_ROOT (default ~/Library/Application Support/Steam), BUILD_ROOT (default
# /Users/annon/projects/proton-macos-build; state in $BUILD_ROOT/steamplay/persist-test),
# OVERRIDE_APPS (default "500 979070 2950790": Left 4 Dead, Just Die Already, IRON NEST), CANARY
# (default 500), and PERSIST_TEST_FAKE_STEAM=1 to try the script on a copy of a Steam folder
# while Steam runs.

set -euo pipefail

BUILD_ROOT=${BUILD_ROOT:-/Users/annon/projects/proton-macos-build}
STEAM_ROOT=${STEAM_ROOT:-$HOME/Library/Application Support/Steam}
OVERRIDE_APPS=${OVERRIDE_APPS:-"500 979070 2950790"}
CANARY=${CANARY:-500}
STATE_DIR=$BUILD_ROOT/steamplay/persist-test
CFG_LINE='@sSteamCmdForcePlatformType windows'
CFG_FILES=("$STEAM_ROOT/steam_dev.cfg" "$STEAM_ROOT/Steam.AppBundle/Steam/Contents/MacOS/steam_dev.cfg")
PROBE_VDF="$STEAM_ROOT/compatibilitytools.d/proton-macos-probe/compatibilitytool.vdf"
PROBE_LOG=$BUILD_ROOT/evidence/steamplay/probe.log

die() { echo "steam-platform-persist-test.sh: error: $*" >&2; exit 1; }
steam_running() { [ -z "${PERSIST_TEST_FAKE_STEAM:-}" ] && pgrep -x steam_osx >/dev/null; }
libraries() { sed -n 's/^[[:space:]]*"path"[[:space:]]*"\(.*\)"$/\1/p' "$STEAM_ROOT/steamapps/libraryfolders.vdf"; }
app_name() { sed -n 's/^[[:space:]]*"name"[[:space:]]*"\(.*\)"$/\1/p' "$1" | head -1; }
# The signed-in user's config folder: the one whose localconfig.vdf Steam wrote last
user_config() {
    local newest=
    for cfg in "$STEAM_ROOT"/userdata/*/config/localconfig.vdf; do
        [ -f "$cfg" ] || continue
        if [ -z "$newest" ] || [ "$cfg" -nt "$newest" ]; then newest=$cfg; fi
    done
    [ -n "$newest" ] && dirname "$newest"
}
since_setup() { LC_ALL=C awk -v s="[$1]" 'substr($0, 1, 21) >= s' "$2"; }

# Sets every installed game's manifest aside, except those of the app ids given, and with it what
# Steam has downloaded for the game so far (downloading/<id>, its state files and temp/<id>)
set_aside_except() {
    local keep=" $* 228980 " n=0 library manifest id dest item kind   # 228980: Steam's shared redistributables
    mkdir -p "$STATE_DIR"
    date '+%Y-%m-%d %H:%M:%S' > "$STATE_DIR/setup-time"
    if [ -s "$STATE_DIR/moved.tsv" ]; then   # a second experiment before restore: nothing more to move
        echo "manifests are already set aside ($(grep -c 'appmanifest_' "$STATE_DIR/moved.tsv") games): left as they are"
        return 0
    fi
    mkdir -p "$STATE_DIR/manifests" "$STATE_DIR/downloads"
    : > "$STATE_DIR/moved.tsv"
    while IFS= read -r library; do
        for manifest in "$library"/steamapps/appmanifest_*.acf; do
            [ -f "$manifest" ] || continue
            id=$(basename "$manifest" .acf); id=${id#appmanifest_}
            case "$keep" in *" $id "*) echo "left       $id  $(app_name "$manifest")"; continue ;; esac
            dest="$STATE_DIR/manifests/$n-$(basename "$manifest")"
            mv "$manifest" "$dest"
            printf '%s\t%s\n' "$dest" "$manifest" >> "$STATE_DIR/moved.tsv"
            echo "set aside  $id  $(app_name "$dest")"
            for item in "$library/steamapps/downloading/$id" "$library/steamapps/temp/$id" \
                        "$library"/steamapps/downloading/state_"${id}"_*.patch; do
                [ -e "$item" ] || continue
                kind=$(basename "$(dirname "$item")")
                dest="$STATE_DIR/downloads/$n-$kind-$(basename "$item")"
                mv "$item" "$dest"
                printf '%s\t%s\n' "$dest" "$item" >> "$STATE_DIR/moved.tsv"
                echo "set aside  $id  its $kind/$(basename "$item")"
            done
        done
        n=$((n + 1))
    done < <(libraries)
    date '+%Y-%m-%d %H:%M:%S' > "$STATE_DIR/setup-time"
}

[ -f "$STEAM_ROOT/steamapps/libraryfolders.vdf" ] || die "no Steam library list in $STEAM_ROOT"

case ${1:-} in
setup-overrides)
    steam_running && die "quit Steam first (Steam > Quit Steam)"
    config=$(user_config) || true
    [ -n "$config" ] || die "no signed-in user's config folder in $STEAM_ROOT/userdata"
    # shellcheck disable=SC2086
    set_aside_except $OVERRIDE_APPS
    [ ! -f "$config/compat.vdf" ] || cp -p "$config/compat.vdf" "$STATE_DIR/compat.vdf.before"
    {
        printf '"platform_overrides"\n{\n'
        for id in $OVERRIDE_APPS; do
            printf '\t"%s"\n\t{\n\t\t"dest"\t\t"macos"\n\t\t"src"\t\t"windows"\n\t}\n' "$id"
        done
        printf '}\n'
    } > "$config/compat.vdf"
    echo "overrides  $config/compat.vdf (windows to macos for: $OVERRIDE_APPS)"
    if [ -f "$PROBE_VDF" ] && grep -q '"to_oslist"[[:space:]]*"osx"' "$PROBE_VDF"; then
        cp -p "$PROBE_VDF" "$STATE_DIR/compatibilitytool.vdf.before"
        sed -i '' 's/"to_oslist"\([[:space:]]*\)"osx"/"to_oslist"\1"macos"/' "$PROBE_VDF"
        echo "probe tool now targets macos ($PROBE_VDF)"
    fi
    echo "experiment: overrides" > "$STATE_DIR/experiment"
    echo "Now start Steam, wait a minute, and run: $0 status"
    ;;
setup-cfg)
    steam_running && die "quit Steam first (Steam > Quit Steam)"
    set_aside_except "$CANARY"
    for cfg in "${CFG_FILES[@]}"; do
        [ -d "$(dirname "$cfg")" ] || continue
        grep -qxF "$CFG_LINE" "$cfg" 2>/dev/null || printf '%s\n' "$CFG_LINE" >> "$cfg"
        echo "switch in  $cfg"
    done
    echo "experiment: cfg" > "$STATE_DIR/experiment"
    echo "Now start Steam, wait a minute, and run: $0 status"
    ;;
status)
    steam_running && echo "Steam is running" || echo "Steam is not running"
    [ -f "$STATE_DIR/experiment" ] && cat "$STATE_DIR/experiment"
    config=$(user_config) || true
    if [ -n "$config" ] && [ -f "$config/compat.vdf" ]; then
        echo "overrides in $config/compat.vdf: $(sed -n 's/^\t"\([0-9]*\)"$/\1/p' "$config/compat.vdf" | tr '\n' ' ')"
    else
        echo "no compat.vdf"
    fi
    [ -f "$PROBE_VDF" ] && echo "probe tool: $(grep -o '"to_oslist"[[:space:]]*"[a-z]*"' "$PROBE_VDF" | tr -s '[:space:]' ' ')"
    for cfg in "${CFG_FILES[@]}"; do
        grep -qxF "$CFG_LINE" "$cfg" 2>/dev/null && echo "switch in  $cfg"
    done
    aside=0; [ -s "$STATE_DIR/moved.tsv" ] && aside=$(wc -l < "$STATE_DIR/moved.tsv" | tr -d ' ')
    echo "manifests set aside: $aside"
    while IFS= read -r library; do
        for manifest in "$library"/steamapps/appmanifest_*.acf; do
            [ -f "$manifest" ] || continue
            id=$(basename "$manifest" .acf)
            depots=$(sed -n '/"InstalledDepots"/,/^\t}/p' "$manifest" | sed -n 's/^\t\t"\([0-9]*\)"$/\1/p' | tr '\n' ' ')
            echo "installed  ${id#appmanifest_}  $(app_name "$manifest")  depots: ${depots:-none}"
        done
    done < <(libraries)
    [ -f "$STATE_DIR/setup-time" ] || { echo "no setup has run"; exit 0; }
    since=$(cat "$STATE_DIR/setup-time")
    echo "== Steam's content log since setup ($since): depots and updates"
    if [ -f "$STEAM_ROOT/logs/content_log.txt" ]; then
        since_setup "$since" "$STEAM_ROOT/logs/content_log.txt" \
            | LC_ALL=C grep -E "config changed|update started|finished update|update canceled|finished uninstall" \
            | cut -c1-200 || echo "  (nothing)"
    fi
    echo "== Steam's compatibility log since setup"
    if [ -f "$STEAM_ROOT/logs/compat_log.txt" ]; then
        since_setup "$since" "$STEAM_ROOT/logs/compat_log.txt" | cut -c1-200 | grep . || echo "  (nothing)"
    fi
    echo "== the probe tool's log since setup (an entry means Steam started the tool)"
    if [ -f "$PROBE_LOG" ]; then
        LC_ALL=C awk -v s="=== $since" '/^=== / { on = (substr($0, 1, 23) >= s) } on' "$PROBE_LOG" | cut -c1-200 | grep . || echo "  (nothing)"
    else
        echo "  (no $PROBE_LOG)"
    fi
    ;;
restore)
    steam_running && die "quit Steam first (Steam > Quit Steam)"
    [ -s "$STATE_DIR/moved.tsv" ] || die "no manifests are set aside"
    left=
    while IFS=$'\t' read -r from to; do
        if [ -e "$to" ]; then echo "kept aside $from: $to exists now"; left=1; continue; fi
        mv "$from" "$to"
        case $to in *.acf) echo "put back   $(basename "$to")  $(app_name "$to")" ;; *) echo "put back   $to" ;; esac
    done < "$STATE_DIR/moved.tsv"
    [ -n "$left" ] || rm "$STATE_DIR/moved.tsv"
    ;;
clean)
    steam_running && die "quit Steam first (Steam > Quit Steam)"
    config=$(user_config) || true
    if [ -n "$config" ] && [ -f "$config/compat.vdf" ]; then
        rm "$config/compat.vdf"
        [ ! -f "$STATE_DIR/compat.vdf.before" ] || mv "$STATE_DIR/compat.vdf.before" "$config/compat.vdf"
        echo "overrides out of $config/compat.vdf"
    fi
    for cfg in "${CFG_FILES[@]}"; do
        [ -f "$cfg" ] || continue
        grep -vxF "$CFG_LINE" "$cfg" > "$cfg.tmp" || true
        if [ -s "$cfg.tmp" ]; then mv "$cfg.tmp" "$cfg"; else rm -f "$cfg.tmp" "$cfg"; fi
        echo "switch out of $cfg"
    done
    ;;
*)
    die "usage: $0 setup-overrides | setup-cfg | status | restore | clean"
    ;;
esac
