#!/bin/bash
#
# Install the native arm64 macOS Wine build and wrap its loader in an app bundle.
#
# A restricted entitlement such as com.apple.developer.cross-architecture-support (4K pages,
# memory below 4 GB, hardware TSO) only counts for an executable inside an app bundle that
# embeds a provisioning profile granting it and that a certificate of the profile's team signed.
# So the loader moves into wine.app next to ntdll.so, and the usual paths become links to it
# (the layout of bin/bundle-wine.sh in github.com/athei/mach9):
#
#   lib/wine/aarch64-unix/wine.app/Contents/MacOS/wine
#   lib/wine/aarch64-unix/wine.app/Contents/Info.plist
#   lib/wine/aarch64-unix/wine.app/Contents/embedded.provisionprofile   (with LOADER_PROFILE)
#   lib/wine/aarch64-unix/wine -> wine.app/Contents/MacOS/wine
#   bin/wine -> ../lib/wine/aarch64-unix/wine.app/Contents/MacOS/wine
#
# bin/wine replaces the launcher that `make install` puts there: the launcher loads ntdll.so into
# itself, so Windows code would run in an executable outside the bundle.
#
# Without LOADER_PROFILE the bundle is signed ad hoc with macos/wine-loader.entitlements (the
# custom x18 ABI, which needs no profile). With it, a certificate of the profile's team signs the
# bundle, which then also claims the cross-architecture entitlement.
#
#   macos/bundle-wine.sh
#   LOADER_PROFILE=/path/to/loader.provisionprofile macos/bundle-wine.sh
#
# Environment overrides:
#   BUILD_ROOT      (default /Users/annon/projects/proton-macos-build)
#   BUILD_DIR       (default $BUILD_ROOT/wine-aarch64), as build-wine.sh built it; the bundle goes
#                   into the prefix it was configured with
#   LOADER_PROFILE  provisioning profile to embed (default: none)
#   BUNDLE_ID       bundle identifier (default: the profile's, or org.winehq.wine without a
#                   profile); with a profile it has to be the one the profile is for
#   MIN_FREE_GB     abort if less free disk space than this (default 10)

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
BUILD_ROOT=${BUILD_ROOT:-/Users/annon/projects/proton-macos-build}
BUILD_DIR=${BUILD_DIR:-$BUILD_ROOT/wine-aarch64}
LOADER_PROFILE=${LOADER_PROFILE:-}
BUNDLE_ID=${BUNDLE_ID:-}
MIN_FREE_GB=${MIN_FREE_GB:-10}
ENTITLEMENTS=$SCRIPT_DIR/wine-loader.entitlements
UNIX_DIR=aarch64-unix
CROSS_ARCH_ENTITLEMENT=com.apple.developer.cross-architecture-support
X18_ENTITLEMENT=com.apple.security.custom-x18-abi-toggle
# What the hardened runtime would otherwise refuse: FEX's code buffers (MAP_JIT), pages that
# are writable and executable in Windows terms, and the unix libraries, which are signed ad hoc
# and not by the loader's team.
RUNTIME_ENTITLEMENTS="com.apple.security.cs.allow-jit
com.apple.security.cs.disable-executable-page-protection
com.apple.security.cs.disable-library-validation"

log() { echo ":: $*" >&2; }
die() { echo "bundle-wine.sh: error: $*" >&2; exit 1; }

[ "$(uname -s)" = Darwin ] || die "this script runs on macOS only"
[ "$(uname -m)" = arm64 ] || die "this script expects an arm64 (Apple Silicon) host"
[ -f "$BUILD_DIR/Makefile" ] || die "no Wine build in $BUILD_DIR (run macos/build-wine.sh first)"
[ -f "$ENTITLEMENTS" ] || die "missing $ENTITLEMENTS"

INSTALL_DIR=$(sed -n 's/^prefix = //p' "$BUILD_DIR/Makefile" | head -1)
case "$INSTALL_DIR" in
    /*/*) ;;
    *) die "the build in $BUILD_DIR has no usable prefix ('$INSTALL_DIR')" ;;
esac
VERSION=$(sed -n 's/^PACKAGE_VERSION = //p' "$BUILD_DIR/Makefile" | head -1)
[ -n "$VERSION" ] || die "no PACKAGE_VERSION in $BUILD_DIR/Makefile"

TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/bundle-wine.XXXXXX")
trap 'rm -rf "$TMP_DIR"' EXIT

########################################################################
# 1. The profile and the signing identity (before anything is changed)
########################################################################
# Everything about the signature comes from the profile: the team, the bundle identifier and
# the certificates that may sign. The identity is picked by its SHA-1, since several
# certificates can share a name, and has to be one the profile lists.
LOADER_TEAM=
LOADER_IDENTITY=
if [ -n "$LOADER_PROFILE" ]; then
    [ -f "$LOADER_PROFILE" ] || die "no provisioning profile at $LOADER_PROFILE"
    plist=$TMP_DIR/profile.plist
    security cms -D -i "$LOADER_PROFILE" >"$plist" 2>/dev/null \
        || die "$LOADER_PROFILE is not a signed provisioning profile"
    # both are ISO 8601 in UTC, so they compare as strings
    expires=$(plutil -extract ExpirationDate raw -o - "$plist" 2>/dev/null) \
        || die "the provisioning profile has no ExpirationDate"
    [[ "$expires" > "$(date -u +%Y-%m-%dT%H:%M:%SZ)" ]] || die "the provisioning profile expired on $expires"
    [ "$(/usr/libexec/PlistBuddy -c "Print :Entitlements:$CROSS_ARCH_ENTITLEMENT" "$plist" 2>/dev/null)" = true ] \
        || die "the provisioning profile does not grant $CROSS_ARCH_ENTITLEMENT"
    LOADER_TEAM=$(/usr/libexec/PlistBuddy -c 'Print :TeamIdentifier:0' "$plist" 2>/dev/null) \
        || die "the provisioning profile names no TeamIdentifier"
    appid=$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.application-identifier' "$plist" 2>/dev/null) \
        || die "the provisioning profile grants no com.apple.application-identifier"
    profile_id=${appid#"$LOADER_TEAM".}
    [ -n "$LOADER_TEAM" ] && [ "$profile_id" != "$appid" ] \
        || die "the application identifier $appid does not start with the team $LOADER_TEAM"
    case "$profile_id" in *\**) die "the profile is for the wildcard identifier $profile_id; the entitlement needs an explicit one" ;; esac
    [ -z "$BUNDLE_ID" ] || [ "$BUNDLE_ID" = "$profile_id" ] \
        || die "BUNDLE_ID is $BUNDLE_ID, but the profile is for $profile_id"
    BUNDLE_ID=$profile_id

    certs=" "
    i=0
    while cert=$(plutil -extract "DeveloperCertificates.$i" raw -o - "$plist" 2>/dev/null); do
        certs="$certs$(printf '%s' "$cert" | base64 --decode | shasum -a 1 | cut -d' ' -f1 | tr a-f A-F) "
        i=$((i + 1))
    done
    for id in $(security find-identity -v -p codesigning | awk -v team="($LOADER_TEAM)\"" 'index($0, team) { print $2 }'); do
        case "$certs" in *" $id "*) LOADER_IDENTITY=$id; break ;; esac
    done
    [ -n "$LOADER_IDENTITY" ] \
        || die "no valid code signing identity of team $LOADER_TEAM in the keychain is one of the $i certificates the profile lists"
    log "profile: $BUNDLE_ID, team $LOADER_TEAM, expires $expires, identity $LOADER_IDENTITY"
else
    BUNDLE_ID=${BUNDLE_ID:-org.winehq.wine}
    log "no LOADER_PROFILE: ad-hoc signature with $(basename "$ENTITLEMENTS")"
fi

########################################################################
# 2. Install
########################################################################
free_gb=$(df -g "$BUILD_ROOT" | awk 'NR==2 {print $4}')
log "free disk space: ${free_gb} GB"
[ "$free_gb" -ge "$MIN_FREE_GB" ] || die "only ${free_gb} GB free on $BUILD_ROOT (minimum ${MIN_FREE_GB} GB)"

unixdir=$INSTALL_DIR/lib/wine/$UNIX_DIR
app=$unixdir/wine.app
# The links of an earlier run point into the bundle: make install must not write through them.
rm -rf "$app"
rm -f "$unixdir/wine" "$INSTALL_DIR/bin/wine"

install_log=$BUILD_ROOT/bundle-wine-install.log
log "make install-lib into $INSTALL_DIR (log: $install_log)"
make -C "$BUILD_DIR" install-lib >"$install_log" 2>&1 || die "make install-lib failed, see $install_log"
[ -f "$unixdir/wine" ] && [ ! -L "$unixdir/wine" ] || die "make install-lib left no loader at $unixdir/wine"
[ -f "$unixdir/ntdll.so" ] || die "make install-lib left no $unixdir/ntdll.so"

########################################################################
# 3. The bundle
########################################################################
mkdir -p "$app/Contents/MacOS"
mv "$unixdir/wine" "$app/Contents/MacOS/wine"
[ -z "$LOADER_PROFILE" ] || cp "$LOADER_PROFILE" "$app/Contents/embedded.provisionprofile"
# The keys of loader/wine_info.plist.in, which the loader also carries in its __info_plist
# section; in a bundle this file is the one the system reads.
cat >"$app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleAllowMixedLocalizations</key>
    <true/>
    <key>CFBundleDevelopmentRegion</key>
    <string>English</string>
    <key>CFBundleExecutable</key>
    <string>wine</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>Wine</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
    <key>NSPrincipalClass</key>
    <string>WineApplication</string>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
EOF
plutil -lint "$app/Contents/Info.plist" >/dev/null || die "Info.plist does not parse"
ln -s wine.app/Contents/MacOS/wine "$unixdir/wine"
# the other names in bin (wineboot, winecfg, ...) are links to bin/wine and go on working: ntdll
# takes the program from the name the loader was started under
rm -f "$INSTALL_DIR/bin/wine"
ln -s "../lib/wine/$UNIX_DIR/wine.app/Contents/MacOS/wine" "$INSTALL_DIR/bin/wine"

########################################################################
# 4. Sign
########################################################################
# The bundle is signed as a whole and without --deep: the loader is the only code in it.
if [ -n "$LOADER_PROFILE" ]; then
    ents=$TMP_DIR/loader-entitlements.plist
    /usr/libexec/PlistBuddy \
        -c "Add :com.apple.application-identifier string $LOADER_TEAM.$BUNDLE_ID" \
        -c "Add :com.apple.developer.team-identifier string $LOADER_TEAM" \
        -c "Add :$CROSS_ARCH_ENTITLEMENT bool true" \
        -c "Add :$X18_ENTITLEMENT bool true" \
        "$ents" >/dev/null
    for key in $RUNTIME_ENTITLEMENTS; do
        /usr/libexec/PlistBuddy -c "Add :$key bool true" "$ents" >/dev/null
    done
    log "signing $app ($BUNDLE_ID, identity $LOADER_IDENTITY, hardened runtime)"
    # No secure timestamp: it needs Apple's timestamp server, and only notarization asks for it.
    codesign --force --options runtime --timestamp=none --sign "$LOADER_IDENTITY" --entitlements "$ents" "$app" \
        || die "codesign failed for $app"
else
    log "signing $app ($BUNDLE_ID, ad hoc)"
    codesign --force --sign - --entitlements "$ENTITLEMENTS" "$app" || die "codesign failed for $app"
fi
codesign --verify --strict "$app" || die "signature of $app does not verify"
log "entitlements: $(codesign -d --entitlements - --xml "$app" 2>/dev/null | perl -ne 'print "$1 " while /<key>([^<]*)<\/key>/g')"

log "done: $INSTALL_DIR/bin/wine -> $(readlink "$INSTALL_DIR/bin/wine")"
