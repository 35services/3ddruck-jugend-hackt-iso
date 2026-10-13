#!/bin/sh

# puts a link "Infos" to /usr/share/jugendhackt-iso/desktop on the user's desktop, on every
# login, so a deleted link comes back. The desktop folder name depends on the language,
# e.g. "Desktop" or "Schreibtisch".
#
# The files belong to root and are in a folder only root can change, so they can't be
# changed by accident: a text editor can't save them. A read-only file on the desktop
# isn't enough, since an editor can replace it with a new file, which the desktop folder
# allows. Copies on the desktop from older versions of this script are removed on every
# login and replaced by the link.
#
# Also copies the files from /etc/skel that are missing in the home folder. The
# home folder is kept on the persistence partition (data/persistence.conf), so it
# already exists when live-config creates the user, which then skips /etc/skel.

MARKER="${XDG_STATE_HOME:-$HOME/.local/state}/jugendhackt-iso/desktop-files-copied"
SHARED_DIR=/usr/share/jugendhackt-iso/desktop

if [ ! -e "$MARKER" ]; then
  cp -r --update=none /etc/skel/. "$HOME/"
  xdg-user-dirs-update
fi

DESKTOP_DIR="$(xdg-user-dir DESKTOP)"
mkdir -p "$DESKTOP_DIR"

for FILE in "$SHARED_DIR"/*; do
  TARGET="$DESKTOP_DIR/$(basename "$FILE")"
  if [ -e "$TARGET" ] || [ -L "$TARGET" ]; then
    rm -f "$TARGET"
  fi
done

if [ ! -L "$DESKTOP_DIR/Infos" ]; then
  ln -s "$SHARED_DIR" "$DESKTOP_DIR/Infos"
fi

mkdir -p "$(dirname "$MARKER")"
touch "$MARKER"
