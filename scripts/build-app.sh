#!/bin/bash
# Build Notchi.app into ./build.
#   SIGN_ID="Notchi Self-Signed" ./scripts/build-app.sh   # stable signature (permissions survive updates)
#   ./scripts/build-app.sh                                # ad-hoc signature
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
# Sign with a real certificate if this Mac has one (Apple Development / Developer ID / a
# self-signed code-signing cert): the signature then stays the same across builds, so macOS
# keeps Notchi's permissions (Input Monitoring, iTerm2/Spotify control). Otherwise ad-hoc.
if [ -z "${SIGN_ID:-}" ]; then
  SIGN_ID="$(security find-identity -v -p codesigning 2>/dev/null | awk 'NR==1 && /\)/ {print $2}')"
  SIGN_ID="${SIGN_ID:--}"
fi
APP="build/Notchi.app"

swift build -c "$CONFIG" ${ARCHS:+$ARCHS}
BIN="$(swift build -c "$CONFIG" ${ARCHS:+$ARCHS} --show-bin-path)/Notchi"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Notchi"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp bin/island "$APP/Contents/Resources/island"
cp Resources/iterm_tabs.py "$APP/Contents/Resources/iterm_tabs.py"
# The Java backend (notes, clipboard, screen time, workspaces…). Notchi starts it by itself
# when Java 21+ is installed, and works without it otherwise.
if [ -f backend/pom.xml ] && { [ -n "${JAVA_HOME:-}" ] || /usr/libexec/java_home -v 21+ >/dev/null 2>&1; }; then
  (cd backend && ./mvnw -q package -DskipTests) || echo "warning: backend build failed; Notchi will run without it"
fi
if [ -f backend/target/notchi-backend.jar ]; then
  cp backend/target/notchi-backend.jar "$APP/Contents/Resources/notchi-backend.jar"
fi
chmod +x "$APP/Contents/Resources/island"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/" || true

codesign --force --deep --sign "$SIGN_ID" "$APP"
echo "Built $APP (signed with: $([ "$SIGN_ID" = "-" ] && echo ad-hoc || echo "your certificate ${SIGN_ID:0:8}…"))"
