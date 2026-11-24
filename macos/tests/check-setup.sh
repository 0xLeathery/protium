#!/bin/bash
#
# Checks what "Set up Steam" does on a Steam it cannot set up, the guard's limit, what happens
# when Protium.app is deleted without "Uninstall", and the diagnostics file.
#
#   macos/tests/check-setup.sh
#
# It works in $BUILD_ROOT/evidence/setup/ on made-up Steam folders and on a copy of this Mac's
# Steam settings (when there is a Steam), never on Steam itself, the real tools folder or the
# guard launchd runs: STEAM_ROOT, STEAMPLAY_HOME, STEAMPLAY_TOOLS_DIR, STEAMPLAY_GUARD_LOG and
# STEAMPLAY_DIAGNOSE_DIR point into the folder and STEAMPLAY_FAKE_STEAM is set.
#   never-opened   no Steam folder at all
#   first-start    a Steam folder without its app cache (issue #2: a Steam nobody signed in to)
#   copy           this Mac's config, app cache, library list and users' config
# Prints PASS or FAIL per case; exit status 1 when one failed.
#
# Environment overrides: BUILD_ROOT, REAL_STEAM (default ~/Library/Application Support/Steam).

set -u
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
MACOS_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
BUILD_ROOT=${BUILD_ROOT:-$HOME/projects/proton-macos-build}
REAL_STEAM=${REAL_STEAM:-$HOME/Library/Application Support/Steam}
E=$BUILD_ROOT/evidence/setup
rm -rf "$E"
mkdir -p "$E/first-start/config" "$E/home" "$E/tools" "$E/logs"
export STEAMPLAY_FAKE_STEAM=1 STEAMPLAY_HOME=$E/home STEAMPLAY_TOOLS_DIR=$E/tools
export STEAMPLAY_GUARD_LOG=$E/logs/guard.log STEAMPLAY_DIAGNOSE_DIR=$E/diagnostics

FAILED=0
pass() { echo "PASS  $1: $2"; }
fail() { echo "FAIL  $1: $2"; FAILED=1; }
steamplay() { /usr/bin/python3 -B "$MACOS_DIR/steamplay" "$@"; }

# 1. a Steam that cannot be set up: one sentence, status 1, no traceback; uninstall goes through
for root in never-opened first-start; do
    export STEAM_ROOT=$E/$root
    for cmd in "setup" "setup --check" "setup --dry-run" "status"; do
        out=$(steamplay $cmd 2>&1); status=$?
        name="$root/${cmd// /}"
        if [ $status = 1 ] && [ "$(echo "$out" | wc -l)" -eq 1 ] && echo "$out" | grep -q "press Set up Steam again" \
                && ! echo "$out" | grep -q Traceback; then
            pass "$name" "$(echo "$out" | cut -c1-90)"
        else
            fail "$name" "status $status: $(echo "$out" | tail -2 | tr '\n' ' ' | cut -c1-200)"
        fi
    done
    out=$(steamplay uninstall 2>&1) && pass "$root/uninstall" "goes through" || fail "$root/uninstall" "$(echo "$out" | tail -1)"
    out=$(steamplay diagnose 2>&1) && [ -f "${out#diagnostics saved: }" ] && pass "$root/diagnose" "a file is written" \
        || fail "$root/diagnose" "$(echo "$out" | tail -1)"
done

if [ ! -f "$REAL_STEAM/appcache/appinfo.vdf" ]; then
    echo "SKIP  the rest: no Steam on this Mac to copy the settings of"
    exit $FAILED
fi
C=$E/copy
mkdir -p "$C/appcache" "$C/steamapps" "$C/logs" "$C/Steam.AppBundle/Steam/Contents/MacOS"
cp -R "$REAL_STEAM/config" "$C/config"
cp "$REAL_STEAM/appcache/appinfo.vdf" "$C/appcache/"
cp "$REAL_STEAM"/steamapps/*.vdf "$REAL_STEAM"/steamapps/*.acf "$C/steamapps/" 2>/dev/null
for u in "$REAL_STEAM"/userdata/*/; do
    [ -d "$u/config" ] && mkdir -p "$C/userdata/$(basename "$u")" && cp -R "$u/config" "$C/userdata/$(basename "$u")/config"
done
export STEAM_ROOT=$C

# 2. a Steam that can: setup, and a fault nobody foresaw told in one line
out=$(steamplay setup 2>&1); status=$?
[ $status = 0 ] && echo "$out" | grep -q "^Steam is set up" && grep -q "^@sSteamCmdForcePlatformType linux" "$C/steam_dev.cfg" \
    && pass copy/setup "$(echo "$out" | head -1 | cut -c1-80)" || fail copy/setup "status $status: $(echo "$out" | tail -1)"
mkdir -p "$E/broken" && cp -R "$C/" "$E/broken/" && head -c 5000 "$C/appcache/appinfo.vdf" >"$E/broken/appcache/appinfo.vdf"
out=$(STEAM_ROOT=$E/broken steamplay setup --dry-run 2>&1); status=$?
[ $status = 1 ] && [ "$(echo "$out" | wc -l)" -eq 2 ] && echo "$out" | grep -q "^Something went wrong" && grep -q Traceback "$E/logs/steamplay-error.log" \
    && pass broken-cache "one line, and the traceback in steamplay-error.log" || fail broken-cache "status $status: $(echo "$out" | tail -2 | tr '\n' ' ' | cut -c1-200)"

# 3. the guard stops a Steam that turns the tools down three times, then lets it run
session() { printf '[%s] Client version: 1\n[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >>"$C/logs/compat_log.txt"; }
survived=""
for i in 1 2 3 4; do
    session "Ignoring tool proton-macos because of its platform"
    sleep 60 & pid=$!
    STEAMPLAY_FAKE_RUNNING_PID=$pid steamplay guard >/dev/null 2>&1
    if kill -0 $pid 2>/dev/null; then survived="$survived$i"; kill $pid; fi
    wait $pid 2>/dev/null
    sleep 1
done
[ "$survived" = 4 ] && [ "$(grep -c 'Leaving it running' "$E/logs/guard.log")" = 1 ] \
    && pass guard-limit "stopped three times, the fourth start left running" || fail guard-limit "left running: '$survived'; $(tail -1 "$E/logs/guard.log")"
steamplay status 2>&1 | grep -q "PROBLEM: Steam started without Protium's tools" && pass guard-limit-status "status says so" || fail guard-limit-status "status does not say so"
session "Registering tool proton-macos, x"; echo "[x] Registering tool macos-native, x" >>"$C/logs/compat_log.txt"
sleep 60 & pid=$!
STEAMPLAY_FAKE_RUNNING_PID=$pid steamplay guard >/dev/null 2>&1; kill $pid 2>/dev/null; wait $pid 2>/dev/null
[ ! -e "$E/home/guard-stops.json" ] && pass guard-limit-cleared "a start with the tools registered clears the count" || fail guard-limit-cleared "guard-stops.json is still there"

# 4. the app deleted without Uninstall: launchd's script takes Protium out of Steam
cp "$MACOS_DIR/steamplay" "$E/home/steamplay"
wrapper() {     # $1 the app, $2 its python
    /usr/bin/python3 -B - "$MACOS_DIR/steamplay" "$1" "$2" <<'PY'
import importlib.machinery, importlib.util, os, shlex, sys
loader = importlib.machinery.SourceFileLoader("steamplay", sys.argv[1])
m = importlib.util.module_from_spec(importlib.util.spec_from_loader("steamplay", loader))
loader.exec_module(m)
values = {"python": sys.argv[3], "script": os.path.join(m.HOME_DIR, "steamplay"), "app": sys.argv[2], "home": m.HOME_DIR,
          "steam_root": m.STEAM_ROOT, "tools_dir": m.TOOLS_DIR, "plist": "/nonexistent/guard.plist", "label": "none.test"}
with open(m.GUARD_WRAPPER, "w") as f:
    f.write(m.GUARD_WRAPPER_TEXT % {k: shlex.quote(v) for k, v in values.items()})
PY
}
ours() { echo "$(cat "$C/steam_dev.cfg" "$C/Steam.AppBundle/Steam/Contents/MacOS/steam_dev.cfg" 2>/dev/null | grep -c ForcePlatformType)/$(ls "$E/tools" | wc -l | tr -d ' ')/$(grep -c 'proton-macos\|macos-native' "$C/config/config.vdf")"; }
export STEAMPLAY_GONE_WAIT=2 STEAMPLAY_GONE_STEP=1
before=$(ours)
wrapper "" /bin/echo
[ "$(sh "$E/home/guard-run.sh")" = "$E/home/steamplay guard watch" ] && pass wrapper-checkout "an install from a checkout runs the watch" || fail wrapper-checkout "it did not"
wrapper "$E" /bin/echo
[ "$(sh "$E/home/guard-run.sh")" = "$E/home/steamplay guard watch" ] && pass wrapper-app-there "with the app there it runs the watch" || fail wrapper-app-there "it did not"
wrapper "$E/gone/Protium.app" "$E/gone/Protium.app/python3"
echo '{}' >"$E/home/update-pending.json"
sh "$E/home/guard-run.sh"
[ "$(ours)" = "$before" ] && pass wrapper-update "nothing is touched while an update is under way ($before)" || fail wrapper-update "switch/tools/mappings went from $before to $(ours)"
rm "$E/home/update-pending.json"
sh "$E/home/guard-run.sh"
[ "$(ours)" = "0/0/0" ] && pass wrapper-app-gone "the switch, the tools and the mappings are gone (were $before)" || fail wrapper-app-gone "switch/tools/mappings: $(ours), were $before"

# 5. the diagnostics file: written, and without the home folder or an account number
out=$(steamplay diagnose 2>&1); file=${out#diagnostics saved: }
if [ -f "$file" ] && ! grep -q -e "$HOME" "$file" && ! grep -qE 'userdata/[0-9]|7656119[0-9]{10}' "$file" && ! grep -q "could not be read" "$file"; then
    pass diagnose "$(wc -l <"$file" | tr -d ' ') lines, no home folder and no account number in it"
else
    fail diagnose "$(echo "$out" | tail -1 | cut -c1-200)"
fi
exit $FAILED
