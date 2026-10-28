#!/bin/bash
# Adds the approvals API to Galaxy Link in a NovaAI checkout, then runs galaxy's tests.
#   galaxy-patch/apply.sh ~/path/to/NovaAI
set -euo pipefail
NOVA="${1:?usage: apply.sh path/to/NovaAI}"
PATCH="$(cd "$(dirname "$0")" && pwd)/0001-approvals.patch"
cd "$NOVA/galaxy"
git apply --check "$PATCH"
git apply "$PATCH"
bun test
echo "Applied. Restart galaxyd (launchctl kickstart -k gui/\$(id -u)/ai.galaxy.link) to serve approvals."
