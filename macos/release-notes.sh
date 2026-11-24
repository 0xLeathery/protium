#!/bin/bash
#
# Writes a release's page to stdout: its section of CHANGELOG.md (kept in the form of
# keepachangelog.com: "## [1.2.3] - 2026-01-31"), then what every release says
# (requirements, how to install, the disk image's checksum, where the source is).
#
#   macos/release-notes.sh <version> <disk image>
#
# macos/make-release.sh runs it for $RELEASE_DIR/Protium-<version>.notes.md, which
# macos/publish-release.sh publishes.

set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
PROTON_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
[ $# = 2 ] || { echo "usage: release-notes.sh <version> <disk image>" >&2; exit 64; }
VERSION=$1
dmg=$2
MIN_MACOS=${MIN_MACOS:-27.0}
commit() { git -C "$1" rev-parse --short=8 HEAD 2>/dev/null || echo unknown; }

# the section, without the blank lines around it
awk -v v="[$VERSION]" '/^## /{on = ($2 == v); next} /^\[[^]]*\]: /{on = 0} on' "${CHANGELOG:-$PROTON_DIR/CHANGELOG.md}" \
    | awk 'NF {for (; blank > 0; blank--) print ""; print; seen = 1; next} seen {blank++}'
cat <<EOF

## Requirements

- An Apple Silicon Mac
- macOS $MIN_MACOS or later
- Steam for Mac

## Install

1. Download \`$(basename "$dmg")\` and open it.
2. Drag Protium into the Applications folder, over the older one if there is one, and open it from there.
3. The first time: quit Steam, then click **Set up Steam** in Protium's window. It asks for an administrator password once, to make the folder Steam finds its compatibility tools in.
4. Start Steam and install a Windows game from your library.

The app is signed with a Developer ID and notarized by Apple.

## Verify the download

\`\`\`
shasum -a 256 $(basename "$dmg")
$(shasum -a 256 "$dmg" | cut -d' ' -f1)
\`\`\`

## Source and licenses

Protium is GPL-3.0-or-later; its components keep their own licenses. Every component's license is in the app under \`Contents/SharedSupport/licenses\`, and \`SOURCE.txt\` there lists the repository and commit each one was built from. This release is built from \`$(commit "$PROTON_DIR")\` of this repository and \`$(commit "$PROTON_DIR/wine")\` of [protium-wine](https://github.com/0xLeathery/protium-wine). The changes of every release are in [CHANGELOG.md](https://github.com/0xLeathery/protium/blob/macos-port/CHANGELOG.md).
EOF
