#!/bin/sh

# copies /usr/share/jugendhackt-iso/desktop to the user's desktop on the first login.
# The desktop folder name depends on the language, e.g. "Desktop" or "Schreibtisch".
# Runs only once, so deleted files are not restored.

MARKER="${XDG_STATE_HOME:-$HOME/.local/state}/jugendhackt-iso/desktop-files-copied"

if [ -e "$MARKER" ]; then
  exit 0
fi

xdg-user-dirs-update
DESKTOP_DIR="$(xdg-user-dir DESKTOP)"

mkdir -p "$DESKTOP_DIR"
cp -r --update=none /usr/share/jugendhackt-iso/desktop/. "$DESKTOP_DIR/"

mkdir -p "$(dirname "$MARKER")"
touch "$MARKER"
