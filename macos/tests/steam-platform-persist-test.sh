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
# Experiment 3, Steam Play itself: Mac Steam's CCompatManager is the one from Linux, and its
# constructor enables it only when Steam's platform is "linux" (steamclient.dylib, arm64,
# 0x6bab74..0x6bab90), which is why overrides and tool mappings did nothing on "windows" or
# "macos". So this tells Steam it is on Linux and lets two tools choose each game's build:
# proton-macos (from windows) and macos-native (from macos), both in macos/steamplay-tools.
#
#   steam-platform-persist-test.sh setup-register     Steam quit: every game aside, install the
#                                                     tools, switch to linux: does Steam register
#                                                     the tools, with nothing to lose?
#   steam-platform-persist-test.sh setup-steamplay    Steam quit: put the canaries back (IRON NEST,
#                                                     Left 4 Dead, Kerbal Space Program), switch to
#                                                     linux, install the tools, map IRON NEST, Left
#                                                     4 Dead and Just Die Already to proton-macos,
#                                                     Kerbal to macos-native, all other games to
#                                                     proton-macos, and take the steamplay-launch
#                                                     launch options out
#
# Reading "status" after experiment 3: "Registering tool proton-macos" and "macos-native" in the
# compatibility log; no "config changed" for IRON NEST, Just Die Already or Left 4 Dead (they keep
# their Windows depots); Kerbal changed to its Mac depot (220202), not a Linux one; after Play, the
# probe log names the tool Steam started and its verb. A Linux depot or removed files: stop.
#
# Result of experiment 3 (2026-11-17): Steam Play does switch on with "linux": the compatibility
# log shows Valve's own tool list processed (Proton versions registered from app 891390), the
# Steam Linux Runtime mapped to Valve's games, and our mappings read ("Mapping AppID 500 to tool
# proton-macos"). But Steam never scanned compatibilitytools.d (no "Processing local tool list" or
# "No local tool list detected" in any log), so our two tools did not exist for it, and it took
# the games mapped to them for native Linux ones: Left 4 Dead lost its Windows depot 503 and Just
# Die Already all of its files, within four seconds of startup. Back on the windows switch, Steam
# restored both at its next start. What starts the local tool scan on the Mac client
# (CLoadLocalToolListJob, base folder from 0xa494e8 + "/compatibilitytools.d") is not known.
#
# Second attempt, setup-register (2026-11-17 12:02 and 12:07): Steam's tool scan looks in
# /usr/local/share/steam/compatibilitytools.d (also /usr/share/steam, the folders of
# $STEAM_EXTRA_COMPAT_TOOLS_PATHS and the folder of its client library inside the app bundle), and
# reads steam_dev.cfg only next to its executables inside the app bundle: with the linux line in
# the Steam root's copy alone it stayed on macos ("Ignoring tool proton-macos as it's for a
# different target platform linux"). With the line in the bundle's copy and the tools in
# /usr/local: "Registering tool macos-native, AppID 0", "Registering tool proton-macos, AppID 0",
# "Loaded manifest for tool ..." for both, and Valve's tool list processed. Every game was aside.
#
# For all:
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
# Result of experiment 2 (2026-11-17): it works. Four seconds after Steam started, with nothing
# typed into its console, the content log had "AppID 500 config changed : added depots 503" and
# "removed depots 515" (Left 4 Dead back on its Windows depot, binkw32.dll back a second later) and
# "AppID 979070 config changed : added depots 979071" (Just Die Already, wiped before, downloading
# again by itself). With the switch on, Play on IRON NEST's own library entry, whose launch option
# was macos/steamplay-launch (macos/steamplay hook), started the game through that script. Which
# of the two steam_dev.cfg files Steam reads is not yet known: both were written.
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
CANARY_APPS=${CANARY_APPS:-"2950790 500 220200"}
STATE_DIR=$BUILD_ROOT/steamplay/persist-test
CFG_LINE='@sSteamCmdForcePlatformType windows'
CFG_ANY='^@sSteamCmdForcePlatformType '
STEAMPLAY=$(cd "$(dirname "$0")/.." && pwd)/steamplay
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
    mkdir -p "$STATE_DIR/manifests" "$STATE_DIR/downloads"
    date '+%Y-%m-%d %H:%M:%S' > "$STATE_DIR/setup-time"
    # a later experiment before restore adds to what is aside; what is aside is not in a library
    [ -s "$STATE_DIR/moved.tsv" ] || : > "$STATE_DIR/moved.tsv"
    n=$(wc -l < "$STATE_DIR/moved.tsv" | tr -d ' ')
    while IFS= read -r library; do
        for manifest in "$library"/steamapps/appmanifest_*.acf; do
            [ -f "$manifest" ] || continue
            id=$(basename "$manifest" .acf); id=${id#appmanifest_}
            case "$keep" in *" $id "*) echo "left       $id  $(app_name "$manifest")"; continue ;; esac
            dest="$STATE_DIR/manifests/$n-$(basename "$manifest")"
            [ ! -e "$dest" ] || dest="$dest.$(date +%s)"
            mv "$manifest" "$dest"
            printf '%s\t%s\n' "$dest" "$manifest" >> "$STATE_DIR/moved.tsv"
            echo "set aside  $id  $(app_name "$dest")"
            for item in "$library/steamapps/downloading/$id" "$library/steamapps/temp/$id" \
                        "$library"/steamapps/downloading/state_"${id}"_*.patch; do
                [ -e "$item" ] || continue
                kind=$(basename "$(dirname "$item")")
                dest="$STATE_DIR/downloads/$n-$kind-$(basename "$item")"
                [ ! -e "$dest" ] || dest="$dest.$(date +%s)"
                mv "$item" "$dest"
                printf '%s\t%s\n' "$dest" "$item" >> "$STATE_DIR/moved.tsv"
                echo "set aside  $id  its $kind/$(basename "$item")"
            done
        done
        n=$((n + 1))
    done < <(libraries)
    date '+%Y-%m-%d %H:%M:%S' > "$STATE_DIR/setup-time"
}

# Puts the manifests of the given app ids, and what was downloaded for them, back from aside
put_back() {
    local from to id mine
    : > "$STATE_DIR/moved.tsv.new"
    while IFS=$'\t' read -r from to; do
        mine=
        for id in "$@"; do
            case $to in
                */appmanifest_"$id".acf|*/downloading/"$id"|*/temp/"$id"|*/downloading/state_"$id"_*) mine=1 ;;
            esac
        done
        if [ -n "$mine" ] && [ ! -e "$to" ]; then
            mv "$from" "$to"
            echo "put back   $to"
        else
            [ -z "$mine" ] || echo "kept aside $from: $to exists"
            printf '%s\t%s\n' "$from" "$to" >> "$STATE_DIR/moved.tsv.new"
        fi
    done < "$STATE_DIR/moved.tsv"
    mv "$STATE_DIR/moved.tsv.new" "$STATE_DIR/moved.tsv"
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
setup-steamplay)
    steam_running && die "quit Steam first (Steam > Quit Steam)"
    [ -s "$STATE_DIR/moved.tsv" ] || die "run setup-overrides or setup-cfg first, so that the other games are aside"
    # The canaries back from aside: IRON NEST (Windows only), Left 4 Dead (Windows and a 32-bit
    # Mac build) and Kerbal Space Program (Windows, Mac and Linux builds)
    # shellcheck disable=SC2086
    put_back $CANARY_APPS
    for cfg in "${CFG_FILES[@]}"; do
        [ -d "$(dirname "$cfg")" ] || continue
        { grep -v "$CFG_ANY" "$cfg" 2>/dev/null || true; echo '@sSteamCmdForcePlatformType linux'; } > "$cfg.tmp"
        mv "$cfg.tmp" "$cfg"
        echo "linux in   $cfg"
    done
    "$STEAMPLAY" tools
    "$STEAMPLAY" map 2950790 proton-macos 979070 proton-macos 500 proton-macos 220200 macos-native 0 proton-macos
    "$STEAMPLAY" hook --remove 2950790 979070
    date '+%Y-%m-%d %H:%M:%S' > "$STATE_DIR/setup-time"
    echo "experiment: steamplay" > "$STATE_DIR/experiment"
    echo "Now start Steam, wait a minute, and run: $0 status"
    ;;
setup-register)
    # Step 1 of the second Steam Play attempt: are tools in /usr/local/share/steam/
    # compatibilitytools.d registered? Every game is set aside first, so there is nothing to lose.
    steam_running && die "quit Steam first (Steam > Quit Steam)"
    "$STEAMPLAY" tools || exit 1
    set_aside_except
    # Steam reads only the steam_dev.cfg next to its executables, inside its app bundle: with the
    # line in the Steam root's copy alone (2026-11-17 12:02), Steam stayed on macos.
    for cfg in "${CFG_FILES[@]}"; do
        [ -d "$(dirname "$cfg")" ] || continue
        { grep -v "$CFG_ANY" "$cfg" 2>/dev/null || true; echo '@sSteamCmdForcePlatformType linux'; } > "$cfg.tmp"
        mv "$cfg.tmp" "$cfg"
        echo "linux in   $cfg"
    done
    date '+%Y-%m-%d %H:%M:%S' > "$STATE_DIR/setup-time"
    echo "experiment: register" > "$STATE_DIR/experiment"
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
        line=$(grep "$CFG_ANY" "$cfg" 2>/dev/null || true)
        [ -n "$line" ] && echo "switch     $line  ($cfg)"
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
    echo "== Steam's compatibility log since setup: tools, tool lists, our mappings"
    if [ -f "$STEAM_ROOT/logs/compat_log.txt" ]; then
        since_setup "$since" "$STEAM_ROOT/logs/compat_log.txt" \
            | LC_ALL=C grep -E "Client version|proton-macos|macos-native|tool list|Ignoring tool|Unmapping|Processing" \
            | LC_ALL=C grep -v "Registering tool proton_[0-9]|Registering tool proton_experimental" | cut -c1-200 | grep . \
            || echo "  (nothing)"
        echo "  ($(since_setup "$since" "$STEAM_ROOT/logs/compat_log.txt" | LC_ALL=C grep -c "Registering tool") tools registered in all)"
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
        grep -v "$CFG_ANY" "$cfg" > "$cfg.tmp" || true
        if [ -s "$cfg.tmp" ]; then mv "$cfg.tmp" "$cfg"; else rm -f "$cfg.tmp" "$cfg"; fi
        echo "switch out of $cfg"
    done
    ;;
*)
    die "usage: $0 setup-overrides | setup-cfg | setup-steamplay | status | restore | clean"
    ;;
esac
