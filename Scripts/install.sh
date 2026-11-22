#!/bin/bash
# Builds the app, installs it into /Applications and puts a shortcut (alias) on the Desktop.
set -euo pipefail
cd "$(dirname "$0")/.."

SRC="dist/K24 Zipper.app"
DEST="/Applications/K24 Zipper.app"
LINK="$HOME/Desktop/K24 Zipper"

./Scripts/build-app.sh

# Quit a running copy so it can be replaced.
osascript -e 'tell application id "com.k24.zipper" to quit' >/dev/null 2>&1 || true
sleep 1

rm -rf "$DEST"
ditto "$SRC" "$DEST"
touch "$DEST"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST" || true

# Desktop shortcut: a Finder alias when possible, otherwise a symbolic link.
rm -f "$LINK"
if ! osascript -e "tell application \"Finder\" to make alias file to (POSIX file \"$DEST\") at (path to desktop folder)" \
               -e "tell application \"Finder\" to set name of result to \"K24 Zipper\"" >/dev/null 2>&1; then
  ln -s "$DEST" "$LINK"
fi

echo "Installed $DEST"
echo "Shortcut on Desktop: $LINK"
