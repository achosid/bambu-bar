#!/bin/zsh
# Install Bambu Bar.app into /Applications and open it.
#   scripts/install.sh           uses the existing build, or builds if missing
#   scripts/install.sh --build   rebuilds before installing
set -euo pipefail

ROOT=${0:A:h:h}
APP="$ROOT/build/App.noindex/Bambu Bar.app"
DEST="/Applications/Bambu Bar.app"
if [[ "${1:-}" == "--build" || ! -d "$APP" ]]; then
  "$ROOT/scripts/build.sh"
fi
pkill -x "Bambu Bar" 2>/dev/null && sleep 1 || true
rm -rf "$DEST"
ditto "$APP" "$DEST"
open "$DEST"
echo "==> Installed $DEST"
