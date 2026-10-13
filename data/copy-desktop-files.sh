#!/bin/sh

# copies /usr/share/jugendhackt-iso/desktop to the user's desktop on the first login.
# The desktop folder name depends on the language, e.g. "Desktop" or "Schreibtisch".
# Runs only once, so deleted files are not restored. cp keeps the files' mode, so
# the .txt files, which the build makes read-only, stay read-only on the desktop.
#
# Also copies the files from /etc/skel that are missing in the home folder. The
# home folder is kept on the persistence partition (data/persistence.conf), so it
# already exists when live-config creates the user, which then skips /etc/skel.

MARKER="${XDG_STATE_HOME:-$HOME/.local/state}/jugendhackt-iso/desktop-files-copied"

if [ -e "$MARKER" ]; then
  exit 0
fi

cp -r --update=none /etc/skel/. "$HOME/"

xdg-user-dirs-update
DESKTOP_DIR="$(xdg-user-dir DESKTOP)"

mkdir -p "$DESKTOP_DIR"
cp -r --update=none /usr/share/jugendhackt-iso/desktop/. "$DESKTOP_DIR/"

mkdir -p "$(dirname "$MARKER")"
touch "$MARKER"
