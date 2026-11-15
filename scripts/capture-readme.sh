#!/bin/zsh
# Captures the README's screenshots and GIFs into docs/images/, in light and dark.
# Each scene runs Reglance in demo mode (made-up chats, canned replies, a gradient
# backdrop over the rest of the screen), so no real chat or window ends up in an image.
# The scenes are staged in Sources/Reglance/DemoScene.swift.
#
#   scripts/capture-readme.sh                 every scene
#   scripts/capture-readme.sh hero picker     only these scenes
#
# Needs ffmpeg (brew install ffmpeg) and Screen Recording permission for your terminal
# (System Settings > Privacy & Security > Screen & System Audio Recording). Takes about
# two minutes; leave the mouse and keyboard alone while it runs. It quits a running
# Reglance first. Turn on Do Not Disturb so notifications stay out of the shots.
set -euo pipefail

cd "${0:A:h}/.."
OUT=docs/images
GIF_WIDTH=${GIF_WIDTH:-800}   # pixels; the captures themselves are Retina (2x)
SCENES=("$@")
(( $#SCENES )) || SCENES=(hero picker attachments chats widgets agent)

command -v ffmpeg >/dev/null || { echo "GIFs need ffmpeg: brew install ffmpeg" >&2; exit 1; }

scripts/build-app.sh   # also quits a running Reglance
BIN=build/Reglance.app/Contents/MacOS/Reglance
WORK=$(mktemp -d)
trap 'pkill -f "$BIN" 2>/dev/null || true; rm -rf "$WORK"' EXIT
mkdir -p $OUT
sips -s format png -Z 256 Resources/AppIcon.icns --out $OUT/icon.png >/dev/null

for scene in $SCENES; do
    for appearance in light dark; do
        demo="$WORK/$scene-$appearance"
        mkdir -p $demo
        echo "Capturing $scene ($appearance)…"
        REGLANCE_DEMO=$demo REGLANCE_DEMO_SCENE=$scene REGLANCE_DEMO_APPEARANCE=$appearance \
            "$BIN" >/dev/null 2>"$demo/log" &
        app=$!

        # The app writes scene-ready.json once the shot is staged.
        for _ in {1..300}; do
            [[ -f $demo/scene-ready.json ]] && break
            kill -0 $app 2>/dev/null || { echo "Reglance exited:" >&2; cat $demo/log >&2; exit 1; }
            sleep 0.1
        done
        [[ -f $demo/scene-ready.json ]] || { echo "Timed out waiting for scene $scene" >&2; exit 1; }
        rect=$(plutil -extract rect raw $demo/scene-ready.json)
        video=$(plutil -extract video raw $demo/scene-ready.json)
        file="$OUT/$scene-$appearance"

        if (( video > 0 )); then
            # Start recording, then tell the app to play the scene. One spare second
            # covers screencapture's start-up delay.
            screencapture -x -R$rect -V$(( video + 1 )) "$demo/clip.mov" &
            recorder=$!
            sleep 0.4
            touch $demo/scene-go
            wait $recorder
            ffmpeg -loglevel error -y -i "$demo/clip.mov" -vf \
                "fps=20,scale=$GIF_WIDTH:-1:flags=lanczos,split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=sierra2_4a:diff_mode=rectangle" \
                "$file.gif"
            echo "  $file.gif ($(du -h "$file.gif" | cut -f1))"
        else
            screencapture -x -R$rect "$file.png"
            touch $demo/scene-go
            echo "  $file.png ($(du -h "$file.png" | cut -f1))"
        fi

        kill $app 2>/dev/null || true
        wait $app 2>/dev/null || true
    done
done
echo "Done. Images are in $OUT/."
