#!/usr/bin/env bash
# BetterScreenshot uninstaller
# Removes BetterScreenshot from Hammerspoon. Your screenshots and Hammerspoon itself are kept.
set -euo pipefail

HS_DIR="$HOME/.hammerspoon"
INIT="$HS_DIR/init.lua"
MODULE="betterscreenshot.lua"
STAMP="$(date +%Y%m%d-%H%M%S)"

ok()   { printf '\033[32m✓\033[0m %s\n' "$*"; }
info() { printf '\033[34m→\033[0m %s\n' "$*"; }

printf '\033[1m%s\033[0m\n\n' "Uninstalling BetterScreenshot"

# 1. Remove the require line (and its comment) from init.lua, after a backup
if [[ -f "$INIT" ]] && grep -qF 'require("betterscreenshot")' "$INIT"; then
  cp "$INIT" "$INIT.bak-$STAMP"
  info "Backed up your init.lua to init.lua.bak-$STAMP"
  grep -vF -e 'require("betterscreenshot")' -e '-- BetterScreenshot (Option+Shift+S)' "$INIT.bak-$STAMP" > "$INIT" || true
  ok "Removed BetterScreenshot from init.lua"
else
  ok "init.lua doesn't load BetterScreenshot"
fi

# 2. Remove the module
if [[ -f "$HS_DIR/$MODULE" ]]; then
  rm "$HS_DIR/$MODULE"
  ok "Removed ~/.hammerspoon/$MODULE"
fi

# 3. Reload Hammerspoon if it's running
if [[ "${BETTERSCREENSHOT_NO_RESTART:-}" != "1" ]] && pgrep -xq Hammerspoon; then
  osascript -e 'quit app "Hammerspoon"' >/dev/null 2>&1 || true
  for _ in {1..20}; do pgrep -xq Hammerspoon || break; sleep 0.25; done
  open -a Hammerspoon
  ok "Restarted Hammerspoon"
fi

echo
echo "Done. Your screenshots in ~/Pictures/Screenshots were not touched."
echo "To remove Hammerspoon too:  brew uninstall --cask hammerspoon"
