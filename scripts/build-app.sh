#!/bin/zsh
# Builds Nebula.app into ./build, gated on its numbers.
#
#   scripts/build-app.sh                 build only if every accuracy and latency target is met
#   scripts/build-app.sh --recorder      the first build, before any recordings: nothing can fire
#   scripts/build-app.sh --ship-passing  build with only the gestures that met every target switched on
#   add --install to copy it to /Applications and launch it
#
# The gates: the unit tests, the per-frame recognizer benchmark (p95 ≤ 2 ms), and the
# accuracy report on your held-out test sessions (≥ 99% recall per gesture, ≤ 0.5% wrong
# gesture, ≤ 1 false fire per 4 armed hours). Recordings and your model live in
# ~/Library/Application Support/Nebula; override with NEBULA_DATA and NEBULA_MODEL.
#
# macOS ties Camera and Accessibility permissions to the code signature. Ad-hoc signing (the
# default) changes it on every build, so you'd re-grant after each rebuild. Set
# NEBULA_SIGN_IDENTITY (or NOVA_SIGN_IDENTITY) to your "Apple Development: …" identity
# (see `security find-identity -p codesigning -v`) to keep them.
set -euo pipefail
cd "$(dirname "$0")/.."

MODE=gated
INSTALL=0
for arg in "$@"; do
    case "$arg" in
        --recorder) MODE=recorder ;;
        --ship-passing) MODE=passing ;;
        --install) INSTALL=1 ;;
        *) echo "unknown option $arg"; exit 2 ;;
    esac
done

SUPPORT="$HOME/Library/Application Support/Nebula"
export NEBULA_DATA="${NEBULA_DATA:-$SUPPORT/Recordings}"
export NEBULA_MODEL="${NEBULA_MODEL:-$SUPPORT/model.json}"
mkdir -p build

echo "→ Building"
swift build -c release
BIN="$(swift build -c release --show-bin-path)"

echo "→ Unit tests, latency benchmark and allocation checks"
# The accuracy gate runs next, through nebula-report, gesture by gesture.
NEBULA_DATA= NEBULA_MODEL= swift test -c release -Xswiftc -enable-testing

GATE=build/gate.json
if [[ "$MODE" == recorder ]]; then
    echo '{"mode":"recorder","passing":[],"generatedAt":0,"summary":"Recording build: no recordings yet, so no gesture can act. Record in Practice, then build again."}' > "$GATE"
    echo "→ Recording build: every gesture stays off until the report proves it."
else
    [[ -f "$NEBULA_MODEL" ]] || { echo "No trained model at $NEBULA_MODEL. Train in Nebula (Settings → Train and report), or build with --recorder first."; exit 1; }
    echo "→ Accuracy and latency report on held-out test sessions"
    set +e
    "$BIN/nebula-report" gate --data "$NEBULA_DATA" --model "$NEBULA_MODEL" --json build/report.json --gate-file "$GATE"
    STATUS=$?
    set -e
    if [[ $STATUS -ne 0 && "$MODE" == gated ]]; then
        echo "✗ A target was missed (report above). Not building. Use --ship-passing to build with only the gestures that passed."
        exit 1
    fi
    if [[ $STATUS -ne 0 ]]; then
        echo "→ Shipping with only the gestures that met every target switched on."
    fi
fi

APP=build/Nebula.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Nebula" "$APP/Contents/MacOS/Nebula"
cp "$BIN/nebula-report" "$APP/Contents/MacOS/nebula-report"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/model.json "$APP/Contents/Resources/model.json"
cp "$GATE" "$APP/Contents/Resources/gate.json"

ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
    sips -z $size $size Resources/AppIcon.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    sips -z $((size * 2)) $((size * 2)) Resources/AppIcon.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

codesign --force --sign "${NEBULA_SIGN_IDENTITY:-${NOVA_SIGN_IDENTITY:--}}" "$APP/Contents/MacOS/nebula-report"
codesign --force --sign "${NEBULA_SIGN_IDENTITY:-${NOVA_SIGN_IDENTITY:--}}" "$APP"
echo "Built $APP"

if [[ $INSTALL -eq 1 ]]; then
    pkill -x Nebula 2>/dev/null || true
    # Wait for the old copy to quit, or launching the new one races it (error -600).
    for _ in {1..20}; do pgrep -x Nebula >/dev/null || break; sleep 0.25; done
    rm -rf /Applications/Nebula.app
    cp -R "$APP" /Applications/
    for attempt in 1 2 3; do
        open /Applications/Nebula.app && break
        sleep 1
    done
    echo "Installed and launched /Applications/Nebula.app"
fi
