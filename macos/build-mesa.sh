#!/bin/bash
#
# Build KosmicKrisp, Mesa's Vulkan driver on Metal, for the native arm64 macOS Wine build.
#
#   lib/libvulkan_kosmickrisp.dylib                         arm64
#   share/vulkan/icd.d/kosmickrisp_mesa_icd.aarch64.json    its manifest, which names the driver
#                                                           by a path relative to itself
#
# under $MESA_DIST. Windows code reaches the driver through Wine's vulkan-1.dll and winevulkan,
# win32u.so and the Vulkan loader (macos/build-vulkan.sh), which finds a driver by its manifest.
# vkd3d-proton (Direct3D 12) is what needs it. Only the Vulkan driver is built: OpenGL on it
# (Zink and Mesa's EGL) is not.
#
# The build has two stages, the way github.com/athei/mach9 builds it. KosmicKrisp compiles its
# OpenCL C kernels at build time with three tools of Mesa's (mesa_clc, vtn_bindgen2, kk_clc),
# which link LLVM, SPIRV-LLVM-Translator and SPIRV-Tools; those come from Homebrew. Stage 1
# builds just the tools. Stage 2 builds the driver with LLVM and SPIRV-Tools off and the tools
# of stage 1 named in its native file, with a pkg-config that searches nowhere and Homebrew off
# PATH, so that the driver links system libraries only and nothing that happens to be installed
# changes what is built.
#
# The source is the macos-patched branch of github.com/athei/mesa at a fixed commit, built as
# it is. Mesa wants commits written with AI labelled as such and takes none at all in some
# directories (its AGENTS.md); this script never patches the source, and refuses a source tree
# that differs from the commit.
#
# Environment overrides:
#   BUILD_ROOT     (default ~/projects/proton-macos-build)
#   MESA_REPO      (default https://github.com/athei/mesa)
#   MESA_COMMIT    (default 7bbfd48b2e7490a2091716087647d7ddf8f7c408, macos-patched on 2026-11-15)
#   MESA_SRC       (default $BUILD_ROOT/mesa-src), cloned when missing
#   MESA_DIST      (default $BUILD_ROOT/mesa-dist)
#   PYTHON         the Python that the environment below is made from; Mesa's build needs
#                  3.10 or newer, which the Python of Xcode is not (default Homebrew's python3)
#   MESA_VENV      Python environment that gets meson and the modules Mesa's build scripts
#                  need (default $BUILD_ROOT/mesa-venv)
#   JOBS           build parallelism (default 12)
#   MIN_FREE_GB    abort if less free disk space than this (default 10)

set -euo pipefail

BUILD_ROOT=${BUILD_ROOT:-$HOME/projects/proton-macos-build}
MESA_REPO=${MESA_REPO:-https://github.com/athei/mesa}
MESA_COMMIT=${MESA_COMMIT:-7bbfd48b2e7490a2091716087647d7ddf8f7c408}
MESA_SRC=${MESA_SRC:-$BUILD_ROOT/mesa-src}
MESA_DIST=${MESA_DIST:-$BUILD_ROOT/mesa-dist}
PYTHON=${PYTHON:-}
VENV=${MESA_VENV:-$BUILD_ROOT/mesa-venv}
JOBS=${JOBS:-12}
MIN_FREE_GB=${MIN_FREE_GB:-10}
MESON_VERSION=1.11.2
PYTHON_REQUIREMENTS="mako==1.4.3 markupsafe==3.0.4 packaging==26.3 pyyaml==6.0.3"
HOMEBREW_FORMULAE="llvm spirv-llvm-translator spirv-tools bison"
BLD=$BUILD_ROOT/mesa-build
TOOLS_BLD=$BLD/tools
DRIVER_BLD=$BLD/driver
DRIVER_PREFIX=$BLD/driver-install
TOOLS="src/compiler/clc/mesa_clc src/compiler/spirv/vtn_bindgen2 src/kosmickrisp/clc/kk_clc"
DRIVER=libvulkan_kosmickrisp.dylib
ICD_JSON=kosmickrisp_mesa_icd.aarch64.json
# Both stages: the macOS platform and KosmicKrisp alone, no OpenGL.
COMMON_OPTIONS="--buildtype=release -Dplatforms=macos -Dvulkan-drivers=kosmickrisp -Dgallium-drivers= -Dopengl=false -Dzstd=disabled"
TOOLS_OPTIONS="-Dmesa-clc=enabled -Dprecomp-compiler=enabled"
# Stage 2: the tools of stage 1, and every optional library denied.
DRIVER_OPTIONS="-Dmesa-clc=system -Dprecomp-compiler=system -Dllvm=disabled -Dspirv-tools=disabled
    -Degl=disabled -Dgles1=disabled -Dgles2=disabled -Dglx=disabled -Dgbm=disabled
    -Ddisplay-info=disabled -Dexpat=disabled -Dxmlconfig=disabled -Dvalgrind=disabled
    -Dlibunwind=disabled -Dlmsensors=disabled -Dglvnd=disabled -Dgallium-va=disabled"

log() { echo ":: $*" >&2; }
die() { echo "build-mesa.sh: error: $*" >&2; exit 1; }

[ "$(uname -s)" = Darwin ] || die "this script builds on macOS only"
[ "$(uname -m)" = arm64 ] || die "this script expects an arm64 (Apple Silicon) host"
for tool in git ninja pkg-config brew; do command -v $tool >/dev/null || die "$tool not found"; done
NINJA=$(command -v ninja)
brew_prefix=$(brew --prefix)
PYTHON=${PYTHON:-$brew_prefix/bin/python3}
[ -x "$PYTHON" ] || die "no Python at $PYTHON (brew install python, or name one with PYTHON)"
"$PYTHON" -c 'import sys; sys.exit(sys.version_info < (3, 10))' || die "$PYTHON is $("$PYTHON" --version 2>&1); Mesa's build needs 3.10 or newer"
python_version=$("$PYTHON" -c 'import platform; print(platform.python_version())')
missing=
for f in $HOMEBREW_FORMULAE; do [ -d "$brew_prefix/opt/$f" ] || missing="$missing $f"; done
[ -z "$missing" ] || die "not installed in $brew_prefix:$missing (brew install$missing)"
LLVM_CONFIG=$brew_prefix/opt/llvm/bin/llvm-config
[ -x "$LLVM_CONFIG" ] || die "no llvm-config at $LLVM_CONFIG"
# Mesa needs a newer bison than macOS's 2.3; macOS's flex is new enough.
BISON=$brew_prefix/opt/bison/bin/bison
FLEX=/usr/bin/flex
[ -x "$BISON" ] || die "no bison at $BISON"
[ -x "$FLEX" ] || die "no flex at $FLEX (install the Xcode command line tools)"

# Only Apple's compilers, which the native files name, and none of the caller's flags or
# pkg-config paths: each stage sets the search it needs.
# The oldest macOS the driver runs on (Protium supports macOS 27.0 and later), kept through
# the unset below; it is part of the key, so a change rebuilds the driver
deployment_target=${MACOSX_DEPLOYMENT_TARGET:-27.0}
unset CC CXX OBJC OBJCXX CFLAGS CXXFLAGS OBJCFLAGS CPPFLAGS LDFLAGS PKG_CONFIG_PATH PKG_CONFIG_LIBDIR MACOSX_DEPLOYMENT_TARGET
export MACOSX_DEPLOYMENT_TARGET=$deployment_target

key="mesa=$MESA_COMMIT options=[$(echo $COMMON_OPTIONS $TOOLS_OPTIONS $DRIVER_OPTIONS)]"
key="$key llvm=$("$LLVM_CONFIG" --version) spirv=[$(PKG_CONFIG_PATH=$brew_prefix/lib/pkgconfig pkg-config --modversion LLVMSPIRVLib SPIRV-Tools | paste -sd ' ' -)]"
key="$key bison=[$("$BISON" --version | head -1)] flex=[$("$FLEX" --version | head -1)] meson=$MESON_VERSION python=$python_version [$PYTHON_REQUIREMENTS]"
key="$key cc=[$(/usr/bin/clang --version | head -1)] sdk=$(xcrun --show-sdk-version) macos=$MACOSX_DEPLOYMENT_TARGET"
if [ -f "$MESA_DIST/lib/$DRIVER" ] && [ -f "$MESA_DIST/share/vulkan/icd.d/$ICD_JSON" ] && [ "$(cat "$MESA_DIST/KEY" 2>/dev/null)" = "$key" ]; then
    log "Mesa $(cat "$MESA_DIST/DESCRIBE" 2>/dev/null): KosmicKrisp built already in $MESA_DIST"
    exit 0
fi

mkdir -p "$BUILD_ROOT"
free_gb=$(df -g "$BUILD_ROOT" | awk 'NR==2 {print $4}')
log "free disk space: ${free_gb} GB"
[ "$free_gb" -ge "$MIN_FREE_GB" ] || die "only ${free_gb} GB free on $BUILD_ROOT (minimum ${MIN_FREE_GB} GB)"

########################################################################
# 1. meson and the Python modules of Mesa's build scripts
########################################################################
# The environment is made again when the Python it came from or what goes into it changes.
venv_key="python=$python_version meson=$MESON_VERSION $PYTHON_REQUIREMENTS"
if [ "$(cat "$VENV/KEY" 2>/dev/null)" != "$venv_key" ] || ! "$VENV/bin/python3" -c 'import mako, packaging, yaml' 2>/dev/null; then
    log "Python $python_version environment in $VENV: meson $MESON_VERSION, $PYTHON_REQUIREMENTS"
    case "$VENV" in "$BUILD_ROOT"/?*) ;; *) die "MESA_VENV ($VENV) is not below $BUILD_ROOT" ;; esac
    rm -rf "$VENV"
    "$PYTHON" -m venv "$VENV"
    # shellcheck disable=SC2086 # one word per requirement
    "$VENV/bin/python3" -m pip install --quiet --disable-pip-version-check "meson==$MESON_VERSION" $PYTHON_REQUIREMENTS
    echo "$venv_key" >"$VENV/KEY"
fi
MESON=$VENV/bin/meson

########################################################################
# 2. Source at the fixed commit, unmodified
########################################################################
if [ ! -d "$MESA_SRC/.git" ]; then
    log "cloning $MESA_REPO -> $MESA_SRC"
    git clone -q --filter=blob:none --no-checkout "$MESA_REPO" "$MESA_SRC"
fi
git -C "$MESA_SRC" cat-file -e "$MESA_COMMIT^{commit}" 2>/dev/null || git -C "$MESA_SRC" fetch -q origin "$MESA_COMMIT"
[ "$(git -C "$MESA_SRC" rev-parse HEAD 2>/dev/null)" = "$MESA_COMMIT" ] \
    || git -C "$MESA_SRC" -c advice.detachedHead=false checkout -q --detach "$MESA_COMMIT"
dirty=$(git -C "$MESA_SRC" status --porcelain --untracked-files=no | head -5)
[ -z "$dirty" ] || die "$MESA_SRC differs from $MESA_COMMIT; Mesa is built unmodified:
$dirty"
describe="$(cat "$MESA_SRC/VERSION") $(git -C "$MESA_SRC" rev-parse --short=12 HEAD)"
log "Mesa $describe"

########################################################################
# 3. Build: fresh trees whenever what they are built from changes
########################################################################
if [ "$(cat "$BLD/.build-mesa-key" 2>/dev/null)" != "$key" ]; then
    rm -rf "$BLD"
    mkdir -p "$BLD"
fi

# Stage 1, the tools, for this host. They link Homebrew's LLVM, SPIRV-LLVM-Translator and
# SPIRV-Tools, found through Homebrew's pkg-config files.
cat >"$BLD/tools-native.ini" <<EOF
[binaries]
c = '/usr/bin/clang'
cpp = '/usr/bin/clang++'
objc = '/usr/bin/clang'
objcpp = '/usr/bin/clang++'
llvm-config = '$LLVM_CONFIG'
EOF
if [ ! -f "$TOOLS_BLD/build.ninja" ]; then
    log "configuring the tools (stage 1)"
    # shellcheck disable=SC2086 # one word per option
    PKG_CONFIG_PATH=$brew_prefix/lib/pkgconfig PATH="$VENV/bin:$PATH" "$MESON" setup "$TOOLS_BLD" "$MESA_SRC" \
        --native-file "$BLD/tools-native.ini" $COMMON_OPTIONS $TOOLS_OPTIONS >"$BUILD_ROOT/mesa-build.tools-setup.log" 2>&1 \
        || die "meson setup of the tools failed, see $BUILD_ROOT/mesa-build.tools-setup.log"
fi
log "building the tools (stage 1)"
# shellcheck disable=SC2086 # one word per target
PATH="$VENV/bin:$PATH" "$NINJA" -C "$TOOLS_BLD" -j"$JOBS" $TOOLS >"$BUILD_ROOT/mesa-build.tools-ninja.log" 2>&1 \
    || die "building the tools failed, see $BUILD_ROOT/mesa-build.tools-ninja.log"

# Stage 2, the driver. CoreGraphics is linked explicitly: the driver calls CGColorSpace
# functions, which it would otherwise only find at run time, through QuartzCore, as
# flat-namespace imports. cmake is named as false so that meson has no CMake to look for
# libraries with.
cat >"$BLD/driver-native.ini" <<EOF
[binaries]
c = '/usr/bin/clang'
cpp = '/usr/bin/clang++'
objc = '/usr/bin/clang'
objcpp = '/usr/bin/clang++'
mesa_clc = '$TOOLS_BLD/src/compiler/clc/mesa_clc'
vtn_bindgen2 = '$TOOLS_BLD/src/compiler/spirv/vtn_bindgen2'
kk_clc = '$TOOLS_BLD/src/kosmickrisp/clc/kk_clc'
bison = '$BISON'
flex = '$FLEX'
cmake = 'false'

[built-in options]
c_link_args = ['-framework', 'CoreGraphics']
cpp_link_args = ['-framework', 'CoreGraphics']
objc_link_args = ['-framework', 'CoreGraphics']
EOF
(
    export PKG_CONFIG_LIBDIR=
    export NINJA
    export PATH="$VENV/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    if [ ! -f "$DRIVER_BLD/build.ninja" ]; then
        log "configuring the driver (stage 2)"
        # shellcheck disable=SC2086 # one word per option
        "$MESON" setup "$DRIVER_BLD" "$MESA_SRC" --native-file "$BLD/driver-native.ini" --prefix="$DRIVER_PREFIX" \
            $COMMON_OPTIONS $DRIVER_OPTIONS >"$BUILD_ROOT/mesa-build.driver-setup.log" 2>&1 \
            || die "meson setup of the driver failed, see $BUILD_ROOT/mesa-build.driver-setup.log"
    fi
    log "building the driver (stage 2)"
    "$NINJA" -C "$DRIVER_BLD" -j"$JOBS" >"$BUILD_ROOT/mesa-build.driver-ninja.log" 2>&1 \
        || die "building the driver failed, see $BUILD_ROOT/mesa-build.driver-ninja.log"
    rm -rf "$DRIVER_PREFIX"
    "$NINJA" -C "$DRIVER_BLD" install >>"$BUILD_ROOT/mesa-build.driver-ninja.log" 2>&1 \
        || die "installing the driver failed, see $BUILD_ROOT/mesa-build.driver-ninja.log"
)
echo "$key" >"$BLD/.build-mesa-key"

########################################################################
# 4. Stage and check
########################################################################
# Into $MESA_DIST.part, renamed into place once all of it is checked.
part=$MESA_DIST.part
rm -rf "$part"
mkdir -p "$part/lib" "$part/share/vulkan/icd.d"
lib=$part/lib/$DRIVER
cp -L "$DRIVER_PREFIX/lib/$DRIVER" "$lib"
chmod u+w "$lib"
# The install name Mesa wrote is a path in the install prefix. Changing it voids the linker's
# signature, which arm64 code needs to load, so sign again, ad hoc.
install_name_tool -id "@loader_path/$DRIVER" "$lib" 2>/dev/null || die "install_name_tool -id failed for $DRIVER"
codesign --force --sign - "$lib" 2>/dev/null || die "codesign failed for $DRIVER"

[ "$(lipo -archs "$lib")" = arm64 ] || die "$DRIVER is not an arm64-only Mach-O"
deps=$(otool -L "$lib" | tail -n +3 | awk '{print $1}' | grep -vE '^(/usr/lib/|/System/Library/)' || true)
[ -z "$deps" ] || die "$DRIVER loads libraries outside the system:
$deps"
# A flat-namespace import is looked up in whatever the process has loaded and fails at run time
# where nothing provides it.
flat=$(nm -m -u "$lib" | grep 'dynamically looked up' | grep -v 'weak external' || true)
[ -z "$flat" ] || die "$DRIVER has flat-namespace imports:
$flat"
nm -gU "$lib" | awk '{print $NF}' | grep -qxF _vk_icdGetInstanceProcAddr || die "$DRIVER does not export vk_icdGetInstanceProcAddr"

# Mesa writes the driver's install path into the manifest. The loader takes a relative
# library_path as relative to the manifest, which keeps $MESA_DIST usable wherever it is.
icd=$part/share/vulkan/icd.d/$ICD_JSON
[ -f "$DRIVER_PREFIX/share/vulkan/icd.d/$ICD_JSON" ] || die "the driver build installed no $ICD_JSON"
"$VENV/bin/python3" - "$DRIVER_PREFIX/share/vulkan/icd.d/$ICD_JSON" "$icd" "../../../lib/$DRIVER" <<'EOF'
import json, sys
src, dst, path = sys.argv[1:]
manifest = json.load(open(src))
manifest["ICD"]["library_path"] = path
json.dump(manifest, open(dst, "w"), indent=4)
EOF
grep -qF "\"../../../lib/$DRIVER\"" "$icd" || die "$ICD_JSON does not name ../../../lib/$DRIVER"

echo "$describe" >"$part/DESCRIBE"
echo "$key" >"$part/KEY"
rm -rf "$MESA_DIST"
mv "$part" "$MESA_DIST"
log "done: $MESA_DIST (Mesa $describe)"
ls -l "$MESA_DIST/lib" "$MESA_DIST/share/vulkan/icd.d" >&2
cat "$MESA_DIST/share/vulkan/icd.d/$ICD_JSON" >&2
