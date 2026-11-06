#!/bin/zsh
# Publishes a release from this Mac: runs every check, builds the universal app, tags the
# commit, and uploads the zip with its SHA-256 to GitHub Releases. Needs the GitHub CLI (gh).
#
#   ./scripts/release.sh 0.2.0
#
# Add the version to CHANGELOG.md first; its section becomes the release notes.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: scripts/release.sh <version>, for example 0.2.0}"
VERSION="${VERSION#v}"
TAG="v$VERSION"
REPO="mralifakbar/panefold"

[[ -z "$(git status --porcelain)" ]] || { echo "Commit or stash your changes first." >&2; exit 1; }
grep -q "^## \[$VERSION\]" CHANGELOG.md || { echo "Add a ## [$VERSION] section to CHANGELOG.md first." >&2; exit 1; }
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && { echo "$TAG already exists." >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "Sign in to the GitHub CLI first: gh auth login" >&2; exit 1; }

VERSION="$VERSION" ./scripts/ci.sh

ZIP="build/Panefold-$VERSION.zip"
(cd build && shasum -a 256 "Panefold-$VERSION.zip" | tee SHA256SUMS.txt)

NOTES=build/notes.md
awk -v v="[$VERSION]" '/^## \[/ { p = index($0, v) > 0; next } /^\[[^]]+\]: / { p = 0 } p' CHANGELOG.md > $NOTES
{
  echo
  echo "### Install"
  echo
  echo "1. Download **Panefold-$VERSION.zip**, unzip it, and move **Panefold.app** to Applications."
  echo "2. Open it and follow the welcome tour. It asks for Accessibility access, which macOS requires before any app can move other apps' windows."
  echo
  echo "SHA-256:"
  echo '```'
  cat build/SHA256SUMS.txt
  echo '```'
} >> $NOTES

git push origin HEAD
git tag -a "$TAG" -m "Panefold $VERSION"
git push origin "$TAG"
gh release create "$TAG" "$ZIP" build/SHA256SUMS.txt --repo "$REPO" --title "Panefold $VERSION" --notes-file $NOTES --verify-tag
echo "✓ Released Panefold $VERSION: https://github.com/$REPO/releases/tag/$TAG"
