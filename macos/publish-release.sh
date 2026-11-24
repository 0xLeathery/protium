#!/bin/bash
#
# Publish the release macos/make-release.sh made: tags the commit v<version> and creates the
# release on GitHub from $RELEASE_DIR/Protium-<version>.notes.md with the disk image attached.
# This is the only way a release is published, so that its page, the app and CHANGELOG.md say the
# same thing.
#
#   macos/publish-release.sh [--yes]
#
# It refuses when the disk image is not notarized, when its notes are missing, when the checkout
# has changes that are not committed or not pushed, and when the release exists already. It shows
# what it will publish and asks, unless --yes is given.
#
# Environment overrides: BUILD_ROOT, RELEASE_DIR, VERSION (default: macos/app/VERSION),
# REPO (default 0xLeathery/protium), REMOTE (default protium).

set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
PROTON_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
BUILD_ROOT=${BUILD_ROOT:-$HOME/projects/proton-macos-build}
RELEASE_DIR=${RELEASE_DIR:-$BUILD_ROOT/release}
VERSION=${VERSION:-$(cat "$SCRIPT_DIR/app/VERSION")}
REPO=${REPO:-0xLeathery/protium}
REMOTE=${REMOTE:-protium}
die() { echo "publish-release.sh: error: $*" >&2; exit 1; }

dmg=$RELEASE_DIR/Protium-$VERSION.dmg
notes=$RELEASE_DIR/Protium-$VERSION.notes.md
[ -f "$dmg" ] || die "no $dmg: run macos/make-release.sh"
[ -s "$notes" ] || die "no $notes: run macos/make-release.sh"
xcrun stapler validate "$dmg" >/dev/null 2>&1 || die "$dmg is not notarized"
spctl -a -t open --context context:primary-signature "$dmg" 2>/dev/null || die "Gatekeeper does not accept $dmg"
cd "$PROTON_DIR"
[ -z "$(git status --porcelain --untracked-files=no --ignore-submodules=dirty)" ] || die "the checkout has changes that are not committed"
head=$(git rev-parse HEAD)
branch=$(git rev-parse --abbrev-ref HEAD)
git fetch -q "$REMOTE" "$branch"
git merge-base --is-ancestor "$head" "$REMOTE/$branch" || die "commit $head is not pushed to $REMOTE"
gh release view "v$VERSION" -R "$REPO" >/dev/null 2>&1 && die "release v$VERSION exists already"

echo "Protium $VERSION, commit $head, $(du -h "$dmg" | cut -f1) $dmg"
echo "---------------------------------------------------------------- notes"
cat "$notes"
echo "----------------------------------------------------------------"
if [ "${1:-}" != --yes ]; then
    printf 'Publish this as v%s on github.com/%s? [y/N] ' "$VERSION" "$REPO"
    read -r answer
    [ "$answer" = y ] || die "not published"
fi
gh release create "v$VERSION" "$dmg" -R "$REPO" --target "$head" --title "Protium $VERSION" --notes-file "$notes"
gh release view "v$VERSION" -R "$REPO" --json url -q .url
