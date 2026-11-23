#!/bin/bash
#
# Build GStreamer for winegstreamer, which decodes the audio and video of Media Foundation and
# DirectShow (game cutscenes and intros), for the native arm64 macOS Wine build:
#
#   $GST_DIST/lib/libgst*-1.0.0.dylib, liborc-0.4.0.dylib, libav*.dylib, libsw*.dylib
#   $GST_DIST/lib/gstreamer-1.0/libgst*.dylib     the plugins
#   $GST_DIST/lib/pkgconfig                        for Wine's configure
#
# The sources are Proton's: GStreamer and orc at the commits of Proton's gstreamer and gst-orc
# submodules, built unmodified with the options of Proton's Makefile.in, without what macOS has no
# use (X11 in gst-plugins-base, libsoup in gst-plugins-good), and with GStreamer GL on CGL and
# Cocoa instead of GLX and EGL: winegstreamer links it, and goes on without it when it fails at
# run time. FFmpeg is Proton's too (its ffmpeg submodule, 4.3.3, which Wine's winedmo is written
# for), for gst-libav and for winedmo, which opens the files of Media Foundation's MP4, ASF/WMV,
# AVI, WAV, MPEG and MP3 sources. Proton builds it with no decoders, since Steam gives Linux
# transcoded copies of a game's videos, which Mac Steam does not; so this build enables the common
# decoders of game video (H.264, HEVC, MPEG-4, WMV/VC-1, AAC, MP3, WMA, AC-3) and the demuxers
# and bitstream filters winedmo asks for by name. It is LGPL (no --enable-gpl, no --enable-nonfree).
# AV1 is left to Proton's dav1d plugin from gst-plugins-rs, not built yet: FFmpeg 4.3's wrapper for
# dav1d does not build against a current dav1d.
#
# Homebrew provides glib, libogg, libvorbis, opus, theora, libvpx and mpg123.
#
# Environment overrides:
#   BUILD_ROOT     (default ~/projects/proton-macos-build)
#   GST_SRC        sources (default $BUILD_ROOT/gst-src)
#   GST_DIST       output (default $BUILD_ROOT/gst-dist)
#   VENV           Python environment with meson (default $BUILD_ROOT/py-venv)
#   MIN_FREE_GB    abort if less free disk space than this (default 4)

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
PROTON_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
BUILD_ROOT=${BUILD_ROOT:-$HOME/projects/proton-macos-build}
GST_SRC=${GST_SRC:-$BUILD_ROOT/gst-src}
GST_DIST=${GST_DIST:-$BUILD_ROOT/gst-dist}
VENV=${VENV:-$BUILD_ROOT/py-venv}
MIN_FREE_GB=${MIN_FREE_GB:-4}
BLD=$BUILD_ROOT/gst-build
MESON_VERSION=1.11.2

log() { echo ":: $*" >&2; }
die() { echo "build-gstreamer.sh: error: $*" >&2; exit 1; }

[ "$(uname -s)" = Darwin ] && [ "$(uname -m)" = arm64 ] || die "this script builds on Apple Silicon macOS only"
command -v brew >/dev/null || die "Homebrew is required"
BREW=$(brew --prefix)
for f in glib libogg libvorbis opus theora libvpx mpg123; do
    [ -d "$BREW/opt/$f" ] || die "Homebrew $f not installed: brew install $f"
done
mkdir -p "$BUILD_ROOT"
free_gb=$(df -g "$BUILD_ROOT" | awk 'NR==2 {print $4}')
[ "$free_gb" -ge "$MIN_FREE_GB" ] || die "only ${free_gb} GB free on $BUILD_ROOT (minimum ${MIN_FREE_GB} GB)"
if [ "$("$VENV/bin/meson" --version 2>/dev/null)" != "$MESON_VERSION" ]; then
    [ -x "$VENV/bin/python3" ] || python3 -m venv "$VENV"
    "$VENV/bin/python3" -m pip install --quiet --disable-pip-version-check "meson==$MESON_VERSION"
fi
export PATH="$GST_DIST/bin:$VENV/bin:$PATH"   # orc's orcc, for the plugins
export PKG_CONFIG_PATH="$GST_DIST/lib/pkgconfig:$BREW/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"

########################################################################
# 1. Sources: Proton's submodule commits, and the FFmpeg release
########################################################################
fetch() {  # name url commit
    local dir=$GST_SRC/$1
    if [ "$(git -C "$dir" rev-parse HEAD 2>/dev/null)" != "$3" ]; then
        log "fetching $1 at $3"
        [ -d "$dir/.git" ] || { git init -q "$dir" && git -C "$dir" remote add origin "$2"; }
        git -C "$dir" fetch -q --depth 1 origin "$3"
        git -C "$dir" -c advice.detachedHead=false checkout -q --detach FETCH_HEAD
    fi
    [ -z "$(git -C "$dir" status --porcelain --untracked-files=no)" ] || die "$dir differs from $3; it is built unmodified"
}
mkdir -p "$GST_SRC"
fetch gstreamer https://github.com/GStreamer/gstreamer.git "$(git -C "$PROTON_DIR" ls-tree HEAD gstreamer | awk '{print $3}')"
fetch orc https://github.com/GStreamer/orc.git "$(git -C "$PROTON_DIR" ls-tree HEAD gst-orc | awk '{print $3}')"
fetch ffmpeg https://github.com/FFmpeg/FFmpeg.git "$(git -C "$PROTON_DIR" ls-tree HEAD ffmpeg | awk '{print $3}')"

key="gstreamer=$(git -C "$GST_SRC/gstreamer" rev-parse HEAD) orc=$(git -C "$GST_SRC/orc" rev-parse HEAD) ffmpeg=$(git -C "$GST_SRC/ffmpeg" rev-parse HEAD) script=$(shasum "$0" | cut -c1-12)"
if [ "$(cat "$GST_DIST/KEY" 2>/dev/null)" = "$key" ]; then
    log "up to date: $GST_DIST"
    exit 0
fi
rm -rf "$GST_DIST" "$BLD"
mkdir -p "$GST_DIST" "$BLD"

meson_build() {  # name source-dir meson-args...
    local name=$1 src=$2; shift 2
    log "building $name"
    meson setup "$BLD/$name" "$src" --prefix="$GST_DIST" --libdir=lib --buildtype=release \
        --wrap-mode=nodownload "$@" >"$BLD/$name.setup.log" 2>&1 || { tail -20 "$BLD/$name.setup.log" >&2; die "meson setup failed for $name"; }
    ninja -C "$BLD/$name" install >"$BLD/$name.build.log" 2>&1 || { tail -20 "$BLD/$name.build.log" >&2; die "build failed for $name"; }
}

########################################################################
# 2. orc and FFmpeg
########################################################################
meson_build orc "$GST_SRC/orc" -Dorc-test=disabled -Dtests=disabled -Dexamples=disabled -Dbenchmarks=disabled -Dgtk_doc=disabled

log "building FFmpeg $(cat "$GST_SRC/ffmpeg/RELEASE")"
mkdir -p "$BLD/ffmpeg"
(cd "$BLD/ffmpeg" && "$GST_SRC/ffmpeg/configure" --prefix="$GST_DIST" \
    --enable-shared --disable-static --enable-pic --disable-programs --disable-doc \
    --disable-network --disable-autodetect --disable-everything \
    --enable-decoder=h264,hevc,mpeg4,mpeg1video,mpeg2video,msmpeg4v1,msmpeg4v2,msmpeg4v3,wmv1,wmv2,wmv3,vc1,theora,vp8,vp9 \
    --enable-decoder=aac,mp3,mp2,ac3,eac3,flac,vorbis,opus,wmav1,wmav2,wmapro,adpcm_ms,adpcm_ima_wav,pcm_s16le,pcm_s24le,pcm_f32le,pcm_u8 \
    --enable-parser=h264,hevc,mpeg4video,mpegvideo,vc1,aac,mpegaudio,ac3,flac,vorbis,opus,vp8,vp9,av1 \
    --enable-demuxer=matroska,mov,avi,wav,asf,mpegps,mpegts,mp3,aac,flac,ogg \
    --enable-bsf=h264_mp4toannexb,hevc_mp4toannexb \
    --enable-swresample \
    >"$BLD/ffmpeg.setup.log" 2>&1) || { tail -20 "$BLD/ffmpeg.setup.log" >&2; die "FFmpeg configure failed"; }
make -C "$BLD/ffmpeg" -j"$(sysctl -n hw.ncpu)" install >"$BLD/ffmpeg.build.log" 2>&1 || { tail -20 "$BLD/ffmpeg.build.log" >&2; die "FFmpeg build failed"; }

########################################################################
# 3. GStreamer and its plugins, with Proton's options
########################################################################
common=(-Dtests=disabled -Dexamples=disabled -Dnls=disabled -Ddoc=disabled)
meson_build gstreamer "$GST_SRC/gstreamer/subprojects/gstreamer" "${common[@]}" \
    -Dgst_parse=false -Dbenchmarks=disabled -Dtools=disabled -Dbash-completion=disabled \
    -Dintrospection=disabled -Dcheck=enabled -Dlibunwind=disabled -Dlibdw=disabled
meson_build gst-plugins-base "$GST_SRC/gstreamer/subprojects/gst-plugins-base" "${common[@]}" \
    -Dauto_features=disabled -Dadder=enabled -Dapp=enabled -Daudioconvert=enabled -Daudioresample=enabled \
    -Dogg=enabled -Dopus=enabled -Dpbtypes=enabled -Dplayback=enabled -Dtheora=enabled -Dtypefind=enabled \
    -Dvideoconvertscale=enabled -Dvorbis=enabled -Dorc=enabled -Dtools=disabled -Dintrospection=disabled \
    -Dgl=enabled -Dgl_api=opengl -Dgl_platform=cgl -Dgl_winsys=cocoa -Dgl-graphene=disabled
meson_build gst-plugins-good "$GST_SRC/gstreamer/subprojects/gst-plugins-good" "${common[@]}" \
    -Dauto_features=disabled -Dapetag=enabled -Daudioparsers=enabled -Dautodetect=enabled -Davi=enabled \
    -Ddebugutils=enabled -Ddeinterlace=enabled -Dicydemux=enabled -Disomp4=enabled -Dmatroska=enabled \
    -Dmpg123=enabled -Dvideobox=enabled -Dvideofilter=enabled -Dvpx=enabled -Dwavparse=enabled \
    -Did3demux=enabled -Dorc=enabled
meson_build gst-plugins-bad "$GST_SRC/gstreamer/subprojects/gst-plugins-bad" "${common[@]}" \
    -Dauto_features=disabled -Dvideoparsers=enabled -Dhls=enabled -Dmpegtsdemux=enabled -Daudiobuffersplit=enabled \
    -Dintrospection=disabled
meson_build gst-libav "$GST_SRC/gstreamer/subprojects/gst-libav" -Dtests=disabled -Ddoc=disabled

echo "$key" >"$GST_DIST/KEY"
log "done: $GST_DIST ($(ls "$GST_DIST/lib/gstreamer-1.0" | grep -c '\.dylib$') plugins)"
