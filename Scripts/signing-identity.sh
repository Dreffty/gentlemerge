#!/bin/sh
# Prints the identity to sign the app with.
#
# macOS remembers a permission against the app's signature. An ad-hoc signature
# changes with every build, so each rebuild is a new app to it: it asks for the
# Downloads folder, Automation and the rest all over again, and the app hangs
# until somebody answers. An "Apple Development" certificate stays the same from
# build to build, so what you granted stays granted. A free Apple ID gets you one.
#
# CODESIGN_IDENTITY wins when set; `-` asks for ad-hoc on purpose (CI, public builds).

if [ -n "${CODESIGN_IDENTITY:-}" ]; then
    printf '%s\n' "$CODESIGN_IDENTITY"
    exit 0
fi

found=$(security find-identity -v -p codesigning 2>/dev/null |
    awk -F'"' '/Apple Development:/ { print $2; exit }')
if [ -n "$found" ]; then
    printf '%s\n' "$found"
    exit 0
fi

echo "warning: no Apple Development identity here, so this build is signed ad-hoc:" \
    "macOS will treat every rebuild as a new app and ask for its permissions again." >&2
echo "-"
