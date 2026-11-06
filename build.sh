#!/bin/zsh
# Builds build/Panefold.app.
#
#   ./build.sh               native architecture
#   ./build.sh --universal   arm64 + x86_64, what releases ship
#   ./build.sh --zip         also write build/Panefold-<version>.zip
#   ./build.sh --install     also copy the app to /Applications
#
# The version comes from $VERSION, else the latest git tag, else 0.1.0.
# Signing with a stable identity matters: macOS ties the Accessibility grant to the
# signature, so an ad-hoc build loses it on every rebuild. Set PANEFOLD_SIGN_IDENTITY
# to pick one; otherwise the first Developer ID, then Apple Development, certificate is used.
set -euo pipefail

cd "$(dirname "$0")"
ROOT=$PWD
APP="$ROOT/build/Panefold.app"

UNIVERSAL=0 ZIP=0 INSTALL=0
for arg in "$@"; do
  case $arg in
    --universal) UNIVERSAL=1 ;;
    --zip) ZIP=1 ;;
    --install) INSTALL=1 ;;
    *) echo "unknown option: $arg" >&2; exit 1 ;;
  esac
done

VERSION="${VERSION:-$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)}"
VERSION="${VERSION:-0.1.0}"
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"

# One build per architecture, joined with lipo. `swift build --arch arm64 --arch x86_64` goes through
# Xcode's build system, which fails with "duplicate output file" on some Xcode 16 releases.
BINARIES=()
ARCHS=($(uname -m))
(( UNIVERSAL )) && ARCHS=(arm64 x86_64)
for arch in $ARCHS; do
  swift build -c release --triple "$arch-apple-macosx14.0"
  BINARIES+=("$(swift build -c release --triple "$arch-apple-macosx14.0" --show-bin-path)/Panefold")
done

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create "${BINARIES[@]}" -output "$APP/Contents/MacOS/Panefold"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
# The icon is drawn by scripts/make-icon.swift and cached in build/ until that script changes.
ICNS="$ROOT/build/AppIcon.icns"
if [[ ! -f "$ICNS" || "$ROOT/scripts/make-icon.swift" -nt "$ICNS" ]]; then
  rm -rf "$ROOT/build/AppIcon.iconset" && mkdir -p "$ROOT/build/AppIcon.iconset"
  swift "$ROOT/scripts/make-icon.swift" "$ROOT/build/icon-1024.png"
  for s in 16 32 128 256 512; do
    sips -z $s $s "$ROOT/build/icon-1024.png" --out "$ROOT/build/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
    sips -z $((s * 2)) $((s * 2)) "$ROOT/build/icon-1024.png" --out "$ROOT/build/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ROOT/build/AppIcon.iconset" -o "$ICNS"
fi
cp "$ICNS" "$APP/Contents/Resources/AppIcon.icns"
# Translations live in the bundle itself so SwiftUI finds them through Bundle.main.
for lproj in "$ROOT"/Resources/*.lproj(N); do
  cp -R "$lproj" "$APP/Contents/Resources/"
done
plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "$APP/Contents/Info.plist"

IDENTITY="${PANEFOLD_SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
  # Developer ID first: it's the one meant for apps shared outside the App Store.
  IDENTITIES=("${(@f)$(security find-identity -p codesigning -v 2>/dev/null | awk -F'"' '/Developer ID Application/ {print $2}'; security find-identity -p codesigning -v 2>/dev/null | awk -F'"' '/Apple Development/ {print $2}')}")
  IDENTITIES=(${IDENTITIES:#})
  if (( ${#IDENTITIES} > 0 )); then
    IDENTITY=$IDENTITIES[1]
    if (( ${#IDENTITIES} > 1 )); then
      echo "Several signing identities found; using the first. Pick one with PANEFOLD_SIGN_IDENTITY:"
      printf '  %s\n' "${IDENTITIES[@]}"
    fi
  fi
fi
if [[ -z "$IDENTITY" ]]; then
  echo "No signing identity found; signing ad-hoc. Permissions will need re-granting after each rebuild."
  IDENTITY="-"
fi

# Notarization needs a secure timestamp. Other builds skip it so they work offline.
TIMESTAMP=--timestamp=none
[[ $IDENTITY == "Developer ID Application"* ]] && TIMESTAMP=--timestamp

if [[ -n "${PANEFOLD_SIGN_IDENTITY:-}" ]]; then
  # An identity asked for by name must not quietly turn into an ad-hoc build.
  codesign --force --options runtime $TIMESTAMP --sign "$IDENTITY" "$APP"
elif ! codesign --force --options runtime $TIMESTAMP --sign "$IDENTITY" "$APP" 2>/dev/null; then
  echo "Signing with \"$IDENTITY\" failed (is the login keychain locked?). Falling back to ad-hoc."
  IDENTITY="-"
  codesign --force --options runtime --sign - "$APP"
fi
codesign --verify --strict "$APP"

echo "Built $APP $VERSION ($(lipo -archs "$APP/Contents/MacOS/Panefold"))"
echo "Signed by: $([[ $IDENTITY == "-" ]] && echo ad-hoc || echo "$IDENTITY")"

if (( INSTALL )); then
  rm -rf /Applications/Panefold.app
  cp -R "$APP" /Applications/
  echo "Installed /Applications/Panefold.app"
fi

if (( ZIP )); then
  rm -f "build/Panefold-$VERSION.zip"
  ditto -c -k --keepParent "$APP" "build/Panefold-$VERSION.zip"
  echo "Packed build/Panefold-$VERSION.zip"
fi
