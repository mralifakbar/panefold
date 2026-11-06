#!/bin/zsh
# Everything a pull request should pass, run on this Mac. There is no hosted CI.
#
#   ./scripts/ci.sh
set -euo pipefail
cd "$(dirname "$0")/.."

echo "› Unit tests"
swift test

echo "› Translations"
for f in Resources/*.lproj/*.strings(N); do plutil -lint "$f" >/dev/null || { plutil -lint "$f"; exit 1; }; done
python3 scripts/check-strings.py

echo "› Universal build"
./build.sh --universal --zip

echo "› Smoke test"
APP=build/Panefold.app
codesign --verify --strict "$APP"
lipo -archs "$APP/Contents/MacOS/Panefold" | grep -q x86_64
lipo -archs "$APP/Contents/MacOS/Panefold" | grep -q arm64
plutil -lint "$APP/Contents/Info.plist" >/dev/null

echo "✓ All checks passed"
