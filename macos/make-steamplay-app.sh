#!/bin/bash
#
# Make "Steam Play.app", the one Mac app that starts any Windows game Mac Steam installed:
#
#   macos/make-steamplay-app.sh [--trace CHANNELS]
#   open -a "<STEAMPLAY_APPS>/Steam Play.app" --args <app id>
#
# The app runs macos/steamplay-run.sh for the app id it is given, after starting Mac Steam when
# it is not running, and stays open until the game exits. Steam library shortcuts (macos/
# steamplay sync) open it this way. With --trace, Wine's debug channels CHANNELS (e.g. +cursor)
# go to each game's log in its compatdata folder.
#
# macOS asks the user before a program reads a removable or network drive, Documents, Desktop or
# Downloads, and decides by the app whose main program runs. So the app's main program is a
# small compiled launcher, which starts the script as a child and waits for it, rather than the
# script itself (whose program would be /bin/bash), and the app is signed with a fixed identity,
# so that the user's answer, or a Full Disk Access entry, outlasts a rebuild of the app.
#
# Environment overrides:
#   BUILD_ROOT       (default ~/projects/proton-macos-build)
#   STEAMPLAY_APPS   where the app is made (default $BUILD_ROOT/steamplay-apps)
#   SIGN_IDENTITY    code-signing identity (default: the first "Apple Development" identity,
#                    else ad hoc, which macOS remembers only until the app is rebuilt)

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
BUILD_ROOT=${BUILD_ROOT:-$HOME/projects/proton-macos-build}
STEAMPLAY_APPS=${STEAMPLAY_APPS:-$BUILD_ROOT/steamplay-apps}

die() { echo "make-steamplay-app.sh: error: $*" >&2; exit 1; }

trace=
if [ "${1:-}" = --trace ]; then trace=$2; shift 2; fi
[ $# -eq 0 ] || die "usage: make-steamplay-app.sh [--trace CHANNELS]"
if [ -z "${SIGN_IDENTITY:-}" ]; then
    SIGN_IDENTITY=$(security find-identity -v -p codesigning | sed -n 's/^ *[0-9]*) \([0-9A-F]\{40\}\) "Apple Development.*/\1/p' | head -1)
    [ -n "$SIGN_IDENTITY" ] || { SIGN_IDENTITY=-; echo ":: no Apple Development identity: ad hoc signature" >&2; }
fi

app="$STEAMPLAY_APPS/Steam Play.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cat >"$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>steamplay</string>
    <key>CFBundleIdentifier</key><string>local.steamplay.launcher</string>
    <key>CFBundleName</key><string>Steam Play</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>LSMultipleInstancesProhibited</key><false/>
    <key>NSRemovableVolumesUsageDescription</key><string>Games and their Wine prefixes can be in a Steam library on an external drive.</string>
    <key>NSNetworkVolumesUsageDescription</key><string>Games and their Wine prefixes can be in a Steam library on a network drive.</string>
    <key>NSDocumentsFolderUsageDescription</key><string>Windows games keep saves and settings in Documents.</string>
    <key>NSDesktopFolderUsageDescription</key><string>Windows games can read and write files on the Desktop.</string>
    <key>NSDownloadsFolderUsageDescription</key><string>Windows games can read and write files in Downloads.</string>
</dict>
</plist>
PLIST

cat >"$app/Contents/Resources/steamplay.sh" <<LAUNCH
#!/bin/bash
# Made by macos/make-steamplay-app.sh: runs the game whose Steam app id is \$1.
[ -n "\${1:-}" ] || { echo "Steam Play: no app id" >&2; exit 2; }
if ! pgrep -f steam_osx >/dev/null; then
    open -g -a Steam
    for i in \$(seq 1 120); do pgrep -f steam_osx >/dev/null && break; sleep 0.5; done
    sleep 15   # Steam signs in after it starts
fi
${trace:+export WINEDEBUG=+pid,+timestamp,$trace}
exec "$SCRIPT_DIR/steamplay-run.sh" "\$@"
LAUNCH
chmod +x "$app/Contents/Resources/steamplay.sh"

src=$(mktemp -d)/steamplay.c
cat >"$src" <<'C'
/* Starts Contents/Resources/steamplay.sh with this process's arguments and waits for it, so that
 * macOS charges what the script and the game read to this app. */
#include <mach-o/dyld.h>
#include <limits.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>

extern char **environ;

int main(int argc, char **argv)
{
    char exe[PATH_MAX], script[PATH_MAX + 64], *slash;
    uint32_t size = sizeof(exe);
    pid_t pid;
    int status, i;

    if (_NSGetExecutablePath(exe, &size) || !realpath(exe, script)) return 1;
    if (!(slash = strrchr(script, '/'))) return 1;
    strcpy(slash, "/../Resources/steamplay.sh");
    /* LaunchServices adds -psn_... to the arguments of an app opened from Finder */
    argv[0] = script;
    for (i = 1; i < argc; i++) if (!strncmp(argv[i], "-psn_", 5)) argv[i] = "";
    if (posix_spawn(&pid, script, NULL, NULL, argv, environ)) { perror(script); return 1; }
    while (waitpid(pid, &status, 0) < 0) ;
    return WIFEXITED(status) ? WEXITSTATUS(status) : 1;
}
C
clang -O2 -arch arm64 -mmacosx-version-min=13.0 -o "$app/Contents/MacOS/steamplay" "$src" || die "the launcher did not build"
rm -f "$src"
codesign --force --options runtime --sign "$SIGN_IDENTITY" "$app" >/dev/null 2>&1 || die "codesign failed for $app"
echo "$app"
