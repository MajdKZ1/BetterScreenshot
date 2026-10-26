#!/usr/bin/env bash
# BetterScreenshot installer
# Installs Hammerspoon (via Homebrew) and sets up the screenshot hotkey.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HS_DIR="$HOME/.hammerspoon"
INIT="$HS_DIR/init.lua"
MODULE="betterscreenshot.lua"
REQUIRE_LINE='require("betterscreenshot")'
STAMP="$(date +%Y%m%d-%H%M%S)"

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
ok()   { printf '\033[32m✓\033[0m %s\n' "$*"; }
info() { printf '\033[34m→\033[0m %s\n' "$*"; }
fail() { printf '\033[31m✗\033[0m %s\n' "$*" >&2; exit 1; }

bold "Installing BetterScreenshot"
echo

# 1. macOS only
[[ "$(uname)" == "Darwin" ]] || fail "BetterScreenshot only works on macOS."

# 2. Homebrew
if ! command -v brew >/dev/null 2>&1; then
  fail "Homebrew isn't installed. Install it first (https://brew.sh), then run this script again:
  /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
fi
ok "Homebrew found"

# 3. Hammerspoon
if [[ -d "/Applications/Hammerspoon.app" ]]; then
  ok "Hammerspoon already installed"
else
  info "Installing Hammerspoon..."
  brew install --cask hammerspoon
  ok "Hammerspoon installed"
fi

# 4. Folders
mkdir -p "$HS_DIR" "$HOME/Pictures/Screenshots"
ok "Screenshots will be saved to ~/Pictures/Screenshots"

# 5. Copy the module (back up an older, different copy first)
if [[ -f "$HS_DIR/$MODULE" ]] && ! cmp -s "$REPO_DIR/$MODULE" "$HS_DIR/$MODULE"; then
  cp "$HS_DIR/$MODULE" "$HS_DIR/$MODULE.bak-$STAMP"
  info "Backed up your old $MODULE to $MODULE.bak-$STAMP"
fi
cp "$REPO_DIR/$MODULE" "$HS_DIR/$MODULE"
ok "Copied $MODULE to ~/.hammerspoon"

# 6. Load it from init.lua (back up first, never add the line twice)
if [[ -f "$INIT" ]]; then
  if grep -qF "$REQUIRE_LINE" "$INIT"; then
    ok "init.lua already loads BetterScreenshot"
  else
    cp "$INIT" "$INIT.bak-$STAMP"
    info "Backed up your init.lua to init.lua.bak-$STAMP"
    printf '\n-- BetterScreenshot (Option+Shift+S)\n%s\n' "$REQUIRE_LINE" >> "$INIT"
    ok "Added BetterScreenshot to your existing init.lua"
  fi
else
  printf -- '-- BetterScreenshot (Option+Shift+S)\n%s\n' "$REQUIRE_LINE" > "$INIT"
  ok "Created ~/.hammerspoon/init.lua"
fi

# 7. (Re)start Hammerspoon so the config loads
if [[ "${BETTERSCREENSHOT_NO_RESTART:-}" != "1" ]]; then
  if pgrep -xq Hammerspoon; then
    osascript -e 'quit app "Hammerspoon"' >/dev/null 2>&1 || true
    for _ in {1..20}; do pgrep -xq Hammerspoon || break; sleep 0.25; done
  fi
  open -a Hammerspoon
  ok "Hammerspoon started"
fi

echo
bold "Almost done! Give Hammerspoon these two permissions:"
echo "  1. System Settings → Privacy & Security → Screen & System Audio Recording → turn on Hammerspoon"
echo "  2. System Settings → Privacy & Security → Accessibility → turn on Hammerspoon"
echo
echo "Then quit Hammerspoon (menu bar hammer icon → Quit) and open it again."
echo
bold "Press Option+Shift+S to take a screenshot. Enjoy!"
