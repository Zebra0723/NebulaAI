#!/bin/zsh
# Shows, gesture by gesture, what Nebula saw in your recordings: how sure each judge was,
# which of Judge A's conditions your hand missed, and which frames were unusable. Paste
# the output to Claude to tune Nebula to your hands. Joint numbers only, never images.
set -euo pipefail
SUPPORT="$HOME/Library/Application Support/Nebula"
"/Applications/Nebula.app/Contents/MacOS/nebula-report" diagnose \
    --data "$SUPPORT/Recordings" --model "$SUPPORT/model.json" 2>&1 | tee "$SUPPORT/diagnosis.txt"
echo
echo "Saved to $SUPPORT/diagnosis.txt"
