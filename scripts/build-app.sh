#!/bin/zsh
# Builds build/ReGlance.app: a release build wrapped in an app bundle with
# Resources/Info.plist (regular Mac app with a Dock icon), ad-hoc code signed.
# Formula/reglance.rb does the same steps when installing through Homebrew.
#
#   scripts/build-app.sh          build
#   scripts/build-app.sh --open   build, then launch it
set -euo pipefail

cd "${0:A:h}/.."
APP="build/ReGlance.app"

swift build -c release --product Reglance
BIN="$(swift build -c release --show-bin-path)/Reglance"

# Quit a running copy so the bundle can be replaced.
pkill -x Reglance 2>/dev/null && sleep 0.5 || true

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Reglance"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"   # from scripts/make-icon.swift
plutil -lint "$APP/Contents/Info.plist" >/dev/null

codesign --force --sign - --identifier app.reglance "$APP"
codesign --verify --strict "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--open" ]]; then
    open "$APP"
fi
