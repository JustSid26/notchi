#!/bin/bash
# Package build/Notchi.app into build/Notchi.dmg (drag-to-Applications layout).
set -euo pipefail
cd "$(dirname "$0")/.."

[ -d build/Notchi.app ] || ./scripts/build-app.sh
STAGE="build/dmg"
rm -rf "$STAGE" build/Notchi.dmg
mkdir -p "$STAGE"
cp -R build/Notchi.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Notchi" -srcfolder "$STAGE" -ov -format UDZO build/Notchi.dmg >/dev/null
rm -rf "$STAGE"
echo "Created build/Notchi.dmg"
