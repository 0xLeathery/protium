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
#   FEX_DIST        output of build-fex.sh (default $BUILD_ROOT/fex-dist); its ARM64EC module is
#                   installed with Wine's own modules when it is there. Without it an x86_64
#                   program stops with "could not load libarm64ecfex.dll".
#   WOW64           whether the 32-bit side goes in: Wine's i386 DLLs, when the build has them
#                   (WINE_ARCHS with i386), and FEX's libwow64fex. "auto" (the default) is yes
#                   with LOADER_PROFILE and no without: a 32-bit process lives below 4 GB,
#                   where macOS maps nothing without the cross-architecture entitlement, so
#                   without it the DLLs are 200 MB that nothing can run, and every new prefix
#                   would start a 32-bit rundll32 only for ntdll to refuse it. "yes" and "no"
#                   force it.
#   DXMT_DIST       output of build-dxmt.sh (default $BUILD_ROOT/dxmt-dist); when it is there,
#                   its dxgi, d3d10core and d3d11 take the place of Wine's own, which have no
#                   usable backend on this build, and its winemetal modules are added
#   VKD3D_DIST      output of build-vkd3d-proton.sh (default $BUILD_ROOT/vkd3d-proton-dist); when
#                   it is there, its d3d12 and d3d12core take the place of Wine's own. Direct3D
#                   12 then needs the Vulkan driver of MESA_DIST.
#   HOST_DYLIBS     Homebrew libraries that Wine opens by name at run time (default
#                   libfreetype.6.dylib, without which Wine has no TrueType fonts). They are
#                   copied with the Homebrew libraries they need into lib/external.
#   VULKAN_DIST     output of build-vulkan.sh (default $BUILD_ROOT/vulkan-dist); its loader is
#                   installed the same way when it is there
#   MESA_DIST       output of build-mesa.sh (default $BUILD_ROOT/mesa-dist); when it and the
#                   loader are there, its Vulkan driver, KosmicKrisp, is installed, with its
#                   manifest in share/vulkan/icd.d, the directory ntdll names to the loader
#   MIN_FREE_GB     abort if less free disk space than this (default 10)

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
BUILD_ROOT=${BUILD_ROOT:-/Users/annon/projects/proton-macos-build}
BUILD_DIR=${BUILD_DIR:-$BUILD_ROOT/wine-aarch64}
LOADER_PROFILE=${LOADER_PROFILE:-}
BUNDLE_ID=${BUNDLE_ID:-}
FEX_DIST=${FEX_DIST:-$BUILD_ROOT/fex-dist}
DXMT_DIST=${DXMT_DIST:-$BUILD_ROOT/dxmt-dist}
VKD3D_DIST=${VKD3D_DIST:-$BUILD_ROOT/vkd3d-proton-dist}
HOST_DYLIBS=${HOST_DYLIBS:-libfreetype.6.dylib}
WOW64=${WOW64:-auto}
VULKAN_DIST=${VULKAN_DIST:-$BUILD_ROOT/vulkan-dist}
MESA_DIST=${MESA_DIST:-$BUILD_ROOT/mesa-dist}
VULKAN_DRIVER=libvulkan_kosmickrisp.dylib
VULKAN_ICD_JSON=kosmickrisp_mesa_icd.aarch64.json
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
# The install tree is removed and written again below, so it has to be a directory of ours.
case "$INSTALL_DIR" in
    *..*) die "the prefix of the build in $BUILD_DIR ('$INSTALL_DIR') contains '..'" ;;
    "$BUILD_ROOT"/?*) ;;
    *) die "the prefix of the build in $BUILD_DIR ('$INSTALL_DIR') is not below $BUILD_ROOT" ;;
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
    # Every valid identity is tried: the name of an Apple Development certificate ends in an
    # ID of the person, not of the team, so the name cannot pick the candidates.
    for id in $(security find-identity -v -p codesigning | awk '$2 ~ /^[0-9A-F]+$/ && length($2) == 40 { print $2 }'); do
        case "$certs" in *" $id "*) LOADER_IDENTITY=$id; break ;; esac
    done
    [ -n "$LOADER_IDENTITY" ] \
        || die "no valid code signing identity in the keychain is one of the $i certificates the profile lists"
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
pedir=$INSTALL_DIR/lib/wine/aarch64-windows
app=$unixdir/wine.app
# Start from an empty tree. The links of an earlier run point into the bundle, and make install
# must not write through them; a build directory with other PE architectures installs into the
# same prefix, and nothing of it may be left behind.
rm -rf "$INSTALL_DIR"

install_log=$BUILD_ROOT/bundle-wine-install.log
log "make install-lib into $INSTALL_DIR (log: $install_log)"
make -C "$BUILD_DIR" install-lib >"$install_log" 2>&1 || die "make install-lib failed, see $install_log"
[ -f "$unixdir/wine" ] && [ ! -L "$unixdir/wine" ] || die "make install-lib left no loader at $unixdir/wine"
[ -f "$unixdir/ntdll.so" ] || die "make install-lib left no $unixdir/ntdll.so"

# The 32-bit side: only where a 32-bit process can exist (see WOW64 above)
case "$WOW64" in
    auto) wow64=no; [ -z "$LOADER_PROFILE" ] || wow64=yes ;;
    yes|no) wow64=$WOW64 ;;
    *) die "WOW64 is '$WOW64' (auto, yes or no)" ;;
esac
i386dir=$INSTALL_DIR/lib/wine/i386-windows
if [ -d "$i386dir" ]; then
    if [ $wow64 = yes ]; then
        log "32-bit side: $(ls "$i386dir" | wc -l | tr -d ' ') files in lib/wine/i386-windows"
    else
        rm -rf "$i386dir"
        if [ -n "$LOADER_PROFILE" ]; then log "32-bit side left out (WOW64=$WOW64)"
        else log "32-bit side left out (no LOADER_PROFILE: nothing can be mapped below 4 GB, where a 32-bit process lives)"; fi
    fi
elif [ $wow64 = yes ]; then
    log "no 32-bit side in this build (WINE_ARCHS without i386)"
fi

# FEX's ARM64EC module, where Proton's Makefile.in installs it
if [ -f "$FEX_DIST/lib/wine/aarch64-windows/libarm64ecfex.dll" ] && [ -f "$FEX_DIST/lib/wine/$UNIX_DIR/libarm64ecfex.so" ]; then
    cp "$FEX_DIST/lib/wine/aarch64-windows/libarm64ecfex.dll" "$pedir/libarm64ecfex.dll"
    cp "$FEX_DIST/lib/wine/$UNIX_DIR/libarm64ecfex.so" "$unixdir/libarm64ecfex.so"
    log "installed FEX's ARM64EC module from $FEX_DIST"
    # and its module for 32-bit code, which wow64.dll loads in a WoW64 process
    if [ $wow64 = yes ] && [ -d "$i386dir" ] && [ -f "$FEX_DIST/lib/wine/aarch64-windows/libwow64fex.dll" ] && [ -f "$FEX_DIST/lib/wine/$UNIX_DIR/libwow64fex.so" ]; then
        cp "$FEX_DIST/lib/wine/aarch64-windows/libwow64fex.dll" "$pedir/libwow64fex.dll"
        cp "$FEX_DIST/lib/wine/$UNIX_DIR/libwow64fex.so" "$unixdir/libwow64fex.so"
        log "installed FEX's WoW64 module from $FEX_DIST"
    fi
else
    log "no FEX module in $FEX_DIST (macos/build-fex.sh builds it): x86_64 programs will not run"
fi

# DXMT, Direct3D 10 and 11 on Metal. Its DLLs are Wine builtins of the same names as Wine's own
# dxgi, d3d10core and d3d11 and replace them; Wine's d3d10 and d3d10_1 stay and sit on top of
# DXMT's d3d10core.
if [ -f "$DXMT_DIST/lib/wine/aarch64-windows/d3d11.dll" ] && [ -f "$DXMT_DIST/lib/wine/$UNIX_DIR/winemetal.so" ]; then
    for dll in dxgi d3d10core d3d11 winemetal; do
        cp "$DXMT_DIST/lib/wine/aarch64-windows/$dll.dll" "$pedir/$dll.dll"
    done
    cp "$DXMT_DIST/lib/wine/$UNIX_DIR/winemetal.so" "$unixdir/winemetal.so"
    log "installed DXMT $(cat "$DXMT_DIST/DESCRIBE" 2>/dev/null) from $DXMT_DIST in place of Wine's dxgi, d3d10core and d3d11"
else
    log "no DXMT in $DXMT_DIST (macos/build-dxmt.sh builds it): Direct3D 10 and 11 stay Wine's own"
fi

# vkd3d-proton, Direct3D 12 on Vulkan. Its d3d12 and d3d12core are Wine builtins of the same
# names as Wine's own and replace them: Wine's make no device on the adapter of DXMT's dxgi,
# which in turn presents vkd3d-proton's swap chains.
if [ -f "$VKD3D_DIST/lib/wine/aarch64-windows/d3d12.dll" ] && [ -f "$VKD3D_DIST/lib/wine/aarch64-windows/d3d12core.dll" ]; then
    for dll in d3d12 d3d12core; do
        cp "$VKD3D_DIST/lib/wine/aarch64-windows/$dll.dll" "$pedir/$dll.dll"
    done
    log "installed vkd3d-proton $(cat "$VKD3D_DIST/DESCRIBE" 2>/dev/null) from $VKD3D_DIST in place of Wine's d3d12 and d3d12core"
else
    log "no vkd3d-proton in $VKD3D_DIST (macos/build-vkd3d-proton.sh builds it): Direct3D 12 stays Wine's own"
fi

########################################################################
# 3. Host libraries
########################################################################
# Wine's Unix libraries open these by their bare name, which dyld only looks up in the rpaths
# of the library that asks, and Wine links each with its own directory as the rpath. Homebrew's
# directory is not searched, so a library that is only there is not found: "Wine cannot find the
# FreeType font library". Copy each one and the Homebrew libraries it needs into lib/external,
# make them refer to each other by @loader_path, and link the ones Wine asks for into the Unix
# library directory. Changing the references voids the signatures, so sign again, ad hoc.
extdir=$INSTALL_DIR/lib/external
brew_prefix=$(brew --prefix 2>/dev/null) || die "Homebrew is required for the host libraries ($HOST_DYLIBS)"
mkdir -p "$extdir"
copy_host_dylib() {
    local src=$1 name dep
    name=$(basename "$src")
    [ -f "$extdir/$name" ] && return 0
    [ -f "$src" ] || die "host library $src not found"
    cp -L "$src" "$extdir/$name"
    chmod u+w "$extdir/$name"
    install_name_tool -id "@loader_path/$name" "$extdir/$name" 2>/dev/null || die "install_name_tool -id failed for $name"
    # the libraries it needs from Homebrew (the system's own stay where they are)
    for dep in $(otool -L "$src" | awk 'NR > 1 { print $1 }' | grep -E "^($brew_prefix|@rpath|@loader_path)/" || true); do
        case "$dep" in
            @rpath/*|@loader_path/*) dep_src=$(dirname "$(realpath "$src")")/$(basename "$dep") ;;
            *) dep_src=$dep ;;
        esac
        [ "$(basename "$dep")" = "$name" ] && continue
        install_name_tool -change "$dep" "@loader_path/$(basename "$dep")" "$extdir/$name" 2>/dev/null \
            || die "install_name_tool -change failed for $name ($dep)"
        copy_host_dylib "$dep_src"
    done
    codesign --force --sign - "$extdir/$name" 2>/dev/null || die "codesign failed for $extdir/$name"
}
for lib in $HOST_DYLIBS; do
    copy_host_dylib "$brew_prefix/lib/$lib"
    ln -sf "../../external/$lib" "$unixdir/$lib"
done
# the Vulkan loader, which win32u.so opens when Wine was built with Vulkan
if [ -f "$VULKAN_DIST/lib/libvulkan.1.dylib" ]; then
    copy_host_dylib "$VULKAN_DIST/lib/libvulkan.1.dylib"
    ln -sf "../../external/libvulkan.1.dylib" "$unixdir/libvulkan.1.dylib"
fi
# KosmicKrisp, the Vulkan driver. The loader finds a driver by its manifest, and ntdll.so names
# share/vulkan/icd.d of the install to the loader as the only place to look (VK_DRIVER_FILES),
# so the manifest goes there. It names the driver in lib/external by a path relative to itself.
# The loader would also look in the Resources of the main bundle by itself, but only a process
# started by the path of the loader in wine.app has that bundle, not one started as bin/wine.
if [ -f "$VULKAN_DIST/lib/libvulkan.1.dylib" ] && [ -f "$MESA_DIST/lib/$VULKAN_DRIVER" ] && [ -f "$MESA_DIST/share/vulkan/icd.d/$VULKAN_ICD_JSON" ]; then
    copy_host_dylib "$MESA_DIST/lib/$VULKAN_DRIVER"
    icd_dir=$INSTALL_DIR/share/vulkan/icd.d
    icd_path=../../../lib/external/$VULKAN_DRIVER
    mkdir -p "$icd_dir"
    sed "s|\"library_path\": *\"[^\"]*\"|\"library_path\": \"$icd_path\"|" "$MESA_DIST/share/vulkan/icd.d/$VULKAN_ICD_JSON" >"$icd_dir/$VULKAN_ICD_JSON"
    grep -qF "\"$icd_path\"" "$icd_dir/$VULKAN_ICD_JSON" || die "$VULKAN_ICD_JSON has no library_path to rewrite"
    [ "$(cd "$icd_dir" && realpath "$icd_path" 2>/dev/null)" = "$(realpath "$extdir/$VULKAN_DRIVER")" ] \
        || die "$icd_path does not lead from $icd_dir to $extdir/$VULKAN_DRIVER"
    grep -qaF VK_DRIVER_FILES "$unixdir/ntdll.so" \
        || die "ntdll.so does not name VK_DRIVER_FILES: this Wine does not point the Vulkan loader at share/vulkan/icd.d"
    log "installed the Vulkan driver KosmicKrisp (Mesa $(cat "$MESA_DIST/DESCRIBE" 2>/dev/null)) with its manifest in share/vulkan/icd.d"
else
    log "no Vulkan driver in $MESA_DIST (macos/build-mesa.sh builds it), or no loader: Vulkan has no device"
fi
log "host libraries in lib/external: $(ls "$extdir" | tr '\n' ' ')"

########################################################################
# 4. The bundle
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
# 5. Sign
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
