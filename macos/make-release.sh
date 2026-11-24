#!/bin/bash
#
# Make Protium.app and its disk image, the release a player installs: the Wine install
# (macos/bundle-wine.sh), the Steam Play scripts, a Python for them, the app's window
# (macos/app/Protium.swift) and every component's license, all signed with a Developer ID
# certificate, hardened runtime and secure timestamps, and notarized.
#
#   $BUILD_ROOT/release/Protium.app
#   $BUILD_ROOT/release/Protium-<version>.dmg
#   $BUILD_ROOT/release/Protium-<version>.notes.md   the release's page (macos/release-notes.sh):
#                                                    its section of CHANGELOG.md and how to
#                                                    install and verify it;
#                                                    macos/publish-release.sh publishes both
#
# The install tree is copied, never changed: the copy has the PE files' debug information
# stripped, build-tree rpaths removed and the loader signed again with the Developer ID profile,
# which lets it run on any Mac, where bundle-wine.sh signs it with the development profile.
#
# Layout of the app:
#   Contents/MacOS/Protium                    the window (Set up Steam, Repair, Status, Uninstall)
#   Contents/Resources/Protium.icns           the icon, drawn by macos/app/make-icon.swift
#   Contents/Resources/steamplay/             steamplay, steamplay-launch, steamplay-run.sh, tools,
#                                             compat/capabilities.json
#   Contents/SharedSupport/runtime/           the Wine install, with its loader wine.app
#   Contents/SharedSupport/python/            a standalone CPython for steamplay
#   Contents/SharedSupport/licenses/          each component's license, and SOURCE.txt
#
# Notarization needs a notarytool keychain profile, made once:
#   xcrun notarytool store-credentials protium-notary --apple-id <id> --team-id 922Z3D8FB9
# Without one, or with NOTARIZE=0, the app and disk image are signed but not notarized.
#
# Environment overrides:
#   BUILD_ROOT      (default ~/projects/proton-macos-build)
#   INSTALL_DIR     the Wine install to ship (default $BUILD_ROOT/install-aarch64)
#   RELEASE_DIR     (default $BUILD_ROOT/release)
#   VERSION         (default: macos/app/VERSION)
#   SIGN_IDENTITY   (default: the first "Developer ID Application" identity in the keychain)
#   LOADER_PROFILE  the loader's Developer ID profile (default
#                   $BUILD_ROOT/signing/loader-developer-id.provisionprofile)
#   PYTHON_TARBALL  (default $BUILD_ROOT/third-party/python/<the pinned build below>)
#   TOOLCHAIN_DIR   llvm-mingw, for llvm-strip (default as in build-wine.sh)
#   NOTARY_PROFILE  notarytool keychain profile (default protium-notary)
#   NOTARIZE        auto (default: when the keychain profile exists), 1 or 0
#   MIN_MACOS       the oldest macOS the release supports (default 27.0); a Mach-O file that
#                   needs a newer one stops the release

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
PROTON_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
BUILD_ROOT=${BUILD_ROOT:-$HOME/projects/proton-macos-build}
INSTALL_DIR=${INSTALL_DIR:-$BUILD_ROOT/install-aarch64}
RELEASE_DIR=${RELEASE_DIR:-$BUILD_ROOT/release}
VERSION=${VERSION:-$(cat "$SCRIPT_DIR/app/VERSION")}
LOADER_PROFILE=${LOADER_PROFILE:-$BUILD_ROOT/signing/loader-developer-id.provisionprofile}
# CPython from github.com/astral-sh/python-build-standalone, release 20261123
PYTHON_BUILD=cpython-3.14.10+20261123-aarch64-apple-darwin-install_only_stripped.tar.gz
PYTHON_SHA256=f4b4683e628b86490baccd466d9fb9d4f1e73d57c96690634b6a1c0e91f3c5f7
PYTHON_TARBALL=${PYTHON_TARBALL:-$BUILD_ROOT/third-party/python/$PYTHON_BUILD}
TOOLCHAIN_DIR=${TOOLCHAIN_DIR:-$HOME/projects/proton-macos-toolchain/llvm-mingw-20261020-ucrt-macos-universal}
NOTARY_PROFILE=${NOTARY_PROFILE:-protium-notary}
NOTARIZE=${NOTARIZE:-auto}
MIN_MACOS=${MIN_MACOS:-27.0}
BUNDLE_ID=com.redshot.protium
MTLD3D_TARBALL=$BUILD_ROOT/third-party/mtld3d/mtld3d-v0.15.3.tar.xz

log() { echo ":: $*" >&2; }
die() { echo "make-release.sh: error: $*" >&2; exit 1; }

########################################################################
# 0. What the release is made from
########################################################################
[ "$(uname -m)" = arm64 ] || die "this script expects an arm64 (Apple Silicon) host"
[ -x "$INSTALL_DIR/bin/wine" ] || die "no Wine install in $INSTALL_DIR (run macos/bundle-wine.sh)"
loader_app=$INSTALL_DIR/lib/wine/aarch64-unix/wine.app
[ -d "$loader_app" ] || die "no loader app in $INSTALL_DIR (bundle-wine.sh signs one with a profile)"
[ -x "$TOOLCHAIN_DIR/bin/llvm-strip" ] || die "no llvm-strip in $TOOLCHAIN_DIR/bin"
[ -f "$PYTHON_TARBALL" ] || die "no $PYTHON_TARBALL: download $PYTHON_BUILD from github.com/astral-sh/python-build-standalone release 20261123"
[ "$(shasum -a 256 "$PYTHON_TARBALL" | cut -d' ' -f1)" = "$PYTHON_SHA256" ] || die "$PYTHON_TARBALL does not have the pinned SHA-256"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "VERSION $VERSION is not x.y.z"
# the release's section of CHANGELOG.md: what the app and the release's page say is new
CHANGELOG=$PROTON_DIR/CHANGELOG.md
# (Keep a Changelog: "## [1.2.3] - 2026-01-31", and the links at the end of the file are not part of it)
changes() { awk -v v="[$VERSION]" '/^## /{on = ($2 == v); next} /^\[[^]]*\]: /{on = 0} on' "$CHANGELOG"; }
[ -n "$(changes | tr -d '[:space:]')" ] || die "CHANGELOG.md has no section \"## [$VERSION] - <date>\": move what is under [Unreleased] into one first"

if [ -z "${SIGN_IDENTITY:-}" ]; then
    SIGN_IDENTITY=$(security find-identity -v -p codesigning | sed -n 's/^ *[0-9]*) \([0-9A-F]\{40\}\) "Developer ID Application:.*/\1/p' | head -1)
    [ -n "$SIGN_IDENTITY" ] || die "no Developer ID Application identity in the keychain"
fi
team=$(security find-identity -v -p codesigning | grep "$SIGN_IDENTITY" | sed -n 's/.*(\([A-Z0-9]\{10\}\))".*/\1/p' | head -1)
[ -n "$team" ] || die "the identity $SIGN_IDENTITY names no team"

[ -f "$LOADER_PROFILE" ] || die "no Developer ID profile at $LOADER_PROFILE"
profile_plist=$(mktemp)
trap 'rm -f "$profile_plist"' EXIT
security cms -D -i "$LOADER_PROFILE" >"$profile_plist" 2>/dev/null || die "$LOADER_PROFILE is not a signed profile"
pb() { /usr/libexec/PlistBuddy -c "Print :$1" "$profile_plist" 2>/dev/null; }
[ "$(pb ProvisionsAllDevices)" = true ] || die "$LOADER_PROFILE is not a Developer ID profile (it lists devices)"
[ "$(pb Entitlements:com.apple.developer.cross-architecture-support)" = true ] \
    || die "$LOADER_PROFILE does not grant the cross-architecture entitlement"
[ "$(pb TeamIdentifier:0)" = "$team" ] || die "$LOADER_PROFILE is for team $(pb TeamIdentifier:0), the identity for $team"

if [ "$NOTARIZE" = auto ]; then
    if xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then NOTARIZE=1; else NOTARIZE=0; fi
fi
log "Protium $VERSION from $INSTALL_DIR, signed by team $team, notarize: $NOTARIZE"

# every Mach-O file under a folder, deepest first (signing order)
macho_files() {
    find "$1" -type f -print0 | while IFS= read -r -d '' f; do
        case "$(file -b "$f")" in *Mach-O*) echo "$f" ;; esac
    done | awk '{ print gsub("/", "/") "\t" $0 }' | sort -rn | cut -f2-
}
minos() {
    otool -l "$1" 2>/dev/null | awk '/LC_BUILD_VERSION/{b=1} b&&/minos/{print $2; exit}'
}

########################################################################
# 1. The app's folders
########################################################################
app=$RELEASE_DIR/Protium.app
C=$app/Contents
rm -rf "$app"
mkdir -p "$C/MacOS" "$C/Resources/steamplay" "$C/SharedSupport/licenses"

log "the window"
swiftc -swift-version 5 -O -target "arm64-apple-macos$MIN_MACOS" -framework AppKit \
    -o "$C/MacOS/Protium" "$SCRIPT_DIR/app/Protium.swift"
log "the icon"
icon_work=$(mktemp -d)
swiftc -swift-version 5 -O -o "$icon_work/make-icon" "$SCRIPT_DIR/app/make-icon.swift"
mkdir "$icon_work/Protium.iconset"
for size in 16 32 128 256 512; do
    "$icon_work/make-icon" "$size" "$icon_work/Protium.iconset/icon_${size}x${size}.png"
    "$icon_work/make-icon" "$((size * 2))" "$icon_work/Protium.iconset/icon_${size}x${size}@2x.png"
done
iconutil -c icns -o "$C/Resources/Protium.icns" "$icon_work/Protium.iconset" || die "iconutil failed"
rm -rf "$icon_work"
cat >"$C/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key><string>Protium</string>
	<key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
	<key>CFBundleName</key><string>Protium</string>
	<key>CFBundleIconFile</key><string>Protium</string>
	<key>CFBundleDisplayName</key><string>Protium</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>$VERSION</string>
	<key>CFBundleVersion</key><string>$VERSION</string>
	<key>LSMinimumSystemVersion</key><string>$MIN_MACOS</string>
	<key>LSApplicationCategoryType</key><string>public.app-category.games</string>
	<key>NSHumanReadableCopyright</key><string>Copyright © 2026 Ethan Hurst. GPL-3.0-or-later; components keep their own licenses.</string>
	<key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
EOF

log "the Steam Play scripts"
for f in steamplay steamplay-launch steamplay-run.sh; do
    cp "$SCRIPT_DIR/$f" "$C/Resources/steamplay/$f"
done
rsync -a --exclude .DS_Store "$SCRIPT_DIR/steamplay-tools" "$SCRIPT_DIR/compat" "$C/Resources/steamplay/"
# what "steamplay version" answers with, and the app compares the newest release to
echo "$VERSION" >"$C/Resources/steamplay/VERSION"
cp "$CHANGELOG" "$C/Resources/steamplay/CHANGELOG.md"

log "the Wine install"
rsync -a --exclude .DS_Store "$INSTALL_DIR/" "$C/SharedSupport/runtime/"

log "Python ($PYTHON_BUILD)"
tar -xzf "$PYTHON_TARBALL" -C "$C/SharedSupport"
py=$C/SharedSupport/python
# what steamplay does not use: Tk, IDLE, pip and the test suite
rm -rf "$py"/bin/idle* "$py"/bin/pip* "$py"/bin/pydoc* "$py"/lib/tcl* "$py"/lib/tk* "$py"/lib/itcl* \
    "$py"/lib/thread* "$py"/lib/libtcl* "$py"/lib/libtk* "$py"/lib/python3.14/{idlelib,tkinter,turtledemo,ensurepip,test} \
    "$py"/lib/python3.14/lib-dynload/_tkinter*
"$py/bin/python3" -I -c 'import json, plistlib, shlex, hashlib, zipfile, subprocess, zlib' \
    || die "the bundled Python cannot import what steamplay needs"

########################################################################
# 2. Clean the copy
########################################################################
log "stripping debug information from the PE files"
n=0
while IFS= read -r -d '' f; do
    case "$(file -b "$f")" in
    PE32*) "$TOOLCHAIN_DIR/bin/llvm-strip" --strip-debug "$f"; n=$((n + 1)) ;;
    esac
done < <(find "$C/SharedSupport/runtime/lib/wine" -type f -path '*-windows/*' -print0)
log "$n PE files stripped"

log "removing build-tree rpaths"
while IFS= read -r f; do
    otool -l "$f" | awk '/cmd LC_RPATH/{r=1} r&&/ path /{print $2; r=0}' | while IFS= read -r rp; do
        case "$rp" in
        /Users/*|/Volumes/*|"$BUILD_ROOT"*|/opt/homebrew*) install_name_tool -delete_rpath "$rp" "$f" 2>/dev/null ;;
        esac
    done
done < <(macho_files "$C/SharedSupport/runtime")

# A Homebrew library in lib/external carries the macOS of the Mac whose Homebrew built it (27.2
# for one made on 27.2), though it uses nothing newer than the release's macOS: within the same
# major version it is marked for MIN_MACOS. What this script's builds made is never marked.
min_major=${MIN_MACOS%%.*}
for f in "$C/SharedSupport/runtime/lib/external/"*.dylib; do
    v=$(minos "$f"); [ -n "$v" ] || continue
    [ "${v%%.*}" = "$min_major" ] && [ "$v" != "$MIN_MACOS" ] \
        && [ "$(printf '%s\n%s\n' "$v" "$MIN_MACOS" | sort -V | tail -1)" = "$v" ] || continue
    [ -e "/opt/homebrew/lib/$(basename "$f")" ] || continue
    sdk=$(otool -l "$f" | awk '/LC_BUILD_VERSION/{b=1} b&&/ sdk /{print $2; exit}')
    xcrun vtool -set-build-version macos "$MIN_MACOS" "$sdk" -replace -output "$f.vtool" "$f" 2>/dev/null \
        && mv "$f.vtool" "$f" || die "could not mark $(basename "$f") for macOS $MIN_MACOS"
    log "$(basename "$f"): Homebrew built it for macOS $v, marked for $MIN_MACOS"
done

log "checking the oldest macOS each file needs"
too_new=$(macho_files "$C" | while IFS= read -r f; do
    v=$(minos "$f"); [ -n "$v" ] || continue
    [ "$(printf '%s\n%s\n' "$v" "$MIN_MACOS" | sort -V | tail -1)" = "$MIN_MACOS" ] || echo "$v ${f#$C/}"
done)
[ -z "$too_new" ] || die "these need a macOS newer than $MIN_MACOS (rebuild with MACOSX_DEPLOYMENT_TARGET=$MIN_MACOS):
$(echo "$too_new" | head -20)"

########################################################################
# 3. Licenses and where the source is
########################################################################
log "licenses"
L=$C/SharedSupport/licenses
mkdir -p "$L"/{protium,wine,dxmt,vkd3d-proton,fex,mesa,mtld3d,python,gstreamer}
cp "$PROTON_DIR/LICENSE" "$PROTON_DIR/LICENSE.protium" "$PROTON_DIR/LICENSE.proton" "$L/protium/"
cp "$PROTON_DIR/wine/LICENSE" "$PROTON_DIR/wine/COPYING.LIB" "$L/wine/"
cp "$BUILD_ROOT/dxmt-src/COPYING.LIB" "$L/dxmt/"
cp "$BUILD_ROOT/vkd3d-proton-src/COPYING" "$L/vkd3d-proton/"
cp "$BUILD_ROOT/fex-src/LICENSE" "$L/fex/"
cp "$BUILD_ROOT/mesa-src/docs/license.rst" "$L/mesa/"
tar -xJf "$MTLD3D_TARBALL" -C "$L/mtld3d" --strip-components 1 '*/LICENSE' 2>/dev/null \
    || tar -xJf "$MTLD3D_TARBALL" -C "$L/mtld3d" LICENSE 2>/dev/null || log "no LICENSE in $MTLD3D_TARBALL"
cp "$py/lib/python3.14/LICENSE.txt" "$L/python/"
for d in gstreamer orc ffmpeg; do
    for f in "$BUILD_ROOT/gst-src/$d"/COPYING* "$BUILD_ROOT/gst-src/$d"/LICENSE*; do
        [ -f "$f" ] && cp "$f" "$L/gstreamer/$d-$(basename "$f")"
    done
done
# the Homebrew libraries bundle-wine.sh copied into lib/external, by their formula
for lib in "$C/SharedSupport/runtime/lib/external/"*.dylib; do
    name=$(basename "$lib")
    src=$(ls /opt/homebrew/opt/*/lib/"$name" 2>/dev/null | head -1) || true
    [ -n "$src" ] || continue
    formula=$(basename "$(dirname "$(dirname "$src")")")
    [ -d "$L/homebrew/$formula" ] && continue
    mkdir -p "$L/homebrew/$formula"
    find -L "/opt/homebrew/opt/$formula/" -maxdepth 1 -type f \( -iname 'COPYING*' -o -iname 'LICENSE*' -o -iname 'LICENCE*' \) \
        -exec cp {} "$L/homebrew/$formula/" \;
done
commit() { git -C "$1" rev-parse HEAD 2>/dev/null || echo unknown; }
cat >"$L/SOURCE.txt" <<EOF
Protium $VERSION is built from:
  Protium (Proton 11 with macOS support)  https://github.com/0xLeathery/protium  $(commit "$PROTON_DIR")
  Wine                                    https://github.com/0xLeathery/protium-wine  $(commit "$PROTON_DIR/wine")
  DXMT                                    https://github.com/athei/dxmt  $(commit "$BUILD_ROOT/dxmt-src")  + macos/patches/dxmt
  vkd3d-proton                            https://github.com/athei/vkd3d-proton  $(commit "$BUILD_ROOT/vkd3d-proton-src")  + macos/patches/vkd3d-proton
  FEX                                     https://github.com/athei/FEX  $(commit "$BUILD_ROOT/fex-src")  + macos/patches/fex
  Mesa (KosmicKrisp)                      https://github.com/athei/mesa  $(commit "$BUILD_ROOT/mesa-src")
  mtld3d                                  https://github.com/athei/mtld3d  v0.15.3 (release)
  GStreamer, ORC, FFmpeg                  Proton's submodules at the commits of this Protium
  CPython                                 https://github.com/astral-sh/python-build-standalone  $PYTHON_BUILD
The libraries in runtime/lib/external that are not built above come from Homebrew; their licenses
are in homebrew/. The source of every LGPL and GPL component is at the addresses above, at the
commits given.
EOF

########################################################################
# 4. Sign: every Mach-O file, then the loader app, then Protium.app
########################################################################
sign() { codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$@"; }

log "signing $(macho_files "$C" | grep -v -c "/wine.app/Contents/MacOS/") Mach-O files"
while IFS= read -r f; do
    case "$f" in */wine.app/Contents/MacOS/*|"$C/MacOS/Protium") continue ;; esac
    sign "$f" || die "could not sign $f"
done < <(macho_files "$C")

log "signing the loader with the Developer ID profile"
rt_loader=$C/SharedSupport/runtime/lib/wine/aarch64-unix/wine.app
ents=$(mktemp)
codesign -d --entitlements :- "$loader_app" >"$ents" 2>/dev/null || die "could not read the loader's entitlements"
/usr/libexec/PlistBuddy -c 'Print :com.apple.developer.cross-architecture-support' "$ents" >/dev/null 2>&1 \
    || die "the installed loader was not signed with the cross-architecture entitlement (bundle-wine.sh without a profile?)"
cp "$LOADER_PROFILE" "$rt_loader/Contents/embedded.provisionprofile"
sign --entitlements "$ents" "$rt_loader" || die "could not sign the loader"
rm -f "$ents"

log "signing Protium.app"
sign "$C/MacOS/Protium"
sign "$app"
codesign --verify --deep --strict "$app" || die "the signature of $app does not verify"

########################################################################
# 5. Notarize the app, make the disk image, notarize it
########################################################################
notarize() {
    log "notarizing $(basename "$1")"
    xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json >"$1.notary.json" \
        || die "notarytool failed for $1"
    grep -q '"status" *: *"Accepted"' "$1.notary.json" || die "$1 was not accepted: $(cat "$1.notary.json")"
}
if [ "$NOTARIZE" = 1 ]; then
    zip=$RELEASE_DIR/Protium-$VERSION.zip
    rm -f "$zip"
    ditto -c -k --keepParent "$app" "$zip"
    notarize "$zip"
    xcrun stapler staple "$app"
    rm -f "$zip"
fi

log "disk image"
dmg=$RELEASE_DIR/Protium-$VERSION.dmg
stage=$RELEASE_DIR/dmg-stage
rm -rf "$stage" "$dmg"
mkdir -p "$stage"
ditto "$app" "$stage/Protium.app"
ln -s /Applications "$stage/Applications"
hdiutil create -quiet -volname "Protium $VERSION" -srcfolder "$stage" -fs APFS -format ULMO "$dmg"
rm -rf "$stage"
sign "$dmg"
if [ "$NOTARIZE" = 1 ]; then
    notarize "$dmg"
    xcrun stapler staple "$dmg"
    spctl -a -vv -t open --context context:primary-signature "$dmg" 2>&1 | sed 's/^/:: /' >&2 || true
fi
# the release's page, for macos/publish-release.sh
"$SCRIPT_DIR/release-notes.sh" "$VERSION" "$dmg" >"$RELEASE_DIR/Protium-$VERSION.notes.md"
log "done: $dmg ($(du -h "$dmg" | cut -f1); app $(du -sh "$app" | cut -f1))"
