#!/bin/sh
# Puts build/GentleMerge.app into a folder of applications.
#
# Copied alongside and renamed into place, so a copy that fails half way leaves
# the app you already had.

set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
DIRECTORY=${1:-}

# An empty or relative folder would put the removals below somewhere nobody meant.
case "$DIRECTORY" in
    /*) ;;
    *) echo "install-app: wants an absolute folder, got \"$DIRECTORY\"" >&2; exit 64 ;;
esac
[ -d "$ROOT/build/GentleMerge.app" ] || { echo "install-app: build first: make app" >&2; exit 1; }

TARGET="$DIRECTORY/GentleMerge.app"
NEW="$TARGET.new"
OLD="$TARGET.old"

mkdir -p "$DIRECTORY"
rm -rf "$NEW" "$OLD"
ditto "$ROOT/build/GentleMerge.app" "$NEW"
if [ -e "$TARGET" ]; then mv "$TARGET" "$OLD"; fi
mv "$NEW" "$TARGET"
rm -rf "$OLD"

echo "gentlemerge: installed $TARGET"
