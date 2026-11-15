#!/bin/zsh
# Builds build/Reglance.app: a release build wrapped in an app bundle with
# Resources/Info.plist (menu bar agent, no Dock icon), ad-hoc code signed.
# Formula/reglance.rb does the same steps when installing through Homebrew.
#
#   scripts/build-app.sh          build
#   scripts/build-app.sh --open   build, then launch it
set -euo pipefail

cd "${0:A:h}/.."
APP="build/Reglance.app"

swift build -c release --product Reglance
BIN="$(swift build -c release --show-bin-path)/Reglance"

# Quit a running copy so the bundle can be replaced.
pkill -x Reglance 2>/dev/null && sleep 0.5 || true

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/Reglance"
cp Resources/Info.plist "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist" >/dev/null

codesign --force --sign - --identifier app.reglance "$APP"
codesign --verify --strict "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--open" ]]; then
    open "$APP"
fi
