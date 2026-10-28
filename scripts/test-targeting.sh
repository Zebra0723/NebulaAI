#!/bin/zsh
# Runs the end-to-end targeting tests with real windows, inside the installed Nebula.app
# (so they use Nebula's Accessibility and Automation permissions). Opens and closes windows in
# Safari, Preview, TextEdit and Keynote: run it when you aren't using them.
set -euo pipefail
APP="${1:-/Applications/Nebula.app}"
pkill -x Nebula 2>/dev/null || true
"$APP/Contents/MacOS/Nebula" --test-targeting
